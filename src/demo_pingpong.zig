//! Ping-pong demo: two actors bounce a value across a hostile fabric.
//! Programs live in programs/asm/ping.asm and programs/asm/pong.asm.

const std = @import("std");
const isa = @import("isa.zig");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const ping_src = @embedFile("programs/asm/ping.asm");
const pong_src = @embedFile("programs/asm/pong.asm");

pub const Options = struct {
    seed: u64 = 0x6564,
    loss_ppm4k: u16 = 1024,
    rounds: u64 = 8,
    trace: bool = false,
};

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
    m.setRing(core, 0, 5, .{
        .base = 0x2480,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    }); // the timer SQ (AUTO_REARM entry lives at $2480)
    m.setRing(core, 0, ring.slot_rx, .{
        .base = 0x2100,
        .cap_log2 = 1, // two landing buffers: AUTO_REPOST's validity window
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    });
}

pub const Outcome = struct {
    reason: machine.StopReason,
    final: u64,
    retransmissions: u64,
    served: u64,
    ping_halted: bool,
    cycles: u64,
    stats: machine.Stats,
};

/// Build, run, and measure — shared by the CLI demo and the test suite.
pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    var m = try machine.Machine.init(alloc, .{
        .cores = 2,
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

    var diag = asm6564.Diagnostic{};
    inline for (.{ .{ @as(u16, 0), ping_src, "ping" }, .{ @as(u16, 1), pong_src, "pong" } }) |spec| {
        var out = asm6564.assemble(alloc, spec[1], &diag) catch |err| {
            std.debug.print("{s}: asm error line {d}: {s}\n", .{ spec[2], diag.line, diag.message });
            return err;
        };
        defer out.deinit();
        m.load(spec[0], out.origin, out.code);
    }
    // Stage the round count where ping.asm expects it.
    var rounds_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &rounds_le, opts.rounds, .little);
    m.load(0, 0x2600, &rounds_le);

    try m.spawn(1, 0, 0x1000, 0x3000, 0); // pong listens first
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();

    const ping = &m.cores[0].contexts[0];
    const pong = &m.cores[1].contexts[0];
    var max_clock: u64 = 0;
    for (m.cores) |*c| max_clock = @max(max_clock, c.clock);
    return .{
        .reason = reason,
        .final = std.mem.readInt(u64, m.cores[0].ram[0x2280 - machine.ram_base ..][0..8], .little),
        .retransmissions = std.mem.readInt(u64, ping.near[0x818..][0..8], .little),
        .served = std.mem.readInt(u64, pong.near[0x820..][0..8], .little),
        .ping_halted = ping.state == .halted,
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — ping-pong across a hostile fabric
        \\  seed 0x{X}, loss {d}/4096 ({d:.1}%), dup 128/4096, {d} rounds
        \\
    , .{
        opts.seed,
        opts.loss_ppm4k,
        @as(f64, @floatFromInt(opts.loss_ppm4k)) * 100.0 / 4096.0,
        opts.rounds,
    });

    const verdict = switch (o.reason) {
        .deadlock => if (o.ping_halted)
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
        verdict,                  o.final,
        o.retransmissions,        o.served,
        o.cycles,                 o.cycles,
        o.stats.instructions,     o.stats.sends,
        o.stats.unroutable,       o.stats.delivered,
        o.stats.lost,             o.stats.duplicated,
        o.stats.timeouts,         o.stats.rejects,
        o.stats.context_switches,
    });
    if (opts.rounds > 0 and !o.ping_halted) std.process.exit(1);
}
