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
; Harness contract:
;   PTT 2 → upstream ack ring
;   desc slots: 1 CQ, 2 item RX (buf $2200, cookie $2A), 4 ack SQ
;   RAM: $2600 = K, $2608 = n (stage count)
;   near: $880 E (items consumed; K+1 = complete), $8C0 checksum of data
;         vals, $8C8 verification errors (harness reads all three)

        .org $1000
        LDA #0
        STA $880
        STA $8C0
        STA $8C8
        ; RX 2: items from upstream
        LDA ##$2200
        STA !$2A00
        LDA #64
        STA !$2A08
        LDA #0
        STA !$2A10
        LDA #$2A
        STA !$2A18
        RECV 2
        ; SQ 4: acks to upstream (PTT 2)
        LDA ##$FF00_0200_0000_0000
        STA !$2440
        LDA ##$2260
        STA !$2448
        LDA #8
        STA !$2450
        LDA #2
        STA !$2458
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY
        AND #$FF
        CMP #3
        BNE wait            ; our ack sends' transport acks: ignore
        TYA
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        AND #$FF
        CMP #0
        BNE wait            ; rejected: nothing landed
        CPX #$2A
        BNE wait
        LDA !$2200          ; inbound seq
        CMP $880
        BEQ fresh
        ; duplicate of a consumed item: our ack was lost — re-ack it
        STA !$2260
        SEND 4
        RECV 2
        BRA wait
fresh:  CMP !$2600
        BCS accept          ; the DONE item: no data to verify
        ; verify val == (seq+1)·2^n − 1
        CLC
        LDA !$2200
        ADC #1
        LDX !$2608
        BEQ vdone
vloop:  ASL
        DEX
        BNE vloop
vdone:  SEC
        SBC #1
        CMP !$2208
        BEQ vok
        INC $8C8            ; a corrupted transform would show here
vok:    CLC
        LDA $8C0
        ADC !$2208
        STA $8C0            ; checksum += val
accept: LDA !$2200
        STA !$2260
        SEND 4              ; ack it
        INC $880
        RECV 2
        BRA wait            ; and serve forever
