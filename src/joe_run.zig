//! The joe loader: runs any .joe file that carries a `system` block.
//! No per-program demo_*.zig harness — the deployment is data in the
//! source, and everything a harness used to do by hand is mechanical
//! once the ABI is fixed:
//!
//!   placement    one instance per core unless `on N` says otherwise;
//!                instances sharing a core become contexts, each in its
//!                own $1000 block (code, rings, buffers, stack). An
//!                actor's `spawn`s become further contexts on its core.
//!   wiring       an instance name as an argument = a capability: a PTT
//!                slot in the sender's core, aimed at the target's RX
//!                ring — the loader binds it like wiring two actors
//!   staging      params written into the near page; addr params get
//!                the window value of their allocated slot. Ring
//!                descriptors are NOT loader business: compiled init
//!                self-stages them, so respawn re-runs init cleanly.
//!   supervision  per spawn: the child's watchdog + WDEX ceiling, the
//!                exit link to the spawner's CQ, and the spawn record
//!                in the spawner's near page ({ctx, entry, sp, arg} for
//!                SPWN, +32 the child's timer-SQE address so the exit
//!                runtime can stop a dead child's clock)
//!   timers       one black-hole PTT slot per user; the `after N`
//!                period becomes the fabric's send_timeout (per-send
//!                timeouts are still an open spec item, §10)
//!
//! The outcome reports every context by name — spawned children as
//! `parent/Actor#k` — with state, fault, and `var` values read back.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");
const joe = @import("joe.zig");

pub const Options = struct {
    seed: u64 = 0x6564,
    loss_ppm4k: u16 = 1024,
    dup_ppm4k: u16 = 128,
    base_latency: u64 = 200,
    jitter: u64 = 120,
    max_cycles: u64 = 50_000_000,
    trace: bool = false,
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
    ref_slots: [8]u16 = @splat(0),
    timer_ptt: u16 = 0,
    /// Set for spawned children: index of the spawning instance.
    parent: ?usize = null,
    rec_off: u16 = 0,
    watchdog: u64 = 0,
};

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

    // ── Place the declared instances: explicit `on N` wins; the rest
    //    fill fresh cores. ──
    var all = std.ArrayList(Placed).init(scratch);
    var next_core: u16 = 0;
    var ctx_count = std.AutoHashMap(u16, u8).init(scratch);
    for (pl.instances) |inst| {
        if (inst.args.len > 8) return fail("more than 8 instance args", .{});
        const core = inst.core orelse blk: {
            while (ctx_count.contains(next_core)) next_core += 1;
            break :blk next_core;
        };
        const n = ctx_count.get(core) orelse 0;
        try ctx_count.put(core, n + 1);
        try all.append(.{
            .name = inst.name,
            .actor = inst.actor,
            .args = inst.args,
            .core = core,
            .ctx = n,
        });
    }
    var cores: u16 = 0;
    {
        var it = ctx_count.iterator();
        while (it.next()) |e| cores = @max(cores, e.key_ptr.* + 1);
    }

    // ── PTT slots: capability refs first, in instance order. ──
    var ptt_next = try scratch.alloc(u16, cores);
    @memset(ptt_next, 0);
    for (all.items) |*p| {
        for (p.args, 0..) |a, k| {
            if (a == .ref) {
                p.ref_slots[k] = ptt_next[p.core];
                ptt_next[p.core] += 1;
            }
        }
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
            .timer_ptt = ptt_next[pc.core], // consumed below iff used
        }, &diag) catch |err| {
            std.debug.print("joe {s}: line {d}: {s}\n", .{ pc.actor, diag.line, diag.message });
            return err;
        };
        errdefer r.deinit();
        if (r.uses_timer) {
            all.items[i].timer_ptt = ptt_next[pc.core];
            ptt_next[pc.core] += 1;
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
    });
    defer m.deinit();

    // ── Wire capabilities and black holes (rings are self-staged). ──
    for (all.items, compiled.items) |*p, *c| {
        for (p.args, 0..) |a, k| {
            if (a != .ref) continue;
            if (!c.r.params[k].addr)
                return fail("{s}: arg {d} names an instance but the param is not addr", .{ p.name, k });
            const target = for (all.items) |*t| {
                if (t.parent == null and std.mem.eql(u8, t.name, a.ref)) break t;
            } else return fail("{s}: no instance named {s}", .{ p.name, a.ref });
            m.setPtt(p.core, p.ref_slots[k], .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(target.core, target.ctx, ring.slot_rx),
                .rights = .{ .send = true },
                .token = joe.abi.token,
            });
        }
        if (c.r.uses_timer) {
            m.setPtt(p.core, p.timer_ptt, .{
                .prefix_lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx),
                .rights = .{ .send = true },
                .token = 0,
            });
        }
    }

    // ── Load code, stage params and supervision. ──
    for (all.items, compiled.items) |*p, *c| {
        m.load(p.core, c.out.origin, c.out.code);
        const near = &m.cores[p.core].contexts[p.ctx].near;
        for (p.args, c.r.params, 0..) |a, prm, k| {
            const value: u64 = switch (a) {
                .int => |v| v,
                .ref => ring.windowAddr(p.ref_slots[k], 0),
            };
            std.mem.writeInt(u64, near[prm.off..][0..8], value, .little);
        }
        if (p.parent) |pi| {
            const parent = all.items[pi];
            const layout = joe.Layout{ .origin = blockOf(p.ctx), .data = blockOf(p.ctx) + joe.abi.data_off };
            const pnear = &m.cores[parent.core].contexts[parent.ctx].near;
            const rec = [_]u64{ p.ctx, blockOf(p.ctx), blockOf(p.ctx) + joe.abi.block_size, 0, layout.timerBase() };
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
    return .{
        .alloc = alloc,
        .reason = reason,
        .instances = try insts.toOwnedSlice(),
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
    var parked: usize = 0;
    var running: usize = 0;
    for (o.instances) |inst| {
        switch (inst.state) {
            .parked => parked += 1,
            .ready => running += 1,
            else => {},
        }
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
    for (o.instances) |inst| {
        try stdout.print("  {s} = {s} @ core {d}.{d}: {s}", .{
            inst.name, inst.actor, inst.core, inst.ctx, @tagName(inst.state),
        });
        if (inst.state == .faulted)
            try stdout.print(" ({s})", .{@tagName(inst.fault)});
        try stdout.print(" [{d} B]", .{inst.code_bytes});
        for (inst.vars) |v| try stdout.print("  {s}={d}", .{ v.name, v.value });
        try stdout.print("\n", .{});
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
