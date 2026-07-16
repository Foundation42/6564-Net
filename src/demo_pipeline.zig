//! Pipeline dataflow demo (Phase 3): source → n transform stages → sink,
//! one core per node, every hop crossing the fault-injected fabric.
//!
//! Each hop runs stop-and-wait on application acks with dedup-by-sequence;
//! a stage acks upstream when it takes *ownership* of an item, so hops
//! overlap — throughput is set by the slowest hop's round trip, not the
//! pipeline depth. Backpressure is the absence of an ack. Shutdown is a
//! poison-pill DONE item; the sink is immortal so two-generals can't wedge
//! the last hop.
//!
//! Programs: programs/pipe_source.asm, pipe_stage.asm, pipe_sink.asm.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const source_src = @embedFile("programs/pipe_source.asm");
const stage_src = @embedFile("programs/pipe_stage.asm");
const sink_src = @embedFile("programs/pipe_sink.asm");

pub const Options = struct {
    seed: u64 = 0x6564,
    loss_ppm4k: u16 = 1024,
    items: u64 = 16,
    stages: u16 = 2,
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    consumed: u64, // sink's E: items + DONE = K+1 when complete
    checksum: u64,
    expected_checksum: u64,
    verify_errors: u64,
    retransmissions: u64,
    source_halted: bool,
    stages_done: bool, // every stage reached lame-duck phase (2)
    cycles: u64,
    stats: machine.Stats,
};

fn wireNode(m: *machine.Machine, core: u16) void {
    const mk = struct {
        fn desc(base: u64, cap_log2: u5, entry: u16, token: u64) ring.Desc {
            return .{
                .base = base,
                .cap_log2 = cap_log2,
                .entry_size = entry,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .head = 0,
                .tail = 0,
                .token = token,
            };
        }
    }.desc;
    // CQ storage is $2000..$21FF (32 × 16 B) — RX ring storage lives at
    // $2A00/$2A40, clear of it. (The first draft overlapped them; completion
    // records overwrote the staged RX entries once the CQ wrapped. Memory
    // maps: the oldest bug there is.)
    m.setRing(core, 0, ring.slot_sq, mk(0x2400, 0, ring.sq_entry_size, 0)); // items out
    m.setRing(core, 0, ring.slot_cq, mk(0x2000, 5, ring.cq_entry_size, 0));
    m.setRing(core, 0, ring.slot_rx, mk(0x2A00, 0, ring.rx_entry_size, 0x6564)); // items in
    m.setRing(core, 0, 3, mk(0x2A40, 0, ring.rx_entry_size, 0x6564)); // acks in
    m.setRing(core, 0, 4, mk(0x2440, 0, ring.sq_entry_size, 0)); // acks out
}

/// Build, run, and measure — shared by the CLI demo and the test suite.
pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const n = opts.stages;
    const k = opts.items;
    const cores: u16 = n + 2; // source, stages, sink

    var m = try machine.Machine.init(alloc, .{
        .cores = cores,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .seed = opts.seed,
        .link = .{
            .base_latency = 200,
            .jitter = 120,
            .loss_ppm4k = opts.loss_ppm4k,
            .dup_ppm4k = 128,
            .send_timeout = 2500,
        },
        .max_cycles = 50_000_000,
        .trace = opts.trace,
    });
    defer m.deinit();

    var diag = asm6564.Diagnostic{};
    var programs: [3]asm6564.Output = undefined;
    inline for (.{ source_src, stage_src, sink_src }, 0..) |src, i| {
        programs[i] = asm6564.assemble(alloc, src, &diag) catch |err| {
            std.debug.print("pipeline asm error line {d}: {s}\n", .{ diag.line, diag.message });
            return err;
        };
    }
    defer for (&programs) |*p| p.deinit();

    var core: u16 = 0;
    while (core < cores) : (core += 1) {
        wireNode(&m, core);
        const prog = if (core == 0) &programs[0] else if (core == cores - 1) &programs[2] else &programs[1];
        m.load(core, prog.origin, prog.code);

        // Everyone learns K; the sink also learns the stage count.
        var w: [8]u8 = undefined;
        std.mem.writeInt(u64, &w, k, .little);
        m.load(core, 0x2600, &w);
        if (core == cores - 1) {
            std.mem.writeInt(u64, &w, n, .little);
            m.load(core, 0x2608, &w);
        }

        // PTT 0: items to the next hop. PTT 1: the timer black hole.
        if (core < cores - 1) {
            m.setPtt(core, 0, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(core + 1, 0, ring.slot_rx),
                .rights = .{ .send = true },
                .token = 0x6564,
            });
            m.setPtt(core, 1, .{
                .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
                .rights = .{ .send = true },
                .token = 0,
            });
        }
        // PTT 2: acks to the previous hop's ack ring (slot 3).
        if (core > 0) {
            m.setPtt(core, 2, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(core - 1, 0, 3),
                .rights = .{ .send = true },
                .token = 0x6564,
            });
        }
        try m.spawn(core, 0, 0x1000, 0x3000, 0);
    }

    const reason = try m.run();

    const sink = &m.cores[cores - 1].contexts[0];
    var retrans = std.mem.readInt(u64, m.cores[0].contexts[0].near[0x818..][0..8], .little);
    var stages_done = true;
    core = 1;
    while (core < cores - 1) : (core += 1) {
        const ctx = &m.cores[core].contexts[0];
        retrans += std.mem.readInt(u64, ctx.near[0x8D0..][0..8], .little);
        if (std.mem.readInt(u64, ctx.near[0x8B8..][0..8], .little) != 2) stages_done = false;
    }
    var max_clock: u64 = 0;
    for (m.cores) |*c| max_clock = @max(max_clock, c.clock);

    // Σ ((s+1)·2^n − 1) for s in 0..K−1.
    const pow: u64 = @as(u64, 1) << @intCast(n);
    const expected = pow * (k * (k + 1) / 2) - k;

    return .{
        .reason = reason,
        .consumed = std.mem.readInt(u64, sink.near[0x880..][0..8], .little),
        .checksum = std.mem.readInt(u64, sink.near[0x8C0..][0..8], .little),
        .expected_checksum = expected,
        .verify_errors = std.mem.readInt(u64, sink.near[0x8C8..][0..8], .little),
        .retransmissions = retrans,
        .source_halted = m.cores[0].contexts[0].state == .halted,
        .stages_done = stages_done,
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);

    const complete = o.consumed == opts.items + 1 and o.verify_errors == 0 and
        o.checksum == o.expected_checksum and o.source_halted and o.stages_done;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — pipeline dataflow: source → {d} stages → sink, {d} cores
        \\  seed 0x{X}, loss {d}/4096 ({d:.1}%), dup 128/4096, {d} items
        \\  per hop: stop-and-wait on app acks, dedup by seq, ack-on-ownership
        \\
        \\  sink consumed {d}/{d} (items + DONE), checksum 0x{X} {s}
        \\  verify errors {d}, retransmissions {d}
        \\  source {s}, stages {s}, sink parked immortal
        \\
        \\  outcome: {s}{s}
        \\  cycles {d} ({d} per item end-to-end), instructions {d}
        \\  fabric: {d} sends ({d} timer ticks), {d} delivered, {d} lost,
        \\          {d} duplicated, {d} timeouts, {d} rejects
        \\
    , .{
        opts.stages,                                               opts.stages + 2,
        opts.seed,                                                 opts.loss_ppm4k,
        @as(f64, @floatFromInt(opts.loss_ppm4k)) * 100.0 / 4096.0, opts.items,
        o.consumed,                                                opts.items + 1,
        o.checksum,                                                if (o.checksum == o.expected_checksum) "(verified)" else "(MISMATCH)",
        o.verify_errors,                                           o.retransmissions,
        if (o.source_halted) "halted" else "STUCK",                if (o.stages_done) "lame-duck (serving re-acks)" else "STUCK",
        @tagName(o.reason),                                        if (complete) " — every item transformed, delivered, verified" else " — INCOMPLETE",
        o.cycles,                                                  if (opts.items == 0) 0 else o.cycles / opts.items,
        o.stats.instructions,                                      o.stats.sends,
        o.stats.unroutable,                                        o.stats.delivered,
        o.stats.lost,                                              o.stats.duplicated,
        o.stats.timeouts,                                          o.stats.rejects,
    });
    if (!complete) std.process.exit(1);
}
