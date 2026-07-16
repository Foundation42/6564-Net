const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module other projects import as `@import("sim6564")`.
    const sim_mod = b.addModule("sim6564", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI simulator: assemble + run programs on a simulated mesh.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("sim6564", sim_mod);
    const exe = b.addExecutable(.{ .name = "sim6564", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the simulator demo");
    run_step.dependOn(&run_cmd.step);

    // Tests live in src/root.zig, which pulls in every module.
    const unit_tests = b.addTest(.{ .root_module = sim_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
