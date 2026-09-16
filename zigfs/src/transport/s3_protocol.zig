const std = @import("std");
const time = @import("../common/time.zig");

pub const Operation = enum {
    list_buckets,
    create_bucket,
    head_bucket,
    get_bucket_location,
    get_bucket_versioning,
    put_bucket_versioning,
    get_bucket_lifecycle,
    put_bucket_lifecycle,
    delete_bucket_lifecycle,
    delete_bucket,
    delete_objects,
    list_objects_v2,
    list_object_versions,
    list_multipart_uploads,
    put_object,
    get_object,
    head_object,
    delete_object,
    create_multipart_upload,
    upload_part,
    list_parts,
    complete_multipart_upload,
    abort_multipart_upload,
    post_policy_upload,
    unsupported,
};

pub const ParsedTarget = struct {
    allocator: std.mem.Allocator,
    decoded_path: []u8,
    parameters: []QueryParameter,
    bucket: ?[]const u8,
    key: ?[]const u8,
    addressing_style: AddressingStyle,
    operation: Operation,

    pub fn deinit(self: ParsedTarget) void {
        self.allocator.free(self.decoded_path);
        for (self.parameters) |parameter| {
            self.allocator.free(parameter.name);
            self.allocator.free(parameter.value);
        }
        self.allocator.free(self.parameters);
    }

    pub fn query(self: ParsedTarget, name: []const u8) error{DuplicateQueryParameter}!?[]const u8 {
        var value: ?[]const u8 = null;
        for (self.parameters) |parameter| {
            if (!std.mem.eql(u8, parameter.name, name)) continue;
            if (value != null) return error.DuplicateQueryParameter;
            value = parameter.value;
        }
        return value;
    }
};

pub const AddressingStyle = enum {
    path,
    virtual_hosted,
};

pub const QueryParameter = struct {
    name: []u8,
    value: []u8,
};

pub const ParseError = error{
    OutOfMemory,
    InvalidTarget,
};

pub const AddressingError = error{
    InvalidHost,
    HostNotAllowed,
};

pub fn parseTarget(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    target: []const u8,
) ParseError!ParsedTarget {
    return parseTargetWithHost(allocator, method, target, null, "", false) catch |err| switch (err) {
        error.InvalidHost, error.HostNotAllowed => unreachable,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidTarget => error.InvalidTarget,
    };
}

pub fn parseTargetWithHost(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    target: []const u8,
    host: ?[]const u8,
    public_endpoint: []const u8,
    virtual_hosted_style: bool,
) (ParseError || AddressingError)!ParsedTarget {
    if (target.len == 0 or target[0] != '/' or std.mem.indexOfScalar(u8, target, '#') != null) {
        return error.InvalidTarget;
    }
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    var decoded_path = try strictPercentDecode(allocator, target[0..query_start]);
    errdefer allocator.free(decoded_path);
    if (std.mem.indexOfScalar(u8, decoded_path, 0) != null) return error.InvalidTarget;
    const parameters = try parseQuery(
        allocator,
        if (query_start < target.len) target[query_start + 1 ..] else "",
    );
    errdefer {
        for (parameters) |parameter| {
            allocator.free(parameter.name);
            allocator.free(parameter.value);
        }
        allocator.free(parameters);
    }

    var addressing_style: AddressingStyle = .path;
    var bucket: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    if (virtual_hosted_style) {
        const request_host = host orelse return error.InvalidHost;
        const endpoint_authority = publicEndpointAuthority(public_endpoint) orelse {
            return error.InvalidHost;
        };
        const host_style = classifyHost(request_host, endpoint_authority) orelse {
            return error.HostNotAllowed;
        };
        addressing_style = host_style.style;
        if (host_style.style == .virtual_hosted) {
            bucket = host_style.bucket;
            const bucket_len = bucket.?.len;
            const without_leading_slash = decoded_path[1..];
            key = if (without_leading_slash.len == 0) null else without_leading_slash;
            const normalized_path = try normalizedVirtualPath(
                allocator,
                bucket.?,
                key,
            );
            allocator.free(decoded_path);
            decoded_path = normalized_path;
            bucket = decoded_path[1 .. bucket_len + 1];
            const key_start = bucket_len + 2;
            key = if (decoded_path.len > key_start) decoded_path[key_start..] else null;
        } else {
            const without_leading_slash = decoded_path[1..];
            const first_slash = std.mem.indexOfScalar(u8, without_leading_slash, '/');
            bucket = if (without_leading_slash.len == 0)
                null
            else if (first_slash) |position|
                without_leading_slash[0..position]
            else
                without_leading_slash;
            key = if (first_slash) |position|
                if (position + 1 < without_leading_slash.len)
                    without_leading_slash[position + 1 ..]
                else
                    null
            else
                null;
        }
    } else {
        const without_leading_slash = decoded_path[1..];
        const first_slash = std.mem.indexOfScalar(u8, without_leading_slash, '/');
        bucket = if (without_leading_slash.len == 0)
            null
        else if (first_slash) |position|
            without_leading_slash[0..position]
        else
            without_leading_slash;
        key = if (first_slash) |position|
            if (position + 1 < without_leading_slash.len)
                without_leading_slash[position + 1 ..]
            else
                null
        else
            null;
    }
    const operation = classify(method, bucket, key, parameters);
    return .{
        .allocator = allocator,
        .decoded_path = decoded_path,
        .parameters = parameters,
        .bucket = bucket,
        .key = key,
        .addressing_style = addressing_style,
        .operation = operation,
    };
}

const HostStyle = struct {
    style: AddressingStyle,
    bucket: ?[]const u8 = null,
};

fn publicEndpointAuthority(endpoint: []const u8) ?[]const u8 {
    const authority = if (std.mem.startsWith(u8, endpoint, "http://"))
        endpoint["http://".len..]
    else if (std.mem.startsWith(u8, endpoint, "https://"))
        endpoint["https://".len..]
    else
        return null;
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#@") != null) return null;
    return authority;
}

fn classifyHost(host: []const u8, endpoint_authority: []const u8) ?HostStyle {
    if (host.len == 0 or host[host.len - 1] == '.') return null;
    if (std.ascii.eqlIgnoreCase(host, endpoint_authority)) return .{ .style = .path };
    if (endpoint_authority.len > std.math.maxInt(usize) - 1) return null;
    const suffix_len = endpoint_authority.len + 1;
    if (host.len <= suffix_len or !std.ascii.eqlIgnoreCase(host[host.len - endpoint_authority.len ..], endpoint_authority)) {
        return null;
    }
    const separator = host.len - endpoint_authority.len - 1;
    if (host[separator] != '.') return null;
    const bucket = host[0..separator];
    if (bucket.len == 0 or std.mem.indexOfScalar(u8, bucket, ':') != null) return null;
    return .{ .style = .virtual_hosted, .bucket = bucket };
}

fn normalizedVirtualPath(
    allocator: std.mem.Allocator,
    bucket: []const u8,
    key: ?[]const u8,
) ParseError![]u8 {
    return if (key) |value|
        std.fmt.allocPrint(allocator, "/{s}/{s}", .{ bucket, value }) catch error.OutOfMemory
    else
        std.fmt.allocPrint(allocator, "/{s}", .{bucket}) catch error.OutOfMemory;
}

fn classify(
    method: std.http.Method,
    bucket: ?[]const u8,
    key: ?[]const u8,
    parameters: []const QueryParameter,
) Operation {
    if (bucket == null) return if (method == .GET) .list_buckets else .unsupported;
    if (key == null) {
        return switch (method) {
            .PUT => if (parameters.len == 0)
                .create_bucket
            else if (queryShape(parameters, "versioning") == .empty and parameters.len == 1)
                .put_bucket_versioning
            else if (queryShape(parameters, "lifecycle") == .empty and parameters.len == 1)
                .put_bucket_lifecycle
            else
                .unsupported,
            .HEAD => .head_bucket,
            .DELETE => if (parameters.len == 0)
                .delete_bucket
            else if (queryShape(parameters, "lifecycle") == .empty and parameters.len == 1)
                .delete_bucket_lifecycle
            else
                .unsupported,
            .POST => if (hasQueryValue(parameters, "delete", ""))
                .delete_objects
            else if (parameters.len == 0)
                .post_policy_upload
            else
                .unsupported,
            .GET => if (queryShape(parameters, "uploads") == .empty)
                .list_multipart_uploads
            else if (queryShape(parameters, "versions") == .empty)
                .list_object_versions
            else if (hasQueryValue(parameters, "list-type", "2"))
                .list_objects_v2
            else if (hasQueryValue(parameters, "location", ""))
                .get_bucket_location
            else if (queryShape(parameters, "versioning") == .empty and parameters.len == 1)
                .get_bucket_versioning
            else if (queryShape(parameters, "lifecycle") == .empty and parameters.len == 1)
                .get_bucket_lifecycle
            else
                .unsupported,
            else => .unsupported,
        };
    }
    const uploads = queryShape(parameters, "uploads");
    const upload_id = queryShape(parameters, "uploadId");
    const part_number = queryShape(parameters, "partNumber");
    if (uploads != .missing or upload_id != .missing or part_number != .missing) {
        if (method == .POST and uploads == .empty and upload_id == .missing and part_number == .missing) {
            return .create_multipart_upload;
        }
        if (method == .PUT and uploads == .missing and upload_id == .non_empty and part_number == .non_empty) {
            return .upload_part;
        }
        if (method == .GET and uploads == .missing and upload_id == .non_empty and part_number == .missing) {
            return .list_parts;
        }
        if (method == .POST and uploads == .missing and upload_id == .non_empty and part_number == .missing) {
            return .complete_multipart_upload;
        }
        if (method == .DELETE and uploads == .missing and upload_id == .non_empty and part_number == .missing) {
            return .abort_multipart_upload;
        }
        return .unsupported;
    }
    return switch (method) {
        .PUT => .put_object,
        .GET => .get_object,
        .HEAD => .head_object,
        .DELETE => .delete_object,
        else => .unsupported,
    };
}

const QueryShape = enum { missing, empty, non_empty, duplicate };

fn queryShape(parameters: []const QueryParameter, name: []const u8) QueryShape {
    var result: QueryShape = .missing;
    for (parameters) |parameter| {
        if (!std.mem.eql(u8, parameter.name, name)) continue;
        if (result != .missing) return .duplicate;
        result = if (parameter.value.len == 0) .empty else .non_empty;
    }
    return result;
}

fn hasQueryValue(
    parameters: []const QueryParameter,
    name: []const u8,
    value: []const u8,
) bool {
    for (parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, name) and
            std.mem.eql(u8, parameter.value, value)) return true;
    }
    return false;
}

fn parseQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
) ParseError![]QueryParameter {
    if (query.len == 0) return allocator.alloc(QueryParameter, 0) catch error.OutOfMemory;
    var parameters: std.ArrayList(QueryParameter) = .empty;
    errdefer {
        for (parameters.items) |parameter| {
            allocator.free(parameter.name);
            allocator.free(parameter.value);
        }
        parameters.deinit(allocator);
    }
    var iterator = std.mem.splitScalar(u8, query, '&');
    while (iterator.next()) |raw_parameter| {
        const equals = std.mem.indexOfScalar(u8, raw_parameter, '=');
        const raw_name = if (equals) |position| raw_parameter[0..position] else raw_parameter;
        const raw_value = if (equals) |position| raw_parameter[position + 1 ..] else "";
        const name = try strictPercentDecode(allocator, raw_name);
        errdefer allocator.free(name);
        const value = try strictPercentDecode(allocator, raw_value);
        parameters.append(allocator, .{ .name = name, .value = value }) catch {
            allocator.free(value);
            return error.OutOfMemory;
        };
    }
    return parameters.toOwnedSlice(allocator) catch error.OutOfMemory;
}

pub fn strictPercentDecode(
    allocator: std.mem.Allocator,
    value: []const u8,
) ParseError![]u8 {
    const output = allocator.alloc(u8, value.len) catch return error.OutOfMemory;
    errdefer allocator.free(output);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < value.len) {
        if (value[input_index] == '%') {
            if (value.len - input_index < 3) return error.InvalidTarget;
            output[output_index] = decodeHexByte(
                value[input_index + 1],
                value[input_index + 2],
            ) orelse return error.InvalidTarget;
            input_index += 3;
        } else {
            output[output_index] = value[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return allocator.realloc(output, output_index) catch return error.OutOfMemory;
}

fn decodeHexByte(high: u8, low: u8) ?u8 {
    const high_value = hexValue(high) orelse return null;
    const low_value = hexValue(low) orelse return null;
    return (high_value << 4) | low_value;
}

fn hexValue(character: u8) ?u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'a'...'f' => character - 'a' + 10,
        'A'...'F' => character - 'A' + 10,
        else => null,
    };
}

pub const ErrorKind = enum {
    access_denied,
    invalid_access_key_id,
    signature_does_not_match,
    authorization_header_malformed,
    authorization_query_parameters_error,
    request_time_too_skewed,
    request_expired,
    expired_token,
    invalid_token,
    no_such_bucket,
    no_such_key,
    no_such_version,
    no_such_lifecycle_configuration,
    bucket_already_exists,
    bucket_already_owned_by_you,
    bucket_not_empty,
    directory_not_empty,
    invalid_bucket_name,
    invalid_request,
    invalid_argument,
    invalid_location_constraint,
    malformed_xml,
    invalid_digest,
    bad_digest,
    x_amz_content_sha256_mismatch,
    invalid_range,
    not_modified,
    precondition_failed,
    method_not_allowed,
    no_such_upload,
    invalid_part,
    invalid_part_order,
    entity_too_small,
    entity_too_large,
    not_implemented,
    service_unavailable,
    internal_error,
};

pub const ErrorDescriptor = struct {
    code: []const u8,
    message: []const u8,
    status: std.http.Status,
};

pub fn describe(kind: ErrorKind) ErrorDescriptor {
    return switch (kind) {
        .access_denied => .{ .code = "AccessDenied", .message = "Access Denied.", .status = .forbidden },
        .invalid_access_key_id => .{ .code = "InvalidAccessKeyId", .message = "The AWS access key ID you provided does not exist in our records.", .status = .forbidden },
        .signature_does_not_match => .{ .code = "SignatureDoesNotMatch", .message = "The request signature we calculated does not match the signature you provided.", .status = .forbidden },
        .authorization_header_malformed => .{ .code = "AuthorizationHeaderMalformed", .message = "The authorization header is malformed.", .status = .bad_request },
        .authorization_query_parameters_error => .{ .code = "AuthorizationQueryParametersError", .message = "The query string authentication parameters are malformed or invalid.", .status = .bad_request },
        .request_time_too_skewed => .{ .code = "RequestTimeTooSkewed", .message = "The difference between the request time and the server's time is too large.", .status = .forbidden },
        .request_expired => .{ .code = "AccessDenied", .message = "Request has expired.", .status = .forbidden },
        .expired_token => .{ .code = "ExpiredToken", .message = "The provided token has expired.", .status = .forbidden },
        .invalid_token => .{ .code = "InvalidToken", .message = "The provided token is malformed or otherwise invalid.", .status = .forbidden },
        .no_such_bucket => .{ .code = "NoSuchBucket", .message = "The specified bucket does not exist.", .status = .not_found },
        .no_such_key => .{ .code = "NoSuchKey", .message = "The specified key does not exist.", .status = .not_found },
        .no_such_version => .{ .code = "NoSuchVersion", .message = "The specified version does not exist.", .status = .not_found },
        .no_such_lifecycle_configuration => .{ .code = "NoSuchLifecycleConfiguration", .message = "The lifecycle configuration does not exist.", .status = .not_found },
        .bucket_already_exists => .{ .code = "BucketAlreadyExists", .message = "The requested bucket name is not available.", .status = .conflict },
        .bucket_already_owned_by_you => .{ .code = "BucketAlreadyOwnedByYou", .message = "Your previous request to create the named bucket succeeded and you already own it.", .status = .conflict },
        .bucket_not_empty => .{ .code = "BucketNotEmpty", .message = "The bucket you tried to delete is not empty.", .status = .conflict },
        .directory_not_empty => .{ .code = "DirectoryNotEmpty", .message = "The directory you tried to delete is not empty.", .status = .conflict },
        .invalid_bucket_name => .{ .code = "InvalidBucketName", .message = "The specified bucket is not valid.", .status = .bad_request },
        .invalid_request => .{ .code = "InvalidRequest", .message = "The request is invalid.", .status = .bad_request },
        .invalid_argument => .{ .code = "InvalidArgument", .message = "Invalid Argument.", .status = .bad_request },
        .invalid_location_constraint => .{ .code = "InvalidLocationConstraint", .message = "The specified location constraint is not valid.", .status = .bad_request },
        .malformed_xml => .{ .code = "MalformedXML", .message = "The XML you provided was not well-formed or did not validate against our published schema.", .status = .bad_request },
        .invalid_digest => .{ .code = "InvalidDigest", .message = "The Content-MD5 you specified is not valid.", .status = .bad_request },
        .bad_digest => .{ .code = "BadDigest", .message = "The checksum you specified did not match what we received.", .status = .bad_request },
        .x_amz_content_sha256_mismatch => .{ .code = "XAmzContentSHA256Mismatch", .message = "The provided x-amz-content-sha256 does not match what was computed.", .status = .bad_request },
        .invalid_range => .{ .code = "InvalidRange", .message = "The requested range is not satisfiable.", .status = .range_not_satisfiable },
        .not_modified => .{ .code = "NotModified", .message = "Not Modified.", .status = .not_modified },
        .precondition_failed => .{ .code = "PreconditionFailed", .message = "At least one of the preconditions you specified did not hold.", .status = .precondition_failed },
        .method_not_allowed => .{ .code = "MethodNotAllowed", .message = "The specified method is not allowed against this resource.", .status = .method_not_allowed },
        .no_such_upload => .{ .code = "NoSuchUpload", .message = "The specified multipart upload does not exist.", .status = .not_found },
        .invalid_part => .{ .code = "InvalidPart", .message = "One or more of the specified parts could not be found or did not match the provided ETag.", .status = .bad_request },
        .invalid_part_order => .{ .code = "InvalidPartOrder", .message = "The list of parts was not in ascending order.", .status = .bad_request },
        .entity_too_small => .{ .code = "EntityTooSmall", .message = "Your proposed upload is smaller than the minimum allowed object size.", .status = .bad_request },
        .entity_too_large => .{ .code = "EntityTooLarge", .message = "Your proposed upload exceeds the maximum allowed size.", .status = .bad_request },
        .not_implemented => .{ .code = "NotImplemented", .message = "A header or operation you provided implies functionality that is not implemented.", .status = .not_implemented },
        .service_unavailable => .{ .code = "ServiceUnavailable", .message = "Please reduce your request rate.", .status = .service_unavailable },
        .internal_error => .{ .code = "InternalError", .message = "We encountered an internal error. Please try again.", .status = .internal_server_error },
    };
}

pub fn errorXml(
    allocator: std.mem.Allocator,
    kind: ErrorKind,
    resource: []const u8,
    request_id: []const u8,
) error{OutOfMemory}![]u8 {
    const descriptor = describe(kind);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.print(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>{s}</Code><Message>{s}</Message><Resource>",
        .{ descriptor.code, descriptor.message },
    ) catch return error.OutOfMemory;
    writeXmlEscaped(writer, resource) catch return error.OutOfMemory;
    writer.writeAll("</Resource><RequestId>") catch return error.OutOfMemory;
    writeXmlEscaped(writer, request_id) catch return error.OutOfMemory;
    writer.writeAll("</RequestId></Error>\n") catch return error.OutOfMemory;
    return output.toOwnedSlice() catch error.OutOfMemory;
}

pub fn writeXmlEscaped(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |character| switch (character) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '\'' => try writer.writeAll("&apos;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(character),
    };
}

pub fn writeIsoTime(
    writer: *std.Io.Writer,
    unix_seconds: i64,
) std.Io.Writer.Error!void {
    var buffer: [20]u8 = undefined;
    const value = time.formatIso8601(unix_seconds, &buffer) catch return error.WriteFailed;
    try writer.writeAll(value);
}

test "S3 target parsing separates path-style buckets objects and List V2" {
    const bucket = try parseTarget(std.testing.allocator, .PUT, "/project-assets");
    defer bucket.deinit();
    try std.testing.expectEqual(.create_bucket, bucket.operation);
    try std.testing.expectEqualStrings("project-assets", bucket.bucket.?);

    const object = try parseTarget(std.testing.allocator, .GET, "/project-assets/photos%2Fcover.jpg");
    defer object.deinit();
    try std.testing.expectEqual(.get_object, object.operation);
    try std.testing.expectEqualStrings("photos/cover.jpg", object.key.?);

    const list = try parseTarget(std.testing.allocator, .GET, "/project-assets?list-type=2&prefix=photos%2F");
    defer list.deinit();
    try std.testing.expectEqual(.list_objects_v2, list.operation);
    try std.testing.expectEqualStrings("photos/", (try list.query("prefix")).?);

    const multipart_uploads = try parseTarget(std.testing.allocator, .GET, "/project-assets?uploads=&prefix=photos%2F");
    defer multipart_uploads.deinit();
    try std.testing.expectEqual(.list_multipart_uploads, multipart_uploads.operation);

    const location = try parseTarget(std.testing.allocator, .GET, "/project-assets?location=");
    defer location.deinit();
    try std.testing.expectEqual(.get_bucket_location, location.operation);

    const get_versioning = try parseTarget(std.testing.allocator, .GET, "/project-assets?versioning=");
    defer get_versioning.deinit();
    try std.testing.expectEqual(.get_bucket_versioning, get_versioning.operation);

    const put_versioning = try parseTarget(std.testing.allocator, .PUT, "/project-assets?versioning=");
    defer put_versioning.deinit();
    try std.testing.expectEqual(.put_bucket_versioning, put_versioning.operation);

    const get_lifecycle = try parseTarget(std.testing.allocator, .GET, "/project-assets?lifecycle=");
    defer get_lifecycle.deinit();
    try std.testing.expectEqual(.get_bucket_lifecycle, get_lifecycle.operation);

    const list_versions = try parseTarget(std.testing.allocator, .GET, "/project-assets?versions=&prefix=photos%2F");
    defer list_versions.deinit();
    try std.testing.expectEqual(.list_object_versions, list_versions.operation);

    const object_version = try parseTarget(std.testing.allocator, .GET, "/project-assets/photos%2Fcover.jpg?versionId=null");
    defer object_version.deinit();
    try std.testing.expectEqual(.get_object, object_version.operation);
    try std.testing.expectEqualStrings("null", (try object_version.query("versionId")).?);

    const delete_objects = try parseTarget(std.testing.allocator, .POST, "/project-assets?delete=");
    defer delete_objects.deinit();
    try std.testing.expectEqual(.delete_objects, delete_objects.operation);

    const post_policy = try parseTarget(std.testing.allocator, .POST, "/project-assets");
    defer post_policy.deinit();
    try std.testing.expectEqual(.post_policy_upload, post_policy.operation);

    const create_multipart = try parseTarget(std.testing.allocator, .POST, "/project-assets/large.bin?uploads");
    defer create_multipart.deinit();
    try std.testing.expectEqual(.create_multipart_upload, create_multipart.operation);

    const upload_part = try parseTarget(std.testing.allocator, .PUT, "/project-assets/large.bin?partNumber=1&uploadId=opaque");
    defer upload_part.deinit();
    try std.testing.expectEqual(.upload_part, upload_part.operation);

    const complete = try parseTarget(std.testing.allocator, .POST, "/project-assets/large.bin?uploadId=opaque");
    defer complete.deinit();
    try std.testing.expectEqual(.complete_multipart_upload, complete.operation);
}

test "S3 target parsing supports configured virtual-hosted style" {
    const object = try parseTargetWithHost(
        std.testing.allocator,
        .GET,
        "/photos/cover.jpg",
        "project-assets.objects.example.test:9000",
        "http://objects.example.test:9000",
        true,
    );
    defer object.deinit();
    try std.testing.expectEqual(.virtual_hosted, object.addressing_style);
    try std.testing.expectEqualStrings("project-assets", object.bucket.?);
    try std.testing.expectEqualStrings("photos/cover.jpg", object.key.?);
    try std.testing.expectEqualStrings("/project-assets/photos/cover.jpg", object.decoded_path);
    try std.testing.expectEqual(.get_object, object.operation);

    const bucket = try parseTargetWithHost(
        std.testing.allocator,
        .GET,
        "/?list-type=2",
        "project-assets.objects.example.test:9000",
        "https://objects.example.test:9000",
        true,
    );
    defer bucket.deinit();
    try std.testing.expectEqual(.virtual_hosted, bucket.addressing_style);
    try std.testing.expectEqualStrings("project-assets", bucket.bucket.?);
    try std.testing.expect(bucket.key == null);
    try std.testing.expectEqual(.list_objects_v2, bucket.operation);
    try std.testing.expectEqualStrings("/project-assets", bucket.decoded_path);
}

test "S3 virtual-hosted style rejects an authority outside the configured endpoint" {
    try std.testing.expectError(
        error.HostNotAllowed,
        parseTargetWithHost(
            std.testing.allocator,
            .GET,
            "/object.txt",
            "project-assets.other.example.test:9000",
            "http://objects.example.test:9000",
            true,
        ),
    );
}

test "S3 virtual-hosted style keeps the configured authority path-compatible" {
    const parsed = try parseTargetWithHost(
        std.testing.allocator,
        .GET,
        "/project-assets/object.txt",
        "objects.example.test:9000",
        "http://objects.example.test:9000",
        true,
    );
    defer parsed.deinit();
    try std.testing.expectEqual(.path, parsed.addressing_style);
    try std.testing.expectEqualStrings("project-assets", parsed.bucket.?);
    try std.testing.expectEqualStrings("object.txt", parsed.key.?);
}

test "S3 XML errors escape resources and expose stable request IDs" {
    const xml = try errorXml(
        std.testing.allocator,
        .no_such_key,
        "/bucket/a&b",
        "request-1",
    );
    defer std.testing.allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Code>NoSuchKey</Code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "/bucket/a&amp;b") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<RequestId>request-1</RequestId>") != null);
}
