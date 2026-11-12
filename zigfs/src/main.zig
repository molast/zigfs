const std = @import("std");
const zigfs = @import("zigfs");

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = zigfs.application.logging.logFn };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config = try zigfs.config.Config.loadWithEnvironment(init.io, init.arena.allocator(), args, zigfs.config.Config.environmentFromMap(init.environ_map));

    var app = zigfs.application.Application.init(config);
    defer app.deinit(init.io);
    try app.initialize(init.io);
    if (config.root_access_key.len > 0) {
        const service = app.credentialService() orelse return error.Unavailable;
        if (service.index.accessKeyGeneration(config.root_access_key) != null) return error.RootAccessKeyConflict;
    }
    config.api_address = try zigfs.application.listener_settings.load(init.arena.allocator(), app.data_root.?, init.io, config.api_address);
    app.config.api_address = config.api_address;
    config.s3_region = try zigfs.application.region_settings.load(init.arena.allocator(), app.data_root.?, init.io, config.s3_region);
    app.config.s3_region = config.s3_region;
    const authentication = try zigfs.application.auth_settings.load(init.arena.allocator(), app.data_root.?, init.io, zigfs.application.auth_settings.Settings.fromConfig(config));
    authentication.apply(&config);
    authentication.apply(&app.config);
    zigfs.application.logging.active = if (app.logger) |*logger| logger else null;
    defer zigfs.application.logging.active = null;
    if (app.kms) |*kms| {
        kms.allow_insecure_dev_defaults = config.kms_allow_insecure_dev_defaults;
        var kms_arena = std.heap.ArenaAllocator.init(app.allocator);
        defer kms_arena.deinit();
        kms.restore(kms_arena.allocator()) catch |err| zigfs.application.logging.reportFailure(.kms, err, @errorReturnTrace(), @src(), "KMS automatic startup failed: {s}", .{@errorName(err)});
    }
    try zigfs.application.oidc_store.importEnvironment(init.arena.allocator(), app.data_root.?, init.io, app.master_key.?.bytes, config.oidc_providers);

    if (std.mem.eql(u8, config.admin_username, "admin") and
        std.mem.eql(u8, config.admin_password, "zigfs-admin"))
    {
        std.log.warn("ZigFS is using the default local administrator credentials; change ZIGFS_ROOT_USER and ZIGFS_ROOT_PASSWORD in .env before external exposure", .{});
    }

    const recovery_state = app.recoveryState();
    std.debug.print(
        "zigfs {s} initialized (data_root={s}, api={s}, metrics={s}, metrics_enabled={}, recovery={s}, failure={s})\n",
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

    zigfs.transport.http.serve(init.io, &app) catch |err| {
        zigfs.application.logging.reportFailure(.server, err, @errorReturnTrace(), @src(), "ZigFS service stopped: {t}", .{err});
        return err;
    };
}

test {
    _ = zigfs;
}
