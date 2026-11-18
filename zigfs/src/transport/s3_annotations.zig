const std = @import("std");
const s3 = @import("s3.zig");
const protocol = @import("s3_protocol.zig");
const sigv4 = @import("../auth/sigv4.zig");
const Application = @import("../application/mod.zig").Application;
const annotations = @import("../application/object_annotations.zig");
const A = std.mem.Allocator;

fn element(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print("<{s}>", .{name});
    try protocol.writeXmlEscaped(writer, value);
    try writer.print("</{s}>", .{name});
}

pub fn serve(
    request: *std.http.Server.Request,
    app: *Application,
    parsed: protocol.ParsedTarget,
    access: s3.BucketAccess,
    headers: []const sigv4.Header,
    hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = parsed.query("annotationName") catch return s3.respondError(request, a, .invalid_argument, request_id);
    if (name) |value| {
        if (!annotations.validName(value)) return s3.respondError(request, a, .invalid_argument, request_id);
    } else if (request.head.method != .GET) return s3.respondError(request, a, .invalid_argument, request_id);
    const payload = if (request.head.method == .PUT)
        s3.readXmlPayload(request, a, 1024 * 1024, hash) catch |err| return s3.respondError(request, a, s3.mapXmlPayloadError(err), request_id)
    else
        null;
    if (payload) |bytes| {
        if (bytes.len == 0) return s3.respondError(request, a, .invalid_argument, request_id);
        if (!try validChecksums(a, headers, bytes)) return s3.respondError(request, a, .bad_digest, request_id);
    }
    const objects = app.objectService().?;
    const version = s3.parseRequestedVersion(parsed) catch return s3.respondError(request, a, .invalid_argument, request_id);
    // Keep the parent version pinned until the annotation index is published.
    var lease = (if (version) |id| objects.openVersion(parsed.bucket.?, parsed.key.?, id) else objects.open(parsed.bucket.?, parsed.key.?)) catch |err| return s3.respondError(request, a, s3.mapObjectError(err), request_id);
    defer lease.deinit();
    const object = lease.metadata();
    if (!s3.kmsReadAllowed(a, access, object)) return s3.respondError(request, a, .access_denied, request_id);
    if (s3.singleHeader(headers, "x-amz-object-if-match") catch return s3.respondError(request, a, .invalid_argument, request_id)) |etag| {
        var buffer: [40]u8 = undefined;
        if (!std.mem.eql(u8, etag, s3.formatObjectEtag(object, &buffer))) return s3.respondError(request, a, .precondition_failed, request_id);
    }
    var version_buffer: [32]u8 = undefined;
    const response_headers = [_]std.http.Header{
        .{ .name = "x-amz-object-version-id", .value = object.version_id.write(&version_buffer) },
        .{ .name = "x-amz-server-side-encryption", .value = if (object.encryption_metadata != null and object.encryption_metadata.?.kms != null) "aws:kms" else "AES256" },
    };
    const filename = try annotations.path(a, object);
    if (request.head.method == .PUT or request.head.method == .DELETE) {
        // Serialize only metadata publication; no network delivery happens under this lock.
        app.state_mutex.lockUncancelable(app.io.?);
        const entry: ?annotations.Entry = blk: {
            defer app.state_mutex.unlock(app.io.?);
            if (payload) |bytes| {
                var key = lease.annotationKey() catch |err| return s3.respondError(request, a, s3.mapObjectError(err), request_id);
                defer std.crypto.secureZero(u8, &key);
                break :blk annotations.put(a, app.io.?, app.systemStore(), filename, key, name.?, bytes) catch |err| {
                    return s3.respondError(request, a, if (err == error.AnnotationLimit) .invalid_request else .service_unavailable, request_id);
                };
            }
            annotations.remove(a, app.systemStore(), filename, name.?) catch return s3.respondError(request, a, .service_unavailable, request_id);
            break :blk null;
        };
        if (entry) |stored| {
            var output: std.Io.Writer.Allocating = .init(a);
            try output.writer.writeAll("<PutObjectAnnotationOutput>");
            try element(&output.writer, "Key", object.key);
            try element(&output.writer, "AnnotationName", stored.name);
            try output.writer.writeAll("</PutObjectAnnotationOutput>");
            const extra = response_headers ++ [_]std.http.Header{.{ .name = "etag", .value = stored.etag }};
            return s3.respondXml(request, output.written(), .ok, request_id, &extra);
        }
        return s3.respondEmpty(request, .no_content, request_id, &response_headers);
    }
    app.state_mutex.lockUncancelable(app.io.?);
    // Read the blob under the same lock as its index, so replacement cannot reclaim it.
    const index = annotations.load(a, app.systemStore(), filename) catch {
        app.state_mutex.unlock(app.io.?);
        return s3.respondError(request, a, .service_unavailable, request_id);
    };
    if (name) |value| {
        const entry = annotations.find(index, value) orelse {
            app.state_mutex.unlock(app.io.?);
            return s3.respondError(request, a, .no_such_key, request_id);
        };
        const bytes = blk: {
            defer app.state_mutex.unlock(app.io.?);
            var key = lease.annotationKey() catch |err| return s3.respondError(request, a, s3.mapObjectError(err), request_id);
            defer std.crypto.secureZero(u8, &key);
            break :blk annotations.get(a, app.systemStore(), key, entry) catch return s3.respondError(request, a, .service_unavailable, request_id);
        };
        defer std.crypto.secureZero(u8, bytes);
        var time_buffer: [29]u8 = undefined;
        const extra = response_headers ++ [_]std.http.Header{
            .{ .name = "etag", .value = entry.etag },
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "last-modified", .value = try @import("../common/time.zig").formatHttpDate(entry.modified, &time_buffer) },
            .{ .name = "x-amz-request-id", .value = request_id },
        };
        try request.respond(bytes, .{ .status = .ok, .extra_headers = &extra });
        return .ok;
    }
    app.state_mutex.unlock(app.io.?);
    const prefix = parsed.query("annotation-prefix") catch return s3.respondError(request, a, .invalid_argument, request_id);
    const token = parsed.query("continuation-token") catch return s3.respondError(request, a, .invalid_argument, request_id);
    const maximum_text = parsed.query("max-annotation-results") catch return s3.respondError(request, a, .invalid_argument, request_id);
    const maximum = std.fmt.parseInt(usize, maximum_text orelse "1000", 10) catch return s3.respondError(request, a, .invalid_argument, request_id);
    if (maximum == 0 or maximum > 1000) return s3.respondError(request, a, .invalid_argument, request_id);
    var output: std.Io.Writer.Allocating = .init(a);
    try output.writer.writeAll("<ListObjectAnnotationsOutput>");
    try element(&output.writer, "Bucket", object.bucket_name);
    try element(&output.writer, "Key", object.key);
    var count: usize = 0;
    var last: []const u8 = "";
    var more = false;
    try output.writer.writeAll("<Annotations>");
    for (index.entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix orelse "")) continue;
        if (token) |after| if (!std.mem.lessThan(u8, after, entry.name)) continue;
        if (count == maximum) {
            more = true;
            break;
        }
        try output.writer.writeAll("<AnnotationEntry>");
        try element(&output.writer, "AnnotationName", entry.name);
        try element(&output.writer, "ETag", entry.etag);
        try output.writer.writeAll("<LastModified>");
        try protocol.writeIsoTime(&output.writer, entry.modified);
        try output.writer.print("</LastModified><Size>{d}</Size></AnnotationEntry>", .{entry.size});
        count += 1;
        last = entry.name;
    }
    try output.writer.print("</Annotations><AnnotationCount>{d}</AnnotationCount><MaxAnnotationResults>{d}</MaxAnnotationResults>", .{ count, maximum });
    if (more) try element(&output.writer, "NextContinuationToken", last);
    try output.writer.writeAll("</ListObjectAnnotationsOutput>");
    return s3.respondXml(request, output.written(), .ok, request_id, &response_headers);
}

fn validChecksums(a: A, headers: []const sigv4.Header, bytes: []const u8) !bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-md5") or std.ascii.eqlIgnoreCase(header.name, "x-amz-checksum-md5")) {
            var digest: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(bytes, &digest, .{});
            var encoded: [24]u8 = undefined;
            if (!std.mem.eql(u8, header.value, std.base64.standard.Encoder.encode(&encoded, &digest))) return false;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-amz-checksum-sha256")) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            var encoded: [44]u8 = undefined;
            if (!std.mem.eql(u8, header.value, std.base64.standard.Encoder.encode(&encoded, &digest))) return false;
        } else {
            const name = try std.ascii.allocLowerString(a, header.name);
            if (std.mem.startsWith(u8, name, "x-amz-checksum-")) return false;
        }
    }
    return true;
}
