const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const bucket_service = @import("../application/bucket_service.zig");
const credential_service = @import("../application/credential_service.zig");
const object_listing = @import("../application/object_listing.zig");
const multipart_service = @import("../application/multipart_service.zig");
const object_service = @import("../application/object_service.zig");
const lifecycle_service = @import("../application/lifecycle_service.zig");
const policy = @import("../auth/policy.zig");
const sigv4 = @import("../auth/sigv4.zig");
const checksum = @import("../common/checksum.zig");
const time = @import("../common/time.zig");
const credential_domain = @import("../domain/credential.zig");
const object_domain = @import("../domain/object.zig");
const multipart_domain = @import("../domain/multipart.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const aws_chunked = @import("aws_chunked.zig");
const protocol = @import("s3_protocol.zig");
const delete_objects = @import("s3_delete_objects.zig");
const s3_multipart = @import("s3_multipart.zig");
const s3_post_policy = @import("s3_post_policy.zig");

pub const service_name = "s3";

const ByteRange = struct {
    start: u64,
    end: u64,
    length: u64,
};

const ChecksumRequest = struct {
    header: ?checksum.Value = null,
    header_crc64nvme: ?u64 = null,
    trailer: aws_chunked.Trailer = .none,
};

const ConditionalHeaders = struct {
    if_match: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
    if_unmodified_since: ?[]const u8 = null,

    fn isEmpty(self: ConditionalHeaders) bool {
        return self.if_match == null and self.if_none_match == null and
            self.if_modified_since == null and self.if_unmodified_since == null;
    }
};

const ConditionalOutcome = enum {
    proceed,
    not_modified,
    precondition_failed,
};

const MetadataDirective = enum { copy, replace };

const CopySource = struct {
    target: protocol.ParsedTarget,
    bucket: []const u8,
    key: []const u8,
    version_id: ?object_domain.VersionId,

    fn deinit(self: *CopySource) void {
        self.target.deinit();
        self.* = undefined;
    }
};

pub fn serveRequest(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    // Browsers use this unauthenticated preflight before direct presigned writes and deletes.
    if (request.head.method == .OPTIONS) return respondCorsPreflight(request, request_id);

    const allocator = application.allocator;
    const raw_target = request.head.target;
    var headers: std.ArrayList(sigv4.Header) = .empty;
    defer headers.deinit(allocator);
    var header_iterator = request.iterateHeaders();
    while (header_iterator.next()) |header| {
        headers.append(allocator, .{ .name = header.name, .value = header.value }) catch {
            return respondError(request, allocator, .internal_error, request_id);
        };
    }
    const host = if (application.config.s3_virtual_hosted_style)
        singleHeader(headers.items, "host") catch {
            return respondError(request, allocator, .invalid_request, request_id);
        }
    else
        null;
    const parsed = protocol.parseTargetWithHost(
        allocator,
        request.head.method,
        raw_target,
        host,
        application.config.s3_public_endpoint,
        application.config.s3_virtual_hosted_style,
    ) catch {
        return respondError(request, allocator, .invalid_request, request_id);
    };
    defer parsed.deinit();
    // Request body reads may reuse the HTTP head buffer. Keep Resource stable for errors.
    request.head.target = parsed.decoded_path;

    if (parsed.operation == .post_policy_upload) {
        const policy_authorization = singleHeader(headers.items, "authorization") catch {
            return respondError(request, allocator, .invalid_request, request_id);
        };
        if (sigv4.hasPresignedParameters(raw_target) or policy_authorization != null) {
            return respondError(request, allocator, .invalid_request, request_id);
        }
        return servePostPolicyUpload(request, application, parsed, headers.items, request_id);
    }

    const authorization_header = singleHeader(headers.items, "authorization") catch {
        return respondError(request, allocator, .authorization_header_malformed, request_id);
    };
    const uses_presigned_auth = sigv4.hasPresignedParameters(raw_target);
    if (uses_presigned_auth and authorization_header != null) {
        return respondError(request, allocator, .invalid_request, request_id);
    }
    if (uses_presigned_auth and !allowsPresigned(parsed.operation)) {
        return respondError(request, allocator, .access_denied, request_id);
    }

    var presigned: ?sigv4.PresignedAuthorization = null;
    defer if (presigned) |*value| value.deinit();
    var authorization: ?sigv4.Authorization = null;
    var payload_hash: sigv4.PayloadHash = .unsigned;
    const access_key: []const u8 = if (uses_presigned_auth) presigned_access: {
        presigned = sigv4.parsePresignedAuthorization(allocator, raw_target) catch |err| {
            return respondError(request, allocator, mapPresignedParseError(err), request_id);
        };
        break :presigned_access presigned.?.authorization.access_key;
    } else header_access: {
        const parsed_authorization = sigv4.parseAuthorization(headers.items) catch |err| {
            return respondError(request, allocator, mapSignatureParseError(err), request_id);
        };
        authorization = parsed_authorization;
        payload_hash = sigv4.requestPayloadHash(headers.items) catch {
            return respondError(request, allocator, .invalid_request, request_id);
        };
        break :header_access parsed_authorization.access_key;
    };
    const credentials = application.credentialService() orelse {
        return respondError(request, allocator, .service_unavailable, request_id);
    };
    var auth_material = credentials.resolveForAuth(access_key) catch |err| {
        return respondError(request, allocator, mapCredentialError(err), request_id);
    };
    defer auth_material.deinit(allocator);
    const provided_session_token = if (presigned) |value|
        value.security_token_storage
    else
        sigv4.headerSessionToken(headers.items) catch {
            return respondError(request, allocator, .invalid_token, request_id);
        };
    sigv4.validateSessionToken(auth_material.session_token, provided_session_token) catch {
        return respondError(request, allocator, .invalid_token, request_id);
    };
    const auth_request: sigv4.Request = .{
        .method = @tagName(request.head.method),
        .target = raw_target,
        .headers = headers.items,
        .now_unix_seconds = std.Io.Clock.real.now(application.io orelse {
            return respondError(request, allocator, .service_unavailable, request_id);
        }).toSeconds(),
        .expected_region = application.config.s3_region,
        .max_clock_skew_seconds = @intCast(application.config.s3_request_time_skew_seconds),
    };
    if (presigned) |value| {
        sigv4.verifyPresigned(allocator, auth_request, value, auth_material.secret_key) catch |err| {
            return respondError(request, allocator, mapPresignedVerifyError(err), request_id);
        };
    } else {
        sigv4.verify(allocator, auth_request, authorization.?, auth_material.secret_key) catch |err| {
            return respondError(request, allocator, mapSignatureVerifyError(err), request_id);
        };
    }

    if (hasUnsupportedHeaders(parsed.operation, headers.items)) {
        return respondError(request, allocator, .not_implemented, request_id);
    }

    const copy_source_header = singleHeader(headers.items, "x-amz-copy-source") catch {
        return respondError(request, allocator, .invalid_argument, request_id);
    };

    if (actionFor(parsed.operation)) |action| {
        policy.authorize(auth_material.policy, action) catch {
            return respondError(request, allocator, .access_denied, request_id);
        };
    }
    if (copy_source_header != null) {
        policy.authorize(auth_material.policy, .get_object) catch {
            return respondError(request, allocator, .access_denied, request_id);
        };
    }
    return switch (parsed.operation) {
        .list_buckets => serveListBuckets(
            request,
            application,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .create_bucket => serveCreateBucket(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .head_bucket => serveHeadBucket(
            request,
            application,
            parsed.bucket.?,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .get_bucket_location => serveGetBucketLocation(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .get_bucket_versioning => serveGetBucketVersioning(request, application, parsed, auth_material.owner, headers.items, request_id),
        .put_bucket_versioning => servePutBucketVersioning(request, application, parsed, auth_material.owner, headers.items, payload_hash, request_id),
        .get_bucket_lifecycle => serveGetBucketLifecycle(request, application, parsed, auth_material.owner, headers.items, request_id),
        .put_bucket_lifecycle => servePutBucketLifecycle(request, application, parsed, auth_material.owner, headers.items, payload_hash, request_id),
        .delete_bucket_lifecycle => serveDeleteBucketLifecycle(request, application, parsed, auth_material.owner, headers.items, request_id),
        .delete_bucket => serveDeleteBucket(
            request,
            application,
            parsed.bucket.?,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .delete_objects => serveDeleteObjects(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .list_objects_v2 => serveListObjects(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .list_object_versions => serveListObjectVersions(request, application, parsed, auth_material.owner, headers.items, request_id),
        .list_multipart_uploads => serveListMultipartUploads(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .put_object => servePutObject(
            request,
            application,
            parsed.bucket.?,
            parsed.key.?,
            auth_material.owner,
            headers.items,
            authorization,
            auth_material.secret_key,
            payload_hash,
            request_id,
        ),
        .get_object => serveGetObject(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            payload_hash,
            request_id,
        ),
        .head_object => serveHeadObject(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .delete_object => serveDeleteObject(
            request,
            application,
            parsed,
            auth_material.owner,
            payload_hash,
            request_id,
        ),
        .create_multipart_upload => serveCreateMultipartUpload(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .upload_part => serveUploadPart(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            authorization,
            auth_material.secret_key,
            payload_hash,
            request_id,
        ),
        .list_parts => serveListParts(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .complete_multipart_upload => serveCompleteMultipartUpload(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            payload_hash,
            request_id,
        ),
        .abort_multipart_upload => serveAbortMultipartUpload(
            request,
            application,
            parsed,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .post_policy_upload => respondError(request, allocator, .invalid_request, request_id),
        .unsupported => respondError(request, allocator, .not_implemented, request_id),
    };
}

fn actionFor(operation: protocol.Operation) ?credential_domain.Action {
    return switch (operation) {
        .list_buckets => .list_buckets,
        .create_bucket => .create_bucket,
        .head_bucket => .head_bucket,
        .get_bucket_location => .head_bucket,
        .get_bucket_versioning, .get_bucket_lifecycle => .head_bucket,
        .put_bucket_versioning, .put_bucket_lifecycle, .delete_bucket_lifecycle => .create_bucket,
        .delete_bucket => .delete_bucket,
        .delete_objects => .delete_object,
        .list_objects_v2, .list_object_versions => .list_objects,
        .list_multipart_uploads => .head_bucket,
        .put_object => .put_object,
        .get_object => .get_object,
        .head_object => .head_object,
        .delete_object => .delete_object,
        .create_multipart_upload, .upload_part, .complete_multipart_upload => .put_object,
        .list_parts => .get_object,
        .abort_multipart_upload => .delete_object,
        .post_policy_upload => .put_object,
        .unsupported => null,
    };
}

fn allowsPresigned(operation: protocol.Operation) bool {
    return switch (operation) {
        .get_object,
        .put_object,
        .delete_object,
        .list_multipart_uploads,
        .create_multipart_upload,
        .upload_part,
        .list_parts,
        .complete_multipart_upload,
        .abort_multipart_upload,
        => true,
        else => false,
    };
}

fn serveListBuckets(
    request: *std.http.Server.Request,
    application: *Application,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const buckets = application.bucketService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const result = buckets.list() catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    defer result.deinit(application.allocator);
    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Owner><ID>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
    writer.writeAll("</ID><DisplayName>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
    writer.writeAll("</DisplayName></Owner><Buckets>") catch return error.WriteFailed;
    for (result.buckets) |bucket| {
        if (!std.mem.eql(u8, bucket.owner, owner)) continue;
        writer.writeAll("<Bucket><Name>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, bucket.name) catch return error.WriteFailed;
        writer.writeAll("</Name><CreationDate>") catch return error.WriteFailed;
        protocol.writeIsoTime(writer, bucket.created_at_unix_seconds) catch return error.WriteFailed;
        writer.writeAll("</CreationDate></Bucket>") catch return error.WriteFailed;
    }
    writer.writeAll("</Buckets></ListAllMyBucketsResult>\n") catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn serveCreateBucket(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    const payload_error = try validateCreateBucketPayload(
        request,
        application.allocator,
        headers,
        application.config.s3_region,
    );
    if (payload_error) |kind| return respondError(request, application.allocator, kind, request_id);
    const buckets = application.bucketService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const result = buckets.create(parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    defer result.deinit(application.allocator);
    if (!result.created and !std.mem.eql(u8, application.config.s3_region, "us-east-1")) {
        return respondError(
            request,
            application.allocator,
            .bucket_already_owned_by_you,
            request_id,
        );
    }
    const location = parsed.decoded_path;
    const extra = [_]std.http.Header{.{ .name = "location", .value = location }};
    return respondEmpty(request, .ok, request_id, &extra);
}

fn serveHeadBucket(
    request: *std.http.Server.Request,
    application: *Application,
    bucket_name: []const u8,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    defer bucket.deinit(application.allocator);
    return respondEmpty(request, .ok, request_id, &.{});
}

fn serveGetBucketLocation(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const location = parsed.query("location") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    if (location.len != 0) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);

    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<LocationConstraint xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
    ) catch return respondError(request, application.allocator, .internal_error, request_id);
    if (!std.mem.eql(u8, application.config.s3_region, "us-east-1")) {
        protocol.writeXmlEscaped(writer, application.config.s3_region) catch {
            return respondError(request, application.allocator, .internal_error, request_id);
        };
    }
    writer.writeAll("</LocationConstraint>\n") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn serveGetBucketVersioning(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) return respondError(request, application.allocator, .invalid_request, request_id);
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    defer bucket.deinit(application.allocator);
    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">") catch return error.WriteFailed;
    switch (bucket.versioning) {
        .unversioned => {},
        .enabled => writer.writeAll("<Status>Enabled</Status>") catch return error.WriteFailed,
        .suspended => writer.writeAll("<Status>Suspended</Status>") catch return error.WriteFailed,
    }
    writer.writeAll("</VersioningConfiguration>\n") catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn servePutBucketVersioning(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const existing = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    existing.deinit(application.allocator);
    const body = readXmlPayload(request, application.allocator, 64 * 1024, payload_hash) catch |err| {
        return respondError(request, application.allocator, mapXmlPayloadError(err), request_id);
    };
    defer application.allocator.free(body);
    if (validateBodyChecksums(headers, body)) |checksum_error| {
        return respondError(request, application.allocator, checksum_error, request_id);
    }
    if (std.mem.indexOf(u8, body, "<VersioningConfiguration") == null) {
        return respondError(request, application.allocator, .malformed_xml, request_id);
    }
    const status = xmlElementText(body, "Status") orelse {
        return respondError(request, application.allocator, .malformed_xml, request_id);
    };
    const versioning: @import("../domain/bucket.zig").Versioning = if (std.mem.eql(u8, status, "Enabled"))
        .enabled
    else if (std.mem.eql(u8, status, "Suspended"))
        .suspended
    else
        return respondError(request, application.allocator, .malformed_xml, request_id);
    const buckets = application.bucketService() orelse return respondError(request, application.allocator, .service_unavailable, request_id);
    const updated = buckets.setVersioning(parsed.bucket.?, versioning) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    updated.deinit(application.allocator);
    return respondEmpty(request, .ok, request_id, &.{});
}

fn serveGetBucketLifecycle(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) return respondError(request, application.allocator, .invalid_request, request_id);
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    defer bucket.deinit(application.allocator);
    const configuration = bucket.lifecycle_configuration orelse {
        return respondError(request, application.allocator, .no_such_lifecycle_configuration, request_id);
    };
    return respondXml(request, configuration, .ok, request_id, &.{});
}

fn servePutBucketLifecycle(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const existing = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    existing.deinit(application.allocator);
    const body = readXmlPayload(request, application.allocator, 1024 * 1024, payload_hash) catch |err| {
        return respondError(request, application.allocator, mapXmlPayloadError(err), request_id);
    };
    defer application.allocator.free(body);
    if (validateBodyChecksums(headers, body)) |checksum_error| {
        return respondError(request, application.allocator, checksum_error, request_id);
    }
    const configuration = lifecycle_service.parse(application.allocator, body) catch |err| switch (err) {
        error.UnsupportedFeature => return respondError(request, application.allocator, .not_implemented, request_id),
        error.OutOfMemory => return respondError(request, application.allocator, .internal_error, request_id),
        else => return respondError(request, application.allocator, .malformed_xml, request_id),
    };
    configuration.deinit(application.allocator);
    const buckets = application.bucketService() orelse return respondError(request, application.allocator, .service_unavailable, request_id);
    const updated = buckets.putLifecycle(parsed.bucket.?, body) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    updated.deinit(application.allocator);
    return respondEmpty(request, .ok, request_id, &.{});
}

fn serveDeleteBucketLifecycle(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) return respondError(request, application.allocator, .invalid_request, request_id);
    const existing = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    existing.deinit(application.allocator);
    const buckets = application.bucketService() orelse return respondError(request, application.allocator, .service_unavailable, request_id);
    const updated = buckets.deleteLifecycle(parsed.bucket.?) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    updated.deinit(application.allocator);
    return respondEmpty(request, .no_content, request_id, &.{});
}

fn serveDeleteBucket(
    request: *std.http.Server.Request,
    application: *Application,
    bucket_name: []const u8,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const buckets = application.bucketService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    buckets.delete(bucket_name) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    return respondEmpty(request, .no_content, request_id, &.{});
}

fn serveListObjects(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const list_type = parsed.query("list-type") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    if (!std.mem.eql(u8, list_type, "2")) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const fetch_owner = parsed.query("fetch-owner") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const include_owner = if (fetch_owner) |value|
        if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return respondError(request, application.allocator, .invalid_argument, request_id)
    else
        false;
    const prefix = parsed.query("prefix") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse "";
    const delimiter = parsed.query("delimiter") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const continuation_token = parsed.query("continuation-token") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const start_after = parsed.query("start-after") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const max_keys_value = parsed.query("max-keys") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const max_keys = if (max_keys_value) |value|
        std.fmt.parseInt(usize, value, 10) catch {
            return respondError(request, application.allocator, .invalid_argument, request_id);
        }
    else
        object_listing.max_keys;
    const encoding_type = parsed.query("encoding-type") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (encoding_type != null and !std.mem.eql(u8, encoding_type.?, "url")) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const listing = application.objectListing() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const result = listing.list(parsed.bucket.?, .{
        .prefix = prefix,
        .delimiter = delimiter,
        .max_keys = max_keys,
        .start_after = start_after,
        .continuation_token = continuation_token,
    }) catch |err| {
        return respondError(request, application.allocator, mapListingError(err), request_id);
    };
    defer result.deinit(application.allocator);
    const xml = buildListObjectsXml(
        application.allocator,
        parsed.bucket.?,
        prefix,
        delimiter,
        max_keys,
        start_after,
        continuation_token,
        encoding_type != null,
        include_owner,
        owner,
        result,
    ) catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    defer application.allocator.free(xml);
    return respondXml(request, xml, .ok, request_id, &.{});
}

fn serveListObjectVersions(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) return respondError(request, application.allocator, .invalid_request, request_id);
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const versions_query = parsed.query("versions") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (versions_query == null or versions_query.?.len != 0) return respondError(request, application.allocator, .invalid_argument, request_id);
    const prefix = parsed.query("prefix") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse "";
    const delimiter = parsed.query("delimiter") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const key_marker = parsed.query("key-marker") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const version_id_marker = parsed.query("version-id-marker") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (version_id_marker != null and key_marker == null) return respondError(request, application.allocator, .invalid_argument, request_id);
    const parsed_version_marker = if (version_id_marker) |value|
        object_domain.parseVersionId(value) catch return respondError(request, application.allocator, .invalid_argument, request_id)
    else
        null;
    const max_keys_text = parsed.query("max-keys") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const max_keys = if (max_keys_text) |value| std.fmt.parseInt(usize, value, 10) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } else 1000;
    if (max_keys > 1000) return respondError(request, application.allocator, .invalid_argument, request_id);
    const encoding_type = parsed.query("encoding-type") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (encoding_type != null and !std.mem.eql(u8, encoding_type.?, "url")) return respondError(request, application.allocator, .invalid_argument, request_id);

    const objects = application.objectService() orelse return respondError(request, application.allocator, .service_unavailable, request_id);
    const result = objects.listVersions(parsed.bucket.?, prefix) catch |err| {
        return respondError(request, application.allocator, mapObjectError(err), request_id);
    };
    defer result.deinit(application.allocator);

    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListVersionsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, parsed.bucket.?) catch return error.WriteFailed;
    writer.writeAll("</Name><Prefix>") catch return error.WriteFailed;
    writeEncodedXml(writer, prefix, encoding_type != null) catch return error.WriteFailed;
    writer.writeAll("</Prefix><KeyMarker>") catch return error.WriteFailed;
    if (key_marker) |value| writeEncodedXml(writer, value, encoding_type != null) catch return error.WriteFailed;
    writer.writeAll("</KeyMarker><VersionIdMarker>") catch return error.WriteFailed;
    if (version_id_marker) |value| protocol.writeXmlEscaped(writer, value) catch return error.WriteFailed;
    writer.writeAll("</VersionIdMarker>") catch return error.WriteFailed;
    if (delimiter) |value| {
        writer.writeAll("<Delimiter>") catch return error.WriteFailed;
        writeEncodedXml(writer, value, encoding_type != null) catch return error.WriteFailed;
        writer.writeAll("</Delimiter>") catch return error.WriteFailed;
    }
    if (encoding_type != null) writer.writeAll("<EncodingType>url</EncodingType>") catch return error.WriteFailed;

    var emitted: usize = 0;
    var is_truncated = false;
    var next_key: ?[]const u8 = null;
    var next_version: ?object_domain.VersionId = null;
    var last_common_prefix: ?[]const u8 = null;
    var marker_version_seen = parsed_version_marker == null;
    for (result.entries) |entry| {
        if (key_marker) |marker_key| {
            const order = std.mem.order(u8, entry.key, marker_key);
            if (order == .lt) continue;
            if (order == .eq) {
                if (parsed_version_marker == null) continue;
                if (!marker_version_seen) {
                    if (object_domain.VersionId.eql(entry.version_id, parsed_version_marker.?)) marker_version_seen = true;
                    continue;
                }
            }
        }
        var common_prefix: ?[]const u8 = null;
        if (delimiter) |separator| if (separator.len != 0) {
            const remainder = entry.key[prefix.len..];
            if (std.mem.indexOf(u8, remainder, separator)) |position| {
                common_prefix = entry.key[0 .. prefix.len + position + separator.len];
                if (last_common_prefix != null and std.mem.eql(u8, last_common_prefix.?, common_prefix.?)) continue;
            }
        };
        if (emitted == max_keys) {
            is_truncated = true;
            break;
        }
        if (common_prefix) |value| {
            writer.writeAll("<CommonPrefixes><Prefix>") catch return error.WriteFailed;
            writeEncodedXml(writer, value, encoding_type != null) catch return error.WriteFailed;
            writer.writeAll("</Prefix></CommonPrefixes>") catch return error.WriteFailed;
            last_common_prefix = value;
            next_key = value;
            next_version = null;
        } else {
            const element = if (entry.is_delete_marker) "DeleteMarker" else "Version";
            writer.print("<{s}><Key>", .{element}) catch return error.WriteFailed;
            writeEncodedXml(writer, entry.key, encoding_type != null) catch return error.WriteFailed;
            writer.writeAll("</Key><VersionId>") catch return error.WriteFailed;
            var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
            protocol.writeXmlEscaped(writer, entry.version_id.write(&version_buffer)) catch return error.WriteFailed;
            writer.print("</VersionId><IsLatest>{s}</IsLatest><LastModified>", .{if (entry.is_latest) "true" else "false"}) catch return error.WriteFailed;
            protocol.writeIsoTime(writer, entry.last_modified_unix_seconds) catch return error.WriteFailed;
            if (!entry.is_delete_marker) {
                var etag_buffer: [40]u8 = undefined;
                const etag = formatStoredEtag(entry.etag_md5, entry.etag_part_count, &etag_buffer);
                writer.writeAll("</LastModified><ETag>") catch return error.WriteFailed;
                protocol.writeXmlEscaped(writer, etag) catch return error.WriteFailed;
                writer.print("</ETag><Size>{d}</Size><StorageClass>STANDARD</StorageClass>", .{entry.size}) catch return error.WriteFailed;
            } else {
                writer.writeAll("</LastModified>") catch return error.WriteFailed;
            }
            writer.writeAll("<Owner><ID>") catch return error.WriteFailed;
            protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
            writer.writeAll("</ID><DisplayName>") catch return error.WriteFailed;
            protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
            writer.print("</DisplayName></Owner></{s}>", .{element}) catch return error.WriteFailed;
            next_key = entry.key;
            next_version = entry.version_id;
        }
        emitted += 1;
    }
    writer.print("<MaxKeys>{d}</MaxKeys><IsTruncated>{s}</IsTruncated>", .{ max_keys, if (is_truncated) "true" else "false" }) catch return error.WriteFailed;
    if (is_truncated and next_key != null) {
        writer.writeAll("<NextKeyMarker>") catch return error.WriteFailed;
        writeEncodedXml(writer, next_key.?, encoding_type != null) catch return error.WriteFailed;
        writer.writeAll("</NextKeyMarker>") catch return error.WriteFailed;
        if (next_version) |version| {
            var buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
            writer.writeAll("<NextVersionIdMarker>") catch return error.WriteFailed;
            protocol.writeXmlEscaped(writer, version.write(&buffer)) catch return error.WriteFailed;
            writer.writeAll("</NextVersionIdMarker>") catch return error.WriteFailed;
        }
    }
    writer.writeAll("</ListVersionsResult>\n") catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn serveListMultipartUploads(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const uploads_query = parsed.query("uploads") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    if (uploads_query.len != 0) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const prefix = parsed.query("prefix") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse "";
    const delimiter = parsed.query("delimiter") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const key_marker = parsed.query("key-marker") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const upload_id_marker = parsed.query("upload-id-marker") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const max_uploads_text = parsed.query("max-uploads") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const max_uploads = if (max_uploads_text) |value|
        std.fmt.parseInt(usize, value, 10) catch {
            return respondError(request, application.allocator, .invalid_argument, request_id);
        }
    else
        multipart_service.max_list_uploads;
    const encoding_type = parsed.query("encoding-type") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (encoding_type != null and !std.mem.eql(u8, encoding_type.?, "url")) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const multiparts = application.multipartService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const result = multiparts.listUploads(parsed.bucket.?, .{
        .prefix = prefix,
        .delimiter = delimiter,
        .key_marker = key_marker,
        .upload_id_marker = upload_id_marker,
        .max_uploads = max_uploads,
    }) catch |err| {
        return respondError(request, application.allocator, mapMultipartError(err), request_id);
    };
    defer result.deinit(application.allocator);

    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListMultipartUploadsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    protocol.writeXmlEscaped(writer, parsed.bucket.?) catch return error.WriteFailed;
    writer.writeAll("</Bucket><KeyMarker>") catch return error.WriteFailed;
    if (key_marker) |value| writeEncodedXml(writer, value, encoding_type != null) catch return error.WriteFailed;
    writer.writeAll("</KeyMarker><UploadIdMarker>") catch return error.WriteFailed;
    if (upload_id_marker) |value| protocol.writeXmlEscaped(writer, value) catch return error.WriteFailed;
    writer.writeAll("</UploadIdMarker>") catch return error.WriteFailed;
    if (result.is_truncated) {
        writer.writeAll("<NextKeyMarker>") catch return error.WriteFailed;
        if (result.next_key_marker) |value| writeEncodedXml(writer, value, encoding_type != null) catch return error.WriteFailed;
        writer.writeAll("</NextKeyMarker><NextUploadIdMarker>") catch return error.WriteFailed;
        if (result.next_upload_id_marker) |value| protocol.writeXmlEscaped(writer, value) catch return error.WriteFailed;
        writer.writeAll("</NextUploadIdMarker>") catch return error.WriteFailed;
    }
    if (delimiter) |value| {
        writer.writeAll("<Delimiter>") catch return error.WriteFailed;
        writeEncodedXml(writer, value, encoding_type != null) catch return error.WriteFailed;
        writer.writeAll("</Delimiter>") catch return error.WriteFailed;
    }
    writer.writeAll("<Prefix>") catch return error.WriteFailed;
    writeEncodedXml(writer, prefix, encoding_type != null) catch return error.WriteFailed;
    writer.print("</Prefix><MaxUploads>{d}</MaxUploads><IsTruncated>{s}</IsTruncated>", .{
        max_uploads,
        if (result.is_truncated) "true" else "false",
    }) catch return error.WriteFailed;
    if (encoding_type != null) writer.writeAll("<EncodingType>url</EncodingType>") catch return error.WriteFailed;
    for (result.uploads) |upload| {
        writer.writeAll("<Upload><Key>") catch return error.WriteFailed;
        writeEncodedXml(writer, upload.key, encoding_type != null) catch return error.WriteFailed;
        writer.writeAll("</Key><UploadId>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, upload.upload_id) catch return error.WriteFailed;
        writer.writeAll("</UploadId><Initiator><ID>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
        writer.writeAll("</ID><DisplayName>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
        writer.writeAll("</DisplayName></Initiator><Owner><ID>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
        writer.writeAll("</ID><DisplayName>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
        writer.writeAll("</DisplayName></Owner><StorageClass>STANDARD</StorageClass><Initiated>") catch return error.WriteFailed;
        protocol.writeIsoTime(writer, upload.initiated_at_unix_seconds) catch return error.WriteFailed;
        writer.writeAll("</Initiated></Upload>") catch return error.WriteFailed;
    }
    for (result.common_prefixes) |common_prefix| {
        writer.writeAll("<CommonPrefixes><Prefix>") catch return error.WriteFailed;
        writeEncodedXml(writer, common_prefix, encoding_type != null) catch return error.WriteFailed;
        writer.writeAll("</Prefix></CommonPrefixes>") catch return error.WriteFailed;
    }
    writer.writeAll("</ListMultipartUploadsResult>\n") catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn servePutObject(
    request: *std.http.Server.Request,
    application: *Application,
    bucket_name: []const u8,
    key: []const u8,
    owner: []const u8,
    headers: []const sigv4.Header,
    authorization: ?sigv4.Authorization,
    secret_key: []const u8,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const copy_source = singleHeader(headers, "x-amz-copy-source") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (copy_source != null) {
        return serveCopyObject(
            request,
            application,
            bucket_name,
            key,
            owner,
            headers,
            payload_hash,
            request_id,
        );
    }
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    const include_version_id = bucket.versioning != .unversioned;
    bucket.deinit(application.allocator);
    const conditions = parseConditionalHeaders(headers) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    var observed_object: ?object_domain.Object = null;
    defer if (observed_object) |value| value.deinit(application.allocator);
    if (!conditions.isEmpty()) {
        observed_object = objects.head(bucket_name, key) catch |err| switch (err) {
            error.ObjectNotFound => null,
            else => return respondError(request, application.allocator, mapObjectError(err), request_id),
        };
        const observed_view: ?*const object_domain.Object = if (observed_object) |*value| value else null;
        const outcome = evaluateConditional(conditions, observed_view, .PUT) catch {
            return respondError(request, application.allocator, .invalid_argument, request_id);
        };
        if (outcome == .precondition_failed) {
            return respondError(request, application.allocator, .precondition_failed, request_id);
        }
    }
    const expected_current: ?object_service.ExpectedCurrent = if (conditions.isEmpty())
        null
    else if (observed_object != null)
        .{ .generation = observed_object.?.metadata_generation }
    else
        .missing;
    const expected_md5 = parseContentMd5(headers) catch {
        return respondError(request, application.allocator, .invalid_digest, request_id);
    };
    const checksum_request = parseChecksumRequest(headers) catch |err| switch (err) {
        error.InvalidDigest => return respondError(request, application.allocator, .invalid_digest, request_id),
        error.UnsupportedChecksum => return respondError(request, application.allocator, .not_implemented, request_id),
        error.InvalidRequest => return respondError(request, application.allocator, .invalid_request, request_id),
    };
    const expected_crc64nvme = checksum_request.header_crc64nvme;
    const expected_checksum = checksum_request.header;
    const expected_sha256: ?[32]u8 = switch (payload_hash) {
        .digest => |digest| digest,
        .unsigned => null,
        .streaming => null,
    };
    var put_headers = collectPutHeaders(application.allocator, request) catch |err| switch (err) {
        error.OutOfMemory => return respondError(request, application.allocator, .internal_error, request_id),
        error.InvalidMetadata => return respondError(request, application.allocator, .invalid_request, request_id),
    };
    defer put_headers.deinit(application.allocator);
    var read_buffer: [16 * 1024]u8 = undefined;
    const stable_resource = request.head.target;
    const body_reader = request.readerExpectContinue(&read_buffer) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    request.head.target = stable_resource;
    var http_source: HttpSource = .{
        .reader = body_reader,
        .remaining = request.head.content_length,
    };
    var streaming_source: aws_chunked.Source = undefined;
    var streaming_source_active = false;
    defer if (streaming_source_active) streaming_source.deinit();
    const source = switch (payload_hash) {
        .digest, .unsigned => http_source.interface(),
        .streaming => streamed: {
            const decoded_length = parseStreamingDecodedLength(headers) catch {
                return respondError(request, application.allocator, .invalid_request, request_id);
            };
            const verifier = sigv4.StreamingVerifier.init(
                application.allocator,
                headers,
                authorization orelse {
                    return respondError(request, application.allocator, .invalid_request, request_id);
                },
                secret_key,
            ) catch |err| {
                return respondError(request, application.allocator, mapSignatureVerifyError(err), request_id);
            };
            streaming_source = aws_chunked.Source.init(
                body_reader,
                verifier,
                decoded_length,
                checksum_request.trailer,
            );
            streaming_source_active = true;
            break :streamed streaming_source.interface();
        },
    };
    const object = objects.put(bucket_name, key, source, .{
        .content_type = put_headers.content_type,
        .user_metadata = put_headers.views,
        .expected_md5 = expected_md5,
        .expected_sha256 = expected_sha256,
        .expected_crc64nvme = expected_crc64nvme,
        .expected_checksum = expected_checksum,
        .expected_current = expected_current,
    }) catch |err| {
        const kind: protocol.ErrorKind = if (err == error.InputReadFailed and streaming_source_active)
            mapStreamingFailure(streaming_source.failure)
        else if (err == error.ChecksumMismatch)
            if (expected_md5 != null or expected_checksum != null)
                .bad_digest
            else
                .x_amz_content_sha256_mismatch
        else
            mapObjectError(err);
        return respondError(request, application.allocator, kind, request_id);
    };
    defer object.deinit(application.allocator);
    var etag_buffer: [34]u8 = undefined;
    const etag = formatEtag(object.etag_md5, &etag_buffer);
    const response_checksum = expected_checksum orelse if (streaming_source_active)
        streaming_source.verified_checksum
    else
        null;
    if (response_checksum) |value| {
        var encoded_buffer: [64]u8 = undefined;
        var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
        const encoded = checksum.encodeValue(value, &encoded_buffer);
        var extra = [_]std.http.Header{
            .{ .name = "etag", .value = etag },
            .{ .name = value.algorithm().headerName(), .value = encoded },
            .{ .name = "x-amz-version-id", .value = object.version_id.write(&version_buffer) },
        };
        return respondEmpty(request, .ok, request_id, extra[0..if (include_version_id) 3 else 2]);
    }
    var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
    const extra = [_]std.http.Header{
        .{ .name = "etag", .value = etag },
        .{ .name = "x-amz-version-id", .value = object.version_id.write(&version_buffer) },
    };
    return respondEmpty(request, .ok, request_id, extra[0..if (include_version_id) 2 else 1]);
}

fn servePostPolicyUpload(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    _ = headers;
    if (request.head.transfer_encoding != .none) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const content_type = request.head.content_type orelse {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    var read_buffer: [16 * 1024]u8 = undefined;
    const stable_resource = request.head.target;
    const body_reader = request.readerExpectContinue(&read_buffer) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    request.head.target = stable_resource;
    var form = s3_post_policy.Parser.init(
        application.allocator,
        body_reader,
        request.head.content_length,
        content_type,
    ) catch |err| {
        return respondError(request, application.allocator, mapPostPolicyParserError(err), request_id);
    };
    defer form.deinit();
    const file = form.parseUntilFile() catch |err| {
        return respondError(request, application.allocator, mapPostPolicyParserError(err), request_id);
    };

    const policy_value = postField(&form, "policy") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const credential_value = postField(&form, "x-amz-credential") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const amz_date = postField(&form, "x-amz-date") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const algorithm_value = postField(&form, "x-amz-algorithm") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    if (!std.mem.eql(u8, algorithm_value, sigv4.algorithm)) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const signature_value = postField(&form, "x-amz-signature") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const access_key = sigv4.postPolicyAccessKey(credential_value) catch {
        return respondError(request, application.allocator, .authorization_header_malformed, request_id);
    };
    const credentials = application.credentialService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    var auth_material = credentials.resolveForAuth(access_key) catch |err| {
        return respondError(request, application.allocator, mapCredentialError(err), request_id);
    };
    defer auth_material.deinit(application.allocator);
    const supplied_token = postField(&form, "x-amz-security-token") catch {
        return respondError(request, application.allocator, .invalid_token, request_id);
    };
    sigv4.validateSessionToken(auth_material.session_token, supplied_token) catch {
        return respondError(request, application.allocator, .invalid_token, request_id);
    };
    sigv4.verifyPostPolicySignature(
        application.allocator,
        policy_value,
        credential_value,
        amz_date,
        signature_value,
        auth_material.secret_key,
        application.config.s3_region,
    ) catch |err| {
        return respondError(request, application.allocator, mapPostPolicySignatureError(err), request_id);
    };
    const signed_at = sigv4.parseAmzDate(amz_date) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const now = std.Io.Clock.real.now(application.io orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    }).toSeconds();
    const difference: i128 = @as(i128, signed_at) - now;
    const absolute_difference = if (difference < 0) -difference else difference;
    if (absolute_difference > application.config.s3_request_time_skew_seconds) {
        return respondError(request, application.allocator, .request_time_too_skewed, request_id);
    }

    const key_value = postField(&form, "key") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const expanded_key = expandPostPolicyKey(application.allocator, key_value, file.filename) catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    defer application.allocator.free(expanded_key);
    var policy_constraints = validatePostPolicy(
        application.allocator,
        policy_value,
        &form,
        parsed.bucket.?,
        expanded_key,
        file.content_type,
        now,
    ) catch |err| {
        return respondError(request, application.allocator, mapPostPolicyError(err), request_id);
    };
    if (policy_constraints.content_type == null) {
        policy_constraints.content_type = file.content_type;
    }
    var metadata = collectPostMetadata(application.allocator, &form) catch |err| {
        return respondError(request, application.allocator, if (err == error.OutOfMemory) .internal_error else .invalid_request, request_id);
    };
    defer metadata.deinit(application.allocator);
    var bounded = SizeBoundSource{
        .inner = form.fileSource(),
        .minimum = policy_constraints.minimum_size,
        .maximum = policy_constraints.maximum_size,
    };
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const object = objects.put(parsed.bucket.?, expanded_key, bounded.interface(), .{
        .content_type = policy_constraints.content_type.?,
        .user_metadata = metadata.views,
        .expected_md5 = policy_constraints.expected_md5,
        .expected_crc64nvme = policy_constraints.expected_crc64nvme,
    }) catch |err| {
        const kind: protocol.ErrorKind = if (err == error.InputReadFailed) switch (bounded.failure) {
            .too_small => .entity_too_small,
            .too_large => .entity_too_large,
            .none => if (form.failure == .field_too_large) .invalid_request else .invalid_request,
        } else if (err == error.ChecksumMismatch) .bad_digest else mapObjectError(err);
        return respondError(request, application.allocator, kind, request_id);
    };
    defer object.deinit(application.allocator);
    form.finish() catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    return respondPostPolicySuccess(request, application.allocator, parsed.bucket.?, expanded_key, object, policy_constraints.success_status, request_id);
}

const PostPolicyError = error{
    InvalidPolicy,
    UnsupportedCondition,
    UnsupportedField,
    UnsupportedChecksum,
    OutOfMemory,
};

const PostPolicyConstraints = struct {
    minimum_size: u64 = 0,
    maximum_size: u64 = std.math.maxInt(u64),
    content_type: ?[]const u8 = null,
    expected_md5: ?[16]u8 = null,
    expected_crc64nvme: ?u64 = null,
    success_status: std.http.Status = .no_content,
};

const PostMetadata = struct {
    allocator: std.mem.Allocator,
    views: []object_domain.UserMetadata,

    fn deinit(self: *PostMetadata, allocator: std.mem.Allocator) void {
        _ = self.allocator;
        allocator.free(self.views);
        self.* = undefined;
    }
};

fn postField(form: *const s3_post_policy.Parser, name: []const u8) s3_post_policy.Error!?[]const u8 {
    return form.lookup(name);
}

fn expandPostPolicyKey(
    allocator: std.mem.Allocator,
    key: []const u8,
    filename: []const u8,
) ![]u8 {
    const token = "${filename}";
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, key, offset, token)) |position| {
        output.appendSlice(allocator, key[offset..position]) catch return error.OutOfMemory;
        output.appendSlice(allocator, filename) catch return error.OutOfMemory;
        offset = position + token.len;
    }
    output.appendSlice(allocator, key[offset..]) catch return error.OutOfMemory;
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn validatePostPolicy(
    allocator: std.mem.Allocator,
    encoded_policy: []const u8,
    form: *const s3_post_policy.Parser,
    bucket: []const u8,
    key: []const u8,
    file_content_type: []const u8,
    now: i64,
) PostPolicyError!PostPolicyConstraints {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded_policy) catch {
        return error.InvalidPolicy;
    };
    if (decoded_size == 0 or decoded_size > 64 * 1024) return error.InvalidPolicy;
    const decoded = allocator.alloc(u8, decoded_size) catch return error.OutOfMemory;
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded_policy) catch return error.InvalidPolicy;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        decoded,
        .{ .parse_numbers = true },
    ) catch return error.InvalidPolicy;
    defer parsed.deinit();
    const document = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidPolicy,
    };
    const expiration_value = document.get("expiration") orelse return error.InvalidPolicy;
    const expiration = switch (expiration_value) {
        .string => |value| time.parseIso8601(value) catch return error.InvalidPolicy,
        else => return error.InvalidPolicy,
    };
    if (now >= expiration) return error.InvalidPolicy;
    const conditions_value = document.get("conditions") orelse return error.InvalidPolicy;
    const conditions = switch (conditions_value) {
        .array => |value| value.items,
        else => return error.InvalidPolicy,
    };

    var result: PostPolicyConstraints = .{};
    var has_length_range = false;
    for (conditions) |condition| {
        switch (condition) {
            .object => |object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const condition_name = entry.key_ptr.*;
                    const expected = switch (entry.value_ptr.*) {
                        .string => |value| value,
                        else => return error.InvalidPolicy,
                    };
                    const actual = postPolicyValue(form, condition_name, bucket, key, file_content_type) catch {
                        return error.InvalidPolicy;
                    };
                    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPolicy;
                }
            },
            .array => |array| {
                if (array.items.len == 0) return error.InvalidPolicy;
                const operator = switch (array.items[0]) {
                    .string => |value| value,
                    else => return error.InvalidPolicy,
                };
                if (std.mem.eql(u8, operator, "content-length-range")) {
                    if (array.items.len != 3 or has_length_range) return error.InvalidPolicy;
                    result.minimum_size = postPolicyNumber(array.items[1]) orelse return error.InvalidPolicy;
                    result.maximum_size = postPolicyNumber(array.items[2]) orelse return error.InvalidPolicy;
                    if (result.minimum_size > result.maximum_size) return error.InvalidPolicy;
                    has_length_range = true;
                    continue;
                }
                if (!std.mem.eql(u8, operator, "eq") and
                    !std.mem.eql(u8, operator, "starts-with")) return error.UnsupportedCondition;
                if (array.items.len != 3) return error.InvalidPolicy;
                const variable = switch (array.items[1]) {
                    .string => |value| value,
                    else => return error.InvalidPolicy,
                };
                if (variable.len < 2 or variable[0] != '$') return error.InvalidPolicy;
                const expected = switch (array.items[2]) {
                    .string => |value| value,
                    else => return error.InvalidPolicy,
                };
                const actual = postPolicyValue(form, variable[1..], bucket, key, file_content_type) catch {
                    return error.InvalidPolicy;
                };
                if (std.mem.eql(u8, operator, "eq")) {
                    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPolicy;
                } else if (std.mem.eql(u8, variable[1..], "Content-Type")) {
                    var values = std.mem.splitScalar(u8, actual, ',');
                    while (values.next()) |value| {
                        if (!std.mem.startsWith(u8, std.mem.trim(u8, value, " \t"), expected)) return error.InvalidPolicy;
                    }
                } else if (!std.mem.startsWith(u8, actual, expected)) {
                    return error.InvalidPolicy;
                }
            },
            else => return error.InvalidPolicy,
        }
    }
    for (form.fieldsView()) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, "file") or
            std.ascii.eqlIgnoreCase(field.name, "policy") or
            std.ascii.eqlIgnoreCase(field.name, "x-amz-signature") or
            std.ascii.startsWithIgnoreCase(field.name, "x-ignore")) continue;
        if (!postPolicySupportsField(field.name)) return error.UnsupportedField;
        if (!postPolicyConditionMentions(conditions, field.name)) return error.InvalidPolicy;
    }
    result.expected_md5 = try parsePostMd5(form);
    result.expected_crc64nvme = try parsePostCrc64(form);
    if (postField(form, "x-amz-sdk-checksum-algorithm") catch return error.InvalidPolicy) |algorithm| {
        if (!std.ascii.eqlIgnoreCase(algorithm, "CRC64NVME")) return error.UnsupportedChecksum;
        if (result.expected_crc64nvme == null) return error.InvalidPolicy;
    }
    const redirect = postField(form, "success_action_redirect") catch return error.InvalidPolicy;
    if (redirect != null) {
        return error.UnsupportedField;
    }
    if (postField(form, "success_action_status") catch return error.InvalidPolicy) |status| {
        if (std.mem.eql(u8, status, "200")) result.success_status = .ok else if (std.mem.eql(u8, status, "201")) result.success_status = .created else if (std.mem.eql(u8, status, "204")) result.success_status = .no_content else return error.InvalidPolicy;
    }
    result.content_type = postField(form, "Content-Type") catch return error.InvalidPolicy;
    return result;
}

fn postPolicyValue(
    form: *const s3_post_policy.Parser,
    name: []const u8,
    bucket: []const u8,
    key: []const u8,
    file_content_type: []const u8,
) s3_post_policy.Error![]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "bucket")) return bucket;
    if (std.ascii.eqlIgnoreCase(name, "key")) return key;
    if (std.ascii.eqlIgnoreCase(name, "content-type")) return (try form.lookup("Content-Type")) orelse file_content_type;
    return (try form.lookup(name)) orelse "";
}

fn postPolicyNumber(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn postPolicyConditionMentions(conditions: []const std.json.Value, field_name: []const u8) bool {
    for (conditions) |condition| switch (condition) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, field_name)) return true;
        },
        .array => |array| if (array.items.len >= 2) switch (array.items[0]) {
            .string => |operator| if (std.mem.eql(u8, operator, "eq") or std.mem.eql(u8, operator, "starts-with")) switch (array.items[1]) {
                .string => |variable| if (variable.len > 1 and variable[0] == '$' and std.ascii.eqlIgnoreCase(variable[1..], field_name)) return true,
                else => {},
            },
            else => {},
        },
        else => {},
    };
    return false;
}

fn postPolicySupportsField(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "key") or
        std.ascii.eqlIgnoreCase(name, "policy") or
        std.ascii.eqlIgnoreCase(name, "x-amz-algorithm") or
        std.ascii.eqlIgnoreCase(name, "x-amz-credential") or
        std.ascii.eqlIgnoreCase(name, "x-amz-date") or
        std.ascii.eqlIgnoreCase(name, "x-amz-signature") or
        std.ascii.eqlIgnoreCase(name, "x-amz-security-token") or
        std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-md5") or
        std.ascii.eqlIgnoreCase(name, "x-amz-checksum-crc64nvme") or
        std.ascii.eqlIgnoreCase(name, "x-amz-sdk-checksum-algorithm") or
        std.ascii.eqlIgnoreCase(name, "success_action_status") or
        std.ascii.startsWithIgnoreCase(name, "x-amz-meta-");
}

fn parsePostMd5(form: *const s3_post_policy.Parser) PostPolicyError!?[16]u8 {
    const maybe_value = form.lookup("Content-MD5") catch return error.InvalidPolicy;
    const value = maybe_value orelse return null;
    const size = std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidPolicy;
    if (size != 16) return error.InvalidPolicy;
    var digest: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&digest, value) catch return error.InvalidPolicy;
    return digest;
}

fn parsePostCrc64(form: *const s3_post_policy.Parser) PostPolicyError!?u64 {
    const maybe_value = form.lookup("x-amz-checksum-crc64nvme") catch return error.InvalidPolicy;
    const value = maybe_value orelse return null;
    const size = std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidPolicy;
    if (size != 8) return error.InvalidPolicy;
    var digest: [8]u8 = undefined;
    std.base64.standard.Decoder.decode(&digest, value) catch return error.InvalidPolicy;
    return std.mem.readInt(u64, &digest, .big);
}

fn collectPostMetadata(allocator: std.mem.Allocator, form: *const s3_post_policy.Parser) !PostMetadata {
    var views = std.ArrayList(object_domain.UserMetadata).empty;
    errdefer views.deinit(allocator);
    for (form.fieldsView()) |field| {
        const prefix = "x-amz-meta-";
        if (field.name.len <= prefix.len or !std.ascii.startsWithIgnoreCase(field.name, prefix)) continue;
        views.append(allocator, .{ .name = field.name[prefix.len..], .value = field.value }) catch return error.OutOfMemory;
    }
    const slice = views.toOwnedSlice(allocator) catch return error.OutOfMemory;
    object_domain.validateUserMetadata(slice) catch {
        allocator.free(slice);
        return error.InvalidMetadata;
    };
    return .{ .allocator = allocator, .views = slice };
}

fn respondPostPolicySuccess(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    bucket: []const u8,
    key: []const u8,
    object: object_domain.Object,
    status: std.http.Status,
    request_id: []const u8,
) !std.http.Status {
    var etag: [34]u8 = undefined;
    const etag_value = formatEtag(object.etag_md5, &etag);
    if (status == .created) {
        var xml: std.Io.Writer.Allocating = .init(allocator);
        defer xml.deinit();
        const writer = &xml.writer;
        writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<PostResponse><Location>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, request.head.target) catch return error.WriteFailed;
        writer.writeAll("</Location><Bucket>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, bucket) catch return error.WriteFailed;
        writer.writeAll("</Bucket><Key>") catch return error.WriteFailed;
        protocol.writeXmlEscaped(writer, key) catch return error.WriteFailed;
        writer.print("</Key><ETag>{s}</ETag></PostResponse>\n", .{etag_value}) catch return error.WriteFailed;
        return respondXml(request, xml.written(), .created, request_id, &.{});
    }
    const extra = [_]std.http.Header{.{ .name = "etag", .value = etag_value }};
    return respondEmpty(request, status, request_id, &extra);
}

fn serveCopyObject(
    request: *std.http.Server.Request,
    application: *Application,
    target_bucket_name: []const u8,
    target_key: []const u8,
    owner: []const u8,
    headers: []const sigv4.Header,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequestWithHash(request, payload_hash) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const target_bucket = ensureBucketOwner(application, target_bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    const target_has_version_id = target_bucket.versioning != .unversioned;
    target_bucket.deinit(application.allocator);

    var source = (parseCopySource(application.allocator, headers) catch |err| switch (err) {
        error.OutOfMemory => return respondError(request, application.allocator, .internal_error, request_id),
        error.InvalidCopySource => return respondError(request, application.allocator, .invalid_argument, request_id),
    }) orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    defer source.deinit();
    const source_bucket = ensureBucketOwner(application, source.bucket, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    const source_has_version_id = source.version_id != null or source_bucket.versioning != .unversioned;
    source_bucket.deinit(application.allocator);

    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    var source_lease = (if (source.version_id) |version_id|
        objects.openVersion(source.bucket, source.key, version_id)
    else
        objects.open(source.bucket, source.key)) catch |err| {
        const kind: protocol.ErrorKind = if (source.version_id != null and err == error.ObjectNotFound)
            .no_such_version
        else if (source.version_id != null and err == error.DeleteMarker)
            .invalid_request
        else
            mapObjectError(err);
        return respondError(request, application.allocator, kind, request_id);
    };
    var source_object = source_lease.takeMetadata();
    source_lease.deinit();
    defer source_object.deinit(application.allocator);

    const source_conditions = parseCopySourceConditions(headers) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const source_outcome = evaluateConditional(source_conditions, &source_object, .GET) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (source_outcome != .proceed) {
        return respondError(request, application.allocator, .precondition_failed, request_id);
    }

    const destination_conditions = parseConditionalHeaders(headers) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    var observed_target: ?object_domain.Object = null;
    defer if (observed_target) |value| value.deinit(application.allocator);
    if (!destination_conditions.isEmpty()) {
        observed_target = objects.head(target_bucket_name, target_key) catch |err| switch (err) {
            error.ObjectNotFound => null,
            else => return respondError(request, application.allocator, mapObjectError(err), request_id),
        };
        const observed_view: ?*const object_domain.Object = if (observed_target) |*value| value else null;
        const outcome = evaluateConditional(destination_conditions, observed_view, .PUT) catch {
            return respondError(request, application.allocator, .invalid_argument, request_id);
        };
        if (outcome == .precondition_failed) {
            return respondError(request, application.allocator, .precondition_failed, request_id);
        }
    }
    const expected_current: ?object_service.ExpectedCurrent = if (destination_conditions.isEmpty())
        null
    else if (observed_target != null)
        .{ .generation = observed_target.?.metadata_generation }
    else
        .missing;

    const directive = parseMetadataDirective(headers) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    var replacement_headers: ?PutHeaders = null;
    defer if (replacement_headers) |*value| value.deinit(application.allocator);
    if (directive == .replace) {
        replacement_headers = collectPutHeaders(application.allocator, request) catch |err| switch (err) {
            error.OutOfMemory => return respondError(request, application.allocator, .internal_error, request_id),
            error.InvalidMetadata => return respondError(request, application.allocator, .invalid_request, request_id),
        };
    }
    const content_type = if (replacement_headers) |value| value.content_type else source_object.content_type;
    const metadata = if (replacement_headers) |value| value.views else source_object.view().user_metadata;
    const object = objects.copy(
        source.bucket,
        source.key,
        source.version_id,
        target_bucket_name,
        target_key,
        .{
            .content_type = content_type,
            .user_metadata = metadata,
            .expected_current = expected_current,
            .expected_source_generation = if (source.version_id == null) source_object.metadata_generation else null,
        },
        directive == .copy,
    ) catch |err| {
        const kind: protocol.ErrorKind = if (source.version_id != null and err == error.ObjectNotFound)
            .no_such_version
        else if (source.version_id != null and err == error.DeleteMarker)
            .invalid_request
        else
            mapObjectError(err);
        return respondError(request, application.allocator, kind, request_id);
    };
    defer object.deinit(application.allocator);

    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CopyObjectResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LastModified>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    protocol.writeIsoTime(writer, object.last_modified_unix_seconds) catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    writer.writeAll("</LastModified><ETag>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    var etag_buffer: [40]u8 = undefined;
    protocol.writeXmlEscaped(writer, formatObjectEtag(&object, &etag_buffer)) catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    writer.writeAll("</ETag></CopyObjectResult>\n") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    var target_version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
    var source_version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
    var extra: [2]std.http.Header = undefined;
    var extra_count: usize = 0;
    if (target_has_version_id) {
        extra[extra_count] = .{ .name = "x-amz-version-id", .value = object.version_id.write(&target_version_buffer) };
        extra_count += 1;
    }
    if (source_has_version_id) {
        extra[extra_count] = .{ .name = "x-amz-copy-source-version-id", .value = source_object.version_id.write(&source_version_buffer) };
        extra_count += 1;
    }
    return respondXml(request, xml.written(), .ok, request_id, extra[0..extra_count]);
}

fn serveGetObject(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const bucket_name = parsed.bucket.?;
    const key = parsed.key.?;
    if (ensureEmptyRequestWithHash(request, payload_hash) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    const include_version_id = bucket.versioning != .unversioned;
    bucket.deinit(application.allocator);
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const version_id = parseRequestedVersion(parsed) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    var lease = (if (version_id) |version|
        objects.openVersion(bucket_name, key, version)
    else
        objects.open(bucket_name, key)) catch |err| {
        if (err == error.DeleteMarker or err == error.ObjectNotFound) {
            if (try respondObjectMarkerError(request, application, objects, bucket_name, key, version_id, request_id)) |status| return status;
        }
        return respondError(request, application.allocator, if (version_id != null and err == error.ObjectNotFound) .no_such_version else mapObjectError(err), request_id);
    };
    defer lease.deinit();
    const object = lease.metadata();
    const conditions = parseConditionalHeaders(headers) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const outcome = evaluateConditional(conditions, object, .GET) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (outcome == .not_modified) return respondNotModified(request, application.allocator, object, request_id);
    if (outcome == .precondition_failed) {
        return respondError(request, application.allocator, .precondition_failed, request_id);
    }
    const range_value = singleHeader(headers, "range") catch {
        return respondInvalidRange(request, application.allocator, object.size, request_id);
    };
    const range = if (range_value) |value|
        parseRange(value, object.size) catch {
            return respondInvalidRange(request, application.allocator, object.size, request_id);
        }
    else
        null;
    var response_headers = try ObjectResponseHeaders.init(
        application.allocator,
        object,
        false,
        range,
        include_version_id,
    );
    defer response_headers.deinit(application.allocator);
    const header_values = response_headers.populate(object, request_id);
    var response_buffer: [16 * 1024]u8 = undefined;
    var body_writer = try request.respondStreaming(&response_buffer, .{
        .content_length = if (range) |value| value.length else object.size,
        .respond_options = .{
            .status = if (range != null) .partial_content else .ok,
            .extra_headers = header_values,
        },
    });
    var sink: HttpSink = .{ .writer = &body_writer.writer };
    if (range) |value| {
        try lease.streamRange(value.start, value.length, sink.interface());
    } else {
        try lease.stream(sink.interface());
    }
    try body_writer.end();
    return if (range != null) .partial_content else .ok;
}

fn serveHeadObject(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    const bucket_name = parsed.bucket.?;
    const key = parsed.key.?;
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    const include_version_id = bucket.versioning != .unversioned;
    bucket.deinit(application.allocator);
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const version_id = parseRequestedVersion(parsed) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    var lease = (if (version_id) |version|
        objects.openVersion(bucket_name, key, version)
    else
        objects.open(bucket_name, key)) catch |err| {
        if (err == error.DeleteMarker or err == error.ObjectNotFound) {
            if (try respondObjectMarkerError(request, application, objects, bucket_name, key, version_id, request_id)) |status| return status;
        }
        return respondError(request, application.allocator, if (version_id != null and err == error.ObjectNotFound) .no_such_version else mapObjectError(err), request_id);
    };
    defer lease.deinit();
    const object = lease.metadata();
    const conditions = parseConditionalHeaders(headers) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const outcome = evaluateConditional(conditions, object, .HEAD) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (outcome == .not_modified) return respondNotModified(request, application.allocator, object, request_id);
    if (outcome == .precondition_failed) {
        return respondError(request, application.allocator, .precondition_failed, request_id);
    }
    var response_headers = try ObjectResponseHeaders.init(application.allocator, object, true, null, include_version_id);
    defer response_headers.deinit(application.allocator);
    const header_values = response_headers.populate(object, request_id);
    try request.respond("", .{
        .status = .ok,
        .transfer_encoding = .none,
        .extra_headers = header_values,
    });
    return .ok;
}

fn serveDeleteObject(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const bucket_name = parsed.bucket.?;
    const key = parsed.key.?;
    if (ensureEmptyRequestWithHash(request, payload_hash) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const requested_version = parseRequestedVersion(parsed) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const result = (if (requested_version) |version|
        objects.deleteVersion(bucket_name, key, version)
    else
        objects.delete(bucket_name, key)) catch |err| {
        return respondError(request, application.allocator, mapObjectError(err), request_id);
    };
    var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
    var extra: [2]std.http.Header = undefined;
    var count: usize = 0;
    if (result.version_id) |version| {
        extra[count] = .{ .name = "x-amz-version-id", .value = version.write(&version_buffer) };
        count += 1;
    }
    if (result.delete_marker) {
        extra[count] = .{ .name = "x-amz-delete-marker", .value = "true" };
        count += 1;
    }
    return respondEmpty(request, .no_content, request_id, extra[0..count]);
}

fn serveCreateMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    const uploads = parsed.query("uploads") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    if (uploads.len != 0 or ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    var put_headers = collectPutHeaders(application.allocator, request) catch |err| switch (err) {
        error.OutOfMemory => return respondError(request, application.allocator, .internal_error, request_id),
        error.InvalidMetadata => return respondError(request, application.allocator, .invalid_request, request_id),
    };
    defer put_headers.deinit(application.allocator);
    const multiparts = application.multipartService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const upload = multiparts.create(parsed.bucket.?, parsed.key.?, .{
        .content_type = put_headers.content_type,
        .user_metadata = put_headers.views,
    }) catch |err| {
        return respondError(request, application.allocator, mapMultipartError(err), request_id);
    };
    defer upload.deinit(application.allocator);
    var upload_id_buffer: [32]u8 = undefined;
    const upload_id = multipart_domain.formatUploadId(upload.id, &upload_id_buffer);
    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    protocol.writeXmlEscaped(writer, parsed.bucket.?) catch return error.WriteFailed;
    writer.writeAll("</Bucket><Key>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, parsed.key.?) catch return error.WriteFailed;
    writer.writeAll("</Key><UploadId>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, upload_id) catch return error.WriteFailed;
    writer.writeAll("</UploadId></InitiateMultipartUploadResult>\n") catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn serveUploadPart(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    authorization: ?sigv4.Authorization,
    secret_key: []const u8,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const upload_id = parsed.query("uploadId") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const part_number_text = parsed.query("partNumber") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const part_number = std.fmt.parseInt(u16, part_number_text, 10) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    if (part_number == 0 or part_number > multipart_domain.max_parts) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const expected_md5 = parseContentMd5(headers) catch {
        return respondError(request, application.allocator, .invalid_digest, request_id);
    };
    const checksum_request = parseChecksumRequest(headers) catch |err| switch (err) {
        error.InvalidDigest => return respondError(request, application.allocator, .invalid_digest, request_id),
        error.UnsupportedChecksum => return respondError(request, application.allocator, .not_implemented, request_id),
        error.InvalidRequest => return respondError(request, application.allocator, .invalid_request, request_id),
    };
    const expected_crc64nvme = checksum_request.header_crc64nvme;
    const expected_checksum = checksum_request.header;
    const expected_sha256: ?[32]u8 = switch (payload_hash) {
        .digest => |digest| digest,
        .unsigned, .streaming => null,
    };
    var read_buffer: [16 * 1024]u8 = undefined;
    const stable_resource = request.head.target;
    const body_reader = request.readerExpectContinue(&read_buffer) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    request.head.target = stable_resource;
    var http_source: HttpSource = .{
        .reader = body_reader,
        .remaining = request.head.content_length,
    };
    var streaming_source: aws_chunked.Source = undefined;
    var streaming_source_active = false;
    defer if (streaming_source_active) streaming_source.deinit();
    const source = switch (payload_hash) {
        .digest, .unsigned => http_source.interface(),
        .streaming => streamed: {
            const decoded_length = parseStreamingDecodedLength(headers) catch {
                return respondError(request, application.allocator, .invalid_request, request_id);
            };
            const verifier = sigv4.StreamingVerifier.init(
                application.allocator,
                headers,
                authorization orelse return respondError(request, application.allocator, .invalid_request, request_id),
                secret_key,
            ) catch |err| {
                return respondError(request, application.allocator, mapSignatureVerifyError(err), request_id);
            };
            streaming_source = aws_chunked.Source.init(
                body_reader,
                verifier,
                decoded_length,
                checksum_request.trailer,
            );
            streaming_source_active = true;
            break :streamed streaming_source.interface();
        },
    };
    const multiparts = application.multipartService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const part = multiparts.uploadPart(
        parsed.bucket.?,
        parsed.key.?,
        upload_id,
        part_number,
        source,
        .{
            .expected_md5 = expected_md5,
            .expected_sha256 = expected_sha256,
            .expected_crc64nvme = expected_crc64nvme,
            .expected_checksum = expected_checksum,
        },
    ) catch |err| {
        const kind: protocol.ErrorKind = if (err == error.InputReadFailed and streaming_source_active)
            mapStreamingFailure(streaming_source.failure)
        else if (err == error.ChecksumMismatch)
            if (expected_md5 != null or expected_checksum != null) .bad_digest else .x_amz_content_sha256_mismatch
        else
            mapMultipartError(err);
        return respondError(request, application.allocator, kind, request_id);
    };
    var etag_buffer: [34]u8 = undefined;
    const etag = formatEtag(part.etag_md5, &etag_buffer);
    const response_checksum = expected_checksum orelse if (streaming_source_active)
        streaming_source.verified_checksum
    else
        null;
    if (response_checksum) |value| {
        var encoded_buffer: [64]u8 = undefined;
        const encoded = checksum.encodeValue(value, &encoded_buffer);
        const extra = [_]std.http.Header{
            .{ .name = "etag", .value = etag },
            .{ .name = value.algorithm().headerName(), .value = encoded },
        };
        return respondEmpty(request, .ok, request_id, &extra);
    }
    const extra = [_]std.http.Header{.{ .name = "etag", .value = etag }};
    return respondEmpty(request, .ok, request_id, &extra);
}

fn serveListParts(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const upload_id = parsed.query("uploadId") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const marker_text = parsed.query("part-number-marker") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const max_parts_text = parsed.query("max-parts") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    };
    const marker = if (marker_text) |value| std.fmt.parseInt(u16, value, 10) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } else 0;
    const max_parts = if (max_parts_text) |value| std.fmt.parseInt(usize, value, 10) catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } else 1000;
    if (marker > multipart_domain.max_parts or max_parts > 1000) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const multiparts = application.multipartService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const upload = multiparts.listParts(parsed.bucket.?, parsed.key.?, upload_id) catch |err| {
        return respondError(request, application.allocator, mapMultipartError(err), request_id);
    };
    defer upload.deinit(application.allocator);
    var start: usize = 0;
    while (start < upload.parts.len and upload.parts[start].number <= marker) start += 1;
    const end = @min(upload.parts.len, start + max_parts);
    const truncated = end < upload.parts.len;
    const next_marker: u16 = if (end > start) upload.parts[end - 1].number else marker;
    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListPartsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    protocol.writeXmlEscaped(writer, parsed.bucket.?) catch return error.WriteFailed;
    writer.writeAll("</Bucket><Key>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, parsed.key.?) catch return error.WriteFailed;
    writer.writeAll("</Key><UploadId>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, upload_id) catch return error.WriteFailed;
    writer.writeAll("</UploadId><Initiator><ID>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
    writer.writeAll("</ID><DisplayName>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
    writer.writeAll("</DisplayName></Initiator><Owner><ID>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
    writer.writeAll("</ID><DisplayName>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, owner) catch return error.WriteFailed;
    writer.print(
        "</DisplayName></Owner><StorageClass>STANDARD</StorageClass><PartNumberMarker>{d}</PartNumberMarker><NextPartNumberMarker>{d}</NextPartNumberMarker><MaxParts>{d}</MaxParts><IsTruncated>{s}</IsTruncated>",
        .{ marker, next_marker, max_parts, if (truncated) "true" else "false" },
    ) catch return error.WriteFailed;
    for (upload.parts[start..end]) |part| {
        var etag: [34]u8 = undefined;
        writer.print("<Part><PartNumber>{d}</PartNumber><LastModified>", .{part.number}) catch return error.WriteFailed;
        protocol.writeIsoTime(writer, part.last_modified_unix_seconds) catch return error.WriteFailed;
        writer.print("</LastModified><ETag>{s}</ETag><Size>{d}</Size></Part>", .{
            formatEtag(part.etag_md5, &etag),
            part.size,
        }) catch return error.WriteFailed;
    }
    writer.writeAll("</ListPartsResult>\n") catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn serveCompleteMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
    const upload_id = parsed.query("uploadId") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    if (payload_hash == .streaming or (request.head.content_length orelse 0) > s3_multipart.max_payload_size) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    var read_buffer: [16 * 1024]u8 = undefined;
    const stable_resource = request.head.target;
    const body_reader = request.readerExpectContinue(&read_buffer) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    request.head.target = stable_resource;
    const body = body_reader.allocRemaining(application.allocator, .limited(s3_multipart.max_payload_size)) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    defer application.allocator.free(body);
    if (!verifyPayloadHash(body, payload_hash)) {
        return respondError(request, application.allocator, .x_amz_content_sha256_mismatch, request_id);
    }
    if (validateBodyChecksums(headers, body)) |checksum_error| {
        return respondError(request, application.allocator, checksum_error, request_id);
    }
    const completion = s3_multipart.parse(application.allocator, body) catch |err| switch (err) {
        error.OutOfMemory => return respondError(request, application.allocator, .internal_error, request_id),
        error.MalformedXml, error.TooManyParts => return respondError(request, application.allocator, .malformed_xml, request_id),
    };
    defer completion.deinit(application.allocator);
    const multiparts = application.multipartService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const object = multiparts.complete(parsed.bucket.?, parsed.key.?, upload_id, completion.parts) catch |err| {
        return respondError(request, application.allocator, mapMultipartError(err), request_id);
    };
    defer object.deinit(application.allocator);
    var etag_buffer: [40]u8 = undefined;
    const etag = formatObjectEtag(&object, &etag_buffer);
    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Location>") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    protocol.writeXmlEscaped(writer, request.head.target) catch return error.WriteFailed;
    writer.writeAll("</Location><Bucket>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, parsed.bucket.?) catch return error.WriteFailed;
    writer.writeAll("</Bucket><Key>") catch return error.WriteFailed;
    protocol.writeXmlEscaped(writer, parsed.key.?) catch return error.WriteFailed;
    writer.print("</Key><ETag>{s}</ETag></CompleteMultipartUploadResult>\n", .{etag}) catch return error.WriteFailed;
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn serveAbortMultipartUpload(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    if (ensureEmptyRequest(request, headers) != null) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    const upload_id = parsed.query("uploadId") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const multiparts = application.multipartService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    multiparts.abort(parsed.bucket.?, parsed.key.?, upload_id) catch |err| {
        return respondError(request, application.allocator, mapMultipartError(err), request_id);
    };
    return respondEmpty(request, .no_content, request_id, &.{});
}

fn serveDeleteObjects(
    request: *std.http.Server.Request,
    application: *Application,
    parsed: protocol.ParsedTarget,
    owner: []const u8,
    headers: []const sigv4.Header,
    request_id: []const u8,
) !std.http.Status {
    const delete_query = parsed.query("delete") catch {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    } orelse return respondError(request, application.allocator, .invalid_argument, request_id);
    if (delete_query.len != 0 or parsed.parameters.len != 1) {
        return respondError(request, application.allocator, .invalid_argument, request_id);
    }
    const bucket = ensureBucketOwner(application, parsed.bucket.?, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);

    const expected_md5 = parseContentMd5(headers) catch {
        return respondError(request, application.allocator, .invalid_digest, request_id);
    };
    const flexible_checksum = parseChecksumRequest(headers) catch |err| switch (err) {
        error.InvalidDigest => return respondError(request, application.allocator, .invalid_digest, request_id),
        error.UnsupportedChecksum => return respondError(request, application.allocator, .not_implemented, request_id),
        error.InvalidRequest => return respondError(request, application.allocator, .invalid_request, request_id),
    };
    if (expected_md5 == null and flexible_checksum.header == null) {
        return respondError(request, application.allocator, .invalid_digest, request_id);
    }
    const payload_hash = sigv4.requestPayloadHash(headers) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    if (payload_hash == .streaming) {
        return respondError(request, application.allocator, .not_implemented, request_id);
    }
    if ((request.head.content_length orelse 0) > delete_objects.max_payload_size) {
        return respondError(request, application.allocator, .invalid_request, request_id);
    }
    var read_buffer: [16 * 1024]u8 = undefined;
    const stable_resource = request.head.target;
    const body_reader = request.readerExpectContinue(&read_buffer) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    request.head.target = stable_resource;
    const body = body_reader.allocRemaining(
        application.allocator,
        .limited(delete_objects.max_payload_size),
    ) catch {
        return respondError(request, application.allocator, .invalid_request, request_id);
    };
    defer application.allocator.free(body);

    if (validateBodyChecksums(headers, body)) |checksum_error| {
        return respondError(request, application.allocator, checksum_error, request_id);
    }
    switch (payload_hash) {
        .unsigned => {},
        .digest => |expected| {
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body, &actual, .{});
            if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) {
                return respondError(
                    request,
                    application.allocator,
                    .x_amz_content_sha256_mismatch,
                    request_id,
                );
            }
        },
        .streaming => unreachable,
    }

    const delete_request = delete_objects.parse(application.allocator, body) catch |err| switch (err) {
        error.OutOfMemory => return respondError(
            request,
            application.allocator,
            .internal_error,
            request_id,
        ),
        error.MalformedXml, error.TooManyObjects => return respondError(
            request,
            application.allocator,
            .malformed_xml,
            request_id,
        ),
    };
    defer delete_request.deinit(application.allocator);
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };

    var xml: std.Io.Writer.Allocating = .init(application.allocator);
    defer xml.deinit();
    const writer = &xml.writer;
    writer.writeAll(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
    ) catch return respondError(request, application.allocator, .internal_error, request_id);
    for (delete_request.keys) |key| {
        _ = objects.delete(parsed.bucket.?, key) catch |err| {
            const descriptor = protocol.describe(mapObjectError(err));
            writer.writeAll("<Error><Key>") catch {
                return respondError(request, application.allocator, .internal_error, request_id);
            };
            protocol.writeXmlEscaped(writer, key) catch return error.WriteFailed;
            writer.print("</Key><Code>{s}</Code><Message>{s}</Message></Error>", .{
                descriptor.code,
                descriptor.message,
            }) catch return respondError(
                request,
                application.allocator,
                .internal_error,
                request_id,
            );
            continue;
        };
        if (!delete_request.quiet) {
            writer.writeAll("<Deleted><Key>") catch {
                return respondError(request, application.allocator, .internal_error, request_id);
            };
            protocol.writeXmlEscaped(writer, key) catch return error.WriteFailed;
            writer.writeAll("</Key></Deleted>") catch {
                return respondError(request, application.allocator, .internal_error, request_id);
            };
        }
    }
    writer.writeAll("</DeleteResult>\n") catch {
        return respondError(request, application.allocator, .internal_error, request_id);
    };
    return respondXml(request, xml.written(), .ok, request_id, &.{});
}

fn ensureBucketOwner(
    application: *Application,
    bucket_name: []const u8,
    owner: []const u8,
) bucket_service.Error!@import("../domain/bucket.zig").Bucket {
    const buckets = application.bucketService() orelse return error.Unavailable;
    const bucket = try buckets.head(bucket_name);
    if (!std.mem.eql(u8, bucket.owner, owner)) {
        bucket.deinit(application.allocator);
        return error.InvalidOwner;
    }
    return bucket;
}

fn ensureEmptyRequest(
    request: *const std.http.Server.Request,
    headers: []const sigv4.Header,
) ?protocol.ErrorKind {
    const payload_hash = sigv4.requestPayloadHash(headers) catch return .invalid_request;
    return ensureEmptyRequestWithHash(request, payload_hash);
}

fn ensureEmptyRequestWithHash(
    request: *const std.http.Server.Request,
    payload_hash: sigv4.PayloadHash,
) ?protocol.ErrorKind {
    if ((request.head.content_length orelse 0) != 0 or
        request.head.transfer_encoding != .none)
    {
        return .invalid_request;
    }
    return switch (payload_hash) {
        .unsigned => null,
        .streaming => .not_implemented,
        .digest => |digest| checked: {
            var empty_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("", &empty_digest, .{});
            break :checked if (std.crypto.timing_safe.eql([32]u8, empty_digest, digest))
                null
            else
                .x_amz_content_sha256_mismatch;
        },
    };
}

fn verifyPayloadHash(body: []const u8, payload_hash: sigv4.PayloadHash) bool {
    return switch (payload_hash) {
        .unsigned => true,
        .streaming => false,
        .digest => |expected| verified: {
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body, &actual, .{});
            break :verified std.crypto.timing_safe.eql([32]u8, expected, actual);
        },
    };
}

fn validateBodyChecksums(headers: []const sigv4.Header, body: []const u8) ?protocol.ErrorKind {
    if (parseContentMd5(headers) catch return .invalid_digest) |expected| {
        var actual: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(body, &actual, .{});
        if (!std.crypto.timing_safe.eql([16]u8, expected, actual)) return .bad_digest;
    }
    const request = parseChecksumRequest(headers) catch |err| return switch (err) {
        error.InvalidDigest => .invalid_digest,
        error.UnsupportedChecksum => .not_implemented,
        error.InvalidRequest => .invalid_request,
    };
    const expected = request.header orelse return null;
    return if (bodyMatchesChecksum(body, expected)) null else .bad_digest;
}

fn bodyMatchesChecksum(body: []const u8, expected: checksum.Value) bool {
    return switch (expected) {
        .crc32 => |value| value == checksum.Crc32.hash(body),
        .crc32c => |value| value == checksum.Crc32C.hash(body),
        .crc64nvme => |value| value == checksum.Crc64Nvme.hash(body),
        .sha1 => |value| matches: {
            var actual: [20]u8 = undefined;
            checksum.Sha1.hash(body, &actual, .{});
            break :matches std.crypto.timing_safe.eql([20]u8, value, actual);
        },
        .sha256 => |value| matches: {
            var actual: [32]u8 = undefined;
            checksum.Sha256.hash(body, &actual, .{});
            break :matches std.crypto.timing_safe.eql([32]u8, value, actual);
        },
    };
}

const XmlPayloadError = error{
    OutOfMemory,
    InvalidRequest,
    PayloadTooLarge,
    ChecksumMismatch,
};

fn readXmlPayload(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    max_length: usize,
    payload_hash: sigv4.PayloadHash,
) XmlPayloadError![]u8 {
    switch (payload_hash) {
        .streaming => return error.InvalidRequest,
        else => {},
    }
    var read_buffer: [4096]u8 = undefined;
    const stable_resource = request.head.target;
    const reader = request.readerExpectContinue(&read_buffer) catch return error.InvalidRequest;
    request.head.target = stable_resource;
    const body = reader.allocRemaining(allocator, .limited(max_length)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.PayloadTooLarge,
        else => return error.InvalidRequest,
    };
    errdefer allocator.free(body);
    if (!verifyPayloadHash(body, payload_hash)) return error.ChecksumMismatch;
    return body;
}

fn mapXmlPayloadError(err: XmlPayloadError) protocol.ErrorKind {
    return switch (err) {
        error.OutOfMemory => .internal_error,
        error.InvalidRequest => .invalid_request,
        error.PayloadTooLarge => .entity_too_large,
        error.ChecksumMismatch => .x_amz_content_sha256_mismatch,
    };
}

fn xmlElementText(xml: []const u8, name: []const u8) ?[]const u8 {
    var open_buffer: [128]u8 = undefined;
    var close_buffer: [128]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buffer, "<{s}>", .{name}) catch return null;
    const close = std.fmt.bufPrint(&close_buffer, "</{s}>", .{name}) catch return null;
    const start_position = std.mem.indexOf(u8, xml, open) orelse return null;
    const value_start = start_position + open.len;
    const relative_end = std.mem.indexOf(u8, xml[value_start..], close) orelse return null;
    return std.mem.trim(u8, xml[value_start .. value_start + relative_end], " \t\r\n");
}

fn parseRequestedVersion(parsed: protocol.ParsedTarget) error{ InvalidVersionId, DuplicateQueryParameter }!?object_domain.VersionId {
    const value = try parsed.query("versionId");
    return if (value) |encoded| object_domain.parseVersionId(encoded) catch error.InvalidVersionId else null;
}

fn respondObjectMarkerError(
    request: *std.http.Server.Request,
    application: *Application,
    objects: object_service.ObjectService,
    bucket_name: []const u8,
    key: []const u8,
    version_id: ?object_domain.VersionId,
    request_id: []const u8,
) !?std.http.Status {
    const marker = objects.findDeleteMarker(bucket_name, key, version_id) catch return null;
    const value = marker orelse return null;
    defer value.deinit(application.allocator);
    var version_buffer: [object_domain.VersionId.encoded_length]u8 = undefined;
    var modified_buffer: [29]u8 = undefined;
    const modified = time.formatHttpDate(value.last_modified_unix_seconds, &modified_buffer) catch return null;
    const extra = [_]std.http.Header{
        .{ .name = "x-amz-delete-marker", .value = "true" },
        .{ .name = "x-amz-version-id", .value = value.version_id.write(&version_buffer) },
        .{ .name = "last-modified", .value = modified },
    };
    const status = try respondErrorWithHeaders(
        request,
        application.allocator,
        if (version_id == null) .no_such_key else .method_not_allowed,
        request_id,
        &extra,
    );
    return status;
}

fn validateCreateBucketPayload(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    headers: []const sigv4.Header,
    expected_region: []const u8,
) !?protocol.ErrorKind {
    const payload_hash = sigv4.requestPayloadHash(headers) catch return .invalid_request;
    if ((request.head.content_length orelse 0) == 0 and
        request.head.transfer_encoding == .none)
    {
        switch (payload_hash) {
            .unsigned => {},
            .streaming => return .not_implemented,
            .digest => |digest| {
                var empty_digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash("", &empty_digest, .{});
                if (!std.crypto.timing_safe.eql([32]u8, empty_digest, digest)) {
                    return .x_amz_content_sha256_mismatch;
                }
            },
        }
        return validateLocationConstraint("", expected_region);
    }
    var read_buffer: [4096]u8 = undefined;
    const stable_resource = request.head.target;
    const reader = request.readerExpectContinue(&read_buffer) catch return .invalid_request;
    request.head.target = stable_resource;
    const body = reader.allocRemaining(allocator, .limited(64 * 1024)) catch return .invalid_request;
    defer allocator.free(body);
    switch (payload_hash) {
        .unsigned => {},
        .streaming => return .not_implemented,
        .digest => |digest| {
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body, &actual, .{});
            if (!std.crypto.timing_safe.eql([32]u8, actual, digest)) {
                return .x_amz_content_sha256_mismatch;
            }
        },
    }
    return validateLocationConstraint(body, expected_region);
}

fn validateLocationConstraint(
    body: []const u8,
    expected_region: []const u8,
) ?protocol.ErrorKind {
    var remaining = std.mem.trim(u8, body, " \t\r\n");
    if (remaining.len == 0) {
        return if (std.mem.eql(u8, expected_region, "us-east-1")) null else .invalid_location_constraint;
    }
    if (std.mem.startsWith(u8, remaining, "<?xml")) {
        const declaration_end = std.mem.indexOf(u8, remaining, "?>") orelse return .malformed_xml;
        remaining = std.mem.trim(u8, remaining[declaration_end + 2 ..], " \t\r\n");
    }
    const root_start = "<CreateBucketConfiguration";
    if (!std.mem.startsWith(u8, remaining, root_start)) return .malformed_xml;
    const root_open_end = std.mem.indexOfScalarPos(u8, remaining, root_start.len, '>') orelse {
        return .malformed_xml;
    };
    remaining = std.mem.trim(u8, remaining[root_open_end + 1 ..], " \t\r\n");
    const location_start = "<LocationConstraint>";
    const location_end = "</LocationConstraint>";
    if (!std.mem.startsWith(u8, remaining, location_start)) return .malformed_xml;
    remaining = remaining[location_start.len..];
    const value_end = std.mem.indexOf(u8, remaining, location_end) orelse return .malformed_xml;
    const region = std.mem.trim(u8, remaining[0..value_end], " \t\r\n");
    remaining = std.mem.trim(u8, remaining[value_end + location_end.len ..], " \t\r\n");
    if (!std.mem.eql(u8, remaining, "</CreateBucketConfiguration>")) return .malformed_xml;
    if (std.mem.eql(u8, expected_region, "us-east-1") or
        !std.mem.eql(u8, region, expected_region))
    {
        return .invalid_location_constraint;
    }
    return null;
}

fn parseConditionalHeaders(headers: []const sigv4.Header) error{InvalidCondition}!ConditionalHeaders {
    return .{
        .if_match = singleHeader(headers, "if-match") catch return error.InvalidCondition,
        .if_none_match = singleHeader(headers, "if-none-match") catch return error.InvalidCondition,
        .if_modified_since = singleHeader(headers, "if-modified-since") catch return error.InvalidCondition,
        .if_unmodified_since = singleHeader(headers, "if-unmodified-since") catch return error.InvalidCondition,
    };
}

fn parseCopySourceConditions(headers: []const sigv4.Header) error{InvalidCondition}!ConditionalHeaders {
    return .{
        .if_match = singleHeader(headers, "x-amz-copy-source-if-match") catch return error.InvalidCondition,
        .if_none_match = singleHeader(headers, "x-amz-copy-source-if-none-match") catch return error.InvalidCondition,
        .if_modified_since = singleHeader(headers, "x-amz-copy-source-if-modified-since") catch return error.InvalidCondition,
        .if_unmodified_since = singleHeader(headers, "x-amz-copy-source-if-unmodified-since") catch return error.InvalidCondition,
    };
}

fn parseMetadataDirective(headers: []const sigv4.Header) error{InvalidDirective}!MetadataDirective {
    const value = singleHeader(headers, "x-amz-metadata-directive") catch return error.InvalidDirective;
    const directive = value orelse return .copy;
    if (std.ascii.eqlIgnoreCase(directive, "COPY")) return .copy;
    if (std.ascii.eqlIgnoreCase(directive, "REPLACE")) return .replace;
    return error.InvalidDirective;
}

fn parseCopySource(
    allocator: std.mem.Allocator,
    headers: []const sigv4.Header,
) error{ OutOfMemory, InvalidCopySource }!?CopySource {
    const raw = singleHeader(headers, "x-amz-copy-source") catch return error.InvalidCopySource;
    const value = raw orelse return null;
    if (value.len < 3 or std.mem.indexOfScalar(u8, value, '#') != null) return error.InvalidCopySource;
    const normalized = if (value[0] == '/')
        null
    else
        std.fmt.allocPrint(allocator, "/{s}", .{value}) catch return error.OutOfMemory;
    defer if (normalized) |owned| allocator.free(owned);
    var target = protocol.parseTarget(allocator, .PUT, normalized orelse value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTarget => return error.InvalidCopySource,
    };
    errdefer target.deinit();
    const bucket = target.bucket orelse return error.InvalidCopySource;
    const key = target.key orelse return error.InvalidCopySource;
    if (target.parameters.len > 1) return error.InvalidCopySource;
    if (target.parameters.len == 1 and !std.mem.eql(u8, target.parameters[0].name, "versionId")) {
        return error.InvalidCopySource;
    }
    const version_text = target.query("versionId") catch return error.InvalidCopySource;
    const version_id = if (version_text) |encoded|
        object_domain.parseVersionId(encoded) catch return error.InvalidCopySource
    else
        null;
    return .{
        .target = target,
        .bucket = bucket,
        .key = key,
        .version_id = version_id,
    };
}

fn evaluateConditional(
    conditions: ConditionalHeaders,
    object: ?*const object_domain.Object,
    method: std.http.Method,
) error{InvalidCondition}!ConditionalOutcome {
    var etag_buffer: [40]u8 = undefined;
    const current_etag = if (object) |value| formatObjectEtag(value, &etag_buffer) else null;
    const has_if_match = conditions.if_match != null;
    if (conditions.if_match) |value| {
        if (!try etagListMatches(value, current_etag, false)) return .precondition_failed;
    }
    const has_if_none_match = conditions.if_none_match != null;
    if (conditions.if_none_match) |value| {
        if (try etagListMatches(value, current_etag, true)) {
            return if (method == .GET or method == .HEAD) .not_modified else .precondition_failed;
        }
    }
    if (!has_if_match) {
        if (conditions.if_unmodified_since) |value| {
            const timestamp = time.parseHttpDate(value) catch return error.InvalidCondition;
            if (object) |current| {
                if (current.last_modified_unix_seconds > timestamp) return .precondition_failed;
            }
        }
    }
    if (!has_if_none_match and (method == .GET or method == .HEAD) and conditions.if_modified_since != null) {
        const timestamp = time.parseHttpDate(conditions.if_modified_since.?) catch return error.InvalidCondition;
        if (object) |current| {
            if (current.last_modified_unix_seconds <= timestamp) return .not_modified;
        }
    }
    return .proceed;
}

fn etagListMatches(
    value: []const u8,
    current: ?[]const u8,
    allow_weak: bool,
) error{InvalidCondition}!bool {
    var iterator = std.mem.splitScalar(u8, value, ',');
    var saw_value = false;
    var wildcard = false;
    var matched = false;
    while (iterator.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len == 0) return error.InvalidCondition;
        if (std.mem.eql(u8, token, "*")) {
            if (saw_value) return error.InvalidCondition;
            wildcard = true;
            saw_value = true;
            continue;
        }
        if (wildcard) return error.InvalidCondition;
        const weak = std.mem.startsWith(u8, token, "W/");
        const etag_value = if (weak) token[2..] else token;
        if (etag_value.len < 2 or etag_value[0] != '"' or etag_value[etag_value.len - 1] != '"') {
            return error.InvalidCondition;
        }
        if ((!weak or allow_weak) and current != null and std.mem.eql(u8, etag_value, current.?)) {
            matched = true;
        }
        saw_value = true;
    }
    if (!saw_value) return error.InvalidCondition;
    return matched or (wildcard and current != null);
}

fn respondNotModified(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    object: *const object_domain.Object,
    request_id: []const u8,
) !std.http.Status {
    var etag_buffer: [40]u8 = undefined;
    var last_modified_buffer: [29]u8 = undefined;
    const etag = formatObjectEtag(object, &etag_buffer);
    const last_modified = time.formatHttpDate(object.last_modified_unix_seconds, &last_modified_buffer) catch {
        return respondError(request, allocator, .internal_error, request_id);
    };
    const extra = [_]std.http.Header{
        .{ .name = "etag", .value = etag },
        .{ .name = "last-modified", .value = last_modified },
    };
    return respondEmpty(request, .not_modified, request_id, &extra);
}

fn hasUnsupportedHeaders(
    operation: protocol.Operation,
    headers: []const sigv4.Header,
) bool {
    const upload_operation = operation == .put_object or operation == .upload_part;
    const checksum_body_operation = upload_operation or
        operation == .put_bucket_versioning or
        operation == .put_bucket_lifecycle or
        operation == .complete_multipart_upload or
        operation == .delete_objects;
    const signed_streaming = hasHeaderValue(headers, "x-amz-content-sha256", sigv4.streaming_payload);
    const signed_streaming_trailer = hasHeaderValue(
        headers,
        "x-amz-content-sha256",
        sigv4.streaming_trailer_payload,
    );
    const supported_streaming = upload_operation and (signed_streaming or signed_streaming_trailer);
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-content-sha256") and
            std.mem.startsWith(u8, header.value, "STREAMING-"))
        {
            if (!supported_streaming) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-security-token")) {
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-trailer")) {
            if (!upload_operation or !signed_streaming_trailer or
                checksumAlgorithmFromHeaderName(header.value) == null) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-decoded-content-length")) {
            if (!supported_streaming) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-sdk-checksum-algorithm")) {
            if (!checksum_body_operation or
                checksum.Algorithm.parse(header.value) == null) return true;
            continue;
        }
        if (checksumHeaderAlgorithm(header.name) != null) {
            if (!checksum_body_operation) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-checksum-mode")) {
            if ((operation != .get_object and operation != .head_object) or
                !std.ascii.eqlIgnoreCase(header.value, "ENABLED")) return true;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(header.name, "x-amz-checksum-")) return true;
        if (std.ascii.eqlIgnoreCase(header.name, "if-match") or
            std.ascii.eqlIgnoreCase(header.name, "if-none-match") or
            std.ascii.eqlIgnoreCase(header.name, "if-modified-since") or
            std.ascii.eqlIgnoreCase(header.name, "if-unmodified-since"))
        {
            if (operation == .get_object or operation == .head_object or operation == .put_object) {
                continue;
            }
            return true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "range") and operation != .get_object) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-copy-source")) {
            if (operation != .put_object) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-metadata-directive")) {
            if (operation != .put_object or !hasHeaderName(headers, "x-amz-copy-source")) return true;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(header.name, "x-amz-copy-source-if-")) {
            if (operation != .put_object or !hasHeaderName(headers, "x-amz-copy-source")) return true;
            const suffix = header.name["x-amz-copy-source-if-".len..];
            if (!std.ascii.eqlIgnoreCase(suffix, "match") and
                !std.ascii.eqlIgnoreCase(suffix, "none-match") and
                !std.ascii.eqlIgnoreCase(suffix, "modified-since") and
                !std.ascii.eqlIgnoreCase(suffix, "unmodified-since")) return true;
            continue;
        }
    }
    return false;
}

fn hasHeaderName(headers: []const sigv4.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}

fn hasHeaderValue(
    headers: []const sigv4.Header,
    name: []const u8,
    value: []const u8,
) bool {
    var matches: usize = 0;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (!std.mem.eql(u8, header.value, value)) return false;
        matches += 1;
    }
    return matches == 1;
}

fn parseStreamingDecodedLength(headers: []const sigv4.Header) error{InvalidLength}!u64 {
    var value: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "x-amz-decoded-content-length")) continue;
        if (value != null) return error.InvalidLength;
        value = header.value;
    }
    const encoded = value orelse return error.InvalidLength;
    if (encoded.len == 0 or (encoded.len > 1 and encoded[0] == '0')) return error.InvalidLength;
    return std.fmt.parseInt(u64, encoded, 10) catch error.InvalidLength;
}

fn singleHeader(
    headers: []const sigv4.Header,
    name: []const u8,
) error{DuplicateHeader}!?[]const u8 {
    var value: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (value != null) return error.DuplicateHeader;
        value = header.value;
    }
    return value;
}

fn parseRange(value: []const u8, object_size: u64) error{InvalidRange}!ByteRange {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, value, prefix) or
        std.mem.indexOfScalar(u8, value, ',') != null or
        std.mem.indexOfAny(u8, value, " \t\r\n") != null or
        object_size == 0)
    {
        return error.InvalidRange;
    }
    const specification = value[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, specification, '-') orelse {
        return error.InvalidRange;
    };
    if (std.mem.indexOfScalarPos(u8, specification, separator + 1, '-') != null) {
        return error.InvalidRange;
    }
    const start_text = specification[0..separator];
    const end_text = specification[separator + 1 ..];
    if (start_text.len == 0) {
        const suffix_length = std.fmt.parseInt(u64, end_text, 10) catch {
            return error.InvalidRange;
        };
        if (suffix_length == 0) return error.InvalidRange;
        const length = @min(suffix_length, object_size);
        return .{
            .start = object_size - length,
            .end = object_size - 1,
            .length = length,
        };
    }
    const start = std.fmt.parseInt(u64, start_text, 10) catch return error.InvalidRange;
    if (start >= object_size) return error.InvalidRange;
    const requested_end = if (end_text.len == 0)
        object_size - 1
    else
        std.fmt.parseInt(u64, end_text, 10) catch return error.InvalidRange;
    if (requested_end < start) return error.InvalidRange;
    const end = @min(requested_end, object_size - 1);
    return .{
        .start = start,
        .end = end,
        .length = end - start + 1,
    };
}

fn parseContentMd5(headers: []const sigv4.Header) error{InvalidDigest}!?[16]u8 {
    var encoded: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-md5")) continue;
        if (encoded != null) return error.InvalidDigest;
        encoded = header.value;
    }
    const value = encoded orelse return null;
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(value) catch {
        return error.InvalidDigest;
    };
    if (decoded_size != 16) return error.InvalidDigest;
    var digest: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&digest, value) catch return error.InvalidDigest;
    return digest;
}

fn parseCrc64Nvme(
    headers: []const sigv4.Header,
) error{ InvalidDigest, UnsupportedChecksum, InvalidRequest }!?u64 {
    return (try parseChecksumRequest(headers)).header_crc64nvme;
}

fn checksumHeaderAlgorithm(name: []const u8) ?checksum.Algorithm {
    inline for (std.meta.fields(checksum.Algorithm)) |field| {
        const algorithm: checksum.Algorithm = @enumFromInt(field.value);
        if (std.ascii.eqlIgnoreCase(name, algorithm.headerName())) return algorithm;
    }
    return null;
}

fn checksumAlgorithmFromHeaderName(name: []const u8) ?checksum.Algorithm {
    return checksumHeaderAlgorithm(name);
}

fn parseChecksumRequest(
    headers: []const sigv4.Header,
) error{ InvalidDigest, UnsupportedChecksum, InvalidRequest }!ChecksumRequest {
    var algorithm: ?[]const u8 = null;
    var algorithm_value: ?checksum.Algorithm = null;
    var checksum_algorithm: ?checksum.Algorithm = null;
    var encoded: ?[]const u8 = null;
    var trailer_name: ?[]const u8 = null;
    var content_encoding: ?[]const u8 = null;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-sdk-checksum-algorithm")) {
            if (algorithm != null) return error.InvalidDigest;
            algorithm = header.value;
            algorithm_value = checksum.Algorithm.parse(header.value) orelse return error.UnsupportedChecksum;
        } else if (checksumHeaderAlgorithm(header.name)) |header_algorithm| {
            if (encoded != null) return error.InvalidDigest;
            checksum_algorithm = header_algorithm;
            encoded = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-amz-trailer")) {
            if (trailer_name != null) return error.InvalidDigest;
            trailer_name = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) {
            if (content_encoding != null) return error.InvalidRequest;
            content_encoding = header.value;
        } else if (std.ascii.startsWithIgnoreCase(header.name, "x-amz-checksum-")) {
            return error.UnsupportedChecksum;
        }
    }
    const payload_hash_value = singleHeader(headers, "x-amz-content-sha256") catch {
        return error.InvalidDigest;
    };
    const signed_trailer = if (payload_hash_value) |value|
        std.mem.eql(u8, value, sigv4.streaming_trailer_payload)
    else
        false;
    if (trailer_name) |name| {
        if (!signed_trailer) return error.InvalidRequest;
        if (content_encoding == null or
            !std.ascii.eqlIgnoreCase(content_encoding.?, "aws-chunked"))
        {
            return error.InvalidRequest;
        }
        const trailer_algorithm = checksumAlgorithmFromHeaderName(name) orelse return error.UnsupportedChecksum;
        if (algorithm_value) |declared| if (declared != trailer_algorithm) return error.InvalidDigest;
        if (encoded != null) return error.InvalidDigest;
        return .{ .trailer = aws_chunked.Trailer.fromAlgorithm(trailer_algorithm) };
    }
    if (signed_trailer) return error.InvalidRequest;
    if (algorithm != null and encoded == null) return error.InvalidDigest;
    const value = encoded orelse return .{};
    const selected_algorithm = checksum_algorithm orelse return error.InvalidDigest;
    if (algorithm_value) |declared| if (declared != selected_algorithm) return error.InvalidDigest;
    const decoded = checksum.decodeValue(selected_algorithm, value) orelse return error.InvalidDigest;
    var result: ChecksumRequest = .{ .header = decoded };
    switch (decoded) {
        .crc64nvme => |crc| result.header_crc64nvme = crc,
        else => {},
    }
    return result;
}

const PutHeaders = struct {
    content_type: []u8,
    owned_metadata: []object_domain.OwnedUserMetadata,
    views: []object_domain.UserMetadata,

    fn deinit(self: *PutHeaders, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        for (self.owned_metadata) |entry| entry.deinit(allocator);
        allocator.free(self.owned_metadata);
        allocator.free(self.views);
        self.* = undefined;
    }
};

fn collectPutHeaders(
    allocator: std.mem.Allocator,
    request: *const std.http.Server.Request,
) error{ OutOfMemory, InvalidMetadata }!PutHeaders {
    const content_type = allocator.dupe(
        u8,
        request.head.content_type orelse "application/octet-stream",
    ) catch return error.OutOfMemory;
    errdefer allocator.free(content_type);
    var owned: std.ArrayList(object_domain.OwnedUserMetadata) = .empty;
    errdefer {
        for (owned.items) |entry| entry.deinit(allocator);
        owned.deinit(allocator);
    }
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        const prefix = "x-amz-meta-";
        if (header.name.len <= prefix.len or
            !std.ascii.startsWithIgnoreCase(header.name, prefix)) continue;
        const raw_name = header.name[prefix.len..];
        const name = allocator.alloc(u8, raw_name.len) catch return error.OutOfMemory;
        errdefer allocator.free(name);
        for (raw_name, 0..) |character, index| name[index] = std.ascii.toLower(character);
        const value = allocator.dupe(u8, header.value) catch return error.OutOfMemory;
        owned.append(allocator, .{ .name = name, .value = value }) catch {
            allocator.free(value);
            return error.OutOfMemory;
        };
    }
    const owned_slice = owned.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer {
        for (owned_slice) |entry| entry.deinit(allocator);
        allocator.free(owned_slice);
    }
    const views = allocator.alloc(object_domain.UserMetadata, owned_slice.len) catch {
        return error.OutOfMemory;
    };
    for (owned_slice, 0..) |entry, index| {
        views[index] = .{ .name = entry.name, .value = entry.value };
    }
    object_domain.validateContentType(content_type) catch return error.InvalidMetadata;
    object_domain.validateUserMetadata(views) catch return error.InvalidMetadata;
    return .{
        .content_type = content_type,
        .owned_metadata = owned_slice,
        .views = views,
    };
}

const HttpSource = struct {
    reader: *std.Io.Reader,
    remaining: ?u64,

    fn interface(self: *HttpSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *HttpSource = @ptrCast(@alignCast(context));
        if (self.remaining == 0) return 0;
        const count = self.reader.readSliceShort(buffer) catch return error.ReadFailed;
        if (count == 0 and self.remaining != null) return error.ReadFailed;
        if (self.remaining) |remaining| {
            if (count > remaining) return error.ReadFailed;
            self.remaining = remaining - count;
        }
        return count;
    }
};

const SizeBoundSource = struct {
    inner: byte_stream.Source,
    minimum: u64,
    maximum: u64,
    size: u64 = 0,
    failure: enum { none, too_small, too_large } = .none,

    fn interface(self: *SizeBoundSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *SizeBoundSource = @ptrCast(@alignCast(context));
        const count = self.inner.read(buffer) catch return error.ReadFailed;
        if (count == 0) {
            if (self.size < self.minimum) {
                self.failure = .too_small;
                return error.ReadFailed;
            }
            return 0;
        }
        if (self.size > self.maximum or count > self.maximum - self.size) {
            self.failure = .too_large;
            return error.ReadFailed;
        }
        self.size += count;
        return count;
    }
};

const HttpSink = struct {
    writer: *std.Io.Writer,

    fn interface(self: *HttpSink) byte_stream.Sink {
        return .{ .context = self, .vtable = &.{ .write_all = writeAll } };
    }

    fn writeAll(context: *anyopaque, bytes: []const u8) byte_stream.Sink.Error!void {
        const self: *HttpSink = @ptrCast(@alignCast(context));
        self.writer.writeAll(bytes) catch return error.WriteFailed;
    }
};

const ObjectResponseHeaders = struct {
    headers: []std.http.Header,
    owned_names: [][]u8,
    etag: [40]u8,
    etag_length: usize,
    last_modified: [29]u8,
    content_length: [20]u8,
    content_length_length: usize,
    content_range: [64]u8,
    content_range_length: usize,
    include_content_length: bool,
    include_version_id: bool,
    version_id: [object_domain.VersionId.encoded_length]u8,
    version_id_length: usize,

    fn init(
        allocator: std.mem.Allocator,
        object: *const object_domain.Object,
        include_content_length: bool,
        range: ?ByteRange,
        include_version_id: bool,
    ) !ObjectResponseHeaders {
        var result: ObjectResponseHeaders = .{
            .headers = undefined,
            .owned_names = undefined,
            .etag = undefined,
            .etag_length = 0,
            .last_modified = undefined,
            .content_length = undefined,
            .content_length_length = 0,
            .content_range = undefined,
            .content_range_length = 0,
            .include_content_length = include_content_length,
            .include_version_id = include_version_id,
            .version_id = undefined,
            .version_id_length = 0,
        };
        result.etag_length = formatObjectEtag(object, &result.etag).len;
        _ = time.formatHttpDate(object.last_modified_unix_seconds, &result.last_modified) catch {
            return error.InvalidTimestamp;
        };
        const response_size = if (range) |value| value.length else object.size;
        const content_length = std.fmt.bufPrint(&result.content_length, "{d}", .{response_size}) catch {
            return error.NoSpaceLeft;
        };
        result.content_length_length = content_length.len;
        if (include_version_id) {
            const version = object.version_id.write(&result.version_id);
            if (version.ptr != result.version_id[0..].ptr) @memcpy(result.version_id[0..version.len], version);
            result.version_id_length = version.len;
        }
        if (range) |value| {
            const content_range = std.fmt.bufPrint(
                &result.content_range,
                "bytes {d}-{d}/{d}",
                .{ value.start, value.end, object.size },
            ) catch return error.NoSpaceLeft;
            result.content_range_length = content_range.len;
        }
        const fixed_count: usize = 8 +
            @as(usize, @intFromBool(include_content_length)) +
            @as(usize, @intFromBool(range != null)) +
            @as(usize, @intFromBool(include_version_id));
        result.headers = try allocator.alloc(std.http.Header, fixed_count + object.user_metadata.len);
        errdefer allocator.free(result.headers);
        result.owned_names = try allocator.alloc([]u8, object.user_metadata.len);
        var initialized_names: usize = 0;
        errdefer {
            for (result.owned_names[0..initialized_names]) |name| allocator.free(name);
            allocator.free(result.owned_names);
        }
        for (object.user_metadata, 0..) |entry, index| {
            const name = try std.fmt.allocPrint(allocator, "x-amz-meta-{s}", .{entry.name});
            result.owned_names[index] = name;
            initialized_names += 1;
        }
        return result;
    }

    fn populate(
        self: *ObjectResponseHeaders,
        object: *const object_domain.Object,
        request_id: []const u8,
    ) []const std.http.Header {
        var index: usize = 0;
        self.headers[index] = .{ .name = "content-type", .value = object.content_type };
        index += 1;
        if (self.include_content_length) {
            self.headers[index] = .{
                .name = "content-length",
                .value = self.content_length[0..self.content_length_length],
            };
            index += 1;
        }
        self.headers[index] = .{ .name = "accept-ranges", .value = "bytes" };
        index += 1;
        if (self.content_range_length != 0) {
            self.headers[index] = .{
                .name = "content-range",
                .value = self.content_range[0..self.content_range_length],
            };
            index += 1;
        }
        self.headers[index] = .{ .name = "etag", .value = self.etag[0..self.etag_length] };
        index += 1;
        self.headers[index] = .{ .name = "last-modified", .value = &self.last_modified };
        index += 1;
        if (self.include_version_id) {
            self.headers[index] = .{ .name = "x-amz-version-id", .value = self.version_id[0..self.version_id_length] };
            index += 1;
        }
        self.headers[index] = .{ .name = "x-amz-request-id", .value = request_id };
        index += 1;
        self.headers[index] = .{ .name = "x-request-id", .value = request_id };
        index += 1;
        self.headers[index] = .{ .name = "access-control-allow-origin", .value = "*" };
        index += 1;
        self.headers[index] = .{ .name = "access-control-expose-headers", .value = "etag, content-length, content-range, last-modified, x-amz-request-id, x-request-id, x-amz-version-id, x-amz-delete-marker, x-amz-copy-source-version-id" };
        index += 1;
        for (object.user_metadata, 0..) |entry, metadata_index| {
            self.headers[index] = .{
                .name = self.owned_names[metadata_index],
                .value = entry.value,
            };
            index += 1;
        }
        return self.headers[0..index];
    }

    fn deinit(self: *ObjectResponseHeaders, allocator: std.mem.Allocator) void {
        for (self.owned_names) |name| allocator.free(name);
        allocator.free(self.owned_names);
        allocator.free(self.headers);
        self.* = undefined;
    }
};

fn formatEtag(etag_md5: [16]u8, buffer: *[34]u8) []const u8 {
    buffer[0] = '"';
    const hex = std.fmt.bytesToHex(etag_md5, .lower);
    @memcpy(buffer[1..33], &hex);
    buffer[33] = '"';
    return buffer;
}

fn formatObjectEtag(object: *const object_domain.Object, buffer: *[40]u8) []const u8 {
    return formatStoredEtag(object.etag_md5, object.etag_part_count, buffer);
}

fn formatStoredEtag(etag_md5: [16]u8, etag_part_count: u16, buffer: *[40]u8) []const u8 {
    buffer[0] = '"';
    const hex = std.fmt.bytesToHex(etag_md5, .lower);
    @memcpy(buffer[1..33], &hex);
    if (etag_part_count == 0) {
        buffer[33] = '"';
        return buffer[0..34];
    }
    buffer[33] = '-';
    const count = std.fmt.bufPrint(buffer[34 .. buffer.len - 1], "{d}", .{etag_part_count}) catch unreachable;
    const end = 34 + count.len;
    buffer[end] = '"';
    return buffer[0 .. end + 1];
}

fn buildListObjectsXml(
    allocator: std.mem.Allocator,
    bucket_name: []const u8,
    prefix: []const u8,
    delimiter: ?[]const u8,
    max_keys: usize,
    start_after: ?[]const u8,
    continuation_token: ?[]const u8,
    url_encoding: bool,
    include_owner: bool,
    owner: []const u8,
    result: object_listing.Result,
) error{OutOfMemory}![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>") catch return error.OutOfMemory;
    writeEncodedXml(writer, bucket_name, url_encoding) catch return error.OutOfMemory;
    writer.writeAll("</Name><Prefix>") catch return error.OutOfMemory;
    writeEncodedXml(writer, prefix, url_encoding) catch return error.OutOfMemory;
    writer.print("</Prefix><KeyCount>{d}</KeyCount><MaxKeys>{d}</MaxKeys>", .{ result.key_count, max_keys }) catch return error.OutOfMemory;
    if (delimiter) |value| {
        writer.writeAll("<Delimiter>") catch return error.OutOfMemory;
        writeEncodedXml(writer, value, url_encoding) catch return error.OutOfMemory;
        writer.writeAll("</Delimiter>") catch return error.OutOfMemory;
    }
    if (url_encoding) writer.writeAll("<EncodingType>url</EncodingType>") catch return error.OutOfMemory;
    if (continuation_token) |value| {
        writer.writeAll("<ContinuationToken>") catch return error.OutOfMemory;
        protocol.writeXmlEscaped(writer, value) catch return error.OutOfMemory;
        writer.writeAll("</ContinuationToken>") catch return error.OutOfMemory;
    }
    if (start_after) |value| {
        writer.writeAll("<StartAfter>") catch return error.OutOfMemory;
        writeEncodedXml(writer, value, url_encoding) catch return error.OutOfMemory;
        writer.writeAll("</StartAfter>") catch return error.OutOfMemory;
    }
    writer.print("<IsTruncated>{s}</IsTruncated>", .{if (result.is_truncated) "true" else "false"}) catch return error.OutOfMemory;
    if (result.next_continuation_token) |value| {
        writer.writeAll("<NextContinuationToken>") catch return error.OutOfMemory;
        protocol.writeXmlEscaped(writer, value) catch return error.OutOfMemory;
        writer.writeAll("</NextContinuationToken>") catch return error.OutOfMemory;
    }
    for (result.objects) |object| {
        writer.writeAll("<Contents><Key>") catch return error.OutOfMemory;
        writeEncodedXml(writer, object.key, url_encoding) catch return error.OutOfMemory;
        writer.writeAll("</Key><LastModified>") catch return error.OutOfMemory;
        protocol.writeIsoTime(writer, object.last_modified_unix_seconds) catch return error.OutOfMemory;
        var etag: [40]u8 = undefined;
        writer.print("</LastModified><ETag>{s}</ETag><Size>{d}</Size><StorageClass>STANDARD</StorageClass>", .{
            formatStoredEtag(object.etag_md5, object.etag_part_count, &etag),
            object.size,
        }) catch return error.OutOfMemory;
        if (include_owner) {
            writer.writeAll("<Owner><ID>") catch return error.OutOfMemory;
            protocol.writeXmlEscaped(writer, owner) catch return error.OutOfMemory;
            writer.writeAll("</ID><DisplayName>") catch return error.OutOfMemory;
            protocol.writeXmlEscaped(writer, owner) catch return error.OutOfMemory;
            writer.writeAll("</DisplayName></Owner>") catch return error.OutOfMemory;
        }
        writer.writeAll("</Contents>") catch return error.OutOfMemory;
    }
    for (result.common_prefixes) |common_prefix| {
        writer.writeAll("<CommonPrefixes><Prefix>") catch return error.OutOfMemory;
        writeEncodedXml(writer, common_prefix, url_encoding) catch return error.OutOfMemory;
        writer.writeAll("</Prefix></CommonPrefixes>") catch return error.OutOfMemory;
    }
    writer.writeAll("</ListBucketResult>\n") catch return error.OutOfMemory;
    return output.toOwnedSlice() catch error.OutOfMemory;
}

fn writeEncodedXml(
    writer: *std.Io.Writer,
    value: []const u8,
    url_encoding: bool,
) std.Io.Writer.Error!void {
    if (!url_encoding) return protocol.writeXmlEscaped(writer, value);
    for (value) |character| {
        if (std.ascii.isAlphanumeric(character) or
            character == '-' or character == '_' or character == '.' or
            character == '~' or character == '/')
        {
            try protocol.writeXmlEscaped(writer, &.{character});
        } else {
            try writer.print("%{X:0>2}", .{character});
        }
    }
}

fn respondError(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    kind: protocol.ErrorKind,
    request_id: []const u8,
) !std.http.Status {
    return respondErrorWithHeaders(request, allocator, kind, request_id, &.{});
}

fn respondErrorWithHeaders(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    kind: protocol.ErrorKind,
    request_id: []const u8,
    additional_headers: []const std.http.Header,
) !std.http.Status {
    const xml = protocol.errorXml(allocator, kind, request.head.target, request_id) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(xml);
    if (request.head.method == .HEAD) {
        return respondEmpty(request, protocol.describe(kind).status, request_id, additional_headers);
    }
    return respondXml(request, xml, protocol.describe(kind).status, request_id, additional_headers);
}

fn respondInvalidRange(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    object_size: u64,
    request_id: []const u8,
) !std.http.Status {
    var value_buffer: [40]u8 = undefined;
    const value = try std.fmt.bufPrint(&value_buffer, "bytes */{d}", .{object_size});
    const headers = [_]std.http.Header{.{ .name = "content-range", .value = value }};
    return respondErrorWithHeaders(request, allocator, .invalid_range, request_id, &headers);
}

fn respondXml(
    request: *std.http.Server.Request,
    body: []const u8,
    status: std.http.Status,
    request_id: []const u8,
    additional_headers: []const std.http.Header,
) !std.http.Status {
    var headers: [16]std.http.Header = undefined;
    if (additional_headers.len > headers.len - 6) return error.OutOfMemory;
    headers[0] = .{ .name = "content-type", .value = "application/xml" };
    headers[1] = .{ .name = "cache-control", .value = "no-store" };
    headers[2] = .{ .name = "x-amz-request-id", .value = request_id };
    headers[3] = .{ .name = "x-request-id", .value = request_id };
    headers[4] = .{ .name = "access-control-allow-origin", .value = "*" };
    headers[5] = .{ .name = "access-control-expose-headers", .value = "etag, content-length, content-range, last-modified, x-amz-request-id, x-request-id, x-amz-version-id, x-amz-delete-marker, x-amz-copy-source-version-id, x-amz-checksum-crc32, x-amz-checksum-crc32c, x-amz-checksum-crc64nvme, x-amz-checksum-sha1, x-amz-checksum-sha256" };
    @memcpy(headers[6..][0..additional_headers.len], additional_headers);
    try request.respond(body, .{
        .status = status,
        .extra_headers = headers[0 .. 6 + additional_headers.len],
    });
    return status;
}

fn respondEmpty(
    request: *std.http.Server.Request,
    status: std.http.Status,
    request_id: []const u8,
    additional_headers: []const std.http.Header,
) !std.http.Status {
    var headers: [16]std.http.Header = undefined;
    if (additional_headers.len > headers.len - 5) return error.OutOfMemory;
    headers[0] = .{ .name = "cache-control", .value = "no-store" };
    headers[1] = .{ .name = "x-amz-request-id", .value = request_id };
    headers[2] = .{ .name = "x-request-id", .value = request_id };
    headers[3] = .{ .name = "access-control-allow-origin", .value = "*" };
    headers[4] = .{ .name = "access-control-expose-headers", .value = "etag, content-length, content-range, last-modified, x-amz-request-id, x-request-id, x-amz-version-id, x-amz-delete-marker, x-amz-copy-source-version-id, x-amz-checksum-crc32, x-amz-checksum-crc32c, x-amz-checksum-crc64nvme, x-amz-checksum-sha1, x-amz-checksum-sha256" };
    @memcpy(headers[5..][0..additional_headers.len], additional_headers);
    try request.respond("", .{
        .status = status,
        .extra_headers = headers[0 .. 5 + additional_headers.len],
    });
    return status;
}

fn respondCorsPreflight(
    request: *std.http.Server.Request,
    request_id: []const u8,
) !std.http.Status {
    const headers = [_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-amz-request-id", .value = request_id },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "access-control-allow-methods", .value = "GET, PUT, DELETE, HEAD, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "content-type, content-md5, if-match, if-none-match, if-modified-since, if-unmodified-since, x-amz-content-sha256, x-amz-date, x-amz-security-token, x-amz-copy-source, x-amz-copy-source-if-match, x-amz-copy-source-if-none-match, x-amz-copy-source-if-modified-since, x-amz-copy-source-if-unmodified-since, x-amz-metadata-directive, authorization, x-amz-sdk-checksum-algorithm, x-amz-trailer, x-amz-checksum-crc32, x-amz-checksum-crc32c, x-amz-checksum-crc64nvme, x-amz-checksum-sha1, x-amz-checksum-sha256" },
        .{ .name = "access-control-expose-headers", .value = "etag, content-length, content-range, last-modified, x-amz-request-id, x-request-id, x-amz-version-id, x-amz-delete-marker, x-amz-copy-source-version-id, x-amz-checksum-crc32, x-amz-checksum-crc32c, x-amz-checksum-crc64nvme, x-amz-checksum-sha1, x-amz-checksum-sha256" },
        .{ .name = "access-control-max-age", .value = "600" },
    };
    try request.respond("", .{ .status = .no_content, .extra_headers = &headers });
    return .no_content;
}

fn mapSignatureParseError(err: sigv4.Error) protocol.ErrorKind {
    return switch (err) {
        error.MissingAuthorization => .access_denied,
        error.OutOfMemory => .internal_error,
        else => .authorization_header_malformed,
    };
}

fn mapSignatureVerifyError(err: sigv4.Error) protocol.ErrorKind {
    return switch (err) {
        error.SignatureDoesNotMatch => .signature_does_not_match,
        error.RequestTimeTooSkewed => .request_time_too_skewed,
        error.InvalidCredentialScope => .authorization_header_malformed,
        error.OutOfMemory => .internal_error,
        error.InvalidToken => .invalid_token,
        else => .invalid_request,
    };
}

fn mapStreamingFailure(failure: aws_chunked.Failure) protocol.ErrorKind {
    return switch (failure) {
        .signature_mismatch, .trailer_signature_mismatch => .signature_does_not_match,
        .checksum_mismatch => .bad_digest,
        .none,
        .malformed_chunk_header,
        .unexpected_end,
        .invalid_chunk_ending,
        .invalid_final_ending,
        .malformed_trailer,
        .decoded_length_mismatch,
        => .invalid_request,
    };
}

fn mapPresignedParseError(err: sigv4.Error) protocol.ErrorKind {
    return switch (err) {
        error.OutOfMemory => .internal_error,
        error.InvalidToken => .invalid_token,
        else => .authorization_query_parameters_error,
    };
}

fn mapPresignedVerifyError(err: sigv4.Error) protocol.ErrorKind {
    return switch (err) {
        error.SignatureDoesNotMatch => .signature_does_not_match,
        error.RequestTimeTooSkewed => .request_time_too_skewed,
        error.RequestExpired => .request_expired,
        error.InvalidCredentialScope => .authorization_query_parameters_error,
        error.OutOfMemory => .internal_error,
        error.InvalidToken => .invalid_token,
        else => .invalid_request,
    };
}

fn mapCredentialError(err: credential_service.Error) protocol.ErrorKind {
    return switch (err) {
        error.InvalidAccessKey, error.CredentialNotFound => .invalid_access_key_id,
        error.CredentialDisabled => .access_denied,
        error.CredentialExpired => .expired_token,
        error.OutOfMemory,
        error.Conflict,
        error.CorruptMetadata,
        error.SecretDecryptionFailed,
        error.Unavailable,
        error.InvalidOwner,
        error.InvalidTTL,
        => .internal_error,
    };
}

fn mapPostPolicyParserError(err: s3_post_policy.Error) protocol.ErrorKind {
    return switch (err) {
        error.OutOfMemory => .internal_error,
        error.InvalidContentType,
        error.InvalidBoundary,
        error.InvalidBody,
        error.FieldTooLarge,
        error.TooManyFields,
        error.DuplicateField,
        => .invalid_request,
    };
}

fn mapPostPolicySignatureError(err: sigv4.Error) protocol.ErrorKind {
    return switch (err) {
        error.SignatureDoesNotMatch => .signature_does_not_match,
        error.InvalidCredentialScope,
        error.MalformedAuthorization,
        => .authorization_header_malformed,
        error.InvalidDate => .invalid_argument,
        error.OutOfMemory => .internal_error,
        else => .invalid_request,
    };
}

fn mapPostPolicyError(err: PostPolicyError) protocol.ErrorKind {
    return switch (err) {
        error.InvalidPolicy => .invalid_argument,
        error.UnsupportedCondition,
        error.UnsupportedField,
        => .invalid_argument,
        error.UnsupportedChecksum => .not_implemented,
        error.OutOfMemory => .internal_error,
    };
}

fn mapBucketError(err: bucket_service.Error) protocol.ErrorKind {
    return switch (err) {
        error.InvalidBucketName => .invalid_bucket_name,
        error.InvalidOwner => .access_denied,
        error.BucketNotFound => .no_such_bucket,
        error.BucketAlreadyExists => .bucket_already_exists,
        error.BucketNotEmpty => .bucket_not_empty,
        error.Unavailable => .service_unavailable,
        error.OutOfMemory,
        error.Conflict,
        error.CorruptMetadata,
        => .internal_error,
    };
}

fn mapObjectError(err: object_service.Error) protocol.ErrorKind {
    return switch (err) {
        error.InvalidBucketName => .invalid_bucket_name,
        error.InvalidObjectKey,
        error.InvalidContentType,
        error.InvalidUserMetadata,
        error.InvalidVersionId,
        error.InputReadFailed,
        error.InvalidRange,
        => .invalid_request,
        error.BucketNotFound => .no_such_bucket,
        error.ObjectNotFound => .no_such_key,
        error.DeleteMarker => .no_such_key,
        error.ChecksumMismatch => .bad_digest,
        error.ConditionNotMet => .precondition_failed,
        error.Unavailable => .service_unavailable,
        error.OutOfMemory,
        error.OutputWriteFailed,
        error.Conflict,
        error.CorruptMetadata,
        error.CorruptData,
        => .internal_error,
    };
}

fn mapMultipartError(err: multipart_service.Error) protocol.ErrorKind {
    return switch (err) {
        error.InvalidBucketName => .invalid_bucket_name,
        error.InvalidUploadId, error.UploadNotFound => .no_such_upload,
        error.InvalidPart => .invalid_part,
        error.InvalidPartOrder => .invalid_part_order,
        error.EntityTooSmall => .entity_too_small,
        error.InvalidPartNumber,
        error.InvalidListOptions,
        error.InvalidObjectKey,
        error.InvalidContentType,
        error.InvalidUserMetadata,
        error.InputReadFailed,
        => .invalid_request,
        error.BucketNotFound => .no_such_bucket,
        error.ChecksumMismatch => .bad_digest,
        error.Unavailable => .service_unavailable,
        error.OutOfMemory,
        error.Conflict,
        error.CorruptMetadata,
        error.CorruptData,
        => .internal_error,
    };
}

fn mapListingError(err: object_listing.Error) protocol.ErrorKind {
    return switch (err) {
        error.InvalidBucketName => .invalid_bucket_name,
        error.InvalidListOptions,
        error.InvalidContinuationToken,
        => .invalid_argument,
        error.BucketNotFound => .no_such_bucket,
        error.Unavailable => .service_unavailable,
        error.OutOfMemory, error.CorruptMetadata => .internal_error,
    };
}

test "S3 operation policy mapping keeps Bucket and Object permissions separate" {
    try std.testing.expectEqual(credential_domain.Action.list_buckets, actionFor(.list_buckets).?);
    try std.testing.expectEqual(credential_domain.Action.head_bucket, actionFor(.get_bucket_location).?);
    try std.testing.expectEqual(credential_domain.Action.head_bucket, actionFor(.list_multipart_uploads).?);
    try std.testing.expectEqual(credential_domain.Action.put_object, actionFor(.put_object).?);
    try std.testing.expectEqual(credential_domain.Action.put_object, actionFor(.upload_part).?);
    try std.testing.expectEqual(credential_domain.Action.get_object, actionFor(.list_parts).?);
    try std.testing.expectEqual(credential_domain.Action.delete_object, actionFor(.delete_objects).?);
    try std.testing.expect(actionFor(.unsupported) == null);
}

test "S3 Content-MD5 parsing accepts a single RFC 4648 digest" {
    const headers = [_]sigv4.Header{.{
        .name = "Content-MD5",
        .value = "kAFQmDzST7DWlj99KOF/cg==",
    }};
    const digest = (try parseContentMd5(&headers)).?;
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &std.fmt.bytesToHex(digest, .lower));
    const duplicate = [_]sigv4.Header{ headers[0], headers[0] };
    try std.testing.expectError(error.InvalidDigest, parseContentMd5(&duplicate));
}

test "S3 CRC64NVME parsing accepts AWS flexible checksum headers" {
    const headers = [_]sigv4.Header{
        .{ .name = "x-amz-sdk-checksum-algorithm", .value = "CRC64NVME" },
        .{ .name = "x-amz-checksum-crc64nvme", .value = "rosUhgp5mIg=" },
    };
    try std.testing.expectEqual(@as(u64, 0xae8b14860a799888), (try parseCrc64Nvme(&headers)).?);
    const unsupported = [_]sigv4.Header{.{
        .name = "x-amz-sdk-checksum-algorithm",
        .value = "CRC16",
    }};
    try std.testing.expectError(error.UnsupportedChecksum, parseCrc64Nvme(&unsupported));
    const unknown_header = [_]sigv4.Header{.{
        .name = "x-amz-checksum-foo",
        .value = "AAAA",
    }};
    try std.testing.expectError(error.UnsupportedChecksum, parseChecksumRequest(&unknown_header));
}

test "S3 flexible checksum headers parse and preserve algorithm values" {
    const values = [_]struct {
        algorithm: []const u8,
        header: []const u8,
        value: checksum.Value,
    }{
        .{ .algorithm = "CRC32", .header = "x-amz-checksum-crc32", .value = .{ .crc32 = 0xcbf43926 } },
        .{ .algorithm = "CRC32C", .header = "x-amz-checksum-crc32c", .value = .{ .crc32c = 0xe3069283 } },
        .{ .algorithm = "CRC64NVME", .header = "x-amz-checksum-crc64nvme", .value = .{ .crc64nvme = 0xae8b14860a799888 } },
        .{ .algorithm = "SHA1", .header = "x-amz-checksum-sha1", .value = .{ .sha1 = .{ 0xf7, 0xc3, 0xbc, 0x1d, 0x80, 0x8e, 0x04, 0x73, 0x2a, 0xdf, 0x67, 0x99, 0x65, 0xcc, 0xc3, 0x4c, 0xa7, 0xae, 0x34, 0x41 } } },
        .{ .algorithm = "SHA256", .header = "x-amz-checksum-sha256", .value = .{ .sha256 = .{ 0x15, 0xe2, 0xb0, 0xd3, 0xc3, 0x38, 0x91, 0xeb, 0xb0, 0xf1, 0xef, 0x60, 0x9e, 0xc4, 0x19, 0x42, 0x0c, 0x20, 0xe3, 0x20, 0xce, 0x94, 0xc6, 0x5f, 0xbc, 0x8c, 0x33, 0x12, 0x44, 0x8e, 0xb2, 0x25 } } },
    };
    for (values) |entry| {
        var encoded_buffer: [64]u8 = undefined;
        const encoded = checksum.encodeValue(entry.value, &encoded_buffer);
        const headers = [_]sigv4.Header{
            .{ .name = "x-amz-sdk-checksum-algorithm", .value = entry.algorithm },
            .{ .name = entry.header, .value = encoded },
        };
        const parsed = try parseChecksumRequest(&headers);
        try std.testing.expect(parsed.header != null);
        try std.testing.expectEqual(entry.value.algorithm(), parsed.header.?.algorithm());
        try std.testing.expectEqualStrings(encoded, checksum.encodeValue(parsed.header.?, &encoded_buffer));
        try std.testing.expect(!hasUnsupportedHeaders(.put_object, &headers));
    }
}

test "S3 XML body checksum validation accepts valid values and rejects mismatches" {
    const valid_headers = [_]sigv4.Header{
        .{ .name = "x-amz-sdk-checksum-algorithm", .value = "CRC64NVME" },
        .{ .name = "x-amz-checksum-crc64nvme", .value = "rosUhgp5mIg=" },
    };
    try std.testing.expect(validateBodyChecksums(&valid_headers, "123456789") == null);
    try std.testing.expectEqual(
        protocol.ErrorKind.bad_digest,
        validateBodyChecksums(&valid_headers, "different").?,
    );

    const mismatched_algorithm = [_]sigv4.Header{
        .{ .name = "x-amz-sdk-checksum-algorithm", .value = "CRC32" },
        .{ .name = "x-amz-checksum-crc64nvme", .value = "rosUhgp5mIg=" },
    };
    try std.testing.expectEqual(
        protocol.ErrorKind.invalid_digest,
        validateBodyChecksums(&mismatched_algorithm, "123456789").?,
    );
}

test "S3 supported checksum headers remain distinct from streaming checksums" {
    const crc64_headers = [_]sigv4.Header{
        .{ .name = "x-amz-sdk-checksum-algorithm", .value = "CRC64NVME" },
        .{ .name = "x-amz-checksum-crc64nvme", .value = "rosUhgp5mIg=" },
    };
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &crc64_headers));

    const checksum_mode = [_]sigv4.Header{.{
        .name = "x-amz-checksum-mode",
        .value = "ENABLED",
    }};
    try std.testing.expect(!hasUnsupportedHeaders(.head_object, &checksum_mode));

    const conditional = [_]sigv4.Header{.{
        .name = "If-None-Match",
        .value = "*",
    }};
    try std.testing.expect(!hasUnsupportedHeaders(.get_object, &conditional));
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &conditional));
    try std.testing.expect(hasUnsupportedHeaders(.delete_object, &conditional));

    const streaming = [_]sigv4.Header{.{
        .name = "x-amz-content-sha256",
        .value = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
    }};
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &streaming));
    try std.testing.expect(hasUnsupportedHeaders(.get_object, &streaming));

    const signed_trailer = [_]sigv4.Header{
        .{ .name = "content-encoding", .value = "aws-chunked" },
        .{ .name = "x-amz-content-sha256", .value = sigv4.streaming_trailer_payload },
        .{ .name = "x-amz-sdk-checksum-algorithm", .value = "CRC64NVME" },
        .{ .name = "x-amz-trailer", .value = "x-amz-checksum-crc64nvme" },
    };
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &signed_trailer));
    try std.testing.expect(!hasUnsupportedHeaders(.upload_part, &signed_trailer));
    try std.testing.expect(hasUnsupportedHeaders(.get_object, &signed_trailer));
    try std.testing.expectEqual(
        aws_chunked.Trailer.crc64nvme,
        (try parseChecksumRequest(&signed_trailer)).trailer,
    );

    const supported_crc32c_trailer = [_]sigv4.Header{
        .{ .name = "content-encoding", .value = "aws-chunked" },
        .{ .name = "x-amz-content-sha256", .value = sigv4.streaming_trailer_payload },
        .{ .name = "x-amz-sdk-checksum-algorithm", .value = "CRC32C" },
        .{ .name = "x-amz-trailer", .value = "x-amz-checksum-crc32c" },
    };
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &supported_crc32c_trailer));
    try std.testing.expectEqual(
        aws_chunked.Trailer.crc32c,
        (try parseChecksumRequest(&supported_crc32c_trailer)).trailer,
    );

    const missing_trailer = [_]sigv4.Header{.{
        .name = "x-amz-content-sha256",
        .value = sigv4.streaming_trailer_payload,
    }};
    try std.testing.expectError(error.InvalidRequest, parseChecksumRequest(&missing_trailer));

    const missing_content_encoding = [_]sigv4.Header{
        .{ .name = "x-amz-content-sha256", .value = sigv4.streaming_trailer_payload },
        .{ .name = "x-amz-trailer", .value = "x-amz-checksum-crc64nvme" },
    };
    try std.testing.expectError(
        error.InvalidRequest,
        parseChecksumRequest(&missing_content_encoding),
    );
}

test "S3 conditional headers use strong and weak ETag matching" {
    const object = object_domain.Object{
        .id = .{0} ** 16,
        .bucket_id = .{0} ** 16,
        .bucket_name = "",
        .key = "",
        .size = 0,
        .etag_md5 = .{0} ** 16,
        .checksum_sha256 = .{0} ** 32,
        .content_type = "",
        .last_modified_unix_seconds = 1_369_353_600,
        .user_metadata = &.{},
        .data_generation = .{0} ** 16,
        .status = .active,
        .metadata_generation = 7,
    };
    const current = "\"00000000000000000000000000000000\"";
    try std.testing.expect(try etagListMatches(current, current, false));
    try std.testing.expect(try etagListMatches("W/\"00000000000000000000000000000000\"", current, true));
    try std.testing.expect(!try etagListMatches("W/\"00000000000000000000000000000000\"", current, false));
    try std.testing.expect(try etagListMatches("*", current, false));
    try std.testing.expectError(error.InvalidCondition, etagListMatches("* , \"other\"", current, false));

    const exact = [_]sigv4.Header{.{ .name = "If-Match", .value = current }};
    const exact_conditions = try parseConditionalHeaders(&exact);
    try std.testing.expectEqual(
        ConditionalOutcome.proceed,
        try evaluateConditional(exact_conditions, &object, .GET),
    );
    const none = [_]sigv4.Header{.{ .name = "If-None-Match", .value = current }};
    try std.testing.expectEqual(
        ConditionalOutcome.not_modified,
        try evaluateConditional(try parseConditionalHeaders(&none), &object, .GET),
    );
    try std.testing.expectEqual(
        ConditionalOutcome.precondition_failed,
        try evaluateConditional(try parseConditionalHeaders(&none), &object, .PUT),
    );
    const old_date = [_]sigv4.Header{.{ .name = "If-Unmodified-Since", .value = "Thu, 01 Jan 1970 00:00:00 GMT" }};
    try std.testing.expectEqual(
        ConditionalOutcome.precondition_failed,
        try evaluateConditional(try parseConditionalHeaders(&old_date), &object, .GET),
    );
    const match_precedence = [_]sigv4.Header{
        .{ .name = "If-Match", .value = current },
        .{ .name = "If-Unmodified-Since", .value = "Thu, 01 Jan 1970 00:00:00 GMT" },
    };
    try std.testing.expectEqual(
        ConditionalOutcome.proceed,
        try evaluateConditional(try parseConditionalHeaders(&match_precedence), &object, .GET),
    );
    const current_date = [_]sigv4.Header{.{ .name = "If-Modified-Since", .value = "Fri, 24 May 2013 00:00:00 GMT" }};
    try std.testing.expectEqual(
        ConditionalOutcome.not_modified,
        try evaluateConditional(try parseConditionalHeaders(&current_date), &object, .HEAD),
    );
    const none_precedence = [_]sigv4.Header{
        .{ .name = "If-None-Match", .value = "\"different\"" },
        .{ .name = "If-Modified-Since", .value = "Fri, 01 Jan 2100 00:00:00 GMT" },
    };
    try std.testing.expectEqual(
        ConditionalOutcome.proceed,
        try evaluateConditional(try parseConditionalHeaders(&none_precedence), &object, .GET),
    );
}

test "S3 CopyObject parses encoded sources and metadata directives" {
    const headers = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets/folder%2Fhello.txt",
    }};
    var source = (try parseCopySource(std.testing.allocator, &headers)).?;
    defer source.deinit();
    try std.testing.expectEqualStrings("project-assets", source.bucket);
    try std.testing.expectEqualStrings("folder/hello.txt", source.key);
    try std.testing.expect(source.version_id == null);
    try std.testing.expectEqual(MetadataDirective.copy, try parseMetadataDirective(&headers));

    const unprefixed_headers = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "project-assets/folder%2Fhello.txt",
    }};
    var unprefixed = (try parseCopySource(std.testing.allocator, &unprefixed_headers)).?;
    defer unprefixed.deinit();
    try std.testing.expectEqualStrings("project-assets", unprefixed.bucket);
    try std.testing.expectEqualStrings("folder/hello.txt", unprefixed.key);

    const version_id_text = "00112233445546778899aabbccddeeff";
    const version_headers = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets/folder%2Fhello.txt?versionId=" ++ version_id_text,
    }};
    var versioned = (try parseCopySource(std.testing.allocator, &version_headers)).?;
    defer versioned.deinit();
    try std.testing.expectEqualStrings("folder/hello.txt", versioned.key);
    try std.testing.expect(object_domain.VersionId.eql(
        try object_domain.parseVersionId(version_id_text),
        versioned.version_id.?,
    ));

    const encoded_question_headers = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets/folder%3Fname.txt",
    }};
    var encoded_question = (try parseCopySource(std.testing.allocator, &encoded_question_headers)).?;
    defer encoded_question.deinit();
    try std.testing.expectEqualStrings("folder?name.txt", encoded_question.key);
    try std.testing.expect(encoded_question.version_id == null);

    const replace_headers = [_]sigv4.Header{
        headers[0],
        .{ .name = "x-amz-metadata-directive", .value = "replace" },
    };
    try std.testing.expectEqual(MetadataDirective.replace, try parseMetadataDirective(&replace_headers));
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &replace_headers));
    try std.testing.expect(hasUnsupportedHeaders(.get_object, &replace_headers));

    const malformed = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets/no%ZZ",
    }};
    try std.testing.expectError(error.InvalidCopySource, parseCopySource(std.testing.allocator, &malformed));
    const missing_key = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets",
    }};
    try std.testing.expectError(error.InvalidCopySource, parseCopySource(std.testing.allocator, &missing_key));
    const invalid_version = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets/folder/hello.txt?versionId=invalid",
    }};
    try std.testing.expectError(error.InvalidCopySource, parseCopySource(std.testing.allocator, &invalid_version));
    const unsupported_query = [_]sigv4.Header{.{
        .name = "x-amz-copy-source",
        .value = "/project-assets/folder/hello.txt?other=value",
    }};
    try std.testing.expectError(error.InvalidCopySource, parseCopySource(std.testing.allocator, &unsupported_query));
}

test "S3 streaming failure mapping separates signatures checksums and framing" {
    try std.testing.expectEqual(
        protocol.ErrorKind.signature_does_not_match,
        mapStreamingFailure(.trailer_signature_mismatch),
    );
    try std.testing.expectEqual(protocol.ErrorKind.bad_digest, mapStreamingFailure(.checksum_mismatch));
    try std.testing.expectEqual(protocol.ErrorKind.invalid_request, mapStreamingFailure(.malformed_trailer));
}

test "S3 streaming decoded length is singular and canonical" {
    const headers = [_]sigv4.Header{.{
        .name = "x-amz-decoded-content-length",
        .value = "21",
    }};
    try std.testing.expectEqual(@as(u64, 21), try parseStreamingDecodedLength(&headers));
    const duplicate = [_]sigv4.Header{ headers[0], headers[0] };
    try std.testing.expectError(error.InvalidLength, parseStreamingDecodedLength(&duplicate));
}

test "S3 single byte ranges normalize open ended and suffix forms" {
    try std.testing.expectEqual(
        ByteRange{ .start = 0, .end = 3, .length = 4 },
        try parseRange("bytes=0-3", 10),
    );
    try std.testing.expectEqual(
        ByteRange{ .start = 7, .end = 9, .length = 3 },
        try parseRange("bytes=-3", 10),
    );
    try std.testing.expectEqual(
        ByteRange{ .start = 8, .end = 9, .length = 2 },
        try parseRange("bytes=8-", 10),
    );
    try std.testing.expectError(error.InvalidRange, parseRange("bytes=10-11", 10));
    try std.testing.expectError(error.InvalidRange, parseRange("bytes=0-1,4-5", 10));
}

test "CreateBucket location constraint matches the configured endpoint region" {
    try std.testing.expectEqual(null, validateLocationConstraint("", "us-east-1"));
    try std.testing.expectEqual(
        protocol.ErrorKind.invalid_location_constraint,
        validateLocationConstraint("", "eu-central-1").?,
    );
    try std.testing.expectEqual(null, validateLocationConstraint(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
            "<LocationConstraint>eu-central-1</LocationConstraint>" ++
            "</CreateBucketConfiguration>",
        "eu-central-1",
    ));
    try std.testing.expectEqual(
        protocol.ErrorKind.invalid_location_constraint,
        validateLocationConstraint(
            "<CreateBucketConfiguration><LocationConstraint>ap-south-1</LocationConstraint></CreateBucketConfiguration>",
            "eu-central-1",
        ).?,
    );
    try std.testing.expectEqual(
        protocol.ErrorKind.malformed_xml,
        validateLocationConstraint("<CreateBucketConfiguration>", "eu-central-1").?,
    );
}
