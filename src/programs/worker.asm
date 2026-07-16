; worker.asm — a supervised worker actor.
;
; On entry A holds the address of this worker's config block in RAM (the
; spawn-block arg, so it survives restarts):
;   word0  progress cell address (RAM; accumulates across incarnations)
;   word1  crash fuse: BRK after this many items (0 = reliable)
;   word2  quota: items to produce before a clean HLT
;
; The work loop YLDs after every item — cooperative scheduling, so siblings
; share the core. A worker whose fuse burns down BRKs mid-shift; hardware
; posts the exit notification and the supervisor decides its fate.

        .org $1200
        STA $830            ; config pointer
        LDY #0
        LDA ($830),Y
        STA $838            ; progress cell address
        LDY #8
        LDA ($830),Y
        STA $840            ; fuse (0 = reliable)
        LDY #16
        LDA ($830),Y
        STA $848            ; quota
work:   LDA ($838)          ; produce one item: progress += 1
        INC
        STA ($838)
        YLD                 ; share the core with our siblings
        LDA $840
        BEQ steady          ; no fuse: reliable worker
        DEC $840
        BNE steady
        BRK                 ; the fuse burns out mid-shift
steady: DEC $848
        BNE work
        HLT                 ; quota met: clock out clean
