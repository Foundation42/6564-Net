; fanin_sink.asm — the Big Brother: the single target of a massive fan-in.
; Count and checksum every landed delivery; halt when the expected total
; arrives. Used by both capstone stress tests (the flood target, and the
; fork-join aggregator).
;
; The entire program is one CQPOP loop over a deep AUTO_REPOST ring — this
; is the workload that ring flag was built for: the pop is the only
; bookkeeping, and absorption rate is pop rate.
;
; The contract, as directives: a deep CQ, and the cap-256 AUTO_REPOST RX
; with 256 loader-posted landing entries (cookie = buffer address) and the
; tail pre-granted — this program never issues RECV. The expected total is
; staged at $2600; count and checksum read back from near $860/$868. One
; deviation from the demo harness: its CQ held 512 records, and `.ring
; cap` stops at 256 — harmless here, because a sink that never sends has
; at most one unpopped record per landing buffer, so the moment a 256-CQ
; fills the RX ring is already empty and admission rejects identically.
;
; The .system block is the flood. The sink is declared first: it takes
; core 0 alone (the demo's placement) and its readbacks lead the report.
; Spawn order is pure pre-run staging — the rings are the loader's work,
; so deliveries can land before their owner has ever run.

        .actor FanInSink(expected arg @ $2600)
        .ring 1 cq cap=256
        .ring 2 rx cap=256 auto_repost post=256 size=8 grant
        .var count $860
        .var checksum $868
        .use "flood_sender.asm"

        .system
        sink = FanInSink(10000)
        senders = FloodSender[10000](sink, index)
        .endsystem

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
