const std = @import("std");
const multipart_domain = @import("../domain/multipart.zig");
const multipart_payload = @import("multipart_payload.zig");
const store_port = @import("../ports/multipart_store.zig");
const repository_port = @import("../ports/metadata_repository.zig");

pub const MetadataMultipartStore = struct {
    repository: repository_port.MetadataRepository,

    pub fn init(repository: repository_port.MetadataRepository) MetadataMultipartStore {
        return .{ .repository = repository };
    }

    pub fn interface(self: *MetadataMultipartStore) store_port.MultipartStore {
        return .{ .context = self, .vtable = &.{
            .get = getImpl,
            .put = putImpl,
            .tombstone = tombstoneImpl,
        } };
    }

    fn getImpl(context: *anyopaque, allocator: std.mem.Allocator, upload_id: []const u8) store_port.Error!store_port.Record {
        const self: *MetadataMultipartStore = @ptrCast(@alignCast(context));
        if (multipart_domain.parseUploadId(upload_id) == null) return error.InvalidValue;
        const record = self.repository.get(allocator, .multipart, upload_id) catch |err| return mapRepositoryError(err);
        defer record.deinit(allocator);
        if (record.tombstone) return .{ .tombstone = record.generation };
        const decoded = multipart_payload.decode(allocator, record.payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptMetadata,
        };
        defer decoded.deinit(allocator);
        var encoded: [32]u8 = undefined;
        if (!std.mem.eql(u8, multipart_domain.formatUploadId(decoded.value.id, &encoded), upload_id)) {
            return error.CorruptMetadata;
        }
        const owned = multipart_domain.cloneFromView(allocator, decoded.value, record.generation) catch return error.OutOfMemory;
        return .{ .active = owned };
    }

    fn putImpl(context: *anyopaque, allocator: std.mem.Allocator, value: multipart_domain.View, expected: store_port.ExpectedGeneration) store_port.Error!u64 {
        const self: *MetadataMultipartStore = @ptrCast(@alignCast(context));
        const payload = multipart_payload.encode(allocator, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
        defer allocator.free(payload);
        var upload_id: [32]u8 = undefined;
        return self.repository.put(
            allocator,
            .multipart,
            multipart_domain.formatUploadId(value.id, &upload_id),
            switch (expected) {
                .missing => .missing,
                .exact => |generation| .{ .exact = generation },
            },
            payload,
        ) catch |err| mapRepositoryError(err);
    }

    fn tombstoneImpl(context: *anyopaque, allocator: std.mem.Allocator, upload_id: []const u8, expected_generation: u64) store_port.Error!u64 {
        const self: *MetadataMultipartStore = @ptrCast(@alignCast(context));
        if (multipart_domain.parseUploadId(upload_id) == null) return error.InvalidValue;
        return self.repository.tombstone(allocator, .multipart, upload_id, .{ .exact = expected_generation }) catch |err| mapRepositoryError(err);
    }
};

fn mapRepositoryError(err: repository_port.Error) store_port.Error {
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
