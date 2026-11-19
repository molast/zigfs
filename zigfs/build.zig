const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const diagnostic_allocator = b.option(bool, "diagnostic-allocator", "Use SafeAllocator with allocation traces and write-after-free checks (diagnostic builds only)") orelse false;
    const sanitize_c = b.option(std.zig.SanitizeC, "sanitize-c", "C undefined-behavior checks: off, trap, full; not Zig ASan");
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable compiler TSan instrumentation where supported");
    if (diagnostic_allocator and optimize != .debug and optimize != .safe) {
        std.debug.panic("diagnostic-allocator requires Debug or ReleaseSafe", .{});
    }
    const diagnostic_options = b.addOptions();
    diagnostic_options.addOption(bool, "allocator_enabled", diagnostic_allocator);

    const mod = b.addModule("zigfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
        .sanitize_thread = sanitize_thread,
        .error_tracing = true,
        .strip = false,
        .link_libc = true,
    });

    const test_support = b.createModule(.{
        .root_source_file = b.path("tests/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_support.addImport("zigfs", mod);
    mod.addImport("test_support", test_support);

    // Resources are embedded at compile time; deployed services need no resource directory.
    const policies = [_][]const u8{
        "consoleAdmin", "diagnostics", "KMSAuditor", "KMSKeyAdministrator",
        "KMSKeyUser",   "readonly",    "readwrite",  "writeonly",
    };
    for (policies) |name| {
        mod.addAnonymousImport(b.fmt("builtin_policy_{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("resources/policies/{s}.json", .{name})),
        });
    }
    mod.addAnonymousImport("display_timezones", .{
        .root_source_file = b.path("resources/display_timezones.txt"),
    });

    mod.addImport("metadata_engine", b.dependency("metadata_engine", .{
        .target = target,
        .optimize = optimize,
    }).module("metadata_engine"));

    mod.addCSourceFile(.{ .file = b.path("src/backend/host_metrics.c"), .flags = &.{"-std=c99"} });
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
    if (b.option([]const u8, "curl-root", "Directory containing libcurl include, lib, and bin directories")) |curl_root| {
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ curl_root, "include" }) });
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ curl_root, "lib" }) });
    }
    mod.linkSystemLibrary(if (target.result.os.tag == .windows) "libcurl" else "curl", .{});
    if (target.result.os.tag == .windows) mod.linkSystemLibrary("ws2_32", .{});

    const exe = b.addExecutable(.{
        .name = "zigfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
            .sanitize_thread = sanitize_thread,
            .error_tracing = true,
            .strip = false,
            .link_libc = true,
            .imports = &.{.{ .name = "zigfs", .module = mod }},
        }),
    });
    exe.root_module.addOptions("diagnostic_options", diagnostic_options);
    b.installArtifact(exe);

    // Deliberate faults are separate executables, never unit tests or HTTP routes.
    const memory_probe = b.addExecutable(.{
        .name = "memory-diagnostic-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/memory_diagnostic_probe.zig"),
            .target = target,
            .optimize = .debug,
            .error_tracing = true,
            .strip = false,
        }),
    });
    const install_memory_probe = b.addInstallArtifact(memory_probe, .{});
    b.step("memory-diagnostic-probe", "Build isolated SafeAllocator fault probes").dependOn(&install_memory_probe.step);

    const thread_probe = b.addExecutable(.{
        .name = "thread-sanitizer-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/thread_sanitizer_probe.zig"),
            .target = target,
            .optimize = .debug,
            .sanitize_thread = true,
            .error_tracing = true,
            .strip = false,
            .link_libc = true,
        }),
    });
    const install_thread_probe = b.addInstallArtifact(thread_probe, .{});
    b.step("thread-sanitizer-probe", "Build isolated Zig TSan positive and negative controls").dependOn(&install_thread_probe.step);

    const run_step = b.step("run", "Run zigfs");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const delivery_probe = b.addExecutable(.{
        .name = "event-delivery-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/event_delivery_probe.zig"),
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
    const support_tests = b.addTest(.{ .root_module = test_support });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const run_support_tests = b.addRunArtifact(support_tests);

    const test_step = b.step("test", "Run unit and contract tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_support_tests.step);
}
