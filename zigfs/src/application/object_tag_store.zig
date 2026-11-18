const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const std = @import("std");
pub const Tag = struct { key: []const u8, value: []const u8 };
pub const Record = struct { version: u32 = 1, tags: []const Tag = &.{} };
pub fn filenameFor(a: std.mem.Allocator, bucket: []const u8, object: []const u8, version: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bucket);
    hasher.update(&[1]u8{0});
    hasher.update(object);
    hasher.update(&[1]u8{0});
    hasher.update(version);
    hasher.final(&digest);
    return std.fmt.allocPrint(a, "{s}.json", .{std.fmt.bytesToHex(digest, .lower)});
}
fn key(a: std.mem.Allocator, bucket: []const u8, object: []const u8, version: []const u8) ![]u8 {
    const filename = try filenameFor(a, bucket, object, version);
    defer a.free(filename);
    return std.fmt.allocPrint(a, "system/object-tags/{s}", .{filename});
}
pub fn load(a: std.mem.Allocator, root: SystemStore, io: std.Io, bucket: []const u8, object: []const u8, version: []const u8) !Record {
    _ = io;
    const path = try key(a, bucket, object, version);
    defer a.free(path);
    const bytes = root.read(a, path, 128 * 1024) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Record, a, bytes, .{ .allocate = .alloc_always });
    validateRecord(parsed.value) catch {
        parsed.deinit();
        return error.InvalidTag;
    };
    return parsed.value;
}
fn validateRecord(record: Record) !void {
    if (record.version != 1 or record.tags.len > 10) return error.InvalidTag;
    for (record.tags, 0..) |tag, i| {
        if (tag.key.len == 0 or tag.key.len > 128 or tag.value.len > 256 or !std.unicode.utf8ValidateSlice(tag.key) or !std.unicode.utf8ValidateSlice(tag.value)) return error.InvalidTag;
        for (record.tags[0..i]) |previous| if (std.mem.eql(u8, previous.key, tag.key)) return error.InvalidTag;
    }
}
pub fn save(a: std.mem.Allocator, root: SystemStore, io: std.Io, bucket: []const u8, object: []const u8, version: []const u8, record: Record) !void {
    _ = io;
    if (record.tags.len > 10) return error.TooManyTags;
    for (record.tags, 0..) |tag, i| {
        if (tag.key.len == 0 or tag.key.len > 128 or tag.value.len > 256 or !std.unicode.utf8ValidateSlice(tag.key) or !std.unicode.utf8ValidateSlice(tag.value)) return error.InvalidTag;
        for (record.tags[0..i]) |previous| if (std.mem.eql(u8, previous.key, tag.key)) return error.DuplicateTag;
    }
    const path = try key(a, bucket, object, version);
    defer a.free(path);
    const bytes = try std.json.Stringify.valueAlloc(a, record, .{});
    defer a.free(bytes);
    try root.put(a, path, bytes);
}
pub fn remove(a: std.mem.Allocator, root: SystemStore, io: std.Io, bucket: []const u8, object: []const u8, version: []const u8) !void {
    _ = io;
    const path = try key(a, bucket, object, version);
    defer a.free(path);
    try root.remove(a, path);
}

/// Validate stored tags before advertising readiness.
pub fn validateAll(a: std.mem.Allocator, root: SystemStore, io: std.Io) !usize {
    _ = io;
    const records = try root.scanNamespace(a, .object_tag);
    defer records.deinit(a);
    var count: usize = 0;
    for (records.records) |record| {
        if (record.tombstone or !std.mem.startsWith(u8, record.key, "system/object-tags/")) continue;
        const parsed = try std.json.parseFromSlice(Record, a, record.payload, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try validateRecord(parsed.value);
        count += 1;
    }
    return count;
}

/// Caller holds object locks and owns the live key suffix set.
pub fn pruneOrphans(a: std.mem.Allocator, root: SystemStore, io: std.Io, live: *const std.StringHashMap(void)) !usize {
    _ = io;
    const prefix = "system/object-tags/";
    const records = try root.scanNamespace(a, .object_tag);
    defer records.deinit(a);
    var removed: usize = 0;
    for (records.records) |record| {
        if (record.tombstone or !std.mem.startsWith(u8, record.key, prefix)) continue;
        const parsed = try std.json.parseFromSlice(Record, a, record.payload, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try validateRecord(parsed.value);
        if (live.contains(record.key[prefix.len..])) continue;
        try root.remove(a, record.key);
        removed += 1;
    }
    return removed;
}

test "object tags persist by object version and enforce limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("../metadata/engine_repository.zig").EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer repository.deinit();
    const metadata = SystemStore{ .repository = repository.interface() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try save(a, metadata, io, "bucket", "key", "null", .{ .tags = &.{.{ .key = "team", .value = "blue" }} });
    const loaded = try load(a, metadata, io, "bucket", "key", "null");
    try std.testing.expectEqualStrings("blue", loaded.tags[0].value);
    const other = try load(a, metadata, io, "bucket", "key", "version-2");
    try std.testing.expectEqual(@as(usize, 0), other.tags.len);
    var many: [11]Tag = undefined;
    for (&many, 0..) |*tag, i| tag.* = .{ .key = if (i == 0) "duplicate" else "tag", .value = "v" };
    try std.testing.expectError(error.TooManyTags, save(a, metadata, io, "bucket", "key", "null", .{ .tags = &many }));
    try remove(a, metadata, io, "bucket", "key", "null");
    const empty = try load(a, metadata, io, "bucket", "key", "null");
    try std.testing.expectEqual(@as(usize, 0), empty.tags.len);
}
