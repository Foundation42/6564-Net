; mem_churn.asm — one actor walks a big stripe of core RAM, unpredictably.
;
; The cache experiment (see measurements.md): visit every line of the
; stripe once per sweep in Galois-LFSR order — a maximal-period shuffle
; the host's prefetchers cannot predict. The first draft strode +64
; linearly and measured nothing: a linear walk is a prefetcher's
; breakfast, and L3 capacity never got a vote. Every visited cell ends
; up holding exactly `sweeps` (line 0 is the LFSR's fixed point and
; stays zero) — that is the verification.
;
; Harness contract:
;   near $840 = stripe base       $848 = LFSR polynomial (taps for n =
;   log2(lines); two-tap maximal, so lines must be 2^15/17/18/20)
;   $868 = lines - 1 (touches per sweep = the LFSR's period)
;   spawn arg (A) = sweeps        line = 64 bytes

        .org $1000
        STA $850            ; sweeps remaining
sweep:  LDA #1
        STA $858            ; idx = 1 (any nonzero seed)
        LDA $868
        STA $870            ; touches remaining this sweep
line:   LDA $858            ; addr = base + idx * 64
        ASL #6
        CLC
        ADC $840
        STA $860
        LDA ($860)
        INC                 ; read-modify-write: the honest kind of touch
        STA ($860)
        LDA $858            ; idx = lfsr(idx): shift right, xor taps on carry
        LSR
        BCC nox
        EOR $848
nox:    STA $858
        DEC $870
        BNE line
        DEC $850
        BNE sweep
        HLT
