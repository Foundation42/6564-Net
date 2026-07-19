//! The .asm loader: runs any hand-written program whose source carries
//! its harness contract as directives (src/asm.zig's contract section)
//! and a `.system` block in joe's deployment grammar — the same planner,
//! the same report, one dialect for the whole machine.
//!
//! What each demo_*.zig harness once did by hand is mechanical once the
//! contract is data:
//!
//!   placement    `on N` wins; singletons take fresh cores; replicas pack
//!                fresh cores under the context budget. Code loads once
//!                per (core, program) — one code page, N actors, the way
//!                the hand-written ring always ran.
//!   wiring       `cap = N` pins a PTT slot exactly where the code baked
//!                its window constants; `cap @ addr` lets the loader pick
//!                a slot (deduplicated per core and target) and stage the
//!                window pointer where the contract says the code looks
//!                for it. `.timer` is the black hole (spec §6.3).
//!   staging      `.ring` descriptors, posted landing entries with
//!                cookie = buffer address, `.stage` cells, params into
//!                near or RAM, the spawn argument into A.
//!   readback     `.var` cells become named values in the shared Outcome;
//!                spawn order is reverse declaration, same as joe: the
//!                openers are declared first and move last.
//!
//! Nothing here invents policy: every rule is a demo harness's behavior,
//! transcribed once instead of fourteen times.

const std = @import("std");
const ring = @import("ring.zig");
const machine = @import("machine.zig");
const asm6564 = @import("asm.zig");
const dev = @import("dev.zig");
const joe = @import("joe.zig");
const joe_run = @import("joe_run.zig");

pub const Options = joe_run.Options;
pub const Outcome = joe_run.Outcome;

/// One assembly source: `name` is how `.use` and diagnostics refer to it.
pub const Source = struct { name: []const u8, text: []const u8 };

const token: u64 = 0x6564;
const max_ctx_per_core: u8 = 200;
const stack_bytes: u64 = 256;

/// The peripheral row (spec §7), by the names a system block may use.
/// The token is the capability token a client's PTT entry carries — the
/// RTC answers to token 0 (it keeps no secrets), everything else to the
/// machine's.
const device_table = [_]struct { name: []const u8, coord: u16, token: u64 }{
    .{ .name = "Console", .coord = 0xFF00, .token = token },
    .{ .name = "Entropy", .coord = 0xFF01, .token = token },
    .{ .name = "Rtc", .coord = 0xFF02, .token = 0 },
    .{ .name = "Block", .coord = 0xFF03, .token = token },
    .{ .name = "Net", .coord = 0xFF04, .token = token },
    .{ .name = "Matmul", .coord = 0xFF05, .token = token },
    .{ .name = "MatmulRemote", .coord = 0xFF06, .token = token },
};

fn fail(comptime fmt: []const u8, args: anytype) error{Deploy} {
    std.debug.print("asm run: " ++ fmt ++ "\n", args);
    return error.Deploy;
}

/// Assemble just enough of a lead source to learn its `.use` list — the
/// CLI reads those files (relative to the lead) and hands everything to
/// simulate(). Caller owns the returned names.
pub fn usesOf(alloc: std.mem.Allocator, text: []const u8) ![][]u8 {
    var diag = asm6564.Diagnostic{};
    var out = asm6564.assemble(alloc, text, &diag) catch |err| {
        std.debug.print("asm run: line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    defer out.deinit();
    const names = try alloc.alloc([]u8, out.meta.uses.len);
    for (out.meta.uses, 0..) |u, i| names[i] = try alloc.dupe(u8, u);
    return names;
}

const Actor = struct {
    name: []const u8,
    out: asm6564.Output,
    src: []const u8,
};

const Placed = struct {
    name: []const u8,
    ai: usize,
    args: []const joe.InstanceDecl.Arg,
    core: u16,
    ctx: u8,
    gi: usize = 0,
    gn: usize = 1,
    /// Storage the layout pass allocates: ring bases and landing-cell
    /// bases parallel to the actor's meta.rings, and the stack top.
    ring_bases: []u64 = &.{},
    cell_bases: []u64 = &.{},
    sp: u64 = 0,
};

const Group = struct { first: usize, count: usize };

fn entrySize(kind: anytype) u16 {
    return switch (kind) {
        .sq => ring.sq_entry_size,
        .cq => ring.cq_entry_size,
        .rx => ring.rx_entry_size,
    };
}

/// N ring nodes on one core, the fuse lit at n0 — the classic harness's
/// parametric shape as system text. Caller owns the result.
pub fn ringSystem(alloc: std.mem.Allocator, nodes: usize, laps: u64) ![]u8 {
    var text = std.ArrayList(u8).init(alloc);
    errdefer text.deinit();
    try text.writer().print("n0 = RingNode(n1, {d}) on 0\n", .{laps * @as(u64, @intCast(nodes))});
    for (1..nodes) |i| {
        try text.writer().print("n{d} = RingNode(n{d}, 0) on 0\n", .{ i, (i + 1) % nodes });
    }
    return text.toOwnedSlice();
}

/// One sink, N flood senders — the fan-in stress shape as system text.
pub fn floodSystem(alloc: std.mem.Allocator, senders: u64) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\sink = FanInSink({d})
        \\senders = FloodSender[{d}](sink, index)
        \\
    , .{ senders, senders });
}

/// source → N transform stages → sink, one core per node.
pub fn pipelineSystem(alloc: std.mem.Allocator, items: u64, stages: u16) ![]u8 {
    var text = std.ArrayList(u8).init(alloc);
    errdefer text.deinit();
    const w = text.writer();
    if (stages == 0) {
        try w.print("source = Source(sink, {d}) on 0\n", .{items});
        try w.print("sink = Sink(source, {d}, 0) on 1\n", .{items});
    } else {
        try w.print("source = Source(s1, {d}) on 0\n", .{items});
        for (1..@as(usize, stages) + 1) |i| {
            if (i == stages) {
                try w.print("s{d} = Stage(sink, ", .{i});
            } else {
                try w.print("s{d} = Stage(s{d}, ", .{ i, i + 1 });
            }
            if (i == 1) {
                try w.print("source, {d}) on {d}\n", .{ items, i });
            } else {
                try w.print("s{d}, {d}) on {d}\n", .{ i - 1, items, i });
            }
        }
        try w.print("sink = Sink(s{d}, {d}, {d}) on {d}\n", .{
            stages, items, stages, @as(usize, stages) + 1,
        });
    }
    return text.toOwnedSlice();
}

pub fn simulate(alloc: std.mem.Allocator, sources: []const Source, opts: Options) !Outcome {
    return simulateSystem(alloc, sources, null, opts);
}

/// Like simulate(), but `override` (joe system-block grammar, braces not
/// included) replaces the lead source's .system block — how tests and
/// parametric CLI verbs run one program at many shapes: the contract
/// stays in the file, the deployment is the caller's data.
pub fn simulateSystem(
    alloc: std.mem.Allocator,
    sources: []const Source,
    override: ?[]const u8,
    opts: Options,
) !Outcome {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    // ── Assemble everything; the .actor names are the system's cast. ──
    var actors = std.ArrayList(Actor).init(scratch);
    defer for (actors.items) |*a| a.out.deinit();
    for (sources) |s| {
        var diag = asm6564.Diagnostic{};
        var out = asm6564.assemble(alloc, s.text, &diag) catch |err| {
            std.debug.print("asm run {s}: line {d}: {s}\n", .{ s.name, diag.line, diag.message });
            return err;
        };
        errdefer out.deinit();
        const aname = out.meta.actor orelse
            return fail("{s}: no .actor directive — this source has no contract", .{s.name});
        for (actors.items) |a| {
            if (std.mem.eql(u8, a.name, aname))
                return fail("{s}: actor {s} is declared twice", .{ s.name, aname });
        }
        try actors.append(.{ .name = aname, .out = out, .src = s.name });
    }
    if (actors.items.len == 0) return fail("no sources", .{});

    // ── The deployment: the lead source's .system block, read by joe's
    //    planner — one grammar for the whole machine. ──
    const sys_text = override orelse actors.items[0].out.meta.system orelse
        return fail("{s}: no .system block to run", .{actors.items[0].src});
    const wrapped = try std.fmt.allocPrint(scratch, "system {{\n{s}}}\n", .{sys_text});
    var diag = joe.Diagnostic{};
    var pl = joe.plan(alloc, wrapped, &diag) catch |err| {
        std.debug.print("asm run {s}: .system line {d}: {s}\n", .{
            actors.items[0].src, diag.line, diag.message,
        });
        return err;
    };
    defer pl.deinit();
    if (pl.instances.len == 0)
        return fail("the .system block declares nothing to run", .{});

    // ── Sort instances into devices and placements. ──
    var devices = std.ArrayList(struct { name: []const u8, coord: u16, token: u64 }).init(scratch);
    var all = std.ArrayList(Placed).init(scratch);
    var groups = std.StringHashMap(Group).init(scratch);
    var ctx_count = std.AutoHashMap(u16, u8).init(scratch);
    var core_owner = std.AutoHashMap(u16, usize).init(scratch);
    var next_core: u16 = 0;
    for (pl.instances, 0..) |*inst, decl_i| {
        const dentry = for (device_table) |d| {
            if (std.mem.eql(u8, d.name, inst.actor)) break d;
        } else null;
        if (dentry) |d| {
            if (inst.args.len != 0 or inst.replicas != 1)
                return fail("{s}: a device takes no arguments and no replicas", .{inst.name});
            try devices.append(.{ .name = inst.name, .coord = d.coord, .token = d.token });
            continue;
        }
        const ai = for (actors.items, 0..) |a, i| {
            if (std.mem.eql(u8, a.name, inst.actor)) break i;
        } else return fail("{s}: no actor named {s} (missing .use?)", .{ inst.name, inst.actor });
        const n: usize = @intCast(inst.replicas);
        if (n > 1) try groups.put(inst.name, .{ .first = all.items.len, .count = n });
        for (0..n) |ri| {
            const core: u16 = inst.core orelse blk: {
                while (true) {
                    const used = ctx_count.get(next_core) orelse 0;
                    const owner = core_owner.get(next_core);
                    const mine = owner == null or owner.? == decl_i;
                    const fits = if (n > 1)
                        mine and used < max_ctx_per_core
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
            try all.append(.{
                .name = if (n > 1)
                    try std.fmt.allocPrint(scratch, "{s}[{d}]", .{ inst.name, ri })
                else
                    inst.name,
                .ai = ai,
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
    var max_ctx: u8 = 1;
    {
        var it = ctx_count.iterator();
        while (it.next()) |e| {
            cores = @max(cores, e.key_ptr.* + 1);
            max_ctx = @max(max_ctx, e.value_ptr.*);
        }
    }
    for (all.items) |*p| {
        const meta = &actors.items[p.ai].out.meta;
        if (p.args.len != meta.params.len)
            return fail("{s}: {d} args for {d} params", .{ p.name, p.args.len, meta.params.len });
    }

    // ── Layout: everything the contract pins is reserved; everything it
    //    leaves open (ring storage, landing cells, stacks) is allocated
    //    above the highest pinned address, per core, in declaration
    //    order. Addresses never change cycle counts — only collisions
    //    would, and those are errors. ──
    const bump = try scratch.alloc(u64, cores);
    @memset(bump, machine.ram_base);
    const reserve = struct {
        fn f(b: []u64, core: u16, lo: u64, len: u64) void {
            b[core] = @max(b[core], lo + len);
        }
    }.f;
    var loaded = std.AutoHashMap(u64, void).init(scratch); // (core<<32)|ai
    for (all.items) |*p| {
        const a = &actors.items[p.ai];
        const meta = &a.out.meta;
        reserve(bump, p.core, a.out.origin, a.out.code.len);
        for (meta.rings) |r| {
            if (r.base) |b| {
                if (p.gn > 1)
                    return fail("{s}: a replicated actor cannot pin ring storage", .{p.name});
                reserve(bump, p.core, b, @as(u64, @as(u32, 1) << @intCast(r.cap_log2)) * entrySize(r.kind));
            }
        }
        for (meta.stages) |s| {
            if (s.addr >= machine.ram_base)
                reserve(bump, p.core, s.addr, 8 * @as(u64, s.values.len));
        }
        for (meta.reserves) |r| {
            if (r.addr >= machine.ram_base)
                reserve(bump, p.core, r.addr, r.len);
        }
        for (meta.params) |prm| {
            if (prm.where == .cell and prm.where.cell >= machine.ram_base)
                reserve(bump, p.core, prm.where.cell, if (prm.group) 8 * 64 else 8);
        }
    }
    for (bump) |*b| b.* = std.mem.alignForward(u64, b.*, 64);
    for (all.items) |*p| {
        const meta = &actors.items[p.ai].out.meta;
        const bases = try scratch.alloc(u64, meta.rings.len);
        const cells = try scratch.alloc(u64, meta.rings.len);
        for (meta.rings, 0..) |r, i| {
            const cap: u64 = @as(u64, @as(u32, 1) << @intCast(r.cap_log2));
            if (r.base) |b| {
                bases[i] = b;
            } else {
                bases[i] = bump[p.core];
                bump[p.core] = std.mem.alignForward(u64, bump[p.core] + cap * entrySize(r.kind), 64);
            }
            if (r.post > 0) {
                cells[i] = bump[p.core];
                bump[p.core] = std.mem.alignForward(u64, bump[p.core] + @as(u64, r.post) * r.size, 64);
            } else cells[i] = 0;
        }
        p.ring_bases = bases;
        p.cell_bases = cells;
        p.sp = bump[p.core] + stack_bytes;
        bump[p.core] = std.mem.alignForward(u64, p.sp, 64);
    }
    var ram_top: u64 = machine.ram_base + 0x1000;
    for (bump) |b| ram_top = @max(ram_top, b);

    // ── Timers: one period per system, like joe (open item, §10). ──
    var timer_period: u64 = 0;
    for (all.items) |*p| {
        if (actors.items[p.ai].out.meta.timer) |t| {
            if (timer_period != 0 and timer_period != t.period)
                return fail("two different timer periods in one system (open spec item, §10)", .{});
            timer_period = t.period;
        }
    }

    // ── The machine. ──
    var m = try machine.Machine.init(alloc, .{
        .cores = cores,
        .contexts_per_core = max_ctx,
        .ram_size = std.math.ceilPowerOfTwoAssert(usize, @intCast(ram_top)),
        .seed = opts.seed,
        .link = .{
            .base_latency = opts.base_latency,
            .jitter = opts.jitter,
            .loss_ppm4k = opts.loss_ppm4k,
            .dup_ppm4k = opts.dup_ppm4k,
            // The mesh default, not joe's 2500: the hand-written corpus
            // measured its canon numbers against this horizon.
            .send_timeout = if (timer_period != 0) timer_period else 2000,
        },
        .max_cycles = opts.max_cycles,
        .trace = opts.trace,
        .scorch_parks = opts.scorch,
        .contended_lstn = opts.contended_lstn,
    });
    defer m.deinit();

    for (devices.items) |*d| {
        switch (d.coord) {
            0xFF00 => try m.attachDevice(d.coord, token, .{ .console = dev.Console.init(alloc) }),
            0xFF01 => try m.attachDevice(d.coord, token, .{ .entropy = dev.Entropy.init(opts.seed ^ 0xE47) }),
            0xFF02 => try m.attachDevice(d.coord, 0, .{ .rtc = .{} }),
            0xFF03 => try m.attachDevice(d.coord, token, .{ .block = try dev.Block.init(alloc, 8, 64) }),
            0xFF04 => try m.attachDevice(d.coord, token, .{ .net = dev.Net.init(alloc) }),
            0xFF05 => try m.attachAccel(d.coord, token, .inproc),
            0xFF06 => try m.attachAccel(d.coord, token, .remote),
            else => unreachable,
        }
    }

    // ── Capability slots: pinned ones go exactly where the contract says
    //    (the code baked the window constants); free ones allocate above
    //    every pin on that core, deduplicated per (core, target). ──
    const ptt_floor = try scratch.alloc(u16, cores);
    @memset(ptt_floor, 0);
    for (all.items) |*p| {
        const meta = &actors.items[p.ai].out.meta;
        for (meta.params) |prm| {
            if (prm.where == .slot)
                ptt_floor[p.core] = @max(ptt_floor[p.core], prm.where.slot + 1);
        }
        if (meta.timer) |t| {
            if (t.slot) |s| ptt_floor[p.core] = @max(ptt_floor[p.core], s + 1);
        }
    }
    const ptt_next = try scratch.alloc(u16, cores);
    @memcpy(ptt_next, ptt_floor);
    const PttKey = struct { core: u16, lo: u64 };
    var ptt_map = std.AutoHashMap(PttKey, u16).init(scratch);
    const pttFor = struct {
        fn of(
            mach: *machine.Machine,
            map: *std.AutoHashMap(PttKey, u16),
            nexts: []u16,
            core: u16,
            lo: u64,
            tok: u64,
        ) !u16 {
            const key = PttKey{ .core = core, .lo = lo };
            if (map.get(key)) |s| return s;
            if (nexts[core] >= 255)
                return fail("core {d} is out of capability slots", .{core});
            const slot = nexts[core];
            nexts[core] += 1;
            mach.setPtt(core, slot, .{
                .prefix_hi = 0xfd65_6400_0000_0000,
                .prefix_lo = lo,
                .rights = .{ .send = true },
                .token = tok,
            });
            try map.put(key, slot);
            return slot;
        }
    }.of;

    // A capability target is an instance's RX ring: `rx=N` names one,
    // otherwise the first declared. An actor targeted on two rings (a
    // pipeline stage: items one way, acks the other) needs its callers
    // to say which.
    const rxSlotOf = struct {
        fn f(meta: *const asm6564.Meta, want: ?u8) ?u8 {
            if (want) |w| {
                for (meta.rings) |r| {
                    if (r.kind == .rx and r.slot == w) return w;
                }
                return null;
            }
            for (meta.rings) |r| {
                if (r.kind == .rx) return r.slot;
            }
            return null;
        }
    }.f;
    // The spawn-argument value an instance's `arg @ A` param carries.
    const argA = struct {
        fn f(t: *const Placed, params: []const asm6564.MetaParam) u64 {
            for (t.args, params) |ia, prm| {
                if (prm.kind == .arg and prm.where == .reg_a) {
                    return switch (ia) {
                        .int => |v| v,
                        .index => @intCast(t.gi),
                        .ref => 0,
                    };
                }
            }
            return 0;
        }
    }.f;

    const writeCell = struct {
        fn f(mach: *machine.Machine, p: *const Placed, addr: u64, v: u64) void {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .little);
            if (addr < 0x1000) {
                mach.writeNear(p.core, p.ctx, @intCast(addr), &b);
            } else {
                mach.load(p.core, addr, &b);
            }
        }
    }.f;

    // ── Stage, instance by instance. ──
    // A replying device is claimed by one instance: its reply window can
    // only aim at one RX ring.
    var reply_claim = std.AutoHashMap(u16, []const u8).init(scratch);
    for (all.items) |*p| {
        const a = &actors.items[p.ai];
        const meta = &a.out.meta;
        const lkey = (@as(u64, p.core) << 32) | @as(u64, @intCast(p.ai));
        if (!loaded.contains(lkey)) {
            m.load(p.core, a.out.origin, a.out.code);
            try loaded.put(lkey, {});
        }

        // Rings and their landing entries.
        var companion: ?u8 = null;
        for (meta.rings) |r| {
            if (r.kind == .cq) companion = r.slot;
        }
        for (meta.rings, p.ring_bases, p.cell_bases) |r, base, cell_base| {
            m.setRing(p.core, p.ctx, r.slot, .{
                .base = base,
                .cap_log2 = @intCast(r.cap_log2),
                .entry_size = entrySize(r.kind),
                .watermark = 0,
                .companion_cq = companion orelse r.slot,
                .flags = if (r.auto_repost) ring.desc_flag_auto_repost else 0,
                .head = 0,
                .tail = if (r.grant) r.post else 0,
                .token = if (r.kind == .rx) token else 0,
            });
            if (r.post > 0) {
                if (r.kind != .rx)
                    return fail("{s}: only rx rings post landing entries", .{p.name});
                for (0..r.post) |k| {
                    const cell = cell_base + @as(u64, @intCast(k)) * r.size;
                    const entry = ring.RxEntry{ .buf = cell, .cap = r.size, .filled = 0, .cookie = cell };
                    var entry_bytes: [32]u8 = undefined;
                    for (entry.pack(), 0..) |word, wi|
                        std.mem.writeInt(u64, entry_bytes[wi * 8 ..][0..8], word, .little);
                    m.load(p.core, base + 32 * @as(u64, @intCast(k)), &entry_bytes);
                }
            }
        }

        // Params.
        for (p.args, meta.params) |arg, prm| {
            switch (prm.kind) {
                .cap => {
                    const rname = switch (arg) {
                        .ref => |r| r,
                        else => return fail("{s}: param {s} wants a capability, got a number", .{ p.name, prm.name }),
                    };
                    // A device?
                    const ddev = for (devices.items) |*d| {
                        if (std.mem.eql(u8, d.name, rname)) break d;
                    } else null;
                    if (prm.group) {
                        // cap[]: a group's windows, aligned like joe
                        // groups — a singleton takes them all, a larger
                        // member group slices over the replicas, a
                        // smaller one is shared.
                        if (ddev != null)
                            return fail("{s}: {s} is a device, not a group", .{ p.name, rname });
                        const g = groups.get(rname) orelse
                            return fail("{s}: no group named {s}", .{ p.name, rname });
                        const cell0 = prm.where.cell;
                        if (p.gn > 1 and cell0 >= machine.ram_base)
                            return fail("{s}: replicas keep cap[] cells in the near page", .{p.name});
                        var first = g.first;
                        var count = g.count;
                        if (p.gn > 1) {
                            if (g.count >= p.gn) {
                                if (g.count % p.gn != 0)
                                    return fail("{s}: {d} members of {s} do not divide over {d} replicas", .{ p.name, g.count, rname, p.gn });
                                count = g.count / p.gn;
                                first = g.first + p.gi * count;
                            } else {
                                if (p.gn % g.count != 0)
                                    return fail("{s}: {d} replicas do not divide over {d} members of {s}", .{ p.name, p.gn, g.count, rname });
                                count = 1;
                                first = g.first + (p.gi * g.count) / p.gn;
                            }
                        }
                        for (0..count) |j| {
                            const t = &all.items[first + j];
                            const rx = rxSlotOf(&actors.items[t.ai].out.meta, prm.rx) orelse
                                return fail("{s}: {s} declares no matching rx ring", .{ p.name, t.name });
                            const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, ring.PttEntry.loFrom(t.core, t.ctx, rx), token);
                            writeCell(&m, p, cell0 + 8 * @as(u64, @intCast(j)), ring.windowAddr(slot, 0));
                        }
                        continue;
                    }
                    const cap_token: u64 = if (ddev) |d| d.token else token;
                    const lo = if (ddev) |d|
                        ring.PttEntry.loFrom(d.coord, 0, 0)
                    else blk: {
                        const t = for (all.items) |*t2| {
                            if (t2.gn == 1 and std.mem.eql(u8, t2.name, rname)) break t2;
                        } else return fail("{s}: no instance named {s}", .{ p.name, rname });
                        const rx = rxSlotOf(&actors.items[t.ai].out.meta, prm.rx) orelse
                            return fail("{s}: {s} declares no matching rx ring", .{ p.name, rname });
                        break :blk ring.PttEntry.loFrom(t.core, t.ctx, rx);
                    };
                    switch (prm.where) {
                        // Grant only: the code builds addresses itself.
                        .none => _ = try pttFor(&m, &ptt_map, ptt_next, p.core, lo, cap_token),
                        .slot => |s| m.setPtt(p.core, s, .{
                            .prefix_hi = 0xfd65_6400_0000_0000,
                            .prefix_lo = lo,
                            .rights = .{ .send = true },
                            .token = cap_token,
                        }),
                        .cell => |cell| {
                            const slot = try pttFor(&m, &ptt_map, ptt_next, p.core, lo, cap_token);
                            if (cell >= machine.ram_base and p.gn > 1)
                                return fail("{s}: replicas cannot share a RAM capability cell", .{p.name});
                            writeCell(&m, p, cell, ring.windowAddr(slot, 0));
                        },
                        .reg_a => unreachable,
                    }
                    if (prm.reply) {
                        // The reply window: the device's own capability
                        // aimed back at our RX ring — the loader wiring
                        // driver to device, same act as wiring two actors.
                        const d = ddev orelse
                            return fail("{s}: `reply` wires a device; {s} replies through its own caps", .{ p.name, rname });
                        const my_rx = rxSlotOf(meta, null) orelse
                            return fail("{s}: takes a reply but declares no rx ring", .{p.name});
                        const gop = try reply_claim.getOrPut(d.coord);
                        if (gop.found_existing)
                            return fail("{s}: device {s} already replies to {s}", .{ p.name, rname, gop.value_ptr.* });
                        gop.value_ptr.* = p.name;
                        m.setDevicePtt(d.coord, 0, .{
                            .prefix_hi = 0xfd65_6400_0000_0000,
                            .prefix_lo = ring.PttEntry.loFrom(p.core, p.ctx, my_rx),
                            .rights = .{ .send = true },
                            .token = token,
                        });
                    }
                },
                .arg => {
                    const v: u64 = switch (arg) {
                        .int => |v| v,
                        .index => @intCast(p.gi),
                        .ref => return fail("{s}: param {s} wants a number, got a capability", .{ p.name, prm.name }),
                    };
                    switch (prm.where) {
                        // `arg @ A` rides the spawn call, staged nowhere.
                        .reg_a => {},
                        .cell => |cell| {
                            if (cell >= machine.ram_base and p.gn > 1)
                                return fail("{s}: replicas cannot share a RAM argument cell", .{p.name});
                            writeCell(&m, p, cell, v);
                        },
                        .slot, .none => unreachable,
                    }
                },
                .sup => {
                    // Supervision (spec §5.4): the child's spawn block
                    // lands where the contract says, its exit link aims
                    // at our CQ, and its leash is ours to set.
                    const rname = switch (arg) {
                        .ref => |r| r,
                        else => return fail("{s}: param {s} supervises an instance, got a number", .{ p.name, prm.name }),
                    };
                    const t = for (all.items) |*t2| {
                        if (t2.gn == 1 and std.mem.eql(u8, t2.name, rname)) break t2;
                    } else return fail("{s}: no instance named {s}", .{ p.name, rname });
                    if (t.core != p.core)
                        return fail("{s}: supervision is core-local; {s} lives on core {d}", .{ p.name, rname, t.core });
                    const tmeta = &actors.items[t.ai].out.meta;
                    const cell = prm.where.cell;
                    const words = [4]u64{
                        t.ctx,
                        actors.items[t.ai].out.origin,
                        t.sp,
                        argA(t, tmeta.params),
                    };
                    for (words, 0..) |w, j|
                        writeCell(&m, p, cell + 8 * @as(u64, @intCast(j)), w);
                    const cq = companion orelse
                        return fail("{s}: supervises but declares no cq ring", .{p.name});
                    m.linkSupervisor(p.core, t.ctx, p.ctx, cq);
                    if (prm.watchdog != 0)
                        m.setWatchdog(p.core, t.ctx, prm.watchdog);
                },
            }
        }

        // The black hole (spec §6.3): a send that can only time out.
        if (meta.timer) |t| {
            const lo = ring.PttEntry.loFrom(0xFFFF, 0, ring.slot_rx);
            if (t.slot) |s| {
                m.setPtt(p.core, s, .{
                    .prefix_lo = lo,
                    .rights = .{ .send = true },
                    .token = 0,
                });
            } else if (t.cell) |cell| {
                const key = PttKey{ .core = p.core, .lo = lo };
                const slot = ptt_map.get(key) orelse blk: {
                    if (ptt_next[p.core] >= 255)
                        return fail("core {d} is out of capability slots", .{p.core});
                    const s = ptt_next[p.core];
                    ptt_next[p.core] += 1;
                    m.setPtt(p.core, s, .{
                        .prefix_lo = lo,
                        .rights = .{ .send = true },
                        .token = 0,
                    });
                    try ptt_map.put(key, s);
                    break :blk s;
                };
                writeCell(&m, p, cell, ring.windowAddr(slot, 0));
            }
        }

        // Staged cells.
        for (meta.stages) |s| {
            for (s.values, 0..) |v, j|
                writeCell(&m, p, s.addr + 8 * @as(u64, @intCast(j)), v);
        }
    }

    // ── Spawn in reverse declaration order: servers declared later are
    //    listening before openers move (the corpus's structural lesson). ──
    var s = all.items.len;
    while (s > 0) {
        s -= 1;
        const p = &all.items[s];
        const meta = &actors.items[p.ai].out.meta;
        try m.spawn(p.core, p.ctx, actors.items[p.ai].out.origin, p.sp, argA(p, meta.params));
    }

    const reason = try m.run();

    // ── Read the system back, joe's way. ──
    var insts = std.ArrayList(joe_run.InstanceOut).init(alloc);
    errdefer insts.deinit();
    var max_clock: u64 = 0;
    for (m.cores) |*core| max_clock = @max(max_clock, core.clock);
    for (all.items) |*p| {
        const a = &actors.items[p.ai];
        const ctx = &m.cores[p.core].contexts[p.ctx];
        var vars = std.ArrayList(joe_run.VarOut).init(alloc);
        for (a.out.meta.vars) |v| {
            const value = if (v.addr < 0x1000)
                std.mem.readInt(u64, ctx.near[@intCast(v.addr)..][0..8], .little)
            else
                std.mem.readInt(u64, m.cores[p.core].ram[@intCast(v.addr - machine.ram_base)..][0..8], .little);
            try vars.append(.{ .name = try alloc.dupe(u8, v.name), .value = value });
        }
        try insts.append(.{
            .name = try alloc.dupe(u8, p.name),
            .actor = try alloc.dupe(u8, a.name),
            .core = p.core,
            .ctx = p.ctx,
            .state = ctx.state,
            .fault = ctx.fault,
            .code_bytes = a.out.code.len,
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

pub fn run(alloc: std.mem.Allocator, sources: []const Source, opts: Options) !void {
    var o = try simulate(alloc, sources, opts);
    defer o.deinit();
    try joe_run.report(&o, opts, "asm");
}

pub fn runSystem(alloc: std.mem.Allocator, sources: []const Source, override: ?[]const u8, opts: Options) !void {
    var o = try simulateSystem(alloc, sources, override, opts);
    defer o.deinit();
    try joe_run.report(&o, opts, "asm");
}
