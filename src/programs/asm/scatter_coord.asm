; scatter_coord.asm — scatter-gather coordinator: fan a task out to W
; workers, gather the W results, retry stragglers from the fabric-as-clock
; timer. Request-response needs no ack protocol: the RESULT is the ack, and
; workers are idempotent, so a lost task or lost result both heal with one
; re-scatter.
;
; Fan-in: the result RX ring has capacity 8 with eight posted landing
; buffers, each staged (by the harness) with its own ADDRESS as its cookie —
; so a completion record tells us exactly where that result landed.
;
; The contract, as directives the loader executes (src/asm_run.zig): the
; black hole pinned at PTT 0 (the timer SQE below bakes its window
; constant; the period is the fabric's send_timeout) and the eight
; workers' capabilities staged as window pointers at $A00+8i — the
; loader allocates their slots above the pin, so worker i lands at
; PTT i and the staged fan-out chain can bake the same windows. The
; demo's four rings — task SQ, CQ, the timer SQ at slot 5, and the
; cap-8 AUTO_REPOST result RX with eight loader-posted landing entries
; (cookie = buffer address; the code reads results only through
; cookies, so the cells are the loader's to place). The fan-out chain
; is staged data: worker 1's SQE is the ring head at $2400, workers
; 2..8 LINK-chained near-page entries at $C20.., each carrying its own
; {id, value} payload from $2280+16(i−1). W at $8A8 and the scatter
; loop bound 8·(W+1) at $8B0 arrive as spawn args; $B00+8i are the
; task values for straggler re-sends, $2380 the straggler payload
; buffer (reserved). Gathered sum, count and the send counter are the
; readbacks the demo verifies; $900+8i are our done flags.
;
; The .system block is the demo's default shape: the coordinator on
; core 0, eight workers on cores 1..8 — singletons, because a worker
; pins its ring storage and each must own a core. The coordinator is
; declared first: spawn is reverse declaration, so every worker is
; parked listening before the fan-out chain fires.

        .actor Coord(w1 cap @ $A08, w2 cap @ $A10, w3 cap @ $A18, w4 cap @ $A20, w5 cap @ $A28, w6 cap @ $A30, w7 cap @ $A38, w8 cap @ $A40, w arg @ $8A8, bound arg @ $8B0)
        .ring 0 sq base=$2400 cap=1
        .ring 1 cq base=$2000 cap=32
        .ring 2 rx base=$2A00 cap=8 auto_repost post=8 size=64
        .ring 5 sq base=$2480 cap=1
        .timer = 0 period=2500
        .reserve $2380 $10
        ; the task payloads {id, value}, value = id + 3
        .stage $2280 1, 4, 2, 5, 3, 6, 4, 7, 5, 8, 6, 9, 7, 10, 8, 11
        ; the straggler task-value table at $B00+8i
        .stage $B08 4, 5, 6, 7, 8, 9, 10, 11
        ; the fan-out chain: head SQE in the ring, the rest LINK-chained
        ; near-page entries (word0 = op send | LINK | next<<16)
        .stage $2400 $0C20_0101, $FF00_0100_0000_0000, $2280, $1_0000_0010
        .stage $C20 $0C40_0101, $FF00_0200_0000_0000, $2290, $2_0000_0010
        .stage $C40 $0C60_0101, $FF00_0300_0000_0000, $22A0, $3_0000_0010
        .stage $C60 $0C80_0101, $FF00_0400_0000_0000, $22B0, $4_0000_0010
        .stage $C80 $0CA0_0101, $FF00_0500_0000_0000, $22C0, $5_0000_0010
        .stage $CA0 $0CC0_0101, $FF00_0600_0000_0000, $22D0, $6_0000_0010
        .stage $CC0 $0CE0_0101, $FF00_0700_0000_0000, $22E0, $7_0000_0010
        .stage $CE0 $0000_0001, $FF00_0800_0000_0000, $22F0, $8_0000_0010
        .var sum $8C0
        .var gathered $8C8
        .var scatter_sends $8D0
        .use "scatter_worker.asm"

        .system
        c = Coord(w1, w2, w3, w4, w5, w6, w7, w8, 8, 72) on 0
        w1 = Worker(c) on 1
        w2 = Worker(c) on 2
        w3 = Worker(c) on 3
        w4 = Worker(c) on 4
        w5 = Worker(c) on 5
        w6 = Worker(c) on 6
        w7 = Worker(c) on 7
        w8 = Worker(c) on 8
        .endsystem

        .org $1000
        ; post all result landing buffers (entries pre-staged in RAM)
        LDX $8A8
rposts: RECV 2
        DEX
        BNE rposts
        ; the eternal timer (SQ 5 → black hole PTT 0, AUTO_REARM)
        LDA ##$202
        STA !$2480          ; op = txr | flags = AUTO_REARM
        LDA ##$FF00_0000_0000_0000
        STA !$2488          ; target: the black hole (PTT 0)
        LDA #0
        STA !$2490          ; tick payload
        LDA ##$77_0000_0000
        STA !$2498          ; cookie $77
        SEND 5              ; arm the chain
        SEND 0              ; initial fan-out: the whole task chain, one
                            ; doorbell — LINK fires worker j+1's entry when
                            ; worker j's copy resolves ok; a lost task
                            ; breaks the chain loudly (chain_cancelled) and
                            ; the timer re-scatters the stragglers
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY                 ; completion word0 → Y
        AND #$FF
        CMP #1
        BEQ timer
        CMP #3
        BEQ del
        BRA wait            ; transport acks: ignore
timer:  JSR scatter         ; nudge whoever hasn't answered
        BRA wait
del:    TYA                 ; a delivery: clean?
        LSR #8
        AND #$FF
        CMP #0
        BNE wait            ; rejected: nothing landed
        STX $8E0            ; cookie = the landing buffer's address
        LDA ($8E0)          ; word0: worker id
        ASL #3
        TAX                 ; X = id·8
        LDA $900,X
        BNE dup             ; already gathered: a stale duplicate
        LDA #1
        STA $900,X
        LDY #8
        LDA ($8E0),Y        ; word1: the computed result
        CLC
        ADC $8C0
        STA $8C0            ; sum += result
        INC $8C8
dup:    LDA $8C8            ; (AUTO_REPOST already re-armed the slot)
        CMP $8A8
        BNE wait
        LDA #2
        STA !$2480          ; disarm the timer: clear AUTO_REARM
        HLT                 ; gathered all W: done

; Send the task to every worker whose done flag is still clear.
scatter:
        LDA #1
        STA !$2400          ; plain send: the fan-out chain is spent
        LDA ##$2380
        STA !$2410          ; stragglers use their own payload buffer
        LDX #8              ; worker 1 → table offset 8
sloop:  LDA $900,X
        BNE snext           ; already answered
        LDA $A00,X
        STA !$2408          ; SQE target = this worker's window pointer
        TXA
        LSR #3
        STA !$2380          ; task word0: worker id
        LDA $B00,X
        STA !$2388          ; task word1: the value to square
        SEND 0
        INC $8D0
snext:  TXA
        CLC
        ADC #8
        TAX
        CPX $8B0
        BNE sloop
        RTS
