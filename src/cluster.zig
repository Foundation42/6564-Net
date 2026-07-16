//! The IO plane (spec §6.5, v2.4): multiple dies — each a complete Machine
//! running its untouched single-threaded deterministic loop — joined by a
//! conservative-horizon window scheme, one die per host core if you like.
//!
//! Transparency: software addresses remoteness with one byte. A PTT entry
//! whose route byte is non-zero egresses to the die that the cluster's
//! routing table names; the destination coordinates in the entry apply
//! within that die. Same SEND, same acks, same timeouts, same programs —
//! a remote prefix is a prefix that is farther away, which is §3.2's claim
//! finally cashed at machine scale.
//!
//! Determinism, and why threads are free:
//!  - The window equals the plane's base latency, so traffic emitted in
//!    window k is due no earlier than window k+1: injecting at barriers
//!    never hands a die an event in its past (a core may overshoot the
//!    horizon by one instruction — the same tolerance the event loop has
//!    always had for events due mid-instruction).
//!  - Within a window, dies share nothing: each owns its outbox and its
//!    plane PRNG, and rolls the plane's fault model for its own egress.
//!  - The barrier merge sorts by (due, src_die, seq) before injecting.
//! Consequently results are bit-identical at any thread count — guarded
//! by test, not hoped for.

const std = @import("std");
const ring = @import("ring.zig");
const mesh = @import("mesh.zig");
const machine = @import("machine.zig");
const topology = @import("topology.zig");

/// Route-table entry meaning "no such path": the plane's black hole.
pub const no_route: u16 = 0xFFFF;
pub const route_slots = 256;

pub const Config = struct {
    dies: u16 = 2,
    /// One configuration for every die (per-die seeds are derived).
    die: machine.Config = .{},
    /// The IO plane's fault model. base_latency sets the window, so it
    /// must exceed zero; make it dearer than the on-die mesh — that is
    /// the honest physics of leaving a die. send_timeout is unused here:
    /// timeouts are armed by the sending die from its own link config.
    plane: mesh.LinkConfig = .{
        .base_latency = 2000,
        .jitter = 500,
        .loss_ppm4k = 0,
        .dup_ppm4k = 0,
    },
    seed: u64 = 0x6564,
    /// Step dies on host threads within each window.
    parallel: bool = false,
    /// Where die threads land on an asymmetric host (Zen X3D: one
    /// big-cache CCD, one high-frequency CCD). Placement is a wall-clock
    /// knob only — results are bit-identical regardless (the whole point
    /// of the conservative windows). Best-effort: silently unpinned off
    /// Linux or when sysfs is unreadable.
    pin: PinPolicy = .none,
};

pub const PinPolicy = enum {
    none,
    /// Round-robin across L3 domains, low indices first — on typical Zen
    /// numbering those are distinct physical cores before SMT siblings.
    spread,
    /// Everyone onto the big-cache CCD: barrier traffic stays in one L3.
    vcache,
    /// Everyone onto the high-frequency CCD: clocks over cache.
    freq,
};

pub const PlaneStats = struct {
    grams: u64 = 0,
    acks: u64 = 0,
    lost: u64 = 0,
    duplicated: u64 = 0,
    unroutable: u64 = 0,

    fn fold(self: *PlaneStats, other: *PlaneStats) void {
        self.grams += other.grams;
        self.acks += other.acks;
        self.lost += other.lost;
        self.duplicated += other.duplicated;
        self.unroutable += other.unroutable;
        other.* = .{};
    }
};

/// One item of barrier traffic, fault model already applied.
const Queued = struct {
    dst_die: u16,
    src_die: u16,
    seq: u64,
    due: u64,
    kind: union(enum) {
        gram: mesh.Datagram,
        ack: struct { send_id: u64, status: ring.Status, byte_count: u32 },
    },

    fn lessThan(_: void, a: Queued, b: Queued) bool {
        if (a.due != b.due) return a.due < b.due;
        if (a.src_die != b.src_die) return a.src_die < b.src_die;
        return a.seq < b.seq;
    }
};

/// A die's side of the plane: outbox, egress PRNG, per-window stats.
/// Touched only by its die's thread between barriers.
const Outbox = struct {
    cluster: *Cluster,
    die: u16,
    prng: std.Random.DefaultPrng,
    items: std.ArrayListUnmanaged(Queued) = .{},
    seq: u64 = 0,
    stats: PlaneStats = .{},
};

pub const Outcome = struct {
    /// Per-die stop reasons. A die whose actors park forever (a service
    /// die still listening when the work ends) reads `.deadlock` — at
    /// cluster level that only means "was still listening".
    reasons: []machine.StopReason,
    windows: u64,
    plane: PlaneStats,

    pub fn deinit(self: *Outcome, alloc: std.mem.Allocator) void {
        alloc.free(self.reasons);
    }
};

pub const Cluster = struct {
    /// Must be thread-safe when cfg.parallel is set: dies allocate from
    /// worker threads, and a payload may be freed by the die it lands on.
    /// GPA's default config, smp_allocator and std.testing.allocator all
    /// qualify.
    alloc: std.mem.Allocator,
    cfg: Config,
    dies: []machine.Machine,
    routes: [][route_slots]u16,
    outboxes: []Outbox,
    window: u64,
    stats: PlaneStats = .{},

    /// Heap-constructed so outbox back-pointers stay stable.
    pub fn init(alloc: std.mem.Allocator, cfg: Config) !*Cluster {
        std.debug.assert(cfg.dies >= 1);
        std.debug.assert(cfg.plane.base_latency > 0);
        const self = try alloc.create(Cluster);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .cfg = cfg,
            .dies = &.{},
            .routes = &.{},
            .outboxes = &.{},
            .window = cfg.plane.base_latency,
        };
        const shared = self.alloc;
        self.routes = try shared.alloc([route_slots]u16, cfg.dies);
        for (self.routes) |*row| @memset(row, no_route);
        self.outboxes = try shared.alloc(Outbox, cfg.dies);
        self.dies = try shared.alloc(machine.Machine, cfg.dies);
        var made: usize = 0;
        errdefer {
            for (self.dies[0..made]) |*d| d.deinit();
            shared.free(self.dies);
            shared.free(self.outboxes);
            shared.free(self.routes);
        }
        for (self.dies, 0..) |*d, i| {
            var die_cfg = cfg.die;
            die_cfg.seed = cfg.seed ^ (0x9E37_79B9_7F4A_7C15 *% (@as(u64, i) + 1));
            d.* = try machine.Machine.init(shared, die_cfg);
            made += 1;
        }
        for (self.outboxes, 0..) |*ob, i| {
            ob.* = .{
                .cluster = self,
                .die = @intCast(i),
                .prng = std.Random.DefaultPrng.init(
                    cfg.seed ^ (0xC2B2_AE3D_27D4_EB4F *% (@as(u64, i) + 1)),
                ),
            };
            self.dies[i].attachPlane(@intCast(i), .{ .ctx = ob, .emit = emit });
        }
        return self;
    }

    pub fn deinit(self: *Cluster) void {
        const shared = self.alloc;
        for (self.dies) |*d| d.deinit();
        for (self.outboxes) |*ob| {
            for (ob.items.items) |q| switch (q.kind) {
                .gram => |g| shared.free(g.payload),
                else => {},
            };
            ob.items.deinit(shared);
        }
        shared.free(self.dies);
        shared.free(self.outboxes);
        shared.free(self.routes);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    pub fn die(self: *Cluster, i: u16) *machine.Machine {
        return &self.dies[i];
    }

    /// Name the die a route byte leads to, per source die. Route 0 is the
    /// on-die mesh by definition and cannot be remapped.
    pub fn setRoute(self: *Cluster, from_die: u16, route_byte: u8, to_die: u16) void {
        std.debug.assert(route_byte != 0);
        std.debug.assert(to_die < self.dies.len and to_die != from_die);
        self.routes[from_die][route_byte] = to_die;
    }

    /// The die-side egress hook: applies routing and the plane's fault
    /// model (from the DIE's own PRNG — deterministic regardless of host
    /// threading) and queues barrier traffic. Runs mid-window on the
    /// die's thread; touches only its own outbox.
    fn emit(ctx: *anyopaque, out: mesh.Outbound) error{OutOfMemory}!void {
        const ob: *Outbox = @ptrCast(@alignCast(ctx));
        const cl = ob.cluster;
        const shared = cl.alloc;
        switch (out.kind) {
            .gram => |g| {
                const dst = cl.routes[ob.die][out.route];
                if (dst == no_route or dst >= cl.dies.len or dst == ob.die) {
                    // A route byte with no path: the plane's black hole.
                    // Only the sender's timeout speaks (§6.1).
                    shared.free(g.payload);
                    ob.stats.unroutable += 1;
                    return;
                }
                ob.stats.grams += 1;
                const p = mesh.plan(cl.cfg.plane, ob.prng.random(), out.sent_at);
                if (p.arrivals.len == 0) {
                    shared.free(g.payload);
                    ob.stats.lost += 1;
                    return;
                }
                if (p.arrivals.len == 2) ob.stats.duplicated += 1;
                for (p.arrivals.constSlice(), 0..) |due, idx| {
                    var gg = g;
                    if (idx != 0) gg.payload = try shared.dupe(u8, g.payload);
                    ob.seq += 1;
                    try ob.items.append(shared, .{
                        .dst_die = dst,
                        .src_die = ob.die,
                        .seq = ob.seq,
                        .due = due,
                        .kind = .{ .gram = gg },
                    });
                }
            },
            .ack => |a| {
                if (a.dst_die >= cl.dies.len) return;
                ob.stats.acks += 1;
                if (mesh.roll(ob.prng.random(), cl.cfg.plane.loss_ppm4k)) {
                    ob.stats.lost += 1;
                    return;
                }
                ob.seq += 1;
                try ob.items.append(shared, .{
                    .dst_die = a.dst_die,
                    .src_die = ob.die,
                    .seq = ob.seq,
                    .due = out.sent_at + mesh.latency(cl.cfg.plane, ob.prng.random()),
                    .kind = .{ .ack = .{
                        .send_id = a.send_id,
                        .status = a.status,
                        .byte_count = a.byte_count,
                    } },
                });
            },
        }
    }

    fn dieWorker(d: *machine.Machine, horizon: u64, result: *?machine.StopReason, err: *?anyerror) void {
        result.* = d.runUntil(horizon) catch |e| blk: {
            err.* = e;
            break :blk null;
        };
    }

    /// Persistent worker pool: one thread per die for the whole run —
    /// windows are far too frequent to pay a spawn per die per window.
    /// (Measured before fixing: 16 dies x 12k windows of spawn/join burned
    /// 3.7x the sequential wall clock. Barriers are cheap; spawns are not.)
    const Pool = struct {
        mutex: std.Thread.Mutex = .{},
        start: std.Thread.Condition = .{},
        done: std.Thread.Condition = .{},
        gen: u64 = 0,
        horizon: u64 = 0,
        remaining: usize = 0,
        quit: bool = false,
    };

    /// Decide the cpu each die thread pins to (null = unpinned).
    fn planPins(policy: PinPolicy, pins: []?usize) void {
        if (policy == .none) return;
        const ncpu = std.Thread.getCpuCount() catch return;
        const topo = topology.detectTopology(ncpu) orelse return;
        var cpus: [topology.MAX_CPUS_PER_GROUP * topology.MAX_GROUPS]usize = undefined;
        switch (policy) {
            .none => {},
            .vcache => {
                const cn = topo.vcacheCpus(cpus[0..]);
                if (cn == 0) return;
                for (pins, 0..) |*p, i| p.* = cpus[i % cn];
            },
            .freq => {
                var cn = topo.freqCpus(cpus[0..]);
                if (cn == 0) cn = topo.vcacheCpus(cpus[0..]); // single-CCD box
                if (cn == 0) return;
                for (pins, 0..) |*p, i| p.* = cpus[i % cn];
            },
            .spread => {
                if (topo.ng == 0) return;
                for (pins, 0..) |*p, i| {
                    const g = &topo.groups[i % topo.ng];
                    if (g.n == 0) continue;
                    p.* = g.cpus[(i / topo.ng) % g.n];
                }
            },
        }
    }

    fn poolWorker(
        self: *Cluster,
        pool: *Pool,
        i: usize,
        pin: ?usize,
        results: []?machine.StopReason,
        errs: []?anyerror,
    ) void {
        if (pin) |cpu| topology.pinToCpu(cpu);
        var seen: u64 = 0;
        while (true) {
            pool.mutex.lock();
            while (pool.gen == seen and !pool.quit) pool.start.wait(&pool.mutex);
            if (pool.quit) {
                pool.mutex.unlock();
                return;
            }
            seen = pool.gen;
            const horizon = pool.horizon;
            pool.mutex.unlock();

            dieWorker(&self.dies[i], horizon, &results[i], &errs[i]);

            pool.mutex.lock();
            pool.remaining -= 1;
            if (pool.remaining == 0) pool.done.signal();
            pool.mutex.unlock();
        }
    }

    /// The window loop: step every die to the horizon (threaded or not —
    /// same bits), then exchange at the barrier; finish when every die is
    /// terminal and the plane is empty.
    pub fn run(self: *Cluster) !Outcome {
        const n = self.dies.len;
        const results = try self.alloc.alloc(?machine.StopReason, n);
        defer self.alloc.free(results);
        const errs = try self.alloc.alloc(?anyerror, n);
        defer self.alloc.free(errs);
        var scratch = std.ArrayListUnmanaged(Queued){};
        defer scratch.deinit(self.alloc);

        const threaded = self.cfg.parallel and n > 1;
        var pool = Pool{};
        const threads: []std.Thread = if (threaded) try self.alloc.alloc(std.Thread, n) else &.{};
        defer if (threaded) self.alloc.free(threads);
        var spawned: usize = 0;
        defer if (threaded) {
            pool.mutex.lock();
            pool.quit = true;
            pool.start.broadcast();
            pool.mutex.unlock();
            for (threads[0..spawned]) |t| t.join();
        };
        if (threaded) {
            var pins: [256]?usize = @splat(null);
            planPins(self.cfg.pin, pins[0..@min(n, pins.len)]);
            for (threads, 0..) |*t, i| {
                const pin = if (i < pins.len) pins[i] else null;
                t.* = try std.Thread.spawn(.{}, poolWorker, .{ self, &pool, i, pin, results, errs });
                spawned += 1;
            }
        }

        var windows: u64 = 0;
        var horizon: u64 = self.window;
        while (true) {
            windows += 1;
            @memset(errs, null);
            if (threaded) {
                pool.mutex.lock();
                pool.gen += 1;
                pool.horizon = horizon;
                pool.remaining = n;
                pool.start.broadcast();
                while (pool.remaining != 0) pool.done.wait(&pool.mutex);
                pool.mutex.unlock();
            } else {
                for (0..n) |i| dieWorker(&self.dies[i], horizon, &results[i], &errs[i]);
            }
            for (errs) |e| if (e) |err| return err;

            // The barrier: drain every outbox into one deterministically
            // ordered sequence and inject.
            scratch.clearRetainingCapacity();
            for (self.outboxes) |*ob| {
                try scratch.appendSlice(self.alloc, ob.items.items);
                ob.items.clearRetainingCapacity();
                self.stats.fold(&ob.stats);
            }
            std.mem.sort(Queued, scratch.items, {}, Queued.lessThan);
            for (scratch.items) |q| switch (q.kind) {
                .gram => |g| try self.dies[q.dst_die].injectDeliver(g, q.due),
                .ack => |a| try self.dies[q.dst_die].injectAck(a.send_id, a.status, a.byte_count, q.due),
            };

            var all_done = true;
            for (results) |r| {
                if (r == null) all_done = false;
            }
            if (all_done and scratch.items.len == 0) break;
            horizon += self.window;
        }

        const reasons = try self.alloc.alloc(machine.StopReason, n);
        for (reasons, results) |*r, res| r.* = res.?;
        return .{ .reasons = reasons, .windows = windows, .plane = self.stats };
    }
};
