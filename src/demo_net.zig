//! Armstrong's ring across HOST PROCESSES (spec §6.5 over a real
//! socket): each process runs a Cluster of dies; the bridge carries
//! window barriers over TCP. Still the same unmodified ring_node.asm,
//! still one route byte per crossing — and still bit-identical replay
//! from the seeds, because frames carry virtual time and the wall clock
//! never enters the machine. TCP is just a slow backplane.
//!
//! Topology: listener owns global dies [0, D), connector [256, 256+D).
//! The global ring runs through all 2D dies; each process has exactly
//! one PTT entry whose route leads off-node. The listener injects and
//! the token comes home to its die 0, node 0.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const cluster = @import("cluster.zig");
const bridge = @import("bridge.zig");
const asm6564 = @import("asm.zig");

const node_src = @embedFile("programs/asm/ring_node.asm");

pub const connector_base: u16 = 256;

pub const Role = enum { listener, connector };

pub const Options = struct {
    role: Role,
    host: []const u8 = "127.0.0.1",
    port: u16 = 6564,
    dies: u16 = 2, // per process, 1..16
    nodes: u16 = 20, // per die, 2..200
    laps: u64 = 5, // 1..1000
    parallel: bool = true,
    trace: bool = false,
};

pub const Outcome = struct {
    reasons: []machine.StopReason,
    die_stats: []cluster.DieStat,
    passes: u64,
    crossings: u64,
    cycles: u64,
    windows: u64,
    plane: cluster.PlaneStats,
    /// Did the token finish on THIS process (listener die 0, node 0)?
    finished_here: bool,

    pub fn deinit(self: *const Outcome, alloc: std.mem.Allocator) void {
        alloc.free(self.reasons);
        alloc.free(self.die_stats);
    }
};

/// Run one node of the federation over an established bridge. The test
/// suite drives this directly on two threads; the CLI wraps it with the
/// listen/connect handshake below.
pub fn simulate(alloc: std.mem.Allocator, opts: Options, br: *bridge.Bridge) !Outcome {
    const d_count: u16 = @max(1, @min(16, opts.dies));
    const n: u16 = @max(2, @min(200, opts.nodes));
    const laps: u64 = @max(1, @min(1000, opts.laps));
    const passes = 2 * @as(u64, d_count) * n * laps;
    const crossings = 2 * @as(u64, d_count) * laps;
    const my_base: u16 = if (opts.role == .listener) 0 else connector_base;
    const peer_base: u16 = if (opts.role == .listener) connector_base else 0;

    var cl = try cluster.Cluster.init(alloc, .{
        .dies = d_count,
        .die = .{
            .cores = 1,
            .contexts_per_core = @intCast(n),
            .ram_size = 0x20000,
            .max_cycles = 80 * passes + 4000 * crossings + 1_000_000,
            .trace = opts.trace,
        },
        .plane = .{ .base_latency = 2000, .jitter = 500 },
        .parallel = opts.parallel and !opts.trace,
        .node_base = my_base,
    });
    defer cl.deinit();

    var diag = asm6564.Diagnostic{};
    var prog = asm6564.assemble(alloc, node_src, &diag) catch |err| {
        std.debug.print("net asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer prog.deinit();

    var buf8: [8]u8 = undefined;
    var die_i: u16 = 0;
    while (die_i < d_count) : (die_i += 1) {
        const m = cl.die(die_i);
        m.load(0, prog.origin, prog.code);
        // Route 1 from each die: the next die of the global ring — local
        // for all but the last, which leaves the process entirely.
        if (die_i + 1 < d_count) {
            cl.setRoute(die_i, 1, die_i + 1);
        } else {
            cl.setRemoteRoute(die_i, 1, peer_base);
        }
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            const ctx: u8 = @intCast(i);
            const last = i == n - 1;
            m.setPtt(0, i, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(0, if (last) 0 else @intCast(i + 1), ring.slot_rx),
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
            if (!(opts.role == .listener and die_i == 0 and i == 0))
                try m.spawn(0, ctx, 0x1000, 0x3000, 0);
        }
    }
    if (opts.role == .listener)
        try cl.die(0).spawn(0, 0, 0x1000, 0x3000, passes);

    try br.hello(cl);
    cl.exchange = br.exchange();
    var out = try cl.run();
    errdefer out.deinit(alloc);
    const die_stats = try cluster.snapshot(cl, alloc);
    errdefer alloc.free(die_stats);

    var finished = false;
    var max_clock: u64 = 0;
    die_i = 0;
    while (die_i < d_count) : (die_i += 1) {
        const m = cl.die(die_i);
        max_clock = @max(max_clock, m.cores[0].clock);
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            const flag = std.mem.readInt(u64, m.cores[0].contexts[i].near[0x850..][0..8], .little);
            if (flag != 0 and die_i == 0 and i == 0) finished = true;
        }
    }

    return .{
        .reasons = out.reasons,
        .die_stats = die_stats,
        .passes = passes,
        .crossings = crossings,
        .cycles = max_clock,
        .windows = out.windows,
        .plane = out.plane,
        .finished_here = finished and opts.role == .listener,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const stdout = std.io.getStdOut().writer();
    var br = switch (opts.role) {
        .listener => blk: {
            try stdout.print("sim6564 net — listening on port {d}…\n", .{opts.port});
            break :blk try bridge.Bridge.listen(opts.port);
        },
        .connector => blk: {
            try stdout.print("sim6564 net — connecting to {s}:{d}…\n", .{ opts.host, opts.port });
            var tries: u32 = 0;
            while (true) {
                const b = bridge.Bridge.connect(opts.host, opts.port) catch |err| {
                    tries += 1;
                    if (tries > 50) return err;
                    std.time.sleep(100 * std.time.ns_per_ms);
                    continue;
                };
                break :blk b;
            }
        },
    };
    defer br.deinit();

    const o = try simulate(alloc, opts, &br);
    defer o.deinit(alloc);
    const ok = o.finished_here or opts.role == .connector;
    try stdout.print(
        \\sim6564 — the ring across two PROCESSES ({s}, dies {d}x2, {d} nodes/die)
        \\  {d} passes, {d} socket crossings; virtual time on the wire,
        \\  wall clock never in the machine
        \\
        \\  outcome: {s} — {d} cycles, {d} lock-step windows
        \\
    , .{
        @tagName(opts.role),
        @max(1, @min(16, opts.dies)),
        @max(2, @min(200, opts.nodes)),
        o.passes,
        o.crossings,
        if (o.finished_here) "the message came home HERE" else "served my half of the ring",
        o.cycles,
        o.windows,
    });
    try cluster.writeStatsTable(stdout, o.die_stats, o.plane);
    if (!ok) std.process.exit(1);
}
