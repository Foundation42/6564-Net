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
; The contract, as directives. The demo harness pre-staged each context's
; submission entry by hand; a replicated actor cannot pin ring storage,
; so — like flood_sender before it — the prologue stages its own: the SQ
; base comes from descriptor word0 at near $000 (architecturally visible
; state), the target from the $830 cell the loader fills, and the entry
; is built through pointers, leaving $840 aimed at its value word for the
; serve loop. `next cap[] @ $830` pairs equal groups member for member —
; worker j gets relay j — and a singleton referent (the aggregator) is a
; shared one-member group, so one actor names both partners. The delta
; arrives in two staged pieces, group base + replica index, because a
; worker's global number g = base + index is per-replica data the system
; block can only spell that way; the prologue adds them once.

        .actor Pass(next cap[] @ $830, delta arg @ $850, base arg @ $860)
        .ring 0 sq cap=1
        .ring 1 cq cap=4
        .ring 2 rx cap=1 post=1 size=8 grant

        .org $1200
        LDA $850
        CLC
        ADC $860            ; delta += the group's base
        STA $850
        LDA $000            ; SQ descriptor word0: the loader-chosen base
        STA $8E0            ; &word0
        CLC
        ADC #8
        STA $8E8            ; &word1
        ADC #8
        STA $840            ; &word2: the value word the loop fills
        LDA #2
        STA ($8E0)          ; op = txr
        LDA $830
        STA ($8E8)          ; target = our partner's window
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
        LSR #8
        AND #$FF
        CMP #0
        BEQ fin             ; passed on: our part is done
        SEND 0              ; rejected or timed out: offer it again
        BRA serve
got:    TYA
        LSR #8
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
