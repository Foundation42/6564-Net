//! sim6564 CLI — demo dispatcher.
//!
//!   sim6564 [pingpong] [seed] [loss_ppm4k] [rounds] [trace]
//!       Two actors bounce a value across a lossy, duplicating, reordering
//!       fabric; ping runs an end-to-end reliable protocol (programs/ping.asm,
//!       programs/pong.asm).
//!
//!   sim6564 supervise [trace]
//!       A one-for-one supervision tree: exit links and SPWN keep a crashing
//!       worker alive until the restart budget says otherwise
//!       (programs/supervisor.asm, programs/worker.asm).

const std = @import("std");
const sim = @import("sim6564");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const first = args.next() orelse
        return sim.demo_pingpong.run(alloc, .{});

    if (std.mem.eql(u8, first, "supervise")) {
        const trace = if (args.next()) |s| std.mem.eql(u8, s, "trace") else false;
        return sim.demo_supervise.run(alloc, .{ .trace = trace });
    }

    // Everything else is the ping-pong demo; a bare first argument is the
    // seed (back-compatible with the original positional CLI).
    var opts = sim.demo_pingpong.Options{};
    if (!std.mem.eql(u8, first, "pingpong"))
        opts.seed = try std.fmt.parseInt(u64, first, 0)
    else if (args.next()) |s|
        opts.seed = try std.fmt.parseInt(u64, s, 0);
    if (args.next()) |s| opts.loss_ppm4k = @min(4096, try std.fmt.parseInt(u16, s, 0));
    if (args.next()) |s| opts.rounds = @min(100, try std.fmt.parseInt(u64, s, 0));
    if (args.next()) |s| opts.trace = std.mem.eql(u8, s, "trace");
    try sim.demo_pingpong.run(alloc, opts);
}
