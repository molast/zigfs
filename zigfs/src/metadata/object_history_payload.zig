const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");
const object_payload = @import("object_payload.zig");
const id = @import("../common/id.zig");

pub const magic = [4]u8{ 'Z', 'F', 'O', 'H' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const header_length: usize = 24;
pub const entry_header_length: usize = 32;
pub const max_entries: usize = 100_000;

const flags_offset: usize = 8;
const entry_count_offset: usize = 12;
const bucket_length_offset: usize = 16;
const key_length_offset: usize = 18;
const reserved_offset: usize = 20;

pub const Error = std.mem.Allocator.Error || error{
    InvalidLength,
    InvalidMagic,
    UnsupportedVersion,
    UnsupportedFlags,
    InvalidBucketName,
    InvalidObjectKey,
    InvalidVersionId,
    InvalidTimestamp,
    InvalidEntry,
    TooManyEntries,
    PayloadTooLarge,
};

pub fn isHistory(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], &magic);
}

pub fn encode(
    allocator: std.mem.Allocator,
    history: *const object_domain.History,
) Error![]u8 {
    bucket_domain.validateName(history.bucket_name) catch return error.InvalidBucketName;
    object_domain.validateKey(history.key) catch return error.InvalidObjectKey;
    if (history.entries.len == 0 or history.entries.len > max_entries) return error.TooManyEntries;

    const encoded_objects = try allocator.alloc(?[]u8, history.entries.len);
    defer allocator.free(encoded_objects);
    @memset(encoded_objects, null);
    defer for (encoded_objects) |payload| if (payload) |bytes| allocator.free(bytes);

    var total_length = std.math.add(usize, header_length, history.bucket_name.len) catch return error.PayloadTooLarge;
    total_length = std.math.add(usize, total_length, history.key.len) catch return error.PayloadTooLarge;
    for (history.entries, 0..) |entry, index| {
        total_length = std.math.add(usize, total_length, entry_header_length) catch return error.PayloadTooLarge;
        switch (entry) {
            .object => |object| {
                if (!std.mem.eql(u8, object.bucket_name, history.bucket_name) or
                    !std.mem.eql(u8, object.key, history.key)) return error.InvalidEntry;
                const payload = object_payload.encode(allocator, object.view()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidEntry,
                };
                encoded_objects[index] = payload;
                if (payload.len > std.math.maxInt(u32)) return error.PayloadTooLarge;
                total_length = std.math.add(usize, total_length, payload.len) catch return error.PayloadTooLarge;
            },
            .delete_marker => |marker| {
                if (!std.mem.eql(u8, marker.bucket_name, history.bucket_name) or
                    !std.mem.eql(u8, marker.key, history.key)) return error.InvalidEntry;
                if (marker.last_modified_unix_seconds <= 0) return error.InvalidTimestamp;
            },
        }
    }

    const bytes = try allocator.alloc(u8, total_length);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    std.mem.writeInt(u16, bytes[4..6], major_version, .little);
    std.mem.writeInt(u16, bytes[6..8], minor_version, .little);
    std.mem.writeInt(u32, bytes[flags_offset..entry_count_offset], 0, .little);
    std.mem.writeInt(u32, bytes[entry_count_offset..bucket_length_offset], @intCast(history.entries.len), .little);
    std.mem.writeInt(u16, bytes[bucket_length_offset..key_length_offset], @intCast(history.bucket_name.len), .little);
    std.mem.writeInt(u16, bytes[key_length_offset..reserved_offset], @intCast(history.key.len), .little);
    std.mem.writeInt(u32, bytes[reserved_offset..header_length], 0, .little);

    var offset = header_length;
    copyField(bytes, &offset, history.bucket_name);
    copyField(bytes, &offset, history.key);
    for (history.entries, 0..) |entry, index| {
        const header = bytes[offset..][0..entry_header_length];
        const version_id = entry.versionId();
        header[0] = switch (entry) {
            .object => 1,
            .delete_marker => 2,
        };
        header[1] = switch (version_id) {
            .null_version => 0,
            .uuid => 1,
        };
        std.mem.writeInt(i64, header[4..12], entry.modifiedAt(), .little);
        const payload = encoded_objects[index] orelse "";
        std.mem.writeInt(u32, header[12..16], @intCast(payload.len), .little);
        switch (version_id) {
            .null_version => {},
            .uuid => |value| @memcpy(header[16..32], &value),
        }
        offset += entry_header_length;
        copyField(bytes, &offset, payload);
    }
    std.debug.assert(offset == bytes.len);
    return bytes;
}

pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    metadata_generation: u64,
) Error!object_domain.History {
    if (bytes.len < header_length) return error.InvalidLength;
    if (!isHistory(bytes)) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != major_version or
        std.mem.readInt(u16, bytes[6..8], .little) != minor_version) return error.UnsupportedVersion;
    if (std.mem.readInt(u32, bytes[flags_offset..entry_count_offset], .little) != 0 or
        std.mem.readInt(u32, bytes[reserved_offset..header_length], .little) != 0) return error.UnsupportedFlags;
    const entry_count = std.mem.readInt(u32, bytes[entry_count_offset..bucket_length_offset], .little);
    if (entry_count == 0 or entry_count > max_entries) return error.TooManyEntries;
    const bucket_length = std.mem.readInt(u16, bytes[bucket_length_offset..key_length_offset], .little);
    const key_length = std.mem.readInt(u16, bytes[key_length_offset..reserved_offset], .little);
    var offset: usize = header_length;
    const bucket_view = takeField(bytes, &offset, bucket_length) orelse return error.InvalidLength;
    const key_view = takeField(bytes, &offset, key_length) orelse return error.InvalidLength;
    bucket_domain.validateName(bucket_view) catch return error.InvalidBucketName;
    object_domain.validateKey(key_view) catch return error.InvalidObjectKey;

    const bucket = try allocator.dupe(u8, bucket_view);
    errdefer allocator.free(bucket);
    const key = try allocator.dupe(u8, key_view);
    errdefer allocator.free(key);
    const entries = try allocator.alloc(object_domain.VersionEntry, entry_count);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    while (initialized < entries.len) : (initialized += 1) {
        const header = takeField(bytes, &offset, entry_header_length) orelse return error.InvalidLength;
        if (header[2] != 0 or header[3] != 0) return error.UnsupportedFlags;
        const modified_at = std.mem.readInt(i64, header[4..12], .little);
        if (modified_at <= 0) return error.InvalidTimestamp;
        const payload_length = std.mem.readInt(u32, header[12..16], .little);
        const version_id: object_domain.VersionId = switch (header[1]) {
            0 => .null_version,
            1 => version: {
                var value: id.Uuid = undefined;
                @memcpy(&value, header[16..32]);
                if (!id.isValidV4(value)) return error.InvalidVersionId;
                break :version .{ .uuid = value };
            },
            else => return error.InvalidVersionId,
        };
        const payload = takeField(bytes, &offset, payload_length) orelse return error.InvalidLength;
        entries[initialized] = switch (header[0]) {
            1 => object: {
                if (payload.len == 0) return error.InvalidEntry;
                const decoded = object_payload.decode(allocator, payload) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidEntry,
                };
                defer decoded.deinit(allocator);
                if (!std.mem.eql(u8, decoded.value.bucket_name, bucket_view) or
                    !std.mem.eql(u8, decoded.value.key, key_view) or
                    decoded.value.last_modified_unix_seconds != modified_at) return error.InvalidEntry;
                var view = decoded.value;
                view.version_id = version_id;
                break :object .{ .object = object_domain.cloneFromView(allocator, view, metadata_generation) catch return error.OutOfMemory };
            },
            2 => marker: {
                if (payload.len != 0) return error.InvalidEntry;
                const marker_bucket = try allocator.dupe(u8, bucket_view);
                errdefer allocator.free(marker_bucket);
                break :marker .{ .delete_marker = .{
                    .bucket_name = marker_bucket,
                    .key = try allocator.dupe(u8, key_view),
                    .version_id = version_id,
                    .last_modified_unix_seconds = modified_at,
                } };
            },
            else => return error.InvalidEntry,
        };
    }
    if (offset != bytes.len) return error.InvalidLength;
    return .{
        .bucket_name = bucket,
        .key = key,
        .entries = entries,
        .metadata_generation = metadata_generation,
    };
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

test "object history payload round trips versions and delete markers" {
    const allocator = std.testing.allocator;
    const bucket = try allocator.dupe(u8, "project-assets");
    const key = try allocator.dupe(u8, "notes.txt");
    const entries = try allocator.alloc(object_domain.VersionEntry, 2);
    entries[0] = .{ .delete_marker = .{
        .bucket_name = try allocator.dupe(u8, bucket),
        .key = try allocator.dupe(u8, key),
        .version_id = .{ .uuid = .{ 0, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 } },
        .last_modified_unix_seconds = 1_800_000_001,
    } };
    entries[1] = .{ .object = try object_domain.cloneFromView(allocator, .{
        .id = .{ 1, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_id = .{ 2, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .bucket_name = bucket,
        .key = key,
        .size = 5,
        .etag_md5 = @as([16]u8, @splat(1)),
        .checksum_sha256 = @as([32]u8, @splat(2)),
        .content_type = "text/plain",
        .last_modified_unix_seconds = 1_800_000_000,
        .user_metadata = &.{},
        .data_generation = .{ 3, 1, 2, 3, 4, 5, 0x46, 7, 0x88, 9, 10, 11, 12, 13, 14, 15 },
        .status = .active,
        .version_id = .null_version,
    }, 7) };
    const history: object_domain.History = .{ .bucket_name = bucket, .key = key, .entries = entries, .metadata_generation = 7 };
    defer history.deinit(allocator);
    const encoded = try encode(allocator, &history);
    defer allocator.free(encoded);
    const decoded = try decode(allocator, encoded, 11);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expect(decoded.entries[0] == .delete_marker);
    try std.testing.expect(decoded.entries[1] == .object);
    try std.testing.expectEqual(@as(u64, 11), decoded.entries[1].object.metadata_generation);
}
