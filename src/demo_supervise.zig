//! Supervision tree demo (Phase 3): one supervisor, three workers on one
//! core. Worker 2 has a fuse — it crashes every 5 items. Exit links tell the
//! supervisor; SPWN resurrects the worker with fresh registers (its progress
//! cell in RAM survives, so work accumulates across incarnations). The
//! restart budget runs out eventually and the crasher is abandoned, honestly.
//!
//! Programs: programs/supervisor.asm, programs/worker.asm (one program, N
//! workers — shared read-only code, distinct config blocks).

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const supervisor_src = @embedFile("programs/supervisor.asm");
const worker_src = @embedFile("programs/worker.asm");

pub const Options = struct {
    trace: bool = false,
};

const n_workers = 3;
const quota = 12; // items each worker owes
const fuse = 5; // worker 2 crashes after this many items
const budget = 3; // supervisor's restart budget

const progress_base: u64 = 0x2700; // + 8*ctx
const restarts_addr: u64 = 0x2780;
const config_base: u64 = 0x2800; // + 32*ctx

pub const Outcome = struct {
    reason: machine.StopReason,
    progress: [n_workers + 1]u64, // indexed by ctx id; [0] unused
    restarts: u64,
    supervisor_halted: bool,
    flaky_state: machine.CtxState,
    cycles: u64,
    instructions: u64,
};

/// Build, run, and measure — shared by the CLI demo and the test suite.
pub fn simulate(alloc: std.mem.Allocator, trace: bool) !Outcome {
    var m = try machine.Machine.init(alloc, .{
        .cores = 1,
        .contexts_per_core = n_workers + 1,
        .ram_size = 0x8000,
        .trace = trace,
    });
    defer m.deinit();

    var diag = asm6564.Diagnostic{};
    inline for (.{ .{ supervisor_src, "supervisor" }, .{ worker_src, "worker" } }) |spec| {
        var out = asm6564.assemble(alloc, spec[0], &diag) catch |err| {
            std.debug.print("{s}: asm error line {d}: {s}\n", .{ spec[1], diag.line, diag.message });
            return err;
        };
        defer out.deinit();
        m.load(0, out.origin, out.code);
    }

    // Supervisor CQ: descriptor slot 1, ring storage at $2080, cap 16.
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2080,
        .cap_log2 = 4,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });

    // Supervisor near page: alive count, restart budget, spawn-block table.
    var w: [8]u8 = undefined;
    std.mem.writeInt(u64, &w, n_workers, .little);
    m.writeNear(0, 0, 0x860, &w);
    std.mem.writeInt(u64, &w, budget, .little);
    m.writeNear(0, 0, 0x868, &w);

    var ctx: u8 = 1;
    while (ctx <= n_workers) : (ctx += 1) {
        const cfg_addr = config_base + 32 * @as(u64, ctx);
        const sp = 0x3000 + 0x400 * @as(u64, ctx);

        // Worker config block in RAM: {progress cell, fuse, quota}.
        var cfg: [24]u8 = undefined;
        std.mem.writeInt(u64, cfg[0..8], progress_base + 8 * @as(u64, ctx), .little);
        std.mem.writeInt(u64, cfg[8..16], if (ctx == 2) fuse else 0, .little);
        std.mem.writeInt(u64, cfg[16..24], quota, .little);
        m.load(0, cfg_addr, &cfg);

        // Spawn block in the supervisor's near page: {ctx, entry, sp, arg}.
        var blk: [32]u8 = undefined;
        std.mem.writeInt(u64, blk[0..8], ctx, .little);
        std.mem.writeInt(u64, blk[8..16], 0x1200, .little);
        std.mem.writeInt(u64, blk[16..24], sp, .little);
        std.mem.writeInt(u64, blk[24..32], cfg_addr, .little);
        m.writeNear(0, 0, @intCast(0x900 + 32 * @as(u16, ctx)), &blk);

        // Exit link: this child's obituaries go to the supervisor's CQ.
        m.linkSupervisor(0, ctx, 0, ring.slot_cq);
        try m.spawn(0, ctx, 0x1200, sp, cfg_addr);
    }
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();

    var out = Outcome{
        .reason = reason,
        .progress = undefined,
        .restarts = std.mem.readInt(u64, m.cores[0].ram[restarts_addr - machine.ram_base ..][0..8], .little),
        .supervisor_halted = m.cores[0].contexts[0].state == .halted,
        .flaky_state = m.cores[0].contexts[2].state,
        .cycles = m.cores[0].clock,
        .instructions = m.stats.instructions,
    };
    out.progress[0] = 0;
    for (1..n_workers + 1) |c| {
        const addr = progress_base + 8 * @as(u64, @intCast(c));
        out.progress[c] = std.mem.readInt(u64, m.cores[0].ram[addr - machine.ram_base ..][0..8], .little);
    }
    return out;
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts.trace);

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — supervision tree: 1 supervisor, 3 workers, 1 core
        \\  worker 2 crashes every {d} items (BRK); restart budget {d}; quota {d}
        \\
        \\  worker 1 (reliable): {d}/{d} items, clean exit
        \\  worker 2 (flaky):    {d} items across {d} incarnations, then abandoned ({s})
        \\  worker 3 (reliable): {d}/{d} items, clean exit
        \\  supervisor: {d} restarts issued, {s}
        \\
        \\  outcome: {s} — the crasher stays down only because the budget says so
        \\  cycles {d}, instructions {d}
        \\
    , .{
        fuse,               budget,
        quota,              o.progress[1],
        quota,              o.progress[2],
        o.restarts + 1,     @tagName(o.flaky_state),
        o.progress[3],      quota,
        o.restarts,         if (o.supervisor_halted) "halted clean" else "DID NOT FINISH",
        @tagName(o.reason), o.cycles,
        o.instructions,
    });
    if (!o.supervisor_halted) std.process.exit(1);
}
