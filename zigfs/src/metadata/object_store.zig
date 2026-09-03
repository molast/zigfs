const std = @import("std");
const object_domain = @import("../domain/object.zig");
const object_key = @import("object_key.zig");
const object_payload = @import("object_payload.zig");
const object_store_port = @import("../ports/object_store.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const MetadataObjectStore = struct {
    repository: repository_port.MetadataRepository,

    pub fn init(repository: repository_port.MetadataRepository) MetadataObjectStore {
        return .{ .repository = repository };
    }

    pub fn interface(self: *MetadataObjectStore) object_store_port.ObjectStore {
        return .{ .context = self, .vtable = &.{
            .get = getImpl,
            .put = putImpl,
            .tombstone = tombstoneImpl,
        } };
    }

    fn getImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        bucket: []const u8,
        key: []const u8,
    ) object_store_port.Error!object_store_port.Record {
        const self: *MetadataObjectStore = @ptrCast(@alignCast(context));
        const repository_key = object_key.encode(allocator, bucket, key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidKey => return error.InvalidValue,
        };
        defer allocator.free(repository_key);
        const record = self.repository.get(allocator, .object, repository_key) catch |err| {
            return mapRepositoryError(err);
        };
        defer record.deinit(allocator);
        if (record.tombstone) return .{ .tombstone = record.generation };

        const decoded = object_payload.decode(allocator, record.payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptMetadata,
        };
        defer decoded.deinit(allocator);
        if (!std.mem.eql(u8, decoded.value.bucket_name, bucket) or
            !std.mem.eql(u8, decoded.value.key, key))
        {
            return error.CorruptMetadata;
        }
        const owned = object_domain.cloneFromView(
            allocator,
            decoded.value,
            record.generation,
        ) catch return error.OutOfMemory;
        return .{ .active = owned };
    }

    fn putImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: object_store_port.Value,
        expected_generation: object_store_port.ExpectedGeneration,
    ) object_store_port.Error!u64 {
        const self: *MetadataObjectStore = @ptrCast(@alignCast(context));
        const repository_key = object_key.encode(
            allocator,
            value.bucket_name,
            value.key,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidKey => return error.InvalidValue,
        };
        defer allocator.free(repository_key);
        const payload = object_payload.encode(allocator, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        defer allocator.free(payload);
        return self.repository.put(
            allocator,
            .object,
            repository_key,
            mapExpectedGeneration(expected_generation),
            payload,
        ) catch |err| mapRepositoryError(err);
    }

    fn tombstoneImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        bucket: []const u8,
        key: []const u8,
        expected_generation: u64,
    ) object_store_port.Error!u64 {
        const self: *MetadataObjectStore = @ptrCast(@alignCast(context));
        const repository_key = object_key.encode(allocator, bucket, key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidKey => return error.InvalidValue,
        };
        defer allocator.free(repository_key);
        return self.repository.tombstone(
            allocator,
            .object,
            repository_key,
            .{ .exact = expected_generation },
        ) catch |err| mapRepositoryError(err);
    }
};

fn mapExpectedGeneration(
    expected: object_store_port.ExpectedGeneration,
) repository_port.ExpectedGeneration {
    return switch (expected) {
        .missing => .missing,
        .exact => |generation| .{ .exact = generation },
    };
}

fn mapRepositoryError(err: repository_port.Error) object_store_port.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.NotFound,
        error.Conflict => error.Conflict,
        error.CorruptRecord, error.CorruptJournal => error.CorruptMetadata,
        error.InvalidKey,
        error.PayloadTooLarge,
        error.GenerationExhausted,
        error.Unavailable,
        => error.Unavailable,
    };
}

fn testValue() object_store_port.Value {
    return .{
        .id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_id = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = "project-assets",
        .key = "images/cover.png",
        .size = 6,
        .etag_md5 = .{1} ** 16,
        .checksum_sha256 = .{2} ** 32,
        .content_type = "image/png",
        .last_modified_unix_seconds = 1_800_000_000,
        .user_metadata = &.{.{ .name = "client-id", .value = "mobile" }},
        .data_generation = .{ 2, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .status = .active,
    };
}

test "metadata object store owns encoding CAS tombstones and corruption checks" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = MetadataObjectStore.init(memory.interface());
    const store = adapter.interface();
    const value = testValue();
    const generation = try store.put(std.testing.allocator, value, .missing);
    try std.testing.expectError(
        error.Conflict,
        store.put(std.testing.allocator, value, .missing),
    );
    const found = try store.get(std.testing.allocator, value.bucket_name, value.key);
    defer found.deinit(std.testing.allocator);
    switch (found) {
        .active => |object| {
            try std.testing.expectEqual(generation, object.metadata_generation);
            try std.testing.expectEqualStrings(value.content_type, object.content_type);
            try std.testing.expectEqualStrings("mobile", object.user_metadata[0].value);
        },
        .tombstone => return error.TestUnexpectedResult,
    }
    const deleted_generation = try store.tombstone(
        std.testing.allocator,
        value.bucket_name,
        value.key,
        generation,
    );
    const deleted = try store.get(std.testing.allocator, value.bucket_name, value.key);
    switch (deleted) {
        .active => |object| {
            object.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
        .tombstone => |actual| try std.testing.expectEqual(deleted_generation, actual),
    }

    const corrupt_key = try object_key.encode(
        std.testing.allocator,
        "project-assets",
        "corrupt.txt",
    );
    defer std.testing.allocator.free(corrupt_key);
    _ = try memory.interface().put(
        std.testing.allocator,
        .object,
        corrupt_key,
        .missing,
        "corrupt",
    );
    try std.testing.expectError(
        error.CorruptMetadata,
        store.get(std.testing.allocator, "project-assets", "corrupt.txt"),
    );
}
