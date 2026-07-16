//! joe — a small language for the 6564-Net. Go's clothes, Erlang's soul,
//! occam's discipline (docs/joe-v1-sketch.md is the authoritative sketch).
//!
//! The constructs are the silicon: an `actor` is a context, `var` is the
//! near page, `serve` is LSTN → CQPOP → tag dispatch → loop, `after` is the
//! fabric-as-clock timer, `send` is fire-and-forget (the runtime consumes
//! transport acks for buffer release and shows them to no one — the
//! end-to-end argument as a language default). What joe cannot say is the
//! real specification: no shared state, no synchronous calls, no
//! transport-ack visibility.
//!
//! v1 compiles the pingpong subset: `message`, `actor`, `var`, params,
//! `send`, `serve`/`case`/`where`/`after`, `if`/`else`, `halt`, `bounded`,
//! assignment (`=`, `+=`, `-=`). Deferred to later items (they parse to an
//! honest "unsupported in v1" error): `let` liveness (that IS handoff item
//! 4), `spawn`, `chain`, `for`, `quiesce`, `region`/`grant`, floats in
//! messages. The compiler is four passes in one file — lex → parse →
//! check → emit — producing .asm text for asm.zig. No IR.
//!
//! ## The v1 runtime ABI (matches ping.asm/pong.asm's proven wiring)
//!
//!   desc slots:  0 SQ ($2400)  1 CQ ($2000)  2 RX ($2100, cap 2,
//!                AUTO_REPOST)  5 timer SQ ($2480)
//!   RAM:         $2200/$2240 landing buffers (cap 64)  $2500 msg staging
//!   near page:   params from $800, vars after them, then compiler
//!                internals (_w0, _ptr, _t, _acc, _fp)
//!   PTT:         addr params are window values staged by the harness;
//!                PTT 1 is the black hole when any `after` exists
//!   timer:       AUTO_REARM TXR, SQ slot 5, cookie $77 (reserved)
//!
//! ## Wire format
//!
//! word0 low 16 bits = message tag (declaration order, 1-based); fields
//! pack after it, each aligned to its own size, so a field never straddles
//! an 8-byte word. Total ≤ 8 bytes rides TXR (a register datagram — the
//! 60-cycle path); larger messages stage at $2500 and ride SEND. Both land
//! identically, so the receive side never knows which.

const std = @import("std");
const isa = @import("isa.zig");
const ring = @import("ring.zig");
const machine = @import("machine.zig");

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ Syntax, Semantics, Unsupported, OutOfMemory };

// ── Runtime ABI ──────────────────────────────────────────────────────────

/// Where one compiled actor instance lives. Every RAM address the compiler
/// emits derives from this, so any number of instances can share a core —
/// the loader hands each context its own block. The defaults describe a
/// lone actor in the classic demo shape (code $1000, data $2000).
pub const Layout = struct {
    origin: u64 = 0x1000,
    data: u64 = 0x2000,
    /// PTT slot of the black hole the `after` timer ticks against.
    /// Fixed at 255 by the v1 ABI: every actor on a core shares the one
    /// black hole, and capability slots grow from 0 without ever
    /// colliding with it.
    timer_ptt: u16 = 255,

    pub fn cqBase(l: Layout) u64 {
        return l.data; // 16 completion entries
    }
    pub fn rxBase(l: Layout) u64 {
        return l.data + 0x100; // 2 landing entries, AUTO_REPOST
    }
    pub fn timerBase(l: Layout) u64 {
        return l.data + 0x140;
    }
    pub fn sqBase(l: Layout) u64 {
        return l.data + 0x160;
    }
    pub fn staging(l: Layout) u64 {
        return l.data + 0x180; // outbound message image (64B)
    }
    pub fn land0(l: Layout) u64 {
        return l.data + 0x200;
    }
    pub fn land1(l: Layout) u64 {
        return l.data + 0x240;
    }
    pub fn timerWindow(l: Layout) u64 {
        return (@as(u64, 0xFF) << 56) | (@as(u64, l.timer_ptt) << 40);
    }
};

pub const abi = struct {
    pub const timer_desc: u8 = 5;
    pub const land_cap: u64 = 64;
    /// The one capability token of the v1 ABI: RX rings require it, the
    /// loader's PTT entries present it.
    pub const token: u64 = 0x6564;
    pub const param_base: u16 = 0x800;
    pub const timer_cookie: u64 = 0x77;
    /// One instance block: code at +0, data at +$800 (rings, buffers,
    /// staging, then the array area), stack down from +$2000. The loader
    /// places context c of a core at ram_base + c * block_size.
    pub const block_size: u64 = 0x2000;
    pub const data_off: u64 = 0x800;
    /// Arrays (group params and `var x [N]u64`) live in RAM from this
    /// offset within the data region — the near page is too small.
    pub const array_off: u64 = 0x280;
    /// Group parameters hold up to this many windows.
    pub const group_cap: u16 = 128;
};

// ── AST ──────────────────────────────────────────────────────────────────

const Type = enum {
    u8_,
    u16_,
    u32_,
    u64_,
    addr,
    /// `[]addr` — a group parameter: the count lives in the near-page
    /// slot, the windows in a RAM array the loader stages.
    addr_slice,

    fn size(self: Type) u16 {
        return switch (self) {
            .u8_ => 1,
            .u16_ => 2,
            .u32_ => 4,
            .u64_, .addr, .addr_slice => 8,
        };
    }

    fn named(name: []const u8) ?Type {
        const pairs = .{
            .{ "u8", Type.u8_ },   .{ "u16", Type.u16_ },
            .{ "u32", Type.u32_ }, .{ "u64", Type.u64_ },
            .{ "addr", Type.addr },
        };
        inline for (pairs) |p| {
            if (std.mem.eql(u8, name, p[0])) return p[1];
        }
        return null;
    }
};

const Field = struct {
    name: []const u8,
    ty: Type,
    offset: u16 = 0,
};

const Message = struct {
    name: []const u8,
    fields: []Field,
    tag: u16 = 0,
    wire_size: u16 = 0, // padded to 8
};

const BinOp = enum { add, sub, band, bor, bxor, shl, shr, eq, ne, lt, le, gt, ge, land };

const Expr = union(enum) {
    int: u64,
    ident: []const u8,
    field: struct { base: []const u8, name: []const u8 },
    index: struct { base: []const u8, idx: *Expr },
    bin: struct { op: BinOp, l: *Expr, r: *Expr },
};

const AssignOp = enum { set, add, sub };

const Stmt = union(enum) {
    assign: struct { name: []const u8, idx: ?*Expr, op: AssignOp, expr: *Expr },
    send: struct { target: []const u8, target_idx: ?*Expr, msg: []const u8, args: []*Expr, line: usize },
    for_range: struct { name: []const u8, from: *Expr, to: *Expr, body: []Stmt },
    for_group: struct { idx: []const u8, elem: []const u8, group: []const u8, body: []Stmt, line: usize },
    /// `send tty, "TEXT"` — raw bytes to a device: no tag, no fields,
    /// just the payload a teletype expects.
    send_str: struct { target: []const u8, text: []const u8, line: usize },
    if_: struct { cond: *Expr, then: []Stmt, els: []Stmt },
    halt: struct { ok: bool },
    bounded: struct { n: u64, body: []Stmt },
    /// Enter the lame-duck phase: timers die, the quiesce case set takes
    /// over. Termination is a phase, not an instruction.
    quiesce,
    spawn: struct {
        actor: []const u8,
        args: []u64, // v1: literal args only
        restarts: u64,
        watchdog: u64,
        line: usize,
    },
};

const ExitCause = enum { crash, hung, abandoned };

const Handler = union(enum) {
    case: struct {
        msg: []const u8,
        bind: ?[]const u8, // null = wildcard `_`
        where: ?*Expr,
        body: []Stmt,
        line: usize,
    },
    after: struct { n: u64, body: []Stmt },
    exit_case: struct {
        bind: []const u8,
        cause: ExitCause,
        code_bind: ?[]const u8,
        body: []Stmt,
        line: usize,
    },
};

const Param = struct { name: []const u8, ty: Type };

/// `array` > 0 makes this a u64 array of that many elements, living in
/// the instance block's RAM (the near page is too small for them).
const VarDecl = struct { name: []const u8, ty: Type, init: ?*Expr, array: u16 = 0 };

const Actor = struct {
    name: []const u8,
    params: []Param,
    vars: []VarDecl,
    body: []Stmt,
    handlers: []Handler,
    /// The lame-duck case set (sketch §2.3): served after a `quiesce`
    /// statement, with timers dead — stragglers converge, the machine
    /// goes quiet instead of staying awake.
    quiesce: []Handler,
};

/// One line of a `system` block: `name = Actor(args) [on core]`.
/// An argument that names another instance is a capability reference —
/// the loader wires a PTT slot and stages the window value.
pub const InstanceDecl = struct {
    name: []const u8,
    actor: []const u8,
    args: []const Arg,
    core: ?u16,
    /// `name = Actor[N](args)` declares N replicas; each is a context.
    replicas: u64 = 1,
    line: usize,

    pub const Arg = union(enum) {
        int: u64,
        ref: []const u8,
        /// The literal `index`: each replica receives its own index.
        index,
    };
};

const Program = struct {
    messages: []Message,
    actors: []Actor,
    system: []InstanceDecl,
};

// ── Lexer ────────────────────────────────────────────────────────────────

const TokKind = enum {
    ident,
    int,
    string,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    colon,
    dot,
    dotdot,
    underscore,
    assign, // =
    plus_eq,
    minus_eq,
    eq_eq,
    bang_eq,
    lt,
    le,
    gt,
    ge,
    plus,
    minus,
    amp,
    pipe,
    caret,
    shl,
    shr,
    and_and,
    eof,
};

const Token = struct {
    kind: TokKind,
    text: []const u8 = "",
    value: u64 = 0,
    line: usize,
};

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,

    fn peekc(self: *Lexer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.line += 1;
                self.pos += 1;
            } else if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn next(self: *Lexer) Error!Token {
        self.skipSpace();
        const line = self.line;
        if (self.pos >= self.src.len) return .{ .kind = .eof, .line = line };
        const c = self.src[self.pos];
        // Two-char operators first.
        const two = if (self.pos + 1 < self.src.len) self.src[self.pos .. self.pos + 2] else "";
        const twos = .{
            .{ "+=", TokKind.plus_eq }, .{ "-=", TokKind.minus_eq },
            .{ "==", TokKind.eq_eq },   .{ "!=", TokKind.bang_eq },
            .{ "<=", TokKind.le },      .{ ">=", TokKind.ge },
            .{ "<<", TokKind.shl },     .{ ">>", TokKind.shr },
            .{ "&&", TokKind.and_and }, .{ "..", TokKind.dotdot },
        };
        inline for (twos) |t| {
            if (std.mem.eql(u8, two, t[0])) {
                self.pos += 2;
                return .{ .kind = t[1], .line = line };
            }
        }
        const ones = .{
            .{ '{', TokKind.lbrace },   .{ '}', TokKind.rbrace },
            .{ '(', TokKind.lparen },   .{ ')', TokKind.rparen },
            .{ '[', TokKind.lbracket }, .{ ']', TokKind.rbracket },
            .{ ',', TokKind.comma },    .{ ':', TokKind.colon },
            .{ '.', TokKind.dot },      .{ '=', TokKind.assign },
            .{ '<', TokKind.lt },     .{ '>', TokKind.gt },
            .{ '+', TokKind.plus },   .{ '-', TokKind.minus },
            .{ '&', TokKind.amp },    .{ '|', TokKind.pipe },
            .{ '^', TokKind.caret },
        };
        inline for (ones) |o| {
            if (c == o[0]) {
                self.pos += 1;
                return .{ .kind = o[1], .line = line };
            }
        }
        if (c == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '"') {
                if (self.src[self.pos] == '\\') self.pos += 1; // escape: skip the next char
                self.pos += 1;
            }
            if (self.pos >= self.src.len) return Error.Syntax;
            const raw = self.src[start..self.pos];
            self.pos += 1; // closing quote
            return .{ .kind = .string, .text = raw, .line = line };
        }
        if (c == '$' or std.ascii.isDigit(c)) {
            const start = self.pos;
            var base: u8 = 10;
            if (c == '$') {
                base = 16;
                self.pos += 1;
            } else if (c == '0' and self.pos + 1 < self.src.len and
                (self.src[self.pos + 1] == 'x' or self.src[self.pos + 1] == 'X'))
            {
                base = 16;
                self.pos += 2;
            }
            var v: u64 = 0;
            var any = false;
            while (self.pos < self.src.len) {
                const d = self.src[self.pos];
                if (d == '_') {
                    self.pos += 1;
                    continue;
                }
                const dv = std.fmt.charToDigit(d, base) catch break;
                v = v *% base +% dv;
                any = true;
                self.pos += 1;
            }
            if (!any) return Error.Syntax;
            return .{ .kind = .int, .value = v, .text = self.src[start..self.pos], .line = line };
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = self.pos;
            while (self.pos < self.src.len and
                (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
                self.pos += 1;
            const text = self.src[start..self.pos];
            if (text.len == 1 and text[0] == '_')
                return .{ .kind = .underscore, .line = line };
            return .{ .kind = .ident, .text = text, .line = line };
        }
        return Error.Syntax;
    }
};

// ── Parser ───────────────────────────────────────────────────────────────

const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    tok: Token,
    diag: ?*Diagnostic,

    fn fail(self: *Parser, comptime msg: []const u8, err: Error) Error {
        if (self.diag) |d| {
            d.line = self.tok.line;
            d.message = msg;
        }
        return err;
    }

    fn advance(self: *Parser) Error!void {
        self.tok = self.lex.next() catch
            return self.fail("unrecognized character", Error.Syntax);
    }

    fn expect(self: *Parser, kind: TokKind, comptime what: []const u8) Error!Token {
        if (self.tok.kind != kind)
            return self.fail("expected " ++ what, Error.Syntax);
        const t = self.tok;
        try self.advance();
        return t;
    }

    fn isKw(self: *Parser, kw: []const u8) bool {
        return self.tok.kind == .ident and std.mem.eql(u8, self.tok.text, kw);
    }

    fn eatKw(self: *Parser, kw: []const u8) Error!bool {
        if (self.isKw(kw)) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn parseProgram(self: *Parser) Error!Program {
        var msgs = std.ArrayList(Message).init(self.arena);
        var actors = std.ArrayList(Actor).init(self.arena);
        var system = std.ArrayList(InstanceDecl).init(self.arena);
        try self.advance();
        while (self.tok.kind != .eof) {
            if (try self.eatKw("message")) {
                try msgs.append(try self.parseMessage());
            } else if (try self.eatKw("actor")) {
                try actors.append(try self.parseActor());
            } else if (try self.eatKw("system")) {
                _ = try self.expect(.lbrace, "{");
                while (self.tok.kind != .rbrace) {
                    try system.append(try self.parseInstance());
                }
                try self.advance(); // }
            } else return self.fail("expected `message`, `actor` or `system`", Error.Syntax);
        }
        return .{
            .messages = try msgs.toOwnedSlice(),
            .actors = try actors.toOwnedSlice(),
            .system = try system.toOwnedSlice(),
        };
    }

    /// `name = Actor(arg, …) [on N]` — args are ints or instance names.
    fn parseInstance(self: *Parser) Error!InstanceDecl {
        const line = self.tok.line;
        const name = try self.expect(.ident, "instance name");
        _ = try self.expect(.assign, "=");
        const actor = try self.expect(.ident, "actor name");
        var replicas: u64 = 1;
        if (self.tok.kind == .lbracket) {
            try self.advance();
            const n = try self.expect(.int, "replica count");
            _ = try self.expect(.rbracket, "]");
            if (n.value == 0) return self.fail("zero replicas", Error.Semantics);
            replicas = n.value;
        }
        _ = try self.expect(.lparen, "(");
        var args = std.ArrayList(InstanceDecl.Arg).init(self.arena);
        while (self.tok.kind != .rparen) {
            switch (self.tok.kind) {
                .int => try args.append(.{ .int = self.tok.value }),
                .ident => {
                    if (std.mem.eql(u8, self.tok.text, "index")) {
                        try args.append(.index);
                    } else {
                        try args.append(.{ .ref = self.tok.text });
                    }
                },
                else => return self.fail("instance args are literals, names or `index`", Error.Syntax),
            }
            try self.advance();
            if (self.tok.kind == .comma) try self.advance();
        }
        try self.advance(); // )
        var core: ?u16 = null;
        if (try self.eatKw("on")) {
            const n = try self.expect(.int, "core number");
            core = @intCast(n.value);
        }
        return .{
            .name = name.text,
            .actor = actor.text,
            .args = try args.toOwnedSlice(),
            .core = core,
            .replicas = replicas,
            .line = line,
        };
    }

    fn parseType(self: *Parser) Error!Type {
        if (self.tok.kind == .lbracket) {
            try self.advance();
            _ = try self.expect(.rbracket, "]");
            const t = try self.expect(.ident, "addr");
            if (!std.mem.eql(u8, t.text, "addr"))
                return self.fail("v1 slices are []addr only", Error.Unsupported);
            return .addr_slice;
        }
        const t = try self.expect(.ident, "a type");
        return Type.named(t.text) orelse
            self.fail("unknown type (v1 speaks u8..u64, addr and []addr)", Error.Unsupported);
    }

    fn parseMessage(self: *Parser) Error!Message {
        const name = try self.expect(.ident, "message name");
        _ = try self.expect(.lbrace, "{");
        var fields = std.ArrayList(Field).init(self.arena);
        while (self.tok.kind != .rbrace) {
            const fname = try self.expect(.ident, "field name");
            const ty = try self.parseType();
            if (ty == .addr_slice)
                return self.fail("a message cannot carry a slice", Error.Semantics);
            try fields.append(.{ .name = fname.text, .ty = ty });
            if (self.tok.kind == .comma) try self.advance();
        }
        try self.advance(); // }
        return .{ .name = name.text, .fields = try fields.toOwnedSlice() };
    }

    fn parseActor(self: *Parser) Error!Actor {
        const name = try self.expect(.ident, "actor name");
        _ = try self.expect(.lparen, "(");
        var params = std.ArrayList(Param).init(self.arena);
        while (self.tok.kind != .rparen) {
            const pname = try self.expect(.ident, "parameter name");
            const ty = try self.parseType();
            try params.append(.{ .name = pname.text, .ty = ty });
            if (self.tok.kind == .comma) try self.advance();
        }
        try self.advance(); // )
        _ = try self.expect(.lbrace, "{");

        var vlist = std.ArrayList(VarDecl).init(self.arena);
        while (self.isKw("var")) {
            try self.advance();
            const vname = try self.expect(.ident, "var name");
            if (self.tok.kind == .lbracket) {
                // `var got [128]u64` — a RAM array; zeroed at load, not
                // at respawn (it lives outside the near page).
                try self.advance();
                const n = try self.expect(.int, "array length");
                _ = try self.expect(.rbracket, "]");
                const t = try self.expect(.ident, "u64");
                if (!std.mem.eql(u8, t.text, "u64"))
                    return self.fail("v1 arrays are u64 only", Error.Unsupported);
                if (n.value == 0 or n.value > 256)
                    return self.fail("array length is 1..256 in v1", Error.Semantics);
                try vlist.append(.{ .name = vname.text, .ty = .u64_, .init = null, .array = @intCast(n.value) });
                continue;
            }
            const ty = try self.parseType();
            if (ty == .addr_slice)
                return self.fail("[]addr is a parameter type", Error.Semantics);
            var init_expr: ?*Expr = null;
            if (self.tok.kind == .assign) {
                try self.advance();
                init_expr = try self.parseExpr();
            }
            try vlist.append(.{ .name = vname.text, .ty = ty, .init = init_expr });
        }

        var body = std.ArrayList(Stmt).init(self.arena);
        while (!self.isKw("serve") and self.tok.kind != .rbrace) {
            try body.append(try self.parseStmt());
        }

        var handlers = std.ArrayList(Handler).init(self.arena);
        if (try self.eatKw("serve")) {
            _ = try self.expect(.lbrace, "{");
            while (self.tok.kind != .rbrace) {
                try handlers.append(try self.parseHandler());
            }
            try self.advance(); // }
        }
        var quiesce = std.ArrayList(Handler).init(self.arena);
        if (try self.eatKw("quiesce")) {
            _ = try self.expect(.lbrace, "{");
            while (self.tok.kind != .rbrace) {
                const h = try self.parseHandler();
                if (h != .case)
                    return self.fail("a quiesce block holds only cases — timers are dead here", Error.Syntax);
                try quiesce.append(h);
            }
            try self.advance(); // }
        }
        _ = try self.expect(.rbrace, "} to close the actor");
        return .{
            .name = name.text,
            .params = try params.toOwnedSlice(),
            .vars = try vlist.toOwnedSlice(),
            .body = try body.toOwnedSlice(),
            .handlers = try handlers.toOwnedSlice(),
            .quiesce = try quiesce.toOwnedSlice(),
        };
    }

    fn parseHandler(self: *Parser) Error!Handler {
        if (try self.eatKw("case")) {
            const line = self.tok.line;
            const msg = try self.expect(.ident, "message name");
            if (std.mem.eql(u8, msg.text, "exit")) {
                // `case exit(w, crash(code) | hung | abandoned):`
                _ = try self.expect(.lparen, "(");
                const bind = try self.expect(.ident, "worker binding");
                _ = try self.expect(.comma, ",");
                const cause_t = try self.expect(.ident, "a cause");
                var cause: ExitCause = undefined;
                var code_bind: ?[]const u8 = null;
                if (std.mem.eql(u8, cause_t.text, "crash")) {
                    cause = .crash;
                    _ = try self.expect(.lparen, "(");
                    code_bind = (try self.expect(.ident, "code binding")).text;
                    _ = try self.expect(.rparen, ")");
                } else if (std.mem.eql(u8, cause_t.text, "hung")) {
                    cause = .hung;
                } else if (std.mem.eql(u8, cause_t.text, "abandoned")) {
                    cause = .abandoned;
                } else return self.fail("cause is crash(code), hung or abandoned", Error.Syntax);
                _ = try self.expect(.rparen, ")");
                _ = try self.expect(.colon, ":");
                return .{ .exit_case = .{
                    .bind = bind.text,
                    .cause = cause,
                    .code_bind = code_bind,
                    .body = try self.parseHandlerBody(),
                    .line = line,
                } };
            }
            _ = try self.expect(.lparen, "(");
            var bind: ?[]const u8 = null;
            if (self.tok.kind == .underscore) {
                try self.advance();
            } else {
                bind = (try self.expect(.ident, "binding or `_`")).text;
            }
            _ = try self.expect(.rparen, ")");
            var where: ?*Expr = null;
            if (try self.eatKw("where")) where = try self.parseExpr();
            _ = try self.expect(.colon, ":");
            return .{ .case = .{
                .msg = msg.text,
                .bind = bind,
                .where = where,
                .body = try self.parseHandlerBody(),
                .line = line,
            } };
        }
        if (try self.eatKw("after")) {
            const n = try self.expect(.int, "cycle count");
            _ = try self.expect(.colon, ":");
            return .{ .after = .{ .n = n.value, .body = try self.parseHandlerBody() } };
        }
        return self.fail("expected `case` or `after`", Error.Syntax);
    }

    fn parseHandlerBody(self: *Parser) Error![]Stmt {
        var body = std.ArrayList(Stmt).init(self.arena);
        while (self.tok.kind != .rbrace and !self.isKw("case") and !self.isKw("after")) {
            try body.append(try self.parseStmt());
        }
        return body.toOwnedSlice();
    }

    fn parseBlock(self: *Parser) Error![]Stmt {
        _ = try self.expect(.lbrace, "{");
        var body = std.ArrayList(Stmt).init(self.arena);
        while (self.tok.kind != .rbrace) {
            try body.append(try self.parseStmt());
        }
        try self.advance(); // }
        return body.toOwnedSlice();
    }

    fn parseStmt(self: *Parser) Error!Stmt {
        const line = self.tok.line;
        if (try self.eatKw("send")) {
            const target = try self.expect(.ident, "target");
            var target_idx: ?*Expr = null;
            if (self.tok.kind == .lbracket) {
                try self.advance();
                target_idx = try self.parseExpr();
                _ = try self.expect(.rbracket, "]");
            }
            _ = try self.expect(.comma, ",");
            if (self.tok.kind == .string) {
                if (target_idx != null)
                    return self.fail("a string send goes to one device", Error.Semantics);
                // decode escapes into the arena
                var text = std.ArrayList(u8).init(self.arena);
                var j: usize = 0;
                const raw = self.tok.text;
                while (j < raw.len) : (j += 1) {
                    if (raw[j] == '\\' and j + 1 < raw.len) {
                        j += 1;
                        try text.append(switch (raw[j]) {
                            'n' => '\n',
                            't' => '\t',
                            else => raw[j],
                        });
                    } else try text.append(raw[j]);
                }
                try self.advance();
                return .{ .send_str = .{
                    .target = target.text,
                    .text = try text.toOwnedSlice(),
                    .line = line,
                } };
            }
            const msg = try self.expect(.ident, "message name");
            _ = try self.expect(.lbrace, "{");
            var args = std.ArrayList(*Expr).init(self.arena);
            while (self.tok.kind != .rbrace) {
                try args.append(try self.parseExpr());
                if (self.tok.kind == .comma) try self.advance();
            }
            try self.advance(); // }
            return .{ .send = .{
                .target = target.text,
                .target_idx = target_idx,
                .msg = msg.text,
                .args = try args.toOwnedSlice(),
                .line = line,
            } };
        }
        if (try self.eatKw("for")) {
            if (self.tok.kind == .lparen) {
                // `for (k, w) in group { … }`
                try self.advance();
                const iname = try self.expect(.ident, "index binding");
                _ = try self.expect(.comma, ",");
                const ename = try self.expect(.ident, "element binding");
                _ = try self.expect(.rparen, ")");
                if (!try self.eatKw("in")) return self.fail("expected `in`", Error.Syntax);
                const gname = try self.expect(.ident, "a []addr parameter");
                return .{ .for_group = .{
                    .idx = iname.text,
                    .elem = ename.text,
                    .group = gname.text,
                    .body = try self.parseBlock(),
                    .line = line,
                } };
            }
            const vname = try self.expect(.ident, "loop variable");
            if (!try self.eatKw("in")) return self.fail("expected `in`", Error.Syntax);
            const from = try self.parseExpr();
            _ = try self.expect(.dotdot, "..");
            const to = try self.parseExpr();
            return .{ .for_range = .{
                .name = vname.text,
                .from = from,
                .to = to,
                .body = try self.parseBlock(),
            } };
        }
        if (try self.eatKw("if")) {
            const cond = try self.parseExpr();
            const then = try self.parseBlock();
            var els: []Stmt = &.{};
            if (try self.eatKw("else")) els = try self.parseBlock();
            return .{ .if_ = .{ .cond = cond, .then = then, .els = els } };
        }
        if (try self.eatKw("halt")) {
            if (try self.eatKw("ok")) return .{ .halt = .{ .ok = true } };
            if (try self.eatKw("err")) return .{ .halt = .{ .ok = false } };
            return self.fail("halt is `halt ok` or `halt err`", Error.Syntax);
        }
        if (try self.eatKw("bounded")) {
            const n = try self.expect(.int, "cycle count");
            return .{ .bounded = .{ .n = n.value, .body = try self.parseBlock() } };
        }
        if (try self.eatKw("spawn")) {
            const actor = try self.expect(.ident, "actor name");
            _ = try self.expect(.lparen, "(");
            var args = std.ArrayList(u64).init(self.arena);
            while (self.tok.kind != .rparen) {
                const v = try self.expect(.int, "a literal arg (v1)");
                try args.append(v.value);
                if (self.tok.kind == .comma) try self.advance();
            }
            try self.advance(); // )
            var restarts: u64 = 0;
            var watchdog: u64 = 0;
            if (try self.eatKw("restarts")) restarts = (try self.expect(.int, "restart budget")).value;
            if (try self.eatKw("watchdog")) watchdog = (try self.expect(.int, "watchdog budget")).value;
            return .{ .spawn = .{
                .actor = actor.text,
                .args = try args.toOwnedSlice(),
                .restarts = restarts,
                .watchdog = watchdog,
                .line = line,
            } };
        }
        if (try self.eatKw("quiesce")) return .quiesce;
        inline for (.{ "chain", "let", "region", "grant", "log" }) |kw| {
            if (self.isKw(kw))
                return self.fail("`" ++ kw ++ "` is not in v1 yet", Error.Unsupported);
        }
        // assignment: ident[idx]? (=|+=|-=) expr
        const name = try self.expect(.ident, "a statement");
        var idx: ?*Expr = null;
        if (self.tok.kind == .lbracket) {
            try self.advance();
            idx = try self.parseExpr();
            _ = try self.expect(.rbracket, "]");
        }
        const op: AssignOp = switch (self.tok.kind) {
            .assign => .set,
            .plus_eq => .add,
            .minus_eq => .sub,
            else => return self.fail("expected `=`, `+=` or `-=`", Error.Syntax),
        };
        try self.advance();
        return .{ .assign = .{ .name = name.text, .idx = idx, .op = op, .expr = try self.parseExpr() } };
    }

    fn mkExpr(self: *Parser, e: Expr) Error!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    // precedence: && < comparisons < | ^ < & < << >> < + -
    fn parseExpr(self: *Parser) Error!*Expr {
        var l = try self.parseCmp();
        while (self.tok.kind == .and_and) {
            try self.advance();
            const r = try self.parseCmp();
            l = try self.mkExpr(.{ .bin = .{ .op = .land, .l = l, .r = r } });
        }
        return l;
    }

    fn parseCmp(self: *Parser) Error!*Expr {
        const l = try self.parseOr();
        const op: BinOp = switch (self.tok.kind) {
            .eq_eq => .eq,
            .bang_eq => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => return l,
        };
        try self.advance();
        const r = try self.parseOr();
        return self.mkExpr(.{ .bin = .{ .op = op, .l = l, .r = r } });
    }

    fn parseOr(self: *Parser) Error!*Expr {
        var l = try self.parseAnd();
        while (self.tok.kind == .pipe or self.tok.kind == .caret) {
            const op: BinOp = if (self.tok.kind == .pipe) .bor else .bxor;
            try self.advance();
            l = try self.mkExpr(.{ .bin = .{ .op = op, .l = l, .r = try self.parseAnd() } });
        }
        return l;
    }

    fn parseAnd(self: *Parser) Error!*Expr {
        var l = try self.parseShift();
        while (self.tok.kind == .amp) {
            try self.advance();
            l = try self.mkExpr(.{ .bin = .{ .op = .band, .l = l, .r = try self.parseShift() } });
        }
        return l;
    }

    fn parseShift(self: *Parser) Error!*Expr {
        var l = try self.parseAdd();
        while (self.tok.kind == .shl or self.tok.kind == .shr) {
            const op: BinOp = if (self.tok.kind == .shl) .shl else .shr;
            try self.advance();
            l = try self.mkExpr(.{ .bin = .{ .op = op, .l = l, .r = try self.parseAdd() } });
        }
        return l;
    }

    fn parseAdd(self: *Parser) Error!*Expr {
        var l = try self.parsePrimary();
        while (self.tok.kind == .plus or self.tok.kind == .minus) {
            const op: BinOp = if (self.tok.kind == .plus) .add else .sub;
            try self.advance();
            l = try self.mkExpr(.{ .bin = .{ .op = op, .l = l, .r = try self.parsePrimary() } });
        }
        return l;
    }

    fn parsePrimary(self: *Parser) Error!*Expr {
        switch (self.tok.kind) {
            .int => {
                const v = self.tok.value;
                try self.advance();
                return self.mkExpr(.{ .int = v });
            },
            .lparen => {
                try self.advance();
                const e = try self.parseExpr();
                _ = try self.expect(.rparen, ")");
                return e;
            },
            .ident => {
                const name = self.tok.text;
                try self.advance();
                if (self.tok.kind == .dot) {
                    try self.advance();
                    const f = try self.expect(.ident, "field name");
                    return self.mkExpr(.{ .field = .{ .base = name, .name = f.text } });
                }
                if (self.tok.kind == .lbracket) {
                    try self.advance();
                    const idx = try self.parseExpr();
                    _ = try self.expect(.rbracket, "]");
                    return self.mkExpr(.{ .index = .{ .base = name, .idx = idx } });
                }
                return self.mkExpr(.{ .ident = name });
            },
            else => return self.fail("expected an expression", Error.Syntax),
        }
    }
};

// ── Codegen ──────────────────────────────────────────────────────────────

const Gen = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8),
    prog: *const Program,
    actor: *const Actor,
    layout: Layout,
    diag: ?*Diagnostic,

    labels: usize = 0,
    serve_label: usize = 0,
    quiesce_label: usize = 0,
    has_quiesce: bool = false,
    /// Current case binding: name → the landing pointer internal.
    bind: ?[]const u8 = null,
    bind_msg: ?*const Message = null,
    /// Current exit-case bindings: worker (fields id/life) and fault code.
    exit_bind: ?[]const u8 = null,
    exit_code_bind: ?[]const u8 = null,
    in_handler: bool = false,
    uses_timer: bool = false,
    timer_period: u64 = 0,
    spawn_count: u16 = 0,
    spawn_seen: u16 = 0,

    /// String literals staged after the code, one label each.
    strings: std.ArrayList(struct { label: usize, text: []const u8 }),

    // Near-page slot offsets, assigned in layout().
    slots: std.StringHashMap(u16),
    off_w0: u16 = 0,
    off_ptr: u16 = 0,
    off_t: u16 = 0,
    off_acc: u16 = 0,
    off_fp: u16 = 0,
    off_ectx: u16 = 0,
    off_elife: u16 = 0,
    off_ecode: u16 = 0,
    off_tarmed: u16 = 0,
    off_elem: u16 = 0,
    /// First free near slot after the fixed layout — loop variables and
    /// bindings are handed out from here.
    next_slot: u16 = 0,
    /// RAM arrays: name → near slot holding the base pointer. Group
    /// params and array vars both land here.
    arrays: std.StringHashMap(struct { ptr_slot: u16, area: u64, len: u16 }),
    /// Spawn records live after the internals: 48 bytes each —
    /// {ctx, entry, sp, arg} (the SPWN block, loader-staged), +32 the
    /// child's timer-SQE address (for disarm-on-death), +40 the restart
    /// budget (init-staged from the `restarts` literal).
    spawn_base: u16 = 0,

    fn fail(self: *Gen, line: usize, comptime msg: []const u8, err: Error) Error {
        if (self.diag) |d| {
            d.line = line;
            d.message = msg;
        }
        return err;
    }

    fn w(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        self.out.writer().print(fmt ++ "\n", args) catch return Error.OutOfMemory;
    }

    fn label(self: *Gen) usize {
        self.labels += 1;
        return self.labels;
    }

    fn message(self: *Gen, name: []const u8) ?*const Message {
        for (self.prog.messages) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    /// Emit an immediate operand: `#n` when it survives imm8 sign-extension
    /// intact, `##$X` otherwise.
    fn imm(self: *Gen, v: u64) Error![]const u8 {
        if (v <= 127) {
            return std.fmt.allocPrint(self.arena, "#{d}", .{v}) catch return Error.OutOfMemory;
        }
        return std.fmt.allocPrint(self.arena, "##${X}", .{v}) catch return Error.OutOfMemory;
    }

    fn layoutSlots(self: *Gen) Error!void {
        var off: u16 = abi.param_base;
        var area: u64 = 0;
        for (self.actor.params) |p| {
            // A slice param's near slot holds the COUNT; its windows go
            // to the RAM array area, base pointer staged below.
            try self.slots.put(p.name, off);
            off += 8;
        }
        for (self.actor.vars) |v| {
            if (v.array > 0) continue; // RAM arrays get pointers, not slots
            try self.slots.put(v.name, off);
            off += 8;
        }
        self.off_w0 = off;
        self.off_ptr = off + 8;
        self.off_t = off + 16;
        self.off_acc = off + 24;
        self.off_fp = off + 32;
        self.off_ectx = off + 40;
        self.off_elife = off + 48;
        self.off_ecode = off + 56;
        self.off_tarmed = off + 64;
        self.off_elem = off + 72;
        self.spawn_base = off + 80;
        for (self.actor.handlers) |h| {
            if (h == .after) {
                self.uses_timer = true;
                self.timer_period = h.after.n;
            }
        }
        for (self.actor.body) |s| {
            if (s == .spawn) self.spawn_count += 1;
        }
        // Arrays after the spawn records: a near slot for each base
        // pointer; the elements in the block's RAM array area.
        var aoff: u16 = self.spawn_base + self.spawn_count * 48;
        for (self.actor.params) |p| {
            if (p.ty != .addr_slice) continue;
            try self.arrays.put(p.name, .{ .ptr_slot = aoff, .area = area, .len = abi.group_cap });
            aoff += 8;
            area += @as(u64, abi.group_cap) * 8;
        }
        for (self.actor.vars) |v| {
            if (v.array == 0) continue;
            try self.arrays.put(v.name, .{ .ptr_slot = aoff, .area = area, .len = v.array });
            aoff += 8;
            area += @as(u64, v.array) * 8;
        }
        self.next_slot = aoff;
        if (abi.array_off + area > abi.block_size - abi.data_off - 0x400)
            return self.fail(0, "arrays overflow the instance block", Error.Semantics);
        self.has_quiesce = self.actor.quiesce.len > 0 or anyQuiesce(self.actor.body) or blk: {
            for (self.actor.handlers) |h| {
                const body = switch (h) {
                    .case => |c| c.body,
                    .after => |a| a.body,
                    .exit_case => |e| e.body,
                };
                if (anyQuiesce(body)) break :blk true;
            }
            break :blk false;
        };
    }

    fn anyQuiesce(list: []const Stmt) bool {
        for (list) |s| {
            switch (s) {
                .quiesce => return true,
                .if_ => |i| if (anyQuiesce(i.then) or anyQuiesce(i.els)) return true,
                .bounded => |b| if (anyQuiesce(b.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn spawnRec(self: *Gen, k: u16) u16 {
        return self.spawn_base + k * 48;
    }

    /// Loop variables and bindings get near slots on demand; the same
    /// name reuses its slot (a shadowed loop variable is the same cell).
    fn getOrAddSlot(self: *Gen, name: []const u8) Error!u16 {
        if (self.slots.get(name)) |s| return s;
        const s = self.next_slot;
        if (@as(u32, s) + 8 > isa.mactab_base)
            return self.fail(0, "near page exhausted", Error.Semantics);
        try self.slots.put(name, s);
        self.next_slot += 8;
        return s;
    }

    // ── Expressions: result in A ─────────────────────────────────────────

    fn evalInto(self: *Gen, e: *const Expr) Error!void {
        switch (e.*) {
            .int => |v| {
                if (v <= 127) {
                    try self.w("        LDA #{d}", .{v});
                } else {
                    try self.w("        LDA ##${X}", .{v});
                }
            },
            .ident => |name| {
                if (self.exit_code_bind != null and std.mem.eql(u8, self.exit_code_bind.?, name)) {
                    try self.w("        LDA ${X}", .{self.off_ecode});
                    return;
                }
                const slot = self.slots.get(name) orelse {
                    if (self.bind != null and std.mem.eql(u8, self.bind.?, name))
                        return self.fail(0, "a message binding needs a field access", Error.Semantics);
                    return self.fail(0, "unknown name", Error.Semantics);
                };
                try self.w("        LDA ${X}", .{slot});
            },
            .index => |ix| {
                const arr = self.arrays.get(ix.base) orelse
                    return self.fail(0, "not an array or group", Error.Semantics);
                try self.evalInto(ix.idx);
                try self.w("        ASL #3", .{});
                try self.w("        TAY", .{});
                try self.w("        LDA (${X}),Y", .{arr.ptr_slot});
            },
            .field => |f| {
                if (self.exit_bind != null and std.mem.eql(u8, self.exit_bind.?, f.base)) {
                    // w.id = the dead worker's context id; w.life = the
                    // incarnation that died (both from the exit cookie).
                    if (std.mem.eql(u8, f.name, "id")) {
                        try self.w("        LDA ${X}", .{self.off_ectx});
                    } else if (std.mem.eql(u8, f.name, "life")) {
                        try self.w("        LDA ${X}", .{self.off_elife});
                    } else return self.fail(0, "a worker binding has .id and .life", Error.Semantics);
                    return;
                }
                const bind = self.bind orelse
                    return self.fail(0, "field access outside a case", Error.Semantics);
                if (!std.mem.eql(u8, bind, f.base))
                    return self.fail(0, "field base is not the case binding", Error.Semantics);
                const msg = self.bind_msg.?;
                const fld = for (msg.fields) |*fl| {
                    if (std.mem.eql(u8, fl.name, f.name)) break fl;
                } else return self.fail(0, "no such field in the message", Error.Semantics);
                const word: u16 = fld.offset / 8;
                const bit: u16 = (fld.offset % 8) * 8;
                if (word == 0) {
                    try self.w("        LDA (${X})", .{self.off_ptr});
                } else {
                    try self.w("        LDA ${X}", .{self.off_ptr});
                    try self.w("        CLC", .{});
                    try self.w("        ADC #{d}", .{word * 8});
                    try self.w("        STA ${X}", .{self.off_fp});
                    try self.w("        LDA (${X})", .{self.off_fp});
                }
                if (bit != 0) try self.w("        LSR #{d}", .{bit});
                if (fld.ty.size() < 8) {
                    const mask: u64 = (@as(u64, 1) << @intCast(fld.ty.size() * 8)) - 1;
                    try self.w("        AND ##${X}", .{mask});
                }
            },
            .bin => |b| {
                switch (b.op) {
                    .eq, .ne, .lt, .le, .gt, .ge, .land => return self.fail(
                        0,
                        "comparisons live in `if`/`where`, not in values (v1)",
                        Error.Unsupported,
                    ),
                    .shl, .shr => {
                        // Counted shifts want a constant count.
                        if (b.r.* != .int)
                            return self.fail(0, "shift count must be a literal (v1)", Error.Unsupported);
                        try self.evalInto(b.l);
                        const mn: []const u8 = if (b.op == .shl) "ASL" else "LSR";
                        try self.w("        {s} #{d}", .{ mn, b.r.int });
                    },
                    .add, .sub, .band, .bor, .bxor => {
                        try self.evalInto(b.l);
                        try self.w("        PHA", .{});
                        try self.evalInto(b.r);
                        try self.w("        STA ${X}", .{self.off_t});
                        try self.w("        PLA", .{});
                        switch (b.op) {
                            .add => {
                                try self.w("        CLC", .{});
                                try self.w("        ADC ${X}", .{self.off_t});
                            },
                            .sub => {
                                try self.w("        SEC", .{});
                                try self.w("        SBC ${X}", .{self.off_t});
                            },
                            .band => try self.w("        AND ${X}", .{self.off_t}),
                            .bor => try self.w("        ORA ${X}", .{self.off_t}),
                            .bxor => try self.w("        EOR ${X}", .{self.off_t}),
                            else => unreachable,
                        }
                    },
                }
            },
        }
    }

    /// Emit a branch to `target` when `cond` is FALSE. Conditions are
    /// comparisons or && chains of them (v1).
    fn branchIfFalse(self: *Gen, cond: *const Expr, target: usize) Error!void {
        if (cond.* != .bin)
            return self.fail(0, "a condition must compare something (v1)", Error.Unsupported);
        const b = cond.bin;
        switch (b.op) {
            .land => {
                try self.branchIfFalse(b.l, target);
                try self.branchIfFalse(b.r, target);
                return;
            },
            .eq, .ne, .lt, .le, .gt, .ge => {},
            else => return self.fail(0, "a condition must compare something (v1)", Error.Unsupported),
        }
        // A = left, M = right; CMP sets flags from A − M (unsigned).
        try self.evalInto(b.l);
        try self.w("        PHA", .{});
        try self.evalInto(b.r);
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        PLA", .{});
        try self.w("        CMP ${X}", .{self.off_t});
        switch (b.op) {
            .eq => try self.w("        BNE L{d}", .{target}),
            .ne => try self.w("        BEQ L{d}", .{target}),
            .lt => try self.w("        BCS L{d}", .{target}), // C = A >= M
            .ge => try self.w("        BCC L{d}", .{target}),
            .gt => {
                try self.w("        BCC L{d}", .{target});
                try self.w("        BEQ L{d}", .{target});
            },
            .le => {
                const ok = self.label();
                try self.w("        BEQ L{d}", .{ok});
                try self.w("        BCS L{d}", .{target});
                try self.w("L{d}:", .{ok});
            },
            else => unreachable,
        }
    }

    // ── Statements ───────────────────────────────────────────────────────

    fn stmts(self: *Gen, list: []const Stmt) Error!void {
        for (list) |*s| try self.stmt(s);
    }

    fn stmt(self: *Gen, s: *const Stmt) Error!void {
        switch (s.*) {
            .assign => |a| {
                if (a.idx) |ix| {
                    // arr[e] = v — evaluate v first (it may clobber Y).
                    const arr = self.arrays.get(a.name) orelse
                        return self.fail(0, "not an array", Error.Semantics);
                    if (a.op != .set)
                        return self.fail(0, "v1 array assignment is `=` only", Error.Unsupported);
                    try self.evalInto(a.expr);
                    try self.w("        PHA", .{});
                    try self.evalInto(ix);
                    try self.w("        ASL #3", .{});
                    try self.w("        TAY", .{});
                    try self.w("        PLA", .{});
                    try self.w("        STA (${X}),Y", .{arr.ptr_slot});
                    return;
                }
                const slot = self.slots.get(a.name) orelse
                    return self.fail(0, "unknown variable", Error.Semantics);
                switch (a.op) {
                    .set => {
                        try self.evalInto(a.expr);
                        try self.w("        STA ${X}", .{slot});
                    },
                    .add, .sub => {
                        try self.evalInto(a.expr);
                        try self.w("        STA ${X}", .{self.off_t});
                        try self.w("        LDA ${X}", .{slot});
                        if (a.op == .add) {
                            try self.w("        CLC", .{});
                            try self.w("        ADC ${X}", .{self.off_t});
                        } else {
                            try self.w("        SEC", .{});
                            try self.w("        SBC ${X}", .{self.off_t});
                        }
                        try self.w("        STA ${X}", .{slot});
                    },
                }
            },
            .send => |sd| try self.send(sd),
            .send_str => |ss| {
                const tslot = self.slots.get(ss.target) orelse
                    return self.fail(ss.line, "unknown send target", Error.Semantics);
                const lbl = self.label();
                try self.strings.append(.{ .label = lbl, .text = ss.text });
                try self.w("        LDA #1              ; SQE: op = send", .{});
                try self.w("        STA !${X}", .{self.layout.sqBase()});
                try self.w("        LDA ${X}", .{tslot});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 8});
                try self.w("        LDA ##L{d}", .{lbl});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 16});
                try self.w("        LDA ##${X}", .{@as(u64, 1) << 32 | ss.text.len});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 24});
                try self.w("        SEND 0", .{});
            },
            .if_ => |i| {
                const l_else = self.label();
                try self.branchIfFalse(i.cond, l_else);
                try self.stmts(i.then);
                if (i.els.len == 0) {
                    try self.w("L{d}:", .{l_else});
                } else {
                    const l_end = self.label();
                    try self.w("        BRA L{d}", .{l_end});
                    try self.w("L{d}:", .{l_else});
                    try self.stmts(i.els);
                    try self.w("L{d}:", .{l_end});
                }
            },
            .halt => |h| {
                // `halt ok` is a clean shutdown and cleans up its timer.
                // `halt err` is a crash, and crashes never clean up —
                // that is precisely what supervisors are for: the exit
                // runtime disarms a dead child's timer when (and only
                // when) it will stay dead.
                if (h.ok and self.uses_timer) {
                    try self.w("        LDA #2              ; disarm the timer", .{});
                    try self.w("        STA !${X}", .{self.layout.timerBase()});
                }
                try self.w("        {s}", .{if (h.ok) "HLT" else "BRK"});
            },
            .bounded => |b| {
                try self.w("        WDEX ##{d}", .{b.n});
                try self.stmts(b.body);
            },
            .for_range => |f| {
                const kslot = try self.getOrAddSlot(f.name);
                const l_top = self.label();
                const l_end = self.label();
                try self.evalInto(f.from);
                try self.w("        STA ${X}", .{kslot});
                try self.w("L{d}:", .{l_top});
                try self.evalInto(f.to);
                try self.w("        STA ${X}", .{self.off_t});
                try self.w("        LDA ${X}", .{kslot});
                try self.w("        CMP ${X}", .{self.off_t});
                try self.w("        BCS L{d}", .{l_end});
                try self.stmts(f.body);
                try self.w("        INC ${X}", .{kslot});
                try self.w("        BRA L{d}", .{l_top});
                try self.w("L{d}:", .{l_end});
            },
            .for_group => |f| {
                // for (k, w) in ws — count from the param slot, elements
                // fetched through the group's base pointer each lap.
                const arr = self.arrays.get(f.group) orelse
                    return self.fail(f.line, "not a []addr parameter", Error.Semantics);
                const count_slot = self.slots.get(f.group) orelse
                    return self.fail(f.line, "unknown group", Error.Semantics);
                const kslot = try self.getOrAddSlot(f.idx);
                const eslot = try self.getOrAddSlot(f.elem);
                const l_top = self.label();
                const l_end = self.label();
                try self.w("        LDA #0", .{});
                try self.w("        STA ${X}", .{kslot});
                try self.w("L{d}:   LDA ${X}", .{ l_top, kslot });
                try self.w("        CMP ${X}", .{count_slot});
                try self.w("        BCS L{d}", .{l_end});
                try self.w("        ASL #3", .{});
                try self.w("        TAY", .{});
                try self.w("        LDA (${X}),Y", .{arr.ptr_slot});
                try self.w("        STA ${X}", .{eslot});
                try self.stmts(f.body);
                try self.w("        INC ${X}", .{kslot});
                try self.w("        BRA L{d}", .{l_top});
                try self.w("L{d}:", .{l_end});
            },
            .quiesce => {
                // Termination is a phase: kill the clock, cross into the
                // lame-duck case set, never come back.
                if (self.uses_timer) {
                    try self.w("        LDA #2              ; quiesce: the timer dies here", .{});
                    try self.w("        STA !${X}", .{self.layout.timerBase()});
                }
                try self.w("        BRA L{d}", .{self.quiesce_label});
            },
            .spawn => |sp| {
                if (self.in_handler)
                    return self.fail(sp.line, "v1: spawn lives in the actor body, before serve", Error.Unsupported);
                const rec = self.spawnRec(self.spawn_seen);
                self.spawn_seen += 1;
                try self.w("; spawn {s} restarts {d} watchdog {d}", .{ sp.actor, sp.restarts, sp.watchdog });
                try self.w("        LDA {s}", .{try self.imm(sp.restarts)});
                try self.w("        STA ${X}", .{rec + 40});
                try self.w("        SPWN ${X}", .{rec});
            },
        }
    }

    /// `send target, Msg{args}` — build the wire image and ship it. ≤ 8
    /// bytes rides TXR through the target's near-page slot; larger stages
    /// at msg_staging and rides SEND 0. Fire and forget either way: the
    /// serve loop consumes the transport ack invisibly.
    fn send(self: *Gen, sd: anytype) Error!void {
        const msg = self.message(sd.msg) orelse
            return self.fail(sd.line, "unknown message", Error.Semantics);
        if (sd.args.len != msg.fields.len)
            return self.fail(sd.line, "wrong number of message fields", Error.Semantics);
        const tslot: u16 = if (sd.target_idx) |ix| blk: {
            // send group[e], … — fetch the element window first; the
            // message build below never touches Y or the elem slot.
            const arr = self.arrays.get(sd.target) orelse
                return self.fail(sd.line, "not a []addr parameter", Error.Semantics);
            try self.evalInto(ix);
            try self.w("        ASL #3", .{});
            try self.w("        TAY", .{});
            try self.w("        LDA (${X}),Y", .{arr.ptr_slot});
            try self.w("        STA ${X}", .{self.off_elem});
            break :blk self.off_elem;
        } else self.slots.get(sd.target) orelse
            return self.fail(sd.line, "unknown send target", Error.Semantics);

        if (msg.wire_size <= 8) {
            // TXR path: compose tag | fields into A.
            try self.w("        LDA {s}", .{try self.imm(msg.tag)});
            try self.w("        STA ${X}", .{self.off_acc});
            for (msg.fields, sd.args) |*f, arg| {
                try self.evalInto(arg);
                if (f.ty.size() < 8) {
                    const mask: u64 = (@as(u64, 1) << @intCast(f.ty.size() * 8)) - 1;
                    try self.w("        AND ##${X}", .{mask});
                }
                if (f.offset != 0) try self.w("        ASL #{d}", .{f.offset * 8});
                try self.w("        ORA ${X}", .{self.off_acc});
                try self.w("        STA ${X}", .{self.off_acc});
            }
            try self.w("        LDA ${X}", .{self.off_acc});
            try self.w("        TXR (${X})", .{tslot});
            return;
        }
        // SEND path: stage the image word by word, then one SQE.
        var word: u16 = 0;
        while (word * 8 < msg.wire_size) : (word += 1) {
            var first = true;
            for (msg.fields, sd.args) |*f, arg| {
                if (f.offset / 8 != word) continue;
                try self.evalInto(arg);
                if (f.ty.size() < 8) {
                    const mask: u64 = (@as(u64, 1) << @intCast(f.ty.size() * 8)) - 1;
                    try self.w("        AND ##${X}", .{mask});
                }
                const bit = (f.offset % 8) * 8;
                if (bit != 0) try self.w("        ASL #{d}", .{bit});
                if (word == 0 or !first) {
                    if (first) {
                        // word 0 starts from the tag
                        try self.w("        ORA {s}", .{try self.imm(msg.tag)});
                    } else {
                        try self.w("        ORA ${X}", .{self.off_acc});
                    }
                }
                try self.w("        STA ${X}", .{self.off_acc});
                first = false;
            }
            if (first) {
                // no fields in this word: tag alone (word 0) or zero
                try self.w("        LDA {s}", .{if (word == 0) try self.imm(msg.tag) else "#0"});
                try self.w("        STA ${X}", .{self.off_acc});
            }
            try self.w("        LDA ${X}", .{self.off_acc});
            try self.w("        STA !${X}", .{self.layout.staging() + word * 8});
        }
        try self.w("        LDA #1              ; SQE: op = send", .{});
        try self.w("        STA !${X}", .{self.layout.sqBase()});
        try self.w("        LDA ${X}", .{tslot});
        try self.w("        STA !${X}", .{self.layout.sqBase() + 8});
        try self.w("        LDA ##${X}", .{self.layout.staging()});
        try self.w("        STA !${X}", .{self.layout.sqBase() + 16});
        try self.w("        LDA ##${X}", .{@as(u64, 1) << 32 | msg.wire_size});
        try self.w("        STA !${X}", .{self.layout.sqBase() + 24});
        try self.w("        SEND 0", .{});
    }

    // ── The actor: prologue, body, serve loop ────────────────────────────

    /// Emit a store of `v` to near offset `off` (via A).
    fn store(self: *Gen, v: u64, off: u64) Error!void {
        try self.w("        LDA {s}", .{try self.imm(v)});
        try self.w("        STA ${X}", .{off});
    }

    fn emit(self: *Gen) Error!void {
        try self.layoutSlots();
        try self.w("; joe v1 — actor {s} (compiled; do not edit)", .{self.actor.name});
        try self.w("        .org ${X}", .{self.layout.origin});

        // Ring descriptors, self-staged — head = tail = 0 every life, so
        // init is idempotent and a respawned incarnation starts clean.
        // Word layout is ring.Desc.pack's.
        try self.w("; ring descriptors (self-staged: init must survive respawn)", .{});
        const w1 = struct {
            fn of(cap_log2: u64, entry: u64, flags: u64) u64 {
                return cap_log2 | (entry << 8) |
                    (@as(u64, ring.slot_cq) << 48) | (flags << 56);
            }
        }.of;
        const descs = [4]struct { slot: u16, base: u64, cfg: u64, token: u64 }{
            .{ .slot = ring.slot_sq, .base = self.layout.sqBase(), .cfg = w1(0, ring.sq_entry_size, 0), .token = 0 },
            .{ .slot = ring.slot_cq, .base = self.layout.cqBase(), .cfg = w1(4, ring.cq_entry_size, 0), .token = 0 },
            .{ .slot = ring.slot_rx, .base = self.layout.rxBase(), .cfg = w1(1, ring.rx_entry_size, ring.desc_flag_auto_repost), .token = abi.token },
            .{ .slot = abi.timer_desc, .base = self.layout.timerBase(), .cfg = w1(0, ring.sq_entry_size, 0), .token = 0 },
        };
        for (descs) |d| {
            const off = @as(u64, d.slot) * ring.desc_size;
            try self.store(d.base, off);
            try self.store(d.cfg, off + 8);
            try self.store(0, off + 16); // head = tail = 0
            try self.store(d.token, off + 24);
        }

        if (self.arrays.count() > 0) {
            try self.w("; array base pointers (elements live in the block's RAM)", .{});
            var ait = self.arrays.iterator();
            while (ait.next()) |e| {
                try self.store(
                    self.layout.data + abi.array_off + e.value_ptr.area,
                    e.value_ptr.ptr_slot,
                );
            }
        }

        // RX ring: two landing buffers, cookie = buffer address.
        try self.w("; landing buffers (cap-2 AUTO_REPOST ring)", .{});
        const lands = [2]struct { buf: u64, off: u64 }{
            .{ .buf = self.layout.land0(), .off = 0 },
            .{ .buf = self.layout.land1(), .off = 32 },
        };
        for (lands) |lb| {
            try self.w("        LDA ##${X}", .{lb.buf});
            try self.w("        STA !${X}", .{self.layout.rxBase() + lb.off});
            try self.w("        STA !${X}", .{self.layout.rxBase() + lb.off + 24});
            try self.w("        LDA #{d}", .{abi.land_cap});
            try self.w("        STA !${X}", .{self.layout.rxBase() + lb.off + 8});
            try self.w("        LDA #0", .{});
            try self.w("        STA !${X}", .{self.layout.rxBase() + lb.off + 16});
        }
        try self.w("        RECV 2", .{});
        try self.w("        RECV 2", .{});

        if (self.uses_timer) {
            // The chain is address-based, not incarnation-based: it keeps
            // ticking across a supervised respawn. The armed flag lives in
            // the near page (which survives SPWN), so only the first life
            // lights the fire — re-arming under a live chain would double
            // the tick rate every death.
            const l_armed = self.label();
            try self.w("; the after-timer: AUTO_REARM TXR into the black hole (spec §6.3)", .{});
            try self.w("        LDA ${X}", .{self.off_tarmed});
            try self.w("        BNE L{d}", .{l_armed});
            try self.w("        LDA #1", .{});
            try self.w("        STA ${X}", .{self.off_tarmed});
            try self.w("        LDA ##$202", .{});
            try self.w("        STA !${X}", .{self.layout.timerBase()});
            try self.w("        LDA ##${X}", .{self.layout.timerWindow()});
            try self.w("        STA !${X}", .{self.layout.timerBase() + 8});
            try self.w("        LDA #0", .{});
            try self.w("        STA !${X}", .{self.layout.timerBase() + 16});
            try self.w("        LDA ##${X}", .{abi.timer_cookie << 32});
            try self.w("        STA !${X}", .{self.layout.timerBase() + 24});
            try self.w("        SEND {d}", .{abi.timer_desc});
            try self.w("L{d}:", .{l_armed});
        }

        // var initializers
        for (self.actor.vars) |v| {
            if (v.init) |e| {
                try self.evalInto(e);
                try self.w("        STA ${X}", .{self.slots.get(v.name).?});
            }
        }

        // opening statements
        try self.stmts(self.actor.body);

        if (self.actor.handlers.len == 0) {
            try self.w("        HLT", .{});
            try self.emitStrings();
            return;
        }

        // ── serve ──
        self.serve_label = self.label();
        self.quiesce_label = self.label();
        const l_dispatch = self.label();
        const l_exit = self.label();
        try self.w("; serve: LSTN, pop, dispatch — acks are consumed, never seen", .{});
        try self.w("L{d}:   LSTN 1", .{self.serve_label});
        try self.w("        CQPOP 1", .{});
        try self.w("        BEQ L{d}", .{self.serve_label});
        try self.w("        STA ${X}", .{self.off_w0});
        try self.w("        STX ${X}", .{self.off_ptr});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.deliver)});
        try self.w("        BEQ L{d}", .{l_dispatch});
        if (self.spawn_count > 0) {
            try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.exit)});
            try self.w("        BEQ L{d}", .{l_exit});
        }
        if (self.uses_timer) {
            // tag 1 (txr) + cookie $77 = the timer; everything else is ack noise
            try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.txr)});
            try self.w("        BNE L{d}", .{self.serve_label});
            try self.w("        LDA ${X}", .{self.off_ptr});
            try self.w("        AND ##$FFFFFFFF", .{});
            try self.w("        CMP #{d}", .{abi.timer_cookie});
            try self.w("        BNE L{d}", .{self.serve_label});
            self.in_handler = true;
            for (self.actor.handlers) |*h| {
                if (h.* == .after) {
                    try self.stmts(h.after.body);
                    break;
                }
            }
            self.in_handler = false;
            try self.w("        BRA L{d}", .{self.serve_label});
        } else {
            try self.w("        BRA L{d}", .{self.serve_label});
        }

        // deliveries: clean status, then first-match tag + guard chain
        try self.w("L{d}:   LDA ${X}", .{ l_dispatch, self.off_w0 });
        try self.w("        LSR #8", .{});
        try self.w("        AND #$FF", .{});
        try self.w("        BNE L{d}", .{self.serve_label});
        for (self.actor.handlers) |*h| {
            if (h.* != .case) continue;
            const c = h.case;
            const msg = self.message(c.msg) orelse
                return self.fail(c.line, "unknown message in case", Error.Semantics);
            const l_next = self.label();
            try self.w("; case {s}({s})", .{ c.msg, c.bind orelse "_" });
            try self.w("        LDA (${X})", .{self.off_ptr});
            try self.w("        AND ##$FFFF", .{});
            try self.w("        CMP {s}", .{try self.imm(msg.tag)});
            try self.w("        BNE L{d}", .{l_next});
            self.bind = c.bind;
            self.bind_msg = msg;
            if (c.where) |g| try self.branchIfFalse(g, l_next);
            self.in_handler = true;
            try self.stmts(c.body);
            self.in_handler = false;
            self.bind = null;
            self.bind_msg = null;
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_next});
        }
        try self.w("        BRA L{d}", .{self.serve_label});

        if (self.spawn_count > 0) try self.emitExitRuntime(l_exit);
        if (self.has_quiesce) try self.emitQuiesce();
        try self.emitStrings();
    }

    fn emitStrings(self: *Gen) Error!void {
        if (self.strings.items.len == 0) return;
        try self.w("; string literals", .{});
        for (self.strings.items) |s| {
            try self.w("L{d}:", .{s.label});
            var idx: usize = 0;
            while (idx < s.text.len) {
                const chunk = @min(16, s.text.len - idx);
                self.out.writer().writeAll("        .byte ") catch return Error.OutOfMemory;
                for (s.text[idx .. idx + chunk], 0..) |b, bi| {
                    if (bi > 0) self.out.writer().writeAll(",") catch return Error.OutOfMemory;
                    self.out.writer().print("{d}", .{b}) catch return Error.OutOfMemory;
                }
                self.out.writer().writeAll("\n") catch return Error.OutOfMemory;
                idx += chunk;
            }
        }
    }

    /// The lame-duck loop (sketch §2.3): a restricted case set, no
    /// timers, everything else consumed in silence. Stragglers converge;
    /// the machine goes quiet instead of staying awake.
    fn emitQuiesce(self: *Gen) Error!void {
        const lq = self.quiesce_label;
        const l_dispatch = self.label();
        // Case-body BRAs loop back to the quiesce serve, not the live one.
        const saved = self.serve_label;
        self.serve_label = lq;
        defer self.serve_label = saved;
        try self.w("; quiesce: the lame-duck serve", .{});
        try self.w("L{d}:   LSTN 1", .{lq});
        try self.w("        CQPOP 1", .{});
        try self.w("        BEQ L{d}", .{lq});
        try self.w("        STA ${X}", .{self.off_w0});
        try self.w("        STX ${X}", .{self.off_ptr});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.deliver)});
        try self.w("        BEQ L{d}", .{l_dispatch});
        try self.w("        BRA L{d}", .{lq});
        try self.w("L{d}:   LDA ${X}", .{ l_dispatch, self.off_w0 });
        try self.w("        LSR #8", .{});
        try self.w("        AND #$FF", .{});
        try self.w("        BNE L{d}", .{lq});
        for (self.actor.quiesce) |*h| {
            const c = h.case;
            const msg = self.message(c.msg) orelse
                return self.fail(c.line, "unknown message in quiesce case", Error.Semantics);
            const l_next = self.label();
            try self.w("; quiesce case {s}({s})", .{ c.msg, c.bind orelse "_" });
            try self.w("        LDA (${X})", .{self.off_ptr});
            try self.w("        AND ##$FFFF", .{});
            try self.w("        CMP {s}", .{try self.imm(msg.tag)});
            try self.w("        BNE L{d}", .{l_next});
            self.bind = c.bind;
            self.bind_msg = msg;
            if (c.where) |g| try self.branchIfFalse(g, l_next);
            self.in_handler = true;
            try self.stmts(c.body);
            self.in_handler = false;
            self.bind = null;
            self.bind_msg = null;
            try self.w("        BRA L{d}", .{lq});
            try self.w("L{d}:", .{l_next});
        }
        try self.w("        BRA L{d}", .{lq});
    }

    /// The supervision runtime (sketch §2.2: "restarts N is policy, not
    /// code"): match the obituary to a spawn record, run the policy —
    /// clean exit stays down (and its timer is disarmed); a fault
    /// respawns while budget lasts (SPWN, the chain keeps ticking) or is
    /// abandoned (disarm, stay down) — then hand the obituary to the
    /// user's exit cases as an ordinary event.
    fn emitExitRuntime(self: *Gen, l_exit: usize) Error!void {
        const l_crash = self.label();
        const l_hung = self.label();
        const l_abandoned = self.label();
        try self.w("; exit runtime: obituaries → policy → the user's cases", .{});
        try self.w("L{d}:   LDA ${X}", .{ l_exit, self.off_ptr });
        try self.w("        AND ##$FFFFFFFF", .{});
        try self.w("        STA ${X}", .{self.off_ectx});
        try self.w("        LDA ${X}", .{self.off_ptr});
        try self.w("        LSR #32", .{});
        try self.w("        STA ${X}", .{self.off_elife});
        try self.w("        LDA ${X}", .{self.off_w0});
        try self.w("        LSR #32", .{});
        try self.w("        STA ${X}", .{self.off_ecode});
        var k: u16 = 0;
        while (k < self.spawn_count) : (k += 1) {
            const rec = self.spawnRec(k);
            const l_next = self.label();
            const l_fault = self.label();
            const l_respawn = self.label();
            try self.w("        LDA ${X}", .{rec});
            try self.w("        CMP ${X}", .{self.off_ectx});
            try self.w("        BNE L{d}", .{l_next});
            try self.w("        LDA ${X}", .{self.off_w0});
            try self.w("        LSR #8", .{});
            try self.w("        AND #$FF", .{});
            try self.w("        CMP #{d}", .{@intFromEnum(ring.Status.fault)});
            try self.w("        BEQ L{d}", .{l_fault});
            try self.w("        LDA #2              ; clean exit: it stays down, its clock stops", .{});
            try self.w("        STA (${X})", .{rec + 32});
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:   LDA ${X}", .{ l_fault, rec + 40 });
            try self.w("        BNE L{d}", .{l_respawn});
            try self.w("        LDA #2              ; out of restarts: abandoned, honestly", .{});
            try self.w("        STA (${X})", .{rec + 32});
            try self.w("        BRA L{d}", .{l_abandoned});
            try self.w("L{d}:   DEC ${X}", .{ l_respawn, rec + 40 });
            try self.w("        SPWN ${X}         ; fresh registers, same near page, next life", .{rec});
            try self.w("        LDA ${X}", .{self.off_ecode});
            try self.w("        CMP #{d}", .{@intFromEnum(machine.Fault.watchdog)});
            try self.w("        BEQ L{d}", .{l_hung});
            try self.w("        BRA L{d}", .{l_crash});
            try self.w("L{d}:", .{l_next});
        }
        try self.w("        BRA L{d}", .{self.serve_label});
        // The user's cases, one landing site per cause.
        const causes = [3]struct { cause: ExitCause, label: usize }{
            .{ .cause = .crash, .label = l_crash },
            .{ .cause = .hung, .label = l_hung },
            .{ .cause = .abandoned, .label = l_abandoned },
        };
        for (causes) |cz| {
            try self.w("L{d}:", .{cz.label});
            for (self.actor.handlers) |*h| {
                if (h.* != .exit_case or h.exit_case.cause != cz.cause) continue;
                self.exit_bind = h.exit_case.bind;
                self.exit_code_bind = h.exit_case.code_bind;
                self.in_handler = true;
                try self.stmts(h.exit_case.body);
                self.in_handler = false;
                self.exit_bind = null;
                self.exit_code_bind = null;
                break;
            }
            try self.w("        BRA L{d}", .{self.serve_label});
        }
    }
};

// ── Public interface ─────────────────────────────────────────────────────

pub const Slot = struct {
    name: []const u8,
    off: u16,
    addr: bool = false,
    /// A []addr parameter: `off` holds the count; the windows go to RAM
    /// at block + `area` (group_cap entries reserved).
    group: bool = false,
    area: u64 = 0,
};

/// One `spawn` in the actor body, exported for the loader: it places the
/// child, wires watchdog + exit link, and stages the spawn record at
/// `rec_off` in the spawner's near page ({ctx, entry, sp, arg} for SPWN,
/// +32 the child's timer-SQE address).
pub const SpawnOut = struct {
    actor: []const u8,
    rec_off: u16,
    restarts: u64,
    watchdog: u64,
    args: []u64,
};

pub const Result = struct {
    alloc: std.mem.Allocator,
    /// Generated assembly, ready for asm.zig.
    asm_text: []u8,
    /// Near-page slots for the actor's params (the harness stages these)
    /// and vars (tests may read them). Names are owned copies.
    params: []Slot,
    vars: []Slot,
    spawns: []SpawnOut,
    uses_timer: bool,
    /// The `after N` period — the harness wires it as the fabric's
    /// send_timeout until per-send timeouts land (open item, spec §10).
    timer_period: u64,

    pub fn deinit(self: *Result) void {
        for (self.params) |p| self.alloc.free(p.name);
        for (self.vars) |v| self.alloc.free(v.name);
        for (self.spawns) |s| {
            self.alloc.free(s.actor);
            self.alloc.free(s.args);
        }
        self.alloc.free(self.spawns);
        self.alloc.free(self.params);
        self.alloc.free(self.vars);
        self.alloc.free(self.asm_text);
    }
};

/// The deployment described by a source's `system` block, owned copy —
/// everything a loader needs to place, wire and stage instances.
pub const Plan = struct {
    alloc: std.mem.Allocator,
    instances: []PlanInstance,

    pub const PlanInstance = struct {
        name: []const u8,
        actor: []const u8,
        args: []InstanceDecl.Arg,
        core: ?u16,
        replicas: u64,
        line: usize,
    };

    pub fn deinit(self: *Plan) void {
        for (self.instances) |inst| {
            self.alloc.free(inst.name);
            self.alloc.free(inst.actor);
            for (inst.args) |a| {
                if (a == .ref) self.alloc.free(a.ref);
            }
            self.alloc.free(inst.args);
        }
        self.alloc.free(self.instances);
    }
};

/// Parse a source's `system` block into a deployment plan.
pub fn plan(alloc: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) Error!Plan {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var parser = Parser{
        .arena = arena_state.allocator(),
        .lex = .{ .src = source },
        .tok = undefined,
        .diag = diag,
    };
    const prog = try parser.parseProgram();
    var out = std.ArrayList(Plan.PlanInstance).init(alloc);
    errdefer out.deinit();
    for (prog.system) |inst| {
        var args = std.ArrayList(InstanceDecl.Arg).init(alloc);
        for (inst.args) |a| {
            try args.append(switch (a) {
                .int => |v| .{ .int = v },
                .ref => |r| .{ .ref = try alloc.dupe(u8, r) },
                .index => .index,
            });
        }
        try out.append(.{
            .name = try alloc.dupe(u8, inst.name),
            .actor = try alloc.dupe(u8, inst.actor),
            .args = try args.toOwnedSlice(),
            .core = inst.core,
            .replicas = inst.replicas,
            .line = inst.line,
        });
    }
    return .{ .alloc = alloc, .instances = try out.toOwnedSlice() };
}

/// Compile one actor out of a .joe source file to 6564 assembly.
pub fn compile(
    alloc: std.mem.Allocator,
    source: []const u8,
    actor_name: []const u8,
    layout: Layout,
    diag: ?*Diagnostic,
) Error!Result {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = Parser{
        .arena = arena,
        .lex = .{ .src = source },
        .tok = undefined,
        .diag = diag,
    };
    var prog = try parser.parseProgram();

    // Layout: tags in declaration order (1-based), fields packed at their
    // own alignment, wire size padded to 8.
    for (prog.messages, 0..) |*m, i| {
        m.tag = @intCast(i + 1);
        var off: u16 = 2; // the tag word
        for (m.fields) |*f| {
            const a = f.ty.size();
            off = std.mem.alignForward(u16, off, a);
            f.offset = off;
            off += a;
        }
        m.wire_size = std.mem.alignForward(u16, @max(off, 8), 8);
        if (m.wire_size > abi.land_cap) {
            if (diag) |d| d.message = "message larger than a landing buffer";
            return Error.Semantics;
        }
    }

    const actor = for (prog.actors) |*a| {
        if (std.mem.eql(u8, a.name, actor_name)) break a;
    } else {
        if (diag) |d| d.message = "no such actor in this source";
        return Error.Semantics;
    };

    var gen = Gen{
        .arena = arena,
        .out = std.ArrayList(u8).init(alloc),
        .prog = &prog,
        .actor = actor,
        .layout = layout,
        .diag = diag,
        .slots = std.StringHashMap(u16).init(arena),
        .strings = .init(arena),
        .arrays = .init(arena),
    };
    errdefer gen.out.deinit();
    try gen.emit();

    var params = std.ArrayList(Slot).init(alloc);
    errdefer params.deinit();
    var vars = std.ArrayList(Slot).init(alloc);
    errdefer vars.deinit();
    for (actor.params) |p| {
        try params.append(.{
            .name = try alloc.dupe(u8, p.name),
            .off = gen.slots.get(p.name).?,
            .addr = p.ty == .addr,
            .group = p.ty == .addr_slice,
            .area = if (p.ty == .addr_slice)
                abi.data_off + abi.array_off + gen.arrays.get(p.name).?.area
            else
                0,
        });
    }
    for (actor.vars) |v| {
        if (v.array > 0) continue; // RAM arrays aren't read back by name
        try vars.append(.{ .name = try alloc.dupe(u8, v.name), .off = gen.slots.get(v.name).? });
    }
    var spawns = std.ArrayList(SpawnOut).init(alloc);
    errdefer spawns.deinit();
    var k: u16 = 0;
    for (actor.body) |s| {
        if (s != .spawn) continue;
        try spawns.append(.{
            .actor = try alloc.dupe(u8, s.spawn.actor),
            .rec_off = gen.spawnRec(k),
            .restarts = s.spawn.restarts,
            .watchdog = s.spawn.watchdog,
            .args = try alloc.dupe(u64, s.spawn.args),
        });
        k += 1;
    }
    return .{
        .alloc = alloc,
        .asm_text = try gen.out.toOwnedSlice(),
        .params = try params.toOwnedSlice(),
        .vars = try vars.toOwnedSlice(),
        .spawns = try spawns.toOwnedSlice(),
        .uses_timer = gen.uses_timer,
        .timer_period = gen.timer_period,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "joe: pingpong compiles and assembles" {
    const src = @embedFile("programs/pingpong.joe");
    const asm6564 = @import("asm.zig");
    inline for (.{ "Pinger", "Ponger" }) |name| {
        var diag = Diagnostic{};
        var r = compile(testing.allocator, src, name, .{}, &diag) catch |err| {
            std.debug.print("joe {s}: line {d}: {s}\n", .{ name, diag.line, diag.message });
            return err;
        };
        defer r.deinit();
        var adiag = asm6564.Diagnostic{};
        var out = asm6564.assemble(testing.allocator, r.asm_text, &adiag) catch |err| {
            std.debug.print("joe {s}: asm line {d}: {s}\n{s}\n", .{ name, adiag.line, adiag.message, r.asm_text });
            return err;
        };
        defer out.deinit();
        try testing.expect(out.code.len > 0);
    }
}

test "joe: v1 refuses what it cannot yet say, honestly" {
    const src =
        \\actor A() {
        \\    chain { } on_break(k, c) { }
        \\    serve { }
        \\}
    ;
    var diag = Diagnostic{};
    try testing.expectError(
        Error.Unsupported,
        compile(testing.allocator, src, "A", .{}, &diag),
    );
}

test "joe: the system block parses into a plan" {
    const src = @embedFile("programs/pingpong.joe");
    var p = try plan(testing.allocator, src, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.instances.len);
    try testing.expectEqualStrings("pinger", p.instances[0].name);
    try testing.expectEqualStrings("Pinger", p.instances[0].actor);
    try testing.expectEqual(@as(usize, 2), p.instances[0].args.len);
    try testing.expectEqualStrings("ponger", p.instances[0].args[0].ref);
    try testing.expectEqual(@as(u64, 8), p.instances[0].args[1].int);
}
