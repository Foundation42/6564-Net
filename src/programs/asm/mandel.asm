; mandel.asm — the Mandelbrot set, in IEEE 754 double precision, on a
; 6502 descendant, printed by a teletype that is an actor on the mesh.
;
; The 8-bit rite of passage, upgraded: where the Superboard II did this
; in interpreted BASIC with 5-digit floats, the 6564 does it with Tier 0
; scalar FP (spec extended page, prefix $42 — the byte the 65816
; reserved as WDM and never spent). Every arithmetic result here is
; bit-exact: the harness asserts entire rows against an independent
; computation, character for character. A picture as a determinism test.
;
; z ← z² + c over a 64×22 grid, x ∈ [-2, 0.5], y ∈ [-1.1, 1.1],
; escape at |z|² ≥ 4, 16 iterations max, one palette char per count.
;
; Harness contract:
;   PTT 0 → console ($FF00)   desc: 0 SQ ($2400), 1 CQ   line buf $2600
;
; Near page: $800 cx   $808 cy   $810 zx   $818 zy   $820 zx²  $828 zy²
;            $830 n    $838 bufptr $840 rows $848 tmp
;            $850 dx   $858 dy   $860 4.0  $870.. palette (17 chars)

        .org $1000
        ; constants into the near page — variables lived in zero page
        ; on the ancestor, and they still do
        LDA ##$3FA4514514514514   ; dx = 2.5/63
        STA $850
        LDA ##$3FBAD1AD1AD1AD1B   ; dy = 2.2/21
        STA $858
        LDA ##$4010000000000000   ; 4.0 — the escape circle
        STA $860
        LDA ##$2B3D7E3B3A2C2E20   ; " .,:;~=+"
        STA $870
        LDA ##$262425234F586F78   ; "xoXO#%$&"
        STA $878
        LDA ##$0000000000000040   ; "@" — the set itself
        STA $880
        ; stage the one SQE: a finished line to the console, each row
        LDA #1
        STA !$2400                ; op = send
        LDA ##$FF00_0000_0000_0000
        STA !$2408                ; target: the console, via PTT 0
        LDA ##$2600
        STA !$2410                ; the line buffer
        LDA ##$1_0000_0041        ; len 65 | cookie 1
        STA !$2418
        LDA ##$3FF199999999999A   ; cy = 1.1, the top edge
        STA $808
        LDA #22
        STA $840

rowlp:  LDA ##$C000000000000000   ; cx = -2.0, the left edge
        STA $800
        LDA ##$2600
        STA $838
        LDY #64

        ; ── one point: iterate z² + c ──
collp:  LDA #0                    ; integer zero IS +0.0 — same bits
        STA $810
        STA $818
        STA $830
itlp:   LDA $810
        FMUL $810
        STA $820                  ; zx²
        LDA $818
        FMUL $818
        STA $828                  ; zy²
        FADD $820
        FCMP $860                 ; |z|² against 4.0
        BMI keep                  ; strictly inside: keep going
        BRA esc
keep:   LDA $810
        FMUL $818
        STA $848
        FADD $848                 ; 2·zx·zy — doubling by addition, exact
        FADD $808
        STA $818                  ; zy′
        LDA $820
        FSUB $828
        FADD $800
        STA $810                  ; zx′ = zx² − zy² + cx
        INC $830
        LDA $830
        CMP #16
        BNE itlp

esc:    LDX $830
        LDA $870,X                ; palette[n]
        AND #$FF
        STA ($838)                ; low byte lands; the 8-byte tail is
                                  ; overwritten by the columns to come
        LDA $800
        FADD $850                 ; cx += dx
        STA $800
        INC $838
        DEY
        BNE collp

        LDA #10                   ; newline caps the row
        STA ($838)
        JSR sendln
        LDA $808
        FSUB $858                 ; cy −= dy
        STA $808
        DEC $840
        BNE rowlp
        HLT

; ship the line: the delivery ack is the receipt; a bad verdict means
; say it again — politeness through idempotence, hello.asm's discipline
sendln: SEND 0
swait:  LSTN 1
        CQPOP 1
        BEQ swait
        TAX
        AND #$FF
        CMP #2
        BNE swait
        TXA
        LSR #8
        AND #$FF
        BNE sendln
        RTS
