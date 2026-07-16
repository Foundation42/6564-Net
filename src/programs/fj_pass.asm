; fj_pass.asm — one program, two roles in the fork-join matrix. Receive a
; value, add our delta, pass it on through our staged entry, retry until
; the fabric confirms, halt.
;
;   worker: delta = our global index g, inbound value 0 → we send g
;           (to our partner relay, same core: reliable, but the retry loop
;           costs nothing when the first attempt lands)
;   relay:  delta = 1, inbound value g → we send g+1
;           (cross-core to the aggregator: the 1,000-way fan-in, where
;           no_buffer rejects are real and the retry loop earns its keep)
;
; Harness contract (per context):
;   desc slots: 0 SQ (SQE: op txr, target staged), 1 CQ, 2 RX (one message)
;   near $840 = pointer to our SQE's value word
;   near $850 = our delta

        .org $1200
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        TAY
        AND #$FF
        CMP #3
        BEQ got
        CMP #1
        BNE serve           ; (nothing else visits this CQ)
        TYA                 ; our pass resolved: how?
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
        BEQ fin             ; passed on: our part is done
        SEND 0              ; rejected or timed out: offer it again
        BRA serve
got:    TYA
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
        BNE serve
        STX $8E0            ; cookie = where the value landed
        CLC
        LDA ($8E0)
        ADC $850            ; + our delta
        STA ($840)          ; into our staged entry's value word
        SEND 0
        BRA serve
fin:    HLT
