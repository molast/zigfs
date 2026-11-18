//! Additional S3 control-plane operations. Every request uses the normal S3
//! authentication path, then checks the bucket owner before accessing metadata.
const std = @import("std");
const s3 = @import("s3.zig");
const protocol = @import("s3_protocol.zig");
const xml = @import("../common/xml.zig");
const Application = @import("../application/mod.zig").Application;
const sigv4 = @import("../auth/sigv4.zig");
const bucket_domain = @import("../domain/bucket.zig");
const A = std.mem.Allocator;
const namespace = "http://s3.amazonaws.com/doc/2006-03-01/";
const Configuration = struct {
    query: []const u8,
    root: []const u8,
    read_action: []const u8,
    write_action: []const u8,
    id_root: ?[]const u8 = null,
};
const configurations = [_]Configuration{
    .{ .query = "cors", .root = "CORSConfiguration", .read_action = "s3:GetBucketCORS", .write_action = "s3:PutBucketCORS" },
    .{ .query = "notification", .root = "NotificationConfiguration", .read_action = "s3:GetBucketNotification", .write_action = "s3:PutBucketNotification" },
    .{ .query = "website", .root = "WebsiteConfiguration", .read_action = "s3:GetBucketWebsite", .write_action = "s3:PutBucketWebsite" },
    .{ .query = "logging", .root = "BucketLoggingStatus", .read_action = "s3:GetBucketLogging", .write_action = "s3:PutBucketLogging" },
    .{ .query = "requestPayment", .root = "RequestPaymentConfiguration", .read_action = "s3:GetBucketRequestPayment", .write_action = "s3:PutBucketRequestPayment" },
    .{ .query = "accelerate", .root = "AccelerateConfiguration", .read_action = "s3:GetAccelerateConfiguration", .write_action = "s3:PutAccelerateConfiguration" },
    .{ .query = "abac", .root = "AbacStatus", .read_action = "s3:GetBucketAbac", .write_action = "s3:PutBucketAbac" },
    .{ .query = "analytics", .root = "AnalyticsConfiguration", .read_action = "s3:GetAnalyticsConfiguration", .write_action = "s3:PutAnalyticsConfiguration", .id_root = "ListBucketAnalyticsConfigurationsResult" },
    .{ .query = "inventory", .root = "InventoryConfiguration", .read_action = "s3:GetInventoryConfiguration", .write_action = "s3:PutInventoryConfiguration", .id_root = "ListInventoryConfigurationsResult" },
    .{ .query = "metrics", .root = "MetricsConfiguration", .read_action = "s3:GetMetricsConfiguration", .write_action = "s3:PutMetricsConfiguration", .id_root = "ListMetricsConfigurationsResult" },
    .{ .query = "intelligent-tiering", .root = "IntelligentTieringConfiguration", .read_action = "s3:GetIntelligentTieringConfiguration", .write_action = "s3:PutIntelligentTieringConfiguration", .id_root = "ListBucketIntelligentTieringConfigurationsResult" },
};

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn has(parameters: []const protocol.QueryParameter, name: []const u8) bool {
    for (parameters) |parameter| if (eq(parameter.name, name)) return true;
    return false;
}
pub fn recognizes(method: std.http.Method, object: bool, parameters: []const protocol.QueryParameter) bool {
    if (method != .GET and method != .PUT and method != .DELETE and method != .POST) return false;
    var selected: ?[]const u8 = null;
    for (parameters) |parameter| {
        var control = false;
        if (object) {
            for ([_][]const u8{ "acl", "attributes", "legal-hold", "retention", "torrent", "select", "annotation", "encryption", "restore" }) |name| {
                if (eq(parameter.name, name)) control = true;
            }
        } else {
            for (configurations) |configuration| if (eq(parameter.name, configuration.query)) {
                control = true;
            };
            for ([_][]const u8{ "tagging", "acl", "publicAccessBlock", "ownershipControls", "object-lock" }) |name| {
                if (eq(parameter.name, name)) control = true;
            }
        }
        if (control) {
            if (selected != null or parameter.value.len != 0) return false;
            selected = parameter.name;
        } else {
            var allowed = std.mem.startsWith(u8, parameter.name, "X-Amz-");
            for ([_][]const u8{ "versionId", "id", "continuation-token", "select-type", "annotationName", "annotation-prefix", "max-annotation-results" }) |name| {
                if (eq(parameter.name, name)) allowed = true;
            }
            if (!allowed) return false;
        }
    }
    const name = selected orelse return false;
    if (object) {
        if (eq(name, "annotation")) return method == .GET or method == .PUT or method == .DELETE;
        if (eq(name, "torrent") or eq(name, "attributes")) return method == .GET;
        if (eq(name, "select") or eq(name, "restore")) return method == .POST;
        if (eq(name, "encryption")) return method == .PUT;
        return method == .GET or method == .PUT;
    }
    return method == .GET or method == .PUT or method == .DELETE;
}
pub fn action(method: std.http.Method, parsed: protocol.ParsedTarget) []const u8 {
    const read = method == .GET;
    if (parsed.key != null) {
        if (has(parsed.parameters, "torrent") or has(parsed.parameters, "select")) return "s3:GetObject";
        if (has(parsed.parameters, "restore")) return "s3:RestoreObject";
        if (has(parsed.parameters, "encryption")) return "s3:UpdateObjectEncryption";
        if (has(parsed.parameters, "annotation")) return switch (method) {
            .PUT => "s3:PutObjectAnnotation",
            .DELETE => "s3:DeleteObjectAnnotation",
            else => if ((parsed.query("annotationName") catch null) != null) "s3:GetObjectAnnotation" else "s3:ListObjectAnnotations",
        };
        if (has(parsed.parameters, "acl")) return if (read) "s3:GetObjectAcl" else "s3:PutObjectAcl";
        if (has(parsed.parameters, "attributes")) return "s3:GetObjectAttributes";
        if (has(parsed.parameters, "legal-hold")) return if (read) "s3:GetObjectLegalHold" else "s3:PutObjectLegalHold";
        return if (read) "s3:GetObjectRetention" else "s3:PutObjectRetention";
    }
    for (configurations) |configuration| {
        if (has(parsed.parameters, configuration.query)) return if (read) configuration.read_action else configuration.write_action;
    }
    if (has(parsed.parameters, "tagging")) return if (read) "s3:GetBucketTagging" else "s3:PutBucketTagging";
    if (has(parsed.parameters, "acl")) return if (read) "s3:GetBucketAcl" else "s3:PutBucketAcl";
    if (has(parsed.parameters, "publicAccessBlock")) return if (read) "s3:GetBucketPublicAccessBlock" else "s3:PutBucketPublicAccessBlock";
    if (has(parsed.parameters, "ownershipControls")) return if (read) "s3:GetBucketOwnershipControls" else "s3:PutBucketOwnershipControls";
    return if (read) "s3:GetBucketObjectLockConfiguration" else "s3:PutBucketObjectLockConfiguration";
}
fn child(node: xml.Node, name: []const u8) ?xml.Node {
    for (node.children) |value| if (eq(value.name, name)) return value;
    return null;
}
fn text(node: xml.Node, name: []const u8) ?[]const u8 {
    return if (child(node, name)) |value| std.mem.trim(u8, value.text, " \r\n\t") else null;
}
fn element(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print("<{s}>", .{name});
    try protocol.writeXmlEscaped(writer, value);
    try writer.print("</{s}>", .{name});
}
fn path(a: A, bucket: bucket_domain.Bucket, kind: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "config/s3-buckets/{s}/{s}.json", .{ std.fmt.bytesToHex(bucket.id, .lower), kind });
}
/// Returned values belong to the caller's arena; the engine owns its copy on put.
fn load(a: A, app: *Application, key: []const u8) !std.json.Value {
    const bytes = app.systemStore().read(a, key, 4 * 1024 * 1024) catch |err| switch (err) {
        error.NotFound => return .{ .object = .{} },
        else => return err,
    };
    return (try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn save(a: A, app: *Application, key: []const u8, value: std.json.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    if (bytes.len > 4 * 1024 * 1024) return error.StreamTooLong;
    try app.systemStore().put(a, key, bytes);
}

pub fn serve(request: *std.http.Server.Request, app: *Application, parsed: protocol.ParsedTarget, access: s3.BucketAccess, headers: []const sigv4.Header, hash: sigv4.PayloadHash, request_id: []const u8) !std.http.Status {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bucket = s3.ensureBucketOwner(app, parsed.bucket.?, access) catch |err| return s3.respondError(request, app.allocator, s3.mapBucketError(err), request_id);
    defer bucket.deinit(app.allocator);
    if (s3.singleHeader(headers, "x-amz-expected-bucket-owner") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id)) |owner| {
        if (!eq(owner, bucket.owner)) return s3.respondError(request, app.allocator, .access_denied, request_id);
    }
    if (parsed.key != null and has(parsed.parameters, "annotation")) {
        return @import("s3_annotations.zig").serve(request, app, parsed, access, headers, hash, request_id);
    }
    var body: ?xml.Node = null;
    if (request.head.method == .PUT or request.head.method == .POST) {
        const bytes = s3.readXmlPayload(request, a, 1024 * 1024, hash) catch |err| return s3.respondError(request, app.allocator, s3.mapXmlPayloadError(err), request_id);
        body = xml.parse(a, bytes) catch return s3.respondError(request, app.allocator, .malformed_xml, request_id);
    }
    if (has(parsed.parameters, "acl")) return acl(request, app, parsed, bucket, body, request_id);
    if (parsed.key != null) return objectControl(request, app, parsed, access, headers, body, request_id);
    const buckets = app.bucketService().?;
    if (has(parsed.parameters, "tagging")) {
        if (request.head.method == .GET) {
            var output: std.Io.Writer.Allocating = .init(a);
            try output.writer.writeAll("<Tagging><TagSet>");
            if (bucket.tags_json) |json| {
                const tags = (try std.json.parseFromSlice(std.json.Value, a, json, .{})).value;
                var items = tags.object.iterator();
                while (items.next()) |item| {
                    if (item.value_ptr.* != .string) return s3.respondError(request, app.allocator, .internal_error, request_id);
                    try output.writer.writeAll("<Tag>");
                    try element(&output.writer, "Key", item.key_ptr.*);
                    try element(&output.writer, "Value", item.value_ptr.string);
                    try output.writer.writeAll("</Tag>");
                }
            }
            try output.writer.writeAll("</TagSet></Tagging>");
            return s3.respondXml(request, output.written(), .ok, request_id, &.{});
        }
        var tags: std.json.Value = .{ .object = .{} };
        if (body) |node| {
            if (!eq(node.name, "Tagging")) return s3.respondError(request, app.allocator, .malformed_xml, request_id);
            const set = child(node, "TagSet") orelse return s3.respondError(request, app.allocator, .malformed_xml, request_id);
            if (set.children.len > 50) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            for (set.children) |tag| {
                const key = text(tag, "Key") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                const value = text(tag, "Value") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                if (!eq(tag.name, "Tag") or key.len == 0 or key.len > 128 or value.len > 256 or tags.object.contains(key)) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                try tags.object.put(a, key, .{ .string = value });
            }
        }
        const updated = buckets.setTags(bucket.name, if (body != null) try std.json.Stringify.valueAlloc(a, tags, .{}) else null) catch |err| return s3.respondError(request, app.allocator, s3.mapBucketError(err), request_id);
        updated.deinit(app.allocator);
        return s3.respondEmpty(request, if (body != null) .ok else .no_content, request_id, &.{});
    }
    if (has(parsed.parameters, "ownershipControls")) {
        if (request.head.method == .DELETE) return s3.respondError(request, app.allocator, .not_implemented, request_id);
        if (body) |node| {
            const rule = child(node, "Rule") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            if (!eq(text(rule, "ObjectOwnership") orelse "", "BucketOwnerEnforced")) return s3.respondError(request, app.allocator, .not_implemented, request_id);
        }
        if (request.head.method != .GET) return s3.respondEmpty(request, .ok, request_id, &.{});
        return s3.respondXml(request, "<OwnershipControls><Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule></OwnershipControls>", .ok, request_id, &.{});
    }
    if (has(parsed.parameters, "publicAccessBlock")) {
        if (request.head.method != .GET) {
            var blocked = false;
            if (body) |node| {
                if (!eq(node.name, "PublicAccessBlockConfiguration")) return s3.respondError(request, app.allocator, .malformed_xml, request_id);
                var first: ?bool = null;
                for ([_][]const u8{ "BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets" }) |field| {
                    const value = text(node, field) orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    if (!eq(value, "true") and !eq(value, "false")) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    const flag = eq(value, "true");
                    // The backend has one enforcement switch: reject unrepresentable combinations.
                    if (first) |previous| {
                        if (previous != flag) return s3.respondError(request, app.allocator, .not_implemented, request_id);
                    }
                    first = flag;
                    blocked = flag;
                }
            }
            const updated = buckets.setPublicAccess(bucket.name, blocked) catch |err| return s3.respondError(request, app.allocator, s3.mapBucketError(err), request_id);
            updated.deinit(app.allocator);
            return s3.respondEmpty(request, .ok, request_id, &.{});
        }
        var output: std.Io.Writer.Allocating = .init(a);
        try output.writer.writeAll("<PublicAccessBlockConfiguration>");
        for ([_][]const u8{ "BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets" }) |field| try element(&output.writer, field, if (bucket.block_public_access) "true" else "false");
        try output.writer.writeAll("</PublicAccessBlockConfiguration>");
        return s3.respondXml(request, output.written(), .ok, request_id, &.{});
    }
    if (has(parsed.parameters, "object-lock")) return bucketLock(request, app, bucket, body, request_id);
    for (configurations) |configuration| {
        if (has(parsed.parameters, configuration.query)) return configurationRequest(a, request, app, parsed, bucket, configuration, body, request_id);
    }
    return s3.respondError(request, app.allocator, .not_implemented, request_id);
}

fn acl(request: *std.http.Server.Request, app: *Application, parsed: protocol.ParsedTarget, bucket: bucket_domain.Bucket, body: ?xml.Node, request_id: []const u8) !std.http.Status {
    _ = body;
    if (parsed.key) |key| {
        const objects = app.objectService().?;
        const version = s3.parseRequestedVersion(parsed) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const object = (if (version) |id| headVersion(objects, bucket.name, key, id) else objects.head(bucket.name, key)) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
        object.deinit(app.allocator);
    }
    if (request.head.method != .GET) return s3.respondError(request, app.allocator, .not_implemented, request_id);
    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.writeAll("<AccessControlPolicy><Owner>");
    try element(&output.writer, "ID", bucket.owner);
    try element(&output.writer, "DisplayName", bucket.owner);
    try output.writer.writeAll("</Owner><AccessControlList><Grant><Grantee xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:type=\"CanonicalUser\">");
    try element(&output.writer, "ID", bucket.owner);
    try output.writer.writeAll("</Grantee><Permission>FULL_CONTROL</Permission></Grant></AccessControlList></AccessControlPolicy>");
    return s3.respondXml(request, output.written(), .ok, request_id, &.{});
}

fn configurationRequest(a: A, request: *std.http.Server.Request, app: *Application, parsed: protocol.ParsedTarget, bucket: bucket_domain.Bucket, configuration: Configuration, body: ?xml.Node, request_id: []const u8) !std.http.Status {
    const is_notification = eq(configuration.query, "notification");
    if (is_notification) app.policy_mutex.lockUncancelable(app.io.?);
    defer if (is_notification) app.policy_mutex.unlock(app.io.?);
    if (is_notification and body != null) {
        const notifications = @import("../application/s3_notifications.zig");
        const rules = notifications.parse(a, body.?) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const configured = @import("../application/event_destinations.zig").load(app.systemStore(), app.io.?, a, app.master_key.?.bytes) catch return s3.respondError(request, app.allocator, .service_unavailable, request_id);
        defer configured.deinit();
        notifications.validateTargets(rules, configured.value) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    }
    const id = parsed.query("id") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    if (configuration.id_root != null and request.head.method != .GET and id == null) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    if (id) |value| if (value.len == 0 or value.len > 256) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    if (body) |node| {
        if (!eq(node.name, configuration.root)) return s3.respondError(request, app.allocator, .malformed_xml, request_id);
        if (id) |value| if (!eq(text(node, "Id") orelse "", value)) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        if (eq(configuration.query, "cors")) {
            if (node.children.len == 0 or node.children.len > 100) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            for (node.children) |rule| {
                if (!eq(rule.name, "CORSRule") or child(rule, "AllowedOrigin") == null or child(rule, "AllowedMethod") == null) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                for (rule.children) |field| {
                    if (std.mem.indexOfAny(u8, field.text, "\r\n") != null) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    if (eq(field.name, "AllowedMethod") and !eq(field.text, "GET") and !eq(field.text, "PUT") and !eq(field.text, "POST") and !eq(field.text, "DELETE") and !eq(field.text, "HEAD")) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                }
            }
        }
        if (eq(configuration.query, "intelligent-tiering")) {
            @import("../application/s3_tiering.zig").validate(node) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        }
        if (eq(configuration.query, "inventory") or eq(configuration.query, "analytics") or eq(configuration.query, "metrics")) {
            const reports = @import("../application/s3_reports.zig");
            reports.validate(node, configuration.query) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            if (reports.destination(node, configuration.query)) |destination| {
                const name = reports.targetName(destination) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                const target = app.bucketService().?.head(name) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                defer target.deinit(app.allocator);
                if (!eq(target.owner, bucket.owner)) return s3.respondError(request, app.allocator, .access_denied, request_id);
            }
        }
        if (eq(configuration.query, "logging")) {
            if (child(node, "LoggingEnabled")) |enabled| {
                const target_name = text(enabled, "TargetBucket") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                const target = app.bucketService().?.head(target_name) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                defer target.deinit(app.allocator);
                if (!eq(target.owner, bucket.owner)) return s3.respondError(request, app.allocator, .access_denied, request_id);
                if (child(enabled, "TargetGrants") != null) return s3.respondError(request, app.allocator, .not_implemented, request_id);
                if (child(enabled, "TargetObjectKeyFormat")) |format| {
                    if (child(format, "SimplePrefix") == null) return s3.respondError(request, app.allocator, .not_implemented, request_id);
                }
            } else if (node.children.len > 0) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        }
        if (eq(configuration.query, "website")) {
            const index = child(node, "IndexDocument") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            const suffix = text(index, "Suffix") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            if (suffix.len == 0 or std.mem.indexOfAny(u8, suffix, "/\r\n") != null) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            for (node.children) |field| {
                if (!eq(field.name, "IndexDocument") and !eq(field.name, "ErrorDocument")) return s3.respondError(request, app.allocator, .not_implemented, request_id);
            }
        }
        if (eq(configuration.query, "abac")) {
            const status = text(node, "Status") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            if (!eq(status, "Enabled") and !eq(status, "Disabled")) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        }
        // A single instance cannot enable AWS global transfer acceleration or billing.
        if (eq(configuration.query, "accelerate") and !eq(text(node, "Status") orelse "", "Suspended")) return s3.respondError(request, app.allocator, .not_implemented, request_id);
        if (eq(configuration.query, "requestPayment") and !eq(text(node, "Payer") orelse "", "BucketOwner")) return s3.respondError(request, app.allocator, .not_implemented, request_id);
    }
    const key = try path(a, bucket, configuration.query);
    app.state_mutex.lockUncancelable(app.io.?);
    defer app.state_mutex.unlock(app.io.?);
    var document = load(a, app, key) catch return s3.respondError(request, app.allocator, .service_unavailable, request_id);
    if (document != .object) return s3.respondError(request, app.allocator, .internal_error, request_id);
    const item_id = id orelse "";
    if (body) |node| {
        if (!document.object.contains(item_id) and document.object.count() >= 1000) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        try document.object.put(a, item_id, .{ .string = try xml.encode(a, node, namespace) });
        save(a, app, key, document) catch return s3.respondError(request, app.allocator, .service_unavailable, request_id);
        return s3.respondEmpty(request, .ok, request_id, &.{});
    }
    if (request.head.method == .DELETE) {
        _ = document.object.swapRemove(item_id);
        save(a, app, key, document) catch return s3.respondError(request, app.allocator, .service_unavailable, request_id);
        return s3.respondEmpty(request, .no_content, request_id, &.{});
    }
    if (configuration.id_root != null and id == null) {
        // Stable lexicographic tokens permit clients to resume list-by-ID.
        var ids: std.ArrayList([]const u8) = .empty;
        for (document.object.keys()) |value| try ids.append(a, value);
        std.mem.sort([]const u8, ids.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        const token = parsed.query("continuation-token") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        var output: std.Io.Writer.Allocating = .init(a);
        try output.writer.print("<{s}>", .{configuration.id_root.?});
        var count: usize = 0;
        var last: []const u8 = "";
        var more = false;
        for (ids.items) |value| {
            if (token) |after| if (!std.mem.lessThan(u8, after, value)) continue;
            if (count == 100) {
                more = true;
                break;
            }
            const node = try xml.parse(a, document.object.get(value).?.string);
            const encoded = try xml.encode(a, node, null);
            const start = std.mem.indexOf(u8, encoded, "?>").? + 2;
            try output.writer.writeAll(encoded[start..]);
            count += 1;
            last = value;
        }
        try element(&output.writer, "IsTruncated", if (more) "true" else "false");
        if (more) try element(&output.writer, "NextContinuationToken", last);
        try output.writer.print("</{s}>", .{configuration.id_root.?});
        return s3.respondXml(request, output.written(), .ok, request_id, &.{});
    }
    if (document.object.get(item_id)) |value| return s3.respondXml(request, value.string, .ok, request_id, &.{});
    if (configuration.id_root == null and (eq(configuration.query, "notification") or eq(configuration.query, "logging"))) {
        return s3.respondXml(request, try std.fmt.allocPrint(a, "<{s}/>", .{configuration.root}), .ok, request_id, &.{});
    }
    return s3.respondError(request, app.allocator, .no_such_key, request_id);
}

pub fn preflight(request: *std.http.Server.Request, app: *Application, request_id: []const u8) !std.http.Status {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = protocol.parseTarget(a, .GET, request.head.target) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    if (parsed.bucket == null) return s3.respondCorsPreflight(request, request_id);
    const service = app.bucketService() orelse return s3.respondError(request, app.allocator, .service_unavailable, request_id);
    const bucket = service.head(parsed.bucket.?) catch return s3.respondError(request, app.allocator, .no_such_bucket, request_id);
    defer bucket.deinit(app.allocator);
    const document = try load(a, app, try path(a, bucket, "cors"));
    const value = document.object.get("") orelse return s3.respondCorsPreflight(request, request_id);
    const configuration = try xml.parse(a, value.string);
    var origin: []const u8 = "";
    var method: []const u8 = "";
    var requested_headers: []const u8 = "";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) origin = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "access-control-request-method")) method = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "access-control-request-headers")) requested_headers = header.value;
    }
    for (configuration.children) |rule| {
        var origin_allowed = false;
        var method_allowed = false;
        for (rule.children) |field| {
            if (eq(field.name, "AllowedOrigin") and (eq(field.text, "*") or eq(field.text, origin))) origin_allowed = true;
            if (eq(field.name, "AllowedMethod") and eq(field.text, method)) method_allowed = true;
        }
        if (!origin_allowed or !method_allowed) continue;
        var names = std.mem.splitScalar(u8, requested_headers, ',');
        var all_headers = true;
        while (names.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " \t");
            if (trimmed.len == 0) continue;
            var allowed = false;
            for (rule.children) |field| if (eq(field.name, "AllowedHeader") and (eq(field.text, "*") or std.ascii.eqlIgnoreCase(field.text, trimmed))) {
                allowed = true;
            };
            all_headers = all_headers and allowed;
        }
        if (!all_headers) continue;
        const response_headers = [_]std.http.Header{
            .{ .name = "access-control-allow-origin", .value = origin },
            .{ .name = "access-control-allow-methods", .value = method },
            .{ .name = "access-control-allow-headers", .value = requested_headers },
            .{ .name = "vary", .value = "Origin, Access-Control-Request-Method, Access-Control-Request-Headers" },
            .{ .name = "x-amz-request-id", .value = request_id },
        };
        try request.respond("", .{ .status = .no_content, .extra_headers = &response_headers });
        return .no_content;
    }
    return s3.respondError(request, app.allocator, .access_denied, request_id);
}

fn bucketLock(request: *std.http.Server.Request, app: *Application, bucket: bucket_domain.Bucket, body: ?xml.Node, request_id: []const u8) !std.http.Status {
    if (body) |node| {
        if (!eq(node.name, "ObjectLockConfiguration") or !eq(text(node, "ObjectLockEnabled") orelse "", "Enabled")) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        if (!bucket.object_locking) return s3.respondError(request, app.allocator, .invalid_request, request_id);
        var retention: bucket_domain.Retention = .{};
        if (child(node, "Rule")) |rule| {
            const value = child(rule, "DefaultRetention") orelse return s3.respondError(request, app.allocator, .malformed_xml, request_id);
            const mode = text(value, "Mode") orelse "";
            const years = text(value, "Years");
            const days = text(value, "Days");
            if ((years == null) == (days == null) or (!eq(mode, "GOVERNANCE") and !eq(mode, "COMPLIANCE"))) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            const count = std.fmt.parseInt(u64, years orelse days.?, 10) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            if (count == 0 or count > 36500) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            retention = .{ .enabled = true, .mode = if (eq(mode, "GOVERNANCE")) .governance else .compliance, .default_duration_seconds = count * 86400 * @as(u64, if (years != null) 365 else 1) };
        }
        const updated = app.bucketService().?.setRetention(bucket.name, retention) catch |err| return s3.respondError(request, app.allocator, s3.mapBucketError(err), request_id);
        updated.deinit(app.allocator);
        return s3.respondEmpty(request, .ok, request_id, &.{});
    }
    if (request.head.method != .GET) return s3.respondError(request, app.allocator, .invalid_request, request_id);
    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    try output.writer.writeAll("<ObjectLockConfiguration>");
    if (bucket.object_locking) try element(&output.writer, "ObjectLockEnabled", "Enabled");
    if (bucket.retention.enabled) {
        try output.writer.writeAll("<Rule><DefaultRetention>");
        try element(&output.writer, "Mode", if (bucket.retention.mode == .compliance) "COMPLIANCE" else "GOVERNANCE");
        try output.writer.print("<Days>{d}</Days></DefaultRetention></Rule>", .{bucket.retention.default_duration_seconds.? / 86400});
    }
    try output.writer.writeAll("</ObjectLockConfiguration>");
    return s3.respondXml(request, output.written(), .ok, request_id, &.{});
}

fn objectControl(request: *std.http.Server.Request, app: *Application, parsed: protocol.ParsedTarget, access: s3.BucketAccess, headers: []const sigv4.Header, body: ?xml.Node, request_id: []const u8) !std.http.Status {
    const objects = app.objectService().?;
    const version = s3.parseRequestedVersion(parsed) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    const object = (if (version) |id| headVersion(objects, parsed.bucket.?, parsed.key.?, id) else objects.head(parsed.bucket.?, parsed.key.?)) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
    defer object.deinit(app.allocator);
    if (has(parsed.parameters, "restore")) {
        if (!@import("../domain/object.zig").archived(object.storage_class, object.archive_tier)) return s3.respondError(request, app.allocator, .invalid_object_state, request_id);
        const node = body orelse return s3.respondError(request, app.allocator, .malformed_xml, request_id);
        if (!eq(node.name, "RestoreRequest") or child(node, "SelectParameters") != null) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const days = std.fmt.parseInt(i64, text(node, "Days") orelse (if (object.storage_class == .intelligent_tiering) "1" else ""), 10) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        if (days < 1 or days > 36500) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        if (!s3.kmsReadAllowed(app.allocator, access, &object)) return s3.respondError(request, app.allocator, .access_denied, request_id);
        // Local archives retain their ciphertext in the local object store. Verify
        // every byte before atomically publishing the temporary read window.
        {
            var lease = objects.openVersion(parsed.bucket.?, parsed.key.?, object.version_id) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
            defer lease.deinit();
            const VerifySink = struct {
                fn write(_: *anyopaque, _: []const u8) @import("../ports/byte_stream.zig").Sink.Error!void {}
            };
            var context: u8 = 0;
            lease.streamForRestore(.{ .context = &context, .vtable = &.{ .write_all = VerifySink.write } }) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
        }
        const until = std.Io.Clock.real.now(app.io.?).toSeconds() + days * 86400;
        const updated = objects.setRestore(parsed.bucket.?, parsed.key.?, object.version_id, until, object.data_generation) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
        objects.notifyObject(.GET, "ObjectAccessed:Restore", updated);
        updated.deinit(app.allocator);
        return s3.respondEmpty(request, if (object.restored_until == null) .accepted else .ok, request_id, &.{});
    }
    if (has(parsed.parameters, "torrent") or has(parsed.parameters, "select")) return objectData(request, app, parsed, access, body, request_id);
    if (has(parsed.parameters, "encryption")) {
        if (request.head.method != .PUT) return s3.respondError(request, app.allocator, .not_implemented, request_id);
        const node = body orelse return s3.respondError(request, app.allocator, .malformed_xml, request_id);
        const encryption = child(node, "SSE-KMS") orelse return s3.respondError(request, app.allocator, .invalid_request, request_id);
        const key = text(encryption, "KMSKeyArn") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        if (!s3.kmsReadAllowed(app.allocator, access, &object)) return s3.respondError(request, app.allocator, .access_denied, request_id);
        var arena = std.heap.ArenaAllocator.init(app.allocator);
        defer arena.deinit();
        const kms = if (app.kms) |*value| value else return s3.respondError(request, app.allocator, .service_unavailable, request_id);
        const selection = kms.select(arena.allocator(), key) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const principal = access.principal orelse return s3.respondError(request, app.allocator, .access_denied, request_id);
        for ([_][]const u8{ "kms:Encrypt", "kms:GenerateDataKey", "kms:ReEncryptTo" }) |permission| {
            if (!principal.allowsKms(app.allocator, permission, selection.key(), access.context)) return s3.respondError(request, app.allocator, .access_denied, request_id);
        }
        const updated = objects.updateEncryption(parsed.bucket.?, parsed.key.?, object.version_id, selection) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
        updated.deinit(app.allocator);
        return s3.respondEmpty(request, .ok, request_id, &.{});
    }
    if (has(parsed.parameters, "legal-hold") or has(parsed.parameters, "retention")) {
        const bucket = app.bucketService().?.head(parsed.bucket.?) catch |err| return s3.respondError(request, app.allocator, s3.mapBucketError(err), request_id);
        defer bucket.deinit(app.allocator);
        if (!bucket.object_locking) return s3.respondError(request, app.allocator, .invalid_request, request_id);
        if (request.head.method != .GET and request.head.method != .PUT) return s3.respondError(request, app.allocator, .invalid_request, request_id);
    }
    if (has(parsed.parameters, "retention")) {
        if (body) |node| {
            if (!eq(node.name, "Retention")) return s3.respondError(request, app.allocator, .malformed_xml, request_id);
            const mode_text = text(node, "Mode");
            const date = text(node, "RetainUntilDate");
            if ((date == null) != (mode_text == null)) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            const mode: ?bucket_domain.RetentionMode = if (mode_text) |value|
                if (eq(value, "GOVERNANCE")) .governance else if (eq(value, "COMPLIANCE")) .compliance else return s3.respondError(request, app.allocator, .invalid_argument, request_id)
            else
                null;
            const until = if (date) |value| @import("../common/time.zig").parseIso8601(value) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id) else null;
            if (until) |value| if (value <= std.Io.Clock.real.now(app.io.?).toSeconds()) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            const bypass_header = s3.singleHeader(headers, "x-amz-bypass-governance-retention") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            var bypass = false;
            if (bypass_header) |value| {
                if (!eq(value, "true") and !eq(value, "false")) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                if (eq(value, "true")) {
                    const principal = access.principal orelse return s3.respondError(request, app.allocator, .access_denied, request_id);
                    if (!principal.policy.bypass_governance_retention or !principal.allowsWithContext(app.allocator, "s3:BypassGovernanceRetention", parsed.bucket, parsed.key, access.context)) return s3.respondError(request, app.allocator, .access_denied, request_id);
                    bypass = true;
                }
            }
            const updated = objects.setRetention(parsed.bucket.?, parsed.key.?, object.version_id, until, mode, bypass) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
            updated.deinit(app.allocator);
            return s3.respondEmpty(request, .ok, request_id, &.{});
        }
        var output: std.Io.Writer.Allocating = .init(app.allocator);
        defer output.deinit();
        try output.writer.writeAll("<Retention>");
        if (object.retention_until_unix_seconds) |until| {
            try element(&output.writer, "Mode", if (object.retention_mode == .compliance) "COMPLIANCE" else "GOVERNANCE");
            try output.writer.writeAll("<RetainUntilDate>");
            try protocol.writeIsoTime(&output.writer, until);
            try output.writer.writeAll("</RetainUntilDate>");
        }
        try output.writer.writeAll("</Retention>");
        return s3.respondXml(request, output.written(), .ok, request_id, &.{});
    }
    if (has(parsed.parameters, "legal-hold")) {
        if (body) |node| {
            const status = text(node, "Status") orelse "";
            if (!eq(node.name, "LegalHold") or (!eq(status, "ON") and !eq(status, "OFF"))) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
            const updated = objects.setLegalHold(parsed.bucket.?, parsed.key.?, object.version_id, eq(status, "ON")) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
            updated.deinit(app.allocator);
            return s3.respondEmpty(request, .ok, request_id, &.{});
        }
        return s3.respondXml(request, if (object.legal_hold) "<LegalHold><Status>ON</Status></LegalHold>" else "<LegalHold><Status>OFF</Status></LegalHold>", .ok, request_id, &.{});
    }
    if (has(parsed.parameters, "attributes")) {
        const selected = s3.singleHeader(headers, "x-amz-object-attributes") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        var fields = std.mem.splitScalar(u8, selected orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id), ',');
        var output: std.Io.Writer.Allocating = .init(app.allocator);
        defer output.deinit();
        try output.writer.writeAll("<GetObjectAttributesOutput>");
        while (fields.next()) |raw_field| {
            const field = std.mem.trim(u8, raw_field, " ");
            if (eq(field, "ETag")) {
                var etag_buffer: [40]u8 = undefined;
                try element(&output.writer, "ETag", std.mem.trim(u8, s3.formatObjectEtag(&object, &etag_buffer), "\""));
            } else if (eq(field, "ObjectSize")) {
                try output.writer.print("<ObjectSize>{d}</ObjectSize>", .{object.size});
            } else if (eq(field, "StorageClass")) {
                try element(&output.writer, "StorageClass", object.storage_class.wire());
            } else if (eq(field, "Checksum")) {
                if (!s3.kmsReadAllowed(app.allocator, access, &object)) return s3.respondError(request, app.allocator, .access_denied, request_id);
                var lease = objects.openVersion(parsed.bucket.?, parsed.key.?, object.version_id) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
                defer lease.deinit();
                const digest = lease.fullChecksumSha256() catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
                var encoded: [44]u8 = undefined;
                try output.writer.writeAll("<Checksum>");
                try element(&output.writer, "ChecksumSHA256", std.base64.standard.Encoder.encode(&encoded, &digest));
                try element(&output.writer, "ChecksumType", "FULL_OBJECT");
                try output.writer.writeAll("</Checksum>");
            } else if (eq(field, "ObjectParts")) {
                if (object.multipart_manifest) |manifest| {
                    const marker_text = s3.singleHeader(headers, "x-amz-part-number-marker") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    const max_text = s3.singleHeader(headers, "x-amz-max-parts") catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    const marker = std.fmt.parseInt(u16, marker_text orelse "0", 10) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    const max_parts = std.fmt.parseInt(u16, max_text orelse "1000", 10) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    if (max_parts == 0 or max_parts > 1000) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
                    try output.writer.print("<ObjectParts><PartsCount>{d}</PartsCount><PartNumberMarker>{d}</PartNumberMarker><MaxParts>{d}</MaxParts>", .{ manifest.parts.len, marker, max_parts });
                    var count: usize = 0;
                    var last: u16 = marker;
                    var truncated = false;
                    for (manifest.parts) |part| {
                        if (part.number <= marker) continue;
                        if (count == max_parts) {
                            truncated = true;
                            break;
                        }
                        try output.writer.print("<Parts><PartNumber>{d}</PartNumber><Size>{d}</Size></Parts>", .{ part.number, part.size });
                        count += 1;
                        last = part.number;
                    }
                    try element(&output.writer, "IsTruncated", if (truncated) "true" else "false");
                    if (truncated) try output.writer.print("<NextPartNumberMarker>{d}</NextPartNumberMarker>", .{last});
                    try output.writer.writeAll("</ObjectParts>");
                }
            } else return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        }
        try output.writer.writeAll("</GetObjectAttributesOutput>");
        return s3.respondXml(request, output.written(), .ok, request_id, &.{});
    }
    return s3.respondError(request, app.allocator, .not_implemented, request_id);
}

fn headVersion(objects: @import("../application/object_service.zig").ObjectService, bucket: []const u8, key: []const u8, version: @import("../domain/object.zig").VersionId) !@import("../domain/object.zig").Object {
    var lease = try objects.openVersion(bucket, key, version);
    defer lease.deinit();
    const object = lease.metadata();
    return @import("../domain/object.zig").cloneFromView(objects.allocator, object.view(), object.metadata_generation);
}

/// Data operations hold a read lease and authorize KMS decryption just like GetObject.
fn objectData(request: *std.http.Server.Request, app: *Application, parsed: protocol.ParsedTarget, access: s3.BucketAccess, body: ?xml.Node, request_id: []const u8) !std.http.Status {
    const torrent = has(parsed.parameters, "torrent");
    if ((torrent and request.head.method != .GET) or (!torrent and request.head.method != .POST)) return s3.respondError(request, app.allocator, .invalid_request, request_id);
    if (!torrent) {
        const node = body orelse return s3.respondError(request, app.allocator, .malformed_xml, request_id);
        if (!eq(node.name, "SelectObjectContentRequest") or !eq(text(node, "ExpressionType") orelse "", "SQL")) return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const expression = std.mem.trim(u8, text(node, "Expression") orelse "", " \t\r\n;");
        // Explicitly bounded SQL subset; never silently ignore a predicate or projection.
        if (!std.ascii.eqlIgnoreCase(expression, "SELECT * FROM S3Object")) return s3.respondError(request, app.allocator, .not_implemented, request_id);
        const input = child(node, "InputSerialization") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const output = child(node, "OutputSerialization") orelse return s3.respondError(request, app.allocator, .invalid_argument, request_id);
        const csv = child(input, "CSV") orelse return s3.respondError(request, app.allocator, .not_implemented, request_id);
        const out_csv = child(output, "CSV") orelse return s3.respondError(request, app.allocator, .not_implemented, request_id);
        if (out_csv.children.len != 0 or csv.children.len != 0 or !eq(text(input, "CompressionType") orelse "NONE", "NONE")) return s3.respondError(request, app.allocator, .not_implemented, request_id);
    }
    const objects = app.objectService().?;
    const version = s3.parseRequestedVersion(parsed) catch return s3.respondError(request, app.allocator, .invalid_argument, request_id);
    var lease = (if (version) |id| objects.openVersion(parsed.bucket.?, parsed.key.?, id) else objects.open(parsed.bucket.?, parsed.key.?)) catch |err| return s3.respondError(request, app.allocator, s3.mapObjectError(err), request_id);
    defer lease.deinit();
    const object = lease.metadata();
    if (!s3.kmsReadAllowed(app.allocator, access, object)) return s3.respondError(request, app.allocator, .access_denied, request_id);
    // Bound the response assembly until the HTTP event writer supports incremental frames.
    if (object.size > 16 * 1024 * 1024) return s3.respondError(request, app.allocator, .not_implemented, request_id);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source = @import("../application/object_service.zig").LeaseSource.init(&lease, 0, object.size);
    var output: std.Io.Writer.Allocating = .init(a);
    var buffer: [256 * 1024]u8 = undefined;
    if (torrent) {
        var pieces: std.Io.Writer.Allocating = .init(a);
        while (true) {
            const count = try source.interface().read(&buffer);
            if (count == 0) break;
            var digest: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(buffer[0..count], &digest, .{});
            try pieces.writer.writeAll(&digest);
        }
        const name = std.fs.path.basename(parsed.key.?);
        // Canonical bencode dictionary order; trackerless torrents use peer discovery.
        try output.writer.print("d4:infod6:lengthi{d}e4:name{d}:{s}12:piece lengthi262144e6:pieces{d}:", .{ object.size, name.len, name, pieces.written().len });
        try output.writer.writeAll(pieces.written());
        try output.writer.writeAll("ee");
    } else {
        while (true) {
            const count = try source.interface().read(&buffer);
            if (count == 0) break;
            try eventFrame(a, &output.writer, "Records", buffer[0..count]);
        }
        const stats = try std.fmt.allocPrint(a, "<Stats><BytesScanned>{d}</BytesScanned><BytesProcessed>{d}</BytesProcessed><BytesReturned>{d}</BytesReturned></Stats>", .{ object.size, object.size, object.size });
        try eventFrame(a, &output.writer, "Stats", stats);
        try eventFrame(a, &output.writer, "End", "");
    }
    try request.respond(output.written(), .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = if (torrent) "application/x-bittorrent" else "application/vnd.amazon.eventstream" },
        .{ .name = "x-amz-request-id", .value = request_id },
    } });
    return .ok;
}

fn eventFrame(a: A, writer: *std.Io.Writer, kind: []const u8, payload: []const u8) !void {
    var headers: std.Io.Writer.Allocating = .init(a);
    for ([_][2][]const u8{ .{ ":message-type", "event" }, .{ ":event-type", kind }, .{ ":content-type", "application/octet-stream" } }) |entry| {
        try headers.writer.writeByte(@intCast(entry[0].len));
        try headers.writer.writeAll(entry[0]);
        try headers.writer.writeByte(7);
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(entry[1].len), .big);
        try headers.writer.writeAll(&length);
        try headers.writer.writeAll(entry[1]);
    }
    var frame: std.Io.Writer.Allocating = .init(a);
    var prelude: [12]u8 = undefined;
    std.mem.writeInt(u32, prelude[0..4], @intCast(16 + headers.written().len + payload.len), .big);
    std.mem.writeInt(u32, prelude[4..8], @intCast(headers.written().len), .big);
    std.mem.writeInt(u32, prelude[8..12], std.hash.crc.@"CRC-32/ISO-HDLC".hash(prelude[0..8]), .big);
    try frame.writer.writeAll(&prelude);
    try frame.writer.writeAll(headers.written());
    try frame.writer.writeAll(payload);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, std.hash.crc.@"CRC-32/ISO-HDLC".hash(frame.written()), .big);
    try writer.writeAll(frame.written());
    try writer.writeAll(&checksum);
}
