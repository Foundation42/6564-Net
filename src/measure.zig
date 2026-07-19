//! The measurement harness for the MAC & chains go/no-go plan (see
//! docs/6564-mac-and-chains-sketch.md §6). Runs every classic workload at
//! its frozen baseline configuration and reports, per program: assembled
//! code bytes, executed instructions, cycles to completion, and feature
//! fire counts. All seeds fixed; fault injection on. Emits a markdown
//! table so a run's output can be committed verbatim as the before/after
//! record.
//!
//! Since the harness retirement, every workload runs through the generic
//! loader (src/asm_run.zig) from the programs' own contracts — the same
//! path `sim6564 run` takes. One historical note: scatter's baseline
//! moved from 6 workers to the contract's full 8 when the fan-out chain
//! became part of the program's deployment.

const std = @import("std");
const asm6564 = @import("asm.zig");
const asm_run = @import("asm_run.zig");
const machine = @import("machine.zig");

const Row = struct {
    name: []const u8,
    code_bytes: usize,
    instructions: u64,
    cycles: u64,
    context_switches: u64,
    ok: bool,
};

const sources = struct {
    const pingpong = [_]asm_run.Source{
        .{ .name = "ping.asm", .text = @embedFile("programs/asm/ping.asm") },
        .{ .name = "pong.asm", .text = @embedFile("programs/asm/pong.asm") },
    };
    const supervise = [_]asm_run.Source{
        .{ .name = "supervisor.asm", .text = @embedFile("programs/asm/supervisor.asm") },
        .{ .name = "worker.asm", .text = @embedFile("programs/asm/worker.asm") },
    };
    const pipeline = [_]asm_run.Source{
        .{ .name = "pipe_source.asm", .text = @embedFile("programs/asm/pipe_source.asm") },
        .{ .name = "pipe_stage.asm", .text = @embedFile("programs/asm/pipe_stage.asm") },
        .{ .name = "pipe_sink.asm", .text = @embedFile("programs/asm/pipe_sink.asm") },
    };
    const scatter = [_]asm_run.Source{
        .{ .name = "scatter_coord.asm", .text = @embedFile("programs/asm/scatter_coord.asm") },
        .{ .name = "scatter_worker.asm", .text = @embedFile("programs/asm/scatter_worker.asm") },
    };
    const ring = [_]asm_run.Source{
        .{ .name = "ring_node.asm", .text = @embedFile("programs/asm/ring_node.asm") },
    };
};

fn codeBytes(alloc: std.mem.Allocator, srcs: []const asm_run.Source) !usize {
    var total: usize = 0;
    for (srcs) |src| {
        var out = try asm6564.assemble(alloc, src.text, null);
        defer out.deinit();
        total += out.code.len;
    }
    return total;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var rows: [5]Row = undefined;

    { // pingpong: seed 0x6564, 25% loss, 8 rounds (the contract's default)
        var o = try asm_run.simulate(alloc, &sources.pingpong, .{ .loss_ppm4k = 1024 });
        defer o.deinit();
        rows[0] = .{
            .name = "pingpong (0x6564/1024/8)",
            .code_bytes = try codeBytes(alloc, &sources.pingpong),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.instance("p").?.state == .halted and o.varOf("p", "final") == 8,
        };
    }
    { // supervise: fixed scenario
        var o = try asm_run.simulate(alloc, &sources.supervise, .{});
        defer o.deinit();
        rows[1] = .{
            .name = "supervise (fixed)",
            .code_bytes = try codeBytes(alloc, &sources.supervise),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = 0, // per-run stat folded into instructions story
            .ok = o.instance("sup").?.state == .halted and o.varOf("sup", "restarts") == 5,
        };
    }
    { // pipeline: seed 0x6564, 25% loss, 16 items, 2 stages
        const sys = try asm_run.pipelineSystem(alloc, 16, 2);
        defer alloc.free(sys);
        var o = try asm_run.simulateSystem(alloc, &sources.pipeline, sys, .{ .loss_ppm4k = 1024 });
        defer o.deinit();
        rows[2] = .{
            .name = "pipeline (0x6564/1024/16/2)",
            .code_bytes = try codeBytes(alloc, &sources.pipeline),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.instance("source").?.state == .halted and
                o.varOf("s1", "phase") == 2 and o.varOf("s2", "phase") == 2 and
                o.varOf("sink", "checksum") == 4 * (16 * 17 / 2) - 16,
        };
    }
    { // scatter: seed 0x6564, 25% loss, the contract's 8 workers
        var o = try asm_run.simulate(alloc, &sources.scatter, .{ .loss_ppm4k = 1024 });
        defer o.deinit();
        rows[3] = .{
            .name = "scatter (0x6564/1024/8)",
            .code_bytes = try codeBytes(alloc, &sources.scatter),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.instance("c").?.state == .halted and o.varOf("c", "sum") == 492,
        };
    }
    { // ring: 64 nodes, 100 laps
        const sys = try asm_run.ringSystem(alloc, 64, 100);
        defer alloc.free(sys);
        var o = try asm_run.simulateSystem(alloc, &sources.ring, sys, .{});
        defer o.deinit();
        rows[4] = .{
            .name = "ring (64x100)",
            .code_bytes = try codeBytes(alloc, &sources.ring),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.varOf("n0", "finisher") == 1 and o.cycles / 6400 < 100,
        };
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\## sim6564 measurements (fixed seeds, fault injection on)
        \\
        \\| demo | code bytes | instructions | cycles | ctx switches | verified |
        \\|---|---:|---:|---:|---:|---|
        \\
    );
    var totals = Row{ .name = "**total**", .code_bytes = 0, .instructions = 0, .cycles = 0, .context_switches = 0, .ok = true };
    for (rows) |r| {
        try stdout.print("| {s} | {d} | {d} | {d} | {d} | {s} |\n", .{
            r.name,             r.code_bytes,
            r.instructions,     r.cycles,
            r.context_switches, if (r.ok) "yes" else "**NO**",
        });
        totals.code_bytes += r.code_bytes;
        totals.instructions += r.instructions;
        totals.cycles += r.cycles;
        totals.context_switches += r.context_switches;
        totals.ok = totals.ok and r.ok;
    }
    try stdout.print("| {s} | {d} | {d} | {d} | {d} | {s} |\n", .{
        totals.name,             totals.code_bytes,
        totals.instructions,     totals.cycles,
        totals.context_switches, if (totals.ok) "yes" else "**NO**",
    });
    if (!totals.ok) std.process.exit(1);
}
