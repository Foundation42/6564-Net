//! sim6564 demo: two actors ping-pong a value across a hostile fabric.
//!
//! Core 0 ("ping") sends a 64-bit value to core 1 ("pong"), which increments
//! and echoes it. Ping drives N rounds, retransmitting on timeout or reject —
//! reliability built in software from CQ feedback, exactly as §6.1 intends.
//! The link loses, delays, reorders and duplicates datagrams (seeded, so any
//! run reproduces exactly).
//!
//!   usage: sim6564 [seed] [loss_ppm4k] [rounds]
//!     seed        RNG seed (default 0x6564)
//!     loss_ppm4k  packet loss in parts per 4096, 0..4096 (default 1024 = 25%)
//!     rounds      ping-pong rounds (default 8, max 100)

const std = @import("std");
const sim = @import("sim6564");

const ring = sim.ring;
const machine = sim.machine;

// Both cores share this layout; see integration_tests.zig for the map.
// Ping is a full end-to-end protocol: it ignores transport acks entirely and
// retransmits on a timer, accepting only the echo whose sequence it expects.
// The ISA has no timer — so ping builds one from the fabric's honesty: a TXR
// to an unroutable prefix (PTT slot 1) is a guaranteed timeout completion,
// send_timeout cycles later. The fabric is the clock.
const ping_src_fmt =
    \\        .org $1000
    \\        LDA #{d}            ; rounds
    \\        STA $810
    \\        LDA ##$FF00_0100_0000_0000
    \\        STA $838            ; black-hole window pointer = our timer
    \\        ; stage the RX landing entry (ring cap 1: constant address)
    \\        LDA ##$2200
    \\        STA !$2100
    \\        LDA #64
    \\        STA !$2108
    \\        LDA #0
    \\        STA !$2110
    \\        LDA #$AA
    \\        STA !$2118
    \\        ; stage the transmit descriptor
    \\        LDA ##$FF00_0000_0000_0000
    \\        STA !$2400          ; dst: window, PTT slot 0
    \\        LDA ##$2500
    \\        STA !$2408          ; src buffer
    \\        LDA #8
    \\        STA !$2410          ; length
    \\        LDA #1
    \\        STA !$2418          ; cookie
    \\        LDA #0
    \\        STA !$2500          ; first message value
    \\        TXR ($838),A        ; arm the retransmit timer chain
    \\loop:   RECV 2              ; landing space for the reply
    \\send:   SEND 0
    \\wait:   LSTN 1
    \\        CQPOP 1
    \\        BEQ wait
    \\        TAY                 ; completion word0 → Y
    \\        AND #$FF
    \\        CMP #1
    \\        BEQ timer           ; our timer came back (tag=txr)
    \\        CMP #3
    \\        BEQ got
    \\        BRA wait            ; transport acks: end-to-end only, ignore
    \\timer:  INC $818            ; count a retransmission
    \\        LDA #0
    \\        TXR ($838),A        ; re-arm the chain
    \\        BRA send            ; and resend whatever we're waiting on
    \\got:    TYA                 ; a delivery completion: clean?
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        AND #$FF
    \\        CMP #0
    \\        BNE wait            ; rejected inbound (dup noise): keep waiting
    \\        LDA !$2500          ; sequence check: the only echo we accept
    \\        INC                 ; is (value we sent) + 1 — stale duplicates
    \\        STA $828            ; of earlier echoes are ignored
    \\        LDA !$2200
    \\        CMP $828
    \\        BNE stale
    \\        STA !$2500          ; the echo becomes the next message
    \\        DEC $810
    \\        BNE loop
    \\        LDA !$2200
    \\        STA !$2280          ; final value, for the harness
    \\        HLT
    \\stale:  RECV 2              ; it landed, so it ate our buffer: repost
    \\        BRA wait
;

const pong_src =
    \\        .org $1000
    \\        ; stage RX landing entry
    \\        LDA ##$2200
    \\        STA !$2100
    \\        LDA #64
    \\        STA !$2108
    \\        LDA #0
    \\        STA !$2110
    \\        LDA #$BB
    \\        STA !$2118
    \\        ; stage transmit descriptor for echoes
    \\        LDA ##$FF00_0000_0000_0000
    \\        STA !$2400
    \\        LDA ##$2500
    \\        STA !$2408
    \\        LDA #8
    \\        STA !$2410
    \\        LDA #2
    \\        STA !$2418
    \\serve0: RECV 2
    \\serve:  LSTN 1
    \\        CQPOP 1
    \\        BEQ serve
    \\        TAY
    \\        AND #$FF
    \\        CMP #3
    \\        BNE serve           ; send-acks et al: keep listening
    \\        TYA
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        LSR
    \\        AND #$FF
    \\        CMP #0
    \\        BNE serve           ; rejected dup / noise: our buffer is still
    \\                            ; posted, so do NOT repost — just listen
    \\echo:   LDA !$2200
    \\        INC
    \\        STA !$2500
    \\        INC $820            ; count served deliveries
    \\        SEND 0
    \\        BRA serve0
;

fn wire(m: *machine.Machine, core: u16) void {
    m.setRing(core, 0, ring.slot_sq, .{
        .base = 0x2400,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 4,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, 0, ring.slot_rx, .{
        .base = 0x2100,
        .cap_log2 = 0,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var seed: u64 = 0x6564;
    var loss: u16 = 1024;
    var rounds: u64 = 8;
    var trace = false;
    {
        var args = try std.process.argsWithAllocator(alloc);
        defer args.deinit();
        _ = args.next();
        if (args.next()) |s| seed = try std.fmt.parseInt(u64, s, 0);
        if (args.next()) |s| loss = @min(4096, try std.fmt.parseInt(u16, s, 0));
        if (args.next()) |s| rounds = @min(100, try std.fmt.parseInt(u64, s, 0));
        if (args.next()) |s| trace = std.mem.eql(u8, s, "trace");
    }

    var m = try machine.Machine.init(alloc, .{
        .cores = 2,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .seed = seed,
        .link = .{
            .base_latency = 200,
            .jitter = 120,
            .loss_ppm4k = loss,
            .dup_ppm4k = 128,
            .send_timeout = 2500,
        },
        .max_cycles = 50_000_000,
        .trace = trace,
    });
    defer m.deinit();

    // Each core's PTT slot 0 points at the other core's default RX ring.
    m.setPtt(0, 0, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(1, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0x6564,
    });
    m.setPtt(1, 0, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0x6564,
    });
    // Ping's timer: PTT slot 1 routes to a core that doesn't exist. Sends
    // through it vanish; their timeout completions are the clock ticks.
    m.setPtt(0, 1, .{
        .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    wire(&m, 0);
    wire(&m, 1);

    const ping_src = try std.fmt.allocPrint(alloc, ping_src_fmt, .{rounds});
    defer alloc.free(ping_src);
    var diag = sim.asm6564.Diagnostic{};
    inline for (.{ .{ 0, "ping" }, .{ 1, "pong" } }) |spec| {
        const src = if (spec[0] == 0) ping_src else pong_src;
        var out = sim.asm6564.assemble(alloc, src, &diag) catch |err| {
            std.debug.print("{s}: asm error line {d}: {s}\n", .{ spec[1], diag.line, diag.message });
            return err;
        };
        defer out.deinit();
        m.load(spec[0], out.origin, out.code);
    }
    try m.spawn(1, 0, 0x1000, 0x3000); // pong listens first
    try m.spawn(0, 0, 0x1000, 0x3000);

    const reason = try m.run();

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — ping-pong across a hostile fabric
        \\  seed 0x{X}, loss {d}/4096 ({d:.1}%), dup 128/4096, {d} rounds
        \\
    , .{ seed, loss, @as(f64, @floatFromInt(loss)) * 100.0 / 4096.0, rounds });

    const ping = &m.cores[0].contexts[0];
    const pong = &m.cores[1].contexts[0];
    const final = std.mem.readInt(u64, m.cores[0].ram[0x2280 - machine.ram_base ..][0..8], .little);
    const retries = std.mem.readInt(u64, ping.near[0x818..][0..8], .little);
    const served = std.mem.readInt(u64, pong.near[0x820..][0..8], .little);

    const verdict = switch (reason) {
        .deadlock => if (ping.state == .halted)
            "ping completed; pong still parked listening — machine quiesced"
        else
            "DEADLOCK: ping did not finish",
        .all_halted => "all contexts halted",
        .faulted => "a context FAULTED",
        .max_cycles => "hit max_cycles",
    };
    try stdout.print(
        \\
        \\  outcome: {s}
        \\  final value {d} (sequence-checked: must equal rounds)
        \\  ping timer retransmissions {d}, pong deliveries served {d}
        \\
        \\  cycles: core0 {d}, core1 {d}   instructions: {d}
        \\  fabric: {d} sends ({d} timer ticks into the void), {d} delivered,
        \\          {d} lost, {d} duplicated, {d} timeouts, {d} rejects,
        \\          {d} context switches
        \\
    , .{
        verdict,                  final,
        retries,                  served,
        m.cores[0].clock,         m.cores[1].clock,
        m.stats.instructions,     m.stats.sends,
        m.stats.unroutable,       m.stats.delivered,
        m.stats.lost,             m.stats.duplicated,
        m.stats.timeouts,         m.stats.rejects,
        m.stats.context_switches,
    });
    if (rounds > 0 and ping.state != .halted) std.process.exit(1);
}
