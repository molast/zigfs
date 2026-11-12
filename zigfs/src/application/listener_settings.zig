const std = @import("std");
pub const Settings = struct { api_address: []const u8 };
const path = ".zigfs/config/listener.json";
pub fn validate(value: []const u8) !std.Io.net.IpAddress {
    if (value.len > 128) return error.InvalidListenAddress;
    const address = std.Io.net.IpAddress.parseLiteral(value) catch return error.InvalidListenAddress;
    const port = switch (address) {
        .ip4 => |v| v.port,
        .ip6 => |v| v.port,
    };
    if (port == 0) return error.InvalidListenAddress;
    return address;
}
// Uses a request/startup arena.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, fallback: []const u8) ![]const u8 {
    const bytes = root.readFileAlloc(io, path, a, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return fallback,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always });
    _ = try validate(parsed.value.api_address);
    return parsed.value.api_address;
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, address: []const u8) !void {
    _ = try validate(address);
    const bytes = try std.json.Stringify.valueAlloc(a, Settings{ .api_address = address }, .{});
    try root.createDirPath(io, ".zigfs/config");
    var file = try root.createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
    try @import("../metadata/durable.zig").syncParent(root, io, path);
}
test "listener values require literal addresses and nonzero ports" {
    _ = try validate("0.0.0.0:9000");
    _ = try validate("[::1]:9000");
    for ([_][]const u8{ "localhost:9000", "127.0.0.1:0", "127.0.0.1:65536", ":9000", "https://localhost" }) |value| try std.testing.expectError(error.InvalidListenAddress, validate(value));
}
