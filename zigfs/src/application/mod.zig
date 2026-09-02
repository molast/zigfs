const std = @import("std");
const Config = @import("../config.zig").Config;
const LocalStorageBackend = @import("../backend/local.zig").LocalStorageBackend;

pub const Application = struct {
    config: Config,

    pub fn init(config: Config) Application {
        return .{ .config = config };
    }

    pub fn initialize(self: *Application, io: std.Io) !void {
        var local = LocalStorageBackend.init(self.config.data_root);
        const storage = local.interface();
        try storage.ensureReady(io);
    }
};
