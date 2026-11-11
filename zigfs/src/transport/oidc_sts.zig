const std = @import("std");
const Application = @import("../application/mod.zig").Application;
const oidc = @import("../application/oidc_auth.zig");
const protocol = @import("s3_protocol.zig");
const role_prefix = "arn:aws:iam::000000000000:role/oidc/";

pub fn matches(request: *std.http.Server.Request) bool {
    if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, "/")) return false;
    var headers = request.iterateHeaders();
    while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-type")) return std.mem.startsWith(u8, h.value, "application/x-www-form-urlencoded");
    return false;
}
fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%') {
            if (i + 2 >= text.len) return error.InvalidForm;
            try out.append(a, try std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(a, if (text[i] == '+') ' ' else text[i]);
    }
    return out.items;
}
fn respond(request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !std.http.Status {
    try request.respond(body, .{ .status = status, .extra_headers = &.{ .{ .name = "Content-Type", .value = "text/xml" }, .{ .name = "Cache-Control", .value = "no-store" } } });
    return status;
}
fn failure(request: *std.http.Server.Request) !std.http.Status {
    return respond(request, "<ErrorResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><Error><Type>Sender</Type><Code>InvalidIdentityToken</Code><Message>Web identity request could not be verified</Message></Error></ErrorResponse>", .bad_request);
}
pub fn serve(request: *std.http.Server.Request, app: *Application, request_id: []const u8, audit_context: *@import("audit_context.zig").Context) !std.http.Status {
    try audit_context.operation("sts:AssumeRoleWithWebIdentity", "/");
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    const body = reader.allocRemaining(a, .limited(128 * 1024)) catch return failure(request);
    var form: std.StringHashMap([]const u8) = .init(a);
    var fields = std.mem.splitScalar(u8, body, '&');
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return failure(request);
        const name = decode(a, field[0..equal]) catch return failure(request);
        if (form.contains(name)) return failure(request);
        try form.put(name, decode(a, field[equal + 1 ..]) catch return failure(request));
    }
    if (!std.mem.eql(u8, form.get("Action") orelse "", "AssumeRoleWithWebIdentity") or !std.mem.eql(u8, form.get("Version") orelse "2011-06-15", "2011-06-15")) return failure(request);
    var names = form.keyIterator();
    while (names.next()) |name| {
        const allowed = [_][]const u8{ "Action", "Version", "RoleArn", "RoleSessionName", "DurationSeconds", "Policy", "WebIdentityToken", "ProviderId" };
        var known = false;
        for (allowed) |field| if (std.mem.eql(u8, name.*, field)) {
            known = true;
        };
        // Never silently drop unsupported policy restrictions or provider selectors.
        if (!known and policyIndex(name.*) == null) return failure(request);
    }
    const arn = form.get("RoleArn") orelse return failure(request);
    if (!std.mem.startsWith(u8, arn, role_prefix)) return failure(request);
    const provider = arn[role_prefix.len..];
    if (!@import("../application/oidc_store.zig").validId(provider)) return failure(request);
    const session_name = form.get("RoleSessionName") orelse return failure(request);
    if (!validSessionName(session_name)) return failure(request);
    const ttl = std.fmt.parseInt(u64, form.get("DurationSeconds") orelse "3600", 10) catch return failure(request);
    if (ttl < 900 or ttl > 43200) return failure(request);
    const policy = sessionPolicy(a, app, &form) catch return failure(request);
    const identity = oidc.webIdentity(a, app, provider, form.get("WebIdentityToken") orelse return failure(request)) catch return failure(request);
    if (form.get("ProviderId")) |selector| {
        if (!std.mem.eql(u8, selector, identity.issuer)) {
            oidc.logout(a, app, identity.token) catch {};
            return failure(request);
        }
    }
    try audit_context.identify(identity.subject_id);
    try audit_context.authenticate("oidc", identity.subject_id, null);
    const now = std.Io.Clock.real.now(app.io.?).toSeconds();
    var issued = false;
    defer if (!issued) oidc.logout(a, app, identity.token) catch {};
    if (identity.expires_at < now + 60) return failure(request);
    const credentials = app.credentialService() orelse return failure(request);
    var result = credentials.createWithOptions(try std.fmt.allocPrint(a, "oidc:{s}", .{try oidc.digest(a, identity.token)}), .all, .{ .ttl_seconds = @min(ttl, @as(u64, @intCast(identity.expires_at - now))), .name = session_name, .policy_document = policy }) catch return failure(request);
    issued = true;
    defer result.deinit(app.allocator);
    var expiry: [20]u8 = undefined;
    const expiration = try @import("../common/time.zig").formatIso8601(result.credential.expires_at_unix_seconds.?, &expiry);
    var xml: std.Io.Writer.Allocating = .init(a);
    try xml.writer.writeAll("<AssumeRoleWithWebIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><AssumeRoleWithWebIdentityResult><Credentials><AccessKeyId>");
    try protocol.writeXmlEscaped(&xml.writer, result.credential.access_key);
    try xml.writer.writeAll("</AccessKeyId><SecretAccessKey>");
    try protocol.writeXmlEscaped(&xml.writer, result.secret_key);
    try xml.writer.writeAll("</SecretAccessKey><SessionToken>");
    try protocol.writeXmlEscaped(&xml.writer, &result.session_token.?);
    try xml.writer.print("</SessionToken><Expiration>{s}</Expiration></Credentials><AssumedRoleUser><Arn>arn:aws:sts::000000000000:assumed-role/oidc/{s}/{s}</Arn><AssumedRoleId>{s}:{s}</AssumedRoleId></AssumedRoleUser><SubjectFromWebIdentityToken>", .{ expiration, provider, session_name, identity.subject_id, session_name });
    try protocol.writeXmlEscaped(&xml.writer, identity.external_subject);
    try xml.writer.writeAll("</SubjectFromWebIdentityToken><Provider>");
    try protocol.writeXmlEscaped(&xml.writer, identity.issuer);
    try xml.writer.writeAll("</Provider><Audience>");
    try protocol.writeXmlEscaped(&xml.writer, identity.audience);
    try xml.writer.print("</Audience><PackedPolicySize>{d}</PackedPolicySize></AssumeRoleWithWebIdentityResult><ResponseMetadata><RequestId>", .{(policy.len * 100 + 131071) / 131072});
    try protocol.writeXmlEscaped(&xml.writer, request_id);
    try xml.writer.writeAll("</RequestId></ResponseMetadata></AssumeRoleWithWebIdentityResponse>");
    return respond(request, xml.written(), .ok);
}

fn validSessionName(name: []const u8) bool {
    if (name.len < 2 or name.len > 64) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_+=,.@-", c) == null) return false;
    return true;
}
fn policyIndex(name: []const u8) ?usize {
    const prefix = "PolicyArns.member.";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".arn")) return null;
    const raw = name[prefix.len .. name.len - 4];
    const index = std.fmt.parseInt(usize, raw, 10) catch return null;
    if (index == 0 or index > 10 or raw[0] == '0') return null;
    return index;
}
fn appendStatements(a: std.mem.Allocator, statements: *std.ArrayList(std.json.Value), document: []const u8) !void {
    try @import("../auth/iam_policy.zig").validateDocument(a, document, .session);
    const value = (try std.json.parseFromSlice(std.json.Value, a, document, .{})).value;
    const statement = value.object.get("Statement") orelse return error.InvalidPolicy;
    if (statement == .array) try statements.appendSlice(a, statement.array.items) else try statements.append(a, statement);
}
fn sessionPolicy(a: std.mem.Allocator, app: *Application, form: *std.StringHashMap([]const u8)) ![]const u8 {
    const inline_policy = form.get("Policy") orelse "";
    var size = inline_policy.len;
    var statements: std.ArrayList(std.json.Value) = .empty;
    if (inline_policy.len > 0) try appendStatements(a, &statements, inline_policy);
    app.policy_mutex.lockUncancelable(app.io.?);
    defer app.policy_mutex.unlock(app.io.?);
    const policies = try @import("../application/policy_store.zig").load(app.data_root.?, app.io.?, a);
    var gap = false;
    var used = std.StringHashMap(void).init(a);
    for (1..11) |i| {
        const field = try std.fmt.allocPrint(a, "PolicyArns.member.{d}.arn", .{i});
        const arn = form.get(field) orelse {
            gap = true;
            continue;
        };
        if (gap or used.contains(arn)) return error.InvalidPolicy;
        try used.put(arn, {});
        size += arn.len;
        const prefix = "arn:aws:iam::000000000000:policy/";
        if (!std.mem.startsWith(u8, arn, prefix)) return error.InvalidPolicy;
        var found = false;
        for (policies.value) |p| if (std.mem.eql(u8, p.name, arn[prefix.len..])) {
            try appendStatements(a, &statements, p.document);
            found = true;
        };
        if (!found) return error.InvalidPolicy;
    }
    if (size > 2048) return error.InvalidPolicy;
    if (size == 0) return "";
    const result = try std.json.Stringify.valueAlloc(a, .{ .Version = "2012-10-17", .Statement = statements.items }, .{});
    if (result.len > 131072) return error.PackedPolicyTooLarge;
    return result;
}
