const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const id = @import("../common/id.zig");

pub const magic = [4]u8{ 'Z', 'F', 'B', 'K' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 1;
pub const legacy_header_length: usize = 40;
pub const header_length: usize = 48;

const flags_offset: usize = 8;
const status_offset: usize = 10;
const versioning_offset: usize = 11;
const bucket_id_offset: usize = 12;
const created_at_offset: usize = 28;
const name_length_offset: usize = 36;
const owner_length_offset: usize = 38;
const lifecycle_length_offset: usize = 40;
const reserved_offset: usize = 44;

pub const Value = struct {
    id: id.Uuid,
    name: []const u8,
    owner: []const u8,
    status: bucket_domain.Status,
    versioning: bucket_domain.Versioning = .unversioned,
    lifecycle_configuration: ?[]const u8 = null,
    created_at_unix_seconds: i64,
};

pub const EncodeError = std.mem.Allocator.Error ||
    bucket_domain.ValidationError ||
    bucket_domain.OwnerValidationError ||
    error{ InvalidBucketId, InvalidCreatedAt, PayloadTooLarge };

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnsupportedMajorVersion,
    UnsupportedMinorVersion,
    UnsupportedFlags,
    InvalidStatus,
    InvalidBucketId,
    InvalidCreatedAt,
    InvalidName,
    InvalidOwner,
};

pub fn encode(
    allocator: std.mem.Allocator,
    value: Value,
) EncodeError![]u8 {
    try bucket_domain.validateName(value.name);
    try bucket_domain.validateOwner(value.owner);
    if (!id.isValidV4(value.id)) return error.InvalidBucketId;
    if (value.created_at_unix_seconds <= 0) return error.InvalidCreatedAt;

    const lifecycle = value.lifecycle_configuration orelse "";
    if (lifecycle.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
    const names_length = std.math.add(usize, value.name.len, value.owner.len) catch {
        return error.PayloadTooLarge;
    };
    const fields_length = std.math.add(usize, names_length, lifecycle.len) catch {
        return error.PayloadTooLarge;
    };
    const total_length = std.math.add(usize, header_length, fields_length) catch {
        return error.PayloadTooLarge;
    };
    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u16, bytes[flags_offset..status_offset], 0, .little);
    bytes[status_offset] = @intFromEnum(value.status);
    bytes[versioning_offset] = @intFromEnum(value.versioning);
    @memcpy(bytes[bucket_id_offset..created_at_offset], &value.id);
    std.mem.writeInt(
        i64,
        bytes[created_at_offset..name_length_offset],
        value.created_at_unix_seconds,
        .little,
    );
    std.mem.writeInt(u16, bytes[name_length_offset..owner_length_offset], @intCast(value.name.len), .little);
    std.mem.writeInt(u16, bytes[owner_length_offset..lifecycle_length_offset], @intCast(value.owner.len), .little);
    std.mem.writeInt(u32, bytes[lifecycle_length_offset..reserved_offset], @intCast(lifecycle.len), .little);
    std.mem.writeInt(u32, bytes[reserved_offset..header_length], 0, .little);
    var offset = header_length;
    @memcpy(bytes[offset .. offset + value.name.len], value.name);
    offset += value.name.len;
    @memcpy(bytes[offset .. offset + value.owner.len], value.owner);
    offset += value.owner.len;
    @memcpy(bytes[offset..], lifecycle);
    return bytes;
}

pub fn decode(bytes: []const u8) DecodeError!Value {
    if (bytes.len < legacy_header_length) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version) {
        return error.UnsupportedMajorVersion;
    }
    const encoded_minor_version = std.mem.readInt(u16, bytes[6..8], .little);
    if (encoded_minor_version > minor_version) {
        return error.UnsupportedMinorVersion;
    }
    const encoded_header_length = if (encoded_minor_version == 0) legacy_header_length else header_length;
    if (bytes.len < encoded_header_length) return error.InvalidLength;
    if (std.mem.readInt(u16, bytes[flags_offset..status_offset], .little) != 0 or
        (encoded_minor_version == 0 and bytes[versioning_offset] != 0) or
        (encoded_minor_version != 0 and std.mem.readInt(u32, bytes[reserved_offset..header_length], .little) != 0))
    {
        return error.UnsupportedFlags;
    }
    const status: bucket_domain.Status = switch (bytes[status_offset]) {
        1 => .active,
        else => return error.InvalidStatus,
    };
    const versioning: bucket_domain.Versioning = if (encoded_minor_version == 0)
        .unversioned
    else switch (bytes[versioning_offset]) {
        0 => .unversioned,
        1 => .enabled,
        2 => .suspended,
        else => return error.UnsupportedFlags,
    };
    var bucket_id: id.Uuid = undefined;
    @memcpy(&bucket_id, bytes[bucket_id_offset..created_at_offset]);
    if (!id.isValidV4(bucket_id)) return error.InvalidBucketId;

    const created_at_unix_seconds = std.mem.readInt(
        i64,
        bytes[created_at_offset..name_length_offset],
        .little,
    );
    if (created_at_unix_seconds <= 0) return error.InvalidCreatedAt;
    const name_length = std.mem.readInt(
        u16,
        bytes[name_length_offset..owner_length_offset],
        .little,
    );
    const owner_length = std.mem.readInt(
        u16,
        bytes[owner_length_offset..legacy_header_length],
        .little,
    );
    const lifecycle_length: u32 = if (encoded_minor_version == 0)
        0
    else
        std.mem.readInt(u32, bytes[lifecycle_length_offset..reserved_offset], .little);
    const names_length = std.math.add(usize, name_length, owner_length) catch {
        return error.InvalidLength;
    };
    const fields_length = std.math.add(usize, names_length, lifecycle_length) catch {
        return error.InvalidLength;
    };
    const expected_length = std.math.add(usize, encoded_header_length, fields_length) catch {
        return error.InvalidLength;
    };
    if (bytes.len != expected_length) return error.InvalidLength;
    const name = bytes[encoded_header_length .. encoded_header_length + name_length];
    const owner = bytes[encoded_header_length + name_length .. encoded_header_length + names_length];
    const lifecycle = bytes[encoded_header_length + names_length ..];
    bucket_domain.validateName(name) catch return error.InvalidName;
    bucket_domain.validateOwner(owner) catch return error.InvalidOwner;
    return .{
        .id = bucket_id,
        .name = name,
        .owner = owner,
        .status = status,
        .versioning = versioning,
        .lifecycle_configuration = if (lifecycle.len == 0) null else lifecycle,
        .created_at_unix_seconds = created_at_unix_seconds,
    };
}

test "bucket payload round trips all required metadata" {
    const value: Value = .{
        .id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .name = "project-assets",
        .owner = "root",
        .status = .active,
        .created_at_unix_seconds = 1_800_000_000,
    };
    const encoded = try encode(std.testing.allocator, value);
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(encoded);
    try std.testing.expectEqualSlices(u8, &value.id, &decoded.id);
    try std.testing.expectEqualStrings(value.name, decoded.name);
    try std.testing.expectEqualStrings(value.owner, decoded.owner);
    try std.testing.expectEqual(value.status, decoded.status);
    try std.testing.expectEqual(value.created_at_unix_seconds, decoded.created_at_unix_seconds);
}

test "bucket payload rejects incompatible and malformed values" {
    const value: Value = .{
        .id = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .name = "project-assets",
        .owner = "root",
        .status = .active,
        .created_at_unix_seconds = 1_800_000_000,
    };
    const valid = try encode(std.testing.allocator, value);
    defer std.testing.allocator.free(valid);
    try std.testing.expectError(error.InvalidLength, decode(valid[0 .. valid.len - 1]));

    var changed = try std.testing.allocator.dupe(u8, valid);
    defer std.testing.allocator.free(changed);
    changed[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(changed));
    @memcpy(changed, valid);
    std.mem.writeInt(u16, changed[6..8], minor_version + 1, .little);
    try std.testing.expectError(error.UnsupportedMinorVersion, decode(changed));
    @memcpy(changed, valid);
    changed[status_offset] = 255;
    try std.testing.expectError(error.InvalidStatus, decode(changed));
    @memcpy(changed, valid);
    changed[flags_offset] = 1;
    try std.testing.expectError(error.UnsupportedFlags, decode(changed));
    @memcpy(changed, valid);
    changed[bucket_id_offset + 6] = 0;
    try std.testing.expectError(error.InvalidBucketId, decode(changed));
}
