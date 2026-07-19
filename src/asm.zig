//! A small two-pass assembler for the 6564-Net, driven by the same ISA table
//! as the simulator (src/isa.zig) — one source of truth, per §9.
//!
//! ## Syntax
//!
//!   ; comment                        label:      NAME = expr
//!   .org $1000        set origin     .qword v,…  emit 64-bit words
//!   .byte v,…         emit bytes     .ascii "…"  emit text
//!
//! ## Contract directives
//!
//! Every hand-written program documents its deployment in a "Harness
//! contract" comment. These directives are that contract made machine-
//! readable: they emit no bytes and change no encodings — they fill
//! `Output.meta`, which the generic loader (src/asm_run.zig) executes the
//! way each demo_*.zig harness once did by hand.
//!
//!   .actor Name(next cap @ $840, fuse arg @ A)
//!                        the actor and its params. `cap` is a capability:
//!                        `= N` pins PTT slot N (the code bakes window
//!                        constants); `@ addr` lets the loader pick a slot
//!                        and stage the window pointer at addr; bare `cap`
//!                        is grant-only. Options: `reply` (the device's
//!                        own PTT aims back at our RX), `rx=N` (which of
//!                        the target's RX rings — a stage takes items on
//!                        one ring and acks on another). `arg` is a
//!                        number: `@ A` arrives in the accumulator at
//!                        spawn, `@ addr` is staged. `cap[]` stages a
//!                        group's window pointers at addr, aligned like
//!                        joe groups: a singleton takes them all, equal
//!                        groups pair off, larger groups slice. `sup @
//!                        addr watchdog=N` supervises: the child's spawn
//!                        block {ctx, entry, sp, arg} lands at addr, its
//!                        exit link aims at our CQ, its leash is ours to
//!                        set (spec §5.4).
//!   .ring 2 rx cap=2 auto_repost post=2 size=8
//!                        a descriptor the loader stages: slot, kind
//!                        (sq|cq|rx), capacity (a power of two), optional
//!                        pinned base=addr (when the code addresses the
//!                        storage), auto_repost, `post=N size=M` landing
//!                        entries (cookie = buffer address), `grant` for a
//!                        pre-granted tail.
//!   .timer = 1 period=2500
//!                        the black-hole capability (spec §6.3): `= N`
//!                        pins the PTT slot, `@ addr` stages its window
//!                        pointer; period becomes the fabric timeout.
//!   .stage $B00 1, 2, 3  qwords the loader writes before spawn (near
//!                        page below $1000, core RAM at and above it).
//!   .reserve $2200 $400  RAM the program owns (buffers, request cells):
//!                        the loader allocates nothing on top of it.
//!   .var name $850       a named readback cell for the outcome report.
//!   .use "pong.asm"      another actor's source joins the system.
//!   .system … .endsystem the deployment, in joe's system-block grammar —
//!                        one dialect for the whole machine; lines are
//!                        captured verbatim for joe's planner.
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

pub const ParamKind = enum { cap, arg, sup };
pub const ParamWhere = union(enum) {
    /// Bare `cap` — grant only: the code builds target addresses itself
    /// (SQE routing by prefix match); no slot pinned, nothing staged.
    none,
    /// `arg @ A` — the spawn argument register.
    reg_a,
    /// `@ addr` — staged at a near ($000-$FFF) or RAM cell.
    cell: u64,
    /// `cap = N` — pinned PTT slot; the code bakes the window constant.
    slot: u16,
};

/// One parameter of a `.actor` signature.
pub const MetaParam = struct {
    name: []const u8,
    kind: ParamKind,
    /// `cap[]` / `arg[]`: a group reference staged as an 8-byte-stride array.
    group: bool = false,
    where: ParamWhere,
    /// Trailing `reply`: this capability's target sends data back — the
    /// loader stages the target's own capability aimed at our RX ring
    /// (a device's reply window, staged like wiring any two actors).
    reply: bool = false,
    /// `rx=N`: which of the target's RX rings this capability aims at.
    /// Null aims at the target's first-declared RX — but an actor
    /// targeted on two rings (a pipeline stage: items one way, acks the
    /// other) needs its callers to say which.
    rx: ?u8 = null,
    /// `sup … watchdog=N`: the child's burst budget (spec §5.4), set by
    /// the supervisor's contract — an actor must not edit its own leash.
    watchdog: u64 = 0,
};

/// One `.ring` descriptor for the loader to stage.
pub const MetaRing = struct {
    slot: u8,
    kind: enum { sq, cq, rx },
    cap_log2: u8,
    /// Pinned storage base; null lets the loader allocate.
    base: ?u64 = null,
    auto_repost: bool = false,
    /// Landing entries to post (RX): count and buffer size, cookie = buffer.
    post: u16 = 0,
    size: u16 = 8,
    /// Pre-grant the whole tail (no RECV in the code).
    grant: bool = false,
};

pub const MetaStage = struct { addr: u64, values: []u64 };
/// `.reserve addr len` — RAM the program owns (buffers, request cells):
/// the loader must not allocate ring storage or stacks over it.
pub const MetaReserve = struct { addr: u64, len: u64 };
pub const MetaVar = struct { name: []const u8, addr: u64 };
pub const MetaTimer = struct { slot: ?u16 = null, cell: ?u64 = null, period: u64 };

/// The machine-readable harness contract (see the header comment). Every
/// slice is owned by `Output.alloc`; absent pieces are empty/null, so a
/// directive-free source has an empty meta and nothing downstream changes.
pub const Meta = struct {
    actor: ?[]const u8 = null,
    params: []MetaParam = &.{},
    rings: []MetaRing = &.{},
    stages: []MetaStage = &.{},
    reserves: []MetaReserve = &.{},
    vars: []MetaVar = &.{},
    timer: ?MetaTimer = null,
    uses: [][]const u8 = &.{},
    /// Verbatim lines between .system/.endsystem — joe's system grammar.
    system: ?[]const u8 = null,
};

pub const Output = struct {
    origin: u64,
    code: []u8,
    symbols: std.StringHashMap(u64),
    meta: Meta = .{},
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Output) void {
        self.alloc.free(self.code);
        var it = self.symbols.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.symbols.deinit();
        freeMeta(self.alloc, &self.meta);
    }

    pub fn symbol(self: *const Output, name: []const u8) ?u64 {
        return self.symbols.get(name);
    }
};

fn freeMeta(alloc: std.mem.Allocator, meta: *Meta) void {
    if (meta.actor) |a| alloc.free(a);
    for (meta.params) |p| alloc.free(p.name);
    alloc.free(meta.params);
    alloc.free(meta.rings);
    for (meta.stages) |s| alloc.free(s.values);
    alloc.free(meta.stages);
    alloc.free(meta.reserves);
    for (meta.vars) |v| alloc.free(v.name);
    alloc.free(meta.vars);
    for (meta.uses) |u| alloc.free(u);
    alloc.free(meta.uses);
    if (meta.system) |s| alloc.free(s);
    meta.* = .{};
}

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
    /// `VFADD 0, 1` — two vector registers packed into one desc byte.
    pair: struct { a: Expr, b: Expr },
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
    // Contract accumulators — transferred to Output.meta on success.
    meta_actor: ?[]const u8 = null,
    meta_params: std.ArrayListUnmanaged(MetaParam) = .{},
    meta_rings: std.ArrayListUnmanaged(MetaRing) = .{},
    meta_stages: std.ArrayListUnmanaged(MetaStage) = .{},
    meta_reserves: std.ArrayListUnmanaged(MetaReserve) = .{},
    meta_vars: std.ArrayListUnmanaged(MetaVar) = .{},
    meta_timer: ?MetaTimer = null,
    meta_uses: std.ArrayListUnmanaged([]const u8) = .{},
    system_text: std.ArrayListUnmanaged(u8) = .{},
    saw_system: bool = false,
    in_system: bool = false,

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
        if (self.meta_actor) |a| self.alloc.free(a);
        for (self.meta_params.items) |p| self.alloc.free(p.name);
        self.meta_params.deinit(self.alloc);
        self.meta_rings.deinit(self.alloc);
        for (self.meta_stages.items) |s| self.alloc.free(s.values);
        self.meta_stages.deinit(self.alloc);
        self.meta_reserves.deinit(self.alloc);
        for (self.meta_vars.items) |v| self.alloc.free(v.name);
        self.meta_vars.deinit(self.alloc);
        for (self.meta_uses.items) |u| self.alloc.free(u);
        self.meta_uses.deinit(self.alloc);
        self.system_text.deinit(self.alloc);
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
            if (self.in_system) {
                const t = std.mem.trim(u8, raw, " \t\r");
                if (std.ascii.eqlIgnoreCase(t, ".endsystem")) {
                    self.in_system = false;
                } else {
                    try self.system_text.appendSlice(self.alloc, raw);
                    try self.system_text.append(self.alloc, '\n');
                }
                continue;
            }
            try self.line(line_no, raw);
        }
        if (self.in_system)
            return self.fail(line_no, ".system without .endsystem", Error.BadDirective);
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
        const meta = Meta{
            .actor = self.meta_actor,
            .params = try self.meta_params.toOwnedSlice(self.alloc),
            .rings = try self.meta_rings.toOwnedSlice(self.alloc),
            .stages = try self.meta_stages.toOwnedSlice(self.alloc),
            .reserves = try self.meta_reserves.toOwnedSlice(self.alloc),
            .vars = try self.meta_vars.toOwnedSlice(self.alloc),
            .timer = self.meta_timer,
            .uses = try self.meta_uses.toOwnedSlice(self.alloc),
            .system = if (self.saw_system)
                try self.system_text.toOwnedSlice(self.alloc)
            else
                null,
        };
        self.meta_actor = null;
        const symbols = self.symbols;
        self.symbols = std.StringHashMap(u64).init(self.alloc);
        return .{ .origin = org, .code = code, .symbols = symbols, .meta = meta, .alloc = self.alloc };
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
        if (std.ascii.eqlIgnoreCase(name, ".actor")) return self.dirActor(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".ring")) return self.dirRing(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".timer")) return self.dirTimer(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".stage")) return self.dirStage(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".reserve")) return self.dirReserve(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".var")) return self.dirVar(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".use")) return self.dirUse(line_no, rest);
        if (std.ascii.eqlIgnoreCase(name, ".system")) {
            if (self.saw_system)
                return self.fail(line_no, "duplicate .system block", Error.BadDirective);
            self.saw_system = true;
            self.in_system = true;
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, ".endsystem"))
            return self.fail(line_no, ".endsystem without .system", Error.BadDirective);
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

    fn evalStr(self: *Assembler, line_no: usize, text: []const u8) Error!u64 {
        return self.eval(line_no, try self.parseExpr(line_no, text));
    }

    fn dirActor(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        if (self.meta_actor != null)
            return self.fail(line_no, "duplicate .actor", Error.BadDirective);
        var head = rest;
        var body: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '(')) |open| {
            const close = std.mem.lastIndexOfScalar(u8, rest, ')') orelse
                return self.fail(line_no, ".actor missing ')'", Error.BadDirective);
            head = std.mem.trim(u8, rest[0..open], " \t");
            body = std.mem.trim(u8, rest[open + 1 .. close], " \t");
        }
        if (!validSymbol(head))
            return self.fail(line_no, ".actor needs a name", Error.BadDirective);
        self.meta_actor = try self.alloc.dupe(u8, head);
        if (body.len == 0) return;
        var parts = std.mem.splitScalar(u8, body, ',');
        while (parts.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            const sp = std.mem.indexOfAny(u8, p, " \t") orelse
                return self.fail(line_no, "param needs `name cap|arg @|= where`", Error.BadDirective);
            const pname = p[0..sp];
            if (!validSymbol(pname))
                return self.fail(line_no, "bad param name", Error.BadDirective);
            var spec = std.mem.trim(u8, p[sp..], " \t");
            var kind: ParamKind = undefined;
            var group = false;
            var matched = false;
            for ([_][]const u8{ "cap[]", "arg[]", "cap", "arg", "sup" }) |kw| {
                if (std.mem.startsWith(u8, spec, kw)) {
                    kind = switch (kw[0]) {
                        'c' => .cap,
                        'a' => .arg,
                        else => .sup,
                    };
                    group = kw.len == 5;
                    spec = std.mem.trim(u8, spec[kw.len..], " \t");
                    matched = true;
                    break;
                }
            }
            if (!matched)
                return self.fail(line_no, "param kind must be cap, arg or sup", Error.BadDirective);
            if (spec.len == 0) {
                // Bare `cap`: grant only, the code routes by address.
                if (kind != .cap or group)
                    return self.fail(line_no, "only a scalar cap can be bare (grant only)", Error.BadDirective);
                try self.meta_params.append(self.alloc, .{
                    .name = try self.alloc.dupe(u8, pname),
                    .kind = kind,
                    .where = .none,
                });
                continue;
            }
            if (spec.len < 2 or (spec[0] != '@' and spec[0] != '='))
                return self.fail(line_no, "param needs `@ where` or `= slot`", Error.BadDirective);
            const sep = spec[0];
            var toks = std.mem.tokenizeAny(u8, spec[1..], " \t");
            const val = toks.next() orelse
                return self.fail(line_no, "param needs a value after @ or =", Error.BadDirective);
            var reply = false;
            var rx: ?u8 = null;
            var watchdog: u64 = 0;
            while (toks.next()) |t| {
                if (std.ascii.eqlIgnoreCase(t, "reply")) {
                    if (kind != .cap)
                        return self.fail(line_no, "only a cap takes `reply`", Error.BadDirective);
                    reply = true;
                } else if (std.ascii.startsWithIgnoreCase(t, "rx=")) {
                    if (kind != .cap)
                        return self.fail(line_no, "only a cap takes `rx=`", Error.BadDirective);
                    const v = try self.evalStr(line_no, t[3..]);
                    if (v > 63) return self.fail(line_no, "rx slot out of range", Error.ValueOutOfRange);
                    rx = @intCast(v);
                } else if (std.ascii.startsWithIgnoreCase(t, "watchdog=")) {
                    if (kind != .sup)
                        return self.fail(line_no, "only a sup takes `watchdog=`", Error.BadDirective);
                    watchdog = try self.evalStr(line_no, t[9..]);
                } else return self.fail(line_no, "unknown param option", Error.BadDirective);
            }
            const where: ParamWhere = if (sep == '=') blk: {
                if (kind != .cap or group)
                    return self.fail(line_no, "only a scalar cap pins a PTT slot", Error.BadDirective);
                const s = try self.evalStr(line_no, val);
                if (s > 254) return self.fail(line_no, "PTT slot out of range", Error.ValueOutOfRange);
                break :blk .{ .slot = @intCast(s) };
            } else if (std.ascii.eqlIgnoreCase(val, "A")) blk: {
                if (kind != .arg or group)
                    return self.fail(line_no, "only a scalar arg rides the accumulator", Error.BadDirective);
                break :blk .reg_a;
            } else blk: {
                break :blk .{ .cell = try self.evalStr(line_no, val) };
            };
            if (kind == .sup and where != .cell)
                return self.fail(line_no, "a sup param needs `@ cell` for its spawn block", Error.BadDirective);
            try self.meta_params.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, pname),
                .kind = kind,
                .group = group,
                .where = where,
                .reply = reply,
                .rx = rx,
                .watchdog = watchdog,
            });
        }
    }

    fn dirRing(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        var toks = std.mem.tokenizeAny(u8, rest, " \t");
        const slot_tok = toks.next() orelse
            return self.fail(line_no, ".ring needs `slot kind …`", Error.BadDirective);
        const slot = try self.evalStr(line_no, slot_tok);
        if (slot > 63) return self.fail(line_no, "descriptor slot out of range", Error.ValueOutOfRange);
        const kind_tok = toks.next() orelse
            return self.fail(line_no, ".ring needs a kind (sq|cq|rx)", Error.BadDirective);
        var r = MetaRing{
            .slot = @intCast(slot),
            .kind = if (std.ascii.eqlIgnoreCase(kind_tok, "sq")) .sq //
            else if (std.ascii.eqlIgnoreCase(kind_tok, "cq")) .cq //
            else if (std.ascii.eqlIgnoreCase(kind_tok, "rx")) .rx //
            else return self.fail(line_no, "ring kind must be sq, cq or rx", Error.BadDirective),
            .cap_log2 = 0,
        };
        var saw_cap = false;
        while (toks.next()) |tok| {
            if (std.ascii.eqlIgnoreCase(tok, "auto_repost")) {
                r.auto_repost = true;
            } else if (std.ascii.eqlIgnoreCase(tok, "grant")) {
                r.grant = true;
            } else if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
                const key = tok[0..eq];
                const v = try self.evalStr(line_no, tok[eq + 1 ..]);
                if (std.ascii.eqlIgnoreCase(key, "cap")) {
                    if (v == 0 or (v & (v - 1)) != 0 or v > 256)
                        return self.fail(line_no, "ring cap must be a power of two ≤ 256", Error.ValueOutOfRange);
                    r.cap_log2 = @intCast(@ctz(v));
                    saw_cap = true;
                } else if (std.ascii.eqlIgnoreCase(key, "base")) {
                    r.base = v;
                } else if (std.ascii.eqlIgnoreCase(key, "post")) {
                    r.post = @intCast(@min(v, 256));
                } else if (std.ascii.eqlIgnoreCase(key, "size")) {
                    r.size = @intCast(@min(v, 4096));
                } else return self.fail(line_no, "unknown .ring key", Error.BadDirective);
            } else return self.fail(line_no, "unknown .ring flag", Error.BadDirective);
        }
        if (!saw_cap) return self.fail(line_no, ".ring needs cap=N", Error.BadDirective);
        try self.meta_rings.append(self.alloc, r);
    }

    fn dirTimer(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        if (self.meta_timer != null)
            return self.fail(line_no, "duplicate .timer", Error.BadDirective);
        if (rest.len < 2 or (rest[0] != '=' and rest[0] != '@'))
            return self.fail(line_no, ".timer needs `= slot` or `@ cell`", Error.BadDirective);
        var toks = std.mem.tokenizeAny(u8, rest[1..], " \t");
        const val = toks.next() orelse
            return self.fail(line_no, ".timer needs a slot or cell", Error.BadDirective);
        var t = MetaTimer{ .period = 2500 };
        if (rest[0] == '=') {
            const s = try self.evalStr(line_no, val);
            if (s > 254) return self.fail(line_no, "PTT slot out of range", Error.ValueOutOfRange);
            t.slot = @intCast(s);
        } else {
            t.cell = try self.evalStr(line_no, val);
        }
        while (toks.next()) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
                if (std.ascii.eqlIgnoreCase(tok[0..eq], "period")) {
                    t.period = try self.evalStr(line_no, tok[eq + 1 ..]);
                    continue;
                }
            }
            return self.fail(line_no, "unknown .timer key", Error.BadDirective);
        }
        self.meta_timer = t;
    }

    fn dirStage(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        const sp = std.mem.indexOfAny(u8, rest, " \t") orelse
            return self.fail(line_no, ".stage needs `addr v, …`", Error.BadDirective);
        const addr = try self.evalStr(line_no, rest[0..sp]);
        var values: std.ArrayListUnmanaged(u64) = .{};
        errdefer values.deinit(self.alloc);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, rest[sp..], " \t"), ',');
        while (it.next()) |part| {
            const v = try self.evalStr(line_no, std.mem.trim(u8, part, " \t"));
            try values.append(self.alloc, v);
        }
        try self.meta_stages.append(self.alloc, .{
            .addr = addr,
            .values = try values.toOwnedSlice(self.alloc),
        });
    }

    fn dirReserve(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        var toks = std.mem.tokenizeAny(u8, rest, " \t");
        const addr_tok = toks.next() orelse
            return self.fail(line_no, ".reserve needs `addr len`", Error.BadDirective);
        const len_tok = toks.next() orelse
            return self.fail(line_no, ".reserve needs a length", Error.BadDirective);
        if (toks.next() != null)
            return self.fail(line_no, ".reserve takes exactly `addr len`", Error.BadDirective);
        try self.meta_reserves.append(self.alloc, .{
            .addr = try self.evalStr(line_no, addr_tok),
            .len = try self.evalStr(line_no, len_tok),
        });
    }

    fn dirVar(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        var toks = std.mem.tokenizeAny(u8, rest, " \t");
        const vname = toks.next() orelse
            return self.fail(line_no, ".var needs `name addr`", Error.BadDirective);
        if (!validSymbol(vname))
            return self.fail(line_no, "bad .var name", Error.BadDirective);
        const addr_tok = toks.next() orelse
            return self.fail(line_no, ".var needs an address", Error.BadDirective);
        if (toks.next() != null)
            return self.fail(line_no, ".var takes exactly `name addr`", Error.BadDirective);
        try self.meta_vars.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, vname),
            .addr = try self.evalStr(line_no, addr_tok),
        });
    }

    fn dirUse(self: *Assembler, line_no: usize, rest: []const u8) Error!void {
        if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"')
            return self.fail(line_no, ".use needs a quoted file name", Error.BadDirective);
        try self.meta_uses.append(self.alloc, try self.alloc.dupe(u8, rest[1 .. rest.len - 1]));
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
        // expr[,X|,Y] — split on the last comma. Anything else after the
        // comma is a register pair (VFADD 0, 1).
        if (std.mem.lastIndexOfScalar(u8, text, ',')) |comma| {
            const reg = std.mem.trim(u8, text[comma + 1 ..], " \t");
            const body = std.mem.trim(u8, text[0..comma], " \t");
            if (std.ascii.eqlIgnoreCase(reg, "X")) return .{ .expr_x = try self.parseExpr(line_no, body) };
            if (std.ascii.eqlIgnoreCase(reg, "Y")) return .{ .expr_y = try self.parseExpr(line_no, body) };
            return .{ .pair = .{
                .a = try self.parseExpr(line_no, body),
                .b = try self.parseExpr(line_no, reg),
            } };
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
        // MAC n: the slot index selects one of sixteen one-byte opcodes in
        // the $?F column. The slot must be a pass-1 literal.
        if (mnem == .mac) {
            const ex = switch (shape) {
                .expr => |e2| e2.expr,
                else => return self.fail(line_no, "MAC needs a slot number", Error.BadOperand),
            };
            if (!self.known(ex))
                return self.fail(line_no, "MAC slot must be a literal", Error.BadOperand);
            const v = self.eval(line_no, ex) catch unreachable;
            if (v > 15) return self.fail(line_no, "MAC slot out of range", Error.ValueOutOfRange);
            return isa.decode[(@as(u8, @intCast(v)) << 4) | 0x0F].?;
        }
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
            .pair => &.{.desc},
            .caps => &.{.caps},
        };
        for (modes) |mode| {
            if (isa.lookup(mnem, mode)) |enc| return enc;
        }
        return self.fail(line_no, "no such encoding for this operand form", Error.NoSuchEncoding);
    }

    fn emit(self: *Assembler, line_no: usize, pc: u64, enc: isa.Encoding, shape: OperandShape, whole: []u8) Error!void {
        // Extended-page encodings carry the $42 prefix; operands follow the
        // opcode byte either way.
        var buf = whole;
        if (enc.page == .ext) {
            buf[0] = isa.ext_prefix;
            buf = buf[1..];
        }
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
            .desc => switch (shape) {
                .pair => |p| {
                    const a = try self.eval(line_no, p.a);
                    const b = try self.eval(line_no, p.b);
                    if (a > 7 or b > 7)
                        return self.fail(line_no, "vector register out of range", Error.ValueOutOfRange);
                    buf[1] = @intCast((a << 3) | b);
                },
                else => {
                    const v = try self.eval(line_no, shape.expr.expr);
                    if (v >= 64) return self.fail(line_no, "descriptor slot out of range", Error.ValueOutOfRange);
                    buf[1] = @intCast(v);
                },
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

test "contract directives fill meta and emit no bytes" {
    const src =
        \\ .actor RingNode(next cap @ $840, fuse arg @ A, ws cap[] @ $A00, con cap = 0)
        \\ .ring 1 cq cap=4
        \\ .ring 2 rx cap=2 auto_repost post=2 size=8 base=$4000
        \\ .timer = 3 period=3000
        \\ .stage $B00 1, 2, 3
        \\ .var finisher $850
        \\ .use "pong.asm"
        \\ .system
        \\    n0 = RingNode(n1, 800)
        \\ .endsystem
        \\ .org $1000
        \\ HLT
    ;
    var out = try assemble(testing.allocator, src, null);
    defer out.deinit();
    // The contract is metadata: one HLT is the whole program.
    try testing.expectEqual(@as(usize, 1), out.code.len);
    const m = &out.meta;
    try testing.expectEqualStrings("RingNode", m.actor.?);
    try testing.expectEqual(@as(usize, 4), m.params.len);
    try testing.expectEqualStrings("next", m.params[0].name);
    try testing.expectEqual(ParamKind.cap, m.params[0].kind);
    try testing.expectEqual(@as(u64, 0x840), m.params[0].where.cell);
    try testing.expectEqual(ParamWhere.reg_a, m.params[1].where);
    try testing.expect(m.params[2].group);
    try testing.expectEqual(@as(u16, 0), m.params[3].where.slot);
    try testing.expectEqual(@as(usize, 2), m.rings.len);
    try testing.expectEqual(@as(u8, 2), m.rings[0].cap_log2);
    try testing.expect(m.rings[1].auto_repost);
    try testing.expectEqual(@as(u16, 2), m.rings[1].post);
    try testing.expectEqual(@as(u64, 0x4000), m.rings[1].base.?);
    try testing.expectEqual(@as(u16, 3), m.timer.?.slot.?);
    try testing.expectEqual(@as(u64, 3000), m.timer.?.period);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, m.stages[0].values);
    try testing.expectEqualStrings("finisher", m.vars[0].name);
    try testing.expectEqualStrings("pong.asm", m.uses[0]);
    try testing.expect(std.mem.indexOf(u8, m.system.?, "n0 = RingNode(n1, 800)") != null);
}

test "a directive-free source has an empty meta" {
    var out = try assemble(testing.allocator, ".org $1000\nHLT\n", null);
    defer out.deinit();
    try testing.expectEqual(@as(?[]const u8, null), out.meta.actor);
    try testing.expectEqual(@as(usize, 0), out.meta.params.len);
    try testing.expectEqual(@as(?[]const u8, null), out.meta.system);
}

test "errors carry line numbers" {
    var diag = Diagnostic{};
    const r = assemble(testing.allocator, ".org $1000\nBOGUS #1\n", &diag);
    try testing.expectError(Error.UnknownMnemonic, r);
    try testing.expectEqual(@as(usize, 2), diag.line);
}
