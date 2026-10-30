const std = @import("std");
const bucket_domain = @import("../domain/bucket.zig");
const object_domain = @import("../domain/object.zig");
const repository_payload = @import("repository_payload.zig");

pub const Parsed = struct {
    bucket: []const u8,
    key: []const u8,
};

pub fn encode(
    allocator: std.mem.Allocator,
    bucket: []const u8,
    key: []const u8,
) error{ OutOfMemory, InvalidKey }![]u8 {
    bucket_domain.validateName(bucket) catch return error.InvalidKey;
    object_domain.validateKey(key) catch return error.InvalidKey;
    const prefix_length = std.math.add(usize, bucket.len, 1) catch {
        return error.InvalidKey;
    };
    const combined_length = std.math.add(usize, prefix_length, key.len) catch {
        return error.InvalidKey;
    };
    if (combined_length > repository_payload.max_key_length) return error.InvalidKey;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ bucket, key }) catch {
        return error.OutOfMemory;
    };
}

pub fn parse(value: []const u8) ?Parsed {
    const separator = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    if (separator == 0 or separator + 1 >= value.len) return null;
    const parsed: Parsed = .{
        .bucket = value[0..separator],
        .key = value[separator + 1 ..],
    };
    bucket_domain.validateName(parsed.bucket) catch return null;
    object_domain.validateKey(parsed.key) catch return null;
    return parsed;
}

test "record key supports the full S3 object key length" {
    const key = @as([object_domain.max_key_length]u8, @splat('k'));
    const encoded = try encode(std.testing.allocator, "project-assets", &key);
    defer std.testing.allocator.free(encoded);
    const parsed = parse(encoded).?;
    try std.testing.expectEqualStrings("project-assets", parsed.bucket);
    try std.testing.expectEqualSlices(u8, &key, parsed.key);
}

test "record key preserves nested and traversal-like object keys" {
    const encoded = try encode(std.testing.allocator, "project-assets", "../../a/b.txt");
    defer std.testing.allocator.free(encoded);
    const parsed = parse(encoded).?;
    try std.testing.expectEqualStrings("project-assets", parsed.bucket);
    try std.testing.expectEqualStrings("../../a/b.txt", parsed.key);
}
