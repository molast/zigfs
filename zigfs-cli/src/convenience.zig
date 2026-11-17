//! Compatibility syntax and stateful configuration edits. Invocation-arena ownership.
const std = @import("std");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const s = @import("command_support.zig");
const aliases = @import("alias.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const utc = @import("utc_time");
const entries = @import("compat_catalog.zig").entries;
pub fn canonical(action: []const u8) []const u8 {
    inline for (entries) |entry| if (w.eq(entry.path, action)) return entry.operation;
    return action;
}
pub fn wanted(action: []const u8) bool {
    inline for (entries) |entry| if (w.eq(entry.path, action)) return true;
    if (std.mem.startsWith(u8, action, "ilm rule ") or std.mem.startsWith(u8, action, "anonymous ") or std.mem.startsWith(u8, action, "event ")) return true;
    if (s.contains(&.{ "admin kms key create", "admin kms set", "admin oidc-provider create", "admin oidc-provider update" }, action)) return true;
    return s.contains(&.{ "bucket encryption set", "bucket lock set", "object retention set", "object legalhold set", "object restore", "sql", "tag set", "bucket tag set", "object tag set", "bucket cors set", "quota set" }, action);
}
fn call(a: A, ctx: aliases.Context, r: m.Args, remote: m.Remote, op: []const u8, input: V, config: ?[]const u8, writing: bool) !w.Output {
    return m.executeInput(a, ctx, op, try s.network(a, r, writing), remote.alias, input, config, true, false);
}
fn finish(a: A, json: bool, quiet: bool, action: []const u8, out: w.Output) !w.Output {
    if (out.exit_code != 0) return out;
    const envelope = (try std.json.parseFromSlice(V, a, out.stdout, .{})).value;
    return w.output(a, json, quiet, action, m.get(envelope, "data") orelse return error.InvalidResponse);
}
fn fileInput(a: A, ctx: aliases.Context, r: m.Args) !V {
    const path = r.values.get("--file") orelse if (r.operands.items.len == 2) r.operands.items[1] else return error.InvalidInput;
    if (r.values.contains("--file") and r.operands.items.len != 1) return error.InvalidInput;
    return s.readJson(a, ctx, path);
}
fn rawOrConfig(value: V, field: []const u8) !V {
    // Accept native payload files and previously emitted CLI envelopes.
    const unwrapped = m.get(m.get(value, "data") orelse .null, "result") orelse value;
    if (m.get(unwrapped, field)) |v| return v;
    return unwrapped;
}
fn mode(value: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(value, "governance")) return "GOVERNANCE";
    if (std.ascii.eqlIgnoreCase(value, "compliance")) return "COMPLIANCE";
    return error.InvalidInput;
}
fn oneTarget(r: m.Args) !m.Remote {
    if (r.operands.items.len != 1) return error.InvalidInput;
    return m.remote(r.operands.items[0]);
}
pub fn execute(a: A, ctx: aliases.Context, requested: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!w.Output {
    var action = canonical(requested);
    if (std.mem.startsWith(u8, action, "admin ")) return @import("admin_workflows.zig").execute(a, ctx, action, args, config, json, quiet);
    if (s.contains(&.{ "find", "tree" }, action)) return @import("scan.zig").execute(a, ctx, action, args, config, json, quiet);
    var r = try m.parse(a, args);
    if (std.mem.startsWith(u8, action, "object retention ") and r.flags.contains("--default")) {
        action = if (std.mem.endsWith(u8, action, "info")) "bucket lock info" else if (std.mem.endsWith(u8, action, "clear")) "bucket lock clear" else "bucket lock set";
        _ = r.flags.remove("--default");
    }
    if (w.eq(action, "quota set")) {
        if (r.values.get("--size")) |value| {
            if (r.values.contains("--max-bytes")) return error.InvalidInput;
            _ = r.values.remove("--size");
            try r.values.put(a, "--max-bytes", try std.fmt.allocPrint(a, "{d}", .{try @import("multipart.zig").size(value)}));
        }
        return forward(a, ctx, action, r, config, json, quiet);
    }
    if (std.mem.startsWith(u8, action, "ilm rule ")) return lifecycle(a, ctx, action, r, config, json, quiet);
    if (std.mem.startsWith(u8, action, "event ")) return notification(a, ctx, action, r, config, json, quiet);
    if (std.mem.startsWith(u8, action, "anonymous ")) return anonymous(a, ctx, action, r, config, json, quiet);
    if (s.contains(&.{ "tag set", "bucket tag set", "object tag set" }, action) and (r.values.contains("--input-json") or r.values.contains("--tagging"))) {
        const target = try oneTarget(r);
        const mapped = if (w.eq(action, "tag set")) (if (target.key != null and target.key.?.len > 0) "object tag set" else "bucket tag set") else action;
        return m.execute(a, ctx, mapped, args, config, json, quiet);
    }
    if (s.contains(&.{ "tag set", "tag remove", "bucket tag set", "bucket tag remove", "object tag set", "object tag remove" }, action)) return tagging(a, ctx, action, r, config, json, quiet);
    if (w.eq(action, "bucket cors set")) {
        if (r.values.contains("--input-json") or r.values.contains("--cors-configuration")) return m.execute(a, ctx, action, args, config, json, quiet);
        try s.check(r, &.{"--file"}, &.{});
        if (r.operands.items.len < 1 or r.operands.items.len > 2) return error.InvalidInput;
        const remote = try m.remote(r.operands.items[0]);
        var input = try s.base(a, remote, null);
        const path = r.values.get("--file") orelse if (r.operands.items.len == 2) r.operands.items[1] else return error.InvalidInput;
        if (r.values.contains("--file") and r.operands.items.len != 1) return error.InvalidInput;
        const bytes = std.mem.trim(u8, try s.readBytes(a, ctx, path), " \r\n\t");
        var value: V = undefined;
        if (std.mem.startsWith(u8, bytes, "<")) {
            const xml = @import("xml.zig");
            const root = try xml.parse(a, bytes);
            const model = try m.model(a);
            var ref = s.object();
            try m.put(a, &ref, "shape", "CORSConfiguration");
            value = try m.normalize(a, model, ref, try xml.toJson(a, root), 0);
        } else {
            value = try rawOrConfig((try std.json.parseFromSlice(V, a, bytes, .{})).value, "CORSConfiguration");
        }
        try input.object.put(a, "CORSConfiguration", value);
        return finish(a, json, quiet, action, try call(a, ctx, r, remote, "put-bucket-cors", input, config, true));
    }
    const configurable = s.contains(&.{ "bucket encryption set", "bucket lock set", "object retention set", "object legalhold set", "object restore", "sql" }, action);
    if (configurable and (r.values.contains("--file") or r.values.contains("--input-json") or r.values.contains("--retention") or r.values.contains("--legal-hold") or r.values.contains("--object-lock-configuration") or r.values.contains("--server-side-encryption-configuration") or r.values.contains("--restore-request") or r.values.contains("--expression"))) {
        // Rebuild from normalized arguments so consumed flags do not reappear.
        return forward(a, ctx, action, r, config, json, quiet);
    }
    if (!configurable and !s.contains(&.{ "object retention clear", "object legalhold clear" }, action)) return forward(a, ctx, action, r, config, json, quiet);
    return configuration(a, ctx, action, r, config, json, quiet);
}
/// Rebuild options after canonicalization; do not recursively invoke the CLI parser.
fn forward(a: A, ctx: aliases.Context, action: []const u8, r: m.Args, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    var args: std.ArrayList([]const u8) = .empty;
    var values = r.values.iterator();
    while (values.next()) |entry| try args.appendSlice(a, &.{ entry.key_ptr.*, entry.value_ptr.* });
    var flags = r.flags.keyIterator();
    while (flags.next()) |flag| try args.append(a, flag.*);
    for (r.headers.items) |header| try args.appendSlice(a, &.{ "--header", try std.fmt.allocPrint(a, "{s}:{s}", .{ header.name, header.value }) });
    try args.append(a, "--");
    try args.appendSlice(a, r.operands.items);
    if (@import("workflows.zig").wanted(action)) return @import("workflows.zig").execute(a, ctx, action, args.items, config, json, quiet);
    return m.execute(a, ctx, action, args.items, config, json, quiet);
}
fn configuration(a: A, ctx: aliases.Context, action: []const u8, r: m.Args, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    var remote: m.Remote = undefined;
    const retention = w.eq(action, "object retention set") or w.eq(action, "bucket lock set");
    var selected_mode = r.values.get("--mode");
    var validity: ?[]const u8 = null;
    if (retention and r.operands.items.len == 3) {
        if (selected_mode != null or r.values.contains("--days") or r.values.contains("--years")) return error.InvalidInput;
        selected_mode = r.operands.items[0];
        validity = r.operands.items[1];
        remote = try m.remote(r.operands.items[2]);
    } else remote = try oneTarget(r);
    var input = try s.base(a, remote, r.values.get("--version-id"));
    var op: []const u8 = undefined;
    if (w.eq(action, "bucket encryption set")) {
        try s.check(r, &.{ "--mode", "--key-id" }, &.{});
        const selected = r.values.get("--mode") orelse return error.InvalidInput;
        var algorithm = s.object();
        if (w.eq(selected, "sse-s3")) {
            if (r.values.contains("--key-id")) return error.InvalidInput;
            try m.put(a, &algorithm, "SSEAlgorithm", "AES256");
        } else if (w.eq(selected, "sse-kms")) {
            try m.put(a, &algorithm, "SSEAlgorithm", "aws:kms");
            if (r.values.get("--key-id")) |key| try m.put(a, &algorithm, "KMSMasterKeyID", key);
        } else return error.InvalidInput;
        var rule = s.object();
        try rule.object.put(a, "ApplyServerSideEncryptionByDefault", algorithm);
        var rules = s.array(a);
        try rules.array.append(rule);
        var value = s.object();
        try value.object.put(a, "Rules", rules);
        try input.object.put(a, "ServerSideEncryptionConfiguration", value);
        op = "put-bucket-encryption";
    } else if (retention or w.eq(action, "object retention clear")) {
        try s.check(r, &.{ "--mode", "--days", "--years", "--version-id", "--retain-until-date" }, &.{"--bypass-governance-retention"});
        var value = s.object();
        if (retention) {
            try m.put(a, &value, "Mode", try mode(selected_mode orelse return error.InvalidInput));
            if (r.values.contains("--days") and r.values.contains("--years")) return error.InvalidInput;
            var count_text = r.values.get("--days") orelse r.values.get("--years");
            var years = r.values.contains("--years");
            if (validity) |v| if (v.len > 1 and (v[v.len - 1] == 'd' or v[v.len - 1] == 'y')) {
                count_text = v[0 .. v.len - 1];
                years = v[v.len - 1] == 'y';
            };
            if (w.eq(action, "bucket lock set")) {
                const count = try std.fmt.parseInt(i64, count_text orelse return error.InvalidInput, 10);
                if (count <= 0 or r.values.contains("--retain-until-date")) return error.InvalidInput;
                try value.object.put(a, if (years) "Years" else "Days", .{ .integer = count });
                var rule = s.object();
                try rule.object.put(a, "DefaultRetention", value);
                value = s.object();
                try m.put(a, &value, "ObjectLockEnabled", "Enabled");
                try value.object.put(a, "Rule", rule);
            } else {
                var deadline: i64 = undefined;
                if (count_text) |text| {
                    if (r.values.contains("--retain-until-date")) return error.InvalidInput;
                    const count = try std.fmt.parseInt(i64, text, 10);
                    if (count <= 0) return error.InvalidInput;
                    const span = try std.math.mul(i64, count, if (years) 365 * 86400 else 86400);
                    deadline = try std.math.add(i64, std.Io.Clock.real.now(ctx.io).toSeconds(), span);
                } else deadline = try utc.parseIso8601(r.values.get("--retain-until-date") orelse validity orelse return error.InvalidInput);
                if (deadline <= std.Io.Clock.real.now(ctx.io).toSeconds()) return error.InvalidInput;
                var buffer: [20]u8 = undefined;
                try m.put(a, &value, "RetainUntilDate", try a.dupe(u8, try utc.formatIso8601(deadline, &buffer)));
            }
        }
        const bucket = w.eq(action, "bucket lock set");
        try input.object.put(a, if (bucket) "ObjectLockConfiguration" else "Retention", value);
        op = if (bucket) "put-object-lock-configuration" else "put-object-retention";
    } else if (std.mem.startsWith(u8, action, "object legalhold ")) {
        try s.check(r, &.{"--version-id"}, &.{});
        var value = s.object();
        try m.put(a, &value, "Status", if (std.mem.endsWith(u8, action, "clear")) "OFF" else "ON");
        try input.object.put(a, "LegalHold", value);
        op = "put-object-legal-hold";
    } else if (w.eq(action, "object restore")) {
        try s.check(r, &.{ "--days", "--tier", "--version-id" }, &.{});
        const days = try std.fmt.parseInt(i64, r.values.get("--days") orelse return error.InvalidInput, 10);
        if (days <= 0) return error.InvalidInput;
        var value = s.object();
        try value.object.put(a, "Days", .{ .integer = days });
        var glacier = s.object();
        try m.put(a, &glacier, "Tier", r.values.get("--tier") orelse "Standard");
        try value.object.put(a, "GlacierJobParameters", glacier);
        try input.object.put(a, "RestoreRequest", value);
        op = "restore-object";
    } else if (w.eq(action, "sql")) {
        try s.check(r, &.{ "--query", "--input-format", "--output-format", "--compression", "--output" }, &.{"--overwrite"});
        try m.put(a, &input, "Expression", r.values.get("--query") orelse return error.InvalidInput);
        try m.put(a, &input, "ExpressionType", "SQL");
        var source = s.object();
        const format = r.values.get("--input-format") orelse "csv";
        if (w.eq(format, "csv")) try source.object.put(a, "CSV", s.object()) else if (w.eq(format, "parquet")) try source.object.put(a, "Parquet", s.object()) else if (w.eq(format, "json")) {
            var value = s.object();
            try m.put(a, &value, "Type", "DOCUMENT");
            try source.object.put(a, "JSON", value);
        } else return error.InvalidInput;
        const compression = r.values.get("--compression") orelse "none";
        if (!s.contains(&.{ "none", "gzip", "bzip2" }, compression) or (w.eq(format, "parquet") and !w.eq(compression, "none"))) return error.InvalidInput;
        try m.put(a, &source, "CompressionType", try std.ascii.allocUpperString(a, compression));
        try input.object.put(a, "InputSerialization", source);
        var destination = s.object();
        const output_format = r.values.get("--output-format") orelse "csv";
        if (!s.contains(&.{ "csv", "json" }, output_format)) return error.InvalidInput;
        try destination.object.put(a, if (w.eq(output_format, "csv")) "CSV" else "JSON", s.object());
        try input.object.put(a, "OutputSerialization", destination);
        var options = try s.network(a, r, true);
        try options.values.put(a, "--output", r.values.get("--output") orelse return error.InvalidInput);
        if (r.flags.contains("--overwrite")) try options.flags.put(a, "--overwrite", {});
        // Select is a read operation despite its POST transport.
        try options.flags.put(a, "--yes", {});
        return m.executeInput(a, ctx, "select-object-content", options, remote.alias, input, config, json, quiet);
    } else return error.InvalidInput;
    return finish(a, json, quiet, action, try call(a, ctx, r, remote, op, input, config, true));
}
fn missingConfiguration(a: A, out: w.Output) bool {
    if (out.exit_code != 5) return false;
    const parsed = std.json.parseFromSlice(V, a, out.stderr, .{}) catch return false;
    return w.eq(m.text(m.get(parsed.value, "error") orelse .null, "code") orelse "", "NO_CONFIGURATION");
}
fn tagging(a: A, ctx: aliases.Context, action: []const u8, r: m.Args, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    try s.check(r, &.{ "--file", "--tag", "--key", "--version-id" }, &.{});
    try s.mutation(r);
    const remote = try oneTarget(r);
    const object = remote.key != null and remote.key.?.len > 0;
    if (std.mem.startsWith(u8, action, "object ") and !object) return error.InvalidInput;
    if (std.mem.startsWith(u8, action, "bucket ") and object) return error.InvalidInput;
    const remove = std.mem.endsWith(u8, action, "remove");
    var input = try s.base(a, remote, r.values.get("--version-id"));
    var tags = s.array(a);
    if (remove) {
        if (!r.values.contains("--key") or r.values.contains("--tag") or r.values.contains("--file")) return error.InvalidInput;
        const current = try call(a, ctx, r, remote, if (object) "get-object-tagging" else "get-bucket-tagging", input, config, false);
        if (current.exit_code != 0) return current;
        const existing = m.get(try s.result(a, current), "TagSet") orelse return error.InvalidResponse;
        for (existing.array.items) |tag| {
            if (!s.contains(s.values(r, "--key"), m.text(tag, "Key") orelse return error.InvalidResponse)) try tags.array.append(tag);
        }
    } else if (r.values.get("--file")) |path| {
        if (r.values.contains("--tag") or r.values.contains("--key")) return error.InvalidInput;
        const value = try s.readJson(a, ctx, path);
        tags = m.get(value, "TagSet") orelse return error.InvalidInput;
        if (tags != .array) return error.InvalidInput;
    } else {
        if (!r.values.contains("--tag") or r.values.contains("--key")) return error.InvalidInput;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (s.values(r, "--tag")) |pair| {
            const at = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidInput;
            const key = pair[0..at];
            if (key.len == 0 or seen.contains(key)) return error.InvalidInput;
            try seen.put(a, key, {});
            var tag = s.object();
            try m.put(a, &tag, "Key", key);
            try m.put(a, &tag, "Value", pair[at + 1 ..]);
            try tags.array.append(tag);
        }
    }
    var value = s.object();
    try value.object.put(a, "TagSet", tags);
    try input.object.put(a, "Tagging", value);
    return finish(a, json, quiet, action, try call(a, ctx, r, remote, if (object) "put-object-tagging" else "put-bucket-tagging", input, config, true));
}
const lifecycle_minimum = "TransitionDefaultMinimumObjectSize";

/// Canonical export format: Rules plus the optional setting carried in an HTTP header.
/// Accept old flat files, complete request objects, and previous CLI result envelopes.
fn lifecycleDocument(a: A, value: V) !V {
    const data = m.get(value, "data");
    const unwrapped = if (data) |body| m.get(body, "result") orelse body else value;
    const payload = m.get(unwrapped, "LifecycleConfiguration") orelse unwrapped;
    const rules = m.get(payload, "Rules") orelse return error.InvalidInput;
    if (rules != .array) return error.InvalidInput;
    var document = s.object();
    try document.object.put(a, "Rules", rules);
    const outer = m.get(unwrapped, lifecycle_minimum);
    const inner = m.get(payload, lifecycle_minimum);
    if (outer != null and inner != null) {
        if (outer.? != .string or inner.? != .string or !w.eq(outer.?.string, inner.?.string)) return error.InvalidInput;
    }
    if (outer orelse inner) |minimum| {
        if (minimum != .string) return error.InvalidInput;
        try document.object.put(a, lifecycle_minimum, minimum);
    }
    return document;
}

/// The minimum-size setting is a request header, not part of the lifecycle XML payload.
fn applyLifecycle(a: A, input: *V, document: V) !void {
    var payload = s.object();
    try payload.object.put(a, "Rules", m.get(document, "Rules") orelse return error.InvalidInput);
    try input.object.put(a, "LifecycleConfiguration", payload);
    if (m.get(document, lifecycle_minimum)) |minimum| {
        try input.object.put(a, lifecycle_minimum, minimum);
    }
}

fn lifecycle(a: A, ctx: aliases.Context, action: []const u8, r: m.Args, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    try s.check(r, &.{ "--file", "--id", "--output" }, &.{ "--all", "--overwrite" });
    const importing = w.eq(action, "ilm rule import");
    if (r.operands.items.len < 1 or r.operands.items.len > @as(usize, if (importing) 2 else 1)) return error.InvalidInput;
    const remote = try m.remote(r.operands.items[0]);
    if (remote.key != null) return error.InvalidInput;
    var input = try s.base(a, remote, null);
    const reading = w.eq(action, "ilm rule list") or w.eq(action, "ilm rule export");
    if (!reading) try s.mutation(r);
    if (importing) {
        const document = try lifecycleDocument(a, try fileInput(a, ctx, r));
        try applyLifecycle(a, &input, document);
        return finish(a, json, quiet, action, try call(a, ctx, r, remote, "put-bucket-lifecycle-configuration", input, config, true));
    }
    if (r.flags.contains("--all")) {
        if (!w.eq(action, "ilm rule remove") or r.values.contains("--id")) return error.InvalidInput;
        return finish(a, json, quiet, action, try call(a, ctx, r, remote, "delete-bucket-lifecycle", input, config, true));
    }
    const current = try call(a, ctx, r, remote, "get-bucket-lifecycle-configuration", input, config, false);
    var document = s.object();
    try document.object.put(a, "Rules", s.array(a));
    if (current.exit_code != 0) {
        if (!w.eq(action, "ilm rule add") or !missingConfiguration(a, current)) return current;
    } else document = try lifecycleDocument(a, try s.result(a, current));
    const rules = m.get(document, "Rules").?;
    if (reading) {
        if (w.eq(action, "ilm rule export")) return s.rawJson(a, ctx, r, document);
        return w.output(a, json, quiet, action, document);
    }
    if (r.values.contains("--output") or r.flags.contains("--overwrite")) return error.InvalidInput;
    const id = r.values.get("--id") orelse return error.InvalidInput;
    var next = s.array(a);
    var found = false;
    for (rules.array.items) |rule| {
        if (w.eq(m.text(rule, "ID") orelse "", id)) {
            found = true;
            continue;
        }
        try next.array.append(rule);
    }
    const add = w.eq(action, "ilm rule add");
    if ((add and found) or (!add and !found)) return error.InvalidInput;
    if (!w.eq(action, "ilm rule remove")) {
        var rule = try fileInput(a, ctx, r);
        if (rule != .object) return error.InvalidInput;
        if (m.text(rule, "ID")) |supplied| if (!w.eq(supplied, id)) return error.InvalidInput;
        try m.put(a, &rule, "ID", id);
        try next.array.append(rule);
    }
    const op: []const u8 = if (next.array.items.len == 0) "delete-bucket-lifecycle" else "put-bucket-lifecycle-configuration";
    if (next.array.items.len > 0) {
        try document.object.put(a, "Rules", next);
        try applyLifecycle(a, &input, document);
    }
    return finish(a, json, quiet, action, try call(a, ctx, r, remote, op, input, config, true));
}
fn notification(a: A, ctx: aliases.Context, action: []const u8, r: m.Args, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    if (w.eq(action, "event add")) {
        try s.check(r, &.{ "--file", "--id", "--arn", "--events", "--prefix", "--suffix", "--type" }, &.{});
        if (r.values.contains("--file")) {
            for ([_][]const u8{ "--arn", "--events", "--prefix", "--suffix" }) |name| {
                if (r.values.contains(name)) return error.ConflictingOptions;
            }
        }
    } else if (w.eq(action, "event set")) {
        try s.check(r, &.{"--file"}, &.{});
    } else if (w.eq(action, "event remove")) {
        try s.check(r, &.{"--id"}, &.{"--all"});
        if (r.flags.contains("--all") == r.values.contains("--id")) return error.InvalidInput;
    } else {
        try s.check(r, &.{}, &.{});
    }
    const remote = try oneTarget(r);
    if (remote.key != null) return error.InvalidInput;
    var input = try s.base(a, remote, null);
    if (w.eq(action, "event get") or w.eq(action, "event list")) return finish(a, json, quiet, action, try call(a, ctx, r, remote, "get-bucket-notification-configuration", input, config, false));
    try s.mutation(r);
    var value = s.object();
    const kinds = [_][]const u8{ "TopicConfigurations", "QueueConfigurations", "LambdaFunctionConfigurations" };
    if (w.eq(action, "event set")) value = try fileInput(a, ctx, r) else if (w.eq(action, "event clear") or (w.eq(action, "event remove") and r.flags.contains("--all"))) {
        if (r.values.contains("--id")) return error.InvalidInput;
    } else {
        const current = try call(a, ctx, r, remote, "get-bucket-notification-configuration", input, config, false);
        if (current.exit_code != 0) return current;
        value = try s.result(a, current);
        if (value != .object) value = s.object();
        const id = r.values.get("--id") orelse return error.InvalidInput;
        var found = false;
        for (kinds) |kind| {
            const old = m.get(value, kind) orelse continue;
            var next = s.array(a);
            for (old.array.items) |item| {
                if (w.eq(m.text(item, "Id") orelse "", id)) {
                    found = true;
                    continue;
                }
                try next.array.append(item);
            }
            try value.object.put(a, kind, next);
        }
        const add = w.eq(action, "event add");
        if ((add and found) or (!add and !found)) return error.InvalidInput;
        if (add) {
            const kind = r.values.get("--type") orelse "queue";
            const index: usize = if (w.eq(kind, "topic")) 0 else if (w.eq(kind, "queue")) 1 else if (w.eq(kind, "lambda")) 2 else return error.InvalidInput;
            var item = if (r.values.contains("--file")) try fileInput(a, ctx, r) else s.object();
            if (item != .object) return error.InvalidInput;
            try m.put(a, &item, "Id", id);
            if (!r.values.contains("--file")) {
                try m.put(a, &item, ([_][]const u8{ "TopicArn", "QueueArn", "LambdaFunctionArn" })[index], r.values.get("--arn") orelse return error.InvalidInput);
                var events = s.array(a);
                var parts = std.mem.splitScalar(u8, r.values.get("--events") orelse return error.InvalidInput, ',');
                while (parts.next()) |event| {
                    if (event.len == 0) return error.InvalidInput;
                    try events.array.append(.{ .string = event });
                }
                try item.object.put(a, "Events", events);
                var filters = s.array(a);
                for ([_][]const u8{ "prefix", "suffix" }) |name| {
                    const option = try std.fmt.allocPrint(a, "--{s}", .{name});
                    if (r.values.get(option)) |filter_value| {
                        var rule = s.object();
                        try m.put(a, &rule, "Name", name);
                        try m.put(a, &rule, "Value", filter_value);
                        try filters.array.append(rule);
                    }
                }
                if (filters.array.items.len > 0) {
                    var key = s.object();
                    try key.object.put(a, "FilterRules", filters);
                    var filter = s.object();
                    try filter.object.put(a, "Key", key);
                    try item.object.put(a, "Filter", filter);
                }
            }
            var list = m.get(value, kinds[index]) orelse s.array(a);
            try list.array.append(item);
            try value.object.put(a, kinds[index], list);
        }
    }
    try input.object.put(a, "NotificationConfiguration", value);
    return finish(a, json, quiet, action, try call(a, ctx, r, remote, "put-bucket-notification-configuration", input, config, true));
}
fn anonymous(a: A, ctx: aliases.Context, action: []const u8, original: m.Args, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    var r = original;
    if (w.eq(action, "anonymous set") and r.operands.items.len == 2) {
        if (r.values.contains("--mode")) return error.InvalidInput;
        try r.values.put(a, "--mode", r.operands.items[0]);
        r.operands.items = r.operands.items[1..];
    }
    try s.check(r, &.{ "--mode", "--file", "--output" }, &.{"--overwrite"});
    const remote = try oneTarget(r);
    if (w.eq(action, "anonymous links")) return publicLinks(a, ctx, r, remote, config, json, quiet);
    if (w.eq(action, "anonymous set")) return forward(a, ctx, action, r, config, json, quiet);
    var input = try s.base(a, remote, null);
    _ = input.object.swapRemove("Key");
    if (w.eq(action, "anonymous set-json")) {
        const value = try fileInput(a, ctx, r);
        try m.put(a, &input, "Policy", try std.json.Stringify.valueAlloc(a, value, .{}));
        return finish(a, json, quiet, action, try call(a, ctx, r, remote, "put-bucket-policy", input, config, true));
    }
    const out = try call(a, ctx, r, remote, "get-bucket-policy", input, config, false);
    if (out.exit_code != 0) return out;
    if (w.eq(action, "anonymous get-json")) {
        var value = try s.result(a, out);
        if (m.get(value, "Policy")) |policy| value = if (policy == .string) (try std.json.parseFromSlice(V, a, policy.string, .{})).value else policy;
        return s.rawJson(a, ctx, r, value);
    }
    return finish(a, json, quiet, action, out);
}
fn publicLinks(a: A, ctx: aliases.Context, r: m.Args, remote: m.Remote, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    var input = s.object();
    try m.put(a, &input, "Bucket", remote.bucket);
    try m.put(a, &input, "Prefix", remote.key orelse "");
    var options = try s.network(a, r, false);
    try options.flags.put(a, "--all-pages", {});
    const out = try m.executeInput(a, ctx, "list-objects-v2", options, remote.alias, input, config, true, false);
    if (out.exit_code != 0) return out;
    const envelope = (try std.json.parseFromSlice(V, a, out.stdout, .{})).value;
    const pages = m.get(m.get(envelope, "data").?, "pages").?;
    const conn = try m.connection(a, ctx, r, config, remote.alias);
    const uri = try std.Uri.parse(conn.endpoint);
    const host = switch (uri.host.?) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    const dns = w.eq(conn.bucket_lookup, "dns");
    const authority = if (dns) try std.fmt.allocPrint(a, "{s}.{s}", .{ remote.bucket, host }) else host;
    const host_port = if (uri.port) |port| try std.fmt.allocPrint(a, "{s}:{d}", .{ authority, port }) else authority;
    var links = s.array(a);
    for (pages.array.items) |page| if (m.get(page, "Contents")) |objects| {
        for (objects.array.items) |item| {
            const key = m.text(item, "Key") orelse return error.InvalidResponse;
            const path = if (dns) try std.fmt.allocPrint(a, "/{s}", .{key}) else try std.fmt.allocPrint(a, "/{s}/{s}", .{ remote.bucket, key });
            const encoded = try @import("signing.zig").encode(a, path, true);
            try links.array.append(.{ .string = try std.fmt.allocPrint(a, "{s}://{s}{s}", .{ uri.scheme, host_port, encoded }) });
        }
    };
    return w.output(a, json, quiet, "anonymous-links", .{ .links = links, .access_verified = false });
}
pub const help =
    \\High-level commands (logic connected, pending validation).
    \\Tags: set TARGET --tag KEY=VALUE (repeatable); remove TARGET --key KEY (repeatable).
    \\Events: add BUCKET --id ID --type queue|topic|lambda --arn ARN --events CSV [--prefix P --suffix S]; remove --id ID|--all.
    \\Retention: set MODE VALIDITY TARGET [--default] [--vid ID] [--bypass]; clear TARGET.
    \\Lock: set BUCKET --mode governance|compliance --days N|--years N. Legalhold set/clear writes ON/OFF.
    \\Encryption: set BUCKET --mode sse-s3|sse-kms [--key-id ID]. Quota: set BUCKET --size SIZE.
    \\Lifecycle export writes Rules plus optional TransitionDefaultMinimumObjectSize; import BUCKET FILE preserves both.
    \\Legacy Rules-only imports leave the minimum-size default to the server. remove --all clears the configuration.
    \\Anonymous: set ACCESS TARGET; get-json/set-json/links TARGET. Policy set replaces the entire document.
    \\SQL: TARGET --query SQL --input-format csv|json|parquet --output-format csv|json --compression none|gzip|bzip2 --output FILE.
    \\Mutations require --yes or --dry-run. S3 read-modify-write configuration edits have no CAS; serialize writers.
    \\
;
