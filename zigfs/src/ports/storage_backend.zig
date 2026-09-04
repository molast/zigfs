const std = @import("std");
const format = @import("../metadata/format.zig");

pub const EnsureReadyError = std.Io.Dir.CreateDirPathOpenError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.File.OpenError ||
    std.Io.File.LockError ||
    format.Error ||
    error{
        AlreadyInitialized,
        DataRootLocked,
        StorageNotWritable,
    };

pub const StorageBackend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ensure_ready: *const fn (context: *anyopaque, io: std.Io) EnsureReadyError!void,
    };

    pub fn ensureReady(self: StorageBackend, io: std.Io) EnsureReadyError!void {
        return self.vtable.ensure_ready(self.context, io);
    }
};
