const std = @import("std");
const Config = @import("../config.zig").Config;
const LocalStorageBackend = @import("../backend/local.zig").LocalStorageBackend;

pub const Application = struct {
    config: Config,
    local_storage: LocalStorageBackend,

    pub fn init(config: Config) Application {
        return .{
            .config = config,
            .local_storage = LocalStorageBackend.init(config.data_root),
        };
    }

    pub fn initialize(self: *Application, io: std.Io) !void {
        const storage = self.local_storage.interface();
        try storage.ensureReady(io);
    }

    pub fn deinit(self: *Application, io: std.Io) void {
        self.local_storage.deinit(io);
    }
};
