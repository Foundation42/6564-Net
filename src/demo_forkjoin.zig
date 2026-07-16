//! The Fork-Join Matrix: one root splits a message to L×W workers (default
//! 8×125 = 1,000), each passes it to a partner relay, and all 1,000 relays
//! aggregate back to a single node. A massive parallel scheduling burst:
//! the fork lights ~2,000 actors across L cores within a few hundred
//! cycles, and the join is a 1,000-way cross-core fan-in.
//!
//! The topology is hierarchical BY CONSTRUCTION: a destination costs a PTT
//! slot (256/core, shared by all the core's contexts) and a LINK chain
//! entry costs 32 near-page bytes (~59 fit) — so root→lieutenants is a
//! LINK chain, lieutenant→workers is an on-die fire-and-forget loop, and
//! nothing addresses 1,000 peers flat. Fan-out degree is an architectural
//! constant of the machine (spec open question 1, felt in practice).
//!
//! Checksum: worker g sends g, its relay sends g+1, so the aggregator must
//! collect exactly K messages summing to K(K+1)/2 + K.
//!
//! Programs: fj_root.asm, fj_lieutenant.asm, fj_pass.asm, fanin_sink.asm.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const root_src = @embedFile("programs/fj_root.asm");
const lieutenant_src = @embedFile("programs/fj_lieutenant.asm");
const pass_src = @embedFile("programs/fj_pass.asm");
const sink_src = @embedFile("programs/fanin_sink.asm");

pub const Options = struct {
    lieutenants: u16 = 8, // 1..16
    workers: u16 = 125, // per lieutenant, 1..125 (PTT + context budget)
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    received: u64,
    sum: u64,
    expected_sum: u64,
    k: u64,
    cycles: u64,
    stats: machine.Stats,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const l: u16 = @max(1, @min(16, opts.lieutenants));
    const w: u16 = @max(1, @min(125, opts.workers));
    const k = @as(u64, l) * w;
    const agg_core: u16 = l + 1;

    var m = try machine.Machine.init(alloc, .{
        .cores = l + 2, // root, lieutenants, aggregator
        .contexts_per_core = @intCast(2 * w + 1),
        .ram_size = 0x10000,
        .link = .{
            .base_latency = 200,
            .jitter = 120,
            .loss_ppm4k = 0,
            .dup_ppm4k = 0,
            .send_timeout = 2500,
        },
        .max_cycles = 2_000_000 + 200 * k,
        .trace = opts.trace,
    });
    defer m.deinit();

    var diag = asm6564.Diagnostic{};
    var progs: [4]asm6564.Output = undefined;
    inline for (.{ root_src, lieutenant_src, pass_src, sink_src }, 0..) |src, i| {
        progs[i] = asm6564.assemble(alloc, src, &diag) catch |err| {
            std.debug.print("forkjoin asm error line {d}: {s}\n", .{ diag.line, diag.message });
            return err;
        };
    }
    defer for (&progs) |*p| p.deinit();
    const root_p = &progs[0];
    const lt_p = &progs[1];
    const pass_p = &progs[2];
    const sink_p = &progs[3];

    var w8: [8]u8 = undefined;
    var eb: [32]u8 = undefined;
    const stage = struct {
        fn sqe(mm: *machine.Machine, core: u16, addr: u64, e: ring.SqEntry, buf: *[32]u8) void {
            for (e.pack(), 0..) |word, wi|
                std.mem.writeInt(u64, buf[wi * 8 ..][0..8], word, .little);
            if (addr < machine.near_size) {
                mm.writeNear(core, 0, @intCast(addr), buf);
            } else {
                mm.load(core, addr, buf);
            }
        }
    }.sqe;

    // ── Root (core 0): one doorbell, a LINK chain of L lieutenants ──────
    m.load(0, root_p.origin, root_p.code);
    m.setRing(0, 0, ring.slot_sq, .{
        .base = 0x2400,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 5,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    var lt: u16 = 1;
    while (lt <= l) : (lt += 1) {
        m.setPtt(0, lt, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(lt, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
        const entry = ring.SqEntry{
            .op = .txr,
            .flags = if (lt < l) ring.SqEntry.flag_link else 0,
            .link = if (lt < l) @intCast(0xC00 + 32 * @as(u16, lt - 1) + 32) else 0,
            .target = ring.windowAddr(lt, 0),
            .buf = 0, // the "go" value
            .len = 0,
            .cookie_lo = lt,
        };
        // Head lives in the SQ ring; the rest are near-page chain entries.
        const addr: u64 = if (lt == 1) 0x2400 else 0xC00 + 32 * @as(u64, lt - 1);
        stage(&m, 0, addr, entry, &eb);
    }
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    // ── Lieutenant cores (1..L): 1 lieutenant + W workers + W relays ────
    var core: u16 = 1;
    while (core <= l) : (core += 1) {
        m.load(core, lt_p.origin, lt_p.code);
        m.load(core, pass_p.origin, pass_p.code);
        // PTT: slot 0 → aggregator; 1..W → workers; W+1..2W → relays.
        m.setPtt(core, 0, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(agg_core, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
        var s: u16 = 1;
        while (s <= 2 * w) : (s += 1) {
            m.setPtt(core, s, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(core, @intCast(s), ring.slot_rx),
                .rights = .{ .send = true },
                .token = 0x6564,
            });
        }
        var i: u16 = 0;
        while (i <= 2 * w) : (i += 1) {
            const ctx: u8 = @intCast(i);
            // Everyone gets: SQ 0 at $6000+32i, RX 2 (one granted buffer,
            // cell $C000+8i, cookie = cell), and a CQ (lieutenant's is deep
            // at $E000; the rest stripe $8000+64i).
            m.setRing(core, ctx, ring.slot_sq, .{
                .base = 0x6000 + 32 * @as(u64, i),
                .cap_log2 = 0,
                .entry_size = ring.sq_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 0,
                .token = 0,
            });
            m.setRing(core, ctx, ring.slot_cq, .{
                .base = if (i == 0) 0xE000 else 0x8000 + 64 * @as(u64, i),
                .cap_log2 = if (i == 0) 8 else 2,
                .entry_size = ring.cq_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 0,
                .token = 0,
            });
            m.setRing(core, ctx, ring.slot_rx, .{
                .base = 0x4000 + 32 * @as(u64, i),
                .cap_log2 = 0,
                .entry_size = ring.rx_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 1, // one message each, granted by the loader
                .token = 0x6564,
            });
            const cell: u64 = 0xC000 + 8 * @as(u64, i);
            const rxe = ring.RxEntry{ .buf = cell, .cap = 8, .filled = 0, .cookie = cell };
            for (rxe.pack(), 0..) |word, wi|
                std.mem.writeInt(u64, eb[wi * 8 ..][0..8], word, .little);
            m.load(core, 0x4000 + 32 * @as(u64, i), &eb);

            const sqe_addr: u64 = 0x6000 + 32 * @as(u64, i);
            if (i == 0) {
                // The lieutenant: retargetable on-die fan entry.
                stage(&m, core, sqe_addr, .{
                    .op = .txr,
                    .target = ring.windowAddr(1, 0),
                    .buf = 0,
                    .len = 0,
                    .cookie_lo = 0,
                }, &eb);
                std.mem.writeInt(u64, &w8, sqe_addr + 8, .little); // target word
                m.writeNear(core, ctx, 0x848, &w8);
                var kk: u16 = 1;
                while (kk <= w) : (kk += 1) {
                    std.mem.writeInt(u64, &w8, ring.windowAddr(kk, 0), .little);
                    m.writeNear(core, ctx, @intCast(0x900 + 8 * kk), &w8);
                }
                std.mem.writeInt(u64, &w8, 8 * (@as(u64, w) + 1), .little);
                m.writeNear(core, ctx, 0x868, &w8);
                try m.spawn(core, ctx, 0x1000, 0x3000, 0);
            } else {
                // Workers (1..W) pass to their relay; relays (W+1..2W) pass
                // to the aggregator. One program, different delta and target.
                const is_worker = i <= w;
                stage(&m, core, sqe_addr, .{
                    .op = .txr,
                    .target = if (is_worker)
                        ring.windowAddr(w + i, 0) // partner relay's PTT slot
                    else
                        ring.windowAddr(0, 0), // the aggregator
                    .buf = 0, // value word, written at runtime
                    .len = 0,
                    .cookie_lo = i,
                }, &eb);
                // stage() writes SQEs for ctx 0's near page only; these are
                // RAM addresses, so it landed in core RAM — correct. Near
                // config per context:
                std.mem.writeInt(u64, &w8, sqe_addr + 16, .little); // value word
                m.writeNear(core, ctx, 0x840, &w8);
                const delta: u64 = if (is_worker)
                    (@as(u64, core - 1) * w + i) // its global index g
                else
                    1;
                std.mem.writeInt(u64, &w8, delta, .little);
                m.writeNear(core, ctx, 0x850, &w8);
                try m.spawn(core, ctx, 0x1200, 0x3000, 0);
            }
        }
    }

    // ── Aggregator (core L+1): the fanin sink, expecting K ──────────────
    m.load(agg_core, sink_p.origin, sink_p.code);
    m.setRing(agg_core, 0, ring.slot_cq, .{
        .base = 0x8000,
        .cap_log2 = 9,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(agg_core, 0, ring.slot_rx, .{
        .base = 0x4000,
        .cap_log2 = 8,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 256,
        .token = 0x6564,
    });
    var jj: u64 = 0;
    while (jj < 256) : (jj += 1) {
        const cell: u64 = 0xC000 + 8 * jj;
        const rxe = ring.RxEntry{ .buf = cell, .cap = 8, .filled = 0, .cookie = cell };
        for (rxe.pack(), 0..) |word, wi|
            std.mem.writeInt(u64, eb[wi * 8 ..][0..8], word, .little);
        m.load(agg_core, 0x4000 + 32 * jj, &eb);
    }
    std.mem.writeInt(u64, &w8, k, .little);
    m.load(agg_core, 0x2600, &w8);
    try m.spawn(agg_core, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();

    var max_clock: u64 = 0;
    for (m.cores) |*c| max_clock = @max(max_clock, c.clock);
    const anear = &m.cores[agg_core].contexts[0].near;
    return .{
        .reason = reason,
        .received = std.mem.readInt(u64, anear[0x860..][0..8], .little),
        .sum = std.mem.readInt(u64, anear[0x868..][0..8], .little),
        .expected_sum = k * (k + 1) / 2 + k,
        .k = k,
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    const l = @max(1, @min(16, opts.lieutenants));
    const w = @max(1, @min(125, opts.workers));
    const complete = o.reason == .all_halted and o.received == o.k and o.sum == o.expected_sum;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — Fork-Join Matrix: 1 → {d}×{d} = {d} workers → {d} relays → 1
        \\  fork: a LINK chain to {d} lieutenants, then on-die fire-and-forget;
        \\  join: a {d}-way cross-core fan-in with backoff-free relay retries
        \\
        \\  aggregated {d}/{d}, checksum {d} {s}
        \\  outcome: {s}{s}
        \\
        \\  makespan {d} cycles, fork chain fires {d}
        \\  fabric: {d} sends, {d} delivered, {d} no-buffer rejects at the join,
        \\          {d} auto-reposts, {d} CQ overflows on the measured path
        \\  {d} instructions, {d} zero-cycle context switches across ~{d} actors
        \\
    , .{
        l,                        w,
        o.k,                      o.k,
        l,                        o.k,
        o.received,               o.k,
        o.sum,                    if (o.sum == o.expected_sum) "(verified)" else "(MISMATCH)",
        @tagName(o.reason),       if (complete) " — forked, relayed, joined" else " — INCOMPLETE",
        o.cycles,                 o.stats.chain_fires,
        o.stats.sends,            o.stats.delivered,
        o.stats.rejects,          o.stats.auto_reposts,
        o.stats.cq_overflows,     o.stats.instructions,
        o.stats.context_switches, 2 * o.k + l + 2,
    });
    if (!complete) std.process.exit(1);
}
