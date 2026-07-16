; pong.asm — the echo server: receive a value, add one, send it back.
; Serves forever; the machine quiesces around it when ping finishes.
;
; The receive ring is AUTO_REPOST (capacity 2): hardware re-enqueues the
; landing buffer as we pop each delivery, which erases the old serve0/serve
; repost bookkeeping outright — rejected duplicates and clean deliveries
; need no distinction here anymore. The completion cookie is the landing
; buffer's address.
;
; Harness contract: PTT 0 → peer's RX ring; desc slots 0 SQ / 1 CQ / 2 RX
; (cap 2, AUTO_REPOST); $2500 outgoing echo buffer, $820 served counter.

        .org $1000
        ; stage both RX landing entries (cookie = buffer address)
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
        ; stage the echo transmit entry (SQE)
        LDA #1
        STA !$2400          ; op = send
        LDA ##$FF00_0000_0000_0000
        STA !$2408          ; target
        LDA ##$2500
        STA !$2410          ; buffer
        LDA ##$2_0000_0008
        STA !$2418          ; len 8 | cookie 2
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        TAY
        AND #$FF
        CMP #3
        BNE serve           ; send-acks et al: keep listening
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
        BNE serve           ; rejected dup / noise: just listen
echo:   STX $8E0            ; cookie = where it landed
        LDA ($8E0)
        INC
        STA !$2500
        INC $820            ; count served deliveries
        SEND 0
        BRA serve
