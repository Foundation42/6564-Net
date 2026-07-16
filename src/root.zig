//! sim6564 — reference simulator for the 6564-Net architecture.
//! See docs/6564-net-architecture-v2.md and docs/simulator.md.

pub const isa = @import("isa.zig");
pub const ring = @import("ring.zig");
pub const mesh = @import("mesh.zig");
pub const machine = @import("machine.zig");
pub const asm6564 = @import("asm.zig");
pub const demo_pingpong = @import("demo_pingpong.zig");
pub const demo_supervise = @import("demo_supervise.zig");
pub const demo_pipeline = @import("demo_pipeline.zig");
pub const demo_scatter = @import("demo_scatter.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("integration_tests.zig");
}
