//! joe demo: pingpong.joe compiled at runtime and run across the same
//! hostile fabric as the hand-written ping.asm/pong.asm — joe's first
//! breath. The compiler (src/joe.zig) turns each actor into a program;
//! this harness wires the v1 runtime ABI (same rings, same PTT shape,
//! same black-hole timer as demo_pingpong) and stages the actor
//! parameters into the near page, which is all a loader is.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");
const joe = @import("joe.zig");

const joe_src = @embedFile("programs/pingpong.joe");

pub const Options = struct {
    seed: u64 = 0x6564,
    loss_ppm4k: u16 = 1024,
    rounds: u64 = 8,
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    /// Pinger's `seq` var, read from its near page: must equal rounds.
    seq: u64,
    ping_halted: bool,
    ping_code: usize,
    pong_code: usize,
    cycles: u64,
    stats: machine.Stats,
};

fn wire(m: *machine.Machine, core: u16) void {
    m.setRing(core, 0, ring.slot_sq, .{
        .base = joe.abi.sq_base,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, 0, ring.slot_cq, .{
        .base = joe.abi.cq_base,
        .cap_log2 = 4,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, 0, joe.abi.timer_desc, .{
        .base = joe.abi.timer_base,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(core, 0, ring.slot_rx, .{
        .base = joe.abi.rx_base,
        .cap_log2 = 1,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    });
}

fn stageParam(m: *machine.Machine, core: u16, ctx: u8, off: u16, value: u64) void {
    std.mem.writeInt(u64, m.cores[core].contexts[ctx].near[off..][0..8], value, .little);
}

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    // Compile both actors first — the timer period below comes from
    // Pinger's `after`.
    var diag = joe.Diagnostic{};
    var ping = joe.compile(alloc, joe_src, "Pinger", 0x1000, &diag) catch |err| {
        std.debug.print("joe Pinger: line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer ping.deinit();
    var pong = joe.compile(alloc, joe_src, "Ponger", 0x1000, &diag) catch |err| {
        std.debug.print("joe Ponger: line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer pong.deinit();

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
            .send_timeout = ping.timer_period, // `after N` — the harness's half of the contract
        },
        .max_cycles = 50_000_000,
        .trace = opts.trace,
    });
    defer m.deinit();

    // Each core's PTT 0 → the other's RX ring; core 0's PTT 1 → nowhere
    // (the black hole Pinger's `after` timer ticks against).
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
    m.setPtt(0, 1, .{
        .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
        .rights = .{ .send = true },
        .token = 0,
    });
    wire(&m, 0);
    wire(&m, 1);

    var out_len: [2]usize = .{ 0, 0 };
    inline for (.{ .{ @as(u16, 0), &ping, "Pinger" }, .{ @as(u16, 1), &pong, "Ponger" } }) |spec| {
        var adiag = asm6564.Diagnostic{};
        var out = asm6564.assemble(alloc, spec[1].asm_text, &adiag) catch |err| {
            std.debug.print("joe {s}: asm line {d}: {s}\n", .{ spec[2], adiag.line, adiag.message });
            return err;
        };
        defer out.deinit();
        m.load(spec[0], out.origin, out.code);
        out_len[spec[0]] = out.code.len;
    }

    // Stage parameters — the loader's whole job in the v1 ABI. Both
    // actors' `peer` is their own PTT slot 0, as a window value.
    const peer_window = ring.windowAddr(0, 0);
    stageParam(&m, 0, 0, ping.params[0].off, peer_window); // Pinger.peer
    stageParam(&m, 0, 0, ping.params[1].off, opts.rounds); // Pinger.rounds
    stageParam(&m, 1, 0, pong.params[0].off, peer_window); // Ponger.peer

    try m.spawn(1, 0, 0x1000, 0x3800, 0); // Ponger listens first
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();

    const pinger = &m.cores[0].contexts[0];
    var max_clock: u64 = 0;
    for (m.cores) |*c| max_clock = @max(max_clock, c.clock);
    const seq_off = for (ping.vars) |v| {
        if (std.mem.eql(u8, v.name, "seq")) break v.off;
    } else unreachable;
    return .{
        .reason = reason,
        .seq = std.mem.readInt(u64, pinger.near[seq_off..][0..8], .little),
        .ping_halted = pinger.state == .halted,
        .ping_code = out_len[0],
        .pong_code = out_len[1],
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    const stdout = std.io.getStdOut().writer();
    const verdict = switch (o.reason) {
        .deadlock => if (o.ping_halted)
            "Pinger halted; Ponger parked serving — machine quiesced"
        else
            "DEADLOCK: Pinger did not finish",
        .all_halted => "all contexts halted",
        .faulted => "a context FAULTED",
        .max_cycles => "hit max_cycles",
    };
    try stdout.print(
        \\sim6564 — joe: pingpong.joe, compiled and run
        \\  seed 0x{X}, loss {d}/4096 ({d:.1}%), dup 128/4096, {d} rounds
        \\
        \\  outcome: {s}
        \\  Pinger.seq = {d} (sequence-checked: must equal rounds)
        \\  code: Pinger {d} bytes, Ponger {d} bytes
        \\
        \\  cycles: {d}   instructions: {d}
        \\  fabric: {d} sends ({d} ticks into the void), {d} delivered,
        \\          {d} lost, {d} duplicated, {d} timeouts, {d} rejects
        \\
    , .{
        opts.seed,
        opts.loss_ppm4k,
        @as(f64, @floatFromInt(opts.loss_ppm4k)) * 100.0 / 4096.0,
        opts.rounds,
        verdict,
        o.seq,
        o.ping_code,
        o.pong_code,
        o.cycles,
        o.stats.instructions,
        o.stats.sends,
        o.stats.unroutable,
        o.stats.delivered,
        o.stats.lost,
        o.stats.duplicated,
        o.stats.timeouts,
        o.stats.rejects,
    });
    if (!o.ping_halted or o.seq != opts.rounds) std.process.exit(1);
}
