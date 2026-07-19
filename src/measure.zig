//! The measurement harness for the MAC & chains go/no-go plan (see
//! docs/6564-mac-and-chains-sketch.md §6). Runs every demo at its frozen
//! baseline configuration and reports, per demo: assembled code bytes,
//! executed instructions, cycles to completion, and feature fire counts.
//! All seeds fixed; fault injection on. Emits a markdown table so a run's
//! output can be committed verbatim as the before/after record.

const std = @import("std");
const asm6564 = @import("asm.zig");
const machine = @import("machine.zig");
const demo_pingpong = @import("demo_pingpong.zig");
const demo_supervise = @import("demo_supervise.zig");
const demo_pipeline = @import("demo_pipeline.zig");
const demo_scatter = @import("demo_scatter.zig");
const demo_ring = @import("demo_ring.zig");

const Row = struct {
    name: []const u8,
    code_bytes: usize,
    instructions: u64,
    cycles: u64,
    context_switches: u64,
    ok: bool,
};

const sources = struct {
    const pingpong = [_][]const u8{
        @embedFile("programs/asm/ping.asm"),
        @embedFile("programs/asm/pong.asm"),
    };
    const supervise = [_][]const u8{
        @embedFile("programs/asm/supervisor.asm"),
        @embedFile("programs/asm/worker.asm"),
    };
    const pipeline = [_][]const u8{
        @embedFile("programs/asm/pipe_source.asm"),
        @embedFile("programs/asm/pipe_stage.asm"),
        @embedFile("programs/asm/pipe_sink.asm"),
    };
    const scatter = [_][]const u8{
        @embedFile("programs/asm/scatter_coord.asm"),
        @embedFile("programs/asm/scatter_worker.asm"),
    };
    const ring = [_][]const u8{
        @embedFile("programs/asm/ring_node.asm"),
    };
};

fn codeBytes(alloc: std.mem.Allocator, srcs: []const []const u8) !usize {
    var total: usize = 0;
    for (srcs) |src| {
        var out = try asm6564.assemble(alloc, src, null);
        defer out.deinit();
        total += out.code.len;
    }
    return total;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var rows: [5]Row = undefined;

    { // pingpong: seed 0x6564, 25% loss, 8 rounds
        const o = try demo_pingpong.simulate(alloc, .{ .seed = 0x6564, .loss_ppm4k = 1024, .rounds = 8 });
        rows[0] = .{
            .name = "pingpong (0x6564/1024/8)",
            .code_bytes = try codeBytes(alloc, &sources.pingpong),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.ping_halted and o.final == 8,
        };
    }
    { // supervise: fixed scenario
        const o = try demo_supervise.simulate(alloc, false);
        rows[1] = .{
            .name = "supervise (fixed)",
            .code_bytes = try codeBytes(alloc, &sources.supervise),
            .instructions = o.instructions,
            .cycles = o.cycles,
            .context_switches = 0, // per-run stat folded into instructions story
            .ok = o.supervisor_halted and o.restarts == 5,
        };
    }
    { // pipeline: seed 0x6564, 25% loss, 16 items, 2 stages
        const o = try demo_pipeline.simulate(alloc, .{ .seed = 0x6564, .loss_ppm4k = 1024, .items = 16, .stages = 2 });
        rows[2] = .{
            .name = "pipeline (0x6564/1024/16/2)",
            .code_bytes = try codeBytes(alloc, &sources.pipeline),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.source_halted and o.stages_done and o.checksum == o.expected_checksum,
        };
    }
    { // scatter: seed 0x6564, 25% loss, 6 workers
        const o = try demo_scatter.simulate(alloc, .{ .seed = 0x6564, .loss_ppm4k = 1024, .workers = 6 });
        rows[3] = .{
            .name = "scatter (0x6564/1024/6)",
            .code_bytes = try codeBytes(alloc, &sources.scatter),
            .instructions = o.stats.instructions,
            .cycles = o.cycles,
            .context_switches = o.stats.context_switches,
            .ok = o.coordinator_halted and o.sum == o.expected_sum,
        };
    }
    { // ring: 64 nodes, 100 laps
        const o = try demo_ring.simulate(alloc, .{ .nodes = 64, .laps = 100 });
        rows[4] = .{
            .name = "ring (64x100)",
            .code_bytes = try codeBytes(alloc, &sources.ring),
            .instructions = o.instructions,
            .cycles = o.cycles,
            .context_switches = o.context_switches,
            .ok = o.exactly_one_finisher and o.finisher_is_node0 and o.cycles_per_pass < 100,
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
