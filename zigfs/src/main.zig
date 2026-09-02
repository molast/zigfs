const std = @import("std");
const zigfs = @import("zigfs");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try zigfs.config.Config.load(init.io, init.arena.allocator(), args);

    var app = zigfs.application.Application.init(config);
    try app.initialize(init.io);

    std.log.info(
        "zigfs {s} initialized (data_root={s}, s3={s}, management={s})",
        .{ zigfs.version, config.data_root, config.s3_address, config.management_address },
    );
}

test {
    _ = zigfs;
}
