//! Supervision tree demo (Phase 3): one supervisor, four workers on one
//! core, two ways to die.
//!
//! Worker 2 has a crash fuse — it BRKs every 5 items. Worker 4 has a hang
//! fuse — after 3 items it spins without yielding, the failure mode
//! cooperative scheduling can't reach on its own; its watchdog (spec §5.4)
//! force-faults it so the exit link can speak. Either way the supervisor
//! sees one exit completion and answers with SPWN, spending that child's own
//! restart budget; work accumulates in RAM across incarnations. Budgets run
//! out; the unreliable are abandoned, honestly.
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

const n_workers = 4;
const quota = 12; // items each worker owes
const crash_fuse = 5; // worker 2 BRKs after this many items
const hang_fuse = 3; // worker 4 stops yielding after this many items
const watchdog_cycles = 500; // burst budget for every worker
const budgets = [n_workers + 1]u64{ 0, 0, 3, 0, 2 }; // per-child restarts

const progress_base: u64 = 0x2700; // + 8*ctx
const restarts_addr: u64 = 0x2780;
const config_base: u64 = 0x2800; // + 32*ctx

pub const Outcome = struct {
    reason: machine.StopReason,
    progress: [n_workers + 1]u64, // indexed by ctx id; [0] unused
    restarts: u64,
    watchdog_trips: u64,
    supervisor_halted: bool,
    crasher_state: machine.CtxState,
    hanger_state: machine.CtxState,
    hanger_fault: machine.Fault,
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

    // Supervisor near page: alive count, spawn blocks, per-child budgets.
    var w: [8]u8 = undefined;
    std.mem.writeInt(u64, &w, n_workers, .little);
    m.writeNear(0, 0, 0x860, &w);

    var ctx: u8 = 1;
    while (ctx <= n_workers) : (ctx += 1) {
        const cfg_addr = config_base + 32 * @as(u64, ctx);
        const sp = 0x3000 + 0x400 * @as(u64, ctx);

        // Worker config block in RAM: {progress cell, crash fuse, quota,
        // hang fuse}.
        var cfg: [32]u8 = undefined;
        std.mem.writeInt(u64, cfg[0..8], progress_base + 8 * @as(u64, ctx), .little);
        std.mem.writeInt(u64, cfg[8..16], if (ctx == 2) crash_fuse else 0, .little);
        std.mem.writeInt(u64, cfg[16..24], quota, .little);
        std.mem.writeInt(u64, cfg[24..32], if (ctx == 4) hang_fuse else 0, .little);
        m.load(0, cfg_addr, &cfg);

        // Spawn block in the supervisor's near page: {ctx, entry, sp, arg}.
        var blk: [32]u8 = undefined;
        std.mem.writeInt(u64, blk[0..8], ctx, .little);
        std.mem.writeInt(u64, blk[8..16], 0x1200, .little);
        std.mem.writeInt(u64, blk[16..24], sp, .little);
        std.mem.writeInt(u64, blk[24..32], cfg_addr, .little);
        m.writeNear(0, 0, @intCast(0x900 + 32 * @as(u16, ctx)), &blk);

        // This child's restart budget.
        std.mem.writeInt(u64, &w, budgets[ctx], .little);
        m.writeNear(0, 0, @intCast(0xA00 + 8 * @as(u16, ctx)), &w);

        // Exit link and watchdog: obituaries to the supervisor's CQ, and a
        // burst budget so even a hang produces one.
        m.linkSupervisor(0, ctx, 0, ring.slot_cq);
        m.setWatchdog(0, ctx, watchdog_cycles);
        try m.spawn(0, ctx, 0x1200, sp, cfg_addr);
    }
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();

    var out = Outcome{
        .reason = reason,
        .progress = undefined,
        .restarts = std.mem.readInt(u64, m.cores[0].ram[restarts_addr - machine.ram_base ..][0..8], .little),
        .watchdog_trips = m.stats.watchdog_trips,
        .supervisor_halted = m.cores[0].contexts[0].state == .halted,
        .crasher_state = m.cores[0].contexts[2].state,
        .hanger_state = m.cores[0].contexts[4].state,
        .hanger_fault = m.cores[0].contexts[4].fault,
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
        \\sim6564 — supervision tree: 1 supervisor, 4 workers, 1 core
        \\  worker 2 BRKs every {d} items (budget {d}); worker 4 stops yielding
        \\  after {d} items and only its {d}-cycle watchdog can tell (budget {d})
        \\
        \\  worker 1 (reliable): {d}/{d} items, clean exit
        \\  worker 2 (crasher):  {d} items across {d} incarnations, abandoned ({s})
        \\  worker 3 (reliable): {d}/{d} items, clean exit
        \\  worker 4 (hanger):   {d} items across {d} incarnations, abandoned ({s}/{s})
        \\  supervisor: {d} restarts issued, {d} watchdog trips, {s}
        \\
        \\  outcome: {s} — the unreliable stay down only because budgets say so
        \\  cycles {d}, instructions {d}
        \\
    , .{
        crash_fuse,                                                    budgets[2],
        hang_fuse,                                                     watchdog_cycles,
        budgets[4],                                                    o.progress[1],
        quota,                                                         o.progress[2],
        budgets[2] + 1,                                                @tagName(o.crasher_state),
        o.progress[3],                                                 quota,
        o.progress[4],                                                 budgets[4] + 1,
        @tagName(o.hanger_state),                                      @tagName(o.hanger_fault),
        o.restarts,                                                    o.watchdog_trips,
        if (o.supervisor_halted) "halted clean" else "DID NOT FINISH", @tagName(o.reason),
        o.cycles,                                                      o.instructions,
    });
    if (!o.supervisor_halted) std.process.exit(1);
}
