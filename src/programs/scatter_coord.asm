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
; Harness contract:
;   PTT 0 = black hole (timer); PTT i = worker i's task ring (i = 1..W)
;   desc slots: 0 task SQ, 1 CQ, 2 result RX (cap 8, entries staged by
;   harness: buf $2C00+64i, cookie = buf address)
;   near (staged by harness): $8A8 W, $8B0 8·(W+1) — scatter loop bound,
;     $A00+8i worker window pointers, $B00+8i task values
;   near (ours): $8C0 gathered sum, $8C8 gathered count, $8D0 scatter sends,
;     $900+8i done flags
;   RAM: $2280 task out {id, value}

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
