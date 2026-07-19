; pipe_sink.asm — pipeline tail: verify and checksum each data item, ack
; everything, never die. Each item should arrive as val = (seq+1)·2^n − 1
; where n is the number of transform stages.
;
; The sink is deliberately immortal: shutdown over a lossy fabric is
; two-generals, and the last hop's DONE ack can always be lost. Because we
; keep re-acking duplicates forever (parked between events, costing nothing),
; the stage behind us retries until its ack arrives, halts, and the machine
; quiesces around us. No timer chain here — nothing keeps us artificially
; awake.
;
; The contract, as directives the loader executes (src/asm_run.zig): the
; upstream ack capability pinned at PTT 2 (its window constant is baked
; into the ack SQE below; `rx=3` names the last stage's ack ring), and
; the rings pinned where the code stages their entries — the cap-2
; AUTO_REPOST item RX at slot 2, storage $2A00, and the ack SQ at
; $2440. No timer ring and no black hole: nothing keeps us artificially
; awake. K and the stage count n arrive through arguments at
; $2600/$2608; the landing and ack buffers are reserved at $2200.
; Consumed count ($880; K+1 = complete), the checksum of data vals
; ($8C0) and verification errors ($8C8) read back into the report —
; they are what the demo verifies.

        .actor Sink(up cap = 2 rx=3, k arg @ $2600, n arg @ $2608)
        .ring 1 cq cap=32
        .ring 2 rx base=$2A00 cap=2 auto_repost
        .ring 4 sq base=$2440 cap=1
        .reserve $2200 $100
        .var consumed $880
        .var checksum $8C0
        .var verify_errors $8C8

        .org $1000
        LDA #0
        STA $880
        STA $8C0
        STA $8C8
        ; RX 2: items from upstream — two landing buffers (AUTO_REPOST),
        ; cookie = buffer address
        LDA ##$2200
        STA !$2A00
        STA !$2A18
        LDA #16
        STA !$2A08
        LDA #0
        STA !$2A10
        LDA ##$2220
        STA !$2A20
        STA !$2A38
        LDA #16
        STA !$2A28
        LDA #0
        STA !$2A30
        RECV 2
        RECV 2
        ; SQ 4: acks to upstream (PTT 2)
        LDA #1
        STA !$2440          ; op = send
        LDA ##$FF00_0200_0000_0000
        STA !$2448          ; target
        LDA ##$2260
        STA !$2450          ; buffer
        LDA ##$2_0000_0008
        STA !$2458          ; len 8 | cookie 2
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY
        AND #$FF
        CMP #3
        BNE wait            ; our ack sends' transport acks: ignore
        TYA
        LSR #8
        AND #$FF
        CMP #0
        BNE wait            ; rejected: nothing landed
        STX $8E0            ; cookie = where the item landed
        LDA ($8E0)          ; inbound seq
        CMP $880
        BEQ fresh
        ; duplicate of a consumed item: our ack was lost — re-ack it
        STA !$2260
        SEND 4
        BRA wait
fresh:  CMP !$2600
        BCS accept          ; the DONE item: no data to verify
        ; verify val == (seq+1)·2^n − 1
        CLC
        LDA ($8E0)
        ADC #1
        LDX !$2608
        BEQ vdone
vloop:  ASL
        DEX
        BNE vloop
vdone:  SEC
        SBC #1
        LDY #8
        CMP ($8E0),Y
        BEQ vok
        INC $8C8            ; a corrupted transform would show here
vok:    CLC
        LDA $8C0
        LDY #8
        ADC ($8E0),Y
        STA $8C0            ; checksum += val
accept: LDA ($8E0)
        STA !$2260
        SEND 4              ; ack it
        INC $880
        BRA wait            ; and serve forever
