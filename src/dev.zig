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
//! The echoed tag (§7.3 addendum, Amendment 3): every asking device's
//! request begins with a CALLER-TAG word the silicon never interprets
//! and echoes verbatim as the reply's first word — the accelerator
//! contract's reserved word, generalized. The reply wears the tag you
//! gave it, so a serve loop can match it like any message. Uniform
//! framing for Entropy/Rtc/Block/Net: word0 = tag, word1 = reply
//! window, args from word2; reply = echoed tag, then data from +8.
//! The Console is a raw sink — payload is text, no header, no reply —
//! and stays one.
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

/// Requests that expect a reply: word0 = caller tag, word1 = the reply
/// window address (in the device's PTT space).
fn replyWindow(payload: []const u8) ?u64 {
    if (payload.len < 16) return null;
    const w = word(payload, 1);
    return if (ring.isWindow(w)) w else null;
}

/// Start a reply with the request's echoed tag word (§7.3 addendum).
fn tagged(window: u64, payload: []const u8) Reply {
    var r = Reply{ .window = window };
    r.data.appendSlice(payload[0..8]) catch unreachable;
    return r;
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
// Request: word0 = tag, word1 = reply window, word2 = byte count
// (clamped to 64). Reply: the echoed tag, then that many bytes from the
// device's own seeded stream — a separate PRNG from the mesh's, so
// attaching the device never perturbs fault injection. Deterministic
// like everything else: same seed, same entropy.

pub const Entropy = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Entropy {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn handle(self: *Entropy, payload: []const u8) Result {
        const window = replyWindow(payload) orelse
            return .{ .status = .reject_no_buffer };
        if (payload.len < 24) return .{ .status = .reject_no_buffer };
        const count = @min(@max(word(payload, 2), 1), 64);
        var r = tagged(window, payload);
        r.data.resize(@intCast(8 + count)) catch unreachable;
        self.prng.random().bytes(r.data.slice()[8..]);
        return .{ .reply = r };
    }
};

// ── RTC: what time is it on the fabric? ──────────────────────────────────
//
// Request: word0 = tag, word1 = reply window. Reply: the echoed tag,
// then 8 bytes — the cycle at which the request reached the device. A
// device's clock is fabric time: the black hole gives software intervals
// (§6.3); the RTC gives it timestamps.

pub const Rtc = struct {
    fn handle(_: *Rtc, due: u64, payload: []const u8) Result {
        const window = replyWindow(payload) orelse
            return .{ .status = .reject_no_buffer };
        var r = tagged(window, payload);
        r.data.resize(16) catch unreachable;
        std.mem.writeInt(u64, r.data.slice()[8..16], due, .little);
        return .{ .reply = r };
    }
};

// ── Block: sectors over the fabric ───────────────────────────────────────
//
// Request header (24 bytes):
//   word0 = tag   word1 = reply window (reads; present, ignored, for
//   writes — one framing per device)   word2 = op (0 read, 1 write)
//   | sector << 8
// Write: the bytes after the header land in the sector, applied at
// delivery — the fabric ack IS the write ack; there is nothing more to
// wait for. Read: the echoed tag, then the whole sector, to the reply
// window (post a landing buffer at least tag + sector deep, or take
// `truncated` honestly). Both idempotent: lose a reply, just ask again.

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
        if (payload.len < 24) return .{ .status = .reject_no_buffer };
        const op = word(payload, 2) & 0xFF;
        const sec = self.sector(word(payload, 2) >> 8) orelse
            return .{ .status = .reject_no_buffer };
        switch (op) {
            0 => {
                const window = replyWindow(payload) orelse
                    return .{ .status = .reject_no_buffer };
                var r = tagged(window, payload);
                r.data.appendSlice(sec) catch unreachable;
                return .{ .reply = r };
            },
            1 => {
                const body = payload[24..];
                const n = @min(body.len, sec.len);
                @memcpy(sec[0..n], body[0..n]);
                if (n < body.len) return .{ .status = .truncated };
                // The reply window IS the request for a reply: leave a
                // return address on a write and the device echoes your
                // tag when the sector is yours — a sequencing point for
                // drivers that cannot see transport verdicts. Leave none
                // (the window word zero) and the fabric ack is the whole
                // receipt, as it always was.
                if (replyWindow(payload)) |window|
                    return .{ .reply = tagged(window, payload) };
                return .{};
            },
            else => return .{ .status = .reject_no_buffer },
        }
    }
};

// ── Net: the byte-pipe to the outside world ──────────────────────────────
//
// The NIC-as-device (§7.4's predicted fifth citizen): raw TCP, no
// protocol opinion — HTTP, WebSockets, TLS are PROTOCOL ACTORS layered
// above (§7.5), in silicon or in 6564 code, and clients can't tell.
//
// Requests (word0 = tag, word1 = reply window, word2 = op | conn << 8):
//   op 0 open:  word3 = port, bytes[32..] = host.
//               Reply: tag, then 8 bytes — the connection id.
//   op 1 send:  bytes[24..] go down the pipe. The ack is the write ack.
//   op 2 recv:  word3 = max bytes (≤ 240 sane).
//               Reply: tag, then 0..max bytes; TAG-ONLY (8 bytes) means
//               "nothing yet, ask again" — and a REJECTED request means
//               EOF/closed: the ack vocabulary still suffices.
//   op 3 close: done. Ack ok.
//
// This is the one device that touches wall-clock reality: DNS, connect
// and a bounded poll happen inside `handle`, and the outside world does
// not replay. Determinism stays scoped to everything on our side of the
// socket (§7.5); a machine without a Net attached replays exactly as
// before.

pub const Net = struct {
    alloc: std.mem.Allocator,
    conns: [4]?std.net.Stream = @splat(null),
    /// How long a recv with no data may hold the event loop, real ms.
    poll_ms: i32 = 25,

    pub fn init(alloc: std.mem.Allocator) Net {
        return .{ .alloc = alloc };
    }

    fn free(self: *Net) ?usize {
        for (&self.conns, 0..) |*c, i| {
            if (c.* == null) return i;
        }
        return null;
    }

    fn handle(self: *Net, payload: []const u8) Result {
        if (payload.len < 24) return .{ .status = .reject_no_buffer };
        const op = word(payload, 2) & 0xFF;
        const conn_id = (word(payload, 2) >> 8) & 0xFF;
        switch (op) {
            0 => { // open
                if (payload.len < 33) return .{ .status = .reject_no_buffer };
                const window = replyWindow(payload) orelse
                    return .{ .status = .reject_no_buffer };
                const port: u16 = @truncate(word(payload, 3));
                const slot = self.free() orelse
                    return .{ .status = .reject_no_buffer };
                const host = payload[32..];
                const stream = std.net.tcpConnectToHost(self.alloc, host, port) catch
                    return .{ .status = .reject_no_buffer };
                self.conns[slot] = stream;
                var r = tagged(window, payload);
                r.data.resize(16) catch unreachable;
                std.mem.writeInt(u64, r.data.slice()[8..16], slot, .little);
                return .{ .reply = r };
            },
            1 => { // send
                const c = if (conn_id < self.conns.len) self.conns[conn_id] else null;
                const stream = c orelse return .{ .status = .reject_no_buffer };
                stream.writeAll(payload[24..]) catch
                    return .{ .status = .reject_no_buffer };
                // A return address asks for an echo when the bytes are
                // down the pipe (see Block's write).
                if (replyWindow(payload)) |window|
                    return .{ .reply = tagged(window, payload) };
                return .{};
            },
            2 => { // recv
                if (payload.len < 32) return .{ .status = .reject_no_buffer };
                const window = replyWindow(payload) orelse
                    return .{ .status = .reject_no_buffer };
                const max = @min(@max(word(payload, 3), 1), 240);
                const c = if (conn_id < self.conns.len) self.conns[conn_id] else null;
                const stream = c orelse return .{ .status = .reject_no_buffer };
                var fds = [_]std.posix.pollfd{.{
                    .fd = stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&fds, self.poll_ms) catch 0;
                var r = tagged(window, payload);
                if (ready == 0) return .{ .reply = r }; // nothing yet: tag only
                r.data.resize(@intCast(8 + max)) catch unreachable;
                const n = stream.read(r.data.slice()[8..]) catch
                    return .{ .status = .reject_no_buffer };
                if (n == 0) return .{ .status = .reject_no_buffer }; // EOF
                r.data.resize(8 + n) catch unreachable;
                return .{ .reply = r };
            },
            3 => { // close
                if (conn_id < self.conns.len) {
                    if (self.conns[conn_id]) |s| s.close();
                    self.conns[conn_id] = null;
                }
                return .{};
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
    net: Net,

    /// One request, delivered at fabric time `due`.
    pub fn handle(self: *Device, due: u64, payload: []const u8) Result {
        return switch (self.*) {
            .console => |*d| d.handle(payload),
            .entropy => |*d| d.handle(payload),
            .rtc => |*d| d.handle(due, payload),
            .block => |*d| d.handle(payload),
            .net => |*d| d.handle(payload),
        };
    }

    pub fn deinit(self: *Device) void {
        switch (self.*) {
            .console => |*d| d.out.deinit(d.alloc),
            .block => |*d| d.alloc.free(d.data),
            .net => |*d| for (&d.conns) |*c| {
                if (c.*) |s| s.close();
                c.* = null;
            },
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

test "entropy is deterministic from seed, clamps count, echoes the tag" {
    var a = Device{ .entropy = Entropy.init(42) };
    var b = Device{ .entropy = Entropy.init(42) };
    var req: [24]u8 = undefined;
    std.mem.writeInt(u64, req[0..8], 0xBEEF_0042, .little);
    std.mem.writeInt(u64, req[8..16], ring.windowAddr(3, 0), .little);
    std.mem.writeInt(u64, req[16..24], 8, .little);
    const ra = a.handle(0, &req).reply.?;
    const rb = b.handle(0, &req).reply.?;
    try std.testing.expectEqualSlices(u8, ra.data.slice(), rb.data.slice());
    try std.testing.expectEqual(@as(usize, 16), ra.data.len);
    // the reply wears the tag you gave it (§7.3 addendum)
    try std.testing.expectEqual(
        @as(u64, 0xBEEF_0042),
        std.mem.readInt(u64, ra.data.slice()[0..8], .little),
    );
    std.mem.writeInt(u64, req[16..24], 4096, .little);
    try std.testing.expectEqual(@as(usize, 8 + 64), a.handle(0, &req).reply.?.data.len);
}

test "rtc replies with fabric time behind the echoed tag" {
    var d = Device{ .rtc = .{} };
    var req: [16]u8 = undefined;
    std.mem.writeInt(u64, req[0..8], 77, .little);
    std.mem.writeInt(u64, req[8..16], ring.windowAddr(1, 0), .little);
    const r = d.handle(6564, &req).reply.?;
    try std.testing.expectEqual(@as(u64, 77), std.mem.readInt(u64, r.data.slice()[0..8], .little));
    try std.testing.expectEqual(
        @as(u64, 6564),
        std.mem.readInt(u64, r.data.slice()[8..16], .little),
    );
}

test "block round-trips a sector and rejects the void" {
    var d = Device{ .block = try Block.init(std.testing.allocator, 4, 64) };
    defer d.deinit();
    var wr: [32]u8 = undefined;
    std.mem.writeInt(u64, wr[0..8], 0, .little); // tag (writes: present, unused)
    std.mem.writeInt(u64, wr[8..16], 0, .little);
    std.mem.writeInt(u64, wr[16..24], 1 | (2 << 8), .little); // write sector 2
    std.mem.writeInt(u64, wr[24..32], 0x6564_6564_6564_6564, .little);
    try std.testing.expectEqual(ring.Status.ok, d.handle(0, &wr).status);

    var rd: [24]u8 = undefined;
    std.mem.writeInt(u64, rd[0..8], 9, .little); // tag
    std.mem.writeInt(u64, rd[8..16], ring.windowAddr(0, 0), .little);
    std.mem.writeInt(u64, rd[16..24], 0 | (2 << 8), .little); // read sector 2
    const r = d.handle(0, &rd).reply.?;
    try std.testing.expectEqual(@as(usize, 8 + 64), r.data.len);
    try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, r.data.slice()[0..8], .little));
    try std.testing.expectEqual(
        @as(u64, 0x6564_6564_6564_6564),
        std.mem.readInt(u64, r.data.slice()[8..16], .little),
    );

    std.mem.writeInt(u64, rd[16..24], 0 | (9 << 8), .little); // no sector 9
    try std.testing.expectEqual(ring.Status.reject_no_buffer, d.handle(0, &rd).status);
}
