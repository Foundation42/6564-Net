//! The Fan-In / Big Brother stress test: N senders (default 10,000, spread
//! 200 to a core) flood ONE target actor simultaneously. Exercises extreme
//! CQ contention, the admission rule (a delivery needs a landing buffer AND
//! a completion slot — CQ-full is backpressure, not record loss), and the
//! reject/backoff/retry economy at scale. The architecture cannot
//! head-of-line block by design: a saturated ring drops and reject-completes,
//! and unlucky senders retry on their own clocks.
//!
//! Programs: programs/flood_sender.asm, programs/fanin_sink.asm.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const sender_src = @embedFile("programs/flood_sender.asm");
const sink_src = @embedFile("programs/fanin_sink.asm");

const per_core = 200;

pub const Options = struct {
    senders: u64 = 10_000, // 1..10_000
    loss_ppm4k: u16 = 0, // pure-contention test by default
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    received: u64,
    sum: u64,
    expected_sum: u64,
    senders: u64,
    cycles: u64,
    stats: machine.Stats,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const n: u64 = @max(1, @min(10_000, opts.senders));
    const sender_cores: u16 = @intCast((n + per_core - 1) / per_core);

    var m = try machine.Machine.init(alloc, .{
        .cores = sender_cores + 1,
        .contexts_per_core = per_core,
        .ram_size = 0x10000,
        .link = .{
            .base_latency = 200,
            .jitter = 120,
            .loss_ppm4k = opts.loss_ppm4k,
            .dup_ppm4k = 0,
            .send_timeout = 2500,
        },
        .max_cycles = 500 * n + 5_000_000,
        .trace = opts.trace,
    });
    defer m.deinit();

    var diag = asm6564.Diagnostic{};
    var sender = asm6564.assemble(alloc, sender_src, &diag) catch |err| {
        std.debug.print("bigbrother asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer sender.deinit();
    var sink = asm6564.assemble(alloc, sink_src, &diag) catch |err| {
        std.debug.print("bigbrother asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer sink.deinit();

    // ── The target (core 0, ctx 0): one actor against the flood ─────────
    m.load(0, sink.origin, sink.code);
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x8000,
        .cap_log2 = 9, // 512 records — deeper than the RX ring, so a landed
        .entry_size = ring.cq_entry_size, // delivery can always post
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(0, 0, ring.slot_rx, .{
        .base = 0x4000,
        .cap_log2 = 8, // 256 landing buffers absorbing the burst
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 256, // all granted by the loader
        .token = 0x6564,
    });
    var j: u64 = 0;
    while (j < 256) : (j += 1) {
        const cell: u64 = 0xC000 + 8 * j;
        const entry = ring.RxEntry{ .buf = cell, .cap = 8, .filled = 0, .cookie = cell };
        var eb: [32]u8 = undefined;
        for (entry.pack(), 0..) |word, wi|
            std.mem.writeInt(u64, eb[wi * 8 ..][0..8], word, .little);
        m.load(0, 0x4000 + 32 * j, &eb);
    }
    var w8: [8]u8 = undefined;
    std.mem.writeInt(u64, &w8, n, .little);
    m.load(0, 0x2600, &w8);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    // ── The crowd: cores 1.., 200 senders each ──────────────────────────
    var id: u64 = 1;
    var core: u16 = 1;
    while (core <= sender_cores) : (core += 1) {
        m.load(core, sender.origin, sender.code);
        m.setPtt(core, 0, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
        m.setPtt(core, 1, .{
            .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0,
        });
        var i: u16 = 0;
        while (i < per_core and id <= n) : ({
            i += 1;
            id += 1;
        }) {
            const ctx: u8 = @intCast(i);
            const cell: u64 = 0x6000 + 8 * @as(u64, i);
            std.mem.writeInt(u64, &w8, id, .little);
            m.load(core, cell, &w8);
            const sqe = ring.SqEntry{
                .op = .send,
                .target = ring.windowAddr(0, 0),
                .buf = cell,
                .len = 8,
                .cookie_lo = @intCast(id & 0xFFFF_FFFF),
            };
            var eb: [32]u8 = undefined;
            for (sqe.pack(), 0..) |word, wi|
                std.mem.writeInt(u64, eb[wi * 8 ..][0..8], word, .little);
            m.load(core, 0x4000 + 32 * @as(u64, i), &eb);
            m.setRing(core, ctx, ring.slot_sq, .{
                .base = 0x4000 + 32 * @as(u64, i),
                .cap_log2 = 0,
                .entry_size = ring.sq_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 0,
                .token = 0,
            });
            m.setRing(core, ctx, ring.slot_cq, .{
                .base = 0x8000 + 64 * @as(u64, i),
                .cap_log2 = 2,
                .entry_size = ring.cq_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 0,
                .token = 0,
            });
            std.mem.writeInt(u64, &w8, ring.windowAddr(1, 0), .little);
            m.writeNear(core, ctx, 0x838, &w8);
            try m.spawn(core, ctx, 0x1000, 0x3000, 0);
        }
    }

    const reason = try m.run();

    var max_clock: u64 = 0;
    for (m.cores) |*c| max_clock = @max(max_clock, c.clock);
    const tnear = &m.cores[0].contexts[0].near;
    return .{
        .reason = reason,
        .received = std.mem.readInt(u64, tnear[0x860..][0..8], .little),
        .sum = std.mem.readInt(u64, tnear[0x868..][0..8], .little),
        .expected_sum = n * (n + 1) / 2,
        .senders = n,
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    const exact = opts.loss_ppm4k == 0;
    const complete = o.reason == .all_halted and o.received == o.senders and
        (!exact or o.sum == o.expected_sum);
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — Big Brother: {d} senders, one target, one ring
        \\  loss {d}/4096; target: 256 landing buffers, 512-record CQ,
        \\  AUTO_REPOST absorption; senders back off on reject, retry on loss
        \\
        \\  received {d}/{d}, checksum {d} {s}
        \\  outcome: {s}{s}
        \\
        \\  {d} cycles to absorb the flood ({d} per message end-to-end)
        \\  fabric: {d} send attempts, {d} delivered, {d} no-buffer rejects
        \\          (backpressure events), {d} timeouts, {d} lost,
        \\          {d} auto-reposts, {d} CQ overflows (must be 0)
        \\  {d} instructions, {d} context switches
        \\
    , .{
        o.senders,                opts.loss_ppm4k,
        o.received,               o.senders,
        o.sum,                    if (!exact) "(dups possible under loss)" else if (o.sum == o.expected_sum) "(verified)" else "(MISMATCH)",
        @tagName(o.reason),       if (complete) " — every voice heard, exactly once" else " — INCOMPLETE",
        o.cycles,                 o.cycles / o.senders,
        o.stats.sends,            o.stats.delivered,
        o.stats.rejects,          o.stats.timeouts,
        o.stats.lost,             o.stats.auto_reposts,
        o.stats.cq_overflows,     o.stats.instructions,
        o.stats.context_switches,
    });
    if (!complete) std.process.exit(1);
}
