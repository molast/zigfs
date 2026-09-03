const std = @import("std");
const time = @import("../common/time.zig");

pub const Operation = enum {
    list_buckets,
    create_bucket,
    head_bucket,
    delete_bucket,
    list_objects_v2,
    put_object,
    get_object,
    head_object,
    delete_object,
    unsupported,
};

pub const ParsedTarget = struct {
    allocator: std.mem.Allocator,
    decoded_path: []u8,
    parameters: []QueryParameter,
    bucket: ?[]const u8,
    key: ?[]const u8,
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

pub const QueryParameter = struct {
    name: []u8,
    value: []u8,
};

pub const ParseError = error{
    OutOfMemory,
    InvalidTarget,
};

pub fn parseTarget(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    target: []const u8,
) ParseError!ParsedTarget {
    if (target.len == 0 or target[0] != '/' or std.mem.indexOfScalar(u8, target, '#') != null) {
        return error.InvalidTarget;
    }
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const decoded_path = try strictPercentDecode(allocator, target[0..query_start]);
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

    const without_leading_slash = decoded_path[1..];
    const first_slash = std.mem.indexOfScalar(u8, without_leading_slash, '/');
    const bucket: ?[]const u8 = if (without_leading_slash.len == 0)
        null
    else if (first_slash) |position|
        without_leading_slash[0..position]
    else
        without_leading_slash;
    const key: ?[]const u8 = if (first_slash) |position|
        if (position + 1 < without_leading_slash.len)
            without_leading_slash[position + 1 ..]
        else
            null
    else
        null;
    const operation = classify(method, bucket, key, parameters);
    return .{
        .allocator = allocator,
        .decoded_path = decoded_path,
        .parameters = parameters,
        .bucket = bucket,
        .key = key,
        .operation = operation,
    };
}

fn classify(
    method: std.http.Method,
    bucket: ?[]const u8,
    key: ?[]const u8,
    parameters: []const QueryParameter,
) Operation {
    if (hasMultipartQuery(parameters)) return .unsupported;
    if (bucket == null) return if (method == .GET) .list_buckets else .unsupported;
    if (key == null) {
        return switch (method) {
            .PUT => .create_bucket,
            .HEAD => .head_bucket,
            .DELETE => .delete_bucket,
            .GET => if (hasQueryValue(parameters, "list-type", "2"))
                .list_objects_v2
            else
                .unsupported,
            else => .unsupported,
        };
    }
    return switch (method) {
        .PUT => .put_object,
        .GET => .get_object,
        .HEAD => .head_object,
        .DELETE => .delete_object,
        else => .unsupported,
    };
}

fn hasMultipartQuery(parameters: []const QueryParameter) bool {
    for (parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, "uploads") or
            std.mem.eql(u8, parameter.name, "uploadId") or
            std.mem.eql(u8, parameter.name, "partNumber"))
        {
            return true;
        }
    }
    return false;
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

fn strictPercentDecode(
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
    request_time_too_skewed,
    no_such_bucket,
    no_such_key,
    bucket_already_exists,
    bucket_already_owned_by_you,
    bucket_not_empty,
    invalid_bucket_name,
    invalid_request,
    invalid_argument,
    invalid_location_constraint,
    malformed_xml,
    invalid_digest,
    bad_digest,
    x_amz_content_sha256_mismatch,
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
        .request_time_too_skewed => .{ .code = "RequestTimeTooSkewed", .message = "The difference between the request time and the server's time is too large.", .status = .forbidden },
        .no_such_bucket => .{ .code = "NoSuchBucket", .message = "The specified bucket does not exist.", .status = .not_found },
        .no_such_key => .{ .code = "NoSuchKey", .message = "The specified key does not exist.", .status = .not_found },
        .bucket_already_exists => .{ .code = "BucketAlreadyExists", .message = "The requested bucket name is not available.", .status = .conflict },
        .bucket_already_owned_by_you => .{ .code = "BucketAlreadyOwnedByYou", .message = "Your previous request to create the named bucket succeeded and you already own it.", .status = .conflict },
        .bucket_not_empty => .{ .code = "BucketNotEmpty", .message = "The bucket you tried to delete is not empty.", .status = .conflict },
        .invalid_bucket_name => .{ .code = "InvalidBucketName", .message = "The specified bucket is not valid.", .status = .bad_request },
        .invalid_request => .{ .code = "InvalidRequest", .message = "The request is invalid.", .status = .bad_request },
        .invalid_argument => .{ .code = "InvalidArgument", .message = "Invalid Argument.", .status = .bad_request },
        .invalid_location_constraint => .{ .code = "InvalidLocationConstraint", .message = "The specified location constraint is not valid.", .status = .bad_request },
        .malformed_xml => .{ .code = "MalformedXML", .message = "The XML you provided was not well-formed or did not validate against our published schema.", .status = .bad_request },
        .invalid_digest => .{ .code = "InvalidDigest", .message = "The Content-MD5 you specified is not valid.", .status = .bad_request },
        .bad_digest => .{ .code = "BadDigest", .message = "The Content-MD5 you specified did not match what we received.", .status = .bad_request },
        .x_amz_content_sha256_mismatch => .{ .code = "XAmzContentSHA256Mismatch", .message = "The provided x-amz-content-sha256 does not match what was computed.", .status = .bad_request },
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
