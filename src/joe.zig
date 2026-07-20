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
//! v1 speaks: `message`, `actor`, `var` (scalars and `[N]u64` arrays),
//! params (incl. `[]addr` groups), `send` (incl. `send self` — Amendment
//! 1's self-send loop), `serve`/`case`/`where`/`after`, `if`/`else`,
//! `halt`, `bounded` (checked — see below), `for` (bounded replication,
//! A1.2), `quiesce`, `spawn`…`restarts`…`watchdog`, and the `system`
//! block. Deferred to later items (they parse to an honest "unsupported
//! in v1" error): `let` liveness (that IS handoff item 4), `chain`,
//! `region`/`grant`, `log`; the A1.4 vector package rides with Tier 1.
//! `while` is not deferred — it is not in the language (A1.1). The
//! compiler is four passes in one file — lex → parse → check → emit —
//! producing .asm text for asm.zig. No IR.
//!
//! Amendment 1 (docs/joe-v1-amendment-1.md) makes `bounded` CHECKED:
//! every emitted instruction is charged its ISA-table cycles, so every
//! burst has a computed worst case, and `bounded N` is required exactly
//! when that bound exceeds the spawn-site watchdog (or is data-dependent),
//! rejected when N understates a computable body, and rejected as
//! gratuitous when the handler already fits.
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
const struple = @import("struple.zig");

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
    /// Item 7's measurement flag: route eligible byte-equality sites
    /// through a shared MAC-vectored comparator instead of inlining.
    /// Costs the per-burst SP re-establishment the collapse removed;
    /// buys code size where an actor compares many bufs to one field.
    mac: bool = false,
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

/// The reply window an ask stages (§7.3): PTT slot 0 **in the device's
/// own space**, which the loader aims back at the asker's RX ring —
/// wiring a driver to its device is the same act as wiring two actors.
const device_reply_window: u64 = @as(u64, 0xFF) << 56;

/// Bytes an outbound message image may occupy: staging() to land0().
const staging_room: u16 = 0x80;

/// The device names a system block may instantiate, and what each one
/// IS. The loader holds the authoritative copy (src/joe_run.zig); this
/// is the compiler's early knowledge of the same wiring.
const device_dialects = [_]struct { name: []const u8, dialect: ring.Dialect }{
    .{ .name = "Console", .dialect = .raw },
    .{ .name = "Entropy", .dialect = .ask },
    .{ .name = "Rtc", .dialect = .ask },
    .{ .name = "Block", .dialect = .ask },
    .{ .name = "Net", .dialect = .ask },
    .{ .name = "Matmul", .dialect = .msg },
    .{ .name = "MatmulRemote", .dialect = .msg },
};

/// An instance name → what that endpoint is. Devices carry their own
/// dialect; every other instance is an actor, and actors take messages.
fn dialectOfInstance(prog: *const Program, name: []const u8) ring.Dialect {
    for (prog.system) |*inst| {
        if (!std.mem.eql(u8, inst.name, name)) continue;
        for (device_dialects) |d| {
            if (std.mem.eql(u8, d.name, inst.actor)) return d.dialect;
        }
        return .msg;
    }
    return .any;
}

pub const abi = struct {
    pub const timer_desc: u8 = 5;
    pub const land_cap: u64 = 64;
    /// The one capability token of the v1 ABI: RX rings require it, the
    /// loader's PTT entries present it.
    pub const token: u64 = 0x6564;
    pub const param_base: u16 = 0x800;
    pub const timer_cookie: u64 = 0x77;
    /// One instance block: code at +0, data at +$2000 (rings, buffers,
    /// staging, then the array area), stack down from +$4000. The loader
    /// places context c of a core at ram_base + c * block_size, and
    /// refuses code that overflows the code region — the A2 store taught
    /// us what silent overlap looks like (an actor executing its own
    /// completion queue: bad_macro at a mid-instruction address).
    pub const block_size: u64 = 0x4000;
    pub const data_off: u64 = 0x2000;
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
    /// `bytes` — a variable-length struple payload in a message (A2.5):
    /// one length byte then the bytes, filling the envelope's remainder.
    /// v1: at most one per message, in last position.
    bytes_,
    /// `f64` — Tier 0 scalar float; bits in a u64 slot (A1.4).
    f64_,
    /// `grant` — a region grant riding a message (item 6): two wire
    /// words, the descriptor slot and the token. Message fields only.
    grant_,
    /// `vec` — eight f64 lanes in a 64-byte near-page slab; expressions
    /// evaluate through the Tier 1 V file, which never survives a park,
    /// so `var` stays the only thing that does (A1.4).
    vec_,

    fn size(self: Type) u16 {
        return switch (self) {
            .u8_ => 1,
            .u16_ => 2,
            .u32_ => 4,
            .u64_, .addr, .addr_slice, .f64_ => 8,
            .bytes_ => 0, // laid out specially; never masked or packed
            .grant_ => 16,
            .vec_ => 64,
        };
    }

    fn named(name: []const u8) ?Type {
        const pairs = .{
            .{ "u8", Type.u8_ },   .{ "u16", Type.u16_ },
            .{ "u32", Type.u32_ }, .{ "u64", Type.u64_ },
            .{ "addr", Type.addr }, .{ "bytes", Type.bytes_ },
            .{ "f64", Type.f64_ },  .{ "vec", Type.vec_ },
            .{ "grant", Type.grant_ },
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
    /// `message Draw -> Rand {…}` (Amendment 3): the reply this request
    /// asks for. A paired request lowers to the §7.3 ask framing — word0
    /// = the reply's tag (echoed by the device), word1 = the reply
    /// window, arguments one per word after — and never to a joe wire
    /// image, because a device does not speak joe.
    reply: ?[]const u8 = null,
    /// `message Write -> _ {…}` — a device request that expects no
    /// answer (a block write, a net send): same framing, because the row
    /// has one, and the fabric ack is the whole receipt.
    tells: bool = false,
    /// Set on the REPLY message: its fields live one word each from
    /// offset 8, behind the echoed tag. Everything downstream — the case
    /// ladder, field loads — reads it like any other message.
    is_reply: bool = false,

    /// Does this message lower to the §7.3 device framing?
    fn device(m: *const Message) bool {
        return m.reply != null or m.tells;
    }
};

const BinOp = enum { add, sub, mul, div, band, bor, bxor, shl, shr, eq, ne, lt, le, gt, ge, land };

const Expr = union(enum) {
    int: u64,
    ident: []const u8,
    field: struct { base: []const u8, name: []const u8 },
    index: struct { base: []const u8, idx: *Expr },
    bin: struct { op: BinOp, l: *Expr, r: *Expr },
    /// `key.count()` — walk a buf's elements with the total skip (A2.2);
    /// data-dependent by nature, so A1.3's rules apply in full.
    count: []const u8,
    /// `bind.field.len` — the byte count of a device reply's raw payload.
    paylen: struct { base: []const u8, name: []const u8 },
    /// A float literal, as its f64 bits.
    float: u64,
    /// `[1.0, 2.0, …]` — a vector literal, eight f64 lanes (zero-padded).
    vlit: []u64,
    /// `v.reduce(+|max|min)` — the Tier 1 reduction, into a scalar f64.
    reduce: struct { base: *Expr, op: enum { sum, max, min } },
    /// `v.permute([3,2,1,0,…])` — constant lane shuffle; `mask` is the
    /// A-format index byte per lane.
    permute: struct { base: *Expr, mask: u64 },
    /// `f64(e)` / `int(e)` — the explicit conversions (ITOF / FTOI).
    cast: struct { to_f64: bool, e: *Expr },
    /// `grant frame` as a send argument (item 6): stages the region's
    /// descriptor slot and token, and flips the compile-time type-state.
    grantref: []const u8,
};

/// One element of an `is` tuple pattern (A2.4): constants fuse into a
/// pre-packed memcmp; `?x` decodes and binds one integer element; a
/// non-subset element fails the match, it does not fault.
const Tpat = union(enum) {
    lit_str: []const u8,
    lit_int: u64,
    bind: []const u8,
};

/// `subject is ("users", ?id, ..rest)` — subject is a bound message's
/// bytes field or a local buf. `rest` binds the remaining bytes as a
/// view value (offset<<32 | length, subject-relative); without it the
/// pattern requires end of stream.
const Pattern = struct {
    subject: *Expr,
    elems: []Tpat,
    rest: ?[]const u8,
    line: usize,
};

const AssignOp = enum { set, add, sub };

const Stmt = union(enum) {
    assign: struct { name: []const u8, idx: ?*Expr, op: AssignOp, expr: *Expr, field: ?[]const u8 = null },
    /// `let x = e` — a burst-local binding (Amendment 3): lives for the
    /// rest of its block, never crosses a park, cannot be reassigned.
    /// Where it lives is codegen's business; the lifetime is the contract.
    let_: struct { name: []const u8, expr: *Expr, line: usize },
    send: struct { target: []const u8, target_idx: ?*Expr, msg: []const u8, args: []*Expr, line: usize },
    for_range: struct { name: []const u8, from: *Expr, to: *Expr, body: []Stmt },
    for_group: struct { idx: []const u8, elem: []const u8, group: []const u8, body: []Stmt, line: usize },
    /// `send tty, "TEXT"` — raw bytes to a device: no tag, no fields,
    /// just the payload a teletype expects.
    send_str: struct { target: []const u8, text: []const u8, line: usize },
    /// `send tty, b` — a buf's current bytes, verbatim, length at send
    /// time (Amendment 3). Raw is for devices; actors take messages.
    send_buf: struct { target: []const u8, buf: []const u8, line: usize },
    /// `send tty, ch.data` — forward a device reply's raw payload from
    /// the landing buffer; the fabric's own count is its length.
    send_field: struct { target: []const u8, bind: []const u8, field: []const u8, line: usize },
    /// `clear b` / `append b, …` — the raw dialect (Amendment 3):
    /// `pack` speaks struple to actors, `append` speaks raw to devices.
    clear_: struct { buf: []const u8, line: usize },
    append_: struct { buf: []const u8, src: AppendSrc, line: usize },
    if_: struct { cond: *Expr, then: []Stmt, els: []Stmt },
    halt: struct { ok: bool },
    bounded: struct { n: u64, body: []Stmt, line: usize },
    /// Enter the lame-duck phase: timers die, the quiesce case set takes
    /// over. Termination is a phase, not an instruction.
    quiesce,
    /// `pack key, ("users", id, "profile")` — encode a struple tuple into
    /// a declared buffer (A2.3). Canonical only; capacity checked.
    pack: struct { buf: []const u8, elems: []PackElem, line: usize },
    /// `grant frame to boss` (A4 movement 3) — hand a region capability
    /// to another actor. Probate, not bequest: the grantee an actor
    /// names is its supervisor, which the exit link already legitimizes.
    /// `onward` adds the `grant` verb, so the grantee may pass it on
    /// again. Withheld by default: a chain ends wherever somebody
    /// declines to extend it, and that decision should be readable in
    /// the source rather than inferred from the grantee's identity.
    /// Probate needs it — an executor that cannot distribute the estate
    /// is not an executor — and probate is exactly where it is written.
    grant_: struct { region: []const u8, to: []const u8, onward: bool, line: usize },
    /// `adopt h as frame` (A4 movement 3) — sign for the estate. Copies
    /// the descriptor hardware installed (base, verbs, extent, token)
    /// into the slot the heir's own `frame` names, points `frame`'s base
    /// cell at the inherited memory, and clears hardware's slot so the
    /// estate is named exactly once. The verbs come across by copy, not
    /// by reconstruction: the grantor's attenuation survives adoption
    /// because nobody re-derives it.
    adopt_: struct { rec: []const u8, region: []const u8, line: usize },
    /// `copy dst, src` — bytes into a buf from another buf or from the
    /// bound message's bytes field. The store's Put, among others.
    copy_: struct { dst: []const u8, src: *Expr, line: usize },
    spawn: struct {
        actor: []const u8,
        args: []u64, // v1: literal args only
        restarts: u64,
        watchdog: u64,
        /// `spawn W() as w` — the supervisor's name for the child. Binds a
        /// capability aimed at the child's RX ring (the exit link's twin,
        /// pointed down), so probate can reach a successor: obituaries
        /// flow up, and now a grant can flow back. null = unnamed, the
        /// old shape — a supervisor that only buries.
        bind: ?[]const u8,
        line: usize,
    },
};

const AppendSrc = union(enum) { str: []const u8, byte: *Expr, name: []const u8 };

const ExitCause = enum { crash, hung, abandoned };

const Handler = union(enum) {
    case: struct {
        msg: []const u8,
        bind: ?[]const u8, // null = wildcard `_`
        where: ?*Expr,
        /// `where subject is (…)` — the A2.4 tuple pattern; a case has
        /// a comparison guard or a pattern, not both.
        pat: ?Pattern = null,
        body: []Stmt,
        line: usize,
    },
    after: struct { n: u64, body: []Stmt, line: usize },
    exit_case: struct {
        bind: []const u8,
        cause: ExitCause,
        code_bind: ?[]const u8,
        body: []Stmt,
        line: usize,
    },
    /// `case handoff(h):` (A4 movement 3) — an estate arrived. The
    /// binding names the grant record, not the memory: until `adopt`
    /// runs, the heir holds a capability it cannot address, in a
    /// descriptor slot hardware chose. Probate, not bequest.
    handoff_case: struct {
        bind: []const u8,
        body: []Stmt,
        line: usize,
    },
};

const Param = struct { name: []const u8, ty: Type };

/// `array` > 0 makes this a u64 array of that many elements, living in
/// the instance block's RAM (the near page is too small for them).
/// `buf_cap` > 0 makes this a `buf [N]u8` (Amendment 2): a near-page byte
/// slab with a length slot — small, hot, survives parks.
/// `region_len` > 0 makes this a REGISTERED REGION (item 6): a RAM array
/// with a descriptor — grantable, token-guarded, type-state-locked while
/// granted. `region_f64` picks the element type.
const VarDecl = struct {
    name: []const u8,
    ty: Type,
    init: ?*Expr,
    array: u16 = 0,
    buf_cap: u16 = 0,
    region_len: u16 = 0,
    region_f64: bool = false,
    /// `var anim Anim` (A3.4): the record this variable is shaped by.
    record: ?[]const u8 = null,
};

/// One element of a `pack` tuple literal: constants pre-pack at compile
/// time; an identifier is a u64 scalar encoded at runtime.
const PackElem = union(enum) {
    str: []const u8,
    int: u64,
    ident: []const u8,
};

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
    /// `const name = "…"` — named read-only byte data (Amendment 3),
    /// staged after code the way string literals are; the on-ramp to
    /// §11's shared const pages.
    consts: []Const,
    records: []Record = &.{},
};

const Const = struct { name: []const u8, text: []const u8 };

/// `struct Anim { last u64, index u64 }` (A3.4) — named offsets into the
/// near page: no pointers, no nesting, scalar fields, fixed layout. A
/// shape, not a heap.
const Record = struct { name: []const u8, fields: []Field };

// ── Lexer ────────────────────────────────────────────────────────────────

const TokKind = enum {
    ident,
    int,
    /// A float literal; `value` holds the f64 bits.
    float,
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
    question,
    assign, // =
    arrow, // -> : a request and the reply it expects (A3.3)
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
    star,
    slash,
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
            .{ "->", TokKind.arrow },
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
            .{ '^', TokKind.caret },  .{ '?', TokKind.question },
            .{ '*', TokKind.star },   .{ '/', TokKind.slash },
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
            // A decimal literal may continue as a float: `1.5`, `2.5e-3`.
            // `1..8` stays a range (the second dot disqualifies), and hex
            // never grows a point.
            if (base == 10) {
                const s = self.src;
                var p = self.pos;
                var is_float = false;
                if (p + 1 < s.len and s[p] == '.' and std.ascii.isDigit(s[p + 1])) {
                    is_float = true;
                    p += 1;
                    while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
                }
                if (p < s.len and (s[p] == 'e' or s[p] == 'E')) {
                    var q = p + 1;
                    if (q < s.len and (s[q] == '+' or s[q] == '-')) q += 1;
                    if (q < s.len and std.ascii.isDigit(s[q])) {
                        is_float = true;
                        p = q;
                        while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
                    }
                }
                if (is_float) {
                    self.pos = p;
                    const text = self.src[start..self.pos];
                    const f = std.fmt.parseFloat(f64, text) catch return Error.Syntax;
                    return .{ .kind = .float, .value = @bitCast(f), .text = text, .line = line };
                }
            }
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
        var consts = std.ArrayList(Const).init(self.arena);
        var records = std.ArrayList(Record).init(self.arena);
        try self.advance();
        while (self.tok.kind != .eof) {
            if (try self.eatKw("message")) {
                var reply: ?Message = null;
                try msgs.append(try self.parseMessage(&reply));
                if (reply) |r| try msgs.append(r);
            } else if (try self.eatKw("actor")) {
                try actors.append(try self.parseActor());
            } else if (try self.eatKw("const")) {
                const cname = try self.expect(.ident, "const name");
                if (self.tok.kind != .assign)
                    return self.fail("a const is `const name = \"…\"`", Error.Syntax);
                try self.advance();
                if (self.tok.kind != .string)
                    return self.fail("v1 consts are byte strings", Error.Unsupported);
                const text = try self.decodeStr(self.tok.text);
                try self.advance();
                try consts.append(.{ .name = cname.text, .text = text });
            } else if (try self.eatKw("struct")) {
                const rname = try self.expect(.ident, "struct name");
                const rfields = try self.parseFields();
                for (rfields) |*f| {
                    if (f.ty == .bytes_ or f.ty == .vec_ or f.ty == .addr_slice)
                        return self.fail("a record holds scalars (v1): a shape, not a heap", Error.Unsupported);
                }
                try records.append(.{ .name = rname.text, .fields = rfields });
            } else if (try self.eatKw("system")) {
                _ = try self.expect(.lbrace, "{");
                while (self.tok.kind != .rbrace) {
                    try system.append(try self.parseInstance());
                }
                try self.advance(); // }
            } else return self.fail("expected `message`, `actor`, `const` or `system`", Error.Syntax);
        }
        return .{
            .messages = try msgs.toOwnedSlice(),
            .actors = try actors.toOwnedSlice(),
            .system = try system.toOwnedSlice(),
            .consts = try consts.toOwnedSlice(),
            .records = try records.toOwnedSlice(),
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

    /// `message Name { fields }` and, for the device conversation
    /// (A3.3), `message Ask [{ fields }] -> Reply { fields }`: two
    /// messages in one declaration, because a request and the answer it
    /// expects are one fact. Returns the request; the reply (when there
    /// is one) comes back through `extra`.
    fn parseMessage(self: *Parser, extra: *?Message) Error!Message {
        const name = try self.expect(.ident, "message name");
        const no_fields: []Field = &.{};
        const fields = if (self.tok.kind == .lbrace) try self.parseFields() else no_fields;
        if (self.tok.kind != .arrow)
            return .{ .name = name.text, .fields = fields };
        try self.advance(); // ->
        if (self.tok.kind == .underscore) {
            // `-> _`: a device request that answers to nothing.
            try self.advance();
            return .{ .name = name.text, .fields = fields, .tells = true };
        }
        const rname = try self.expect(.ident, "reply message name");
        if (self.tok.kind != .lbrace)
            return self.fail("a reply names its fields (`-> Reply { … }`)", Error.Syntax);
        extra.* = .{
            .name = rname.text,
            .fields = try self.parseFields(),
            .is_reply = true,
        };
        return .{ .name = name.text, .fields = fields, .reply = rname.text };
    }

    fn parseFields(self: *Parser) Error![]Field {
        _ = try self.expect(.lbrace, "{");
        var fields = std.ArrayList(Field).init(self.arena);
        while (self.tok.kind != .rbrace) {
            const fname = try self.expect(.ident, "field name");
            const ty = try self.parseType();
            if (ty == .addr_slice)
                return self.fail("a message cannot carry a slice", Error.Semantics);
            if (ty == .vec_)
                return self.fail("a vec doesn't ride a message (v1) — send scalars or bytes", Error.Semantics);
            try fields.append(.{ .name = fname.text, .ty = ty });
            if (self.tok.kind == .comma) try self.advance();
        }
        try self.advance(); // }
        return fields.toOwnedSlice();
    }

    fn parseActor(self: *Parser) Error!Actor {
        const name = try self.expect(.ident, "actor name");
        _ = try self.expect(.lparen, "(");
        var params = std.ArrayList(Param).init(self.arena);
        while (self.tok.kind != .rparen) {
            const pname = try self.expect(.ident, "parameter name");
            const ty = try self.parseType();
            if (ty == .bytes_)
                return self.fail("bytes live in messages and bufs, not params (v1)", Error.Semantics);
            if (ty == .vec_)
                return self.fail("a vec is actor-local (v1) — params carry scalars", Error.Semantics);
            if (ty == .grant_)
                return self.fail("a grant rides a message, not a param", Error.Semantics);
            try params.append(.{ .name = pname.text, .ty = ty });
            if (self.tok.kind == .comma) try self.advance();
        }
        try self.advance(); // )
        _ = try self.expect(.lbrace, "{");

        var vlist = std.ArrayList(VarDecl).init(self.arena);
        while (self.isKw("var")) {
            try self.advance();
            const vname = try self.expect(.ident, "var name");
            if (self.isKw("region")) {
                // `var frame region [96]f64` — a registered region (item
                // 6): RAM elements plus a descriptor the actor can grant.
                try self.advance();
                _ = try self.expect(.lbracket, "[");
                const n = try self.expect(.int, "region length");
                _ = try self.expect(.rbracket, "]");
                const t = try self.expect(.ident, "u64 or f64");
                const is_f = std.mem.eql(u8, t.text, "f64");
                if (!is_f and !std.mem.eql(u8, t.text, "u64"))
                    return self.fail("v1 regions hold u64 or f64", Error.Unsupported);
                if (n.value == 0 or n.value > 512)
                    return self.fail("region length is 1..512 elements in v1", Error.Semantics);
                try vlist.append(.{
                    .name = vname.text,
                    .ty = if (is_f) .f64_ else .u64_,
                    .init = null,
                    .region_len = @intCast(n.value),
                    .region_f64 = is_f,
                });
                continue;
            }
            if (self.isKw("buf")) {
                // `var key buf [64]u8` — a near-page byte buffer (A2.1).
                try self.advance();
                _ = try self.expect(.lbracket, "[");
                const n = try self.expect(.int, "buffer capacity");
                _ = try self.expect(.rbracket, "]");
                const t = try self.expect(.ident, "u8");
                if (!std.mem.eql(u8, t.text, "u8"))
                    return self.fail("a buf is bytes: `buf [N]u8`", Error.Syntax);
                if (n.value < 16 or n.value > 1024)
                    return self.fail("buf capacity is 16..1024 in v1", Error.Semantics);
                try vlist.append(.{ .name = vname.text, .ty = .u64_, .init = null, .buf_cap = @intCast(n.value) });
                continue;
            }
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
            if (self.tok.kind == .ident and Type.named(self.tok.text) == null) {
                // `var anim Anim` — a record-shaped variable (A3.4).
                const rname = self.tok.text;
                try self.advance();
                try vlist.append(.{
                    .name = vname.text,
                    .ty = .u64_,
                    .init = null,
                    .record = rname,
                });
                continue;
            }
            const ty = try self.parseType();
            if (ty == .addr_slice)
                return self.fail("[]addr is a parameter type", Error.Semantics);
            if (ty == .bytes_)
                return self.fail("a byte variable is a `buf [N]u8`", Error.Semantics);
            if (ty == .grant_)
                return self.fail("a grant rides a message; a grantable thing is a `region`", Error.Semantics);
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
            if (std.mem.eql(u8, msg.text, "handoff")) {
                // `case handoff(h):` — the estate arrives as an ordinary
                // delivery, because a capability moving IS a message.
                _ = try self.expect(.lparen, "(");
                const bind = try self.expect(.ident, "a name for the estate");
                _ = try self.expect(.rparen, ")");
                _ = try self.expect(.colon, ":");
                return .{ .handoff_case = .{
                    .bind = bind.text,
                    .body = try self.parseHandlerBody(),
                    .line = line,
                } };
            }
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
            var pat: ?Pattern = null;
            if (try self.eatKw("where")) {
                const subj = try self.parseExpr();
                if (try self.eatKw("is")) {
                    if (subj.* != .field and subj.* != .ident)
                        return self.fail("a match subject is a bytes field or a buf", Error.Semantics);
                    pat = try self.parseTpat(subj);
                } else where = subj;
            }
            _ = try self.expect(.colon, ":");
            return .{ .case = .{
                .msg = msg.text,
                .bind = bind,
                .where = where,
                .pat = pat,
                .body = try self.parseHandlerBody(),
                .line = line,
            } };
        }
        if (try self.eatKw("after")) {
            const line = self.tok.line;
            const n = try self.expect(.int, "cycle count");
            _ = try self.expect(.colon, ":");
            return .{ .after = .{ .n = n.value, .body = try self.parseHandlerBody(), .line = line } };
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
                const text = try self.decodeStr(self.tok.text);
                try self.advance();
                return .{ .send_str = .{
                    .target = target.text,
                    .text = text,
                    .line = line,
                } };
            }
            const msg = try self.expect(.ident, "message name");
            if (self.tok.kind == .dot) {
                // `send tty, ch.data` — a device reply's raw payload,
                // forwarded straight from the landing buffer.
                try self.advance();
                const fname = try self.expect(.ident, "field name");
                if (target_idx != null)
                    return self.fail("a raw send goes to one device", Error.Semantics);
                return .{ .send_field = .{
                    .target = target.text,
                    .bind = msg.text,
                    .field = fname.text,
                    .line = line,
                } };
            }
            if (self.tok.kind != .lbrace) {
                // `send tty, b` — a buf, raw (Amendment 3).
                if (target_idx != null)
                    return self.fail("a raw send goes to one device", Error.Semantics);
                return .{ .send_buf = .{ .target = target.text, .buf = msg.text, .line = line } };
            }
            _ = try self.expect(.lbrace, "{");
            var args = std.ArrayList(*Expr).init(self.arena);
            while (self.tok.kind != .rbrace) {
                if (try self.eatKw("grant")) {
                    const rname = try self.expect(.ident, "a region name");
                    try args.append(try self.mkExpr(.{ .grantref = rname.text }));
                } else {
                    try args.append(try self.parseExpr());
                }
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
            return .{ .bounded = .{ .n = n.value, .body = try self.parseBlock(), .line = line } };
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
            var bind: ?[]const u8 = null;
            // `restarts` / `watchdog` / `as` in any order — three clauses,
            // none required, each read at most once.
            while (true) {
                if (try self.eatKw("restarts")) {
                    restarts = (try self.expect(.int, "restart budget")).value;
                } else if (try self.eatKw("watchdog")) {
                    watchdog = (try self.expect(.int, "watchdog budget")).value;
                } else if (try self.eatKw("as")) {
                    bind = (try self.expect(.ident, "a name for the child")).text;
                } else break;
            }
            return .{ .spawn = .{
                .actor = actor.text,
                .args = try args.toOwnedSlice(),
                .restarts = restarts,
                .watchdog = watchdog,
                .bind = bind,
                .line = line,
            } };
        }
        if (try self.eatKw("quiesce")) return .quiesce;
        if (try self.eatKw("pack")) {
            const bname = try self.expect(.ident, "a buf name");
            _ = try self.expect(.comma, ",");
            _ = try self.expect(.lparen, "(");
            var elems = std.ArrayList(PackElem).init(self.arena);
            while (self.tok.kind != .rparen) {
                switch (self.tok.kind) {
                    .string => try elems.append(.{ .str = try self.decodeStr(self.tok.text) }),
                    .int => try elems.append(.{ .int = self.tok.value }),
                    .ident => try elems.append(.{ .ident = self.tok.text }),
                    else => return self.fail("a tuple element is a literal or a name (v1)", Error.Syntax),
                }
                try self.advance();
                if (self.tok.kind == .comma) try self.advance();
            }
            try self.advance(); // )
            if (elems.items.len == 0)
                return self.fail("an empty tuple packs nothing", Error.Semantics);
            return .{ .pack = .{ .buf = bname.text, .elems = try elems.toOwnedSlice(), .line = line } };
        }
        if (try self.eatKw("copy")) {
            const dst = try self.expect(.ident, "a buf name");
            _ = try self.expect(.comma, ",");
            return .{ .copy_ = .{ .dst = dst.text, .src = try self.parseExpr(), .line = line } };
        }
        if (try self.eatKw("clear")) {
            const bname = try self.expect(.ident, "a buf name");
            return .{ .clear_ = .{ .buf = bname.text, .line = line } };
        }
        if (try self.eatKw("append")) {
            const bname = try self.expect(.ident, "a buf name");
            _ = try self.expect(.comma, ",");
            if (self.tok.kind == .string) {
                const text = try self.decodeStr(self.tok.text);
                try self.advance();
                return .{ .append_ = .{ .buf = bname.text, .src = .{ .str = text }, .line = line } };
            }
            if (try self.eatKw("byte")) {
                _ = try self.expect(.lparen, "(");
                const e = try self.parseExpr();
                _ = try self.expect(.rparen, ")");
                return .{ .append_ = .{ .buf = bname.text, .src = .{ .byte = e }, .line = line } };
            }
            if (self.tok.kind == .ident) {
                // A const's bytes, whole — the literal it names.
                const cname = self.tok.text;
                try self.advance();
                return .{ .append_ = .{ .buf = bname.text, .src = .{ .name = cname }, .line = line } };
            }
            return self.fail("append takes a literal, a const or byte(expr) (v1)", Error.Unsupported);
        }
        if (self.isKw("while"))
            return self.fail(
                "joe has no `while` (Amendment 1): unbounded iteration is a self-send loop, one park per slice",
                Error.Semantics,
            );
        if (try self.eatKw("let")) {
            const bname = try self.expect(.ident, "binding name");
            if (self.tok.kind != .assign)
                return self.fail("a let is `let name = expr`", Error.Syntax);
            try self.advance();
            return .{ .let_ = .{ .name = bname.text, .expr = try self.parseExpr(), .line = line } };
        }
        if (try self.eatKw("grant")) {
            const rname = try self.expect(.ident, "a region name");
            if (!try self.eatKw("to"))
                return self.fail("a grant names its grantee: `grant frame to boss`", Error.Syntax);
            const to = try self.expect(.ident, "the grantee");
            const onward = try self.eatKw("onward");
            return .{ .grant_ = .{
                .region = rname.text,
                .to = to.text,
                .onward = onward,
                .line = line,
            } };
        }
        if (try self.eatKw("adopt")) {
            const rec = try self.expect(.ident, "the estate (a `handoff` binding)");
            if (!try self.eatKw("as"))
                return self.fail("an adoption names the region it becomes: `adopt h as frame`", Error.Syntax);
            const rname = try self.expect(.ident, "a region name");
            return .{ .adopt_ = .{ .rec = rec.text, .region = rname.text, .line = line } };
        }
        inline for (.{ "chain", "region", "log" }) |kw| {
            if (self.isKw(kw))
                return self.fail("`" ++ kw ++ "` is not in v1 yet", Error.Unsupported);
        }
        // assignment: ident(.field | [idx])? (=|+=|-=) expr
        const name = try self.expect(.ident, "a statement");
        var field: ?[]const u8 = null;
        if (self.tok.kind == .dot) {
            try self.advance();
            field = (try self.expect(.ident, "field name")).text;
        }
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
        return .{ .assign = .{
            .name = name.text,
            .idx = idx,
            .op = op,
            .expr = try self.parseExpr(),
            .field = field,
        } };
    }

    /// `("users", ?id, ..rest)` — the A2.4 tuple pattern.
    fn parseTpat(self: *Parser, subj: *Expr) Error!Pattern {
        const line = self.tok.line;
        _ = try self.expect(.lparen, "(");
        var elems = std.ArrayList(Tpat).init(self.arena);
        var rest: ?[]const u8 = null;
        while (self.tok.kind != .rparen) {
            if (self.tok.kind == .dotdot) {
                try self.advance();
                rest = (try self.expect(.ident, "rest binding")).text;
                break; // ..rest is always last
            }
            switch (self.tok.kind) {
                .string => {
                    try elems.append(.{ .lit_str = try self.decodeStr(self.tok.text) });
                    try self.advance();
                },
                .int => {
                    try elems.append(.{ .lit_int = self.tok.value });
                    try self.advance();
                },
                .question => {
                    try self.advance();
                    try elems.append(.{ .bind = (try self.expect(.ident, "bind name")).text });
                },
                else => return self.fail("a pattern element is a literal, `?name` or `..rest`", Error.Syntax),
            }
            if (self.tok.kind == .comma) try self.advance();
        }
        _ = try self.expect(.rparen, ")");
        if (elems.items.len == 0 and rest == null)
            return self.fail("an empty pattern matches nothing", Error.Semantics);
        return .{ .subject = subj, .elems = try elems.toOwnedSlice(), .rest = rest, .line = line };
    }

    /// Decode a string token's escapes (`\n`, `\t`, `\x`) into the arena.
    fn decodeStr(self: *Parser, raw: []const u8) Error![]const u8 {
        var text = std.ArrayList(u8).init(self.arena);
        var j: usize = 0;
        while (j < raw.len) : (j += 1) {
            if (raw[j] == '\\' and j + 1 < raw.len) {
                j += 1;
                try text.append(switch (raw[j]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    else => raw[j],
                });
            } else try text.append(raw[j]);
        }
        return text.toOwnedSlice();
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
        var l = try self.parseMul();
        while (self.tok.kind == .plus or self.tok.kind == .minus) {
            const op: BinOp = if (self.tok.kind == .plus) .add else .sub;
            try self.advance();
            l = try self.mkExpr(.{ .bin = .{ .op = op, .l = l, .r = try self.parseMul() } });
        }
        return l;
    }

    fn parseMul(self: *Parser) Error!*Expr {
        var l = try self.parsePrimary();
        while (self.tok.kind == .star or self.tok.kind == .slash) {
            const op: BinOp = if (self.tok.kind == .star) .mul else .div;
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
            .float => {
                const v = self.tok.value;
                try self.advance();
                return self.mkExpr(.{ .float = v });
            },
            .lbracket => {
                // `[1.0, 2.0, …]` — eight f64 lanes, zero-padded.
                try self.advance();
                var lanes = std.ArrayList(u64).init(self.arena);
                while (self.tok.kind != .rbracket) {
                    switch (self.tok.kind) {
                        .float => try lanes.append(self.tok.value),
                        .int => try lanes.append(@bitCast(@as(f64, @floatFromInt(self.tok.value)))),
                        else => return self.fail("vector lanes are number literals (v1)", Error.Syntax),
                    }
                    try self.advance();
                    if (self.tok.kind == .comma) try self.advance();
                }
                try self.advance(); // ]
                if (lanes.items.len == 0 or lanes.items.len > 8)
                    return self.fail("a vector holds 1..8 lanes", Error.Semantics);
                while (lanes.items.len < 8) try lanes.append(@bitCast(@as(f64, 0.0)));
                return self.mkExpr(.{ .vlit = try lanes.toOwnedSlice() });
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
                if (self.tok.kind == .lparen) {
                    // `f64(e)` / `int(e)` — the explicit conversions
                    if (std.mem.eql(u8, name, "f64") or std.mem.eql(u8, name, "int")) {
                        try self.advance();
                        const e = try self.parseExpr();
                        _ = try self.expect(.rparen, ")");
                        return self.mkExpr(.{ .cast = .{ .to_f64 = name[0] == 'f', .e = e } });
                    }
                    return self.fail("only `f64(…)` and `int(…)` call like functions (v1)", Error.Unsupported);
                }
                if (self.tok.kind == .dot) {
                    try self.advance();
                    const f = try self.expect(.ident, "field name");
                    if (self.tok.kind == .lparen) {
                        try self.advance();
                        if (std.mem.eql(u8, f.text, "count")) {
                            _ = try self.expect(.rparen, ")");
                            return self.mkExpr(.{ .count = name });
                        }
                        if (std.mem.eql(u8, f.text, "reduce")) {
                            // `.reduce(+ | max | min)`
                            const op: @FieldType(@FieldType(Expr, "reduce"), "op") = blk: {
                                if (self.tok.kind == .plus) {
                                    try self.advance();
                                    break :blk .sum;
                                }
                                if (self.isKw("max")) {
                                    try self.advance();
                                    break :blk .max;
                                }
                                if (self.isKw("min")) {
                                    try self.advance();
                                    break :blk .min;
                                }
                                return self.fail("reduce takes `+`, `max` or `min` (v1)", Error.Unsupported);
                            };
                            _ = try self.expect(.rparen, ")");
                            return self.mkExpr(.{ .reduce = .{
                                .base = try self.mkExpr(.{ .ident = name }),
                                .op = op,
                            } });
                        }
                        if (std.mem.eql(u8, f.text, "permute")) {
                            _ = try self.expect(.lbracket, "[");
                            var mask: u64 = 0;
                            var i: u6 = 0;
                            while (self.tok.kind != .rbracket) {
                                const n = try self.expect(.int, "a lane index");
                                if (n.value > 7 or i >= 8)
                                    return self.fail("permute takes up to 8 lane indices 0..7", Error.Semantics);
                                mask |= n.value << (i * 8);
                                i += 1;
                                if (self.tok.kind == .comma) try self.advance();
                            }
                            try self.advance(); // ]
                            // unnamed lanes keep their place
                            while (i < 8) : (i += 1) mask |= @as(u64, i) << (i * 8);
                            _ = try self.expect(.rparen, ")");
                            return self.mkExpr(.{ .permute = .{
                                .base = try self.mkExpr(.{ .ident = name }),
                                .mask = mask,
                            } });
                        }
                        return self.fail("v1 methods: `.count()`, `.reduce(op)`, `.permute([…])`", Error.Unsupported);
                    }
                    if (self.tok.kind == .dot) {
                        // `ch.data.len` — how many bytes a device reply's
                        // payload actually carried (A3.3): the fabric
                        // counted them, so nothing in-band has to.
                        try self.advance();
                        const m = try self.expect(.ident, "`len`");
                        if (!std.mem.eql(u8, m.text, "len"))
                            return self.fail("a payload has `.len` (v1)", Error.Unsupported);
                        return self.mkExpr(.{ .paylen = .{ .base = name, .name = f.text } });
                    }
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

// ── The cost accountant (Amendment 1, A1.3) ─────────────────────────────
//
// With `while` gone and `for` bounded by construction, every burst — init,
// and each handler body plus its share of the serve loop — has a worst-case
// cycle count the compiler can add up. It does: every emitted line is
// charged its ISA-table cycles (mode-exact, the same table the machine
// bills from), constant-extent loops multiply, and an extent the analysis
// cannot see (a group's count, a variable range) marks the burst
// data-dependent. Then `bounded N` is REQUIRED exactly when the computed
// bound exceeds the spawn-site watchdog (or cannot be computed), REJECTED
// when N understates a computable body, and REJECTED as gratuitous when
// the handler already fits. The watchdog remains judge of the
// data-dependent claims — the only lies left are about data.

/// Classify an emitted operand into its addressing mode. The generator's
/// output is a closed set of shapes; anything unrecognized falls back to
/// the mnemonic's worst-case encoding.
fn operandMode(op: []const u8) ?isa.Mode {
    if (op.len == 0) return null; // impl (or acc) — resolved in cycFor
    if (std.mem.startsWith(u8, op, "##")) return .imm64;
    if (op[0] == '#') return .imm8;
    if (std.mem.startsWith(u8, op, "!$")) return .abs;
    if (op[0] == '(') return if (std.mem.endsWith(u8, op, ",Y")) .ind_y else .ind;
    if (op[0] == '$') return .near;
    if (op[0] == 'L') return .rel16; // branch target label
    return .desc; // bare descriptor index: SEND 0, RECV 2, LSTN 1, CQPOP 1
}

fn cycFor(mn: isa.Mnemonic, mode: ?isa.Mode) u64 {
    // Both pages: the accountant bills from the same tables the machine
    // does, base and extended alike.
    if (mode) |md| {
        for (isa.table) |enc| {
            if (enc.mnemonic == mn and enc.mode == md) return enc.cycles;
        }
        for (isa.xtable) |enc| {
            if (enc.mnemonic == mn and enc.mode == md) return enc.cycles;
        }
    } else {
        for (isa.table) |enc| {
            if (enc.mnemonic == mn and (enc.mode == .impl or enc.mode == .acc)) return enc.cycles;
        }
        for (isa.xtable) |enc| {
            if (enc.mnemonic == mn and (enc.mode == .impl or enc.mode == .acc)) return enc.cycles;
        }
    }
    var worst: u64 = 0;
    for (isa.table) |enc| {
        if (enc.mnemonic == mn) worst = @max(worst, enc.cycles);
    }
    for (isa.xtable) |enc| {
        if (enc.mnemonic == mn) worst = @max(worst, enc.cycles);
    }
    return worst;
}

/// The cycle charge for one emitted line of assembly. Labels, comments
/// and directives are free; an instruction costs what the ISA table says.
fn lineCost(full: []const u8) u64 {
    var line = full;
    if (line.len > 1 and line[0] == 'L') {
        var j: usize = 1;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j > 1 and j < line.len and line[j] == ':') line = line[j + 1 ..];
    }
    line = std.mem.trim(u8, line, " ");
    if (line.len == 0 or line[0] == ';' or line[0] == '.') return 0;
    var j: usize = 0;
    while (j < line.len and std.ascii.isAlphabetic(line[j])) j += 1;
    const word = line[0..j];
    if (word.len == 0 or word.len > 7) return 0;
    var buf: [8]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, word);
    const mn: isa.Mnemonic = if (std.mem.eql(u8, lower, "and"))
        .and_
    else
        std.meta.stringToEnum(isa.Mnemonic, lower) orelse return 0;
    var rest = std.mem.trim(u8, line[j..], " ");
    if (std.mem.indexOfScalar(u8, rest, ';')) |semi|
        rest = std.mem.trim(u8, rest[0..semi], " ");
    return cycFor(mn, operandMode(rest));
}

/// One accounted burst: init, or one handler body. `cost` excludes the
/// serve loop's dispatch overhead, which is added at check time.
const Burst = struct { line: usize, cost: u64, dyn: bool, is_init: bool, nbounded: usize };

/// One `bounded N { … }` as accounted: the declared budget against the
/// computed (or uncomputable) body cost.
const BoundedRec = struct { line: usize, n: u64, body_cost: u64, body_dyn: bool };

/// A `buf [N]u8` inside the generator: near-page offsets of the length
/// slot and the data slab.
const BufInfo = struct { len_slot: u16, data: u16, cap: u16 };


/// A registered region inside the generator: its descriptor slot, RAM
/// area, and the compile-time grant state.
const RegionInfo = struct {
    slot: u8,
    f64: bool,
    len: u16,
    area: u64,
    granted_anywhere: bool = false,
    locked: bool = false,
};

/// A ≤ 8-byte chunk of pre-packed struple bytes as the little-endian word
/// an immediate store lays down (byte 0 lands at the lowest address).
fn chunkWord(b: []const u8) u64 {
    var w: u64 = 0;
    const n = @min(b.len, 8);
    var i: usize = 0;
    while (i < n) : (i += 1) w |= @as(u64, b[i]) << @intCast(i * 8);
    return w;
}

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
    /// The `case handoff(h)` binding, live only inside that handler:
    /// `adopt` is the one statement that may name it.
    handoff_bind: ?[]const u8 = null,
    in_handler: bool = false,
    uses_timer: bool = false,
    uses_self: bool = false,
    /// This actor asks a device (A3.3): the loader must wire each
    /// answering device's reply window back at our RX ring.
    asks_devices: bool = false,
    timer_period: u64 = 0,
    spawn_count: u16 = 0,

    /// A1.3 accounting: running cycle total of everything emitted, the
    /// data-dependent flag for the burst in progress, the bursts and
    /// bounded declarations collected for the end-of-emit check, and the
    /// strictest watchdog any spawn site imposes on this actor (0 = none).
    cost: u64 = 0,
    cost_dyn: bool = false,
    bursts: std.ArrayList(Burst),
    brecs: std.ArrayList(BoundedRec),
    watchdog: u64 = 0,

    /// String literals staged after the code, one label each.
    strings: std.ArrayList(struct { label: usize, text: []const u8 }),

    // Near-page slot offsets, assigned in layout().
    slots: std.StringHashMap(u16),
    /// Live `let` bindings (Amendment 3): name → is-f64. A let's slot
    /// rides in `slots` like any binding; this map is what makes it a
    /// let — typed, immutable, and removed at its block's end.
    lets: std.StringHashMap(bool),
    /// Record-shaped variables (A3.4): name → its base slot and shape.
    records: std.StringHashMap(struct { base: u16, rec: *const Record }),
    /// Names a supervisor gave the children it spawned (`spawn W() as w`).
    /// Membership makes a name an actor endpoint for the dialect check —
    /// a spawned joe actor always takes messages, never raw bytes.
    child_caps: std.StringHashMap(void),
    /// Spawn index (declaration order) → the near slot holding that
    /// child's capability, for the named ones. What the loader stages.
    childcap_of: std.AutoHashMap(u16, u16),
    /// Every spawn statement in the actor, in canonical (lexical) order —
    /// the source of truth for spawn_count, record indices and SpawnOut.
    spawn_list: std.ArrayList(*const Stmt),
    /// A spawn statement → its record index, so a `SPWN` in a handler
    /// reads the same record slot the loader staged, regardless of the
    /// order the emitter happens to reach it (A4.8).
    spawn_idx: std.AutoHashMap(*const Stmt, u16),
    /// Consts staged so far: name → string label. Lazily registered on
    /// first use, so an unreferenced const costs an actor nothing.
    const_labels: std.StringHashMap(usize),
    off_w0: u16 = 0,
    /// How many bytes this delivery actually carried (completion word0's
    /// count field). A device's raw payload has no length byte — the
    /// fabric already counted it, so the count IS the framing (A3.3).
    off_dcount: u16 = 0,
    /// Set when a handler forwards a device reply's raw bytes: the serve
    /// loop then keeps the count for every delivery.
    needs_dcount: bool = false,
    off_ptr: u16 = 0,
    off_t: u16 = 0,
    off_acc: u16 = 0,
    off_fp: u16 = 0,
    off_ectx: u16 = 0,
    off_elife: u16 = 0,
    off_ecode: u16 = 0,
    off_tarmed: u16 = 0,
    off_elem: u16 = 0,
    /// `send self` ships through this slot: a capability to the actor's
    /// own RX ring, loader-staged (Amendment 1's self-send loop).
    off_self: u16 = 0,
    /// A4 movement 3: the window of this actor's supervisor — staged
    /// for spawned children, because the exit link already establishes
    /// that relationship and probate needs no other grantee.
    off_boss: u16 = 0,
    uses_boss: bool = false,
    /// Expression temporaries (item 4): a static near-page stack, depth
    /// known at compile time. Compiled code never touches SP after init —
    /// under the collapsed-register convention even the stack pointer is
    /// volatile across parks, so the stack is simply not used.
    off_tmp: u16 = 0,
    tdepth: u8 = 0,
    /// Tail masks for byte equality (A2): masks[k] = 2^(8k)−1 at
    /// off_masks + 8k, staged at init when the actor has any bufs — the
    /// ISA has no variable shifts, so the mask is a table lookup.
    off_masks: u16 = 0,
    /// Staging slab for vector literals in expression position.
    off_vlit: u16 = 0,
    /// The MAC comparator's argument/scratch slots (item 7) and state:
    /// one routine per distinct field offset, up to eight MACTAB slots.
    off_mc: u16 = 0,
    mac_candidates: usize = 0,
    mac_shapes: [8]u16 = @splat(0),
    mac_nshapes: usize = 0,
    mc_labels: [8]usize = @splat(0),
    /// First free near slot after the fixed layout — loop variables and
    /// bindings are handed out from here.
    next_slot: u16 = 0,
    /// RAM arrays: name → near slot holding the base pointer. Group
    /// params, array vars and regions all land here.
    arrays: std.StringHashMap(struct { ptr_slot: u16, area: u64, len: u16, f64: bool = false }),
    /// Registered regions (item 6): grantable RAM arrays with a
    /// descriptor. `locked` is the compile-time type-state — granted
    /// means inaccessible until the done/failed case rebinds.
    regions: std.StringHashMap(RegionInfo),
    /// Byte buffers (A2.1): near-page slab + length slot. The slab keeps
    /// 8 bytes of slack past capacity so unaligned word stores of partial
    /// appends land in owned ground.
    bufs: std.StringHashMap(BufInfo),
    /// `vec` variables (A1.4): 64-byte near-page slabs. Expressions pass
    /// through the V file; every statement loads and stores, so nothing
    /// wide ever needs to survive a park — the convention by construction.
    vecs: std.StringHashMap(u16),
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
        const start = self.out.items.len;
        self.out.writer().print(fmt ++ "\n", args) catch return Error.OutOfMemory;
        // A1.3: charge the line its ISA-table cycles as it is written.
        self.cost +|= lineCost(self.out.items[start .. self.out.items.len - 1]);
    }

    const BurstMark = struct { cost: u64, dyn: bool, nb: usize };

    fn beginBurst(self: *Gen) BurstMark {
        const m = BurstMark{ .cost = self.cost, .dyn = self.cost_dyn, .nb = self.brecs.items.len };
        self.cost_dyn = false;
        return m;
    }

    fn endBurst(self: *Gen, m: BurstMark, line: usize, is_init: bool) Error!void {
        self.bursts.append(.{
            .line = line,
            .cost = self.cost - m.cost,
            .dyn = self.cost_dyn,
            .is_init = is_init,
            .nbounded = self.brecs.items.len - m.nb,
        }) catch return Error.OutOfMemory;
        self.cost_dyn = m.dyn;
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

    /// What the endpoint behind a parameter IS (A4 movement 1), inferred
    /// from the system block — where the wiring already lives, so the
    /// language needs no new syntax. A device name resolves to its
    /// dialect; anything else is an actor, and actors take messages.
    /// `any` means the compiler cannot tell (the actor is uninstantiated,
    /// or instantiated inconsistently), and an unknown endpoint is
    /// checked by the RBC at run time instead — the compiler's check is
    /// the EARLY copy of the machine's, never the only one.
    fn targetDialect(self: *Gen, pname: []const u8) ring.Dialect {
        // A child a supervisor spawned and named is an actor: it takes
        // messages. The compiler knows this outright — no system-block
        // wiring to consult, because the child is born, not passed in.
        // `boss` is likewise always an actor (the supervisor).
        if (self.child_caps.contains(pname)) return .msg;
        if (std.mem.eql(u8, pname, "boss")) return .msg;
        const pidx = for (self.actor.params, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, pname)) break i;
        } else return .any;
        var seen: ring.Dialect = .any;
        for (self.prog.system) |*inst| {
            if (!std.mem.eql(u8, inst.actor, self.actor.name)) continue;
            if (pidx >= inst.args.len) continue;
            const arg = inst.args[pidx];
            if (arg != .ref) continue;
            const d = dialectOfInstance(self.prog, arg.ref);
            if (seen != .any and seen != d) return .any; // wired both ways
            seen = d;
        }
        return seen;
    }

    /// A raw send needs a raw sink: bytes at an actor would arrive as a
    /// message with a nonsense tag, and bytes at an asking device would
    /// have its word1 read as a reply window.
    fn requireRaw(self: *Gen, target: []const u8, line: usize) Error!void {
        const have = self.targetDialect(target);
        if (have == .any or have == .raw) return;
        if (have == .ask)
            return self.fail(line, "this endpoint is an asking device: raw bytes have nowhere to land (A4)", Error.Semantics);
        return self.fail(line, "this endpoint is an actor: it takes messages, not raw bytes (A4)", Error.Semantics);
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
            if (v.array > 0 or v.buf_cap > 0 or v.region_len > 0 or v.ty == .vec_) continue; // wide things get their own homes
            if (v.record) |rname| {
                // A record is named offsets: its fields take consecutive
                // near slots, and the variable names the first (A3.4).
                const rec = for (self.prog.records) |*r| {
                    if (std.mem.eql(u8, r.name, rname)) break r;
                } else return self.fail(0, "unknown record type", Error.Semantics);
                try self.slots.put(v.name, off);
                try self.records.put(v.name, .{ .base = off, .rec = rec });
                off += @intCast(8 * rec.fields.len);
                continue;
            }
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
        self.off_self = off + 80;
        self.off_boss = off + 96; // A4 m3: the executor's window (a child's supervisor)
        self.off_tmp = off + 88; // 4 slots
        self.off_masks = off + 120; // 8 slots (index k*8, k = 1..7)
        self.off_vlit = off + 184; // 64 B
        self.off_mc = off + 248; // 3 slots: arg, rem, X stash
        self.off_dcount = off + 272; // this delivery's byte count (A3.3)
        self.spawn_base = off + 280;
        for (self.actor.handlers) |h| {
            if (h == .after) {
                self.uses_timer = true;
                self.timer_period = h.after.n;
            }
        }
        // A1.3: the strictest watchdog any spawn site imposes on this
        // actor is the budget its bursts must fit (0 = nobody counting).
        // A spawn site can now be in a handler (A4.7), so both halves of
        // every other actor are scanned, not just its body.
        for (self.prog.actors) |a| {
            var sites = std.ArrayList(*const Stmt).init(self.arena);
            try collectSpawns(a.body, &sites);
            for (a.handlers) |*h| try collectSpawns(handlerBody(h), &sites);
            for (sites.items) |s| {
                if (!std.mem.eql(u8, s.spawn.actor, self.actor.name)) continue;
                if (s.spawn.watchdog == 0) continue;
                self.watchdog = if (self.watchdog == 0)
                    s.spawn.watchdog
                else
                    @min(self.watchdog, s.spawn.watchdog);
            }
        }
        // Canonical spawn order: the actor's body, then each handler's
        // body, recursing into nested blocks. This one walk fixes the
        // record index for every consumer — the emitter, the child-cap
        // slots, and the SpawnOut the loader reads — so a `SPWN` reads the
        // record slot that was staged for it no matter where it lives.
        try collectSpawns(self.actor.body, &self.spawn_list);
        for (self.actor.handlers) |*h| try collectSpawns(handlerBody(h), &self.spawn_list);
        self.spawn_count = @intCast(self.spawn_list.items.len);
        for (self.spawn_list.items, 0..) |s, k| try self.spawn_idx.put(s, @intCast(k));
        // A named child's capability lives after the spawn records: one
        // near slot per `spawn … as name`, holding the supervisor's window
        // to the child's RX ring. Unnamed spawns reserve nothing, so a
        // program that never names a child keeps its old near layout — the
        // exit-only supervisor is byte-for-byte what it was.
        var aoff: u16 = self.spawn_base + self.spawn_count * 48;
        for (self.spawn_list.items, 0..) |s, k| {
            if (s.spawn.bind) |name| {
                if (self.slots.contains(name))
                    return self.fail(s.spawn.line, "a spawned child's name is already in use", Error.Semantics);
                try self.slots.put(name, aoff); // `grant`/`send` resolve here
                try self.child_caps.put(name, {});
                try self.childcap_of.put(@intCast(k), aoff);
                aoff += 8;
            }
        }
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
        var next_region_slot: u8 = 8; // rings own 0..5; regions from 8
        for (self.actor.vars) |v| {
            if (v.region_len == 0) continue;
            try self.arrays.put(v.name, .{ .ptr_slot = aoff, .area = area, .len = v.region_len, .f64 = v.region_f64 });
            try self.regions.put(v.name, .{ .slot = next_region_slot, .f64 = v.region_f64, .len = v.region_len, .area = area });
            next_region_slot += 1;
            aoff += 8;
            area += @as(u64, v.region_len) * 8;
        }
        for (self.actor.vars) |v| {
            if (v.buf_cap == 0) continue;
            try self.bufs.put(v.name, .{ .len_slot = aoff, .data = aoff + 8, .cap = v.buf_cap });
            aoff += 8 + std.mem.alignForward(u16, v.buf_cap + 8, 8);
            if (@as(u32, aoff) + 8 > isa.mactab_base)
                return self.fail(0, "near page exhausted (buffers)", Error.Semantics);
        }
        for (self.actor.vars) |v| {
            if (v.ty != .vec_) continue;
            try self.vecs.put(v.name, aoff);
            aoff += 64;
            if (@as(u32, aoff) + 8 > isa.mactab_base)
                return self.fail(0, "near page exhausted (vectors)", Error.Semantics);
        }
        self.next_slot = aoff;
        if (abi.array_off + area > abi.block_size - abi.data_off - 0x400)
            return self.fail(0, "arrays overflow the instance block", Error.Semantics);
        // Can any answer this system speaks carry a raw payload? Then
        // every delivery keeps its count (A3.3) — four instructions in
        // the dispatcher, and only for actors in device conversations.
        for (self.prog.messages) |*m| {
            if (!m.is_reply) continue;
            if (m.fields.len > 0 and m.fields[m.fields.len - 1].ty == .bytes_)
                self.needs_dcount = true;
        }
        if (self.layout.mac) {
            self.mac_candidates = self.countBufEq();
            if (self.mac_candidates >= 2) try self.prescanMacShapes();
        }
        // which regions ever leave home (the grant prescan)
        {
            var rit = self.regions.iterator();
            while (rit.next()) |e| {
                var granted = bodyGrants(self.actor.body, e.key_ptr.*);
                for (self.actor.handlers) |h| {
                    const body = switch (h) {
                        .case => |c| c.body,
                        .after => |a| a.body,
                        .exit_case => |x| x.body,
                        .handoff_case => |x| x.body,
                    };
                    if (bodyGrants(body, e.key_ptr.*)) granted = true;
                }
                e.value_ptr.granted_anywhere = granted;
            }
        }
        self.has_quiesce = self.actor.quiesce.len > 0 or anyQuiesce(self.actor.body) or blk: {
            for (self.actor.handlers) |h| {
                const body = switch (h) {
                    .case => |c| c.body,
                    .after => |a| a.body,
                    .exit_case => |e| e.body,
                    .handoff_case => |e| e.body,
                };
                if (anyQuiesce(body)) break :blk true;
            }
            break :blk false;
        };
    }

    /// Does anything in this program hand a capability on? If so, the
    /// wire is NOT closed: the RBC becomes a sender that no `message`
    /// declaration describes, and the sole-case elision below loses its
    /// precondition. Whole-program, because the grantor is somebody
    /// else's source — an heir cannot know locally that it is an heir.
    fn programGrants(prog: *const Program) bool {
        for (prog.actors) |*a| {
            if (anyGrantIn(a.body)) return true;
            for (a.handlers) |h| {
                const body = switch (h) {
                    .case => |c| c.body,
                    .after => |t| t.body,
                    .exit_case => |e| e.body,
                    .handoff_case => |e| e.body,
                };
                if (anyGrantIn(body)) return true;
            }
            for (a.quiesce) |h| if (anyGrantIn(h.case.body)) return true;
        }
        return false;
    }

    fn anyGrantIn(list: []const Stmt) bool {
        for (list) |s| {
            switch (s) {
                .grant_ => return true,
                .send => |sd| for (sd.args) |a| {
                    if (a.* == .grantref) return true;
                },
                .if_ => |i| if (anyGrantIn(i.then) or anyGrantIn(i.els)) return true,
                .bounded => |b| if (anyGrantIn(b.body)) return true,
                .for_range => |f| if (anyGrantIn(f.body)) return true,
                .for_group => |f| if (anyGrantIn(f.body)) return true,
                else => {},
            }
        }
        return false;
    }

    /// The body of any handler kind — every one carries statements.
    fn handlerBody(h: *const Handler) []Stmt {
        return switch (h.*) {
            .case => |c| c.body,
            .after => |a| a.body,
            .exit_case => |e| e.body,
            .handoff_case => |x| x.body,
        };
    }

    /// Every `spawn` in a statement list, in lexical order, as stable
    /// pointers into the arena — recursing into nested blocks so a spawn
    /// buried in an `if` or a `for` is still counted. Amendment 4.8's
    /// dynamic spawn: a spawn may live in a handler now, not only in the
    /// actor body, so the record index a `SPWN` reads must be assigned by
    /// identity (the statement pointer) rather than by emission order,
    /// which threads through region dispatch, the case ladder and the
    /// timer body in a sequence no single walk reproduces.
    fn collectSpawns(list: []const Stmt, out: *std.ArrayList(*const Stmt)) Error!void {
        for (list) |*s| {
            switch (s.*) {
                .spawn => out.append(s) catch return Error.OutOfMemory,
                .if_ => |i| {
                    try collectSpawns(i.then, out);
                    try collectSpawns(i.els, out);
                },
                .bounded => |b| try collectSpawns(b.body, out),
                .for_range => |f| try collectSpawns(f.body, out),
                .for_group => |f| try collectSpawns(f.body, out),
                else => {},
            }
        }
    }

    /// Does this statement list grant the named region anywhere?
    fn bodyGrants(list: []const Stmt, name: []const u8) bool {
        for (list) |s| {
            switch (s) {
                .send => |sd| for (sd.args) |a| {
                    if (a.* == .grantref and std.mem.eql(u8, a.grantref, name)) return true;
                },
                .grant_ => |g| if (std.mem.eql(u8, g.region, name)) return true,
                .if_ => |i| if (bodyGrants(i.then, name) or bodyGrants(i.els, name)) return true,
                .bounded => |b| if (bodyGrants(b.body, name)) return true,
                .for_range => |f| if (bodyGrants(f.body, name)) return true,
                .for_group => |f| if (bodyGrants(f.body, name)) return true,
                else => {},
            }
        }
        return false;
    }

    /// The §6.2 type-state, per burst (v1's conservative shape): a
    /// granted-anywhere region is reachable in a handler only BEFORE
    /// that handler's own grant of it, and inside its done/failed case
    /// (the rebind). Every other handler must keep its hands off — it
    /// may run while the region is hardware-owned.
    fn setRegionLocks(self: *Gen, body: []const Stmt, rebind: ?[]const u8) void {
        var it = self.regions.iterator();
        while (it.next()) |e| {
            const rp = e.value_ptr;
            if (!rp.granted_anywhere) {
                rp.locked = false;
                continue;
            }
            if (rebind) |rb| {
                if (std.mem.eql(u8, rb, e.key_ptr.*)) {
                    rp.locked = false;
                    continue;
                }
            }
            rp.locked = !bodyGrants(body, e.key_ptr.*);
        }
    }

    /// Item 7: collect the comparator shapes — every distinct bytes-field
    /// offset that a buf compares against, one MACTAB slot each (≤ 8;
    /// beyond that a site simply inlines). Runs with each case's binding
    /// in scope so field offsets resolve exactly as codegen will see them.
    fn prescanMacShapes(self: *Gen) Error!void {
        for (self.actor.handlers) |h| {
            if (h != .case) continue;
            const c = h.case;
            self.bind = c.bind;
            self.bind_msg = self.message(c.msg);
            if (c.where) |g| self.collectShapes(g);
            self.collectShapesIn(c.body);
            self.bind = null;
            self.bind_msg = null;
        }
        for (self.actor.quiesce) |h| {
            const c = h.case;
            self.bind = c.bind;
            self.bind_msg = self.message(c.msg);
            if (c.where) |g| self.collectShapes(g);
            self.collectShapesIn(c.body);
            self.bind = null;
            self.bind_msg = null;
        }
        for (0..self.mac_nshapes) |i| self.mc_labels[i] = self.label();
    }

    fn collectShapesIn(self: *Gen, list: []const Stmt) void {
        for (list) |st| {
            switch (st) {
                .if_ => |i| {
                    self.collectShapes(i.cond);
                    self.collectShapesIn(i.then);
                    self.collectShapesIn(i.els);
                },
                .bounded => |b| self.collectShapesIn(b.body),
                .for_range => |f| self.collectShapesIn(f.body),
                .for_group => |f| self.collectShapesIn(f.body),
                else => {},
            }
        }
    }

    fn collectShapes(self: *Gen, e: *const Expr) void {
        if (e.* != .bin) return;
        const b = e.bin;
        if (b.op == .land) {
            self.collectShapes(b.l);
            self.collectShapes(b.r);
            return;
        }
        if (b.op != .eq and b.op != .ne) return;
        const sa = self.byteSubject(b.l) orelse return;
        const sb = self.byteSubject(b.r) orelse return;
        const foff: u16 = if (sa == .field and sb == .buf)
            sa.field
        else if (sb == .field and sa == .buf)
            sb.field
        else
            return;
        for (self.mac_shapes[0..self.mac_nshapes]) |f| {
            if (f == foff) return;
        }
        if (self.mac_nshapes < 8) {
            self.mac_shapes[self.mac_nshapes] = foff;
            self.mac_nshapes += 1;
        }
    }

    /// Item 7's reuse census: how many conditions compare a buf with
    /// something byte-shaped? Two or more make the shared comparator
    /// worth a MACTAB slot.
    fn countBufEq(self: *Gen) usize {
        var n: usize = 0;
        n += self.countBufEqIn(self.actor.body);
        for (self.actor.handlers) |h| {
            switch (h) {
                .case => |c| {
                    if (c.where) |g| n += self.condBufEq(g);
                    n += self.countBufEqIn(c.body);
                },
                .after => |a| n += self.countBufEqIn(a.body),
                .exit_case => |x| n += self.countBufEqIn(x.body),
                .handoff_case => |x| n += self.countBufEqIn(x.body),
            }
        }
        for (self.actor.quiesce) |h| {
            if (h.case.where) |g| n += self.condBufEq(g);
            n += self.countBufEqIn(h.case.body);
        }
        return n;
    }

    fn countBufEqIn(self: *Gen, list: []const Stmt) usize {
        var n: usize = 0;
        for (list) |st| {
            switch (st) {
                .if_ => |i| {
                    n += self.condBufEq(i.cond);
                    n += self.countBufEqIn(i.then);
                    n += self.countBufEqIn(i.els);
                },
                .bounded => |b| n += self.countBufEqIn(b.body),
                .for_range => |f| n += self.countBufEqIn(f.body),
                .for_group => |f| n += self.countBufEqIn(f.body),
                else => {},
            }
        }
        return n;
    }

    fn condBufEq(self: *Gen, e: *const Expr) usize {
        if (e.* != .bin) return 0;
        const b = e.bin;
        if (b.op == .land) return self.condBufEq(b.l) + self.condBufEq(b.r);
        if (b.op != .eq and b.op != .ne) return 0;
        const lbuf = b.l.* == .ident and self.bufs.contains(b.l.ident);
        const rbuf = b.r.* == .ident and self.bufs.contains(b.r.ident);
        return if (lbuf or rbuf) 1 else 0;
    }

    /// A `case done(r)` / `case failed(r)` where r names a region — the
    /// grant-completion cases, routed by the architected $6772 tag.
    fn isRegionCase(self: *Gen, c: anytype) bool {
        if (c.bind == null) return false;
        if (!std.mem.eql(u8, c.msg, "done") and !std.mem.eql(u8, c.msg, "failed")) return false;
        return self.regions.contains(c.bind.?);
    }

    fn actorPacksInto(self: *const Gen, name: []const u8) bool {
        if (packsInto(self.actor.body, name)) return true;
        for (self.actor.handlers) |h| {
            const body = switch (h) {
                .case => |c| c.body,
                .after => |a| a.body,
                .exit_case => |e| e.body,
                .handoff_case => |e| e.body,
            };
            if (packsInto(body, name)) return true;
        }
        for (self.actor.quiesce) |h| {
            if (packsInto(h.case.body, name)) return true;
        }
        return false;
    }

    fn packsInto(list: []const Stmt, name: []const u8) bool {
        for (list) |s| {
            switch (s) {
                .pack => |p| if (std.mem.eql(u8, p.buf, name)) return true,
                .copy_ => |c| if (std.mem.eql(u8, c.dst, name)) return true,
                .if_ => |i| if (packsInto(i.then, name) or packsInto(i.els, name)) return true,
                .bounded => |b| if (packsInto(b.body, name)) return true,
                .for_range => |f| if (packsInto(f.body, name)) return true,
                .for_group => |f| if (packsInto(f.body, name)) return true,
                else => {},
            }
        }
        return false;
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

    /// `anim.index` — the near slot a record field lives in (A3.4), or
    /// null when this isn't a record access at all.
    fn recordSlot(self: *Gen, base: []const u8, field: []const u8) ?u16 {
        const r = self.records.get(base) orelse return null;
        for (r.rec.fields, 0..) |*f, i| {
            if (std.mem.eql(u8, f.name, field)) return r.base + @as(u16, @intCast(i * 8));
        }
        return null;
    }

    /// The label of a `const`'s staged bytes, registered on first use.
    fn constLabel(self: *Gen, name: []const u8) Error!?usize {
        if (self.const_labels.get(name)) |l| return l;
        for (self.prog.consts) |c| {
            if (std.mem.eql(u8, c.name, name)) {
                const lbl = self.label();
                try self.strings.append(.{ .label = lbl, .text = c.text });
                try self.const_labels.put(name, lbl);
                return lbl;
            }
        }
        return null;
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

    /// A value that can be an operand directly — a literal (imm) or a
    /// scalar near-page slot — so binary ops and compares skip the
    /// evaluate-spill-reload dance entirely (item 4: registers are free
    /// within a burst; the near page is for state that crosses parks).
    /// `imm64` is a value that must never take the sign-extending imm8
    /// form — f64 bits, chiefly.
    const Operand = union(enum) { imm: u64, imm64: u64, slot: u16 };

    /// The static type of an expression (A1.4's minimal discipline: f64
    /// and vec never mix with integers silently).
    fn exprType(self: *Gen, e: *const Expr) Type {
        switch (e.*) {
            .int => return .u64_,
            .float => return .f64_,
            .vlit, .permute => return .vec_,
            .reduce => return .f64_,
            .cast => |c| return if (c.to_f64) .f64_ else .u64_,
            .count, .grantref, .paylen => return .u64_,
            .index => |ix| {
                if (self.arrays.get(ix.base)) |arr| {
                    if (arr.f64) return .f64_;
                }
                return .u64_;
            },
            .ident => |name| {
                if (self.vecs.contains(name)) return .vec_;
                if (self.lets.get(name)) |isf| return if (isf) .f64_ else .u64_;
                for (self.actor.params) |p| {
                    if (std.mem.eql(u8, p.name, name)) return p.ty;
                }
                for (self.actor.vars) |v| {
                    if (std.mem.eql(u8, v.name, name)) return v.ty;
                }
                return .u64_; // loop vars, pattern binds, internals
            },
            .field => |fx| {
                if (self.bind != null and std.mem.eql(u8, self.bind.?, fx.base)) {
                    if (self.bind_msg) |m| {
                        for (m.fields) |*fl| {
                            if (std.mem.eql(u8, fl.name, fx.name)) return fl.ty;
                        }
                    }
                }
                return .u64_;
            },
            .bin => |b| {
                const lt = self.exprType(b.l);
                const rt = self.exprType(b.r);
                if (lt == .vec_ or rt == .vec_) return .vec_;
                if (lt == .f64_ or rt == .f64_) return .f64_;
                return .u64_;
            },
        }
    }

    /// Evaluate a scalar in float context: an int literal promotes to its
    /// f64 value at compile time; everything else must already be f64.
    fn evalFloatScalar(self: *Gen, e: *const Expr) Error!void {
        if (e.* == .int) {
            try self.w("        LDA ##${X}", .{@as(u64, @bitCast(@as(f64, @floatFromInt(e.int))))});
            return;
        }
        if (self.exprType(e) != .f64_)
            return self.fail(0, "mixing integers and floats wants an explicit f64()/int()", Error.Semantics);
        try self.evalInto(e);
    }

    fn simpleOperandF(self: *Gen, e: *const Expr) ?Operand {
        switch (e.*) {
            .float => |b| return .{ .imm64 = b },
            .int => |v| return .{ .imm64 = @bitCast(@as(f64, @floatFromInt(v))) },
            .ident => |name| {
                if (self.exprType(e) != .f64_) return null;
                if (self.slots.get(name)) |s| return .{ .slot = s };
                return null;
            },
            else => return null,
        }
    }

    /// Float binary arithmetic: A ⟵ A op M through the Tier 0 ops — no
    /// carry discipline, no masks, IEEE the whole way.
    fn floatBin(self: *Gen, b: anytype) Error!void {
        const mn: []const u8 = switch (b.op) {
            .add => "FADD",
            .sub => "FSUB",
            .mul => "FMUL",
            .div => "FDIV",
            else => return self.fail(0, "float ops are + - * / (v1)", Error.Semantics),
        };
        if (self.simpleOperandF(b.r)) |opr| {
            try self.evalFloatScalar(b.l);
            try self.opSimpleRt(mn, opr);
            return;
        }
        const tmp = try self.pushTmp();
        try self.evalFloatScalar(b.r);
        try self.w("        STA ${X}", .{tmp});
        try self.evalFloatScalar(b.l);
        try self.w("        {s} ${X}", .{ mn, tmp });
        self.popTmp();
    }

    fn opSimpleRt(self: *Gen, mn: []const u8, opr: Operand) Error!void {
        switch (opr) {
            .imm => |v| try self.w("        {s} {s}", .{ mn, try self.imm(v) }),
            .imm64 => |v| try self.w("        {s} ##${X}", .{ mn, v }),
            .slot => |s| try self.w("        {s} ${X}", .{ mn, s }),
        }
    }

    /// Evaluate a vector expression into V[d] (A1.4). Every leaf loads
    /// from the near page and every statement stores back — the V file
    /// is burst scratch by construction, exactly as volatile as A.
    fn vecEvalInto(self: *Gen, e: *const Expr, d: u8) Error!void {
        if (d > 6)
            return self.fail(0, "vector expression too deep (v1)", Error.Unsupported);
        switch (e.*) {
            .ident => |name| {
                const slab = self.vecs.get(name) orelse
                    return self.fail(0, "not a vec variable", Error.Semantics);
                try self.w("        LDX {s}", .{try self.imm(slab)});
                try self.w("        VLD {d}", .{d});
            },
            .vlit => |lanes| {
                for (lanes, 0..) |bits, i| {
                    try self.w("        LDA ##${X}", .{bits});
                    try self.w("        STA ${X}", .{self.off_vlit + i * 8});
                }
                try self.w("        LDX {s}", .{try self.imm(self.off_vlit)});
                try self.w("        VLD {d}", .{d});
            },
            .permute => |p| {
                try self.vecEvalInto(p.base, d);
                try self.w("        LDA ##${X}", .{p.mask});
                try self.w("        VPERM {d}, {d}", .{ d, d });
            },
            .bin => |b| {
                const mn: []const u8 = switch (b.op) {
                    .add => "VFADD",
                    .sub => "VFSUB",
                    .mul => "VFMUL",
                    .div => "VFDIV",
                    else => return self.fail(0, "vec ops are + - * / (v1; masks ride with their first workload)", Error.Unsupported),
                };
                const lt = self.exprType(b.l);
                const rt = self.exprType(b.r);
                if (lt == .vec_ and rt == .vec_) {
                    try self.vecEvalInto(b.l, d);
                    try self.vecEvalInto(b.r, d + 1);
                } else if (lt == .vec_) {
                    try self.vecEvalInto(b.l, d);
                    try self.evalFloatScalar(b.r);
                    try self.w("        VBCA {d}", .{d + 1});
                } else {
                    try self.evalFloatScalar(b.l);
                    try self.w("        VBCA {d}", .{d});
                    try self.vecEvalInto(b.r, d + 1);
                }
                try self.w("        {s} {d}, {d}", .{ mn, d, d + 1 });
            },
            else => return self.fail(0, "not a vector expression", Error.Semantics),
        }
    }

    /// Store a vector expression into a slab — a literal writes straight
    /// through, anything else rides V0.
    fn storeVec(self: *Gen, slab: u16, e: *const Expr) Error!void {
        if (e.* == .vlit) {
            for (e.vlit, 0..) |bits, i| {
                try self.w("        LDA ##${X}", .{bits});
                try self.w("        STA ${X}", .{slab + i * 8});
            }
            return;
        }
        if (self.exprType(e) != .vec_) {
            // `v = 2.0` — a scalar broadcast assignment
            try self.evalFloatScalar(e);
            try self.w("        VBCA 0", .{});
        } else {
            try self.vecEvalInto(e, 0);
        }
        try self.w("        LDX {s}", .{try self.imm(slab)});
        try self.w("        VST 0", .{});
    }

    fn simpleOperand(self: *Gen, e: *const Expr) ?Operand {
        switch (e.*) {
            .int => |v| return .{ .imm = v },
            .ident => |name| {
                if (self.exit_code_bind != null and std.mem.eql(u8, self.exit_code_bind.?, name))
                    return .{ .slot = self.off_ecode };
                if (self.bind != null and std.mem.eql(u8, self.bind.?, name)) return null;
                if (self.exit_bind != null and std.mem.eql(u8, self.exit_bind.?, name)) return null;
                if (self.slots.get(name)) |s| return .{ .slot = s };
                return null;
            },
            else => return null,
        }
    }

    /// Emit `MNEM <operand>` for a simple operand: `#v`, `##$V` or `$slot`.
    fn opSimple(self: *Gen, comptime mnem: []const u8, opr: Operand) Error!void {
        switch (opr) {
            .imm => |v| try self.w("        " ++ mnem ++ " {s}", .{try self.imm(v)}),
            .imm64 => |v| try self.w("        " ++ mnem ++ " ##${X}", .{v}),
            .slot => |s| try self.w("        " ++ mnem ++ " ${X}", .{s}),
        }
    }

    /// A static temp slot for the current expression depth. Depth > 4
    /// would need a fifth slot; v1 rejects it honestly.
    fn pushTmp(self: *Gen) Error!u16 {
        if (self.tdepth >= 4)
            return self.fail(0, "expression too deep (v1 nests four temporaries)", Error.Unsupported);
        const s = self.off_tmp + @as(u16, self.tdepth) * 8;
        self.tdepth += 1;
        return s;
    }

    fn popTmp(self: *Gen) void {
        self.tdepth -= 1;
    }

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
                // A3.2: byte indexing over bufs and consts — one byte,
                // zero-extended. Arrays keep their word semantics.
                if (self.bufs.get(ix.base)) |bi| {
                    try self.evalInto(ix.idx);
                    try self.w("        STA ${X}", .{self.off_t});
                    try self.w("        LDX ${X}", .{self.off_t});
                    try self.w("        LDA ${X},X", .{bi.data});
                    try self.w("        AND #$FF", .{});
                    return;
                }
                if (try self.constLabel(ix.base)) |lbl| {
                    try self.evalInto(ix.idx);
                    try self.w("        CLC", .{});
                    try self.w("        ADC ##L{d}", .{lbl});
                    try self.w("        STA ${X}", .{self.off_t});
                    try self.w("        LDA (${X})", .{self.off_t});
                    try self.w("        AND #$FF", .{});
                    return;
                }
                const arr = self.arrays.get(ix.base) orelse
                    return self.fail(0, "not an array, buf, const or group", Error.Semantics);
                if (self.regions.get(ix.base)) |r| {
                    if (r.locked)
                        return self.fail(0, "a granted region is inaccessible until done/failed rebinds it (§6.2)", Error.Semantics);
                }
                try self.evalInto(ix.idx);
                try self.w("        ASL #3", .{});
                try self.w("        TAY", .{});
                try self.w("        LDA (${X}),Y", .{arr.ptr_slot});
            },
            .paylen => |px| {
                const bind = self.bind orelse
                    return self.fail(0, "a payload length needs a case binding", Error.Semantics);
                if (!std.mem.eql(u8, bind, px.base))
                    return self.fail(0, "field base is not the case binding", Error.Semantics);
                const bmsg = self.bind_msg.?;
                if (!bmsg.is_reply)
                    return self.fail(0, "`.len` is a device reply's payload count (A3.3)", Error.Semantics);
                const fld = for (bmsg.fields) |*fl| {
                    if (std.mem.eql(u8, fl.name, px.name)) break fl;
                } else return self.fail(0, "no such field in the reply", Error.Semantics);
                if (fld.ty != .bytes_)
                    return self.fail(0, "`.len` measures a bytes payload", Error.Semantics);
                self.needs_dcount = true;
                try self.w("        LDA ${X}", .{self.off_dcount});
                try self.w("        SEC", .{});
                try self.w("        SBC #{d}", .{fld.offset});
            },
            .count => |bname| {
                const bi = self.bufs.get(bname) orelse
                    return self.fail(0, "`.count()` walks a buf", Error.Semantics);
                try self.emitCount(bi);
                // element counts are data — A1.3's rules apply in full
                self.cost_dyn = true;
            },
            .float => |bits| try self.w("        LDA ##${X}", .{bits}),
            .cast => |c| {
                if (c.to_f64) {
                    if (self.exprType(c.e) == .f64_)
                        return self.fail(0, "f64() of a float is already one", Error.Semantics);
                    try self.evalInto(c.e);
                    try self.w("        ITOF", .{});
                } else {
                    try self.evalFloatScalar(c.e);
                    try self.w("        FTOI", .{});
                }
            },
            .reduce => |r| {
                try self.vecEvalInto(r.base, 0);
                try self.w("        {s} 0", .{switch (r.op) {
                    .sum => @as([]const u8, "VRADD"),
                    .max => "VRMAX",
                    .min => "VRMIN",
                }});
            },
            .vlit, .permute => return self.fail(0, "a vector value needs a vec home", Error.Semantics),
            .grantref => return self.fail(0, "`grant` rides inside a send's braces", Error.Semantics),
            .field => |f| {
                if (self.recordSlot(f.base, f.name)) |slot| {
                    try self.w("        LDA ${X}", .{slot});
                    return;
                }
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
                if (fld.ty == .bytes_)
                    return self.fail(0, "a bytes field is matched with `is` or forwarded whole (v1)", Error.Semantics);
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
                    .mul, .div => {
                        if (self.exprType(e) == .vec_)
                            return self.fail(0, "a vector value needs a vec home", Error.Semantics);
                        if (self.exprType(e) != .f64_)
                            return self.fail(0, "no integer × or ÷ in the machine — shift-add, or take it to f64", Error.Unsupported);
                        try self.floatBin(b);
                    },
                    .shl, .shr => {
                        // Counted shifts want a constant count.
                        if (b.r.* != .int)
                            return self.fail(0, "shift count must be a literal (v1)", Error.Unsupported);
                        try self.evalInto(b.l);
                        const mn: []const u8 = if (b.op == .shl) "ASL" else "LSR";
                        try self.w("        {s} #{d}", .{ mn, b.r.int });
                    },
                    .add, .sub, .band, .bor, .bxor => {
                        const t = self.exprType(e);
                        if (t == .vec_)
                            return self.fail(0, "a vector value needs a vec home", Error.Semantics);
                        if (t == .f64_) {
                            if (b.op != .add and b.op != .sub)
                                return self.fail(0, "bitwise ops are integer ops", Error.Semantics);
                            try self.floatBin(b);
                            return;
                        }
                        if (self.simpleOperand(b.r)) |opr| {
                            // A = l, then one direct-operand instruction.
                            try self.evalInto(b.l);
                            switch (b.op) {
                                .add => {
                                    try self.w("        CLC", .{});
                                    try self.opSimple("ADC", opr);
                                },
                                .sub => {
                                    try self.w("        SEC", .{});
                                    try self.opSimple("SBC", opr);
                                },
                                .band => try self.opSimple("AND", opr),
                                .bor => try self.opSimple("ORA", opr),
                                .bxor => try self.opSimple("EOR", opr),
                                else => unreachable,
                            }
                            return;
                        }
                        // Complex right side: r first into a static temp,
                        // then l in A against it (evaluation is pure, so
                        // the reorder is free — and the stack stays cold).
                        const tmp = try self.pushTmp();
                        try self.evalInto(b.r);
                        try self.w("        STA ${X}", .{tmp});
                        try self.evalInto(b.l);
                        switch (b.op) {
                            .add => {
                                try self.w("        CLC", .{});
                                try self.w("        ADC ${X}", .{tmp});
                            },
                            .sub => {
                                try self.w("        SEC", .{});
                                try self.w("        SBC ${X}", .{tmp});
                            },
                            .band => try self.w("        AND ${X}", .{tmp}),
                            .bor => try self.w("        ORA ${X}", .{tmp}),
                            .bxor => try self.w("        EOR ${X}", .{tmp}),
                            else => unreachable,
                        }
                        self.popTmp();
                    },
                }
            },
        }
    }

    /// A byte-comparable subject: a local buf, or the bound message's
    /// bytes field (as its landing-buffer offset).
    const ByteSubj = union(enum) { buf: BufInfo, field: u16 };

    fn byteSubject(self: *Gen, e: *const Expr) ?ByteSubj {
        switch (e.*) {
            .ident => |name| {
                if (self.bufs.get(name)) |bi| return .{ .buf = bi };
                return null;
            },
            .field => |fx| {
                if (self.bind == null or !std.mem.eql(u8, self.bind.?, fx.base)) return null;
                const m = self.bind_msg orelse return null;
                for (m.fields) |*fl| {
                    if (std.mem.eql(u8, fl.name, fx.name))
                        return if (fl.ty == .bytes_) .{ .field = fl.offset } else null;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Byte equality (A2, the store's comparator): lengths first, then
    /// whole words, then the tail word under a mask-table mask (the ISA
    /// has no variable shifts, so the mask is a lookup). Branches to
    /// `l_diff` on any difference; falls through equal.
    fn emitByteCmp(self: *Gen, a: ByteSubj, b: ByteSubj, l_diff: usize) Error!void {
        const t_rem = try self.pushTmp();
        var tmps: u8 = 1;
        defer while (tmps > 0) : (tmps -= 1) self.popTmp();
        const pa: ?u16 = if (a == .field) blk: {
            tmps += 1;
            break :blk try self.pushTmp();
        } else null;
        const pb: ?u16 = if (b == .field) blk: {
            tmps += 1;
            break :blk try self.pushTmp();
        } else null;
        const any_buf = a == .buf or b == .buf;
        const t_x: ?u16 = if (any_buf) blk: {
            tmps += 1;
            break :blk try self.pushTmp();
        } else null;

        try self.w("; byte equality: lengths, words, masked tail", .{});
        // field pointers at the length byte
        if (pa) |p| {
            try self.w("        LDA ${X}", .{self.off_ptr});
            try self.w("        CLC", .{});
            try self.w("        ADC {s}", .{try self.imm(a.field)});
            try self.w("        STA ${X}", .{p});
        }
        if (pb) |p| {
            try self.w("        LDA ${X}", .{self.off_ptr});
            try self.w("        CLC", .{});
            try self.w("        ADC {s}", .{try self.imm(b.field)});
            try self.w("        STA ${X}", .{p});
        }
        // lengths
        switch (a) {
            .buf => |bi| try self.w("        LDA ${X}", .{bi.len_slot}),
            .field => {
                try self.w("        LDA (${X})", .{pa.?});
                try self.w("        AND #$FF", .{});
            },
        }
        try self.w("        STA ${X}", .{t_rem});
        switch (b) {
            .buf => |bi| try self.w("        LDA ${X}", .{bi.len_slot}),
            .field => {
                try self.w("        LDA (${X})", .{pb.?});
                try self.w("        AND #$FF", .{});
            },
        }
        try self.w("        CMP ${X}", .{t_rem});
        try self.w("        BNE L{d}", .{l_diff});
        // advance field pointers past the length byte
        if (pa) |p| try self.w("        INC ${X}", .{p});
        if (pb) |p| try self.w("        INC ${X}", .{p});
        if (any_buf) try self.w("        LDX #0", .{});
        const l_w = self.label();
        const l_tail = self.label();
        const l_done = self.label();
        const c_loop = self.cost;
        try self.w("L{d}:   LDA ${X}", .{ l_w, t_rem });
        try self.w("        CMP #8", .{});
        try self.w("        BCC L{d}", .{l_tail});
        try self.loadSide(a, pa);
        try self.w("        STA ${X}", .{self.off_t});
        try self.loadSide(b, pb);
        try self.w("        CMP ${X}", .{self.off_t});
        try self.w("        BNE L{d}", .{l_diff});
        if (any_buf) {
            try self.w("        TXA", .{});
            try self.w("        CLC", .{});
            try self.w("        ADC #8", .{});
            try self.w("        TAX", .{});
        }
        if (pa) |p| try self.bumpPtr(p);
        if (pb) |p| try self.bumpPtr(p);
        try self.w("        LDA ${X}", .{t_rem});
        try self.w("        SEC", .{});
        try self.w("        SBC #8", .{});
        try self.w("        STA ${X}", .{t_rem});
        try self.w("        BRA L{d}", .{l_w});
        // A1.3: bufs cap at 1024 → at most 128 word laps.
        self.cost +|= (self.cost - c_loop) *| 127;
        try self.w("L{d}:   LDA ${X}", .{ l_tail, t_rem });
        try self.w("        BEQ L{d}", .{l_done});
        if (t_x) |tx| {
            try self.w("        TXA", .{});
            try self.w("        STA ${X}", .{tx});
        }
        try self.w("        LDA ${X}", .{t_rem});
        try self.w("        ASL #3", .{});
        try self.w("        TAX", .{});
        try self.w("        LDA ${X},X", .{self.off_masks});
        try self.w("        STA ${X}", .{self.off_acc});
        if (t_x) |tx| try self.w("        LDX ${X}", .{tx});
        try self.loadSide(a, pa);
        try self.w("        AND ${X}", .{self.off_acc});
        try self.w("        STA ${X}", .{self.off_t});
        try self.loadSide(b, pb);
        try self.w("        AND ${X}", .{self.off_acc});
        try self.w("        CMP ${X}", .{self.off_t});
        try self.w("        BNE L{d}", .{l_diff});
        try self.w("L{d}:", .{l_done});
    }

    /// Item 7: the shared comparators, one per field shape. In: _mc
    /// holds the buf's len-slot offset (its slab is the adjacent 8).
    /// Out: A = 0 equal, 1 different — the verdict, with Z telling it.
    fn emitMacComparator(self: *Gen) Error!void {
        for (0..self.mac_nshapes) |i| {
            try self.emitOneComparator(self.mc_labels[i], self.mac_shapes[i]);
        }
    }

    fn emitOneComparator(self: *Gen, entry_label: usize, foff: u16) Error!void {
        const rem = self.off_mc + 8;
        const txs = self.off_mc + 16;
        const l_w = self.label();
        const l_tail = self.label();
        const l_eq = self.label();
        const l_diff = self.label();
        try self.w("; MAC: byte equality, buf(arg) vs the bytes field at +{d}", .{foff});
        try self.w("L{d}:   LDX ${X}", .{ entry_label, self.off_mc });
        try self.w("        LDA $0,X", .{});
        try self.w("        STA ${X}", .{rem});
        try self.w("        LDA ${X}", .{self.off_ptr});
        try self.w("        CLC", .{});
        try self.w("        ADC {s}", .{try self.imm(foff)});
        try self.w("        STA ${X}", .{self.off_fp});
        try self.w("        LDA (${X})", .{self.off_fp});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP ${X}", .{rem});
        try self.w("        BNE L{d}", .{l_diff});
        try self.w("        INC ${X}", .{self.off_fp});
        try self.w("        LDA ${X}", .{self.off_mc});
        try self.w("        CLC", .{});
        try self.w("        ADC #8", .{});
        try self.w("        TAX", .{});
        const c_loop = self.cost;
        try self.w("L{d}:   LDA ${X}", .{ l_w, rem });
        try self.w("        CMP #8", .{});
        try self.w("        BCC L{d}", .{l_tail});
        try self.w("        LDA $0,X", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        LDA (${X})", .{self.off_fp});
        try self.w("        CMP ${X}", .{self.off_t});
        try self.w("        BNE L{d}", .{l_diff});
        try self.w("        TXA", .{});
        try self.w("        CLC", .{});
        try self.w("        ADC #8", .{});
        try self.w("        TAX", .{});
        try self.w("        LDA ${X}", .{self.off_fp});
        try self.w("        CLC", .{});
        try self.w("        ADC #8", .{});
        try self.w("        STA ${X}", .{self.off_fp});
        try self.w("        LDA ${X}", .{rem});
        try self.w("        SEC", .{});
        try self.w("        SBC #8", .{});
        try self.w("        STA ${X}", .{rem});
        try self.w("        BRA L{d}", .{l_w});
        self.cost +|= (self.cost - c_loop) *| 127;
        try self.w("L{d}:   LDA ${X}", .{ l_tail, rem });
        try self.w("        BEQ L{d}", .{l_eq});
        try self.w("        TXA", .{});
        try self.w("        STA ${X}", .{txs});
        try self.w("        LDA ${X}", .{rem});
        try self.w("        ASL #3", .{});
        try self.w("        TAX", .{});
        try self.w("        LDA ${X},X", .{self.off_masks});
        try self.w("        STA ${X}", .{self.off_acc});
        try self.w("        LDX ${X}", .{txs});
        try self.w("        LDA $0,X", .{});
        try self.w("        AND ${X}", .{self.off_acc});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        LDA (${X})", .{self.off_fp});
        try self.w("        AND ${X}", .{self.off_acc});
        try self.w("        CMP ${X}", .{self.off_t});
        try self.w("        BNE L{d}", .{l_diff});
        try self.w("L{d}:   LDA #0              ; equal", .{l_eq});
        try self.w("        RTS", .{});
        try self.w("L{d}:   LDA #1              ; different", .{l_diff});
        try self.w("        RTS", .{});
    }

    fn loadSide(self: *Gen, s: ByteSubj, p: ?u16) Error!void {
        switch (s) {
            .buf => |bi| try self.w("        LDA ${X},X", .{bi.data}),
            .field => try self.w("        LDA (${X})", .{p.?}),
        }
    }

    fn bumpPtr(self: *Gen, p: u16) Error!void {
        try self.w("        LDA ${X}", .{p});
        try self.w("        CLC", .{});
        try self.w("        ADC #8", .{});
        try self.w("        STA ${X}", .{p});
    }

    /// Emit a branch to `target` when `cond` is FALSE. Conditions are
    /// comparisons or && chains of them (v1).
    fn branchIfFalse(self: *Gen, cond: *const Expr, target: usize) Error!void {
        if (cond.* != .bin)
            return self.fail(0, "a condition must compare something (v1)", Error.Unsupported);
        const b = cond.bin;
        // Byte subjects compare as bytes (A2): `key == g.key` and friends.
        if (b.op == .eq or b.op == .ne) {
            if (self.byteSubject(b.l)) |sa| {
                if (self.byteSubject(b.r)) |sb| {
                    if (sa == .field and sb == .field)
                        return self.fail(0, "compare two message fields through a buf (v1)", Error.Unsupported);
                    // Item 7: route buf-vs-field sites with a shared
                    // shape through the MAC comparator; anything else
                    // stays inline.
                    if (self.layout.mac and self.mac_candidates >= 2) {
                        const shaped: ?struct { buf: BufInfo, foff: u16 } = blk: {
                            if (sa == .buf and sb == .field) break :blk .{ .buf = sa.buf, .foff = sb.field };
                            if (sa == .field and sb == .buf) break :blk .{ .buf = sb.buf, .foff = sa.field };
                            break :blk null;
                        };
                        if (shaped) |sh| {
                            const slot: ?usize = for (self.mac_shapes[0..self.mac_nshapes], 0..) |f, i| {
                                if (f == sh.foff) break i;
                            } else null;
                            if (slot) |i| {
                                try self.w("        LDA {s}", .{try self.imm(sh.buf.len_slot)});
                                try self.w("        STA ${X}", .{self.off_mc});
                                try self.w("        MAC {d}", .{i});
                                // A1.3: the burst runs the whole routine —
                                // charge its conservative bound at the site.
                                self.cost +|= 600;
                                // the routine RETURNS a verdict: A=0 equal
                                try self.w("        {s} L{d}", .{
                                    if (b.op == .eq) @as([]const u8, "BNE") else "BEQ", target,
                                });
                                return;
                            }
                        }
                    }
                    if (b.op == .eq) {
                        try self.emitByteCmp(sa, sb, target);
                    } else {
                        const l_diff = self.label();
                        try self.emitByteCmp(sa, sb, l_diff);
                        try self.w("        BRA L{d}", .{target});
                        try self.w("L{d}:", .{l_diff});
                    }
                    return;
                }
            }
        }
        switch (b.op) {
            .land => {
                try self.branchIfFalse(b.l, target);
                try self.branchIfFalse(b.r, target);
                return;
            },
            .eq, .ne, .lt, .le, .gt, .ge => {},
            else => return self.fail(0, "a condition must compare something (v1)", Error.Unsupported),
        }
        // Float comparisons ride FCMP's conventions: Z eq, N lt, C ge;
        // unordered raises V alone, so every comparison with NaN is
        // false — except `!=`, which IEEE makes true (Z stays clear).
        if (self.exprType(b.l) == .f64_ or self.exprType(b.r) == .f64_) {
            switch (b.op) {
                .eq, .ne, .lt, .le, .gt, .ge => {},
                else => return self.fail(0, "a float condition compares (v1)", Error.Unsupported),
            }
            if (self.simpleOperandF(b.r)) |opr| {
                try self.evalFloatScalar(b.l);
                try self.opSimpleRt("FCMP", opr);
            } else {
                const tmp = try self.pushTmp();
                try self.evalFloatScalar(b.r);
                try self.w("        STA ${X}", .{tmp});
                try self.evalFloatScalar(b.l);
                try self.w("        FCMP ${X}", .{tmp});
                self.popTmp();
            }
            switch (b.op) {
                .eq => try self.w("        BNE L{d}", .{target}),
                .ne => try self.w("        BEQ L{d}", .{target}),
                .lt => try self.w("        BPL L{d}", .{target}),
                .ge => try self.w("        BCC L{d}", .{target}),
                .gt => {
                    try self.w("        BCC L{d}", .{target});
                    try self.w("        BEQ L{d}", .{target});
                },
                .le => {
                    const ok = self.label();
                    try self.w("        BEQ L{d}", .{ok});
                    try self.w("        BMI L{d}", .{ok});
                    try self.w("        BRA L{d}", .{target});
                    try self.w("L{d}:", .{ok});
                },
                else => unreachable,
            }
            return;
        }
        // A = left, M = right; CMP sets flags from A − M (unsigned).
        if (b.r.* == .int and b.r.int == 0 and (b.op == .eq or b.op == .ne)) {
            // `x == 0` / `x != 0`: every evaluation ends in an instruction
            // that sets Z from A — the compare is already done.
            try self.evalInto(b.l);
        } else if (self.simpleOperand(b.r)) |opr| {
            try self.evalInto(b.l);
            try self.opSimple("CMP", opr);
        } else {
            const tmp = try self.pushTmp();
            try self.evalInto(b.r);
            try self.w("        STA ${X}", .{tmp});
            try self.evalInto(b.l);
            try self.w("        CMP ${X}", .{tmp});
            self.popTmp();
        }
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
        // A block is a let scope: bindings made here die here — and since
        // every park lives at a block boundary (serve's LSTN), a let can
        // never cross one. When a future construct parks mid-block, the
        // liveness check moves here and starts naming parks in errors.
        var block_lets: [8]?[]const u8 = @splat(null);
        var n_lets: usize = 0;
        for (list) |*s| {
            if (s.* == .let_) {
                if (n_lets == block_lets.len)
                    return self.fail(s.let_.line, "more than 8 live lets in one block — some of these are state, and state is a var", Error.Semantics);
                block_lets[n_lets] = s.let_.name;
                n_lets += 1;
            }
            try self.stmt(s);
        }
        for (block_lets[0..n_lets]) |bn| {
            _ = self.slots.remove(bn.?);
            _ = self.lets.remove(bn.?);
        }
    }

    fn stmt(self: *Gen, s: *const Stmt) Error!void {
        switch (s.*) {
            .let_ => |l| {
                if (self.slots.contains(l.name))
                    return self.fail(l.line, "this name is already bound — a let does not shadow", Error.Semantics);
                const ty = self.exprType(l.expr);
                if (ty == .vec_)
                    return self.fail(l.line, "a vec is a slab, not a binding — use a var", Error.Semantics);
                if (ty == .f64_) {
                    try self.evalFloatScalar(l.expr);
                } else {
                    try self.evalInto(l.expr);
                }
                const slot = try self.getOrAddSlot(l.name);
                try self.w("        STA ${X}", .{slot});
                try self.lets.put(l.name, ty == .f64_);
            },
            .adopt_ => |a| {
                // A4 movement 3, the other half: signing for the estate.
                if (self.handoff_bind == null or !std.mem.eql(u8, self.handoff_bind.?, a.rec))
                    return self.fail(a.line, "`adopt` signs for a `case handoff` binding", Error.Semantics);
                const rp = self.regions.getPtr(a.region) orelse
                    return self.fail(a.line, "an estate becomes a `region` variable", Error.Semantics);
                if (rp.locked)
                    return self.fail(a.line, "this region is granted out to silicon here (§6.2)", Error.Semantics);
                const arr = self.arrays.get(a.region).?;
                const doff = @as(u64, rp.slot) * ring.desc_size;
                try self.w("; adopt {s} as {s}: hardware chose the slot, the heir chooses the name", .{ a.rec, a.region });
                try self.w("        LDA ${X}", .{self.off_ptr});
                try self.w("        CLC", .{});
                try self.w("        ADC #8", .{});
                try self.w("        STA ${X}", .{self.off_fp});
                try self.w("        LDA (${X})          ; word1: the slot the RBC picked", .{self.off_fp});
                try self.w("        AND #$FF", .{});
                try self.w("        ASL #5              ; × 32: a descriptor's stride", .{});
                try self.w("        TAX", .{});
                // The descriptor moves by COPY, not by reconstruction:
                // whatever attenuation the grantor chose survives,
                // because nobody here re-derives it (§2.3 — the only
                // honest way to preserve a field you do not interpret).
                try self.w("        LDA $0,X            ; base", .{});
                try self.w("        STA ${X}          ; {s}[i] now reads the inherited memory", .{ arr.ptr_slot, a.region });
                try self.w("        STA ${X}", .{doff});
                try self.w("        LDA $8,X            ; verbs | REGION — copied, never re-derived", .{});
                try self.w("        STA ${X}", .{doff + 8});
                try self.w("        LDA $10,X           ; extent", .{});
                try self.w("        STA ${X}", .{doff + 16});
                try self.w("        LDA $18,X           ; the token the RBC minted", .{});
                try self.w("        STA ${X}", .{doff + 24});
                // Release hardware's slot: the estate is named once, and
                // the slot is free for the next inheritance.
                try self.w("        LDA #0", .{});
                try self.w("        STA $0,X", .{});
                try self.w("        STA $8,X", .{});
                try self.w("        STA $10,X", .{});
                try self.w("        STA $18,X", .{});
            },
            .grant_ => |g| {
                // A4 movement 3: the estate, handed to the executor.
                const rp = self.regions.getPtr(g.region) orelse
                    return self.fail(g.line, "`grant` hands on a `region` variable", Error.Semantics);
                if (rp.locked)
                    return self.fail(g.line, "this region is granted out to silicon here (§6.2)", Error.Semantics);
                const tslot: u16 = if (std.mem.eql(u8, g.to, "boss")) blk: {
                    self.uses_boss = true;
                    break :blk self.off_boss;
                } else self.slots.get(g.to) orelse
                    return self.fail(g.line, "unknown grantee", Error.Semantics);
                try self.w("; grant {s} to {s}: the capability moves, the memory stays", .{ g.region, g.to });
                try self.w("        LDA #4              ; SQE: op = grant", .{});
                try self.w("        STA !${X}", .{self.layout.sqBase()});
                try self.w("        LDA ${X}", .{tslot});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 8});
                try self.w("        LDA {s}", .{try self.imm(rp.slot)});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 16});
                // The verbs the grantee receives. read|write always;
                // `grant` only when this grant said `onward`, so the
                // delegation chain ends by default and is extended on
                // purpose (A4.5).
                // Built from the type, not spelled as a constant: the
                // bit positions live in ring.Verbs and nowhere else.
                const verbs: u64 = @as(u4, @bitCast(ring.Verbs{
                    .read = true,
                    .write = true,
                    .grant = g.onward,
                }));
                try self.w("        LDA ##${X}", .{@as(u64, 1) << 32 | verbs});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 24});
                try self.w("        SEND 0", .{});
                // The region is no longer ours: the compiler's copy of
                // the surrender the RBC just performed.
                rp.locked = true;
            },
            .clear_ => |c| {
                const bi = self.bufs.get(c.buf) orelse
                    return self.fail(c.line, "`clear` empties a buf", Error.Semantics);
                try self.w("        LDA #0", .{});
                try self.w("        STA ${X}", .{bi.len_slot});
            },
            .append_ => |ap| {
                const bi = self.bufs.get(ap.buf) orelse
                    return self.fail(ap.line, "`append` fills a buf", Error.Semantics);
                var src = ap.src;
                if (src == .name) {
                    // A const appends as the literal it names.
                    for (self.prog.consts) |c| {
                        if (std.mem.eql(u8, c.name, src.name)) {
                            src = .{ .str = c.text };
                            break;
                        }
                    } else return self.fail(ap.line, "append takes a literal, a const or byte(expr)", Error.Semantics);
                }
                switch (src) {
                    .name => unreachable,
                    .str => |txt| {
                        if (txt.len == 0) return;
                        if (txt.len > bi.cap)
                            return self.fail(ap.line, "this literal cannot fit the buf", Error.Semantics);
                        const l_fit = self.label();
                        try self.w("        LDA ${X}", .{bi.len_slot});
                        try self.w("        CMP {s}", .{try self.imm(bi.cap - txt.len + 1)});
                        try self.w("        BCC L{d}", .{l_fit});
                        try self.w("        BRK                 ; pack_overflow", .{});
                        try self.w("L{d}:", .{l_fit});
                        for (txt) |ch| {
                            try self.w("        LDA #{d}", .{ch});
                            try self.w("        LDX ${X}", .{bi.len_slot});
                            try self.w("        STA ${X},X", .{bi.data});
                            try self.w("        INC ${X}", .{bi.len_slot});
                        }
                    },
                    .byte => |e| {
                        const l_fit = self.label();
                        try self.w("        LDA ${X}", .{bi.len_slot});
                        try self.w("        CMP {s}", .{try self.imm(bi.cap)});
                        try self.w("        BCC L{d}", .{l_fit});
                        try self.w("        BRK                 ; pack_overflow", .{});
                        try self.w("L{d}:", .{l_fit});
                        try self.evalInto(e);
                        try self.w("        AND #$FF", .{});
                        try self.w("        LDX ${X}", .{bi.len_slot});
                        try self.w("        STA ${X},X", .{bi.data});
                        try self.w("        INC ${X}", .{bi.len_slot});
                    },
                }
            },
            .send_field => |sf| {
                try self.requireRaw(sf.target, sf.line);
                const tslot = self.slots.get(sf.target) orelse
                    return self.fail(sf.line, "unknown send target", Error.Semantics);
                const bind = self.bind orelse
                    return self.fail(sf.line, "forwarding a payload needs a case binding", Error.Semantics);
                if (!std.mem.eql(u8, bind, sf.bind))
                    return self.fail(sf.line, "field base is not the case binding", Error.Semantics);
                const bmsg = self.bind_msg.?;
                if (!bmsg.is_reply)
                    return self.fail(sf.line, "raw forwarding is for a device reply's payload (A3.3)", Error.Semantics);
                const fld = for (bmsg.fields) |*fl| {
                    if (std.mem.eql(u8, fl.name, sf.field)) break fl;
                } else return self.fail(sf.line, "no such field in the reply", Error.Semantics);
                if (fld.ty != .bytes_)
                    return self.fail(sf.line, "only a bytes field forwards raw", Error.Semantics);
                // Copy the payload out of the landing buffer first: it is
                // AUTO_REPOST space, so hardware may refill it the moment
                // this handler parks — pointing an SQE at it hands the
                // fabric a buffer the fabric owns. (Chunks went missing
                // exactly this way; the copy is 7 word moves, priced.)
                try self.w("; forward {s}.{s}: stage it, then send — never point at a re-granted buffer", .{ sf.bind, sf.field });
                try self.w("        LDA ${X}", .{self.off_ptr});
                try self.w("        CLC", .{});
                try self.w("        ADC #{d}", .{fld.offset});
                try self.w("        STA ${X}", .{self.off_fp});
                try self.w("        LDA ##${X}", .{self.layout.staging()});
                try self.w("        STA ${X}", .{self.off_t});
                var wo: u16 = 0;
                while (fld.offset + wo < abi.land_cap) : (wo += 8) {
                    try self.w("        LDY #{d}", .{wo});
                    try self.w("        LDA (${X}),Y", .{self.off_fp});
                    try self.w("        STA (${X}),Y", .{self.off_t});
                }
                try self.w("        LDA ##$1_0000_0001  ; SQE: op = send, claim raw (A4)", .{});
                try self.w("        STA !${X}", .{self.layout.sqBase()});
                try self.w("        LDA ${X}", .{tslot});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 8});
                try self.w("        LDA ##${X}", .{self.layout.staging()});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 16});
                // length = what the fabric counted, less the header
                try self.w("        LDA ${X}", .{self.off_dcount});
                try self.w("        SEC", .{});
                try self.w("        SBC #{d}", .{fld.offset});
                try self.w("        ORA ##${X}", .{@as(u64, 1) << 32});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 24});
                try self.w("        SEND 0", .{});
            },
            .send_buf => |sb| {
                try self.requireRaw(sb.target, sb.line);
                const tslot = self.slots.get(sb.target) orelse
                    return self.fail(sb.line, "unknown send target", Error.Semantics);
                const bi = self.bufs.get(sb.buf) orelse
                    return self.fail(sb.line, "a raw send takes a buf", Error.Semantics);
                try self.w("        LDA ##$1_0000_0001  ; SQE: op = send, claim raw (A4)", .{});
                try self.w("        STA !${X}", .{self.layout.sqBase()});
                try self.w("        LDA ${X}", .{tslot});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 8});
                try self.w("        LDA {s}", .{try self.imm(bi.data)});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 16});
                try self.w("        LDA ${X}", .{bi.len_slot});
                try self.w("        ORA ##${X}", .{@as(u64, 1) << 32});
                try self.w("        STA !${X}", .{self.layout.sqBase() + 24});
                try self.w("        SEND 0", .{});
            },
            .assign => |a| {
                if (self.lets.contains(a.name))
                    return self.fail(0, "a let is a binding, not a variable — this wants a var", Error.Semantics);
                if (a.field) |fname| {
                    // `anim.index = e` — a record field is a near slot
                    // like any other (A3.4).
                    const slot = self.recordSlot(a.name, fname) orelse
                        return self.fail(0, "no such record field", Error.Semantics);
                    switch (a.op) {
                        .set => try self.evalInto(a.expr),
                        .add, .sub => {
                            // slot OP expr, in that order — subtraction
                            // does not commute, and the operand form
                            // keeps the near page out of it when it can.
                            const mn: []const u8 = if (a.op == .add) "ADC" else "SBC";
                            const carry: []const u8 = if (a.op == .add) "CLC" else "SEC";
                            if (self.simpleOperand(a.expr)) |opr| {
                                try self.w("        LDA ${X}", .{slot});
                                try self.w("        {s}", .{carry});
                                if (a.op == .add) {
                                    try self.opSimple("ADC", opr);
                                } else {
                                    try self.opSimple("SBC", opr);
                                }
                            } else {
                                const tmp = try self.pushTmp();
                                try self.evalInto(a.expr);
                                try self.w("        STA ${X}", .{tmp});
                                try self.w("        LDA ${X}", .{slot});
                                try self.w("        {s}", .{carry});
                                try self.w("        {s} ${X}", .{ mn, tmp });
                                self.popTmp();
                            }
                        },
                    }
                    try self.w("        STA ${X}", .{slot});
                    return;
                }
                if (a.idx) |ix| {
                    // arr[e] = v — evaluate v first (it may clobber Y).
                    const arr = self.arrays.get(a.name) orelse
                        return self.fail(0, "not an array", Error.Semantics);
                    if (self.regions.get(a.name)) |r| {
                        if (r.locked)
                            return self.fail(0, "a granted region is inaccessible until done/failed rebinds it (§6.2)", Error.Semantics);
                    }
                    if (a.op != .set)
                        return self.fail(0, "v1 array assignment is `=` only", Error.Unsupported);
                    if (self.simpleOperand(a.expr)) |opr| {
                        try self.evalInto(ix);
                        try self.w("        ASL #3", .{});
                        try self.w("        TAY", .{});
                        try self.opSimple("LDA", opr);
                        try self.w("        STA (${X}),Y", .{arr.ptr_slot});
                        return;
                    }
                    const tmp = try self.pushTmp();
                    try self.evalInto(a.expr);
                    try self.w("        STA ${X}", .{tmp});
                    try self.evalInto(ix);
                    try self.w("        ASL #3", .{});
                    try self.w("        TAY", .{});
                    try self.w("        LDA ${X}", .{tmp});
                    try self.w("        STA (${X}),Y", .{arr.ptr_slot});
                    self.popTmp();
                    return;
                }
                if (self.vecs.get(a.name)) |slab| {
                    if (a.op != .set)
                        return self.fail(0, "vec assignment is `=` (v1)", Error.Unsupported);
                    try self.storeVec(slab, a.expr);
                    return;
                }
                const slot = self.slots.get(a.name) orelse
                    return self.fail(0, "unknown variable", Error.Semantics);
                const ident_e = Expr{ .ident = a.name };
                const is_f = self.exprType(&ident_e) == .f64_;
                if (!is_f and self.exprType(a.expr) == .f64_)
                    return self.fail(0, "a float into an integer wants int()", Error.Semantics);
                if (is_f) {
                    switch (a.op) {
                        .set => {
                            try self.evalFloatScalar(a.expr);
                            try self.w("        STA ${X}", .{slot});
                        },
                        .add, .sub => {
                            const mn: []const u8 = if (a.op == .add) "FADD" else "FSUB";
                            if (self.simpleOperandF(a.expr)) |opr| {
                                try self.w("        LDA ${X}", .{slot});
                                try self.opSimpleRt(mn, opr);
                            } else if (a.op == .add) {
                                try self.evalFloatScalar(a.expr);
                                try self.w("        FADD ${X}", .{slot});
                            } else {
                                const tmp = try self.pushTmp();
                                try self.evalFloatScalar(a.expr);
                                try self.w("        STA ${X}", .{tmp});
                                try self.w("        LDA ${X}", .{slot});
                                try self.w("        FSUB ${X}", .{tmp});
                                self.popTmp();
                            }
                            try self.w("        STA ${X}", .{slot});
                        },
                    }
                    return;
                }
                switch (a.op) {
                    .set => {
                        try self.evalInto(a.expr);
                        try self.w("        STA ${X}", .{slot});
                    },
                    .add, .sub => {
                        // `x += 1` is what INC is for.
                        if (a.expr.* == .int and a.expr.int == 1) {
                            try self.w("        {s} ${X}", .{
                                if (a.op == .add) @as([]const u8, "INC") else "DEC", slot,
                            });
                            return;
                        }
                        if (self.simpleOperand(a.expr)) |opr| {
                            try self.w("        LDA ${X}", .{slot});
                            if (a.op == .add) {
                                try self.w("        CLC", .{});
                                try self.opSimple("ADC", opr);
                            } else {
                                try self.w("        SEC", .{});
                                try self.opSimple("SBC", opr);
                            }
                            try self.w("        STA ${X}", .{slot});
                            return;
                        }
                        if (a.op == .add) {
                            // Commutative: A = e, then add the slot in.
                            try self.evalInto(a.expr);
                            try self.w("        CLC", .{});
                            try self.w("        ADC ${X}", .{slot});
                        } else {
                            const tmp = try self.pushTmp();
                            try self.evalInto(a.expr);
                            try self.w("        STA ${X}", .{tmp});
                            try self.w("        LDA ${X}", .{slot});
                            try self.w("        SEC", .{});
                            try self.w("        SBC ${X}", .{tmp});
                            self.popTmp();
                        }
                        try self.w("        STA ${X}", .{slot});
                    },
                }
            },
            .send => |sd| try self.send(sd),
            .send_str => |ss| {
                try self.requireRaw(ss.target, ss.line);
                const tslot = self.slots.get(ss.target) orelse
                    return self.fail(ss.line, "unknown send target", Error.Semantics);
                const lbl = self.label();
                try self.strings.append(.{ .label = lbl, .text = ss.text });
                try self.w("        LDA ##$1_0000_0001  ; SQE: op = send, claim raw (A4)", .{});
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
                const c0 = self.cost;
                const d0 = self.cost_dyn;
                self.cost_dyn = false;
                try self.stmts(b.body);
                self.brecs.append(.{
                    .line = b.line,
                    .n = b.n,
                    .body_cost = self.cost - c0,
                    .body_dyn = self.cost_dyn,
                }) catch return Error.OutOfMemory;
                self.cost_dyn = self.cost_dyn or d0;
            },
            .for_range => |f| {
                const kslot = try self.getOrAddSlot(f.name);
                const l_top = self.label();
                const l_end = self.label();
                // A1.3: a constant extent multiplies the once-emitted body
                // into the bound; anything else is data-dependent.
                const trips: ?u64 = if (f.from.* == .int and f.to.* == .int)
                    f.to.int -| f.from.int
                else
                    null;
                const c0 = self.cost;
                try self.evalInto(f.from);
                try self.w("        STA ${X}", .{kslot});
                try self.w("L{d}:", .{l_top});
                if (self.simpleOperand(f.to)) |opr| {
                    try self.w("        LDA ${X}", .{kslot});
                    try self.opSimple("CMP", opr);
                } else {
                    try self.evalInto(f.to);
                    try self.w("        STA ${X}", .{self.off_t});
                    try self.w("        LDA ${X}", .{kslot});
                    try self.w("        CMP ${X}", .{self.off_t});
                }
                try self.w("        BCS L{d}", .{l_end});
                try self.stmts(f.body);
                try self.w("        INC ${X}", .{kslot});
                try self.w("        BRA L{d}", .{l_top});
                try self.w("L{d}:", .{l_end});
                if (trips) |t| {
                    self.cost +|= (self.cost - c0) *| t;
                } else self.cost_dyn = true;
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
                // A group's count is the loader's runtime data — the
                // analysis cannot see this extent.
                self.cost_dyn = true;
            },
            .pack => |pk| try self.stmtPack(pk),
            .copy_ => |cp| try self.stmtCopy(cp),
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
                // A4.8: a spawn may live in a handler now, not only the
                // body. Its record index is fixed by identity (set in
                // setup), so a handler `SPWN` reads the slot the loader
                // staged for this exact site — the child's context, and
                // thus its RX ring and the parent's capability to it,
                // survive every incarnation the site starts.
                const rec = self.spawnRec(self.spawn_idx.get(s).?);
                try self.w("; spawn {s} restarts {d} watchdog {d}", .{ sp.actor, sp.restarts, sp.watchdog });
                try self.w("        LDA {s}", .{try self.imm(sp.restarts)});
                try self.w("        STA ${X}", .{rec + 40});
                try self.w("        SPWN ${X}", .{rec});
            },
        }
    }

    /// `key.count()` — A2.2's element walk, which is also A2.7's machine
    /// half of "skip is total": every valid element of the FULL tower —
    /// including big ints, decimal, map and set, which joe cannot decode —
    /// is stepped over structurally. A malformed or truncated stream is
    /// BRK: the actor crashes honestly and the supervisor hears about it.
    /// Result: the element count, in A.
    fn emitCount(self: *Gen, bi: BufInfo) Error!void {
        const t_n = try self.pushTmp();
        const t_aux = try self.pushTmp();
        defer {
            self.popTmp();
            self.popTmp();
        }
        const L = struct {
            top: usize,
            next: usize,
            done: usize,
            brk: usize,
            one: usize,
            neg: usize,
            pos: usize,
            adv1w: usize,
            f4: usize,
            f8: usize,
            u16_: usize,
            framed: usize,
            fs: usize,
            fs_inc: usize,
            bign: usize,
            bigp: usize,
            big: usize,
            bm: usize,
            bl: usize,
            bb: usize,
            bb2: usize,
            bdone: usize,
            dec: usize,
            dec_nz: usize,
            dec_n: usize,
            dec_e: usize,
            nc: usize,
            pos_e: usize,
            w_e: usize,
            dsc: usize,
            dfound: usize,
            exact: usize,
        };
        var l: L = undefined;
        inline for (@typeInfo(L).@"struct".fields) |f| @field(l, f.name) = self.label();

        try self.w("; count(): the total skip — all 18 type codes, in silicon", .{});
        try self.w("        LDX #0", .{});
        try self.w("        LDA #0", .{});
        try self.w("        STA ${X}", .{t_n});
        try self.w("L{d}:   TXA", .{l.top});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.done});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        // the dispatch ladder: exact codes first, then the ranges
        try self.w("        CMP #$01", .{});
        try self.w("        BEQ L{d}", .{l.one});
        try self.w("        CMP #$02", .{});
        try self.w("        BEQ L{d}", .{l.one});
        try self.w("        CMP #$05", .{});
        try self.w("        BEQ L{d}", .{l.one});
        try self.w("        CMP #$06", .{});
        try self.w("        BEQ L{d}", .{l.one});
        try self.w("        CMP #$0F", .{});
        try self.w("        BEQ L{d}", .{l.bign});
        try self.w("        CMP #$20", .{});
        try self.w("        BEQ L{d}", .{l.one});
        try self.w("        CMP #$31", .{});
        try self.w("        BEQ L{d}", .{l.bigp});
        try self.w("        CMP #$38", .{});
        try self.w("        BEQ L{d}", .{l.dec});
        try self.w("        CMP #$10", .{});
        try self.w("        BCC L{d}", .{l.brk});
        try self.w("        CMP #$20", .{});
        try self.w("        BCC L{d}", .{l.neg});
        try self.w("        CMP #$31", .{});
        try self.w("        BCC L{d}", .{l.pos});
        try self.w("        CMP #$34", .{});
        try self.w("        BEQ L{d}", .{l.f4});
        try self.w("        CMP #$35", .{});
        try self.w("        BEQ L{d}", .{l.f8});
        try self.w("        CMP #$40", .{});
        try self.w("        BEQ L{d}", .{l.f8});
        try self.w("        CMP #$44", .{});
        try self.w("        BEQ L{d}", .{l.u16_});
        try self.w("        CMP #$48", .{});
        try self.w("        BEQ L{d}", .{l.framed});
        try self.w("        CMP #$49", .{});
        try self.w("        BEQ L{d}", .{l.framed});
        try self.w("        CMP #$50", .{});
        try self.w("        BEQ L{d}", .{l.framed});
        try self.w("        CMP #$52", .{});
        try self.w("        BEQ L{d}", .{l.framed});
        try self.w("        CMP #$54", .{});
        try self.w("        BEQ L{d}", .{l.framed});
        try self.w("L{d}:   BRK                 ; malformed or truncated", .{l.brk});
        // one-byte elements
        try self.w("L{d}:   INX", .{l.one});
        try self.w("        BRA L{d}", .{l.next});
        // fixed ints: width from the code, both sides of zero
        try self.w("L{d}:   STA ${X}", .{ l.neg, self.off_t });
        try self.w("        LDA #$20", .{});
        try self.w("        SEC", .{});
        try self.w("        SBC ${X}", .{self.off_t});
        try self.w("        BRA L{d}", .{l.adv1w});
        try self.w("L{d}:   SEC", .{l.pos});
        try self.w("        SBC #$20", .{});
        try self.w("L{d}:   STA ${X}", .{ l.adv1w, self.off_t });
        try self.w("        TXA", .{});
        try self.w("        CLC", .{});
        try self.w("        ADC ${X}", .{self.off_t});
        try self.w("        TAX", .{});
        try self.w("        INX", .{});
        try self.w("        BRA L{d}", .{l.next});
        // fixed-width payloads
        try self.w("L{d}:   TXA", .{l.f4});
        try self.w("        CLC", .{});
        try self.w("        ADC #5", .{});
        try self.w("        TAX", .{});
        try self.w("        BRA L{d}", .{l.next});
        try self.w("L{d}:   TXA", .{l.f8});
        try self.w("        CLC", .{});
        try self.w("        ADC #9", .{});
        try self.w("        TAX", .{});
        try self.w("        BRA L{d}", .{l.next});
        try self.w("L{d}:   TXA", .{l.u16_});
        try self.w("        CLC", .{});
        try self.w("        ADC #17", .{});
        try self.w("        TAX", .{});
        try self.w("        BRA L{d}", .{l.next});
        // framed: scan for an unescaped terminator
        try self.w("L{d}:   INX", .{l.framed});
        try self.w("L{d}:   TXA", .{l.fs});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        try self.w("        BNE L{d}", .{l.fs_inc});
        try self.w("        INX                 ; past the 0x00", .{});
        try self.w("        TXA", .{});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.next});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP #$FF", .{});
        try self.w("        BNE L{d}", .{l.next});
        try self.w("        INX                 ; escaped literal 0x00", .{});
        try self.w("        BRA L{d}", .{l.fs});
        try self.w("L{d}:   INX", .{l.fs_inc});
        try self.w("        BRA L{d}", .{l.fs});
        // big ints: [m][n][magnitude], complemented when negative
        try self.w("L{d}:   LDA ##$FF", .{l.bign});
        try self.w("        STA ${X}", .{t_aux});
        try self.w("        BRA L{d}", .{l.big});
        try self.w("L{d}:   LDA #0", .{l.bigp});
        try self.w("        STA ${X}", .{t_aux});
        try self.w("L{d}:   INX", .{l.big});
        try self.w("        TXA", .{});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        LDA ${X}", .{t_aux});
        try self.w("        BEQ L{d}", .{l.bm});
        try self.w("        LDA ${X}", .{self.off_t});
        try self.w("        EOR ##$FF", .{});
        try self.w("        AND #$FF", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("L{d}:   LDA ${X}", .{ l.bm, self.off_t });
        try self.w("        CMP #9", .{});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        INX", .{});
        try self.w("        LDA #0", .{});
        try self.w("        STA ${X}", .{self.off_acc});
        try self.w("L{d}:   LDA ${X}", .{ l.bl, self.off_t });
        try self.w("        BEQ L{d}", .{l.bdone});
        try self.w("        TXA", .{});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        LDA ${X}", .{self.off_acc});
        try self.w("        ASL #8", .{});
        try self.w("        STA ${X}", .{self.off_acc});
        try self.w("        LDA ${X}", .{t_aux});
        try self.w("        BEQ L{d}", .{l.bb});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        EOR ##$FF", .{});
        try self.w("        AND #$FF", .{});
        try self.w("        BRA L{d}", .{l.bb2});
        try self.w("L{d}:   LDA ${X},X", .{ l.bb, bi.data });
        try self.w("        AND #$FF", .{});
        try self.w("L{d}:   ORA ${X}", .{ l.bb2, self.off_acc });
        try self.w("        STA ${X}", .{self.off_acc});
        try self.w("        INX", .{});
        try self.w("        DEC ${X}", .{self.off_t});
        try self.w("        BRA L{d}", .{l.bl});
        try self.w("L{d}:   TXA", .{l.bdone});
        try self.w("        CLC", .{});
        try self.w("        ADC ${X}", .{self.off_acc});
        try self.w("        TAX", .{});
        try self.w("        BRA L{d}", .{l.next});
        // decimal: sign, embedded exponent int, digits to the terminator
        try self.w("L{d}:   INX", .{l.dec});
        try self.w("        TXA", .{});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP #2", .{});
        try self.w("        BNE L{d}", .{l.dec_nz});
        try self.w("        INX                 ; canonical zero", .{});
        try self.w("        BRA L{d}", .{l.next});
        try self.w("L{d}:   CMP #1", .{l.dec_nz});
        try self.w("        BEQ L{d}", .{l.dec_n});
        try self.w("        CMP #3", .{});
        try self.w("        BNE L{d}", .{l.brk});
        try self.w("        LDA #0", .{});
        try self.w("        STA ${X}", .{t_aux});
        try self.w("        BRA L{d}", .{l.dec_e});
        try self.w("L{d}:   LDA ##$FF", .{l.dec_n});
        try self.w("        STA ${X}", .{t_aux});
        try self.w("L{d}:   INX                 ; past the sign", .{l.dec_e});
        try self.w("        TXA", .{});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        LDA ${X}", .{t_aux});
        try self.w("        BEQ L{d}", .{l.nc});
        try self.w("        LDA ${X}", .{self.off_t});
        try self.w("        EOR ##$FF", .{});
        try self.w("        AND #$FF", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("L{d}:   LDA ${X}", .{ l.nc, self.off_t });
        try self.w("        CMP #$20", .{});
        try self.w("        BCS L{d}", .{l.pos_e});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        LDA #$20", .{});
        try self.w("        SEC", .{});
        try self.w("        SBC ${X}", .{self.off_t});
        try self.w("        BRA L{d}", .{l.w_e});
        try self.w("L{d}:   SEC", .{l.pos_e});
        try self.w("        SBC #$20", .{});
        try self.w("L{d}:   CMP #17", .{l.w_e});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        TXA", .{});
        try self.w("        CLC", .{});
        try self.w("        ADC ${X}", .{self.off_t});
        try self.w("        TAX", .{});
        try self.w("        INX", .{});
        try self.w("L{d}:   TXA", .{l.dsc});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BCS L{d}", .{l.brk});
        try self.w("        LDA ${X},X", .{bi.data});
        try self.w("        AND #$FF", .{});
        try self.w("        CMP ${X}", .{t_aux});
        try self.w("        BEQ L{d}", .{l.dfound});
        try self.w("        INX", .{});
        try self.w("        BRA L{d}", .{l.dsc});
        try self.w("L{d}:   INX", .{l.dfound});
        try self.w("        BRA L{d}", .{l.next});
        // one more element walked
        try self.w("L{d}:   INC ${X}", .{ l.next, t_n });
        try self.w("        BRA L{d}", .{l.top});
        // the stream must end exactly at the length — else it was truncated
        try self.w("L{d}:   TXA", .{l.done});
        try self.w("        CMP ${X}", .{bi.len_slot});
        try self.w("        BEQ L{d}", .{l.exact});
        try self.w("        BRK                 ; overshoot: truncated element", .{});
        try self.w("L{d}:   LDA ${X}", .{ l.exact, t_n });
    }

    /// `pack buf, (…)` (A2.3): constant segments pre-pack at compile time
    /// through the host half of struple #13 and land as immediate word
    /// stores; a variable element is a u64 encoded at runtime — type code
    /// $20+n, big-endian magnitude — through unaligned near_x appends
    /// (the slab's 8-byte slack makes every word store legal). Capacity
    /// is checked at compile time where lengths are static, at runtime
    /// (BRK — pack_overflow arrives as a crash in v1) where they are not.
    fn stmtPack(self: *Gen, pk: anytype) Error!void {
        const bi = self.bufs.get(pk.buf) orelse
            return self.fail(pk.line, "pack wants a `buf` variable", Error.Semantics);
        var i: usize = 0;
        // The leading constant run: static bytes at static offset zero.
        var pre = struple.Packer.init(self.arena);
        while (i < pk.elems.len) : (i += 1) {
            switch (pk.elems[i]) {
                .str => |s| pre.appendString(s) catch return Error.OutOfMemory,
                .int => |v| pre.appendUint(v) catch return Error.OutOfMemory,
                .ident => break,
            }
        }
        const prefix = pre.bytes();
        if (prefix.len > bi.cap)
            return self.fail(pk.line, "the tuple's constants alone overflow the buffer", Error.Semantics);
        try self.w("; pack {s}: {d}-byte constant prefix, {d} runtime element(s)", .{
            pk.buf, prefix.len, pk.elems.len - i,
        });
        var off: u16 = 0;
        while (off < prefix.len) : (off += 8) {
            try self.w("        LDA ##${X}", .{chunkWord(prefix[off..])});
            try self.w("        STA ${X}", .{bi.data + off});
        }
        try self.w("        LDA {s}", .{try self.imm(prefix.len)});
        try self.w("        STA ${X}", .{bi.len_slot});

        while (i < pk.elems.len) : (i += 1) {
            switch (pk.elems[i]) {
                .ident => |name| {
                    const slot = self.slots.get(name) orelse
                        return self.fail(pk.line, "a tuple element names a scalar (v1)", Error.Semantics);
                    try self.emitIntAppend(bi, slot);
                },
                else => {
                    // A constant run after a variable element: static
                    // bytes at a runtime offset.
                    var run = struple.Packer.init(self.arena);
                    while (i < pk.elems.len) : (i += 1) {
                        switch (pk.elems[i]) {
                            .str => |s| run.appendString(s) catch return Error.OutOfMemory,
                            .int => |v| run.appendUint(v) catch return Error.OutOfMemory,
                            .ident => break,
                        }
                    }
                    i -= 1; // outer loop re-advances
                    const blob = run.bytes();
                    // guard: len + blob must fit
                    const l_ok = self.label();
                    try self.w("        LDA ${X}", .{bi.len_slot});
                    try self.w("        CMP {s}", .{try self.imm(bi.cap - blob.len + 1)});
                    try self.w("        BCC L{d}", .{l_ok});
                    try self.w("        BRK                 ; pack_overflow", .{});
                    try self.w("L{d}:   TAX", .{l_ok});
                    var boff: u16 = 0;
                    while (boff < blob.len) : (boff += 8) {
                        if (boff != 0) {
                            try self.w("        TXA", .{});
                            try self.w("        CLC", .{});
                            try self.w("        ADC #8", .{});
                            try self.w("        TAX", .{});
                        }
                        try self.w("        LDA ##${X}", .{chunkWord(blob[boff..])});
                        try self.w("        STA ${X},X", .{bi.data});
                    }
                    try self.w("        LDA ${X}", .{bi.len_slot});
                    try self.w("        CLC", .{});
                    try self.w("        ADC {s}", .{try self.imm(blob.len)});
                    try self.w("        STA ${X}", .{bi.len_slot});
                },
            }
        }
    }

    /// `copy dst, src` (A2): whole-word copies — buf to buf straight
    /// through the near page, bytes field to buf through the landing
    /// pointer. Length checked against the destination's capacity (BRK
    /// on overflow, the pack_overflow law).
    fn stmtCopy(self: *Gen, cp: anytype) Error!void {
        const di = self.bufs.get(cp.dst) orelse
            return self.fail(cp.line, "copy wants a `buf` destination", Error.Semantics);
        const src = self.byteSubject(cp.src) orelse
            return self.fail(cp.line, "copy's source is a buf or the bound bytes field", Error.Semantics);
        switch (src) {
            .buf => |si| {
                try self.w("; copy {s} <- buf", .{cp.dst});
                if (si.cap > di.cap) {
                    const l_ok = self.label();
                    try self.w("        LDA ${X}", .{si.len_slot});
                    try self.w("        CMP {s}", .{try self.imm(di.cap + 1)});
                    try self.w("        BCC L{d}", .{l_ok});
                    try self.w("        BRK                 ; copy overflow", .{});
                    try self.w("L{d}:", .{l_ok});
                }
                try self.w("        LDA ${X}", .{si.len_slot});
                try self.w("        STA ${X}", .{di.len_slot});
                const words = (@min(si.cap, di.cap) + 7) / 8;
                var wo: u16 = 0;
                while (wo < words) : (wo += 1) {
                    try self.w("        LDA ${X}", .{si.data + wo * 8});
                    try self.w("        STA ${X}", .{di.data + wo * 8});
                }
            },
            .field => |foff| {
                const cap_msg: u16 = @intCast(abi.land_cap - foff - 1);
                const tp = try self.pushTmp();
                defer self.popTmp();
                try self.w("; copy {s} <- bytes field", .{cp.dst});
                try self.w("        LDA ${X}", .{self.off_ptr});
                try self.w("        CLC", .{});
                try self.w("        ADC {s}", .{try self.imm(foff)});
                try self.w("        STA ${X}", .{tp});
                try self.w("        LDA (${X})", .{tp});
                try self.w("        AND #$FF", .{});
                if (cap_msg > di.cap) {
                    const l_ok = self.label();
                    try self.w("        CMP {s}", .{try self.imm(di.cap + 1)});
                    try self.w("        BCC L{d}", .{l_ok});
                    try self.w("        BRK                 ; copy overflow", .{});
                    try self.w("L{d}:", .{l_ok});
                }
                try self.w("        STA ${X}", .{di.len_slot});
                try self.w("        INC ${X}", .{tp});
                const words = (@min(cap_msg, di.cap) + 7) / 8;
                var wo: u16 = 0;
                while (wo < words) : (wo += 1) {
                    if (wo != 0) try self.bumpPtr(tp);
                    try self.w("        LDA (${X})", .{tp});
                    try self.w("        STA ${X}", .{di.data + wo * 8});
                }
            },
        }
    }

    /// Append one u64 as a canonical struple int at the buffer's current
    /// length: zero is the bare $20; else type code $20+n then the n
    /// magnitude bytes, emitted MSB-first by a skip-counted peel of the
    /// top byte (no variable shift counts exist on this machine).
    fn emitIntAppend(self: *Gen, bi: BufInfo, vslot: u16) Error!void {
        const t_cnt = try self.pushTmp();
        const t_skip = try self.pushTmp();
        const l_nz = self.label();
        const l_count = self.label();
        const l_emit = self.label();
        const l_next = self.label();
        const l_loop = self.label();
        const l_done = self.label();
        const l_fit = self.label();
        // worst-case append is 9 bytes; the guard is the pack_overflow law
        try self.w("        LDA ${X}", .{bi.len_slot});
        try self.w("        CMP {s}", .{try self.imm(bi.cap - 8)});
        try self.w("        BCC L{d}", .{l_fit});
        try self.w("        BRK                 ; pack_overflow", .{});
        try self.w("L{d}:   LDA ${X}", .{ l_fit, vslot });
        try self.w("        BNE L{d}", .{l_nz});
        try self.w("        LDX ${X}", .{bi.len_slot});
        try self.w("        LDA #$20            ; canonical zero", .{});
        try self.w("        STA ${X},X", .{bi.data});
        try self.w("        INC ${X}", .{bi.len_slot});
        try self.w("        BRA L{d}", .{l_done});
        // count the magnitude bytes: n = 1..8
        try self.w("L{d}:   STA ${X}", .{ l_nz, self.off_t });
        try self.w("        LDA #0", .{});
        try self.w("        STA ${X}", .{t_cnt});
        const c_count = self.cost;
        try self.w("L{d}:   INC ${X}", .{ l_count, t_cnt });
        try self.w("        LDA ${X}", .{self.off_t});
        try self.w("        LSR #8", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        BNE L{d}", .{l_count});
        self.cost +|= (self.cost - c_count) *| 7; // ≤ 8 laps, one emitted
        // type code $20 + n
        try self.w("        LDA ${X}", .{t_cnt});
        try self.w("        CLC", .{});
        try self.w("        ADC #$20", .{});
        try self.w("        LDX ${X}", .{bi.len_slot});
        try self.w("        STA ${X},X", .{bi.data});
        try self.w("        INC ${X}", .{bi.len_slot});
        // peel 8 top bytes, skipping the 8-n leading zeros
        try self.w("        LDA #8", .{});
        try self.w("        SEC", .{});
        try self.w("        SBC ${X}", .{t_cnt});
        try self.w("        STA ${X}", .{t_skip});
        try self.w("        LDA ${X}", .{vslot});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        LDA #8", .{});
        try self.w("        STA ${X}", .{t_cnt});
        const c_emit = self.cost;
        try self.w("L{d}:   LDA ${X}", .{ l_loop, t_skip });
        try self.w("        BEQ L{d}", .{l_emit});
        try self.w("        DEC ${X}", .{t_skip});
        try self.w("        BRA L{d}", .{l_next});
        try self.w("L{d}:   LDA ${X}", .{ l_emit, self.off_t });
        try self.w("        LSR #56             ; the top byte", .{});
        try self.w("        LDX ${X}", .{bi.len_slot});
        try self.w("        STA ${X},X", .{bi.data});
        try self.w("        INC ${X}", .{bi.len_slot});
        try self.w("L{d}:   LDA ${X}", .{ l_next, self.off_t });
        try self.w("        ASL #8", .{});
        try self.w("        STA ${X}", .{self.off_t});
        try self.w("        DEC ${X}", .{t_cnt});
        try self.w("        LDA ${X}", .{t_cnt});
        try self.w("        BNE L{d}", .{l_loop});
        self.cost +|= (self.cost - c_emit) *| 7; // 8 laps, one emitted
        try self.w("L{d}:", .{l_done});
        self.popTmp();
        self.popTmp();
    }

    /// Evaluate a message-field argument into A, masked to the field's
    /// width — skipping the mask when the value provably fits: a literal
    /// masks at compile time, a bound field was masked by its own load.
    fn evalArg(self: *Gen, arg: *const Expr, f: *const Field) Error!void {
        const mask: u64 = if (f.ty.size() < 8)
            (@as(u64, 1) << @intCast(f.ty.size() * 8)) - 1
        else
            ~@as(u64, 0);
        if (arg.* == .int) {
            const v = arg.int & mask;
            if (v <= 127) {
                try self.w("        LDA #{d}", .{v});
            } else {
                try self.w("        LDA ##${X}", .{v});
            }
            return;
        }
        try self.evalInto(arg);
        if (f.ty.size() < 8 and self.maskedTo(arg) > f.ty.size())
            try self.w("        AND ##${X}", .{mask});
    }

    /// The width in bytes an evaluated expression provably fits after
    /// evalInto (8 = unknown): a case binding's field is masked to its
    /// declared size by the load itself.
    fn maskedTo(self: *Gen, e: *const Expr) u16 {
        switch (e.*) {
            .field => |fx| {
                if (self.bind != null and std.mem.eql(u8, self.bind.?, fx.base)) {
                    if (self.bind_msg) |m| {
                        for (m.fields) |*fl| {
                            if (std.mem.eql(u8, fl.name, fx.name)) return fl.ty.size();
                        }
                    }
                }
                return 8;
            },
            else => return 8,
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
        } else if (std.mem.eql(u8, sd.target, "self")) blk: {
            // Amendment 1: the self-send loop. A capability to your own
            // RX ring, loader-staged; delivery is on-chip and lossless
            // (dst_core == src_core never rides the mesh).
            self.uses_self = true;
            break :blk self.off_self;
        } else if (std.mem.eql(u8, sd.target, "boss")) blk: {
            // A child speaking up to its supervisor — the exit link's
            // conversational twin. Probate already lets a child GRANT to
            // `boss`; letting it SEND completes the pair, and it is how a
            // screen tells the Cabinet it is ready to be lent the frame.
            // The loader stages `boss` the same window either way.
            self.uses_boss = true;
            break :blk self.off_boss;
        } else self.slots.get(sd.target) orelse
            return self.fail(sd.line, "unknown send target", Error.Semantics);

        // A4 movement 1, the compiler's early copy of the RBC's check:
        // what this payload claims must equal what the endpoint IS.
        if (sd.target_idx == null and !std.mem.eql(u8, sd.target, "self")) {
            const want: ring.Dialect = if (msg.device()) .ask else .msg;
            const have = self.targetDialect(sd.target);
            if (have != .any and have != want) {
                if (have == .raw)
                    return self.fail(sd.line, "this endpoint takes raw bytes, not a message — `send it, buf` (A4)", Error.Semantics);
                if (have == .ask)
                    return self.fail(sd.line, "this endpoint is an asking device: declare the request with `-> Reply` (A4)", Error.Semantics);
                return self.fail(sd.line, "this endpoint takes a message, not a device request (A4)", Error.Semantics);
            }
        }
        if (msg.device()) {
            // The ask path (A3.3 / §7.3): a device request is not a joe
            // wire image — it is {tag, reply window, arguments}. The tag
            // we stage is the REPLY's, so the answer comes home wearing
            // a name this actor's serve loop already knows; a `-> _`
            // request stages tag 0 and answers to nobody.
            const rtag: u64 = if (msg.reply) |rname| blk: {
                const rmsg = self.message(rname) orelse
                    return self.fail(sd.line, "unknown reply message", Error.Semantics);
                self.asks_devices = true;
                break :blk rmsg.tag;
            } else 0;
            if (sd.target_idx != null or std.mem.eql(u8, sd.target, "self"))
                return self.fail(sd.line, "a device request goes to one device", Error.Semantics);
            try self.w("; {s}: tag, reply window, then arguments (§7.3)", .{msg.name});
            try self.w("        LDA {s}", .{try self.imm(rtag)});
            try self.w("        STA !${X}", .{self.layout.staging()});
            try self.w("        LDA ##${X}", .{device_reply_window});
            try self.w("        STA !${X}", .{self.layout.staging() + 8});
            var raw_buf: ?BufInfo = null;
            var fixed: u16 = 16;
            for (msg.fields, sd.args) |*f, arg| {
                if (f.ty == .bytes_) {
                    // A device takes raw payload — no length byte; the
                    // SQE's length carries the size, as it always did.
                    const bname = switch (arg.*) {
                        .ident => |n| n,
                        else => return self.fail(sd.line, "a device's bytes argument is a buf", Error.Semantics),
                    };
                    const bi = self.bufs.get(bname) orelse
                        return self.fail(sd.line, "a device's bytes argument is a buf", Error.Semantics);
                    // The staged image must fit its room, or it would
                    // scribble on the landing entries next door — the
                    // overlap lesson, charged at compile time.
                    if (f.offset + bi.cap > staging_room)
                        return self.fail(sd.line, "this request overflows the staging area — shrink the buf", Error.Semantics);
                    var wo: u16 = 0;
                    while (wo < bi.cap) : (wo += 8) {
                        try self.w("        LDA ${X}", .{bi.data + wo});
                        try self.w("        STA !${X}", .{self.layout.staging() + f.offset + wo});
                    }
                    raw_buf = bi;
                    continue;
                }
                try self.evalArg(arg, f);
                try self.w("        STA !${X}", .{self.layout.staging() + f.offset});
                fixed = f.offset + 8;
            }
            try self.w("        LDA ##$3_0000_0001  ; SQE: op = send, claim ask (A4)", .{});
            try self.w("        STA !${X}", .{self.layout.sqBase()});
            try self.w("        LDA ${X}", .{tslot});
            try self.w("        STA !${X}", .{self.layout.sqBase() + 8});
            try self.w("        LDA ##${X}", .{self.layout.staging()});
            try self.w("        STA !${X}", .{self.layout.sqBase() + 16});
            if (raw_buf) |bi| {
                try self.w("        LDA ${X}", .{bi.len_slot});
                try self.w("        CLC", .{});
                try self.w("        ADC ##${X}", .{@as(u64, 1) << 32 | fixed});
            } else {
                try self.w("        LDA ##${X}", .{@as(u64, 1) << 32 | fixed});
            }
            try self.w("        STA !${X}", .{self.layout.sqBase() + 24});
            try self.w("        SEND 0", .{});
            return;
        }
        if (msg.is_reply)
            return self.fail(sd.line, "a reply is what a device sends you, not what you send", Error.Semantics);

        if (msg.wire_size <= 8) {
            // TXR path (item 4): the wire word composes in A — the near
            // page holds a partial only between field evaluations, and a
            // single-field message never touches it at all.
            if (msg.fields.len == 0) {
                try self.w("        LDA {s}", .{try self.imm(msg.tag)});
            } else {
                for (msg.fields, sd.args, 0..) |*f, arg, i| {
                    try self.evalArg(arg, f);
                    if (f.offset != 0) try self.w("        ASL #{d}", .{f.offset * 8});
                    if (i == 0) {
                        try self.w("        ORA {s}", .{try self.imm(msg.tag)});
                    } else {
                        try self.w("        ORA ${X}", .{self.off_acc});
                    }
                    if (i + 1 < msg.fields.len) try self.w("        STA ${X}", .{self.off_acc});
                }
            }
            try self.w("        TXR (${X})", .{tslot});
            return;
        }
        // SEND path: each staged word composes in A the same way and
        // stores straight to the staging buffer. A bytes field (always
        // last, 8-aligned) is staged after the fixed words: its length
        // byte, then the payload words.
        const bytes_arg: ?*Expr = blk: {
            if (msg.fields.len > 0 and msg.fields[msg.fields.len - 1].ty == .bytes_)
                break :blk sd.args[msg.fields.len - 1];
            break :blk null;
        };
        const fixed_end: u16 = if (bytes_arg != null) msg.fields[msg.fields.len - 1].offset else msg.wire_size;
        var word: u16 = 0;
        while (word * 8 < fixed_end) : (word += 1) {
            var have = false;
            for (msg.fields, sd.args) |*f, arg| {
                if (f.ty == .grant_) {
                    // grant-on-send (item 6): two words — the region's
                    // descriptor slot, then its live token — and the
                    // compile-time type-state flips: from here to the
                    // done/failed case, the region is unreachable.
                    const fw = f.offset / 8;
                    if (word != fw and word != fw + 1) continue;
                    if (arg.* != .grantref)
                        return self.fail(sd.line, "a grant field wants `grant <region>`", Error.Semantics);
                    const rp = self.regions.getPtr(arg.grantref) orelse
                        return self.fail(sd.line, "grant wants a `region` variable", Error.Semantics);
                    if (rp.locked)
                        return self.fail(sd.line, "this region is already granted out here (§6.2)", Error.Semantics);
                    if (have) try self.w("        STA ${X}", .{self.off_acc});
                    if (word == fw) {
                        try self.w("        LDA {s}", .{try self.imm(rp.slot)});
                    } else {
                        try self.w("        LDA ${X}", .{@as(u64, rp.slot) * ring.desc_size + 24});
                        rp.locked = true; // granted: inaccessible by type
                    }
                    have = true;
                    continue;
                }
                if (f.offset / 8 != word) continue;
                if (have) try self.w("        STA ${X}", .{self.off_acc});
                try self.evalArg(arg, f);
                const bit = (f.offset % 8) * 8;
                if (bit != 0) try self.w("        ASL #{d}", .{bit});
                if (word == 0 and !have) {
                    try self.w("        ORA {s}", .{try self.imm(msg.tag)});
                } else if (have) {
                    try self.w("        ORA ${X}", .{self.off_acc});
                }
                have = true;
            }
            if (!have) {
                // no fields in this word: tag alone (word 0) or zero
                try self.w("        LDA {s}", .{if (word == 0) try self.imm(msg.tag) else "#0"});
            }
            try self.w("        STA !${X}", .{self.layout.staging() + word * 8});
        }
        if (bytes_arg) |arg| {
            const foff = msg.fields[msg.fields.len - 1].offset;
            const cap_msg: u16 = @intCast(abi.land_cap - foff - 1);
            switch (arg.*) {
                .ident => |bname| {
                    const bi = self.bufs.get(bname) orelse
                        return self.fail(sd.line, "a bytes argument is a buf or a bound bytes field (v1)", Error.Semantics);
                    // guard, then length word, then payload words
                    const l_ok = self.label();
                    try self.w("; bytes field: {s}'s length byte + payload", .{bname});
                    try self.w("        LDA ${X}", .{bi.len_slot});
                    try self.w("        CMP {s}", .{try self.imm(cap_msg + 1)});
                    try self.w("        BCC L{d}", .{l_ok});
                    try self.w("        BRK                 ; bytes overflow the envelope", .{});
                    try self.w("L{d}:   STA !${X}", .{ l_ok, self.layout.staging() + foff });
                    var wo: u16 = 0;
                    while (wo < cap_msg) : (wo += 8) {
                        if (wo >= bi.cap) break; // buf shorter than the envelope
                        try self.w("        LDA ${X}", .{bi.data + wo});
                        try self.w("        STA !${X}", .{self.layout.staging() + foff + 1 + wo});
                    }
                },
                .field => |fx| {
                    // forward a bound bytes field whole: word-for-word
                    // copy from the landing buffer (both sides 8-aligned,
                    // the length byte rides the first word).
                    const bind = self.bind orelse
                        return self.fail(sd.line, "a forwarded bytes field needs a case binding", Error.Semantics);
                    if (!std.mem.eql(u8, bind, fx.base))
                        return self.fail(sd.line, "field base is not the case binding", Error.Semantics);
                    const smsg = self.bind_msg.?;
                    const sfld = for (smsg.fields) |*fl| {
                        if (std.mem.eql(u8, fl.name, fx.name)) break fl;
                    } else return self.fail(sd.line, "no such field in the message", Error.Semantics);
                    if (sfld.ty != .bytes_)
                        return self.fail(sd.line, "only a bytes field forwards into a bytes field", Error.Semantics);
                    if (abi.land_cap - sfld.offset < abi.land_cap - foff)
                        return self.fail(sd.line, "the destination bytes field is narrower than the source", Error.Semantics);
                    try self.w("; bytes field: forward {s}.{s} whole", .{ fx.base, fx.name });
                    var wo: u16 = 0;
                    while (sfld.offset + wo < abi.land_cap) : (wo += 8) {
                        try self.w("        LDA ${X}", .{self.off_ptr});
                        try self.w("        CLC", .{});
                        try self.w("        ADC {s}", .{try self.imm(sfld.offset + wo)});
                        try self.w("        STA ${X}", .{self.off_fp});
                        try self.w("        LDA (${X})", .{self.off_fp});
                        try self.w("        STA !${X}", .{self.layout.staging() + foff + wo});
                    }
                },
                else => return self.fail(sd.line, "a bytes argument is a buf or a bound bytes field (v1)", Error.Semantics),
            }
        }
        try self.w("        LDA ##$2_0000_0001  ; SQE: op = send, claim msg (A4)", .{});
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
        // Label the two loops up front: a body `quiesce` needs the
        // lame-duck label even in a serve-less actor.
        self.serve_label = self.label();
        self.quiesce_label = self.label();
        const m_init = self.beginBurst();
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
        if (self.regions.count() > 0) {
            // The descriptor table IS the region table: base, REGION
            // flag, length in bytes, token. Re-staged every life —
            // idempotent respawn, same as the rings.
            try self.w("; region descriptors (grantable; the token is the leash)", .{});
            var rit = self.regions.iterator();
            while (rit.next()) |e| {
                const r = e.value_ptr.*;
                const off = @as(u64, r.slot) * ring.desc_size;
                try self.store(self.layout.data + abi.array_off + r.area, off);
                try self.store(@as(u64, ring.desc_flag_region) << 56, off + 8);
                try self.store(@as(u64, r.len) * 8, off + 16);
                try self.store(abi.token, off + 24);
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
                if (v.ty == .vec_) {
                    try self.storeVec(self.vecs.get(v.name).?, e);
                    continue;
                }
                try self.evalInto(e);
                try self.w("        STA ${X}", .{self.slots.get(v.name).?});
            }
        }
        // Item 7: the MAC comparator vectors, staged like any near word.
        if (self.layout.mac and self.mac_nshapes > 0) {
            try self.w("; MACTAB: one byte-comparator vector per field shape", .{});
            for (0..self.mac_nshapes) |i| {
                try self.w("        LDA ##L{d}", .{self.mc_labels[i]});
                try self.w("        STA ${X}", .{isa.mactab_base + i * 8});
            }
        }
        // Byte-equality tail masks, staged once per life.
        if (self.bufs.count() > 0) {
            try self.w("; tail masks for byte equality", .{});
            var k: u16 = 1;
            while (k < 8) : (k += 1) {
                const mask = (@as(u64, 1) << @intCast(k * 8)) - 1;
                try self.w("        LDA ##${X}", .{mask});
                try self.w("        STA ${X}", .{self.off_masks + k * 8});
            }
        }
        // Pack targets reset their length every life (the near page
        // survives SPWN). A buf never packed keeps its bytes — that is
        // the harness staging contract, and respawn honesty for the rest.
        {
            var bit = self.bufs.iterator();
            var first = true;
            while (bit.next()) |e| {
                if (!self.actorPacksInto(e.key_ptr.*)) continue;
                if (first) try self.w("        LDA #0", .{});
                first = false;
                try self.w("        STA ${X}", .{e.value_ptr.len_slot});
            }
        }

        // opening statements
        self.setRegionLocks(self.actor.body, null);
        try self.stmts(self.actor.body);
        try self.endBurst(m_init, 0, true);

        if (self.actor.handlers.len == 0) {
            if (self.has_quiesce) {
                try self.emitQuiesce();
            } else {
                try self.w("        HLT", .{});
            }
            try self.emitStrings();
            try self.emitMacComparator();
            try self.checkBounds(0);
            return;
        }

        // ── serve ──
        const serve_cost_start = self.cost;
        const l_exit = self.label();
        // The fused deliver test (item 4): word0 low 16 = status<<8 | tag,
        // so `AND ##$FFFF / CMP #deliver` accepts exactly a clean delivery
        // in one compare — acks, exits, timers and empty pops all fail it.
        // word0 rides in Y (registers are free within a burst); the near
        // page is touched only for what the handlers actually need.
        const has_other = self.uses_timer or self.spawn_count > 0 or self.needs_dcount;
        const l_other = if (has_other) self.label() else self.serve_label;
        try self.w("; serve: LSTN, pop, fused deliver test — acks fail one compare", .{});
        try self.w("L{d}:   LSTN 1", .{self.serve_label});
        if (self.layout.mac and self.mac_nshapes > 0) {
            // MAC is JSR-shaped and SP is park-volatile: every burst
            // re-establishes the stack before anything can call. This is
            // the tax item 4 removed and item 7 pays to measure.
            try self.w("        LDX ##${X}", .{self.layout.data + (abi.block_size - abi.data_off)});
            try self.w("        TXS", .{});
        }
        try self.w("        CQPOP 1", .{});
        if (has_other) try self.w("        TAY", .{});
        try self.w("        AND ##$FFFF", .{});
        try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.deliver)});
        try self.w("        BNE L{d}", .{l_other});
        try self.w("        STX ${X}", .{self.off_ptr});
        if (self.needs_dcount) {
            // The fabric counted the bytes; keep the count for whoever
            // forwards a device's raw payload.
            try self.w("        TYA", .{});
            try self.w("        LSR #32", .{});
            try self.w("        AND ##$FFFF_FFFF", .{});
            try self.w("        STA ${X}", .{self.off_dcount});
        }
        try self.emitRegionDispatcher();
        try self.emitCaseLadder(self.actor.handlers, self.serve_label);

        if (has_other) {
            try self.w("; not a delivery: exit and timer peel off, acks fall through", .{});
            try self.w("L{d}:", .{l_other});
            if (self.spawn_count > 0) {
                const l_not_exit = self.label();
                try self.w("        TYA", .{});
                try self.w("        AND #$FF", .{});
                try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.exit)});
                try self.w("        BNE L{d}", .{l_not_exit});
                try self.w("        STY ${X}", .{self.off_w0});
                try self.w("        STX ${X}", .{self.off_ptr});
                try self.w("        BRA L{d}", .{l_exit});
                try self.w("L{d}:", .{l_not_exit});
            }
            if (self.uses_timer) {
                // tag 1 (txr) + cookie $77 in X = the timer tick
                try self.w("        TYA", .{});
                try self.w("        AND #$FF", .{});
                try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.txr)});
                try self.w("        BNE L{d}", .{self.serve_label});
                try self.w("        TXA", .{});
                try self.w("        AND ##$FFFFFFFF", .{});
                try self.w("        CMP #{d}", .{abi.timer_cookie});
                try self.w("        BNE L{d}", .{self.serve_label});
                self.in_handler = true;
                for (self.actor.handlers) |*h| {
                    if (h.* == .after) {
                        self.setRegionLocks(h.after.body, null);
                        const bm = self.beginBurst();
                        try self.stmts(h.after.body);
                        try self.endBurst(bm, h.after.line, false);
                        break;
                    }
                }
                self.in_handler = false;
            }
            try self.w("        BRA L{d}", .{self.serve_label});
        }

        if (self.spawn_count > 0) try self.emitExitRuntime(l_exit);
        if (self.has_quiesce) try self.emitQuiesce();
        try self.emitStrings();
        try self.emitMacComparator();

        // A1.3: everything in the serve region that is not a handler body
        // is dispatch overhead — every burst pays it on top of its own.
        var handler_costs: u64 = 0;
        for (self.bursts.items) |b| {
            if (!b.is_init) handler_costs +|= b.cost;
        }
        try self.checkBounds((self.cost - serve_cost_start) -| handler_costs);
    }

    /// Amendment 1, A1.3: the compiler checks your arithmetic.
    fn checkBounds(self: *Gen, overhead: u64) Error!void {
        if (self.watchdog == 0) {
            // Nobody set a budget, so nothing needs declaring — and a
            // declaration against no budget is noise the language rejects.
            if (self.brecs.items.len > 0)
                return self.fail(
                    self.brecs.items[0].line,
                    "gratuitous `bounded` (A1.3): this actor has no watchdog, nobody is counting",
                    Error.Semantics,
                );
            return;
        }
        var bi: usize = 0;
        for (self.bursts.items) |b| {
            const total = b.cost +| (if (b.is_init) 0 else overhead);
            const recs = self.brecs.items[bi .. bi + b.nbounded];
            bi += b.nbounded;
            for (recs) |r| {
                if (!r.body_dyn and r.n < r.body_cost)
                    return self.fail(
                        r.line,
                        "`bounded` understates the computed worst case (A1.3): you cannot understate your appetite",
                        Error.Semantics,
                    );
            }
            if (b.nbounded == 0) {
                if (b.dyn)
                    return self.fail(
                        b.line,
                        "this handler's worst case is data-dependent (A1.3): declare `bounded N`",
                        Error.Semantics,
                    );
                if (total > self.watchdog)
                    return self.fail(
                        b.line,
                        "computed worst case exceeds the watchdog budget (A1.3): declare `bounded N`",
                        Error.Semantics,
                    );
            } else if (!b.dyn and total <= self.watchdog) {
                return self.fail(
                    b.line,
                    "gratuitous `bounded` (A1.3): this handler fits the watchdog budget",
                    Error.Semantics,
                );
            }
        }
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

    /// Walker addressing for patterns and `.count()`: a buf walks with X
    /// against its near-page slab; a message bytes field walks with Y
    /// through a pointer at the landing buffer. The limit slot holds the
    /// subject length in cursor coordinates.
    const PatCtx = struct {
        is_buf: bool,
        data: u16 = 0,
        ptr_tmp: u16 = 0,
        lim_slot: u16,
    };

    fn patLoad(self: *Gen, ctx: PatCtx) Error!void {
        if (ctx.is_buf) {
            try self.w("        LDA ${X},X", .{ctx.data});
        } else {
            try self.w("        LDA (${X}),Y", .{ctx.ptr_tmp});
        }
    }

    fn patCursorToA(self: *Gen, ctx: PatCtx) Error!void {
        try self.w("        {s}", .{if (ctx.is_buf) @as([]const u8, "TXA") else "TYA"});
    }

    fn patAdvance(self: *Gen, ctx: PatCtx, k: u16) Error!void {
        if (k == 1) {
            try self.w("        {s}", .{if (ctx.is_buf) @as([]const u8, "INX") else "INY"});
            return;
        }
        try self.patCursorToA(ctx);
        try self.w("        CLC", .{});
        try self.w("        ADC {s}", .{try self.imm(k)});
        try self.w("        {s}", .{if (ctx.is_buf) @as([]const u8, "TAX") else "TAY"});
    }

    /// `cursor + k must not pass the limit` — branch to fail if it would.
    fn patBound(self: *Gen, ctx: PatCtx, k: u16, l_fail: usize) Error!void {
        const l_ok = self.label();
        try self.patCursorToA(ctx);
        if (k > 0) {
            try self.w("        CLC", .{});
            try self.w("        ADC {s}", .{try self.imm(k)});
        }
        try self.w("        CMP ${X}", .{ctx.lim_slot});
        try self.w("        BEQ L{d}", .{l_ok});
        try self.w("        BCS L{d}", .{l_fail});
        try self.w("L{d}:", .{l_ok});
    }

    /// A2.4: `subject is ("users", ?id, ..rest)`. Constant segments fuse
    /// into word compares against pre-packed bytes; `?x` decodes and
    /// binds one integer element (a non-subset element fails the match,
    /// it does not fault); `..rest` binds the remaining bytes as a view
    /// value (cursor<<32 | remaining); no rest means end-of-stream.
    fn emitPattern(self: *Gen, pat: *const Pattern, l_fail: usize) Error!void {
        var ctx: PatCtx = undefined;
        var tmps: u8 = 0;
        switch (pat.subject.*) {
            .ident => |bname| {
                const bi = self.bufs.get(bname) orelse
                    return self.fail(pat.line, "the match subject is not a buf", Error.Semantics);
                ctx = .{ .is_buf = true, .data = bi.data, .lim_slot = bi.len_slot };
                try self.w("; pattern over buf {s}", .{bname});
                try self.w("        LDX #0", .{});
            },
            .field => |fx| {
                const bind = self.bind orelse
                    return self.fail(pat.line, "field access outside a case", Error.Semantics);
                if (!std.mem.eql(u8, bind, fx.base))
                    return self.fail(pat.line, "field base is not the case binding", Error.Semantics);
                const msg = self.bind_msg.?;
                const fld = for (msg.fields) |*fl| {
                    if (std.mem.eql(u8, fl.name, fx.name)) break fl;
                } else return self.fail(pat.line, "no such field in the message", Error.Semantics);
                if (fld.ty != .bytes_)
                    return self.fail(pat.line, "the match subject is not a bytes field", Error.Semantics);
                const ptr_tmp = try self.pushTmp();
                const lim_tmp = try self.pushTmp();
                tmps = 2;
                try self.w("; pattern over {s}.{s}", .{ fx.base, fx.name });
                try self.w("        LDA ${X}", .{self.off_ptr});
                try self.w("        CLC", .{});
                try self.w("        ADC {s}", .{try self.imm(fld.offset)});
                try self.w("        STA ${X}", .{ptr_tmp});
                // limit = length byte + 1: cursor space starts past it
                try self.w("        LDA (${X})", .{ptr_tmp});
                try self.w("        AND #$FF", .{});
                try self.w("        CLC", .{});
                try self.w("        ADC #1", .{});
                try self.w("        STA ${X}", .{lim_tmp});
                ctx = .{ .is_buf = false, .ptr_tmp = ptr_tmp, .lim_slot = lim_tmp };
                try self.w("        LDY #1", .{});
            },
            else => return self.fail(pat.line, "a match subject is a bytes field or a buf", Error.Semantics),
        }
        defer while (tmps > 0) : (tmps -= 1) self.popTmp();

        var i: usize = 0;
        while (i < pat.elems.len) {
            switch (pat.elems[i]) {
                .lit_str, .lit_int => {
                    // coalesce the constant run and compare it in words
                    var blob = struple.Packer.init(self.arena);
                    while (i < pat.elems.len) : (i += 1) {
                        switch (pat.elems[i]) {
                            .lit_str => |s| blob.appendString(s) catch return Error.OutOfMemory,
                            .lit_int => |v| blob.appendUint(v) catch return Error.OutOfMemory,
                            .bind => break,
                        }
                    }
                    const b = blob.bytes();
                    try self.patBound(ctx, @intCast(b.len), l_fail);
                    var off: u16 = 0;
                    while (off < b.len) : (off += 8) {
                        const k: u16 = @intCast(@min(8, b.len - off));
                        try self.patLoad(ctx);
                        if (k < 8) {
                            const mask = (@as(u64, 1) << @intCast(k * 8)) - 1;
                            try self.w("        AND ##${X}", .{mask});
                        }
                        try self.w("        CMP ##${X}", .{chunkWord(b[off..])});
                        try self.w("        BNE L{d}", .{l_fail});
                        try self.patAdvance(ctx, k);
                    }
                },
                .bind => |bname| {
                    i += 1;
                    const bslot = try self.getOrAddSlot(bname);
                    const t_w = try self.pushTmp();
                    const t_val = try self.pushTmp();
                    defer {
                        self.popTmp();
                        self.popTmp();
                    }
                    const l_nz = self.label();
                    const l_end = self.label();
                    const l_loop = self.label();
                    try self.patBound(ctx, 1, l_fail);
                    try self.patLoad(ctx);
                    try self.w("        AND #$FF", .{});
                    try self.w("        CMP #$20", .{});
                    try self.w("        BNE L{d}", .{l_nz});
                    try self.w("        LDA #0              ; canonical zero", .{});
                    try self.w("        STA ${X}", .{bslot});
                    try self.patAdvance(ctx, 1);
                    try self.w("        BRA L{d}", .{l_end});
                    // positive fixed 1..8 only — anything else fails the match
                    try self.w("L{d}:   SEC", .{l_nz});
                    try self.w("        SBC #$20", .{});
                    try self.w("        CMP #9", .{});
                    try self.w("        BCS L{d}", .{l_fail});
                    try self.w("        STA ${X}", .{t_w});
                    try self.w("        CLC", .{});
                    try self.w("        ADC #1", .{});
                    try self.w("        STA ${X}", .{self.off_t});
                    // bounds: cursor + 1 + w within the subject
                    {
                        const l_ok = self.label();
                        try self.patCursorToA(ctx);
                        try self.w("        CLC", .{});
                        try self.w("        ADC ${X}", .{self.off_t});
                        try self.w("        CMP ${X}", .{ctx.lim_slot});
                        try self.w("        BEQ L{d}", .{l_ok});
                        try self.w("        BCS L{d}", .{l_fail});
                        try self.w("L{d}:", .{l_ok});
                    }
                    try self.patAdvance(ctx, 1);
                    try self.w("        LDA #0", .{});
                    try self.w("        STA ${X}", .{t_val});
                    const c_loop = self.cost;
                    try self.w("L{d}:   LDA ${X}", .{ l_loop, t_val });
                    try self.w("        ASL #8", .{});
                    try self.w("        STA ${X}", .{t_val});
                    try self.patLoad(ctx);
                    try self.w("        AND #$FF", .{});
                    try self.w("        ORA ${X}", .{t_val});
                    try self.w("        STA ${X}", .{t_val});
                    try self.patAdvance(ctx, 1);
                    try self.w("        DEC ${X}", .{t_w});
                    try self.w("        LDA ${X}", .{t_w});
                    try self.w("        BNE L{d}", .{l_loop});
                    self.cost +|= (self.cost - c_loop) *| 7; // ≤ 8 magnitude bytes
                    try self.w("        LDA ${X}", .{t_val});
                    try self.w("        STA ${X}", .{bslot});
                    try self.w("L{d}:", .{l_end});
                },
            }
        }
        if (pat.rest) |rname| {
            const rslot = try self.getOrAddSlot(rname);
            try self.w("; ..{s}: view = cursor<<32 | remaining", .{rname});
            try self.patCursorToA(ctx);
            try self.w("        STA ${X}", .{self.off_t});
            try self.w("        LDA ${X}", .{ctx.lim_slot});
            try self.w("        SEC", .{});
            try self.w("        SBC ${X}", .{self.off_t});
            try self.w("        STA ${X}", .{self.off_acc});
            try self.patCursorToA(ctx);
            try self.w("        ASL #32", .{});
            try self.w("        ORA ${X}", .{self.off_acc});
            try self.w("        STA ${X}", .{rslot});
        } else {
            // no rest: the pattern owns the whole subject
            try self.patCursorToA(ctx);
            try self.w("        CMP ${X}", .{ctx.lim_slot});
            try self.w("        BNE L{d}", .{l_fail});
        }
    }

    /// The $6772 family (item 6, A4 movement 3): deliveries whose word0
    /// low16 is the architected $6772 — far outside any program's tag
    /// space — carrying region business rather than a program message.
    /// The KIND byte at bits 24..31 says which:
    ///
    ///   kind 0 — a grant I MADE completed: status at 16..23, my region
    ///            slot in word1. Routed to `case done(r)` / `failed(r)`.
    ///   kind 1 — a grant I RECEIVED: routed to `case handoff(h)`.
    ///
    /// Unmatched ones are consumed, so the case ladder never sees region
    /// business and the sole-case elision stays sound. That elision is
    /// why the low16 must be $6772 and not merely contain it: a program
    /// whose sole case is tag 1 does no tag test at all, and an
    /// inheritance arriving as "tag 1" would be handled as that message.
    fn emitRegionDispatcher(self: *Gen) Error!void {
        var any = false;
        var rit = self.regions.iterator();
        while (rit.next()) |e| {
            if (e.value_ptr.granted_anywhere) any = true;
        }
        var handoff: ?@TypeOf(self.actor.handlers[0].handoff_case) = null;
        for (self.actor.handlers) |*h| {
            if (h.* == .handoff_case) handoff = h.handoff_case;
        }
        if (!any and handoff == null) return;
        const l_not = self.label();
        try self.w("; region business: the $6772 family, kind byte at 24..31", .{});
        try self.w("        LDA (${X})", .{self.off_ptr});
        try self.w("        AND ##$FFFF", .{});
        try self.w("        CMP ##$6772", .{});
        try self.w("        BNE L{d}", .{l_not});
        if (handoff) |hc| {
            const l_not_handoff = self.label();
            try self.w("; kind 1: an estate arrived — `case handoff({s})`", .{hc.bind});
            try self.w("        LDA (${X})", .{self.off_ptr});
            try self.w("        LSR #24", .{});
            try self.w("        AND #$FF", .{});
            try self.w("        CMP #1", .{});
            try self.w("        BNE L{d}", .{l_not_handoff});
            self.handoff_bind = hc.bind;
            self.setRegionLocks(hc.body, null);
            self.in_handler = true;
            const bm = self.beginBurst();
            try self.stmts(hc.body);
            try self.endBurst(bm, hc.line, false);
            self.in_handler = false;
            self.handoff_bind = null;
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_not_handoff});
        }
        if (!any) {
            // Nothing of ours is out on loan: consume and go round.
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_not});
            return;
        }
        try self.w("        LDA ${X}", .{self.off_ptr});
        try self.w("        CLC", .{});
        try self.w("        ADC #8", .{});
        try self.w("        STA ${X}", .{self.off_fp});
        try self.w("        LDA (${X})", .{self.off_fp});
        try self.w("        AND #$FF", .{});
        rit = self.regions.iterator();
        while (rit.next()) |e| {
            const rname = e.key_ptr.*;
            const r = e.value_ptr.*;
            if (!r.granted_anywhere) continue;
            var done_body: ?[]const Stmt = null;
            var done_line: usize = 0;
            var fail_body: ?[]const Stmt = null;
            var fail_line: usize = 0;
            for (self.actor.handlers) |*h| {
                if (h.* != .case) continue;
                const c = h.case;
                if (c.bind == null or !std.mem.eql(u8, c.bind.?, rname)) continue;
                if (std.mem.eql(u8, c.msg, "done")) {
                    done_body = c.body;
                    done_line = c.line;
                } else if (std.mem.eql(u8, c.msg, "failed")) {
                    fail_body = c.body;
                    fail_line = c.line;
                }
            }
            if (done_body == null and fail_body == null) continue;
            const l_next = self.label();
            const l_fail = self.label();
            try self.w("; region {s}: rebind on completion", .{rname});
            try self.w("        CMP {s}", .{try self.imm(r.slot)});
            try self.w("        BNE L{d}", .{l_next});
            try self.w("        LDA (${X})", .{self.off_ptr});
            try self.w("        LSR #16", .{});
            try self.w("        AND #$FF", .{});
            try self.w("        BNE L{d}", .{l_fail});
            if (done_body) |body| {
                self.setRegionLocks(body, rname);
                self.in_handler = true;
                const bm = self.beginBurst();
                try self.stmts(body);
                try self.endBurst(bm, done_line, false);
                self.in_handler = false;
            }
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_fail});
            if (fail_body) |body| {
                self.setRegionLocks(body, rname);
                self.in_handler = true;
                const bm = self.beginBurst();
                try self.stmts(body);
                try self.endBurst(bm, fail_line, false);
                self.in_handler = false;
            }
            try self.w("        BRA L{d}", .{self.serve_label});
            try self.w("L{d}:", .{l_next});
        }
        try self.w("        BRA L{d}", .{self.serve_label});
        try self.w("L{d}:", .{l_not});
    }

    /// The delivery dispatch (item 4): the message tag once in A, then a
    /// compare ladder — two instructions per non-matching case, guards
    /// reloading the stashed tag on failure. A sole unguarded case skips
    /// the test entirely: the wire is closed (every sender compiles from
    /// this same source), so one pattern means every delivery matches.
    fn emitCaseLadder(self: *Gen, handlers: []const Handler, loop_label: usize) Error!void {
        var case_count: usize = 0;
        var any_guard = false;
        for (handlers) |*h| {
            if (h.* != .case) continue;
            if (self.isRegionCase(h.case)) continue; // routed by $6772, not by tag
            case_count += 1;
            if (h.case.where != null or h.case.pat != null) any_guard = true;
        }
        if (case_count == 0) {
            try self.w("        BRA L{d}", .{loop_label});
            return;
        }
        // The elision is sound only while the wire is closed. A program
        // that grants has a sender the vocabulary does not cover, so the
        // tag test earns its two instructions back.
        if (case_count == 1 and !any_guard and !programGrants(self.prog)) {
            for (handlers) |*h| {
                if (h.* != .case) continue;
                if (self.isRegionCase(h.case)) continue;
                const c = h.case;
                const msg = self.message(c.msg) orelse
                    return self.fail(c.line, "unknown message in case", Error.Semantics);
                try self.w("; case {s}({s}) — sole pattern, closed wire: no tag test", .{ c.msg, c.bind orelse "_" });
                self.bind = c.bind;
                self.bind_msg = msg;
                self.setRegionLocks(c.body, null);
                self.in_handler = true;
                const bm = self.beginBurst();
                try self.stmts(c.body);
                try self.endBurst(bm, c.line, false);
                self.in_handler = false;
                self.bind = null;
                self.bind_msg = null;
                try self.w("        BRA L{d}", .{loop_label});
            }
            return;
        }
        try self.w("        LDA (${X})", .{self.off_ptr});
        try self.w("        AND ##$FFFF", .{});
        if (any_guard) try self.w("        STA ${X}", .{self.off_t});
        for (handlers) |*h| {
            if (h.* != .case) continue;
            if (self.isRegionCase(h.case)) continue;
            const c = h.case;
            const msg = self.message(c.msg) orelse
                return self.fail(c.line, "unknown message in case", Error.Semantics);
            const l_next = self.label();
            try self.w("; case {s}({s})", .{ c.msg, c.bind orelse "_" });
            try self.w("        CMP {s}", .{try self.imm(msg.tag)});
            try self.w("        BNE L{d}", .{l_next});
            self.bind = c.bind;
            self.bind_msg = msg;
            var l_fail: ?usize = null;
            if (c.where != null or c.pat != null) l_fail = self.label();
            if (c.where) |g| try self.branchIfFalse(g, l_fail.?);
            if (c.pat) |*p| try self.emitPattern(p, l_fail.?);
            self.setRegionLocks(c.body, null);
            self.in_handler = true;
            const bm = self.beginBurst();
            try self.stmts(c.body);
            try self.endBurst(bm, c.line, false);
            self.in_handler = false;
            self.bind = null;
            self.bind_msg = null;
            try self.w("        BRA L{d}", .{loop_label});
            if (l_fail) |lf| {
                // guard failed: restore the tag and try the next case
                try self.w("L{d}:   LDA ${X}", .{ lf, self.off_t });
            }
            try self.w("L{d}:", .{l_next});
        }
        try self.w("        BRA L{d}", .{loop_label});
    }

    /// The lame-duck loop (sketch §2.3): a restricted case set, no
    /// timers, everything else consumed in silence. Stragglers converge;
    /// the machine goes quiet instead of staying awake.
    fn emitQuiesce(self: *Gen) Error!void {
        const lq = self.quiesce_label;
        // Case-body BRAs loop back to the quiesce serve, not the live one.
        const saved = self.serve_label;
        self.serve_label = lq;
        defer self.serve_label = saved;
        try self.w("; quiesce: the lame-duck serve — same fused test, timers dead", .{});
        try self.w("L{d}:   LSTN 1", .{lq});
        if (self.layout.mac and self.mac_nshapes > 0) {
            try self.w("        LDX ##${X}", .{self.layout.data + (abi.block_size - abi.data_off)});
            try self.w("        TXS", .{});
        }
        try self.w("        CQPOP 1", .{});
        try self.w("        AND ##$FFFF", .{});
        try self.w("        CMP #{d}", .{@intFromEnum(ring.Tag.deliver)});
        try self.w("        BNE L{d}", .{lq});
        try self.w("        STX ${X}", .{self.off_ptr});
        try self.emitCaseLadder(self.actor.quiesce, lq);
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
                self.setRegionLocks(h.exit_case.body, null);
                self.in_handler = true;
                const bm = self.beginBurst();
                try self.stmts(h.exit_case.body);
                try self.endBurst(bm, h.exit_case.line, false);
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

/// A `buf [N]u8` as the harness sees it: length slot and data slab are
/// near-page offsets.
pub const BufOut = struct { name: []const u8, len_slot: u16, data: u16, cap: u16 };

pub const Slot = struct {
    name: []const u8,
    off: u16,
    addr: bool = false,
    /// An f64 slot: the value is float bits — display it as one.
    f64: bool = false,
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
    /// The supervisor's near slot for a capability to this child, when it
    /// was named (`spawn … as w`). The loader mints the PTT entry — aimed
    /// at the child's RX ring — and stages the window here. null = unnamed.
    cap_off: ?u16 = null,
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
    /// Set when the actor says `send self` (Amendment 1): the near slot
    /// where the loader stages a capability to the actor's own RX ring.
    self_slot: ?u16,
    /// Where the loader stages a child's capability to its supervisor
    /// (A4 movement 3), when the actor grants anything to `boss`.
    boss_slot: ?u16 = null,
    /// Set when the actor asks a device (A3.3): every answering device
    /// it holds a capability to needs its reply window aimed back here.
    asks_devices: bool = false,
    /// The actor's byte buffers (A2.1) — harnesses stage into and read
    /// out of the near page through these.
    bufs: []BufOut,

    pub fn deinit(self: *Result) void {
        for (self.params) |p| self.alloc.free(p.name);
        for (self.vars) |v| self.alloc.free(v.name);
        for (self.bufs) |b| self.alloc.free(b.name);
        self.alloc.free(self.bufs);
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
    // own alignment, wire size padded to 8. A `bytes` field (A2.5) sits
    // last: one length byte, then the payload filling the envelope.
    for (prog.messages, 0..) |*m, i| {
        m.tag = @intCast(i + 1);
        // A3.3's two device layouts. An ASK's arguments go one per word
        // behind the tag and the reply window (§7.3's framing — a device
        // does not speak joe, so nothing packs); a REPLY's fields go one
        // per word behind the echoed tag. Both keep field offsets, so
        // the case ladder and every field load stay exactly as they are.
        if (m.device() or m.is_reply) {
            var doff: u16 = if (m.is_reply) 8 else 16;
            for (m.fields, 0..) |*f, fi| {
                if (f.ty == .bytes_) {
                    if (fi + 1 != m.fields.len) {
                        if (diag) |d| d.message = "a bytes field goes last (v1)";
                        return Error.Semantics;
                    }
                    f.offset = doff;
                    doff = abi.land_cap;
                    continue;
                }
                f.offset = doff;
                doff += 8;
            }
            m.wire_size = std.mem.alignForward(u16, @max(doff, 16), 8);
            if (m.wire_size > abi.land_cap) {
                if (diag) |d| d.message = "device message larger than a landing buffer";
                return Error.Semantics;
            }
            continue;
        }
        var off: u16 = 2; // the tag word
        for (m.fields, 0..) |*f, fi| {
            if (f.ty == .bytes_) {
                if (fi + 1 != m.fields.len) {
                    if (diag) |d| d.message = "a bytes field goes last (v1)";
                    return Error.Semantics;
                }
                // 8-aligned so the length byte + payload stage and
                // forward as whole words.
                f.offset = std.mem.alignForward(u16, off, 8);
                if (f.offset + 2 > abi.land_cap) {
                    if (diag) |d| d.message = "no room left for a bytes field";
                    return Error.Semantics;
                }
                off = abi.land_cap; // length byte + payload take the rest
                continue;
            }
            const a = f.ty.size();
            off = std.mem.alignForward(u16, off, @min(a, 8));
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
        .lets = std.StringHashMap(bool).init(arena),
        .records = .init(arena),
        .child_caps = .init(arena),
        .childcap_of = .init(arena),
        .spawn_list = .init(arena),
        .spawn_idx = .init(arena),
        .const_labels = std.StringHashMap(usize).init(arena),
        .strings = .init(arena),
        .arrays = .init(arena),
        .bufs = .init(arena),
        .vecs = .init(arena),
        .regions = .init(arena),
        .bursts = .init(arena),
        .brecs = .init(arena),
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
        if (v.array > 0 or v.buf_cap > 0 or v.region_len > 0 or v.ty == .vec_) continue; // wide things aren't scalar readbacks
        try vars.append(.{
            .name = try alloc.dupe(u8, v.name),
            .off = gen.slots.get(v.name).?,
            .f64 = v.ty == .f64_,
        });
    }
    var bufs_out = std.ArrayList(BufOut).init(alloc);
    errdefer bufs_out.deinit();
    {
        var bit = gen.bufs.iterator();
        while (bit.next()) |e| {
            try bufs_out.append(.{
                .name = try alloc.dupe(u8, e.key_ptr.*),
                .len_slot = e.value_ptr.len_slot,
                .data = e.value_ptr.data,
                .cap = e.value_ptr.cap,
            });
        }
    }
    // Canonical spawn order (body then handlers), the same walk that fixed
    // every record index — so SpawnOut[k] is the site a `SPWN` reads at
    // spawnRec(k), whether that spawn lives in the body or a handler.
    var spawns = std.ArrayList(SpawnOut).init(alloc);
    errdefer spawns.deinit();
    for (gen.spawn_list.items, 0..) |s, k| {
        try spawns.append(.{
            .actor = try alloc.dupe(u8, s.spawn.actor),
            .rec_off = gen.spawnRec(@intCast(k)),
            .restarts = s.spawn.restarts,
            .watchdog = s.spawn.watchdog,
            .args = try alloc.dupe(u64, s.spawn.args),
            .cap_off = gen.childcap_of.get(@intCast(k)),
        });
    }
    return .{
        .alloc = alloc,
        .asm_text = try gen.out.toOwnedSlice(),
        .params = try params.toOwnedSlice(),
        .vars = try vars.toOwnedSlice(),
        .spawns = try spawns.toOwnedSlice(),
        .uses_timer = gen.uses_timer,
        .timer_period = gen.timer_period,
        .self_slot = if (gen.uses_self) gen.off_self else null,
        .boss_slot = if (gen.uses_boss) gen.off_boss else null,
        .asks_devices = gen.asks_devices,
        .bufs = try bufs_out.toOwnedSlice(),
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "joe: pingpong compiles and assembles" {
    const src = @embedFile("programs/joe/pingpong.joe");
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

test "joe A1.1: `while` is not deferred — it is not in the language" {
    const src =
        \\actor A(n u64) {
        \\    var x u64 = 0
        \\    while x < n { x += 1 }
        \\    serve { }
        \\}
    ;
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator, src, "A", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "self-send loop") != null);
}

// A1.3 fixtures: W is spawned with a watchdog, so its bursts are checked.
fn a13Src(comptime handler: []const u8, comptime watchdog: []const u8) []const u8 {
    return
        \\actor Boss() {
        \\    spawn W() restarts 0 watchdog
    ++ " " ++ watchdog ++
        \\
        \\    serve {
        \\        case exit(w, abandoned):
        \\            halt ok
        \\    }
        \\}
        \\actor W(n u64) {
        \\    var x u64 = 0
        \\    serve {
        \\        after 500:
        \\
    ++ handler ++
        \\
        \\    }
        \\}
    ;
}

test "joe A1.3: you cannot understate your appetite" {
    // Five statements the compiler can add up exactly; `bounded 5` is a lie
    // told in arithmetic, and arithmetic is checked now.
    const src = comptime a13Src(
        \\            bounded 5 {
        \\                x += 1
        \\                x += 2
        \\            }
    , "400");
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator, src, "W", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "understate") != null);
}

test "joe A1.3: a data-dependent extent demands a declaration" {
    // n is runtime data — the analysis cannot see this bound, so the
    // programmer must say it out loud (and the watchdog judges it).
    const src = comptime a13Src(
        \\            for i in 0..n { x += 1 }
    , "400");
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator, src, "W", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "data-dependent") != null);
}

test "joe A1.3: a computed bound over budget demands a declaration" {
    const src = comptime a13Src(
        \\            for i in 0..100 { x += 1 }
    , "400");
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator, src, "W", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "exceeds the watchdog") != null);
}

test "joe A1.3: an honest declaration over budget is accepted" {
    const src = comptime a13Src(
        \\            bounded 100000 {
        \\                for i in 0..100 { x += 1 }
        \\            }
    , "400");
    var r = try compile(testing.allocator, src, "W", .{}, null);
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.asm_text, "WDEX ##100000") != null);
}

test "joe A1.3: a gratuitous bounded is rejected" {
    // The handler fits the budget with room to spare: the declaration is
    // noise, and the compiler will not accept it.
    const src = comptime a13Src(
        \\            bounded 300 { x += 1 }
    , "100000");
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator, src, "W", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "gratuitous") != null);
}

test "joe A1.3: bounded without a watchdog is gratuitous too" {
    const src =
        \\actor A() {
        \\    var x u64 = 0
        \\    serve {
        \\        after 500:
        \\            bounded 100 { x += 1 }
        \\    }
        \\}
    ;
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator, src, "A", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "nobody is counting") != null);
}

test "joe A3.1: let binds, scopes to its block, and refuses reassignment" {
    var r = try compile(testing.allocator,
        \\actor A() {
        \\    var x u64 = 0
        \\    var y f64 = 0.0
        \\    serve {
        \\        case Go(_):
        \\            let t = x + 3
        \\            let f = y * 2.0
        \\            x = t + t
        \\            if f > 1.5 { x += 1 }
        \\    }
        \\}
        \\message Go { }
    , "A", .{}, null);
    defer r.deinit();
    // f64-typed let: the comparison compiled through FCMP.
    try testing.expect(std.mem.indexOf(u8, r.asm_text, "FCMP") != null);
}

test "joe A3.1: a let is a binding, not a variable" {
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator,
        \\actor A() {
        \\    var x u64 = 0
        \\    serve {
        \\        case Go(_):
        \\            let t = x + 1
        \\            t = 5
        \\    }
        \\}
        \\message Go { }
    , "A", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "binding, not a variable") != null);
}

test "joe A3.1: a let does not shadow" {
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator,
        \\actor A() {
        \\    var x u64 = 0
        \\    serve {
        \\        case Go(_):
        \\            let x = 3
        \\            x = x
        \\    }
        \\}
        \\message Go { }
    , "A", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "does not shadow") != null);
}

test "joe A3.4: a record is named offsets, read and written by field" {
    var r = try compile(testing.allocator,
        \\struct Anim { last u64, index u64, cell u64 }
        \\message Tick { }
        \\actor P() {
        \\    var anim Anim
        \\    var seen u64 = 0
        \\    serve {
        \\        case Tick(_):
        \\            anim.index += 1
        \\            anim.cell = anim.index + 3
        \\            seen = anim.cell
        \\    }
        \\}
    , "P", .{}, null);
    defer r.deinit();
    // Three fields, three consecutive near slots — and `anim` names the
    // first, so the field slots differ by 8.
    const base = for (r.vars) |v| {
        if (std.mem.eql(u8, v.name, "anim")) break v.off;
    } else unreachable;
    const seen = for (r.vars) |v| {
        if (std.mem.eql(u8, v.name, "seen")) break v.off;
    } else unreachable;
    try testing.expectEqual(base + 24, seen); // the record took three slots
}

test "joe A3.4: a record holds scalars, not heaps" {
    var diag = Diagnostic{};
    try testing.expectError(Error.Unsupported, compile(testing.allocator,
        \\struct Bad { payload bytes }
        \\actor P() { var b Bad }
    , "P", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "a shape, not a heap") != null);
}

test "joe A4.1: a framed message at a raw sink is a compile error" {
    // The politely-printed bug. Before A4 this compiled, and the console
    // dutifully printed the request's bytes.
    var diag = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator,
        \\message Write { op u64 }
        \\actor A(tty addr) {
        \\    send tty, Write{1}
        \\}
        \\system {
        \\    a = A(tty)
        \\    tty = Console()
        \\}
    , "A", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "takes raw bytes") != null);
}

test "joe A4.1: raw bytes at an actor, and an undeclared ask, are compile errors" {
    var diag = Diagnostic{};
    // Bytes at an actor: they would arrive as a message with a nonsense tag.
    try testing.expectError(Error.Semantics, compile(testing.allocator,
        \\message Go { }
        \\actor A(peer addr) {
        \\    var b buf [16]u8
        \\    append b, "hi"
        \\    send peer, b
        \\}
        \\actor B() { serve { case Go(_): halt ok } }
        \\system {
        \\    a = A(b)
        \\    b = B()
        \\}
    , "A", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "takes messages, not raw bytes") != null);

    // A plain message at an asking device: word1 would be read as a
    // reply window in the DEVICE's PTT space — the §7.3 hazard, made
    // unrepresentable.
    var diag2 = Diagnostic{};
    try testing.expectError(Error.Semantics, compile(testing.allocator,
        \\message Draw { count u64 }
        \\actor A(well addr) {
        \\    send well, Draw{8}
        \\}
        \\system {
        \\    a = A(well)
        \\    well = Entropy()
        \\}
    , "A", .{}, &diag2));
    try testing.expect(std.mem.indexOf(u8, diag2.message, "asking device") != null);
}

test "joe: the system block parses into a plan" {
    const src = @embedFile("programs/joe/pingpong.joe");
    var p = try plan(testing.allocator, src, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.instances.len);
    try testing.expectEqualStrings("pinger", p.instances[0].name);
    try testing.expectEqualStrings("Pinger", p.instances[0].actor);
    try testing.expectEqual(@as(usize, 2), p.instances[0].args.len);
    try testing.expectEqualStrings("ponger", p.instances[0].args[0].ref);
    try testing.expectEqual(@as(u64, 8), p.instances[0].args[1].int);
}
