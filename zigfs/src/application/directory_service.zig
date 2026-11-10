const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const directory_domain = @import("../domain/directory.zig");
const object_store_port = @import("../ports/object_store.zig");
const directory_store_port = @import("../ports/directory_store.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");
const index_module = @import("../metadata/index.zig");

pub const Error = error{
    OutOfMemory,
    InvalidBucketName,
    InvalidDirectoryKey,
    BucketNotFound,
    DirectoryNotFound,
    DirectoryNotEmpty,
    CorruptMetadata,
    Unavailable,
    Conflict,
};

pub const DeleteResult = struct { deleted: bool };

pub const DirectoryService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    bucket_store: bucket_store_port.BucketStore,
    directory_store: directory_store_port.DirectoryStore,
    object_store: object_store_port.ObjectStore,
    index: *index_module.MetadataIndex,
    state_mutex: *std.Io.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bucket_store: bucket_store_port.BucketStore,
        directory_store: directory_store_port.DirectoryStore,
        object_store: object_store_port.ObjectStore,
        index: *index_module.MetadataIndex,
        state_mutex: *std.Io.Mutex,
    ) DirectoryService {
        return .{ .allocator = allocator, .io = io, .bucket_store = bucket_store, .directory_store = directory_store, .object_store = object_store, .index = index, .state_mutex = state_mutex };
    }

    pub fn create(self: DirectoryService, bucket_name: []const u8, key: []const u8) Error!directory_domain.Directory {
        directory_domain.validate(bucket_name, key) catch |err| return switch (err) {
            error.InvalidBucketName => error.InvalidBucketName,
            error.InvalidDirectoryKey => error.InvalidDirectoryKey,
        };
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.verifyBucketLocked(bucket_name);
        // A typed directory owns its key namespace. Remove any object marker
        // at the same key before publishing the directory record.
        try self.removeObjectMarkerLocked(bucket_name, key);
        if (self.index.directoryGeneration(bucket_name, key) != null) return self.directory_store.get(self.allocator, bucket_name, key) catch |err| return mapStoreError(err);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        try self.ensureParentsLocked(bucket_name, key, now);
        var prepared = self.index.prepareDirectory(bucket_name, key) catch |err| return mapIndexError(err);
        defer prepared.deinit(self.index.allocator);
        const generation = self.directory_store.put(self.allocator, bucket_name, key, now, now, .missing) catch |err| return mapStoreError(err);
        self.index.publishDirectory(&prepared, generation, now);
        return self.directory_store.get(self.allocator, bucket_name, key) catch |err| return mapStoreError(err);
    }

    pub fn delete(self: DirectoryService, bucket_name: []const u8, key: []const u8) Error!DeleteResult {
        directory_domain.validate(bucket_name, key) catch |err| return switch (err) {
            error.InvalidBucketName => error.InvalidBucketName,
            error.InvalidDirectoryKey => error.InvalidDirectoryKey,
        };
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.verifyBucketLocked(bucket_name);
        const generation = self.index.directoryGeneration(bucket_name, key) orelse return .{ .deleted = false };
        // Delete the complete key namespace in one metadata transaction. The
        // index already contains every descendant key, so this remains
        // bounded by the number of records and does not recurse through the
        // directory tree or the object data plane.
        var object_position: usize = 0;
        while (object_position < self.index.objectEntries().len) {
            const entry = self.index.objectEntries()[object_position];
            if (!std.mem.eql(u8, entry.bucket, bucket_name) or entry.key.len <= key.len or !std.mem.startsWith(u8, entry.key, key)) {
                object_position += 1;
                continue;
            }
            const record = self.object_store.get(self.allocator, bucket_name, entry.key) catch |err| return mapObjectError(err);
            defer record.deinit(self.allocator);
            const object_generation = entry.generation;
            if (record == .tombstone) {
                object_position += 1;
                continue;
            }
            _ = self.object_store.tombstone(self.allocator, bucket_name, entry.key, object_generation) catch |err| return mapObjectError(err);
            if (!self.index.removeObject(bucket_name, entry.key)) return error.CorruptMetadata;
        }
        var directory_position: usize = 0;
        while (directory_position < self.index.directoryEntries().len) {
            const entry = self.index.directoryEntries()[directory_position];
            if (!std.mem.eql(u8, entry.bucket, bucket_name) or entry.key.len <= key.len or !std.mem.startsWith(u8, entry.key, key)) {
                directory_position += 1;
                continue;
            }
            _ = self.directory_store.tombstone(self.allocator, bucket_name, entry.key, entry.generation) catch |err| return mapStoreError(err);
            if (!self.index.removeDirectory(bucket_name, entry.key)) return error.CorruptMetadata;
        }
        try self.removeObjectMarkerLocked(bucket_name, key);
        _ = self.directory_store.tombstone(self.allocator, bucket_name, key, generation) catch |err| return mapStoreError(err);
        if (!self.index.removeDirectory(bucket_name, key)) return error.CorruptMetadata;
        return .{ .deleted = true };
    }

    /// Remove only directory records after object-service deletion. Historical
    /// versions remain reachable for ordinary versioned deletes.
    pub fn prune(self: DirectoryService, bucket_name: []const u8, key: []const u8, all_versions: bool) Error!void {
        return self.pruneInternal(bucket_name, key, all_versions, false);
    }

    /// Reconcile indexed directories against authoritative records. A valid
    /// empty directory is not garbage: retain it, including its generation.
    pub fn repair(self: DirectoryService, bucket_name: []const u8, prefix: []const u8) Error!void {
        directory_domain.validate(bucket_name, prefix) catch return error.InvalidDirectoryKey;
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.verifyBucketLocked(bucket_name);
        var keys: std.ArrayList([]u8) = .empty;
        defer {
            for (keys.items) |key| self.allocator.free(key);
            keys.deinit(self.allocator);
        }
        const root_key = self.allocator.dupe(u8, prefix) catch return error.OutOfMemory;
        keys.append(self.allocator, root_key) catch {
            self.allocator.free(root_key);
            return error.OutOfMemory;
        };
        for (self.index.directoryEntries()) |entry| {
            if (!std.mem.eql(u8, entry.bucket, bucket_name) or !std.mem.startsWith(u8, entry.key, prefix) or std.mem.eql(u8, entry.key, prefix)) continue;
            const key = self.allocator.dupe(u8, entry.key) catch return error.OutOfMemory;
            keys.append(self.allocator, key) catch {
                self.allocator.free(key);
                return error.OutOfMemory;
            };
        }
        for (keys.items) |key| {
            const record = self.directory_store.get(self.allocator, bucket_name, key) catch |err| switch (err) {
                error.NotFound => {
                    // A durable tombstone or absent record proves the listing
                    // entry is stale. Do not tombstone a healthy empty folder.
                    _ = self.index.removeDirectory(bucket_name, key);
                    continue;
                },
                else => return mapStoreError(err),
            };
            defer record.deinit(self.allocator);
            if (self.index.directoryGeneration(bucket_name, key) != record.generation) {
                var prepared = self.index.prepareDirectory(bucket_name, key) catch |err| return mapIndexError(err);
                defer prepared.deinit(self.index.allocator);
                self.index.publishDirectory(&prepared, record.generation, record.last_modified_unix_seconds);
            }
        }
    }

    fn pruneInternal(self: DirectoryService, bucket_name: []const u8, key: []const u8, all_versions: bool, keep_root: bool) Error!void {
        directory_domain.validate(bucket_name, key) catch return error.InvalidDirectoryKey;
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.verifyBucketLocked(bucket_name);
        for (self.index.objectEntries()) |entry| {
            if (!std.mem.eql(u8, entry.bucket, bucket_name) or !std.mem.startsWith(u8, entry.key, key)) continue;
            const record = self.object_store.get(self.allocator, bucket_name, entry.key) catch |err| return mapObjectError(err);
            defer record.deinit(self.allocator);
            switch (record) {
                .active => |object| {
                    if (!std.mem.endsWith(u8, entry.key, "/") or object.size != 0) return error.DirectoryNotEmpty;
                },
                .delete_marker => if (all_versions and !std.mem.endsWith(u8, entry.key, "/")) {
                    return error.DirectoryNotEmpty;
                },
                .tombstone => {},
            }
        }
        var marker_position: usize = 0;
        while (marker_position < self.index.objectEntries().len) {
            const entry = self.index.objectEntries()[marker_position];
            if (std.mem.eql(u8, entry.bucket, bucket_name) and std.mem.startsWith(u8, entry.key, key) and std.mem.endsWith(u8, entry.key, "/")) {
                try self.removeObjectMarkerLocked(bucket_name, entry.key);
            } else marker_position += 1;
        }
        var position: usize = 0;
        while (position < self.index.directoryEntries().len) {
            const entry = self.index.directoryEntries()[position];
            if (!std.mem.eql(u8, entry.bucket, bucket_name) or !std.mem.startsWith(u8, entry.key, key) or (keep_root and std.mem.eql(u8, entry.key, key))) {
                position += 1;
                continue;
            }
            _ = self.directory_store.tombstone(self.allocator, bucket_name, entry.key, entry.generation) catch |err| return mapStoreError(err);
            if (!self.index.removeDirectory(bucket_name, entry.key)) return error.CorruptMetadata;
        }
    }

    /// Called while the application state mutex is held by an object commit.
    /// Parent directories are created as independent metadata records.
    pub fn ensureParentsLocked(self: DirectoryService, bucket_name: []const u8, object_key: []const u8, now: i64) Error!void {
        const parents = directory_domain.parentKeys(self.allocator, object_key) catch return error.OutOfMemory;
        defer {
            for (parents) |parent| self.allocator.free(parent);
            self.allocator.free(parents);
        }
        for (parents) |parent| {
            if (self.index.directoryGeneration(bucket_name, parent) != null) continue;
            var prepared = self.index.prepareDirectory(bucket_name, parent) catch |err| return mapIndexError(err);
            defer prepared.deinit(self.index.allocator);
            const generation = self.directory_store.put(self.allocator, bucket_name, parent, now, now, .missing) catch |err| return mapStoreError(err);
            self.index.publishDirectory(&prepared, generation, now);
        }
    }

    fn verifyBucketLocked(self: DirectoryService, name: []const u8) Error!void {
        const indexed = self.index.bucketGeneration(name) orelse return error.BucketNotFound;
        const record = self.bucket_store.get(self.allocator, name) catch |err| return switch (err) {
            error.NotFound => error.CorruptMetadata,
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata,
            error.Conflict, error.Unavailable => error.Unavailable,
        };
        defer record.deinit(self.allocator);
        switch (record) {
            .active => |bucket| if (bucket.generation != indexed) return error.CorruptMetadata,
            .tombstone => return error.CorruptMetadata,
        }
    }

    fn removeObjectMarkerLocked(self: DirectoryService, bucket_name: []const u8, key: []const u8) Error!void {
        const generation = self.index.objectGeneration(bucket_name, key) orelse return;
        const record = self.object_store.get(self.allocator, bucket_name, key) catch |err| return mapObjectError(err);
        defer record.deinit(self.allocator);
        switch (record) {
            .active => |object| if (object.size != 0) return error.Conflict,
            .delete_marker, .tombstone => {},
        }
        _ = self.object_store.tombstone(self.allocator, bucket_name, key, generation) catch |err| return mapObjectError(err);
        if (!self.index.removeObject(bucket_name, key)) return error.CorruptMetadata;
    }
};

fn mapIndexError(err: index_module.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptRecord => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapStoreError(err: directory_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.DirectoryNotFound,
        error.Conflict => error.Conflict,
        error.InvalidValue => error.InvalidDirectoryKey,
        error.CorruptMetadata => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}

fn mapObjectError(err: object_store_port.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CorruptMetadata, error.InvalidValue, error.NotFound, error.Conflict => error.CorruptMetadata,
        error.Unavailable => error.Unavailable,
    };
}
