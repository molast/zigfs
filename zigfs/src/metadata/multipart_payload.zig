const std = @import("std");
const multipart_domain = @import("../domain/multipart.zig");
const object_domain = @import("../domain/object.zig");
const id = @import("../common/id.zig");

pub const magic = [4]u8{ 'Z', 'F', 'M', 'P' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const header_length: usize = 72;
pub const part_record_length: usize = 84;

const flags_offset: usize = 8;
const status_offset: usize = 10;
const reserved_offset: usize = 11;
const upload_id_offset: usize = 12;
const bucket_id_offset: usize = 28;
const initiated_at_offset: usize = 44;
const bucket_name_length_offset: usize = 52;
const key_length_offset: usize = 54;
const content_type_length_offset: usize = 56;
const metadata_count_offset: usize = 58;
const metadata_length_offset: usize = 60;
const part_count_offset: usize = 64;
const header_reserved_offset: usize = 66;

pub const Value = multipart_domain.View;

pub const Decoded = struct {
    value: Value,
    metadata_storage: []object_domain.UserMetadata,
    part_storage: []multipart_domain.Part,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.metadata_storage);
        allocator.free(self.part_storage);
    }
};

pub const EncodeError = std.mem.Allocator.Error || multipart_domain.ValidationError || error{PayloadTooLarge};

pub const DecodeError = std.mem.Allocator.Error || error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    UnsupportedMinorVersion,
    UnsupportedFlags,
    InvalidStatus,
    InvalidUploadId,
    InvalidBucketId,
    InvalidInitiatedAt,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidContentType,
    InvalidUserMetadata,
    InvalidPart,
};

pub fn encode(allocator: std.mem.Allocator, value: Value) EncodeError![]u8 {
    try multipart_domain.validateView(value);
    var metadata_length: usize = 0;
    for (value.user_metadata) |entry| {
        metadata_length = std.math.add(usize, metadata_length, 6) catch return error.PayloadTooLarge;
        metadata_length = std.math.add(usize, metadata_length, entry.name.len) catch return error.PayloadTooLarge;
        metadata_length = std.math.add(usize, metadata_length, entry.value.len) catch return error.PayloadTooLarge;
    }
    const field_length = std.math.add(usize, value.bucket_name.len, value.key.len) catch return error.PayloadTooLarge;
    const text_length = std.math.add(usize, field_length, value.content_type.len) catch return error.PayloadTooLarge;
    const with_metadata = std.math.add(usize, text_length, metadata_length) catch return error.PayloadTooLarge;
    const parts_length = std.math.mul(usize, value.parts.len, part_record_length) catch return error.PayloadTooLarge;
    const variable_length = std.math.add(usize, with_metadata, parts_length) catch return error.PayloadTooLarge;
    const total_length = std.math.add(usize, header_length, variable_length) catch return error.PayloadTooLarge;

    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u16, bytes[flags_offset..status_offset], 0, .little);
    bytes[status_offset] = @intFromEnum(value.status);
    @memcpy(bytes[upload_id_offset..bucket_id_offset], &value.id);
    @memcpy(bytes[bucket_id_offset..initiated_at_offset], &value.bucket_id);
    std.mem.writeInt(i64, bytes[initiated_at_offset..bucket_name_length_offset], value.initiated_at_unix_seconds, .little);
    std.mem.writeInt(u16, bytes[bucket_name_length_offset..key_length_offset], @intCast(value.bucket_name.len), .little);
    std.mem.writeInt(u16, bytes[key_length_offset..content_type_length_offset], @intCast(value.key.len), .little);
    std.mem.writeInt(u16, bytes[content_type_length_offset..metadata_count_offset], @intCast(value.content_type.len), .little);
    std.mem.writeInt(u16, bytes[metadata_count_offset..metadata_length_offset], @intCast(value.user_metadata.len), .little);
    std.mem.writeInt(u32, bytes[metadata_length_offset..part_count_offset], @intCast(metadata_length), .little);
    std.mem.writeInt(u16, bytes[part_count_offset..header_reserved_offset], @intCast(value.parts.len), .little);

    var offset = header_length;
    copyField(bytes, &offset, value.bucket_name);
    copyField(bytes, &offset, value.key);
    copyField(bytes, &offset, value.content_type);
    for (value.user_metadata) |entry| {
        std.mem.writeInt(u16, bytes[offset..][0..2], @intCast(entry.name.len), .little);
        std.mem.writeInt(u32, bytes[offset + 2 ..][0..4], @intCast(entry.value.len), .little);
        offset += 6;
        copyField(bytes, &offset, entry.name);
        copyField(bytes, &offset, entry.value);
    }
    for (value.parts) |part| {
        std.mem.writeInt(u16, bytes[offset..][0..2], part.number, .little);
        bytes[offset + 2] = @intFromEnum(part.status);
        bytes[offset + 3] = 0;
        std.mem.writeInt(u64, bytes[offset + 4 ..][0..8], part.size, .little);
        @memcpy(bytes[offset + 12 ..][0..16], &part.etag_md5);
        @memcpy(bytes[offset + 28 ..][0..32], &part.checksum_sha256);
        @memcpy(bytes[offset + 60 ..][0..16], &part.data_generation);
        std.mem.writeInt(i64, bytes[offset + 76 ..][0..8], part.last_modified_unix_seconds, .little);
        offset += part_record_length;
    }
    std.debug.assert(offset == bytes.len);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < header_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) return error.UnsupportedMajorVersion;
    if (std.mem.readInt(u16, bytes[6..8], .little) != minor_version) return error.UnsupportedMinorVersion;
    if (std.mem.readInt(u16, bytes[flags_offset..status_offset], .little) != 0 or
        bytes[reserved_offset] != 0 or
        !allZero(bytes[header_reserved_offset..header_length]))
    {
        return error.UnsupportedFlags;
    }
    const status: multipart_domain.Status = switch (bytes[status_offset]) {
        1 => .active,
        else => return error.InvalidStatus,
    };
    var upload_id: id.Uuid = undefined;
    @memcpy(&upload_id, bytes[upload_id_offset..bucket_id_offset]);
    if (!id.isValidV4(upload_id)) return error.InvalidUploadId;
    var bucket_id: id.Uuid = undefined;
    @memcpy(&bucket_id, bytes[bucket_id_offset..initiated_at_offset]);
    if (!id.isValidV4(bucket_id)) return error.InvalidBucketId;
    const initiated_at = std.mem.readInt(i64, bytes[initiated_at_offset..bucket_name_length_offset], .little);
    if (initiated_at <= 0) return error.InvalidInitiatedAt;

    const bucket_name_length = std.mem.readInt(u16, bytes[bucket_name_length_offset..key_length_offset], .little);
    const key_length = std.mem.readInt(u16, bytes[key_length_offset..content_type_length_offset], .little);
    const content_type_length = std.mem.readInt(u16, bytes[content_type_length_offset..metadata_count_offset], .little);
    const metadata_count = std.mem.readInt(u16, bytes[metadata_count_offset..metadata_length_offset], .little);
    const metadata_length = std.mem.readInt(u32, bytes[metadata_length_offset..part_count_offset], .little);
    const part_count = std.mem.readInt(u16, bytes[part_count_offset..header_reserved_offset], .little);
    if (metadata_count > object_domain.max_user_metadata_entries or
        metadata_length > object_domain.max_user_metadata_bytes + object_domain.max_user_metadata_entries * 6 or
        part_count > multipart_domain.max_parts)
    {
        return error.InvalidLength;
    }
    const fixed_fields_length = std.math.add(usize, bucket_name_length, key_length) catch return error.InvalidLength;
    const text_length = std.math.add(usize, fixed_fields_length, content_type_length) catch return error.InvalidLength;
    const with_metadata = std.math.add(usize, text_length, metadata_length) catch return error.InvalidLength;
    const parts_length = std.math.mul(usize, part_count, part_record_length) catch return error.InvalidLength;
    const variable_length = std.math.add(usize, with_metadata, parts_length) catch return error.InvalidLength;
    const expected_length = std.math.add(usize, header_length, variable_length) catch return error.InvalidLength;
    if (expected_length != bytes.len) {
        return error.InvalidLength;
    }

    var offset = header_length;
    const bucket_name = takeField(bytes, &offset, bucket_name_length) orelse return error.InvalidLength;
    const key = takeField(bytes, &offset, key_length) orelse return error.InvalidLength;
    const content_type = takeField(bytes, &offset, content_type_length) orelse return error.InvalidLength;
    const metadata_end = std.math.add(usize, offset, metadata_length) catch return error.InvalidLength;
    const metadata = try allocator.alloc(object_domain.UserMetadata, metadata_count);
    errdefer allocator.free(metadata);
    for (metadata) |*entry| {
        if (metadata_end - offset < 6) return error.InvalidUserMetadata;
        const name_length = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const value_length = std.mem.readInt(u32, bytes[offset + 2 ..][0..4], .little);
        offset += 6;
        entry.name = takeField(bytes, &offset, name_length) orelse return error.InvalidUserMetadata;
        entry.value = takeField(bytes, &offset, value_length) orelse return error.InvalidUserMetadata;
    }
    if (offset != metadata_end) return error.InvalidUserMetadata;
    const parts = try allocator.alloc(multipart_domain.Part, part_count);
    errdefer allocator.free(parts);
    for (parts) |*part| {
        if (bytes.len - offset < part_record_length) return error.InvalidPart;
        part.number = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        part.status = switch (bytes[offset + 2]) {
            1 => .committed,
            else => return error.InvalidPart,
        };
        if (bytes[offset + 3] != 0) return error.InvalidPart;
        part.size = std.mem.readInt(u64, bytes[offset + 4 ..][0..8], .little);
        @memcpy(&part.etag_md5, bytes[offset + 12 ..][0..16]);
        @memcpy(&part.checksum_sha256, bytes[offset + 28 ..][0..32]);
        @memcpy(&part.data_generation, bytes[offset + 60 ..][0..16]);
        part.last_modified_unix_seconds = std.mem.readInt(i64, bytes[offset + 76 ..][0..8], .little);
        offset += part_record_length;
    }
    if (offset != bytes.len) return error.InvalidLength;
    const value: Value = .{
        .id = upload_id,
        .bucket_id = bucket_id,
        .bucket_name = bucket_name,
        .key = key,
        .content_type = content_type,
        .user_metadata = metadata,
        .initiated_at_unix_seconds = initiated_at,
        .parts = parts,
        .status = status,
    };
    multipart_domain.validateView(value) catch |err| return switch (err) {
        error.InvalidBucketId => error.InvalidBucketId,
        error.InvalidUploadId => error.InvalidUploadId,
        error.InvalidInitiatedAt => error.InvalidInitiatedAt,
        error.InvalidLength, error.InvalidCharacter, error.InvalidBoundary, error.AdjacentPeriods, error.IpAddress, error.ReservedPrefix, error.ReservedSuffix => error.InvalidBucketName,
        error.InvalidKeyLength, error.KeyContainsNull => error.InvalidObjectKey,
        error.InvalidContentType => error.InvalidContentType,
        error.TooManyUserMetadataEntries, error.InvalidUserMetadataName, error.InvalidUserMetadataValue, error.DuplicateUserMetadataName, error.UserMetadataTooLarge => error.InvalidUserMetadata,
        else => error.InvalidPart,
    };
    return .{ .value = value, .metadata_storage = metadata, .part_storage = parts };
}

fn copyField(bytes: []u8, offset: *usize, value: []const u8) void {
    @memcpy(bytes[offset.* .. offset.* + value.len], value);
    offset.* += value.len;
}

fn takeField(bytes: []const u8, offset: *usize, length: usize) ?[]const u8 {
    const end = std.math.add(usize, offset.*, length) catch return null;
    if (end > bytes.len) return null;
    const value = bytes[offset.*..end];
    offset.* = end;
    return value;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testValue() Value {
    return .{
        .id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_id = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = "project-assets",
        .key = "large/archive.bin",
        .content_type = "application/octet-stream",
        .user_metadata = &.{.{ .name = "client-id", .value = "mobile" }},
        .initiated_at_unix_seconds = 1_800_000_000,
        .parts = &.{.{
            .number = 1,
            .size = 11,
            .etag_md5 = .{1} ** 16,
            .checksum_sha256 = .{2} ** 32,
            .data_generation = .{ 2, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
            .last_modified_unix_seconds = 1_800_000_001,
        }},
    };
}

test "multipart payload round trips upload and committed parts" {
    const bytes = try encode(std.testing.allocator, testValue());
    defer std.testing.allocator.free(bytes);
    const decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("project-assets", decoded.value.bucket_name);
    try std.testing.expectEqualStrings("large/archive.bin", decoded.value.key);
    try std.testing.expectEqual(@as(usize, 1), decoded.value.parts.len);
    try std.testing.expectEqual(@as(u16, 1), decoded.value.parts[0].number);
    try std.testing.expectEqual(@as(u64, 11), decoded.value.parts[0].size);
}

test "multipart payload rejects corruption" {
    const bytes = try encode(std.testing.allocator, testValue());
    defer std.testing.allocator.free(bytes);
    var changed = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(changed);
    changed[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(std.testing.allocator, changed));
    @memcpy(changed, bytes);
    changed[header_reserved_offset] = 1;
    try std.testing.expectError(error.UnsupportedFlags, decode(std.testing.allocator, changed));
}
