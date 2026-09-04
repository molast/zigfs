const std = @import("std");
const id = @import("../common/id.zig");
const durable = @import("../metadata/durable.zig");
const format = @import("../metadata/format.zig");
const storage_port = @import("../ports/storage_backend.zig");
const StorageBackend = storage_port.StorageBackend;

pub const LocalStorageBackend = struct {
    const write_probe_path = ".zigfs/tmp/storage-ready.probe";

    root_path: []const u8,
    lock_file: ?std.Io.File = null,
    persistent_instance_id: ?id.Uuid = null,

    pub fn init(root_path: []const u8) LocalStorageBackend {
        return .{ .root_path = root_path };
    }

    pub fn interface(self: *LocalStorageBackend) StorageBackend {
        return .{
            .context = self,
            .vtable = &.{ .ensure_ready = ensureReady },
        };
    }

    pub fn deinit(self: *LocalStorageBackend, io: std.Io) void {
        if (self.lock_file) |lock_file| {
            lock_file.unlock(io);
            lock_file.close(io);
            self.lock_file = null;
        }
        self.persistent_instance_id = null;
    }

    pub fn instanceId(self: *const LocalStorageBackend) ?id.Uuid {
        return self.persistent_instance_id;
    }

    fn ensureReady(context: *anyopaque, io: std.Io) storage_port.EnsureReadyError!void {
        const self: *LocalStorageBackend = @ptrCast(@alignCast(context));
        return self.ensureReadyIn(io, std.Io.Dir.cwd());
    }

    pub fn ensureReadyIn(
        self: *LocalStorageBackend,
        io: std.Io,
        parent: std.Io.Dir,
    ) storage_port.EnsureReadyError!void {
        if (self.lock_file != null) return error.AlreadyInitialized;

        var root = try parent.createDirPathOpen(io, self.root_path, .{});
        defer root.close(io);

        try root.createDirPath(io, ".zigfs");
        var lock_file = try root.createFile(io, ".zigfs/instance.lock", .{
            .read = true,
            .truncate = false,
        });
        errdefer lock_file.close(io);
        if (!try lock_file.tryLock(io, .exclusive)) return error.DataRootLocked;
        errdefer lock_file.unlock(io);

        const format_metadata = try format.loadOrCreate(root, io);
        try root.createDirPath(io, ".zigfs/system/credentials");
        try root.createDirPath(io, ".zigfs/system/configuration");
        try root.createDirPath(io, ".zigfs/system/configuration/records");
        try root.createDirPath(io, ".zigfs/journal");
        try root.createDirPath(io, ".zigfs/indexes");
        try root.createDirPath(io, ".zigfs/tmp");
        try root.createDirPath(io, "metadata/buckets");
        try root.createDirPath(io, "metadata/objects");
        try root.createDirPath(io, "metadata/multipart");
        try root.createDirPath(io, "multipart");
        try root.createDirPath(io, "objects");
        try probeWritable(root, io);

        self.lock_file = lock_file;
        self.persistent_instance_id = format_metadata.instance_id;
    }

    fn probeWritable(root: std.Io.Dir, io: std.Io) error{StorageNotWritable}!void {
        {
            var probe = root.createFile(io, write_probe_path, .{
                .read = true,
                .truncate = true,
            }) catch return error.StorageNotWritable;
            defer probe.close(io);
            probe.writeStreamingAll(io, "zigfs-ready") catch return error.StorageNotWritable;
            probe.sync(io) catch return error.StorageNotWritable;
        }
        root.deleteFile(io, write_probe_path) catch return error.StorageNotWritable;
        durable.syncParent(root, io, write_probe_path) catch return error.StorageNotWritable;
    }
};

test "local backend retains an exclusive data root lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = LocalStorageBackend.init("data");
    try first.ensureReadyIn(std.testing.io, tmp.dir);
    defer first.deinit(std.testing.io);

    var second = LocalStorageBackend.init("data");
    try std.testing.expectError(
        error.DataRootLocked,
        second.ensureReadyIn(std.testing.io, tmp.dir),
    );
    try std.testing.expect(second.instanceId() == null);
}

test "local backend reopens after lock owner exits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = LocalStorageBackend.init("data");
    try first.ensureReadyIn(std.testing.io, tmp.dir);
    const original_id = first.instanceId().?;
    first.deinit(std.testing.io);

    var second = LocalStorageBackend.init("data");
    try second.ensureReadyIn(std.testing.io, tmp.dir);
    defer second.deinit(std.testing.io);
    try std.testing.expectEqualSlices(u8, &original_id, &second.instanceId().?);
}

test "local backend creates phase 2b metadata layout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var backend = LocalStorageBackend.init("data");
    try backend.ensureReadyIn(std.testing.io, tmp.dir);
    defer backend.deinit(std.testing.io);

    const required_directories = [_][]const u8{
        "data/.zigfs/system/configuration/records",
        "data/.zigfs/system/credentials",
        "data/.zigfs/journal",
        "data/.zigfs/tmp",
        "data/metadata/buckets",
        "data/metadata/objects",
        "data/metadata/multipart",
        "data/multipart",
    };
    for (required_directories) |path| {
        var directory = try tmp.dir.openDir(std.testing.io, path, .{});
        directory.close(std.testing.io);
    }
}

test "local backend rejects an unwritable probe path and releases its lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "data/.zigfs/tmp/storage-ready.probe");

    var unavailable = LocalStorageBackend.init("data");
    try std.testing.expectError(
        error.StorageNotWritable,
        unavailable.ensureReadyIn(std.testing.io, tmp.dir),
    );
    try std.testing.expect(unavailable.instanceId() == null);

    try tmp.dir.deleteDir(std.testing.io, "data/.zigfs/tmp/storage-ready.probe");
    var recovered = LocalStorageBackend.init("data");
    try recovered.ensureReadyIn(std.testing.io, tmp.dir);
    defer recovered.deinit(std.testing.io);
    try std.testing.expect(recovered.instanceId() != null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "data/.zigfs/tmp/storage-ready.probe", .{}),
    );
}
