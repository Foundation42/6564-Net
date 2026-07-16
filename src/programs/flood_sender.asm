; flood_sender.asm — one of ten thousand: send a single 8-byte message
; (our id, staged by the loader in our payload cell) at Big Brother's ring
; and keep trying until the fabric says it landed.
;
; Retry discipline matters at this scale: a timeout means the send died in
; flight — retry immediately. A no_buffer reject means the target is FULL —
; that silence-shaped backpressure again — so back off one timer period
; (a one-shot TXR into the black hole) before offering it again. Ten
; thousand of us hammering instantly on every reject would be a livelock
; machine.
;
; Harness contract (per sender context):
;   PTT 0 → the target's ring   PTT 1 → black hole
;   desc slots: 0 SQ (SQE staged by loader: op send, buf = our payload
;   cell, len 8), 1 CQ
;   near $838 = black-hole window pointer (backoff timer)

        .org $1000
        SEND 0              ; first attempt
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY
        AND #$FF
        CMP #1
        BEQ again           ; backoff timer expired: offer it again
        CMP #2
        BNE wait
        TYA                 ; our send resolved: how?
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
        BEQ done            ; landed: we are heard
        CMP #4
        BEQ again           ; timeout: died in flight, retry now
        LDA #0              ; rejected: the target is saturated — back off
        TXR ($838),A
        BRA wait
again:  SEND 0
        BRA wait
done:   HLT
