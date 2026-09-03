const std = @import("std");
const index_module = @import("../metadata/index.zig");
const data_store_port = @import("../ports/object_data_store.zig");
const object_store_port = @import("../ports/object_store.zig");
const ObjectLockPool = @import("object_lock_pool.zig").ObjectLockPool;

const LocationKey = [48]u8;

pub const Error = error{
    OutOfMemory,
    CorruptMetadata,
    CorruptData,
    Unavailable,
};

pub const Report = struct {
    scanned_generations: usize,
    retained_generations: usize,
    removed_generations: usize,
};

pub const ObjectGcService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    object_store: object_store_port.ObjectStore,
    data_store: data_store_port.ObjectDataStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    object_locks: *ObjectLockPool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        object_store: object_store_port.ObjectStore,
        data_store: data_store_port.ObjectDataStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
        object_locks: *ObjectLockPool,
    ) ObjectGcService {
        return .{
            .allocator = allocator,
            .io = io,
            .object_store = object_store,
            .data_store = data_store,
            .index = index,
            .state_mutex = state_mutex,
            .object_locks = object_locks,
        };
    }

    pub fn collect(self: ObjectGcService) Error!Report {
        self.object_locks.lockAll(self.io);
        defer self.object_locks.unlockAll(self.io);

        var reachable = std.AutoHashMap(LocationKey, void).init(self.allocator);
        defer reachable.deinit();
        self.state_mutex.lockUncancelable(self.io);
        self.collectReachableLocked(&reachable) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);

        const scan = self.data_store.scanGenerations(self.allocator) catch |err| {
            return mapDataStoreError(err);
        };
        defer scan.deinit(self.allocator);
        var retained: usize = 0;
        for (scan.generations) |generation| {
            if (reachable.contains(locationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained += 1;
            }
        }
        if (retained != reachable.count()) return error.CorruptData;

        var removed: usize = 0;
        for (scan.generations) |generation| {
            if (reachable.contains(locationKey(generation.location))) continue;
            const did_remove = self.data_store.deleteGeneration(generation.location) catch |err| {
                return mapDataStoreError(err);
            };
            if (!did_remove) return error.CorruptData;
            removed += 1;
        }
        return .{
            .scanned_generations = scan.generations.len,
            .retained_generations = retained,
            .removed_generations = removed,
        };
    }

    fn collectReachableLocked(
        self: ObjectGcService,
        reachable: *std.AutoHashMap(LocationKey, void),
    ) Error!void {
        for (self.index.objectEntries()) |entry| {
            const record = self.object_store.get(
                self.allocator,
                entry.bucket,
                entry.key,
            ) catch |err| return mapObjectStoreError(err);
            defer record.deinit(self.allocator);
            const object = switch (record) {
                .active => |value| value,
                .tombstone => return error.CorruptMetadata,
            };
            if (object.metadata_generation != entry.generation) {
                return error.CorruptMetadata;
            }
            const key = locationKey(.{
                .bucket_id = object.bucket_id,
                .object_id = object.id,
                .data_generation = object.data_generation,
            });
            if (reachable.contains(key)) return error.CorruptMetadata;
            reachable.put(key, {}) catch return error.OutOfMemory;
        }
    }
};

fn locationKey(location: data_store_port.Location) LocationKey {
    var key: LocationKey = undefined;
    @memcpy(key[0..16], &location.bucket_id);
    @memcpy(key[16..32], &location.object_id);
    @memcpy(key[32..48], &location.data_generation);
    return key;
}

fn mapObjectStoreError(err: object_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound,
        error.Conflict,
        error.InvalidValue,
        error.CorruptMetadata,
        => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapDataStoreError(err: data_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptData => error.CorruptData,
        error.InvalidValue => error.CorruptMetadata,
        error.SourceReadFailed,
        error.SinkWriteFailed,
        error.NotFound,
        error.Conflict,
        error.Unavailable,
        => error.Unavailable,
    };
}
