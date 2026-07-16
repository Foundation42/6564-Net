; scatter_worker.asm — a scatter-gather worker: receive {id, v}, compute v²
; by shift-add multiplication, reply {id, v²}. Stateless and idempotent — a
; duplicate task (the coordinator re-scatters stragglers) just recomputes and
; resends, which IS the retransmission protocol. Immortal, like every node
; that has an upstream: parked between requests, costing nothing.
;
; Harness contract:
;   PTT 0 → coordinator's result ring
;   desc slots: 0 result SQ, 1 CQ, 2 task RX (cap 1)
;   RAM: $2200 task landing {id, v}, $2280 reply out {id, v²}
;   near: $850 served count (harness reads; > 1 per task = duplicates seen)

        .org $1000
        ; stage both task landing entries (cap-2 AUTO_REPOST ring;
        ; cookie = buffer address)
        LDA ##$2200
        STA !$2A00
        STA !$2A18
        LDA #16
        STA !$2A08
        LDA #0
        STA !$2A10
        LDA ##$2220
        STA !$2A20
        STA !$2A38
        LDA #16
        STA !$2A28
        LDA #0
        STA !$2A30
        RECV 2
        RECV 2
        ; stage the reply transmit descriptor (SQ 0 → PTT 0)
        LDA #1
        STA !$2400          ; op = send
        LDA ##$FF00_0000_0000_0000
        STA !$2408          ; target
        LDA ##$2280
        STA !$2410          ; buffer
        LDA ##$1_0000_0010
        STA !$2418          ; len 16 | cookie 1
serve:  LSTN 1
        CQPOP 1
        BEQ serve
        TAY
        AND #$FF
        CMP #3
        BNE serve           ; transport acks: ignore
        TYA
        LSR #8
        AND #$FF
        CMP #0
        BNE serve           ; rejected: nothing landed
        ; reply {id, v·v}
        STX $8E0            ; cookie = where the task landed
        LDA ($8E0)
        STA !$2280          ; echo the worker id
        LDY #8
        LDA ($8E0),Y
        STA $8F0            ; multiplicand (walks left)
        STA $8F8            ; multiplier (walks right)
        LDA #0
        STA $8E8            ; product
mul:    LDA $8F8
        BEQ mdone
        LSR
        STA $8F8
        BCC noadd           ; that bit was clear
        CLC
        LDA $8E8
        ADC $8F0
        STA $8E8
noadd:  LDA $8F0
        ASL
        STA $8F0
        BRA mul
mdone:  LDA $8E8
        STA !$2288
        INC $850            ; count requests served
        SEND 0
        BRA serve
