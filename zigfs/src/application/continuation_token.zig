const std = @import("std");

pub const magic = [4]u8{ 'Z', 'F', 'C', 'T' };
pub const major_version: u16 = 1;
pub const minor_version: u16 = 0;
pub const max_cursor_length: usize = 1024;

const header_length: usize = 46;
const checksum_length: usize = 32;
const max_raw_length: usize = header_length + max_cursor_length + checksum_length;
pub const max_encoded_length: usize = std.base64.url_safe_no_pad.Encoder.calcSize(max_raw_length);

pub const Context = struct {
    bucket: []const u8,
    prefix: []const u8,
    delimiter: ?[]const u8,
};

pub const Decoded = struct {
    cursor: []u8,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.cursor);
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidContext,
    InvalidCursor,
    InvalidToken,
};

pub fn encode(
    allocator: std.mem.Allocator,
    context: Context,
    cursor: []const u8,
) Error![]u8 {
    try validateContext(context);
    if (!validBoundedField(cursor, false)) return error.InvalidCursor;

    const raw_length = header_length + cursor.len + checksum_length;
    const raw = allocator.alloc(u8, raw_length) catch return error.OutOfMemory;
    defer allocator.free(raw);
    @memset(raw, 0);
    @memcpy(raw[0..magic.len], &magic);
    std.mem.writeInt(u16, raw[4..6], major_version, .little);
    std.mem.writeInt(u16, raw[6..8], minor_version, .little);
    std.mem.writeInt(u16, raw[8..10], 0, .little);
    std.mem.writeInt(u16, raw[10..12], 0, .little);
    const context_checksum = hashContext(context);
    @memcpy(raw[12..44], &context_checksum);
    std.mem.writeInt(u16, raw[44..46], @intCast(cursor.len), .little);
    @memcpy(raw[header_length .. header_length + cursor.len], cursor);
    const checksum_offset = raw.len - checksum_length;
    std.crypto.hash.sha2.Sha256.hash(raw[0..checksum_offset], raw[checksum_offset..][0..checksum_length], .{});

    const encoded_length = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    const encoded = allocator.alloc(u8, encoded_length) catch return error.OutOfMemory;
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw);
    return encoded;
}

pub fn decode(
    allocator: std.mem.Allocator,
    context: Context,
    token: []const u8,
) Error!Decoded {
    try validateContext(context);
    if (token.len == 0 or token.len > max_encoded_length) return error.InvalidToken;
    const raw_length = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(token) catch {
        return error.InvalidToken;
    };
    if (raw_length < header_length + 1 + checksum_length or raw_length > max_raw_length) {
        return error.InvalidToken;
    }
    const raw = allocator.alloc(u8, raw_length) catch return error.OutOfMemory;
    defer allocator.free(raw);
    std.base64.url_safe_no_pad.Decoder.decode(raw, token) catch return error.InvalidToken;

    if (!std.mem.eql(u8, raw[0..magic.len], &magic) or
        std.mem.readInt(u16, raw[4..6], .little) != major_version or
        std.mem.readInt(u16, raw[6..8], .little) != minor_version or
        std.mem.readInt(u16, raw[8..10], .little) != 0 or
        std.mem.readInt(u16, raw[10..12], .little) != 0)
    {
        return error.InvalidToken;
    }
    const cursor_length = std.mem.readInt(u16, raw[44..46], .little);
    if (cursor_length == 0 or cursor_length > max_cursor_length or
        raw.len != header_length + cursor_length + checksum_length)
    {
        return error.InvalidToken;
    }
    const checksum_offset = raw.len - checksum_length;
    var expected_checksum: [checksum_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw[0..checksum_offset], &expected_checksum, .{});
    var actual_checksum: [checksum_length]u8 = undefined;
    @memcpy(&actual_checksum, raw[checksum_offset..]);
    if (!std.crypto.timing_safe.eql([checksum_length]u8, expected_checksum, actual_checksum)) {
        return error.InvalidToken;
    }
    const expected_context = hashContext(context);
    var actual_context: [32]u8 = undefined;
    @memcpy(&actual_context, raw[12..44]);
    if (!std.crypto.timing_safe.eql([32]u8, expected_context, actual_context)) {
        return error.InvalidToken;
    }
    const cursor = raw[header_length..checksum_offset];
    if (!validBoundedField(cursor, false)) return error.InvalidToken;
    return .{ .cursor = allocator.dupe(u8, cursor) catch return error.OutOfMemory };
}

fn validateContext(context: Context) Error!void {
    if (context.bucket.len == 0 or context.bucket.len > 63 or
        !validBoundedField(context.prefix, true))
    {
        return error.InvalidContext;
    }
    if (context.delimiter) |delimiter| {
        if (!validBoundedField(delimiter, false)) return error.InvalidContext;
    }
}

fn validBoundedField(value: []const u8, allow_empty: bool) bool {
    return (allow_empty or value.len > 0) and
        value.len <= max_cursor_length and
        std.mem.indexOfScalar(u8, value, 0) == null;
}

fn hashContext(context: Context) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    updateHashField(&hash, context.bucket);
    updateHashField(&hash, context.prefix);
    if (context.delimiter) |delimiter| {
        hash.update(&.{1});
        updateHashField(&hash, delimiter);
    } else {
        hash.update(&.{0});
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn updateHashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hash.update(&length);
    hash.update(value);
}

test "continuation token round trips and binds the listing context" {
    const context: Context = .{
        .bucket = "project-assets",
        .prefix = "images/",
        .delimiter = "/",
    };
    const token = try encode(std.testing.allocator, context, "images/2026/z.png");
    defer std.testing.allocator.free(token);
    try std.testing.expect(std.mem.indexOfAny(u8, token, "/+=") == null);
    const decoded = try decode(std.testing.allocator, context, token);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("images/2026/z.png", decoded.cursor);
    try std.testing.expectError(error.InvalidToken, decode(std.testing.allocator, .{
        .bucket = "project-assets",
        .prefix = "videos/",
        .delimiter = "/",
    }, token));
}

test "continuation token rejects corruption and malformed input" {
    const context: Context = .{ .bucket = "project-assets", .prefix = "", .delimiter = null };
    const token = try encode(std.testing.allocator, context, "object.txt");
    defer std.testing.allocator.free(token);
    var changed = try std.testing.allocator.dupe(u8, token);
    defer std.testing.allocator.free(changed);
    changed[changed.len - 1] = if (changed[changed.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.InvalidToken, decode(std.testing.allocator, context, changed));
    try std.testing.expectError(error.InvalidToken, decode(std.testing.allocator, context, "%%%"));
    try std.testing.expectError(error.InvalidCursor, encode(std.testing.allocator, context, ""));
}
