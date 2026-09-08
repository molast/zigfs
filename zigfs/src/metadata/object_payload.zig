const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");
const id = @import("../common/id.zig");

pub const magic = [4]u8{ 'Z', 'F', 'O', 'B' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 2;
pub const legacy_header_length: usize = 136;
pub const etag_header_length: usize = 140;
pub const header_length: usize = 164;
pub const multipart_part_length: usize = 64;

const flags_offset: usize = 8;
const status_offset: usize = 10;
const reserved_offset: usize = 11;
const object_id_offset: usize = 12;
const bucket_id_offset: usize = 28;
const data_generation_offset: usize = 44;
const size_offset: usize = 60;
const modified_at_offset: usize = 68;
const etag_offset: usize = 76;
const checksum_offset: usize = 92;
const bucket_name_length_offset: usize = 124;
const key_length_offset: usize = 126;
const content_type_length_offset: usize = 128;
const metadata_count_offset: usize = 130;
const metadata_length_offset: usize = 132;
const etag_part_count_offset: usize = 136;
const layout_offset: usize = 140;
const layout_reserved_offset: usize = 141;
const manifest_count_offset: usize = 144;
const manifest_reserved_offset: usize = 146;
const upload_id_offset: usize = 148;

pub const Value = object_domain.View;

pub const Decoded = struct {
    value: Value,
    metadata_storage: []object_domain.UserMetadata,
    manifest_storage: []object_domain.MultipartPart,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.metadata_storage);
        allocator.free(self.manifest_storage);
    }
};

pub const EncodeError = std.mem.Allocator.Error ||
    bucket_domain.ValidationError ||
    object_domain.ValidationError ||
    error{ InvalidObjectId, InvalidBucketId, InvalidDataGeneration, InvalidModifiedAt, InvalidMultipartManifest, PayloadTooLarge };

pub const DecodeError = std.mem.Allocator.Error || error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    UnsupportedMinorVersion,
    UnsupportedFlags,
    InvalidStatus,
    InvalidObjectId,
    InvalidBucketId,
    InvalidDataGeneration,
    InvalidModifiedAt,
    InvalidMultipartManifest,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidContentType,
    InvalidUserMetadata,
};

pub fn encode(allocator: std.mem.Allocator, value: Value) EncodeError![]u8 {
    try validateValue(value);

    var metadata_length: usize = 0;
    for (value.user_metadata) |entry| {
        metadata_length = std.math.add(usize, metadata_length, 6) catch {
            return error.PayloadTooLarge;
        };
        metadata_length = std.math.add(usize, metadata_length, entry.name.len) catch {
            return error.PayloadTooLarge;
        };
        metadata_length = std.math.add(usize, metadata_length, entry.value.len) catch {
            return error.PayloadTooLarge;
        };
    }
    const fields_length = std.math.add(usize, value.bucket_name.len, value.key.len) catch {
        return error.PayloadTooLarge;
    };
    const with_content_type = std.math.add(usize, fields_length, value.content_type.len) catch {
        return error.PayloadTooLarge;
    };
    const variable_length = std.math.add(usize, with_content_type, metadata_length) catch {
        return error.PayloadTooLarge;
    };
    const manifest_part_count = if (value.multipart_manifest) |manifest| manifest.parts.len else 0;
    const manifest_length = std.math.mul(usize, manifest_part_count, multipart_part_length) catch {
        return error.PayloadTooLarge;
    };
    const payload_length = std.math.add(usize, variable_length, manifest_length) catch {
        return error.PayloadTooLarge;
    };
    const total_length = std.math.add(usize, header_length, payload_length) catch {
        return error.PayloadTooLarge;
    };
    if (metadata_length > std.math.maxInt(u32)) return error.PayloadTooLarge;

    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u16, bytes[flags_offset..status_offset], 0, .little);
    bytes[status_offset] = @intFromEnum(value.status);
    bytes[reserved_offset] = 0;
    @memcpy(bytes[object_id_offset..bucket_id_offset], &value.id);
    @memcpy(bytes[bucket_id_offset..data_generation_offset], &value.bucket_id);
    @memcpy(bytes[data_generation_offset..size_offset], &value.data_generation);
    std.mem.writeInt(u64, bytes[size_offset..modified_at_offset], value.size, .little);
    std.mem.writeInt(i64, bytes[modified_at_offset..etag_offset], value.last_modified_unix_seconds, .little);
    @memcpy(bytes[etag_offset..checksum_offset], &value.etag_md5);
    @memcpy(bytes[checksum_offset..bucket_name_length_offset], &value.checksum_sha256);
    std.mem.writeInt(u16, bytes[bucket_name_length_offset..key_length_offset], @intCast(value.bucket_name.len), .little);
    std.mem.writeInt(u16, bytes[key_length_offset..content_type_length_offset], @intCast(value.key.len), .little);
    std.mem.writeInt(u16, bytes[content_type_length_offset..metadata_count_offset], @intCast(value.content_type.len), .little);
    std.mem.writeInt(u16, bytes[metadata_count_offset..metadata_length_offset], @intCast(value.user_metadata.len), .little);
    std.mem.writeInt(u32, bytes[metadata_length_offset..etag_part_count_offset], @intCast(metadata_length), .little);
    std.mem.writeInt(u16, bytes[etag_part_count_offset .. etag_part_count_offset + 2], value.etag_part_count, .little);
    if (value.multipart_manifest) |manifest| {
        bytes[layout_offset] = 1;
        std.mem.writeInt(u16, bytes[manifest_count_offset..manifest_reserved_offset], @intCast(manifest.parts.len), .little);
        @memcpy(bytes[upload_id_offset..header_length], &manifest.upload_id);
    }

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
    if (value.multipart_manifest) |manifest| {
        for (manifest.parts) |part| {
            const encoded_part = bytes[offset..][0..multipart_part_length];
            std.mem.writeInt(u16, encoded_part[0..2], part.number, .little);
            std.mem.writeInt(u64, encoded_part[8..16], part.size, .little);
            @memcpy(encoded_part[16..48], &part.checksum_sha256);
            @memcpy(encoded_part[48..64], &part.data_generation);
            offset += multipart_part_length;
        }
    }
    std.debug.assert(offset == bytes.len);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < legacy_header_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    const encoded_minor_version = std.mem.readInt(u16, bytes[6..8], .little);
    if (encoded_minor_version > minor_version) {
        return error.UnsupportedMinorVersion;
    }
    const encoded_header_length = switch (encoded_minor_version) {
        0 => legacy_header_length,
        1 => etag_header_length,
        else => header_length,
    };
    if (bytes.len < encoded_header_length) return error.InvalidLength;
    if (std.mem.readInt(u16, bytes[flags_offset..status_offset], .little) != 0 or
        bytes[reserved_offset] != 0 or
        (encoded_minor_version >= 2 and
            (!allZero(bytes[layout_reserved_offset..manifest_count_offset]) or
                !allZero(bytes[manifest_reserved_offset..upload_id_offset]))))
    {
        return error.UnsupportedFlags;
    }
    const status: object_domain.Status = switch (bytes[status_offset]) {
        1 => .active,
        else => return error.InvalidStatus,
    };

    var object_id: id.Uuid = undefined;
    @memcpy(&object_id, bytes[object_id_offset..bucket_id_offset]);
    if (!id.isValidV4(object_id)) return error.InvalidObjectId;
    var bucket_id: id.Uuid = undefined;
    @memcpy(&bucket_id, bytes[bucket_id_offset..data_generation_offset]);
    if (!id.isValidV4(bucket_id)) return error.InvalidBucketId;
    var data_generation: id.Uuid = undefined;
    @memcpy(&data_generation, bytes[data_generation_offset..size_offset]);
    if (!id.isValidV4(data_generation)) return error.InvalidDataGeneration;

    const size = std.mem.readInt(u64, bytes[size_offset..modified_at_offset], .little);
    const modified_at = std.mem.readInt(i64, bytes[modified_at_offset..etag_offset], .little);
    if (modified_at <= 0) return error.InvalidModifiedAt;
    var etag_md5: [16]u8 = undefined;
    @memcpy(&etag_md5, bytes[etag_offset..checksum_offset]);
    var checksum_sha256: [32]u8 = undefined;
    @memcpy(&checksum_sha256, bytes[checksum_offset..bucket_name_length_offset]);
    const etag_part_count = if (encoded_minor_version == 0)
        0
    else
        std.mem.readInt(u16, bytes[etag_part_count_offset .. etag_part_count_offset + 2], .little);
    if (etag_part_count > object_domain.max_multipart_parts) return error.UnsupportedFlags;
    const layout = if (encoded_minor_version >= 2) bytes[layout_offset] else 0;
    if (layout > 1) return error.InvalidMultipartManifest;
    const manifest_count = if (encoded_minor_version >= 2)
        std.mem.readInt(u16, bytes[manifest_count_offset..manifest_reserved_offset], .little)
    else
        0;
    var upload_id: id.Uuid = .{0} ** 16;
    if (encoded_minor_version >= 2) @memcpy(&upload_id, bytes[upload_id_offset..header_length]);
    if ((layout == 0 and (manifest_count != 0 or !allZero(&upload_id))) or
        (layout == 1 and (manifest_count == 0 or manifest_count != etag_part_count or !id.isValidV4(upload_id))))
    {
        return error.InvalidMultipartManifest;
    }

    const bucket_name_length = std.mem.readInt(u16, bytes[bucket_name_length_offset..key_length_offset], .little);
    const key_length = std.mem.readInt(u16, bytes[key_length_offset..content_type_length_offset], .little);
    const content_type_length = std.mem.readInt(u16, bytes[content_type_length_offset..metadata_count_offset], .little);
    const metadata_count = std.mem.readInt(u16, bytes[metadata_count_offset..metadata_length_offset], .little);
    const metadata_length = std.mem.readInt(u32, bytes[metadata_length_offset..etag_part_count_offset], .little);
    if (metadata_count > object_domain.max_user_metadata_entries or
        metadata_length > object_domain.max_user_metadata_bytes +
            object_domain.max_user_metadata_entries * 6)
    {
        return error.InvalidUserMetadata;
    }
    const fixed_fields_length = std.math.add(usize, bucket_name_length, key_length) catch {
        return error.InvalidLength;
    };
    const fields_length = std.math.add(usize, fixed_fields_length, content_type_length) catch {
        return error.InvalidLength;
    };
    const variable_length = std.math.add(usize, fields_length, metadata_length) catch {
        return error.InvalidLength;
    };
    const manifest_length = std.math.mul(usize, manifest_count, multipart_part_length) catch {
        return error.InvalidLength;
    };
    const payload_length = std.math.add(usize, variable_length, manifest_length) catch {
        return error.InvalidLength;
    };
    const expected_length = std.math.add(usize, encoded_header_length, payload_length) catch {
        return error.InvalidLength;
    };
    if (bytes.len != expected_length) return error.InvalidLength;

    var offset = encoded_header_length;
    const bucket_name = takeField(bytes, &offset, bucket_name_length) orelse return error.InvalidLength;
    const key = takeField(bytes, &offset, key_length) orelse return error.InvalidLength;
    const content_type = takeField(bytes, &offset, content_type_length) orelse return error.InvalidLength;
    bucket_domain.validateName(bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(key) catch return error.InvalidObjectKey;
    object_domain.validateContentType(content_type) catch return error.InvalidContentType;

    const metadata_end = std.math.add(usize, offset, metadata_length) catch {
        return error.InvalidLength;
    };
    if (metadata_end > bytes.len) return error.InvalidLength;
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
    object_domain.validateUserMetadata(metadata) catch return error.InvalidUserMetadata;

    const manifest_parts = try allocator.alloc(object_domain.MultipartPart, manifest_count);
    errdefer allocator.free(manifest_parts);
    var total_size: u64 = 0;
    var previous_part_number: u16 = 0;
    for (manifest_parts) |*part| {
        const encoded_part = takeField(bytes, &offset, multipart_part_length) orelse return error.InvalidLength;
        if (!allZero(encoded_part[2..8])) return error.InvalidMultipartManifest;
        part.number = std.mem.readInt(u16, encoded_part[0..2], .little);
        part.size = std.mem.readInt(u64, encoded_part[8..16], .little);
        @memcpy(&part.checksum_sha256, encoded_part[16..48]);
        @memcpy(&part.data_generation, encoded_part[48..64]);
        if (part.number == 0 or part.number <= previous_part_number or !id.isValidV4(part.data_generation)) {
            return error.InvalidMultipartManifest;
        }
        total_size = std.math.add(u64, total_size, part.size) catch return error.InvalidMultipartManifest;
        previous_part_number = part.number;
    }
    if (offset != bytes.len or (layout == 1 and total_size != size)) return error.InvalidMultipartManifest;

    return .{
        .value = .{
            .id = object_id,
            .bucket_id = bucket_id,
            .bucket_name = bucket_name,
            .key = key,
            .size = size,
            .etag_md5 = etag_md5,
            .etag_part_count = etag_part_count,
            .checksum_sha256 = checksum_sha256,
            .content_type = content_type,
            .last_modified_unix_seconds = modified_at,
            .user_metadata = metadata,
            .data_generation = data_generation,
            .multipart_manifest = if (layout == 1) .{ .upload_id = upload_id, .parts = manifest_parts } else null,
            .status = status,
        },
        .metadata_storage = metadata,
        .manifest_storage = manifest_parts,
    };
}

fn validateValue(value: Value) EncodeError!void {
    if (!id.isValidV4(value.id)) return error.InvalidObjectId;
    if (!id.isValidV4(value.bucket_id)) return error.InvalidBucketId;
    if (!id.isValidV4(value.data_generation)) return error.InvalidDataGeneration;
    if (value.last_modified_unix_seconds <= 0) return error.InvalidModifiedAt;
    if (value.etag_part_count > object_domain.max_multipart_parts) return error.PayloadTooLarge;
    if (value.multipart_manifest) |manifest| {
        if (!id.isValidV4(manifest.upload_id) or manifest.parts.len == 0 or
            manifest.parts.len > object_domain.max_multipart_parts or
            manifest.parts.len != value.etag_part_count) return error.InvalidMultipartManifest;
        var total_size: u64 = 0;
        var previous_part_number: u16 = 0;
        for (manifest.parts) |part| {
            if (part.number == 0 or part.number <= previous_part_number or !id.isValidV4(part.data_generation)) {
                return error.InvalidMultipartManifest;
            }
            total_size = std.math.add(u64, total_size, part.size) catch return error.InvalidMultipartManifest;
            previous_part_number = part.number;
        }
        if (total_size != value.size) return error.InvalidMultipartManifest;
    }
    try bucket_domain.validateName(value.bucket_name);
    try object_domain.validateKey(value.key);
    try object_domain.validateContentType(value.content_type);
    try object_domain.validateUserMetadata(value.user_metadata);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
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

fn testValue() Value {
    return .{
        .id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_id = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = "project-assets",
        .key = "images/cover.png",
        .size = 1234,
        .etag_md5 = .{1} ** 16,
        .checksum_sha256 = .{2} ** 32,
        .content_type = "image/png",
        .last_modified_unix_seconds = 1_800_000_000,
        .user_metadata = &.{
            .{ .name = "client-id", .value = "mobile" },
            .{ .name = "trace", .value = "123" },
        },
        .data_generation = .{ 2, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .status = .active,
    };
}

test "object payload round trips required metadata" {
    const value = testValue();
    const bytes = try encode(std.testing.allocator, value);
    defer std.testing.allocator.free(bytes);
    const decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &value.id, &decoded.value.id);
    try std.testing.expectEqualSlices(u8, &value.bucket_id, &decoded.value.bucket_id);
    try std.testing.expectEqualStrings(value.bucket_name, decoded.value.bucket_name);
    try std.testing.expectEqualStrings(value.key, decoded.value.key);
    try std.testing.expectEqual(value.size, decoded.value.size);
    try std.testing.expectEqualSlices(u8, &value.etag_md5, &decoded.value.etag_md5);
    try std.testing.expectEqualSlices(u8, &value.checksum_sha256, &decoded.value.checksum_sha256);
    try std.testing.expectEqualStrings(value.content_type, decoded.value.content_type);
    try std.testing.expectEqual(value.last_modified_unix_seconds, decoded.value.last_modified_unix_seconds);
    try std.testing.expectEqual(@as(usize, 2), decoded.value.user_metadata.len);
    try std.testing.expectEqualStrings("mobile", decoded.value.user_metadata[0].value);
    try std.testing.expectEqualSlices(u8, &value.data_generation, &decoded.value.data_generation);
}

test "object payload rejects incompatible and malformed records" {
    const bytes = try encode(std.testing.allocator, testValue());
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(
        error.InvalidLength,
        decode(std.testing.allocator, bytes[0 .. bytes.len - 1]),
    );
    var changed = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(changed);
    changed[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(std.testing.allocator, changed));
    @memcpy(changed, bytes);
    std.mem.writeInt(u16, changed[6..8], minor_version + 1, .little);
    try std.testing.expectError(error.UnsupportedMinorVersion, decode(std.testing.allocator, changed));
    @memcpy(changed, bytes);
    changed[status_offset] = 255;
    try std.testing.expectError(error.InvalidStatus, decode(std.testing.allocator, changed));
    @memcpy(changed, bytes);
    changed[object_id_offset + 6] = 0;
    try std.testing.expectError(error.InvalidObjectId, decode(std.testing.allocator, changed));
}

test "object payload reads V1.0 records without multipart ETag fields" {
    const current = try encode(std.testing.allocator, testValue());
    defer std.testing.allocator.free(current);
    const legacy = try std.testing.allocator.alloc(u8, current.len - (header_length - legacy_header_length));
    defer std.testing.allocator.free(legacy);
    @memcpy(legacy[0..legacy_header_length], current[0..legacy_header_length]);
    std.mem.writeInt(u16, legacy[6..8], 0, .little);
    @memcpy(legacy[legacy_header_length..], current[header_length..]);
    const decoded = try decode(std.testing.allocator, legacy);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 0), decoded.value.etag_part_count);
    try std.testing.expectEqualStrings(testValue().key, decoded.value.key);
}
