//! The joe loader: runs any .joe file that carries a `system` block.
//! No per-program demo_*.zig harness — the deployment is data in the
//! source, and everything a harness used to do by hand is mechanical
//! once the ABI is fixed:
//!
//!   placement    one instance per core unless `on N` says otherwise;
//!                instances sharing a core become contexts, each in its
//!                own $1000 block (code, rings, buffers, stack)
//!   wiring       an instance name as an argument = a capability: a PTT
//!                slot in the sender's core, aimed at the target's RX
//!                ring — the loader binds it like wiring two actors
//!   staging      params written into the near page; addr params get
//!                the window value of their allocated slot
//!   timers       one black-hole PTT slot per core that needs one; the
//!                `after N` period becomes the fabric's send_timeout
//!                (per-send timeouts are still an open spec item, §10)
//!
//! The outcome reports every instance by name: state, fault if any, and
//! its `var` values read back from the near page.

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
    decl: joe.Plan.PlanInstance,
    core: u16,
    ctx: u8,
    /// PTT slots allocated for this instance's ref args, in arg order.
    ref_slots: [8]u16 = @splat(0),
    timer_ptt: u16 = 0,
};

fn fail(comptime fmt: []const u8, args: anytype) error{Deploy} {
    std.debug.print("joe run: " ++ fmt ++ "\n", args);
    return error.Deploy;
}

pub fn simulate(alloc: std.mem.Allocator, source: []const u8, opts: Options) !Outcome {
    var diag = joe.Diagnostic{};
    var pl = joe.plan(alloc, source, &diag) catch |err| {
        std.debug.print("joe: line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer pl.deinit();
    if (pl.instances.len == 0)
        return fail("this source has no `system` block to run", .{});

    // ── Place: explicit `on N` wins; the rest fill fresh cores. ──
    var placed = try alloc.alloc(Placed, pl.instances.len);
    defer alloc.free(placed);
    var next_core: u16 = 0;
    var ctx_count = std.AutoHashMap(u16, u8).init(alloc);
    defer ctx_count.deinit();
    for (pl.instances, 0..) |inst, i| {
        if (inst.args.len > 8) return fail("more than 8 instance args", .{});
        const core = inst.core orelse blk: {
            while (ctx_count.contains(next_core)) next_core += 1;
            break :blk next_core;
        };
        const n = ctx_count.get(core) orelse 0;
        try ctx_count.put(core, n + 1);
        placed[i] = .{ .decl = inst, .core = core, .ctx = n };
    }
    var cores: u16 = 0;
    var max_ctx: u8 = 1;
    var it = ctx_count.iterator();
    while (it.next()) |e| {
        cores = @max(cores, e.key_ptr.* + 1);
        max_ctx = @max(max_ctx, e.value_ptr.*);
    }

    // ── Allocate PTT slots per core: refs in instance order, then one
    //    black hole per core that hosts a timer. ──
    var ptt_next = try alloc.alloc(u16, cores);
    defer alloc.free(ptt_next);
    @memset(ptt_next, 0);
    for (placed) |*p| {
        for (p.decl.args, 0..) |a, k| {
            if (a == .ref) {
                p.ref_slots[k] = ptt_next[p.core];
                ptt_next[p.core] += 1;
            }
        }
    }

    // ── Compile every instance in its own block. ──
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
    for (placed) |*p| {
        const block = machine.ram_base + @as(u64, p.ctx) * joe.abi.block_size;
        // The timer slot is per-core; allocate lazily on first need.
        var r = joe.compile(alloc, source, p.decl.actor, .{
            .origin = block,
            .data = block + joe.abi.data_off,
            .timer_ptt = ptt_next[p.core], // valid only if the actor uses it
        }, &diag) catch |err| {
            std.debug.print("joe {s}: line {d}: {s}\n", .{ p.decl.actor, diag.line, diag.message });
            return err;
        };
        if (r.uses_timer) {
            p.timer_ptt = ptt_next[p.core];
            ptt_next[p.core] += 1;
            if (timer_period != 0 and timer_period != r.timer_period) {
                r.deinit();
                return fail("two different `after` periods in one system (open spec item, §10)", .{});
            }
            timer_period = r.timer_period;
        }
        if (r.params.len != p.decl.args.len) {
            std.debug.print("joe {s}: {d} args for {d} params\n", .{ p.decl.name, p.decl.args.len, r.params.len });
            r.deinit();
            return error.Deploy;
        }
        var adiag = asm6564.Diagnostic{};
        const out = asm6564.assemble(alloc, r.asm_text, &adiag) catch |err| {
            std.debug.print("joe {s}: asm line {d}: {s}\n", .{ p.decl.actor, adiag.line, adiag.message });
            r.deinit();
            return err;
        };
        try compiled.append(.{ .r = r, .out = out });
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

    // ── Wire: rings for every context, PTT capabilities, black holes. ──
    for (placed, compiled.items) |*p, *c| {
        const layout = joe.Layout{
            .origin = machine.ram_base + @as(u64, p.ctx) * joe.abi.block_size,
            .data = machine.ram_base + @as(u64, p.ctx) * joe.abi.block_size + joe.abi.data_off,
        };
        m.setRing(p.core, p.ctx, ring.slot_sq, .{
            .base = layout.sqBase(),
            .cap_log2 = 0,
            .entry_size = ring.sq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.setRing(p.core, p.ctx, ring.slot_cq, .{
            .base = layout.cqBase(),
            .cap_log2 = 4,
            .entry_size = ring.cq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.setRing(p.core, p.ctx, joe.abi.timer_desc, .{
            .base = layout.timerBase(),
            .cap_log2 = 0,
            .entry_size = ring.sq_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .head = 0,
            .tail = 0,
            .token = 0,
        });
        m.setRing(p.core, p.ctx, ring.slot_rx, .{
            .base = layout.rxBase(),
            .cap_log2 = 1,
            .entry_size = ring.rx_entry_size,
            .watermark = 0,
            .companion_cq = ring.slot_cq,
            .flags = ring.desc_flag_auto_repost,
            .head = 0,
            .tail = 0,
            .token = 0x6564,
        });
        // Capabilities: each ref arg gets its slot aimed at the target.
        for (p.decl.args, 0..) |a, k| {
            if (a != .ref) continue;
            if (!c.r.params[k].addr)
                return fail("{s}: arg {d} names an instance but the param is not addr", .{ p.decl.name, k });
            const target = for (placed) |*t| {
                if (std.mem.eql(u8, t.decl.name, a.ref)) break t;
            } else return fail("{s}: no instance named {s}", .{ p.decl.name, a.ref });
            m.setPtt(p.core, p.ref_slots[k], .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = ring.PttEntry.loFrom(target.core, target.ctx, ring.slot_rx),
                .rights = .{ .send = true },
                .token = 0x6564,
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

    // ── Load, stage, spawn — last declared spawns first, so servers
    //    declared later in the block are listening before openers move.
    for (placed, compiled.items) |*p, *c| {
        m.load(p.core, c.out.origin, c.out.code);
        for (p.decl.args, c.r.params, 0..) |a, prm, k| {
            const value: u64 = switch (a) {
                .int => |v| v,
                .ref => ring.windowAddr(p.ref_slots[k], 0),
            };
            std.mem.writeInt(
                u64,
                m.cores[p.core].contexts[p.ctx].near[prm.off..][0..8],
                value,
                .little,
            );
        }
    }
    var i: usize = placed.len;
    while (i > 0) {
        i -= 1;
        const p = &placed[i];
        const block = machine.ram_base + @as(u64, p.ctx) * joe.abi.block_size;
        try m.spawn(p.core, p.ctx, block, block + joe.abi.block_size, 0);
    }

    const reason = try m.run();

    // ── Read the system back. ──
    var insts = std.ArrayList(InstanceOut).init(alloc);
    errdefer insts.deinit();
    var max_clock: u64 = 0;
    for (m.cores) |*core| max_clock = @max(max_clock, core.clock);
    for (placed, compiled.items) |*p, *c| {
        const ctx = &m.cores[p.core].contexts[p.ctx];
        var vars = std.ArrayList(VarOut).init(alloc);
        for (c.r.vars) |v| {
            try vars.append(.{
                .name = try alloc.dupe(u8, v.name),
                .value = std.mem.readInt(u64, ctx.near[v.off..][0..8], .little),
            });
        }
        try insts.append(.{
            .name = try alloc.dupe(u8, p.decl.name),
            .actor = try alloc.dupe(u8, p.decl.actor),
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
    // Translate the machine's stop reason into system terms: a "deadlock"
    // where every instance is halted or parked serving is quiescence —
    // the system went quiet, which is what finishing looks like when
    // some actors serve forever.
    var halted: usize = 0;
    var parked: usize = 0;
    var faulted: usize = 0;
    for (o.instances) |inst| {
        switch (inst.state) {
            .halted => halted += 1,
            .parked => parked += 1,
            .faulted => faulted += 1,
            else => {},
        }
    }
    const verdict = switch (o.reason) {
        .deadlock => if (faulted == 0 and halted + parked == o.instances.len)
            "quiescent — the work is done, the servers are parked"
        else
            "DEADLOCK: something is stuck",
        .all_halted => "all instances halted",
        .faulted => "an instance FAULTED",
        .max_cycles => "hit max_cycles",
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
    for (o.instances) |inst| {
        if (inst.state == .faulted) std.process.exit(1);
    }
}
