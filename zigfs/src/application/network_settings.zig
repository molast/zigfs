const std = @import("std");
const Config = @import("../config.zig").Config;
pub const Settings = struct {
    s3_public_endpoint: []const u8,
    s3_virtual_hosted_style: bool,
    trusted_proxies: []const []const u8 = &.{},
};
const path = ".zigfs/config/network.json";
// Callers hold policy_mutex and use a request arena.
pub fn load(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, config: Config) !Settings {
    const bytes = root.readFileAlloc(io, path, a, .limited(8192)) catch |err| switch (err) {
        error.FileNotFound => return .{ .s3_public_endpoint = config.s3_public_endpoint, .s3_virtual_hosted_style = config.s3_virtual_hosted_style },
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always });
    try validate(parsed.value);
    return parsed.value;
}
pub fn validate(value: Settings) !void {
    if (value.trusted_proxies.len > 64) return error.InvalidTrustedProxy;
    for (value.trusted_proxies) |proxy| {
        if (proxy.len == 0 or proxy.len > 64 or std.mem.indexOfAny(u8, proxy, "%[]") != null) return error.InvalidTrustedProxy;
        const end = std.mem.indexOfScalar(u8, proxy, '/') orelse proxy.len;
        if (!(@import("../auth/iam_policy.zig").ipContains(proxy, proxy[0..end]) catch return error.InvalidTrustedProxy)) return error.InvalidTrustedProxy;
    }
    if (value.s3_public_endpoint.len > 2048 or !Config.isValidPublicEndpoint(value.s3_public_endpoint)) return error.InvalidPublicEndpoint;
    const uri = std.Uri.parse(value.s3_public_endpoint) catch return error.InvalidPublicEndpoint;
    const host = uri.host orelse return error.InvalidPublicEndpoint;
    const hostname = switch (host) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    if (hostname.len == 0 or std.mem.indexOfAny(u8, hostname, "%*\\") != null) return error.InvalidPublicEndpoint;
    if (uri.port) |port| if (port == 0) return error.InvalidPublicEndpoint;
    if (value.s3_virtual_hosted_style) {
        if (std.mem.indexOfScalar(u8, hostname, ':') != null) return error.InvalidVirtualHostedEndpoint;
        _ = std.Io.net.Ip4Address.parse(hostname, 0) catch return;
        return error.InvalidVirtualHostedEndpoint;
    }
}
pub fn save(a: std.mem.Allocator, root: std.Io.Dir, io: std.Io, value: Settings) !void {
    try validate(value);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try root.createDirPath(io, ".zigfs/config");
    var atomic = try root.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    try @import("../metadata/durable.zig").syncParent(root, io, path);
}
test "network endpoint validation" {
    try validate(.{ .s3_public_endpoint = "https://s3.example.com", .s3_virtual_hosted_style = true });
    try std.testing.expectError(error.InvalidPublicEndpoint, validate(.{ .s3_public_endpoint = "https://example.com/path", .s3_virtual_hosted_style = false }));
    try std.testing.expectError(error.InvalidVirtualHostedEndpoint, validate(.{ .s3_public_endpoint = "http://127.0.0.1:9000", .s3_virtual_hosted_style = true }));
}

test "network settings persist and startup defaults remain fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fallback = try load(a, tmp.dir, std.testing.io, .{});
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", fallback.s3_public_endpoint);
    const value: Settings = .{ .s3_public_endpoint = "https://storage.example.com", .s3_virtual_hosted_style = true };
    try save(a, tmp.dir, std.testing.io, value);
    const loaded = try load(a, tmp.dir, std.testing.io, .{});
    try std.testing.expectEqualStrings(value.s3_public_endpoint, loaded.s3_public_endpoint);
    try std.testing.expect(loaded.s3_virtual_hosted_style);
    try std.testing.expectError(error.InvalidPublicEndpoint, save(a, tmp.dir, std.testing.io, .{ .s3_public_endpoint = "file:///tmp", .s3_virtual_hosted_style = false }));
    const unchanged = try load(a, tmp.dir, std.testing.io, .{});
    try std.testing.expectEqualStrings(value.s3_public_endpoint, unchanged.s3_public_endpoint);
}

test "trusted proxy settings reject malformed and oversized lists" {
    for ([_][]const u8{ "localhost", "0.0.0.0/33", "::/129", "127.0.0.1/8/8", "*", "10.0.0.1:80", "" }) |proxy| {
        try std.testing.expectError(error.InvalidTrustedProxy, validate(.{ .s3_public_endpoint = "https://example.com", .s3_virtual_hosted_style = false, .trusted_proxies = &.{proxy} }));
    }
    try validate(.{ .s3_public_endpoint = "http://localhost:9000", .s3_virtual_hosted_style = false, .trusted_proxies = &.{ "127.0.0.1", "::1/128", "10.0.0.0/24" } });
}
