const std = @import("std");
const storage_port = @import("../ports/storage_backend.zig");
const StorageBackend = storage_port.StorageBackend;

pub const LocalStorageBackend = struct {
    root_path: []const u8,

    pub fn init(root_path: []const u8) LocalStorageBackend {
        return .{ .root_path = root_path };
    }

    pub fn interface(self: *LocalStorageBackend) StorageBackend {
        return .{
            .context = self,
            .vtable = &.{ .ensure_ready = ensureReady },
        };
    }

    fn ensureReady(context: *anyopaque, io: std.Io) storage_port.EnsureReadyError!void {
        const self: *LocalStorageBackend = @ptrCast(@alignCast(context));
        const cwd = std.Io.Dir.cwd();
        var root = try cwd.createDirPathOpen(io, self.root_path, .{});
        defer root.close(io);

        try root.createDirPath(io, ".zigfs/system/credentials");
        try root.createDirPath(io, ".zigfs/journal");
        try root.createDirPath(io, ".zigfs/indexes");
        try root.createDirPath(io, ".zigfs/tmp");
        try root.createDirPath(io, "metadata/buckets");
        try root.createDirPath(io, "metadata/objects");
        try root.createDirPath(io, "metadata/multipart");
        try root.createDirPath(io, "objects");
    }
};
