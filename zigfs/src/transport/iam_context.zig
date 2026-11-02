const std = @import("std");
const iam = @import("../auth/iam_policy.zig");
const sigv4 = @import("../auth/sigv4.zig");
const protocol = @import("s3_protocol.zig");
const time = @import("../common/time.zig");

// All strings are copied into the request arena before a body read can reuse
// HTTP's head buffer. SourceIp comes from the accepted socket, never headers.
pub fn build(a: std.mem.Allocator, owner: []const u8, headers: []const sigv4.Header, parsed: protocol.ParsedTarget, peer: std.Io.net.IpAddress, now: i64, auth_type: []const u8, signed_at: ?i64, region: []const u8, subject_id: ?[]const u8) !iam.Context {
    var entries: std.ArrayList(iam.Entry) = .empty;
    if (owner.len > 0) {
        try add(a, &entries, "aws:username", if (std.mem.startsWith(u8, owner, "user:")) owner[5..] else owner);
        try add(a, &entries, "aws:userid", subject_id orelse owner);
        try add(a, &entries, "aws:PrincipalAccount", @import("../application/resource_policy_store.zig").account_id);
        const arn = if (std.mem.startsWith(u8, owner, "role:")) blk: {
            const role_suffix = owner["role:".len..];
            const role_name = role_suffix[0 .. (std.mem.indexOfScalar(u8, role_suffix, ':') orelse role_suffix.len)];
            break :blk try std.fmt.allocPrint(a, "arn:aws:iam::{s}:role/{s}", .{ @import("../application/resource_policy_store.zig").account_id, role_name });
        } else if (std.mem.startsWith(u8, owner, "oidc:")) try std.fmt.allocPrint(a, "arn:aws:sts::{s}:federated-user/{s}", .{ @import("../application/resource_policy_store.zig").account_id, subject_id orelse owner[5..] }) else if (subject_id != null) try std.fmt.allocPrint(a, "arn:aws:iam::{s}:user/{s}", .{ @import("../application/resource_policy_store.zig").account_id, owner[5..] }) else "arn:aws:iam::" ++ @import("../application/resource_policy_store.zig").account_id ++ ":root";
        try add(a, &entries, "aws:PrincipalArn", arn);
        try add(a, &entries, "aws:PrincipalType", if (std.mem.startsWith(u8, owner, "role:")) "Role" else if (std.mem.startsWith(u8, owner, "oidc:")) "FederatedUser" else if (std.mem.startsWith(u8, owner, "user:")) "User" else "Account");
    } else {
        try add(a, &entries, "aws:PrincipalAccount", "anonymous");
    }
    try add(a, &entries, "aws:SecureTransport", "false"); // Listener is HTTP; no trusted proxy/TLS assertion exists.
    try add(a, &entries, "aws:RequestedRegion", region);
    const address = try std.fmt.allocPrint(a, "{f}", .{peer});
    const ip = if (address[0] == '[') address[1..std.mem.indexOfScalar(u8, address, ']').?] else address[0..std.mem.lastIndexOfScalar(u8, address, ':').?];
    try add(a, &entries, "aws:SourceIp", ip);
    var date: [20]u8 = undefined;
    try add(a, &entries, "aws:CurrentTime", try time.formatIso8601(now, &date));
    try add(a, &entries, "aws:EpochTime", try std.fmt.allocPrint(a, "{d}", .{now}));
    try add(a, &entries, "s3:authType", auth_type);
    if (owner.len > 0) try add(a, &entries, "s3:signatureversion", "AWS4-HMAC-SHA256");
    if (signed_at) |stamp| try add(a, &entries, "s3:signatureAge", try std.fmt.allocPrint(a, "{d}", .{@max(0, now - stamp) * 1000}));
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) try add(a, &entries, "aws:UserAgent", header.value);
        if (std.ascii.eqlIgnoreCase(header.name, "referer")) try add(a, &entries, "aws:Referer", header.value);
        if (std.ascii.startsWithIgnoreCase(header.name, "x-amz-")) {
            const name = try std.fmt.allocPrint(a, "s3:{s}", .{header.name});
            if (iam.supportedKey(name)) try add(a, &entries, name, header.value);
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-tagging")) try addTags(a, &entries, header.value);
    }
    for (parsed.parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, "prefix") or std.mem.eql(u8, parameter.name, "delimiter") or std.mem.eql(u8, parameter.name, "max-keys") or std.mem.eql(u8, parameter.name, "versionId")) {
            const name = try std.fmt.allocPrint(a, "s3:{s}", .{parameter.name});
            try add(a, &entries, name, parameter.value);
        }
    }
    if (parsed.operation == .list_objects_v2) {
        if ((parsed.query("prefix") catch null) == null) try add(a, &entries, "s3:prefix", "");
        if ((parsed.query("max-keys") catch null) == null) try add(a, &entries, "s3:max-keys", "1000");
    }
    return .{ .entries = try entries.toOwnedSlice(a) };
}

pub fn add(a: std.mem.Allocator, entries: *std.ArrayList(iam.Entry), key: []const u8, value: []const u8) !void {
    try entries.append(a, .{ .key = try a.dupe(u8, key), .value = try a.dupe(u8, value) });
}
fn addTags(a: std.mem.Allocator, entries: *std.ArrayList(iam.Entry), raw: []const u8) !void {
    const target = try std.fmt.allocPrint(a, "/?{s}", .{raw});
    const parsed = try protocol.parseTarget(a, .GET, target);
    for (parsed.parameters) |tag| {
        try add(a, entries, try std.fmt.allocPrint(a, "s3:RequestObjectTag/{s}", .{tag.name}), tag.value);
        try add(a, entries, "s3:RequestObjectTagKeys", tag.name);
    }
}
