//! The 6564-Net machine: banked contexts, cores, the hardware scheduler and
//! the cycle-stepped discrete-event loop that binds cores to the mesh.
//!
//! ## Address space (per context)
//!
//!   0x0000 .. 0x0FFF   near page — private per context (§3.1)
//!   0x1000 .. ram_end  core RAM — shared by the core's contexts (code,
//!                      data, stacks, ring storage). Contexts are actors;
//!                      sharing RAM within a core is a v0.1 simplification
//!                      recorded in docs/simulator.md.
//!   0xFF.. ........    network window (§3.2): PTT index in bits 55..40.
//!
//! Loads from the network window fault (`remote_load`): remote reads are a
//! software protocol built from SEND/RECV, not a synchronous bus operation.
//! Stores to the window become single-word datagrams (TXR semantics).
//!
//! ## Scheduling
//!
//! Cooperative, per the spec's §5: a context runs until it parks (`LSTN` on
//! an empty ring), yields (`YLD`), halts, or faults; the core then
//! bank-switches to the next runnable continuation. The switch itself is
//! free (§2.2) — zero cycles. Cores advance on private clocks; the machine
//! steps whichever core is furthest behind, and mesh events fire when the
//! virtual clock passes their due cycle. Ties break by core index and event
//! sequence number, so every run is exactly reproducible from its seed.

const std = @import("std");
const isa = @import("isa.zig");
const ring = @import("ring.zig");
const mesh = @import("mesh.zig");

pub const near_size = 0x1000;
pub const ram_base: u64 = 0x1000;

pub const Fault = enum {
    none,
    bad_opcode,
    bad_address,
    /// Load through the network window — not an architectural operation.
    remote_load,
    /// Store through a PTT slot lacking send rights, or an empty PTT slot.
    no_capability,
    /// RECV posted to a full ring, or a descriptor with zero entry size.
    bad_descriptor,
    /// BRK executed.
    brk,
    /// The context held the pipeline past its watchdog burst budget (§5.4):
    /// a compute-hung actor, force-faulted so its exit link can speak.
    watchdog,
    /// MAC through a zero vector: a bug, not a jump to page zero.
    bad_macro,
};

pub const CtxState = enum {
    /// Not started, or finished: not on the run queue, not waiting.
    idle,
    /// On the run queue (or currently executing).
    ready,
    /// Parked by LSTN, waiting on a ring (park_slot).
    parked,
    halted,
    faulted,
};

/// An exit link (§5 of the spec, added in Phase 3): when this context halts
/// or faults, hardware posts an exit completion to a supervisor's CQ — the
/// Erlang monitor, in silicon. Survives SPWN restarts.
pub const SupLink = struct { ctx: u8, cq_slot: u8 };

pub const Context = struct {
    a: u64 = 0,
    x: u64 = 0,
    y: u64 = 0,
    sp: u64 = 0,
    ip: u64 = 0,
    p: isa.Flags = .{},
    near: [near_size]u8 = @splat(0),
    state: CtxState = .idle,
    park_slot: u8 = 0,
    fault: Fault = .none,
    fault_addr: u64 = 0,
    /// Incarnation counter, bumped by SPWN. Run-queue entries from a previous
    /// life carry the old value and are skipped at dispatch — a restarted
    /// actor is never resumed at its dead predecessor's continuation.
    gen: u32 = 0,
    sup_link: ?SupLink = null,
    /// Watchdog burst budget: the most consecutive cycles this context may
    /// hold the pipeline without parking, yielding, or halting. 0 = no
    /// watchdog. Exceeding it is a `watchdog` fault — the exit link fires
    /// like any other crash. Privileged config; survives SPWN.
    watchdog: u64 = 0,
    instructions: u64 = 0,
};

const RunEntry = struct { ctx: u8, gen: u32, ip: u64 };

pub const Core = struct {
    id: u16,
    ram: []u8,
    contexts: []Context,
    ptt: [256]ring.PttEntry = @splat(.{}),
    runq: std.fifo.LinearFifo(RunEntry, .Dynamic),
    /// Context currently owning the pipeline, if any.
    current: ?u8 = null,
    clock: u64 = 0,
    /// Cycle at which the current context was dispatched — the base the
    /// watchdog measures bursts from.
    burst_start: u64 = 0,

    fn hasWork(self: *const Core) bool {
        return self.current != null or self.runq.count != 0;
    }

    /// Pick up the next continuation when the pipeline is idle — the
    /// zero-cycle bank switch (§2.2).
    fn dispatch(self: *Core) void {
        if (self.current != null) return;
        while (self.runq.readItem()) |entry| {
            const ctx = &self.contexts[entry.ctx];
            // Stale entries: the context faulted/halted/parked since this was
            // queued, or SPWN started a new incarnation.
            if (ctx.state != .ready or ctx.gen != entry.gen) continue;
            ctx.ip = entry.ip;
            self.current = entry.ctx;
            self.burst_start = self.clock;
            return;
        }
    }
};

pub const Config = struct {
    cores: u16 = 1,
    contexts_per_core: u8 = 4,
    ram_size: usize = 1 << 20,
    link: mesh.LinkConfig = .{},
    seed: u64 = 0x6564,
    /// Hard stop for runaway programs (total cycles on any one core).
    max_cycles: u64 = 10_000_000,
    /// Print scheduler / RBC / fabric events to stderr as they happen.
    trace: bool = false,
};

pub const StopReason = enum { all_halted, faulted, deadlock, max_cycles };

pub const Stats = struct {
    instructions: u64 = 0,
    context_switches: u64 = 0,
    sends: u64 = 0,
    delivered: u64 = 0,
    lost: u64 = 0,
    duplicated: u64 = 0,
    timeouts: u64 = 0,
    rejects: u64 = 0,
    /// Datagrams sent through a PTT entry whose destination doesn't exist in
    /// this machine. They vanish silently — the sender's timeout is the only
    /// truth (§6.1). Software exploits this deliberately: a send to an
    /// unroutable prefix is a guaranteed-timeout completion, i.e. a timer.
    unroutable: u64 = 0,
    /// Contexts force-faulted for holding the pipeline past their burst
    /// budget (§5.4) — each one is a compute-hang the exit link then reports.
    watchdog_trips: u64 = 0,
    /// MAC vectored calls executed (pre-normative mechanism; see sketch).
    macro_calls: u64 = 0,
    cq_overflows: u64 = 0,
};

const PendingSend = struct {
    reply: mesh.ReplyPath,
    done: bool = false,
};

pub const Machine = struct {
    alloc: std.mem.Allocator,
    cfg: Config,
    cores: []Core,
    events: std.PriorityQueue(mesh.Event, void, mesh.Event.order),
    prng: std.Random.DefaultPrng,
    seq: u64 = 0,
    pending: std.AutoHashMap(u64, PendingSend),
    stats: Stats = .{},

    pub fn init(alloc: std.mem.Allocator, cfg: Config) !Machine {
        const cores = try alloc.alloc(Core, cfg.cores);
        errdefer alloc.free(cores);
        var initialized: usize = 0;
        errdefer for (cores[0..initialized]) |*c| {
            alloc.free(c.ram);
            alloc.free(c.contexts);
            c.runq.deinit();
        };
        for (cores, 0..) |*core, i| {
            const ram = try alloc.alloc(u8, cfg.ram_size);
            errdefer alloc.free(ram);
            @memset(ram, 0);
            const ctxs = try alloc.alloc(Context, cfg.contexts_per_core);
            for (ctxs) |*c| c.* = .{};
            core.* = .{
                .id = @intCast(i),
                .ram = ram,
                .contexts = ctxs,
                .runq = std.fifo.LinearFifo(RunEntry, .Dynamic).init(alloc),
            };
            initialized += 1;
        }
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .cores = cores,
            .events = std.PriorityQueue(mesh.Event, void, mesh.Event.order).init(alloc, {}),
            .prng = std.Random.DefaultPrng.init(cfg.seed),
            .pending = std.AutoHashMap(u64, PendingSend).init(alloc),
        };
    }

    pub fn deinit(self: *Machine) void {
        while (self.events.removeOrNull()) |ev| self.freeEvent(ev);
        self.events.deinit();
        self.pending.deinit();
        for (self.cores) |*core| {
            self.alloc.free(core.ram);
            self.alloc.free(core.contexts);
            core.runq.deinit();
        }
        self.alloc.free(self.cores);
    }

    fn freeEvent(self: *Machine, ev: mesh.Event) void {
        switch (ev.kind) {
            .deliver => |d| self.alloc.free(d.payload),
            else => {},
        }
    }

    fn nextSeq(self: *Machine) u64 {
        self.seq += 1;
        return self.seq;
    }

    fn trace(self: *Machine, comptime fmt: []const u8, args: anytype) void {
        if (self.cfg.trace) std.debug.print("[trace] " ++ fmt ++ "\n", args);
    }

    // ── Program / context setup ──────────────────────────────────────────

    pub fn load(self: *Machine, core_idx: u16, addr: u64, bytes: []const u8) void {
        const core = &self.cores[core_idx];
        const off = addr - ram_base;
        @memcpy(core.ram[off..][0..bytes.len], bytes);
    }

    /// Start a context: set its entry point, stack, and argument (lands in
    /// A, mirroring SPWN), and push its first continuation onto the core's
    /// run queue.
    pub fn spawn(self: *Machine, core_idx: u16, ctx_idx: u8, entry: u64, sp: u64, arg: u64) !void {
        const core = &self.cores[core_idx];
        const ctx = &core.contexts[ctx_idx];
        ctx.sp = sp;
        ctx.a = arg;
        ctx.state = .ready;
        try core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = entry });
    }

    /// Write a ring descriptor into a context's near-page descriptor table.
    pub fn setRing(
        self: *Machine,
        core_idx: u16,
        ctx_idx: u8,
        slot: u8,
        desc: ring.Desc,
    ) void {
        const ctx = &self.cores[core_idx].contexts[ctx_idx];
        const words = desc.pack();
        for (words, 0..) |w, i| {
            std.mem.writeInt(u64, ctx.near[slot * ring.desc_size + i * 8 ..][0..8], w, .little);
        }
    }

    /// Install a PTT entry directly (the privileged path around CAPLD).
    pub fn setPtt(self: *Machine, core_idx: u16, slot: u16, entry: ring.PttEntry) void {
        self.cores[core_idx].ptt[slot] = entry;
    }

    /// Pre-stage bytes into a context's near page (config blocks, spawn
    /// tables — the loader's job in a real system).
    pub fn writeNear(self: *Machine, core_idx: u16, ctx_idx: u8, offset: u16, bytes: []const u8) void {
        const ctx = &self.cores[core_idx].contexts[ctx_idx];
        @memcpy(ctx.near[offset..][0..bytes.len], bytes);
    }

    /// Link a context to a supervisor on the same core: when the child halts
    /// or faults, hardware posts an exit completion to the supervisor's CQ.
    pub fn linkSupervisor(self: *Machine, core_idx: u16, child: u8, sup: u8, cq_slot: u8) void {
        self.cores[core_idx].contexts[child].sup_link = .{ .ctx = sup, .cq_slot = cq_slot };
    }

    /// Arm a context's watchdog: the most consecutive cycles it may hold the
    /// pipeline (0 disables). Privileged config; survives SPWN restarts.
    pub fn setWatchdog(self: *Machine, core_idx: u16, ctx_idx: u8, cycles: u64) void {
        self.cores[core_idx].contexts[ctx_idx].watchdog = cycles;
    }

    // ── Memory ───────────────────────────────────────────────────────────

    const MemError = error{ BadAddress, RemoteLoad };

    fn ramSlice(core: *Core, addr: u64, len: u64) MemError![]u8 {
        if (addr < ram_base) return error.BadAddress;
        const off = addr - ram_base;
        if (off + len > core.ram.len) return error.BadAddress;
        return core.ram[off..][0..@intCast(len)];
    }

    fn bytesAt(core: *Core, ctx: *Context, addr: u64, len: u64) MemError![]u8 {
        if (addr < near_size) {
            if (addr + len > near_size) return error.BadAddress;
            return ctx.near[@intCast(addr)..][0..@intCast(len)];
        }
        if (ring.isWindow(addr)) return error.RemoteLoad;
        return ramSlice(core, addr, len);
    }

    fn read64(core: *Core, ctx: *Context, addr: u64) MemError!u64 {
        return std.mem.readInt(u64, (try bytesAt(core, ctx, addr, 8))[0..8], .little);
    }

    fn write64(core: *Core, ctx: *Context, addr: u64, value: u64) MemError!void {
        std.mem.writeInt(u64, (try bytesAt(core, ctx, addr, 8))[0..8], value, .little);
    }

    fn read8(core: *Core, ctx: *Context, addr: u64) MemError!u8 {
        return (try bytesAt(core, ctx, addr, 1))[0];
    }

    fn readDesc(ctx: *Context, slot: u8) ring.Desc {
        var words: [4]u64 = undefined;
        for (&words, 0..) |*w, i| {
            w.* = std.mem.readInt(u64, ctx.near[@as(usize, slot) * ring.desc_size + i * 8 ..][0..8], .little);
        }
        return ring.Desc.unpack(words);
    }

    fn writeDesc(ctx: *Context, slot: u8, desc: ring.Desc) void {
        const words = desc.pack();
        for (words, 0..) |w, i| {
            std.mem.writeInt(u64, ctx.near[@as(usize, slot) * ring.desc_size + i * 8 ..][0..8], w, .little);
        }
    }

    // ── Ring plumbing (the RBCs) ─────────────────────────────────────────

    /// Push raw words as one ring entry. Returns false when the ring is full.
    fn ringPush(core: *Core, ctx: *Context, slot: u8, words: []const u64) MemError!bool {
        var d = readDesc(ctx, slot);
        if (d.entry_size == 0) return error.BadAddress;
        if (d.isFull()) return false;
        const entry = try ramSlice(core, d.entryAddr(d.tail), d.entry_size);
        for (words, 0..) |w, i| {
            if ((i + 1) * 8 > entry.len) break;
            std.mem.writeInt(u64, entry[i * 8 ..][0..8], w, .little);
        }
        d.tail +%= 1;
        writeDesc(ctx, slot, d);
        return true;
    }

    /// Pop one ring entry into `words`. Returns false when empty.
    fn ringPop(core: *Core, ctx: *Context, slot: u8, words: []u64) MemError!bool {
        var d = readDesc(ctx, slot);
        if (d.entry_size == 0) return error.BadAddress;
        if (d.isEmpty()) return false;
        const entry = try ramSlice(core, d.entryAddr(d.head), d.entry_size);
        for (words, 0..) |*w, i| {
            w.* = if ((i + 1) * 8 <= entry.len)
                std.mem.readInt(u64, entry[i * 8 ..][0..8], .little)
            else
                0;
        }
        d.head +%= 1;
        writeDesc(ctx, slot, d);
        return true;
    }

    /// Post a completion record to a context's CQ and wake any listener.
    /// CQ overflow drops the record and counts it — sized CQs are software's
    /// responsibility; see docs/simulator.md.
    fn cqPost(self: *Machine, core_idx: u16, ctx_idx: u8, cq_slot: u8, c: ring.Completion) void {
        const core = &self.cores[core_idx];
        const ctx = &core.contexts[ctx_idx];
        const ok = ringPush(core, ctx, cq_slot, &.{ c.word0(), c.cookie }) catch false;
        self.trace("c{d}x{d} @{d} cqPost slot{d} tag={s} status={s} count={d} cookie=0x{X}{s}", .{
            core_idx,                            ctx_idx,
            core.clock,                          cq_slot,
            @tagName(c.tag),                     @tagName(c.status),
            c.byte_count,                        c.cookie,
            if (ok) "" else " OVERFLOW-DROPPED",
        });
        if (!ok) {
            self.stats.cq_overflows += 1;
            return;
        }
        self.wake(core_idx, ctx_idx, cq_slot);
    }

    /// Wake a context parked on (ctx, slot) — the RBC threshold event (§4.1).
    fn wake(self: *Machine, core_idx: u16, ctx_idx: u8, slot: u8) void {
        const core = &self.cores[core_idx];
        const ctx = &core.contexts[ctx_idx];
        if (ctx.state != .parked or ctx.park_slot != slot) return;
        self.trace("c{d}x{d} @{d} wake (was parked on slot{d})", .{ core_idx, ctx_idx, core.clock, slot });
        ctx.state = .ready;
        core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = ctx.ip }) catch {
            ctx.state = .faulted; // OOM on the run queue: fail loud
            ctx.fault = .bad_descriptor;
        };
    }

    // ── Datagram path ────────────────────────────────────────────────────

    fn sendDatagram(
        self: *Machine,
        src_core: u16,
        ptt_index: u16,
        offset: u64,
        payload: []const u8,
        reply: mesh.ReplyPath,
    ) !void {
        const ptt = &self.cores[src_core].ptt;
        // An out-of-range or empty PTT slot is the same failure: no
        // capability to send there (§6.4). Reported via the CQ, as always.
        const entry = if (ptt_index < ptt.len) ptt[ptt_index] else ring.PttEntry{};
        if (!entry.rights.send) {
            // No capability: the failure is local and synchronous-ish — the
            // RBC rejects at the PTT. Still reported via the CQ, never as an
            // exception (§4.2).
            self.stats.rejects += 1;
            self.cqPost(reply.core, reply.ctx, reply.cq_slot, .{
                .tag = reply.tag,
                .status = .reject_capability,
                .slot = reply.src_slot,
                .byte_count = 0,
                .cookie = reply.cookie,
            });
            return;
        }
        self.stats.sends += 1;
        const send_id = self.nextSeq();
        try self.pending.put(send_id, .{ .reply = reply });

        const now = self.cores[src_core].clock;
        const routable = entry.dstCore() < self.cores.len and
            entry.dstContext() < self.cfg.contexts_per_core and
            entry.dstSlot() < ring.desc_slots;
        if (!routable) {
            // Sent into the void: no arrival, no reject — only the timeout
            // below will speak, and honestly.
            self.stats.unroutable += 1;
            try self.events.add(.{
                .due = now + self.cfg.link.send_timeout,
                .seq = self.nextSeq(),
                .kind = .{ .timeout = .{ .send_id = send_id } },
            });
            return;
        }
        const gram = mesh.Datagram{
            .send_id = send_id,
            .dst_core = entry.dstCore(),
            .dst_ctx = entry.dstContext(),
            .dst_slot = entry.dstSlot(),
            .offset = offset,
            .token = entry.token,
            .payload = undefined,
        };

        const onchip = gram.dst_core == src_core;
        if (onchip) {
            var g = gram;
            g.payload = try self.alloc.dupe(u8, payload);
            try self.events.add(.{
                .due = now + self.cfg.link.onchip_latency,
                .seq = self.nextSeq(),
                .kind = .{ .deliver = g },
            });
        } else {
            const p = mesh.plan(self.cfg.link, self.prng.random(), now);
            if (p.arrivals.len == 0) self.stats.lost += 1;
            if (p.arrivals.len == 2) self.stats.duplicated += 1;
            for (p.arrivals.constSlice()) |due| {
                var g = gram;
                g.payload = try self.alloc.dupe(u8, payload);
                try self.events.add(.{ .due = due, .seq = self.nextSeq(), .kind = .{ .deliver = g } });
            }
        }
        // The timeout always arms; whichever of ack/timeout fires first wins.
        try self.events.add(.{
            .due = now + self.cfg.link.send_timeout,
            .seq = self.nextSeq(),
            .kind = .{ .timeout = .{ .send_id = send_id } },
        });
    }

    fn deliver(self: *Machine, due: u64, gram: mesh.Datagram) !void {
        defer self.alloc.free(gram.payload);
        self.trace("fabric @{d} deliver send_id={d} → c{d}x{d} slot{d} ({d} bytes)", .{
            due, gram.send_id, gram.dst_core, gram.dst_ctx, gram.dst_slot, gram.payload.len,
        });
        const core = &self.cores[gram.dst_core];
        const ctx = &core.contexts[gram.dst_ctx];
        const d = readDesc(ctx, gram.dst_slot);

        var status: ring.Status = .ok;
        var count: u32 = 0;
        var landing_cookie: u64 = 0;

        if (d.token != 0 and d.token != gram.token) {
            status = .reject_capability;
        } else {
            var words: [4]u64 = undefined;
            const got = ringPop(core, ctx, gram.dst_slot, &words) catch false;
            if (!got) {
                status = .reject_no_buffer;
            } else {
                const rx = ring.RxEntry.unpack(words);
                landing_cookie = rx.cookie;
                const n = @min(gram.payload.len, rx.cap);
                if (n < gram.payload.len) status = .truncated;
                count = @intCast(n);
                const buf = ramSlice(core, rx.buf, n) catch {
                    // Bad landing buffer is the receiver's bug; reject the
                    // datagram rather than corrupting RAM.
                    status = .reject_no_buffer;
                    count = 0;
                    return self.resolveDelivery(due, gram, status, count, ctx, landing_cookie, false);
                };
                @memcpy(buf, gram.payload[0..n]);
            }
        }
        try self.resolveDelivery(due, gram, status, count, ctx, landing_cookie, status == .ok or status == .truncated);
    }

    fn resolveDelivery(
        self: *Machine,
        due: u64,
        gram: mesh.Datagram,
        status: ring.Status,
        count: u32,
        ctx: *Context,
        landing_cookie: u64,
        landed: bool,
    ) !void {
        const d = readDesc(ctx, gram.dst_slot);
        if (landed) {
            self.stats.delivered += 1;
            // Receiver learns of arrival via its CQ (§4.2)…
            self.cqPost(gram.dst_core, gram.dst_ctx, d.companion_cq, .{
                .tag = .deliver,
                .status = status,
                .slot = gram.dst_slot,
                .byte_count = count,
                .cookie = landing_cookie,
            });
        } else {
            self.stats.rejects += 1;
            // …and a reject posts to *both* ends (§6.4): the victim sees the
            // attempt on its companion CQ, the sender gets a reject ack.
            self.cqPost(gram.dst_core, gram.dst_ctx, d.companion_cq, .{
                .tag = .deliver,
                .status = status,
                .slot = gram.dst_slot,
                .byte_count = 0,
                .cookie = gram.token,
            });
        }
        // The ack rides the same fault-injected fabric back: it can be lost,
        // in which case the sender's timeout tells the truth (§6.1) — "your
        // datagram MAY have arrived; you don't get to know."
        const pend = self.pending.get(gram.send_id) orelse return; // dup already resolved
        const src_core = pend.reply.core;
        const onchip = src_core == gram.dst_core;
        if (onchip) {
            try self.events.add(.{
                .due = due + self.cfg.link.onchip_latency,
                .seq = self.nextSeq(),
                .kind = .{ .ack = .{ .send_id = gram.send_id, .status = status, .byte_count = count } },
            });
        } else if (!mesh.roll(self.prng.random(), self.cfg.link.loss_ppm4k)) {
            try self.events.add(.{
                .due = due + mesh.latency(self.cfg.link, self.prng.random()),
                .seq = self.nextSeq(),
                .kind = .{ .ack = .{ .send_id = gram.send_id, .status = status, .byte_count = count } },
            });
        }
    }

    fn completeSend(self: *Machine, send_id: u64, status: ring.Status, byte_count: u32) void {
        const kv = self.pending.fetchRemove(send_id) orelse return;
        const reply = kv.value.reply;
        if (status == .timeout) self.stats.timeouts += 1;
        // Release the transmit buffer: clear the OWNED bit (§6.2) — byte 1
        // bit 7 of the staged entry, one byte store. The completion record
        // below is the release fence software observes.
        if (reply.sqe_addr != 0) {
            const core = &self.cores[reply.core];
            if (ramSlice(core, reply.sqe_addr + 1, 1)) |b| {
                b[0] &= ~ring.SqEntry.flag_owned;
            } else |_| {}
        }
        self.cqPost(reply.core, reply.ctx, reply.cq_slot, .{
            .tag = reply.tag,
            .status = status,
            .slot = reply.src_slot,
            .byte_count = byte_count,
            .cookie = reply.cookie,
        });
    }

    fn handleEvent(self: *Machine, ev: mesh.Event) !void {
        switch (ev.kind) {
            .deliver => |gram| try self.deliver(ev.due, gram),
            .ack => |a| self.completeSend(a.send_id, a.status, a.byte_count),
            .timeout => |t| self.completeSend(t.send_id, .timeout, 0),
        }
    }

    // ── Instruction execution ────────────────────────────────────────────

    const StepError = MemError || error{ BadOpcode, NoCapability, BadDescriptor, Brk, BadMacro, OutOfMemory };

    /// Outcome of one instruction: does the current context keep the core?
    const Disposition = enum { keep, switched_out, halted };

    fn step(self: *Machine, core: *Core) !void {
        const ctx_idx = core.current.?;
        const ctx = &core.contexts[ctx_idx];
        const dispo = self.exec(core, ctx_idx, ctx) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.trace("c{d}x{d} @{d} FAULT {s} at ip=0x{X}", .{ core.id, ctx_idx, core.clock, @errorName(err), ctx.ip });
            ctx.state = .faulted;
            ctx.fault = switch (err) {
                error.BadAddress => .bad_address,
                error.RemoteLoad => .remote_load,
                error.BadOpcode => .bad_opcode,
                error.NoCapability => .no_capability,
                error.BadDescriptor => .bad_descriptor,
                error.Brk => .brk,
                error.BadMacro => .bad_macro,
                error.OutOfMemory => return err,
            };
            ctx.fault_addr = ctx.ip;
            core.current = null;
            self.notifyExit(core, ctx_idx, ctx);
            return;
        };
        switch (dispo) {
            .keep => {
                // The watchdog (§5.4): a context that holds the pipeline past
                // its burst budget is force-faulted, so a compute-hung actor
                // can't starve its own supervisor. Checked between
                // instructions — instructions themselves stay atomic.
                if (ctx.watchdog != 0 and core.clock - core.burst_start >= ctx.watchdog) {
                    self.trace("c{d}x{d} @{d} WATCHDOG after {d}-cycle burst at ip=0x{X}", .{
                        core.id, ctx_idx, core.clock, core.clock - core.burst_start, ctx.ip,
                    });
                    ctx.state = .faulted;
                    ctx.fault = .watchdog;
                    ctx.fault_addr = ctx.ip;
                    core.current = null;
                    self.stats.watchdog_trips += 1;
                    self.notifyExit(core, ctx_idx, ctx);
                }
            },
            .switched_out => {
                core.current = null;
                self.stats.context_switches += 1;
            },
            .halted => {
                core.current = null;
                self.notifyExit(core, ctx_idx, ctx);
            },
        }
    }

    /// Fire the exit link, if any (§5.4): a completion record is the one and
    /// only obituary — status ok for a clean HLT, fault (with the fault code
    /// in byte_count) for a crash. The cookie identifies the deceased
    /// precisely: context id in the low half, incarnation in the high half,
    /// so a supervisor can discard obituaries from lives it already replaced.
    fn notifyExit(self: *Machine, core: *Core, ctx_idx: u8, ctx: *Context) void {
        const link = ctx.sup_link orelse return;
        self.trace("c{d}x{d} @{d} exit ({s}, gen{d}) → supervisor x{d}", .{
            core.id, ctx_idx, core.clock, @tagName(ctx.state), ctx.gen, link.ctx,
        });
        self.cqPost(core.id, link.ctx, link.cq_slot, .{
            .tag = .exit,
            .status = if (ctx.state == .faulted) .fault else .ok,
            .byte_count = @intFromEnum(ctx.fault),
            .cookie = @as(u64, ctx_idx) | (@as(u64, ctx.gen) << 32),
        });
    }

    fn exec(self: *Machine, core: *Core, ctx_idx: u8, ctx: *Context) StepError!Disposition {
        const opcode = try read8(core, ctx, ctx.ip);
        const enc = isa.decode[opcode] orelse return error.BadOpcode;
        const operand_addr = ctx.ip + 1;
        const next_ip = ctx.ip + enc.size();
        core.clock += enc.cycles;
        ctx.instructions += 1;
        self.stats.instructions += 1;

        // Operand fetch by mode.
        var imm: u64 = 0; // imm8 (sign-extended) / imm64 value
        var near_off: u16 = 0; // near / ind family raw offset
        var abs_addr: u64 = 0;
        var rel: i16 = 0;
        var desc_slot: u8 = 0;
        var cap_slot: u16 = 0;
        switch (enc.mode) {
            .impl, .acc => {},
            .imm8 => imm = @bitCast(@as(i64, @as(i8, @bitCast(try read8(core, ctx, operand_addr))))),
            .imm64 => imm = try read64(core, ctx, operand_addr),
            .near, .near_x, .near_y, .ind, .ind_y => near_off = try readU16(core, ctx, operand_addr),
            .abs => abs_addr = try read64(core, ctx, operand_addr),
            .rel16 => rel = @bitCast(try readU16(core, ctx, operand_addr)),
            .desc => desc_slot = try read8(core, ctx, operand_addr),
            .caps => {
                cap_slot = try readU16(core, ctx, operand_addr);
                near_off = try readU16(core, ctx, operand_addr + 2);
            },
        }

        // Effective address for memory modes (never fetches the value).
        const ea: u64 = switch (enc.mode) {
            .near => near_off & (near_size - 1),
            .near_x => (near_off +% ctx.x) & (near_size - 1),
            .near_y => (near_off +% ctx.y) & (near_size - 1),
            .abs => abs_addr,
            .ind => try read64(core, ctx, near_off & (near_size - 1)),
            .ind_y => (try read64(core, ctx, near_off & (near_size - 1))) +% ctx.y,
            else => 0,
        };

        ctx.ip = next_ip;

        switch (enc.mnemonic) {
            // ── Loads / stores ────────────────────────────────────────────
            .lda => {
                ctx.a = try self.loadOperand(core, ctx, enc.mode, imm, ea);
                ctx.p.setNZ(ctx.a);
            },
            .ldx => {
                ctx.x = try self.loadOperand(core, ctx, enc.mode, imm, ea);
                ctx.p.setNZ(ctx.x);
            },
            .ldy => {
                ctx.y = try self.loadOperand(core, ctx, enc.mode, imm, ea);
                ctx.p.setNZ(ctx.y);
            },
            .sta => try self.store(core, ctx_idx, ctx, ea, ctx.a),
            .stx => try self.store(core, ctx_idx, ctx, ea, ctx.x),
            .sty => try self.store(core, ctx_idx, ctx, ea, ctx.y),
            // ── Transfers ─────────────────────────────────────────────────
            .tax => {
                ctx.x = ctx.a;
                ctx.p.setNZ(ctx.x);
            },
            .txa => {
                ctx.a = ctx.x;
                ctx.p.setNZ(ctx.a);
            },
            .tay => {
                ctx.y = ctx.a;
                ctx.p.setNZ(ctx.y);
            },
            .tya => {
                ctx.a = ctx.y;
                ctx.p.setNZ(ctx.a);
            },
            .tsx => {
                ctx.x = ctx.sp;
                ctx.p.setNZ(ctx.x);
            },
            .txs => ctx.sp = ctx.x,
            // ── Arithmetic / logic ────────────────────────────────────────
            .adc => addWithCarry(ctx, try self.loadOperand(core, ctx, enc.mode, imm, ea)),
            .sbc => addWithCarry(ctx, ~(try self.loadOperand(core, ctx, enc.mode, imm, ea))),
            .and_ => {
                ctx.a &= try self.loadOperand(core, ctx, enc.mode, imm, ea);
                ctx.p.setNZ(ctx.a);
            },
            .ora => {
                ctx.a |= try self.loadOperand(core, ctx, enc.mode, imm, ea);
                ctx.p.setNZ(ctx.a);
            },
            .eor => {
                ctx.a ^= try self.loadOperand(core, ctx, enc.mode, imm, ea);
                ctx.p.setNZ(ctx.a);
            },
            .cmp => compare(ctx, ctx.a, try self.loadOperand(core, ctx, enc.mode, imm, ea)),
            .cpx => compare(ctx, ctx.x, try self.loadOperand(core, ctx, enc.mode, imm, ea)),
            .cpy => compare(ctx, ctx.y, try self.loadOperand(core, ctx, enc.mode, imm, ea)),
            .asl => {
                ctx.p.c = (ctx.a >> 63) != 0;
                ctx.a <<= 1;
                ctx.p.setNZ(ctx.a);
            },
            .lsr => {
                ctx.p.c = (ctx.a & 1) != 0;
                ctx.a >>= 1;
                ctx.p.setNZ(ctx.a);
            },
            .rol => {
                const cin: u64 = @intFromBool(ctx.p.c);
                ctx.p.c = (ctx.a >> 63) != 0;
                ctx.a = (ctx.a << 1) | cin;
                ctx.p.setNZ(ctx.a);
            },
            .ror => {
                const cin: u64 = @intFromBool(ctx.p.c);
                ctx.p.c = (ctx.a & 1) != 0;
                ctx.a = (ctx.a >> 1) | (cin << 63);
                ctx.p.setNZ(ctx.a);
            },
            .inc => if (enc.mode == .acc) {
                ctx.a +%= 1;
                ctx.p.setNZ(ctx.a);
            } else {
                const v = (try read64(core, ctx, ea)) +% 1;
                try write64(core, ctx, ea, v);
                ctx.p.setNZ(v);
            },
            .dec => if (enc.mode == .acc) {
                ctx.a -%= 1;
                ctx.p.setNZ(ctx.a);
            } else {
                const v = (try read64(core, ctx, ea)) -% 1;
                try write64(core, ctx, ea, v);
                ctx.p.setNZ(v);
            },
            .inx => {
                ctx.x +%= 1;
                ctx.p.setNZ(ctx.x);
            },
            .iny => {
                ctx.y +%= 1;
                ctx.p.setNZ(ctx.y);
            },
            .dex => {
                ctx.x -%= 1;
                ctx.p.setNZ(ctx.x);
            },
            .dey => {
                ctx.y -%= 1;
                ctx.p.setNZ(ctx.y);
            },
            // ── Control flow ──────────────────────────────────────────────
            .jmp => ctx.ip = ea,
            .jsr => {
                try self.push(core, ctx, next_ip);
                ctx.ip = ea;
            },
            .rts => ctx.ip = try self.pop(core, ctx),
            .bpl => try branch(core, ctx, rel, !ctx.p.n),
            .bmi => try branch(core, ctx, rel, ctx.p.n),
            .bvc => try branch(core, ctx, rel, !ctx.p.v),
            .bvs => try branch(core, ctx, rel, ctx.p.v),
            .bcc => try branch(core, ctx, rel, !ctx.p.c),
            .bcs => try branch(core, ctx, rel, ctx.p.c),
            .bne => try branch(core, ctx, rel, !ctx.p.z),
            .beq => try branch(core, ctx, rel, ctx.p.z),
            .bra => try branch(core, ctx, rel, true),
            // ── Stack ─────────────────────────────────────────────────────
            .pha => try self.push(core, ctx, ctx.a),
            .pla => {
                ctx.a = try self.pop(core, ctx);
                ctx.p.setNZ(ctx.a);
            },
            .phx => try self.push(core, ctx, ctx.x),
            .plx => {
                ctx.x = try self.pop(core, ctx);
                ctx.p.setNZ(ctx.x);
            },
            .phy => try self.push(core, ctx, ctx.y),
            .ply => {
                ctx.y = try self.pop(core, ctx);
                ctx.p.setNZ(ctx.y);
            },
            .php => try self.push(core, ctx, @as(u8, @bitCast(ctx.p))),
            .plp => ctx.p = @bitCast(@as(u8, @truncate(try self.pop(core, ctx)))),
            // ── Flags ─────────────────────────────────────────────────────
            .clc => ctx.p.c = false,
            .sec => ctx.p.c = true,
            .clv => ctx.p.v = false,
            // ── Misc ──────────────────────────────────────────────────────
            .nop => {},
            .brk => return error.Brk,
            .hlt => {
                ctx.state = .halted;
                return .halted;
            },
            // ── 6564-Net I/O and concurrency ──────────────────────────────
            .txr => {
                // TXR (ptr),A — ea already resolved through the near page.
                if (!ring.isWindow(ea)) return error.NoCapability;
                var payload: [8]u8 = undefined;
                std.mem.writeInt(u64, &payload, ctx.a, .little);
                try self.sendDatagram(core.id, ring.windowPtt(ea), ring.windowOffset(ea), &payload, .{
                    .core = core.id,
                    .ctx = ctx_idx,
                    .cq_slot = ring.slot_cq,
                    .tag = .txr,
                    .cookie = ea,
                });
            },
            .send => {
                // Doorbell: software staged an SqEntry at the SQ tail slot.
                var d = readDesc(ctx, desc_slot);
                if (d.entry_size < ring.sq_entry_size) return error.BadDescriptor;
                if (d.isFull()) return error.BadDescriptor;
                const sqe_addr = d.entryAddr(d.tail);
                const entry_mem = try ramSlice(core, sqe_addr, d.entry_size);
                var words: [4]u64 = undefined;
                for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, entry_mem[i * 8 ..][0..8], .little);
                const sqe = ring.SqEntry.unpack(words);
                if (!ring.isWindow(sqe.target)) return error.NoCapability;
                // Payload by op: a block transfer, or an 8-byte immediate.
                var txr_payload: [8]u8 = undefined;
                const payload: []const u8 = switch (sqe.op) {
                    .send => try bytesAt(core, ctx, sqe.buf, sqe.len),
                    .txr => blk: {
                        std.mem.writeInt(u64, &txr_payload, sqe.buf, .little);
                        break :blk &txr_payload;
                    },
                    else => return error.BadDescriptor,
                };
                // Accepted: hardware takes the buffer (§6.2). OWNED is byte 1
                // bit 7 of the staged entry.
                entry_mem[1] |= ring.SqEntry.flag_owned;
                d.tail +%= 1;
                // The RBC drains submissions immediately in v0.1 (see docs),
                // so head follows tail; the ring exists architecturally.
                d.head = d.tail;
                writeDesc(ctx, desc_slot, d);
                // The hardware cookie stamp: staging slot and incarnation in
                // the high half, software's cookie_lo in the low half.
                const cookie = @as(u64, sqe.cookie_lo) |
                    (@as(u64, desc_slot) << 32) |
                    (@as(u64, @as(u16, @truncate(ctx.gen))) << 48);
                try self.sendDatagram(core.id, ring.windowPtt(sqe.target), ring.windowOffset(sqe.target), payload, .{
                    .core = core.id,
                    .ctx = ctx_idx,
                    .cq_slot = d.companion_cq,
                    .tag = if (sqe.op == .txr) .txr else .send,
                    .cookie = cookie,
                    .sqe_addr = sqe_addr,
                    .src_slot = desc_slot,
                });
            },
            .recv => {
                // Doorbell: software staged an RxEntry at the RX tail slot.
                var d = readDesc(ctx, desc_slot);
                if (d.entry_size < ring.rx_entry_size) return error.BadDescriptor;
                if (d.isFull()) return error.BadDescriptor;
                d.tail +%= 1;
                writeDesc(ctx, desc_slot, d);
            },
            .lstn => {
                const d = readDesc(ctx, desc_slot);
                if (d.isEmpty()) {
                    self.trace("c{d}x{d} @{d} LSTN parks on slot{d}", .{ core.id, ctx_idx, core.clock, desc_slot });
                    ctx.state = .parked;
                    ctx.park_slot = desc_slot;
                    // Resume after the LSTN once the ring has data.
                    return .switched_out;
                }
            },
            .cont => {
                const target = next_ip +% @as(u64, @bitCast(@as(i64, rel)));
                try core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = target });
            },
            .yld => {
                try core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = ctx.ip });
                return .switched_out;
            },
            .cqpop => {
                var words: [2]u64 = undefined;
                const got = try ringPop(core, ctx, desc_slot, &words);
                if (got) {
                    ctx.a = words[0];
                    ctx.x = words[1];
                    ctx.p.z = false;
                } else {
                    ctx.p.z = true;
                }
            },
            .capld => {
                // Privileged in real silicon; v0.1 runs single-privilege.
                var words: [4]u64 = undefined;
                const base = near_off & (near_size - 1);
                for (&words, 0..) |*w, i| w.* = try read64(core, ctx, base + i * 8);
                core.ptt[cap_slot] = ring.PttEntry.unpack(words);
            },
            .spwn => {
                // (Re)start a sibling from a spawn block at ea:
                //   word0 target ctx id   word1 entry IP
                //   word2 stack pointer   word3 arg (lands in A)
                // The target gets fresh registers and a new generation; its
                // near page (ring wiring, its mailbox) survives, as does its
                // exit link. Also privileged in real silicon.
                var words: [4]u64 = undefined;
                for (&words, 0..) |*w, i| w.* = try read64(core, ctx, ea + i * 8);
                const target_idx = words[0];
                if (target_idx >= core.contexts.len or target_idx == ctx_idx)
                    return error.BadDescriptor;
                const target = &core.contexts[@intCast(target_idx)];
                self.trace("c{d}x{d} @{d} SPWN x{d} gen{d} entry=0x{X}", .{
                    core.id, ctx_idx, core.clock, target_idx, target.gen + 1, words[1],
                });
                target.a = words[3];
                target.x = 0;
                target.y = 0;
                target.sp = words[2];
                target.p = .{};
                target.fault = .none;
                target.fault_addr = 0;
                target.gen +%= 1;
                target.state = .ready;
                try core.runq.writeItem(.{
                    .ctx = @intCast(target_idx),
                    .gen = target.gen,
                    .ip = words[1],
                });
            },
            .mac => {
                // JSR through MACTAB slot n (opcode high nibble). The table
                // is per-context — vectors travel with the actor, not the
                // code — and a null vector is a bug, reported honestly.
                const slot: usize = enc.opcode >> 4;
                const vector = std.mem.readInt(
                    u64,
                    ctx.near[isa.mactab_base + slot * 8 ..][0..8],
                    .little,
                );
                if (vector == 0) return error.BadMacro;
                self.stats.macro_calls += 1;
                try self.push(core, ctx, next_ip);
                ctx.ip = vector;
            },
        }
        return .keep;
    }

    fn readU16(core: *Core, ctx: *Context, addr: u64) MemError!u16 {
        return std.mem.readInt(u16, (try bytesAt(core, ctx, addr, 2))[0..2], .little);
    }

    fn loadOperand(self: *Machine, core: *Core, ctx: *Context, mode: isa.Mode, imm: u64, ea: u64) StepError!u64 {
        _ = self;
        return switch (mode) {
            .imm8, .imm64 => imm,
            else => try read64(core, ctx, ea),
        };
    }

    /// A store: local memory, or — through the network window — a
    /// single-word datagram with TXR semantics (§3.2: uniform syntax).
    fn store(self: *Machine, core: *Core, ctx_idx: u8, ctx: *Context, ea: u64, value: u64) StepError!void {
        if (ring.isWindow(ea)) {
            var payload: [8]u8 = undefined;
            std.mem.writeInt(u64, &payload, value, .little);
            try self.sendDatagram(core.id, ring.windowPtt(ea), ring.windowOffset(ea), &payload, .{
                .core = core.id,
                .ctx = ctx_idx,
                .cq_slot = ring.slot_cq,
                .tag = .txr,
                .cookie = ea,
            });
            return;
        }
        try write64(core, ctx, ea, value);
    }

    fn push(self: *Machine, core: *Core, ctx: *Context, value: u64) StepError!void {
        _ = self;
        ctx.sp -%= 8;
        try write64(core, ctx, ctx.sp, value);
    }

    fn pop(self: *Machine, core: *Core, ctx: *Context) StepError!u64 {
        _ = self;
        const v = try read64(core, ctx, ctx.sp);
        ctx.sp +%= 8;
        return v;
    }

    fn branch(core: *Core, ctx: *Context, rel: i16, cond: bool) MemError!void {
        if (cond) {
            ctx.ip +%= @as(u64, @bitCast(@as(i64, rel)));
            core.clock += 1;
        }
    }

    fn addWithCarry(ctx: *Context, m: u64) void {
        const cin: u64 = @intFromBool(ctx.p.c);
        const r1 = @addWithOverflow(ctx.a, m);
        const r2 = @addWithOverflow(r1[0], cin);
        const result = r2[0];
        ctx.p.c = (r1[1] | r2[1]) != 0;
        ctx.p.v = ((ctx.a ^ result) & (m ^ result)) >> 63 != 0;
        ctx.a = result;
        ctx.p.setNZ(result);
    }

    fn compare(ctx: *Context, reg: u64, m: u64) void {
        ctx.p.c = reg >= m;
        ctx.p.setNZ(reg -% m);
    }

    // ── The machine loop ─────────────────────────────────────────────────

    /// Run until every context is halted/faulted, the machine deadlocks, or
    /// a core hits max_cycles.
    pub fn run(self: *Machine) !StopReason {
        while (true) {
            // The core furthest behind in virtual time that has work.
            var busy: ?*Core = null;
            for (self.cores) |*core| {
                core.dispatch();
                if (core.hasWork()) {
                    if (busy == null or core.clock < busy.?.clock) busy = core;
                }
            }
            const next_ev: ?u64 = if (self.events.peek()) |ev| ev.due else null;

            if (busy) |core| {
                // Events strictly before this core's clock fire first.
                if (next_ev != null and next_ev.? <= core.clock) {
                    const ev = self.events.remove();
                    try self.handleEvent(ev);
                    continue;
                }
                if (core.clock >= self.cfg.max_cycles) return .max_cycles;
                core.dispatch();
                if (core.current != null) try self.step(core);
                continue;
            }

            // No core has runnable work: advance virtual time to the next
            // event, or stop.
            if (next_ev) |due| {
                for (self.cores) |*core| core.clock = @max(core.clock, due);
                const ev = self.events.remove();
                try self.handleEvent(ev);
                continue;
            }
            return self.stopReason();
        }
    }

    fn stopReason(self: *Machine) StopReason {
        var any_fault = false;
        for (self.cores) |*core| {
            for (core.contexts) |*ctx| {
                if (ctx.state == .parked or ctx.state == .ready) return .deadlock;
                if (ctx.state == .faulted) any_fault = true;
            }
        }
        return if (any_fault) .faulted else .all_halted;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testMachine(cfg: Config) !Machine {
    return Machine.init(testing.allocator, cfg);
}

test "arithmetic, flags, branches: countdown loop" {
    var m = try testMachine(.{ .cores = 1, .contexts_per_core = 1, .ram_size = 0x1000 });
    defer m.deinit();
    // X = 5; loop: DEX; BNE loop; HLT
    const prog = [_]u8{
        0xA2, 5, // LDX #5
        0xCA, // DEX
        0xD0, 0xFC, 0xFF, // BNE -4 (back to DEX)
        0xDB, // HLT
    };
    m.load(0, ram_base, &prog);
    try m.spawn(0, 0, ram_base, ram_base + 0x800, 0);
    const reason = try m.run();
    try testing.expectEqual(StopReason.all_halted, reason);
    try testing.expectEqual(@as(u64, 0), m.cores[0].contexts[0].x);
    try testing.expectEqual(CtxState.halted, m.cores[0].contexts[0].state);
}

test "undefined opcode faults honestly" {
    var m = try testMachine(.{ .cores = 1, .contexts_per_core = 1, .ram_size = 0x1000 });
    defer m.deinit();
    m.load(0, ram_base, &.{0x02}); // $02: a jam on NMOS, undefined here too
    try m.spawn(0, 0, ram_base, ram_base + 0x800, 0);
    _ = try m.run();
    try testing.expectEqual(CtxState.faulted, m.cores[0].contexts[0].state);
    try testing.expectEqual(Fault.bad_opcode, m.cores[0].contexts[0].fault);
}
