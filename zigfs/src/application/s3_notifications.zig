//! S3 notification documents share the existing durable event delivery pipeline.
//! Destinations are administrator-registered targets, addressed by local ARN.
const std = @import("std");
const xml = @import("../common/xml.zig");
const subscriptions = @import("bucket_subscriptions.zig");
const destinations = @import("event_destinations.zig");
const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const A = std.mem.Allocator;
const arn_prefix = "arn:zigfs:events:::";

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn child(node: xml.Node, name: []const u8) ?xml.Node {
    for (node.children) |entry| if (eq(entry.name, name)) return entry;
    return null;
}
fn value(node: xml.Node, name: []const u8) ?[]const u8 {
    return if (child(node, name)) |entry| entry.text else null;
}

/// The caller supplies an arena and serializes mutations with policy_mutex.
pub fn parse(a: A, root: xml.Node) !subscriptions.Settings {
    if (!eq(root.name, "NotificationConfiguration") or root.children.len > 100) return error.InvalidNotification;
    var rules: std.ArrayList(subscriptions.Subscription) = .empty;
    for (root.children, 0..) |entry, index| {
        const target_field = if (eq(entry.name, "QueueConfiguration")) "Queue" else if (eq(entry.name, "TopicConfiguration")) "Topic" else return error.UnsupportedNotification;
        const arn = value(entry, target_field) orelse return error.InvalidNotification;
        if (!std.mem.startsWith(u8, arn, arn_prefix)) return error.UnsupportedDestination;
        const target = arn[arn_prefix.len..];
        if (!destinations.validName(target)) return error.InvalidNotification;
        var categories: std.ArrayList([]const u8) = .empty;
        var events: std.ArrayList([]const u8) = .empty;
        for (entry.children) |field| {
            if (!eq(field.name, "Event")) continue;
            const event = field.text;
            const category: []const u8 = if (eq(event, "s3:ObjectCreated:*") or eq(event, "s3:ObjectCreated:Put") or eq(event, "s3:ObjectCreated:Post") or eq(event, "s3:ObjectCreated:Copy") or eq(event, "s3:ObjectCreated:CompleteMultipartUpload")) "PUT" else if (eq(event, "s3:ObjectRemoved:*") or eq(event, "s3:ObjectRemoved:Delete") or eq(event, "s3:ObjectRemoved:DeleteMarkerCreated")) "DELETE" else return error.UnsupportedEvent;
            try events.append(a, event[3..]);
            var found = false;
            for (categories.items) |existing| if (eq(existing, category)) {
                found = true;
            };
            if (!found) try categories.append(a, category);
        }
        if (events.items.len == 0) return error.InvalidNotification;
        var rule: subscriptions.Subscription = .{
            .id = value(entry, "Id") orelse try std.fmt.allocPrint(a, "s3-{d}", .{index}),
            .destination = target,
            .events = categories.items,
            .event_names = events.items,
        };
        if (child(entry, "Filter")) |filter| {
            const keys = child(filter, "S3Key") orelse return error.InvalidNotification;
            var has_prefix = false;
            var has_suffix = false;
            for (keys.children) |item| {
                if (!eq(item.name, "FilterRule")) return error.InvalidNotification;
                const name = value(item, "Name") orelse return error.InvalidNotification;
                const text = value(item, "Value") orelse return error.InvalidNotification;
                if (eq(name, "prefix") and !has_prefix) {
                    rule.prefix = text;
                    has_prefix = true;
                } else if (eq(name, "suffix") and !has_suffix) {
                    rule.suffix = text;
                    has_suffix = true;
                } else return error.InvalidNotification;
            }
        }
        try rules.append(a, rule);
    }
    const result: subscriptions.Settings = .{ .items = rules.items };
    try subscriptions.validate(result);
    return result;
}

pub fn load(a: A, store: SystemStore, bucket_id: [16]u8) !subscriptions.Settings {
    const path = try std.fmt.allocPrint(a, "config/s3-buckets/{s}/notification.json", .{std.fmt.bytesToHex(bucket_id, .lower)});
    const bytes = store.read(a, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    const document = (try std.json.parseFromSlice(std.json.Value, a, bytes, .{})).value;
    if (document != .object) return error.InvalidNotification;
    const encoded = document.object.get("") orelse return .{};
    if (encoded != .string) return error.InvalidNotification;
    return parse(a, try xml.parse(a, encoded.string));
}

pub fn validateTargets(rules: subscriptions.Settings, configured: destinations.Snapshot) !void {
    for (rules.items) |rule| {
        var found = false;
        for (configured.items) |target| if (eq(target.name, rule.destination)) {
            found = true;
        };
        if (!found) return error.DestinationNotFound;
    }
}
