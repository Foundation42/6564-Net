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

/// A device's private job memo, opaque to the machine. A grant device
/// (matmul, display) parses its request in `handle` and packs whatever it
/// needs at completion into these words; the machine stores the memo with
/// the in-flight grant and hands it back to `complete` verbatim, never
/// reading it. Eight words is room for matmul's three offsets and three
/// dimensions with two to spare — a display uses none.
pub const DeviceJob = struct { words: [8]u64 = @splat(0) };

/// A follow-up the machine performs after a device's `handle` returns —
/// the two shapes on the row beyond a plain sync ack (§7.6–7.8):
///   submit    — grant the named region and schedule this device's
///               completion `latency` cycles out (matmul, display). The
///               machine owns the grant/release fence and the $6772
///               completion record; the device owns only the arithmetic,
///               done in `complete` over the granted bytes. `extent` is
///               the furthest byte the device will touch, which the
///               machine bounds-checks against the region length; `pulls`
///               is an optional fabric-chunk cost counted on grant.
///   subscribe — aim the device's push window at the subscriber and (if
///               `first` > 0) start the stream (pad). Idempotent: a second
///               subscribe with `first` == 0 only re-aims — last wins (§7.8).
pub const Action = union(enum) {
    none,
    submit: Submit,
    subscribe: Subscribe,

    pub const Submit = struct {
        slot: u8,
        token: u64,
        latency: u64,
        extent: u64,
        pulls: u64 = 0,
        job: DeviceJob = .{},
    };
    pub const Subscribe = struct { first: u64 };
};

/// One push a device streams unasked (a pad's input frame): the reply to
/// route now, and `again` — reschedule the next push this many cycles out,
/// or 0 when the stream is spent.
pub const Push = struct {
    reply: Reply,
    again: u64 = 0,
};

pub const Result = struct {
    /// Rides the sender's ack: ok = the device accepted the request.
    /// reject_no_buffer = malformed or unserviceable request (the device
    /// had no place for it) — flow-control semantics, retry is sane.
    status: ring.Status = .ok,
    reply: ?Reply = null,
    /// A follow-up beyond the ack: a region grant or a subscription. The
    /// machine performs it only when `status` is ok.
    action: Action = .none,
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

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtDeinit(ptr: *anyopaque) void {
        const self: *Console = @ptrCast(@alignCast(ptr));
        self.out.deinit(self.alloc);
    }
    const vtable = Device.VTable{ .handle = vtHandle, .deinit = vtDeinit };
    pub fn device(self: *Console) Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};

// ── APU: sound as fire-and-forget ────────────────────────────────────────
//
// `send apu, Tone{n}` — a plain message (word0 = tag, word1 = the tone),
// and no reply. The APU is a sink like the console, but it takes a message
// instead of raw text: it counts the tones and remembers the last one,
// which is all a headless machine can honestly say about sound. Fire-and-
// forget is not a limitation here, it is the right shape — you do not wait
// on a sound the way you wait on a frame.

pub const Apu = struct {
    tones: u64 = 0,
    last: u64 = 0,
    /// A running sum of every tone value played. Order-independent, so it
    /// proves which tones the wire carried without depending on the order
    /// a fire-and-forget burst happens to arrive in.
    sum: u64 = 0,

    fn handle(self: *Apu, payload: []const u8) Result {
        self.tones += 1;
        if (payload.len >= 16) {
            const n = word(payload, 1);
            self.last = n;
            self.sum +%= n;
        }
        return .{}; // no reply: sound is fire-and-forget
    }

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    const vtable = Device.VTable{ .handle = vtHandle };
    pub fn device(self: *Apu) Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};

// ── Pad: input as messages the actor latches ─────────────────────────────
//
// The one device that pushes. A WASM-4 game POLLS the gamepad; a 6564
// actor is pushed to — `case Pad(p): buttons = p.buttons`, and edges
// belong to frame time (rocci §1). The actor subscribes once with an
// ordinary A3.3 device ask, `send pad, Poll{}` where `Poll -> Pad`, and
// the pad streams `Pad{buttons}` to the ask's reply window using the
// ask's echoed tag: no new wiring, no new tag lookup — a subscription is
// an ask whose answer never stops coming.
//
// This is the deterministic (harness) implementation of the pad contract:
// the button sequence is a fixed trace, so a recorded game replays bit
// for bit (rocci §4, TAS as a corollary of determinism). A seed-driven
// pad generates the trace from a seed; a real pad reads hardware. All
// three satisfy the same contract — the actor cannot tell which it holds
// (§7.5). Only the trace source differs.

pub const Pad = struct {
    /// The button states to push, in order. Caller-owned (outlives the
    /// run); the machine schedules one push per entry.
    trace: []const u64,
    /// Cycles between pushes — the input rate. Pushes are interval-apart,
    /// so they arrive in order (unlike a same-instant fire-and-forget burst).
    interval: u64,
    index: usize = 0,
    pushed: u64 = 0,
    /// Captured from the Poll: the reply (Pad) tag every push wears, and
    /// the reply window every push is fired through.
    tag: u64 = 0,
    window: u64 = 0,
    /// One subscription starts one stream; a second Poll does not restart it.
    streaming: bool = false,

    fn handle(self: *Pad, payload: []const u8) Result {
        // A Poll subscription: word0 = the Pad (reply) tag, word1 = the
        // reply window. Capturing them is the whole request — the stream
        // that answers it is scheduled by the machine. The first Poll
        // starts the stream (`first` = one interval out); a later Poll only
        // re-aims (`first` = 0), so the input follows the living screen
        // (§7.8, last subscriber wins).
        if (payload.len < 16) return .{ .status = .reject_no_buffer };
        self.tag = word(payload, 0);
        self.window = word(payload, 1);
        const first: u64 = if (self.streaming) 0 else blk: {
            self.streaming = true;
            break :blk self.interval;
        };
        return .{ .action = .{ .subscribe = .{ .first = first } } };
    }

    /// The pad's turn to push: the next button state, wearing the captured
    /// tag, aimed at the captured window — one Push per trace entry, then
    /// the stream is spent (`again` = 0) and the machine stops scheduling.
    fn push(self: *Pad) ?Push {
        if (self.index >= self.trace.len) return null; // the trace is spent
        const buttons = self.trace[self.index];
        self.index += 1;
        self.pushed += 1;
        var r = Reply{ .window = self.window };
        var data: [16]u8 = undefined;
        std.mem.writeInt(u64, data[0..8], self.tag, .little);
        std.mem.writeInt(u64, data[8..16], buttons, .little);
        r.data.appendSlice(&data) catch return null;
        return .{ .reply = r, .again = if (self.index < self.trace.len) self.interval else 0 };
    }

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtPush(ptr: *anyopaque) ?Push {
        return push(@ptrCast(@alignCast(ptr)));
    }
    const vtable = Device.VTable{ .handle = vtHandle, .push = vtPush };
    pub fn device(self: *Pad) Device {
        return .{ .ptr = self, .vt = &vtable };
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

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    const vtable = Device.VTable{ .handle = vtHandle };
    pub fn device(self: *Entropy) Device {
        return .{ .ptr = self, .vt = &vtable };
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

    fn vtHandle(ptr: *anyopaque, due: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), due, payload);
    }
    const vtable = Device.VTable{ .handle = vtHandle };
    pub fn device(self: *Rtc) Device {
        return .{ .ptr = self, .vt = &vtable };
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

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtDeinit(ptr: *anyopaque) void {
        const self: *Block = @ptrCast(@alignCast(ptr));
        self.alloc.free(self.data);
    }
    const vtable = Device.VTable{ .handle = vtHandle, .deinit = vtDeinit };
    pub fn device(self: *Block) Device {
        return .{ .ptr = self, .vt = &vtable };
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

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtDeinit(ptr: *anyopaque) void {
        const self: *Net = @ptrCast(@alignCast(ptr));
        for (&self.conns) |*c| {
            if (c.*) |s| s.close();
            c.* = null;
        }
    }
    const vtable = Device.VTable{ .handle = vtHandle, .deinit = vtDeinit };
    pub fn device(self: *Net) Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};

// ── Matmul & Display: the grant devices (§7.6–7.7) ───────────────────────
//
// These two moved off the machine and onto the row: a grant device parses
// its request in `handle`, and when the machine's completion fence fires it
// is handed a mutable byte view of the granted region (contiguous host
// memory, §6.2) and does its arithmetic in `complete`. The machine owns the
// grant/release fence, the region revalidation (the deferred-read
// discipline — a revoked grant scribbles nothing), and the $6772 completion
// record; the device owns only the numbers. Silicon is an optimization
// (§7.5): an in-proc matmul, a window-pulling polyfill, and a real GPU are
// three implementations of one contract, and only the clock tells them
// apart — now behind one vtable, so a fourth (a real display scanning real
// pixels) plugs in without the machine learning its name.

/// The first accelerator (item 6): C ⟵ A·B inside a granted region, k
/// ascending, IEEE RNE — a `deterministic` contract (§7.5), so the in-proc
/// unit and the remote polyfill agree to the bit and only latency differs.
pub const Matmul = struct {
    /// false = the in-proc unit (DMAs the region); true = the polyfill that
    /// pulls and pushes the region through the network window in 64-byte
    /// chunks — same token, same bytes, a slower clock and a pull count.
    remote: bool,

    fn handle(self: *Matmul, payload: []const u8) Result {
        // Contract (all u64 LE words): w0 reserved tag, w1 region slot,
        // w2 token, w3 dims M | K<<16 | N<<32, w4/w5/w6 the A/B/C offsets.
        if (payload.len < 56) return .{ .status = .reject_no_buffer };
        const dims = word(payload, 3);
        const m: u64 = @as(u16, @truncate(dims));
        const k: u64 = @as(u16, @truncate(dims >> 16));
        const n: u64 = @as(u16, @truncate(dims >> 32));
        if (m == 0 or k == 0 or n == 0 or m > 32 or k > 32 or n > 32)
            return .{ .status = .reject_capability };
        const off_a = word(payload, 4);
        const off_b = word(payload, 5);
        const off_c = word(payload, 6);
        const need_a = m * k * 8;
        const need_b = k * n * 8;
        const need_c = m * n * 8;
        // The furthest byte any operand touches: extent ≤ region length is
        // the machine's one bounds check, equivalent to the three per-operand
        // checks because they all compare against the same length.
        const extent = @max(off_a + need_a, @max(off_b + need_b, off_c + need_c));
        const flops = m * k * n;
        var pulls: u64 = 0;
        const latency: u64 = if (!self.remote) 100 + flops else blk: {
            const chunks = (need_a + need_b + need_c + 63) / 64;
            pulls = chunks;
            break :blk 400 + chunks * 200 + flops;
        };
        var job = DeviceJob{};
        job.words[0] = off_a;
        job.words[1] = off_b;
        job.words[2] = off_c;
        job.words[3] = m;
        job.words[4] = k;
        job.words[5] = n;
        return .{ .action = .{ .submit = .{
            .slot = @truncate(word(payload, 1)),
            .token = word(payload, 2),
            .latency = latency,
            .extent = extent,
            .pulls = pulls,
            .job = job,
        } } };
    }

    fn complete(_: *Matmul, region: []u8, job: DeviceJob) bool {
        const off_a = job.words[0];
        const off_b = job.words[1];
        const off_c = job.words[2];
        const m = job.words[3];
        const k = job.words[4];
        const n = job.words[5];
        var i: u64 = 0;
        while (i < m) : (i += 1) {
            var j: u64 = 0;
            while (j < n) : (j += 1) {
                var acc: f64 = 0;
                var kk: u64 = 0;
                while (kk < k) : (kk += 1) {
                    const av: f64 = @bitCast(rd(region, off_a + (i * k + kk) * 8));
                    const bv: f64 = @bitCast(rd(region, off_b + (kk * n + j) * 8));
                    acc += av * bv;
                }
                wr(region, off_c + (i * n + j) * 8, @bitCast(acc));
            }
        }
        return true;
    }

    fn rd(region: []const u8, off: u64) u64 {
        return std.mem.readInt(u64, region[@intCast(off)..][0..8], .little);
    }
    fn wr(region: []u8, off: u64, v: u64) void {
        std.mem.writeInt(u64, region[@intCast(off)..][0..8], v, .little);
    }

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtComplete(ptr: *anyopaque, region: []u8, job: DeviceJob) bool {
        return complete(@ptrCast(@alignCast(ptr)), region, job);
    }
    const vtable = Device.VTable{ .handle = vtHandle, .complete = vtComplete };
    pub fn device(self: *Matmul) Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};

/// A display is an accelerator whose work is to present (§7.7): the whole
/// granted region is the frame, held for one vblank `period` and returned as
/// the $6772 completion — the frame clock. `frames`/`checksum` are the
/// headless proof that what the actor drew reached the glass.
pub const Display = struct {
    period: u64,
    frames: u64 = 0,
    checksum: u64 = 0,

    fn handle(self: *Display, payload: []const u8) Result {
        // Present {w0 reserved tag, w1 region slot, w2 token}. No dimensions:
        // a display does not compute, it shows. The whole region is the frame.
        if (payload.len < 24) return .{ .status = .reject_no_buffer };
        return .{ .action = .{ .submit = .{
            .slot = @truncate(word(payload, 1)),
            .token = word(payload, 2),
            .latency = self.period,
            .extent = 0, // presents whatever length the region is
        } } };
    }

    fn complete(self: *Display, region: []u8, _: DeviceJob) bool {
        // Snapshot the frame the actor drew (deferred read — a revoked grant
        // never reaches here) as a checksum: the proof it reached the glass.
        var sum: u64 = 0;
        var off: usize = 0;
        while (off + 8 <= region.len) : (off += 8)
            sum +%= std.mem.readInt(u64, region[off..][0..8], .little);
        self.frames += 1;
        self.checksum = sum;
        return true;
    }

    fn vtHandle(ptr: *anyopaque, _: u64, payload: []const u8) Result {
        return handle(@ptrCast(@alignCast(ptr)), payload);
    }
    fn vtComplete(ptr: *anyopaque, region: []u8, job: DeviceJob) bool {
        return complete(@ptrCast(@alignCast(ptr)), region, job);
    }
    const vtable = Device.VTable{ .handle = vtHandle, .complete = vtComplete };
    pub fn device(self: *Display) Device {
        return .{ .ptr = self, .vt = &vtable };
    }
};

// ── The device interface ─────────────────────────────────────────────────

/// A peripheral, seen through the fabric: a pointer to some device and the
/// vtable it answers through. This is the whole of what machine.zig knows —
/// it calls `handle`/`complete`/`push` and never learns a device's name, so
/// a new one (a real display, a seed-driven pad, a GPU) plugs into the row
/// by supplying its own vtable, with no change to the machine or to this
/// file's built-ins. Silicon is an optimization behind an interface (§7.5);
/// the interface is this struct. The idiom is std.mem.Allocator's: a
/// concrete device exposes `pub fn device(self: *T) Device`, and the caller
/// hands that to `attachDevice`.
pub const Device = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// A request landed at fabric time `due`. Pure policy: no machine
        /// access. Returns the ack status, an optional immediate reply, and
        /// an optional follow-up (a grant or a subscription).
        handle: *const fn (ptr: *anyopaque, due: u64, payload: []const u8) Result,
        /// A granted job completes: the device is handed a mutable byte view
        /// of the revalidated, live region and its own job memo, does the
        /// work, and returns whether it was valid. Grant devices only.
        complete: ?*const fn (ptr: *anyopaque, region: []u8, job: DeviceJob) bool = null,
        /// The device's turn to push its stream. Returns the next push or
        /// null when spent. Pushing devices (the pad) only.
        push: ?*const fn (ptr: *anyopaque) ?Push = null,
        /// Free the device's own buffers. Optional — most devices own none.
        /// The machine's box around the device is freed separately, by the
        /// per-type dispose thunk attachDevice records (it alone knows the
        /// concrete type); this frees only what the device itself allocated.
        deinit: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub inline fn handle(self: Device, due: u64, payload: []const u8) Result {
        return self.vt.handle(self.ptr, due, payload);
    }
    pub inline fn complete(self: Device, region: []u8, job: DeviceJob) bool {
        return self.vt.complete.?(self.ptr, region, job);
    }
    pub inline fn push(self: Device) ?Push {
        return self.vt.push.?(self.ptr);
    }
    pub inline fn deinit(self: Device) void {
        if (self.vt.deinit) |f| f(self.ptr);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "console accumulates text" {
    var c = Console.init(std.testing.allocator);
    const d = c.device();
    defer d.deinit();
    try std.testing.expectEqual(ring.Status.ok, d.handle(0, "HELLO ").status);
    try std.testing.expectEqual(ring.Status.ok, d.handle(0, "WORLD").status);
    try std.testing.expectEqualStrings("HELLO WORLD", c.out.items);
}

test "entropy is deterministic from seed, clamps count, echoes the tag" {
    var ea = Entropy.init(42);
    var eb = Entropy.init(42);
    const a = ea.device();
    const b = eb.device();
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
    var rtc = Rtc{};
    const d = rtc.device();
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
    var blk = try Block.init(std.testing.allocator, 4, 64);
    const d = blk.device();
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
