; http_get.asm — a 6502 descendant speaks HTTP/1.1 to the real world.
;
; The net device (§7.4) is a raw byte pipe; the protocol lives HERE, in
; 6564 code — the polyfill layer of §7.5 in its simplest form. Open a
; connection, send the request the harness staged, then pump: ask the
; pipe for bytes, forward each chunk straight from its landing buffer to
; the console (AUTO_REPOST's deferred grant keeps it valid while the
; console ack is awaited), ask again. An EMPTY reply means "nothing yet";
; a REJECTED recv request means EOF — the ack vocabulary is the framing.
;
; Harness contract:
;   PTT 0 console  1 net       desc: 0 SQ ($2400), 1 CQ, 2 RX ($2100)
;   $2518.. hostname           $2608.. request text
;   near $8A8 = port           $8B0 = open req len   $8B8 = send req len
;   landing buffers $2200/$2300 (cap 240), staged here

        .org $1000
        ; two landing buffers (cap-2 AUTO_REPOST ring)
        LDA ##$2200
        STA !$2100
        STA !$2118
        LDA #240
        STA !$2108
        LDA #0
        STA !$2110
        LDA ##$2300
        STA !$2120
        STA !$2138
        LDA #240
        STA !$2128
        LDA #0
        STA !$2130
        RECV 2
        RECV 2

        ; ── open(host, port) ──
        LDA #0
        STA !$2500          ; word0: op 0
        LDA ##$FF00_0000_0000_0000
        STA !$2508          ; word1: reply window (device PTT slot 0)
        LDA $8A8
        STA !$2510          ; word2: port
        LDA #1
        STA !$2400          ; SQE: op send
        LDA ##$FF00_0100_0000_0000
        STA !$2408          ; target: the net device, via PTT 1
        LDA ##$2500
        STA !$2410
        LDA $8B0
        ORA ##$1_0000_0000  ; len | cookie 1
        STA !$2418
        JSR req
        JSR getrx           ; A = connection id
        STA $858
        ASL #8
        STA $868            ; conn << 8, ready to OR with ops

        ; ── send the GET ──
        LDA $868
        ORA #1
        STA !$2600          ; word0: op 1 | conn
        LDA ##$2600
        STA !$2410
        LDA $8B8
        ORA ##$1_0000_0000
        STA !$2418
        JSR req             ; the ack is the write ack

        ; stage the recv request once ($2700): word1 window, word2 max
        LDA ##$FF00_0000_0000_0000
        STA !$2708
        LDA #240
        STA !$2710

        ; ── pump: recv → console → recv ──
pump:   LDA $868
        ORA #2
        STA !$2700          ; word0: op 2 | conn
        LDA ##$FF00_0100_0000_0000
        STA !$2408          ; target: the net device — EVERY lap; the
                            ; console print left itself in this field
                            ; (a shared staged SQE is mutable state:
                            ; set every field you depend on, every time)
        LDA ##$2700
        STA !$2410
        LDA ##$1_0000_0018  ; len 24 | cookie 1
        STA !$2418
        SEND 0
rwait:  LSTN 1
        CQPOP 1
        BEQ rwait
        STA $880
        AND #$FF
        CMP #3
        BEQ rstash          ; the data beat the ack home
        CMP #2
        BNE rwait
        TXA
        AND ##$FFFF_FFFF
        CMP #1
        BNE rwait
        LDA $880
        LSR #8
        AND #$FF
        BEQ rok             ; accepted: bytes (or an empty try-again) follow
        CMP #3
        BEQ eof             ; rejected recv: the pipe has ended
        BRA fail
rstash: STX $8C8
        LDA $880
        STA $8C0
        LDA #1
        STA $8D0
        BRA rwait
rok:    JSR getrx           ; wait the reply; $8C0 = its completion word0
        LDA $8C0            ; count = bits 32.. of the delivery record
        LSR #32
        AND ##$FF_FFFF
        BEQ pump            ; empty: nothing yet, ask again
        ORA ##$1_0000_0000  ; len | cookie 1
        STA $890
        LDA #1
        STA !$2400
        LDA ##$FF00_0000_0000_0000
        STA !$2408          ; target: the console, via PTT 0
        LDA $8E0
        STA !$2410          ; straight from the landing buffer
        LDA $890
        STA !$2418
        JSR req
        BRA pump

        ; ── EOF: close and sign off ──
eof:    LDA $868
        ORA #3
        STA !$2500          ; word0: op 3 | conn
        LDA ##$FF00_0100_0000_0000
        STA !$2408          ; target: the net device, not the teletype
        LDA ##$2500
        STA !$2410
        LDA ##$1_0000_0008
        STA !$2418
        JSR req
        HLT

; submit SQE 0 to the net/console, wait its ack (cookie 1), stash a
; racing delivery — periph.asm's driver discipline, verbatim
req:    SEND 0
rq1:    LSTN 1
        CQPOP 1
        BEQ rq1
        STA $880
        AND #$FF
        CMP #3
        BEQ rqrx
        CMP #2
        BNE rq1
        TXA
        AND ##$FFFF_FFFF
        CMP #1
        BNE rq1
        LDA $880
        LSR #8
        AND #$FF
        BNE fail
        RTS
rqrx:   STX $8C8
        LDA $880
        STA $8C0
        LDA #1
        STA $8D0
        BRA rq1

; collect a device reply: A = first qword, $8E0 = landing buffer,
; $8C0 = the delivery's completion word0 (for byte counts)
getrx:  LDA $8D0
        BNE gr2
gr1:    LSTN 1
        CQPOP 1
        BEQ gr1
        STA $8C0
        AND #$FF
        CMP #3
        BNE gr1
        STX $8C8
gr2:    LDA #0
        STA $8D0
        LDA $8C8
        STA $8E0
        LDA ($8E0)
        RTS

fail:   BRK
