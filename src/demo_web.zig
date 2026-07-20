//! The capstone: a 6564 fetches a real web page. The net device (§7.4)
//! is a raw byte pipe to actual TCP; HTTP/1.1 lives in http_get.asm —
//! §7.5's polyfill layer in its simplest form. The console shows exactly
//! what came down the wire, live.
//!
//! This is the one demo that is NOT deterministic: the outside world
//! does not replay. Everything on our side of the socket still does.

const std = @import("std");
const ring = @import("ring.zig");
const dev = @import("dev.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");

const http_src = @embedFile("programs/asm/http_get.asm");

pub const console_coord: u16 = 0xFF00;
pub const net_coord: u16 = 0xFF04;

pub const Options = struct {
    host: []const u8 = "example.com",
    port: u16 = 80,
    path: []const u8 = "/",
    /// Print bytes to the terminal as the machine speaks them.
    echo: bool = false,
    trace: bool = false,
};

pub const Outcome = struct {
    reason: machine.StopReason,
    /// The console transcript — the raw HTTP response. Caller owns.
    text: []u8,
    cycles: u64,
    stats: machine.Stats,
};

pub fn simulate(alloc: std.mem.Allocator, opts: Options) !Outcome {
    var m = try machine.Machine.init(alloc, .{
        .cores = 1,
        .contexts_per_core = 1,
        .ram_size = 0x8000,
        .link = .{ .base_latency = 200, .jitter = 120, .send_timeout = 2500 },
        .max_cycles = 100_000_000,
        .trace = opts.trace,
    });
    defer m.deinit();

    try m.attachDevice(console_coord, 0x6564, dev.Console.init(alloc));
    if (opts.echo) m.deviceAs(console_coord, dev.Console).?.echo = true;
    try m.attachDevice(net_coord, 0x6564, dev.Net.init(alloc));

    for ([_]struct { slot: u16, coord: u16 }{
        .{ .slot = 0, .coord = console_coord },
        .{ .slot = 1, .coord = net_coord },
    }) |c| {
        m.setPtt(0, c.slot, .{
            .prefix_hi = 0xfd65_6400_0000_0000,
            .prefix_lo = ring.PttEntry.loFrom(c.coord, 0, 0),
            .rights = .{ .send = true },
            .token = 0x6564,
        });
    }
    m.setDevicePtt(net_coord, 0, .{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = ring.PttEntry.loFrom(0, 0, ring.slot_rx),
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
    var prog = asm6564.assemble(alloc, http_src, &diag) catch |err| {
        std.debug.print("web asm error line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer prog.deinit();
    m.load(0, prog.origin, prog.code);

    // Stage the strings and their lengths where http_get.asm expects them:
    // host 32 bytes into the open cell, the GET 24 bytes into the send
    // cell (the echoed-tag framing's request headers, §7.3 addendum).
    m.load(0, 0x2520, opts.host);
    const req_text = try std.fmt.allocPrint(
        alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: sim6564\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        .{ opts.path, opts.host },
    );
    defer alloc.free(req_text);
    m.load(0, 0x2618, req_text);
    var w8: [8]u8 = undefined;
    std.mem.writeInt(u64, &w8, opts.port, .little);
    m.writeNear(0, 0, 0x8A8, &w8);
    std.mem.writeInt(u64, &w8, 32 + opts.host.len, .little);
    m.writeNear(0, 0, 0x8B0, &w8);
    std.mem.writeInt(u64, &w8, 24 + req_text.len, .little);
    m.writeNear(0, 0, 0x8B8, &w8);

    try m.spawn(0, 0, 0x1000, 0x3000, 0);
    const reason = try m.run();

    return .{
        .reason = reason,
        .text = try alloc.dupe(u8, m.deviceAs(console_coord, dev.Console).?.out.items),
        .cycles = m.cores[0].clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, opts_in: Options) !void {
    var opts = opts_in;
    opts.echo = true;
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "sim6564 — http_get.asm fetches http://{s}:{d}{s} through the net device\n\n",
        .{ opts.host, opts.port, opts.path },
    );
    const o = try simulate(alloc, opts);
    defer alloc.free(o.text);
    try stdout.print(
        \\
        \\  outcome: {s} — {d} bytes received in {d} virtual cycles
        \\  fabric: {d} sends, {d} device deliveries, {d} device replies,
        \\          {d} instructions (protocol in 6564 code, §7.5)
        \\
    , .{
        @tagName(o.reason),
        o.text.len,
        o.cycles,
        o.stats.sends,
        o.stats.dev_deliveries,
        o.stats.dev_replies,
        o.stats.instructions,
    });
    if (o.reason != .all_halted) std.process.exit(1);
}
