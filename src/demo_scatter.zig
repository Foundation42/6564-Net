//! Scatter-gather demo (Phase 3 closer): a coordinator fans {id, value}
//! tasks out to W workers across the lossy fabric, workers square the value
//! (shift-add multiply), and the coordinator gathers the W results into a
//! sum — retrying stragglers from its timer until every worker has answered.
//! Request-response needs no ack machinery: the result is the ack, and
//! workers are idempotent.
//!
//! New coverage: fan-in through a capacity-8 RX ring with eight posted
//! landing buffers, each carrying its own address as its completion cookie.
//!
//! Programs: programs/asm/scatter_coord.asm, programs/asm/scatter_worker.asm.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const coord_src = @embedFile("programs/asm/scatter_coord.asm");
const worker_src = @embedFile("programs/asm/scatter_worker.asm");

pub const Options = struct {
    seed: u64 = 0x6564,
    loss_ppm4k: u16 = 1024,
    workers: u16 = 6, // 1..8 (result ring capacity)
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    gathered: u64,
    sum: u64,
    expected_sum: u64,
    scatter_sends: u64,
    served_total: u64, // Σ worker served counts; > gathered means duplicates
    coordinator_halted: bool,
    cycles: u64,
    stats: machine.Stats,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const w: u16 = @max(1, @min(8, opts.workers));
    const cores: u16 = w + 1;

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
    var coord = asm6564.assemble(alloc, coord_src, &diag) catch |err| {
        std.debug.print("scatter asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer coord.deinit();
    var worker = asm6564.assemble(alloc, worker_src, &diag) catch |err| {
        std.debug.print("scatter asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer worker.deinit();

    const mk = struct {
        fn desc(base: u64, cap_log2: u5, entry: u16, token: u64, flags: u8) ring.Desc {
            return .{
                .base = base,
                .cap_log2 = cap_log2,
                .entry_size = entry,
                .watermark = 0,
                .companion_cq = ring.slot_cq,
                .flags = flags,
                .head = 0,
                .tail = 0,
                .token = token,
            };
        }
    }.desc;

    // ── Coordinator (core 0) ─────────────────────────────────────────────
    m.load(0, coord.origin, coord.code);
    m.setRing(0, 0, ring.slot_sq, mk(0x2400, 0, ring.sq_entry_size, 0, 0));
    m.setRing(0, 0, ring.slot_cq, mk(0x2000, 5, ring.cq_entry_size, 0, 0));
    m.setRing(0, 0, ring.slot_rx, mk(0x2A00, 3, ring.rx_entry_size, 0x6564, ring.desc_flag_auto_repost)); // cap 8
    m.setRing(0, 0, 5, mk(0x2480, 0, ring.sq_entry_size, 0, 0)); // timer
    // Timer black hole at PTT 0; workers at PTT 1..W.
    m.setPtt(0, 0, .{
        .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });

    var expected: u64 = 0;
    var idx: u16 = 1;
    var buf8: [8]u8 = undefined;
    while (idx <= w) : (idx += 1) {
        m.setPtt(0, idx, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(idx, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
        // Fan-out chain: worker 1's entry is the ring-staged head at
        // $2400; workers 2..W are LINK-chained near-page entries at
        // $C00+32(j−1). Each entry carries its own payload buffer.
        {
            const payload_addr: u64 = 0x2280 + 16 * @as(u64, idx - 1);
            var payload: [16]u8 = undefined;
            std.mem.writeInt(u64, payload[0..8], idx, .little);
            std.mem.writeInt(u64, payload[8..16], idx + 3, .little);
            m.load(0, payload_addr, &payload);
            const has_next = idx < w;
            const entry = ring.SqEntry{
                .op = .send,
                .flags = if (has_next) ring.SqEntry.flag_link else 0,
                .link = if (has_next) @intCast(0xC00 + 32 * @as(u16, idx)) else 0,
                .target = ring.windowAddr(idx, 0),
                .buf = payload_addr,
                .len = 16,
                .cookie_lo = idx,
            };
            var entry_bytes: [32]u8 = undefined;
            for (entry.pack(), 0..) |word, wi|
                std.mem.writeInt(u64, entry_bytes[wi * 8 ..][0..8], word, .little);
            if (idx == 1) {
                m.load(0, 0x2400, &entry_bytes); // the head, in the SQ ring
            } else {
                m.writeNear(0, 0, @intCast(0xC00 + 32 * @as(u16, idx - 1)), &entry_bytes);
            }
        }
        // Worker window pointer and task value tables in the near page.
        std.mem.writeInt(u64, &buf8, ring.windowAddr(idx, 0), .little);
        m.writeNear(0, 0, @intCast(0xA00 + 8 * idx), &buf8);
        const value: u64 = idx + 3;
        std.mem.writeInt(u64, &buf8, value, .little);
        m.writeNear(0, 0, @intCast(0xB00 + 8 * idx), &buf8);
        expected += value * value;
        // Result landing entry i-1: buffer $2C00+64(i-1), cookie = address.
        const buf_addr: u64 = 0x2C00 + 64 * @as(u64, idx - 1);
        const entry = ring.RxEntry{ .buf = buf_addr, .cap = 64, .filled = 0, .cookie = buf_addr };
        var entry_bytes: [32]u8 = undefined;
        for (entry.pack(), 0..) |word, wi|
            std.mem.writeInt(u64, entry_bytes[wi * 8 ..][0..8], word, .little);
        m.load(0, 0x2A00 + 32 * @as(u64, idx - 1), &entry_bytes);
    }
    std.mem.writeInt(u64, &buf8, w, .little);
    m.writeNear(0, 0, 0x8A8, &buf8);
    std.mem.writeInt(u64, &buf8, 8 * @as(u64, w + 1), .little);
    m.writeNear(0, 0, 0x8B0, &buf8);

    // ── Workers (cores 1..W) ─────────────────────────────────────────────
    idx = 1;
    while (idx <= w) : (idx += 1) {
        m.load(idx, worker.origin, worker.code);
        m.setRing(idx, 0, ring.slot_sq, mk(0x2400, 0, ring.sq_entry_size, 0, 0));
        m.setRing(idx, 0, ring.slot_cq, mk(0x2000, 5, ring.cq_entry_size, 0, 0));
        m.setRing(idx, 0, ring.slot_rx, mk(0x2A00, 1, ring.rx_entry_size, 0x6564, ring.desc_flag_auto_repost));
        m.setPtt(idx, 0, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
        try m.spawn(idx, 0, 0x1000, 0x3000, 0);
    }
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();

    const cnear = &m.cores[0].contexts[0].near;
    var served: u64 = 0;
    idx = 1;
    while (idx <= w) : (idx += 1)
        served += std.mem.readInt(u64, m.cores[idx].contexts[0].near[0x850..][0..8], .little);
    var max_clock: u64 = 0;
    for (m.cores) |*c| max_clock = @max(max_clock, c.clock);

    return .{
        .reason = reason,
        .gathered = std.mem.readInt(u64, cnear[0x8C8..][0..8], .little),
        .sum = std.mem.readInt(u64, cnear[0x8C0..][0..8], .little),
        .expected_sum = expected,
        .scatter_sends = std.mem.readInt(u64, cnear[0x8D0..][0..8], .little),
        .served_total = served,
        .coordinator_halted = m.cores[0].contexts[0].state == .halted,
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    const w = @max(1, @min(8, opts.workers));

    const complete = o.coordinator_halted and o.gathered == w and o.sum == o.expected_sum;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — scatter-gather: 1 coordinator, {d} workers, {d} cores
        \\  seed 0x{X}, loss {d}/4096 ({d:.1}%), dup 128/4096
        \\  fan-out to per-worker PTT slots; fan-in through one cap-8 RX ring;
        \\  the result is the ack — stragglers get the task again on each tick
        \\
        \\  gathered {d}/{d}, Σ v² = {d} {s}
        \\  scatter sends {d} ({d} were straggler retries)
        \\  worker requests served {d} ({d} duplicate computations, all idempotent)
        \\  coordinator {s}, workers parked immortal
        \\
        \\  outcome: {s}{s}
        \\  cycles {d}, instructions {d}
        \\  fabric: {d} sends ({d} timer ticks), {d} delivered, {d} lost,
        \\          {d} duplicated, {d} timeouts, {d} rejects
        \\
    , .{
        w,                                                           w + 1,
        opts.seed,                                                   opts.loss_ppm4k,
        @as(f64, @floatFromInt(opts.loss_ppm4k)) * 100.0 / 4096.0,   o.gathered,
        w,                                                           o.sum,
        if (o.sum == o.expected_sum) "(verified)" else "(MISMATCH)", o.scatter_sends,
        o.scatter_sends -| w,                                        o.served_total,
        o.served_total -| w,                                         if (o.coordinator_halted) "halted" else "STUCK",
        @tagName(o.reason),                                          if (complete) " — all results in, sum verified" else " — INCOMPLETE",
        o.cycles,                                                    o.stats.instructions,
        o.stats.sends,                                               o.stats.unroutable,
        o.stats.delivered,                                           o.stats.lost,
        o.stats.duplicated,                                          o.stats.timeouts,
        o.stats.rejects,
    });
    if (!complete) std.process.exit(1);
}
