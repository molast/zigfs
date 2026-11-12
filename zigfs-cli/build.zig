const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = true,
    });

    const exe = b.addExecutable(.{
        .name = "zc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = true,
            .imports = &.{.{ .name = "zc", .module = cli_module }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the ZigFS CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = cli_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run CLI tests");
    test_step.dependOn(&run_tests.step);
}
