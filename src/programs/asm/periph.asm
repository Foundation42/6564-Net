; periph.asm — one actor walks the peripheral row (spec §7).
;
; Four devices, four capabilities, zero I/O instructions: the console is
; PTT 0, the entropy well PTT 1, the RTC PTT 2, the block store PTT 3 —
; every one reached by SEND, every reply landing in the same RX ring any
; actor would use. The program timestamps itself off the RTC, draws eight
; random bytes and prints them in hex, writes them (with the timestamp)
; to a disk sector, reads the sector back and verifies it, then prints
; how many fabric cycles the whole errand took. A device completion in
; the CQ is the interrupt; there is nothing else to wait on.
;
; Driver discipline: requests are sequential, one in flight at a time,
; and a reply may race its own send-ack on the fabric — so the ack wait
; stashes any delivery record it pops ($8B0/$8B8) for getrx to collect.
;
; The contract, as directives: four pinned capabilities (the request
; SQEs bake their targets, and the RTC answers to token 0 — it keeps no
; secrets), `reply` wiring each answering device's own PTT slot 0 back
; at our RX ring, and the rings the code addresses at their pinned
; bases. The RX landing entries are the code's own business (lines
; below stage them before RECV); the elapsed count at near $890 is the
; machine's own RTC arithmetic, read back into the report.

        .actor Periph(con cap = 0, ent cap = 1 reply, rtc cap = 2 reply, blk cap = 3 reply)
        .ring 0 sq base=$2400 cap=1
        .ring 5 sq base=$2480 cap=1
        .ring 1 cq cap=16
        .ring 2 rx base=$2100 cap=2 auto_repost
        .reserve $2200 $400
        .var elapsed $890

        .system
        p = Periph(con, ent, rtc, blk)
        con = Console()
        ent = Entropy()
        rtc = Rtc()
        blk = Block()
        .endsystem

        .org $1000
        ; two landing buffers (cap-2 AUTO_REPOST ring; cookie = buffer)
        LDA ##$2200
        STA !$2100
        STA !$2118
        LDA #128
        STA !$2108
        LDA #0
        STA !$2110
        LDA ##$2280
        STA !$2120
        STA !$2138
        LDA #128
        STA !$2128
        LDA #0
        STA !$2130
        RECV 2
        RECV 2
        ; the char SQE (slot 5): one byte from $2560 to the console,
        ; cookie 2 — how hexq speaks, one glyph per datagram
        LDA #1
        STA !$2480
        LDA ##$FF00_0000_0000_0000
        STA !$2488
        LDA ##$2560
        STA !$2490
        LDA ##$2_0000_0001  ; len 1 | cookie 2
        STA !$2498

        ; ── the banner ──
        LDA ##banner
        STA !$2410
        LDA ##$1_0000_001A  ; len 26 | cookie 1
        STA !$2418
        JSR sendcon

        ; ── RTC: t0 ──
        LDA #1
        STA !$2500          ; request word0: tag 1 (RTC)
        LDA ##$FF00_0000_0000_0000
        STA !$2508          ; request word1: our reply window
        LDA #1
        STA !$2400
        LDA ##$FF00_0200_0000_0000
        STA !$2408          ; target: the RTC, via PTT 2
        LDA ##$2500
        STA !$2410
        LDA ##$1_0000_0010  ; len 16 | cookie 1
        STA !$2418
        JSR req
        JSR getrx
        STA $850            ; t0

        ; ── entropy: draw 8 bytes ──
        LDA #2
        STA !$2500          ; request word0: tag 2 (entropy)
        LDA #8
        STA !$2510          ; request word2: count ($2508 still the window)
        LDA ##$FF00_0100_0000_0000
        STA !$2408          ; target: the entropy well, via PTT 1
        LDA ##$1_0000_0018  ; len 24 | cookie 1
        STA !$2418
        JSR req
        JSR getrx
        STA $858            ; the draw
        LDA ##s_entr
        STA !$2410
        LDA ##$1_0000_0008  ; len 8
        STA !$2418
        JSR sendcon
        LDA $858
        JSR hexq
        JSR crlf

        ; ── block: write the draw and the timestamp to sector 3 ──
        LDA #3
        STA !$2600          ; header word0: tag 3 (block write; no reply, still distinct)
        LDA #0
        STA !$2608          ; header word1: window (present, ignored for writes)
        LDA ##$301          ; header word2: op 1 (write) | sector 3
        STA !$2610
        LDA $858
        STA !$2618          ; body from byte 24
        LDA $850
        STA !$2620
        LDA #1
        STA !$2400
        LDA ##$FF00_0300_0000_0000
        STA !$2408          ; target: the block store, via PTT 3
        LDA ##$2600
        STA !$2410
        LDA ##$1_0000_0028  ; len 40 | cookie 1
        STA !$2418
        JSR req             ; write applies at delivery: the ack IS durability

        ; ── block: read sector 3 back and verify ──
        LDA #4
        STA !$2640          ; header word0: tag 4 (block read)
        LDA ##$FF00_0000_0000_0000
        STA !$2648          ; header word1: reply window
        LDA ##$300
        STA !$2650          ; header word2: op 0 (read) | sector 3
        LDA ##$2640
        STA !$2410
        LDA ##$1_0000_0018  ; len 24 | cookie 1
        STA !$2418
        JSR req
        JSR getrx           ; A = sector word 0, $8E0 = where it landed
        CMP $858
        BNE bad
        CLC
        LDA $8E0
        ADC #8
        STA $8E8
        LDA ($8E8)          ; sector word 1
        CMP $850
        BNE bad
        LDA ##s_ok
        STA !$2410
        LDA ##$1_0000_0009  ; len 9
        STA !$2418
        JSR sendcon
        BRA fin
bad:    LDA ##s_bad
        STA !$2410
        LDA ##$1_0000_000A  ; len 10
        STA !$2418
        JSR sendcon

        ; ── RTC: t1, and the bill ──
fin:    LDA #1
        STA !$2500          ; word0 back to tag 1 (entropy left its own)
        LDA #1
        STA !$2400
        LDA ##$FF00_0200_0000_0000
        STA !$2408
        LDA ##$2500
        STA !$2410
        LDA ##$1_0000_0010  ; len 16 ($2508 still the window)
        STA !$2418
        JSR req
        JSR getrx
        SEC
        SBC $850
        STA $890            ; elapsed, also for the harness
        LDA ##s_cyc
        STA !$2410
        LDA ##$1_0000_0007  ; len 7
        STA !$2418
        JSR sendcon
        LDA $890
        JSR hexq
        JSR crlf
        HLT

; ── console helpers ──────────────────────────────────────────────────────

; print the staged string: word2/word3 set by caller
sendcon: LDA #1
        STA !$2400
        LDA ##$FF00_0000_0000_0000
        STA !$2408
        JMP req

; submit SQE 0, wait for its ack (cookie 1), stash any reply that races it
req:    SEND 0
rq1:    LSTN 1
        CQPOP 1
        BEQ rq1
        STA $880
        AND #$FF
        CMP #3
        BEQ rqrx            ; the reply beat the ack home
        CMP #2
        BNE rq1
        TXA
        AND ##$FFFF_FFFF
        CMP #1
        BNE rq1
        LDA $880
        LSR #8
        AND #$FF
        BNE fail            ; a device said no: loud, not wedged
        RTS
rqrx:   STX $8B0
        LDA #1
        STA $8B8
        BRA rq1

; collect a device reply: A = its first DATA qword (past the echoed
; tag), $8E0 = where the data starts (landing buffer + 8)
getrx:  LDA $8B8
        BNE gr2             ; already stashed by req
gr1:    LSTN 1
        CQPOP 1
        BEQ gr1
        AND #$FF
        CMP #3
        BNE gr1
        STX $8B0
gr2:    LDA #0
        STA $8B8
        CLC
        LDA $8B0
        ADC #8              ; past the echoed tag (§7.3 addendum)
        STA $8E0
        LDA ($8E0)
        RTS

; one character to the console (the slot-5 SQE, cookie 2)
putc:   STA !$2560
        SEND 5
pc1:    LSTN 1
        CQPOP 1
        BEQ pc1
        STA $888
        AND #$FF
        CMP #3
        BEQ pcrx
        CMP #2
        BNE pc1
        TXA
        AND ##$FFFF_FFFF
        CMP #2
        BNE pc1
        LDA $888
        LSR #8
        AND #$FF
        BNE fail
        RTS
pcrx:   STX $8B0
        LDA #1
        STA $8B8
        BRA pc1

fail:   BRK

; one nibble as a hex glyph
puthex: CLC
        ADC ##hextab
        STA $8D0
        LDA ($8D0)
        AND #$FF
        JMP putc

; A as 16 hex digits, most significant first: peel nibbles LSB-first
; into $900.., then walk the cursor back down printing
hexq:   STA $860
        LDA #16
        STA $870
        LDA ##$900
        STA $878
hx1:    LDA $860
        AND #$0F
        STA ($878)
        LDA $860
        LSR #4
        STA $860
        CLC
        LDA $878
        ADC #8
        STA $878
        DEC $870
        BNE hx1
        LDA #16
        STA $870
hx2:    SEC
        LDA $878
        SBC #8
        STA $878
        LDA ($878)
        JSR puthex
        DEC $870
        BNE hx2
        RTS

crlf:   LDA #10
        JMP putc

banner: .ascii "6564 PERIPHERAL BUS CHECK"
        .byte 10
s_entr: .ascii "ENTROPY "
s_ok:   .ascii "BLOCK OK"
        .byte 10
s_bad:  .ascii "BLOCK BAD"
        .byte 10
s_cyc:  .ascii "CYCLES "
hextab: .ascii "0123456789ABCDEF"
