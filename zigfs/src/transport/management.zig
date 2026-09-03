const std = @import("std");

pub const api_prefix = "/_admin/v1";

pub const Method = enum { get, post, patch, delete };

pub const Route = struct {
    method: Method,
    path: []const u8,
};

pub const routes = [_]Route{
    .{ .method = .post, .path = "/_admin/v1/auth/login" },
    .{ .method = .get, .path = "/_admin/v1/auth/session" },
    .{ .method = .get, .path = "/_admin/v1/buckets" },
    .{ .method = .post, .path = "/_admin/v1/buckets" },
    .{ .method = .delete, .path = "/_admin/v1/buckets/:name" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/objects" },
    .{ .method = .post, .path = "/_admin/v1/objects/presign" },
    .{ .method = .get, .path = "/_admin/v1/access-keys" },
    .{ .method = .post, .path = "/_admin/v1/access-keys" },
    .{ .method = .patch, .path = "/_admin/v1/access-keys/:id" },
    .{ .method = .delete, .path = "/_admin/v1/access-keys/:id" },
    .{ .method = .get, .path = "/_admin/v1/storage" },
    .{ .method = .get, .path = "/_admin/v1/system" },
    .{ .method = .get, .path = "/_admin/v1/health" },
};

test "management routes remain under versioned prefix" {
    for (routes) |route| {
        try std.testing.expect(std.mem.startsWith(u8, route.path, api_prefix));
    }
}
