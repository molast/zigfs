const std = @import("std");

pub const algorithm = "AWS4-HMAC-SHA256";
pub const terminal = "aws4_request";
pub const service = "s3";
pub const default_max_clock_skew_seconds: i64 = 15 * 60;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    headers: []const Header,
    now_unix_seconds: i64,
    expected_region: []const u8,
    max_clock_skew_seconds: i64 = default_max_clock_skew_seconds,
};

pub const PayloadHash = union(enum) {
    digest: [32]u8,
    unsigned,
    streaming,
};

pub const Authorization = struct {
    access_key: []const u8,
    scope_date: []const u8,
    region: []const u8,
    signed_headers: []const u8,
    signature: [32]u8,
};

pub const Error = error{
    OutOfMemory,
    MissingAuthorization,
    MalformedAuthorization,
    InvalidCredentialScope,
    MissingSignedHeader,
    InvalidSignedHeaders,
    InvalidPayloadHash,
    InvalidDate,
    RequestTimeTooSkewed,
    InvalidTarget,
    SignatureDoesNotMatch,
};

pub fn parseAuthorization(headers: []const Header) Error!Authorization {
    const value = findSingleHeader(headers, "authorization") catch |err| return switch (err) {
        error.MissingSignedHeader => error.MissingAuthorization,
        else => error.MalformedAuthorization,
    };
    if (!std.mem.startsWith(u8, value, algorithm ++ " ")) {
        return error.MalformedAuthorization;
    }
    const parameters = value[algorithm.len + 1 ..];
    var credential_value: ?[]const u8 = null;
    var signed_headers: ?[]const u8 = null;
    var signature_value: ?[]const u8 = null;
    var parameter_iterator = std.mem.splitScalar(u8, parameters, ',');
    while (parameter_iterator.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse {
            return error.MalformedAuthorization;
        };
        const name = parameter[0..equals];
        const item_value = parameter[equals + 1 ..];
        if (item_value.len == 0) return error.MalformedAuthorization;
        if (std.mem.eql(u8, name, "Credential")) {
            if (credential_value != null) return error.MalformedAuthorization;
            credential_value = item_value;
        } else if (std.mem.eql(u8, name, "SignedHeaders")) {
            if (signed_headers != null) return error.MalformedAuthorization;
            signed_headers = item_value;
        } else if (std.mem.eql(u8, name, "Signature")) {
            if (signature_value != null) return error.MalformedAuthorization;
            signature_value = item_value;
        } else {
            return error.MalformedAuthorization;
        }
    }

    var scope = std.mem.splitScalar(u8, credential_value orelse return error.MalformedAuthorization, '/');
    const access_key = scope.next() orelse return error.InvalidCredentialScope;
    const scope_date = scope.next() orelse return error.InvalidCredentialScope;
    const region = scope.next() orelse return error.InvalidCredentialScope;
    const scope_service = scope.next() orelse return error.InvalidCredentialScope;
    const scope_terminal = scope.next() orelse return error.InvalidCredentialScope;
    if (scope.next() != null or access_key.len == 0 or scope_date.len != 8 or
        region.len == 0 or !std.mem.eql(u8, scope_service, service) or
        !std.mem.eql(u8, scope_terminal, terminal))
    {
        return error.InvalidCredentialScope;
    }
    const signed = signed_headers orelse return error.MalformedAuthorization;
    try validateSignedHeaders(signed);
    var signature: [32]u8 = undefined;
    try decodeLowerHex(signature_value orelse return error.MalformedAuthorization, &signature);
    return .{
        .access_key = access_key,
        .scope_date = scope_date,
        .region = region,
        .signed_headers = signed,
        .signature = signature,
    };
}

pub fn verify(
    allocator: std.mem.Allocator,
    request: Request,
    authorization: Authorization,
    secret_key: []const u8,
) Error!void {
    if (!std.mem.eql(u8, authorization.region, request.expected_region)) {
        return error.InvalidCredentialScope;
    }
    try validateRequiredAmzHeaders(request.headers, authorization.signed_headers);
    const amz_date = try findSingleHeader(request.headers, "x-amz-date");
    const request_time = try parseAmzDate(amz_date);
    if (!std.mem.eql(u8, authorization.scope_date, amz_date[0..8])) {
        return error.InvalidCredentialScope;
    }
    const difference: i128 = @as(i128, request.now_unix_seconds) - request_time;
    const absolute_difference = if (difference < 0) -difference else difference;
    if (request.max_clock_skew_seconds < 0 or
        absolute_difference > request.max_clock_skew_seconds)
    {
        return error.RequestTimeTooSkewed;
    }

    const canonical = try canonicalRequest(allocator, request, authorization.signed_headers);
    defer allocator.free(canonical);
    var canonical_hash: [32]u8 = undefined;
    Sha256.hash(canonical, &canonical_hash, .{});
    const canonical_hash_hex = std.fmt.bytesToHex(canonical_hash, .lower);
    const scope = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/{s}",
        .{ authorization.scope_date, authorization.region, service, terminal },
    );
    defer allocator.free(scope);
    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n{s}",
        .{ algorithm, amz_date, scope, &canonical_hash_hex },
    );
    defer allocator.free(string_to_sign);

    var prefixed_secret: std.Io.Writer.Allocating = .init(allocator);
    defer prefixed_secret.deinit();
    prefixed_secret.writer.writeAll("AWS4") catch return error.OutOfMemory;
    prefixed_secret.writer.writeAll(secret_key) catch return error.OutOfMemory;
    var date_key: [32]u8 = undefined;
    HmacSha256.create(&date_key, authorization.scope_date, prefixed_secret.written());
    var region_key: [32]u8 = undefined;
    HmacSha256.create(&region_key, authorization.region, &date_key);
    var service_key: [32]u8 = undefined;
    HmacSha256.create(&service_key, service, &region_key);
    var signing_key: [32]u8 = undefined;
    HmacSha256.create(&signing_key, terminal, &service_key);
    defer {
        std.crypto.secureZero(u8, &date_key);
        std.crypto.secureZero(u8, &region_key);
        std.crypto.secureZero(u8, &service_key);
        std.crypto.secureZero(u8, &signing_key);
    }
    var expected_signature: [32]u8 = undefined;
    HmacSha256.create(&expected_signature, string_to_sign, &signing_key);
    if (!std.crypto.timing_safe.eql([32]u8, expected_signature, authorization.signature)) {
        return error.SignatureDoesNotMatch;
    }
}

fn validateRequiredAmzHeaders(
    headers: []const Header,
    signed_headers: []const u8,
) Error!void {
    for (headers) |header| {
        if (!std.ascii.startsWithIgnoreCase(header.name, "x-amz-") or
            std.ascii.eqlIgnoreCase(header.name, "x-amz-content-sha256"))
        {
            continue;
        }
        var signed = std.mem.splitScalar(u8, signed_headers, ';');
        var found = false;
        while (signed.next()) |name| {
            if (std.ascii.eqlIgnoreCase(name, header.name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingSignedHeader;
    }
}

pub fn requestPayloadHash(headers: []const Header) Error!PayloadHash {
    const value = try findSingleHeader(headers, "x-amz-content-sha256");
    if (std.mem.eql(u8, value, "UNSIGNED-PAYLOAD")) return .unsigned;
    if (std.mem.startsWith(u8, value, "STREAMING-")) return .streaming;
    var digest: [32]u8 = undefined;
    decodeLowerHex(value, &digest) catch return error.InvalidPayloadHash;
    return .{ .digest = digest };
}

fn canonicalRequest(
    allocator: std.mem.Allocator,
    request: Request,
    signed_headers: []const u8,
) Error![]u8 {
    if (request.method.len == 0 or std.mem.indexOfAny(u8, request.method, "\r\n") != null) {
        return error.InvalidTarget;
    }
    const path_end = std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len;
    const raw_path = request.target[0..path_end];
    if (raw_path.len == 0 or raw_path[0] != '/' or
        std.mem.indexOfScalar(u8, request.target, '#') != null)
    {
        return error.InvalidTarget;
    }
    const canonical_uri = try normalizeEncoded(allocator, raw_path, true);
    defer allocator.free(canonical_uri);
    const raw_query = if (path_end < request.target.len) request.target[path_end + 1 ..] else "";
    const canonical_query = try canonicalQuery(allocator, raw_query);
    defer allocator.free(canonical_query);
    _ = try requestPayloadHash(request.headers);
    const payload_hash_value = try findSingleHeader(request.headers, "x-amz-content-sha256");

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.print("{s}\n{s}\n{s}\n", .{
        request.method,
        canonical_uri,
        canonical_query,
    }) catch return error.OutOfMemory;
    var names = std.mem.splitScalar(u8, signed_headers, ';');
    while (names.next()) |name| {
        writer.print("{s}:", .{name}) catch return error.OutOfMemory;
        try writeCanonicalHeaderValue(writer, request.headers, name);
        writer.writeByte('\n') catch return error.OutOfMemory;
    }
    writer.writeByte('\n') catch return error.OutOfMemory;
    writer.print("{s}\n{s}", .{ signed_headers, payload_hash_value }) catch {
        return error.OutOfMemory;
    };
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

const QueryParameter = struct {
    name: []u8,
    value: []u8,
};

fn canonicalQuery(allocator: std.mem.Allocator, raw_query: []const u8) Error![]u8 {
    if (raw_query.len == 0) return allocator.dupe(u8, "") catch error.OutOfMemory;
    var parameters: std.ArrayList(QueryParameter) = .empty;
    defer {
        for (parameters.items) |parameter| {
            allocator.free(parameter.name);
            allocator.free(parameter.value);
        }
        parameters.deinit(allocator);
    }
    var iterator = std.mem.splitScalar(u8, raw_query, '&');
    while (iterator.next()) |raw_parameter| {
        const equals = std.mem.indexOfScalar(u8, raw_parameter, '=');
        const raw_name = if (equals) |position| raw_parameter[0..position] else raw_parameter;
        const raw_value = if (equals) |position| raw_parameter[position + 1 ..] else "";
        const name = try normalizeEncoded(allocator, raw_name, false);
        errdefer allocator.free(name);
        const value = try normalizeEncoded(allocator, raw_value, false);
        parameters.append(allocator, .{ .name = name, .value = value }) catch {
            allocator.free(value);
            return error.OutOfMemory;
        };
    }
    std.mem.sort(QueryParameter, parameters.items, {}, struct {
        fn lessThan(_: void, left: QueryParameter, right: QueryParameter) bool {
            const name_order = std.mem.order(u8, left.name, right.name);
            return name_order == .lt or
                (name_order == .eq and std.mem.order(u8, left.value, right.value) == .lt);
        }
    }.lessThan);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (parameters.items, 0..) |parameter, position| {
        if (position != 0) output.writer.writeByte('&') catch return error.OutOfMemory;
        output.writer.print("{s}={s}", .{ parameter.name, parameter.value }) catch {
            return error.OutOfMemory;
        };
    }
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

fn normalizeEncoded(
    allocator: std.mem.Allocator,
    input: []const u8,
    preserve_slash: bool,
) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var index: usize = 0;
    while (index < input.len) {
        const byte = if (input[index] == '%') decoded: {
            if (input.len - index < 3) return error.InvalidTarget;
            const decoded_byte = decodeHexByte(input[index + 1], input[index + 2]) orelse {
                return error.InvalidTarget;
            };
            index += 3;
            break :decoded decoded_byte;
        } else direct: {
            const direct_byte = input[index];
            index += 1;
            break :direct direct_byte;
        };
        if (isUnreserved(byte) or (preserve_slash and byte == '/')) {
            output.writer.writeByte(byte) catch return error.OutOfMemory;
        } else {
            output.writer.print("%{X:0>2}", .{byte}) catch return error.OutOfMemory;
        }
    }
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeCanonicalHeaderValue(
    writer: *std.Io.Writer,
    headers: []const Header,
    name: []const u8,
) Error!void {
    var found = false;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found) writer.writeByte(',') catch return error.OutOfMemory;
        found = true;
        const trimmed = std.mem.trim(u8, header.value, " \t");
        var whitespace = false;
        for (trimmed) |character| {
            if (character == ' ' or character == '\t') {
                whitespace = true;
            } else {
                if (whitespace) writer.writeByte(' ') catch return error.OutOfMemory;
                writer.writeByte(character) catch return error.OutOfMemory;
                whitespace = false;
            }
        }
    }
    if (!found) return error.MissingSignedHeader;
}

fn validateSignedHeaders(value: []const u8) Error!void {
    if (value.len == 0) return error.InvalidSignedHeaders;
    var has_host = false;
    var has_date = false;
    var previous: ?[]const u8 = null;
    var names = std.mem.splitScalar(u8, value, ';');
    while (names.next()) |name| {
        if (name.len == 0) return error.InvalidSignedHeaders;
        for (name) |character| {
            if (!std.ascii.isLower(character) and
                !std.ascii.isDigit(character) and
                character != '-')
            {
                return error.InvalidSignedHeaders;
            }
        }
        if (previous) |prior| {
            if (std.mem.order(u8, prior, name) != .lt) return error.InvalidSignedHeaders;
        }
        if (std.mem.eql(u8, name, "host")) has_host = true;
        if (std.mem.eql(u8, name, "x-amz-date")) has_date = true;
        previous = name;
    }
    if (!has_host or !has_date) return error.InvalidSignedHeaders;
}

fn findSingleHeader(headers: []const Header, name: []const u8) Error![]const u8 {
    var found: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found != null) return error.InvalidSignedHeaders;
        found = header.value;
    }
    return found orelse error.MissingSignedHeader;
}

fn decodeLowerHex(input: []const u8, output: []u8) Error!void {
    if (input.len != output.len * 2) return error.MalformedAuthorization;
    for (output, 0..) |*byte, index| {
        const high = lowerHexValue(input[index * 2]) orelse return error.MalformedAuthorization;
        const low = lowerHexValue(input[index * 2 + 1]) orelse return error.MalformedAuthorization;
        byte.* = (high << 4) | low;
    }
}

fn lowerHexValue(character: u8) ?u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'a'...'f' => character - 'a' + 10,
        else => null,
    };
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

fn isUnreserved(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or
        character == '-' or character == '_' or character == '.' or character == '~';
}

pub fn parseAmzDate(value: []const u8) Error!i64 {
    if (value.len != 16 or value[8] != 'T' or value[15] != 'Z') {
        return error.InvalidDate;
    }
    const year = parseDecimal(value[0..4]) orelse return error.InvalidDate;
    const month = parseDecimal(value[4..6]) orelse return error.InvalidDate;
    const day = parseDecimal(value[6..8]) orelse return error.InvalidDate;
    const hour = parseDecimal(value[9..11]) orelse return error.InvalidDate;
    const minute = parseDecimal(value[11..13]) orelse return error.InvalidDate;
    const second = parseDecimal(value[13..15]) orelse return error.InvalidDate;
    if (year < 1970 or year > 9999 or month < 1 or month > 12 or
        day < 1 or day > daysInMonth(year, month) or hour > 23 or
        minute > 59 or second > 59)
    {
        return error.InvalidDate;
    }
    const days = daysFromCivil(year, month, day);
    return days * 86_400 + hour * 3_600 + minute * 60 + second;
}

fn parseDecimal(value: []const u8) ?i64 {
    var result: i64 = 0;
    for (value) |character| {
        if (!std.ascii.isDigit(character)) return null;
        result = result * 10 + character - '0';
    }
    return result;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year_value: i64, month_value: i64, day: i64) i64 {
    const year = year_value - @intFromBool(month_value <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month_value + (if (month_value > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

test "Signature V4 verifies the AWS S3 published GET object example" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "Range", .value = "bytes=0-9" },
        .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
        .{ .name = "Authorization", .value = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=67fe34c8530db585abddc51067328adfedb6e42487d2566dc7d927d6e2722900" },
    };
    const auth = try parseAuthorization(&headers);
    try verify(std.testing.allocator, .{
        .method = "GET",
        .target = "/test.txt",
        .headers = &headers,
        .now_unix_seconds = 1_369_353_600,
        .expected_region = "us-east-1",
    }, auth, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
}

test "Signature V4 rejects signature changes scope changes and stale requests" {
    const headers = [_]Header{
        .{ .name = "host", .value = "localhost:9000" },
        .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
        .{ .name = "authorization", .value = "AWS4-HMAC-SHA256 Credential=ZF0123456789ABCDEF/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=0000000000000000000000000000000000000000000000000000000000000000" },
    };
    const auth = try parseAuthorization(&headers);
    try std.testing.expectError(error.SignatureDoesNotMatch, verify(
        std.testing.allocator,
        .{
            .method = "GET",
            .target = "/",
            .headers = &headers,
            .now_unix_seconds = 1_369_353_600,
            .expected_region = "us-east-1",
        },
        auth,
        "secret",
    ));
    try std.testing.expectError(error.InvalidCredentialScope, verify(
        std.testing.allocator,
        .{
            .method = "GET",
            .target = "/",
            .headers = &headers,
            .now_unix_seconds = 1_369_353_600,
            .expected_region = "eu-west-1",
        },
        auth,
        "secret",
    ));
    try std.testing.expectError(error.RequestTimeTooSkewed, verify(
        std.testing.allocator,
        .{
            .method = "GET",
            .target = "/",
            .headers = &headers,
            .now_unix_seconds = 1_369_353_600 + 901,
            .expected_region = "us-east-1",
        },
        auth,
        "secret",
    ));
}

test "canonical query normalization accepts empty values and percent encoding" {
    const canonical = try canonicalQuery(std.testing.allocator, "prefix=a%2Fb&list-type=2&delimiter=%2F&empty");
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "delimiter=%2F&empty=&list-type=2&prefix=a%2Fb",
        canonical,
    );
    try std.testing.expectEqual(@as(i64, 1_369_353_600), try parseAmzDate("20130524T000000Z"));
    try std.testing.expectError(error.InvalidDate, parseAmzDate("20130229T000000Z"));
}

test "streaming payload signatures remain distinguishable for protocol rejection" {
    try std.testing.expectEqual(
        PayloadHash.streaming,
        try requestPayloadHash(&.{.{
            .name = "x-amz-content-sha256",
            .value = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
        }}),
    );
}

test "Signature V4 requires x-amz extension headers to be signed" {
    const headers = [_]Header{
        .{ .name = "host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
        .{ .name = "x-amz-meta-owner", .value = "changed" },
        .{ .name = "authorization", .value = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=67fe34c8530db585abddc51067328adfedb6e42487d2566dc7d927d6e2722900" },
    };
    const auth = try parseAuthorization(&headers);
    try std.testing.expectError(error.MissingSignedHeader, verify(
        std.testing.allocator,
        .{
            .method = "GET",
            .target = "/test.txt",
            .headers = &headers,
            .now_unix_seconds = 1_369_353_600,
            .expected_region = "us-east-1",
        },
        auth,
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    ));
}
