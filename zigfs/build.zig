const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = true,
        .strip = false,
        .link_libc = true,
    });

    const build_info = b.addOptions();
    build_info.addOption(i64, "built_at", std.Io.Clock.real.now(b.graph.io).toSeconds());
    const commit = b.option([]const u8, "git-commit", "Source commit for builds without Git metadata") orelse switch (b.runFallible(&.{ "git", "-C", b.root.root_dir.path orelse ".", "rev-parse", "HEAD" }, .{ .stderr_behavior = .ignore })) {
        .success => |output| std.mem.trim(u8, output, " \r\n"),
        else => "",
    };
    build_info.addOption([]const u8, "git_commit", commit);
    mod.addOptions("build_info", build_info);
    mod.addCSourceFile(.{ .file = b.path("src/backend/process_metrics.c"), .flags = &.{"-std=c99"} });

    mod.addCSourceFile(.{ .file = b.path("src/backend/filesystem_capacity.c"), .flags = &.{"-std=c99"} });

    mod.addCSourceFile(.{ .file = b.path("src/backend/kms_http.c"), .flags = &.{"-std=c99"} });
    mod.addCSourceFile(.{ .file = b.path("src/backend/event_webhook.c"), .flags = &.{"-std=c99"} });
    mod.addCSourceFile(.{ .file = b.path("src/backend/event_channel.c"), .flags = &.{"-std=c99"} });
    mod.linkSystemLibrary("curl", .{});

    const exe = b.addExecutable(.{
        .name = "zigfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = true,
            .strip = false,
            .link_libc = true,
            .imports = &.{.{ .name = "zigfs", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zigfs");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const delivery_probe = b.addExecutable(.{
        .name = "event-delivery-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/event_delivery_probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zigfs", .module = mod }},
        }),
    });
    const install_probe = b.addInstallArtifact(delivery_probe, .{});
    b.step("event-delivery-probe", "Build the isolated event delivery conformance runner").dependOn(&install_probe.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit and contract tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
