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
        directory_domain.validate(bucket_name, key) catch |err| return switch (err) { error.InvalidBucketName => error.InvalidBucketName, error.InvalidDirectoryKey => error.InvalidDirectoryKey };
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
        directory_domain.validate(bucket_name, key) catch |err| return switch (err) { error.InvalidBucketName => error.InvalidBucketName, error.InvalidDirectoryKey => error.InvalidDirectoryKey };
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        try self.verifyBucketLocked(bucket_name);
        const generation = self.index.directoryGeneration(bucket_name, key) orelse return .{ .deleted = false };
        if (try self.hasChildrenLocked(bucket_name, key)) return error.DirectoryNotEmpty;
        try self.removeObjectMarkerLocked(bucket_name, key);
        _ = self.directory_store.tombstone(self.allocator, bucket_name, key, generation) catch |err| return mapStoreError(err);
        if (!self.index.removeDirectory(bucket_name, key)) return error.CorruptMetadata;
        return .{ .deleted = true };
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
        const record = self.bucket_store.get(self.allocator, name) catch |err| return switch (err) { error.NotFound => error.CorruptMetadata, error.OutOfMemory => error.OutOfMemory, error.InvalidValue, error.CorruptMetadata => error.CorruptMetadata, error.Conflict, error.Unavailable => error.Unavailable };
        defer record.deinit(self.allocator);
        switch (record) {
            .active => |bucket| if (bucket.generation != indexed) return error.CorruptMetadata,
            .tombstone => return error.CorruptMetadata,
        }
    }

    fn hasChildrenLocked(self: DirectoryService, bucket_name: []const u8, key: []const u8) Error!bool {
        for (self.index.directoryEntries()) |entry| {
            if (std.mem.eql(u8, entry.bucket, bucket_name) and entry.key.len > key.len and std.mem.startsWith(u8, entry.key, key)) return true;
        }
        for (self.index.objectEntries()) |entry| {
            if (!std.mem.eql(u8, entry.bucket, bucket_name) or entry.key.len <= key.len or !std.mem.startsWith(u8, entry.key, key)) continue;
            const record = self.object_store.get(self.allocator, bucket_name, entry.key) catch |err| return mapObjectError(err);
            defer record.deinit(self.allocator);
            if (record == .active) return true;
        }
        return false;
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
    return switch (err) { error.OutOfMemory => error.OutOfMemory, error.CorruptRecord => error.CorruptMetadata, error.Unavailable => error.Unavailable };
}

fn mapStoreError(err: directory_store_port.Error) Error {
    return switch (err) { error.OutOfMemory => error.OutOfMemory, error.NotFound => error.DirectoryNotFound, error.Conflict => error.Conflict, error.InvalidValue => error.InvalidDirectoryKey, error.CorruptMetadata => error.CorruptMetadata, error.Unavailable => error.Unavailable };
}

fn mapObjectError(err: object_store_port.Error) Error {
    return switch (err) { error.OutOfMemory => error.OutOfMemory, error.CorruptMetadata, error.InvalidValue, error.NotFound, error.Conflict => error.CorruptMetadata, error.Unavailable => error.Unavailable };
}
