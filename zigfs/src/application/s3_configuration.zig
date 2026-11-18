//! Read persisted S3 configuration using the bucket UUID, never its reusable name.
const std = @import("std");
const xml = @import("../common/xml.zig");
const Store = @import("../metadata/system_store.zig").SystemStore;
const A = std.mem.Allocator;

pub fn load(a: A, store: Store, bucket_id: [16]u8, kind: []const u8) !?xml.Node {
    const key = try std.fmt.allocPrint(a, "config/s3-buckets/{s}/{s}.json", .{ std.fmt.bytesToHex(bucket_id, .lower), kind });
    const bytes = store.read(a, key, 4 * 1024 * 1024) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    const document = (try std.json.parseFromSlice(std.json.Value, a, bytes, .{})).value;
    if (document != .object) return error.InvalidConfiguration;
    const encoded = document.object.get("") orelse return null;
    if (encoded != .string) return error.InvalidConfiguration;
    return try xml.parse(a, encoded.string);
}
pub fn child(node: xml.Node, name: []const u8) ?xml.Node {
    for (node.children) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}
pub fn text(node: xml.Node, name: []const u8) ?[]const u8 {
    return if (child(node, name)) |entry| entry.text else null;
}
pub fn abacEnabled(a: A, store: Store, bucket_id: [16]u8) !bool {
    const node = try load(a, store, bucket_id, "abac") orelse return true;
    return std.mem.eql(u8, text(node, "Status") orelse return error.InvalidConfiguration, "Enabled");
}
