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
; The contract, as directives: each `sup` param is a child — its spawn
; block {ctx, entry, sp, arg} lands at $900+32·ctx where the SPWN below
; expects it, its exit link aims at our CQ, and its 500-cycle leash is
; ours to set (spec §5.4). The rest is policy as data: the alive count
; at $860, per-child restart budgets at $A00+8·ctx (the crasher gets 3
; lives, the hanger 2, the reliable none — they won't need any), and
; the config blocks the workers read through their spawn argument.
; Progress cells and the restart counter read back into the report.
;
; The .system block is one core: supervisor as context 0, four workers
; declared in order so their ctx ids follow — and since spawn is
; reverse declaration order, the supervisor starts last, when every
; worker is already at work.

        .actor Supervisor(k1 sup @ $920 watchdog=500, k2 sup @ $940 watchdog=500, k3 sup @ $960 watchdog=500, k4 sup @ $980 watchdog=500)
        .ring 1 cq cap=16
        .stage $860 4
        .stage $A08 0, 3, 0, 2
        .stage $2820 $2708, 0, 12, 0
        .stage $2840 $2710, 5, 12, 0
        .stage $2860 $2718, 0, 12, 0
        .stage $2880 $2720, 0, 12, 3
        .reserve $2700 $100
        .var restarts $2780
        .var p1 $2708
        .var p2 $2710
        .var p3 $2718
        .var p4 $2720
        .use "worker.asm"

        .system
        sup = Supervisor(w1, w2, w3, w4) on 0
        w1 = Worker($2820) on 0
        w2 = Worker($2840) on 0
        w3 = Worker($2860) on 0
        w4 = Worker($2880) on 0
        .endsystem

        .org $1000
loop:   LSTN 1
        CQPOP 1
        BEQ loop
        TAY                 ; word0 → Y (X holds the child id cookie)
        AND #$FF
        CMP #4              ; exit notification?
        BNE loop            ; anything else is not our business
        TYA                 ; status = (word0 >> 8) & $FF
        LSR #8
        AND #$FF
        CMP #5              ; fault?
        BEQ crashed
gone:   DEC $860            ; a child has departed (clean, or abandoned)
        BNE loop
        HLT                 ; all children accounted for: our work is done
crashed:
        TXA                 ; X = cookie = child id | incarnation<<32
        AND ##$FF           ; keep the id; the incarnation half is for
        ASL #3        ; supervisors that track lives (we restart
        TAX
        LDA $A00,X          ; this child's remaining restart budget
        BEQ gone            ; spent: abandon it
        SEC
        SBC #1
        STA $A00,X
        INC !$2780          ; count the restart, visibly
        TXA                 ; A = 8 × child id
        ASL #2        ; ×32: stride into the spawn-block table
        TAX
        SPWN $900,X         ; rise again, little actor
        BRA loop
