//! The joe loader: runs any .joe file that carries a `system` block.
//! No per-program demo_*.zig harness — the deployment is data in the
//! source, and everything a harness used to do by hand is mechanical
//! once the ABI is fixed:
//!
//!   placement    one instance per core unless `on N` says otherwise;
//!                `Actor[N]` replicas pack onto fresh cores (bounded by
//!                contexts AND a conservative PTT budget), each context
//!                in its own $2000 block. An actor's `spawn`s become
//!                further contexts on its core.
//!   wiring       an instance name as an argument = a capability: a PTT
//!                slot aimed at the target's RX ring, deduplicated per
//!                (core, target). Group references align: same size →
//!                counterpart; larger → each replica takes its slice
//!                (a []addr param); smaller → replicas share (plain
//!                addr). `index` hands each replica its own number.
//!   staging      params into the near page; group windows into the
//!                block's RAM array area. Ring descriptors are NOT
//!                loader business: compiled init self-stages them, so
//!                respawn re-runs init cleanly.
//!   supervision  per spawn: the child's watchdog + WDEX ceiling, the
//!                exit link, and the spawn record in the spawner's
//!                near page.
//!   timers       PTT 255 = the black hole, fixed by the ABI, one per
//!                core; the `after N` period becomes the fabric's
//!                send_timeout (per-send timeouts: open item, §10).
//!
//! The outcome reports every context by name — replicas as `ws[k]`,
//! spawned children as `parent/Actor#k` — with state, fault, and
//! `var` values read back.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");
const dev = @import("dev.zig");
const joe = @import("joe.zig");

/// Builtin device types a `system` block may instantiate — peripherals
/// are actors made of different silicon (spec §7), so they are named
/// like actors and wired like actors; only the loader knows they need
/// no context.
const device_table = [_]struct { name: []const u8, coord: u16 }{
    .{ .name = "Console", .coord = 0xFF00 },
};

/// Replica-packing limits per core.
const max_ctx_per_core: u8 = 200;
const ptt_budget: u16 = 240; // capability slots; 255 is the black hole

pub const Options = struct {
    seed: u64 = 0x6564,
    loss_ppm4k: u16 = 1024,
    dup_ppm4k: u16 = 128,
    base_latency: u64 = 200,
    jitter: u64 = 120,
    max_cycles: u64 = 50_000_000,
    trace: bool = false,
    /// Item 4's verifier: poison registers at every real park. Compiled
    /// joe must run identically — it never trusts the banked file.
    scorch: bool = false,
    /// The contended-LSTN rule (v2.6 candidate): hot-path delivery is a
    /// privilege of an idle core. Off reproduces the starvation for the
    /// pricing benchmark.
    contended_lstn: bool = true,
};

pub const VarOut = struct { name: []const u8, value: u64 };

pub const InstanceOut = struct {
    name: []const u8,
    actor: []const u8,
    core: u16,
    ctx: u8,
    state: machine.CtxState,
    fault: machine.Fault,
    code_bytes: usize,
    vars: []VarOut,
};

pub const Outcome = struct {
    alloc: std.mem.Allocator,
    reason: machine.StopReason,
    instances: []InstanceOut,
    /// What the console heard, when the system had one.
    console: ?[]u8 = null,
    cycles: u64,
    stats: machine.Stats,

    pub fn deinit(self: *Outcome) void {
        for (self.instances) |inst| {
            self.alloc.free(inst.name);
            self.alloc.free(inst.actor);
            for (inst.vars) |v| self.alloc.free(v.name);
            self.alloc.free(inst.vars);
        }
        self.alloc.free(self.instances);
        if (self.console) |c| self.alloc.free(c);
    }

    pub fn instance(self: *const Outcome, name: []const u8) ?*const InstanceOut {
        for (self.instances) |*inst| {
            if (std.mem.eql(u8, inst.name, name)) return inst;
        }
        return null;
    }

    pub fn varOf(self: *const Outcome, inst_name: []const u8, var_name: []const u8) ?u64 {
        const inst = self.instance(inst_name) orelse return null;
        for (inst.vars) |v| {
            if (std.mem.eql(u8, v.name, var_name)) return v.value;
        }
        return null;
    }
};

const Placed = struct {
    name: []const u8,
    actor: []const u8,
    args: []const joe.InstanceDecl.Arg,
    core: u16,
    ctx: u8,
    /// Replica index and count within this instance's group (0 of 1 for
    /// singletons) — alignment and `index` derive from these.
    gi: usize = 0,
    gn: usize = 1,
    /// Set for spawned children: index of the spawning instance.
    parent: ?usize = null,
    rec_off: u16 = 0,
    watchdog: u64 = 0,
};

const Group = struct { first: usize, count: usize };

fn fail(comptime fmt: []const u8, args: anytype) error{Deploy} {
    std.debug.print("joe run: " ++ fmt ++ "\n", args);
    return error.Deploy;
}

fn blockOf(ctx: u8) u64 {
    return machine.ram_base + @as(u64, ctx) * joe.abi.block_size;
}

pub fn simulate(alloc: std.mem.Allocator, source: []const u8, opts: Options) !Outcome {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var diag = joe.Diagnostic{};
    var pl = joe.plan(alloc, source, &diag) catch |err| {
        std.debug.print("joe: line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer pl.deinit();
    if (pl.instances.len == 0)
        return fail("this source has no `system` block to run", .{});

    // ── Pre-pass: group sizes and devices, so placement can budget PTT
    //    and references can look forward. ──
    var group_sizes = std.StringHashMap(usize).init(scratch);
    var devices = std.ArrayList(struct { name: []const u8, coord: u16 }).init(scratch);
    for (pl.instances) |inst| {
        const coord: ?u16 = for (device_table) |d| {
            if (std.mem.eql(u8, d.name, inst.actor)) break d.coord;
        } else null;
        if (coord) |c| {
            if (inst.args.len != 0 or inst.replicas != 1)
                return fail("{s}: a device takes no arguments and no replicas", .{inst.name});
            try devices.append(.{ .name = inst.name, .coord = c });
        } else {
            try group_sizes.put(inst.name, inst.replicas);
        }
    }

    // Conservative PTT need of one replica: its share of every group it
    // references, one for each singleton ref, one for the black hole.
    const pttNeed = struct {
        fn of(inst: *const joe.Plan.PlanInstance, sizes: *std.StringHashMap(usize)) u16 {
            var need: u16 = 1;
            for (inst.args) |a| {
                if (a != .ref) continue;
                const m = sizes.get(a.ref) orelse 1;
                const n: usize = @intCast(inst.replicas);
                need += @intCast(if (m > n) m / n else 1);
            }
            return need;
        }
    }.of;

    // ── Place: explicit `on N` wins; singletons take fresh cores;
    //    replicas pack fresh cores under the context and PTT budgets. ──
    var all = std.ArrayList(Placed).init(scratch);
    var ctx_count = std.AutoHashMap(u16, u8).init(scratch);
    var ptt_est = std.AutoHashMap(u16, u16).init(scratch);
    // A core belongs to ONE instance declaration: replicas pack among
    // themselves, never onto someone else's core. Mixing tiers starves
    // the minority — an aggregator co-resident with its own flood gets
    // 1/Nth of the pipeline while N-1 senders refill its ring.
    var core_owner = std.AutoHashMap(u16, usize).init(scratch);
    var groups = std.StringHashMap(Group).init(scratch);
    var next_core: u16 = 0;
    for (pl.instances, 0..) |*inst, decl_i| {
        if (for (device_table) |d| {
            if (std.mem.eql(u8, d.name, inst.actor)) break true;
        } else false) continue;
        if (inst.args.len > 8) return fail("more than 8 instance args", .{});
        const n: usize = @intCast(inst.replicas);
        const need = pttNeed(inst, &group_sizes);
        if (n > 1) try groups.put(inst.name, .{ .first = all.items.len, .count = n });
        for (0..n) |ri| {
            const core: u16 = inst.core orelse blk: {
                while (true) {
                    const used = ctx_count.get(next_core) orelse 0;
                    const ptt = ptt_est.get(next_core) orelse 0;
                    const owner = core_owner.get(next_core);
                    const mine = owner == null or owner.? == decl_i;
                    const fits = if (n > 1)
                        mine and used < max_ctx_per_core and ptt + need <= ptt_budget
                    else
                        used == 0;
                    if (fits) break :blk next_core;
                    next_core += 1;
                }
            };
            try core_owner.put(core, decl_i);
            const used = ctx_count.get(core) orelse 0;
            if (used == 255) return fail("{s}: core {d} is out of contexts", .{ inst.name, core });
            try ctx_count.put(core, used + 1);
            try ptt_est.put(core, (ptt_est.get(core) orelse 0) + need);
            try all.append(.{
                .name = if (n > 1)
                    try std.fmt.allocPrint(scratch, "{s}[{d}]", .{ inst.name, ri })
                else
                    inst.name,
                .actor = inst.actor,
                .args = inst.args,
                .core = core,
                .ctx = used,
                .gi = ri,
                .gn = n,
            });
        }
    }
    if (all.items.len == 0)
        return fail("a system of only devices has nothing to run", .{});
    var cores: u16 = 0;
    {
        var it = ctx_count.iterator();
        while (it.next()) |e| cores = @max(cores, e.key_ptr.* + 1);
    }

    // ── Compile everything — the list grows as spawns add children. ──
    const Compiled = struct { r: joe.Result, out: asm6564.Output };
    var compiled = std.ArrayList(Compiled).init(alloc);
    defer {
        for (compiled.items) |*c| {
            c.r.deinit();
            c.out.deinit();
        }
        compiled.deinit();
    }
    var timer_period: u64 = 0;
    var i: usize = 0;
    while (i < all.items.len) : (i += 1) {
        const pc = all.items[i];
        const block = blockOf(pc.ctx);
        var r = joe.compile(alloc, source, pc.actor, .{
            .origin = block,
            .data = block + joe.abi.data_off,
        }, &diag) catch |err| {
            std.debug.print("joe {s}: line {d}: {s}\n", .{ pc.actor, diag.line, diag.message });
            return err;
        };
        errdefer r.deinit();
        if (r.uses_timer) {
            if (timer_period != 0 and timer_period != r.timer_period)
                return fail("two different `after` periods in one system (open spec item, §10)", .{});
            timer_period = r.timer_period;
        }
        if (r.params.len != pc.args.len)
            return fail("{s}: {d} args for {d} params", .{ pc.name, pc.args.len, r.params.len });
        if (r.spawns.len > 0 and pc.parent != null)
            return fail("{s}: v1 supervises one level deep", .{pc.name});
        for (r.spawns, 0..) |s, k| {
            const core = pc.core; // SPWN is core-local: children live with the spawner
            const cctx = ctx_count.get(core) orelse 0;
            if (cctx == 255) return fail("{s}: core {d} is out of contexts", .{ pc.name, core });
            try ctx_count.put(core, cctx + 1);
            const cargs = try scratch.alloc(joe.InstanceDecl.Arg, s.args.len);
            for (s.args, 0..) |v, j| cargs[j] = .{ .int = v };
            try all.append(.{
                .name = try std.fmt.allocPrint(scratch, "{s}/{s}#{d}", .{ pc.name, s.actor, k }),
                .actor = s.actor,
                .args = cargs,
                .core = core,
                .ctx = cctx,
                .parent = i,
                .rec_off = s.rec_off,
                .watchdog = s.watchdog,
            });
        }
        var adiag = asm6564.Diagnostic{};
        const out = asm6564.assemble(alloc, r.asm_text, &adiag) catch |err| {
            std.debug.print("joe {s}: asm line {d}: {s}\n", .{ pc.actor, adiag.line, adiag.message });
            return err;
        };
        try compiled.append(.{ .r = r, .out = out });
    }

    var max_ctx: u8 = 1;
    {
        var it = ctx_count.iterator();
        while (it.next()) |e| max_ctx = @max(max_ctx, e.value_ptr.*);
    }

    // ── The machine. ──
    var m = try machine.Machine.init(alloc, .{
        .cores = cores,
        .contexts_per_core = max_ctx,
        .ram_size = std.math.ceilPowerOfTwoAssert(usize, @intCast(machine.ram_base + @as(u64, max_ctx) * joe.abi.block_size)),
        .seed = opts.seed,
        .link = .{
            .base_latency = opts.base_latency,
            .jitter = opts.jitter,
            .loss_ppm4k = opts.loss_ppm4k,
            .dup_ppm4k = opts.dup_ppm4k,
            .send_timeout = if (timer_period != 0) timer_period else 2500,
        },
        .max_cycles = opts.max_cycles,
        .trace = opts.trace,
        .scorch_parks = opts.scorch,
        .contended_lstn = opts.contended_lstn,
    });
    defer m.deinit();

    for (devices.items) |*d| {
        std.debug.assert(d.coord == 0xFF00); // Console is v1's only device
        try m.attachDevice(d.coord, joe.abi.token, .{ .console = dev.Console.init(alloc) });
    }

    // ── Wire, load and stage, instance by instance. Capability slots
    //    allocate on demand, deduplicated per (core, target). ──
    const ptt_next = try scratch.alloc(u16, cores);
    @memset(ptt_next, 0);
    const PttKey = struct { core: u16, lo: u64 };
    var ptt_map = std.AutoHashMap(PttKey, u16).init(scratch);
    const pttFor = struct {
        fn of(
            mach: *machine.Machine,
            map: *std.AutoHashMap(PttKey, u16),
            nexts: []u16,
            core: u16,
            lo: u64,
        ) !u16 {
            const key = PttKey{ .core = core, .lo = lo };
            if (map.get(key)) |s| return s;
            if (nexts[core] >= ptt_budget)
                return fail("core {d} is out of capability slots", .{core});
            const slot = nexts[core];
            nexts[core] += 1;
            try map.put(key, slot);
            mach.setPtt(core, slot, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = lo,
                .rights = .{ .send = true },
                .token = joe.abi.token,
            });
            return slot;
        }
    }.of;

    for (all.items, compiled.items) |*p, *c| {
        m.load(p.core, c.out.origin, c.out.code);
        const block = blockOf(p.ctx);
        const near = &m.cores[p.core].contexts[p.ctx].near;
        for (p.args, c.r.params, 0..) |a, prm, k| {
            switch (a) {
                .int => |v| {
                    if (prm.addr or prm.group)
                        return fail("{s}: param {s} wants a capability, got a number", .{ p.name, prm.name });
                    std.mem.writeInt(u64, near[prm.off..][0..8], v, .little);
                },
                .index => std.mem.writeInt(u64, near[prm.off..][0..8], p.gi, .little),
                .ref => |rname| {
                    // A device, a singleton, or a group — aligned to this
                    // replica: same size pairs off, larger slices, smaller
                    // shares.
                    if (for (devices.items) |*d| {
                        if (std.mem.eql(u8, d.name, rname)) break d;
                    } else null) |d| {
                        if (!prm.addr)
                            return fail("{s}: {s} is a device; param {s} must be addr", .{ p.name, rname, prm.name });
                        const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, ring.PttEntry.loFrom(d.coord, 0, 0));
                        std.mem.writeInt(u64, near[prm.off..][0..8], ring.windowAddr(slot, 0), .little);
                        continue;
                    }
                    if (groups.get(rname)) |g| {
                        const mcount = g.count;
                        const n = p.gn;
                        if (mcount > n) {
                            // slice: this replica owns mcount/n members
                            if (!prm.group)
                                return fail("{s}: param {s} must be []addr for a slice of {s}", .{ p.name, prm.name, rname });
                            if (mcount % n != 0)
                                return fail("{s}: {d} members of {s} do not divide over {d} replicas", .{ p.name, mcount, rname, n });
                            const slice = mcount / n;
                            if (slice > joe.abi.group_cap)
                                return fail("{s}: slice of {d} exceeds the group cap {d}", .{ p.name, slice, joe.abi.group_cap });
                            std.mem.writeInt(u64, near[prm.off..][0..8], slice, .little);
                            const start = g.first + p.gi * slice;
                            for (0..slice) |j| {
                                const t = &all.items[start + j];
                                const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, ring.PttEntry.loFrom(t.core, t.ctx, ring.slot_rx));
                                const at = block + prm.area + j * 8 - machine.ram_base;
                                std.mem.writeInt(u64, m.cores[p.core].ram[@intCast(at)..][0..8], ring.windowAddr(slot, 0), .little);
                            }
                            continue;
                        }
                        // pick: n >= mcount — replica gi maps to member gi*m/n
                        if (!prm.addr)
                            return fail("{s}: param {s} must be addr (each replica gets one of {s})", .{ p.name, prm.name, rname });
                        if (n % mcount != 0)
                            return fail("{s}: {d} replicas do not divide over {d} members of {s}", .{ p.name, n, mcount, rname });
                        const t = &all.items[g.first + (p.gi * mcount) / n];
                        const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, ring.PttEntry.loFrom(t.core, t.ctx, ring.slot_rx));
                        std.mem.writeInt(u64, near[prm.off..][0..8], ring.windowAddr(slot, 0), .little);
                        continue;
                    }
                    const t = for (all.items) |*t2| {
                        if (t2.parent == null and t2.gn == 1 and std.mem.eql(u8, t2.name, rname)) break t2;
                    } else return fail("{s}: no instance named {s}", .{ p.name, rname });
                    if (!prm.addr)
                        return fail("{s}: arg {d} names an instance but the param is not addr", .{ p.name, k });
                    const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, ring.PttEntry.loFrom(t.core, t.ctx, ring.slot_rx));
                    std.mem.writeInt(u64, near[prm.off..][0..8], ring.windowAddr(slot, 0), .little);
                },
            }
        }
        if (c.r.self_slot) |soff| {
            // `send self` (Amendment 1): a capability to your own RX ring.
            // Same core, so delivery is on-chip — never rides the mesh.
            const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, ring.PttEntry.loFrom(p.core, p.ctx, ring.slot_rx));
            std.mem.writeInt(u64, near[soff..][0..8], ring.windowAddr(slot, 0), .little);
        }
        if (c.r.uses_timer) {
            m.setPtt(p.core, 255, .{
                .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
                .rights = .{ .send = true },
                .token = 0,
            });
        }
        if (p.parent) |pi| {
            const parent = all.items[pi];
            const layout = joe.Layout{ .origin = block, .data = block + joe.abi.data_off };
            const pnear = &m.cores[parent.core].contexts[parent.ctx].near;
            const rec = [_]u64{ p.ctx, block, block + joe.abi.block_size, 0, layout.timerBase() };
            for (rec, 0..) |wv, j| {
                std.mem.writeInt(u64, pnear[p.rec_off + j * 8 ..][0..8], wv, .little);
            }
            m.setWatchdog(p.core, p.ctx, p.watchdog);
            m.setWdexCeiling(p.core, p.ctx, p.watchdog);
            m.linkSupervisor(p.core, p.ctx, parent.ctx, ring.slot_cq);
        }
    }

    // ── Spawn declared instances, last first, so servers declared later
    //    are listening before openers move. Children start via SPWN. ──
    var s = all.items.len;
    while (s > 0) {
        s -= 1;
        const p = &all.items[s];
        if (p.parent != null) continue;
        try m.spawn(p.core, p.ctx, blockOf(p.ctx), blockOf(p.ctx) + joe.abi.block_size, 0);
    }

    const reason = try m.run();

    // ── Read the system back. ──
    var insts = std.ArrayList(InstanceOut).init(alloc);
    errdefer insts.deinit();
    var max_clock: u64 = 0;
    for (m.cores) |*core| max_clock = @max(max_clock, core.clock);
    for (all.items, compiled.items) |*p, *c| {
        const ctx = &m.cores[p.core].contexts[p.ctx];
        var vars = std.ArrayList(VarOut).init(alloc);
        for (c.r.vars) |v| {
            try vars.append(.{
                .name = try alloc.dupe(u8, v.name),
                .value = std.mem.readInt(u64, ctx.near[v.off..][0..8], .little),
            });
        }
        try insts.append(.{
            .name = try alloc.dupe(u8, p.name),
            .actor = try alloc.dupe(u8, p.actor),
            .core = p.core,
            .ctx = p.ctx,
            .state = ctx.state,
            .fault = ctx.fault,
            .code_bytes = c.out.code.len,
            .vars = try vars.toOwnedSlice(),
        });
    }
    var console: ?[]u8 = null;
    for (devices.items) |*d| {
        if (d.coord == 0xFF00) {
            console = try alloc.dupe(u8, m.device(d.coord).?.console.out.items);
            break;
        }
    }
    return .{
        .alloc = alloc,
        .reason = reason,
        .instances = try insts.toOwnedSlice(),
        .console = console,
        .cycles = max_clock,
        .stats = m.stats,
    };
}

pub fn run(alloc: std.mem.Allocator, source: []const u8, opts: Options) !void {
    var o = try simulate(alloc, source, opts);
    defer o.deinit();
    const stdout = std.io.getStdOut().writer();
    // Translate the machine's stop reason into system terms: it stops
    // when the fabric goes quiet, and quiet-with-corpses can be exactly
    // what supervision intended — abandoned workers stay dead.
    var running: usize = 0;
    for (o.instances) |inst| {
        if (inst.state == .ready) running += 1;
    }
    const verdict = switch (o.reason) {
        .deadlock => if (running == 0)
            "quiescent — the work is done, the servers are parked"
        else
            "DEADLOCK: something is stuck",
        .all_halted => "all instances halted",
        .faulted => "quiescent, with the dead left where they fell (supervision may intend this)",
        .max_cycles => "hit max_cycles — something never went quiet",
    };
    try stdout.print(
        \\sim6564 — joe: system of {d} instance(s)
        \\  seed 0x{X}, loss {d}/4096 ({d:.1}%), dup {d}/4096
        \\
        \\  outcome: {s}
        \\
    , .{
        o.instances.len,
        opts.seed,
        opts.loss_ppm4k,
        @as(f64, @floatFromInt(opts.loss_ppm4k)) * 100.0 / 4096.0,
        opts.dup_ppm4k,
        verdict,
    });
    const shown = @min(o.instances.len, 12);
    for (o.instances[0..shown]) |inst| {
        try stdout.print("  {s} = {s} @ core {d}.{d}: {s}", .{
            inst.name, inst.actor, inst.core, inst.ctx, @tagName(inst.state),
        });
        if (inst.state == .faulted)
            try stdout.print(" ({s})", .{@tagName(inst.fault)});
        try stdout.print(" [{d} B]", .{inst.code_bytes});
        for (inst.vars) |v| try stdout.print("  {s}={d}", .{ v.name, v.value });
        try stdout.print("\n", .{});
    }
    if (o.instances.len > shown) {
        var halted: usize = 0;
        var parked: usize = 0;
        var faulted: usize = 0;
        for (o.instances[shown..]) |inst| {
            switch (inst.state) {
                .halted => halted += 1,
                .parked => parked += 1,
                .faulted => faulted += 1,
                else => {},
            }
        }
        try stdout.print("  … and {d} more: {d} parked, {d} halted, {d} faulted\n", .{
            o.instances.len - shown, parked, halted, faulted,
        });
    }
    if (o.console) |text| {
        try stdout.print("\n  the console heard:\n\n", .{});
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (l.len > 0) try stdout.print("    {s}\n", .{l});
        }
    }
    try stdout.print(
        \\
        \\  cycles: {d}   instructions: {d}
        \\  fabric: {d} sends ({d} into the void), {d} delivered, {d} lost,
        \\          {d} duplicated, {d} timeouts, {d} rejects
        \\
    , .{
        o.cycles,
        o.stats.instructions,
        o.stats.sends,
        o.stats.unroutable,
        o.stats.delivered,
        o.stats.lost,
        o.stats.duplicated,
        o.stats.timeouts,
        o.stats.rejects,
    });
    if (o.reason == .max_cycles) std.process.exit(1);
}
