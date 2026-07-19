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
        ; stage both ack landing entries (cap-2 AUTO_REPOST ring;
        ; cookie = buffer address)
        LDA ##$2240
        STA !$2A40
        STA !$2A58
        LDA #8
        STA !$2A48
        LDA #0
        STA !$2A50
        LDA ##$2248
        STA !$2A60
        STA !$2A78
        LDA #8
        STA !$2A68
        LDA #0
        STA !$2A70
        RECV 3
        RECV 3
        ; stage the item transmit entry (SQ 0 → PTT 0)
        LDA #1
        STA !$2400          ; op = send
        LDA ##$FF00_0000_0000_0000
        STA !$2408          ; target
        LDA ##$2280
        STA !$2410          ; buffer
        LDA ##$1_0000_0010
        STA !$2418          ; len 16 (items are {seq, val}) | cookie 1
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
main:   LDA $890
        BNE wait            ; an item is in flight: wait for its ack
        LDA $888
        CMP $880
        BNE fill
        LDA #2
        STA !$2480          ; disarm the timer: clear AUTO_REARM
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
timer:  LDA $890
        BEQ main            ; idle: maybe there's a next item to fill
        INC $818            ; count a retransmission
        SEND 0
        BRA wait
del:    TYA                 ; a delivery: clean, and on the ack ring?
        LSR #8
        AND #$FF
        CMP #0
        BNE wait            ; rejected: nothing landed
        STX $8E0            ; cookie = where the ack landed
        LDA ($8E0)          ; acked seq
        CMP $898
        BNE redo            ; stale duplicate ack: ignore
        LDA #0
        STA $890            ; item delivered downstream: slot free
redo:   BRA main
