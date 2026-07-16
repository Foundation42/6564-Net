; pong.asm — the echo server: receive a value, add one, send it back.
; Serves forever; the machine quiesces around it when ping finishes.
;
; Harness contract: PTT 0 → peer's RX ring; desc slots 0 SQ / 1 CQ / 2 RX;
; $2200 landing buffer, $2500 outgoing echo buffer, $820 served counter.

        .org $1000
        ; stage RX landing entry
        LDA ##$2200
        STA !$2100
        LDA #64
        STA !$2108
        LDA #0
        STA !$2110
        LDA #$BB
        STA !$2118
        ; stage transmit descriptor for echoes
        LDA ##$FF00_0000_0000_0000
        STA !$2400
        LDA ##$2500
        STA !$2408
        LDA #8
        STA !$2410
        LDA #2
        STA !$2418
serve0: RECV 2
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
        BNE serve           ; rejected dup / noise: our buffer is still
                            ; posted, so do NOT repost — just listen
echo:   LDA !$2200
        INC
        STA !$2500
        INC $820            ; count served deliveries
        SEND 0
        BRA serve0
