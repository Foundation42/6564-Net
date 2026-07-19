; flood_sender.asm — one of ten thousand: send a single 8-byte message
; (our id, replica index + 1, arriving in A) at Big Brother's ring and
; keep trying until the fabric says it landed.
;
; Retry discipline matters at this scale: a timeout means the send died in
; flight — retry immediately. A no_buffer reject means the target is FULL —
; that silence-shaped backpressure again — so back off one timer period
; (a one-shot TXR into the black hole) before offering it again. Ten
; thousand of us hammering instantly on every reject would be a livelock
; machine.
;
; The contract, as directives: Big Brother's window pointer staged at near
; $830 (two hundred of us share a core, and — deduplicated — one PTT
; slot), the black-hole backoff timer's window pointer at $838, and a
; one-entry SQ with a four-record CQ, storage the loader's choice. The
; demo harness pre-staged each sender's SQE by hand; a replicated actor
; cannot pin ring storage, so the prologue stages its own — the SQ
; descriptor sits in the near page (slot 0 at $000) and its word0 is the
; base the loader chose. Four stores through that pointer and every
; retry is the same doorbell.

        .actor FloodSender(bigbrother cap @ $830, id arg @ A)
        .ring 0 sq cap=1
        .ring 1 cq cap=4
        .timer @ $838 period=2500

        .org $1000
        INC                 ; spawn arg is our replica index: id = index+1
        STA $840            ; the payload cell: our voice (near, per-context)
        LDA $000            ; SQ descriptor word0: the base the loader chose
        STA $8E0            ; → &SQE word0
        CLC
        ADC #8
        STA $8E8            ; &word1
        ADC #8
        STA $8F0            ; &word2
        ADC #8
        STA $8F8            ; &word3
        LDA #1
        STA ($8E0)          ; op = send
        LDA $830            ; Big Brother's window pointer
        STA ($8E8)          ; target
        LDA ##$840
        STA ($8F0)          ; buf = the payload cell
        LDA #8
        STA ($8F8)          ; len 8
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
        LSR #8
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
