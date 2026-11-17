const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("metadata_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run standalone unit, repository contract and recovery tests")
        .dependOn(&b.addRunArtifact(tests).step);
    const tool = b.addExecutable(.{
        .name = "metadata-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "metadata_engine", .module = module }},
        }),
    });
    b.installArtifact(tool);
    const probe = b.addExecutable(.{
        .name = "metadata-crash-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/crash_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "metadata_engine", .module = module }},
        }),
    });
    const crashes = b.addSystemCommand(&.{ "python3", "tests/crash.py" });
    crashes.addArtifactArg(probe);
    crashes.addArtifactArg(tool);
    b.step("test-crash", "SIGKILL subprocesses at persistence boundaries and verify recovery")
        .dependOn(&crashes.step);
    const reliability = b.addExecutable(.{
        .name = "metadata-reliability-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/reliability_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "metadata_engine", .module = module }},
        }),
    });
    b.step("reliability-probe", "Build the isolated filesystem reliability probe")
        .dependOn(&b.addInstallArtifact(reliability, .{}).step);
    const memory_profile = b.createModule(.{
        .root_source_file = b.path("bench/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "metadata_engine", .module = module }},
    });
    const mixed = b.addExecutable(.{
        .name = "metadata-mixed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mixed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metadata_engine", .module = module },
                .{ .name = "memory_profile", .module = memory_profile },
            },
        }),
    });
    const mixed_run = b.addSystemCommand(&.{ "python3", "tests/mixed.py" });
    mixed_run.addArtifactArg(mixed);
    mixed_run.addPassthruArgs();
    b.step("mixed-soak", "Run one instance against a reference model and sample RSS")
        .dependOn(&mixed_run.step);
    const mixed_test = b.addSystemCommand(&.{ "python3", "tests/mixed.py" });
    mixed_test.addArtifactArg(mixed);
    mixed_test.addArgs(&.{ "--seconds", "2" });
    b.step("test-mixed", "Short mixed reference-model test")
        .dependOn(&mixed_test.step);
    const bench = b.addExecutable(.{
        .name = "metadata-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "metadata_engine", .module = module }},
        }),
    });
    b.installArtifact(bench);
    const soak = b.addSystemCommand(&.{ "python3", "bench/soak.py" });
    soak.addArtifactArg(bench);
    soak.addPassthruArgs();
    b.step("soak", "Repeat verified workloads and collect child peak RSS").dependOn(&soak.step);
    const run = b.addRunArtifact(bench);
    run.addPassthruArgs();
    b.step("bench", "Run durable QPS and latency benchmark in a new directory")
        .dependOn(&run.step);
}
