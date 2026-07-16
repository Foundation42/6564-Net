; pipe_source.asm — pipeline head: generate K data items (val = seq) plus a
; final DONE item (seq = K), stop-and-wait per item on application-level
; acks from the next hop, retransmitting from the fabric-as-clock timer
; (spec §6.3). Transport acks are ignored — only the downstream ack counts.
; Halts once DONE itself is acked.
;
; Harness contract:
;   PTT 0 → downstream item ring    PTT 1 → black hole (timer)
;   desc slots: 0 item SQ, 1 CQ, 3 ack RX (buf $2240, cookie $4C)
;   RAM: $2600 = K
;   near: $880 K+1, $888 next_seq, $890 fwd_busy, $898 fwd_seq,
;         $818 retransmissions (harness reads)

        .org $1000
        LDA !$2600
        INC                 ; K data items + the DONE item (seq = K)
        STA $880
        LDA #0
        STA $888            ; next seq to send
        STA $890            ; nothing in flight
        LDA ##$FF00_0100_0000_0000
        STA $838            ; timer pointer
        ; stage the ack landing entry (RX ring 3, cap 1)
        LDA ##$2240
        STA !$2A40
        LDA #64
        STA !$2A48
        LDA #0
        STA !$2A50
        LDA #$4C
        STA !$2A58
        RECV 3
        ; stage the item transmit descriptor (SQ 0 → PTT 0)
        LDA ##$FF00_0000_0000_0000
        STA !$2400
        LDA ##$2280
        STA !$2408
        LDA #16
        STA !$2410          ; items are {seq, val}: 16 bytes
        LDA #1
        STA !$2418
        LDA #0
        TXR ($838),A        ; arm the timer chain
main:   LDA $890
        BNE wait            ; an item is in flight: wait for its ack
        LDA $888
        CMP $880
        BNE fill
        HLT                 ; every item acked, DONE included
fill:   LDA $888
        STA !$2280          ; seq
        STA !$2288          ; val = seq (the stages transform it)
        STA $898
        INC $888
        LDA #1
        STA $890
        SEND 0
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY                 ; completion word0 → Y
        AND #$FF
        CMP #1
        BEQ timer
        CMP #3
        BEQ del
        BRA wait            ; transport acks: end-to-end only, ignore
timer:  LDA #0
        TXR ($838),A        ; re-arm the chain
        LDA $890
        BEQ main            ; idle: maybe there's a next item to fill
        INC $818            ; count a retransmission
        SEND 0
        BRA wait
del:    TYA                 ; a delivery: clean, and on the ack ring?
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
        BNE wait            ; rejected: nothing landed, nothing to repost
        CPX #$4C
        BNE wait
        LDA !$2240          ; acked seq
        CMP $898
        BNE redo            ; stale duplicate ack: ignore
        LDA #0
        STA $890            ; item delivered downstream: slot free
redo:   RECV 3
        BRA main
