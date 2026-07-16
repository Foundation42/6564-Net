; hello.asm — the first words out of the machine.
;
; The 6564 has no I/O instructions, because SEND is the I/O instruction.
; The console is not a port: it is an actor on the peripheral row of the
; mesh (spec §7), reached through a PTT capability like every other actor.
; One staged SQE and the fabric is a teletype; the delivery ack in our CQ
; is the receipt that the console took the bytes — and if it never comes,
; we say it again. Politeness through idempotence.
;
; Harness contract:
;   PTT 0 → console ($FF00)     desc slots: 0 SQ ($2400), 1 CQ

        .org $1000
        LDA #1
        STA !$2400          ; SQE word0: op = send
        LDA ##$FF00_0000_0000_0000
        STA !$2408          ; word1: target — the console, via PTT 0
        LDA ##msg
        STA !$2410          ; word2: the text
        LDA ##$1_0000_0020  ; word3: len 32 | cookie 1
        STA !$2418
send:   SEND 0
wait:   LSTN 1
        CQPOP 1
        BEQ wait
        TAY
        AND #$FF
        CMP #2              ; our send's completion?
        BNE wait
        TYA                 ; …with what verdict?
        LSR #8
        AND #$FF
        BNE send            ; no confirmation: say it again
        HLT

msg:    .ascii "HELLO, WORLD - THE 6564 SPEAKS."
        .byte 10
