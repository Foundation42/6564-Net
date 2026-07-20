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
const dev = @import("dev.zig");

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
    /// WDEX declared a burst budget above the supervisor's ceiling (§5.4):
    /// asking for more leash than authorized is a fault, not a longer leash.
    wdex_ceiling,
    /// A completion record found no room in this context's CQ (§11 q6,
    /// promoted): sizing a CQ is software's contract, like ring layout,
    /// and breaking it kills the context that owns the queue instead of
    /// silently losing its mail. A dropped timeout record used to mean
    /// an eternal park — a failure no supervisor could see. Now the
    /// exit link fires and someone can answer for it.
    cq_overflow,
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
    /// Ceiling on WDEX declarations: the largest burst budget this context
    /// may set for itself. The supervisor's contract about worst-case
    /// unyielding time — an actor must not edit its own leash. Privileged
    /// config; survives SPWN. 0 = no declarations authorized.
    wdex_ceiling: u64 = 0,
    instructions: u64 = 0,
};

const RunEntry = struct { ctx: u8, gen: u32, ip: u64 };

pub const Core = struct {
    id: u16,
    ram: []u8,
    contexts: []Context,
    /// Tier 1: V0–V7 × 512-bit, eight u64/f64 lanes each. ONE file per
    /// core — never banked, never saved by hardware, volatile across
    /// parks by the §1 convention. Live vector state spills to the near
    /// page or dies with the burst; a watchdog trip mid-block loses it
    /// by design (trips are deaths, deaths restart).
    v: [8][8]u64 = @splat(@splat(0)),
    ptt: [256]ring.PttEntry = @splat(.{}),
    runq: std.fifo.LinearFifo(RunEntry, .Dynamic),
    /// Context currently owning the pipeline, if any.
    current: ?u8 = null,
    clock: u64 = 0,
    /// Cycle at which the current context was dispatched — the base the
    /// watchdog measures bursts from.
    burst_start: u64 = 0,
    /// Active WDEX declaration for the current burst (§5.4): the cycle it
    /// was declared at and the remaining budget granted. budget 0 = no
    /// declaration. Cleared at dispatch — a declaration never outlives the
    /// burst it was made in.
    wdex_base: u64 = 0,
    wdex_budget: u64 = 0,

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
            self.wdex_budget = 0; // declarations reset to base at the park
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
    /// Contended-LSTN rule ("immediate hot-path delivery is a privilege of
    /// an idle core"): an LSTN that finds its ring non-empty still rotates
    /// when another context on the core is runnable. Fairness is the
    /// machine's job — joe never learns about cores. v2.6 candidate,
    /// default on with the pricing in docs/measurements.md.
    contended_lstn: bool = true,
    /// The bank-collapse verifier (handoff item 1/§1): poison A, X, Y, SP
    /// and P at every voluntary park (LSTN that actually parks, YLD). This
    /// is the maximally hostile implementation the collapsed-register
    /// convention permits — registers are one shared set, volatile across
    /// parks, and a context is only near page + run-queue entry + control
    /// block. Code that runs identically with this on has proven it never
    /// relied on the banked file.
    scorch_parks: bool = false,
};

/// The poison stamped into registers at a scorched park — recognizable in
/// any trace, guaranteed not to look like a valid pointer or count.
pub const scorch_pattern: u64 = 0xDEAD_6564_DEAD_6564;

/// Is any OTHER live context runnable on this core? The contended-LSTN
/// test — one scan of state the scheduler already holds.
fn otherRunnable(core: *Core, self_ctx: u8) bool {
    var i: usize = 0;
    while (i < core.runq.count) : (i += 1) {
        const e = core.runq.peekItem(i);
        if (e.ctx == self_ctx) continue;
        const c = &core.contexts[e.ctx];
        if (c.state == .ready and c.gen == e.gen) return true;
    }
    return false;
}

fn scorch(core: *Core, ctx: *Context) void {
    ctx.a = scorch_pattern;
    ctx.x = scorch_pattern;
    ctx.y = scorch_pattern;
    ctx.sp = scorch_pattern;
    ctx.p = .{ .z = true, .n = true, .c = true, .v = true };
    // Tier 1 state is even more volatile than the scalars: one shared
    // file, poisoned wholesale.
    for (&core.v) |*vr| vr.* = @splat(scorch_pattern);
}

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
    /// Landing buffers re-enqueued by AUTO_REPOST rings at CQPOP time.
    auto_reposts: u64 = 0,
    /// Timer entries resubmitted by AUTO_REARM on timeout.
    auto_rearms: u64 = 0,
    /// Chain entries fired by LINK on ok completions.
    chain_fires: u64 = 0,
    /// Staged entries cancelled by an upstream chain break.
    chain_cancels: u64 = 0,
    cq_overflows: u64 = 0,
    /// Capability transfers completed (A4 movement 2).
    grants: u64 = 0,
    /// Requests accepted by peripheral-row devices (§7).
    dev_deliveries: u64 = 0,
    /// Reply datagrams devices fired back through their own PTTs.
    dev_replies: u64 = 0,
    /// 64-byte chunks the remote matmul polyfill pulled/pushed through
    /// the network window — the observable (and only) difference from
    /// the in-proc unit, besides the clock.
    accel_pulls: u64 = 0,
};

/// A device attached to the peripheral row: the device itself, the token it
/// demands of requesters (0 = open), and the PTT its replies route through —
/// bound by the loader exactly like any actor's capabilities.
pub const DevEndpoint = struct {
    dev: dev.Device,
    token: u64 = 0,
    ptt: [dev.ptt_slots]ring.PttEntry = @splat(.{}),
};

/// An accelerator actor on the peripheral row (handoff item 6): matmul,
/// in two indistinguishable implementations per §7.5 — an in-proc "TPU"
/// that DMAs the granted region, and a fabric-remote polyfill that pulls
/// it through the network window chunk by chunk with the same token.
/// Both declare `deterministic`: C[i,j] = Σ_k A[i,k]·B[k,j], k ascending,
/// IEEE RNE — the reduction order is in the contract, so the two
/// implementations agree to the bit and only the clock can tell them
/// apart. Queue depth one: a busy accelerator rejects, and saturation is
/// backpressure, never corruption.
pub const Accel = struct {
    kind: enum { inproc, remote, display },
    token: u64 = 0,
    busy: bool = false,
    /// Display state (kind == .display). A display is an accelerator whose
    /// "work" is to present: it takes a granted frame region, holds it for
    /// one vblank interval, and returns it — the completion is the frame
    /// clock, the grant is the pacing (rocci §2). `frames` counts presents;
    /// `checksum` is the last frame's bytes summed, a headless stand-in for
    /// a framebuffer that proves the actor's drawing reached the glass;
    /// `period` is the vblank interval, the backpressure that paces the
    /// frame loop.
    frames: u64 = 0,
    checksum: u64 = 0,
    period: u64 = 0,
};

/// One granted matmul in flight: everything re-checked at completion
/// time against the LIVE descriptor — the deferred-read discipline, so
/// revocation between grant and completion turns the job into an honest
/// reject instead of a scribble.
const AccelJob = struct {
    coord: u16,
    core: u16,
    ctx: u8,
    slot: u8,
    token: u64,
    m: u16,
    k: u16,
    n: u16,
    off_a: u64,
    off_b: u64,
    off_c: u64,
};

const PendingSend = struct {
    reply: mesh.ReplyPath,
    done: bool = false,
};

pub const Machine = struct {
    /// Monotonic mint counter for transferred capabilities (A4 m2).
    grant_seq: u64 = 0,
    alloc: std.mem.Allocator,
    cfg: Config,
    cores: []Core,
    events: std.PriorityQueue(mesh.Event, void, mesh.Event.order),
    prng: std.Random.DefaultPrng,
    seq: u64 = 0,
    pending: std.AutoHashMap(u64, PendingSend),
    devices: std.AutoHashMap(u16, DevEndpoint),
    accels: std.AutoHashMap(u16, Accel),
    accel_jobs: std.AutoHashMap(u64, AccelJob),
    accel_next_id: u64 = 1,
    /// Which die this machine is on the IO plane (§6.5); 0 standalone.
    die_id: u16 = 0,
    /// The die's hook onto the plane; PTT entries with route != 0 need it.
    egress: ?mesh.Egress = null,
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
            .devices = std.AutoHashMap(u16, DevEndpoint).init(alloc),
            .accels = std.AutoHashMap(u16, Accel).init(alloc),
            .accel_jobs = std.AutoHashMap(u64, AccelJob).init(alloc),
        };
    }

    pub fn deinit(self: *Machine) void {
        while (self.events.removeOrNull()) |ev| self.freeEvent(ev);
        self.events.deinit();
        self.pending.deinit();
        var it = self.devices.valueIterator();
        while (it.next()) |ep| ep.dev.deinit();
        self.devices.deinit();
        self.accels.deinit();
        self.accel_jobs.deinit();
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
    /// Attach a device at a peripheral-row coordinate ($FF00..$FFFE). The
    /// token is what requesters' PTT entries must present (0 = open).
    pub fn attachDevice(self: *Machine, coord: u16, token: u64, d: dev.Device) !void {
        std.debug.assert(coord >= dev.first_core and coord <= dev.last_core);
        const slot = try self.devices.getOrPut(coord);
        std.debug.assert(!slot.found_existing);
        slot.value_ptr.* = .{ .dev = d, .token = token };
    }

    /// Bind a reply capability into a device's PTT — the loader wiring a
    /// driver to its device, same act as wiring any two actors together.
    pub fn setDevicePtt(self: *Machine, coord: u16, slot: u8, entry: ring.PttEntry) void {
        self.devices.getPtr(coord).?.ptt[slot] = entry;
    }

    /// Attach a matmul accelerator at a peripheral coordinate (item 6).
    pub fn attachAccel(self: *Machine, coord: u16, token: u64, kind: @FieldType(Accel, "kind")) !void {
        std.debug.assert(coord >= dev.first_core and coord <= dev.last_core);
        try self.accels.put(coord, .{ .kind = kind, .token = token });
    }

    /// A display in the peripheral row: it takes a granted frame region,
    /// holds it for one vblank `period`, presents it, and returns it. The
    /// frame clock is backpressure — a second Present before PresentDone
    /// is refused, so an actor cannot draw faster than the glass returns
    /// its region (rocci §2). Single-buffered; the double buffer is two
    /// regions alternating grants, a program's choice, not the display's.
    pub fn attachDisplay(self: *Machine, coord: u16, token: u64, period: u64) !void {
        std.debug.assert(coord >= dev.first_core and coord <= dev.last_core);
        try self.accels.put(coord, .{ .kind = .display, .token = token, .period = period });
    }

    /// The last frame a display presented: how many, and a checksum of the
    /// bytes that reached it. Read after a run — the headless proof that
    /// what the actor drew is what the glass received.
    pub fn displayStats(self: *Machine, coord: u16) ?struct { frames: u64, checksum: u64 } {
        const ac = self.accels.getPtr(coord) orelse return null;
        if (ac.kind != .display) return null;
        return .{ .frames = ac.frames, .checksum = ac.checksum };
    }

    /// A pad in the peripheral row: a device that pushes. The trace is the
    /// button sequence (caller-owned), `interval` the input rate. It stays
    /// silent until an actor subscribes with a Poll ask, then streams one
    /// `Pad` per trace entry to the ask's reply window.
    pub fn attachPad(self: *Machine, coord: u16, token: u64, input_trace: []const u64, interval: u64) !void {
        try self.attachDevice(coord, token, .{ .pad = .{ .trace = input_trace, .interval = interval } });
    }

    /// A matmul request arrives (contract, all u64 LE words):
    ///   w0 reserved (joe's tag word — silicon ignores it)
    ///   w1 region desc slot   w2 token presented
    ///   w3 dims M | K<<16 | N<<32 (each 1..32)
    ///   w4 offset of A   w5 offset of B   w6 offset of C  (bytes, in-region)
    /// Grant-on-submit: acceptance sets the descriptor's OWNED flag; the
    /// completion (a delivery to the sender's RX ring, word0 low16 =
    /// $6772 with the status above it, word1 = the slot) is the release
    /// fence. A busy accelerator — or an already-granted region — rejects:
    /// saturation is backpressure.
    fn deliverToAccel(self: *Machine, due: u64, gram: mesh.Datagram) !void {
        const ac = self.accels.getPtr(gram.dst_core).?;
        if (ac.kind == .display) return self.deliverToDisplay(due, gram, ac);
        const reject = struct {
            fn of(m: *Machine, d: u64, g: mesh.Datagram, s: ring.Status) !void {
                m.stats.rejects += 1;
                try m.ackSender(d, g, g.dst_core, s, 0);
            }
        }.of;
        if (ac.token != 0 and ac.token != gram.token)
            return reject(self, due, gram, .reject_capability);
        if (ac.busy or gram.payload.len < 56)
            return reject(self, due, gram, .reject_no_buffer);
        // the granting context is the sender of this request
        const pend = self.pending.get(gram.send_id) orelse
            return reject(self, due, gram, .reject_capability);
        const rcore = pend.reply.core;
        const rctx = pend.reply.ctx;
        const w = struct {
            fn at(p: []const u8, i: usize) u64 {
                return std.mem.readInt(u64, p[i * 8 ..][0..8], .little);
            }
        }.at;
        const job = AccelJob{
            .coord = gram.dst_core,
            .core = rcore,
            .ctx = rctx,
            .slot = @truncate(w(gram.payload, 1)),
            .token = w(gram.payload, 2),
            .m = @truncate(w(gram.payload, 3)),
            .k = @truncate(w(gram.payload, 3) >> 16),
            .n = @truncate(w(gram.payload, 3) >> 32),
            .off_a = w(gram.payload, 4),
            .off_b = w(gram.payload, 5),
            .off_c = w(gram.payload, 6),
        };
        if (job.m == 0 or job.k == 0 or job.n == 0 or job.m > 32 or job.k > 32 or job.n > 32)
            return reject(self, due, gram, .reject_capability);
        const desc = self.regionDesc(job) orelse
            return reject(self, due, gram, .reject_capability);
        if (desc.token == 0 or desc.token != job.token)
            return reject(self, due, gram, .reject_capability);
        if (desc.flags & ring.desc_flag_owned != 0)
            return reject(self, due, gram, .reject_no_buffer); // already granted out
        const need_a = @as(u64, job.m) * job.k * 8;
        const need_b = @as(u64, job.k) * job.n * 8;
        const need_c = @as(u64, job.m) * job.n * 8;
        if (job.off_a + need_a > desc.len or job.off_b + need_b > desc.len or
            job.off_c + need_c > desc.len)
            return reject(self, due, gram, .reject_capability);
        // grant: the region is hardware-owned until the completion fence
        self.setRegionOwned(job, true);
        ac.busy = true;
        const flops = @as(u64, job.m) * job.k * job.n;
        const latency: u64 = switch (ac.kind) {
            // the in-proc unit DMAs; the polyfill pulls and pushes the
            // region through the window in 64-byte chunks, same token —
            // same bytes at the end, only the clock can tell
            .inproc => 100 + flops,
            .remote => blk: {
                const chunks = (need_a + need_b + need_c + 63) / 64;
                self.stats.accel_pulls += chunks;
                break :blk 400 + chunks * 200 + flops;
            },
            .display => unreachable, // routed to deliverToDisplay above
        };
        const id = self.accel_next_id;
        self.accel_next_id += 1;
        try self.accel_jobs.put(id, job);
        try self.events.add(.{ .due = due + latency, .seq = self.nextSeq(), .kind = .{ .accel = .{ .id = id } } });
        self.stats.delivered += 1;
        self.stats.dev_deliveries += 1;
        self.trace("accel ${X} @{d} grant slot{d} {d}x{d}x{d}", .{ gram.dst_core, due, job.slot, job.m, job.k, job.n });
        try self.ackSender(due, gram, gram.dst_core, .ok, @intCast(gram.payload.len));
    }

    /// A Present request arrives (all u64 LE words):
    ///   w0 reserved (joe's tag word — silicon ignores it)
    ///   w1 region desc slot   w2 token presented
    /// The whole region is the frame; there are no dimensions to give,
    /// because a display does not compute, it presents. Grant-on-submit
    /// sets OWNED; the completion after one vblank interval snapshots the
    /// frame and is the release fence. `busy` makes the display single-
    /// buffered: a second Present before PresentDone is backpressure —
    /// the frame clock refusing to run ahead of the glass.
    fn deliverToDisplay(self: *Machine, due: u64, gram: mesh.Datagram, ac: *Accel) !void {
        const reject = struct {
            fn of(m: *Machine, d: u64, g: mesh.Datagram, s: ring.Status) !void {
                m.stats.rejects += 1;
                try m.ackSender(d, g, g.dst_core, s, 0);
            }
        }.of;
        if (ac.token != 0 and ac.token != gram.token)
            return reject(self, due, gram, .reject_capability);
        if (ac.busy or gram.payload.len < 24)
            return reject(self, due, gram, .reject_no_buffer);
        const pend = self.pending.get(gram.send_id) orelse
            return reject(self, due, gram, .reject_capability);
        const w = struct {
            fn at(p: []const u8, i: usize) u64 {
                return std.mem.readInt(u64, p[i * 8 ..][0..8], .little);
            }
        }.at;
        const job = AccelJob{
            .coord = gram.dst_core,
            .core = pend.reply.core,
            .ctx = pend.reply.ctx,
            .slot = @truncate(w(gram.payload, 1)),
            .token = w(gram.payload, 2),
            .m = 0,
            .k = 0,
            .n = 0,
            .off_a = 0,
            .off_b = 0,
            .off_c = 0,
        };
        const desc = self.regionDesc(job) orelse
            return reject(self, due, gram, .reject_capability);
        if (desc.token == 0 or desc.token != job.token)
            return reject(self, due, gram, .reject_capability);
        if (desc.flags & ring.desc_flag_owned != 0)
            return reject(self, due, gram, .reject_no_buffer); // a frame is already up
        self.setRegionOwned(job, true);
        ac.busy = true;
        const id = self.accel_next_id;
        self.accel_next_id += 1;
        try self.accel_jobs.put(id, job);
        try self.events.add(.{ .due = due + ac.period, .seq = self.nextSeq(), .kind = .{ .accel = .{ .id = id } } });
        self.stats.delivered += 1;
        self.stats.dev_deliveries += 1;
        self.trace("display ${X} @{d} present slot{d}", .{ gram.dst_core, due, job.slot });
        try self.ackSender(due, gram, gram.dst_core, .ok, @intCast(gram.payload.len));
    }

    const RegionDesc = struct { base: u64, len: u64, token: u64, flags: u8 };

    /// Read a region descriptor LIVE from the granting context's near
    /// page — every check is against current words, never a copy.
    fn regionDesc(self: *Machine, job: AccelJob) ?RegionDesc {
        if (job.core >= self.cores.len) return null;
        const core = &self.cores[job.core];
        if (job.ctx >= core.contexts.len) return null;
        const ctx = &core.contexts[job.ctx];
        if (job.slot >= ring.desc_slots) return null;
        const off = @as(u64, job.slot) * ring.desc_size;
        const base = read64(core, ctx, off) catch return null;
        const w1 = read64(core, ctx, off + 8) catch return null;
        const len = read64(core, ctx, off + 16) catch return null;
        const token = read64(core, ctx, off + 24) catch return null;
        const flags: u8 = @truncate(w1 >> 56);
        if (flags & ring.desc_flag_region == 0) return null;
        return .{ .base = base, .len = len, .token = token, .flags = flags };
    }

    /// Capability transfer (A4 movement 2): move a region capability from
    /// the granting context to the grantee, minting a fresh token and
    /// leaving a paper trail. Returns the grantee's new descriptor slot,
    /// or null with the reject status set.
    ///
    /// The verbs narrow (subset, attenuable); a region carries no dialect
    /// to copy — dialect is an ENDPOINT property, and a span of memory is
    /// not an endpoint — so the movement-1 tripwire stays silent here,
    /// which is itself the finding: the two fields are not parallel
    /// across capability kinds.
    fn transferRegion(
        self: *Machine,
        from_core: u16,
        from_ctx: u8,
        src_slot: u8,
        to_core: u16,
        to_ctx: u8,
        verbs: ring.Verbs,
    ) ?struct { slot: u8, token: u64, base: u64, len: u64 } {
        if (from_core >= self.cores.len or to_core >= self.cores.len) return null;
        // A region is a span of ONE core's RAM, and RAM is per-core: the
        // base is a core-local address, not a machine-wide one. Carried
        // across a core boundary it would still be a well-formed
        // capability — same length, fresh token, correct verbs — over
        // memory the grantee never named. So the memory domains must
        // MATCH, which makes `domain` a third discipline alongside the
        // two A4 found: verbs attenuate by subset, dialects compare by
        // equality, and a region simply may not leave home.
        //
        // Movement 2 shipped without this because its test granted
        // between two contexts on one core, where the check cannot fire.
        // A capability that is meaningless at the destination must be
        // refused at the source.
        if (from_core != to_core) return null;
        const src = &self.cores[from_core].contexts[from_ctx];
        if (src_slot >= ring.desc_slots) return null;
        const soff = @as(u64, src_slot) * ring.desc_size;
        const base = read64(&self.cores[from_core], src, soff) catch return null;
        const w1 = read64(&self.cores[from_core], src, soff + 8) catch return null;
        const len = read64(&self.cores[from_core], src, soff + 16) catch return null;
        const token = read64(&self.cores[from_core], src, soff + 24) catch return null;
        const flags: u8 = @truncate(w1 >> 56);
        // You cannot pass on what you do not hold: not a region, already
        // granted out to silicon, or revoked (token zero) — all refuse.
        if (flags & ring.desc_flag_region == 0) return null;
        if (flags & ring.desc_flag_owned != 0) return null;
        if (token == 0) return null;
        // The grantor's own verbs bound the grantee's (subset).
        const held: ring.Verbs = @bitCast(@as(u4, @truncate(w1 >> 48)));
        const holds_any = @as(u4, @bitCast(held)) != 0;
        if (holds_any and !verbs.subsetOf(held)) return null;
        if (holds_any and !held.grant) return null; // no right to pass it on

        // Find the grantee a free descriptor slot. Hardware picks, and
        // says which in the grant record: a grantor that had to know the
        // grantee's table layout would be reaching into it.
        const dst = &self.cores[to_core].contexts[to_ctx];
        var slot: u8 = 8; // 0..7 are architected/loader territory
        const free_slot = while (slot < ring.desc_slots) : (slot += 1) {
            const off = @as(u64, slot) * ring.desc_size;
            const b = read64(&self.cores[to_core], dst, off) catch return null;
            const t = read64(&self.cores[to_core], dst, off + 24) catch return null;
            if (b == 0 and t == 0) break slot;
        } else return null;

        // Mint: fresh token, verbs as granted, region flag set.
        self.grant_seq +%= 1;
        const fresh = 0x6772_0000_0000_0000 | self.grant_seq;
        const off = @as(u64, free_slot) * ring.desc_size;
        const nw1 = (@as(u64, @as(u4, @bitCast(verbs))) << 48) |
            (@as(u64, ring.desc_flag_region) << 56);
        write64(&self.cores[to_core], dst, off, base) catch return null;
        write64(&self.cores[to_core], dst, off + 8, nw1) catch return null;
        write64(&self.cores[to_core], dst, off + 16, len) catch return null;
        write64(&self.cores[to_core], dst, off + 24, fresh) catch return null;

        // Surrender the grantor's copy: succession, not sharing. Zeroing
        // the token is the same revocation software already had (§6.2).
        write64(&self.cores[from_core], src, soff + 24, 0) catch return null;
        self.stats.grants += 1;
        return .{ .slot = free_slot, .token = fresh, .base = base, .len = len };
    }

    fn setRegionOwned(self: *Machine, job: AccelJob, owned: bool) void {
        const core = &self.cores[job.core];
        const ctx = &core.contexts[job.ctx];
        const off = @as(u64, job.slot) * ring.desc_size + 8;
        const w1 = read64(core, ctx, off) catch return;
        const flags: u8 = @truncate(w1 >> 56);
        const nf: u8 = if (owned) flags | ring.desc_flag_owned else flags & ~ring.desc_flag_owned;
        const nw = (w1 & 0x00FF_FFFF_FFFF_FFFF) | (@as(u64, nf) << 56);
        write64(core, ctx, off, nw) catch return;
    }

    /// The accelerator finishes: re-check the LIVE descriptor (the
    /// deferred-read discipline — revocation between grant and now turns
    /// the job into a reject, and nothing is scribbled), do the work,
    /// clear OWNED, and deliver the completion to the sender's RX ring.
    /// Completion payload: w0 = 0 ok / 1 rejected, w1 = the desc slot.
    fn accelComplete(self: *Machine, due: u64, id: u64) !void {
        const kv = self.accel_jobs.fetchRemove(id) orelse return;
        const job = kv.value;
        const acp = self.accels.getPtr(job.coord);
        if (acp) |ac| ac.busy = false;
        const is_display = acp != null and acp.?.kind == .display;
        var ok = false;
        if (self.regionDesc(job)) |desc| {
            if (desc.token != 0 and desc.token == job.token) {
                const core = &self.cores[job.core];
                const ctx = &core.contexts[job.ctx];
                if (is_display) {
                    // Present: read the frame the actor drew (deferred —
                    // a revoked grant would have failed the token check
                    // above and scribbled nothing) and snapshot it. The
                    // whole region is the frame; its checksum is the proof
                    // the drawing reached the glass.
                    var sum: u64 = 0;
                    var off: u64 = 0;
                    while (off + 8 <= desc.len) : (off += 8) {
                        sum +%= read64(core, ctx, desc.base + off) catch break;
                    }
                    acp.?.frames += 1;
                    acp.?.checksum = sum;
                    ok = true;
                } else {
                    // the DMA: C[i,j] = Σ_k A[i,k]·B[k,j], k ascending — the
                    // declared-deterministic contract, bit for bit
                    var i: u64 = 0;
                    outer: while (i < job.m) : (i += 1) {
                        var j: u64 = 0;
                        while (j < job.n) : (j += 1) {
                            var acc: f64 = 0;
                            var kk: u64 = 0;
                            while (kk < job.k) : (kk += 1) {
                                const a_at = desc.base + job.off_a + (i * job.k + kk) * 8;
                                const b_at = desc.base + job.off_b + (kk * job.n + j) * 8;
                                const av: f64 = @bitCast(read64(core, ctx, a_at) catch break :outer);
                                const bv: f64 = @bitCast(read64(core, ctx, b_at) catch break :outer);
                                acc += av * bv;
                            }
                            const c_at = desc.base + job.off_c + (i * job.n + j) * 8;
                            write64(core, ctx, c_at, @bitCast(acc)) catch break :outer;
                        }
                    }
                    ok = i == job.m;
                }
            }
        }
        self.setRegionOwned(job, false); // the release fence precedes the record
        self.trace("accel ${X} @{d} {s} slot{d}", .{ job.coord, due, if (ok) @as([]const u8, "complete") else "REVOKED", job.slot });
        var payload: [16]u8 = undefined;
        // word0: the architected grant-completion tag $6772 with the
        // status above it — far outside any program's message tag space,
        // so a joe dispatcher routes it without the silicon ever knowing
        // the program's message table.
        const status: u64 = if (ok) 0 else 1;
        std.mem.writeInt(u64, payload[0..8], 0x6772 | (status << 16), .little);
        std.mem.writeInt(u64, payload[8..16], job.slot, .little);
        const rx_token = blk: {
            // silicon presents whatever the target ring demands
            const core = &self.cores[job.core];
            const ctx = &core.contexts[job.ctx];
            break :blk read64(core, ctx, @as(u64, ring.slot_rx) * ring.desc_size + 24) catch 0;
        };
        const gram = mesh.Datagram{
            .send_id = self.nextSeq(),
            .src_die = self.die_id,
            .dst_core = job.core,
            .dst_ctx = job.ctx,
            .dst_slot = ring.slot_rx,
            .offset = 0,
            .token = rx_token,
            .payload = try self.alloc.dupe(u8, &payload),
        };
        try self.events.add(.{ .due = due + 4, .seq = self.nextSeq(), .kind = .{ .deliver = gram } });
    }

    pub fn device(self: *Machine, coord: u16) ?*dev.Device {
        const ep = self.devices.getPtr(coord) orelse return null;
        return &ep.dev;
    }

    // ── The IO plane (§6.5): egress hook and window-barrier ingress ──────

    /// Join the IO plane as `die_id`. From here on, sends through PTT
    /// entries whose route byte is non-zero leave through `egress`.
    pub fn attachPlane(self: *Machine, die_id: u16, egress: mesh.Egress) void {
        self.die_id = die_id;
        self.egress = egress;
    }

    /// Plane ingress: schedule a cross-die datagram arrival. Call only at
    /// window barriers, in the cluster's deterministic merge order. The
    /// destination coordinates were composed on another die, so they are
    /// validated here; an invalid target vanishes and the sender's timeout
    /// speaks (§6.1), exactly as for an unroutable local prefix.
    pub fn injectDeliver(self: *Machine, gram: mesh.Datagram, due: u64) !void {
        const ok = self.devices.contains(gram.dst_core) or self.accels.contains(gram.dst_core) or
            (gram.dst_core < self.cores.len and
                gram.dst_ctx < self.cfg.contexts_per_core and
                gram.dst_slot < ring.desc_slots);
        if (!ok) {
            self.alloc.free(gram.payload);
            self.stats.unroutable += 1;
            return;
        }
        try self.events.add(.{ .due = due, .seq = self.nextSeq(), .kind = .{ .deliver = gram } });
    }

    /// Plane ingress: an ack that crossed home. Window barriers only.
    pub fn injectAck(self: *Machine, send_id: u64, status: ring.Status, byte_count: u32, due: u64) !void {
        try self.events.add(.{
            .due = due,
            .seq = self.nextSeq(),
            .kind = .{ .ack = .{ .send_id = send_id, .status = status, .byte_count = byte_count } },
        });
    }

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

    /// Authorize WDEX declarations up to `cycles` for a context (§5.4): the
    /// supervisor's ceiling on how long a burst the actor may declare for
    /// itself. Privileged, like the base budget; survives SPWN.
    pub fn setWdexCeiling(self: *Machine, core_idx: u16, ctx_idx: u8, cycles: u64) void {
        self.cores[core_idx].contexts[ctx_idx].wdex_ceiling = cycles;
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

    fn write8(core: *Core, ctx: *Context, addr: u64, value: u64) MemError!void {
        (try bytesAt(core, ctx, addr, 1))[0] = @truncate(value);
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
    /// Sizing a CQ is software's contract (like ring layout); breaking it
    /// is not a dropped letter but a dead context — the record is still
    /// lost, but the loss becomes supervisable instead of eternal (§11
    /// q6, promoted in v2.6).
    /// Post a completion from outside the machine — tests exercising the
    /// queue contract directly.
    pub fn postCompletion(self: *Machine, core_idx: u16, ctx_idx: u8, cq_slot: u8, c: ring.Completion) void {
        self.cqPost(core_idx, ctx_idx, cq_slot, c);
    }

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
            // Which records may be lost quietly? Only the ones someone
            // else will say again. A transport verdict — an ack, a
            // reject, a timeout — is re-derivable by construction: the
            // peer retries, the timer fires again, and a protocol that
            // reads no verdicts (every compiled joe actor) never wanted
            // it. A DELIVERY or an EXIT is different: the message and
            // the obituary exist nowhere else, and losing one is the
            // silent-forever failure — a park with no wake, a death
            // with no mourner. Those kill the context that could not
            // hold them, so the exit link can speak (§11 q6, promoted).
            const irreplaceable = c.tag == .deliver or c.tag == .exit;
            if (irreplaceable and ctx.state != .faulted and ctx.state != .idle) {
                ctx.state = .faulted;
                ctx.fault = .cq_overflow;
                ctx.fault_addr = ctx.ip;
                if (core.current == ctx_idx) core.current = null;
                self.notifyExit(core, ctx_idx, ctx);
            }
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

    /// What a submission claims its payload is (A4 movement 1): the low
    /// two bits of the SQE's reserved hint word. A register send (TXR)
    /// makes no use of it — it is a message by construction — and an
    /// unclaimed 0 is legacy code, which the check waves through.
    fn claimOf(sqe: ring.SqEntry) ring.Dialect {
        if (sqe.op == .txr) return .msg;
        return @enumFromInt(@as(u2, @truncate(sqe.hint)));
    }

    fn sendDatagram(
        self: *Machine,
        src_core: u16,
        ptt_index: u16,
        offset: u64,
        payload: []const u8,
        reply: mesh.ReplyPath,
        /// What the submission CLAIMS its payload is (A4 movement 1).
        /// `any` means the sender made no claim — legacy code, and the
        /// only way past the check.
        claim: ring.Dialect,
    ) !void {
        const ptt = &self.cores[src_core].ptt;
        // An out-of-range or empty PTT slot is the same failure: no
        // capability to send there (§6.4). Reported via the CQ, as always.
        const entry = if (ptt_index < ptt.len) ptt[ptt_index] else ring.PttEntry{};
        // The dialect check rides the capability path, one compare after
        // the rights test: what the payload claims to be must equal what
        // the endpoint IS. A msg image aimed at an asking device would
        // have the device read a tag word as a reply window — that is
        // the hazard, and equality is what makes it unrepresentable.
        const dialect_ok = entry.dialect == .any or claim == .any or entry.dialect == claim;
        if (!entry.rights.send or !dialect_ok) {
            // No capability: the RBC rejects at the PTT. Routed through the
            // normal completion path (an immediate ack event) so the OWNED
            // clear, the release fence, and chain cancellation all behave
            // exactly as for any other failed copy.
            self.stats.rejects += 1;
            const send_id = self.nextSeq();
            try self.pending.put(send_id, .{ .reply = reply });
            try self.events.add(.{
                .due = self.cores[src_core].clock,
                .seq = self.nextSeq(),
                .kind = .{ .ack = .{ .send_id = send_id, .status = .reject_capability, .byte_count = 0 } },
            });
            return;
        }
        self.stats.sends += 1;
        const send_id = self.nextSeq();
        try self.pending.put(send_id, .{ .reply = reply });

        const now = self.cores[src_core].clock;
        if (entry.route != 0) {
            // Off-die (§6.5): the route byte selected an IO-plane path. The
            // plane owns it from here — its own latency, its own losses.
            // The RBC's part is unchanged: OWNED stays set, the timeout
            // arms, and the ack (if it survives the crossing twice) is an
            // ordinary completion. Software cannot tell remoteness except
            // by reading the bill.
            if (self.egress) |eg| {
                const g = mesh.Datagram{
                    .send_id = send_id,
                    .src_die = self.die_id,
                    .dst_core = entry.dstCore(),
                    .dst_ctx = entry.dstContext(),
                    .dst_slot = entry.dstSlot(),
                    .offset = offset,
                    .token = entry.token,
                    .payload = try self.alloc.dupe(u8, payload),
                };
                errdefer self.alloc.free(g.payload);
                try eg.emit(eg.ctx, .{ .route = entry.route, .sent_at = now, .kind = .{ .gram = g } });
            } else {
                // A route with no plane attached: off the edge of the
                // world. Only the timeout below speaks, honestly.
                self.stats.unroutable += 1;
            }
            try self.events.add(.{
                .due = now + self.cfg.link.send_timeout,
                .seq = self.nextSeq(),
                .kind = .{ .timeout = .{ .send_id = send_id } },
            });
            return;
        }
        // The peripheral row (§7): a device coordinate routes like any
        // other — context/slot bits below the row are device-defined.
        const routable = self.devices.contains(entry.dstCore()) or self.accels.contains(entry.dstCore()) or
            (entry.dstCore() < self.cores.len and
                entry.dstContext() < self.cfg.contexts_per_core and
                entry.dstSlot() < ring.desc_slots);
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
            .src_die = self.die_id,
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
        if (self.devices.contains(gram.dst_core))
            return self.deliverToDevice(due, gram);
        if (self.accels.contains(gram.dst_core))
            return self.deliverToAccel(due, gram);
        const core = &self.cores[gram.dst_core];
        const ctx = &core.contexts[gram.dst_ctx];
        const d = readDesc(ctx, gram.dst_slot);

        var status: ring.Status = .ok;
        var count: u32 = 0;
        var landing_cookie: u64 = 0;

        if (d.token != 0 and d.token != gram.token) {
            status = .reject_capability;
        } else if (blk: {
            // Admission needs BOTH a landing buffer and a completion slot:
            // accepting a delivery whose record can't post would silently
            // break the mandatory-completion guarantee under fan-in floods.
            // A full CQ is therefore ordinary backpressure (open question 6).
            const cq = readDesc(ctx, d.companion_cq);
            break :blk cq.isFull();
        }) {
            status = .reject_no_buffer;
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
            // Capability rejects post to *both* ends (§6.4) — a forged or
            // stale token is a security event the victim must be able to
            // see. A no_buffer reject is flow control: the receiver has
            // nothing actionable and, under a fan-in flood, receiver-side
            // reject records would crowd landed records out of the CQ.
            // The sender's reject ack below tells the whole story.
            if (status == .reject_capability) {
                self.cqPost(gram.dst_core, gram.dst_ctx, d.companion_cq, .{
                    .tag = .deliver,
                    .status = status,
                    .slot = gram.dst_slot,
                    .byte_count = 0,
                    .cookie = gram.token,
                });
            }
        }
        try self.ackSender(due, gram, gram.dst_core, status, count);
    }

    /// The ack rides the same fault-injected fabric back: it can be lost,
    /// in which case the sender's timeout tells the truth (§6.1) — "your
    /// datagram MAY have arrived; you don't get to know." A datagram from
    /// another die never touches the local pending map (send_ids are
    /// per-die counters): its ack rides the IO plane home instead.
    fn ackSender(self: *Machine, due: u64, gram: mesh.Datagram, from_core: u16, status: ring.Status, count: u32) !void {
        const send_id = gram.send_id;
        if (gram.src_die != self.die_id) {
            const eg = self.egress orelse return; // a plane we're not on: drop
            try eg.emit(eg.ctx, .{ .route = 0, .sent_at = due, .kind = .{ .ack = .{
                .dst_die = gram.src_die,
                .send_id = send_id,
                .status = status,
                .byte_count = count,
            } } });
            return;
        }
        const pend = self.pending.get(send_id) orelse return; // dup already resolved
        const onchip = pend.reply.core == from_core;
        if (onchip) {
            try self.events.add(.{
                .due = due + self.cfg.link.onchip_latency,
                .seq = self.nextSeq(),
                .kind = .{ .ack = .{ .send_id = send_id, .status = status, .byte_count = count } },
            });
        } else if (!mesh.roll(self.prng.random(), self.cfg.link.loss_ppm4k)) {
            try self.events.add(.{
                .due = due + mesh.latency(self.cfg.link, self.prng.random()),
                .seq = self.nextSeq(),
                .kind = .{ .ack = .{ .send_id = send_id, .status = status, .byte_count = count } },
            });
        }
    }

    /// A request reached the peripheral row (§7). The endpoint's token gates
    /// admission exactly as a ring descriptor's does; the device applies the
    /// request at fabric time `due`; any reply routes through the device's
    /// own PTT as ordinary fire-and-forget datagrams.
    fn deliverToDevice(self: *Machine, due: u64, gram: mesh.Datagram) !void {
        const ep = self.devices.getPtr(gram.dst_core).?;
        var status: ring.Status = .ok;
        var count: u32 = 0;
        if (ep.token != 0 and ep.token != gram.token) {
            status = .reject_capability;
            self.stats.rejects += 1;
        } else {
            const res = ep.dev.handle(due, gram.payload);
            status = res.status;
            if (status == .ok or status == .truncated) {
                count = @intCast(gram.payload.len);
                self.stats.delivered += 1;
                self.stats.dev_deliveries += 1;
                self.trace("dev ${X} @{d} accepted {d} bytes", .{ gram.dst_core, due, gram.payload.len });
            } else {
                self.stats.rejects += 1;
            }
            if (res.reply) |r| try self.deviceReply(ep, due, r);
        }
        try self.ackSender(due, gram, gram.dst_core, status, count);
        // A pad's Poll is a subscription: the answer is a stream of pushes,
        // not one reply. Every Poll re-aims the pad's push window at whoever
        // just subscribed — last wins — so a screen transition moves the
        // input stream to the new screen (§7.8). The first Poll also starts
        // the stream; later ones only redirect it.
        switch (ep.dev) {
            .pad => |*pad| if (status == .ok) {
                if (self.pending.get(gram.send_id)) |pend| {
                    const dc = &self.cores[pend.reply.core];
                    const dx = &dc.contexts[pend.reply.ctx];
                    const rx_token = read64(dc, dx, @as(u64, ring.slot_rx) * ring.desc_size + 24) catch 0;
                    self.setDevicePtt(gram.dst_core, 0, .{
                        .prefix_hi = 0xfd65_6400_0000_0000,
                        .prefix_lo = ring.PttEntry.loFrom(pend.reply.core, pend.reply.ctx, ring.slot_rx),
                        .rights = .{ .send = true },
                        .token = rx_token,
                    });
                }
                if (!pad.streaming) {
                    pad.streaming = true;
                    try self.events.add(.{ .due = due + pad.interval, .seq = self.nextSeq(), .kind = .{ .pad = .{ .coord = gram.dst_core } } });
                }
            },
            else => {},
        }
    }

    /// A pad's turn: push the next button state to the subscriber and
    /// schedule the one after, until the trace runs dry. The push is an
    /// ordinary device reply — same PTT capability, same fault-injected
    /// fabric, so a dropped push is a dropped input frame, as it would be
    /// on real hardware.
    fn padPush(self: *Machine, due: u64, coord: u16) !void {
        const ep = self.devices.getPtr(coord) orelse return;
        const pad = switch (ep.dev) {
            .pad => |*p| p,
            else => return,
        };
        if (pad.index >= pad.trace.len) return; // the trace is spent
        const buttons = pad.trace[pad.index];
        pad.index += 1;
        pad.pushed += 1;
        var data: [16]u8 = undefined;
        std.mem.writeInt(u64, data[0..8], pad.tag, .little);
        std.mem.writeInt(u64, data[8..16], buttons, .little);
        var r = dev.Reply{ .window = pad.window };
        r.data.appendSlice(&data) catch return;
        try self.deviceReply(ep, due, r);
        if (pad.index < pad.trace.len)
            try self.events.add(.{ .due = due + pad.interval, .seq = self.nextSeq(), .kind = .{ .pad = .{ .coord = coord } } });
    }

    /// Fire a device reply through the device's PTT: same capability
    /// discipline as software sends, but silicon doesn't wait — no pending
    /// entry, no timeout, no retry. Driver protocols are idempotent
    /// request/retry, so a lost reply just costs the requester another ask.
    fn deviceReply(self: *Machine, ep: *DevEndpoint, due: u64, r: dev.Reply) !void {
        const slot = ring.windowPtt(r.window);
        const entry = if (slot < ep.ptt.len) ep.ptt[slot] else ring.PttEntry{};
        if (!entry.rights.send) {
            // Reply aimed at an unbound slot: the request lied about its
            // reply window. Nothing routes; the requester's silence-timeout
            // is the only symptom, as for any bad address.
            self.stats.rejects += 1;
            return;
        }
        const routable = entry.dstCore() < self.cores.len and
            entry.dstContext() < self.cfg.contexts_per_core and
            entry.dstSlot() < ring.desc_slots;
        if (!routable) {
            self.stats.unroutable += 1;
            return;
        }
        self.stats.sends += 1;
        self.stats.dev_replies += 1;
        const gram = mesh.Datagram{
            .send_id = self.nextSeq(), // never in pending: no ack sought
            .src_die = self.die_id,
            .dst_core = entry.dstCore(),
            .dst_ctx = entry.dstContext(),
            .dst_slot = entry.dstSlot(),
            .offset = ring.windowOffset(r.window),
            .token = entry.token,
            .payload = undefined,
        };
        const p = mesh.plan(self.cfg.link, self.prng.random(), due);
        if (p.arrivals.len == 0) self.stats.lost += 1;
        if (p.arrivals.len == 2) self.stats.duplicated += 1;
        for (p.arrivals.constSlice()) |arrive| {
            var g = gram;
            g.payload = try self.alloc.dupe(u8, r.data.slice());
            try self.events.add(.{ .due = arrive, .seq = self.nextSeq(), .kind = .{ .deliver = g } });
        }
    }

    fn completeSend(self: *Machine, send_id: u64, status: ring.Status, byte_count: u32) !void {
        const kv = self.pending.fetchRemove(send_id) orelse return;
        const reply = kv.value.reply;
        if (status == .timeout) self.stats.timeouts += 1;
        // Release the transmit buffer: clear the OWNED bit (§6.2) — byte 1
        // bit 7 of the staged entry (near page or RAM), one byte store. The
        // completion record below is the release fence software observes.
        var staged: ?ring.SqEntry = null;
        if (reply.sqe_addr != 0) {
            const core = &self.cores[reply.core];
            const ctx = &core.contexts[reply.ctx];
            if (bytesAt(core, ctx, reply.sqe_addr, ring.sq_entry_size)) |mem| {
                mem[1] &= ~ring.SqEntry.flag_owned;
                var words: [4]u64 = undefined;
                for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, mem[i * 8 ..][0..8], .little);
                staged = ring.SqEntry.unpack(words);
            } else |_| {}
        }
        self.cqPost(reply.core, reply.ctx, reply.cq_slot, .{
            .tag = reply.tag,
            .status = status,
            .slot = reply.src_slot,
            .byte_count = byte_count,
            .cookie = reply.cookie,
        });
        // Autonomous descriptor behavior (§4.3): the RBC re-reads the
        // STAGED entry — its current bytes are the contract, which is what
        // makes clearing a flag the disarm mechanism.
        const sqe = staged orelse return;
        if (status == .timeout and sqe.flags & ring.SqEntry.flag_auto_rearm != 0) {
            // AUTO_REARM: a timeout is a tick; resubmit. Takes precedence
            // over LINK — a rearming entry's chain gets another chance
            // rather than a cancellation.
            const stamp: u16 = @truncate(reply.cookie >> 32);
            if (try self.submitStaged(reply.core, reply.ctx, reply.sqe_addr, reply.cq_slot, reply.src_slot, stamp)) {
                self.stats.auto_rearms += 1;
                self.trace("c{d}x{d} rearm @0x{X}", .{ reply.core, reply.ctx, reply.sqe_addr });
            }
        } else if (sqe.flags & ring.SqEntry.flag_link != 0 and sqe.link != 0) {
            if (status == .ok or status == .truncated) {
                // LINK: fire the next staged entry (near-page offset).
                if (try self.submitStaged(reply.core, reply.ctx, sqe.link, reply.cq_slot, reply.src_slot, sqe.link)) {
                    self.stats.chain_fires += 1;
                    self.trace("c{d}x{d} chain fire → ${X}", .{ reply.core, reply.ctx, sqe.link });
                } else {
                    // Malformed next entry: the chain breaks loudly.
                    self.cancelChain(reply.core, reply.ctx, sqe.link, reply.cq_slot, reply.src_slot);
                }
            } else {
                // Chain break: every remaining staged entry gets its record.
                self.cancelChain(reply.core, reply.ctx, sqe.link, reply.cq_slot, reply.src_slot);
            }
        }
    }

    /// The RBC submits a staged SQE on software's behalf: chain fires and
    /// AUTO_REARM resubmissions. `stamp16` identifies the staging location
    /// in the completion cookie's high half. Returns false when the entry
    /// is malformed (bad op, non-window target, unreadable buffer).
    fn submitStaged(self: *Machine, core_idx: u16, ctx_idx: u8, addr: u64, cq_slot: u8, src_slot: u8, stamp16: u16) !bool {
        const core = &self.cores[core_idx];
        const ctx = &core.contexts[ctx_idx];
        const mem = bytesAt(core, ctx, addr, ring.sq_entry_size) catch return false;
        var words: [4]u64 = undefined;
        for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, mem[i * 8 ..][0..8], .little);
        const sqe = ring.SqEntry.unpack(words);
        if (!ring.isWindow(sqe.target)) return false;
        var txr_payload: [8]u8 = undefined;
        const payload: []const u8 = switch (sqe.op) {
            .send => bytesAt(core, ctx, sqe.buf, sqe.len) catch return false,
            .txr => blk: {
                std.mem.writeInt(u64, &txr_payload, sqe.buf, .little);
                break :blk &txr_payload;
            },
            else => return false,
        };
        mem[1] |= ring.SqEntry.flag_owned;
        const cookie = @as(u64, sqe.cookie_lo) |
            (@as(u64, stamp16) << 32) |
            (@as(u64, @as(u16, @truncate(ctx.gen))) << 48);
        try self.sendDatagram(core_idx, ring.windowPtt(sqe.target), ring.windowOffset(sqe.target), payload, .{
            .core = core_idx,
            .ctx = ctx_idx,
            .cq_slot = cq_slot,
            .tag = if (sqe.op == .txr) .txr else .send,
            .cookie = cookie,
            .sqe_addr = addr,
            .src_slot = src_slot,
        }, claimOf(sqe));
        return true;
    }

    /// A chain broke: post `chain_cancelled` for every remaining staged
    /// entry, cookies intact — stage N, collect N records, always. The walk
    /// is capped so a mis-linked cycle can't spin the RBC forever.
    fn cancelChain(self: *Machine, core_idx: u16, ctx_idx: u8, first: u16, cq_slot: u8, src_slot: u8) void {
        const ctx = &self.cores[core_idx].contexts[ctx_idx];
        var off: u16 = first;
        var hops: u8 = 0;
        while (off != 0 and hops < 16) : (hops += 1) {
            if (@as(u32, off) + ring.sq_entry_size > near_size) break;
            var words: [4]u64 = undefined;
            for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, ctx.near[off + i * 8 ..][0..8], .little);
            const sqe = ring.SqEntry.unpack(words);
            self.trace("c{d}x{d} chain cancel ${X}", .{ core_idx, ctx_idx, off });
            self.cqPost(core_idx, ctx_idx, cq_slot, .{
                .tag = if (sqe.op == .txr) .txr else .send,
                .status = .chain_cancelled,
                .slot = src_slot,
                .byte_count = 0,
                .cookie = @as(u64, sqe.cookie_lo) |
                    (@as(u64, off) << 32) |
                    (@as(u64, @as(u16, @truncate(ctx.gen))) << 48),
            });
            self.stats.chain_cancels += 1;
            off = if (sqe.flags & ring.SqEntry.flag_link != 0) sqe.link else 0;
        }
    }

    fn handleEvent(self: *Machine, ev: mesh.Event) !void {
        switch (ev.kind) {
            .deliver => |gram| try self.deliver(ev.due, gram),
            .ack => |a| try self.completeSend(a.send_id, a.status, a.byte_count),
            .timeout => |t| try self.completeSend(t.send_id, .timeout, 0),
            .accel => |a| try self.accelComplete(ev.due, a.id),
            .pad => |pd| try self.padPush(ev.due, pd.coord),
        }
    }

    // ── Instruction execution ────────────────────────────────────────────

    const StepError = MemError || error{ BadOpcode, NoCapability, BadDescriptor, Brk, BadMacro, WdexCeiling, OutOfMemory };

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
                error.WdexCeiling => .wdex_ceiling,
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
                // A WDEX declaration, while active, replaces the base budget:
                // the burst may run until (declaration cycle + declared n).
                const tripped = if (core.wdex_budget != 0)
                    core.clock - core.wdex_base >= core.wdex_budget
                else
                    ctx.watchdog != 0 and core.clock - core.burst_start >= ctx.watchdog;
                if (tripped) {
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
        // $42 — WDM, the 65816's reserved expansion byte — opens the
        // extended page for exactly one opcode. Prefixes do not stack:
        // $42 $42 hits the null slot in xdecode and faults honestly.
        const enc = if (opcode == isa.ext_prefix)
            isa.xdecode[try read8(core, ctx, ctx.ip + 1)] orelse return error.BadOpcode
        else
            isa.decode[opcode] orelse return error.BadOpcode;
        const operand_addr = ctx.ip + 1 + @intFromBool(enc.page == .ext);
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
            // Byte memory: one byte at the effective address. `LDB` zero-
            // extends into A; `STB` writes A's low byte, the other seven
            // in memory untouched — no read-modify-write, memory is bytes.
            .ldb => {
                ctx.a = try read8(core, ctx, ea);
                ctx.p.setNZ(ctx.a);
            },
            .stb => try write8(core, ctx, ea, ctx.a),
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
            // Shifts: bare = one bit; `#n` = a barrel shift (count mod 64,
            // 0 = no-op, flags untouched). Carry is the last bit shifted
            // out — identical to n single-bit shifts, at constant cost.
            .asl => {
                const n: u6 = if (enc.mode == .imm8) @truncate(imm) else 1;
                if (n != 0) {
                    const sh: u6 = @intCast(64 - @as(u7, n));
                    ctx.p.c = (ctx.a >> sh) & 1 != 0;
                    ctx.a <<= n;
                    ctx.p.setNZ(ctx.a);
                }
            },
            .lsr => {
                const n: u6 = if (enc.mode == .imm8) @truncate(imm) else 1;
                if (n != 0) {
                    ctx.p.c = (ctx.a >> (n - 1)) & 1 != 0;
                    ctx.a >>= n;
                    ctx.p.setNZ(ctx.a);
                }
            },
            .rol => {
                const n: u6 = if (enc.mode == .imm8) @truncate(imm) else 1;
                var i: u7 = 0;
                while (i < n) : (i += 1) {
                    const cin: u64 = @intFromBool(ctx.p.c);
                    ctx.p.c = (ctx.a >> 63) != 0;
                    ctx.a = (ctx.a << 1) | cin;
                    ctx.p.setNZ(ctx.a);
                }
            },
            .ror => {
                const n: u6 = if (enc.mode == .imm8) @truncate(imm) else 1;
                var i: u7 = 0;
                while (i < n) : (i += 1) {
                    const cin: u64 = @intFromBool(ctx.p.c);
                    ctx.p.c = (ctx.a & 1) != 0;
                    ctx.a = (ctx.a >> 1) | (cin << 63);
                    ctx.p.setNZ(ctx.a);
                }
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
                }, .msg); // a register datagram is a message by construction
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
                if (sqe.op == .grant) {
                    // A4 movement 2: hand a capability to whoever this
                    // window names. The grant record arrives as an
                    // ordinary delivery — a capability moving is a
                    // message like any other, and the paper trail is
                    // therefore auditable by anyone who can read a CQ.
                    d.tail +%= 1;
                    writeDesc(ctx, desc_slot, d);
                    const slot_idx = ring.windowPtt(sqe.target);
                    const pe = if (slot_idx < core.ptt.len) core.ptt[slot_idx] else ring.PttEntry{};
                    const dst_core = pe.dstCore();
                    const dst_ctx = pe.dstContext();
                    var payload: [56]u8 = @splat(0);
                    const moved = if (pe.rights.send and dst_core < self.cores.len and
                        dst_ctx < self.cfg.contexts_per_core)
                        self.transferRegion(
                            core.id,
                            ctx_idx,
                            @truncate(sqe.buf),
                            dst_core,
                            dst_ctx,
                            @bitCast(@as(u4, @truncate(sqe.len))),
                        )
                    else
                        null;
                    const st: ring.Status = if (moved == null) .reject_capability else .ok;
                    if (moved) |g| {
                        // The grant record: what you got, and where it
                        // came from. Provenance is data, in a delivery,
                        // because everything auditable here already is.
                        const words_out = [_]u64{
                            ring.grant_record_tag,
                            g.slot,
                            g.token,
                            g.base,
                            g.len,
                            @as(u64, core.id) | (@as(u64, ctx_idx) << 16) |
                                (@as(u64, @as(u16, @truncate(ctx.gen))) << 32),
                            @as(u64, @truncate(sqe.buf)),
                        };
                        for (words_out, 0..) |w, i|
                            std.mem.writeInt(u64, payload[i * 8 ..][0..8], w, .little);
                        try self.sendDatagram(
                            core.id,
                            slot_idx,
                            ring.windowOffset(sqe.target),
                            &payload,
                            .{
                                .core = core.id,
                                .ctx = ctx_idx,
                                .cq_slot = d.companion_cq,
                                .tag = .send,
                                .cookie = sqe.cookie_lo,
                            },
                            .msg,
                        );
                        return .keep;
                    }
                    self.stats.rejects += 1;
                    self.cqPost(core.id, ctx_idx, d.companion_cq, .{
                        .tag = .send,
                        .status = st,
                        .byte_count = 0,
                        .cookie = sqe.cookie_lo,
                    });
                    return .keep;
                }
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
                }, claimOf(sqe));
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
                    if (self.cfg.scorch_parks) scorch(core, ctx);
                    // Resume after the LSTN once the ring has data.
                    return .switched_out;
                }
                // Contended LSTN (v2.6 candidate, measured before adopted):
                // immediate hot-path delivery is a privilege of an idle
                // core. If another context here is runnable, LSTN rotates —
                // requeued to resume past the LSTN, registers volatile
                // exactly as at any park. On-chip delivery outruns the
                // park (4 cycles beats the loop back to LSTN), so without
                // this a hot self-send loop monopolizes the core and an
                // unwatchdogged neighbor starves invisibly — the species
                // of failure this machine exists to exterminate. The
                // rotation is a pure function of run-queue state, so
                // replay stays bit-exact; the item-4 collapse made the
                // switch itself zero mechanism, so fairness is nearly
                // free precisely where a neighbor exists to deserve it.
                if (self.cfg.contended_lstn and otherRunnable(core, ctx_idx)) {
                    self.trace("c{d}x{d} @{d} LSTN rotates: slot{d} hot but the core is contended", .{ core.id, ctx_idx, core.clock, desc_slot });
                    try core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = ctx.ip });
                    if (self.cfg.scorch_parks) scorch(core, ctx);
                    return .switched_out;
                }
            },
            .cont => {
                const target = next_ip +% @as(u64, @bitCast(@as(i64, rel)));
                try core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = target });
            },
            .yld => {
                try core.runq.writeItem(.{ .ctx = ctx_idx, .gen = ctx.gen, .ip = ctx.ip });
                if (self.cfg.scorch_parks) scorch(core, ctx);
                return .switched_out;
            },
            .cqpop => {
                var words: [2]u64 = undefined;
                const got = try ringPop(core, ctx, desc_slot, &words);
                if (got) {
                    ctx.a = words[0];
                    ctx.x = words[1];
                    ctx.p.z = false;
                    // AUTO_REPOST with the DEFERRED grant: popping a landed
                    // delivery from a flagged ring re-enqueues the buffer of
                    // the PREVIOUS pop, holding the current one back — the
                    // just-popped payload is valid until the next CQPOP from
                    // this ring, unconditionally, even when a flood drains
                    // the ring dry. (An immediate grant collapses the window
                    // to zero at exactly that moment; found by Big Brother.)
                    // Capacity-1 rings would re-grant the buffer being read:
                    // architecturally meaningless, fault.
                    const rec = ring.Completion.fromWords(words[0], words[1]);
                    if (rec.tag == .deliver and
                        (rec.status == .ok or rec.status == .truncated))
                    {
                        var rx = readDesc(ctx, rec.slot);
                        if (rx.flags & ring.desc_flag_auto_repost != 0) {
                            if (rx.capacity() == 1) return error.BadDescriptor;
                            if (rx.flags & ring.desc_flag_repost_pending != 0) {
                                if (!rx.isFull()) {
                                    rx.tail +%= 1;
                                    self.stats.auto_reposts += 1;
                                }
                            } else {
                                rx.flags |= ring.desc_flag_repost_pending;
                            }
                            writeDesc(ctx, rec.slot, rx);
                            core.clock += 1; // countable, not free
                        }
                    }
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
            // ── Tier 0 scalar floating point (extended page, prefix $42) ──
            // FP64 lives in A as its bit pattern. IEEE 754, round-to-
            // nearest-even, no FTZ/DAZ, no fusion: every host computes
            // correctly-rounded +,−,×,÷,√ — bit-exact deterministic.
            .fadd, .fsub, .fmul, .fdiv => {
                const a: f64 = @bitCast(ctx.a);
                const m: f64 = @bitCast(try self.loadOperand(core, ctx, enc.mode, imm, ea));
                const r = switch (enc.mnemonic) {
                    .fadd => a + m,
                    .fsub => a - m,
                    .fmul => a * m,
                    .fdiv => a / m,
                    else => unreachable,
                };
                ctx.a = @bitCast(r);
                fpFlags(ctx, r);
            },
            .fsqrt => {
                const r = @sqrt(@as(f64, @bitCast(ctx.a)));
                ctx.a = @bitCast(r);
                fpFlags(ctx, r);
            },
            // ── Tier 1 vectors: the extended $?7 column ─────────────────
            // desc byte: one V index for unary forms, (d << 3) | s for
            // two-register forms. Same IEEE discipline as Tier 0 — RNE,
            // no FTZ, no fusion — eight lanes at a time.
            .vld => {
                const n = desc_slot & 7;
                for (&core.v[n], 0..) |*lane, i|
                    lane.* = try read64(core, ctx, ctx.x +% i * 8);
            },
            .vst => {
                const n = desc_slot & 7;
                if (ctx.x >> 56 == 0xFF) return error.BadAddress; // no vector stores through windows
                for (core.v[n], 0..) |lane, i|
                    try write64(core, ctx, ctx.x +% i * 8, lane);
            },
            .vbca => {
                core.v[desc_slot & 7] = @splat(ctx.a);
            },
            .vfadd, .vfsub, .vfmul, .vfdiv => {
                const d = (desc_slot >> 3) & 7;
                const s = desc_slot & 7;
                const vs = core.v[s];
                for (&core.v[d], vs) |*lane, ms| {
                    const a: f64 = @bitCast(lane.*);
                    const m: f64 = @bitCast(ms);
                    lane.* = @bitCast(switch (enc.mnemonic) {
                        .vfadd => a + m,
                        .vfsub => a - m,
                        .vfmul => a * m,
                        .vfdiv => a / m,
                        else => unreachable,
                    });
                }
            },
            .vadd, .vand, .vora, .veor => {
                const d = (desc_slot >> 3) & 7;
                const s = desc_slot & 7;
                const vs = core.v[s];
                for (&core.v[d], vs) |*lane, ms| {
                    lane.* = switch (enc.mnemonic) {
                        .vadd => lane.* +% ms,
                        .vand => lane.* & ms,
                        .vora => lane.* | ms,
                        .veor => lane.* ^ ms,
                        else => unreachable,
                    };
                }
            },
            .vfcmp => {
                // Lanewise f64 compare, predicate in A. Each lane becomes a
                // 1.0/0.0 mask that VRADD counts — NaN compares false except
                // `ne`, exactly as IEEE and the scalar FCMP already do.
                const d = (desc_slot >> 3) & 7;
                const s = desc_slot & 7;
                const pred: u3 = @truncate(ctx.a);
                const vs = core.v[s];
                for (&core.v[d], vs) |*lane, ms| {
                    const a: f64 = @bitCast(lane.*);
                    const m: f64 = @bitCast(ms);
                    const hit = switch (pred) {
                        0 => a == m,
                        1 => a != m,
                        2 => a < m,
                        3 => a <= m,
                        4 => a > m,
                        5 => a >= m,
                        else => false,
                    };
                    lane.* = @bitCast(@as(f64, if (hit) 1.0 else 0.0));
                }
            },
            .vradd => {
                // The spec'd tree, exactly: ((l0+l1)+(l2+l3))+((l4+l5)+(l6+l7)).
                // Reduction order is part of the contract (§5's bar says
                // "including reduction order"), so it is one shape, always.
                const l = core.v[desc_slot & 7];
                const f = struct {
                    fn of(w: u64) f64 {
                        return @bitCast(w);
                    }
                }.of;
                const r = ((f(l[0]) + f(l[1])) + (f(l[2]) + f(l[3]))) +
                    ((f(l[4]) + f(l[5])) + (f(l[6]) + f(l[7])));
                ctx.a = @bitCast(r);
                fpFlags(ctx, r);
            },
            .vrmax, .vrmin => {
                // Sequential fold, lane 0 bias on ties; any NaN wins as
                // the one canonical NaN. Deterministic in every case.
                const l = core.v[desc_slot & 7];
                var best: f64 = @bitCast(l[0]);
                var poison = std.math.isNan(best);
                for (l[1..]) |w| {
                    const x: f64 = @bitCast(w);
                    if (std.math.isNan(x)) poison = true;
                    if (!poison) {
                        const take = if (enc.mnemonic == .vrmax) x > best else x < best;
                        if (take) best = x;
                    }
                }
                const r: f64 = if (poison) @bitCast(@as(u64, 0x7ff8000000000000)) else best;
                ctx.a = @bitCast(r);
                fpFlags(ctx, r);
            },
            .vperm => {
                const d = (desc_slot >> 3) & 7;
                const s = desc_slot & 7;
                const src = core.v[s]; // copy: d == s must permute cleanly
                for (&core.v[d], 0..) |*lane, i|
                    lane.* = src[(ctx.a >> @intCast(i * 8)) & 7];
            },
            .fcmp => {
                // Z = equal, N = less, C = greater-or-equal (CMP's carry
                // convention). Unordered clears all three and raises V —
                // a NaN comparison is a fact, not a fault.
                const a: f64 = @bitCast(ctx.a);
                const m: f64 = @bitCast(try self.loadOperand(core, ctx, enc.mode, imm, ea));
                if (std.math.isNan(a) or std.math.isNan(m)) {
                    ctx.p.z = false;
                    ctx.p.n = false;
                    ctx.p.c = false;
                    ctx.p.v = true;
                } else {
                    ctx.p.z = a == m;
                    ctx.p.n = a < m;
                    ctx.p.c = a >= m;
                    ctx.p.v = false;
                }
            },
            .ftoi => {
                // Truncate toward zero (the C-cast convention). Out-of-range
                // saturates, NaN converts to 0 — both raise V; in-range
                // conversions clear it. Deterministic in every case.
                const a: f64 = @bitCast(ctx.a);
                const t = @trunc(a);
                var oob = true;
                const r: i64 = if (std.math.isNan(a))
                    0
                else if (t >= 9223372036854775808.0) // 2^63
                    std.math.maxInt(i64)
                else if (t < -9223372036854775808.0)
                    std.math.minInt(i64)
                else blk: {
                    oob = false;
                    break :blk @intFromFloat(t);
                };
                ctx.a = @bitCast(r);
                ctx.p.setNZ(ctx.a);
                ctx.p.v = oob;
            },
            .itof => {
                const r: f64 = @floatFromInt(@as(i64, @bitCast(ctx.a)));
                ctx.a = @bitCast(r);
                fpFlags(ctx, r);
            },
            .flds => {
                // FP32 widens on load — exactly, every f32 is an f64.
                const bits = std.mem.readInt(u32, (try bytesAt(core, ctx, ea, 4))[0..4], .little);
                const r: f64 = @floatCast(@as(f32, @bitCast(bits)));
                ctx.a = @bitCast(r);
                fpFlags(ctx, r);
            },
            .fsts => {
                // Narrow to FP32 (round-to-nearest-even) and store 4 bytes.
                // Plain memory only — a 4-byte window store is not a
                // datagram, and bytesAt faults it honestly.
                const s: f32 = @floatCast(@as(f64, @bitCast(ctx.a)));
                std.mem.writeInt(u32, (try bytesAt(core, ctx, ea, 4))[0..4], @as(u32, @bitCast(s)), .little);
            },
            .wdex => {
                // WDEX ##n (§5.4): declare this burst long — set its
                // remaining watchdog budget to n, checked against the
                // control block's ceiling (the supervisor's contract; an
                // actor must not edit its own leash). A second WDEX in the
                // same burst replaces the first; ##0 cancels back to the
                // base budget. No watchdog armed = nothing to extend.
                if (ctx.watchdog != 0) {
                    if (imm > ctx.wdex_ceiling) return error.WdexCeiling;
                    core.wdex_base = core.clock;
                    core.wdex_budget = imm;
                    self.trace("c{d}x{d} @{d} WDEX declares {d}-cycle burst (ceiling {d})", .{
                        core.id, ctx_idx, core.clock, imm, ctx.wdex_ceiling,
                    });
                }
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

    /// Flags after an FP-valued result: Z = numerically zero (either sign),
    /// N = the sign bit (so −0.0 sets both), V = NaN. Carry untouched.
    fn fpFlags(ctx: *Context, r: f64) void {
        ctx.p.z = r == 0.0;
        ctx.p.n = std.math.signbit(r);
        ctx.p.v = std.math.isNan(r);
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
            }, .msg); // store-through-window is TXR: a message
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
        // runUntil(∞) never pauses: no clock or due date reaches maxInt.
        while (true) if (try self.runUntil(std.math.maxInt(u64))) |reason| return reason;
    }

    /// Advance the die to `horizon`: execution and events strictly before
    /// it. Returns null when paused at the horizon with work or events
    /// still ahead — the die proceeds next window — or the terminal
    /// StopReason once nothing remains at all. A core may overshoot the
    /// horizon by the width of its last instruction; that is the same
    /// tolerance the event loop always had ("events strictly before this
    /// core's clock fire first"), and it is why the IO plane's window can
    /// equal its base latency exactly.
    pub fn runUntil(self: *Machine, horizon: u64) !?StopReason {
        while (true) {
            // The core furthest behind in virtual time that has work.
            var busy: ?*Core = null;
            for (self.cores) |*core| {
                core.dispatch();
                if (core.hasWork() and core.clock < horizon) {
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

            // No core has runnable work this side of the horizon: advance
            // virtual time to the next event, pause, or stop.
            if (next_ev != null and next_ev.? < horizon) {
                for (self.cores) |*core| core.clock = @max(core.clock, next_ev.?);
                const ev = self.events.remove();
                try self.handleEvent(ev);
                continue;
            }
            for (self.cores) |*core| {
                if (core.hasWork()) return null;
            }
            if (next_ev != null) return null;
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
