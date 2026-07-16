//! Armstrong's ring across dies (spec §6.5): the same unmodified
//! programs/ring_node.asm that set the 66-cycle benchmark, now spanning
//! D whole machines joined by the IO plane — one die per host core when
//! `parallel` is on. Node i's PTT slot points at node i+1 exactly as
//! before; the only difference is one byte in the last node's PTT entry:
//! route 1 instead of route 0. The program cannot tell. That byte is the
//! entire programming model of multi-die.
//!
//! What it measures: the cost of leaving a die (plane latency per
//! crossing) and that the conservative-window scheme is bit-identical
//! threaded or not.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const cluster = @import("cluster.zig");
const asm6564 = @import("asm.zig");

const node_src = @embedFile("programs/ring_node.asm");

pub const Options = struct {
    dies: u16 = 4, // 2..16
    nodes: u16 = 50, // 2..200 per die (2..100 when busy > 0)
    laps: u64 = 10, // 1..1000
    /// Laps of a SECOND, die-local ring each die runs concurrently (its
    /// own token, its own n nodes). The global token is sequential by
    /// nature — one die busy at a time, Amdahl's law in its purest form —
    /// so this is what makes host threads earn their keep.
    busy: u64 = 0, // 0..100_000
    parallel: bool = true,
    /// Thread placement on asymmetric hosts (X3D): wall-clock only,
    /// results identical by construction.
    pin: cluster.PinPolicy = .none,
    trace: bool = false,
};

pub const Outcome = struct {
    reasons: []machine.StopReason, // caller frees
    passes: u64,
    busy_passes: u64,
    crossings: u64,
    cycles: u64,
    cycles_per_pass: u64,
    windows: u64,
    instructions: u64,
    plane: cluster.PlaneStats,
    finisher_is_origin: bool,
    exactly_one_finisher: bool,
    busy_rings_finished: bool,
    parallel: bool,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const d_count: u16 = @max(2, @min(16, opts.dies));
    const busy: u64 = @min(100_000, opts.busy);
    const cap: u16 = if (busy > 0) 100 else 200;
    const n: u16 = @max(2, @min(cap, opts.nodes));
    const laps: u64 = @max(1, @min(1000, opts.laps));
    const passes = @as(u64, d_count) * n * laps;
    const busy_passes = @as(u64, d_count) * n * busy;
    const crossings = @as(u64, d_count) * laps;
    const parallel = opts.parallel and !opts.trace;
    const ctxs: u16 = if (busy > 0) 2 * n else n;

    var cl = try cluster.Cluster.init(alloc, .{
        .dies = d_count,
        .die = .{
            .cores = 1,
            .contexts_per_core = @intCast(ctxs),
            .ram_size = 0x20000,
            .max_cycles = 80 * (passes + @as(u64, n) * busy) + 4000 * crossings + 1_000_000,
            .trace = opts.trace,
        },
        .plane = .{ .base_latency = 2000, .jitter = 500 },
        .parallel = parallel,
        .pin = opts.pin,
    });
    defer cl.deinit();

    var diag = asm6564.Diagnostic{};
    var prog = asm6564.assemble(alloc, node_src, &diag) catch |err| {
        std.debug.print("dies asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer prog.deinit();

    var buf8: [8]u8 = undefined;
    var die_i: u16 = 0;
    while (die_i < d_count) : (die_i += 1) {
        const m = cl.die(die_i);
        m.load(0, prog.origin, prog.code); // one code page per die, all actors
        cl.setRoute(die_i, 1, (die_i + 1) % d_count);
        var i: u16 = 0;
        while (i < ctxs) : (i += 1) {
            const ctx: u8 = @intCast(i);
            // Contexts 0..n-1 are this die's segment of the GLOBAL ring;
            // n..2n-1 (busy mode) are a die-local ring with its own token.
            const global = i < n;
            const last = global and i == n - 1;
            const next: u8 = if (last)
                0
            else if (global)
                @intCast(i + 1)
            else
                @intCast(n + (i - n + 1) % n);
            // PTT slot i → the next node: on this die for all but the
            // last global one, whose entry differs by one byte — the route.
            m.setPtt(0, i, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(0, next, ring.slot_rx),
                .route = if (last) 1 else 0,
                .rights = .{ .send = true },
                .token = 0x6564,
            });
            m.setRing(0, ctx, ring.slot_cq, .{
                .base = 0x8000 + 64 * @as(u64, i),
                .cap_log2 = 2,
                .entry_size = ring.cq_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 0,
                .token = 0,
            });
            m.setRing(0, ctx, ring.slot_rx, .{
                .base = 0x4000 + 64 * @as(u64, i),
                .cap_log2 = 1,
                .entry_size = ring.rx_entry_size,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .flags = ring.desc_flag_auto_repost,
                .head = 0,
                .tail = 0,
                .token = 0x6564,
            });
            var slot_i: u64 = 0;
            while (slot_i < 2) : (slot_i += 1) {
                const cell: u64 = 0xC000 + 16 * @as(u64, i) + 8 * slot_i;
                const entry = ring.RxEntry{ .buf = cell, .cap = 8, .filled = 0, .cookie = cell };
                var entry_bytes: [32]u8 = undefined;
                for (entry.pack(), 0..) |word, wi|
                    std.mem.writeInt(u64, entry_bytes[wi * 8 ..][0..8], word, .little);
                m.load(0, 0x4000 + 64 * @as(u64, i) + 32 * slot_i, &entry_bytes);
            }
            std.mem.writeInt(u64, &buf8, ring.windowAddr(i, 0), .little);
            m.writeNear(0, ctx, 0x840, &buf8);
            // Injectors go last: the global one (die 0, node 0) below, and
            // each die's local one (node n) after its ring is listening.
            const injector = (die_i == 0 and i == 0) or (busy > 0 and i == n);
            if (!injector) try m.spawn(0, ctx, 0x1000, 0x3000, 0);
        }
        if (busy > 0) try m.spawn(0, @intCast(n), 0x1000, 0x3000, @as(u64, n) * busy);
    }
    try cl.die(0).spawn(0, 0, 0x1000, 0x3000, passes);

    var out = try cl.run();
    errdefer out.deinit(alloc);

    var global_finishers: u32 = 0;
    var local_finishers: u32 = 0;
    var origin_finished = false;
    var max_clock: u64 = 0;
    var instructions: u64 = 0;
    die_i = 0;
    while (die_i < d_count) : (die_i += 1) {
        const m = cl.die(die_i);
        max_clock = @max(max_clock, m.cores[0].clock);
        instructions += m.stats.instructions;
        var i: u16 = 0;
        while (i < ctxs) : (i += 1) {
            const flag = std.mem.readInt(u64, m.cores[0].contexts[i].near[0x850..][0..8], .little);
            if (flag != 0) {
                if (i < n) global_finishers += 1 else local_finishers += 1;
                if (die_i == 0 and i == 0) origin_finished = true;
            }
        }
    }

    return .{
        .reasons = out.reasons,
        .passes = passes,
        .busy_passes = busy_passes,
        .crossings = crossings,
        .cycles = max_clock,
        .cycles_per_pass = max_clock / passes,
        .windows = out.windows,
        .instructions = instructions,
        .plane = out.plane,
        .finisher_is_origin = origin_finished,
        .exactly_one_finisher = global_finishers == 1,
        .busy_rings_finished = local_finishers == @as(u32, if (busy > 0) d_count else 0),
        .parallel = parallel,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    defer alloc.free(o.reasons);
    const d_count: u16 = @max(2, @min(16, opts.dies));
    const busy: u64 = @min(100_000, opts.busy);
    const cap: u16 = if (busy > 0) 100 else 200;
    const n: u16 = @max(2, @min(cap, opts.nodes));
    const laps: u64 = @max(1, @min(1000, opts.laps));
    const complete = o.exactly_one_finisher and o.finisher_is_origin and o.busy_rings_finished;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — Armstrong's ring across {d} dies ({s})
        \\  {d} nodes per die, {d} laps: {d} passes, {d} die crossings,
        \\  the SAME ring_node.asm — remoteness is one route byte in a PTT entry
        \\
        \\  outcome: {s}
        \\  {d} cycles total — {d} per pass including plane crossings
        \\  {d} conservative windows of 2000 cycles; {d} instructions
        \\  plane: {d} datagrams, {d} acks, {d} lost, {d} duplicated
        \\
    , .{
        d_count,
        if (o.parallel) "one host thread per die" else "sequential",
        n,
        laps,
        o.passes,
        o.crossings,
        if (complete) "the message came home" else "INCOMPLETE",
        o.cycles,
        o.cycles_per_pass,
        o.windows,
        o.instructions,
        o.plane.grams,
        o.plane.acks,
        o.plane.lost,
        o.plane.duplicated,
    });
    if (busy > 0) try stdout.print(
        \\  busy mode: each die also ran its own {d}-node ring for {d} laps —
        \\  {d} local passes keeping all {d} host threads hot
        \\
    , .{ n, busy, o.busy_passes, d_count });
    if (!complete) std.process.exit(1);
}
