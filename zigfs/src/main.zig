const std = @import("std");
const zigfs = @import("zigfs");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try zigfs.config.Config.load(init.io, init.arena.allocator(), args);

    var app = zigfs.application.Application.init(config);
    defer app.deinit(init.io);
    try app.initialize(init.io);

    std.log.info(
        "zigfs {s} initialized (data_root={s}, api={s}, metrics={s}, metrics_enabled={})",
        .{ zigfs.version, config.data_root, config.api_address, config.metrics_address, config.metrics_enabled },
    );

    try zigfs.transport.http.serve(init.io, config);
}

test {
    _ = zigfs;
}
