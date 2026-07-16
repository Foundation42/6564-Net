; ring_node.asm — one node of Joe Armstrong's ring (Programming Erlang,
; chapter 12): N processes in a ring, a message passed around M times,
; N·M message passes in all.
;
; Here a "process" is a banked hardware context and the message is the
; remaining-pass counter, carried in a single-register TXR datagram — the
; cheapest message the ISA has. Receive, decrement, forward; whoever
; decrements to zero has completed pass N·M and halts. On-die delivery is
; reliable (§3.2), so there is no retransmission protocol: this is the bare
; cost of actor-to-actor messaging.
;
; The receive ring is AUTO_REPOST (capacity 2): hardware re-enqueues the
; landing buffer as we pop the delivery, so the loop never issues RECV. The
; completion cookie is the landing buffer's address — where THIS message
; landed.
;
; Harness contract (per node):
;   near $840 = window pointer to the next node's ring (own PTT slot)
;   desc slots: 1 CQ, 2 RX (cap 2, AUTO_REPOST, entries staged by harness,
;   cookie = buffer address)
;   spawn arg (A): N·M for the injecting node, 0 for everyone else
;   near $850 = finisher flag (set by whoever completes the final pass)

        .org $1000
        RECV 2              ; grant landing space before anything moves…
        RECV 2              ; …both buffers; AUTO_REPOST sustains them
        CMP #0
        BEQ serve           ; not the injector
        TXR ($840),A        ; light the fuse: pass 1 departs
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        TAY
        AND #$FF
        CMP #3
        BNE serve           ; our own TXR's transport ack: ignore
        TYA
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
        BNE serve           ; rejected: nothing landed
        STX $848            ; cookie = where the counter landed
        LDA ($848)
        DEC
        BEQ fin             ; that was pass N·M
        TXR ($840),A        ; pass it on
        BRA serve
fin:    INC $850            ; for the harness: the ring ended here
        HLT
