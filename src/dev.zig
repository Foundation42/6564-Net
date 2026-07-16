//! Native peripherals: devices are actors (§7).
//!
//! The 6564 has no I/O instructions because SEND and RECV *are* the I/O
//! instructions. A peripheral is a fabric endpoint at a well-known mesh
//! coordinate — rows $FF00..$FFFE of coordinate space are the peripheral
//! row ($FFFF stays the black hole; a device may never live there). You
//! reach a device through a PTT capability exactly as you reach an actor,
//! it can demand a token exactly as a ring does, and its reply lands in
//! your RX ring exactly as any message does. No MMIO, no interrupt
//! controller, no DMA engine distinct from the fabric: the RBC is the DMA
//! engine, and a device completion in your CQ is the interrupt.
//!
//! Replies follow the actor convention: the request payload carries a
//! window address *in the device's PTT space*, and the loader binds the
//! device's reply capability at attach time — wiring a driver to its
//! device is the same act as wiring any two actors together. Device
//! replies are fire-and-forget silicon on the ordinary fault-injected
//! fabric: they can be lost, so driver protocols are idempotent
//! request/retry — the same discipline every actor already lives by.
//!
//! This module is pure device policy: payload in, (status, optional reply)
//! out. machine.zig owns routing, capability checks, and the event queue.

const std = @import("std");
const ring = @import("ring.zig");

/// The peripheral row of mesh coordinate space.
pub const first_core: u16 = 0xFF00;
pub const last_core: u16 = 0xFFFE; // $FFFF is the black hole, never a device

/// PTT slots a device endpoint carries for its replies.
pub const ptt_slots = 16;

/// Largest single device reply (one block sector).
pub const reply_max = 512;

pub const Reply = struct {
    /// Window address in the DEVICE's PTT space, taken from the request.
    window: u64,
    data: std.BoundedArray(u8, reply_max) = .{},
};

pub const Result = struct {
    /// Rides the sender's ack: ok = the device accepted the request.
    /// reject_no_buffer = malformed or unserviceable request (the device
    /// had no place for it) — flow-control semantics, retry is sane.
    status: ring.Status = .ok,
    reply: ?Reply = null,
};

fn word(payload: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, payload[i * 8 ..][0..8], .little);
}

/// Requests that expect a reply lead with the reply window address.
fn replyWindow(payload: []const u8) ?u64 {
    if (payload.len < 8) return null;
    const w = word(payload, 0);
    return if (ring.isWindow(w)) w else null;
}

// ── Console: the teletype ────────────────────────────────────────────────
//
// Payload bytes are text, appended to the output stream. No header, no
// reply — SEND is PRINT. The delivery ack is the only receipt.

pub const Console = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .{},
    /// Write-through to the host terminal as bytes arrive (demos set this;
    /// tests read `out` instead).
    echo: bool = false,

    pub fn init(alloc: std.mem.Allocator) Console {
        return .{ .alloc = alloc };
    }

    fn handle(self: *Console, payload: []const u8) Result {
        self.out.appendSlice(self.alloc, payload) catch
            return .{ .status = .reject_no_buffer };
        if (self.echo) std.io.getStdOut().writer().writeAll(payload) catch {};
        return .{};
    }
};

// ── Entropy: seeded randomness as a service ──────────────────────────────
//
// Request: word0 = reply window, word1 = byte count (clamped to 64).
// Reply: that many bytes from the device's own seeded stream — a separate
// PRNG from the mesh's, so attaching the device never perturbs fault
// injection. Deterministic like everything else: same seed, same entropy.

pub const Entropy = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Entropy {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn handle(self: *Entropy, payload: []const u8) Result {
        const window = replyWindow(payload) orelse
            return .{ .status = .reject_no_buffer };
        if (payload.len < 16) return .{ .status = .reject_no_buffer };
        const count = @min(@max(word(payload, 1), 1), 64);
        var r = Reply{ .window = window };
        r.data.resize(@intCast(count)) catch unreachable;
        self.prng.random().bytes(r.data.slice());
        return .{ .reply = r };
    }
};

// ── RTC: what time is it on the fabric? ──────────────────────────────────
//
// Request: word0 = reply window. Reply: 8 bytes, the cycle at which the
// request reached the device. A device's clock is fabric time — the black
// hole gives software intervals (§6.3); the RTC gives it timestamps.

pub const Rtc = struct {
    fn handle(_: *Rtc, due: u64, payload: []const u8) Result {
        const window = replyWindow(payload) orelse
            return .{ .status = .reject_no_buffer };
        var r = Reply{ .window = window };
        r.data.resize(8) catch unreachable;
        std.mem.writeInt(u64, r.data.slice()[0..8], due, .little);
        return .{ .reply = r };
    }
};

// ── Block: sectors over the fabric ───────────────────────────────────────
//
// Request header (16 bytes):
//   word0 = op (0 read, 1 write) | sector << 8
//   word1 = reply window (reads; ignored for writes)
// Write: the bytes after the header land in the sector, applied at
// delivery — the fabric ack IS the write ack; there is nothing more to
// wait for. Read: the whole sector goes to the reply window (post a
// landing buffer at least a sector deep, or take `truncated` honestly).
// Both are idempotent by construction: lose a reply, just ask again.

pub const Block = struct {
    alloc: std.mem.Allocator,
    sector_size: u32,
    data: []u8,

    pub fn init(alloc: std.mem.Allocator, sectors: u32, sector_size: u32) !Block {
        std.debug.assert(sector_size >= 8 and sector_size <= reply_max);
        const data = try alloc.alloc(u8, @as(usize, sectors) * sector_size);
        @memset(data, 0);
        return .{ .alloc = alloc, .sector_size = sector_size, .data = data };
    }

    fn sector(self: *Block, idx: u64) ?[]u8 {
        const off = idx * self.sector_size;
        if (off + self.sector_size > self.data.len) return null;
        return self.data[@intCast(off)..][0..self.sector_size];
    }

    fn handle(self: *Block, payload: []const u8) Result {
        if (payload.len < 16) return .{ .status = .reject_no_buffer };
        const op = word(payload, 0) & 0xFF;
        const sec = self.sector(word(payload, 0) >> 8) orelse
            return .{ .status = .reject_no_buffer };
        switch (op) {
            0 => {
                const window = replyWindow(payload[8..]) orelse
                    return .{ .status = .reject_no_buffer };
                var r = Reply{ .window = window };
                r.data.appendSlice(sec) catch unreachable;
                return .{ .reply = r };
            },
            1 => {
                const body = payload[16..];
                const n = @min(body.len, sec.len);
                @memcpy(sec[0..n], body[0..n]);
                return .{ .status = if (n < body.len) .truncated else .ok };
            },
            else => return .{ .status = .reject_no_buffer },
        }
    }
};

// ── The device itself ────────────────────────────────────────────────────

pub const Device = union(enum) {
    console: Console,
    entropy: Entropy,
    rtc: Rtc,
    block: Block,

    /// One request, delivered at fabric time `due`.
    pub fn handle(self: *Device, due: u64, payload: []const u8) Result {
        return switch (self.*) {
            .console => |*d| d.handle(payload),
            .entropy => |*d| d.handle(payload),
            .rtc => |*d| d.handle(due, payload),
            .block => |*d| d.handle(payload),
        };
    }

    pub fn deinit(self: *Device) void {
        switch (self.*) {
            .console => |*d| d.out.deinit(d.alloc),
            .block => |*d| d.alloc.free(d.data),
            else => {},
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "console accumulates text" {
    var d = Device{ .console = Console.init(std.testing.allocator) };
    defer d.deinit();
    try std.testing.expectEqual(ring.Status.ok, d.handle(0, "HELLO ").status);
    try std.testing.expectEqual(ring.Status.ok, d.handle(0, "WORLD").status);
    try std.testing.expectEqualStrings("HELLO WORLD", d.console.out.items);
}

test "entropy is deterministic from seed and clamps count" {
    var a = Device{ .entropy = Entropy.init(42) };
    var b = Device{ .entropy = Entropy.init(42) };
    var req: [16]u8 = undefined;
    std.mem.writeInt(u64, req[0..8], ring.windowAddr(3, 0), .little);
    std.mem.writeInt(u64, req[8..16], 8, .little);
    const ra = a.handle(0, &req).reply.?;
    const rb = b.handle(0, &req).reply.?;
    try std.testing.expectEqualSlices(u8, ra.data.slice(), rb.data.slice());
    try std.testing.expectEqual(@as(usize, 8), ra.data.len);
    std.mem.writeInt(u64, req[8..16], 4096, .little);
    try std.testing.expectEqual(@as(usize, 64), a.handle(0, &req).reply.?.data.len);
}

test "rtc replies with fabric time" {
    var d = Device{ .rtc = .{} };
    var req: [8]u8 = undefined;
    std.mem.writeInt(u64, req[0..8], ring.windowAddr(1, 0), .little);
    const r = d.handle(6564, &req).reply.?;
    try std.testing.expectEqual(
        @as(u64, 6564),
        std.mem.readInt(u64, r.data.slice()[0..8], .little),
    );
}

test "block round-trips a sector and rejects the void" {
    var d = Device{ .block = try Block.init(std.testing.allocator, 4, 64) };
    defer d.deinit();
    var wr: [24]u8 = undefined;
    std.mem.writeInt(u64, wr[0..8], 1 | (2 << 8), .little); // write sector 2
    std.mem.writeInt(u64, wr[8..16], 0, .little);
    std.mem.writeInt(u64, wr[16..24], 0x6564_6564_6564_6564, .little);
    try std.testing.expectEqual(ring.Status.ok, d.handle(0, &wr).status);

    var rd: [16]u8 = undefined;
    std.mem.writeInt(u64, rd[0..8], 0 | (2 << 8), .little); // read sector 2
    std.mem.writeInt(u64, rd[8..16], ring.windowAddr(0, 0), .little);
    const r = d.handle(0, &rd).reply.?;
    try std.testing.expectEqual(@as(usize, 64), r.data.len);
    try std.testing.expectEqual(
        @as(u64, 0x6564_6564_6564_6564),
        std.mem.readInt(u64, r.data.slice()[0..8], .little),
    );

    std.mem.writeInt(u64, rd[0..8], 0 | (9 << 8), .little); // no sector 9
    try std.testing.expectEqual(ring.Status.reject_no_buffer, d.handle(0, &rd).status);
}
