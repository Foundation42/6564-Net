//! Ping-pong demo: two actors bounce a value across a hostile fabric.
//! Programs live in programs/ping.asm and programs/pong.asm.

const std = @import("std");
const isa = @import("isa.zig");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const ping_src = @embedFile("programs/ping.asm");
const pong_src = @embedFile("programs/pong.asm");

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
    m.setRing(core, 0, ring.slot_rx, .{
        .base = 0x2100,
        .cap_log2 = 0,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    });
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
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

    const ping = &m.cores[0].contexts[0];
    const pong = &m.cores[1].contexts[0];
    const final = std.mem.readInt(u64, m.cores[0].ram[0x2280 - machine.ram_base ..][0..8], .little);
    const retries = std.mem.readInt(u64, ping.near[0x818..][0..8], .little);
    const served = std.mem.readInt(u64, pong.near[0x820..][0..8], .little);

    const verdict = switch (reason) {
        .deadlock => if (ping.state == .halted)
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
        verdict,                  final,
        retries,                  served,
        m.cores[0].clock,         m.cores[1].clock,
        m.stats.instructions,     m.stats.sends,
        m.stats.unroutable,       m.stats.delivered,
        m.stats.lost,             m.stats.duplicated,
        m.stats.timeouts,         m.stats.rejects,
        m.stats.context_switches,
    });
    if (opts.rounds > 0 and ping.state != .halted) std.process.exit(1);
}
