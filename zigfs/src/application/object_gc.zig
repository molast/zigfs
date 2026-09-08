const std = @import("std");
const index_module = @import("../metadata/index.zig");
const data_store_port = @import("../ports/object_data_store.zig");
const multipart_data_store_port = @import("../ports/multipart_data_store.zig");
const multipart_store_port = @import("../ports/multipart_store.zig");
const object_store_port = @import("../ports/object_store.zig");
const ObjectLockPool = @import("object_lock_pool.zig").ObjectLockPool;

const ObjectLocationKey = [48]u8;
const MultipartLocationKey = [34]u8;

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
    multipart_store: multipart_store_port.MultipartStore,
    multipart_data_store: multipart_data_store_port.MultipartDataStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    object_locks: *ObjectLockPool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        object_store: object_store_port.ObjectStore,
        data_store: data_store_port.ObjectDataStore,
        multipart_store: multipart_store_port.MultipartStore,
        multipart_data_store: multipart_data_store_port.MultipartDataStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
        object_locks: *ObjectLockPool,
    ) ObjectGcService {
        return .{
            .allocator = allocator,
            .io = io,
            .object_store = object_store,
            .data_store = data_store,
            .multipart_store = multipart_store,
            .multipart_data_store = multipart_data_store,
            .index = index,
            .state_mutex = state_mutex,
            .object_locks = object_locks,
        };
    }

    pub fn collect(self: ObjectGcService) Error!Report {
        self.object_locks.lockAll(self.io);
        defer self.object_locks.unlockAll(self.io);

        var reachable_objects = std.AutoHashMap(ObjectLocationKey, void).init(self.allocator);
        defer reachable_objects.deinit();
        var reachable_parts = std.AutoHashMap(MultipartLocationKey, void).init(self.allocator);
        defer reachable_parts.deinit();
        self.state_mutex.lockUncancelable(self.io);
        self.collectReachableLocked(&reachable_objects, &reachable_parts) catch |err| {
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
            if (reachable_objects.contains(objectLocationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained += 1;
            }
        }
        if (retained != reachable_objects.count()) return error.CorruptData;

        var removed: usize = 0;
        for (scan.generations) |generation| {
            if (reachable_objects.contains(objectLocationKey(generation.location))) continue;
            const did_remove = self.data_store.deleteGeneration(generation.location) catch |err| {
                return mapDataStoreError(err);
            };
            if (!did_remove) return error.CorruptData;
            removed += 1;
        }

        const multipart_scan = self.multipart_data_store.scanGenerations(self.allocator) catch |err| {
            return mapMultipartDataStoreError(err);
        };
        defer multipart_scan.deinit(self.allocator);
        var retained_parts: usize = 0;
        for (multipart_scan.generations) |generation| {
            if (reachable_parts.contains(multipartLocationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained_parts += 1;
            }
        }
        if (retained_parts != reachable_parts.count()) return error.CorruptData;
        for (multipart_scan.generations) |generation| {
            if (reachable_parts.contains(multipartLocationKey(generation.location))) continue;
            const did_remove = self.multipart_data_store.deleteGeneration(generation.location) catch |err| {
                return mapMultipartDataStoreError(err);
            };
            if (!did_remove) return error.CorruptData;
            removed += 1;
        }
        return .{
            .scanned_generations = scan.generations.len + multipart_scan.generations.len,
            .retained_generations = retained + retained_parts,
            .removed_generations = removed,
        };
    }

    pub fn collectMultipart(self: ObjectGcService) Error!Report {
        self.object_locks.lockAll(self.io);
        defer self.object_locks.unlockAll(self.io);

        var reachable_objects = std.AutoHashMap(ObjectLocationKey, void).init(self.allocator);
        defer reachable_objects.deinit();
        var reachable_parts = std.AutoHashMap(MultipartLocationKey, void).init(self.allocator);
        defer reachable_parts.deinit();
        self.state_mutex.lockUncancelable(self.io);
        self.collectReachableLocked(&reachable_objects, &reachable_parts) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);

        const scan = self.multipart_data_store.scanGenerations(self.allocator) catch |err| {
            return mapMultipartDataStoreError(err);
        };
        defer scan.deinit(self.allocator);
        var retained: usize = 0;
        for (scan.generations) |generation| {
            if (reachable_parts.contains(multipartLocationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained += 1;
            }
        }
        if (retained != reachable_parts.count()) return error.CorruptData;
        var removed: usize = 0;
        for (scan.generations) |generation| {
            if (reachable_parts.contains(multipartLocationKey(generation.location))) continue;
            const did_remove = self.multipart_data_store.deleteGeneration(generation.location) catch |err| {
                return mapMultipartDataStoreError(err);
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
        reachable_objects: *std.AutoHashMap(ObjectLocationKey, void),
        reachable_parts: *std.AutoHashMap(MultipartLocationKey, void),
    ) Error!void {
        for (self.index.objectEntries()) |entry| {
            const record = self.object_store.getHistory(
                self.allocator,
                entry.bucket,
                entry.key,
            ) catch |err| return mapObjectStoreError(err);
            defer record.deinit(self.allocator);
            const history = switch (record) {
                .active => |value| value,
                .tombstone => return error.CorruptMetadata,
            };
            if (history.metadata_generation != entry.generation) {
                return error.CorruptMetadata;
            }
            for (history.entries) |version| switch (version) {
                .delete_marker => {},
                .object => |object| {
                    if (object.multipart_manifest) |manifest| {
                        for (manifest.parts) |part| {
                            const key = multipartLocationKey(.{
                                .upload_id = manifest.upload_id,
                                .part_number = part.number,
                                .data_generation = part.data_generation,
                            });
                            reachable_parts.put(key, {}) catch return error.OutOfMemory;
                        }
                    } else {
                        const key = objectLocationKey(.{
                            .bucket_id = object.bucket_id,
                            .object_id = object.id,
                            .data_generation = object.data_generation,
                        });
                        reachable_objects.put(key, {}) catch return error.OutOfMemory;
                    }
                },
            };
        }
        for (self.index.uploadEntries()) |entry| {
            const record = self.multipart_store.get(self.allocator, entry.name) catch |err| return mapMultipartStoreError(err);
            defer record.deinit(self.allocator);
            const upload = switch (record) {
                .active => |value| value,
                .tombstone => return error.CorruptMetadata,
            };
            if (upload.metadata_generation != entry.generation) return error.CorruptMetadata;
            for (upload.parts) |part| {
                const key = multipartLocationKey(.{
                    .upload_id = upload.id,
                    .part_number = part.number,
                    .data_generation = part.data_generation,
                });
                reachable_parts.put(key, {}) catch return error.OutOfMemory;
            }
        }
    }
};

fn objectLocationKey(location: data_store_port.Location) ObjectLocationKey {
    var key: ObjectLocationKey = undefined;
    @memcpy(key[0..16], &location.bucket_id);
    @memcpy(key[16..32], &location.object_id);
    @memcpy(key[32..48], &location.data_generation);
    return key;
}

fn multipartLocationKey(location: multipart_data_store_port.Location) MultipartLocationKey {
    var key: MultipartLocationKey = undefined;
    @memcpy(key[0..16], &location.upload_id);
    std.mem.writeInt(u16, key[16..18], location.part_number, .little);
    @memcpy(key[18..34], &location.data_generation);
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

fn mapMultipartStoreError(err: multipart_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound, error.Conflict, error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapMultipartDataStoreError(err: multipart_data_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptData => error.CorruptData,
        error.InvalidValue => error.CorruptMetadata,
        error.SourceReadFailed, error.SinkWriteFailed, error.NotFound, error.Conflict, error.Unavailable => error.Unavailable,
    };
}
