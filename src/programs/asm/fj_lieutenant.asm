; fj_lieutenant.asm — middle of the fork tree: on receiving "go", fan it
; to this core's W workers. Same-core delivery is reliable (§3.2), so the
; fan is fire-and-forget: W back-to-back doorbells, rewriting the staged
; entry's target through a near-page pointer between each, then halt.
;
; The contract, as directives: the 125 worker windows land at $908..$CE8
; by cap[] — a singleton takes its whole member group. Because the
; lieutenant is declared (and so staged) before its workers wire their
; own capabilities, the loader's slots for the workers start at 0, and
; the staged fan SQE's initial target below is worker one's window,
; slot 0. It hardly matters: the serve loop rewrites the target through
; the $848 pointer before every doorbell. The SQ is pinned at $6000 so
; that pointer and the staged entry can be spelled here; the fan loop
; bound 8·(W+1) = 1008 arrives at $868 as an instance argument — the
; shape lives in the .system block, not in this code. The deep CQ
; absorbs 125 transport acks after we are gone; the one-message RX is
; granted by the loader, cookie = buffer, though only the arrival
; matters to us, never the payload.

        .actor Lieutenant(workers cap[] @ $908, bound arg @ $868)
        .ring 0 sq base=$6000 cap=1
        .ring 1 cq cap=256
        .ring 2 rx cap=1 post=1 size=8 grant
        ; the retargetable on-die fan entry (op txr, value 0), and the
        ; near pointer to its target word
        .stage $6000 2, $FF00_0000_0000_0000, 0, 0
        .stage $848 $6008

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
