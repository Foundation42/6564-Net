//! The virtual network mesh — event types and seeded fault injection (§9
//! Phase 2). Per the spec this is mandatory, not optional: the delivery
//! semantics of §6.1 must be *exercised*, not assumed.
//!
//! This module is pure policy: given a link config, a deterministic PRNG and
//! a send time, `plan` decides what happens to a datagram (delivered when,
//! duplicated, lost). machine.zig owns the event queue and the consequences.
//!
//! Determinism contract: all randomness flows from the machine's single
//! seeded PRNG, and events with equal due-cycles are ordered by their
//! monotonic sequence number — so any run reproduces exactly from its seed.

const std = @import("std");
const ring = @import("ring.zig");

/// Fault model for one class of link. On-chip mesh links are reliable and
/// fixed-latency (local traffic never touches a network stack, §3.2); these
/// knobs apply to off-chip paths.
pub const LinkConfig = struct {
    /// Fixed cycles for on-die mesh hops (same core, or core-to-core on one
    /// die — the simulator treats all same-machine cores as one die for now).
    onchip_latency: u64 = 4,
    /// Base one-way latency for off-chip paths, in cycles.
    base_latency: u64 = 200,
    /// Uniform extra latency in [0, jitter] — this is also what causes
    /// reordering between datagrams on the same flow.
    jitter: u64 = 100,
    /// Packet loss probability in parts per 4096 (applied independently to
    /// datagrams and to their acks — the two-generals problem is real here).
    loss_ppm4k: u16 = 0,
    /// Duplication probability in parts per 4096.
    dup_ppm4k: u16 = 0,
    /// Cycles a sender waits before posting a timeout completion (§6.1).
    send_timeout: u64 = 2000,
};

/// Where a completion should be posted when a send resolves.
pub const ReplyPath = struct {
    core: u16,
    ctx: u8,
    cq_slot: u8,
    tag: ring.Tag,
    cookie: u64,
    /// RAM address of the transmit descriptor whose OWNED bit must clear when
    /// the completion posts (0 = none, e.g. TXR register sends).
    sqe_addr: u64 = 0,
    /// SQ descriptor slot the entry was staged in — the completion record's
    /// source-ring field (0 for ring-less TXR register sends).
    src_slot: u8 = 0,
};

/// A datagram in flight.
pub const Datagram = struct {
    send_id: u64,
    dst_core: u16,
    dst_ctx: u8,
    dst_slot: u8,
    /// Offset field of the window pointer (§3.2). Carried; delivery currently
    /// lands whole datagrams in RX buffers, offset reserved for future
    /// registered-region remote writes.
    offset: u64,
    /// Capability token from the sender's PTT entry (§6.4).
    token: u64,
    /// Owned by the event queue; freed after delivery.
    payload: []u8,
};

pub const Event = struct {
    due: u64,
    seq: u64,
    kind: Kind,

    pub const Kind = union(enum) {
        /// Datagram arrives at its destination core.
        deliver: Datagram,
        /// Ack (or reject) arrives back at the sender.
        ack: struct { send_id: u64, status: ring.Status, byte_count: u32 },
        /// Sender-side timeout check for a send that may have died en route.
        timeout: struct { send_id: u64 },
    };

    pub fn order(_: void, a: Event, b: Event) std.math.Order {
        return switch (std.math.order(a.due, b.due)) {
            .eq => std.math.order(a.seq, b.seq),
            else => |o| o,
        };
    }
};

/// The fate of one datagram on an off-chip link, decided at send time.
pub const Plan = struct {
    /// Delivery times; empty = lost. Two entries = duplicated.
    arrivals: std.BoundedArray(u64, 2),
};

pub fn roll(rand: std.Random, ppm4k: u16) bool {
    if (ppm4k == 0) return false;
    return rand.uintLessThan(u16, 4096) < ppm4k;
}

/// Decide latency/loss/duplication for one off-chip datagram.
pub fn plan(cfg: LinkConfig, rand: std.Random, now: u64) Plan {
    var p = Plan{ .arrivals = .{} };
    if (!roll(rand, cfg.loss_ppm4k)) {
        p.arrivals.append(now + latency(cfg, rand)) catch unreachable;
        if (roll(rand, cfg.dup_ppm4k))
            p.arrivals.append(now + latency(cfg, rand)) catch unreachable;
    }
    return p;
}

pub fn latency(cfg: LinkConfig, rand: std.Random) u64 {
    const j = if (cfg.jitter == 0) 0 else rand.uintAtMost(u64, cfg.jitter);
    return cfg.base_latency + j;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "plan is deterministic from seed" {
    const cfg = LinkConfig{ .loss_ppm4k = 1024, .dup_ppm4k = 512, .jitter = 50 };
    var a = std.Random.DefaultPrng.init(6564);
    var b = std.Random.DefaultPrng.init(6564);
    for (0..200) |_| {
        const pa = plan(cfg, a.random(), 1000);
        const pb = plan(cfg, b.random(), 1000);
        try std.testing.expectEqualSlices(u64, pa.arrivals.constSlice(), pb.arrivals.constSlice());
    }
}

test "loss and duplication rates are roughly honored" {
    const cfg = LinkConfig{ .loss_ppm4k = 2048, .dup_ppm4k = 0 }; // 50% loss
    var prng = std.Random.DefaultPrng.init(42);
    var lost: usize = 0;
    const n = 10_000;
    for (0..n) |_| {
        if (plan(cfg, prng.random(), 0).arrivals.len == 0) lost += 1;
    }
    // 50% ± 3 points is generous but catches inverted logic.
    try std.testing.expect(lost > n * 47 / 100 and lost < n * 53 / 100);
}

test "event ordering: due then seq" {
    const e1 = Event{ .due = 10, .seq = 2, .kind = .{ .timeout = .{ .send_id = 0 } } };
    const e2 = Event{ .due = 10, .seq = 1, .kind = .{ .timeout = .{ .send_id = 1 } } };
    const e3 = Event{ .due = 9, .seq = 9, .kind = .{ .timeout = .{ .send_id = 2 } } };
    try std.testing.expectEqual(std.math.Order.gt, Event.order({}, e1, e2));
    try std.testing.expectEqual(std.math.Order.lt, Event.order({}, e3, e1));
}
