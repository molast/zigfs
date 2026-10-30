const std = @import("std");
const durable = @import("../metadata/durable.zig");
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
    return std.fmt.allocPrint(a, ".zigfs/system/object-tags/{s}", .{filename});
}
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket: []const u8, object: []const u8, version: []const u8) !Record {
    const path = try key(a, bucket, object, version);
    defer a.free(path);
    const bytes = root.readFileAlloc(io, path, a, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Record, a, bytes, .{ .allocate = .alloc_always });
    validateRecord(parsed.value) catch { parsed.deinit(); return error.InvalidTag; };
    return parsed.value;
}
fn validateRecord(record: Record) !void {
    if (record.version != 1 or record.tags.len > 10) return error.InvalidTag;
    for (record.tags, 0..) |tag, i| {
        if (tag.key.len == 0 or tag.key.len > 128 or tag.value.len > 256 or !std.unicode.utf8ValidateSlice(tag.key) or !std.unicode.utf8ValidateSlice(tag.value)) return error.InvalidTag;
        for (record.tags[0..i]) |previous| if (std.mem.eql(u8, previous.key, tag.key)) return error.InvalidTag;
    }
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket: []const u8, object: []const u8, version: []const u8, record: Record) !void {
    if (record.tags.len > 10) return error.TooManyTags;
    for (record.tags, 0..) |tag, i| {
        if (tag.key.len == 0 or tag.key.len > 128 or tag.value.len > 256 or !std.unicode.utf8ValidateSlice(tag.key) or !std.unicode.utf8ValidateSlice(tag.value)) return error.InvalidTag;
        for (record.tags[0..i]) |previous| if (std.mem.eql(u8, previous.key, tag.key)) return error.DuplicateTag;
    }
    const path = try key(a, bucket, object, version);
    defer a.free(path);
    const bytes = try std.json.Stringify.valueAlloc(a, record, .{});
    defer a.free(bytes);
    try root.createDirPath(io, ".zigfs/system/object-tags");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try durable.syncParent(root, io, path);
}
pub fn remove(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, bucket: []const u8, object: []const u8, version: []const u8) !void {
    const path = try key(a, bucket, object, version);
    defer a.free(path);
    root.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    durable.syncParent(root, io, path) catch |err| return err;
}

/// Validates all persisted records during recovery/diagnostics. Tag files are
/// deliberately independent from object payloads, so malformed sidecars must
/// surface as corruption instead of silently changing authorization context.
pub fn validateAll(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io) !usize {
    var directory = root.openDir(io, ".zigfs/system/object-tags", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const bytes = try directory.readFileAlloc(io, entry.name, a, .limited(128 * 1024));
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Record, a, bytes, .{ .allocate = .alloc_always });
        validateRecord(parsed.value) catch { parsed.deinit(); return error.InvalidTag; };
        parsed.deinit();
        count += 1;
    }
    return count;
}

/// Removes valid but unreachable sidecars after the metadata graph has been
/// rebuilt. The caller owns the live filename set and must hold object locks.
pub fn pruneOrphans(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, live: *const std.StringHashMap(void)) !usize {
    var directory = root.openDir(io, ".zigfs/system/object-tags", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var removed: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const bytes = try directory.readFileAlloc(io, entry.name, a, .limited(128 * 1024));
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Record, a, bytes, .{ .allocate = .alloc_always });
        validateRecord(parsed.value) catch { parsed.deinit(); return error.InvalidTag; };
        parsed.deinit();
        if (live.contains(entry.name)) continue;
        directory.deleteFile(io, entry.name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        removed += 1;
    }
    return removed;
}

test "object tags persist by object version and enforce limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try save(a, tmp.dir, io, "bucket", "key", "null", .{ .tags = &.{.{ .key = "team", .value = "blue" }} });
    const loaded = try load(a, tmp.dir, io, "bucket", "key", "null");
    try std.testing.expectEqualStrings("blue", loaded.tags[0].value);
    const other = try load(a, tmp.dir, io, "bucket", "key", "version-2");
    try std.testing.expectEqual(@as(usize, 0), other.tags.len);
    var many: [11]Tag = undefined;
    for (&many, 0..) |*tag, i| tag.* = .{ .key = if (i == 0) "duplicate" else "tag", .value = "v" };
    try std.testing.expectError(error.TooManyTags, save(a, tmp.dir, io, "bucket", "key", "null", .{ .tags = &many }));
    try remove(a, tmp.dir, io, "bucket", "key", "null");
    const empty = try load(a, tmp.dir, io, "bucket", "key", "null");
    try std.testing.expectEqual(@as(usize, 0), empty.tags.len);
}
