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

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ Syntax, Semantics, Unsupported, OutOfMemory };

// ── Runtime ABI constants ────────────────────────────────────────────────

pub const abi = struct {
    pub const sq_base: u64 = 0x2400;
    pub const cq_base: u64 = 0x2000;
    pub const rx_base: u64 = 0x2100;
    pub const timer_base: u64 = 0x2480;
    pub const timer_desc: u8 = 5;
    pub const land0: u64 = 0x2200;
    pub const land1: u64 = 0x2240;
    pub const land_cap: u64 = 64;
    pub const msg_staging: u64 = 0x2500;
    pub const param_base: u16 = 0x800;
    pub const timer_cookie: u64 = 0x77;
    pub const timer_window: u64 = 0xFF00_0100_0000_0000; // PTT 1, the black hole
};

// ── AST ──────────────────────────────────────────────────────────────────

const Type = enum {
    u8_,
    u16_,
    u32_,
    u64_,
    addr,

    fn size(self: Type) u16 {
        return switch (self) {
            .u8_ => 1,
            .u16_ => 2,
            .u32_ => 4,
            .u64_, .addr => 8,
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
    bin: struct { op: BinOp, l: *Expr, r: *Expr },
};

const AssignOp = enum { set, add, sub };

const Stmt = union(enum) {
    assign: struct { name: []const u8, op: AssignOp, expr: *Expr },
    send: struct { target: []const u8, msg: []const u8, args: []*Expr, line: usize },
    if_: struct { cond: *Expr, then: []Stmt, els: []Stmt },
    halt: struct { ok: bool },
    bounded: struct { n: u64, body: []Stmt },
};

const Handler = union(enum) {
    case: struct {
        msg: []const u8,
        bind: ?[]const u8, // null = wildcard `_`
        where: ?*Expr,
        body: []Stmt,
        line: usize,
    },
    after: struct { n: u64, body: []Stmt },
};

const Param = struct { name: []const u8, ty: Type };

const VarDecl = struct { name: []const u8, ty: Type, init: ?*Expr };

const Actor = struct {
    name: []const u8,
    params: []Param,
    vars: []VarDecl,
    body: []Stmt,
    handlers: []Handler,
};

const Program = struct {
    messages: []Message,
    actors: []Actor,
};

// ── Lexer ────────────────────────────────────────────────────────────────

const TokKind = enum {
    ident,
    int,
    lbrace,
    rbrace,
    lparen,
    rparen,
    comma,
    colon,
    dot,
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
            .{ "&&", TokKind.and_and },
        };
        inline for (twos) |t| {
            if (std.mem.eql(u8, two, t[0])) {
                self.pos += 2;
                return .{ .kind = t[1], .line = line };
            }
        }
        const ones = .{
            .{ '{', TokKind.lbrace }, .{ '}', TokKind.rbrace },
            .{ '(', TokKind.lparen }, .{ ')', TokKind.rparen },
            .{ ',', TokKind.comma },  .{ ':', TokKind.colon },
            .{ '.', TokKind.dot },    .{ '=', TokKind.assign },
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
        try self.advance();
        while (self.tok.kind != .eof) {
            if (try self.eatKw("message")) {
                try msgs.append(try self.parseMessage());
            } else if (try self.eatKw("actor")) {
                try actors.append(try self.parseActor());
            } else return self.fail("expected `message` or `actor`", Error.Syntax);
        }
        return .{ .messages = try msgs.toOwnedSlice(), .actors = try actors.toOwnedSlice() };
    }

    fn parseType(self: *Parser) Error!Type {
        const t = try self.expect(.ident, "a type");
        return Type.named(t.text) orelse
            self.fail("unknown type (v1 speaks u8..u64 and addr)", Error.Unsupported);
    }

    fn parseMessage(self: *Parser) Error!Message {
        const name = try self.expect(.ident, "message name");
        _ = try self.expect(.lbrace, "{");
        var fields = std.ArrayList(Field).init(self.arena);
        while (self.tok.kind != .rbrace) {
            const fname = try self.expect(.ident, "field name");
            const ty = try self.parseType();
            try fields.append(.{ .name = fname.text, .ty = ty });
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
            const ty = try self.parseType();
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
        if (self.isKw("quiesce"))
            return self.fail("`quiesce` is not in v1 yet", Error.Unsupported);
        _ = try self.expect(.rbrace, "} to close the actor");
        return .{
            .name = name.text,
            .params = try params.toOwnedSlice(),
            .vars = try vlist.toOwnedSlice(),
            .body = try body.toOwnedSlice(),
            .handlers = try handlers.toOwnedSlice(),
        };
    }

    fn parseHandler(self: *Parser) Error!Handler {
        if (try self.eatKw("case")) {
            const line = self.tok.line;
            const msg = try self.expect(.ident, "message name");
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
            _ = try self.expect(.comma, ",");
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
                .msg = msg.text,
                .args = try args.toOwnedSlice(),
                .line = line,
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
        inline for (.{ "spawn", "chain", "for", "let", "quiesce", "region", "grant", "log" }) |kw| {
            if (self.isKw(kw))
                return self.fail("`" ++ kw ++ "` is not in v1 yet", Error.Unsupported);
        }
        // assignment: ident (=|+=|-=) expr
        const name = try self.expect(.ident, "a statement");
        const op: AssignOp = switch (self.tok.kind) {
            .assign => .set,
            .plus_eq => .add,
            .minus_eq => .sub,
            else => return self.fail("expected `=`, `+=` or `-=`", Error.Syntax),
        };
        try self.advance();
        return .{ .assign = .{ .name = name.text, .op = op, .expr = try self.parseExpr() } };
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
    diag: ?*Diagnostic,

    labels: usize = 0,
    serve_label: usize = 0,
    /// Current case binding: name → the landing pointer internal.
    bind: ?[]const u8 = null,
    bind_msg: ?*const Message = null,
    uses_timer: bool = false,
    timer_period: u64 = 0,

    // Near-page slot offsets, assigned in layout().
    slots: std.StringHashMap(u16),
    off_w0: u16 = 0,
    off_ptr: u16 = 0,
    off_t: u16 = 0,
    off_acc: u16 = 0,
    off_fp: u16 = 0,

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

    fn layout(self: *Gen) Error!void {
        var off: u16 = abi.param_base;
        for (self.actor.params) |p| {
            try self.slots.put(p.name, off);
            off += 8;
        }
        for (self.actor.vars) |v| {
            try self.slots.put(v.name, off);
            off += 8;
        }
        self.off_w0 = off;
        self.off_ptr = off + 8;
        self.off_t = off + 16;
        self.off_acc = off + 24;
        self.off_fp = off + 32;
        for (self.actor.handlers) |h| {
            if (h == .after) {
                self.uses_timer = true;
                self.timer_period = h.after.n;
            }
        }
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
                const slot = self.slots.get(name) orelse {
                    if (self.bind != null and std.mem.eql(u8, self.bind.?, name))
                        return self.fail(0, "a message binding needs a field access", Error.Semantics);
                    return self.fail(0, "unknown name", Error.Semantics);
                };
                try self.w("        LDA ${X}", .{slot});
            },
            .field => |f| {
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
                if (self.uses_timer) {
                    try self.w("        LDA #2              ; disarm the timer", .{});
                    try self.w("        STA !${X}", .{abi.timer_base});
                }
                try self.w("        {s}", .{if (h.ok) "HLT" else "BRK"});
            },
            .bounded => |b| {
                try self.w("        WDEX ##{d}", .{b.n});
                try self.stmts(b.body);
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
        const tslot = self.slots.get(sd.target) orelse
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
            try self.w("        STA !${X}", .{abi.msg_staging + word * 8});
        }
        try self.w("        LDA #1              ; SQE: op = send", .{});
        try self.w("        STA !${X}", .{abi.sq_base});
        try self.w("        LDA ${X}", .{tslot});
        try self.w("        STA !${X}", .{abi.sq_base + 8});
        try self.w("        LDA ##${X}", .{abi.msg_staging});
        try self.w("        STA !${X}", .{abi.sq_base + 16});
        try self.w("        LDA ##${X}", .{@as(u64, 1) << 32 | msg.wire_size});
        try self.w("        STA !${X}", .{abi.sq_base + 24});
        try self.w("        SEND 0", .{});
    }

    // ── The actor: prologue, body, serve loop ────────────────────────────

    fn emit(self: *Gen, origin: u64) Error!void {
        try self.layout();
        try self.w("; joe v1 — actor {s} (compiled; do not edit)", .{self.actor.name});
        try self.w("        .org ${X}", .{origin});

        // RX ring: two landing buffers, cookie = buffer address.
        try self.w("; landing buffers (cap-2 AUTO_REPOST ring)", .{});
        inline for (.{ .{ abi.land0, 0 }, .{ abi.land1, 32 } }) |lb| {
            try self.w("        LDA ##${X}", .{lb[0]});
            try self.w("        STA !${X}", .{abi.rx_base + lb[1]});
            try self.w("        STA !${X}", .{abi.rx_base + lb[1] + 24});
            try self.w("        LDA #{d}", .{abi.land_cap});
            try self.w("        STA !${X}", .{abi.rx_base + lb[1] + 8});
            try self.w("        LDA #0", .{});
            try self.w("        STA !${X}", .{abi.rx_base + lb[1] + 16});
        }
        try self.w("        RECV 2", .{});
        try self.w("        RECV 2", .{});

        if (self.uses_timer) {
            try self.w("; the after-timer: AUTO_REARM TXR into the black hole (spec §6.3)", .{});
            try self.w("        LDA ##$202", .{});
            try self.w("        STA !${X}", .{abi.timer_base});
            try self.w("        LDA ##${X}", .{abi.timer_window});
            try self.w("        STA !${X}", .{abi.timer_base + 8});
            try self.w("        LDA #0", .{});
            try self.w("        STA !${X}", .{abi.timer_base + 16});
            try self.w("        LDA ##${X}", .{abi.timer_cookie << 32});
            try self.w("        STA !${X}", .{abi.timer_base + 24});
            try self.w("        SEND {d}", .{abi.timer_desc});
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
            return;
        }

        // ── serve ──
        self.serve_label = self.label();
        const l_dispatch = self.label();
        try self.w("; serve: LSTN, pop, dispatch — acks are consumed, never seen", .{});
        try self.w("L{d}:   LSTN 1", .{self.serve_label});
        try self.w("        CQPOP 1", .{});
        try self.w("        BEQ L{d}", .{self.serve_label});
        try self.w("        STA ${X}", .{self.off_w0});
        try self.w("        STX ${X}", .{self.off_ptr});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP #3", .{});
        try self.w("        BEQ L{d}", .{l_dispatch});
        if (self.uses_timer) {
            // tag 1 (txr) + cookie $77 = the timer; everything else is ack noise
            const l_after = self.label();
            try self.w("        CMP #1", .{});
            try self.w("        BNE L{d}", .{self.serve_label});
            try self.w("        LDA ${X}", .{self.off_ptr});
            try self.w("        AND ##$FFFFFFFF", .{});
            try self.w("        CMP #{d}", .{abi.timer_cookie});
            try self.w("        BNE L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_after});
            for (self.actor.handlers) |*h| {
                if (h.* == .after) {
                    try self.stmts(h.after.body);
                    break;
                }
            }
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
            try self.stmts(c.body);
            self.bind = null;
            self.bind_msg = null;
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_next});
        }
        try self.w("        BRA L{d}", .{self.serve_label});
    }
};

// ── Public interface ─────────────────────────────────────────────────────

pub const Slot = struct { name: []const u8, off: u16 };

pub const Result = struct {
    alloc: std.mem.Allocator,
    /// Generated assembly, ready for asm.zig.
    asm_text: []u8,
    /// Near-page slots for the actor's params (the harness stages these)
    /// and vars (tests may read them). Names are owned copies.
    params: []Slot,
    vars: []Slot,
    uses_timer: bool,
    /// The `after N` period — the harness wires it as the fabric's
    /// send_timeout until per-send timeouts land (open item, spec §10).
    timer_period: u64,

    pub fn deinit(self: *Result) void {
        for (self.params) |p| self.alloc.free(p.name);
        for (self.vars) |v| self.alloc.free(v.name);
        self.alloc.free(self.params);
        self.alloc.free(self.vars);
        self.alloc.free(self.asm_text);
    }
};

/// Compile one actor out of a .joe source file to 6564 assembly.
pub fn compile(
    alloc: std.mem.Allocator,
    source: []const u8,
    actor_name: []const u8,
    origin: u64,
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
        .diag = diag,
        .slots = std.StringHashMap(u16).init(arena),
    };
    errdefer gen.out.deinit();
    try gen.emit(origin);

    var params = std.ArrayList(Slot).init(alloc);
    errdefer params.deinit();
    var vars = std.ArrayList(Slot).init(alloc);
    errdefer vars.deinit();
    for (actor.params) |p| {
        try params.append(.{ .name = try alloc.dupe(u8, p.name), .off = gen.slots.get(p.name).? });
    }
    for (actor.vars) |v| {
        try vars.append(.{ .name = try alloc.dupe(u8, v.name), .off = gen.slots.get(v.name).? });
    }
    return .{
        .alloc = alloc,
        .asm_text = try gen.out.toOwnedSlice(),
        .params = try params.toOwnedSlice(),
        .vars = try vars.toOwnedSlice(),
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
        var r = compile(testing.allocator, src, name, 0x1000, &diag) catch |err| {
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
        \\    spawn B() restarts 3
        \\    serve { }
        \\}
    ;
    var diag = Diagnostic{};
    try testing.expectError(
        Error.Unsupported,
        compile(testing.allocator, src, "A", 0x1000, &diag),
    );
}
