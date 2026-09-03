const std = @import("std");
const id = @import("../common/id.zig");

pub const max_key_length: usize = 1024;
pub const max_content_type_length: usize = 1024;
pub const max_user_metadata_entries: usize = 64;
pub const max_user_metadata_name_length: usize = 128;
pub const max_user_metadata_value_length: usize = 2048;
pub const max_user_metadata_bytes: usize = 8 * 1024;
pub const max_multipart_parts: u16 = 10_000;

pub const Status = enum(u8) {
    active = 1,
};

pub const UserMetadata = struct {
    name: []const u8,
    value: []const u8,
};

pub const OwnedUserMetadata = struct {
    name: []u8,
    value: []u8,

    pub fn deinit(self: OwnedUserMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const View = struct {
    id: id.Uuid,
    bucket_id: id.Uuid,
    bucket_name: []const u8,
    key: []const u8,
    size: u64,
    etag_md5: [16]u8,
    etag_part_count: u16 = 0,
    checksum_sha256: [32]u8,
    content_type: []const u8,
    last_modified_unix_seconds: i64,
    user_metadata: []const UserMetadata,
    data_generation: id.Uuid,
    status: Status,
};

pub const Object = struct {
    id: id.Uuid,
    bucket_id: id.Uuid,
    bucket_name: []u8,
    key: []u8,
    size: u64,
    etag_md5: [16]u8,
    etag_part_count: u16 = 0,
    checksum_sha256: [32]u8,
    content_type: []u8,
    last_modified_unix_seconds: i64,
    user_metadata: []OwnedUserMetadata,
    data_generation: id.Uuid,
    status: Status,
    metadata_generation: u64,

    pub fn deinit(self: Object, allocator: std.mem.Allocator) void {
        allocator.free(self.bucket_name);
        allocator.free(self.key);
        allocator.free(self.content_type);
        for (self.user_metadata) |entry| entry.deinit(allocator);
        allocator.free(self.user_metadata);
    }

    pub fn view(self: *const Object) View {
        return .{
            .id = self.id,
            .bucket_id = self.bucket_id,
            .bucket_name = self.bucket_name,
            .key = self.key,
            .size = self.size,
            .etag_md5 = self.etag_md5,
            .etag_part_count = self.etag_part_count,
            .checksum_sha256 = self.checksum_sha256,
            .content_type = self.content_type,
            .last_modified_unix_seconds = self.last_modified_unix_seconds,
            .user_metadata = ownedMetadataViews(self.user_metadata),
            .data_generation = self.data_generation,
            .status = self.status,
        };
    }
};

pub fn cloneFromView(
    allocator: std.mem.Allocator,
    source: View,
    metadata_generation: u64,
) std.mem.Allocator.Error!Object {
    const bucket_name = try allocator.dupe(u8, source.bucket_name);
    errdefer allocator.free(bucket_name);
    const key = try allocator.dupe(u8, source.key);
    errdefer allocator.free(key);
    const content_type = try allocator.dupe(u8, source.content_type);
    errdefer allocator.free(content_type);
    const metadata = try allocator.alloc(OwnedUserMetadata, source.user_metadata.len);
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
    return .{
        .id = source.id,
        .bucket_id = source.bucket_id,
        .bucket_name = bucket_name,
        .key = key,
        .size = source.size,
        .etag_md5 = source.etag_md5,
        .etag_part_count = source.etag_part_count,
        .checksum_sha256 = source.checksum_sha256,
        .content_type = content_type,
        .last_modified_unix_seconds = source.last_modified_unix_seconds,
        .user_metadata = metadata,
        .data_generation = source.data_generation,
        .status = source.status,
        .metadata_generation = metadata_generation,
    };
}

fn ownedMetadataViews(entries: []const OwnedUserMetadata) []const UserMetadata {
    return @ptrCast(entries);
}

pub const ValidationError = error{
    InvalidKeyLength,
    KeyContainsNull,
    InvalidContentType,
    TooManyUserMetadataEntries,
    InvalidUserMetadataName,
    InvalidUserMetadataValue,
    DuplicateUserMetadataName,
    UserMetadataTooLarge,
};

pub fn validateKey(key: []const u8) ValidationError!void {
    if (key.len == 0 or key.len > max_key_length) return error.InvalidKeyLength;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.KeyContainsNull;
}

pub fn validateContentType(content_type: []const u8) ValidationError!void {
    if (content_type.len == 0 or content_type.len > max_content_type_length) {
        return error.InvalidContentType;
    }
    for (content_type) |character| {
        if (character < 0x20 or character > 0x7e) return error.InvalidContentType;
    }
}

pub fn validateUserMetadata(entries: []const UserMetadata) ValidationError!void {
    if (entries.len > max_user_metadata_entries) {
        return error.TooManyUserMetadataEntries;
    }
    var total_length: usize = 0;
    for (entries, 0..) |entry, index| {
        if (entry.name.len == 0 or entry.name.len > max_user_metadata_name_length) {
            return error.InvalidUserMetadataName;
        }
        for (entry.name) |character| {
            if (!std.ascii.isLower(character) and
                !std.ascii.isDigit(character) and
                character != '-')
            {
                return error.InvalidUserMetadataName;
            }
        }
        if (entry.value.len > max_user_metadata_value_length or
            std.mem.indexOfAny(u8, entry.value, "\x00\r\n") != null)
        {
            return error.InvalidUserMetadataValue;
        }
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, entry.name)) {
                return error.DuplicateUserMetadataName;
            }
        }
        total_length = std.math.add(usize, total_length, entry.name.len) catch {
            return error.UserMetadataTooLarge;
        };
        total_length = std.math.add(usize, total_length, entry.value.len) catch {
            return error.UserMetadataTooLarge;
        };
        if (total_length > max_user_metadata_bytes) return error.UserMetadataTooLarge;
    }
}

test "object key preserves S3 key bytes without treating them as paths" {
    try validateKey("images/2026/cover.png");
    try validateKey("../../etc/passwd");
    try validateKey(&([_]u8{'k'} ** max_key_length));
    try std.testing.expectError(error.InvalidKeyLength, validateKey(""));
    try std.testing.expectError(
        error.InvalidKeyLength,
        validateKey(&([_]u8{'k'} ** (max_key_length + 1))),
    );
    try std.testing.expectError(error.KeyContainsNull, validateKey("a\x00b"));
}

test "content type and user metadata validation is bounded and canonical" {
    try validateContentType("application/octet-stream");
    try std.testing.expectError(error.InvalidContentType, validateContentType(""));
    try std.testing.expectError(error.InvalidContentType, validateContentType("text/plain\r\n"));

    const valid = [_]UserMetadata{
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "client-id", .value = "mobile" },
    };
    try validateUserMetadata(&valid);
    try std.testing.expectError(
        error.InvalidUserMetadataName,
        validateUserMetadata(&.{.{ .name = "Client-ID", .value = "mobile" }}),
    );
    try std.testing.expectError(
        error.InvalidUserMetadataValue,
        validateUserMetadata(&.{.{ .name = "client-id", .value = "bad\nvalue" }}),
    );
    try std.testing.expectError(
        error.DuplicateUserMetadataName,
        validateUserMetadata(&.{
            .{ .name = "client-id", .value = "one" },
            .{ .name = "client-id", .value = "two" },
        }),
    );
}
