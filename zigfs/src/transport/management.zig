const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const bucket_service = @import("../application/bucket_service.zig");
const credential_service = @import("../application/credential_service.zig");
const management_service = @import("../application/management_service.zig");
const multipart_service = @import("../application/multipart_service.zig");
const object_listing = @import("../application/object_listing.zig");
const lifecycle_service = @import("../application/lifecycle_service.zig");
const directory_service = @import("../application/directory_service.zig");
const credential_domain = @import("../domain/credential.zig");
const role_store = @import("../application/role_store.zig");
const object_domain = @import("../domain/object.zig");
const multipart_domain = @import("../domain/multipart.zig");
const sigv4 = @import("../auth/sigv4.zig");
const time = @import("../common/time.zig");
const s3_multipart = @import("s3_multipart.zig");
const version = @import("../version.zig").value;
const management_auth = @import("management_auth.zig");

pub const api_prefix = "/_admin/v1";
const max_body_size = 1024 * 1024;

pub const Method = enum { get, post, put, patch, delete };

pub const Route = struct {
    method: Method,
    path: []const u8,
};

// Role and organization routes are persisted in the same local authorization root.
pub const routes = [_]Route{
    .{ .method = .get, .path = "/_admin/v1/oidc/providers" },
    .{ .method = .post, .path = "/_admin/v1/oidc/providers" },
    .{ .method = .patch, .path = "/_admin/v1/oidc/providers/:id" },
    .{ .method = .delete, .path = "/_admin/v1/oidc/providers/:id" },
    .{ .method = .get, .path = "/_admin/v1/users/:name/access-keys" },
    .{ .method = .post, .path = "/_admin/v1/users/:name/access-keys" },
    .{ .method = .patch, .path = "/_admin/v1/users/:name/access-keys/:id" },
    .{ .method = .delete, .path = "/_admin/v1/users/:name/access-keys/:id" },
    .{ .method = .get, .path = "/_admin/v1/users" },
    .{ .method = .post, .path = "/_admin/v1/users" },
    .{ .method = .get, .path = "/_admin/v1/users/:name" },
    .{ .method = .patch, .path = "/_admin/v1/users/:name" },
    .{ .method = .delete, .path = "/_admin/v1/users/:name" },
    .{ .method = .get, .path = "/_admin/v1/groups" },
    .{ .method = .post, .path = "/_admin/v1/groups" },
    .{ .method = .get, .path = "/_admin/v1/groups/:name" },
    .{ .method = .patch, .path = "/_admin/v1/groups/:name" },
    .{ .method = .delete, .path = "/_admin/v1/groups/:name" },
    .{ .method = .get, .path = "/_admin/v1/organizations" },
    .{ .method = .post, .path = "/_admin/v1/organizations" },
    .{ .method = .patch, .path = "/_admin/v1/organizations/:name" },
    .{ .method = .delete, .path = "/_admin/v1/organizations/:name" },
    .{ .method = .get, .path = "/_admin/v1/roles" },
    .{ .method = .post, .path = "/_admin/v1/roles" },
    .{ .method = .patch, .path = "/_admin/v1/roles/:name" },
    .{ .method = .delete, .path = "/_admin/v1/roles/:name" },
    .{ .method = .post, .path = "/_admin/v1/sts/assume-role" },
    .{ .method = .get, .path = "/_admin/v1/role-sessions" },
    .{ .method = .post, .path = "/_admin/v1/role-sessions/:access_key/revoke" },

    .{ .method = .get, .path = "/_admin/v1/policies" },
    .{ .method = .post, .path = "/_admin/v1/policies" },
    .{ .method = .get, .path = "/_admin/v1/policies/:name" },
    .{ .method = .patch, .path = "/_admin/v1/policies/:name" },
    .{ .method = .delete, .path = "/_admin/v1/policies/:name" },

    .{ .method = .post, .path = "/_admin/v1/auth/login" },
    .{ .method = .get, .path = "/_admin/v1/auth/session" },
    .{ .method = .get, .path = "/_admin/v1/buckets" },
    .{ .method = .post, .path = "/_admin/v1/buckets" },
    .{ .method = .delete, .path = "/_admin/v1/buckets/:name" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/configuration" },
    .{ .method = .patch, .path = "/_admin/v1/buckets/:name/configuration" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/usage" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/events" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/versions" },
    .{ .method = .get, .path = "/_admin/v1/buckets/:name/objects" },
    .{ .method = .post, .path = "/_admin/v1/buckets/:name/directories" },
    .{ .method = .delete, .path = "/_admin/v1/buckets/:name/directories" },
    .{ .method = .post, .path = "/_admin/v1/buckets/:name/directories/cleanup" },
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
    .{ .method = .get, .path = "/_admin/v1/storage/scanner" },
    .{ .method = .post, .path = "/_admin/v1/storage/gc" },
    .{ .method = .get, .path = "/_admin/v1/system" },
    .{ .method = .get, .path = "/_admin/v1/health" },
    .{ .method = .get, .path = "/_admin/v1/settings" },
    .{ .method = .get, .path = "/_admin/v1/settings/kms" },
    .{ .method = .put, .path = "/_admin/v1/settings/kms" },
    .{ .method = .post, .path = "/_admin/v1/settings/kms/stop" },
    .{ .method = .post, .path = "/_admin/v1/settings/kms/clear-cache" },
    .{ .method = .post, .path = "/_admin/v1/settings/kms/start" },
    .{ .method = .get, .path = "/_admin/v1/settings/kms/keys" },
    .{ .method = .post, .path = "/_admin/v1/settings/kms/keys" },
    .{ .method = .post, .path = "/_admin/v1/settings/kms/keys/action" },
};

pub fn serveRequest(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    caller: management_auth.Principal,
) !std.http.Status {
    const target = request.head.target;
    const path = requestPath(target);

    if (std.mem.eql(u8, path, api_prefix ++ "/oidc/providers") or std.mem.startsWith(u8, path, api_prefix ++ "/oidc/providers/")) return serveOidc(request, application, request_id, path, caller);
    if (std.mem.eql(u8, path, api_prefix ++ "/oidc/validate")) return validateOidcProvider(request, application, request_id, caller);
    if (std.mem.eql(u8, path, api_prefix ++ "/sts/assume-role")) return serveAssumeRole(request, application, request_id, caller);
    if (std.mem.eql(u8, path, api_prefix ++ "/role-sessions") or std.mem.startsWith(u8, path, api_prefix ++ "/role-sessions/")) return serveRoleSessions(request, application, request_id, path);

    if (std.mem.startsWith(u8, path, api_prefix ++ "/users/") and std.mem.indexOf(u8, path, "/access-keys") != null) return serveUserAccessKeys(request, application, request_id, path);
    if (std.mem.eql(u8, path, api_prefix ++ "/organizations") or std.mem.startsWith(u8, path, api_prefix ++ "/organizations/")) return serveRoles(true, request, application, request_id, path);
    if (std.mem.eql(u8, path, api_prefix ++ "/roles") or std.mem.startsWith(u8, path, api_prefix ++ "/roles/")) return serveRoles(false, request, application, request_id, path);
    if (std.mem.eql(u8, path, api_prefix ++ "/users") or std.mem.startsWith(u8, path, api_prefix ++ "/users/")) return serveIdentities(false, request, application, request_id, path);
    if (std.mem.eql(u8, path, api_prefix ++ "/groups") or std.mem.startsWith(u8, path, api_prefix ++ "/groups/")) return serveIdentities(true, request, application, request_id, path);
    if (std.mem.eql(u8, path, api_prefix ++ "/policies") or std.mem.startsWith(u8, path, api_prefix ++ "/policies/")) {
        return servePolicies(request, application, request_id, path);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/buckets")) {
        return switch (request.head.method) {
            .GET => serveListBuckets(request, application, request_id),
            .POST => serveCreateBucket(request, application, request_id),
            else => respondMethodNotAllowed(request, request_id, "GET, POST"),
        };
    }
    if (std.mem.startsWith(u8, path, api_prefix ++ "/buckets/")) {
        const resource = path[(api_prefix ++ "/buckets/").len..];
        if (std.mem.endsWith(u8, resource, "/policy")) {
            const raw_name = resource[0 .. resource.len - "/policy".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) return respondError(request, request_id, .bad_request, "InvalidBucketName", "invalid bucket name");
            return serveBucketResourcePolicy(request, application, request_id, raw_name);
        }
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
        if (std.mem.endsWith(u8, resource, "/usage")) {
            if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
            const raw_name = resource[0 .. resource.len - "/usage".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            return serveGetBucketUsage(request, application, request_id, raw_name);
        }
        if (std.mem.endsWith(u8, resource, "/events")) {
            if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
            const raw_name = resource[0 .. resource.len - "/events".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            return serveListBucketEvents(request, application, request_id, raw_name, target);
        }
        if (std.mem.endsWith(u8, resource, "/tags")) {
            const raw_name = resource[0 .. resource.len - "/tags".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            return switch (request.head.method) {
                .GET => serveGetBucketTags(request, application, request_id, raw_name),
                .PUT => servePutBucketTags(request, application, request_id, raw_name),
                .DELETE => serveDeleteBucketTags(request, application, request_id, raw_name),
                else => respondMethodNotAllowed(request, request_id, "GET, PUT, DELETE"),
            };
        }
        if (std.mem.endsWith(u8, resource, "/legal-hold")) {
            if (request.head.method != .PATCH) return respondMethodNotAllowed(request, request_id, "PATCH");
            const raw_name = resource[0 .. resource.len - "/legal-hold".len];
            return serveSetLegalHold(request, application, request_id, raw_name);
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
        if (std.mem.endsWith(u8, resource, "/directories/cleanup")) {
            if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
            const raw_name = resource[0 .. resource.len - "/directories/cleanup".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            return serveDeleteFolder(request, application, request_id, raw_name, true);
        }
        if (std.mem.endsWith(u8, resource, "/directories")) {
            const raw_name = resource[0 .. resource.len - "/directories".len];
            if (raw_name.len == 0 or std.mem.indexOfScalar(u8, raw_name, '/') != null) {
                return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
            }
            return switch (request.head.method) {
                .POST => serveCreateDirectory(request, application, request_id, raw_name),
                .DELETE => serveDeleteFolder(request, application, request_id, raw_name, false),
                else => respondMethodNotAllowed(request, request_id, "POST, DELETE"),
            };
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
            .POST => serveCreateAccessKey(request, application, request_id, null),
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
    if (std.mem.eql(u8, path, api_prefix ++ "/storage/scanner")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
        return serveStorageScannerStatus(request, application, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/storage/gc")) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
        return serveStorageGc(request, application, request_id);
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
    if (std.mem.eql(u8, path, api_prefix ++ "/settings/kms/stop")) return serveKmsControl(request, application, request_id, true);
    if (std.mem.eql(u8, path, api_prefix ++ "/settings/kms/clear-cache")) return serveKmsControl(request, application, request_id, false);
    if (std.mem.eql(u8, path, api_prefix ++ "/settings/kms/keys")) return serveKmsKeys(request, application, request_id, false);
    if (std.mem.eql(u8, path, api_prefix ++ "/settings/kms/keys/action")) return serveKmsKeys(request, application, request_id, true);
    if (std.mem.eql(u8, path, api_prefix ++ "/settings/kms/start")) return serveKmsStart(request, application, request_id);
    if (std.mem.eql(u8, path, api_prefix ++ "/settings/kms")) return serveKmsSettings(request, application, request_id);
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

fn serveListBucketEvents(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
    target: []const u8,
) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(name);
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = service.head(name) catch |err| return respondBucketError(request, request_id, err);
    bucket.deinit(application.allocator);
    var offset: usize = 0;
    var limit: usize = 50;
    var from: ?i64 = null;
    var to: ?i64 = null;
    var action: ?[]u8 = null;
    var outcome: ?[]u8 = null;
    defer if (action) |value| application.allocator.free(value);
    defer if (outcome) |value| application.allocator.free(value);
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    if (query_start) |start| {
        var parameters = std.mem.splitScalar(u8, target[start + 1 ..], '&');
        while (parameters.next()) |parameter| {
            if (parameter.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse return respondError(request, request_id, .bad_request, "InvalidQuery", "events query is invalid");
            const key = parameter[0..equals];
            const value = decodeComponent(application.allocator, parameter[equals + 1 ..], true) catch return respondError(request, request_id, .bad_request, "InvalidQuery", "events query is invalid");
            defer application.allocator.free(value);
            if (std.mem.eql(u8, key, "cursor")) {
                offset = std.fmt.parseInt(usize, value, 10) catch return respondError(request, request_id, .bad_request, "InvalidQuery", "cursor must be a non-negative integer");
            } else if (std.mem.eql(u8, key, "limit")) {
                limit = std.fmt.parseInt(usize, value, 10) catch return respondError(request, request_id, .bad_request, "InvalidQuery", "limit must be a positive integer");
                if (limit == 0 or limit > 200) return respondError(request, request_id, .bad_request, "InvalidQuery", "limit must be between 1 and 200");
            } else if (std.mem.eql(u8, key, "from")) {
                from = std.fmt.parseInt(i64, value, 10) catch return respondError(request, request_id, .bad_request, "InvalidQuery", "from must be a Unix timestamp");
            } else if (std.mem.eql(u8, key, "to")) {
                to = std.fmt.parseInt(i64, value, 10) catch return respondError(request, request_id, .bad_request, "InvalidQuery", "to must be a Unix timestamp");
            } else if (std.mem.eql(u8, key, "action")) {
                action = application.allocator.dupe(u8, value) catch return respondError(request, request_id, .internal_server_error, "OutOfMemory", "unable to parse action");
            } else if (std.mem.eql(u8, key, "outcome")) {
                outcome = application.allocator.dupe(u8, value) catch return respondError(request, request_id, .internal_server_error, "OutOfMemory", "unable to parse outcome");
            } else {
                return respondError(request, request_id, .bad_request, "InvalidQuery", "unsupported events query parameter");
            }
        }
    }
    if (from != null and to != null and from.? > to.?) return respondError(request, request_id, .bad_request, "InvalidQuery", "from must not be after to");
    var page = application.listAuditEvents(name, offset, limit, from, to, action, outcome) catch |err| return switch (err) {
        error.OutOfMemory => respondError(request, request_id, .internal_server_error, "OutOfMemory", "unable to list audit events"),
        else => respondNotReady(request, request_id),
    };
    defer page.deinit(application.allocator);
    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (page.items) |event| {
        try json.beginObject();
        try json.objectField("timestamp_unix_seconds");
        try json.write(event.timestamp_unix_seconds);
        try json.objectField("request_id");
        try json.write(event.request_id);
        try json.objectField("actor");
        try json.write(event.actor);
        try json.objectField("action");
        try json.write(event.action);
        try json.objectField("target");
        try json.write(event.target);
        try json.objectField("outcome");
        try json.write(event.outcome);
        try json.endObject();
    }
    try json.endArray();
    if (page.next_cursor) |cursor| {
        try json.objectField("next_cursor");
        try json.write(cursor);
    }
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

const CreateBucketRequest = struct {
    name: []const u8,
    owner: ?[]const u8 = null,
    versioning: bool = false,
    object_locking: bool = false,
    max_bytes: ?u64 = null,
    max_objects: ?u64 = null,
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
    const owner = parsed.value.owner orelse application.config.admin_username;
    const result = service.create(parsed.value.name, owner) catch |err| {
        audit(application, request_id, "create_bucket", parsed.value.name, @errorName(err));
        return respondBucketError(request, request_id, err);
    };
    defer result.deinit(application.allocator);
    audit(application, request_id, "create_bucket", parsed.value.name, if (result.created) "created" else "exists");

    if (result.created) {
        if (parsed.value.versioning or parsed.value.object_locking) {
            const updated = service.setVersioning(parsed.value.name, .enabled) catch |err| return respondBucketError(request, request_id, err);
            updated.deinit(application.allocator);
        }
        if (parsed.value.object_locking) {
            const updated = service.setObjectLocking(parsed.value.name, true) catch |err| return respondBucketError(request, request_id, err);
            updated.deinit(application.allocator);
        }
        if (parsed.value.max_bytes != null or parsed.value.max_objects != null) {
            const updated = service.setQuota(parsed.value.name, .{ .max_bytes = parsed.value.max_bytes, .max_objects = parsed.value.max_objects }) catch |err| return respondBucketError(request, request_id, err);
            updated.deinit(application.allocator);
        }
    }

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
    access_policy: ?[]const u8 = null,
    tags_json: ?[]const u8 = null,
    clear_tags: bool = false,
    encryption: ?[]const u8 = null,
    kms_key_id: ?[]const u8 = null,
    max_bytes: ?u64 = null,
    max_objects: ?u64 = null,
    retention_enabled: ?bool = null,
    retention_duration_seconds: ?u64 = null,
    retention_mode: ?[]const u8 = null,
    object_locking: ?bool = null,
    replication_enabled: ?bool = null,
    block_public_access: ?bool = null,
    lifecycle_configuration: ?[]const u8 = null,
    clear_lifecycle: bool = false,
};

const LegalHoldRequest = struct { key: []const u8, version_id: []const u8, enabled: bool };

const TagsRequest = struct { tags_json: []const u8 };

fn serveGetBucketTags(request: *std.http.Server.Request, application: *Application, request_id: []const u8, raw_name: []const u8) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(name);
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = service.head(name) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(application.allocator);
    return respondJson(request, request_id, .ok, .{ .tags_json = bucket.tags_json });
}

fn servePutBucketTags(request: *std.http.Server.Request, application: *Application, request_id: []const u8, raw_name: []const u8) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(name);
    const parsed = try parseJsonBody(TagsRequest, request, application.allocator, request_id) orelse return .bad_request;
    defer parsed.deinit();
    const json = std.json.parseFromSlice(std.json.Value, application.allocator, parsed.value.tags_json, .{}) catch return respondError(request, request_id, .bad_request, "InvalidTags", "tags_json must be valid JSON");
    defer json.deinit();
    if (json.value != .object) return respondError(request, request_id, .bad_request, "InvalidTags", "tags_json must be an object");
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = service.setTags(name, parsed.value.tags_json) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(application.allocator);
    return respondJson(request, request_id, .ok, .{ .tags_json = bucket.tags_json });
}

fn serveDeleteBucketTags(request: *std.http.Server.Request, application: *Application, request_id: []const u8, raw_name: []const u8) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(name);
    const service = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = service.setTags(name, null) catch |err| return respondBucketError(request, request_id, err);
    bucket.deinit(application.allocator);
    return respondNoContent(request, request_id);
}

fn serveSetLegalHold(request: *std.http.Server.Request, application: *Application, request_id: []const u8, raw_name: []const u8) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(name);
    const parsed = try parseJsonBody(LegalHoldRequest, request, application.allocator, request_id) orelse return .bad_request;
    defer parsed.deinit();
    const version_id = @import("../domain/object.zig").parseVersionId(parsed.value.version_id) catch return respondError(request, request_id, .bad_request, "InvalidVersionId", "version_id is invalid");
    const service = application.objectService() orelse return respondNotReady(request, request_id);
    const object = service.setLegalHold(name, parsed.value.key, version_id, parsed.value.enabled) catch |err| {
        return switch (err) {
            error.ObjectNotFound => respondError(request, request_id, .not_found, "ObjectNotFound", "object version does not exist"),
            error.ObjectLocked, error.RetentionActive => respondError(request, request_id, .forbidden, "ObjectLocked", "object is protected"),
            else => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "object metadata is unavailable"),
        };
    };
    defer object.deinit(application.allocator);
    return respondJson(request, request_id, .ok, .{ .key = object.key, .version_id = object.version_id, .legal_hold = object.legal_hold });
}

fn serveGetBucketUsage(request: *std.http.Server.Request, application: *Application, request_id: []const u8, raw_name: []const u8) !std.http.Status {
    const name = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(name);
    const service = application.objectService() orelse return respondNotReady(request, request_id);
    const snapshot = service.usage(name) catch |err| return switch (err) {
        error.BucketNotFound => respondError(request, request_id, .not_found, "BucketNotFound", "bucket does not exist"),
        else => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "usage statistics are unavailable"),
    };
    return respondJson(request, request_id, .ok, .{ .bytes = snapshot.bytes, .objects = snapshot.objects });
}

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
    if (parsed.value.replication_enabled != null) return respondError(request, request_id, .not_implemented, "FeatureUnavailable", "replication requires a second storage site");
    if (parsed.value.versioning == null and parsed.value.access_policy == null and parsed.value.block_public_access == null and parsed.value.tags_json == null and parsed.value.encryption == null and parsed.value.max_bytes == null and parsed.value.max_objects == null and parsed.value.retention_enabled == null and parsed.value.retention_duration_seconds == null and parsed.value.retention_mode == null and parsed.value.object_locking == null and parsed.value.lifecycle_configuration == null and !parsed.value.clear_lifecycle and !parsed.value.clear_tags) {
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
    if (parsed.value.access_policy) |policy| {
        const access_policy: @import("../domain/bucket.zig").AccessPolicy = if (std.mem.eql(u8, policy, "Private"))
            .private
        else if (std.mem.eql(u8, policy, "Readonly"))
            .readonly
        else if (std.mem.eql(u8, policy, "Public"))
            .public
        else if (std.mem.eql(u8, policy, "Custom"))
            .custom
        else
            return respondError(request, request_id, .bad_request, "InvalidAccessPolicy", "access_policy must be Private, Readonly, Public, or Custom");
        const previous = service.head(name) catch |err| return respondBucketError(request, request_id, err);
        defer previous.deinit(application.allocator);
        const updated = service.setAccessPolicy(name, access_policy) catch |err| return respondBucketError(request, request_id, err);
        auditAccessPolicy(application, request_id, name, accessPolicyName(previous.access_policy), accessPolicyName(updated.access_policy));
        updated.deinit(application.allocator);
    }
    if (parsed.value.block_public_access) |blocked| {
        const updated = service.setPublicAccess(name, blocked) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    }
    if (parsed.value.encryption) |status| {
        const encryption: @import("../domain/bucket.zig").Encryption = if (std.mem.eql(u8, status, "Enabled")) .enabled else if (std.mem.eql(u8, status, "Disabled")) .disabled else if (std.mem.eql(u8, status, "KMS")) .kms else return respondError(request, request_id, .bad_request, "InvalidEncryption", "encryption must be Enabled, KMS or Disabled");
        if (encryption == .kms) {
            const kms = if (application.kms) |*value| value else return respondError(request, request_id, .service_unavailable, "KmsUnavailable", "KMS is not configured");
            kms.requireRunning() catch |err| return respondError(request, request_id, .service_unavailable, @errorName(err), @import("../application/kms.zig").saveErrorMessage(err));
        }
        const key = @import("../domain/bucket.zig").KmsKeyId.fromString(parsed.value.kms_key_id orelse "") catch return respondError(request, request_id, .bad_request, "InvalidKeyId", "invalid KMS key ID");
        if (encryption != .kms and key.len > 0) return respondError(request, request_id, .bad_request, "InvalidEncryption", "KMS key ID requires SSE-KMS");
        const updated = service.setEncryptionWithKey(name, .{ .algorithm = encryption, .key = key }) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    }
    if (parsed.value.max_bytes != null or parsed.value.max_objects != null) {
        // The JSON API uses zero as the clear value because omitted fields
        // mean "leave the existing quota unchanged". Keep the domain model
        // canonical by storing cleared limits as null.
        const current = service.head(name) catch |err| return respondBucketError(request, request_id, err);
        defer current.deinit(application.allocator);
        const max_bytes = if (parsed.value.max_bytes) |value| if (value == 0) null else value else current.quota.max_bytes;
        const max_objects = if (parsed.value.max_objects) |value| if (value == 0) null else value else current.quota.max_objects;
        const updated = service.setQuota(name, .{ .max_bytes = max_bytes, .max_objects = max_objects }) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    }
    if (parsed.value.retention_enabled != null or parsed.value.retention_duration_seconds != null or parsed.value.retention_mode != null) {
        const before = service.head(name) catch |err| return respondBucketError(request, request_id, err);
        defer before.deinit(application.allocator);
        const enabled = parsed.value.retention_enabled orelse false;
        const mode: ?@import("../domain/bucket.zig").RetentionMode = if (parsed.value.retention_mode) |value|
            if (std.mem.eql(u8, value, "GOVERNANCE")) .governance else if (std.mem.eql(u8, value, "COMPLIANCE")) .compliance else return respondError(request, request_id, .bad_request, "InvalidRetentionMode", "retention_mode must be GOVERNANCE or COMPLIANCE")
        else
            null;
        const updated = service.setRetention(name, .{ .enabled = enabled, .default_duration_seconds = parsed.value.retention_duration_seconds, .mode = mode }) catch |err| return respondBucketError(request, request_id, err);
        auditRetention(application, request_id, name, before.retention, updated.retention);
        updated.deinit(application.allocator);
    }
    if (parsed.value.object_locking) |enabled| {
        const updated = service.setObjectLocking(name, enabled) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    }
    if (parsed.value.tags_json) |tags_json| {
        const parsed_tags = std.json.parseFromSlice(std.json.Value, application.allocator, tags_json, .{}) catch {
            return respondError(request, request_id, .bad_request, "InvalidTags", "tags_json must be valid JSON");
        };
        defer parsed_tags.deinit();
        if (parsed_tags.value != .object) return respondError(request, request_id, .bad_request, "InvalidTags", "tags_json must be a JSON object");
        if (parsed_tags.value.object.count() > 50) return respondError(request, request_id, .bad_request, "InvalidTags", "at most 50 tags are allowed");
        var tag_iterator = parsed_tags.value.object.iterator();
        while (tag_iterator.next()) |entry| {
            if (entry.key_ptr.*.len == 0 or entry.key_ptr.*.len > 128 or entry.value_ptr.* != .string or entry.value_ptr.*.string.len > 256) {
                return respondError(request, request_id, .bad_request, "InvalidTags", "tag keys must be 1-128 characters and values must be strings up to 256 characters");
            }
        }
        const updated = service.setTags(name, tags_json) catch |err| return respondBucketError(request, request_id, err);
        updated.deinit(application.allocator);
    } else if (parsed.value.clear_tags) {
        const updated = service.setTags(name, null) catch |err| return respondBucketError(request, request_id, err);
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
        .access_policy = switch (bucket.access_policy) {
            .private => "Private",
            .readonly => "Readonly",
            .public => "Public",
            .custom => "Custom",
        },
        .object_ownership = "BucketOwnerEnforced",
        .block_public_access = bucket.block_public_access,
        .tags_json = bucket.tags_json,
        .kms_key_id = bucket.kms_key_id.slice(),
        .encryption = switch (bucket.encryption) {
            .disabled => "Disabled",
            .enabled => "Enabled",
            .kms => "KMS",
        },
        .max_bytes = bucket.quota.max_bytes,
        .max_objects = bucket.quota.max_objects,
        .retention_enabled = bucket.retention.enabled,
        .retention_duration_seconds = bucket.retention.default_duration_seconds,
        .retention_mode = if (bucket.retention.mode) |mode| switch (mode) {
            .governance => "GOVERNANCE",
            .compliance => "COMPLIANCE",
        } else null,
        .object_locking = bucket.object_locking,
        .replication_status = "UNAVAILABLE",
        .replication_enabled = false,
        .replication_reason = "SECOND_SITE_REQUIRED",
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
    const prefix = query.prefix orelse "";
    const result = service.listVersions(bucket, prefix) catch |err| {
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
        if (!isDirectVersionKey(entry.key, prefix)) continue;
        var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
        var modified_buffer: [20]u8 = undefined;
        try json.write(.{
            .key = entry.key,
            .version_id = entry.version_id.write(&version_buffer),
            .is_latest = entry.is_latest,
            .is_delete_marker = entry.is_delete_marker,
            .size = entry.size,
            .last_modified = time.formatIso8601(entry.last_modified_unix_seconds, &modified_buffer) catch return error.WriteFailed,
            .retention_until_unix_seconds = entry.retention_until_unix_seconds,
            .retention_mode = if (entry.retention_mode) |mode| switch (mode) {
                .governance => "GOVERNANCE",
                .compliance => "COMPLIANCE",
            } else null,
            .legal_hold = entry.legal_hold,
        });
    }
    try json.endArray();
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

fn isDirectVersionKey(key: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, key, prefix)) return false;
    const relative_key = key[prefix.len..];
    // An exact key prefix is used by the Admin UI when purging one object's
    // complete version history. Keep that object in the response as well.
    return relative_key.len == 0 or std.mem.indexOfScalar(u8, relative_key, '/') == null;
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
        .search = query.search orelse "",
        .delimiter = query.delimiter,
        .max_keys = query.max_keys,
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
    try json.objectField("common_prefixes");
    try json.beginArray();
    for (result.common_prefixes) |common_prefix| try json.write(common_prefix);
    try json.endArray();
    try json.objectField("directories");
    try json.beginArray();
    for (result.directories) |directory| try writeDirectory(&json, directory);
    try json.endArray();
    try json.objectField("is_truncated");
    try json.write(result.is_truncated);
    if (result.next_continuation_token) |token| {
        try json.objectField("continuation_token");
        try json.write(token);
    }
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

const DirectoryRequest = struct { key: []const u8 };

fn serveCreateDirectory(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    raw_name: []const u8,
) !std.http.Status {
    const bucket = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(bucket);
    const parsed = try parseJsonBody(DirectoryRequest, request, application.allocator, request_id) orelse return .bad_request;
    defer parsed.deinit();
    const service = application.directoryService() orelse return respondNotReady(request, request_id);
    const directory = service.create(bucket, parsed.value.key) catch |err| return respondDirectoryError(request, request_id, err);
    defer directory.deinit(application.allocator);
    var modified_buffer: [20]u8 = undefined;
    const modified = time.formatIso8601(directory.last_modified_unix_seconds, &modified_buffer) catch return error.WriteFailed;
    return respondJson(request, request_id, .created, .{ .type = "directory", .key = directory.key, .last_modified = modified });
}

const DeleteFolderRequest = struct { key: []const u8, all_versions: bool = false };

fn serveDeleteFolder(request: *std.http.Server.Request, application: *Application, request_id: []const u8, raw_name: []const u8, force: bool) !std.http.Status {
    const bucket = decodeComponent(application.allocator, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid");
    defer application.allocator.free(bucket);
    const service = application.folderService() orelse return respondNotReady(request, request_id);
    const query_key = parseDirectoryKeyQuery(application.allocator, request.head.target) catch return respondError(request, request_id, .bad_request, "InvalidQuery", "directory query is invalid");
    defer if (query_key) |key| application.allocator.free(key);
    if (query_key) |key| {
        const all_versions = queryAllVersions(request.head.target);
        service.delete(bucket, key, all_versions, force) catch |err| return respondFolderError(request, request_id, err, force);
    } else {
        const parsed = try parseJsonBody(DeleteFolderRequest, request, application.allocator, request_id) orelse return .bad_request;
        defer parsed.deinit();
        service.delete(bucket, parsed.value.key, parsed.value.all_versions, force) catch |err| return respondFolderError(request, request_id, err, force);
    }
    return respondNoContent(request, request_id);
}

fn respondFolderError(request: *std.http.Server.Request, request_id: []const u8, err: @import("../application/folder_service.zig").Error, cleanup: bool) !std.http.Status {
    const status: std.http.Status = switch (err) {
        error.InvalidBucketName, error.InvalidDirectoryKey, error.InvalidObjectKey => .bad_request,
        error.BucketNotFound => .not_found,
        error.ObjectLocked, error.RetentionActive => .forbidden,
        error.Conflict, error.DirectoryNotEmpty => .conflict,
        else => .service_unavailable,
    };
    return respondError(request, request_id, status, @errorName(err), if (cleanup)
        "Directory repair or residual-data cleanup did not complete. Corrupt authoritative metadata requires recovery; no live data is intentionally deleted by cleanup."
    else
        "Folder deletion did not complete; some items may already have been deleted. Inspect the folder before retrying.");
}

fn queryAllVersions(target: []const u8) bool {
    const start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var parameters = std.mem.splitScalar(u8, target[start + 1 ..], '&');
    while (parameters.next()) |parameter| if (std.mem.eql(u8, parameter, "all_versions=true")) return true;
    return false;
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
    copy_source_bucket: ?[]const u8 = null,
    copy_source_key: ?[]const u8 = null,
    copy_source_version_id: ?[]const u8 = null,
    tagging: bool = false,
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
    const copy_source_requested = value.copy_source_bucket != null or
        value.copy_source_key != null or value.copy_source_version_id != null;
    const copy_source_complete = value.copy_source_bucket != null and value.copy_source_key != null;
    const requested_version = if (value.version_id) |version_id|
        object_domain.parseVersionId(version_id) catch {
            return respondError(request, request_id, .bad_request, "InvalidVersionId", "version ID is invalid");
        }
    else
        null;
    _ = if (value.copy_source_version_id) |version_id|
        object_domain.parseVersionId(version_id) catch {
            return respondError(request, request_id, .bad_request, "InvalidVersionId", "copy source version ID is invalid");
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
        (requested_version != null and (multipart_part or std.mem.eql(u8, value.method, "PUT"))) or
        (copy_source_requested and (!copy_source_complete or multipart_part or requested_version != null or
            !std.mem.eql(u8, value.method, "PUT"))))
    {
        return respondError(request, request_id, .bad_request, "InvalidPresignRequest", "method or expiry is invalid");
    }
    object_domain.validateKey(value.key) catch {
        return respondError(request, request_id, .bad_request, "InvalidObjectKey", "object key is invalid");
    };
    if (value.copy_source_key) |source_key| object_domain.validateKey(source_key) catch {
        return respondError(request, request_id, .bad_request, "InvalidObjectKey", "copy source object key is invalid");
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
    if (copy_source_requested and !material.policy.allows(.get_object)) {
        return respondError(request, request_id, .forbidden, "AccessDenied", "access key policy does not allow reading the copy source");
    }

    const iam_action = if (required_action == .get_object) (if (value.version_id != null) "s3:GetObjectVersion" else "s3:GetObject") else if (required_action == .delete_object) (if (value.version_id != null) "s3:DeleteObjectVersion" else "s3:DeleteObject") else "s3:PutObject";
    if (!material.allowsPresign(application.allocator, iam_action, value.bucket, value.key)) return respondError(request, request_id, .forbidden, "AccessDenied", "inherited policy denies this operation");
    if (value.copy_source_bucket) |source| if (!material.allowsPresign(application.allocator, if (value.copy_source_version_id != null) "s3:GetObjectVersion" else "s3:GetObject", source, value.copy_source_key)) return respondError(request, request_id, .forbidden, "AccessDenied", "inherited policy denies copy source access");

    const buckets = application.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = buckets.head(value.bucket) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(application.allocator);
    if (material.inherited_documents == null and material.key_document == null and !std.mem.eql(u8, bucket.owner, material.owner)) {
        return respondError(request, request_id, .forbidden, "AccessDenied", "access key does not own this bucket");
    }
    if (value.copy_source_bucket) |source_bucket_name| {
        const source_bucket = buckets.head(source_bucket_name) catch |err| return respondBucketError(request, request_id, err);
        defer source_bucket.deinit(application.allocator);
        if (material.inherited_documents == null and material.key_document == null and !std.mem.eql(u8, source_bucket.owner, material.owner)) {
            return respondError(request, request_id, .forbidden, "AccessDenied", "access key does not own the copy source bucket");
        }
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
        try std.fmt.allocPrint(application.allocator, "{s}?versionId={s}{s}", .{ base_target, version_id, if (value.tagging) "&tagging" else "" })
    else if (value.tagging)
        try std.fmt.allocPrint(application.allocator, "{s}?tagging", .{base_target})
    else
        base_target;
    defer if (multipart_part or value.version_id != null or value.tagging) application.allocator.free(unsigned_target);
    const encoded_source_key = if (value.copy_source_key) |source_key|
        try encodePath(application.allocator, source_key)
    else
        null;
    defer if (encoded_source_key) |owned| application.allocator.free(owned);
    const copy_source = if (encoded_source_key) |source_key|
        if (value.copy_source_version_id) |version_id|
            try std.fmt.allocPrint(application.allocator, "/{s}/{s}?versionId={s}", .{
                value.copy_source_bucket.?,
                source_key,
                version_id,
            })
        else
            try std.fmt.allocPrint(application.allocator, "/{s}/{s}", .{
                value.copy_source_bucket.?,
                source_key,
            })
    else
        null;
    defer if (copy_source) |owned| application.allocator.free(owned);
    var headers: [2]sigv4.Header = undefined;
    headers[0] = .{ .name = "host", .value = host };
    var header_count: usize = 1;
    if (copy_source) |source| {
        headers[header_count] = .{ .name = "x-amz-copy-source", .value = source };
        header_count += 1;
    }
    const now = std.Io.Clock.real.now(application.io.?).toSeconds();
    var date_buffer: [16]u8 = undefined;
    const amz_date = time.formatAmzDate(now, &date_buffer) catch {
        return respondError(request, request_id, .internal_server_error, "InternalError", "could not create presigned URL");
    };
    const signed_target = sigv4.presignTarget(application.allocator, .{
        .method = value.method,
        .target = unsigned_target,
        .headers = headers[0..header_count],
        .access_key = value.access_key,
        .secret_key = material.secret_key,
        .amz_date = amz_date,
        .region = application.config.s3_region,
        .expires_seconds = value.expires_seconds,
        .signed_headers = if (copy_source != null) "host;x-amz-copy-source" else "host",
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
    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("url");
    try json.write(url);
    try json.objectField("expires_at");
    try json.write(expires_at);
    try json.objectField("required_headers");
    try json.beginObject();
    if (copy_source) |source| {
        try json.objectField("x-amz-copy-source");
        try json.write(source);
    }
    try json.endObject();
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
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
        if (std.mem.startsWith(u8, details.credential.owner, "user:")) continue;
        try writeCredential(
            &json,
            details.credential,
            null,
            null,
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
    bypass_governance_retention: bool = false,

    fn domain(self: PolicyRequest) credential_domain.Policy {
        return .{
            .bucket_read = self.bucket_read,
            .bucket_write = self.bucket_write,
            .object_read = self.object_read,
            .object_write = self.object_write,
            .bypass_governance_retention = self.bypass_governance_retention and self.object_write,
        };
    }
};

const CreateAccessKeyRequest = struct {
    owner: ?[]const u8 = null,
    policy: PolicyRequest = .{},
    ttl_seconds: ?u64 = null,
    access_key: ?[]const u8 = null,
    secret_key: ?[]const u8 = null,
    expires_at: ?[]const u8 = null,
    name: []const u8 = "",
    description: []const u8 = "",
    inherit_policy: bool = false,
    policy_document: []const u8 = "",
};

fn serveCreateAccessKey(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
    scoped_owner: ?[]const u8,
) !std.http.Status {
    const parsed = try parseJsonBody(CreateAccessKeyRequest, request, application.allocator, request_id) orelse {
        return .bad_request;
    };
    defer parsed.deinit();
    const service = application.credentialService() orelse return respondNotReady(request, request_id);
    const owner = scoped_owner orelse parsed.value.owner orelse application.config.admin_username;
    if (scoped_owner == null and std.mem.startsWith(u8, owner, "user:")) return respondError(request, request_id, .bad_request, "InvalidOwner", "use the user access key endpoint");
    const expiry = if (parsed.value.expires_at) |value| time.parseIso8601(value) catch return respondCredentialError(request, request_id, error.InvalidExpiration) else null;
    var result = service.createWithOptions(owner, parsed.value.policy.domain(), .{
        .ttl_seconds = parsed.value.ttl_seconds,
        .access_key = parsed.value.access_key,
        .secret_key = parsed.value.secret_key,
        .expires_at = expiry,
        .name = parsed.value.name,
        .description = parsed.value.description,
        .inherit_policy = parsed.value.inherit_policy,
        .policy_document = parsed.value.policy_document,
    }) catch |err| {
        audit(application, request_id, "create_access_key", owner, @errorName(err));
        return respondCredentialError(request, request_id, err);
    };
    defer result.deinit(application.allocator);
    audit(application, request_id, "create_access_key", result.credential.access_key, "created");

    var output: std.Io.Writer.Allocating = .init(application.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try writeCredential(&json, result.credential, result.secret_key, if (result.session_token) |*token| token else null);
    return respondJsonBytes(request, request_id, .created, output.written());
}

const UpdateAccessKeyRequest = struct {
    enabled: ?bool = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    inherit_policy: ?bool = null,
    expires_at: ?[]const u8 = null,
    clear_expiry: bool = false,
    policy_document: ?[]const u8 = null,
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
    const expiry = if (parsed.value.expires_at) |value| time.parseIso8601(value) catch return respondCredentialError(request, request_id, error.InvalidExpiration) else null;
    const credential = service.update(access_key, .{ .enabled = parsed.value.enabled, .name = parsed.value.name, .description = parsed.value.description, .inherit_policy = parsed.value.inherit_policy, .expires_at = expiry, .clear_expiry = parsed.value.clear_expiry, .policy_document = parsed.value.policy_document }) catch |err| {
        audit(application, request_id, "update_access_key", access_key, @errorName(err));
        return respondCredentialError(request, request_id, err);
    };
    defer credential.deinit(application.allocator);
    audit(application, request_id, "update_access_key", access_key, "updated");

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
    const capacity = if (application.data_root) |root| @import("../backend/filesystem_capacity.zig").read(root) else null;
    return respondJson(request, request_id, .ok, .{
        .measurement = "logical_object_bytes",
        .total = if (capacity) |value| @as(?u64, value.total) else null,
        .used = snapshot.object_bytes,
        .available = if (capacity) |value| @as(?u64, value.available) else null,
        .physical_used = if (capacity) |value| @as(?u64, value.used) else null,
    });
}

fn serveStorageScannerStatus(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const snapshot = application.storageScannerSnapshot() orelse return respondNotReady(request, request_id);
    return respondJson(request, request_id, .ok, .{
        .partitions = @import("../application/object_gc.zig").partition_count,
        .running = snapshot.running,
        .last_completed_at = snapshot.last_completed_at,
        .last_duration_ms = snapshot.last_duration_ms,
        .last_attempt_succeeded = snapshot.last_attempt_succeeded,
        .next_partition = snapshot.next_partition,
        .last_scan = snapshot.last_scan,
    });
}

fn serveStorageGc(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const report = application.runStorageGc() catch |err| return respondStorageGcError(request, request_id, err);
    return respondJson(request, request_id, .ok, report);
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
        .tags_json = bucket.tags_json,
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
        .retention_until_unix_seconds = object.retention_until_unix_seconds,
        .retention_mode = if (object.retention_mode) |mode| switch (mode) {
            .governance => "GOVERNANCE",
            .compliance => "COMPLIANCE",
        } else null,
        .legal_hold = object.legal_hold,
    });
}

fn writeDirectory(json: *std.json.Stringify, directory: anytype) !void {
    var modified_buffer: [20]u8 = undefined;
    const modified = try time.formatIso8601(directory.last_modified_unix_seconds, &modified_buffer);
    try json.write(.{ .type = "directory", .key = directory.key, .last_modified = modified });
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
    try json.objectField("name");
    try json.write(credential.name);
    try json.objectField("description");
    try json.write(credential.description);
    try json.objectField("policy_document");
    try json.write(credential.policy_document);
    try json.objectField("inherit_policy");
    try json.write(credential.inherit_policy);
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
    search: ?[]u8 = null,
    delimiter: ?[]u8 = null,
    max_keys: usize = object_listing.max_keys,
    max_keys_set: bool = false,
    continuation_token: ?[]u8 = null,

    fn deinit(self: *ListQuery, allocator: std.mem.Allocator) void {
        if (self.prefix) |value| allocator.free(value);
        if (self.search) |value| allocator.free(value);
        if (self.delimiter) |value| allocator.free(value);
        if (self.continuation_token) |value| allocator.free(value);
        self.* = .{};
    }
};

fn parseDirectoryKeyQuery(allocator: std.mem.Allocator, target: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const raw_query = target[query_start + 1 ..];
    if (raw_query.len == 0) return null;
    var key: ?[]u8 = null;
    var seen_all_versions = false;
    errdefer if (key) |value| allocator.free(value);
    var parameters = std.mem.splitScalar(u8, raw_query, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidQuery;
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse return error.InvalidQuery;
        const name = parameter[0..equals];
        if (std.mem.eql(u8, name, "all_versions")) {
            const value = parameter[equals + 1 ..];
            if (seen_all_versions or (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false"))) return error.InvalidQuery;
            seen_all_versions = true;
            continue;
        }
        if (!std.mem.eql(u8, name, "key") or key != null) return error.InvalidQuery;
        key = try decodeComponent(allocator, parameter[equals + 1 ..], true);
    }
    return key;
}

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
        } else if (std.mem.eql(u8, name, "search")) {
            if (result.search != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.search = value;
        } else if (std.mem.eql(u8, name, "delimiter")) {
            if (result.delimiter != null) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.delimiter = value;
        } else if (std.mem.eql(u8, name, "max_keys")) {
            if (result.max_keys_set) {
                allocator.free(value);
                return error.InvalidQuery;
            }
            result.max_keys_set = true;
            result.max_keys = std.fmt.parseInt(usize, value, 10) catch {
                allocator.free(value);
                return error.InvalidQuery;
            };
            allocator.free(value);
            if (result.max_keys == 0 or result.max_keys > object_listing.max_keys) return error.InvalidQuery;
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
        error.RetentionChangeRejected => respondError(request, request_id, .conflict, "RetentionChangeRejected", "COMPLIANCE retention cannot be weakened"),
        error.ObjectLockingRequiresVersioning => respondError(request, request_id, .bad_request, "ObjectLockingRequiresVersioning", "Object Locking requires Versioning Enabled"),
        error.ObjectLockingCannotDisable => respondError(request, request_id, .conflict, "ObjectLockingCannotDisable", "Object Locking cannot be disabled once enabled"),
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

fn respondDirectoryError(request: *std.http.Server.Request, request_id: []const u8, err: directory_service.Error) !std.http.Status {
    return switch (err) {
        error.InvalidBucketName => respondError(request, request_id, .bad_request, "InvalidBucketName", "bucket name is invalid"),
        error.InvalidDirectoryKey => respondError(request, request_id, .bad_request, "InvalidDirectoryKey", "directory key is invalid"),
        error.BucketNotFound, error.DirectoryNotFound => respondError(request, request_id, .not_found, "NotFound", "directory does not exist"),
        error.DirectoryNotEmpty => respondError(request, request_id, .conflict, "DirectoryNotEmpty", "directory must be empty before deletion"),
        error.Conflict => respondError(request, request_id, .conflict, "Conflict", "directory changed concurrently"),
        error.CorruptMetadata => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "directory metadata requires recovery"),
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
        error.InvalidPolicy => respondError(request, request_id, .bad_request, "InvalidPolicy", "policy must be a valid 2012-10-17 policy document"),
        error.InvalidSecretKey => respondError(request, request_id, .bad_request, "InvalidSecretKey", "secret key must be 32 to 64 printable ASCII characters (40 for temporary tokens)"),
        error.InvalidMetadata => respondError(request, request_id, .bad_request, "InvalidMetadata", "name or description is invalid or too long"),
        error.InvalidExpiration => respondError(request, request_id, .bad_request, "InvalidExpiration", "expiry must be a future UTC date and cannot be combined with TTL"),
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

fn respondStorageGcError(
    request: *std.http.Server.Request,
    request_id: []const u8,
    err: @import("../application/object_gc.zig").Error,
) !std.http.Status {
    return switch (err) {
        error.CorruptMetadata => respondError(request, request_id, .service_unavailable, "CorruptMetadata", "metadata requires recovery before storage cleanup"),
        error.CorruptData => respondError(request, request_id, .service_unavailable, "CorruptData", "referenced object data is missing or malformed"),
        error.OutOfMemory, error.Unavailable => respondError(request, request_id, .service_unavailable, "StorageUnavailable", "storage cleanup is unavailable"),
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
    application: *Application,
    request_id: []const u8,
    action: []const u8,
    target: []const u8,
    outcome: []const u8,
) void {
    application.recordAudit(.{
        .timestamp_unix_seconds = std.Io.Clock.real.now(application.io.?).toSeconds(),
        .request_id = request_id,
        .actor = application.config.admin_username,
        .action = action,
        .target = target,
        .outcome = outcome,
    });
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

fn accessPolicyName(policy: @import("../domain/bucket.zig").AccessPolicy) []const u8 {
    return switch (policy) {
        .private => "Private",
        .readonly => "Readonly",
        .public => "Public",
        .custom => "Custom",
    };
}

fn auditAccessPolicy(application: *Application, request_id: []const u8, bucket: []const u8, old_value: []const u8, new_value: []const u8) void {
    audit(application, request_id, "update_access_policy", bucket, new_value);
    std.log.info(
        "management audit request_id={s} actor={s} action=update_access_policy bucket={s} old_value={s} new_value={s} time={d}",
        .{ request_id, application.config.admin_username, bucket, old_value, new_value, std.Io.Clock.real.now(application.io.?).toSeconds() },
    );
}

fn auditRetention(application: *Application, request_id: []const u8, bucket: []const u8, old_value: @import("../domain/bucket.zig").Retention, new_value: @import("../domain/bucket.zig").Retention) void {
    audit(application, request_id, "update_retention", bucket, if (new_value.enabled) "enabled" else "disabled");
    std.log.info(
        "management audit request_id={s} actor={s} action=update_retention bucket={s} old_enabled={} old_duration={d} old_mode={s} new_enabled={} new_duration={d} new_mode={s} time={d}",
        .{ request_id, application.config.admin_username, bucket, old_value.enabled, old_value.default_duration_seconds orelse 0, if (old_value.mode) |mode| @tagName(mode) else "null", new_value.enabled, new_value.default_duration_seconds orelse 0, if (new_value.mode) |mode| @tagName(mode) else "null", std.Io.Clock.real.now(application.io.?).toSeconds() },
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

test "management object listing query supports bounded search pagination" {
    var query = try parseListQuery(
        std.testing.allocator,
        "/_admin/v1/buckets/photos/objects?search=dir%2F&max_keys=10&continuation_token=token",
    );
    defer query.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dir/", query.search.?);
    try std.testing.expectEqual(@as(usize, 10), query.max_keys);
    try std.testing.expectEqualStrings("token", query.continuation_token.?);
    try std.testing.expectError(
        error.InvalidQuery,
        parseListQuery(std.testing.allocator, "/objects?max_keys=1001"),
    );
}

test "management version listing only returns files at the current path" {
    try std.testing.expect(isDirectVersionKey("root.txt", ""));
    try std.testing.expect(!isDirectVersionKey("images/", ""));
    try std.testing.expect(!isDirectVersionKey("images/boat.png", ""));
    try std.testing.expect(isDirectVersionKey("images/boat.png", "images/"));
    try std.testing.expect(!isDirectVersionKey("images/archive/boat.png", "images/"));
    try std.testing.expect(!isDirectVersionKey("documents/readme.txt", "images/"));
}

test "management directory delete query decodes a trailing slash key" {
    const key = (try parseDirectoryKeyQuery(
        std.testing.allocator,
        "/_admin/v1/buckets/test/directories?key=images%2F",
    )).?;
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("images/", key);
}

fn servePolicies(request: *std.http.Server.Request, app: *Application, request_id: []const u8, route_path: []const u8) !std.http.Status {
    const store = @import("../application/policy_store.zig");
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    const collection = std.mem.eql(u8, route_path, api_prefix ++ "/policies");
    const method = request.head.method;
    if (collection and method != .GET and method != .POST) return respondMethodNotAllowed(request, request_id, "GET, POST");
    if (!collection and method != .GET and method != .PATCH and method != .DELETE) return respondMethodNotAllowed(request, request_id, "GET, PATCH, DELETE");
    const name = if (collection) try app.allocator.dupe(u8, "") else decodeComponent(app.allocator, route_path[(api_prefix ++ "/policies/").len..], false) catch return respondError(request, request_id, .bad_request, "InvalidPolicy", "invalid policy name");
    defer app.allocator.free(name);
    var input: ?std.json.Parsed(store.Policy) = null;
    defer if (input) |parsed| parsed.deinit();
    if (method == .POST or method == .PATCH) {
        input = try parseJsonBody(store.Policy, request, app.allocator, request_id) orelse return .bad_request;
        store.validate(app.allocator, input.?.value) catch return respondError(request, request_id, .bad_request, "InvalidPolicy", "policy name or JSON document is invalid");
        if (!collection and !std.mem.eql(u8, name, input.?.value.name)) return respondError(request, request_id, .bad_request, "InvalidPolicy", "policy names cannot be changed");
    }
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = store.load(root, io, app.allocator) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot read policy storage");
    defer loaded.deinit();
    var index: ?usize = null;
    const lookup = if (input) |parsed| parsed.value.name else name;
    for (loaded.value, 0..) |policy, i| {
        if (std.mem.eql(u8, policy.name, lookup)) {
            index = i;
            break;
        }
    }
    if (method == .GET) {
        if (collection) return respondJson(request, request_id, .ok, .{ .items = loaded.value });
        if (index) |i| return respondJson(request, request_id, .ok, loaded.value[i]);
        return respondError(request, request_id, .not_found, "PolicyNotFound", "policy does not exist");
    }
    if (method == .POST and index != null) return respondError(request, request_id, .conflict, "PolicyAlreadyExists", "policy already exists");
    if (method != .POST and index == null) return respondError(request, request_id, .not_found, "PolicyNotFound", "policy does not exist");
    if (method == .DELETE) {
        const identities = @import("../application/identity_store.zig");
        const attached = identities.load(root, io, app.allocator) catch return respondError(request, request_id, .service_unavailable, "IdentityStorageUnavailable", "cannot check policy attachments");
        defer attached.deinit();
        if (identities.policyInUse(attached.value, name)) return respondError(request, request_id, .conflict, "PolicyInUse", "detach this policy from users and groups before deleting it");
        const roles = role_store.load(root, io, app.allocator) catch return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot check role policy attachments");
        defer roles.deinit();
        if (role_store.policyInUse(roles.value, name)) return respondError(request, request_id, .conflict, "PolicyInUse", "detach this policy from roles before deleting it");
        const oidc = @import("../application/oidc_store.zig");
        const key = if (app.master_key) |k| k.bytes else return respondNotReady(request, request_id);
        const providers = oidc.load(root, io, app.allocator, key) catch return respondError(request, request_id, .service_unavailable, "OidcStorageUnavailable", "cannot check provider policy references");
        defer providers.deinit();
        for (providers.value.items) |provider| {
            var names = std.mem.splitScalar(u8, provider.role_policy, ',');
            while (names.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), name)) return respondError(request, request_id, .conflict, "PolicyInUse", "detach this policy from OIDC providers before deleting it");
        }
    }
    var items: std.ArrayList(store.Policy) = .empty;
    defer items.deinit(app.allocator);
    for (loaded.value, 0..) |policy, i| {
        if (index != null and index.? == i) {
            if (method == .PATCH) try items.append(app.allocator, input.?.value);
        } else try items.append(app.allocator, policy);
    }
    if (method == .POST) try items.append(app.allocator, input.?.value);
    store.save(root, io, app.allocator, items.items) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot save policy storage");
    audit(app, request_id, "mutate_policy", lookup, @tagName(method));
    if (method == .DELETE) return respondNoContent(request, request_id);
    return respondJson(request, request_id, if (method == .POST) .created else .ok, input.?.value);
}

fn serveRoles(comptime organization: bool, request: *std.http.Server.Request, app: *Application, request_id: []const u8, route_path: []const u8) !std.http.Status {
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    const method = request.head.method;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = api_prefix ++ (if (organization) "/organizations" else "/roles");
    const collection = std.mem.eql(u8, route_path, prefix);
    const raw_name = if (collection) null else decodeComponent(a, route_path[prefix.len + 1 ..], false) catch return respondError(request, request_id, .bad_request, "InvalidName", "invalid role or organization name");
    if (!collection and (raw_name == null or !role_store.validName(raw_name.?))) return respondError(request, request_id, .bad_request, "InvalidName", "invalid role or organization name");
    if (method == .GET) {
        const loaded = role_store.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot read roles");
        if (collection) return respondJson(request, request_id, .ok, if (organization) .{ .items = loaded.value.organizations } else .{ .items = loaded.value.roles });
        if (organization) for (loaded.value.organizations) |item| if (std.mem.eql(u8, item.name, raw_name.?)) return respondJson(request, request_id, .ok, item);
        if (!organization) for (loaded.value.roles) |item| if (std.mem.eql(u8, item.name, raw_name.?)) return respondJson(request, request_id, .ok, item);
        return respondError(request, request_id, .not_found, "NotFound", "role or organization does not exist");
    }
    if (method != .POST and method != .PATCH and method != .DELETE) return respondMethodNotAllowed(request, request_id, "GET, POST, PATCH, DELETE");
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = role_store.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot read roles");
    var snapshot = loaded.value;
    if (method == .PATCH) {
        if (collection) return respondError(request, request_id, .bad_request, "InvalidName", "PATCH must target one role or organization");
        if (organization) {
            const input = (try parseJsonBody(role_store.Organization, request, a, request_id) orelse return .bad_request).value;
            var items: std.ArrayList(role_store.Organization) = .empty;
            var found = false;
            for (snapshot.organizations) |item| {
                if (std.mem.eql(u8, item.name, raw_name.?)) {
                    found = true;
                    if (!role_store.validName(input.name)) return respondError(request, request_id, .bad_request, "InvalidName", "invalid organization name");
                    try items.append(a, .{ .id = item.id, .name = input.name, .enabled = input.enabled, .paths = input.paths, .members = input.members });
                } else try items.append(a, item);
            }
            if (!found) return respondError(request, request_id, .not_found, "OrganizationNotFound", "organization does not exist");
            snapshot.organizations = items.items;
            try role_store.save(root, io, a, snapshot);
            return respondJson(request, request_id, .ok, items.items[items.items.len - 1]);
        }
        const input = (try parseJsonBody(role_store.Role, request, a, request_id) orelse return .bad_request).value;
        var items: std.ArrayList(role_store.Role) = .empty;
        var found = false;
        const policies = try @import("../application/policy_store.zig").load(root, io, a);
        for (snapshot.roles) |item| {
            if (std.mem.eql(u8, item.name, raw_name.?)) {
                found = true;
                if (!role_store.validName(input.name)) return respondError(request, request_id, .bad_request, "InvalidName", "invalid role name");
                try role_store.validate(a, .{ .id = item.id, .name = input.name, .organization_id = input.organization_id, .enabled = input.enabled, .max_session_seconds = input.max_session_seconds, .trust_policy = input.trust_policy, .policies = input.policies, .permissions_boundary = input.permissions_boundary, .tags_json = input.tags_json }, snapshot, policies.value);
                try items.append(a, .{ .id = item.id, .name = input.name, .organization_id = input.organization_id, .enabled = input.enabled, .max_session_seconds = input.max_session_seconds, .trust_policy = input.trust_policy, .policies = input.policies, .permissions_boundary = input.permissions_boundary, .tags_json = input.tags_json });
            } else try items.append(a, item);
        }
        if (!found) return respondError(request, request_id, .not_found, "RoleNotFound", "role does not exist");
        snapshot.roles = items.items;
        try role_store.save(root, io, a, snapshot);
        return respondJson(request, request_id, .ok, items.items[items.items.len - 1]);
    }
    if (method == .DELETE) {
        if (collection) return respondError(request, request_id, .bad_request, "InvalidName", "collection cannot be deleted");
        if (organization) {
            const org = for (snapshot.organizations) |item| {
                if (std.mem.eql(u8, item.name, raw_name.?)) break item;
            } else return respondError(request, request_id, .not_found, "OrganizationNotFound", "organization does not exist");
            if (role_store.organizationInUse(snapshot, org.id)) return respondError(request, request_id, .conflict, "OrganizationInUse", "organization is referenced by a role");
            var items: std.ArrayList(role_store.Organization) = .empty;
            for (snapshot.organizations) |item| if (!std.mem.eql(u8, item.name, raw_name.?)) try items.append(a, item);
            snapshot.organizations = items.items;
        } else {
            const role = for (snapshot.roles) |item| {
                if (std.mem.eql(u8, item.name, raw_name.?)) break item;
            } else return respondError(request, request_id, .not_found, "RoleNotFound", "role does not exist");
            if (role_store.hasActiveSession(snapshot, role.id, std.Io.Clock.real.now(io).toSeconds())) return respondError(request, request_id, .conflict, "RoleSessionsExist", "revoke active role sessions before deleting the role");
            var items: std.ArrayList(role_store.Role) = .empty;
            for (snapshot.roles) |item| if (!std.mem.eql(u8, item.name, raw_name.?)) try items.append(a, item);
            snapshot.roles = items.items;
        }
        try role_store.save(root, io, a, snapshot);
        return respondNoContent(request, request_id);
    }
    if (!collection) return respondError(request, request_id, .bad_request, "InvalidName", "POST must target a collection");
    if (organization) {
        const value = (try parseJsonBody(role_store.Organization, request, a, request_id) orelse return .bad_request).value;
        if (!role_store.validName(value.name)) return respondError(request, request_id, .bad_request, "InvalidName", "invalid organization name");
        const id = if (value.id.len > 0) value.id else try @import("../application/identity_store.zig").newId(a, io);
        var items: std.ArrayList(role_store.Organization) = .empty;
        for (snapshot.organizations) |item| {
            if (std.mem.eql(u8, item.name, value.name)) return respondError(request, request_id, .conflict, "AlreadyExists", "organization already exists");
            try items.append(a, item);
        }
        try items.append(a, .{ .id = id, .name = value.name, .enabled = value.enabled, .paths = value.paths, .members = value.members });
        snapshot.organizations = items.items;
    } else {
        const value = (try parseJsonBody(role_store.Role, request, a, request_id) orelse return .bad_request).value;
        if (!role_store.validName(value.name)) return respondError(request, request_id, .bad_request, "InvalidName", "invalid role name");
        const id = if (value.id.len > 0) value.id else try @import("../application/identity_store.zig").newId(a, io);
        for (snapshot.roles) |item| if (std.mem.eql(u8, item.name, value.name)) return respondError(request, request_id, .conflict, "AlreadyExists", "role already exists");
        const policies = try @import("../application/policy_store.zig").load(root, io, a);
        try role_store.validate(a, .{ .id = id, .name = value.name, .organization_id = value.organization_id, .enabled = value.enabled, .max_session_seconds = value.max_session_seconds, .trust_policy = value.trust_policy, .policies = value.policies, .permissions_boundary = value.permissions_boundary, .tags_json = value.tags_json }, snapshot, policies.value);
        var items: std.ArrayList(role_store.Role) = .empty;
        try items.appendSlice(a, snapshot.roles);
        try items.append(a, .{ .id = id, .name = value.name, .organization_id = value.organization_id, .enabled = value.enabled, .max_session_seconds = value.max_session_seconds, .trust_policy = value.trust_policy, .policies = value.policies, .permissions_boundary = value.permissions_boundary, .tags_json = value.tags_json });
        snapshot.roles = items.items;
    }
    try role_store.save(root, io, a, snapshot);
    return respondJson(request, request_id, .created, if (organization) snapshot.organizations[snapshot.organizations.len - 1] else snapshot.roles[snapshot.roles.len - 1]);
}

const AssumeRoleInput = struct {
    role_id: []const u8,
    session_name: []const u8,
    duration_seconds: u64 = 3600,
    external_id: ?[]const u8 = null,
    source_identity: ?[]const u8 = null,
    session_tags_json: ?[]const u8 = null,
    transitive_tag_keys_json: ?[]const u8 = null,
    session_policy: ?[]const u8 = null,
};

fn serveAssumeRole(request: *std.http.Server.Request, app: *Application, request_id: []const u8, caller: management_auth.Principal) !std.http.Status {
    if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try parseJsonBody(AssumeRoleInput, request, a, request_id) orelse return .bad_request;
    const input = parsed.value;
    if (!role_store.validName(input.session_name) or input.session_name.len > 64) return respondError(request, request_id, .bad_request, "InvalidSessionName", "session name is invalid");
    if ((input.external_id != null and !role_store.validSessionAttribute(input.external_id.?, 1024)) or (input.source_identity != null and !role_store.validSessionAttribute(input.source_identity.?, 128)) or !role_store.validTagsJson(input.session_tags_json) or !role_store.validTagsJson(input.transitive_tag_keys_json)) return respondError(request, request_id, .bad_request, "InvalidSessionAttributes", "invalid external id, source identity, or session tags");
    if (input.session_policy) |policy| _ = @import("../auth/iam_policy.zig").validateDocument(a, policy, .session) catch return respondError(request, request_id, .bad_request, "InvalidSessionPolicy", "invalid session policy");
    const loaded = role_store.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot read roles");
    if (caller.federated) return respondError(request, request_id, .forbidden, "AccessDenied", "OIDC identities use web-identity credentials rather than local user role trust");
    const role = role_store.findRole(loaded.value, input.role_id) orelse return respondError(request, request_id, .not_found, "RoleNotFound", "role does not exist");
    if (!role.enabled) return respondError(request, request_id, .forbidden, "RoleDisabled", "role is disabled");
    if (input.duration_seconds < 900 or input.duration_seconds > 43200 or input.duration_seconds > role.max_session_seconds) return respondError(request, request_id, .bad_request, "InvalidDuration", "duration exceeds role limits");
    if (!caller.is_root) {
        var entries = std.ArrayList(@import("../auth/iam_policy.zig").Entry).empty;
        try entries.append(a, .{ .key = "aws:userid", .value = caller.id });
        try entries.append(a, .{ .key = "aws:username", .value = caller.username });
        try entries.append(a, .{ .key = "aws:PrincipalArn", .value = try std.fmt.allocPrint(a, "arn:aws:iam::{s}:user/{s}", .{ @import("../application/resource_policy_store.zig").account_id, caller.username }) });
        try entries.append(a, .{ .key = "aws:PrincipalAccount", .value = @import("../application/resource_policy_store.zig").account_id });
        if (input.external_id) |value| try entries.append(a, .{ .key = "sts:ExternalId", .value = value });
        if (input.source_identity) |value| try entries.append(a, .{ .key = "sts:SourceIdentity", .value = value });
        if (input.session_tags_json) |raw_tags| {
            const parsed_tags = std.json.parseFromSlice(std.json.Value, a, raw_tags, .{}) catch return respondError(request, request_id, .bad_request, "InvalidSessionAttributes", "session tags are invalid");
            defer parsed_tags.deinit();
            if (parsed_tags.value != .object) return respondError(request, request_id, .bad_request, "InvalidSessionAttributes", "session tags must be an object");
            var tag_iterator = parsed_tags.value.object.iterator();
            while (tag_iterator.next()) |tag| {
                if (tag.value_ptr.* != .string) return respondError(request, request_id, .bad_request, "InvalidSessionAttributes", "session tag values must be strings");
                try entries.append(a, .{ .key = try std.fmt.allocPrint(a, "aws:RequestTag/{s}", .{tag.key_ptr.*}), .value = tag.value_ptr.*.string });
            }
        }
        const role_resource = try std.fmt.allocPrint(a, "arn:aws:iam::{s}:role/{s}", .{ @import("../application/resource_policy_store.zig").account_id, role.name });
        const assume_context: @import("../auth/iam_policy.zig").Context = .{ .entries = entries.items, .kind = .identity };
        if (!caller.allows(a, "sts:AssumeRole", role_resource, assume_context)) return respondError(request, request_id, .forbidden, "AccessDenied", "caller policy does not allow sts:AssumeRole");
        if (!try role_store.canAssume(a, role, .{ .entries = entries.items, .principal_bindings = &.{} }, "sts:AssumeRole", role_resource)) return respondError(request, request_id, .forbidden, "AccessDenied", "trust policy does not allow this principal");
    }
    const credentials = app.credentialService() orelse return respondNotReady(request, request_id);
    const owner = try std.fmt.allocPrint(a, "role:{s}:{s}", .{ role.id, input.session_name });
    const created = credentials.createWithOptions(owner, .all, .{ .ttl_seconds = input.duration_seconds, .name = input.session_name, .policy_document = input.session_policy orelse "" });
    var result = created catch |err| return respondCredentialError(request, request_id, err);
    defer result.deinit(app.allocator);
    const now = std.Io.Clock.real.now(io).toSeconds();
    var sessions: std.ArrayList(role_store.Session) = .empty;
    for (loaded.value.sessions) |session| try sessions.append(a, session);
    try sessions.append(a, .{ .access_key = result.credential.access_key, .role_id = role.id, .session_name = input.session_name, .subject_id = try std.fmt.allocPrint(a, "{s}:{s}", .{ role.id, input.session_name }), .expires_at = now + @as(i64, @intCast(input.duration_seconds)), .source_identity = input.source_identity, .external_id = input.external_id, .session_tags_json = input.session_tags_json, .transitive_tag_keys_json = input.transitive_tag_keys_json, .session_policy = input.session_policy });
    var snapshot = loaded.value;
    snapshot.sessions = sessions.items;
    role_store.save(root, io, a, snapshot) catch {
        _ = credentials.delete(result.credential.access_key) catch {};
        return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot persist role session");
    };
    return respondJson(request, request_id, .created, .{ .access_key = result.credential.access_key, .secret_key = result.secret_key, .session_token = result.session_token.?, .role_id = role.id, .session_name = input.session_name, .expires_at = now + @as(i64, @intCast(input.duration_seconds)) });
}

fn serveRoleSessions(request: *std.http.Server.Request, app: *Application, request_id: []const u8, route_path: []const u8) !std.http.Status {
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = role_store.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot read roles");
    if (std.mem.eql(u8, route_path, api_prefix ++ "/role-sessions")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET");
        return respondJson(request, request_id, .ok, .{ .items = loaded.value.sessions });
    }
    const prefix = api_prefix ++ "/role-sessions/";
    if (!std.mem.endsWith(u8, route_path, "/revoke") or request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
    const access_key = route_path[prefix.len .. route_path.len - "/revoke".len];
    var sessions: std.ArrayList(role_store.Session) = .empty;
    var found = false;
    for (loaded.value.sessions) |session| {
        var copy = session;
        if (std.mem.eql(u8, session.access_key, access_key)) {
            copy.revoked = true;
            found = true;
        }
        try sessions.append(a, copy);
    }
    if (!found) return respondError(request, request_id, .not_found, "RoleSessionNotFound", "role session does not exist");
    var snapshot = loaded.value;
    snapshot.sessions = sessions.items;
    role_store.save(root, io, a, snapshot) catch return respondError(request, request_id, .service_unavailable, "RoleStorageUnavailable", "cannot persist role session");
    return respondNoContent(request, request_id);
}

fn serveIdentities(comptime is_group: bool, request: *std.http.Server.Request, app: *Application, request_id: []const u8, route_path: []const u8) !std.http.Status {
    const store = @import("../application/identity_store.zig");
    const policies = @import("../application/policy_store.zig");
    const T = if (is_group) store.Group else store.User;
    const Input = if (is_group) store.Group else store.UserInput;
    const prefix = api_prefix ++ (if (is_group) "/groups" else "/users");
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    const method = request.head.method;
    const collection = std.mem.eql(u8, prefix, route_path);
    if (collection and method != .GET and method != .POST) return respondMethodNotAllowed(request, request_id, "GET, POST");
    if (!collection and method != .GET and method != .PATCH and method != .DELETE) return respondMethodNotAllowed(request, request_id, "GET, PATCH, DELETE");
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = if (collection) "" else decodeComponent(a, route_path[prefix.len + 1 ..], false) catch return respondError(request, request_id, .bad_request, "InvalidIdentity", "invalid name");
    if (!collection and !store.validName(name)) return respondError(request, request_id, .bad_request, "InvalidIdentity", "invalid name");
    var input: ?Input = null;
    var user_patch: ?store.UserPatch = null;
    var group_patch: ?store.GroupPatch = null;
    if (method == .PATCH) {
        if (is_group) {
            const parsed = try parseJsonBody(store.GroupPatch, request, a, request_id) orelse return .bad_request;
            group_patch = parsed.value;
            if (group_patch.?.name) |value| if (!std.mem.eql(u8, name, value)) return respondError(request, request_id, .bad_request, "InvalidIdentity", "names cannot be changed");
        } else {
            const parsed = try parseJsonBody(store.UserPatch, request, a, request_id) orelse return .bad_request;
            user_patch = parsed.value;
            if (user_patch.?.name) |value| if (!std.mem.eql(u8, name, value)) return respondError(request, request_id, .bad_request, "InvalidIdentity", "names cannot be changed");
        }
    } else if (method == .POST) {
        const parsed = try parseJsonBody(Input, request, a, request_id) orelse return .bad_request;
        input = parsed.value;
    }
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = store.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "IdentityStorageUnavailable", "cannot read identity storage");
    const items = if (is_group) loaded.value.groups else loaded.value.users;
    const lookup = if (input) |value| value.name else name;
    const index = store.find(items, lookup);
    if (method == .POST and !collection and !std.mem.eql(u8, name, input.?.name)) return respondError(request, request_id, .bad_request, "InvalidIdentity", "names cannot be changed");
    if (method == .GET) {
        if (collection) {
            if (is_group) return respondJson(request, request_id, .ok, .{ .items = items });
            const public = try a.alloc(store.PublicUser, items.len);
            for (items, 0..) |user, i| public[i] = try store.publicUser(a, user, loaded.value.groups);
            return respondJson(request, request_id, .ok, .{ .items = public });
        }
        if (index) |i| {
            if (is_group) return respondJson(request, request_id, .ok, items[i]);
            return respondJson(request, request_id, .ok, try store.publicUser(a, items[i], loaded.value.groups));
        }
        return respondError(request, request_id, .not_found, "IdentityNotFound", "user or group does not exist");
    }
    if (method == .POST and index != null) return respondError(request, request_id, .conflict, "IdentityAlreadyExists", "name already exists");
    if (method != .POST and index == null) return respondError(request, request_id, .not_found, "IdentityNotFound", "user or group does not exist");
    if (method == .PATCH) {
        if (is_group) {
            const old = items[index.?];
            const patch = group_patch.?;
            if (patch.expected_updated_at) |revision| if (revision != old.updated_at) return respondError(request, request_id, .conflict, "RevisionConflict", "group changed; refresh and retry");
            input = .{ .id = old.id, .name = old.name, .description = patch.description orelse old.description, .enabled = patch.enabled orelse old.enabled, .policies = patch.policies orelse old.policies, .members = patch.members orelse old.members, .tags_json = patch.tags_json orelse old.tags_json, .updated_at = old.updated_at };
        } else {
            const old = items[index.?];
            const patch = user_patch.?;
            if (patch.expected_updated_at) |revision| if (revision != old.updated_at) return respondError(request, request_id, .conflict, "RevisionConflict", "user changed; refresh and retry");
            input = .{ .id = old.id, .auth_version = old.auth_version, .updated_at = old.updated_at, .name = old.name, .description = patch.description orelse old.description, .enabled = patch.enabled orelse old.enabled, .policies = patch.policies orelse old.policies, .password = patch.password, .groups = patch.groups, .tags_json = patch.tags_json orelse old.tags_json };
        }
    }
    if (!is_group and method == .DELETE) {
        const credentials = app.credentialService() orelse return respondNotReady(request, request_id);
        const keys = credentials.list() catch |err| return respondCredentialError(request, request_id, err);
        defer keys.deinit(app.allocator);
        const owner = try std.fmt.allocPrint(a, "user:{s}", .{name});
        for (keys.credentials) |key| if (std.mem.eql(u8, key.credential.owner, owner)) return respondError(request, request_id, .conflict, "UserAccessKeysExist", "delete the user's access keys before deleting the user");
    }
    if (input) |value| {
        const available = policies.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot read policy storage");
        store.validate(value, loaded.value, available.value) catch |err| return respondError(request, request_id, .bad_request, @errorName(err), switch (err) {
            error.PolicyNotFound => "a selected policy no longer exists; refresh and retry",
            error.UserNotFound => "a selected user no longer exists; refresh and retry",
            else => "invalid name, description or duplicate selections",
        });
    }
    var snapshot = loaded.value;
    const now = std.Io.Clock.real.now(io).toSeconds();
    var prepared: ?T = null;
    if (input) |value| {
        if (is_group) {
            prepared = value;
            prepared.?.id = if (index) |i| items[i].id else try store.newId(a, io);
            prepared.?.updated_at = now;
        } else {
            if (value.groups) |names| store.assignGroups(a, &snapshot, value.name, names, now) catch return respondError(request, request_id, .bad_request, "InvalidGroup", "selected groups are invalid or no longer exist");
            prepared = store.prepareUser(a, io, value, if (index) |i| items[i] else null, now) catch |err| return respondError(request, request_id, if (err == error.InvalidPassword) .bad_request else .service_unavailable, @errorName(err), if (err == error.InvalidPassword) "password must contain 8 to 1024 bytes" else "cannot prepare password");
        }
    }
    if (is_group) {
        const users = try a.dupe(store.User, snapshot.users);
        for (users) |*user| {
            const before = if (index) |i| store.contains(items[i].members, user.name) else false;
            const after = if (prepared) |value| store.contains(value.members, user.name) else false;
            if (before != after) user.updated_at = now;
        }
        snapshot.users = users;
    }
    if (!is_group and method == .DELETE) {
        snapshot = try store.withoutUser(a, snapshot, name);
        const groups = try a.dupe(store.Group, snapshot.groups);
        for (groups, loaded.value.groups) |*group, old| {
            if (old.members.len != group.members.len) group.updated_at = now;
        }
        snapshot.groups = groups;
    } else {
        var next: std.ArrayList(T) = .empty;
        for (items, 0..) |item, i| {
            if (index != null and i == index.?) {
                if (method == .PATCH) try next.append(a, prepared.?);
            } else try next.append(a, item);
        }
        if (method == .POST) try next.append(a, prepared.?);
        if (is_group) snapshot.groups = next.items else snapshot.users = next.items;
    }
    store.save(root, io, a, snapshot) catch |err| return respondError(request, request_id, if (err == error.IdentityLimit) .bad_request else .service_unavailable, @errorName(err), "cannot save identities");
    audit(app, request_id, if (is_group) "mutate_group" else "mutate_user", lookup, @tagName(method));
    if (method == .DELETE) return respondNoContent(request, request_id);
    if (is_group) return respondJson(request, request_id, if (method == .POST) .created else .ok, prepared.?);
    return respondJson(request, request_id, if (method == .POST) .created else .ok, try store.publicUser(a, prepared.?, snapshot.groups));
}

// Lock identity changes through the scoped operation; credential ownership is immutable.
fn serveUserAccessKeys(request: *std.http.Server.Request, app: *Application, request_id: []const u8, path: []const u8) !std.http.Status {
    const identities = @import("../application/identity_store.zig");
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    const service = app.credentialService() orelse return respondNotReady(request, request_id);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parts = std.mem.splitScalar(u8, path[(api_prefix ++ "/users/").len..], '/');
    const name = decodeComponent(a, parts.next() orelse "", false) catch return respondError(request, request_id, .bad_request, "InvalidIdentity", "invalid user");
    if (!identities.validName(name) or !std.mem.eql(u8, parts.next() orelse "", "access-keys")) return respondError(request, request_id, .bad_request, "InvalidIdentity", "invalid user access key path");
    const raw_key = parts.next();
    if (parts.next() != null or (raw_key != null and raw_key.?.len == 0)) return respondError(request, request_id, .bad_request, "InvalidAccessKey", "invalid access key path");
    const method = request.head.method;
    if (raw_key == null and method != .GET and method != .POST) return respondMethodNotAllowed(request, request_id, "GET, POST");
    if (raw_key != null and method != .PATCH and method != .DELETE) return respondMethodNotAllowed(request, request_id, "PATCH, DELETE");
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const snapshot = identities.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "IdentityStorageUnavailable", "cannot read users");
    const index = identities.find(snapshot.value.users, name) orelse return respondError(request, request_id, .not_found, "IdentityNotFound", "user does not exist");
    const owner = try std.fmt.allocPrint(a, "user:{s}", .{name});
    if (method == .POST) {
        if (!snapshot.value.users[index].enabled) return respondError(request, request_id, .conflict, "UserDisabled", "enable the user before creating access keys");
        return serveCreateAccessKey(request, app, request_id, owner);
    }
    if (raw_key) |raw| {
        const key = decodeComponent(a, raw, false) catch return respondError(request, request_id, .bad_request, "InvalidAccessKey", "invalid access key");
        const record = service.get(key) catch |err| return respondCredentialError(request, request_id, err);
        defer record.deinit(app.allocator);
        if (!std.mem.eql(u8, record.owner, owner)) return respondError(request, request_id, .not_found, "CredentialNotFound", "access key does not belong to this user");
        return if (method == .PATCH) serveUpdateAccessKey(request, app, request_id, raw) else serveDeleteAccessKey(request, app, request_id, raw);
    }
    const keys = service.list() catch |err| return respondCredentialError(request, request_id, err);
    defer keys.deinit(app.allocator);
    var output: std.Io.Writer.Allocating = .init(app.allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (keys.credentials) |key| {
        if (std.mem.eql(u8, key.credential.owner, owner)) try writeCredential(&json, key.credential, null, null);
    }
    try json.endArray();
    try json.endObject();
    return respondJsonBytes(request, request_id, .ok, output.written());
}

fn serveBucketResourcePolicy(request: *std.http.Server.Request, app: *Application, request_id: []const u8, raw_name: []const u8) !std.http.Status {
    const store = @import("../application/resource_policy_store.zig");
    const identities = @import("../application/identity_store.zig");
    const method = request.head.method;
    if (method != .GET and method != .PUT and method != .DELETE) return respondMethodNotAllowed(request, request_id, "GET, PUT, DELETE");
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = decodeComponent(a, raw_name, false) catch return respondError(request, request_id, .bad_request, "InvalidBucketName", "invalid bucket name");
    const buckets = app.bucketService() orelse return respondNotReady(request, request_id);
    const bucket = buckets.head(name) catch |err| return respondBucketError(request, request_id, err);
    defer bucket.deinit(app.allocator);
    const io = app.io orelse return respondNotReady(request, request_id);
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const Input = struct { document: []const u8 };
    const input = if (method == .PUT) (try parseJsonBody(Input, request, a, request_id) orelse return .bad_request).value else Input{ .document = "" };
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    if (method == .GET) {
        const record = store.load(a, root, io, bucket.id) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot read bucket policy");
        return respondJson(request, request_id, .ok, .{ .document = if (record) |value| if (value.value.deleted) "" else value.value.document else "" });
    }
    if (method == .DELETE) {
        if (bucket.access_policy == .custom) {
            const private_bucket = buckets.setAccessPolicy(name, .private) catch |err| return respondBucketError(request, request_id, err);
            private_bucket.deinit(app.allocator);
        }
        store.remove(a, root, io, bucket.id) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot delete bucket policy");
        return respondNoContent(request, request_id);
    }
    const snapshot = identities.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "IdentityStorageUnavailable", "cannot resolve policy principals");
    const prepared = store.prepare(a, input.document, bucket.name, snapshot.value) catch |err| return respondError(request, request_id, .bad_request, @errorName(err), "invalid bucket policy, resource or principal");
    const custom_bucket = buckets.setAccessPolicy(name, .custom) catch |err| return respondBucketError(request, request_id, err);
    custom_bucket.deinit(app.allocator);
    store.save(a, root, io, bucket.id, prepared) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot save bucket policy");
    audit(app, request_id, "put_bucket_policy", name, "updated");
    return respondJson(request, request_id, .ok, input);
}

fn serveOidc(request: *std.http.Server.Request, app: *Application, request_id: []const u8, route_path: []const u8, caller: management_auth.Principal) !std.http.Status {
    if (!caller.is_root) return respondError(request, request_id, .forbidden, "AccessDenied", "only the deployment administrator may configure OIDC");
    const store = @import("../application/oidc_store.zig");
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    const key = if (app.master_key) |k| k.bytes else return respondNotReady(request, request_id);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = api_prefix ++ "/oidc/providers";
    const collection = std.mem.eql(u8, route_path, prefix);
    const id = if (collection) "" else route_path[prefix.len + 1 ..];
    if (!collection and !store.validId(id)) return respondError(request, request_id, .bad_request, "InvalidProvider", "invalid provider ID");
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const loaded = store.load(root, io, a, key) catch return respondError(request, request_id, .service_unavailable, "OidcStorageUnavailable", "cannot read OIDC configuration");
    const method = request.head.method;
    if (method == .GET and collection) {
        var items: std.ArrayList(store.Provider) = .empty;
        for (loaded.value.items) |p| try items.append(a, p.redacted());
        return respondJson(request, request_id, .ok, .{ .items = items.items, .login_supported = true });
    }
    if ((method == .POST and !collection) or ((method == .PATCH or method == .DELETE) and collection) or (method != .POST and method != .PATCH and method != .DELETE)) return respondMethodNotAllowed(request, request_id, "GET, POST, PATCH, DELETE");
    var input: ?store.Provider = null;
    if (method != .DELETE) input = (try parseJsonBody(store.Provider, request, a, request_id) orelse return .bad_request).value;
    const lookup = if (method == .POST) input.?.provider_id else id;
    var found = false;
    var items: std.ArrayList(store.Provider) = .empty;
    for (loaded.value.items) |p| {
        if (!std.mem.eql(u8, p.provider_id, lookup)) {
            try items.append(a, p);
            continue;
        }
        found = true;
        if (method == .POST) return respondError(request, request_id, .conflict, "ProviderExists", "provider ID already exists");
        if (p.environment_managed) return respondError(request, request_id, .conflict, "EnvironmentManaged", "update this provider through ZIGFS_OIDC_PROVIDERS and restart ZigFS");
        if (method == .PATCH and input.?.client_secret.len == 0) input.?.client_secret = p.client_secret;
    }
    if (method != .POST and !found) return respondError(request, request_id, .not_found, "ProviderNotFound", "provider does not exist");
    if (input != null) input.?.environment_managed = false;
    if (input != null) input.?.revision = try @import("../application/identity_store.zig").newId(a, io);
    if (input) |value| {
        if (!std.mem.eql(u8, value.provider_id, lookup)) return respondError(request, request_id, .bad_request, "InvalidProvider", "provider ID cannot be changed");
        store.validate(value) catch return respondError(request, request_id, .bad_request, "InvalidProvider", "check provider ID, client credentials, URLs and openid scope");
        const policies = @import("../application/policy_store.zig");
        const policy_list = policies.load(root, io, a) catch return respondError(request, request_id, .service_unavailable, "PolicyStorageUnavailable", "cannot validate policy references");
        var names = std.mem.splitScalar(u8, value.role_policy, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            var exists = false;
            for (policy_list.value) |policy| {
                if (std.mem.eql(u8, policy.name, name)) exists = true;
            }
            if (!exists) return respondError(request, request_id, .bad_request, "PolicyNotFound", "Role Policy must reference existing policies");
        }
        try items.append(a, value);
    }
    store.save(root, io, a, key, .{ .items = items.items, .flows = loaded.value.flows, .sessions = loaded.value.sessions }) catch return respondError(request, request_id, .service_unavailable, "OidcStorageUnavailable", "cannot persist OIDC configuration");
    audit(app, request_id, "mutate_oidc_provider", lookup, @tagName(method));
    if (method == .DELETE) return respondNoContent(request, request_id);
    return respondJson(request, request_id, if (method == .POST) .created else .ok, input.?.redacted());
}

pub fn serveOidcAuth(request: *std.http.Server.Request, app: *Application, request_id: []const u8) !std.http.Status {
    const oidc = @import("../application/oidc_auth.zig");
    const store = @import("../application/oidc_store.zig");
    const root = app.data_root orelse return respondNotReady(request, request_id);
    const io = app.io orelse return respondNotReady(request, request_id);
    const key = if (app.master_key) |k| k.bytes else return respondNotReady(request, request_id);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = requestPath(request.head.target);
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/providers") and request.head.method == .GET) {
        app.policy_mutex.lockUncancelable(io);
        defer app.policy_mutex.unlock(io);
        const loaded = store.load(root, io, a, key) catch return respondError(request, request_id, .service_unavailable, "OidcUnavailable", "OIDC configuration unavailable");
        const Public = struct { provider_id: []const u8, display_name: []const u8 };
        var items: std.ArrayList(Public) = .empty;
        for (loaded.value.items) |p| if (p.enabled and p.redirect_uri.len > 0) {
            try items.append(a, .{ .provider_id = p.provider_id, .display_name = p.display_name });
        };
        return respondJson(request, request_id, .ok, .{ .items = items.items });
    }
    if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/start")) {
        const input = (try parseJsonBody(struct { provider_id: []const u8 }, request, a, request_id) orelse return .bad_request).value;
        const result = oidc.start(a, app, input.provider_id) catch return respondError(request, request_id, .bad_request, "OidcStartFailed", "provider unavailable or discovery/callback configuration invalid");
        return respondJson(request, request_id, .ok, result);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/logout")) {
        const input = (try parseJsonBody(struct { token: []const u8 }, request, a, request_id) orelse return .bad_request).value;
        oidc.logout(a, app, input.token) catch return respondError(request, request_id, .service_unavailable, "OidcUnavailable", "cannot revoke session");
        return respondNoContent(request, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/refresh")) {
        const input = (try parseJsonBody(struct { token: []const u8 }, request, a, request_id) orelse return .bad_request).value;
        const result = oidc.refresh(a, app, input.token) catch return respondError(request, request_id, .unauthorized, "OidcRefreshFailed", "session could not be renewed");
        return respondJson(request, request_id, .ok, result);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/end-session")) {
        const input = (try parseJsonBody(struct { token: []const u8 }, request, a, request_id) orelse return .bad_request).value;
        const url = oidc.endSession(a, app, input.token) catch return respondError(request, request_id, .service_unavailable, "OidcUnavailable", "session could not be revoked");
        return respondJson(request, request_id, .ok, .{ .logout_url = url });
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/backchannel-logout")) {
        const input = (try parseJsonBody(struct { provider_id: []const u8, logout_token: []const u8 }, request, a, request_id) orelse return .bad_request).value;
        oidc.backchannelLogout(a, app, input.provider_id, input.logout_token) catch return respondError(request, request_id, .bad_request, "InvalidLogoutToken", "logout token could not be verified");
        return respondNoContent(request, request_id);
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/web-identity")) {
        const input = (try parseJsonBody(struct { provider_id: []const u8, web_identity_token: []const u8, duration_seconds: u64 = 3600, session_policy: []const u8 = "" }, request, a, request_id) orelse return .bad_request).value;
        if (input.duration_seconds < 60 or input.duration_seconds > 3600) return respondError(request, request_id, .bad_request, "InvalidDuration", "duration must be between 60 and 3600 seconds");
        if (input.session_policy.len > 0) @import("../auth/iam_policy.zig").validateDocument(a, input.session_policy, .session) catch return respondError(request, request_id, .bad_request, "InvalidPolicy", "invalid session restriction policy");
        const identity = oidc.webIdentity(a, app, input.provider_id, input.web_identity_token) catch return respondError(request, request_id, .unauthorized, "InvalidIdentityToken", "web identity could not be verified");
        const now = std.Io.Clock.real.now(io).toSeconds();
        var issued = false;
        defer if (!issued) oidc.logout(a, app, identity.token) catch {};
        if (identity.expires_at < now + 60) return respondError(request, request_id, .unauthorized, "ExpiredToken", "identity token expired");
        const ttl = @min(input.duration_seconds, @as(u64, @intCast(identity.expires_at - now)));
        const credentials = app.credentialService() orelse return respondNotReady(request, request_id);
        var result = credentials.createWithOptions(try std.fmt.allocPrint(a, "oidc:{s}", .{try oidc.digest(a, identity.token)}), .all, .{ .ttl_seconds = ttl, .name = "oidc-session", .policy_document = input.session_policy }) catch return respondError(request, request_id, .service_unavailable, "CredentialUnavailable", "cannot issue temporary credentials");
        defer result.deinit(app.allocator);
        issued = true;
        return respondJson(request, request_id, .created, .{ .access_key = result.credential.access_key, .secret_key = result.secret_key, .session_token = result.session_token.?, .expires_at = now + @as(i64, @intCast(ttl)), .subject_id = identity.subject_id });
    }
    if (std.mem.eql(u8, path, api_prefix ++ "/auth/oidc/callback")) {
        const input = (try parseJsonBody(struct { state: []const u8, code: []const u8 }, request, a, request_id) orelse return .bad_request).value;
        const result = oidc.callback(a, app, input.state, input.code) catch return respondError(request, request_id, .unauthorized, "OidcLoginFailed", "OIDC login could not be verified");
        return respondJson(request, request_id, .ok, result);
    }
    return respondError(request, request_id, .not_found, "NotFound", "unknown OIDC operation");
}

fn validateOidcProvider(request: *std.http.Server.Request, app: *Application, request_id: []const u8, caller: management_auth.Principal) !std.http.Status {
    if (!caller.is_root) return respondError(request, request_id, .forbidden, "AccessDenied", "deployment administrator required");
    if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = (try parseJsonBody(@import("../application/oidc_store.zig").Provider, request, a, request_id) orelse return .bad_request).value;
    const issuer = @import("../application/oidc_auth.zig").validateDiscovery(a, app.io orelse return respondNotReady(request, request_id), p) catch return respondError(request, request_id, .bad_request, "OidcValidationFailed", "discovery or JWKS validation failed; check issuer URL, HTTPS and provider availability");
    return respondJson(request, request_id, .ok, .{ .issuer = issuer, .discovery_valid = true, .login_verified = false });
}

test "folder deletion query validates all versions and rejects duplicates" {
    const target = "/directories?key=folder%2F&all_versions=true";
    const key = (try parseDirectoryKeyQuery(std.testing.allocator, target)).?;
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("folder/", key);
    try std.testing.expect(queryAllVersions(target));
    try std.testing.expect(!queryAllVersions("/directories?key=folder%2F&all_versions=false"));
    try std.testing.expectError(error.InvalidQuery, parseDirectoryKeyQuery(std.testing.allocator, "/directories?key=a%2F&all_versions=yes"));
    try std.testing.expectError(error.InvalidQuery, parseDirectoryKeyQuery(std.testing.allocator, "/directories?key=a%2F&all_versions=true&all_versions=false"));
}

fn serveKmsSettings(request: *std.http.Server.Request, application: *Application, request_id: []const u8) !std.http.Status {
    const service = if (application.kms) |*kms| kms else return respondError(request, request_id, .service_unavailable, "Unavailable", "KMS is not ready");
    var arena = std.heap.ArenaAllocator.init(application.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (request.head.method == .PUT) {
        const parsed = try parseJsonBody(@import("../application/kms.zig").Config, request, a, request_id) orelse return .bad_request;
        service.save(a, parsed.value) catch |err| {
            std.log.warn("KMS configuration save failed: {s}", .{@errorName(err)});
            return respondError(request, request_id, if (err == error.InvalidKmsConfig or err == error.KmsVaultHttpsRequired) .bad_request else .service_unavailable, @errorName(err), @import("../application/kms.zig").saveErrorMessage(err));
        };
    } else if (request.head.method != .GET) return respondMethodNotAllowed(request, request_id, "GET, PUT");
    const status = service.status(a) catch return respondError(request, request_id, .service_unavailable, "KmsUnavailable", "KMS configuration could not be loaded");
    return respondJson(request, request_id, .ok, status);
}

fn serveKmsStart(request: *std.http.Server.Request, application: *Application, request_id: []const u8) !std.http.Status {
    if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
    const service = if (application.kms) |*kms| kms else return respondError(request, request_id, .service_unavailable, "KmsUnavailable", "KMS is not ready");
    var arena = std.heap.ArenaAllocator.init(application.allocator);
    defer arena.deinit();
    service.verify(arena.allocator()) catch |err| {
        const failed = service.status(arena.allocator()) catch return respondError(request, request_id, .service_unavailable, @errorName(err), @import("../application/kms.zig").saveErrorMessage(err));
        return respondError(request, request_id, .service_unavailable, @errorName(err), if (failed.errorMessage.len > 0) failed.errorMessage else @import("../application/kms.zig").saveErrorMessage(err));
    };
    return respondJson(request, request_id, .ok, try service.status(arena.allocator()));
}

fn serveKmsControl(request: *std.http.Server.Request, application: *Application, request_id: []const u8, stop: bool) !std.http.Status {
    if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
    const service = if (application.kms) |*kms| kms else return respondError(request, request_id, .service_unavailable, "KmsUnavailable", "KMS is not ready");
    var arena = std.heap.ArenaAllocator.init(application.allocator);
    defer arena.deinit();
    if (stop) service.stop(arena.allocator()) catch |err| return respondError(request, request_id, .service_unavailable, @errorName(err), @import("../application/kms.zig").saveErrorMessage(err)) else service.flushCache() catch |err| return respondError(request, request_id, .conflict, @errorName(err), @import("../application/kms.zig").saveErrorMessage(err));
    return respondJson(request, request_id, .ok, try service.status(arena.allocator()));
}

fn serveKmsKeys(request: *std.http.Server.Request, application: *Application, request_id: []const u8, action: bool) !std.http.Status {
    const service = if (application.kms) |*kms| kms else return respondError(request, request_id, .service_unavailable, "KmsUnavailable", "KMS is not ready");
    var arena = std.heap.ArenaAllocator.init(application.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (action) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "POST");
        const input = try parseJsonBody(struct { id: []const u8, action: []const u8 }, request, a, request_id) orelse return .bad_request;
        service.keyAction(a, input.value.id, input.value.action) catch |err| return kmsKeyError(request, request_id, err);
        return respondJson(request, request_id, .ok, .{ .ok = true });
    }
    if (request.head.method == .GET) {
        const keys = service.listKeys(a) catch |err| return kmsKeyError(request, request_id, err);
        return respondJson(request, request_id, .ok, keys);
    }
    if (request.head.method != .POST) return respondMethodNotAllowed(request, request_id, "GET, POST");
    const input = try parseJsonBody(@import("../application/kms_keys.zig").CreateKey, request, a, request_id) orelse return .bad_request;
    const key = service.createKey(a, input.value) catch |err| return kmsKeyError(request, request_id, err);
    return respondJson(request, request_id, .created, key);
}
fn kmsKeyError(request: *std.http.Server.Request, request_id: []const u8, err: anyerror) !std.http.Status {
    return respondError(request, request_id, switch (err) {
        error.InvalidKmsKeyRequest, error.InvalidKmsConfig => .bad_request,
        error.KmsNotRunning, error.KmsKeyPendingDeletion, error.KmsKeyDeletionNotScheduled, error.KmsKeyOperationUnsupported => .conflict,
        else => .service_unavailable,
    }, @errorName(err), @import("../application/kms.zig").saveErrorMessage(err));
}
