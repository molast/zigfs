const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const std = @import("std");
const Config = @import("../config.zig").Config;
pub const Settings = struct {
    s3_public_endpoint: []const u8,
    s3_virtual_hosted_style: bool,
    trusted_proxies: []const []const u8 = &.{},
};
const path = "config/network.json";
// Callers hold policy_mutex and use a request arena.
pub fn load(a: std.mem.Allocator, root: SystemStore, io: std.Io, config: Config) !Settings {
    _ = io;
    const bytes = root.read(a, path, 8192) catch |err| switch (err) {
        error.NotFound => return .{ .s3_public_endpoint = config.s3_public_endpoint, .s3_virtual_hosted_style = config.s3_virtual_hosted_style },
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
pub fn save(a: std.mem.Allocator, root: SystemStore, io: std.Io, value: Settings) !void {
    _ = io;
    try validate(value);
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try root.put(a, path, bytes);
}
test "network endpoint validation" {
    try validate(.{ .s3_public_endpoint = "https://s3.example.com", .s3_virtual_hosted_style = true });
    try std.testing.expectError(error.InvalidPublicEndpoint, validate(.{ .s3_public_endpoint = "https://example.com/path", .s3_virtual_hosted_style = false }));
    try std.testing.expectError(error.InvalidVirtualHostedEndpoint, validate(.{ .s3_public_endpoint = "http://127.0.0.1:9000", .s3_virtual_hosted_style = true }));
}

test "network settings persist and startup defaults remain fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("../metadata/engine_repository.zig").EngineRepository.open(std.testing.allocator, tmp.dir, std.testing.io);
    defer repository.deinit();
    const metadata = SystemStore{ .repository = repository.interface() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fallback = try load(a, metadata, std.testing.io, .{});
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", fallback.s3_public_endpoint);
    const value: Settings = .{ .s3_public_endpoint = "https://storage.example.com", .s3_virtual_hosted_style = true };
    try save(a, metadata, std.testing.io, value);
    const loaded = try load(a, metadata, std.testing.io, .{});
    try std.testing.expectEqualStrings(value.s3_public_endpoint, loaded.s3_public_endpoint);
    try std.testing.expect(loaded.s3_virtual_hosted_style);
    try std.testing.expectError(error.InvalidPublicEndpoint, save(a, metadata, std.testing.io, .{ .s3_public_endpoint = "file:///tmp", .s3_virtual_hosted_style = false }));
    const unchanged = try load(a, metadata, std.testing.io, .{});
    try std.testing.expectEqualStrings(value.s3_public_endpoint, unchanged.s3_public_endpoint);
}

test "trusted proxy settings reject malformed and oversized lists" {
    for ([_][]const u8{ "localhost", "0.0.0.0/33", "::/129", "127.0.0.1/8/8", "*", "10.0.0.1:80", "" }) |proxy| {
        try std.testing.expectError(error.InvalidTrustedProxy, validate(.{ .s3_public_endpoint = "https://example.com", .s3_virtual_hosted_style = false, .trusted_proxies = &.{proxy} }));
    }
    try validate(.{ .s3_public_endpoint = "http://localhost:9000", .s3_virtual_hosted_style = false, .trusted_proxies = &.{ "127.0.0.1", "::1/128", "10.0.0.0/24" } });
}

// Used under policy_mutex for conditional deployment changes from the gateway.
pub fn equal(left: Settings, right: Settings) bool {
    if (!std.mem.eql(u8, left.s3_public_endpoint, right.s3_public_endpoint) or
        left.s3_virtual_hosted_style != right.s3_virtual_hosted_style or
        left.trusted_proxies.len != right.trusted_proxies.len) return false;
    for (left.trusted_proxies, right.trusted_proxies) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

test "conditional network comparison includes endpoint addressing and trusted proxies" {
    const value: Settings = .{ .s3_public_endpoint = "https://s3.example.com", .s3_virtual_hosted_style = false, .trusted_proxies = &.{"127.0.0.1"} };
    try std.testing.expect(equal(value, value));
    var changed = value;
    changed.s3_public_endpoint = "https://other.example.com";
    try std.testing.expect(!equal(value, changed));
    changed = value;
    changed.s3_virtual_hosted_style = true;
    try std.testing.expect(!equal(value, changed));
    changed = value;
    changed.trusted_proxies = &.{"10.0.0.1"};
    try std.testing.expect(!equal(value, changed));
}
