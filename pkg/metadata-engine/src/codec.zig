const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");

pub const Limits = struct {
    pub const max_key_bytes = 2048;
    pub const max_frame_bytes = 64 * 1024 * 1024;
    pub const max_mutations = 4096;
};
pub const header_length = 64;
pub const checksum_length = 32;
const entry_header_length = 12;
const magic = "ZFMETAW1";

pub const Entry = struct {
    record_type: types.Type,
    record: repository.Record,
};

pub const Header = struct {
    length: u32,
    generation: u64,
    count: u32,
};

pub fn validKey(key: []const u8) bool {
    return key.len > 0 and key.len <= Limits.max_key_bytes and
        std.mem.indexOfScalar(u8, key, 0) == null;
}

/// One bounded frame is one atomic transaction. No partial frame is publishable.
pub fn encode(allocator: std.mem.Allocator, entries: []const Entry, generation: u64) ![]u8 {
    if (entries.len == 0 or entries.len > Limits.max_mutations) return error.PayloadTooLarge;
    var length: usize = header_length + checksum_length;
    for (entries) |entry| {
        const record = entry.record;
        if (!validKey(record.key)) return error.InvalidKey;
        if (record.tombstone and record.payload.len != 0) return error.CorruptRecord;
        if (record.payload.len > Limits.max_frame_bytes) return error.PayloadTooLarge;
        length += entry_header_length + record.key.len + record.payload.len;
        if (length > Limits.max_frame_bytes) return error.PayloadTooLarge;
    }
    const bytes = try allocator.alloc(u8, length);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], magic);
    std.mem.writeInt(u16, bytes[8..10], 1, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(length), .little);
    std.mem.writeInt(u64, bytes[16..24], generation, .little);
    std.mem.writeInt(u32, bytes[24..28], @intCast(entries.len), .little);
    std.crypto.hash.sha2.Sha256.hash(bytes[0..32], bytes[32..64], .{});
    var offset: usize = header_length;
    for (entries) |entry| {
        const record = entry.record;
        const header = bytes[offset..][0..entry_header_length];
        header[0] = @backingInt(entry.record_type);
        header[1] = @intFromBool(record.tombstone);
        std.mem.writeInt(u32, header[4..8], @intCast(record.key.len), .little);
        std.mem.writeInt(u32, header[8..12], @intCast(record.payload.len), .little);
        offset += entry_header_length;
        @memcpy(bytes[offset..][0..record.key.len], record.key);
        offset += record.key.len;
        @memcpy(bytes[offset..][0..record.payload.len], record.payload);
        offset += record.payload.len;
    }
    std.crypto.hash.sha2.Sha256.hash(bytes[0..offset], bytes[offset..][0..32], .{});
    return bytes;
}

pub fn decodeHeader(bytes: *const [header_length]u8) !Header {
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.CorruptRecord;
    if (std.mem.readInt(u16, bytes[8..10], .little) != 1) return error.UnsupportedFormat;
    if (std.mem.readInt(u16, bytes[10..12], .little) != 0 or
        std.mem.readInt(u32, bytes[28..32], .little) != 0) return error.CorruptRecord;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..32], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, bytes[32..64])) return error.CorruptRecord;
    const result: Header = .{
        .length = std.mem.readInt(u32, bytes[12..16], .little),
        .generation = std.mem.readInt(u64, bytes[16..24], .little),
        .count = std.mem.readInt(u32, bytes[24..28], .little),
    };
    if (result.length < header_length + checksum_length or
        result.length > Limits.max_frame_bytes or result.generation == 0 or
        result.count == 0 or result.count > Limits.max_mutations) return error.CorruptRecord;
    return result;
}

/// Views borrow frame bytes and cannot be freed as owned repository records.
pub const View = struct {
    record_type: types.Type,
    key: []const u8,
    payload: []const u8,
    generation: u64,
    tombstone: bool,
};

pub const ViewDecoder = struct {
    entries: std.ArrayList(View) = .empty,

    pub fn deinit(self: *ViewDecoder, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Result expires on the next decode or when the input frame is reused.
    pub fn decode(self: *ViewDecoder, allocator: std.mem.Allocator, bytes: []const u8) ![]const View {
        if (bytes.len < header_length) return error.CorruptRecord;
        const header = try decodeHeader(bytes[0..header_length]);
        if (bytes.len != header.length) return error.CorruptRecord;
        const end = bytes.len - checksum_length;
        var checksum: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..end], &checksum, .{});
        if (!std.mem.eql(u8, &checksum, bytes[end..])) return error.CorruptRecord;
        self.entries.clearRetainingCapacity();
        errdefer self.entries.clearRetainingCapacity();
        var offset: usize = header_length;
        for (0..header.count) |_| {
            if (end - offset < entry_header_length) return error.CorruptRecord;
            const item = bytes[offset..][0..entry_header_length];
            const record_type = std.enums.fromInt(types.Type, item[0]) orelse return error.CorruptRecord;
            if (item[1] > 1 or item[2] != 0 or item[3] != 0) return error.CorruptRecord;
            const key_length = std.mem.readInt(u32, item[4..8], .little);
            const payload_length = std.mem.readInt(u32, item[8..12], .little);
            offset += entry_header_length;
            if (key_length > end - offset) return error.CorruptRecord;
            const key = bytes[offset..][0..key_length];
            if (!validKey(key)) return error.CorruptRecord;
            offset += key_length;
            if (payload_length > end - offset or (item[1] == 1 and payload_length != 0))
                return error.CorruptRecord;
            // Duplicate logical keys make publication order ambiguous: reject the frame.
            for (self.entries.items) |previous| {
                if (previous.record_type == record_type and std.mem.eql(u8, previous.key, key))
                    return error.CorruptRecord;
            }
            try self.entries.append(allocator, .{
                .record_type = record_type,
                .key = key,
                .payload = bytes[offset..][0..payload_length],
                .generation = header.generation,
                .tombstone = item[1] == 1,
            });
            offset += payload_length;
        }
        if (offset != end) return error.CorruptRecord;
        return self.entries.items;
    }
};

/// Returned records own their keys and payloads; free with freeEntries.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Entry {
    var decoder: ViewDecoder = .{};
    defer decoder.deinit(allocator);
    const views = try decoder.decode(allocator, bytes);
    const entries = try allocator.alloc(Entry, views.len);
    var copied: usize = 0;
    errdefer {
        for (entries[0..copied]) |entry| entry.record.deinit(allocator);
        allocator.free(entries);
    }
    for (views, entries) |view, *entry| {
        const key = try allocator.dupe(u8, view.key);
        errdefer allocator.free(key);
        entry.* = .{ .record_type = view.record_type, .record = .{
            .key = key,
            .payload = try allocator.dupe(u8, view.payload),
            .generation = view.generation,
            .tombstone = view.tombstone,
        } };
        copied += 1;
    }
    return entries;
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |entry| entry.record.deinit(allocator);
    allocator.free(entries);
}
