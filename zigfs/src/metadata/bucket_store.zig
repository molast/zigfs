const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const bucket_payload = @import("bucket_payload.zig");
const bucket_store_port = @import("../ports/bucket_store.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const MetadataBucketStore = struct {
    repository: repository_port.MetadataRepository,

    pub fn init(repository: repository_port.MetadataRepository) MetadataBucketStore {
        return .{ .repository = repository };
    }

    pub fn interface(self: *MetadataBucketStore) bucket_store_port.BucketStore {
        return .{ .context = self, .vtable = &.{
            .get = getImpl,
            .put = putImpl,
            .tombstone = tombstoneImpl,
        } };
    }

    fn getImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) bucket_store_port.Error!bucket_store_port.Record {
        const self: *MetadataBucketStore = @ptrCast(@alignCast(context));
        const record = self.repository.get(allocator, .bucket, name) catch |err| {
            return mapRepositoryError(err);
        };
        defer record.deinit(allocator);
        if (record.tombstone) return .{ .tombstone = record.generation };

        const decoded = bucket_payload.decode(record.payload) catch {
            return error.CorruptMetadata;
        };
        if (!std.mem.eql(u8, decoded.name, record.key)) {
            return error.CorruptMetadata;
        }
        const owned_name = allocator.dupe(u8, decoded.name) catch return error.OutOfMemory;
        errdefer allocator.free(owned_name);
        const owned_owner = allocator.dupe(u8, decoded.owner) catch return error.OutOfMemory;
        errdefer allocator.free(owned_owner);
        const owned_lifecycle = if (decoded.lifecycle_configuration) |configuration|
            allocator.dupe(u8, configuration) catch return error.OutOfMemory
        else
            null;
        const owned_tags = if (decoded.tags_json) |tags|
            allocator.dupe(u8, tags) catch return error.OutOfMemory
        else
            null;
        return .{ .active = .{
            .id = decoded.id,
            .name = owned_name,
            .owner = owned_owner,
            .status = decoded.status,
            .versioning = decoded.versioning,
            .access_policy = decoded.access_policy,
            .block_public_access = decoded.block_public_access,
            .tags_json = owned_tags,
            .encryption = decoded.encryption,
            .kms_key_id = decoded.kms_key_id,
            .quota = decoded.quota,
            .retention = decoded.retention,
            .object_locking = decoded.object_locking,
            .lifecycle_configuration = owned_lifecycle,
            .created_at_unix_seconds = decoded.created_at_unix_seconds,
            .generation = record.generation,
        } };
    }

    fn putImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: bucket_store_port.Value,
        expected_generation: bucket_store_port.ExpectedGeneration,
    ) bucket_store_port.Error!u64 {
        const self: *MetadataBucketStore = @ptrCast(@alignCast(context));
        const payload = bucket_payload.encode(allocator, .{
            .id = value.id,
            .name = value.name,
            .owner = value.owner,
            .status = value.status,
            .versioning = value.versioning,
            .access_policy = value.access_policy,
            .block_public_access = value.block_public_access,
            .tags_json = value.tags_json,
            .encryption = value.encryption,
            .kms_key_id = value.kms_key_id,
            .quota = value.quota,
            .retention = value.retention,
            .object_locking = value.object_locking,
            .lifecycle_configuration = value.lifecycle_configuration,
            .created_at_unix_seconds = value.created_at_unix_seconds,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        defer allocator.free(payload);
        return self.repository.put(
            allocator,
            .bucket,
            value.name,
            mapExpectedGeneration(expected_generation),
            payload,
        ) catch |err| mapRepositoryError(err);
    }

    fn tombstoneImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
        expected_generation: u64,
    ) bucket_store_port.Error!u64 {
        const self: *MetadataBucketStore = @ptrCast(@alignCast(context));
        return self.repository.tombstone(
            allocator,
            .bucket,
            name,
            .{ .exact = expected_generation },
        ) catch |err| mapRepositoryError(err);
    }
};

fn mapExpectedGeneration(
    expected: bucket_store_port.ExpectedGeneration,
) repository_port.ExpectedGeneration {
    return switch (expected) {
        .missing => .missing,
        .exact => |generation| .{ .exact = generation },
    };
}

fn mapRepositoryError(err: repository_port.Error) bucket_store_port.Error {
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

test "metadata bucket store owns encoding tombstones and corruption checks" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = MetadataBucketStore.init(memory.interface());
    const store = adapter.interface();
    const value: bucket_store_port.Value = .{
        .id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .name = "project-assets",
        .owner = "owner-a",
        .status = .active,
        .created_at_unix_seconds = 1_800_000_000,
    };
    const generation = try store.put(std.testing.allocator, value, .missing);
    try std.testing.expectError(
        error.Conflict,
        store.put(std.testing.allocator, value, .missing),
    );
    const found = try store.get(std.testing.allocator, value.name);
    defer found.deinit(std.testing.allocator);
    switch (found) {
        .active => |bucket| {
            try std.testing.expectEqual(generation, bucket.generation);
            try std.testing.expectEqualStrings(value.owner, bucket.owner);
        },
        .tombstone => return error.TestUnexpectedResult,
    }

    const deleted_generation = try store.tombstone(
        std.testing.allocator,
        value.name,
        generation,
    );
    const deleted = try store.get(std.testing.allocator, value.name);
    switch (deleted) {
        .active => |bucket| {
            bucket.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
        .tombstone => |actual| try std.testing.expectEqual(deleted_generation, actual),
    }

    _ = try memory.interface().put(
        std.testing.allocator,
        .bucket,
        "corrupt-bucket",
        .missing,
        "corrupt",
    );
    try std.testing.expectError(
        error.CorruptMetadata,
        store.get(std.testing.allocator, "corrupt-bucket"),
    );
}
