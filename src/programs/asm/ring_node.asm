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
; The contract, as directives (per node): a capability to the next node's
; ring staged as a window pointer at near $840, a CQ, an AUTO_REPOST RX
; with two posted landing cells (cookie = buffer address), the remaining-
; pass counter in A for the injector (0 for everyone else), and the
; finisher flag at near $850 for the outcome report.
;
; The .system block is eight of us on one core, the message home at n0 —
; the same deployment ring.joe declares, in the same grammar. Larger rings
; are the harnesses' business (demo_dies runs this file across 16 dies).

        .actor RingNode(next cap @ $840, fuse arg @ A)
        .ring 1 cq cap=4
        .ring 2 rx cap=2 auto_repost post=2 size=8
        .var finisher $850

        .system
        n0 = RingNode(n1, 800) on 0
        n1 = RingNode(n2, 0) on 0
        n2 = RingNode(n3, 0) on 0
        n3 = RingNode(n4, 0) on 0
        n4 = RingNode(n5, 0) on 0
        n5 = RingNode(n6, 0) on 0
        n6 = RingNode(n7, 0) on 0
        n7 = RingNode(n0, 0) on 0
        .endsystem

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
        LSR #8
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
