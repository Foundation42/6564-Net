; fj_lieutenant.asm — middle of the fork tree: on receiving "go", fan it
; to this core's W workers. Same-core delivery is reliable (§3.2), so the
; fan is fire-and-forget: W back-to-back doorbells, rewriting the staged
; entry's target through a near-page pointer between each, then halt.
;
; Harness contract:
;   desc slots: 0 SQ (SQE: op txr, value 0), 1 CQ (deep — the fan's
;   transport acks land here after we're gone), 2 RX (one message)
;   near $848 = pointer to our SQE's target word
;   near $900+8k = window pointer to worker k (k = 1..W)
;   near $868 = 8·(W+1), the fan loop bound

        .org $1000
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        TAY
        AND #$FF
        CMP #3
        BNE serve           ; waiting for the "go"
        TYA
        LSR #8
        AND #$FF
        CMP #0
        BNE serve
        LDX #8              ; worker 1 → table offset 8
fan:    LDA $900,X
        STA ($848)          ; retarget the staged entry
        SEND 0              ; fire-and-forget: on-die is reliable
        TXA
        CLC
        ADC #8
        TAX
        CPX $868
        BNE fan
        HLT                 ; the tree is lit below us
