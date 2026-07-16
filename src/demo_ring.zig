//! Joe Armstrong's ring (Programming Erlang, ch. 12): N processes in a
//! ring, a message around M times — N·M message passes. The 6564 rendition:
//! N banked contexts on ONE core (§2.2: contexts are ~41 bytes; creating a
//! "process" is filling in a register bank), message passing by
//! single-register TXR through per-node PTT slots, wakeups by LSTN.
//!
//! The measurement this benchmark exists for: cycles per message pass,
//! actor to actor, scheduler included.
//!
//! Program: programs/ring_node.asm (one program, N nodes).

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const node_src = @embedFile("programs/ring_node.asm");

pub const Options = struct {
    nodes: u16 = 64, // 2..200
    laps: u64 = 100, // 1..1000
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    passes: u64,
    cycles: u64,
    cycles_per_pass: u64,
    instructions: u64,
    context_switches: u64,
    finisher_is_node0: bool,
    exactly_one_finisher: bool,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    const n: u16 = @max(2, @min(200, opts.nodes));
    const m: u64 = @max(1, @min(1000, opts.laps));
    const passes = @as(u64, n) * m;

    var mach = try machine.Machine.init(alloc, .{
        .cores = 1,
        .contexts_per_core = @intCast(n),
        .ram_size = 0x20000,
        .max_cycles = 80 * passes + 1_000_000,
        .trace = opts.trace,
    });
    defer mach.deinit();

    var diag = asm6564.Diagnostic{};
    var prog = asm6564.assemble(alloc, node_src, &diag) catch |err| {
        std.debug.print("ring asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer prog.deinit();
    mach.load(0, prog.origin, prog.code); // one code page, N actors

    var buf8: [8]u8 = undefined;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const ctx: u8 = @intCast(i);
        // PTT slot i → the next node's RX ring, around the ring.
        mach.setPtt(0, i, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(0, @intCast((i + 1) % n), ring.slot_rx),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
        // Rings: CQ (cap 4) and RX (cap 1), storage striped per node.
        mach.setRing(0, ctx, ring.slot_cq, .{
            .base = 0x8000 + 64 * @as(u64, i),
            .cap_log2 = 2,
            .entry_size = ring.cq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        mach.setRing(0, ctx, ring.slot_rx, .{
            .base = 0x4000 + 32 * @as(u64, i),
            .cap_log2 = 0,
            .entry_size = ring.rx_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0x6564,
        });
        // The RX entry: an 8-byte landing cell, exactly one TXR payload.
        const cell: u64 = 0x6000 + 8 * @as(u64, i);
        const entry = ring.RxEntry{ .buf = cell, .cap = 8, .filled = 0, .cookie = cell };
        var entry_bytes: [32]u8 = undefined;
        for (entry.pack(), 0..) |word, wi|
            std.mem.writeInt(u64, entry_bytes[wi * 8 ..][0..8], word, .little);
        mach.load(0, 0x4000 + 32 * @as(u64, i), &entry_bytes);
        // Near config: where to send, where messages land.
        std.mem.writeInt(u64, &buf8, ring.windowAddr(i, 0), .little);
        mach.writeNear(0, ctx, 0x840, &buf8);
        std.mem.writeInt(u64, &buf8, cell, .little);
        mach.writeNear(0, ctx, 0x848, &buf8);
        // Everyone but node 0 starts now; the injector goes last so every
        // landing buffer is posted before pass 1 departs.
        if (i != 0) try mach.spawn(0, ctx, 0x1000, 0x3000, 0);
    }
    try mach.spawn(0, 0, 0x1000, 0x3000, passes);

    const reason = try mach.run();

    var finishers: u16 = 0;
    var node0_finished = false;
    i = 0;
    while (i < n) : (i += 1) {
        const flag = std.mem.readInt(u64, mach.cores[0].contexts[i].near[0x850..][0..8], .little);
        if (flag != 0) {
            finishers += 1;
            if (i == 0) node0_finished = true;
        }
    }

    return .{
        .reason = reason,
        .passes = passes,
        .cycles = mach.cores[0].clock,
        .cycles_per_pass = mach.cores[0].clock / passes,
        .instructions = mach.stats.instructions,
        .context_switches = mach.stats.context_switches,
        // Pass N·M lands back at node 0 (N·M is a multiple of N).
        .finisher_is_node0 = node0_finished,
        .exactly_one_finisher = finishers == 1,
    };
}

pub fn run(alloc: std.mem.Allocator, opts: Options) !void {
    const o = try simulate(alloc, opts);
    const n = @max(2, @min(200, opts.nodes));
    const m = @max(1, @min(1000, opts.laps));

    const complete = o.exactly_one_finisher and o.finisher_is_node0 and
        o.reason == .deadlock;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\sim6564 — Armstrong's ring (Programming Erlang, ch. 12)
        \\  {d} processes in a ring on ONE core, message around {d} times:
        \\  {d} message passes, each a single-register TXR datagram
        \\
        \\  outcome: {s}{s}
        \\  {d} cycles total — {d} cycles per message pass
        \\  ({d} instructions, {d} zero-cycle context switches)
        \\
        \\  a "process" here is a 41-byte register bank; all {d} of them,
        \\  their rings and their mailboxes fit in one core's near pages
        \\
    , .{
        n,                                                                 m,
        o.passes,                                                          @tagName(o.reason),
        if (complete) " — the message came home" else " — INCOMPLETE", o.cycles,
        o.cycles_per_pass,                                                 o.instructions,
        o.context_switches,                                                n,
    });
    if (!complete) std.process.exit(1);
}
