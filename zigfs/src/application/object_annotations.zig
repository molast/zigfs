//! Annotation index publication is atomic. Immutable encrypted blobs are committed
//! before their index entry; crashes can leave unreachable blobs, never dangling refs.
const std = @import("std");
const box = @import("../auth/secret_box.zig");
const Store = @import("../metadata/system_store.zig").SystemStore;
const Object = @import("../domain/object.zig").Object;
const A = std.mem.Allocator;
pub const Entry = struct {
    name: []const u8,
    blob: []const u8,
    modified: i64,
    size: usize,
    etag: []const u8,
};
pub const Index = struct { entries: []const Entry = &.{} };

pub fn path(a: A, object: *const Object) ![]const u8 {
    return std.fmt.allocPrint(a, "config/s3-objects/{s}/{s}/{s}/annotations.json", .{
        std.fmt.bytesToHex(object.bucket_id, .lower), std.fmt.bytesToHex(object.id, .lower), std.fmt.bytesToHex(object.data_generation, .lower),
    });
}
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 32 or c == 127) return false;
    return true;
}
/// Results belong to the caller's arena. Caller holds state_mutex for mutations.
pub fn load(a: A, store: Store, filename: []const u8) !Index {
    const bytes = store.read(a, filename, 1024 * 1024) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    return (try std.json.parseFromSlice(Index, a, bytes, .{ .allocate = .alloc_always })).value;
}
pub fn find(index: Index, name: []const u8) ?Entry {
    for (index.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}
pub fn put(a: A, io: std.Io, store: Store, filename: []const u8, key: box.Key, name: []const u8, payload: []const u8) !Entry {
    if (!validName(name) or payload.len == 0 or payload.len > 1024 * 1024) return error.InvalidAnnotation;
    const index = try load(a, store, filename);
    const previous = find(index, name);
    if (previous == null and index.entries.len >= 1000) return error.AnnotationLimit;
    const uuid = try @import("../common/id.zig").randomV4(io);
    const blob = try std.fmt.allocPrint(a, "{s}.{s}", .{ filename, std.fmt.bytesToHex(uuid, .lower) });
    const sealed = try box.seal(a, io, key, blob, payload);
    var encoded: std.Io.Writer.Allocating = .init(a);
    try encoded.writer.writeAll(&sealed.nonce);
    try encoded.writer.writeAll(&sealed.tag);
    try encoded.writer.writeAll(sealed.ciphertext);
    try store.put(a, blob, encoded.written());
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(payload, &digest, .{});
    const entry: Entry = .{
        .name = name,
        .blob = blob,
        .modified = std.Io.Clock.real.now(io).toSeconds(),
        .size = payload.len,
        .etag = try std.fmt.allocPrint(a, "\"{s}\"", .{std.fmt.bytesToHex(digest, .lower)}),
    };
    var entries: std.ArrayList(Entry) = .empty;
    for (index.entries) |existing| {
        if (!std.mem.eql(u8, existing.name, name)) try entries.append(a, existing);
    }
    try entries.append(a, entry);
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.less);
    try store.put(a, filename, try std.json.Stringify.valueAlloc(a, Index{ .entries = entries.items }, .{}));
    if (previous) |old| store.remove(a, old.blob) catch |err| {
        std.log.warn("Annotation obsolete blob cleanup deferred: {s}", .{@errorName(err)});
    };
    return entry;
}
pub fn get(a: A, store: Store, key: box.Key, entry: Entry) ![]u8 {
    const bytes = try store.read(a, entry.blob, 1024 * 1024 + 28);
    if (bytes.len < 28 or bytes.len - 28 != entry.size) return error.CorruptAnnotation;
    return box.open(a, key, entry.blob, bytes[0..12].*, bytes[12..28].*, bytes[28..]);
}
pub fn remove(a: A, store: Store, filename: []const u8, name: []const u8) !void {
    const index = try load(a, store, filename);
    const previous = find(index, name) orelse return;
    var entries: std.ArrayList(Entry) = .empty;
    for (index.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) try entries.append(a, entry);
    }
    try store.put(a, filename, try std.json.Stringify.valueAlloc(a, Index{ .entries = entries.items }, .{}));
    store.remove(a, previous.blob) catch |err| {
        std.log.warn("Annotation deleted blob cleanup deferred: {s}", .{@errorName(err)});
    };
}
