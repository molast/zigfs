//! Apply bucket CORS rules to successful object GET/HEAD responses.
const std = @import("std");
const App = @import("../application/mod.zig").Application;
const config = @import("../application/s3_configuration.zig");
const sigv4 = @import("../auth/sigv4.zig");
const A = std.mem.Allocator;

pub fn headers(a: A, app: *App, bucket_id: [16]u8, method: std.http.Method, incoming: []const sigv4.Header, original: []const std.http.Header) ![]const std.http.Header {
    const document = try config.load(a, app.systemStore(), bucket_id, "cors") orelse return original;
    var result: std.ArrayList(std.http.Header) = .empty;
    for (original) |header| {
        if (std.ascii.startsWithIgnoreCase(header.name, "access-control-")) continue;
        try result.append(a, header);
    }
    try result.append(a, .{ .name = "vary", .value = "Origin" });
    var origin: ?[]const u8 = null;
    for (incoming) |header| if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
        origin = header.value;
    };
    const requested = origin orelse return result.items;
    for (document.children) |rule| {
        var origin_matches = false;
        var method_matches = false;
        var exposed: std.Io.Writer.Allocating = .init(a);
        for (rule.children) |field| {
            if (std.mem.eql(u8, field.name, "AllowedOrigin")) {
                if (std.mem.eql(u8, field.text, "*") or std.mem.eql(u8, field.text, requested)) origin_matches = true;
            } else if (std.mem.eql(u8, field.name, "AllowedMethod")) {
                if (std.mem.eql(u8, field.text, @tagName(method))) method_matches = true;
            } else if (std.mem.eql(u8, field.name, "ExposeHeader")) {
                if (exposed.written().len > 0) try exposed.writer.writeAll(", ");
                try exposed.writer.writeAll(field.text);
            }
        }
        if (!origin_matches or !method_matches) continue;
        try result.append(a, .{ .name = "access-control-allow-origin", .value = requested });
        if (exposed.written().len > 0) try result.append(a, .{ .name = "access-control-expose-headers", .value = exposed.written() });
        break;
    }
    return result.items;
}
