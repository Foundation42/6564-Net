//! Hello demo: one actor, one capability, one teletype on the fabric.
//! The smallest possible proof of §7 — the machine's first words reach
//! the world through the same SEND every actor already speaks.
//! Program: programs/hello.asm.

const std = @import("std");
const ring = @import("ring.zig");
const dev = @import("dev.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const hello_src = @embedFile("programs/hello.asm");

pub const console_coord: u16 = 0xFF00;

pub const Options = struct {
    seed: u64 = 0x6564,
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    /// What the console heard — caller owns.
    text: []u8,
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
        .max_cycles = 1_000_000,
        .trace = opts.trace,
    });
    defer m.deinit();

    try m.attachDevice(console_coord, 0x6564, .{ .console = dev.Console.init(alloc) });
    m.setPtt(0, 0, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(console_coord, 0, 0),
        .rights = .{ .send = true },
        .token = 0x6564,
    });
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

    var diag = asm6564.Diagnostic{};
    var out = asm6564.assemble(alloc, hello_src, &diag) catch |err| {
        std.debug.print("hello: asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer out.deinit();
    m.load(0, out.origin, out.code);
    try m.spawn(0, 0, 0x1000, 0x3000, 0);

    const reason = try m.run();
    return .{
        .reason = reason,
        .text = try alloc.dupe(u8, m.device(console_coord).?.console.out.items),
        .cycles = m.cores[0].clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    defer alloc.free(o.text);
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — hello: one actor, one capability, one teletype
        \\
        \\  console ($FF00) received:
        \\
        \\    {s}
        \\  outcome: {s} in {d} cycles
        \\  fabric: {d} sends, {d} device deliveries, {d} instructions
        \\
    , .{
        o.text,
        @tagName(o.reason),
        o.cycles,
        o.stats.sends,
        o.stats.dev_deliveries,
        o.stats.instructions,
    });
    if (o.reason != .all_halted) std.process.exit(1);
}
