//! CPU topology + thread affinity (Linux). Vendored from ~/dev/substr
//! (src/topology.zig) — the one piece of substr that finally earned its
//! passage: the IO plane runs one host thread per die, and on an
//! asymmetric part (Zen X3D: one big-cache CCD, one high-frequency CCD)
//! *where* those threads land is a measurable knob (`sim6564 dies …
//! vcache|freq|spread`).
//!
//! Reads L3-cache sharing from sysfs so callers can pin threads to a specific
//! CCD — on a Zen X3D part, the big-cache (V-cache) die versus the higher-
//! frequency die.
//!
//! Best-effort and non-fatal: `detectTopology` returns null off Linux or when
//! sysfs is unreadable, and `pinToCpu` silently no-ops on failure — so callers
//! can always attempt a pin and simply run unpinned where it isn't available.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_GROUPS = 16;
pub const MAX_CPUS_PER_GROUP = 128;

/// One L3 domain (a CCD on Zen): the cpus that share it and its size.
pub const Group = struct {
    size_kb: u64 = 0,
    cpus: [MAX_CPUS_PER_GROUP]usize = undefined,
    n: usize = 0,
    key: [128]u8 = undefined, // the sysfs shared_cpu_list string (for printing/dedupe)
    keylen: usize = 0,
};

pub const Topology = struct {
    groups: [MAX_GROUPS]Group = undefined,
    ng: usize = 0,

    /// The L3 domain with the most cache — the V-cache CCD on an X3D part.
    pub fn vcacheGroup(self: *const Topology) ?*const Group {
        if (self.ng == 0) return null;
        var best: *const Group = &self.groups[0];
        for (self.groups[0..self.ng]) |*g| if (g.size_kb > best.size_kb) {
            best = g;
        };
        return best;
    }

    /// Fill `out` with the V-cache CCD's cpus; returns the count (0 if none).
    pub fn vcacheCpus(self: *const Topology, out: []usize) usize {
        const g = self.vcacheGroup() orelse return 0;
        const n = @min(g.n, out.len);
        @memcpy(out[0..n], g.cpus[0..n]);
        return n;
    }

    /// Fill `out` with all non-V-cache (frequency) cpus; returns the count.
    pub fn freqCpus(self: *const Topology, out: []usize) usize {
        const vc = self.vcacheGroup();
        var n: usize = 0;
        for (self.groups[0..self.ng]) |*g| {
            if (vc) |v| if (g == v) continue;
            for (g.cpus[0..g.n]) |c| {
                if (n < out.len) {
                    out[n] = c;
                    n += 1;
                }
            }
        }
        return n;
    }
};

fn readSysfs(path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \n\r\t");
}

fn parseSizeKb(s: []const u8) u64 {
    var end: usize = 0;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
    const num = std.fmt.parseInt(u64, s[0..end], 10) catch return 0;
    if (end < s.len) switch (s[end]) {
        'M', 'm' => return num * 1024,
        'G', 'g' => return num * 1024 * 1024,
        else => {},
    };
    return num; // assume K
}

fn parseCpuList(s: []const u8, out: []usize) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \n\r\t");
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = std.fmt.parseInt(usize, part[0..dash], 10) catch continue;
            const b = std.fmt.parseInt(usize, part[dash + 1 ..], 10) catch continue;
            var x = a;
            while (x <= b and n < out.len) : (x += 1) {
                out[n] = x;
                n += 1;
            }
        } else {
            const v = std.fmt.parseInt(usize, part, 10) catch continue;
            if (n < out.len) {
                out[n] = v;
                n += 1;
            }
        }
    }
    return n;
}

/// Detect the L3 domains across `ncpu` logical cpus from sysfs. Null off Linux
/// or when sysfs is unreadable.
pub fn detectTopology(ncpu: usize) ?Topology {
    if (builtin.os.tag != .linux) return null;
    var topo = Topology{};
    var pbuf: [128]u8 = undefined;
    var dbuf: [512]u8 = undefined;
    var cpu: usize = 0;
    while (cpu < ncpu) : (cpu += 1) {
        const lp = std.fmt.bufPrint(&pbuf, "/sys/devices/system/cpu/cpu{d}/cache/index3/shared_cpu_list", .{cpu}) catch continue;
        const list = readSysfs(lp, &dbuf) orelse continue;
        // dedupe groups by their shared_cpu_list string
        var found = false;
        for (topo.groups[0..topo.ng]) |g| {
            if (std.mem.eql(u8, g.key[0..g.keylen], list)) {
                found = true;
                break;
            }
        }
        if (found or topo.ng >= MAX_GROUPS) continue;

        var g = Group{};
        @memcpy(g.key[0..list.len], list);
        g.keylen = list.len;
        g.n = parseCpuList(list, &g.cpus);

        var sbuf: [64]u8 = undefined;
        const sp = std.fmt.bufPrint(&pbuf, "/sys/devices/system/cpu/cpu{d}/cache/index3/size", .{cpu}) catch continue;
        if (readSysfs(sp, &sbuf)) |sz| g.size_kb = parseSizeKb(sz);

        topo.groups[topo.ng] = g;
        topo.ng += 1;
    }
    return if (topo.ng > 0) topo else null;
}

/// Pin the CURRENT thread to `cpu` (Linux). Silently no-ops off Linux or on
/// failure — pinning is an optimization, never a correctness requirement.
pub fn pinToCpu(cpu: usize) void {
    if (builtin.os.tag != .linux) return;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    const bits = @bitSizeOf(usize);
    set[cpu / bits] |= @as(usize, 1) << @intCast(cpu % bits);
    std.os.linux.sched_setaffinity(0, &set) catch {};
}

test "topology: detection and pinning are best-effort and safe" {
    const ncpu = std.Thread.getCpuCount() catch 1;
    if (detectTopology(ncpu)) |topo| {
        try std.testing.expect(topo.ng >= 1);
        try std.testing.expect(topo.vcacheGroup() != null);
        var buf: [MAX_CPUS_PER_GROUP]usize = undefined;
        try std.testing.expect(topo.vcacheCpus(&buf) >= 1);
        // freq cpus is the complement; on a single-CCD box it may be empty.
        _ = topo.freqCpus(&buf);
    }
    pinToCpu(0); // must be safe even when it no-ops
}
