//! Management conveniences use the same bearer client and server revision checks.
const std = @import("std");
const m = @import("modeled.zig");
const w = @import("wire.zig");
const s = @import("command_support.zig");
const management = @import("management.zig");
const aliases = @import("alias.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
fn request(a: A, ctx: aliases.Context, r: m.Args, command: []const u8, operands: []const []const u8, body: ?V, config: ?[]const u8, writing: bool) !w.Output {
    return management.executeBody(a, ctx, command, try s.arguments(a, r, operands, writing), config, true, false, body);
}
fn itemBy(collection: V, field: []const u8, name: []const u8) !V {
    if (collection != .array) return error.InvalidResponse;
    for (collection.array.items) |item| {
        if (w.eq(m.text(item, field) orelse "", name)) return item;
    }
    return error.FileNotFound;
}
fn items(a: A, out: w.Output) !V {
    return m.get(try s.result(a, out), "items") orelse return error.InvalidResponse;
}
fn changedList(a: A, old: V, names: []const []const u8, adding: bool) !V {
    if (old != .array or names.len == 0) return error.InvalidInput;
    var result = s.array(a);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (old.array.items) |value| {
        if (value != .string) return error.InvalidResponse;
        if (!adding and s.contains(names, value.string)) continue;
        try result.array.append(value);
        try seen.put(a, value.string, {});
    }
    if (adding) for (names) |name| {
        if (name.len == 0) return error.InvalidInput;
        if (!seen.contains(name)) {
            try result.array.append(.{ .string = name });
            try seen.put(a, name, {});
        }
    };
    return result;
}
fn output(a: A, action: []const u8, out: w.Output, json: bool, quiet: bool) !w.Output {
    if (out.exit_code != 0) return out;
    const envelope = (try std.json.parseFromSlice(V, a, out.stdout, .{})).value;
    return w.output(a, json, quiet, action, m.get(envelope, "data") orelse return error.InvalidResponse);
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!w.Output {
    const r = try m.parse(a, args);
    if (r.operands.items.len == 0) return error.InvalidInput;
    const name = r.operands.items[0];
    const members = std.mem.endsWith(u8, action, "add-members") or std.mem.endsWith(u8, action, "rm-members");
    const identity_toggle = (std.mem.startsWith(u8, action, "admin user ") or std.mem.startsWith(u8, action, "admin group ")) and (std.mem.endsWith(u8, action, "enable") or std.mem.endsWith(u8, action, "disable"));
    if (members or identity_toggle) {
        try s.check(r, &.{}, &.{});
        try s.mutation(r);
        if (r.operands.items.len < 2 or (!members and r.operands.items.len != 2) or (members and r.operands.items.len < 3)) return error.InvalidInput;
        const family: []const u8 = if (std.mem.startsWith(u8, action, "admin group ")) "group" else "user";
        const operands = r.operands.items[0..2];
        const current = try request(a, ctx, r, try std.fmt.allocPrint(a, "admin {s} info", .{family}), operands, null, config, false);
        if (current.exit_code != 0) return current;
        const value = try s.result(a, current);
        var patch = s.object();
        try patch.object.put(a, "expected_updated_at", m.get(value, "updated_at") orelse return error.InvalidResponse);
        if (identity_toggle) try patch.object.put(a, "enabled", .{ .bool = std.mem.endsWith(u8, action, " enable") }) else try patch.object.put(a, "members", try changedList(a, m.get(value, "members") orelse return error.InvalidResponse, r.operands.items[2..], std.mem.endsWith(u8, action, "add-members")));
        return output(a, action, try request(a, ctx, r, try std.fmt.allocPrint(a, "admin {s} update", .{family}), operands, patch, config, true), json, quiet);
    }
    if (w.eq(action, "admin policy attach") or w.eq(action, "admin policy detach")) {
        try s.check(r, &.{ "--user", "--group" }, &.{});
        try s.mutation(r);
        if (r.operands.items.len < 2 or (r.values.contains("--user") == r.values.contains("--group"))) return error.InvalidInput;
        const group = r.values.contains("--group");
        if (s.values(r, if (group) "--group" else "--user").len != 1) return error.InvalidInput;
        const family: []const u8 = if (group) "group" else "user";
        const subject = r.values.get(if (group) "--group" else "--user").?;
        const current = try request(a, ctx, r, try std.fmt.allocPrint(a, "admin {s} info", .{family}), &.{ name, subject }, null, config, false);
        if (current.exit_code != 0) return current;
        const value = try s.result(a, current);
        var patch = s.object();
        try patch.object.put(a, "expected_updated_at", m.get(value, "updated_at") orelse return error.InvalidResponse);
        try patch.object.put(a, "policies", try changedList(a, m.get(value, "policies") orelse return error.InvalidResponse, r.operands.items[1..], std.mem.endsWith(u8, action, "attach")));
        return output(a, action, try request(a, ctx, r, try std.fmt.allocPrint(a, "admin {s} update", .{family}), &.{ name, subject }, patch, config, true), json, quiet);
    }
    if (w.eq(action, "admin policy entities")) {
        try s.check(r, &.{ "--user", "--group", "--policy" }, &.{});
        if (r.operands.items.len != 1) return error.InvalidInput;
        var result = s.object();
        for ([_][]const u8{ "user", "group" }) |family| {
            const out = try request(a, ctx, r, try std.fmt.allocPrint(a, "admin {s} list", .{family}), &.{name}, null, config, false);
            if (out.exit_code != 0) return out;
            var selected = s.array(a);
            const requested = s.values(r, try std.fmt.allocPrint(a, "--{s}", .{family}));
            const policies = s.values(r, "--policy");
            for ((try items(a, out)).array.items) |entity| {
                if (requested.len > 0 and !s.contains(requested, m.text(entity, "name") orelse return error.InvalidResponse)) continue;
                const attached = m.get(entity, "policies") orelse return error.InvalidResponse;
                var matches = policies.len == 0;
                for (attached.array.items) |policy| if (policy == .string and s.contains(policies, policy.string)) {
                    matches = true;
                };
                if (matches) try selected.array.append(entity);
            }
            try result.object.put(a, family, selected);
        }
        return w.output(a, json, quiet, action, .{ .entities = result, .scope = "direct assignments; user group memberships are included" });
    }
    if (w.eq(action, "admin access-key info")) {
        try s.check(r, &.{}, &.{});
        if (r.operands.items.len != 2) return error.InvalidInput;
        const out = try request(a, ctx, r, "admin access-key list", &.{name}, null, config, false);
        if (out.exit_code != 0) return out;
        const result = try s.result(a, out);
        const list = m.get(result, "items") orelse m.get(result, "access_keys") orelse m.get(result, "credentials") orelse return error.InvalidResponse;
        return w.output(a, json, quiet, action, try itemBy(list, "access_key", r.operands.items[1]));
    }
    if (w.eq(action, "admin object legalhold clear")) {
        try s.check(r, &.{ "--file", "--key", "--version-id" }, &.{});
        if (r.operands.items.len != 2) return error.InvalidInput;
        var body = if (r.values.get("--file")) |path| try s.readJson(a, ctx, path) else s.object();
        if (r.values.get("--key")) |key| try m.put(a, &body, "key", key);
        if (r.values.get("--version-id")) |version| try m.put(a, &body, "version_id", version);
        try body.object.put(a, "enabled", .{ .bool = false });
        return output(a, action, try request(a, ctx, r, "admin object legalhold set", r.operands.items, body, config, true), json, quiet);
    }
    if (w.eq(action, "admin kms key create")) {
        try s.check(r, &.{ "--file", "--input-json", "--name", "--description" }, &.{"--set-as-default"});
        try s.mutation(r);
        if (r.operands.items.len != 1 or (r.values.contains("--file") and r.values.contains("--input-json"))) return error.InvalidInput;
        var body = if (r.values.get("--file") orelse r.values.get("--input-json")) |path| try s.readJson(a, ctx, path) else s.object();
        if (body != .object) return error.InvalidInput;
        if (r.values.get("--name")) |value| try m.put(a, &body, "name", value);
        if (r.values.get("--description")) |value| try m.put(a, &body, "description", value);
        if (r.flags.contains("--set-as-default")) try body.object.put(a, "setAsDefault", .{ .bool = true });
        return output(a, action, try request(a, ctx, r, action, &.{name}, body, config, true), json, quiet);
    }
    if (std.mem.startsWith(u8, action, "admin kms key ") and !s.contains(&.{ "admin kms key list", "admin kms key create", "admin kms key action" }, action)) {
        try s.check(r, &.{"--pending-window-days"}, &.{ "--immediate", "--confirm-immediate" });
        const verb = action["admin kms key ".len..];
        if (w.eq(verb, "status") and r.operands.items.len == 1) {
            // Without a key ID, return the backend's key metadata/capabilities.
            try s.check(r, &.{}, &.{});
            return output(a, action, try request(a, ctx, r, "admin kms key list", &.{name}, null, config, false), json, quiet);
        }
        if (r.operands.items.len != 2) return error.InvalidInput;
        if (r.values.get("--pending-window-days")) |days| if (!w.eq(days, "7")) return error.InvalidInput;
        const deleting = w.eq(verb, "delete");
        const immediate = r.flags.contains("--immediate");
        if (immediate and (!deleting or !r.flags.contains("--confirm-immediate"))) return error.ConfirmationRequired;
        if (!immediate and r.flags.contains("--confirm-immediate")) return error.InvalidInput;
        if (!deleting and r.values.contains("--pending-window-days")) return error.InvalidInput;
        var body = s.object();
        try m.put(a, &body, "id", r.operands.items[1]);
        try m.put(a, &body, "action", if (w.eq(verb, "status")) "describe" else if (deleting and !immediate) "schedule-deletion" else verb);
        var options = r;
        if (w.eq(verb, "status")) {
            options.flags = try r.flags.clone(a);
            try options.flags.put(a, "--yes", {});
        }
        return output(a, action, try request(a, ctx, options, "admin kms key action", &.{name}, body, config, true), json, quiet);
    }
    if (w.eq(action, "admin kms set")) {
        try s.check(r, &.{ "--file", "--input-json", "--config-file" }, &.{"--stdin"});
        if (r.operands.items.len != 1) return error.InvalidInput;
        var sources: usize = @intFromBool(r.flags.contains("--stdin"));
        for ([_][]const u8{ "--file", "--input-json", "--config-file" }) |key| sources += @intFromBool(r.values.contains(key));
        if (sources != 1) return error.InvalidInput;
        const path = r.values.get("--file") orelse r.values.get("--input-json") orelse r.values.get("--config-file") orelse "-";
        return output(a, action, try request(a, ctx, r, action, &.{name}, try s.readJson(a, ctx, path), config, true), json, quiet);
    }
    if (std.mem.startsWith(u8, action, "admin oidc-provider ")) return provider(a, ctx, action, r, args, config, json, quiet);
    return management.execute(a, ctx, action, args, config, json, quiet);
}
fn provider(a: A, ctx: aliases.Context, action: []const u8, r: m.Args, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) !w.Output {
    const verb = action["admin oidc-provider ".len..];
    if (s.contains(&.{ "create", "update" }, verb) and r.operands.items.len == 2) {
        try s.check(r, &.{ "--file", "--input-json", "--config-url", "--client-id", "--display-name", "--scopes", "--redirect-uri", "--role-policy" }, &.{});
        try s.mutation(r);
        if (r.values.contains("--file") and r.values.contains("--input-json")) return error.InvalidInput;
        const supplied = if (r.values.get("--file") orelse r.values.get("--input-json")) |path| try s.readJson(a, ctx, path) else s.object();
        if (supplied != .object) return error.InvalidInput;
        const id = r.operands.items[1];
        var body = s.object();
        if (w.eq(verb, "update")) {
            const current = try request(a, ctx, r, "admin oidc-provider list", r.operands.items[0..1], null, config, false);
            if (current.exit_code != 0) return current;
            body = try itemBy(try items(a, current), "provider_id", id);
            // Read responses redact secrets. Empty preserves the server's stored secret.
            try m.put(a, &body, "client_secret", "");
            _ = body.object.swapRemove("has_secret");
        }
        var fields_in = supplied.object.iterator();
        while (fields_in.next()) |field| {
            if (w.eq(field.key_ptr.*, "has_secret") or w.eq(field.key_ptr.*, "environment_managed") or w.eq(field.key_ptr.*, "revision")) return error.InvalidInput;
            if (w.eq(field.key_ptr.*, "client_secret") and field.value_ptr.* == .string and w.eq(field.value_ptr.string, "[REDACTED]")) return error.InvalidInput;
            try body.object.put(a, field.key_ptr.*, field.value_ptr.*);
        }
        if (m.text(body, "provider_id")) |provided| {
            if (!w.eq(provided, id)) return error.InvalidInput;
        }
        try m.put(a, &body, "provider_id", id);
        const fields = .{
            .{ "--config-url", "configuration_url" },
            .{ "--client-id", "client_id" },
            .{ "--display-name", "display_name" },
            .{ "--scopes", "scopes" },
            .{ "--redirect-uri", "redirect_uri" },
            .{ "--role-policy", "role_policy" },
        };
        inline for (fields) |field| {
            if (r.values.get(field[0])) |value| try m.put(a, &body, field[1], value);
        }
        const operands = if (w.eq(verb, "create")) r.operands.items[0..1] else r.operands.items;
        return output(a, action, try request(a, ctx, r, action, operands, body, config, true), json, quiet);
    }
    if (s.contains(&.{ "list", "create", "update", "remove" }, verb)) return management.execute(a, ctx, action, args, config, json, quiet);
    try s.check(r, &.{ "--config-url", "--client-id" }, &.{});
    if (r.operands.items.len != 2) return error.InvalidInput;
    const name = r.operands.items[0];
    const id = r.operands.items[1];
    if (w.eq(verb, "validate")) {
        var body = s.object();
        try m.put(a, &body, "provider_id", id);
        try m.put(a, &body, "configuration_url", r.values.get("--config-url") orelse return error.InvalidInput);
        try m.put(a, &body, "client_id", r.values.get("--client-id") orelse return error.InvalidInput);
        var options = r;
        options.flags = try r.flags.clone(a);
        try options.flags.put(a, "--yes", {});
        return output(a, action, try request(a, ctx, options, "admin oidc validate invoke", &.{name}, body, config, true), json, quiet);
    }
    const out = try request(a, ctx, r, "admin oidc-provider list", &.{name}, null, config, false);
    if (out.exit_code != 0) return out;
    var value = try itemBy(try items(a, out), "provider_id", id);
    if (w.eq(verb, "info")) return w.output(a, json, quiet, action, value);
    try s.mutation(r);
    try value.object.put(a, "enabled", .{ .bool = w.eq(verb, "enable") });
    // The backend preserves the stored secret for an empty client_secret.
    try m.put(a, &value, "client_secret", "");
    _ = value.object.swapRemove("has_secret");
    return output(a, action, try request(a, ctx, r, "admin oidc-provider update", &.{ name, id }, value, config, true), json, quiet);
}

/// Syntax for convenience commands; raw route details remain available below it.
pub fn help(action: []const u8) []const u8 {
    if (w.eq(action, "admin policy attach") or w.eq(action, "admin policy detach")) return "Arguments: ALIAS POLICY... (--user USER | --group GROUP) [--yes | --dry-run]\nReads existing assignments and submits a revision-checked update.\n";
    if (w.eq(action, "admin policy entities")) return "Arguments: ALIAS [--user USER]... [--group GROUP]... [--policy POLICY]...\nLists direct assignments and user group memberships.\n";
    if (std.mem.endsWith(u8, action, "add-members") or std.mem.endsWith(u8, action, "rm-members")) return "Arguments: ALIAS GROUP USER... [--yes | --dry-run]\nPreserves members not selected for removal; checks the stored revision.\n";
    if (std.mem.startsWith(u8, action, "admin oidc-provider ")) return "OIDC list: ALIAS\ninfo/enable/disable/remove: ALIAS PROVIDER_ID\ncreate: ALIAS [PROVIDER_ID] --file JSON|-; with PROVIDER_ID, --config-url and --client-id may supply required fields.\nupdate: ALIAS PROVIDER_ID [--file JSON|- | --input-json JSON|-] [--config-url URL] [--client-id ID] [--display-name TEXT] [--scopes CSV] [--redirect-uri URL] [--role-policy CSV]\nUpdate merges supplied fields with current configuration; secrets belong in the JSON file. Serialize concurrent provider edits (no CAS).\nvalidate: ALIAS PROVIDER_ID --config-url URL --client-id ID (discovery only, not login verification).\nMutations require --yes or --dry-run.\n";
    if (w.eq(action, "admin kms key create")) return "Arguments: ALIAS [--name NAME] [--description TEXT] [--set-as-default] [--file JSON|- | --input-json JSON|-] [--yes | --dry-run]\nExplicit flags override JSON fields. Key tags have no ZigFS contract.\n";
    if (w.eq(action, "admin kms set")) return "Arguments: ALIAS (--config-file JSON | --file JSON|- | --input-json JSON|- | --stdin) [--yes | --dry-run]\nExactly one configuration source is required.\n";
    if (w.eq(action, "admin kms key status")) return "Arguments: ALIAS [KEY_ID]\nWith ID: describe one key. Without ID: list key metadata and backend capabilities.\n";
    if (std.mem.startsWith(u8, action, "admin kms key ")) return "Key action arguments: ALIAS KEY_ID [--yes | --dry-run]\nDelete schedules deletion by default (only --pending-window-days 7).\nImmediate delete requires --immediate --confirm-immediate --yes.\nNative list/create/action routes also accept their documented JSON contracts.\n";
    if (w.eq(action, "admin access-key info")) return "Arguments: ALIAS ACCESS_KEY\nSearches permanent non-user keys. User-owned keys use admin user access-key list ALIAS USER.\n";
    if (w.eq(action, "admin object legalhold clear")) return "Arguments: ALIAS BUCKET --key KEY --version-id ID [--yes | --dry-run]\nAlternatively supply key/version_id with --file JSON|-; enabled is forced to false.\n";
    if ((std.mem.startsWith(u8, action, "admin user ") or std.mem.startsWith(u8, action, "admin group ")) and
        (std.mem.endsWith(u8, action, "enable") or std.mem.endsWith(u8, action, "disable"))) return "Arguments: ALIAS NAME [--yes | --dry-run]\nChanges enabled state while preserving other fields with a revision check.\n";
    return management.help;
}
