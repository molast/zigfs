//! Convenience workflows sharing the modeled protocol client. Pending validation.
const std = @import("std");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const aliases = @import("alias.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
pub const entries = .{
    .{ .path = "quota info", .operation = "workflow" },
    .{ .path = "quota set", .operation = "workflow" },
    .{ .path = "quota clear", .operation = "workflow" },
    .{ .path = "bucket version enable", .operation = "workflow" },
    .{ .path = "bucket version suspend", .operation = "workflow" },
    .{ .path = "bucket lock clear", .operation = "workflow" },
    .{ .path = "object legalhold enable", .operation = "workflow" },
    .{ .path = "object legalhold disable", .operation = "workflow" },
    .{ .path = "tag get", .operation = "workflow" },
    .{ .path = "tag set", .operation = "workflow" },
    .{ .path = "tag clear", .operation = "workflow" },
    .{ .path = "anonymous get", .operation = "workflow" },
    .{ .path = "anonymous list", .operation = "workflow" },
    .{ .path = "anonymous set", .operation = "workflow" },
    .{ .path = "ilm rule list", .operation = "workflow" },
    .{ .path = "ilm rule export", .operation = "workflow" },
    .{ .path = "ilm rule import", .operation = "workflow" },
    .{ .path = "ilm rule add", .operation = "workflow" },
    .{ .path = "ilm rule edit", .operation = "workflow" },
    .{ .path = "ilm rule remove", .operation = "workflow" },
    .{ .path = "event get", .operation = "workflow" },
    .{ .path = "event set", .operation = "workflow" },
    .{ .path = "event clear", .operation = "workflow" },
    .{ .path = "ping", .operation = "workflow" },
    .{ .path = "ready", .operation = "workflow" },
    .{ .path = "find", .operation = "workflow" },
    .{ .path = "tree", .operation = "workflow" },
    .{ .path = "du", .operation = "workflow" },
    .{ .path = "diff", .operation = "workflow" },
    .{ .path = "mirror", .operation = "workflow" },
    .{ .path = "watch", .operation = "workflow" },
    .{ .path = "completions", .operation = "workflow" },
};
pub fn wanted(path: []const u8) bool {
    inline for (entries) |e| if (w.eq(e.path, path)) return true;
    return false;
}
fn object(a: A, bytes: []const u8) !V {
    return (try std.json.parseFromSlice(V, a, bytes, .{})).value;
}
fn base(a: A, remote: m.Remote) !V {
    var v: V = .{ .object = .{} };
    try m.put(a, &v, "Bucket", remote.bucket);
    if (remote.key) |key| if (key.len > 0) {
        try m.put(a, &v, "Key", key);
    };
    return v;
}
fn clean(a: A, source: m.Args) !m.Args {
    var r = source;
    r.values = try source.values.clone(a);
    _ = r.values.remove("--file");
    _ = r.values.remove("--mode");
    _ = r.values.remove("--id");
    return r;
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!w.Output {
    if (w.eq(action, "find") or w.eq(action, "tree") or w.eq(action, "du") or w.eq(action, "diff") or w.eq(action, "mirror")) return @import("scan.zig").execute(a, ctx, action, args, config, json, quiet);
    if (w.eq(action, "watch")) return @import("watch.zig").execute(a, ctx, action, args, config, json, quiet);
    const r = try m.parse(a, args);
    if (r.operands.items.len != 1) return error.InvalidInput;
    if (w.eq(action, "ping") or w.eq(action, "ready")) {
        var flag_names = r.flags.keyIterator();
        while (flag_names.next()) |flag| if (!w.eq(flag.*, "--insecure")) return error.InvalidInput;
        var value_names = r.values.keyIterator();
        while (value_names.next()) |name| {
            var valid = false;
            for ([_][]const u8{ "--endpoint", "--ca-cert", "--timeout", "--connect-timeout" }) |allowed| if (w.eq(name.*, allowed)) {
                valid = true;
                break;
            };
            if (!valid) return error.InvalidInput;
        }
        if (r.headers.items.len != 0) return error.InvalidInput;
        const conn = try m.connection(a, ctx, r, config, r.operands.items[0]);
        const reply = try w.send(a, ctx, .{ .connection = conn, .method = "GET", .path = if (w.eq(action, "ping")) "/health/live" else "/health/ready", .signed = false });
        if (try w.check(a, json, reply)) |err| return err;
        return w.output(a, json, quiet, action, .{ .status_code = reply.status });
    }
    const remote = try m.remote(r.operands.items[0]);
    if (std.mem.startsWith(u8, action, "quota ")) {
        if (remote.key != null) return error.InvalidInput;
        var pass: std.ArrayList([]const u8) = .empty;
        try pass.appendSlice(a, &.{ remote.alias, remote.bucket });
        var options = r.values.iterator();
        while (options.next()) |entry| {
            if (w.eq(entry.key_ptr.*, "--max-bytes") or w.eq(entry.key_ptr.*, "--max-objects")) continue;
            try pass.appendSlice(a, &.{ entry.key_ptr.*, entry.value_ptr.* });
        }
        var flags = r.flags.keyIterator();
        while (flags.next()) |flag| try pass.append(a, flag.*);
        var body: V = .{ .object = .{} };
        if (w.eq(action, "quota clear")) {
            try body.object.put(a, "max_bytes", .{ .integer = 0 });
            try body.object.put(a, "max_objects", .{ .integer = 0 });
        } else {
            inline for (.{ .{ "--max-bytes", "max_bytes" }, .{ "--max-objects", "max_objects" } }) |pair| if (r.values.get(pair[0])) |value| {
                const n = std.fmt.parseInt(i64, value, 10) catch return error.InvalidInput;
                if (n < 0) return error.InvalidInput;
                try body.object.put(a, pair[1], .{ .integer = n });
            };
        }
        return @import("management.zig").executeBody(a, ctx, if (w.eq(action, "quota info")) "admin bucket configuration get" else "admin bucket configuration set", pass.items, config, json, quiet, if (w.eq(action, "quota info")) null else body);
    }

    const simple_bucket = w.eq(action, "bucket version enable") or w.eq(action, "bucket version suspend") or w.eq(action, "bucket lock clear");
    const simple_object = w.eq(action, "object legalhold enable") or w.eq(action, "object legalhold disable");
    if (simple_bucket or simple_object) {
        try @import("command_support.zig").check(r, if (simple_object) &.{"--version-id"} else &.{}, &.{});
        if (simple_bucket and remote.key != null) return error.InvalidInput;
        if (simple_object and (remote.key == null or remote.key.?.len == 0)) return error.InvalidInput;
    }
    var input = try base(a, remote);
    if (r.values.get("--version-id")) |version| try m.put(a, &input, "VersionId", version);
    var op: []const u8 = undefined;
    var options = try clean(a, r);
    if (w.eq(action, "bucket version enable") or w.eq(action, "bucket version suspend")) {
        op = "put-bucket-versioning";
        var conf: V = .{ .object = .{} };
        try m.put(a, &conf, "Status", if (std.mem.endsWith(u8, action, "enable")) "Enabled" else "Suspended");
        try input.object.put(a, "VersioningConfiguration", conf);
    } else if (w.eq(action, "bucket lock clear")) {
        op = "put-object-lock-configuration";
        try input.object.put(a, "ObjectLockConfiguration", try object(a, "{\"ObjectLockEnabled\":\"Enabled\"}"));
    } else if (std.mem.startsWith(u8, action, "object legalhold ")) {
        op = "put-object-legal-hold";
        var conf: V = .{ .object = .{} };
        try m.put(a, &conf, "Status", if (std.mem.endsWith(u8, action, "enable")) "ON" else "OFF");
        try input.object.put(a, "LegalHold", conf);
    } else if (std.mem.startsWith(u8, action, "tag ")) {
        const family: []const u8 = if (input.object.contains("Key")) "object" else "bucket";
        const forwarded = try std.fmt.allocPrint(a, "{s} tag {s}", .{ family, action[4..] });
        return m.execute(a, ctx, forwarded, args, config, json, quiet);
    } else if (std.mem.startsWith(u8, action, "event ")) {
        if (!w.eq(action, "event clear")) return m.execute(a, ctx, if (w.eq(action, "event get")) "bucket notification get" else "bucket notification set", args, config, json, quiet);
        op = "put-bucket-notification-configuration";
        try input.object.put(a, "NotificationConfiguration", try object(a, "{}"));
    } else if (std.mem.startsWith(u8, action, "anonymous ")) {
        const prefix = remote.key orelse "";
        _ = input.object.swapRemove("Key");
        if (!w.eq(action, "anonymous set")) {
            op = "get-bucket-policy";
        } else {
            const mode = r.values.get("--mode") orelse return error.InvalidInput;
            if (w.eq(mode, "none")) {
                if (prefix.len > 0) return error.InvalidInput;
                op = "delete-bucket-policy";
            } else {
                if (!w.eq(mode, "download") and !w.eq(mode, "upload") and !w.eq(mode, "public")) return error.InvalidInput;
                op = "put-bucket-policy";
                const resource = try std.fmt.allocPrint(a, "arn:aws:s3:::{s}/{s}*", .{ remote.bucket, prefix });
                var actions: std.array_list.Managed([]const u8) = .init(a);
                if (!w.eq(mode, "upload")) try actions.append("s3:GetObject");
                if (!w.eq(mode, "download")) try actions.append("s3:PutObject");
                const policy = try std.json.Stringify.valueAlloc(a, .{ .Version = "2012-10-17", .Statement = .{.{ .Sid = "ZcAnonymous", .Effect = "Allow", .Principal = "*", .Action = actions.items, .Resource = resource }} }, .{});
                try m.put(a, &input, "Policy", policy);
            }
        }
    } else if (std.mem.startsWith(u8, action, "ilm rule ")) {
        if (w.eq(action, "ilm rule import")) return m.execute(a, ctx, "bucket lifecycle set", args, config, json, quiet);
        if (w.eq(action, "ilm rule list") or w.eq(action, "ilm rule export")) return m.execute(a, ctx, "bucket lifecycle get", args, config, json, quiet);
        if (!r.flags.contains("--yes") and !r.flags.contains("--dry-run")) return error.ConfirmationRequired;
        var read_options = options;
        read_options.flags = .empty;
        const current = try m.executeInput(a, ctx, "get-bucket-lifecycle-configuration", read_options, remote.alias, input, config, true, false);
        if (current.exit_code != 0) return current;
        const envelope = try object(a, current.stdout);
        const conf = m.get(m.get(envelope, "data").?, "result").?;
        const old = m.get(conf, "Rules") orelse return error.InvalidResponse;
        if (old != .array) return error.InvalidResponse;
        const id = r.values.get("--id") orelse return error.InvalidInput;
        var rules: std.array_list.Managed(V) = .init(a);
        var found = false;
        for (old.array.items) |rule| {
            if (w.eq(m.text(rule, "ID") orelse "", id)) {
                found = true;
                continue;
            }
            try rules.append(rule);
        }
        const add = w.eq(action, "ilm rule add");
        if ((add and found) or (!add and !found)) return error.InvalidInput;
        if (!w.eq(action, "ilm rule remove")) {
            var rule = try w.readJson(a, ctx.io, r.values.get("--file") orelse return error.InvalidInput);
            if (rule != .object) return error.InvalidInput;
            try m.put(a, &rule, "ID", id);
            try rules.append(rule);
        }
        if (rules.items.len == 0) {
            op = "delete-bucket-lifecycle";
        } else {
            op = "put-bucket-lifecycle-configuration";
            var next: V = .{ .object = .{} };
            try next.object.put(a, "Rules", .{ .array = rules });
            try input.object.put(a, "LifecycleConfiguration", next);
        }
    } else return error.UnsupportedOperation;
    _ = options.values.remove("--version-id");
    return m.executeInput(a, ctx, op, options, remote.alias, input, config, json, quiet);
}
pub const help =
    \\Convenience commands, pending validation. Mutations require --yes or --dry-run.
    \\anonymous set TARGET --mode download|upload|public|none replaces the entire policy.
    \\ilm rule add/edit TARGET --id ID --file RULE_JSON; remove uses --id ID.
    \\Lifecycle read-modify-write is not atomic; concurrent configuration writers must be avoided.
    \\find/tree/du TARGET --fallback; diff/mirror SOURCE TARGET --fallback.
    \\Scans are bounded at 100000 entries / 64 MiB and fail rather than truncate.
    \\watch uses the authenticated object-event feed; cursor expiry is an error, never silent resynchronization.
    \\watch --cursor-file PATH requires a real file (not -) and cannot be combined with --cursor.
    \\
;
