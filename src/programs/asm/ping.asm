; ping.asm — the demanding half of the ping-pong demo.
;
; A full end-to-end protocol: ignores transport acks entirely, retransmits on
; a timer, and accepts only the echo whose sequence it expects. The ISA has
; no timer — so ping builds one from the fabric's honesty: a TXR to an
; unroutable prefix (PTT slot 1, the black hole) is a guaranteed timeout
; completion, send_timeout cycles later. The fabric is the clock (spec §6.3).
;
; Harness contract:
;   PTT 0 → peer's RX ring        PTT 1 → black hole (timer)
;   desc slots: 0 SQ, 1 CQ, 2 RX (rings wired by harness)
;   $2600 rounds (staged by harness)   $2280 final value (we report)
;   $2500 message buffer               $2200 landing buffer

        .org $1000
        LDA !$2600          ; rounds
        STA $810
        ; stage both RX landing entries (cap-2 AUTO_REPOST ring;
        ; cookie = buffer address, so we know where each echo landed)
        LDA ##$2200
        STA !$2100
        STA !$2118
        LDA #64
        STA !$2108
        LDA #0
        STA !$2110
        LDA ##$2240
        STA !$2120
        STA !$2138
        LDA #64
        STA !$2128
        LDA #0
        STA !$2130
        RECV 2
        RECV 2
        ; stage the transmit entry (SQE: op / target / buf / len+cookie)
        LDA #1
        STA !$2400          ; word0: op = send
        LDA ##$FF00_0000_0000_0000
        STA !$2408          ; word1: target (window, PTT slot 0)
        LDA ##$2500
        STA !$2410          ; word2: buffer
        LDA ##$1_0000_0008
        STA !$2418          ; word3: len 8 | cookie 1
        LDA #0
        STA !$2500          ; first message value
        ; the eternal timer (SQ 5 → black hole, AUTO_REARM: each timeout
        ; resubmits the entry — stage once, tick forever, disarm by
        ; clearing the flag byte)
        LDA ##$202
        STA !$2480          ; op = txr | flags = AUTO_REARM
        LDA ##$FF00_0100_0000_0000
        STA !$2488          ; target: the black hole (PTT 1)
        LDA #0
        STA !$2490          ; tick payload
        LDA ##$77_0000_0000
        STA !$2498          ; cookie $77
        SEND 5              ; arm the chain
send:   SEND 0
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY                 ; completion word0 → Y
        AND #$FF
        CMP #1
        BEQ timer           ; our timer came back (tag=txr)
        CMP #3
        BEQ got
        BRA wait            ; transport acks: end-to-end only, ignore
timer:  INC $818            ; count a retransmission
        BRA send            ; resend; AUTO_REARM keeps the clock ticking
got:    TYA                 ; a delivery completion: clean?
        LSR #8
        AND #$FF
        CMP #0
        BNE wait            ; rejected inbound (dup noise): keep waiting
        STX $8E0            ; cookie = where this echo landed
        LDA !$2500          ; sequence check: the only echo we accept
        INC                 ; is (value we sent) + 1 — stale duplicates
        STA $828            ; of earlier echoes are ignored (AUTO_REPOST
        LDA ($8E0)          ; already re-armed their buffers)
        CMP $828
        BNE wait
        STA !$2500          ; the echo becomes the next message
        DEC $810
        BNE send
        LDA ($8E0)
        STA !$2280          ; final value, for the harness
        LDA #2
        STA !$2480          ; disarm the timer: clear AUTO_REARM
        HLT
