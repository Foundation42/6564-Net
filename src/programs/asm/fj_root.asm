; fj_root.asm — the fork-join root: one doorbell, and the LINK chain fans
; the "go" message to every lieutenant. The chain (head in the SQ ring,
; the rest staged in the near page by the loader) fires entry-by-entry on
; transport-ok; the root's work is one instruction plus a halt.
;
; Why a chain of lieutenants and not a chain of 1,000 workers: fan-out
; degree is an architectural constant — a destination costs a PTT slot
; (256 per core) and a chain entry costs 32 near-page bytes (~59 fit in
; scratch). Big fan-out is therefore hierarchical BY CONSTRUCTION on this
; machine, which is how dissemination trees work anyway.
;
; The contract, as directives: eight lieutenant capabilities, granted
; bare — this code never reads a window pointer, the staged chain below
; carries them all. Nothing pins a PTT slot on core 0, so the loader
; hands out slots 0..7 in parameter order (the scatter coordinator's
; trick) and the chain bakes those windows. The head SQE lives in the
; one-entry SQ ring pinned at $2400; lieutenants two through eight are
; LINK-chained near-page entries at $C20..$CE0 (word0 = op txr | LINK |
; next<<16, value 0 = the "go", cookie = the lieutenant's number). The
; CQ absorbs eight transport acks nobody pops. The bare-period timer
; pins no capability at all — it is only the fabric horizon the demo
; harness measured this program against.
;
; The .system block is the demo's default shape: 8 lieutenants × 125
; workers = 1,000. A lieutenant core carries its own workers AND their
; relays (ctx 0, 1..125, 126..250 — 251 contexts, the demo's exact
; packing, past the 200 the free-placement budget allows, so every
; instance is pinned with `on`); the aggregator sits alone on core 9,
; declared first so its readbacks — count and checksum, the join's
; verdict — lead the report. Spawn order (reverse declaration) is pure
; pre-run staging: the rings are the loader's work, so nothing can
; arrive before its owner exists. The workers' global numbers ride in
; as group base + replica index (fj_pass adds them once in its
; prologue), and the relays' next names the aggregator directly: a
; singleton referent is a shared one-member group, so one actor
; partners a group in one role and a singleton in the other.

        .actor Root(l1 cap, l2 cap, l3 cap, l4 cap, l5 cap, l6 cap, l7 cap, l8 cap)
        .ring 0 sq base=$2400 cap=1
        .ring 1 cq cap=32
        .timer period=2500
        ; the fork chain: head in the ring, seven near-page links after it
        .stage $2400 $0C20_0102, $FF00_0000_0000_0000, 0, $1_0000_0000
        .stage $C20 $0C40_0102, $FF00_0100_0000_0000, 0, $2_0000_0000
        .stage $C40 $0C60_0102, $FF00_0200_0000_0000, 0, $3_0000_0000
        .stage $C60 $0C80_0102, $FF00_0300_0000_0000, 0, $4_0000_0000
        .stage $C80 $0CA0_0102, $FF00_0400_0000_0000, 0, $5_0000_0000
        .stage $CA0 $0CC0_0102, $FF00_0500_0000_0000, 0, $6_0000_0000
        .stage $CC0 $0CE0_0102, $FF00_0600_0000_0000, 0, $7_0000_0000
        .stage $CE0 2, $FF00_0700_0000_0000, 0, $8_0000_0000
        .use "fj_lieutenant.asm"
        .use "fj_pass.asm"
        .use "fanin_sink.asm"

        .system
        agg = FanInSink(1000) on 9
        root = Root(l1, l2, l3, l4, l5, l6, l7, l8) on 0
        l1 = Lieutenant(ws1, 1008) on 1
        ws1 = Pass[125](rs1, index, 1) on 1
        rs1 = Pass[125](agg, 1, 0) on 1
        l2 = Lieutenant(ws2, 1008) on 2
        ws2 = Pass[125](rs2, index, 126) on 2
        rs2 = Pass[125](agg, 1, 0) on 2
        l3 = Lieutenant(ws3, 1008) on 3
        ws3 = Pass[125](rs3, index, 251) on 3
        rs3 = Pass[125](agg, 1, 0) on 3
        l4 = Lieutenant(ws4, 1008) on 4
        ws4 = Pass[125](rs4, index, 376) on 4
        rs4 = Pass[125](agg, 1, 0) on 4
        l5 = Lieutenant(ws5, 1008) on 5
        ws5 = Pass[125](rs5, index, 501) on 5
        rs5 = Pass[125](agg, 1, 0) on 5
        l6 = Lieutenant(ws6, 1008) on 6
        ws6 = Pass[125](rs6, index, 626) on 6
        rs6 = Pass[125](agg, 1, 0) on 6
        l7 = Lieutenant(ws7, 1008) on 7
        ws7 = Pass[125](rs7, index, 751) on 7
        rs7 = Pass[125](agg, 1, 0) on 7
        l8 = Lieutenant(ws8, 1008) on 8
        ws8 = Pass[125](rs8, index, 876) on 8
        rs8 = Pass[125](agg, 1, 0) on 8
        .endsystem

        .org $1000
        SEND 0              ; light the tree
        HLT
