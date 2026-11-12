const std = @import("std");
const Header = @import("../auth/sigv4.zig").Header;
pub const Origin = struct { peer: std.Io.net.IpAddress, secure: bool = false };

pub fn ipText(a: std.mem.Allocator, peer: std.Io.net.IpAddress) ![]const u8 {
    const address = try std.fmt.allocPrint(a, "{f}", .{peer});
    return if (address[0] == '[') address[1..std.mem.indexOfScalar(u8, address, ']').?] else address[0..std.mem.lastIndexOfScalar(u8, address, ':').?];
}
fn trusted(a: std.mem.Allocator, peer: std.Io.net.IpAddress, proxies: []const []const u8) !bool {
    const ip = try ipText(a, peer);
    for (proxies) |proxy| if (@import("../auth/iam_policy.zig").ipContains(proxy, ip) catch false) return true;
    return false;
}
// The rightmost untrusted hop is the client. Never accept a header asserted by
// an untrusted socket peer. Ambiguous/malformed chains fall back to the socket.
pub fn resolve(a: std.mem.Allocator, peer: std.Io.net.IpAddress, headers: []const Header, proxies: []const []const u8) !Origin {
    const direct: Origin = .{ .peer = peer };
    if (!try trusted(a, peer, proxies)) return direct;
    var forwarded: ?[]const u8 = null;
    var protocols: ?[]const u8 = null;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) {
            if (forwarded != null) return direct;
            forwarded = header.value;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-proto")) {
            if (protocols != null) return direct;
            protocols = header.value;
        }
    }
    const raw = forwarded orelse return direct;
    if (raw.len > 4096) return direct;
    var hops: std.ArrayList(std.Io.net.IpAddress) = .empty;
    var iterator = std.mem.splitScalar(u8, raw, ',');
    while (iterator.next()) |part| {
        const value = std.mem.trim(u8, part, " \t");
        if (hops.items.len >= 64 or std.mem.indexOfAny(u8, value, "%[]/") != null) return direct;
        try hops.append(a, std.Io.net.IpAddress.parse(value, 0) catch return direct);
    }
    var selected = hops.items.len - 1;
    while (selected > 0 and try trusted(a, hops.items[selected], proxies)) selected -= 1;
    var result: Origin = .{ .peer = hops.items[selected] };
    if (protocols) |raw_protocols| {
        if (raw_protocols.len > 512) return result;
        var parts = std.mem.splitScalar(u8, raw_protocols, ',');
        var count: usize = 0;
        var secure = false;
        while (parts.next()) |part| {
            const value = std.mem.trim(u8, part, " \t");
            if (!std.mem.eql(u8, value, "http") and !std.mem.eql(u8, value, "https")) return result;
            if (count == selected) secure = std.mem.eql(u8, value, "https");
            count += 1;
        }
        // A protocol is accepted only when aligned with the complete hop list.
        if (count == hops.items.len) result.secure = secure;
    }
    return result;
}

test "proxy trust ignores spoofed and ambiguous headers and follows trusted hops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 9000);
    const headers = [_]Header{
        .{ .name = "X-Forwarded-For", .value = "198.51.100.7, 10.0.0.2" },
        .{ .name = "X-Forwarded-Proto", .value = "https, http" },
    };
    const untrusted = try resolve(a, peer, &headers, &.{});
    try std.testing.expectEqualStrings("127.0.0.1", try ipText(a, untrusted.peer));
    try std.testing.expect(!untrusted.secure);
    const limited = try resolve(a, peer, &headers, &.{"127.0.0.1"});
    try std.testing.expectEqualStrings("10.0.0.2", try ipText(a, limited.peer));
    try std.testing.expect(!limited.secure);
    const chain = try resolve(a, peer, &headers, &.{ "127.0.0.1", "10.0.0.0/8" });
    try std.testing.expectEqualStrings("198.51.100.7", try ipText(a, chain.peer));
    try std.testing.expect(chain.secure);
    const duplicate = try resolve(a, peer, &.{ headers[0], headers[0], headers[1] }, &.{"127.0.0.1"});
    try std.testing.expectEqualStrings("127.0.0.1", try ipText(a, duplicate.peer));
    const malformed = try resolve(a, peer, &.{.{ .name = "X-Forwarded-For", .value = "bad, 10.0.0.2" }}, &.{"127.0.0.1"});
    try std.testing.expectEqualStrings("127.0.0.1", try ipText(a, malformed.peer));
    const ipv6 = try resolve(a, try std.Io.net.IpAddress.parse("::1", 9000), &.{ .{ .name = "X-Forwarded-For", .value = "2001:db8::7" }, .{ .name = "X-Forwarded-Proto", .value = "https" } }, &.{"::1/128"});
    try std.testing.expect(ipv6.secure);
    try std.testing.expectEqualStrings("2001:db8::7", try ipText(a, ipv6.peer));
}
