; worker.asm — a supervised worker actor.
;
; On entry A holds the address of this worker's config block in RAM (the
; spawn-block arg, so it survives restarts):
;   word0  progress cell address (RAM; accumulates across incarnations)
;   word1  crash fuse: BRK after this many items (0 = reliable)
;   word2  quota: items to produce before a clean HLT
;   word3  hang fuse: after this many items, spin without yielding (0 = never)
;
; The work loop YLDs after every item — cooperative scheduling, so siblings
; share the core. A worker whose crash fuse burns down BRKs mid-shift; one
; whose hang fuse burns down stops yielding entirely, and only the watchdog
; (spec §5.4) can pry the core back. Either way, hardware posts the exit
; notification and the supervisor decides its fate.

        .org $1200
        STA $830            ; config pointer
        LDY #0
        LDA ($830),Y
        STA $838            ; progress cell address
        LDY #8
        LDA ($830),Y
        STA $840            ; crash fuse (0 = reliable)
        LDY #16
        LDA ($830),Y
        STA $848            ; quota
        LDY #24
        LDA ($830),Y
        STA $850            ; hang fuse (0 = never)
work:   LDA ($838)          ; produce one item: progress += 1
        INC
        STA ($838)
        YLD                 ; share the core with our siblings
        LDA $840
        BEQ nocrash         ; no crash fuse: skip
        DEC $840
        BNE nocrash
        BRK                 ; the crash fuse burns out mid-shift
nocrash:
        LDA $850
        BEQ steady          ; no hang fuse: skip
        DEC $850
        BNE steady
spin:   BRA spin            ; compute-hang: no YLD, no mercy — watchdog's job
steady: DEC $848
        BNE work
        HLT                 ; quota met: clock out clean
