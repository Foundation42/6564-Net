//! The cache-footprint experiment (programs/mem_churn.asm): D dies, each
//! visiting every line of a multi-MB stripe in LFSR order — a shuffle
//! the host's prefetchers cannot predict (a linear stride measured
//! nothing; see the ledger). No messaging — this workload exists to
//! give thread placement on an asymmetric host (X3D: 96 MB V-cache CCD
//! vs 32 MB frequency CCD) something to disagree about: at 8 dies x 8 MB
//! the cluster's live working set is 64 MB, which swims in the big L3
//! and thrashes the small one. Placement changes seconds, never bits.
//!
//! Stripe sizes are the ones with two-tap maximal LFSRs over their line
//! count: 2, 8, 16 or 64 MB. The plane is idle by design; its base
//! latency is raised so windows are wide and barrier overhead stays out
//! of the measurement.

const std = @import("std");
const machine = @import("machine.zig");
const cluster = @import("cluster.zig");
const asm6564 = @import("asm.zig");

const churn_src = @embedFile("programs/mem_churn.asm");

const stripe_base: u64 = 0x10000;

/// Supported stripe sizes and their LFSR taps: (n, k) two-tap maximal
/// polynomials over n = log2(lines), poly = 1<<(n-1) | 1<<(k-1).
const StripeCfg = struct { mb: u64, poly: u64 };
const stripes = [_]StripeCfg{
    .{ .mb = 2, .poly = (1 << 14) | (1 << 13) }, // 2^15 lines: (15,14)
    .{ .mb = 8, .poly = (1 << 16) | (1 << 13) }, // 2^17 lines: (17,14)
    .{ .mb = 16, .poly = (1 << 17) | (1 << 10) }, // 2^18 lines: (18,11)
    .{ .mb = 64, .poly = (1 << 19) | (1 << 16) }, // 2^20 lines: (20,17)
};

fn pickStripe(mb: u64) StripeCfg {
    var best = stripes[0];
    for (stripes) |s| {
        if (s.mb <= mb) best = s;
    }
    return best;
}

pub const Options = struct {
    dies: u16 = 8, // 1..16
    stripe_mb: u64 = 8, // rounded down to {2, 8, 16, 64}
    sweeps: u64 = 12, // 1..1000
    parallel: bool = true,
    pin: cluster.PinPolicy = .none,
    trace: bool = false,
};

pub const Outcome = struct {
    reasons: []machine.StopReason,
    die_stats: []cluster.DieStat,
    verified: bool,
    footprint_mb: u64,
    cycles: u64,
    windows: u64,
    plane: cluster.PlaneStats,
    parallel: bool,

    pub fn deinit(self: *const Outcome, alloc: std.mem.Allocator) void {
        alloc.free(self.reasons);
        alloc.free(self.die_stats);
    }
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const d_count: u16 = @max(1, @min(16, opts.dies));
    const cfg = pickStripe(@max(2, @min(64, opts.stripe_mb)));
    const mb = cfg.mb;
    const sweeps: u64 = @max(1, @min(1000, opts.sweeps));
    const stripe = mb << 20;
    const lines = stripe / 64;

    var cl = try cluster.Cluster.init(alloc, .{
        .dies = d_count,
        .die = .{
            .cores = 1,
            .contexts_per_core = 1,
            .ram_size = @intCast(stripe_base + stripe),
            .max_cycles = 80 * lines * sweeps + 1_000_000,
            .trace = opts.trace,
        },
        // No traffic crosses; wide windows keep barriers off the clock.
        .plane = .{ .base_latency = 100_000, .jitter = 0 },
        .parallel = opts.parallel and !opts.trace,
        .pin = opts.pin,
    });
    defer cl.deinit();

    var diag = asm6564.Diagnostic{};
    var prog = asm6564.assemble(alloc, churn_src, &diag) catch |err| {
        std.debug.print("churn asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer prog.deinit();

    var w8: [8]u8 = undefined;
    var die_i: u16 = 0;
    while (die_i < d_count) : (die_i += 1) {
        const m = cl.die(die_i);
        m.load(0, prog.origin, prog.code);
        std.mem.writeInt(u64, &w8, stripe_base, .little);
        m.writeNear(0, 0, 0x840, &w8);
        std.mem.writeInt(u64, &w8, cfg.poly, .little);
        m.writeNear(0, 0, 0x848, &w8);
        std.mem.writeInt(u64, &w8, lines - 1, .little);
        m.writeNear(0, 0, 0x868, &w8);
        try m.spawn(0, 0, 0x1000, 0x3000, sweeps);
    }

    var out = try cl.run();
    errdefer out.deinit(alloc);
    const die_stats = try cluster.snapshot(cl, alloc);
    errdefer alloc.free(die_stats);

    // The LFSR visits every line except line 0 (its fixed point) exactly
    // once per sweep: line 1 and the last line hold `sweeps`, line 0
    // holds zero. Spot-check all three on every die.
    var verified = true;
    var max_clock: u64 = 0;
    die_i = 0;
    while (die_i < d_count) : (die_i += 1) {
        const ram = cl.die(die_i).cores[0].ram;
        const cell = struct {
            fn at(r: []u8, addr: u64) u64 {
                return std.mem.readInt(u64, r[addr - machine.ram_base ..][0..8], .little);
            }
        }.at;
        if (cell(ram, stripe_base) != 0) verified = false;
        if (cell(ram, stripe_base + 64) != sweeps) verified = false;
        if (cell(ram, stripe_base + stripe - 64) != sweeps) verified = false;
        if (out.reasons[die_i] != .all_halted) verified = false;
        max_clock = @max(max_clock, cl.die(die_i).cores[0].clock);
    }

    return .{
        .reasons = out.reasons,
        .die_stats = die_stats,
        .verified = verified,
        .footprint_mb = mb * d_count,
        .cycles = max_clock,
        .windows = out.windows,
        .plane = out.plane,
        .parallel = opts.parallel and !opts.trace,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    defer o.deinit(alloc);
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — memory churn: {d} dies x {d} MB stripes ({s}, pin {s})
        \\  {d} MB of live working set, LFSR-order RMW, {d} sweeps
        \\
        \\  outcome: {s} — {d} cycles, {d} windows
        \\
    , .{
        @max(1, @min(16, opts.dies)),
        pickStripe(@max(2, @min(64, opts.stripe_mb))).mb,
        if (o.parallel) "one host thread per die" else "sequential",
        @tagName(opts.pin),
        o.footprint_mb,
        @max(1, @min(1000, opts.sweeps)),
        if (o.verified) "verified, every cell counted" else "MISMATCH",
        o.cycles,
        o.windows,
    });
    try stdout.print("\n", .{});
    try cluster.writeStatsTable(stdout, o.die_stats, o.plane);
    if (!o.verified) std.process.exit(1);
}
