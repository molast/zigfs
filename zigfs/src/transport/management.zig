const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const bucket_service = @import("../application/bucket_service.zig");
const credential_service = @import("../application/credential_service.zig");
const management_service = @import("../application/management_service.zig");
const multipart_service = @import("../application/multipart_service.zig");
const object_listing = @import("../application/object_listing.zig");
const lifecycle_service = @import("../application/lifecycle_service.zig");
const credential_domain = @import("../domain/credential.zig");
const object_domain = @import("../domain/object.zig");
const multipart_domain = @import("../domain/multipart.zig");
const sigv4 = @import("../auth/sigv4.zig");
const time = @import("../common/time.zig");
const s3_multipart = @import("s3_multipart.zig");
const version = @import("../version.zig").value;

pub const api_prefix = "/_admin/v1";
const max_body_size = 1024 * 1024;

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
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/configuration" },
    .{ .method = .patch, .path = "/_admin/v1/buckets/:name/configuration" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/versions" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/objects" },
    .{ .method = .post, .path = "/_admin/v1/objects/presign" },
    .{ .method = .post, .path = "/_admin/v1/multipart-uploads" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/multipart-uploads" },
    .{ .method = .get, .path = "/_admin/v1/multipart-uploads/:id" },
    .{ .method = .post, .path = "/_admin/v1/multipart-uploads/:id/complete" },
    .{ .method = .delete, .path = "/_admin/v1/multipart-uploads/:id" },
    .{ .method = .get, .path = "/_admin/v1/access-keys" },
    .{ .method = .post, .path = "/_admin/v1/access-keys" },
    .{ .method = .patch, .path = "/_admin/v1/access-keys/:id" },
    .{ .method = .delete, .path = "/_admin/v1/access-keys/:id" },
    .{ .method = .get, .path = "/_admin/v1/storage" },
    .{ .method = .get, .path = "/_admin/v1/system" },
    .{ .method = .get, .path = "/_admin/v1/health" },
    .{ .method = .get, .path = "/_admin/v1/settings" },
};

pub fn serveRequest(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const target = request.head.target;
    const path = requestPath(target);

    if (std.mem.eql(u8, path, api_prefix ++ "/buckets")) {
        return switch (request.head.method) {
            .GET => serveListBuckets(request, application, request_id),
            .POST => serveCreateBucket(request, application, request_id),
            else => respondMethodNotAllowed(request, request_id, "GET, POST"),
        };
    }
    if (std.mem.startsWith(u8, path, api_prefix ++ "/buckets/")) {
        const resource = path[(api_prefix ++ "/buckets/").len..];
        if (std.mem.endsWith(u8, resource, "/configuration")) {
            const raw_name = resource[0 .. resource.len - "/configuration".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) {
                return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            }
            return switch (request.head.method) {
                .GET => serveGetBucketConfiguration(request, application, request_id, raw_name),
                .PATCH => serveUpdateBucketConfiguration(request, application, request_id, raw_name),
                else => respondMethodNotAllowed(request, request_id, "GET, PATCH"),
            };
        }
        if (std.mem.endsWith(u8, resource, "/versions")) {
            if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
            const raw_name = resource[0 .. resource.len - "/versions".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) {
                return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            }
            return serveListObjectVersions(request, application, request_id, raw_name, target);
        }
        if (std.mem.endsWith(u8, resource, "/multipart-uploads")) {
            if (request.head.method != .GET) {
                return respondMethodNotAllowed(request, request_id, "GET");
            }
            const raw_name = resource[0 .. resource.len - "/multipart-uploads".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) {
                return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            }
            return serveListMultipartUploads(request, application, request_id, raw_name, target);
        }
        if (std.mem.endsWith(u8, resource, "/objects")) {
            if (request.head.method != .GET) {
                return respondMethodNotAllowed(request, request_id, "GET");
            }
            const raw_name = resource[0 .. resource.len - "/objects".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) {
                return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            }
            return serveListObjects(request, application, request_id, raw_name, target);
        }
        if (request.head.method != .DELETE) {
            return respondMethodNotAllowed(request, request_id, "DELETE");
        }
        if (resource.len == 0 or std.mem.indexOfScalar(u8, resource, '/') != null) {
            return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
        }
        return serveDeleteBucket(request, application, request_id, resource);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/objects/presign")) {
        if (request.head.method != .POST) {
            return respondMethodNotAllowed(request, request_id, "POST");
        }
        return servePresignObject(request, application, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/multipart-uploads")) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
        return serveCreateMultipartUpload(request, application, request_id);
    }
    if (std.mem.startsWith(u8, path, api_prefix ++ "/multipart-uploads/")) {
        const resource = path[(api_prefix ++ "/multipart-uploads/").len..];
        if (std.mem.endsWith(u8, resource, "/complete")) {
            if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
            const upload_id = resource[0 .. resource.len - "/complete".len];
            if (upload_id.len == 0 or std.mem.indexOfScalar(u8, upload_id, '/') != null) {
                return respondError(request, request_id, .bad_request, "InvalidUploadId", "upload id is invalid");
            }
            return serveCompleteMultipartUpload(request, application, request_id, upload_id);
        }
        if (resource.len == 0 or std.mem.indexOfScalar(u8, resource, '/') != null) {
            return respondError(request, request_id, .bad_request, "InvalidUploadId", "upload id is invalid");
        }
        return switch (request.head.method) {
            .GET => serveGetMultipartUpload(request, application, request_id, resource, target),
            .DELETE => serveAbortMultipartUpload(request, application, request_id, resource, target),
            else => respondMethodNotAllowed(request, request_id, "GET, DELETE"),
        };
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/access-keys")) {
        return switch (request.head.method) {
            .GET => serveListAccessKeys(request, application, request_id),
            .POST => serveCreateAccessKey(request, application, request_id),
            else => respondMethodNotAllowed(request, request_id, "GET, POST"),
        };
    }
    if (std.mem.startsWith(u8, path, api_prefix ++ "/access-keys/")) {
        const raw_access_key = path[(api_prefix ++ "/access-keys/").len..];
        if (raw_access_key.len == 0 or std.mem.indexOfScalar(u8, raw_access_key, '/') != null) {
            return respondError(request, request_id, .bad_request, "InvalidAccessKey", "access key is invalid");
        }
        return switch (request.head.method) {
            .PATCH => serveUpdateAccessKey(request, application, request_id, raw_access_key),
            .DELETE => serveDeleteAccessKey(request, application, request_id, raw_access_key),
            else => respondMethodNotAllowed(request, request_id, "PATCH, DELETE"),
        };
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/storage")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
        return serveStorage(request, application, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/system")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
        return serveSystem(request, application, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/health")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
        return serveHealth(request, application, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/settings")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
        return serveSettings(request, application, request_id);
    }

    return respondError(request, request_id, .not_found, "NotFound", "management endpoint does not exist");
}

fn serveListBuckets(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const result = service.list() catch |err| return respondBucketError(request, request_id, err);
    defer result.deinit(application.allocator);

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (result.buckets) |bucket| try writeBucket(&json, bucket);
    try json.endArray();
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

const CreateBucketRequest = struct {
    name: []const u8,
    owner: []const u8,
};

fn serveCreateBucket(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const parsed = try parseJsonBody(CreateBucketRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const result = service.create(parsed.value.name, parsed.value.owner) catch |err| {
        audit(application, request_id, "create_bucket", parsed.value.name, @errorName(err));
        return respondBucketError(request, request_id, err);
    };
    defer result.deinit(application.allocator);
    audit(application, request_id, "create_bucket", parsed.value.name, if (result.created) "created" else "exists");

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeBucket(&json, result.bucket);
    return respondJsonBytes(request, request_id, if (result.created) .created else .ok, output.written());
}

fn serveDeleteBucket(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    };
    defer application.allocator.free(name);
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    service.delete(name) catch |err| {
        if (err == error.BucketNotFound) {
            audit(application, request_id, "delete_bucket", name, "absent");
            return respondNoContent(request, request_id);
        }
        audit(application, request_id, "delete_bucket", name, @errorName(err));
        return respondBucketError(request, request_id, err);
    };
    audit(application, request_id, "delete_bucket", name, "deleted");
    return respondNoContent(request, request_id);
}

const UpdateBucketConfigurationRequest = struct {
    versioning: ?[]const u8 = null,
    lifecycle_configuration: ?[]const u8 = null,
    clear_lifecycle: bool = false,
};

fn serveGetBucketConfiguration(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    };
    defer application.allocator.free(name);
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = service.head(name) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(application.allocator);
    return respondBucketConfiguration(request, request_id, bucket);
}

fn serveUpdateBucketConfiguration(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    };
    defer application.allocator.free(name);
    const parsed = try parseJsonBody(UpdateBucketConfigurationRequest, request, application.allocator, request_id) orelse return .bad_request;
    defer parsed.deinit();
    if (parsed.value.versioning == null and parsed.value.lifecycle_configuration == null and !parsed.value.clear_lifecycle) {
        return respondError(request, request_id, .bad_request, "InvalidRequest", "at least one bucket setting is required");
    }
    if (parsed.value.lifecycle_configuration != null and parsed.value.clear_lifecycle) {
        return respondError(request, request_id, .bad_request, "InvalidRequest", "lifecycle configuration cannot be set and cleared together");
    }
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    if (parsed.value.versioning) |status| {
        const versioning: @import("../domain/bucket.zig").Versioning = if (std.mem.eql(u8, status, "Enabled"))
            .enabled
        else if (std.mem.eql(u8, status, "Suspended"))
            .suspended
        else
            return respondError(request, request_id, .bad_request, "InvalidVersioning", "versioning must be Enabled or Suspended");
        const updated = service.setVersioning(name, versioning) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    }
    if (parsed.value.lifecycle_configuration) |configuration_xml| {
        const configuration = lifecycle_service.parse(application.allocator, configuration_xml) catch |err| {
            return respondError(
                request,
                request_id,
                if (err == error.UnsupportedFeature) .not_implemented else .bad_request,
                if (err == error.UnsupportedFeature) "UnsupportedLifecycleFeature" else "InvalidLifecycleConfiguration",
                "lifecycle configuration is invalid or unsupported",
            );
        };
        configuration.deinit(application.allocator);
        const updated = service.putLifecycle(name, configuration_xml) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    } else if (parsed.value.clear_lifecycle) {
        const updated = service.deleteLifecycle(name) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    }
    const bucket = service.head(name) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(application.allocator);
    audit(application, request_id, "update_bucket_configuration", name, "updated");
    return respondBucketConfiguration(request, request_id, bucket);
}

fn respondBucketConfiguration(
    request: *std.http.Server.Request,
    request_id: []const u8,
    bucket: @import("../domain/bucket.zig").Bucket,
) !std.http.Status {
    return respondJson(request, request_id, .ok, .{
        .name = bucket.name,
        .versioning = switch (bucket.versioning) {
            .unversioned => "Unversioned",
            .enabled => "Enabled",
            .suspended => "Suspended",
        },
        .lifecycle_configuration = bucket.lifecycle_configuration,
    });
}

fn serveListObjectVersions(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
    target: []const u8,
) !std.http.Status {
    const bucket = decodeComponent(application.allocator, raw_name, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    };
    defer application.allocator.free(bucket);
    var query = parseListQuery(application.allocator, target) catch {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "list query is invalid");
    };
    defer query.deinit(application.allocator);
    if (query.continuation_token != null) return respondError(request, request_id, .bad_request, "InvalidQuery", "continuation_token is not supported for version browsing");
    const service = application.objectService() orelse return respondNotReady(request, request_id);
    const result = service.listVersions(bucket, query.prefix orelse "") catch |err| {
        return respondError(request, request_id, .internal_server_error, "ListVersionsFailed", @errorName(err));
    };
    defer result.deinit(application.allocator);
    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (result.entries) |entry| {
        var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
        var modified_buffer: [20]u8 = undefined;
        try json.write(.{
            .key = entry.key,
            .version_id = entry.version_id.write(&version_buffer),
            .is_latest = entry.is_latest,
            .is_delete_marker = entry.is_delete_marker,
            .size = entry.size,
            .last_modified = time.formatIso8601(entry.last_modified_unix_seconds, &modified_buffer) catch return error.WriteFailed,
        });
    }
    try json.endArray();
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

fn serveListObjects(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
    target: []const u8,
) !std.http.Status {
    const bucket = decodeComponent(application.allocator, raw_name, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    };
    defer application.allocator.free(bucket);
    var query = parseListQuery(application.allocator, target) catch {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "list query is invalid");
    };
    defer query.deinit(application.allocator);

    const service = application.objectListing() orelse return respondNotReady(request, request_id);
    const result = service.list(bucket, .{
        .prefix = query.prefix orelse "",
        .continuation_token = query.continuation_token,
    }) catch |err| return respondListingError(request, request_id, err);
    defer result.deinit(application.allocator);

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (result.objects) |object| try writeObject(&json, object);
    try json.endArray();
    if (result.next_continuation_token) |token| {
        try json.objectField("continuation_token");
        try json.write(token);
    }
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

const PresignObjectRequest = struct {
    access_key: []const u8,
    bucket: []const u8,
    key: []const u8,
    method: []const u8,
    expires_seconds: u64,
    upload_id: ?[]const u8 = null,
    part_number: ?u16 = null,
    version_id: ?[]const u8 = null,
};

const CreateMultipartUploadRequest = struct {
    bucket: []const u8,
    key: []const u8,
    content_type: []const u8 = "application/octet-stream",
};

const CompleteMultipartPartRequest = struct {
    part_number: u16,
    etag: []const u8,
};

const CompleteMultipartUploadRequest = struct {
    bucket: []const u8,
    key: []const u8,
    parts: []const CompleteMultipartPartRequest,
};

fn serveCreateMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const parsed = try parseJsonBody(CreateMultipartUploadRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    const multiparts = application.multipartService() orelse return respondNotReady(request, request_id);
    const upload = multiparts.create(parsed.value.bucket, parsed.value.key, .{
        .content_type = parsed.value.content_type,
    }) catch |err| return respondMultipartError(request, request_id, err);
    defer upload.deinit(application.allocator);
    audit(application, request_id, "create_multipart_upload", parsed.value.key, "created");
    return respondMultipartUpload(request, application, request_id, .created, upload);
}

fn serveListMultipartUploads(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_bucket: []const u8,
    target: []const u8,
) !std.http.Status {
    const bucket = decodeComponent(application.allocator, raw_bucket, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    };
    defer application.allocator.free(bucket);
    var query = parseMultipartListQuery(application.allocator, target) catch {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "multipart list query is invalid");
    };
    defer query.deinit(application.allocator);
    const multiparts = application.multipartService() orelse return respondNotReady(request, request_id);
    const result = multiparts.listUploads(bucket, .{
        .prefix = query.prefix orelse "",
        .key_marker = query.key_marker,
        .upload_id_marker = query.upload_id_marker,
        .max_uploads = query.max_uploads,
    }) catch |err| return respondMultipartError(request, request_id, err);
    defer result.deinit(application.allocator);

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (result.uploads) |upload| {
        try json.beginObject();
        try json.objectField("upload_id");
        try json.write(upload.upload_id);
        try json.objectField("bucket");
        try json.write(bucket);
        try json.objectField("key");
        try json.write(upload.key);
        try json.objectField("initiated_at");
        var initiated_buffer: [20]u8 = undefined;
        try json.write(time.formatIso8601(upload.initiated_at_unix_seconds, &initiated_buffer) catch return error.WriteFailed);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("is_truncated");
    try json.write(result.is_truncated);
    if (result.next_key_marker) |marker| {
        try json.objectField("next_key_marker");
        try json.write(marker);
    }
    if (result.next_upload_id_marker) |marker| {
        try json.objectField("next_upload_id_marker");
        try json.write(marker);
    }
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

fn serveGetMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    upload_id: []const u8,
    target: []const u8,
) !std.http.Status {
    var address = parseMultipartAddressQuery(application.allocator, target) catch {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "multipart address is invalid");
    };
    defer address.deinit(application.allocator);
    if (address.bucket == null or address.key == null) {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "bucket and key are required");
    }
    const multiparts = application.multipartService() orelse return respondNotReady(request, request_id);
    const upload = multiparts.listParts(address.bucket.?, address.key.?, upload_id) catch |err| {
        return respondMultipartError(request, request_id, err);
    };
    defer upload.deinit(application.allocator);
    return respondMultipartUpload(request, application, request_id, .ok, upload);
}

fn serveCompleteMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    upload_id: []const u8,
) !std.http.Status {
    const parsed = try parseJsonBody(CompleteMultipartUploadRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    if (parsed.value.parts.len == 0 or parsed.value.parts.len > multipart_domain.max_parts) {
        return respondError(request, request_id, .bad_request, "InvalidPart", "completion parts are invalid");
    }
    const parts = application.allocator.alloc(multipart_service.CompletePart, parsed.value.parts.len) catch {
        return respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage service is unavailable");
    };
    defer application.allocator.free(parts);
    for (parsed.value.parts, 0..) |part, index| {
        parts[index] = .{
            .number = part.part_number,
            .etag_md5 = s3_multipart.parseEtag(part.etag) orelse {
                return respondError(request, request_id, .bad_request, "InvalidPart", "part ETag is invalid");
            },
        };
    }
    const multiparts = application.multipartService() orelse return respondNotReady(request, request_id);
    const object = multiparts.complete(parsed.value.bucket, parsed.value.key, upload_id, parts) catch |err| {
        return respondMultipartError(request, request_id, err);
    };
    defer object.deinit(application.allocator);
    audit(application, request_id, "complete_multipart_upload", parsed.value.key, "completed");
    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeObject(&json, object);
    return respondJsonBytes(request, request_id, .ok, output.written());
}

fn serveAbortMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    upload_id: []const u8,
    target: []const u8,
) !std.http.Status {
    var address = parseMultipartAddressQuery(application.allocator, target) catch {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "multipart address is invalid");
    };
    defer address.deinit(application.allocator);
    if (address.bucket == null or address.key == null) {
        return respondError(request, request_id, .bad_request, "InvalidQuery", "bucket and key are required");
    }
    const multiparts = application.multipartService() orelse return respondNotReady(request, request_id);
    multiparts.abort(address.bucket.?, address.key.?, upload_id) catch |err| {
        if (err != error.UploadNotFound) return respondMultipartError(request, request_id, err);
    };
    audit(application, request_id, "abort_multipart_upload", address.key.?, "aborted");
    return respondNoContent(request, request_id);
}

fn respondMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    status: std.http.Status,
    upload: multipart_domain.Upload,
) !std.http.Status {
    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    var upload_id_buffer: [32]u8 = undefined;
    try json.objectField("upload_id");
    try json.write(multipart_domain.formatUploadId(upload.id, &upload_id_buffer));
    try json.objectField("bucket");
    try json.write(upload.bucket_name);
    try json.objectField("key");
    try json.write(upload.key);
    try json.objectField("content_type");
    try json.write(upload.content_type);
    try json.objectField("initiated_at");
    var initiated_buffer: [20]u8 = undefined;
    try json.write(time.formatIso8601(upload.initiated_at_unix_seconds, &initiated_buffer) catch return error.WriteFailed);
    try json.objectField("parts");
    try json.beginArray();
    var uploaded_bytes: u64 = 0;
    for (upload.parts) |part| {
        uploaded_bytes += part.size;
        try json.beginObject();
        try json.objectField("part_number");
        try json.write(part.number);
        try json.objectField("size");
        try json.write(part.size);
        try json.objectField("etag");
        const etag = std.fmt.bytesToHex(part.etag_md5, .lower);
        try json.write(&etag);
        try json.objectField("last_modified");
        var modified_buffer: [20]u8 = undefined;
        try json.write(time.formatIso8601(part.last_modified_unix_seconds, &modified_buffer) catch return error.WriteFailed);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("uploaded_bytes");
    try json.write(uploaded_bytes);
    try json.endObject();
    return respondJsonBytes(request, request_id, status, output.written());
}

fn servePresignObject(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const parsed = try parseJsonBody(PresignObjectRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    const value = parsed.value;
    const multipart_part = value.upload_id != null or value.part_number != null;
    const requested_version = if (value.version_id) |version_id|
        object_domain.parseVersionId(version_id) catch {
            return respondError(request, request_id, .bad_request, "InvalidVersionId", "version ID is invalid");
        }
    else
        null;
    if ((!std.mem.eql(u8, value.method, "GET") and
        !std.mem.eql(u8, value.method, "PUT") and
        !std.mem.eql(u8, value.method, "DELETE")) or
        value.expires_seconds == 0 or value.expires_seconds > sigv4.max_presigned_expiry_seconds or
        (multipart_part and (value.upload_id == null or value.part_number == null or
            !std.mem.eql(u8, value.method, "PUT") or value.part_number.? == 0 or
            value.part_number.? > multipart_domain.max_parts)) or
        (requested_version != null and (multipart_part or std.mem.eql(u8, value.method, "PUT"))))
    {
        return respondError(request, request_id, .bad_request, "InvalidPresignRequest", "method or expiry is invalid");
    }
    object_domain.validateKey(value.key) catch {
        return respondError(request, request_id, .bad_request, "InvalidObjectKey", "object key is invalid");
    };

    const credentials = application.credentialService() orelse return respondNotReady(request, request_id);
    var material = credentials.resolveForAuth(value.access_key) catch |err| {
        return respondCredentialError(request, request_id, err);
    };
    defer material.deinit(application.allocator);
    const required_action: credential_domain.Action = if (std.mem.eql(u8, value.method, "GET"))
        .get_object
    else if (std.mem.eql(u8, value.method, "PUT"))
        .put_object
    else
        .delete_object;
    if (!material.policy.allows(required_action)) {
        return respondError(request, request_id, .forbidden, "AccessDenied", "access key policy does not allow this operation");
    }

    const buckets = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = buckets.head(value.bucket) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(application.allocator);
    if (!std.mem.eql(u8, bucket.owner, material.owner)) {
        return respondError(request, request_id, .forbidden, "AccessDenied", "access key does not own this bucket");
    }
    if (multipart_part) {
        const multiparts = application.multipartService() orelse return respondNotReady(request, request_id);
        const upload = multiparts.listParts(value.bucket, value.key, value.upload_id.?) catch |err| {
            return respondMultipartError(request, request_id, err);
        };
        upload.deinit(application.allocator);
    }

    const encoded_key = try encodePath(application.allocator, value.key);
    defer application.allocator.free(encoded_key);
    const endpoint_host = publicEndpointHost(application.config.s3_public_endpoint);
    const host = if (application.config.s3_virtual_hosted_style)
        try std.fmt.allocPrint(application.allocator, "{s}.{s}", .{ bucket.name, endpoint_host })
    else
        endpoint_host;
    defer if (application.config.s3_virtual_hosted_style) application.allocator.free(host);
    const base_target = if (application.config.s3_virtual_hosted_style)
        try std.fmt.allocPrint(application.allocator, "/{s}", .{encoded_key})
    else
        try std.fmt.allocPrint(application.allocator, "/{s}/{s}", .{ bucket.name, encoded_key });
    defer application.allocator.free(base_target);
    const unsigned_target = if (multipart_part)
        try std.fmt.allocPrint(application.allocator, "{s}?partNumber={d}&uploadId={s}", .{
            base_target,
            value.part_number.?,
            value.upload_id.?,
        })
    else if (value.version_id) |version_id|
        try std.fmt.allocPrint(application.allocator, "{s}?versionId={s}", .{ base_target, version_id })
    else
        base_target;
    defer if (multipart_part or value.version_id != null) application.allocator.free(unsigned_target);
    const headers = [_]sigv4.Header{.{ .name = "host", .value = host }};
    const now = std.Io.Clock.real.now(application.io.?).toSeconds();
    var date_buffer: [16]u8 = undefined;
    const amz_date = time.formatAmzDate(now, &date_buffer) catch {
        return respondError(request, request_id, .internal_server_error, "InternalError", "could not create presigned URL");
    };
    const signed_target = sigv4.presignTarget(application.allocator, .{
        .method = value.method,
        .target = unsigned_target,
        .headers = &headers,
        .access_key = value.access_key,
        .secret_key = material.secret_key,
        .amz_date = amz_date,
        .region = application.config.s3_region,
        .expires_seconds = value.expires_seconds,
        .session_token = material.session_token,
    }) catch {
        return respondError(request, request_id, .internal_server_error, "InternalError", "could not create presigned URL");
    };
    defer application.allocator.free(signed_target);
    const url = if (application.config.s3_virtual_hosted_style)
        try std.fmt.allocPrint(
            application.allocator,
            "{s}{s}{s}",
            .{
                if (std.mem.startsWith(u8, application.config.s3_public_endpoint, "http://")) "http://" else "https://",
                host,
                signed_target,
            },
        )
    else
        try std.fmt.allocPrint(
            application.allocator,
            "{s}{s}",
            .{ application.config.s3_public_endpoint, signed_target },
        );
    defer application.allocator.free(url);
    var expiry_buffer: [20]u8 = undefined;
    const expires_at = time.formatIso8601(now + @as(i64, @intCast(value.expires_seconds)), &expiry_buffer) catch {
        return respondError(request, request_id, .internal_server_error, "InternalError", "could not create presigned URL");
    };
    return respondJson(request, request_id, .ok, .{ .url = url, .expires_at = expires_at });
}

fn serveListAccessKeys(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const service = application.credentialService() orelse return respondNotReady(request, request_id);
    const result = service.list() catch |err| return respondCredentialError(request, request_id, err);
    defer result.deinit(application.allocator);

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (result.credentials) |details| {
        try writeCredential(
            &json,
            details.credential,
            details.secret_key,
            details.session_token,
        );
    }
    try json.endArray();
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

const PolicyRequest = struct {
    bucket_read: bool = true,
    bucket_write: bool = true,
    object_read: bool = true,
    object_write: bool = true,

    fn domain(self: PolicyRequest) credential_domain.Policy {
        return .{
            .bucket_read = self.bucket_read,
            .bucket_write = self.bucket_write,
            .object_read = self.object_read,
            .object_write = self.object_write,
        };
    }
};

const CreateAccessKeyRequest = struct {
    owner: []const u8,
    policy: PolicyRequest = .{},
    ttl_seconds: ?u64 = null,
};

fn serveCreateAccessKey(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const parsed = try parseJsonBody(CreateAccessKeyRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    const service = application.credentialService() orelse return respondNotReady(request, request_id);
    var result = service.createWithTTL(
        parsed.value.owner,
        parsed.value.policy.domain(),
        parsed.value.ttl_seconds,
    ) catch |err| {
        audit(application, request_id, "create_access_key", parsed.value.owner, @errorName(err));
        return respondCredentialError(request, request_id, err);
    };
    defer result.deinit(application.allocator);
    audit(application, request_id, "create_access_key", result.credential.access_key, "created");

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeCredential(&json, result.credential, &result.secret_key, if (result.session_token) |*token| token else null);
    return respondJsonBytes(request, request_id, .created, output.written());
}

const UpdateAccessKeyRequest = struct {
    enabled: bool,
};

fn serveUpdateAccessKey(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_access_key: []const u8,
) !std.http.Status {
    const access_key = decodeComponent(application.allocator, raw_access_key, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidAccessKey", "access key is invalid");
    };
    defer application.allocator.free(access_key);
    const parsed = try parseJsonBody(UpdateAccessKeyRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    const service = application.credentialService() orelse return respondNotReady(request, request_id);
    const credential = service.update(access_key, .{ .enabled = parsed.value.enabled }) catch |err| {
        audit(application, request_id, "update_access_key", access_key, @errorName(err));
        return respondCredentialError(request, request_id, err);
    };
    defer credential.deinit(application.allocator);
    audit(application, request_id, "update_access_key", access_key, if (parsed.value.enabled) "enabled" else "disabled");

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeCredential(&json, credential, null, null);
    return respondJsonBytes(request, request_id, .ok, output.written());
}

fn serveDeleteAccessKey(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_access_key: []const u8,
) !std.http.Status {
    const access_key = decodeComponent(application.allocator, raw_access_key, false) catch {
        return respondError(request, request_id, .bad_request, "InvalidAccessKey", "access key is invalid");
    };
    defer application.allocator.free(access_key);
    const service = application.credentialService() orelse return respondNotReady(request, request_id);
    const deleted = service.delete(access_key) catch |err| {
        audit(application, request_id, "delete_access_key", access_key, @errorName(err));
        return respondCredentialError(request, request_id, err);
    };
    audit(application, request_id, "delete_access_key", access_key, if (deleted) "deleted" else "absent");
    return respondNoContent(request, request_id);
}

fn serveStorage(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const service = application.managementService() orelse return respondNotReady(request, request_id);
    const snapshot = service.snapshot() catch |err| return respondManagementError(request, request_id, err);
    return respondJson(request, request_id, .ok, .{
        .measurement = "logical_object_bytes",
        .total = @as(?u64, null),
        .used = snapshot.object_bytes,
        .available = @as(?u64, null),
    });
}

fn serveSystem(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const service = application.managementService() orelse return respondNotReady(request, request_id);
    const snapshot = service.snapshot() catch |err| return respondManagementError(request, request_id, err);
    return respondJson(request, request_id, .ok, .{
        .version = version,
        .uptime = snapshot.uptime_seconds,
        .storage_used = snapshot.object_bytes,
        .objects = snapshot.objects,
        .buckets = snapshot.buckets,
    });
}

fn serveHealth(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const state = application.recoveryState().*;
    const status = if (state.isReady())
        "ready"
    else if (state.status == .recovery_required)
        "degraded"
    else
        "recovery";
    const actions: []const []const u8 = if (state.status == .recovery_required)
        &.{ "inspect_logs", "restore_from_backup" }
    else
        &.{};
    return respondJson(request, request_id, .ok, .{
        .status = status,
        .recovery = @tagName(state.status),
        .reason = @tagName(state.failure),
        .actions = actions,
    });
}

fn serveSettings(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const config = application.config;
    return respondJson(request, request_id, .ok, .{
        .api_address = config.api_address,
        .s3_public_endpoint = config.s3_public_endpoint,
        .s3_virtual_hosted_style = config.s3_virtual_hosted_style,
        .s3_region = config.s3_region,
        .request_time_skew_seconds = config.s3_request_time_skew_seconds,
        .multipart_expiry_seconds = config.s3_multipart_expiry_seconds,
        .lifecycle_scan_interval_seconds = config.s3_lifecycle_scan_interval_seconds,
        .stream_buffer_size = config.stream_buffer_size,
        .metrics_enabled = config.metrics_enabled,
        .metrics_address = config.metrics_address,
        .admin_session_ttl_seconds = config.admin_session_ttl_seconds,
        .reload_required = true,
    });
}

fn writeBucket(json: *std.json.Stringify, bucket: anytype) !void {
    var created_buffer: [20]u8 = undefined;
    const created_at = try time.formatIso8601(bucket.created_at_unix_seconds, &created_buffer);
    try json.write(.{
        .name = bucket.name,
        .owner = bucket.owner,
        .versioning = switch (bucket.versioning) {
            .unversioned => "Unversioned",
            .enabled => "Enabled",
            .suspended => "Suspended",
        },
        .lifecycle_enabled = bucket.lifecycle_configuration != null,
        .created_at = created_at,
    });
}

fn writeObject(json: *std.json.Stringify, object: anytype) !void {
    var modified_buffer: [20]u8 = undefined;
    const last_modified = try time.formatIso8601(object.last_modified_unix_seconds, &modified_buffer);
    const etag_hex = std.fmt.bytesToHex(object.etag_md5, .lower);
    var etag_buffer: [2 + 32 + 1 + 5]u8 = undefined;
    const etag = if (object.etag_part_count == 0)
        try std.fmt.bufPrint(&etag_buffer, "\"{s}\"", .{&etag_hex})
    else
        try std.fmt.bufPrint(&etag_buffer, "\"{s}-{d}\"", .{ &etag_hex, object.etag_part_count });
    try json.write(.{
        .key = object.key,
        .size = object.size,
        .etag = etag,
        .last_modified = last_modified,
    });
}

fn writeCredential(
    json: *std.json.Stringify,
    credential: anytype,
    secret_key: ?[]const u8,
    session_token: ?[]const u8,
) !void {
    var created_buffer: [20]u8 = undefined;
    const created_at = try time.formatIso8601(credential.created_at_unix_seconds, &created_buffer);
    try json.beginObject();
    try json.objectField("id");
    try json.write(credential.access_key);
    try json.objectField("access_key");
    try json.write(credential.access_key);
    try json.objectField("owner");
    try json.write(credential.owner);
    try json.objectField("enabled");
    try json.write(credential.status == .active);
    try json.objectField("policy");
    try json.write(credential.policy);
    try json.objectField("created_at");
    try json.write(created_at);
    try json.objectField("kind");
    try json.write(@tagName(credential.kind));
    if (credential.expires_at_unix_seconds) |expires_at_value| {
        var expires_buffer: [20]u8 = undefined;
        const expires_at = try time.formatIso8601(expires_at_value, &expires_buffer);
        try json.objectField("expires_at");
        try json.write(expires_at);
    }
    if (secret_key) |secret| {
        try json.objectField("secret_key");
        try json.write(secret);
    }
    if (session_token) |token| {
        try json.objectField("session_token");
        try json.write(token);
    }
    try json.endObject();
}

fn parseJsonBody(
    comptime T: type,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    request_id: []const u8,
) !?std.json.Parsed(T) {
    var read_buffer: [4096]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&read_buffer);
    const body = body_reader.allocRemaining(allocator, .limited(max_body_size)) catch |err| switch (err) {
        error.StreamTooLong => {
            _ = try respondError(request, request_id, .payload_too_large, "PayloadTooLarge", "request body is too large");
            return null;
        },
        else => return err,
    };
    defer allocator.free(body);
    return std.json.parseFromSlice(T, allocator, body, .{ .allocate = .alloc_always }) catch {
        _ = try respondError(request, request_id, .bad_request, "InvalidRequest", "request body is invalid");
        return null;
    };
}

const ListQuery = struct {
    prefix: ?[]u8 = null,
    continuation_token: ?[]u8 = null,

    fn deinit(self: *ListQuery, allocator: std.mem.Allocator) void {
        if (self.prefix) |value| allocator.free(value);
        if (self.continuation_token) |value| allocator.free(value);
        self.* = .{};
    }
};

const MultipartListQuery = struct {
    prefix: ?[]u8 = null,
    key_marker: ?[]u8 = null,
    upload_id_marker: ?[]u8 = null,
    max_uploads: usize = multipart_service.max_list_uploads,

    fn deinit(self: *MultipartListQuery, allocator: std.mem.Allocator) void {
        if (self.prefix) |value| allocator.free(value);
        if (self.key_marker) |value| allocator.free(value);
        if (self.upload_id_marker) |value| allocator.free(value);
        self.* = .{};
    }
};

const MultipartAddressQuery = struct {
    bucket: ?[]u8 = null,
    key: ?[]u8 = null,

    fn deinit(self: *MultipartAddressQuery, allocator: std.mem.Allocator) void {
        if (self.bucket) |value| allocator.free(value);
        if (self.key) |value| allocator.free(value);
        self.* = .{};
    }
};

fn parseListQuery(allocator: std.mem.Allocator, target: []const u8) !ListQuery {
    const separator = std.mem.indexOfScalar(u8, target, '?') orelse return .{};
    const raw_query = target[separator + 1 ..];
    if (raw_query.len == 0) return .{};
    var result: ListQuery = .{};
    errdefer result.deinit(allocator);
    var parameters = std.mem.splitScalar(u8, raw_query, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidQuery;
        const equals = std.mem.indexOfScalar(u8, parameter, '=');
        const name = if (equals) |position| parameter[0..position] else parameter;
        const raw_value = if (equals) |position| parameter[position + 1 ..] else "";
        const value = try decodeComponent(allocator, raw_value, true);
        if (std.mem.eql(u8, name, "prefix")) {
            if (result.prefix != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.prefix = value;
        } else if (std.mem.eql(u8, name, "continuation_token")) {
            if (result.continuation_token != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.continuation_token = value;
        } else {
            allocator.free(value);
            return error.InvalidQuery;
        }
    }
    return result;
}

fn parseMultipartListQuery(allocator: std.mem.Allocator, target: []const u8) !MultipartListQuery {
    var result: MultipartListQuery = .{};
    errdefer result.deinit(allocator);
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return result;
    const raw_query = target[query_start + 1 ..];
    if (raw_query.len == 0) return result;
    var parameters = std.mem.splitScalar(u8, raw_query, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidQuery;
        const equals = std.mem.indexOfScalar(u8, parameter, '=');
        const name = if (equals) |position| parameter[0..position] else parameter;
        const raw_value = if (equals) |position| parameter[position + 1 ..] else "";
        const value = try decodeComponent(allocator, raw_value, true);
        if (std.mem.eql(u8, name, "prefix")) {
            if (result.prefix != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.prefix = value;
        } else if (std.mem.eql(u8, name, "key_marker")) {
            if (result.key_marker != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.key_marker = value;
        } else if (std.mem.eql(u8, name, "upload_id_marker")) {
            if (result.upload_id_marker != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.upload_id_marker = value;
        } else if (std.mem.eql(u8, name, "max_uploads")) {
            if (value.len == 0) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.max_uploads = std.fmt.parseInt(usize, value, 10) catch {
                allocator.free(value);
                return error.InvalidQuery;
            };
            allocator.free(value);
        } else {
            allocator.free(value);
            return error.InvalidQuery;
        }
    }
    return result;
}

fn parseMultipartAddressQuery(allocator: std.mem.Allocator, target: []const u8) !MultipartAddressQuery {
    var result: MultipartAddressQuery = .{};
    errdefer result.deinit(allocator);
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return result;
    const raw_query = target[query_start + 1 ..];
    if (raw_query.len == 0) return result;
    var parameters = std.mem.splitScalar(u8, raw_query, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidQuery;
        const equals = std.mem.indexOfScalar(u8, parameter, '=');
        const name = if (equals) |position| parameter[0..position] else parameter;
        const raw_value = if (equals) |position| parameter[position + 1 ..] else "";
        const value = try decodeComponent(allocator, raw_value, true);
        if (std.mem.eql(u8, name, "bucket")) {
            if (result.bucket != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.bucket = value;
        } else if (std.mem.eql(u8, name, "key")) {
            if (result.key != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.key = value;
        } else {
            allocator.free(value);
            return error.InvalidQuery;
        }
    }
    return result;
}

fn decodeComponent(
    allocator: std.mem.Allocator,
    input: []const u8,
    plus_as_space: bool,
) ![]u8 {
    const output = try allocator.alloc(u8, input.len);
    errdefer allocator.free(output);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < input.len) {
        const byte = if (input[input_index] == '%') decoded: {
            if (input.len - input_index < 3) return error.InvalidEncoding;
            const high = std.fmt.charToDigit(input[input_index + 1], 16) catch return error.InvalidEncoding;
            const low = std.fmt.charToDigit(input[input_index + 2], 16) catch return error.InvalidEncoding;
            input_index += 3;
            break :decoded @as(u8, @intCast(high * 16 + low));
        } else direct: {
            const value = input[input_index];
            input_index += 1;
            break :direct if (plus_as_space and value == '+') ' ' else value;
        };
        if (byte == 0 or (!plus_as_space and byte == '/')) return error.InvalidEncoding;
        output[output_index] = byte;
        output_index += 1;
    }
    return allocator.realloc(output, output_index);
}

fn encodePath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or byte == '/') {
            try output.writer.writeByte(byte);
        } else {
            try output.writer.print("%{X:0>2}", .{byte});
        }
    }
    return output.toOwnedSlice();
}

fn publicEndpointHost(endpoint: []const u8) []const u8 {
    if (std.mem.startsWith(u8, endpoint, "http://")) return endpoint["http://".len..];
    return endpoint["https://".len..];
}

fn requestPath(target: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query];
}

fn respondBucketError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    err: bucket_service.Error,
) !std.http.Status {
    return switch (err) {
        error.InvalidBucketName => respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid"),
        error.InvalidOwner => respondError(request, request_id, .bad_request, "InvalidOwner", "bucket owner is invalid"),
        error.BucketNotFound => respondError(request, request_id, .not_found, "BucketNotFound", "bucket does not exist"),
        error.BucketAlreadyExists => respondError(request, request_id, .conflict, "BucketAlreadyExists", "bucket belongs to another owner"),
        error.BucketNotEmpty => respondError(request, request_id, .conflict, "BucketNotEmpty", "bucket is not empty"),
        error.Conflict => respondError(request, request_id, .conflict, "Conflict", "bucket changed concurrently"),
        error.CorruptMetadata => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "bucket metadata requires recovery"),
        error.OutOfMemory, error.Unavailable => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage service is unavailable"),
    };
}

fn respondListingError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    err: object_listing.Error,
) !std.http.Status {
    return switch (err) {
        error.InvalidBucketName => respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid"),
        error.InvalidListOptions => respondError(request, request_id, .bad_request, "InvalidQuery", "list query is invalid"),
        error.InvalidContinuationToken => respondError(request, request_id, .bad_request, "InvalidContinuationToken", "continuation token is invalid"),
        error.BucketNotFound => respondError(request, request_id, .not_found, "BucketNotFound", "bucket does not exist"),
        error.CorruptMetadata => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "object metadata requires recovery"),
        error.OutOfMemory, error.Unavailable => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage service is unavailable"),
    };
}

fn respondMultipartError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    err: multipart_service.Error,
) !std.http.Status {
    return switch (err) {
        error.InvalidBucketName => respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid"),
        error.InvalidObjectKey => respondError(request, request_id, .bad_request, "InvalidObjectKey", "object key is invalid"),
        error.InvalidContentType => respondError(request, request_id, .bad_request, "InvalidContentType", "content type is invalid"),
        error.InvalidUserMetadata => respondError(request, request_id, .bad_request, "InvalidUserMetadata", "user metadata is invalid"),
        error.InvalidUploadId => respondError(request, request_id, .bad_request, "InvalidUploadId", "upload id is invalid"),
        error.InvalidPartNumber, error.InvalidPart, error.InvalidPartOrder, error.EntityTooSmall => respondError(request, request_id, .bad_request, "InvalidPart", "multipart parts are invalid"),
        error.InvalidListOptions => respondError(request, request_id, .bad_request, "InvalidQuery", "multipart list query is invalid"),
        error.BucketNotFound => respondError(request, request_id, .not_found, "BucketNotFound", "bucket does not exist"),
        error.UploadNotFound => respondError(request, request_id, .not_found, "UploadNotFound", "multipart upload does not exist"),
        error.ChecksumMismatch => respondError(request, request_id, .bad_request, "ChecksumMismatch", "part checksum does not match"),
        error.Conflict => respondError(request, request_id, .conflict, "Conflict", "multipart upload changed concurrently"),
        error.CorruptMetadata, error.CorruptData => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "multipart data requires recovery"),
        error.InputReadFailed, error.OutOfMemory, error.Unavailable => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage service is unavailable"),
    };
}

fn respondCredentialError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    err: credential_service.Error,
) !std.http.Status {
    return switch (err) {
        error.InvalidOwner => respondError(request, request_id, .bad_request, "InvalidOwner", "credential owner is invalid"),
        error.InvalidAccessKey => respondError(request, request_id, .bad_request, "InvalidAccessKey", "access key is invalid"),
        error.CredentialNotFound => respondError(request, request_id, .not_found, "AccessKeyNotFound", "access key does not exist"),
        error.CredentialDisabled => respondError(request, request_id, .conflict, "AccessKeyDisabled", "access key is disabled"),
        error.CredentialExpired => respondError(request, request_id, .conflict, "ExpiredToken", "temporary credential has expired"),
        error.InvalidTTL => respondError(request, request_id, .bad_request, "InvalidCredentialTTL", "temporary credential TTL must be between 60 and 43200 seconds"),
        error.Conflict => respondError(request, request_id, .conflict, "Conflict", "access key changed concurrently"),
        error.CorruptMetadata, error.SecretDecryptionFailed => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "credential metadata requires recovery"),
        error.OutOfMemory, error.Unavailable => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage service is unavailable"),
    };
}

fn respondManagementError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    err: management_service.Error,
) !std.http.Status {
    return switch (err) {
        error.CorruptMetadata => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "metadata requires recovery"),
        error.OutOfMemory, error.Unavailable => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage service is unavailable"),
    };
}

fn respondNotReady(request: *std.http.Server.Request, request_id: []const u8) !std.http.Status {
    return respondError(request, request_id, .service_unavailable, "StorageNotReady", "storage service is not ready");
}

pub fn respondMethodNotAllowed(
    request: *std.http.Server.Request,
    request_id: []const u8,
    allow: []const u8,
) !std.http.Status {
    const body = ErrorBody{
        .code = "MethodNotAllowed",
        .message = "method is not allowed for this endpoint",
        .request_id = request_id,
    };
    const encoded = try std.json.Stringify.valueAlloc(std.heap.smp_allocator, body, .{});
    defer std.heap.smp_allocator.free(encoded);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "allow", .value = allow },
    };
    try request.respond(encoded, .{ .status = .method_not_allowed, .extra_headers = &headers });
    return .method_not_allowed;
}

const EmptyDetails = struct {};
const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
    request_id: []const u8,
    details: EmptyDetails = .{},
};

pub fn respondError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
) !std.http.Status {
    return respondJson(request, request_id, status, ErrorBody{
        .code = code,
        .message = message,
        .request_id = request_id,
    });
}

fn respondJson(
    request: *std.http.Server.Request,
    request_id: []const u8,
    status: std.http.Status,
    value: anytype,
) !std.http.Status {
    const encoded = try std.json.Stringify.valueAlloc(std.heap.smp_allocator, value, .{});
    defer std.heap.smp_allocator.free(encoded);
    return respondJsonBytes(request, request_id, status, encoded);
}

fn respondJsonBytes(
    request: *std.http.Server.Request,
    request_id: []const u8,
    status: std.http.Status,
    body: []const u8,
) !std.http.Status {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-request-id", .value = request_id },
    };
    try request.respond(body, .{ .status = status, .extra_headers = &headers });
    return status;
}

fn respondNoContent(
    request: *std.http.Server.Request,
    request_id: []const u8,
) !std.http.Status {
    const headers = [_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-request-id", .value = request_id },
    };
    try request.respond("", .{ .status = .no_content, .extra_headers = &headers });
    return .no_content;
}

fn audit(
    application: *const Application,
    request_id: []const u8,
    action: []const u8,
    target: []const u8,
    outcome: []const u8,
) void {
    std.log.info(
        "management audit request_id={s} actor={s} action={s} target={s} outcome={s} time={d}",
        .{
            request_id,
            application.config.admin_username,
            action,
            target,
            outcome,
            std.Io.Clock.real.now(application.io.?).toSeconds(),
        },
    );
}

test "management routes remain under versioned prefix" {
    for (routes) |route| {
        try std.testing.expect(std.mem.startsWith(u8, route.path, api_prefix));
    }
}

test "management URL components are decoded strictly and object paths are encoded" {
    const decoded = try decodeComponent(std.testing.allocator, "hello%20world", true);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);
    try std.testing.expectError(
        error.InvalidEncoding,
        decodeComponent(std.testing.allocator, "bucket%2Fescape", false),
    );
    const encoded = try encodePath(std.testing.allocator, "folder/a b.txt");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("folder/a%20b.txt", encoded);
}
