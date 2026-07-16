; pipe_stage.asm — a pipeline transform stage: receive {seq, val} from
; upstream, compute val*2 + 1, forward downstream. Every hop is stop-and-wait
; on application acks, retransmitting from the fabric-as-clock timer.
;
; The flow-control seam: we ack upstream the moment we take *ownership* of an
; item (copy into the HOLD slot) — not when it reaches the sink — so hops
; overlap and the pipeline actually pipelines. If HOLD is still full when the
; next item lands, we drop it WITHOUT acking: upstream's timer will offer it
; again. That silence is the backpressure; there is no credit protocol.
;
; Shutdown: the DONE item (seq = K) flows through like any other. But a stage
; must NOT halt when its DONE is acked — its own ack upstream may have been
; lost, and a halted stage would leave upstream retransmitting at a corpse
; (two-generals, cascading hop by hop). Instead we go lame duck: keep serving
; re-acks (parked, costing nothing) but stop re-arming the timer chain, so
; our clock dies and the machine can quiesce around us, exactly like the
; immortal sink.
;
; Harness contract:
;   PTT 0 → downstream item ring    PTT 1 → black hole (timer)
;   PTT 2 → upstream ack ring
;   desc slots: 0 item SQ, 1 CQ, 2 item RX (buf $2200, cookie $2A),
;               3 ack RX (buf $2240, cookie $4C), 4 ack SQ
;   RAM: $2600 = K
;   near: $880 E (next expected seq), $888 hold_full, $890 hold_val,
;         $898 hold_seq, $8A0 fwd_busy, $8D0 retransmissions (harness reads),
;         $8B8 phase: 0 working, 1 DONE in flight, 2 lame duck (harness reads)

        .org $1000
        LDA #0
        STA $880
        STA $888
        STA $8A0
        STA $8B8
        LDA ##$FF00_0100_0000_0000
        STA $838            ; timer pointer
        ; RX 2: items from upstream
        LDA ##$2200
        STA !$2A00
        LDA #64
        STA !$2A08
        LDA #0
        STA !$2A10
        LDA #$2A
        STA !$2A18
        RECV 2
        ; RX 3: acks from downstream
        LDA ##$2240
        STA !$2A40
        LDA #64
        STA !$2A48
        LDA #0
        STA !$2A50
        LDA #$4C
        STA !$2A58
        RECV 3
        ; SQ 0: items to downstream (PTT 0)
        LDA ##$FF00_0000_0000_0000
        STA !$2400
        LDA ##$2280
        STA !$2408
        LDA #16
        STA !$2410
        LDA #1
        STA !$2418
        ; SQ 4: acks to upstream (PTT 2)
        LDA ##$FF00_0200_0000_0000
        STA !$2440
        LDA ##$2260
        STA !$2448
        LDA #8
        STA !$2450
        LDA #2
        STA !$2458
        LDA #0
        TXR ($838),A        ; arm the timer chain
main:   LDA $8A0
        BNE wait            ; a forward is in flight
        LDA $888
        BEQ wait            ; nothing held
        ; HOLD → forward, transformed: val = val*2 + 1
        LDA $898
        STA !$2280          ; out seq
        LDA $890
        ASL
        CLC
        ADC #1
        STA !$2288          ; out val
        LDA #0
        STA $888            ; HOLD is free again
        LDA #1
        STA $8A0
        SEND 0
        LDA !$2280          ; was that the DONE item?
        CMP !$2600
        BNE wait
        LDA #1
        STA $8B8
        BRA wait
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
timer:  LDA $8B8
        CMP #2
        BEQ wait            ; lame duck: let the chain die
        LDA #0
        TXR ($838),A        ; re-arm
        LDA $8A0
        BEQ wait
        INC $8D0            ; count a retransmission
        SEND 0
        BRA wait
del:    TYA                 ; clean delivery? which ring?
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
        CPX #$2A
        BEQ item
        CPX #$4C
        BEQ ack
        BRA wait
ack:    LDA !$2240          ; downstream acked which seq?
        CMP !$2280
        BNE ackrp           ; stale duplicate ack
        LDA #0
        STA $8A0            ; forward complete
        LDA $8B8
        BEQ ackrp
        LDA #2
        STA $8B8            ; DONE has moved on: go lame duck
ackrp:  RECV 3
        BRA main
item:   LDA !$2200          ; inbound seq
        CMP $880
        BEQ fresh
        ; a duplicate of something we already own: our ack was lost — re-ack
        STA !$2260
        SEND 4
        RECV 2
        BRA wait
fresh:  LDA $888
        BEQ take
        RECV 2              ; HOLD full: drop silently — backpressure
        BRA wait
take:   LDA !$2200
        STA $898            ; own it
        STA !$2260
        LDA !$2208
        STA $890
        LDA #1
        STA $888
        SEND 4              ; ack upstream: your slot is free
        INC $880            ; expect the next
        RECV 2
        BRA main
