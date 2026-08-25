const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const simutex = b.addModule("simutex", .{
        .root_source_file = b.path("src/simutex.zig"),
        .target = target,
    });
    simutex.addIncludePath(b.path("src"));
    simutex.addCSourceFile(.{
        .file = b.path("src/core_simulator_bridge.m"),
        .flags = &.{ "-fobjc-arc", "-fblocks" },
    });
    simutex.linkFramework("Foundation", .{});
    simutex.linkSystemLibrary("objc", .{});
    simutex.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "simutex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "simutex", .module = simutex }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run simutex").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = simutex });
    const run_tests = b.addRunArtifact(tests);

    const monitor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/monitor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "simutex", .module = simutex }},
        }),
    });
    const run_monitor_tests = b.addRunArtifact(monitor_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_monitor_tests.step);
}
