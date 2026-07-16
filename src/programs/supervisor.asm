; supervisor.asm — a one-for-one supervisor (context 0).
;
; Children are linked to our CQ by the harness (exit links, spec §5.4): when
; a child halts or faults — including a watchdog fault for a compute-hang —
; hardware posts an exit completion: tag=exit(4), status ok(0)|fault(5),
; cookie = child context id. That completion record is the only obituary
; there is, and it's all a supervisor needs.
;
; Policy: clean exit → child is done, let it rest. Fault → restart it via
; SPWN, spending from that child's own restart budget; when a child's budget
; is gone, it is abandoned (counts as departed). When every child has
; departed, we halt.
;
; Harness contract (near page, pre-staged by the loader):
;   $860 children alive count
;   $900 + 32*ctx: spawn block for child ctx {ctx, entry, sp, arg}
;   $A00 + 8*ctx:  per-child restart budget
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
        TXA                 ; X = cookie = child context id
        ASL
        ASL
        ASL                 ; ×8: stride into the budget table
        TAX
        LDA $A00,X          ; this child's remaining restart budget
        BEQ gone            ; spent: abandon it
        SEC
        SBC #1
        STA $A00,X
        INC !$2780          ; count the restart, visibly
        TXA                 ; A = 8 × child id
        ASL
        ASL                 ; ×32: stride into the spawn-block table
        TAX
        SPWN $900,X         ; rise again, little actor
        BRA loop
