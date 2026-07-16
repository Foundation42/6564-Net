; supervisor.asm — a one-for-one supervisor (context 0).
;
; Children are linked to our CQ by the harness (exit links, spec §5): when a
; child halts or faults, hardware posts an exit completion — tag=exit(4),
; status ok(0)|fault(5), cookie = child context id. That completion record is
; the only obituary there is, and it's all a supervisor needs.
;
; Policy: clean exit → child is done, let it rest. Fault → restart it via
; SPWN, spending from a shared restart budget; when the budget is gone, a
; crashing child is abandoned (counts as departed). When every child has
; departed, we halt.
;
; Harness contract (near page, pre-staged by the loader):
;   $860 children alive count      $868 restart budget
;   $900 + 32*ctx: spawn block for child ctx {ctx, entry, sp, arg}
;   desc slot 1: our CQ            !$2780 restart counter (RAM, we report)

        .org $1000
loop:   LSTN 1
        CQPOP 1
        BEQ loop
        TAY                 ; word0 → Y (X holds the child id cookie)
        AND #$FF
        CMP #4              ; exit notification?
        BNE loop            ; anything else is not our business
        TYA                 ; status = (word0 >> 8) & $FF
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        AND #$FF
        CMP #5              ; fault?
        BEQ crashed
gone:   DEC $860            ; a child has departed (clean, or abandoned)
        BNE loop
        HLT                 ; all children accounted for: our work is done
crashed:
        LDA $868
        BEQ gone            ; restart budget exhausted: abandon it
        DEC $868
        INC !$2780          ; count the restart, visibly
        TXA                 ; X = cookie = child context id
        ASL
        ASL
        ASL
        ASL
        ASL                 ; ×32: stride into the spawn-block table
        TAX
        SPWN $900,X         ; rise again, little actor
        BRA loop
