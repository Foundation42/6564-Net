//! The socket bridge: §6.5's IO plane between HOST PROCESSES. Two
//! sim6564 processes, each running a Cluster with its own node_base,
//! exchange window barriers over a TCP stream — frames of virtual-time-
//! stamped datagrams. The wall clock never enters the virtual machine:
//! due-times on the wire are virtual cycles, both sides advance in
//! lock-step windows, and the whole federation replays bit-identically
//! from its seeds no matter what the real network does. TCP is just a
//! slow backplane.
//!
//! Protocol (all little-endian):
//!   HELLO  magic "6564" | version u16 | node_base u16 | dies u16 |
//!          window u64 | seed u64
//!   FRAME  window u64 | quiescent u8 | count u32 | count x ITEM
//!   ITEM   dst_die u16 | src_die u16 | seq u64 | due u64 | kind u8
//!          kind 0 (gram): send_id u64 | gram_src_die u16 | dst_core u16 |
//!            dst_ctx u8 | dst_slot u8 | offset u64 | token u64 |
//!            len u32 | len bytes
//!          kind 1 (ack): send_id u64 | status u8 | byte_count u32
//!
//! Each window both sides send their frame, then read the peer's — a
//! true barrier. Frames are small and sockets buffer, so write-then-read
//! cannot deadlock at these sizes.

const std = @import("std");
const ring = @import("ring.zig");
const mesh = @import("mesh.zig");
const cluster = @import("cluster.zig");

pub const version: u16 = 1;
const magic = "6564";
pub const max_payload = 1 << 20; // a wire-sanity bound, not an architecture

pub const Bridge = struct {
    stream: std.net.Stream,
    /// Persistent read buffer: a frame's bytes may be read ahead, so the
    /// buffered reader must live as long as the connection.
    br: Buffered = undefined,
    /// Peer identity, learned from HELLO.
    peer_base: u16 = 0,
    peer_dies: u16 = 0,

    const Buffered = std.io.BufferedReader(4096, std.net.Stream.Reader);

    fn wrap(stream: std.net.Stream) Bridge {
        var b = Bridge{ .stream = stream };
        b.br = .{ .unbuffered_reader = stream.reader() };
        return b;
    }

    pub fn deinit(self: *Bridge) void {
        self.stream.close();
    }

    /// Wait for exactly one peer on `port` (0 = ephemeral; see
    /// `listenOn` for retrieving the bound port).
    pub fn listen(port: u16) !Bridge {
        var server = try listenOn(port);
        defer server.deinit();
        return accept(&server);
    }

    pub fn listenOn(port: u16) !std.net.Server {
        const addr = try std.net.Address.parseIp("0.0.0.0", port);
        return addr.listen(.{ .reuse_address = true });
    }

    pub fn accept(server: *std.net.Server) !Bridge {
        const conn = try server.accept();
        return wrap(conn.stream);
    }

    pub fn connect(host: []const u8, port: u16) !Bridge {
        const addr = try std.net.Address.parseIp(host, port);
        return wrap(try std.net.tcpConnectToAddress(addr));
    }

    /// Exchange HELLOs and verify the federation is coherent: same
    /// protocol, same window, same seed, disjoint die-id ranges.
    pub fn hello(self: *Bridge, cl: *const cluster.Cluster) !void {
        var w = self.stream.writer();
        try w.writeAll(magic);
        try w.writeInt(u16, version, .little);
        try w.writeInt(u16, cl.cfg.node_base, .little);
        try w.writeInt(u16, @intCast(cl.dies.len), .little);
        try w.writeInt(u64, cl.window, .little);
        try w.writeInt(u64, cl.cfg.seed, .little);

        var r = self.stream.reader();
        var m: [4]u8 = undefined;
        try r.readNoEof(&m);
        if (!std.mem.eql(u8, &m, magic)) return error.BadMagic;
        if (try r.readInt(u16, .little) != version) return error.VersionMismatch;
        self.peer_base = try r.readInt(u16, .little);
        self.peer_dies = try r.readInt(u16, .little);
        if (try r.readInt(u64, .little) != cl.window) return error.WindowMismatch;
        if (try r.readInt(u64, .little) != cl.cfg.seed) return error.SeedMismatch;
        const my_lo = cl.cfg.node_base;
        const my_hi = my_lo + cl.dies.len;
        if (self.peer_base < my_hi and self.peer_base + self.peer_dies > my_lo)
            return error.DieRangeOverlap;
    }

    /// The cluster.Exchange implementation: ship this window's outgoing
    /// items, then block on the peer's frame for the same window and
    /// inject it. Lock-step by construction.
    pub fn swap(
        ctx: *anyopaque,
        cl: *cluster.Cluster,
        window: u64,
        quiescent: bool,
        outgoing: []const cluster.Queued,
    ) anyerror!cluster.ExchangeResult {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        var bw = std.io.bufferedWriter(self.stream.writer());
        const w = bw.writer();
        try w.writeInt(u64, window, .little);
        try w.writeByte(@intFromBool(quiescent));
        try w.writeInt(u32, @intCast(outgoing.len), .little);
        for (outgoing) |q| {
            try w.writeInt(u16, q.dst_die, .little);
            try w.writeInt(u16, q.src_die, .little);
            try w.writeInt(u64, q.seq, .little);
            try w.writeInt(u64, q.due, .little);
            switch (q.kind) {
                .gram => |g| {
                    try w.writeByte(0);
                    try w.writeInt(u64, g.send_id, .little);
                    try w.writeInt(u16, g.src_die, .little);
                    try w.writeInt(u16, g.dst_core, .little);
                    try w.writeByte(g.dst_ctx);
                    try w.writeByte(g.dst_slot);
                    try w.writeInt(u64, g.offset, .little);
                    try w.writeInt(u64, g.token, .little);
                    try w.writeInt(u32, @intCast(g.payload.len), .little);
                    try w.writeAll(g.payload);
                },
                .ack => |a| {
                    try w.writeByte(1);
                    try w.writeInt(u64, a.send_id, .little);
                    try w.writeByte(@intFromEnum(a.status));
                    try w.writeInt(u32, a.byte_count, .little);
                },
            }
        }
        try bw.flush();

        const r = self.br.reader();
        const peer_window = try r.readInt(u64, .little);
        if (peer_window != window) return error.WindowSkew;
        const peer_quiescent = (try r.readByte()) != 0;
        const count = try r.readInt(u32, .little);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var q = cluster.Queued{
                .dst_die = try r.readInt(u16, .little),
                .src_die = try r.readInt(u16, .little),
                .seq = try r.readInt(u64, .little),
                .due = try r.readInt(u64, .little),
                .kind = undefined,
            };
            switch (try r.readByte()) {
                0 => {
                    var g = mesh.Datagram{
                        .send_id = try r.readInt(u64, .little),
                        .src_die = try r.readInt(u16, .little),
                        .dst_core = try r.readInt(u16, .little),
                        .dst_ctx = try r.readByte(),
                        .dst_slot = try r.readByte(),
                        .offset = try r.readInt(u64, .little),
                        .token = try r.readInt(u64, .little),
                        .payload = undefined,
                    };
                    const len = try r.readInt(u32, .little);
                    if (len > max_payload) return error.PayloadTooLarge;
                    const buf = try cl.alloc.alloc(u8, len);
                    errdefer cl.alloc.free(buf);
                    try r.readNoEof(buf);
                    g.payload = buf;
                    q.kind = .{ .gram = g };
                },
                1 => {
                    const send_id = try r.readInt(u64, .little);
                    const status_byte = try r.readByte();
                    if (status_byte > @intFromEnum(ring.Status.chain_cancelled))
                        return error.BadStatus;
                    q.kind = .{ .ack = .{
                        .send_id = send_id,
                        .status = @enumFromInt(status_byte),
                        .byte_count = try r.readInt(u32, .little),
                    } };
                },
                else => return error.BadItemKind,
            }
            try cl.injectItem(q);
        }
        return .{ .peer_quiescent = peer_quiescent, .received_any = count != 0 };
    }

    pub fn exchange(self: *Bridge) cluster.Exchange {
        return .{ .ctx = self, .swap = swap };
    }
};
