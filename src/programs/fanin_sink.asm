; fanin_sink.asm — the Big Brother: the single target of a massive fan-in.
; Count and checksum every landed delivery; halt when the expected total
; arrives. Used by both capstone stress tests (the flood target, and the
; fork-join aggregator).
;
; The entire program is one CQPOP loop over a deep AUTO_REPOST ring — this
; is the workload that ring flag was built for: the pop is the only
; bookkeeping, and absorption rate is pop rate.
;
; Harness contract:
;   desc slots: 1 CQ (deep), 2 RX (cap 256, AUTO_REPOST, entries staged by
;   the loader with cookie = cell address, tail pre-granted)
;   RAM $2600 = expected message count
;   near: $860 count, $868 checksum (harness reads both)

        .org $1000
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        TAY
        AND #$FF
        CMP #3
        BNE serve           ; only deliveries matter here
        TYA
        LSR #8
        AND #$FF
        CMP #0
        BNE serve           ; rejected: nothing landed
        STX $8E0            ; cookie = where it landed
        INC $860
        CLC
        LDA ($8E0)
        ADC $868
        STA $868            ; checksum += payload
        LDA $860
        CMP !$2600
        BNE serve
        HLT                 ; every voice heard
