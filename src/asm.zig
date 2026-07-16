//! A small two-pass assembler for the 6564-Net, driven by the same ISA table
//! as the simulator (src/isa.zig) — one source of truth, per §9.
//!
//! ## Syntax
//!
//!   ; comment                        label:      NAME = expr
//!   .org $1000        set origin     .qword v,…  emit 64-bit words
//!   .byte v,…         emit bytes     .ascii "…"  emit text
//!
//!   LDA #42           imm8 (sign-extended); #expr picks imm8 when it fits
//!   LDA ##$FF00_0000  imm64 (## forces the wide form)
//!   LDA $0F8          near page      LDA $0F8,X    near indexed
//!   LDA !buffer       absolute (! forces; bare exprs ≥ $1000 are absolute)
//!   LDA (ptr)         near-indirect  LDA (ptr),Y   post-indexed
//!   TXR (ptr),A       ind (the ,A is the spec's spelling; optional)
//!   BEQ done          rel16, computed from the next instruction
//!   SEND 0            desc (one-byte descriptor slot)
//!   CAPLD 3, ($40)    caps (PTT slot, near address of the entry image)
//!
//! Numbers: decimal, $hex, %binary — underscores allowed. Expressions are a
//! term or `term + term` / `term - term`, where a term is a number or symbol.
//! Forward references are fine; an unresolved `#` conservatively assembles
//! as imm64 and a bare operand as absolute.

const std = @import("std");
const isa = @import("isa.zig");

pub const Error = error{
    UnknownMnemonic,
    UnknownSymbol,
    DuplicateSymbol,
    BadOperand,
    BadDirective,
    BadNumber,
    NoSuchEncoding,
    ValueOutOfRange,
    OriginMovedBackwards,
    OutOfMemory,
};

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Output = struct {
    origin: u64,
    code: []u8,
    symbols: std.StringHashMap(u64),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Output) void {
        self.alloc.free(self.code);
        var it = self.symbols.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.symbols.deinit();
    }

    pub fn symbol(self: *const Output, name: []const u8) ?u64 {
        return self.symbols.get(name);
    }
};

/// Assemble a full source text. On error, `diag` (if non-null) carries the
/// offending line number and a static message.
pub fn assemble(alloc: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) Error!Output {
    var a = Assembler.init(alloc);
    defer a.deinit();
    return a.run(source) catch |err| {
        if (diag) |d| d.* = a.diag;
        return err;
    };
}

// ── Implementation ───────────────────────────────────────────────────────

const OperandShape = union(enum) {
    none,
    reg_a,
    imm: struct { expr: Expr, wide: bool },
    expr: struct { expr: Expr, force_abs: bool },
    expr_x: Expr,
    expr_y: Expr,
    ind: Expr,
    ind_y: Expr,
    caps: struct { slot: Expr, near: Expr },
};

const Expr = struct {
    lhs: Term,
    op: enum { none, add, sub } = .none,
    rhs: Term = .{ .number = 0 },

    const Term = union(enum) {
        number: u64,
        symbol: []const u8,
    };
};

const Item = union(enum) {
    instr: struct {
        line: usize,
        pc: u64,
        enc: isa.Encoding,
        shape: OperandShape,
    },
    data: struct {
        pc: u64,
        bytes: std.ArrayListUnmanaged(u8),
    },
};

const Assembler = struct {
    alloc: std.mem.Allocator,
    symbols: std.StringHashMap(u64),
    items: std.ArrayListUnmanaged(Item) = .{},
    pc: u64 = 0,
    origin: ?u64 = null,
    diag: Diagnostic = .{},

    fn init(alloc: std.mem.Allocator) Assembler {
        return .{ .alloc = alloc, .symbols = std.StringHashMap(u64).init(alloc) };
    }

    fn deinit(self: *Assembler) void {
        for (self.items.items) |*item| switch (item.*) {
            .data => |*d| d.bytes.deinit(self.alloc),
            else => {},
        };
        self.items.deinit(self.alloc);
        // symbols ownership transfers to Output on success; on failure free.
        var it = self.symbols.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.symbols.deinit();
    }

    fn fail(self: *Assembler, line_no: usize, msg: []const u8, err: Error) Error {
        self.diag = .{ .line = line_no, .message = msg };
        return err;
    }

    fn run(self: *Assembler, source: []const u8) Error!Output {
        // Pass 1: parse, size, place; collect symbols.
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            try self.line(line_no, raw);
        }
        // Pass 2: resolve and emit.
        const org = self.origin orelse 0;
        if (self.pc < org) return Error.BadDirective;
        const code = try self.alloc.alloc(u8, @intCast(self.pc - org));
        errdefer self.alloc.free(code);
        @memset(code, 0);
        for (self.items.items) |*item| switch (item.*) {
            .data => |d| @memcpy(code[@intCast(d.pc - org)..][0..d.bytes.items.len], d.bytes.items),
            .instr => |ins| {
                const buf = code[@intCast(ins.pc - org)..][0..ins.enc.size()];
                try self.emit(ins.line, ins.pc, ins.enc, ins.shape, buf);
            },
        };
        const symbols = self.symbols;
        self.symbols = std.StringHashMap(u64).init(self.alloc);
        return .{ .origin = org, .code = code, .symbols = symbols, .alloc = self.alloc };
    }

    fn define(self: *Assembler, line_no: usize, name: []const u8, value: u64) Error!void {
        const gop = try self.symbols.getOrPut(name);
        if (gop.found_existing)
            return self.fail(line_no, "duplicate symbol", Error.DuplicateSymbol);
        gop.key_ptr.* = try self.alloc.dupe(u8, name);
        gop.value_ptr.* = value;
    }

    fn line(self: *Assembler, line_no: usize, raw: []const u8) Error!void {
        var text = raw;
        if (std.mem.indexOfScalar(u8, text, ';')) |i| text = text[0..i];
        text = std.mem.trim(u8, text, " \t\r");
        if (text.len == 0) return;

        // label:
        if (std.mem.indexOfScalar(u8, text, ':')) |i| {
            if (validSymbol(text[0..i])) {
                try self.define(line_no, text[0..i], self.pc);
                text = std.mem.trim(u8, text[i + 1 ..], " \t");
                if (text.len == 0) return;
            }
        }

        // NAME = expr
        if (std.mem.indexOfScalar(u8, text, '=')) |i| {
            const name = std.mem.trim(u8, text[0..i], " \t");
            if (validSymbol(name)) {
                const expr = try self.parseExpr(line_no, std.mem.trim(u8, text[i + 1 ..], " \t"));
                const v = try self.eval(line_no, expr);
                return self.define(line_no, name, v);
            }
        }

        if (text[0] == '.') return self.directive(line_no, text);

        // mnemonic [operand]
        const sp = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        const mnem = try self.mnemonic(line_no, text[0..sp]);
        const rest = if (sp < text.len) std.mem.trim(u8, text[sp..], " \t") else "";
        const shape = try self.parseOperand(line_no, rest);
        const enc = try self.pick(line_no, mnem, shape);
        try self.items.append(self.alloc, .{ .instr = .{
            .line = line_no,
            .pc = self.pc,
            .enc = enc,
            .shape = shape,
        } });
        self.pc += enc.size();
    }

    fn directive(self: *Assembler, line_no: usize, text: []const u8) Error!void {
        const sp = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        const name = text[0..sp];
        const rest = if (sp < text.len) std.mem.trim(u8, text[sp..], " \t") else "";
        if (std.ascii.eqlIgnoreCase(name, ".org")) {
            const v = try self.eval(line_no, try self.parseExpr(line_no, rest));
            if (self.origin == null) {
                self.origin = v;
            } else if (v < self.pc) {
                return self.fail(line_no, ".org must not move backwards", Error.OriginMovedBackwards);
            }
            self.pc = v;
            return;
        }
        var bytes: std.ArrayListUnmanaged(u8) = .{};
        errdefer bytes.deinit(self.alloc);
        if (std.ascii.eqlIgnoreCase(name, ".qword")) {
            var it = std.mem.splitScalar(u8, rest, ',');
            while (it.next()) |part| {
                const v = try self.eval(line_no, try self.parseExpr(line_no, std.mem.trim(u8, part, " \t")));
                try bytes.appendSlice(self.alloc, std.mem.asBytes(&std.mem.nativeToLittle(u64, v)));
            }
        } else if (std.ascii.eqlIgnoreCase(name, ".byte")) {
            var it = std.mem.splitScalar(u8, rest, ',');
            while (it.next()) |part| {
                const v = try self.eval(line_no, try self.parseExpr(line_no, std.mem.trim(u8, part, " \t")));
                if (v > 0xFF) return self.fail(line_no, ".byte value out of range", Error.ValueOutOfRange);
                try bytes.append(self.alloc, @intCast(v));
            }
        } else if (std.ascii.eqlIgnoreCase(name, ".ascii")) {
            if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"')
                return self.fail(line_no, ".ascii needs a quoted string", Error.BadDirective);
            try bytes.appendSlice(self.alloc, rest[1 .. rest.len - 1]);
        } else {
            return self.fail(line_no, "unknown directive", Error.BadDirective);
        }
        if (self.origin == null) self.origin = self.pc;
        try self.items.append(self.alloc, .{ .data = .{ .pc = self.pc, .bytes = bytes } });
        self.pc += bytes.items.len;
    }

    fn mnemonic(self: *Assembler, line_no: usize, word: []const u8) Error!isa.Mnemonic {
        inline for (comptime std.enums.values(isa.Mnemonic)) |m| {
            if (std.ascii.eqlIgnoreCase(word, m.spelling())) return m;
        }
        return self.fail(line_no, "unknown mnemonic", Error.UnknownMnemonic);
    }

    fn parseOperand(self: *Assembler, line_no: usize, text: []const u8) Error!OperandShape {
        if (text.len == 0) return .none;
        if (std.ascii.eqlIgnoreCase(text, "A")) return .reg_a;
        if (text[0] == '#') {
            const wide = text.len > 1 and text[1] == '#';
            const body = if (wide) text[2..] else text[1..];
            return .{ .imm = .{ .expr = try self.parseExpr(line_no, body), .wide = wide } };
        }
        if (text[0] == '(') {
            const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse
                return self.fail(line_no, "missing ')'", Error.BadOperand);
            const inner = try self.parseExpr(line_no, std.mem.trim(u8, text[1..close], " \t"));
            const suffix = std.mem.trim(u8, text[close + 1 ..], " \t");
            if (suffix.len == 0) return .{ .ind = inner };
            if (std.ascii.eqlIgnoreCase(suffix, ",Y")) return .{ .ind_y = inner };
            if (std.ascii.eqlIgnoreCase(suffix, ",A")) return .{ .ind = inner }; // TXR (ptr),A
            return self.fail(line_no, "bad indirect suffix", Error.BadOperand);
        }
        // CAPLD slot, (near)
        if (std.mem.indexOfScalar(u8, text, '(')) |paren| {
            if (std.mem.indexOfScalar(u8, text[0..paren], ',')) |comma| {
                const slot = try self.parseExpr(line_no, std.mem.trim(u8, text[0..comma], " \t"));
                const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse
                    return self.fail(line_no, "missing ')'", Error.BadOperand);
                const near = try self.parseExpr(line_no, std.mem.trim(u8, text[paren + 1 .. close], " \t"));
                return .{ .caps = .{ .slot = slot, .near = near } };
            }
        }
        // expr[,X|,Y] — split on the last comma.
        if (std.mem.lastIndexOfScalar(u8, text, ',')) |comma| {
            const reg = std.mem.trim(u8, text[comma + 1 ..], " \t");
            const body = std.mem.trim(u8, text[0..comma], " \t");
            if (std.ascii.eqlIgnoreCase(reg, "X")) return .{ .expr_x = try self.parseExpr(line_no, body) };
            if (std.ascii.eqlIgnoreCase(reg, "Y")) return .{ .expr_y = try self.parseExpr(line_no, body) };
            return self.fail(line_no, "bad index register", Error.BadOperand);
        }
        const force_abs = text[0] == '!';
        const body = if (force_abs) text[1..] else text;
        return .{ .expr = .{ .expr = try self.parseExpr(line_no, body), .force_abs = force_abs } };
    }

    fn parseExpr(self: *Assembler, line_no: usize, text: []const u8) Error!Expr {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return self.fail(line_no, "empty expression", Error.BadOperand);
        // Find a top-level + or - (skip position 0 so "-5" is a term).
        var i: usize = 1;
        while (i < t.len) : (i += 1) {
            if (t[i] == '+' or t[i] == '-') {
                return .{
                    .lhs = try self.parseTerm(line_no, std.mem.trim(u8, t[0..i], " \t")),
                    .op = if (t[i] == '+') .add else .sub,
                    .rhs = try self.parseTerm(line_no, std.mem.trim(u8, t[i + 1 ..], " \t")),
                };
            }
        }
        return .{ .lhs = try self.parseTerm(line_no, t) };
    }

    fn parseTerm(self: *Assembler, line_no: usize, text: []const u8) Error!Expr.Term {
        if (text.len == 0) return self.fail(line_no, "empty term", Error.BadOperand);
        if (text[0] == '$' or text[0] == '%' or std.ascii.isDigit(text[0]) or text[0] == '-') {
            return .{ .number = parseNumber(text) catch
                return self.fail(line_no, "bad number", Error.BadNumber) };
        }
        if (!validSymbol(text)) return self.fail(line_no, "bad symbol", Error.BadOperand);
        return .{ .symbol = text };
    }

    fn evalTerm(self: *Assembler, line_no: usize, term: Expr.Term) Error!u64 {
        return switch (term) {
            .number => |n| n,
            .symbol => |s| self.symbols.get(s) orelse
                self.fail(line_no, "unknown symbol", Error.UnknownSymbol),
        };
    }

    fn eval(self: *Assembler, line_no: usize, expr: Expr) Error!u64 {
        const lhs = try self.evalTerm(line_no, expr.lhs);
        return switch (expr.op) {
            .none => lhs,
            .add => lhs +% try self.evalTerm(line_no, expr.rhs),
            .sub => lhs -% try self.evalTerm(line_no, expr.rhs),
        };
    }

    /// Can this expression be evaluated right now (pass 1)?
    fn known(self: *Assembler, expr: Expr) bool {
        const termKnown = struct {
            fn f(a: *Assembler, t: Expr.Term) bool {
                return switch (t) {
                    .number => true,
                    .symbol => |s| a.symbols.contains(s),
                };
            }
        }.f;
        if (!termKnown(self, expr.lhs)) return false;
        return expr.op == .none or termKnown(self, expr.rhs);
    }

    /// Choose the encoding for (mnemonic, operand shape). Sizing decisions
    /// happen here, in pass 1, and are final — pass 2 must agree.
    fn pick(self: *Assembler, line_no: usize, mnem: isa.Mnemonic, shape: OperandShape) Error!isa.Encoding {
        const modes: []const isa.Mode = switch (shape) {
            .none => &.{ .impl, .acc },
            .reg_a => &.{.acc},
            .imm => |im| blk: {
                if (im.wide) break :blk &.{.imm64};
                if (self.known(im.expr)) {
                    const v = self.eval(line_no, im.expr) catch unreachable;
                    if (fitsI8(v)) break :blk &.{ .imm8, .imm64 };
                }
                break :blk &.{ .imm64, .imm8 };
            },
            .expr => |ex| blk: {
                if (isa.lookup(mnem, .rel16) != null) break :blk &.{.rel16};
                if (isa.lookup(mnem, .desc) != null) break :blk &.{.desc};
                if (ex.force_abs) break :blk &.{.abs};
                if (self.known(ex.expr)) {
                    const v = self.eval(line_no, ex.expr) catch unreachable;
                    if (v < 0x1000) break :blk &.{ .near, .abs };
                }
                break :blk &.{ .abs, .near };
            },
            .expr_x => &.{.near_x},
            .expr_y => &.{.near_y},
            .ind => &.{.ind},
            .ind_y => &.{.ind_y},
            .caps => &.{.caps},
        };
        for (modes) |mode| {
            if (isa.lookup(mnem, mode)) |enc| return enc;
        }
        return self.fail(line_no, "no such encoding for this operand form", Error.NoSuchEncoding);
    }

    fn emit(self: *Assembler, line_no: usize, pc: u64, enc: isa.Encoding, shape: OperandShape, buf: []u8) Error!void {
        buf[0] = enc.opcode;
        const next_ip = pc + enc.size();
        switch (enc.mode) {
            .impl, .acc => {},
            .imm8 => {
                const v = try self.eval(line_no, shape.imm.expr);
                if (!fitsI8(v)) return self.fail(line_no, "imm8 out of range", Error.ValueOutOfRange);
                buf[1] = @truncate(v);
            },
            .imm64 => writeU64(buf[1..9], try self.eval(line_no, shape.imm.expr)),
            .near, .near_x, .near_y, .ind, .ind_y => {
                const v = try self.eval(line_no, switch (shape) {
                    .expr => |ex| ex.expr,
                    .expr_x => |e2| e2,
                    .expr_y => |e2| e2,
                    .ind => |e2| e2,
                    .ind_y => |e2| e2,
                    else => return self.fail(line_no, "operand mismatch", Error.BadOperand),
                });
                if (v >= 0x1000) return self.fail(line_no, "near-page offset out of range", Error.ValueOutOfRange);
                writeU16(buf[1..3], @intCast(v));
            },
            .abs => writeU64(buf[1..9], try self.eval(line_no, shape.expr.expr)),
            .rel16 => {
                const target = try self.eval(line_no, shape.expr.expr);
                const delta = @as(i64, @bitCast(target -% next_ip));
                if (delta > std.math.maxInt(i16) or delta < std.math.minInt(i16))
                    return self.fail(line_no, "branch out of range", Error.ValueOutOfRange);
                writeU16(buf[1..3], @bitCast(@as(i16, @intCast(delta))));
            },
            .desc => {
                const v = try self.eval(line_no, shape.expr.expr);
                if (v >= 64) return self.fail(line_no, "descriptor slot out of range", Error.ValueOutOfRange);
                buf[1] = @intCast(v);
            },
            .caps => {
                const slot = try self.eval(line_no, shape.caps.slot);
                const near = try self.eval(line_no, shape.caps.near);
                if (slot > 0xFFFF or near >= 0x1000)
                    return self.fail(line_no, "CAPLD operand out of range", Error.ValueOutOfRange);
                writeU16(buf[1..3], @intCast(slot));
                writeU16(buf[3..5], @intCast(near));
            },
        }
    }
};

fn writeU16(buf: []u8, v: u16) void {
    std.mem.writeInt(u16, buf[0..2], v, .little);
}

fn writeU64(buf: []u8, v: u64) void {
    std.mem.writeInt(u64, buf[0..8], v, .little);
}

fn fitsI8(v: u64) bool {
    const s = @as(i64, @bitCast(v));
    return s >= -128 and s <= 127;
}

fn validSymbol(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn parseNumber(text: []const u8) !u64 {
    var t = text;
    var neg = false;
    if (t.len > 0 and t[0] == '-') {
        neg = true;
        t = t[1..];
    }
    var base: u8 = 10;
    if (t.len > 0 and t[0] == '$') {
        base = 16;
        t = t[1..];
    } else if (t.len > 0 and t[0] == '%') {
        base = 2;
        t = t[1..];
    }
    if (t.len == 0) return error.BadNumber;
    var v: u64 = 0;
    for (t) |c| {
        if (c == '_') continue;
        const digit = std.fmt.charToDigit(c, base) catch return error.BadNumber;
        v = v *% base +% digit;
    }
    return if (neg) 0 -% v else v;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "countdown program assembles to known bytes" {
    const src =
        \\        .org $1000
        \\start:  LDX #5
        \\loop:   DEX
        \\        BNE loop
        \\        HLT
    ;
    var out = try assemble(testing.allocator, src, null);
    defer out.deinit();
    try testing.expectEqual(@as(u64, 0x1000), out.origin);
    try testing.expectEqualSlices(u8, &.{
        0xA2, 5, // LDX #5
        0xCA, // DEX
        0xD0, 0xFC, 0xFF, // BNE -4
        0xDB, // HLT
    }, out.code);
    try testing.expectEqual(@as(u64, 0x1002), out.symbol("loop").?);
}

test "immediate sizing: imm8 vs imm64, forced wide" {
    const src =
        \\ .org $1000
        \\ LDA #100
        \\ LDA #200
        \\ LDA ##1
        \\ LDA #$FF00_0000_0000_0000
    ;
    var out = try assemble(testing.allocator, src, null);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0xA9), out.code[0]); // imm8
    try testing.expectEqual(@as(u8, 0xA3), out.code[2]); // 200 > 127 → imm64
    try testing.expectEqual(@as(u8, 0xA3), out.code[11]); // ## forces
    try testing.expectEqual(@as(u8, 0xA3), out.code[20]); // big hex
}

test "near vs absolute selection and forcing" {
    const src =
        \\ .org $1000
        \\ buf = $2000
        \\ ptr = $40
        \\ LDA ptr
        \\ LDA buf
        \\ LDA !ptr
        \\ STA (ptr),Y
        \\ SEND 3
        \\ CAPLD 7, ($40)
        \\ TXR (ptr),A
    ;
    var out = try assemble(testing.allocator, src, null);
    defer out.deinit();
    var i: usize = 0;
    try testing.expectEqual(@as(u8, 0xA5), out.code[i]); // LDA near
    i += 3;
    try testing.expectEqual(@as(u8, 0xAD), out.code[i]); // LDA abs
    i += 9;
    try testing.expectEqual(@as(u8, 0xAD), out.code[i]); // forced abs
    i += 9;
    try testing.expectEqual(@as(u8, 0x91), out.code[i]); // STA (near),Y
    i += 3;
    try testing.expectEqual(@as(u8, 0x17), out.code[i]); // SEND desc
    try testing.expectEqual(@as(u8, 3), out.code[i + 1]);
    i += 2;
    try testing.expectEqual(@as(u8, 0x77), out.code[i]); // CAPLD
    try testing.expectEqual(@as(u8, 7), out.code[i + 1]);
    try testing.expectEqual(@as(u8, 0x40), out.code[i + 3]);
    i += 5;
    try testing.expectEqual(@as(u8, 0x07), out.code[i]); // TXR (ptr),A
}

test "forward references resolve" {
    const src =
        \\ .org $1000
        \\ JMP done
        \\ NOP
        \\done: HLT
    ;
    var out = try assemble(testing.allocator, src, null);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 0x4C), out.code[0]);
    const target = std.mem.readInt(u64, out.code[1..9], .little);
    try testing.expectEqual(out.symbol("done").?, target);
}

test "data directives" {
    const src =
        \\ .org $2000
        \\ .qword $1122, 2
        \\ .byte 1, 2, 3
        \\ .ascii "hi"
    ;
    var out = try assemble(testing.allocator, src, null);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 16 + 3 + 2), out.code.len);
    try testing.expectEqual(@as(u64, 0x1122), std.mem.readInt(u64, out.code[0..8], .little));
    try testing.expectEqualSlices(u8, "hi", out.code[19..21]);
}

test "errors carry line numbers" {
    var diag = Diagnostic{};
    const r = assemble(testing.allocator, ".org $1000\nBOGUS #1\n", &diag);
    try testing.expectError(Error.UnknownMnemonic, r);
    try testing.expectEqual(@as(usize, 2), diag.line);
}
