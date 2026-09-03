const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const bucket_service = @import("../application/bucket_service.zig");
const credential_service = @import("../application/credential_service.zig");
const object_listing = @import("../application/object_listing.zig");
const object_service = @import("../application/object_service.zig");
const policy = @import("../auth/policy.zig");
const sigv4 = @import("../auth/sigv4.zig");
const time = @import("../common/time.zig");
const credential_domain = @import("../domain/credential.zig");
const object_domain = @import("../domain/object.zig");
const byte_stream = @import("../ports/byte_stream.zig");
const aws_chunked = @import("aws_chunked.zig");
const protocol = @import("s3_protocol.zig");
const delete_objects = @import("s3_delete_objects.zig");

pub const service_name = "s3";

const ByteRange = struct {
    start: u64,
    end: u64,
    length: u64,
};

pub fn serveRequest(
    request: *std.http.Server.Request,
    application: *Application,
    request_id: []const u8,
) !std.http.Status {
    const allocator = application.allocator;
    const raw_target = request.head.target;
    const parsed = protocol.parseTarget(
        allocator,
        request.head.method,
        raw_target,
    ) catch {
        return respondError(request, allocator, .invalid_request, request_id);
    };
    defer parsed.deinit();
    // Request body reads may reuse the HTTP head buffer. Keep Resource stable for errors.
    request.head.target = parsed.decoded_path;

    var headers: std.ArrayList(sigv4.Header) = .empty;
    defer headers.deinit(allocator);
    var header_iterator = request.iterateHeaders();
    while (header_iterator.next()) |header| {
        headers.append(allocator, .{ .name = header.name, .value = header.value }) catch {
            return respondError(request, allocator, .internal_error, request_id);
        };
    }
    const authorization_header = singleHeader(headers.items, "authorization") catch {
        return respondError(request, allocator, .authorization_header_malformed, request_id);
    };
    const uses_presigned_auth = sigv4.hasPresignedParameters(raw_target);
    if (uses_presigned_auth and authorization_header != null) {
        return respondError(request, allocator, .invalid_request, request_id);
    }
    if (uses_presigned_auth and
        parsed.operation != .get_object and parsed.operation != .put_object)
    {
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

    if (actionFor(parsed.operation)) |action| {
        policy.authorize(auth_material.policy, action) catch {
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
            parsed.bucket.?,
            parsed.key.?,
            auth_material.owner,
            headers.items,
            payload_hash,
            request_id,
        ),
        .head_object => serveHeadObject(
            request,
            application,
            parsed.bucket.?,
            parsed.key.?,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .delete_object => serveDeleteObject(
            request,
            application,
            parsed.bucket.?,
            parsed.key.?,
            auth_material.owner,
            headers.items,
            request_id,
        ),
        .unsupported => respondError(request, allocator, .not_implemented, request_id),
    };
}

fn actionFor(operation: protocol.Operation) ?credential_domain.Action {
    return switch (operation) {
        .list_buckets => .list_buckets,
        .create_bucket => .create_bucket,
        .head_bucket => .head_bucket,
        .get_bucket_location => .head_bucket,
        .delete_bucket => .delete_bucket,
        .delete_objects => .delete_object,
        .list_objects_v2 => .list_objects,
        .put_object => .put_object,
        .get_object => .get_object,
        .head_object => .head_object,
        .delete_object => .delete_object,
        .unsupported => null,
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
    const bucket = ensureBucketOwner(application, bucket_name, owner) catch |err| {
        return respondError(request, application.allocator, mapBucketError(err), request_id);
    };
    bucket.deinit(application.allocator);
    const expected_md5 = parseContentMd5(headers) catch {
        return respondError(request, application.allocator, .invalid_digest, request_id);
    };
    const expected_crc64nvme = parseCrc64Nvme(headers) catch |err| switch (err) {
        error.InvalidDigest => return respondError(request, application.allocator, .invalid_digest, request_id),
        error.UnsupportedChecksum => return respondError(request, application.allocator, .not_implemented, request_id),
    };
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
    var http_source: HttpSource = .{ .reader = body_reader };
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
            streaming_source = aws_chunked.Source.init(body_reader, verifier, decoded_length);
            streaming_source_active = true;
            break :streamed streaming_source.interface();
        },
    };
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const object = objects.put(bucket_name, key, source, .{
        .content_type = put_headers.content_type,
        .user_metadata = put_headers.views,
        .expected_md5 = expected_md5,
        .expected_sha256 = expected_sha256,
        .expected_crc64nvme = expected_crc64nvme,
    }) catch |err| {
        const kind: protocol.ErrorKind = if (err == error.InputReadFailed and streaming_source_active)
            switch (streaming_source.failure) {
                .signature_mismatch => .signature_does_not_match,
                .none,
                .malformed_chunk_header,
                .unexpected_end,
                .invalid_chunk_ending,
                .invalid_final_ending,
                .decoded_length_mismatch,
                => .invalid_request,
            }
        else if (err == error.ChecksumMismatch)
            if (expected_md5 != null or expected_crc64nvme != null)
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
    if (expected_crc64nvme) |checksum| {
        var checksum_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &checksum_bytes, checksum, .big);
        var encoded_buffer: [12]u8 = undefined;
        const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, &checksum_bytes);
        const extra = [_]std.http.Header{
            .{ .name = "etag", .value = etag },
            .{ .name = "x-amz-checksum-crc64nvme", .value = encoded },
        };
        return respondEmpty(request, .ok, request_id, &extra);
    }
    const extra = [_]std.http.Header{.{ .name = "etag", .value = etag }};
    return respondEmpty(request, .ok, request_id, &extra);
}

fn serveGetObject(
    request: *std.http.Server.Request,
    application: *Application,
    bucket_name: []const u8,
    key: []const u8,
    owner: []const u8,
    headers: []const sigv4.Header,
    payload_hash: sigv4.PayloadHash,
    request_id: []const u8,
) !std.http.Status {
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
    var lease = objects.open(bucket_name, key) catch |err| {
        return respondError(request, application.allocator, mapObjectError(err), request_id);
    };
    defer lease.deinit();
    const object = lease.metadata();
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
    bucket_name: []const u8,
    key: []const u8,
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
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    const object = objects.head(bucket_name, key) catch |err| {
        return respondError(request, application.allocator, mapObjectError(err), request_id);
    };
    defer object.deinit(application.allocator);
    var response_headers = try ObjectResponseHeaders.init(application.allocator, &object, true, null);
    defer response_headers.deinit(application.allocator);
    const header_values = response_headers.populate(&object, request_id);
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
    bucket_name: []const u8,
    key: []const u8,
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
    const objects = application.objectService() orelse {
        return respondError(request, application.allocator, .service_unavailable, request_id);
    };
    _ = objects.delete(bucket_name, key) catch |err| {
        return respondError(request, application.allocator, mapObjectError(err), request_id);
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

    const expected_md5 = (parseContentMd5(headers) catch {
        return respondError(request, application.allocator, .invalid_digest, request_id);
    }) orelse return respondError(request, application.allocator, .invalid_digest, request_id);
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

    var actual_md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(body, &actual_md5, .{});
    if (!std.crypto.timing_safe.eql([16]u8, expected_md5, actual_md5)) {
        return respondError(request, application.allocator, .bad_digest, request_id);
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

fn hasUnsupportedHeaders(
    operation: protocol.Operation,
    headers: []const sigv4.Header,
) bool {
    const supported_streaming = operation == .put_object and hasHeaderValue(
        headers,
        "x-amz-content-sha256",
        sigv4.streaming_payload,
    );
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-content-sha256") and
            std.mem.startsWith(u8, header.value, "STREAMING-"))
        {
            if (!supported_streaming) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-security-token") or
            std.ascii.eqlIgnoreCase(header.name, "x-amz-trailer"))
        {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-decoded-content-length")) {
            if (!supported_streaming) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-sdk-checksum-algorithm")) {
            if (operation != .put_object or
                !std.ascii.eqlIgnoreCase(header.value, "CRC64NVME")) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-checksum-crc64nvme")) {
            if (operation != .put_object) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-checksum-mode")) {
            if ((operation != .get_object and operation != .head_object) or
                !std.ascii.eqlIgnoreCase(header.value, "ENABLED")) return true;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(header.name, "x-amz-checksum-")) return true;
        if ((operation == .get_object or operation == .head_object) and
            (std.ascii.eqlIgnoreCase(header.name, "if-match") or
                std.ascii.eqlIgnoreCase(header.name, "if-none-match") or
                std.ascii.eqlIgnoreCase(header.name, "if-modified-since") or
                std.ascii.eqlIgnoreCase(header.name, "if-unmodified-since")))
        {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "range") and operation != .get_object) {
            return true;
        }
        if (operation == .put_object and
            std.ascii.eqlIgnoreCase(header.name, "x-amz-copy-source"))
        {
            return true;
        }
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
) error{ InvalidDigest, UnsupportedChecksum }!?u64 {
    var algorithm: ?[]const u8 = null;
    var encoded: ?[]const u8 = null;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-amz-sdk-checksum-algorithm")) {
            if (algorithm != null) return error.InvalidDigest;
            algorithm = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-amz-checksum-crc64nvme")) {
            if (encoded != null) return error.InvalidDigest;
            encoded = header.value;
        }
    }
    if (algorithm) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "CRC64NVME")) return error.UnsupportedChecksum;
        if (encoded == null) return error.InvalidDigest;
    }
    const value = encoded orelse return null;
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(value) catch {
        return error.InvalidDigest;
    };
    if (decoded_size != 8) return error.InvalidDigest;
    var digest: [8]u8 = undefined;
    std.base64.standard.Decoder.decode(&digest, value) catch return error.InvalidDigest;
    return std.mem.readInt(u64, &digest, .big);
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

    fn interface(self: *HttpSource) byte_stream.Source {
        return .{ .context = self, .vtable = &.{ .read = read } };
    }

    fn read(context: *anyopaque, buffer: []u8) byte_stream.Source.Error!usize {
        const self: *HttpSource = @ptrCast(@alignCast(context));
        return self.reader.readSliceShort(buffer) catch return error.ReadFailed;
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
    etag: [34]u8,
    last_modified: [29]u8,
    content_length: [20]u8,
    content_length_length: usize,
    content_range: [64]u8,
    content_range_length: usize,
    include_content_length: bool,

    fn init(
        allocator: std.mem.Allocator,
        object: *const object_domain.Object,
        include_content_length: bool,
        range: ?ByteRange,
    ) !ObjectResponseHeaders {
        var result: ObjectResponseHeaders = .{
            .headers = undefined,
            .owned_names = undefined,
            .etag = undefined,
            .last_modified = undefined,
            .content_length = undefined,
            .content_length_length = 0,
            .content_range = undefined,
            .content_range_length = 0,
            .include_content_length = include_content_length,
        };
        _ = formatEtag(object.etag_md5, &result.etag);
        _ = time.formatHttpDate(object.last_modified_unix_seconds, &result.last_modified) catch {
            return error.InvalidTimestamp;
        };
        const response_size = if (range) |value| value.length else object.size;
        const content_length = std.fmt.bufPrint(&result.content_length, "{d}", .{response_size}) catch {
            return error.NoSpaceLeft;
        };
        result.content_length_length = content_length.len;
        if (range) |value| {
            const content_range = std.fmt.bufPrint(
                &result.content_range,
                "bytes {d}-{d}/{d}",
                .{ value.start, value.end, object.size },
            ) catch return error.NoSpaceLeft;
            result.content_range_length = content_range.len;
        }
        const fixed_count: usize = 6 +
            @as(usize, @intFromBool(include_content_length)) +
            @as(usize, @intFromBool(range != null));
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
        self.headers[index] = .{ .name = "etag", .value = &self.etag };
        index += 1;
        self.headers[index] = .{ .name = "last-modified", .value = &self.last_modified };
        index += 1;
        self.headers[index] = .{ .name = "x-amz-request-id", .value = request_id };
        index += 1;
        self.headers[index] = .{ .name = "x-request-id", .value = request_id };
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
        var etag: [34]u8 = undefined;
        writer.print("</LastModified><ETag>{s}</ETag><Size>{d}</Size><StorageClass>STANDARD</StorageClass>", .{
            formatEtag(object.etag_md5, &etag),
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
    if (additional_headers.len > headers.len - 4) return error.OutOfMemory;
    headers[0] = .{ .name = "content-type", .value = "application/xml" };
    headers[1] = .{ .name = "cache-control", .value = "no-store" };
    headers[2] = .{ .name = "x-amz-request-id", .value = request_id };
    headers[3] = .{ .name = "x-request-id", .value = request_id };
    @memcpy(headers[4..][0..additional_headers.len], additional_headers);
    try request.respond(body, .{
        .status = status,
        .extra_headers = headers[0 .. 4 + additional_headers.len],
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
    if (additional_headers.len > headers.len - 3) return error.OutOfMemory;
    headers[0] = .{ .name = "cache-control", .value = "no-store" };
    headers[1] = .{ .name = "x-amz-request-id", .value = request_id };
    headers[2] = .{ .name = "x-request-id", .value = request_id };
    @memcpy(headers[3..][0..additional_headers.len], additional_headers);
    try request.respond("", .{
        .status = status,
        .extra_headers = headers[0 .. 3 + additional_headers.len],
    });
    return status;
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
        else => .invalid_request,
    };
}

fn mapPresignedParseError(err: sigv4.Error) protocol.ErrorKind {
    return switch (err) {
        error.OutOfMemory => .internal_error,
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
        else => .invalid_request,
    };
}

fn mapCredentialError(err: credential_service.Error) protocol.ErrorKind {
    return switch (err) {
        error.InvalidAccessKey, error.CredentialNotFound => .invalid_access_key_id,
        error.CredentialDisabled => .access_denied,
        error.OutOfMemory,
        error.Conflict,
        error.CorruptMetadata,
        error.SecretDecryptionFailed,
        error.Unavailable,
        error.InvalidOwner,
        => .internal_error,
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
        error.InputReadFailed,
        error.InvalidRange,
        => .invalid_request,
        error.BucketNotFound => .no_such_bucket,
        error.ObjectNotFound => .no_such_key,
        error.ChecksumMismatch => .bad_digest,
        error.Unavailable => .service_unavailable,
        error.OutOfMemory,
        error.OutputWriteFailed,
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
    try std.testing.expectEqual(credential_domain.Action.put_object, actionFor(.put_object).?);
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
        .value = "SHA256",
    }};
    try std.testing.expectError(error.UnsupportedChecksum, parseCrc64Nvme(&unsupported));
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

    const streaming = [_]sigv4.Header{.{
        .name = "x-amz-content-sha256",
        .value = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
    }};
    try std.testing.expect(!hasUnsupportedHeaders(.put_object, &streaming));
    try std.testing.expect(hasUnsupportedHeaders(.get_object, &streaming));
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
