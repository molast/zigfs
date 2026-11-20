const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("mbedtls", .{});
    const tls = b.addLibrary(.{
        .name = "mbedtls",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tls.root_module.addIncludePath(upstream.path("include"));
    tls.root_module.addIncludePath(b.path("."));
    tls.root_module.addCSourceFiles(.{
        .root = upstream.path("library"),
        .files = @import("mbedtls-sources.zig").files,
    });
    // PSA has shared state. Use portable mutex callbacks, including Windows.
    tls.root_module.addCMacro("MBEDTLS_THREADING_C", "1");
    tls.root_module.addCMacro("MBEDTLS_THREADING_ALT", "1");
    if (target.result.os.tag == .windows) tls.root_module.linkSystemLibrary("bcrypt", .{});

    const module = b.createModule(.{
        .root_source_file = b.path("transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("."));
    module.addIncludePath(upstream.path("include"));
    module.addCMacro("MBEDTLS_THREADING_C", "1");
    module.addCMacro("MBEDTLS_THREADING_ALT", "1");
    module.addCSourceFile(.{ .file = b.path("tls.c"), .flags = &.{"-std=c99"} });
    module.linkLibrary(tls);
    if (target.result.os.tag == .windows) {
        module.linkSystemLibrary("ws2_32", .{});
        module.linkSystemLibrary("crypt32", .{});
    }
    const library = b.addLibrary(.{ .name = "zigfs_net", .linkage = .static, .root_module = module });
    b.installArtifact(library);

    const probe = b.addExecutable(.{
        .name = "net-transport-abi-probe",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    probe.root_module.addIncludePath(b.path("."));
    probe.root_module.addCSourceFile(.{ .file = b.path("tests/abi_probe.c"), .flags = &.{"-std=c99"} });
    probe.root_module.linkLibrary(library);
    b.step("check", "Compile the transport ABI").dependOn(&probe.step);
    b.step("test", "Run the transport ABI probe").dependOn(&b.addRunArtifact(probe).step);
    const http_probe = b.addExecutable(.{
        .name = "net-transport-http-probe",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    http_probe.root_module.addIncludePath(b.path("."));
    http_probe.root_module.addCSourceFile(.{ .file = b.path("tests/http_probe.c"), .flags = &.{"-std=c99"} });
    http_probe.root_module.linkLibrary(library);
    const install_probe = b.addInstallArtifact(http_probe, .{});
    b.step("http-probe", "Build the HTTP/TLS regression probe").dependOn(&install_probe.step);
}
