const std = @import("std");
const credential_domain = @import("../domain/credential.zig");
const credential_payload = @import("credential_payload.zig");
const credential_store_port = @import("../ports/credential_store.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const MetadataCredentialStore = struct {
    repository: repository_port.MetadataRepository,

    pub fn init(repository: repository_port.MetadataRepository) MetadataCredentialStore {
        return .{ .repository = repository };
    }

    pub fn interface(self: *MetadataCredentialStore) credential_store_port.CredentialStore {
        return .{ .context = self, .vtable = &.{
            .get = getImpl,
            .put = putImpl,
            .tombstone = tombstoneImpl,
        } };
    }

    fn getImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        access_key: []const u8,
    ) credential_store_port.Error!credential_store_port.Record {
        const self: *MetadataCredentialStore = @ptrCast(@alignCast(context));
        credential_domain.validateAccessKey(access_key) catch return error.InvalidValue;
        const record = self.repository.get(allocator, .credential, access_key) catch |err| {
            return mapRepositoryError(err);
        };
        defer record.deinit(allocator);
        if (record.tombstone) return .{ .tombstone = record.generation };
        const decoded = credential_payload.decode(record.payload) catch {
            return error.CorruptMetadata;
        };
        if (!std.mem.eql(u8, decoded.access_key, record.key)) {
            return error.CorruptMetadata;
        }
        const owned = credential_domain.cloneFromView(
            allocator,
            decoded,
            record.generation,
        ) catch return error.OutOfMemory;
        return .{ .active = owned };
    }

    fn putImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: credential_domain.View,
        expected_generation: credential_store_port.ExpectedGeneration,
    ) credential_store_port.Error!u64 {
        const self: *MetadataCredentialStore = @ptrCast(@alignCast(context));
        const payload = credential_payload.encode(allocator, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        defer allocator.free(payload);
        return self.repository.put(
            allocator,
            .credential,
            value.access_key,
            switch (expected_generation) {
                .missing => .missing,
                .exact => |generation| .{ .exact = generation },
            },
            payload,
        ) catch |err| mapRepositoryError(err);
    }

    fn tombstoneImpl(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        access_key: []const u8,
        expected_generation: u64,
    ) credential_store_port.Error!u64 {
        const self: *MetadataCredentialStore = @ptrCast(@alignCast(context));
        credential_domain.validateAccessKey(access_key) catch return error.InvalidValue;
        return self.repository.tombstone(
            allocator,
            .credential,
            access_key,
            .{ .exact = expected_generation },
        ) catch |err| mapRepositoryError(err);
    }
};

fn mapRepositoryError(err: repository_port.Error) credential_store_port.Error {
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

test "metadata credential store persists encrypted payload with CAS" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var adapter = MetadataCredentialStore.init(memory.interface());
    const store = adapter.interface();
    const value: credential_domain.View = .{
        .access_key = "ZF0123456789ABCDEF",
        .owner = "tenant-a",
        .status = .active,
        .policy = .all,
        .created_at_unix_seconds = 1_800_000_000,
        .secret_nonce = @as([12]u8, @splat(1)),
        .secret_tag = @as([16]u8, @splat(2)),
        .encrypted_secret = "0123456789abcdef0123456789abcdef01234567",
    };
    const generation = try store.put(std.testing.allocator, value, .missing);
    try std.testing.expectError(error.Conflict, store.put(std.testing.allocator, value, .missing));
    const record = try store.get(std.testing.allocator, value.access_key);
    defer record.deinit(std.testing.allocator);
    switch (record) {
        .active => |credential| {
            try std.testing.expectEqual(generation, credential.metadata_generation);
            try std.testing.expectEqualStrings(value.encrypted_secret, credential.encrypted_secret);
        },
        .tombstone => return error.TestUnexpectedResult,
    }
    _ = try store.tombstone(std.testing.allocator, value.access_key, generation);
}
