const std = @import("std");
const index_module = @import("../metadata/index.zig");
const object_store_port = @import("../ports/object_store.zig");

pub const Error = error{
    OutOfMemory,
    CorruptMetadata,
    Unavailable,
};

pub const Snapshot = struct {
    buckets: u64,
    objects: u64,
    object_bytes: u64,
    uptime_seconds: u64,
};

pub const ManagementService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    object_store: object_store_port.ObjectStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    started_at_unix_seconds: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        object_store: object_store_port.ObjectStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
        started_at_unix_seconds: i64,
    ) ManagementService {
        return .{
            .allocator = allocator,
            .io = io,
            .object_store = object_store,
            .index = index,
            .state_mutex = state_mutex,
            .started_at_unix_seconds = started_at_unix_seconds,
        };
    }

    pub fn snapshot(self: ManagementService) Error!Snapshot {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        var object_bytes: u64 = 0;
        var object_count: u64 = 0;
        for (self.index.objectEntries()) |entry| {
            const record = self.object_store.get(
                self.allocator,
                entry.bucket,
                entry.key,
            ) catch |err| return mapStoreError(err);
            defer record.deinit(self.allocator);
            const object = switch (record) {
                .active => |value| value,
                .delete_marker => continue,
                .tombstone => return error.CorruptMetadata,
            };
            if (object.metadata_generation != entry.generation) {
                return error.CorruptMetadata;
            }
            object_bytes = std.math.add(u64, object_bytes, object.size) catch {
                return error.CorruptMetadata;
            };
            object_count += 1;
        }

        const now = std.Io.Clock.real.now(self.io).toSeconds();
        return .{
            .buckets = @intCast(self.index.bucketEntries().len),
            .objects = object_count,
            .object_bytes = object_bytes,
            .uptime_seconds = if (now > self.started_at_unix_seconds)
                @intCast(now - self.started_at_unix_seconds)
            else
                0,
        };
    }
};

fn mapStoreError(err: object_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptMetadata, error.InvalidValue, error.NotFound => error.CorruptMetadata,
        error.Conflict, error.Unavailable => error.Unavailable,
    };
}
