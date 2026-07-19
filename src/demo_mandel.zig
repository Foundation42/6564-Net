//! Mandelbrot demo: Tier 0 scalar floating point earning its keep.
//! z ← z² + c in IEEE 754 double precision on the extended page
//! (prefix $42), one console line per row — and because every FP
//! result is bit-exact by spec, the whole picture is a determinism
//! test: the harness asserts rows character-for-character against an
//! independent computation. Program: programs/asm/mandel.asm.

const std = @import("std");
const ring = @import("ring.zig");
const dev = @import("dev.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const mandel_src = @embedFile("programs/asm/mandel.asm");

pub const console_coord: u16 = 0xFF00;

pub const cols = 64;
pub const rows = 22;

pub const Options = struct {
    seed: u64 = 0x6564,
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    /// The picture, as the console heard it — caller owns.
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
        .max_cycles = 5_000_000,
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
    var out = asm6564.assemble(alloc, mandel_src, &diag) catch |err| {
        std.debug.print("mandel: asm error line {d}: {s}\n", .{ diag.line, diag.message });
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

/// The same picture, computed independently in host f64 — the oracle the
/// machine's output must match bit-for-bit (via its characters). Mirrors
/// mandel.asm's exact operation order: doubling is t+t, escape compares
/// zy²+zx² (that addition order) against 4.0, strictly-less continues.
pub fn oracleRow(alloc: std.mem.Allocator, row: usize) ![]u8 {
    const pal = " .,:;~=+xoXO#%$&@";
    const dx: f64 = 2.5 / 63.0;
    const dy: f64 = 2.2 / 21.0;
    var line = try alloc.alloc(u8, cols + 1);
    var cy: f64 = 1.1;
    for (0..row) |_| cy = cy - dy;
    var cx: f64 = -2.0;
    for (0..cols) |c| {
        var zx: f64 = 0.0;
        var zy: f64 = 0.0;
        var n: usize = 0;
        while (true) {
            const zx2 = zx * zx;
            const zy2 = zy * zy;
            if (!(zy2 + zx2 < 4.0)) break;
            const t = zx * zy;
            zy = (t + t) + cy;
            zx = (zx2 - zy2) + cx;
            n += 1;
            if (n == 16) break;
        }
        line[c] = pal[n];
        cx = cx + dx;
    }
    line[cols] = '\n';
    return line;
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    defer alloc.free(o.text);
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — mandel: the set, in IEEE doubles, on a 6502 descendant
        \\
        \\{s}
        \\  outcome: {s} in {d} cycles, {d} instructions
        \\  fabric: {d} sends ({d} lines to the teletype)
        \\
    , .{
        o.text,
        @tagName(o.reason),
        o.cycles,
        o.stats.instructions,
        o.stats.sends,
        o.stats.dev_deliveries,
    });
    if (o.reason != .all_halted) std.process.exit(1);
}
