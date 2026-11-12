const std = @import("std");
const time = @import("../common/time.zig");
pub const Entry = struct { key: []const u8, value: []const u8 };
pub const PolicyKind = enum { identity, resource, trust, key_restriction, session, permission_boundary };
pub const Explanation = struct {
    decision: Decision,
    policy_kind: PolicyKind,
    matched_document: ?usize = null,
    matched_statement: ?usize = null,
    reason: []const u8,
};
pub const ValidationLimits = struct {
    max_document_bytes: usize = 256 * 1024,
    max_statements: usize = 1024,
    max_string_bytes: usize = 64 * 1024,
};
pub const PrincipalBinding = struct { arn: []const u8, subject_id: []const u8 };
pub const Context = struct {
    kind: PolicyKind = .identity,
    resource_document: ?[]const u8 = null,
    principal_bindings: []const PrincipalBinding = &.{},
    entries: []const Entry = &.{},
    defer_conditions: bool = false,
    pub fn single(self: Context, key: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.key, key)) {
            if (found != null) return null;
            found = entry.value;
        };
        return found;
    }
};
const Error = error{InvalidPolicy} || std.mem.Allocator.Error;
const Set = enum { normal, any, all };
const Operator = struct { name: []const u8, set: Set = .normal, if_exists: bool = false, negative: bool = false };

pub fn allows(a: std.mem.Allocator, documents: anytype, action: []const u8, resource: []const u8) bool {
    return allowsWithContext(a, documents, action, resource, .{});
}
pub fn allowsWithContext(a: std.mem.Allocator, documents: anytype, action: []const u8, resource: []const u8, context: Context) bool {
    return decisionWithContext(a, documents, action, resource, context) == .allow;
}
pub fn validateDocument(a: std.mem.Allocator, document: []const u8, kind: PolicyKind) error{InvalidPolicy}!void {
    return validateDocumentWithLimits(a, document, kind, .{});
}
pub fn validateDocumentWithLimits(a: std.mem.Allocator, document: []const u8, kind: PolicyKind, limits: ValidationLimits) error{InvalidPolicy}!void {
    if (document.len == 0 or document.len > limits.max_document_bytes) return error.InvalidPolicy;
    const parsed = std.json.parseFromSlice(std.json.Value, a, document, .{ .duplicate_field_behavior = .@"error", .max_value_len = limits.max_string_bytes }) catch return error.InvalidPolicy;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPolicy;
    var fields = parsed.value.object.iterator();
    while (fields.next()) |field| {
        if (!std.mem.eql(u8, field.key_ptr.*, "Version") and !std.mem.eql(u8, field.key_ptr.*, "Statement") and !std.mem.eql(u8, field.key_ptr.*, "Id")) return error.InvalidPolicy;
    }
    const version = parsed.value.object.get("Version") orelse return error.InvalidPolicy;
    if (version != .string or !std.mem.eql(u8, version.string, "2012-10-17")) return error.InvalidPolicy;
    const statements = parsed.value.object.get("Statement") orelse return error.InvalidPolicy;
    const count = if (statements == .array) statements.array.items.len else if (statements == .object) 1 else return error.InvalidPolicy;
    // An empty Statement array is a valid deny-all policy and is useful for
    // revoking an attached policy without deleting its named record.
    if (count > limits.max_statements) return error.InvalidPolicy;
    if (statements == .array) {
        for (statements.array.items) |statement| try validateStatementKind(statement, kind);
    } else try validateStatementKind(statements, kind);
}
pub fn decisionWithContext(a: std.mem.Allocator, documents: anytype, action: []const u8, resource: []const u8, context: Context) Decision {
    var allowed = false;
    for (documents) |document| {
        const parsed = std.json.parseFromSlice(std.json.Value, a, document, .{}) catch return .deny;
        defer parsed.deinit();
        if (parsed.value != .object) return .deny;
        const statements = parsed.value.object.get("Statement") orelse return .deny;
        if (statements == .array) {
            for (statements.array.items) |statement| {
                const decision = evaluate(a, statement, action, resource, context) catch return .deny;
                if (decision == .deny) return .deny;
                if (decision == .allow) allowed = true;
            }
        } else if (statements == .object) {
            const decision = evaluate(a, statements, action, resource, context) catch return .deny;
            if (decision == .deny) return .deny;
            if (decision == .allow) allowed = true;
        } else return .deny;
    }
    return if (allowed) .allow else .none;
}
pub const Decision = enum { none, allow, deny };
pub fn explain(a: std.mem.Allocator, documents: anytype, action: []const u8, resource: []const u8, context: Context) Explanation {
    var document_index: usize = 0;
    var allowed_document: ?usize = null;
    for (documents) |document| {
        const parsed = std.json.parseFromSlice(std.json.Value, a, document, .{}) catch return .{ .decision = .deny, .policy_kind = context.kind, .reason = "InvalidPolicyDocument" };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .decision = .deny, .policy_kind = context.kind, .reason = "InvalidPolicyDocument" };
        const statements = parsed.value.object.get("Statement") orelse return .{ .decision = .deny, .policy_kind = context.kind, .reason = "MissingStatement" };
        const values = if (statements == .array) statements.array.items else &[_]std.json.Value{statements};
        for (values, 0..) |statement, statement_index| {
            const result = evaluate(a, statement, action, resource, context) catch return .{ .decision = .deny, .policy_kind = context.kind, .reason = "InvalidStatement" };
            if (result == .deny) return .{ .decision = .deny, .policy_kind = context.kind, .matched_document = document_index, .matched_statement = statement_index, .reason = "ExplicitDeny" };
            if (result == .allow and allowed_document == null) allowed_document = document_index;
        }
        document_index += 1;
    }
    if (allowed_document) |index| return .{ .decision = .allow, .policy_kind = context.kind, .matched_document = index, .reason = "ExplicitAllow" };
    return .{ .decision = .none, .policy_kind = context.kind, .reason = "NoMatchingAllow" };
}
fn evaluate(a: std.mem.Allocator, statement: std.json.Value, action: []const u8, resource: []const u8, ctx: Context) Error!Decision {
    try validateStatementKind(statement, ctx.kind);
    const object = statement.object;
    // Only resource and trust policies carry principals. Key restrictions,
    // session policies, and permission boundaries use identity-policy syntax
    // and must not attempt to unwrap a missing Principal field.
    if (ctx.kind == .resource or ctx.kind == .trust) {
        const principal = object.get("Principal") orelse object.get("NotPrincipal").?;
        const matches = principalMatches(principal, ctx);
        if (matches == object.contains("NotPrincipal")) return .none;
    }
    const actions = object.get("Action") orelse object.get("NotAction").?;
    const action_match = try patterns(a, actions, action, .{}, true);
    if (action_match == object.contains("NotAction")) return .none;
    const resources = object.get("Resource") orelse object.get("NotResource") orelse std.json.Value{ .string = "*" };
    const resource_match = try patterns(a, resources, resource, ctx, false);
    if (resource_match == object.contains("NotResource")) return .none;
    if (object.get("Condition")) |conditions| {
        if (ctx.defer_conditions) {
            if (std.mem.eql(u8, object.get("Effect").?.string, "Deny")) return .none;
        } else if (!try conditionMatches(a, conditions, ctx)) return .none;
    }
    return if (std.mem.eql(u8, object.get("Effect").?.string, "Deny")) .deny else .allow;
}

// These are identity policies. Principal belongs to resource/trust policies and
// is rejected when saving instead of being silently treated as an identity grant.
pub fn validateStatement(statement: std.json.Value) error{InvalidPolicy}!void {
    return validateStatementKind(statement, .identity);
}
pub fn validateStatementKind(statement: std.json.Value, kind: PolicyKind) error{InvalidPolicy}!void {
    if (statement != .object) return error.InvalidPolicy;
    const o = statement.object;
    var fields = o.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        if (!std.mem.eql(u8, key, "Sid") and !std.mem.eql(u8, key, "Effect") and !std.mem.eql(u8, key, "Action") and !std.mem.eql(u8, key, "NotAction") and !std.mem.eql(u8, key, "Resource") and !std.mem.eql(u8, key, "NotResource") and !std.mem.eql(u8, key, "Principal") and !std.mem.eql(u8, key, "NotPrincipal") and !std.mem.eql(u8, key, "Condition")) return error.InvalidPolicy;
    }
    if (o.get("Sid")) |sid| if (sid != .string or sid.string.len == 0 or sid.string.len > 128) return error.InvalidPolicy;
    if (kind == .identity or kind == .key_restriction or kind == .session or kind == .permission_boundary) {
        if (o.contains("Principal") or o.contains("NotPrincipal")) return error.InvalidPolicy;
    } else {
        if (o.contains("Principal") == o.contains("NotPrincipal")) return error.InvalidPolicy;
        try validatePrincipal(o.get("Principal") orelse o.get("NotPrincipal").?);
    }
    const effect = o.get("Effect") orelse return error.InvalidPolicy;
    if (effect != .string or (!std.mem.eql(u8, effect.string, "Allow") and !std.mem.eql(u8, effect.string, "Deny"))) return error.InvalidPolicy;
    if (o.contains("Action") == o.contains("NotAction")) return error.InvalidPolicy;
    if (!strings(o.get("Action") orelse o.get("NotAction").?)) return error.InvalidPolicy;
    if (o.contains("Resource") and o.contains("NotResource")) return error.InvalidPolicy;
    if (o.get("Resource") orelse o.get("NotResource")) |resource| if (!strings(resource)) return error.InvalidPolicy;
    if (o.get("Condition")) |conditions| {
        if (conditions != .object) return error.InvalidPolicy;
        var operators = conditions.object.iterator();
        while (operators.next()) |item| {
            const op = try parseOperator(item.key_ptr.*);
            if (item.value_ptr.* != .object or item.value_ptr.object.count() == 0) return error.InvalidPolicy;
            var keys = item.value_ptr.object.iterator();
            while (keys.next()) |key| {
                if (!supportedKey(key.key_ptr.*)) return error.InvalidPolicy;
                const value = key.value_ptr.*;
                if (value == .array) {
                    if (value.array.items.len == 0) return error.InvalidPolicy;
                    for (value.array.items) |v| try validateScalar(op, v);
                } else try validateScalar(op, value);
            }
        }
    }
}
fn validatePrincipal(value: std.json.Value) error{InvalidPolicy}!void {
    if (value == .string) {
        if (!std.mem.eql(u8, value.string, "*")) return error.InvalidPolicy;
        return;
    }
    if (value != .object or value.object.count() != 1) return error.InvalidPolicy;
    const aws = value.object.get("AWS") orelse return error.InvalidPolicy;
    if (!strings(aws)) return error.InvalidPolicy;
}
fn principalMatches(value: std.json.Value, ctx: Context) bool {
    if (value == .object) return principalMatches(value.object.get("AWS").?, ctx);
    if (value == .array) {
        for (value.array.items) |item| if (principalMatches(item, ctx)) return true;
        return false;
    }
    if (value != .string) return false;
    if (std.mem.eql(u8, value.string, "*")) return true;
    for (ctx.principal_bindings) |binding| if (std.mem.eql(u8, binding.arn, value.string)) {
        return std.mem.eql(u8, binding.subject_id, ctx.single("aws:userid") orelse return false);
    };
    if (ctx.single("aws:PrincipalArn")) |arn| if (std.mem.eql(u8, arn, value.string)) return true;
    if (ctx.single("aws:PrincipalAccount")) |account| {
        if (std.mem.eql(u8, account, value.string)) return true;
        if (std.mem.startsWith(u8, value.string, "arn:aws:iam::") and std.mem.endsWith(u8, value.string, ":root") and std.mem.eql(u8, value.string[13 .. value.string.len - 5], account)) return true;
    }
    return false;
}

fn strings(value: std.json.Value) bool {
    if (value == .string) return value.string.len > 0;
    if (value != .array or value.array.items.len == 0) return false;
    for (value.array.items) |v| if (v != .string or v.string.len == 0) return false;
    return true;
}
pub fn supportedKey(key: []const u8) bool {
    const keys = [_][]const u8{ "aws:username", "aws:userid", "aws:PrincipalArn", "aws:PrincipalAccount", "aws:PrincipalType", "aws:PrincipalOrgID", "aws:PrincipalOrgPaths", "aws:SourceIp", "aws:SecureTransport", "aws:CurrentTime", "aws:EpochTime", "aws:TokenIssueTime", "aws:UserAgent", "aws:Referer", "aws:RequestedRegion", "sts:ExternalId", "sts:SourceIdentity", "sts:TransitiveTagKeys", "s3:authType", "s3:signatureversion", "s3:signatureAge", "s3:prefix", "s3:delimiter", "s3:max-keys", "s3:versionid", "s3:x-amz-copy-source", "s3:x-amz-metadata-directive", "s3:x-amz-content-sha256", "s3:x-amz-acl", "s3:x-amz-server-side-encryption", "s3:x-amz-server-side-encryption-aws-kms-key-id", "s3:x-amz-storage-class", "s3:x-amz-grant-read", "s3:x-amz-grant-write", "s3:x-amz-grant-full-control", "s3:RequestObjectTagKeys" };
    for (keys) |known| if (std.ascii.eqlIgnoreCase(key, known)) return true;
    return (std.ascii.startsWithIgnoreCase(key, "s3:RequestObjectTag/") and key.len > "s3:RequestObjectTag/".len) or (std.ascii.startsWithIgnoreCase(key, "s3:ExistingObjectTag/") and key.len > "s3:ExistingObjectTag/".len) or (std.ascii.startsWithIgnoreCase(key, "aws:ResourceTag/") and key.len > "aws:ResourceTag/".len) or (std.ascii.startsWithIgnoreCase(key, "aws:PrincipalTag/") and key.len > "aws:PrincipalTag/".len);
}
fn parseOperator(raw: []const u8) error{InvalidPolicy}!Operator {
    var op: Operator = .{ .name = raw };
    if (std.mem.startsWith(u8, op.name, "ForAnyValue:")) {
        op.set = .any;
        op.name = op.name[12..];
    }
    if (std.mem.startsWith(u8, op.name, "ForAllValues:")) {
        op.set = .all;
        op.name = op.name[13..];
    }
    if (std.mem.endsWith(u8, op.name, "IfExists")) {
        op.if_exists = true;
        op.name = op.name[0 .. op.name.len - 8];
    }
    const names = [_][]const u8{ "StringEquals", "StringNotEquals", "StringEqualsIgnoreCase", "StringNotEqualsIgnoreCase", "StringLike", "StringNotLike", "StringLikeIgnoreCase", "StringNotLikeIgnoreCase", "ArnEquals", "ArnNotEquals", "ArnLike", "ArnNotLike", "NumericEquals", "NumericNotEquals", "NumericLessThan", "NumericLessThanEquals", "NumericGreaterThan", "NumericGreaterThanEquals", "DateEquals", "DateNotEquals", "DateLessThan", "DateLessThanEquals", "DateGreaterThan", "DateGreaterThanEquals", "Bool", "Null", "IpAddress", "NotIpAddress", "BinaryEquals" };
    var known = false;
    for (names) |name| if (std.mem.eql(u8, op.name, name)) {
        known = true;
        break;
    };
    if (!known or (std.mem.eql(u8, op.name, "Null") and (op.if_exists or op.set != .normal))) return error.InvalidPolicy;
    op.negative = std.mem.indexOf(u8, op.name, "Not") != null;
    return op;
}
fn scalar(a: std.mem.Allocator, v: std.json.Value) Error![]u8 {
    return switch (v) {
        .string => a.dupe(u8, v.string),
        .bool => a.dupe(u8, if (v.bool) "true" else "false"),
        .integer => std.fmt.allocPrint(a, "{d}", .{v.integer}),
        .float => std.fmt.allocPrint(a, "{d}", .{v.float}),
        .number_string => a.dupe(u8, v.number_string),
        else => error.InvalidPolicy,
    };
}
fn validateScalar(op: Operator, v: std.json.Value) error{InvalidPolicy}!void {
    switch (v) {
        .string, .bool, .integer, .float, .number_string => {},
        else => return error.InvalidPolicy,
    }
    if (std.mem.eql(u8, op.name, "Null") or std.mem.eql(u8, op.name, "Bool")) {
        if (v == .bool) return;
        if (v != .string or (!std.mem.eql(u8, v.string, "true") and !std.mem.eql(u8, v.string, "false"))) return error.InvalidPolicy;
    }
    var buffer: [128]u8 = undefined;
    const raw: []const u8 = switch (v) {
        .string => v.string,
        .integer => std.fmt.bufPrint(&buffer, "{d}", .{v.integer}) catch return error.InvalidPolicy,
        .float => std.fmt.bufPrint(&buffer, "{d}", .{v.float}) catch return error.InvalidPolicy,
        .number_string => v.number_string,
        .bool => if (v.bool) "true" else "false",
        else => return error.InvalidPolicy,
    };
    if (std.mem.startsWith(u8, op.name, "Numeric") or std.mem.startsWith(u8, op.name, "Date")) {
        _ = try number(raw, std.mem.startsWith(u8, op.name, "Date"));
    }
    if (std.mem.startsWith(u8, op.name, "Arn")) try validateArn(raw);
    if (std.mem.endsWith(u8, op.name, "IpAddress")) {
        var parts = std.mem.splitScalar(u8, raw, '/');
        const address = parts.next().?;
        _ = ipContains(raw, address) catch return error.InvalidPolicy;
    }
    if (std.mem.eql(u8, op.name, "BinaryEquals")) {
        _ = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return error.InvalidPolicy;
        for (raw) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=')) return error.InvalidPolicy;
    }
}
fn validateArn(value: []const u8) error{InvalidPolicy}!void {
    if (value.len < 8 or !std.mem.startsWith(u8, value, "arn:")) return error.InvalidPolicy;
    var parts = std.mem.splitScalar(u8, value, ':');
    if (!std.mem.eql(u8, parts.next() orelse "", "arn")) return error.InvalidPolicy;
    _ = parts.next() orelse return error.InvalidPolicy;
    _ = parts.next() orelse return error.InvalidPolicy;
    _ = parts.next() orelse return error.InvalidPolicy;
    _ = parts.next() orelse return error.InvalidPolicy;
    _ = parts.next() orelse return error.InvalidPolicy;
}
fn conditionMatches(a: std.mem.Allocator, conditions: std.json.Value, ctx: Context) Error!bool {
    var operators = conditions.object.iterator();
    while (operators.next()) |operator| {
        const op = try parseOperator(operator.key_ptr.*);
        var keys = operator.value_ptr.object.iterator();
        while (keys.next()) |key| if (!try keyMatches(a, op, key.key_ptr.*, key.value_ptr.*, ctx)) return false;
    }
    return true;
}
fn keyMatches(a: std.mem.Allocator, op: Operator, key: []const u8, expected: std.json.Value, ctx: Context) Error!bool {
    var count: usize = 0;
    var successes: usize = 0;
    for (ctx.entries) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.key, key)) continue;
        count += 1;
        if (std.mem.eql(u8, op.name, "Null")) continue;
        if (try expectedMatches(a, op, expected, entry.value, ctx)) successes += 1;
    }
    if (std.mem.eql(u8, op.name, "Null")) return expectedMatches(a, .{ .name = "Bool" }, expected, if (count == 0) "true" else "false", ctx);
    if (count == 0) return op.if_exists or op.set == .all or (op.set == .normal and op.negative);
    return switch (op.set) {
        .all => successes == count,
        .any => successes > 0,
        .normal => if (op.negative) successes == count else successes > 0,
    };
}
fn expectedMatches(a: std.mem.Allocator, op: Operator, expected: std.json.Value, actual: []const u8, ctx: Context) Error!bool {
    var found = false;
    if (expected == .array) {
        for (expected.array.items) |v| {
            if (try compare(a, op, v, actual, ctx)) found = true;
        }
    } else found = try compare(a, op, expected, actual, ctx);
    return if (op.negative) !found else found;
}
fn compare(a: std.mem.Allocator, op: Operator, value: std.json.Value, actual: []const u8, ctx: Context) Error!bool {
    const raw = try scalar(a, value);
    defer a.free(raw);
    const pattern = std.mem.indexOf(u8, op.name, "Like") != null;
    const expanded = try expand(a, raw, ctx, pattern) orelse return error.InvalidPolicy;
    defer a.free(expanded);
    if (std.mem.startsWith(u8, op.name, "String") or std.mem.startsWith(u8, op.name, "Arn")) {
        if (pattern) return wildcard(expanded, actual, std.mem.endsWith(u8, op.name, "IgnoreCase"));
        return if (std.mem.endsWith(u8, op.name, "IgnoreCase")) std.ascii.eqlIgnoreCase(expanded, actual) else std.mem.eql(u8, expanded, actual);
    }
    if (std.mem.eql(u8, op.name, "Bool")) return std.mem.eql(u8, expanded, actual);
    if (std.mem.endsWith(u8, op.name, "IpAddress")) return ipContains(expanded, actual) catch return error.InvalidPolicy;
    if (std.mem.eql(u8, op.name, "BinaryEquals")) {
        const decoder = std.base64.standard.Decoder;
        const expected_bytes = try a.alloc(u8, decoder.calcSizeForSlice(expanded) catch return error.InvalidPolicy);
        defer a.free(expected_bytes);
        decoder.decode(expected_bytes, expanded) catch return error.InvalidPolicy;
        const actual_bytes = try a.alloc(u8, decoder.calcSizeForSlice(actual) catch return false);
        defer a.free(actual_bytes);
        decoder.decode(actual_bytes, actual) catch return false;
        return std.mem.eql(u8, expected_bytes, actual_bytes);
    }
    const date = std.mem.startsWith(u8, op.name, "Date");
    const left = number(actual, date) catch return false;
    const right = number(expanded, date) catch return error.InvalidPolicy;
    if (std.mem.endsWith(u8, op.name, "LessThanEquals")) return left <= right;
    if (std.mem.endsWith(u8, op.name, "GreaterThanEquals")) return left >= right;
    if (std.mem.endsWith(u8, op.name, "LessThan")) return left < right;
    if (std.mem.endsWith(u8, op.name, "GreaterThan")) return left > right;
    return left == right;
}
fn number(value: []const u8, date: bool) error{InvalidPolicy}!f64 {
    if (date and std.mem.indexOfScalar(u8, value, 'T') != null) {
        if (value.len < 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return error.InvalidPolicy;
        for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |i| if (!std.ascii.isDigit(value[i])) return error.InvalidPolicy;
        var utc: [20]u8 = undefined;
        @memcpy(utc[0..19], value[0..19]);
        utc[19] = 'Z';
        const seconds = time.parseIso8601(&utc) catch return error.InvalidPolicy;
        var end: usize = 19;
        var fraction: f64 = 0;
        if (value[end] == '.') {
            end += 1;
            const start = end;
            while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
            if (end == start or end - start > 9) return error.InvalidPolicy;
            fraction = std.fmt.parseFloat(f64, value[start - 1 .. end]) catch return error.InvalidPolicy;
        }
        const suffix = value[end..];
        var offset: i64 = 0;
        if (!std.mem.eql(u8, suffix, "Z")) {
            if (suffix.len != 6 or (suffix[0] != '+' and suffix[0] != '-') or suffix[3] != ':') return error.InvalidPolicy;
            for ([_]usize{ 1, 2, 4, 5 }) |i| if (!std.ascii.isDigit(suffix[i])) return error.InvalidPolicy;
            const hours = std.fmt.parseInt(i64, suffix[1..3], 10) catch return error.InvalidPolicy;
            const minutes = std.fmt.parseInt(i64, suffix[4..6], 10) catch return error.InvalidPolicy;
            if (hours > 23 or minutes > 59) return error.InvalidPolicy;
            offset = (hours * 60 + minutes) * 60 * @as(i64, if (suffix[0] == '-') -1 else 1);
        }
        return @as(f64, @floatFromInt(seconds - offset)) + fraction;
    }
    const result = std.fmt.parseFloat(f64, value) catch return error.InvalidPolicy;
    if (!std.math.isFinite(result)) return error.InvalidPolicy;
    return result;
}
pub fn ipContains(cidr: []const u8, actual: []const u8) !bool {
    var split = std.mem.splitScalar(u8, cidr, '/');
    const base = try std.Io.net.IpAddress.parse(split.next().?, 0);
    var ip = std.Io.net.IpAddress.parse(actual, 0) catch return false;
    if (base == .ip4 and ip == .ip6) ip = std.Io.net.IpAddress.fromIp6(ip.ip6);
    if (std.meta.activeTag(base) != std.meta.activeTag(ip)) return false;
    const width: usize = if (base == .ip4) 32 else 128;
    const bits = if (split.next()) |prefix| try std.fmt.parseInt(usize, prefix, 10) else width;
    if (bits > width or split.next() != null) return error.InvalidPolicy;
    const first: []const u8 = if (base == .ip4) &base.ip4.bytes else &base.ip6.bytes;
    const second: []const u8 = if (ip == .ip4) &ip.ip4.bytes else &ip.ip6.bytes;
    for (0..bits) |bit| {
        const mask = @as(u8, 0x80) >> @as(u3, @intCast(bit % 8));
        if (first[bit / 8] & mask != second[bit / 8] & mask) return false;
    }
    return true;
}
fn expand(a: std.mem.Allocator, raw: []const u8, ctx: Context, pattern: bool) Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "${")) {
            const end = std.mem.indexOfScalarPos(u8, raw, i + 2, '}') orelse return error.InvalidPolicy;
            const value = ctx.single(raw[i + 2 .. end]) orelse {
                out.deinit(a);
                return null;
            };
            for (value) |c| {
                if (pattern and (c == '*' or c == '?' or c == '\\')) try out.append(a, '\\');
                try out.append(a, c);
            }
            i = end + 1;
        } else {
            if (pattern and raw[i] == '\\') try out.append(a, '\\');
            try out.append(a, raw[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}
fn patterns(a: std.mem.Allocator, value: std.json.Value, text: []const u8, ctx: Context, insensitive: bool) Error!bool {
    if (value == .string) {
        const pattern = try expand(a, value.string, ctx, true) orelse return error.InvalidPolicy;
        defer a.free(pattern);
        return wildcard(pattern, text, insensitive);
    }
    for (value.array.items) |v| if (try patterns(a, v, text, ctx, insensitive)) return true;
    return false;
}
fn wildcard(pattern: []const u8, text: []const u8, insensitive: bool) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        const escaped = p + 1 < pattern.len and pattern[p] == '\\';
        const c = if (escaped) pattern[p + 1] else if (p < pattern.len) pattern[p] else 0;
        if (p < pattern.len and ((!escaped and c == '?') or ((escaped or c != '*') and (if (insensitive) std.ascii.toLower(c) == std.ascii.toLower(text[t]) else c == text[t])))) {
            p += if (escaped) @as(usize, 2) else 1;
            t += 1;
        } else if (p < pattern.len and c == '*' and !escaped) {
            star = p;
            p += 1;
            retry = t;
        } else if (star) |position| {
            p = position + 1;
            retry += 1;
            t = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

test "conditions combine operators keys arrays negation and missing-value semantics" {
    const a = std.testing.allocator;
    const ctx: Context = .{ .entries = &.{ .{ .key = "aws:username", .value = "alice" }, .{ .key = "s3:prefix", .value = "home/alice/" }, .{ .key = "s3:max-keys", .value = "20" }, .{ .key = "aws:SourceIp", .value = "192.0.2.42" }, .{ .key = "aws:SecureTransport", .value = "false" } } };
    const doc = "{\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:*\",\"Resource\":\"arn:aws:s3:::${aws:username}/*\",\"Condition\":{\"StringLike\":{\"s3:prefix\":\"home/${aws:username}/*\"},\"NumericLessThanEquals\":{\"s3:max-keys\":30},\"IpAddress\":{\"aws:SourceIp\":[\"192.0.2.0/24\",\"2001:db8::/32\"]},\"Bool\":{\"aws:SecureTransport\":false}}}]}";
    try std.testing.expect(allowsWithContext(a, &[_][]const u8{doc}, "s3:GetObject", "arn:aws:s3:::alice/file", ctx));
    try std.testing.expect(!allowsWithContext(a, &[_][]const u8{doc}, "s3:GetObject", "arn:aws:s3:::bob/file", ctx));
    try std.testing.expect(!allows(a, &[_][]const u8{doc}, "s3:GetObject", "arn:aws:s3:::alice/file"));
    const missing = std.json.Value{ .string = "present" };
    try std.testing.expect(try keyMatches(a, try parseOperator("StringNotEquals"), "aws:Referer", missing, ctx));
    try std.testing.expect(try keyMatches(a, try parseOperator("StringEqualsIfExists"), "aws:Referer", missing, ctx));
    try std.testing.expect(try keyMatches(a, try parseOperator("ForAllValues:StringEquals"), "aws:Referer", missing, ctx));
    try std.testing.expect(!try keyMatches(a, try parseOperator("ForAnyValue:StringEquals"), "aws:Referer", missing, ctx));
    try std.testing.expect(try keyMatches(a, try parseOperator("Null"), "aws:Referer", .{ .bool = true }, ctx));
    try std.testing.expect(try ipContains("2001:db8::/32", "2001:db8::1"));
    try std.testing.expect(!try ipContains("2001:db8::/48", "2001:db8:1::1"));
}

test "conditional deny overrides grants and presign defers only conditions" {
    const a = std.testing.allocator;
    const allow =
        \\{"Statement":{"Effect":"Allow","Action":"s3:*","Resource":"*"}}
    ;
    const deny =
        \\{"Statement":{"Effect":"Deny","NotAction":"s3:ListBucket","NotResource":"arn:aws:s3:::safe/*","Condition":{"Bool":{"aws:SecureTransport":false}}}}
    ;
    const docs = [_][]const u8{ allow, deny };
    const ctx: Context = .{ .entries = &.{.{ .key = "aws:SecureTransport", .value = "false" }} };
    try std.testing.expect(!allowsWithContext(a, &docs, "s3:GetObject", "arn:aws:s3:::other/file", ctx));
    try std.testing.expect(allowsWithContext(a, &docs, "s3:ListBucket", "arn:aws:s3:::other", ctx));
    try std.testing.expect(allowsWithContext(a, &docs, "s3:GetObject", "arn:aws:s3:::safe/file", ctx));
    try std.testing.expect(allowsWithContext(a, &docs, "s3:GetObject", "arn:aws:s3:::other/file", .{ .defer_conditions = true }));
    const unconditional = "{\"Statement\":{\"Effect\":\"Deny\",\"Action\":\"s3:*\",\"Resource\":\"*\"}}";
    try std.testing.expect(!allowsWithContext(a, &[_][]const u8{ allow, unconditional }, "s3:GetObject", "arn:aws:s3:::other/file", .{ .defer_conditions = true }));
}

test "set operators variables and typed condition operands" {
    const a = std.testing.allocator;
    const ctx: Context = .{ .entries = &.{ .{ .key = "s3:RequestObjectTagKeys", .value = "one" }, .{ .key = "s3:RequestObjectTagKeys", .value = "two" }, .{ .key = "aws:username", .value = "a*?" } } };
    const one: std.json.Value = .{ .string = "one" };
    try std.testing.expect(try keyMatches(a, try parseOperator("ForAnyValue:StringEquals"), "s3:RequestObjectTagKeys", one, ctx));
    try std.testing.expect(!try keyMatches(a, try parseOperator("ForAllValues:StringEquals"), "s3:RequestObjectTagKeys", one, ctx));
    try std.testing.expect(!try keyMatches(a, try parseOperator("StringNotEquals"), "s3:RequestObjectTagKeys", one, ctx));
    const resource: std.json.Value = .{ .string = "arn:aws:s3:::bucket/${aws:username}/*" };
    try std.testing.expect(try patterns(a, resource, "arn:aws:s3:::bucket/a*?/file", ctx, false));
    try std.testing.expect(!try patterns(a, resource, "arn:aws:s3:::bucket/alice/file", ctx, false));
    try std.testing.expectEqual(try number("2026-10-29T00:00:00.5Z", true), try number("2026-10-29T08:00:00.5+08:00", true));
    try std.testing.expectError(error.InvalidPolicy, validateScalar(try parseOperator("NumericEqualsIfExists"), .{ .string = "oops" }));
    try std.testing.expectError(error.InvalidPolicy, validateScalar(try parseOperator("NotIpAddress"), .{ .string = "192.0.2.0/99" }));
    try std.testing.expectError(error.InvalidPolicy, parseOperator("Unsupported"));
    try std.testing.expect(try compare(a, try parseOperator("BinaryEquals"), .{ .string = "YWJj" }, "YWJj", .{}));
    try std.testing.expect(try compare(a, try parseOperator("DateLessThan"), .{ .string = "2026-10-30T00:00:00Z" }, "2026-10-29T00:00:00Z", .{}));
    try std.testing.expect(try compare(a, try parseOperator("StringEqualsIgnoreCase"), .{ .string = "ALICE" }, "alice", .{}));
}
