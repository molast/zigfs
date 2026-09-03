const std = @import("std");
const bucket_domain = @import("bucket.zig");
const object_domain = @import("object.zig");
const id = @import("../common/id.zig");

pub const max_parts: u16 = 10_000;
pub const min_part_number: u16 = 1;
pub const min_nonfinal_part_size: u64 = 5 * 1024 * 1024;

pub const Status = enum(u8) {
    active = 1,
};

pub const PartStatus = enum(u8) {
    committed = 1,
};

pub const Part = struct {
    number: u16,
    size: u64,
    etag_md5: [16]u8,
    checksum_sha256: [32]u8,
    data_generation: id.Uuid,
    last_modified_unix_seconds: i64,
    status: PartStatus = .committed,
};

pub const View = struct {
    id: id.Uuid,
    bucket_id: id.Uuid,
    bucket_name: []const u8,
    key: []const u8,
    content_type: []const u8,
    user_metadata: []const object_domain.UserMetadata,
    initiated_at_unix_seconds: i64,
    parts: []const Part,
    status: Status = .active,
};

pub const Upload = struct {
    id: id.Uuid,
    bucket_id: id.Uuid,
    bucket_name: []u8,
    key: []u8,
    content_type: []u8,
    user_metadata: []object_domain.OwnedUserMetadata,
    initiated_at_unix_seconds: i64,
    parts: []Part,
    status: Status,
    metadata_generation: u64,

    pub fn deinit(self: Upload, allocator: std.mem.Allocator) void {
        allocator.free(self.bucket_name);
        allocator.free(self.key);
        allocator.free(self.content_type);
        for (self.user_metadata) |entry| entry.deinit(allocator);
        allocator.free(self.user_metadata);
        allocator.free(self.parts);
    }

    pub fn view(self: *const Upload) View {
        return .{
            .id = self.id,
            .bucket_id = self.bucket_id,
            .bucket_name = self.bucket_name,
            .key = self.key,
            .content_type = self.content_type,
            .user_metadata = @ptrCast(self.user_metadata),
            .initiated_at_unix_seconds = self.initiated_at_unix_seconds,
            .parts = self.parts,
            .status = self.status,
        };
    }
};

pub const ValidationError = bucket_domain.ValidationError || object_domain.ValidationError || error{
    InvalidUploadId,
    InvalidBucketId,
    InvalidInitiatedAt,
    TooManyParts,
    InvalidPartNumber,
    InvalidPartGeneration,
    InvalidPartOrder,
    InvalidPartStatus,
};

pub fn validateView(value: View) ValidationError!void {
    if (!id.isValidV4(value.id)) return error.InvalidUploadId;
    if (!id.isValidV4(value.bucket_id)) return error.InvalidBucketId;
    if (value.initiated_at_unix_seconds <= 0) return error.InvalidInitiatedAt;
    try bucket_domain.validateName(value.bucket_name);
    try object_domain.validateKey(value.key);
    try object_domain.validateContentType(value.content_type);
    try object_domain.validateUserMetadata(value.user_metadata);
    if (value.parts.len > max_parts) return error.TooManyParts;
    var previous: u16 = 0;
    for (value.parts) |part| {
        if (part.number < min_part_number or part.number > max_parts) {
            return error.InvalidPartNumber;
        }
        if (part.number <= previous) return error.InvalidPartOrder;
        if (!id.isValidV4(part.data_generation)) return error.InvalidPartGeneration;
        if (part.last_modified_unix_seconds <= 0) return error.InvalidInitiatedAt;
        if (part.status != .committed) return error.InvalidPartStatus;
        previous = part.number;
    }
}

pub fn cloneFromView(
    allocator: std.mem.Allocator,
    source: View,
    metadata_generation: u64,
) std.mem.Allocator.Error!Upload {
    const bucket_name = try allocator.dupe(u8, source.bucket_name);
    errdefer allocator.free(bucket_name);
    const key = try allocator.dupe(u8, source.key);
    errdefer allocator.free(key);
    const content_type = try allocator.dupe(u8, source.content_type);
    errdefer allocator.free(content_type);
    const metadata = try allocator.alloc(object_domain.OwnedUserMetadata, source.user_metadata.len);
    var initialized: usize = 0;
    errdefer {
        for (metadata[0..initialized]) |entry| entry.deinit(allocator);
        allocator.free(metadata);
    }
    for (source.user_metadata, 0..) |entry, index| {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value);
        metadata[index] = .{ .name = name, .value = value };
        initialized += 1;
    }
    const parts = try allocator.dupe(Part, source.parts);
    return .{
        .id = source.id,
        .bucket_id = source.bucket_id,
        .bucket_name = bucket_name,
        .key = key,
        .content_type = content_type,
        .user_metadata = metadata,
        .initiated_at_unix_seconds = source.initiated_at_unix_seconds,
        .parts = parts,
        .status = source.status,
        .metadata_generation = metadata_generation,
    };
}

pub fn formatUploadId(upload_id: id.Uuid, buffer: *[32]u8) []const u8 {
    buffer.* = std.fmt.bytesToHex(upload_id, .lower);
    return buffer;
}

pub fn parseUploadId(value: []const u8) ?id.Uuid {
    if (value.len != 32) return null;
    var parsed: id.Uuid = undefined;
    _ = std.fmt.hexToBytes(&parsed, value) catch return null;
    if (!id.isValidV4(parsed)) return null;
    return parsed;
}

test "multipart upload validates sorted committed parts and opaque IDs" {
    const upload_id: id.Uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 };
    var encoded: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &upload_id, &parseUploadId(formatUploadId(upload_id, &encoded)).?);
    try validateView(.{
        .id = upload_id,
        .bucket_id = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = "project-assets",
        .key = "large/archive.bin",
        .content_type = "application/octet-stream",
        .user_metadata = &.{},
        .initiated_at_unix_seconds = 1_800_000_000,
        .parts = &.{},
    });
    try std.testing.expect(parseUploadId("../../not-an-upload-id") == null);
}
