//! struple, the 6564 half — implementation #13 of the wire format
//! (reference: Foundation42/struple; the corpus in struple_vectors.json is
//! the language-neutral contract, vendored verbatim, do not edit).
//!
//! This file is the HOST half: the canonical subset packer joe's compiler
//! uses to pre-pack constant tuple segments (Amendment 2, A2.3), the
//! reader/skip the tests oracle against, and the conformance filter. The
//! MACHINE half is the code joe emits — int append, prefix memcmp, element
//! skip — proven against the same corpus on the simulator, under scorch.
//!
//! joe v1 speaks the declared subset of the type tower (A2.3): nil, bool,
//! int (≤ 8-byte magnitude), f32/f64, timestamp, uuid, string, bytes,
//! array. Reserved (skip-only): 9–16-byte and big ints, decimal, map, set.
//! Skip is total even where decode is partial — a reader steps over any
//! valid element of the full tower, including types it cannot decode.
//!
//! The byte law, restated (ordering IS memcmp):
//!   - one type-code byte; its numeric order is the cross-type sort order
//!   - ints: code $20±n carries the magnitude byte count; payload is
//!     big-endian; negatives in excess form (value + 2^(8n))
//!   - floats: IEEE-754 total-order transform (negatives complemented,
//!     positives sign-flipped); -0.0 squashed; one canonical NaN
//!   - timestamp: sign-flipped big-endian i64 (µs since epoch, UTC)
//!   - uuid: 16 raw bytes, no framing
//!   - string/bytes/array (and map/set): payload 0x00-terminated, literal
//!     0x00 escaped as 0x00 0xFF; nesting re-escapes
//!   - strict decode: non-minimal int payloads are malformed

const std = @import("std");

pub const tc = struct {
    pub const terminator: u8 = 0x00;
    pub const nil: u8 = 0x01;
    pub const undef: u8 = 0x02;
    pub const bool_false: u8 = 0x05;
    pub const bool_true: u8 = 0x06;
    pub const int_neg_big: u8 = 0x0F;
    pub const int_zero: u8 = 0x20;
    pub const int_pos_big: u8 = 0x31;
    pub const float32: u8 = 0x34;
    pub const float64: u8 = 0x35;
    pub const decimal: u8 = 0x38;
    pub const timestamp: u8 = 0x40;
    pub const uuid: u8 = 0x44;
    pub const string: u8 = 0x48;
    pub const bytes: u8 = 0x49;
    pub const array: u8 = 0x50;
    pub const map: u8 = 0x52;
    pub const set: u8 = 0x54;
};

const escape_byte: u8 = 0xFF;

pub const Error = error{ Truncated, InvalidType, Reserved, OutOfMemory };

// ── Packer (canonical subset) ────────────────────────────────────────────

pub const Packer = struct {
    out: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) Packer {
        return .{ .out = std.ArrayList(u8).init(alloc) };
    }
    pub fn deinit(self: *Packer) void {
        self.out.deinit();
    }
    pub fn bytes(self: *const Packer) []const u8 {
        return self.out.items;
    }

    pub fn appendNil(self: *Packer) Error!void {
        try self.out.append(tc.nil);
    }
    pub fn appendUndefined(self: *Packer) Error!void {
        try self.out.append(tc.undef);
    }
    pub fn appendBool(self: *Packer, v: bool) Error!void {
        try self.out.append(if (v) tc.bool_true else tc.bool_false);
    }

    /// Any integer with ≤ 8-byte magnitude — the joe subset. i128 input so
    /// the conformance driver can route wider values to Reserved honestly.
    pub fn appendInt(self: *Packer, v: i128) Error!void {
        if (v == 0) return self.out.append(tc.int_zero);
        if (v > 0) {
            const mag: u128 = @intCast(v);
            if (mag > std.math.maxInt(u64)) return Error.Reserved;
            return self.appendUint(@intCast(mag));
        }
        const mag: u128 = @intCast(-v);
        if (mag > (@as(u128, 1) << 64)) return Error.Reserved; // |-2^64| still 8 bytes
        const n = byteLenOfExcess(mag);
        try self.out.append(tc.int_zero - @as(u8, @intCast(n)));
        // Excess form: low n bytes of the wrapping negation.
        try self.writeBigEndian(0 -% @as(u64, @truncate(mag)), n);
    }

    pub fn appendUint(self: *Packer, v: u64) Error!void {
        if (v == 0) return self.out.append(tc.int_zero);
        const n = byteLen(v);
        try self.out.append(tc.int_zero + @as(u8, @intCast(n)));
        try self.writeBigEndian(v, n);
    }

    pub fn appendF64(self: *Packer, v: f64) Error!void {
        try self.out.append(tc.float64);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, orderableF64Bits(v), .big);
        try self.out.appendSlice(&b);
    }

    pub fn appendF32(self: *Packer, v: f32) Error!void {
        try self.out.append(tc.float32);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, orderableF32Bits(v), .big);
        try self.out.appendSlice(&b);
    }

    pub fn appendTimestamp(self: *Packer, micros: i64) Error!void {
        try self.out.append(tc.timestamp);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, @as(u64, @bitCast(micros)) ^ (@as(u64, 1) << 63), .big);
        try self.out.appendSlice(&b);
    }

    pub fn appendUuid(self: *Packer, v: [16]u8) Error!void {
        try self.out.append(tc.uuid);
        try self.out.appendSlice(&v);
    }

    pub fn appendString(self: *Packer, v: []const u8) Error!void {
        try self.framed(tc.string, v);
    }
    pub fn appendBytes(self: *Packer, v: []const u8) Error!void {
        try self.framed(tc.bytes, v);
    }
    /// `child` is the encoded element stream of another tuple.
    pub fn appendArray(self: *Packer, child: []const u8) Error!void {
        try self.framed(tc.array, child);
    }

    fn framed(self: *Packer, code: u8, content: []const u8) Error!void {
        try self.out.append(code);
        for (content) |b| {
            try self.out.append(b);
            if (b == 0x00) try self.out.append(escape_byte);
        }
        try self.out.append(tc.terminator);
    }

    fn writeBigEndian(self: *Packer, v: u64, n: usize) Error!void {
        var i = n;
        while (i > 0) {
            i -= 1;
            try self.out.append(@truncate(v >> @intCast(i * 8)));
        }
    }
};

fn byteLen(v: u64) usize {
    std.debug.assert(v != 0);
    return (64 - @clz(v) + 7) / 8;
}

/// Byte count of a negative's slot: the width of (magnitude − 1), min 1 —
/// so -256 fits one byte (excess 0x00) while -257 takes two.
fn byteLenOfExcess(mag: u128) usize {
    const pv = mag - 1;
    if (pv == 0) return 1;
    return (128 - @clz(pv) + 7) / 8;
}

pub fn orderableF64Bits(value: f64) u64 {
    var bits: u64 = undefined;
    if (std.math.isNan(value)) {
        bits = 0x7ff8000000000000;
    } else {
        var v = value;
        if (v == 0) v = 0; // squash -0.0
        bits = @bitCast(v);
    }
    return if (bits & 0x8000000000000000 != 0) ~bits else bits ^ 0x8000000000000000;
}

pub fn orderableF32Bits(value: f32) u32 {
    var bits: u32 = undefined;
    if (std.math.isNan(value)) {
        bits = 0x7fc00000;
    } else {
        var v = value;
        if (v == 0) v = 0;
        bits = @bitCast(v);
    }
    return if (bits & 0x80000000 != 0) ~bits else bits ^ 0x80000000;
}

// ── Reader: subset decode + total skip ───────────────────────────────────

pub const Kind = enum { nil, undef, boolean, int, float32, float64, timestamp, uuid, string, bytes, array, reserved };

/// A decoded element. Framed payloads are as stored (escapes intact).
pub const Element = union(Kind) {
    nil,
    undef,
    boolean: bool,
    int: i128,
    float32: f32,
    float64: f64,
    timestamp: i64,
    uuid: [16]u8,
    string: []const u8,
    bytes: []const u8,
    array: []const u8,
    /// A valid element of a reserved type (big int, decimal, map, set) —
    /// skipped whole, held as raw bytes including the type code.
    reserved: []const u8,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }
    pub fn done(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    /// Decode the next element; reserved types come back whole as
    /// `.reserved` (skip is total, decode is a declared subset).
    pub fn next(self: *Reader) Error!?Element {
        if (self.done()) return null;
        const start = self.pos;
        const code = self.buf[self.pos];
        self.pos += 1;
        switch (code) {
            tc.nil => return .nil,
            tc.undef => return .undef,
            tc.bool_false => return .{ .boolean = false },
            tc.bool_true => return .{ .boolean = true },
            tc.int_zero => return .{ .int = 0 },
            0x10...0x1f, 0x21...0x30 => {
                const positive = code > tc.int_zero;
                const n: usize = if (positive) code - tc.int_zero else tc.int_zero - code;
                const payload = try self.take(n);
                // Strict decode: minimal encodings only.
                if (positive) {
                    if (payload[0] == 0x00) return Error.InvalidType;
                } else if (payload[0] == 0xFF and n > 1) return Error.InvalidType;
                if (n > 8) {
                    // 9–16-byte magnitudes: valid tower, outside the subset.
                    self.pos = start;
                    return .{ .reserved = try self.skipRaw() };
                }
                var raw: u64 = 0;
                for (payload) |b| raw = (raw << 8) | b;
                if (positive) return .{ .int = raw };
                const span: i128 = @as(i128, 1) << @intCast(n * 8);
                return .{ .int = @as(i128, raw) - span };
            },
            tc.float32 => {
                var bits = std.mem.readInt(u32, (try self.take(4))[0..4], .big);
                bits = if (bits & 0x80000000 != 0) bits ^ 0x80000000 else ~bits;
                return .{ .float32 = @bitCast(bits) };
            },
            tc.float64 => {
                var bits = std.mem.readInt(u64, (try self.take(8))[0..8], .big);
                bits = if (bits & 0x8000000000000000 != 0) bits ^ 0x8000000000000000 else ~bits;
                return .{ .float64 = @bitCast(bits) };
            },
            tc.timestamp => {
                const raw = std.mem.readInt(u64, (try self.take(8))[0..8], .big);
                return .{ .timestamp = @bitCast(raw ^ (@as(u64, 1) << 63)) };
            },
            tc.uuid => return .{ .uuid = (try self.take(16))[0..16].* },
            tc.string => return .{ .string = try self.takeFramed() },
            tc.bytes => return .{ .bytes = try self.takeFramed() },
            tc.array => return .{ .array = try self.takeFramed() },
            tc.int_neg_big, tc.int_pos_big, tc.decimal, tc.map, tc.set => {
                self.pos = start;
                return .{ .reserved = try self.skipRaw() };
            },
            else => return Error.InvalidType,
        }
    }

    /// Step over the next element of the FULL tower — including types this
    /// reader cannot decode — returning its raw bytes. This is the skip
    /// the machine half mirrors instruction for instruction.
    pub fn skipRaw(self: *Reader) Error![]const u8 {
        if (self.done()) return Error.Truncated;
        const start = self.pos;
        const code = self.buf[self.pos];
        self.pos += 1;
        switch (code) {
            tc.nil, tc.undef, tc.bool_false, tc.bool_true, tc.int_zero => {},
            0x10...0x1f, 0x21...0x30 => {
                const n: usize = if (code > tc.int_zero) code - tc.int_zero else tc.int_zero - code;
                _ = try self.take(n);
            },
            tc.float32 => _ = try self.take(4),
            tc.float64, tc.timestamp => _ = try self.take(8),
            tc.uuid => _ = try self.take(16),
            tc.string, tc.bytes, tc.array, tc.map, tc.set => _ = try self.takeFramed(),
            tc.int_neg_big, tc.int_pos_big => {
                const neg = code == tc.int_neg_big;
                const m: usize = if (neg) ~(try self.take(1))[0] else (try self.take(1))[0];
                if (m > 8) return Error.InvalidType;
                var n: usize = 0;
                for (try self.take(m)) |b| n = (n << 8) | @as(usize, if (neg) ~b else b);
                _ = try self.take(n);
            },
            tc.decimal => {
                const sign = (try self.take(1))[0];
                if (sign != 0x02) { // canonical zero is the sign byte alone
                    if (sign != 0x01 and sign != 0x03) return Error.InvalidType;
                    // Payload runs to an (un)complemented terminator.
                    const term: u8 = if (sign == 0x01) 0xFF else 0x00;
                    while (true) {
                        const b = (try self.take(1))[0];
                        if (b == term) break;
                    }
                }
            },
            else => return Error.InvalidType,
        }
        return self.buf[start..self.pos];
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.buf.len - self.pos) return Error.Truncated;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn takeFramed(self: *Reader) Error![]const u8 {
        const start = self.pos;
        var i = self.pos;
        while (i < self.buf.len) {
            if (self.buf[i] == 0x00) {
                if (i + 1 < self.buf.len and self.buf[i + 1] == escape_byte) {
                    i += 2;
                    continue;
                }
                self.pos = i + 1;
                return self.buf[start..i];
            }
            i += 1;
        }
        return Error.Truncated;
    }
};

/// Unescape a framed payload (0x00 0xFF → 0x00) into `out`; returns the
/// written slice. `out` may alias nothing shorter than the framed input.
pub fn unescapeInto(framed: []const u8, out: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < framed.len) : (i += 1) {
        out[w] = framed[i];
        w += 1;
        if (framed[i] == 0x00) i += 1;
    }
    return out[0..w];
}

// ── Conformance: the vendored corpus is the contract ─────────────────────
//
// struple_vectors.json is generated by the reference implementation and
// shared by all thirteen ports. For every entry whose bytes decode within
// the joe subset: the built value must encode byte-identically (from-value
// direction) and decode→re-encode must reproduce the bytes (transcode, the
// exact decode-direction check). Every entry — subset or reserved — must
// skip cleanly to end of stream: skip is total.

const testing = std.testing;

/// Encode one corpus value (a parsed `json` entry or `build` op tree) with
/// the subset packer. Reserved types return Error.Reserved.
fn encodeValue(p: *Packer, v: std.json.Value) Error!void {
    switch (v) {
        .null => try p.appendNil(),
        .bool => |b| try p.appendBool(b),
        .integer => |i| try p.appendInt(i),
        .float => |f| try p.appendF64(f),
        // Beyond i64 std.json hands back the text: an integer-looking
        // canonical number is still an int (u64-range values live here);
        // anything wider is big-int territory.
        .number_string => |s| {
            const i = std.fmt.parseInt(i128, s, 10) catch return Error.Reserved;
            try p.appendInt(i);
        },
        .string => |s| try p.appendString(s),
        .array => |items| {
            var child = Packer.init(testing.allocator);
            defer child.deinit();
            for (items.items) |it| try encodeValue(&child, it);
            try p.appendArray(child.bytes());
        },
        .object => return Error.Reserved, // a JSON object is a map
    }
}

/// Interpret a `build` op — `{"int": "123"}`, `{"array": [...]}`, … —
/// mirroring the conformance README's op language for the subset.
fn encodeBuildOp(p: *Packer, op: std.json.Value) Error!void {
    const obj = op.object;
    var it = obj.iterator();
    const entry = it.next().?;
    const key = entry.key_ptr.*;
    const val = entry.value_ptr.*;
    if (std.mem.eql(u8, key, "nil")) return p.appendNil();
    if (std.mem.eql(u8, key, "undef")) return p.appendUndefined();
    if (std.mem.eql(u8, key, "bool")) return p.appendBool(val.bool);
    if (std.mem.eql(u8, key, "int")) {
        const i = std.fmt.parseInt(i128, val.string, 10) catch return Error.Reserved;
        return p.appendInt(i);
    }
    if (std.mem.eql(u8, key, "float64")) return p.appendF64(jsonNumber(val));
    if (std.mem.eql(u8, key, "float32")) return p.appendF32(@floatCast(jsonNumber(val)));
    if (std.mem.eql(u8, key, "timestamp")) {
        return p.appendTimestamp(std.fmt.parseInt(i64, val.string, 10) catch return Error.Reserved);
    }
    if (std.mem.eql(u8, key, "uuid")) {
        var u: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&u, val.string) catch return Error.InvalidType;
        return p.appendUuid(u);
    }
    if (std.mem.eql(u8, key, "string")) return p.appendString(val.string);
    if (std.mem.eql(u8, key, "bytes")) {
        var buf: [256]u8 = undefined;
        const raw = std.fmt.hexToBytes(&buf, val.string) catch return Error.InvalidType;
        return p.appendBytes(raw);
    }
    if (std.mem.eql(u8, key, "array")) {
        var child = Packer.init(testing.allocator);
        defer child.deinit();
        for (val.array.items) |it2| try encodeBuildOp(&child, it2);
        return p.appendArray(child.bytes());
    }
    return Error.Reserved; // map, set, decimal
}

fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

/// Decode a full element stream and re-encode it — byte-exact inverse
/// proof. Returns Error.Reserved when the stream leaves the subset.
fn transcode(p: *Packer, stream: []const u8) Error!void {
    var r = Reader.init(stream);
    while (try r.next()) |el| {
        switch (el) {
            .nil => try p.appendNil(),
            .undef => try p.appendUndefined(),
            .boolean => |b| try p.appendBool(b),
            .int => |i| try p.appendInt(i),
            .float32 => |f| try p.appendF32(f),
            .float64 => |f| try p.appendF64(f),
            .timestamp => |t| try p.appendTimestamp(t),
            .uuid => |u| try p.appendUuid(u),
            .string => |s| try reframe(p, tc.string, s),
            .bytes => |s| try reframe(p, tc.bytes, s),
            .array => |framed| {
                const inner = try testing.allocator.alloc(u8, framed.len);
                defer testing.allocator.free(inner);
                var child = Packer.init(testing.allocator);
                defer child.deinit();
                try transcode(&child, unescapeInto(framed, inner));
                try p.appendArray(child.bytes());
            },
            .reserved => return Error.Reserved,
        }
    }
}

fn reframe(p: *Packer, code: u8, framed: []const u8) Error!void {
    const raw = try testing.allocator.alloc(u8, framed.len);
    defer testing.allocator.free(raw);
    const content = unescapeInto(framed, raw);
    if (code == tc.string) try p.appendString(content) else try p.appendBytes(content);
}

test "struple #13: the corpus, both directions where the subset speaks" {
    const src = @embedFile("struple_vectors.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();

    var subset_n: usize = 0;
    var reserved_n: usize = 0;
    for (parsed.value.array.items) |entry| {
        const obj = entry.object;
        const hex = obj.get("bytes").?.string;
        const want = try testing.allocator.alloc(u8, hex.len / 2);
        defer testing.allocator.free(want);
        _ = try std.fmt.hexToBytes(want, hex);

        // Transcode is also the subset classifier: a stream that decodes
        // entirely within the subset must reproduce itself byte-for-byte.
        var back = Packer.init(testing.allocator);
        defer back.deinit();
        const in_subset = if (transcode(&back, want)) |_| true else |err| blk: {
            try testing.expectEqual(Error.Reserved, err);
            break :blk false;
        };

        if (in_subset) {
            subset_n += 1;
            try testing.expectEqualSlices(u8, want, back.bytes());
            // From-value direction.
            var fwd = Packer.init(testing.allocator);
            defer fwd.deinit();
            if (obj.get("json")) |jtext| {
                var val = try std.json.parseFromSlice(std.json.Value, testing.allocator, jtext.string, .{});
                defer val.deinit();
                try encodeValue(&fwd, val.value);
            } else {
                try encodeBuildOp(&fwd, obj.get("build").?);
            }
            try testing.expectEqualSlices(u8, want, fwd.bytes());
        } else reserved_n += 1;

        // Skip is total: every entry, reserved included, walks cleanly.
        var r = Reader.init(want);
        while (!r.done()) _ = try r.skipRaw();
        try testing.expectEqual(want.len, r.pos);
    }
    // The corpus genuinely exercises both sides of the manifest.
    try testing.expect(subset_n >= 40);
    try testing.expect(reserved_n >= 15);
}

test "struple #13: ordering is memcmp on the subset boundary cases" {
    var a = Packer.init(testing.allocator);
    defer a.deinit();
    var b = Packer.init(testing.allocator);
    defer b.deinit();
    // "app" < "apple": termination beats extension.
    try a.appendString("app");
    try b.appendString("apple");
    try testing.expect(std.mem.lessThan(u8, a.bytes(), b.bytes()));
    a.out.clearRetainingCapacity();
    b.out.clearRetainingCapacity();
    // -1 < 0 < 1 across the excess form.
    try a.appendInt(-1);
    try b.appendInt(0);
    try testing.expect(std.mem.lessThan(u8, a.bytes(), b.bytes()));
    a.out.clearRetainingCapacity();
    try a.appendInt(1);
    try testing.expect(std.mem.lessThan(u8, b.bytes(), a.bytes()));
    // -256 fits one excess byte; -257 takes two; order still holds.
    a.out.clearRetainingCapacity();
    b.out.clearRetainingCapacity();
    try a.appendInt(-257);
    try b.appendInt(-256);
    try testing.expect(std.mem.lessThan(u8, a.bytes(), b.bytes()));
}
