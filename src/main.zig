//! sim6564 CLI — demo dispatcher. See usage() for the interface.

const std = @import("std");
const builtin = @import("builtin");
const sim = @import("sim6564");

const usage_text =
    \\sim6564 — 6564-Net reference simulator
    \\
    \\usage:
    \\  sim6564 [pingpong] [seed] [loss_ppm4k] [rounds] [trace]
    \\      Two actors bounce a value across a lossy, duplicating, reordering
    \\      fabric; ping runs an end-to-end reliable protocol built from CQ
    \\      feedback and fabric-as-clock timers (programs/asm/ping.asm, pong.asm).
    \\      Defaults: seed 0x6564, loss 1024/4096 (25%), 8 rounds.
    \\
    \\  sim6564 supervise [trace]
    \\      A one-for-one supervision tree: exit links report crashes AND
    \\      watchdog-caught hangs to the supervisor's CQ; SPWN restarts from
    \\      per-child budgets (programs/asm/supervisor.asm, worker.asm).
    \\
    \\  sim6564 pipeline [seed] [loss_ppm4k] [items] [stages] [trace]
    \\      Dataflow across stages+2 cores: per-hop stop-and-wait on app acks,
    \\      ack-on-ownership so hops overlap, backpressure by silence, and a
    \\      poison-pill shutdown (programs/asm/pipe_source.asm, pipe_stage.asm,
    \\      pipe_sink.asm). Defaults: seed 0x6564, loss 1024, 16 items, 2 stages.
    \\
    \\  sim6564 scatter [seed] [loss_ppm4k] [workers] [trace]
    \\      Fan a task out to up to 8 workers, gather squared results through
    \\      one cap-8 RX ring; the result is the ack, stragglers are re-asked
    \\      on timer ticks (programs/asm/scatter_coord.asm, scatter_worker.asm).
    \\
    \\  sim6564 ring [nodes] [laps] [trace]
    \\      Joe Armstrong's challenge: N processes in a ring, a message
    \\      around M times — N·M passes, timed in cycles per pass. All N
    \\      processes are banked contexts on one core (programs/asm/ring_node.asm).
    \\
    \\  sim6564 bigbrother [senders] [loss_ppm4k] [trace]
    \\      The fan-in stress test: up to 10,000 actors flood one target
    \\      (programs/asm/flood_sender.asm, fanin_sink.asm). Default 10000, loss 0.
    \\
    \\  sim6564 forkjoin [lieutenants] [workers] [trace]
    \\      The fork-join matrix: 1 → LxW workers → LxW relays → 1 aggregator
    \\      (programs/asm/fj_root.asm, fj_lieutenant.asm, fj_pass.asm,
    \\      fanin_sink.asm). Default 8x125 = 1000.
    \\
    \\  sim6564 hello [seed] [trace]
    \\      The machine's first words: one actor prints through the console
    \\      device on the peripheral row (§7) — SEND is the only I/O
    \\      instruction there is (programs/asm/hello.asm).
    \\
    \\  sim6564 run <file.joe|file.asm> [seed] [loss_ppm4k] [trace] [scorch]
    \\      Run any program whose source carries its deployment: a .joe
    \\      file with a `system` block, or a .asm file whose harness
    \\      contract is written as directives (.actor/.ring/.system —
    \\      src/asm.zig) with `.use` pulling in its partners. One loader
    \\      discipline, one report, either language.
    \\
    \\  sim6564 joe [file.joe] [seed] [loss_ppm4k] [trace] [scorch]
    \\      Compile and run any .joe file that carries a `system` block —
    \\      the deployment is data in the source, so there is no per-
    \\      program harness. Placement, capability wiring, parameter
    \\      staging and timers are the loader's job (src/joe_run.zig).
    \\      With no file: the built-in pingpong.joe across a lossy fabric.
    \\
    \\  sim6564 joec <file.joe> <Actor>
    \\      Compile one actor to 6564 assembly on stdout.
    \\
    \\  sim6564 mandel [seed] [trace]
    \\      The Mandelbrot set in IEEE 754 doubles — Tier 0 scalar FP on
    \\      the extended page (prefix $42), one console line per row,
    \\      every row asserted bit-exact against an independent oracle
    \\      (programs/asm/mandel.asm).
    \\
    \\  sim6564 periph [seed] [trace]
    \\      Walk the whole peripheral row: console, entropy well, RTC and
    \\      block store. The actor timestamps itself, draws random bytes,
    \\      round-trips them through a disk sector and prints its own cycle
    \\      bill (programs/asm/periph.asm).
    \\
    \\  sim6564 dies [dies] [nodes_per_die] [laps] [busy_laps] [seq] [trace]
    \\      Armstrong's ring across whole dies joined by the IO plane —
    \\      one host thread per die, bit-identical to the sequential run.
    \\      Remoteness is one route byte in a PTT entry; the program can't
    \\      tell (programs/asm/ring_node.asm, unmodified). Default 4x50x10.
    \\      busy_laps > 0 adds a local ring per die so every host thread
    \\      has work (the lone global token is Amdahl's law incarnate).
    \\      On asymmetric hosts (Zen X3D), add spread | vcache | freq to
    \\      pin die threads by L3 domain — wall-clock only, same bits.
    \\
    \\  sim6564 web [host] [port] [path]
    \\      The capstone: http_get.asm speaks HTTP/1.1 through the net
    \\      device (a raw byte pipe, §7.4) and prints a REAL web page on
    \\      its teletype. Protocol in 6564 code — §7.5's polyfill layer.
    \\      Default http://example.com:80/. Not deterministic: the
    \\      outside world does not replay.
    \\
    \\  sim6564 net <listen [port] | connect [host] [port]> [dies] [nodes] [laps]
    \\      The ring across two OS PROCESSES: each runs half the dies; the
    \\      IO plane's window barriers cross a real TCP socket. Virtual
    \\      time rides the wire, so the federation replays bit-identically
    \\      from its seeds regardless of real network timing. Start the
    \\      listener first, then the connector (same dies/nodes/laps).
    \\
    \\  sim6564 churn [dies] [stripe_mb] [sweeps] [spread|vcache|freq] [seq]
    \\      The cache-footprint experiment: each die read-modify-writes a
    \\      multi-MB stripe in prefetcher-proof LFSR order
    \\      (programs/asm/mem_churn.asm) so thread placement on an X3D host
    \\      has something to disagree about. stripe_mb rounds down to
    \\      {2,8,16,64}. Default 8x8MB x12 = 64 MB live working set.
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
    // Debug builds keep the leak-checking GPA; release builds use the
    // lock-avoiding SMP allocator — the dies demo runs one thread per die,
    // and a shared allocator mutex is where that speedup goes to die.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

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

    if (std.mem.eql(u8, first, "hello")) {
        var opts = sim.demo_hello.Options{};
        if (args.next()) |s| opts.seed = parseOr(u64, s, "seed");
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_hello.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "joe")) {
        var opts = sim.joe_run.Options{};
        var source: []const u8 = @embedFile("programs/joe/pingpong.joe");
        var owned: ?[]u8 = null;
        defer if (owned) |s| alloc.free(s);
        if (args.next()) |s| {
            if (std.mem.endsWith(u8, s, ".joe")) {
                owned = std.fs.cwd().readFileAlloc(alloc, s, 1 << 20) catch |err| {
                    std.debug.print("joe: cannot read {s}: {s}\n", .{ s, @errorName(err) });
                    std.process.exit(1);
                };
                source = owned.?;
                if (args.next()) |s2| opts.seed = parseOr(u64, s2, "seed");
            } else {
                opts.seed = parseOr(u64, s, "seed");
            }
        }
        if (args.next()) |s| {
            opts.loss_ppm4k = @min(4095, parseOr(u16, s, "loss_ppm4k"));
            // loss 0 asks for a CLEAN fabric: duplication off too — a
            // teletype has no dedup, and doubled greetings help no one.
            if (opts.loss_ppm4k == 0) opts.dup_ppm4k = 0;
        }
        while (args.next()) |s| {
            if (std.mem.eql(u8, s, "trace")) opts.trace = true;
            // Item 4's verifier: poison every register at every park.
            // Compiled joe must not notice.
            if (std.mem.eql(u8, s, "scorch")) opts.scorch = true;
        }
        return sim.joe_run.run(alloc, source, opts);
    }

    if (std.mem.eql(u8, first, "run")) {
        const path = args.next() orelse {
            std.debug.print("usage: sim6564 run <file.joe|file.asm> [seed] [loss_ppm4k] [trace] [scorch]\n", .{});
            std.process.exit(2);
        };
        var opts = sim.joe_run.Options{};
        if (args.next()) |s| opts.seed = parseOr(u64, s, "seed");
        if (args.next()) |s| {
            opts.loss_ppm4k = @min(4095, parseOr(u16, s, "loss_ppm4k"));
            if (opts.loss_ppm4k == 0) opts.dup_ppm4k = 0;
        }
        while (args.next()) |s| {
            if (std.mem.eql(u8, s, "trace")) opts.trace = true;
            if (std.mem.eql(u8, s, "scorch")) opts.scorch = true;
        }
        // Files for this command live in an arena: the lead, then every
        // `.use` partner, resolved relative to the lead's directory.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const lead = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch |err| {
            std.debug.print("run: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        if (std.mem.endsWith(u8, path, ".joe"))
            return sim.joe_run.run(alloc, lead, opts);
        if (!std.mem.endsWith(u8, path, ".asm")) {
            std.debug.print("run: {s}: expected a .joe or .asm file\n", .{path});
            std.process.exit(2);
        }
        const dir = std.fs.path.dirname(path) orelse ".";
        const uses = sim.asm_run.usesOf(arena, lead) catch std.process.exit(1);
        var sources = std.ArrayList(sim.asm_run.Source).init(arena);
        try sources.append(.{ .name = std.fs.path.basename(path), .text = lead });
        for (uses) |u| {
            const upath = try std.fs.path.join(arena, &.{ dir, u });
            const text = std.fs.cwd().readFileAlloc(arena, upath, 1 << 20) catch |err| {
                std.debug.print("run: cannot read {s} (.use from {s}): {s}\n", .{ upath, path, @errorName(err) });
                std.process.exit(1);
            };
            try sources.append(.{ .name = u, .text = text });
        }
        return sim.asm_run.run(alloc, sources.items, opts);
    }

    if (std.mem.eql(u8, first, "joec")) {
        const path = args.next() orelse {
            std.debug.print("usage: sim6564 joec <file.joe> <Actor>\n", .{});
            std.process.exit(2);
        };
        const actor = args.next() orelse {
            std.debug.print("usage: sim6564 joec <file.joe> <Actor>\n", .{});
            std.process.exit(2);
        };
        const src = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |err| {
            std.debug.print("joec: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        defer alloc.free(src);
        var diag = sim.joe.Diagnostic{};
        var r = sim.joe.compile(alloc, src, actor, .{}, &diag) catch |err| {
            std.debug.print("joec: {s} line {d}: {s}\n", .{ @errorName(err), diag.line, diag.message });
            std.process.exit(1);
        };
        defer r.deinit();
        const stdout = std.io.getStdOut().writer();
        try stdout.print("{s}", .{r.asm_text});
        return;
    }

    if (std.mem.eql(u8, first, "mandel")) {
        var opts = sim.demo_mandel.Options{};
        if (args.next()) |s| opts.seed = parseOr(u64, s, "seed");
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_mandel.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "dies")) {
        var opts = sim.demo_dies.Options{};
        if (args.next()) |s| opts.dies = @min(16, parseOr(u16, s, "dies"));
        if (args.next()) |s| opts.nodes = @min(200, parseOr(u16, s, "nodes_per_die"));
        if (args.next()) |s| opts.laps = @min(1000, parseOr(u64, s, "laps"));
        while (args.next()) |s| {
            if (std.mem.eql(u8, s, "seq")) {
                opts.parallel = false;
            } else if (std.mem.eql(u8, s, "trace")) {
                opts.trace = true;
            } else if (std.meta.stringToEnum(sim.cluster.PinPolicy, s)) |p| {
                opts.pin = p;
            } else {
                opts.busy = @min(100_000, parseOr(u64, s, "busy_laps"));
            }
        }
        return sim.demo_dies.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "web")) {
        var opts = sim.demo_web.Options{};
        if (args.next()) |s| opts.host = s;
        if (args.next()) |s| opts.port = parseOr(u16, s, "port");
        if (args.next()) |s| opts.path = s;
        return sim.demo_web.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "net")) {
        const role_s = args.next() orelse usage(1);
        var opts: sim.demo_net.Options = undefined;
        if (std.mem.eql(u8, role_s, "listen")) {
            opts = .{ .role = .listener };
            if (args.next()) |s| opts.port = parseOr(u16, s, "port");
        } else if (std.mem.eql(u8, role_s, "connect")) {
            opts = .{ .role = .connector };
            if (args.next()) |s| opts.host = s;
            if (args.next()) |s| opts.port = parseOr(u16, s, "port");
        } else usage(1);
        if (args.next()) |s| opts.dies = @min(16, parseOr(u16, s, "dies"));
        if (args.next()) |s| opts.nodes = @min(200, parseOr(u16, s, "nodes_per_die"));
        if (args.next()) |s| opts.laps = @min(1000, parseOr(u64, s, "laps"));
        return sim.demo_net.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "churn")) {
        var opts = sim.demo_churn.Options{};
        if (args.next()) |s| opts.dies = @min(16, parseOr(u16, s, "dies"));
        if (args.next()) |s| opts.stripe_mb = @min(64, parseOr(u64, s, "stripe_mb"));
        if (args.next()) |s| opts.sweeps = @min(1000, parseOr(u64, s, "sweeps"));
        while (args.next()) |s| {
            if (std.mem.eql(u8, s, "seq")) {
                opts.parallel = false;
            } else if (std.mem.eql(u8, s, "trace")) {
                opts.trace = true;
            } else if (std.meta.stringToEnum(sim.cluster.PinPolicy, s)) |p| {
                opts.pin = p;
            }
        }
        return sim.demo_churn.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "periph")) {
        var opts = sim.demo_periph.Options{};
        if (args.next()) |s| opts.seed = parseOr(u64, s, "seed");
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_periph.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "bigbrother")) {
        var opts = sim.demo_bigbrother.Options{};
        if (args.next()) |s| opts.senders = @min(10_000, parseOr(u64, s, "senders"));
        if (args.next()) |s| opts.loss_ppm4k = @min(4096, parseOr(u16, s, "loss_ppm4k"));
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_bigbrother.run(alloc, opts);
    }

    if (std.mem.eql(u8, first, "forkjoin")) {
        var opts = sim.demo_forkjoin.Options{};
        if (args.next()) |s| opts.lieutenants = @min(16, parseOr(u16, s, "lieutenants"));
        if (args.next()) |s| opts.workers = @min(125, parseOr(u16, s, "workers"));
        if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
        return sim.demo_forkjoin.run(alloc, opts);
    }

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
