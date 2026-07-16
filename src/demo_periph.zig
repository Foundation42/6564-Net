//! Peripheral bus check: one actor walks the whole peripheral row (§7) —
//! console, entropy well, RTC, block store — timestamps itself, draws
//! random bytes, round-trips them through a disk sector, and prints the
//! cycle bill. Every step is a SEND through a capability and a completion
//! in the CQ; there is no other kind of I/O to fall back on.
//! Program: programs/periph.asm.

const std = @import("std");
const ring = @import("ring.zig");
const dev = @import("dev.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const periph_src = @embedFile("programs/periph.asm");

pub const console_coord: u16 = 0xFF00;
pub const entropy_coord: u16 = 0xFF01;
pub const rtc_coord: u16 = 0xFF02;
pub const block_coord: u16 = 0xFF03;

pub const Options = struct {
    seed: u64 = 0x6564,
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    /// The console transcript — caller owns.
    text: []u8,
    /// The program's own cycle count for its errand (near $890).
    elapsed: u64,
    block_ok: bool,
    cycles: u64,
    stats: machine.Stats,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    var m = try machine.Machine.init(alloc, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .seed = opts.seed,
        .link = .{
            .base_latency = 200,
            .jitter = 120,
            .loss_ppm4k = 0,
            .dup_ppm4k = 0,
            .send_timeout = 2500,
        },
        .max_cycles = 5_000_000,
        .trace = opts.trace,
    });
    defer m.deinit();

    // The row: console and block gated by token, the clock public.
    try m.attachDevice(console_coord, 0x6564, .{ .console = dev.Console.init(alloc) });
    try m.attachDevice(entropy_coord, 0x6564, .{ .entropy = dev.Entropy.init(opts.seed ^ 0xE47) });
    try m.attachDevice(rtc_coord, 0, .{ .rtc = .{} });
    try m.attachDevice(block_coord, 0x6564, .{ .block = try dev.Block.init(alloc, 8, 64) });

    // The actor's capabilities to the row…
    for ([_]struct { slot: u16, coord: u16, token: u64 }{
        .{ .slot = 0, .coord = console_coord, .token = 0x6564 },
        .{ .slot = 1, .coord = entropy_coord, .token = 0x6564 },
        .{ .slot = 2, .coord = rtc_coord, .token = 0 },
        .{ .slot = 3, .coord = block_coord, .token = 0x6564 },
    }) |c| {
        m.setPtt(0, c.slot, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(c.coord, 0, 0),
            .rights = .{ .send = true },
            .token = c.token,
        });
    }
    // …and each replying device's capability back to the actor's RX ring:
    // the loader wiring driver to device, same act as wiring two actors.
    for ([_]u16{ entropy_coord, rtc_coord, block_coord }) |coord| {
        m.setDevicePtt(coord, 0, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
    }

    m.setRing(0, 0, ring.slot_sq, .{
        .base = 0x2400,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(0, 0, 5, .{
        .base = 0x2480,
        .cap_log2 = 0,
        .entry_size = ring.sq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    }); // the char SQE hexq speaks through
    m.setRing(0, 0, ring.slot_cq, .{
        .base = 0x2000,
        .cap_log2 = 4,
        .entry_size = ring.cq_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .head = 0,
        .tail = 0,
        .token = 0,
    });
    m.setRing(0, 0, ring.slot_rx, .{
        .base = 0x2100,
        .cap_log2 = 1,
        .entry_size = ring.rx_entry_size,
        .watermark = 0,
        .companion_cq = ring.slot_cq,
        .flags = ring.desc_flag_auto_repost,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    });

    var diag = asm6564.Diagnostic{};
    var out = asm6564.assemble(alloc, periph_src, &diag) catch |err| {
        std.debug.print("periph: asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer out.deinit();
    m.load(0, out.origin, out.code);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();
    const text = try alloc.dupe(u8, m.device(console_coord).?.console.out.items);
    return .{
        .reason = reason,
        .text = text,
        .elapsed = std.mem.readInt(u64, m.cores[0].contexts[0].near[0x890..][0..8], .little),
        .block_ok = std.mem.indexOf(u8, text, "BLOCK OK") != null,
        .cycles = m.cores[0].clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    defer alloc.free(o.text);
    const ok = o.reason == .all_halted and o.block_ok;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — peripheral row: console, entropy, rtc, block ($FF00..$FF03)
        \\
        \\  console transcript:
        \\
    , .{});
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, o.text, "\n"), '\n');
    while (lines.next()) |line| try stdout.print("    {s}\n", .{line});
    try stdout.print(
        \\
        \\  outcome: {s}{s}
        \\  the errand took {d} cycles by the machine's own RTC arithmetic
        \\  fabric: {d} sends, {d} device deliveries, {d} device replies,
        \\          {d} delivered, {d} instructions
        \\
    , .{
        @tagName(o.reason),
        if (ok) " — every device answered" else " — INCOMPLETE",
        o.elapsed,
        o.stats.sends,
        o.stats.dev_deliveries,
        o.stats.dev_replies,
        o.stats.delivered,
        o.stats.instructions,
    });
    if (!ok) std.process.exit(1);
}
