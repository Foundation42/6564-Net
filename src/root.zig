//! sim6564 — reference simulator for the 6564-Net architecture.
//! See docs/6564-net-architecture-v2.4.md and docs/simulator.md.

pub const isa = @import("isa.zig");
pub const ring = @import("ring.zig");
pub const mesh = @import("mesh.zig");
pub const dev = @import("dev.zig");
pub const machine = @import("machine.zig");
pub const cluster = @import("cluster.zig");
pub const topology = @import("topology.zig");
pub const demo_dies = @import("demo_dies.zig");
pub const demo_churn = @import("demo_churn.zig");
pub const asm6564 = @import("asm.zig");
pub const demo_pingpong = @import("demo_pingpong.zig");
pub const demo_hello = @import("demo_hello.zig");
pub const demo_periph = @import("demo_periph.zig");
pub const demo_supervise = @import("demo_supervise.zig");
pub const demo_pipeline = @import("demo_pipeline.zig");
pub const demo_scatter = @import("demo_scatter.zig");
pub const demo_ring = @import("demo_ring.zig");
pub const demo_bigbrother = @import("demo_bigbrother.zig");
pub const demo_forkjoin = @import("demo_forkjoin.zig");
pub const measure = @import("measure.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("integration_tests.zig");
}
