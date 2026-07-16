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
        LDA ##$FF00_0000_0000_0000
        STA $838            ; timer pointer (PTT 0)
        ; task SQE constants; dst is rewritten per scatter
        LDA ##$2280
        STA !$2408
        LDA #16
        STA !$2410
        LDA #1
        STA !$2418
        ; post all result landing buffers (entries pre-staged in RAM)
        LDX $8A8
rposts: RECV 2
        DEX
        BNE rposts
        LDA #0
        TXR ($838),A        ; arm the timer chain
        JSR scatter         ; initial fan-out
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
timer:  LDA #0
        TXR ($838),A        ; re-arm
        JSR scatter         ; nudge whoever hasn't answered
        BRA wait
del:    TYA                 ; a delivery: clean?
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        LSR
        AND #$FF
        CMP #0
        BNE wait            ; rejected: nothing landed
        STX $8E0            ; cookie = the landing buffer's address
        LDA ($8E0)          ; word0: worker id
        ASL
        ASL
        ASL
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
dup:    RECV 2              ; repost this landing slot
        LDA $8C8
        CMP $8A8
        BNE wait
        HLT                 ; gathered all W: done (timer chain dies with us)

; Send the task to every worker whose done flag is still clear.
scatter:
        LDX #8              ; worker 1 → table offset 8
sloop:  LDA $900,X
        BNE snext           ; already answered
        LDA $A00,X
        STA !$2400          ; SQE dst = this worker's window pointer
        TXA
        LSR
        LSR
        LSR
        STA !$2280          ; task word0: worker id
        LDA $B00,X
        STA !$2288          ; task word1: the value to square
        SEND 0
        INC $8D0
snext:  TXA
        CLC
        ADC #8
        TAX
        CPX $8B0
        BNE sloop
        RTS
