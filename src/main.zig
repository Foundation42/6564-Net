//! sim6564 CLI — demo dispatcher. See usage() for the interface.

const std = @import("std");
const sim = @import("sim6564");

const usage_text =
    \\sim6564 — 6564-Net reference simulator
    \\
    \\usage:
    \\  sim6564 [pingpong] [seed] [loss_ppm4k] [rounds] [trace]
    \\      Two actors bounce a value across a lossy, duplicating, reordering
    \\      fabric; ping runs an end-to-end reliable protocol built from CQ
    \\      feedback and fabric-as-clock timers (programs/ping.asm, pong.asm).
    \\      Defaults: seed 0x6564, loss 1024/4096 (25%), 8 rounds.
    \\
    \\  sim6564 supervise [trace]
    \\      A one-for-one supervision tree: exit links report crashes AND
    \\      watchdog-caught hangs to the supervisor's CQ; SPWN restarts from
    \\      per-child budgets (programs/supervisor.asm, worker.asm).
    \\
    \\  sim6564 pipeline [seed] [loss_ppm4k] [items] [stages] [trace]
    \\      Dataflow across stages+2 cores: per-hop stop-and-wait on app acks,
    \\      ack-on-ownership so hops overlap, backpressure by silence, and a
    \\      poison-pill shutdown (programs/pipe_source.asm, pipe_stage.asm,
    \\      pipe_sink.asm). Defaults: seed 0x6564, loss 1024, 16 items, 2 stages.
    \\
    \\  sim6564 scatter [seed] [loss_ppm4k] [workers] [trace]
    \\      Fan a task out to up to 8 workers, gather squared results through
    \\      one cap-8 RX ring; the result is the ack, stragglers are re-asked
    \\      on timer ticks (programs/scatter_coord.asm, scatter_worker.asm).
    \\
    \\  sim6564 ring [nodes] [laps] [trace]
    \\      Joe Armstrong's challenge: N processes in a ring, a message
    \\      around M times — N·M passes, timed in cycles per pass. All N
    \\      processes are banked contexts on one core (programs/ring_node.asm).
    \\
    \\  sim6564 measure
    \\      Run every demo at its frozen baseline config and emit the
    \\      instructions / cycles / code-bytes table (the MAC & chains
    \\      go/no-go data; see docs/6564-mac-and-chains-sketch.md §6).
    \\
    \\  sim6564 help | --help | -h
    \\
;

fn usage(status: u8) noreturn {
    std.io.getStdErr().writeAll(usage_text) catch {};
    std.process.exit(status);
}

fn parseOr(comptime T: type, s: []const u8, what: []const u8) T {
    return std.fmt.parseInt(T, s, 0) catch {
        std.io.getStdErr().writer().print("bad {s}: '{s}'\n\n", .{ what, s }) catch {};
        usage(1);
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const first = args.next() orelse
        return sim.demo_pingpong.run(alloc, .{});

    if (std.mem.eql(u8, first, "help") or
        std.mem.eql(u8, first, "--help") or
        std.mem.eql(u8, first, "-h")) usage(0);

    if (std.mem.eql(u8, first, "supervise")) {
        const trace = if (args.next()) |s| std.mem.eql(u8, s, "trace") else false;
        return sim.demo_supervise.run(alloc, .{ .trace = trace });
    }

    if (std.mem.eql(u8, first, "scatter")) {
        var opts = sim.demo_scatter.Options{};
        if (args.next()) |s| opts.seed = parseOr(u64, s, "seed");
        if (args.next()) |s| opts.loss_ppm4k = @min(4096, parseOr(u16, s, "loss_ppm4k"));
        if (args.next()) |s| opts.workers = @min(8, parseOr(u16, s, "workers"));
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_scatter.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "measure"))
        return sim.measure.run(alloc);

    if (std.mem.eql(u8, first, "ring")) {
        var opts = sim.demo_ring.Options{};
        if (args.next()) |s| opts.nodes = @min(200, parseOr(u16, s, "nodes"));
        if (args.next()) |s| opts.laps = @min(1000, parseOr(u64, s, "laps"));
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_ring.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "pipeline")) {
        var opts = sim.demo_pipeline.Options{};
        if (args.next()) |s| opts.seed = parseOr(u64, s, "seed");
        if (args.next()) |s| opts.loss_ppm4k = @min(4096, parseOr(u16, s, "loss_ppm4k"));
        if (args.next()) |s| opts.items = @min(200, parseOr(u64, s, "items"));
        if (args.next()) |s| opts.stages = @min(8, parseOr(u16, s, "stages"));
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_pipeline.run(alloc, opts);
    }

    // Everything else is the ping-pong demo; a bare first argument is the
    // seed (back-compatible with the original positional CLI).
    var opts = sim.demo_pingpong.Options{};
    if (!std.mem.eql(u8, first, "pingpong"))
        opts.seed = parseOr(u64, first, "seed")
    else if (args.next()) |s|
        opts.seed = parseOr(u64, s, "seed");
    if (args.next()) |s| opts.loss_ppm4k = @min(4096, parseOr(u16, s, "loss_ppm4k"));
    if (args.next()) |s| opts.rounds = @min(100, parseOr(u64, s, "rounds"));
    if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
    try sim.demo_pingpong.run(alloc, opts);
}
