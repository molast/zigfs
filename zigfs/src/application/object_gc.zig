const std = @import("std");
const index_module = @import("../metadata/index.zig");
const data_store_port = @import("../ports/object_data_store.zig");
const multipart_data_store_port = @import("../ports/multipart_data_store.zig");
const multipart_store_port = @import("../ports/multipart_store.zig");
const object_store_port = @import("../ports/object_store.zig");
const object_tags = @import("object_tag_store.zig");
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
    partition: ?u8 = null,
    partitions: u8 = 1,
    scanned_generations: usize,
    retained_generations: usize,
    removed_generations: usize,
    scanned_bytes: u64 = 0,
    retained_bytes: u64 = 0,
    removed_bytes: u64 = 0,
};

pub const partition_count: u8 = 16;

pub const ObjectGcService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_root: std.Io.Dir,
    object_store: object_store_port.ObjectStore,
    data_store: data_store_port.ObjectDataStore,
    multipart_store: multipart_store_port.MultipartStore,
    multipart_data_store: multipart_data_store_port.MultipartDataStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,
    object_locks: *ObjectLockPool,
    multipart_locks: *ObjectLockPool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        data_root: std.Io.Dir,
        object_store: object_store_port.ObjectStore,
        data_store: data_store_port.ObjectDataStore,
        multipart_store: multipart_store_port.MultipartStore,
        multipart_data_store: multipart_data_store_port.MultipartDataStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
        object_locks: *ObjectLockPool,
        multipart_locks: *ObjectLockPool,
    ) ObjectGcService {
        return .{
            .allocator = allocator,
            .io = io,
            .data_root = data_root,
            .object_store = object_store,
            .data_store = data_store,
            .multipart_store = multipart_store,
            .multipart_data_store = multipart_data_store,
            .index = index,
            .state_mutex = state_mutex,
            .object_locks = object_locks,
            .multipart_locks = multipart_locks,
        };
    }

    pub fn collect(self: ObjectGcService) Error!Report {
        return self.collectInternal(null);
    }

    /// Reclaims one physical namespace partition. The metadata graph is still
    /// built from every object/version so an old version can never be removed
    /// merely because its object is not the current version.
    pub fn collectPartition(self: ObjectGcService, partition: u8) Error!Report {
        if (partition >= partition_count) return error.CorruptMetadata;
        return self.collectInternal(partition);
    }

    fn collectInternal(self: ObjectGcService, partition: ?u8) Error!Report {
        self.multipart_locks.lockAll(self.io);
        defer self.multipart_locks.unlockAll(self.io);
        self.object_locks.lockAll(self.io);
        defer self.object_locks.unlockAll(self.io);

        var reachable_objects = std.AutoHashMap(ObjectLocationKey, void).init(self.allocator);
        defer reachable_objects.deinit();
        var reachable_parts = std.AutoHashMap(MultipartLocationKey, void).init(self.allocator);
        defer reachable_parts.deinit();
        var live_tags = std.StringHashMap(void).init(self.allocator);
        defer {
            var tag_iterator = live_tags.keyIterator();
            while (tag_iterator.next()) |tag| self.allocator.free(tag.*);
            live_tags.deinit();
        }
        self.state_mutex.lockUncancelable(self.io);
        self.collectReachableLocked(&reachable_objects, &reachable_parts, &live_tags) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        _ = object_tags.pruneOrphans(self.allocator, self.data_root, self.io, &live_tags) catch |err| return switch (err) {
            error.InvalidTag => error.CorruptMetadata,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };

        const scan = (if (partition) |value|
            self.data_store.scanGenerationPartition(self.allocator, value)
        else
            self.data_store.scanGenerations(self.allocator)) catch |err| {
            return mapDataStoreError(err);
        };
        defer scan.deinit(self.allocator);
        var retained: usize = 0;
        var scanned_bytes: u64 = 0;
        var retained_bytes: u64 = 0;
        var expected_reachable: usize = 0;
        for (scan.generations) |generation| {
            scanned_bytes = std.math.add(u64, scanned_bytes, generation.data_size) catch return error.CorruptData;
            if (reachable_objects.contains(objectLocationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained += 1;
                retained_bytes = std.math.add(u64, retained_bytes, generation.data_size) catch return error.CorruptData;
            }
        }
        var reachable_iterator = reachable_objects.keyIterator();
        while (reachable_iterator.next()) |key| {
            if (partition == null or objectKeyPartition(key.*) == partition.?) expected_reachable += 1;
        }
        if (retained != expected_reachable) return error.CorruptData;

        const multipart_scan = (if (partition) |value|
            self.multipart_data_store.scanGenerationPartition(self.allocator, value)
        else
            self.multipart_data_store.scanGenerations(self.allocator)) catch |err| {
            return mapMultipartDataStoreError(err);
        };
        defer multipart_scan.deinit(self.allocator);
        var retained_parts: usize = 0;
        var expected_reachable_parts: usize = 0;
        for (multipart_scan.generations) |generation| {
            scanned_bytes = std.math.add(u64, scanned_bytes, generation.data_size) catch return error.CorruptData;
            if (reachable_parts.contains(multipartLocationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained_parts += 1;
                retained_bytes = std.math.add(u64, retained_bytes, generation.data_size) catch return error.CorruptData;
            }
        }
        var reachable_part_iterator = reachable_parts.keyIterator();
        while (reachable_part_iterator.next()) |key| {
            if (partition == null or multipartKeyPartition(key.*) == partition.?) expected_reachable_parts += 1;
        }
        if (retained_parts != expected_reachable_parts) return error.CorruptData;

        var removed: usize = 0;
        var removed_bytes: u64 = 0;
        for (scan.generations) |generation| {
            if (reachable_objects.contains(objectLocationKey(generation.location))) continue;
            const did_remove = self.data_store.deleteGeneration(generation.location) catch |err| {
                return mapDataStoreError(err);
            };
            if (!did_remove) return error.CorruptData;
            removed += 1;
            removed_bytes = std.math.add(u64, removed_bytes, generation.data_size) catch return error.CorruptData;
        }
        for (multipart_scan.generations) |generation| {
            if (reachable_parts.contains(multipartLocationKey(generation.location))) continue;
            const did_remove = self.multipart_data_store.deleteGeneration(generation.location) catch |err| {
                return mapMultipartDataStoreError(err);
            };
            if (!did_remove) return error.CorruptData;
            removed += 1;
            removed_bytes = std.math.add(u64, removed_bytes, generation.data_size) catch return error.CorruptData;
        }
        return .{
            .partition = partition,
            .partitions = if (partition == null) 1 else partition_count,
            .scanned_generations = scan.generations.len + multipart_scan.generations.len,
            .retained_generations = retained + retained_parts,
            .removed_generations = removed,
            .scanned_bytes = scanned_bytes,
            .retained_bytes = retained_bytes,
            .removed_bytes = removed_bytes,
        };
    }

    pub fn collectMultipart(self: ObjectGcService) Error!Report {
        self.multipart_locks.lockAll(self.io);
        defer self.multipart_locks.unlockAll(self.io);
        self.object_locks.lockAll(self.io);
        defer self.object_locks.unlockAll(self.io);

        var reachable_objects = std.AutoHashMap(ObjectLocationKey, void).init(self.allocator);
        defer reachable_objects.deinit();
        var reachable_parts = std.AutoHashMap(MultipartLocationKey, void).init(self.allocator);
        defer reachable_parts.deinit();
        self.state_mutex.lockUncancelable(self.io);
        var live_tags = std.StringHashMap(void).init(self.allocator);
        defer {
            var tag_iterator = live_tags.keyIterator();
            while (tag_iterator.next()) |tag| self.allocator.free(tag.*);
            live_tags.deinit();
        }
        self.collectReachableLocked(&reachable_objects, &reachable_parts, &live_tags) catch |err| {
            self.state_mutex.unlock(self.io);
            return err;
        };
        self.state_mutex.unlock(self.io);
        _ = object_tags.pruneOrphans(self.allocator, self.data_root, self.io, &live_tags) catch |err| return switch (err) {
            error.InvalidTag => error.CorruptMetadata,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };

        const scan = self.multipart_data_store.scanGenerations(self.allocator) catch |err| {
            return mapMultipartDataStoreError(err);
        };
        defer scan.deinit(self.allocator);
        var retained: usize = 0;
        var scanned_bytes: u64 = 0;
        var retained_bytes: u64 = 0;
        for (scan.generations) |generation| {
            scanned_bytes = std.math.add(u64, scanned_bytes, generation.data_size) catch return error.CorruptData;
            if (reachable_parts.contains(multipartLocationKey(generation.location))) {
                if (!generation.data_present) return error.CorruptData;
                retained += 1;
                retained_bytes = std.math.add(u64, retained_bytes, generation.data_size) catch return error.CorruptData;
            }
        }
        if (retained != reachable_parts.count()) return error.CorruptData;
        var removed: usize = 0;
        var removed_bytes: u64 = 0;
        for (scan.generations) |generation| {
            if (reachable_parts.contains(multipartLocationKey(generation.location))) continue;
            const did_remove = self.multipart_data_store.deleteGeneration(generation.location) catch |err| {
                return mapMultipartDataStoreError(err);
            };
            if (!did_remove) return error.CorruptData;
            removed += 1;
            removed_bytes = std.math.add(u64, removed_bytes, generation.data_size) catch return error.CorruptData;
        }
        return .{
            .scanned_generations = scan.generations.len,
            .retained_generations = retained,
            .removed_generations = removed,
            .scanned_bytes = scanned_bytes,
            .retained_bytes = retained_bytes,
            .removed_bytes = removed_bytes,
        };
    }

    fn collectReachableLocked(
        self: ObjectGcService,
        reachable_objects: *std.AutoHashMap(ObjectLocationKey, void),
        reachable_parts: *std.AutoHashMap(MultipartLocationKey, void),
        live_tags: *std.StringHashMap(void),
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
                    var version_buffer: [32]u8 = undefined;
                    const version_text = object.version_id.write(&version_buffer);
                    const tag_filename = object_tags.filenameFor(self.allocator, entry.bucket, entry.key, version_text) catch return error.OutOfMemory;
                    live_tags.put(tag_filename, {}) catch { self.allocator.free(tag_filename); return error.OutOfMemory; };
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
            const upload_id = std.fmt.bytesToHex(upload.id, .lower);
            const tag_filename = object_tags.filenameFor(self.allocator, upload.bucket_name, upload.key, &upload_id) catch return error.OutOfMemory;
            live_tags.put(tag_filename, {}) catch { self.allocator.free(tag_filename); return error.OutOfMemory; };
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

fn objectKeyPartition(key: ObjectLocationKey) u8 {
    return key[16] >> 4;
}

fn multipartKeyPartition(key: MultipartLocationKey) u8 {
    return key[0] >> 4;
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
