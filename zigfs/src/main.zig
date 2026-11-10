const std = @import("std");
const zigfs = @import("zigfs");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try zigfs.config.Config.load(init.io, init.arena.allocator(), args);

    var app = zigfs.application.Application.init(config);
    defer app.deinit(init.io);
    try app.initialize(init.io);
    if (app.kms) |*kms| {
        kms.allow_insecure_dev_defaults = std.mem.eql(u8, init.environ_map.get("ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS") orelse "", "true");
        var kms_arena = std.heap.ArenaAllocator.init(app.allocator);
        defer kms_arena.deinit();
        kms.restore(kms_arena.allocator()) catch |err| std.log.warn("KMS automatic startup failed: {s}", .{@errorName(err)});
    }
    try zigfs.application.oidc_store.importEnvironment(init.arena.allocator(), app.data_root.?, init.io, app.master_key.?.bytes, init.environ_map.get("ZIGFS_OIDC_PROVIDERS") orelse "[]");

    if (std.mem.eql(u8, config.admin_username, "admin") and
        std.mem.eql(u8, config.admin_password, "zigfs-admin"))
    {
        std.log.warn("ZigFS is using the default local administrator credentials; change the admin section in config.yaml before external exposure", .{});
    }

    const recovery_state = app.recoveryState();
    std.log.info(
        "zigfs {s} initialized (data_root={s}, api={s}, metrics={s}, metrics_enabled={}, recovery={s}, failure={s})",
        .{
            zigfs.version,
            config.data_root,
            config.api_address,
            config.metrics_address,
            config.metrics_enabled,
            @tagName(recovery_state.status),
            @tagName(recovery_state.failure),
        },
    );

    try zigfs.transport.http.serve(init.io, &app);
}

test {
    _ = zigfs;
}
