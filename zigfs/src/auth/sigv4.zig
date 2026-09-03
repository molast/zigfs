const std = @import("std");

pub const algorithm = "AWS4-HMAC-SHA256";
pub const streaming_payload = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD";
pub const streaming_trailer_payload = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER";
pub const streaming_algorithm = "AWS4-HMAC-SHA256-PAYLOAD";
pub const streaming_trailer_algorithm = "AWS4-HMAC-SHA256-TRAILER";
pub const terminal = "aws4_request";
pub const service = "s3";
pub const default_max_clock_skew_seconds: i64 = 15 * 60;
pub const max_presigned_expiry_seconds: u64 = 7 * 24 * 60 * 60;

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

pub const PresignedAuthorization = struct {
    allocator: std.mem.Allocator,
    credential_storage: []u8,
    signed_headers_storage: []u8,
    authorization: Authorization,
    amz_date: [16]u8,
    expires_seconds: u64,

    pub fn deinit(self: *PresignedAuthorization) void {
        self.allocator.free(self.credential_storage);
        self.allocator.free(self.signed_headers_storage);
        self.* = undefined;
    }
};

pub const PresignRequest = struct {
    method: []const u8,
    target: []const u8,
    headers: []const Header,
    access_key: []const u8,
    secret_key: []const u8,
    amz_date: []const u8,
    region: []const u8,
    expires_seconds: u64,
    signed_headers: []const u8 = "host",
};

const CredentialScope = struct {
    access_key: []const u8,
    scope_date: []const u8,
    region: []const u8,
};

pub const StreamingVerifier = struct {
    signing_key: [32]u8,
    previous_signature: [32]u8,
    amz_date: [16]u8,
    scope_buffer: [128]u8,
    scope_length: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        headers: []const Header,
        authorization: Authorization,
        secret_key: []const u8,
    ) Error!StreamingVerifier {
        const amz_date = try findSingleHeader(headers, "x-amz-date");
        if (amz_date.len != 16) return error.InvalidDate;
        var result: StreamingVerifier = .{
            .signing_key = try deriveSigningKey(
                allocator,
                authorization.scope_date,
                authorization.region,
                secret_key,
            ),
            .previous_signature = authorization.signature,
            .amz_date = undefined,
            .scope_buffer = undefined,
            .scope_length = 0,
        };
        @memcpy(&result.amz_date, amz_date);
        const scope = std.fmt.bufPrint(
            &result.scope_buffer,
            "{s}/{s}/{s}/{s}",
            .{ authorization.scope_date, authorization.region, service, terminal },
        ) catch return error.InvalidCredentialScope;
        result.scope_length = scope.len;
        return result;
    }

    pub fn deinit(self: *StreamingVerifier) void {
        std.crypto.secureZero(u8, &self.signing_key);
        std.crypto.secureZero(u8, &self.previous_signature);
        self.* = undefined;
    }

    pub fn verifyChunkHash(
        self: *StreamingVerifier,
        chunk_hash: [32]u8,
        signature_hex: []const u8,
    ) Error!void {
        var signature: [32]u8 = undefined;
        try decodeLowerHex(signature_hex, &signature);
        var empty_hash: [32]u8 = undefined;
        Sha256.hash("", &empty_hash, .{});
        const previous_hex = std.fmt.bytesToHex(self.previous_signature, .lower);
        const empty_hex = std.fmt.bytesToHex(empty_hash, .lower);
        const chunk_hex = std.fmt.bytesToHex(chunk_hash, .lower);
        var string_buffer: [512]u8 = undefined;
        const string_to_sign = std.fmt.bufPrint(
            &string_buffer,
            "{s}\n{s}\n{s}\n{s}\n{s}\n{s}",
            .{
                streaming_algorithm,
                &self.amz_date,
                self.scope_buffer[0..self.scope_length],
                &previous_hex,
                &empty_hex,
                &chunk_hex,
            },
        ) catch return error.InvalidPayloadHash;
        var expected_signature: [32]u8 = undefined;
        HmacSha256.create(&expected_signature, string_to_sign, &self.signing_key);
        if (!std.crypto.timing_safe.eql([32]u8, expected_signature, signature)) {
            return error.SignatureDoesNotMatch;
        }
        self.previous_signature = signature;
    }

    pub fn verifyTrailerHash(
        self: *StreamingVerifier,
        trailer_hash: [32]u8,
        signature_hex: []const u8,
    ) Error!void {
        var signature: [32]u8 = undefined;
        try decodeLowerHex(signature_hex, &signature);
        const previous_hex = std.fmt.bytesToHex(self.previous_signature, .lower);
        const trailer_hex = std.fmt.bytesToHex(trailer_hash, .lower);
        var string_buffer: [512]u8 = undefined;
        const string_to_sign = std.fmt.bufPrint(
            &string_buffer,
            "{s}\n{s}\n{s}\n{s}\n{s}",
            .{
                streaming_trailer_algorithm,
                &self.amz_date,
                self.scope_buffer[0..self.scope_length],
                &previous_hex,
                &trailer_hex,
            },
        ) catch return error.InvalidPayloadHash;
        var expected_signature: [32]u8 = undefined;
        HmacSha256.create(&expected_signature, string_to_sign, &self.signing_key);
        if (!std.crypto.timing_safe.eql([32]u8, expected_signature, signature)) {
            return error.SignatureDoesNotMatch;
        }
        self.previous_signature = signature;
    }
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
    InvalidExpires,
    RequestTimeTooSkewed,
    RequestExpired,
    InvalidTarget,
    MalformedPresignedQuery,
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

    const credential = try parseCredentialScope(
        credential_value orelse return error.MalformedAuthorization,
    );
    const signed = signed_headers orelse return error.MalformedAuthorization;
    try validateSignedHeaders(signed, true);
    var signature: [32]u8 = undefined;
    try decodeLowerHex(signature_value orelse return error.MalformedAuthorization, &signature);
    return .{
        .access_key = credential.access_key,
        .scope_date = credential.scope_date,
        .region = credential.region,
        .signed_headers = signed,
        .signature = signature,
    };
}

pub fn hasPresignedParameters(target: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse parameter.len;
        const name = parameter[0..equals];
        if (std.mem.eql(u8, name, "X-Amz-Algorithm") or
            std.mem.eql(u8, name, "X-Amz-Credential") or
            std.mem.eql(u8, name, "X-Amz-Date") or
            std.mem.eql(u8, name, "X-Amz-Expires") or
            std.mem.eql(u8, name, "X-Amz-SignedHeaders") or
            std.mem.eql(u8, name, "X-Amz-Signature"))
        {
            return true;
        }
    }
    return false;
}

pub fn parsePresignedAuthorization(
    allocator: std.mem.Allocator,
    target: []const u8,
) Error!PresignedAuthorization {
    const algorithm_value = try decodeRequiredQueryValue(allocator, target, "X-Amz-Algorithm");
    defer allocator.free(algorithm_value);
    if (!std.mem.eql(u8, algorithm_value, algorithm)) return error.MalformedPresignedQuery;

    const credential_storage = try decodeRequiredQueryValue(allocator, target, "X-Amz-Credential");
    errdefer allocator.free(credential_storage);
    const credential = parseCredentialScope(credential_storage) catch {
        return error.InvalidCredentialScope;
    };

    const date_value = try decodeRequiredQueryValue(allocator, target, "X-Amz-Date");
    defer allocator.free(date_value);
    _ = parseAmzDate(date_value) catch return error.InvalidDate;
    if (date_value.len != 16 or !std.mem.eql(u8, credential.scope_date, date_value[0..8])) {
        return error.InvalidCredentialScope;
    }
    var amz_date: [16]u8 = undefined;
    @memcpy(&amz_date, date_value);

    const expires_value = try decodeRequiredQueryValue(allocator, target, "X-Amz-Expires");
    defer allocator.free(expires_value);
    if (expires_value.len == 0) return error.InvalidExpires;
    for (expires_value) |character| {
        if (!std.ascii.isDigit(character)) return error.InvalidExpires;
    }
    const expires_seconds = std.fmt.parseInt(u64, expires_value, 10) catch {
        return error.InvalidExpires;
    };
    if (expires_seconds == 0 or expires_seconds > max_presigned_expiry_seconds) {
        return error.InvalidExpires;
    }

    const signed_headers_storage = try decodeRequiredQueryValue(
        allocator,
        target,
        "X-Amz-SignedHeaders",
    );
    errdefer allocator.free(signed_headers_storage);
    try validateSignedHeaders(signed_headers_storage, false);

    const signature_value = try decodeRequiredQueryValue(allocator, target, "X-Amz-Signature");
    defer allocator.free(signature_value);
    var signature: [32]u8 = undefined;
    decodeLowerHex(signature_value, &signature) catch return error.MalformedPresignedQuery;

    return .{
        .allocator = allocator,
        .credential_storage = credential_storage,
        .signed_headers_storage = signed_headers_storage,
        .authorization = .{
            .access_key = credential.access_key,
            .scope_date = credential.scope_date,
            .region = credential.region,
            .signed_headers = signed_headers_storage,
            .signature = signature,
        },
        .amz_date = amz_date,
        .expires_seconds = expires_seconds,
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

    var signing_key = try deriveSigningKey(
        allocator,
        authorization.scope_date,
        authorization.region,
        secret_key,
    );
    defer std.crypto.secureZero(u8, &signing_key);
    var expected_signature: [32]u8 = undefined;
    HmacSha256.create(&expected_signature, string_to_sign, &signing_key);
    if (!std.crypto.timing_safe.eql([32]u8, expected_signature, authorization.signature)) {
        return error.SignatureDoesNotMatch;
    }
}

pub fn verifyPresigned(
    allocator: std.mem.Allocator,
    request: Request,
    presigned: PresignedAuthorization,
    secret_key: []const u8,
) Error!void {
    const authorization = presigned.authorization;
    if (!std.mem.eql(u8, authorization.region, request.expected_region)) {
        return error.InvalidCredentialScope;
    }
    try validateRequiredAmzHeaders(request.headers, authorization.signed_headers);
    const request_time = try parseAmzDate(&presigned.amz_date);
    if (request.max_clock_skew_seconds < 0) return error.RequestTimeTooSkewed;
    const now: i128 = request.now_unix_seconds;
    const signed_at: i128 = request_time;
    if (signed_at - now > request.max_clock_skew_seconds) {
        return error.RequestTimeTooSkewed;
    }
    if (now > signed_at + presigned.expires_seconds) return error.RequestExpired;

    const canonical = try canonicalRequestWithPayload(
        allocator,
        request,
        authorization.signed_headers,
        "UNSIGNED-PAYLOAD",
        true,
    );
    defer allocator.free(canonical);
    const expected_signature = try calculateSignature(
        allocator,
        canonical,
        &presigned.amz_date,
        authorization.scope_date,
        authorization.region,
        secret_key,
    );
    if (!std.crypto.timing_safe.eql([32]u8, expected_signature, authorization.signature)) {
        return error.SignatureDoesNotMatch;
    }
}

pub fn presignTarget(
    allocator: std.mem.Allocator,
    request: PresignRequest,
) Error![]u8 {
    if ((!std.mem.eql(u8, request.method, "GET") and
        !std.mem.eql(u8, request.method, "PUT")) or
        hasPresignedParameters(request.target))
    {
        return error.InvalidTarget;
    }
    _ = try parseAmzDate(request.amz_date);
    if (request.expires_seconds == 0 or
        request.expires_seconds > max_presigned_expiry_seconds)
    {
        return error.InvalidExpires;
    }
    try validateSignedHeaders(request.signed_headers, false);
    try validateRequiredAmzHeaders(request.headers, request.signed_headers);
    _ = try findSingleHeader(request.headers, "host");

    const scope_date = request.amz_date[0..8];
    const credential = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/{s}/{s}",
        .{ request.access_key, scope_date, request.region, service, terminal },
    );
    defer allocator.free(credential);
    const encoded_credential = try normalizeEncoded(allocator, credential, false);
    defer allocator.free(encoded_credential);
    const encoded_signed_headers = try normalizeEncoded(
        allocator,
        request.signed_headers,
        false,
    );
    defer allocator.free(encoded_signed_headers);

    const separator: []const u8 = if (std.mem.indexOfScalar(u8, request.target, '?') == null)
        "?"
    else if (std.mem.endsWith(u8, request.target, "?") or
        std.mem.endsWith(u8, request.target, "&"))
        ""
    else
        "&";
    const unsigned_target = try std.fmt.allocPrint(
        allocator,
        "{s}{s}X-Amz-Algorithm={s}&X-Amz-Credential={s}&X-Amz-Date={s}&X-Amz-Expires={d}&X-Amz-SignedHeaders={s}",
        .{
            request.target,
            separator,
            algorithm,
            encoded_credential,
            request.amz_date,
            request.expires_seconds,
            encoded_signed_headers,
        },
    );
    defer allocator.free(unsigned_target);
    const canonical = try canonicalRequestWithPayload(
        allocator,
        .{
            .method = request.method,
            .target = unsigned_target,
            .headers = request.headers,
            .now_unix_seconds = 0,
            .expected_region = request.region,
        },
        request.signed_headers,
        "UNSIGNED-PAYLOAD",
        false,
    );
    defer allocator.free(canonical);
    const signature = try calculateSignature(
        allocator,
        canonical,
        request.amz_date,
        scope_date,
        request.region,
        request.secret_key,
    );
    const signature_hex = std.fmt.bytesToHex(signature, .lower);
    return std.fmt.allocPrint(
        allocator,
        "{s}&X-Amz-Signature={s}",
        .{ unsigned_target, &signature_hex },
    ) catch error.OutOfMemory;
}

fn calculateSignature(
    allocator: std.mem.Allocator,
    canonical_request: []const u8,
    amz_date: []const u8,
    scope_date: []const u8,
    region: []const u8,
    secret_key: []const u8,
) Error![32]u8 {
    var canonical_hash: [32]u8 = undefined;
    Sha256.hash(canonical_request, &canonical_hash, .{});
    const canonical_hash_hex = std.fmt.bytesToHex(canonical_hash, .lower);
    const scope = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/{s}",
        .{ scope_date, region, service, terminal },
    );
    defer allocator.free(scope);
    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n{s}",
        .{ algorithm, amz_date, scope, &canonical_hash_hex },
    );
    defer allocator.free(string_to_sign);
    var signing_key = try deriveSigningKey(allocator, scope_date, region, secret_key);
    defer std.crypto.secureZero(u8, &signing_key);
    var signature: [32]u8 = undefined;
    HmacSha256.create(&signature, string_to_sign, &signing_key);
    return signature;
}

fn deriveSigningKey(
    allocator: std.mem.Allocator,
    scope_date: []const u8,
    region: []const u8,
    secret_key: []const u8,
) Error![32]u8 {
    const prefixed_secret = std.fmt.allocPrint(allocator, "AWS4{s}", .{secret_key}) catch {
        return error.OutOfMemory;
    };
    defer {
        std.crypto.secureZero(u8, prefixed_secret);
        allocator.free(prefixed_secret);
    }
    var date_key: [32]u8 = undefined;
    HmacSha256.create(&date_key, scope_date, prefixed_secret);
    defer std.crypto.secureZero(u8, &date_key);
    var region_key: [32]u8 = undefined;
    HmacSha256.create(&region_key, region, &date_key);
    defer std.crypto.secureZero(u8, &region_key);
    var service_key: [32]u8 = undefined;
    HmacSha256.create(&service_key, service, &region_key);
    defer std.crypto.secureZero(u8, &service_key);
    var signing_key: [32]u8 = undefined;
    HmacSha256.create(&signing_key, terminal, &service_key);
    return signing_key;
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
    _ = try requestPayloadHash(request.headers);
    const payload_hash_value = try findSingleHeader(request.headers, "x-amz-content-sha256");
    return canonicalRequestWithPayload(
        allocator,
        request,
        signed_headers,
        payload_hash_value,
        false,
    );
}

fn canonicalRequestWithPayload(
    allocator: std.mem.Allocator,
    request: Request,
    signed_headers: []const u8,
    payload_hash_value: []const u8,
    exclude_presigned_signature: bool,
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
    const canonical_query = try canonicalQueryFiltered(
        allocator,
        raw_query,
        exclude_presigned_signature,
    );
    defer allocator.free(canonical_query);

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
    return canonicalQueryFiltered(allocator, raw_query, false);
}

fn canonicalQueryFiltered(
    allocator: std.mem.Allocator,
    raw_query: []const u8,
    exclude_presigned_signature: bool,
) Error![]u8 {
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
        if (exclude_presigned_signature and std.mem.eql(u8, name, "X-Amz-Signature")) {
            allocator.free(name);
            allocator.free(value);
            continue;
        }
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

fn validateSignedHeaders(value: []const u8, require_date: bool) Error!void {
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
    if (!has_host or (require_date and !has_date)) return error.InvalidSignedHeaders;
}

fn parseCredentialScope(value: []const u8) Error!CredentialScope {
    var scope = std.mem.splitScalar(u8, value, '/');
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
    return .{
        .access_key = access_key,
        .scope_date = scope_date,
        .region = region,
    };
}

fn decodeRequiredQueryValue(
    allocator: std.mem.Allocator,
    target: []const u8,
    expected_name: []const u8,
) Error![]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse {
        return error.MalformedPresignedQuery;
    };
    var found: ?[]const u8 = null;
    var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const equals = std.mem.indexOfScalar(u8, parameter, '=');
        const raw_name = if (equals) |position| parameter[0..position] else parameter;
        const name = try percentDecode(allocator, raw_name);
        defer allocator.free(name);
        if (!std.mem.eql(u8, name, expected_name)) continue;
        if (found != null) return error.MalformedPresignedQuery;
        found = if (equals) |position| parameter[position + 1 ..] else "";
    }
    return percentDecode(allocator, found orelse return error.MalformedPresignedQuery);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const output = allocator.alloc(u8, input.len) catch return error.OutOfMemory;
    errdefer allocator.free(output);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < input.len) {
        if (input[input_index] == '%') {
            if (input.len - input_index < 3) return error.MalformedPresignedQuery;
            output[output_index] = decodeHexByte(
                input[input_index + 1],
                input[input_index + 2],
            ) orelse return error.MalformedPresignedQuery;
            input_index += 3;
        } else {
            output[output_index] = input[input_index];
            input_index += 1;
        }
        output_index += 1;
    }
    return allocator.realloc(output, output_index) catch error.OutOfMemory;
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

test "Signature V4 presigned GET binds method path query headers and expiry" {
    const secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const headers = [_]Header{
        .{ .name = "host", .value = "localhost:9000" },
        .{ .name = "content-type", .value = "application/octet-stream" },
    };
    const target = try presignTarget(std.testing.allocator, .{
        .method = "GET",
        .target = "/project-assets/photos%2Fcover.jpg?response-content-type=image%2Fjpeg",
        .headers = &headers,
        .access_key = "ZF0123456789ABCDEF",
        .secret_key = secret_key,
        .amz_date = "20130524T000000Z",
        .region = "us-east-1",
        .expires_seconds = 600,
        .signed_headers = "content-type;host",
    });
    defer std.testing.allocator.free(target);
    var presigned = try parsePresignedAuthorization(std.testing.allocator, target);
    defer presigned.deinit();
    const request: Request = .{
        .method = "GET",
        .target = target,
        .headers = &headers,
        .now_unix_seconds = 1_369_353_900,
        .expected_region = "us-east-1",
    };
    try verifyPresigned(std.testing.allocator, request, presigned, secret_key);

    var changed_method = request;
    changed_method.method = "PUT";
    try std.testing.expectError(
        error.SignatureDoesNotMatch,
        verifyPresigned(std.testing.allocator, changed_method, presigned, secret_key),
    );
    const changed_headers = [_]Header{
        .{ .name = "host", .value = "localhost:9000" },
        .{ .name = "content-type", .value = "text/plain" },
    };
    var changed_header = request;
    changed_header.headers = &changed_headers;
    try std.testing.expectError(
        error.SignatureDoesNotMatch,
        verifyPresigned(std.testing.allocator, changed_header, presigned, secret_key),
    );
    var expired = request;
    expired.now_unix_seconds = 1_369_354_201;
    try std.testing.expectError(
        error.RequestExpired,
        verifyPresigned(std.testing.allocator, expired, presigned, secret_key),
    );
}

test "Signature V4 presigned parameters reject invalid expiry and duplicate signature" {
    const prefix = "/bucket/key?X-Amz-Algorithm=AWS4-HMAC-SHA256&" ++
        "X-Amz-Credential=ZF0123456789ABCDEF%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&" ++
        "X-Amz-Date=20130524T000000Z&X-Amz-SignedHeaders=host&";
    const invalid_expiry = prefix ++
        "X-Amz-Expires=604801&X-Amz-Signature=0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(
        error.InvalidExpires,
        parsePresignedAuthorization(std.testing.allocator, invalid_expiry),
    );
    const duplicate_signature = prefix ++
        "X-Amz-Expires=60&X-Amz-Signature=0000000000000000000000000000000000000000000000000000000000000000&" ++
        "%58-Amz-Signature=1111111111111111111111111111111111111111111111111111111111111111";
    try std.testing.expectError(
        error.MalformedPresignedQuery,
        parsePresignedAuthorization(std.testing.allocator, duplicate_signature),
    );
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

test "streaming verifier validates the AWS signed trailer vector" {
    const previous_signature_hex = "e05ab64fe1dfdbf0b5870abbaabdb063c371d4e96f2767e6934d90529c5ae850";
    var previous_signature: [32]u8 = undefined;
    try decodeLowerHex(previous_signature_hex, &previous_signature);
    var verifier = try StreamingVerifier.init(
        std.testing.allocator,
        &.{.{ .name = "x-amz-date", .value = "20130524T000000Z" }},
        .{
            .access_key = "AKIAIOSFODNN7EXAMPLE",
            .scope_date = "20130524",
            .region = "us-east-1",
            .signed_headers = "host;x-amz-content-sha256;x-amz-date;x-amz-trailer",
            .signature = previous_signature,
        },
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    );
    defer verifier.deinit();
    var trailer_hash: [32]u8 = undefined;
    Sha256.hash("x-amz-checksum-crc32c:wdBDMA==\n", &trailer_hash, .{});
    try verifier.verifyTrailerHash(
        trailer_hash,
        "41e14ac611e27a8bb3d66c3bad6856f209297767d5dd4fc87d8fa9e422e03faf",
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
