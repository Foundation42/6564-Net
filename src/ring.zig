//! Ring buffer controller layouts — the architecture's *nouns* (§3.1, §4).
//!
//! This module is pure: it defines the near-page descriptor formats and the
//! pack/unpack functions over them. The memory plumbing (where descriptors
//! live, who snoops writes) is machine.zig's job, which keeps everything here
//! unit-testable without a machine.
//!
//! ## Near-page layout (architectural)
//!
//! The bottom 2 KB of each context's 4 KB near page is the descriptor table:
//! 64 slots × 32 bytes. The top 2 KB is software scratch. Three slots have
//! architecturally-assigned roles so that single-register ops like `TXR`
//! (which carry no desc operand) know where to post:
//!
//!   slot 0 — the context's submission queue (SQ)
//!   slot 1 — the context's completion queue (CQ)
//!   slot 2 — the context's default receive ring (RX)
//!
//! ## Ring descriptor (one slot, 4 × u64)
//!
//!   word0  ring base address (core RAM)
//!   word1  geometry: cap_log2[0..8) | entry_size[8..24) | watermark[32..48)
//!          | companion CQ slot[48..56)
//!   word2  indices: head[0..32) | tail[32..64)  (free-running; hw masks)
//!   word3  capability token (rings exposed to remote access; 0 = unset)
//!
//! Head is the consume index, tail the produce index. `count = tail - head`
//! (wrapping u32 arithmetic); the ring is full at `count == capacity`.
//! Hardware owns the wrap — software never computes a modulus (§4.1).
//!
//! ## Ring entry formats
//!
//! SQ entry (32 B) — a transmit descriptor (§6.2):
//!   word0 dst pointer (network window)   word1 src buffer address
//!   word2 length[0..32) | OWNED bit 63   word3 user cookie
//!
//! RX entry (32 B) — a posted landing buffer:
//!   word0 buffer address                 word1 buffer capacity (bytes)
//!   word2 filled length (hw-written)     word3 user cookie
//!
//! CQ entry (16 B) — a completion record (§4.2):
//!   word0 tag[0..8) | status[8..16) | byte count[32..64)
//!   word1 user cookie
//!
//! `CQPOP` loads word0 into A and word1 into X.

const std = @import("std");

/// Size of one descriptor slot in the near-page descriptor table.
pub const desc_size = 32;
/// Number of descriptor slots (64 × 32 B = bottom 2 KB of the near page).
pub const desc_slots = 64;
/// Architecturally-assigned slots.
pub const slot_sq = 0;
pub const slot_cq = 1;
pub const slot_rx = 2;

pub const sq_entry_size = 32;
pub const rx_entry_size = 32;
pub const cq_entry_size = 16;

/// Completion status codes (§4.2, §6.1). The CQ is the *only* channel for
/// I/O status — no sticky flags, no exceptions from network conditions.
pub const Status = enum(u8) {
    ok = 0,
    truncated = 1,
    reject_capability = 2,
    reject_no_buffer = 3,
    timeout = 4,
    /// Exit notifications only: the linked context faulted (byte_count
    /// carries the fault code).
    fault = 5,
};

/// Operation tags for completion records.
pub const Tag = enum(u8) {
    txr = 1,
    send = 2,
    /// Inbound delivery landed in one of our posted RX buffers.
    deliver = 3,
    /// A context linked to this CQ exited: status ok = clean HLT,
    /// status fault = it crashed; cookie = the child's context id.
    exit = 4,
};

/// Ring-descriptor flags (word1 bits 56..64).
pub const desc_flag_auto_repost: u8 = 0x01;

pub const Desc = struct {
    base: u64,
    cap_log2: u5,
    entry_size: u16,
    watermark: u16,
    /// CQ slot that receives this ring's completions (SQ and RX rings).
    companion_cq: u8,
    /// Ring behavior flags: bit 0 = AUTO_REPOST (RX rings; on CQPOP of a
    /// landed delivery, hardware re-enqueues the consumed landing buffer).
    flags: u8 = 0,
    head: u32,
    tail: u32,
    token: u64,

    pub fn capacity(self: Desc) u32 {
        return @as(u32, 1) << self.cap_log2;
    }

    pub fn count(self: Desc) u32 {
        return self.tail -% self.head;
    }

    pub fn isEmpty(self: Desc) bool {
        return self.head == self.tail;
    }

    pub fn isFull(self: Desc) bool {
        return self.count() == self.capacity();
    }

    /// RAM address of entry `index` (a free-running index; masked here).
    pub fn entryAddr(self: Desc, index: u32) u64 {
        const mask = self.capacity() - 1;
        return self.base + @as(u64, index & mask) * self.entry_size;
    }

    pub fn unpack(words: [4]u64) Desc {
        return .{
            .base = words[0],
            .cap_log2 = @truncate(words[1] & 0x1F),
            .entry_size = @truncate((words[1] >> 8) & 0xFFFF),
            .watermark = @truncate((words[1] >> 32) & 0xFFFF),
            .companion_cq = @truncate((words[1] >> 48) & 0xFF),
            .flags = @truncate(words[1] >> 56),
            .head = @truncate(words[2] & 0xFFFF_FFFF),
            .tail = @truncate(words[2] >> 32),
            .token = words[3],
        };
    }

    pub fn pack(self: Desc) [4]u64 {
        return .{
            self.base,
            @as(u64, self.cap_log2) |
                (@as(u64, self.entry_size) << 8) |
                (@as(u64, self.watermark) << 32) |
                (@as(u64, self.companion_cq) << 48) |
                (@as(u64, self.flags) << 56),
            @as(u64, self.head) | (@as(u64, self.tail) << 32),
            self.token,
        };
    }
};

/// A completion record, as packed into a CQ entry (§4.2):
///   word0 = tag[0..8) | status[8..16) | source ring slot[16..24) | count[32..64)
/// The source-ring field says which descriptor slot the record pertains to —
/// the RX ring for deliveries, the SQ for send completions (0 for ring-less
/// operations like TXR register sends and their timeouts).
pub const Completion = struct {
    tag: Tag,
    status: Status,
    slot: u8 = 0,
    byte_count: u32,
    cookie: u64,

    /// word0 as CQPOP delivers it into A.
    pub fn word0(self: Completion) u64 {
        return @as(u64, @intFromEnum(self.tag)) |
            (@as(u64, @intFromEnum(self.status)) << 8) |
            (@as(u64, self.slot) << 16) |
            (@as(u64, self.byte_count) << 32);
    }

    pub fn fromWords(w0: u64, cookie: u64) Completion {
        return .{
            .tag = @enumFromInt(@as(u8, @truncate(w0))),
            .status = @enumFromInt(@as(u8, @truncate(w0 >> 8))),
            .slot = @truncate(w0 >> 16),
            .byte_count = @truncate(w0 >> 32),
            .cookie = cookie,
        };
    }
};

/// Submission-queue entry operations. Non-exhaustive: unknown bytes decode
/// to `_` and fault at execution, honestly.
pub const SqOp = enum(u8) { nop = 0, send = 1, txr = 2, recv = 3, _ };

/// A submission entry, 32 bytes, per the MAC & chains sketch §2:
///
///   word0  op[0..8) | flags[8..16) | link[16..32) | status_hint[32..64)
///   word1  target — window pointer (PTT-mapped)
///   word2  buf (send: buffer base) or value (txr: the 8-byte immediate)
///   word3  len[0..32) | cookie_lo[32..64)
///
/// The completion's cookie is cookie_lo in the low half with a hardware
/// stamp in the high half: staging slot [32..48), incarnation [48..64) —
/// records are self-identifying, and a restarted actor can't misattribute
/// a dead life's completions. `link` is a near-page offset (0 = no chain).
pub const SqEntry = struct {
    op: SqOp,
    flags: u8 = 0,
    link: u16 = 0,
    hint: u32 = 0,
    target: u64,
    buf: u64,
    len: u32,
    cookie_lo: u32,

    /// The §6.2 ownership bit, set at accept, cleared when the completion
    /// posts. Byte offset 1 of the entry, bit 7.
    pub const flag_owned: u8 = 0x80;
    /// Chain to the staged entry at `link` on ok completion (LINK, §3.1).
    pub const flag_link: u8 = 0x01;
    /// Resubmit this entry when it completes with timeout (AUTO_REARM, §3.2).
    pub const flag_auto_rearm: u8 = 0x02;

    pub fn unpack(words: [4]u64) SqEntry {
        return .{
            .op = @enumFromInt(@as(u8, @truncate(words[0]))),
            .flags = @truncate(words[0] >> 8),
            .link = @truncate(words[0] >> 16),
            .hint = @truncate(words[0] >> 32),
            .target = words[1],
            .buf = words[2],
            .len = @truncate(words[3] & 0xFFFF_FFFF),
            .cookie_lo = @truncate(words[3] >> 32),
        };
    }

    pub fn pack(self: SqEntry) [4]u64 {
        return .{
            @as(u64, @intFromEnum(self.op)) | (@as(u64, self.flags) << 8) |
                (@as(u64, self.link) << 16) | (@as(u64, self.hint) << 32),
            self.target,
            self.buf,
            @as(u64, self.len) | (@as(u64, self.cookie_lo) << 32),
        };
    }
};

/// A posted landing buffer, as packed into an RX ring entry.
pub const RxEntry = struct {
    buf: u64,
    cap: u64,
    filled: u64,
    cookie: u64,

    pub fn unpack(words: [4]u64) RxEntry {
        return .{ .buf = words[0], .cap = words[1], .filled = words[2], .cookie = words[3] };
    }

    pub fn pack(self: RxEntry) [4]u64 {
        return .{ self.buf, self.cap, self.filled, self.cookie };
    }
};

/// A PTT entry image, as CAPLD reads it from the near page (§3.2, §6.4):
///   word0 IPv6 prefix (high 64)     word1 IPv6 prefix (low 64)
///   word2 rights[0..3) | route[8..16)     word3 capability token
///
/// Simulator convention for the prefix: cores are addressed fd65:6400::/32
/// with the low word carrying the mesh coordinates the simulator routes by —
/// dst core[0..16) | dst context[16..24) | dst RX descriptor slot[24..32).
pub const PttEntry = struct {
    prefix_hi: u64 = 0,
    prefix_lo: u64 = 0,
    rights: Rights = .{},
    route: u8 = 0,
    token: u64 = 0,

    pub const Rights = packed struct(u3) {
        read: bool = false,
        write: bool = false,
        send: bool = false,
    };

    pub fn dstCore(self: PttEntry) u16 {
        return @truncate(self.prefix_lo);
    }
    pub fn dstContext(self: PttEntry) u8 {
        return @truncate(self.prefix_lo >> 16);
    }
    pub fn dstSlot(self: PttEntry) u8 {
        return @truncate(self.prefix_lo >> 24);
    }

    pub fn unpack(words: [4]u64) PttEntry {
        return .{
            .prefix_hi = words[0],
            .prefix_lo = words[1],
            .rights = @bitCast(@as(u3, @truncate(words[2]))),
            .route = @truncate(words[2] >> 8),
            .token = words[3],
        };
    }

    pub fn pack(self: PttEntry) [4]u64 {
        return .{
            self.prefix_hi,
            self.prefix_lo,
            @as(u64, @as(u3, @bitCast(self.rights))) | (@as(u64, self.route) << 8),
            self.token,
        };
    }

    /// Build the low prefix word from mesh coordinates.
    pub fn loFrom(core: u16, context: u8, slot: u8) u64 {
        return @as(u64, core) | (@as(u64, context) << 16) | (@as(u64, slot) << 24);
    }
};

// ── Network window pointers (§3.2) ───────────────────────────────────────

pub const window_tag: u8 = 0xFF;

pub fn isWindow(addr: u64) bool {
    return (addr >> 56) == window_tag;
}

pub fn windowPtt(addr: u64) u16 {
    return @truncate(addr >> 40);
}

pub fn windowOffset(addr: u64) u64 {
    return addr & ((1 << 40) - 1);
}

pub fn windowAddr(ptt_index: u16, offset: u64) u64 {
    return (@as(u64, window_tag) << 56) | (@as(u64, ptt_index) << 40) |
        (offset & ((1 << 40) - 1));
}

// ── Tests ────────────────────────────────────────────────────────────────

test "descriptor pack/unpack round-trip" {
    const d = Desc{
        .base = 0x2000,
        .cap_log2 = 4,
        .entry_size = 32,
        .watermark = 3,
        .companion_cq = 1,
        .head = 7,
        .tail = 23,
        .token = 0xDEAD_BEEF_CAFE_F00D,
    };
    const rt = Desc.unpack(d.pack());
    try std.testing.expectEqualDeep(d, rt);
    try std.testing.expectEqual(@as(u32, 16), d.capacity());
    try std.testing.expectEqual(@as(u32, 16), d.count());
    try std.testing.expect(d.isFull());
}

test "free-running indices wrap correctly" {
    var d = Desc{
        .base = 0x1000,
        .cap_log2 = 2, // capacity 4
        .entry_size = 16,
        .watermark = 0,
        .companion_cq = 0,
        .head = 0xFFFF_FFFE,
        .tail = 0xFFFF_FFFE,
        .token = 0,
    };
    try std.testing.expect(d.isEmpty());
    d.tail +%= 3;
    try std.testing.expectEqual(@as(u32, 3), d.count());
    // Entry addresses mask into [base, base + cap*entry_size).
    try std.testing.expectEqual(@as(u64, 0x1000 + 2 * 16), d.entryAddr(0xFFFF_FFFE));
    try std.testing.expectEqual(@as(u64, 0x1000 + 0 * 16), d.entryAddr(0x0000_0000));
}

test "completion word0 packing" {
    const c = Completion{ .tag = .send, .status = .timeout, .byte_count = 512, .cookie = 42 };
    const rt = Completion.fromWords(c.word0(), c.cookie);
    try std.testing.expectEqualDeep(c, rt);
}

test "sq entry round-trip; OWNED lives in byte 1 bit 7" {
    var sqe = SqEntry{
        .op = .send,
        .flags = SqEntry.flag_owned | SqEntry.flag_link,
        .link = 0x8C0,
        .target = 0xFF00_0000_0000_0000,
        .buf = 0x2500,
        .len = 16,
        .cookie_lo = 0xABCD,
    };
    const words = sqe.pack();
    try std.testing.expectEqualDeep(sqe, SqEntry.unpack(words));
    // The OWNED bit is byte offset 1, bit 7 — clearable with one byte store.
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, words[0], .little);
    try std.testing.expect(bytes[1] & SqEntry.flag_owned != 0);
    bytes[1] &= ~SqEntry.flag_owned;
    const cleared = SqEntry.unpack(.{ std.mem.readInt(u64, &bytes, .little), words[1], words[2], words[3] });
    try std.testing.expect(cleared.flags & SqEntry.flag_owned == 0);
}

test "completion carries its source ring slot" {
    const c = Completion{ .tag = .deliver, .status = .ok, .slot = 3, .byte_count = 16, .cookie = 7 };
    const rt = Completion.fromWords(c.word0(), c.cookie);
    try std.testing.expectEqual(@as(u8, 3), rt.slot);
    try std.testing.expectEqualDeep(c, rt);
}

test "descriptor flags round-trip" {
    var d = Desc{
        .base = 0x2A00,
        .cap_log2 = 1,
        .entry_size = 32,
        .watermark = 0,
        .companion_cq = 1,
        .flags = desc_flag_auto_repost,
        .head = 0,
        .tail = 0,
        .token = 0x6564,
    };
    try std.testing.expectEqualDeep(d, Desc.unpack(d.pack()));
    d.flags = 0;
    try std.testing.expectEqualDeep(d, Desc.unpack(d.pack()));
}

test "window pointer fields" {
    const addr = windowAddr(0x0102, 0xAB_CDEF);
    try std.testing.expect(isWindow(addr));
    try std.testing.expectEqual(@as(u16, 0x0102), windowPtt(addr));
    try std.testing.expectEqual(@as(u64, 0xAB_CDEF), windowOffset(addr));
    try std.testing.expect(!isWindow(0x1000));
}

test "ptt entry round-trip and coordinates" {
    const p = PttEntry{
        .prefix_hi = 0xfd65_6400_0000_0000,
        .prefix_lo = PttEntry.loFrom(3, 2, 5),
        .rights = .{ .write = true, .send = true },
        .route = 1,
        .token = 0x1234,
    };
    const rt = PttEntry.unpack(p.pack());
    try std.testing.expectEqualDeep(p, rt);
    try std.testing.expectEqual(@as(u16, 3), rt.dstCore());
    try std.testing.expectEqual(@as(u8, 2), rt.dstContext());
    try std.testing.expectEqual(@as(u8, 5), rt.dstSlot());
}
