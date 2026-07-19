//! sim6564 — reference simulator for the 6564-Net architecture.
//! See docs/6564-net-architecture-v2.6.md and docs/simulator.md.

pub const isa = @import("isa.zig");
pub const ring = @import("ring.zig");
pub const mesh = @import("mesh.zig");
pub const dev = @import("dev.zig");
pub const machine = @import("machine.zig");
pub const cluster = @import("cluster.zig");
pub const topology = @import("topology.zig");
pub const demo_dies = @import("demo_dies.zig");
pub const demo_churn = @import("demo_churn.zig");
pub const bridge = @import("bridge.zig");
pub const demo_net = @import("demo_net.zig");
pub const demo_web = @import("demo_web.zig");
pub const asm6564 = @import("asm.zig");
pub const joe = @import("joe.zig");
pub const joe_run = @import("joe_run.zig");
pub const asm_run = @import("asm_run.zig");
pub const struple = @import("struple.zig");
pub const demo_forkjoin = @import("demo_forkjoin.zig");
pub const measure = @import("measure.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("integration_tests.zig");
}
