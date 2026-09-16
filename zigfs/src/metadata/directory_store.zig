const std = @import("std");
const directory_domain = @import("../domain/directory.zig");
const directory_payload = @import("directory_payload.zig");
const directory_store_port = @import("../ports/directory_store.zig");
const object_key = @import("object_key.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const MetadataDirectoryStore = struct {
    repository: repository_port.MetadataRepository,

    pub fn init(repository: repository_port.MetadataRepository) MetadataDirectoryStore {
        return .{ .repository = repository };
    }

    pub fn interface(self: *MetadataDirectoryStore) directory_store_port.DirectoryStore {
        return .{ .context = self, .vtable = &.{ .get = getImpl, .put = putImpl, .tombstone = tombstoneImpl } };
    }

    fn getImpl(context: *anyopaque, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) directory_store_port.Error!directory_domain.Directory {
        const self: *MetadataDirectoryStore = @ptrCast(@alignCast(context));
        const repository_key = object_key.encode(allocator, bucket, key) catch return error.InvalidValue;
        defer allocator.free(repository_key);
        const record = self.repository.get(allocator, .directory, repository_key) catch |err| return mapRepositoryError(err);
        defer record.deinit(allocator);
        if (record.tombstone) return error.NotFound;
        const decoded = directory_payload.decode(record.payload) catch return error.CorruptMetadata;
        if (!std.mem.eql(u8, decoded.bucket_name, bucket) or !std.mem.eql(u8, decoded.key, key)) return error.CorruptMetadata;
        const owned_bucket = allocator.dupe(u8, decoded.bucket_name) catch return error.OutOfMemory;
        errdefer allocator.free(owned_bucket);
        const owned_key = allocator.dupe(u8, decoded.key) catch return error.OutOfMemory;
        return .{ .bucket_name = owned_bucket, .key = owned_key, .created_at_unix_seconds = decoded.created_at_unix_seconds, .last_modified_unix_seconds = decoded.last_modified_unix_seconds, .generation = record.generation };
    }

    fn putImpl(context: *anyopaque, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8, created_at: i64, modified_at: i64, expected: directory_store_port.ExpectedGeneration) directory_store_port.Error!u64 {
        const self: *MetadataDirectoryStore = @ptrCast(@alignCast(context));
        directory_domain.validate(bucket, key) catch return error.InvalidValue;
        const repository_key = object_key.encode(allocator, bucket, key) catch return error.InvalidValue;
        defer allocator.free(repository_key);
        const payload = directory_payload.encode(allocator, .{ .bucket_name = bucket, .key = key, .created_at_unix_seconds = created_at, .last_modified_unix_seconds = modified_at }) catch |err| switch (err) { error.OutOfMemory => return error.OutOfMemory, else => return error.InvalidValue };
        defer allocator.free(payload);
        const repository_expected: repository_port.ExpectedGeneration = switch (expected) {
            .missing => missing: {
                const current = self.repository.get(allocator, .directory, repository_key) catch |err| switch (err) {
                    error.NotFound => break :missing .missing,
                    else => return mapRepositoryError(err),
                };
                defer current.deinit(allocator);
                // A deleted directory is absent to callers, but its recovery
                // record must be replaced using the recorded generation.
                if (!current.tombstone) return error.Conflict;
                break :missing .{ .exact = current.generation };
            },
            .exact => |generation| .{ .exact = generation },
        };
        return self.repository.put(allocator, .directory, repository_key, repository_expected, payload) catch |err| mapRepositoryError(err);
    }

    fn tombstoneImpl(context: *anyopaque, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8, generation: u64) directory_store_port.Error!u64 {
        const self: *MetadataDirectoryStore = @ptrCast(@alignCast(context));
        const repository_key = object_key.encode(allocator, bucket, key) catch return error.InvalidValue;
        defer allocator.free(repository_key);
        return self.repository.tombstone(allocator, .directory, repository_key, .{ .exact = generation }) catch |err| mapRepositoryError(err);
    }
};

fn mapRepositoryError(err: repository_port.Error) directory_store_port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.NotFound,
        error.Conflict => error.Conflict,
        error.CorruptRecord, error.CorruptJournal => error.CorruptMetadata,
        else => error.Unavailable,
    };
}

test "directory store recreates tombstones with generation checks" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    var repository = MemoryMetadataRepository.init(std.testing.allocator);
    defer repository.deinit();
    var adapter = MetadataDirectoryStore.init(repository.interface());
    const store = adapter.interface();

    const first = try store.put(std.testing.allocator, "photos", "images/", 10, 10, .missing);
    try std.testing.expectError(error.Conflict, store.put(std.testing.allocator, "photos", "images/", 20, 20, .missing));
    const deleted = try store.tombstone(std.testing.allocator, "photos", "images/", first);
    try std.testing.expectError(error.NotFound, store.get(std.testing.allocator, "photos", "images/"));

    const recreated = try store.put(std.testing.allocator, "photos", "images/", 30, 30, .missing);
    try std.testing.expect(recreated > deleted);
    const directory = try store.get(std.testing.allocator, "photos", "images/");
    defer directory.deinit(std.testing.allocator);
    try std.testing.expectEqual(recreated, directory.generation);
    try std.testing.expectEqual(@as(i64, 30), directory.created_at_unix_seconds);
    try std.testing.expectError(error.Conflict, store.tombstone(std.testing.allocator, "photos", "images/", deleted));
}
