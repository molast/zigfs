const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;
const Io = std.Io;
const max_bytes = 1024 * 1024;
const private_mode: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @fromBackingInt(@intCast(0o600));

pub const Alias = struct {
    name: []const u8,
    endpoint: []const u8,
    access_key: []const u8 = "",
    secret_key: []const u8 = "",
    session_token: []const u8 = "",
    region: []const u8 = "us-east-1",
    signature: []const u8 = "v4",
    bucket_lookup: []const u8 = "path",
    insecure: bool = false,
    ca_cert: []const u8 = "",
    connect_timeout: u32 = 10,
    timeout: u32 = 300,
    management_endpoint: []const u8 = "",
};
pub const Config = struct { schema_version: u32 = 1, aliases: []const Alias = &.{} };
pub const RequestPolicy = struct {
    part_lanes: usize = 0,
    retries_left: std.atomic.Value(u32),
    rate_limit: u64 = 0,
    initial_backoff: u32 = 100,
    max_backoff: u32 = 1600,
};
pub const Context = struct { io: Io, env: *const std.process.Environ.Map, policy: ?*RequestPolicy = null };
pub const Output = struct { json: []const u8, human: []const u8, raw: bool = false };

pub fn isFlag(name: []const u8) bool {
    for ([_][]const u8{ "--insecure", "--skip-check", "--replace", "--force", "--include-credentials", "--acknowledge-credentials", "--long", "-l" }) |flag| if (eq(flag, name)) return true;
    return false;
}
pub fn isValueOption(name: []const u8) bool {
    for ([_][]const u8{ "--region", "--signature", "--bucket-lookup", "--session-token", "--secret-key-from-env", "--secret-key-file", "--ca-cert", "--connect-timeout", "--timeout", "--management-endpoint", "--output", "-o" }) |flag| if (eq(flag, name)) return true;
    return false;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn nonempty(value: []const u8) !void {
    if (value.len == 0 or value.len > 4096 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidAliasInput;
}
fn validName(name: []const u8) !void {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return error.InvalidAliasInput;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidAliasInput;
}
fn endpointValid(endpoint: []const u8) !void {
    try nonempty(endpoint);
    for (endpoint) |c| if (c <= 32 or c == 127 or c == '\\') return error.InvalidEndpoint;
    const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
    if ((!eq(uri.scheme, "http") and !eq(uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidEndpoint;
    if (uri.host.?.isEmpty() or (!uri.path.isEmpty() and !eq(uri.path.percent_encoded, "/"))) return error.InvalidEndpoint;
    if (uri.port != null and uri.port.? == 0) return error.InvalidEndpoint;
}
fn validate(alias: Alias) !void {
    try validName(alias.name);
    try endpointValid(alias.endpoint);
    if (alias.management_endpoint.len != 0) try endpointValid(alias.management_endpoint);
    try nonempty(alias.region);
    for (alias.region) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidAliasInput;
    if (!eq(alias.signature, "v4")) return error.UnsupportedSignature;
    if (!eq(alias.bucket_lookup, "path") and !eq(alias.bucket_lookup, "dns") and !eq(alias.bucket_lookup, "auto")) return error.InvalidAliasInput;
    if (alias.connect_timeout == 0 or alias.timeout == 0 or alias.connect_timeout > 86400 or alias.timeout > 86400 or alias.connect_timeout > alias.timeout) return error.InvalidAliasInput;
    if ((alias.access_key.len == 0) != (alias.secret_key.len == 0)) return error.IncompleteCredentials;
    if (alias.session_token.len > 0 and alias.access_key.len == 0) return error.IncompleteCredentials;
    for ([_][]const u8{ alias.access_key, alias.secret_key, alias.session_token, alias.ca_cert }) |value| {
        if (value.len > 4096) return error.InvalidAliasInput;
        for (value) |c| if (c < 32 or c == 127) return error.InvalidAliasInput;
    }
}
fn validateConfig(config: Config) !void {
    if (config.schema_version != 1 or config.aliases.len > 1024) return error.InvalidConfiguration;
    for (config.aliases, 0..) |alias, i| {
        try validate(alias);
        for (config.aliases[0..i]) |previous| if (eq(alias.name, previous.name)) return error.DuplicateAlias;
    }
}

pub fn configPath(a: A, env: *const std.process.Environ.Map, explicit: ?[]const u8) ![]const u8 {
    if (explicit orelse env.get("ZC_CONFIG_FILE")) |path| {
        try nonempty(path);
        return std.fs.path.resolve(a, &.{path});
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) {
            if (!std.fs.path.isAbsolute(xdg)) return error.InvalidConfiguration;
            return std.fs.path.join(a, &.{ xdg, "zc", "config.toml" });
        }
    }
    const home = env.get("HOME") orelse return error.MissingHome;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidConfiguration;
    return std.fs.path.join(a, &.{ home, ".config", "zc", "config.toml" });
}

// Read only a bounded regular file; do not follow final-component symlinks.
const FileData = struct { bytes: []const u8, owner_only: bool };
fn readFileData(a: A, io: Io, path: []const u8) !FileData {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > max_bytes) return error.InvalidConfiguration;
    const owner_only = builtin.os.tag == .windows or (@backingInt(stat.permissions) & 0o077) == 0;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidConfiguration;
    return .{ .bytes = bytes, .owner_only = owner_only };
}
fn readFile(a: A, io: Io, path: []const u8, private: bool) ![]const u8 {
    const data = try readFileData(a, io, path);
    if (private and !data.owner_only) return error.InsecurePermissions;
    return data.bytes;
}

fn stripComment(line: []const u8) []const u8 {
    var quoted = false;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (quoted and !escaped and c == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and c == '"') quoted = !quoted;
        if (!quoted and c == '#') return line[0..i];
        escaped = false;
    }
    return line;
}

// Explicit TOML subset: schema_version and [[aliases]], scalar strings/bools/integers.
// Reject unsupported syntax rather than drop or reinterpret configuration on save.
pub fn decodeToml(a: A, bytes: []const u8) !Config {
    var aliases: std.ArrayList(Alias) = .empty;
    var current: ?Alias = null;
    var seen: u64 = 0;
    var schema: ?u32 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (eq(line, "[[aliases]]")) {
            if (current) |alias| {
                if (seen & 3 != 3) return error.InvalidConfiguration;
                try aliases.append(a, alias);
            }
            if (aliases.items.len >= 1024) return error.InvalidConfiguration;
            current = .{ .name = "", .endpoint = "" };
            seen = 0;
            continue;
        }
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfiguration;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (current) |*alias| {
            var matched = false;
            inline for (@typeInfo(Alias).@"struct".field_names, @typeInfo(Alias).@"struct".field_types, 0..) |field_name, field_type, i| {
                if (eq(key, field_name)) {
                    const mask = @as(u64, 1) << i;
                    if (seen & mask != 0) return error.InvalidConfiguration;
                    const parsed = std.json.parseFromSlice(field_type, a, value, .{ .allocate = .alloc_always }) catch return error.InvalidConfiguration;
                    @field(alias, field_name) = parsed.value;
                    seen |= mask;
                    matched = true;
                }
            }
            if (!matched) return error.InvalidConfiguration;
        } else {
            if (!eq(key, "schema_version") or schema != null) return error.InvalidConfiguration;
            schema = std.fmt.parseInt(u32, value, 10) catch return error.InvalidConfiguration;
        }
    }
    if (current) |alias| {
        if (seen & 3 != 3) return error.InvalidConfiguration;
        try aliases.append(a, alias);
    }
    const config: Config = .{ .schema_version = schema orelse return error.InvalidConfiguration, .aliases = aliases.items };
    try validateConfig(config);
    return config;
}
fn encodeToml(a: A, config: Config) ![]const u8 {
    var writer: Io.Writer.Allocating = .init(a);
    const w = &writer.writer;
    try w.writeAll("schema_version = 1\n");
    for (config.aliases) |alias| {
        try w.writeAll("\n[[aliases]]\n");
        inline for (@typeInfo(Alias).@"struct".field_names) |field_name| {
            const value = try std.json.Stringify.valueAlloc(a, @field(alias, field_name), .{});
            try w.print("{s} = {s}\n", .{ field_name, value });
        }
    }
    return writer.toOwnedSlice();
}
fn load(a: A, io: Io, path: []const u8) !Config {
    const bytes = readFile(a, io, path, true) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return decodeToml(a, bytes);
}
fn save(io: Io, path: []const u8, bytes: []const u8, replace: bool) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = private_mode, .replace = replace });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    if (replace) try atomic.replace(io) else try atomic.link(io);
}
fn find(config: Config, name: []const u8) ?usize {
    for (config.aliases, 0..) |alias, i| if (eq(alias.name, name)) return i;
    return null;
}
fn less(_: void, left: Alias, right: Alias) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

pub const Request = struct {
    positionals: [128][]const u8 = undefined,
    count: usize = 0,
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    flags: std.StringHashMapUnmanaged(void) = .empty,
};
fn parseRequest(a: A, action: []const u8, args: []const []const u8) !Request {
    var r: Request = .{};
    var end = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!end and eq(arg, "--")) {
            end = true;
            continue;
        }
        if (!end and std.mem.startsWith(u8, arg, "-")) {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const name = if (split) |at| arg[0..at] else arg;
            const canonical = if (eq(name, "-o")) "--output" else if (eq(name, "-l")) "--long" else name;
            if (r.values.contains(canonical) or r.flags.contains(canonical)) return error.InvalidAliasInput;
            const set_option = isValueOption(canonical) and !eq(canonical, "--output") or eq(canonical, "--insecure") or eq(canonical, "--skip-check");
            const export_option = eq(canonical, "--output") or eq(canonical, "--force") or eq(canonical, "--include-credentials") or eq(canonical, "--acknowledge-credentials");
            if (!(eq(action, "set") and set_option or eq(action, "export") and export_option or eq(action, "import") and eq(canonical, "--replace") or eq(action, "list") and eq(canonical, "--long"))) return error.InvalidAliasInput;
            if (isFlag(canonical)) {
                if (split != null) return error.InvalidAliasInput;
                try r.flags.put(a, canonical, {});
            } else if (isValueOption(canonical)) {
                const value = if (split) |at| arg[at + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.InvalidAliasInput;
                    break :blk args[i];
                };
                try nonempty(value);
                try r.values.put(a, canonical, value);
            } else return error.InvalidAliasInput;
        } else {
            if (r.count == r.positionals.len) return error.InvalidAliasInput;
            r.positionals[r.count] = arg;
            r.count += 1;
        }
    }
    return r;
}

fn envCredentials(env: *const std.process.Environ.Map) !?struct { ak: []const u8, sk: []const u8, token: []const u8 } {
    const ak = env.get("ZC_ACCESS_KEY_ID");
    const sk = env.get("ZC_SECRET_ACCESS_KEY");
    const token = env.get("ZC_SESSION_TOKEN");
    if (ak == null and sk == null and token == null) return null;
    if (ak == null or sk == null or ak.?.len == 0 or sk.?.len == 0) return error.IncompleteCredentials;
    return .{ .ak = ak.?, .sk = sk.?, .token = token orelse "" };
}

pub const Credentials = struct { access_key: []const u8, secret_key: []const u8, session_token: []const u8 = "" };
pub const Overrides = struct {
    credentials: ?Credentials = null,
    region: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    bucket_lookup: ?[]const u8 = null,
    insecure: ?bool = null,
    ca_cert: ?[]const u8 = null,
    connect_timeout: ?u32 = null,
    timeout: ?u32 = null,
};

// Runtime connection resolution never persists environment overrides or mixes credentials.
pub fn resolveConnection(saved: Alias, env: *const std.process.Environ.Map, overrides: Overrides) !Alias {
    var result = saved;
    if (overrides.credentials) |creds| {
        try nonempty(creds.access_key);
        try nonempty(creds.secret_key);
        result.access_key = creds.access_key;
        result.secret_key = creds.secret_key;
        result.session_token = creds.session_token;
    } else if (try envCredentials(env)) |creds| {
        result.access_key = creds.ak;
        result.secret_key = creds.sk;
        result.session_token = creds.token;
    }
    result.region = overrides.region orelse env.get("ZC_REGION") orelse saved.region;
    if (overrides.endpoint) |v| result.endpoint = v;
    if (overrides.bucket_lookup) |v| result.bucket_lookup = v;
    if (overrides.insecure) |v| result.insecure = v;
    if (overrides.ca_cert) |v| result.ca_cert = v;
    if (overrides.connect_timeout) |v| result.connect_timeout = v;
    if (overrides.timeout) |v| result.timeout = v;
    try validate(result);
    if (result.secret_key.len == 0) return error.CredentialsRequired;
    return result;
}

fn promptSecret(a: A, ctx: Context) ![]const u8 {
    if (builtin.os.tag == .windows) return error.PromptUnavailable;
    const stdin = Io.File.stdin();
    if (!try stdin.isTty(ctx.io) or !try Io.File.stderr().isTty(ctx.io)) return error.CredentialsRequired;
    const original = try std.posix.tcgetattr(stdin.handle);
    var settings = original;
    settings.lflag.ECHO = false;
    settings.lflag.ECHONL = false;
    settings.lflag.ICANON = false;
    settings.lflag.ISIG = false;
    settings.cc[@backingInt(std.posix.V.MIN)] = 1;
    settings.cc[@backingInt(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, settings);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};
    try Io.File.stderr().writeStreamingAll(ctx.io, "Secret key: ");
    defer Io.File.stderr().writeStreamingAll(ctx.io, "\n") catch {};
    var value: std.ArrayList(u8) = .empty;
    while (true) {
        var byte: [1]u8 = undefined;
        if (try stdin.readStreaming(ctx.io, &.{&byte}) == 0) return error.CredentialsRequired;
        switch (byte[0]) {
            3 => return error.Interrupted,
            4 => return error.CredentialsRequired,
            10, 13 => break,
            8, 127 => {
                if (value.items.len > 0) value.items.len -= 1;
            },
            else => {
                if (value.items.len >= 4096) return error.InvalidAliasInput;
                try value.append(a, byte[0]);
            },
        }
    }
    try nonempty(value.items);
    return value.items;
}

fn setAlias(a: A, ctx: Context, r: Request, json: bool) !Alias {
    if (r.count < 2 or r.count > 4) return error.InvalidAliasInput;
    var alias: Alias = .{ .name = r.positionals[0], .endpoint = r.positionals[1] };
    try validName(alias.name);
    try endpointValid(alias.endpoint);
    const env_source = r.values.get("--secret-key-from-env");
    const file_source = r.values.get("--secret-key-file");
    if (env_source != null and file_source != null or r.count == 4 and (env_source != null or file_source != null)) return error.InvalidAliasInput;
    if (r.count >= 3) {
        alias.access_key = r.positionals[2];
        alias.secret_key = if (r.count == 4) r.positionals[3] else if (env_source) |name| ctx.env.get(name) orelse return error.CredentialsRequired else if (file_source) |path| blk: {
            const bytes = try readFile(a, ctx.io, path, true);
            const value = std.mem.trimEnd(u8, bytes, "\r\n");
            try nonempty(value);
            break :blk value;
        } else if (!json) try promptSecret(a, ctx) else return error.CredentialsRequired;
        alias.session_token = r.values.get("--session-token") orelse "";
        try nonempty(alias.access_key);
        try nonempty(alias.secret_key);
    } else {
        if (env_source != null or file_source != null or r.values.contains("--session-token")) return error.IncompleteCredentials;
        const creds = try envCredentials(ctx.env) orelse return error.CredentialsRequired;
        alias.access_key = creds.ak;
        alias.secret_key = creds.sk;
        alias.session_token = creds.token;
    }
    alias.region = r.values.get("--region") orelse ctx.env.get("ZC_REGION") orelse alias.region;
    alias.signature = r.values.get("--signature") orelse alias.signature;
    alias.bucket_lookup = r.values.get("--bucket-lookup") orelse alias.bucket_lookup;
    alias.insecure = r.flags.contains("--insecure");
    alias.ca_cert = r.values.get("--ca-cert") orelse "";
    if (alias.ca_cert.len > 0) {
        alias.ca_cert = try std.fs.path.resolve(a, &.{alias.ca_cert});
        const pem = try readFile(a, ctx.io, alias.ca_cert, false);
        if (std.mem.indexOf(u8, pem, "-----BEGIN CERTIFICATE-----") == null or std.mem.indexOf(u8, pem, "-----END CERTIFICATE-----") == null) return error.InvalidCertificate;
    }
    alias.management_endpoint = r.values.get("--management-endpoint") orelse "";
    if (r.values.get("--connect-timeout")) |value| alias.connect_timeout = std.fmt.parseInt(u32, value, 10) catch return error.InvalidAliasInput;
    if (r.values.get("--timeout")) |value| alias.timeout = std.fmt.parseInt(u32, value, 10) catch return error.InvalidAliasInput;
    try validate(alias);
    return alias;
}

/// Verify before taking the configuration lock. Never follow redirects or echo
/// server diagnostics, which can contain credentials or signed request details.
fn verifyEndpoint(a: A, ctx: Context, alias: Alias) !void {
    const wire = @import("wire.zig");
    const xml = @import("xml.zig");
    const reply = try wire.send(a, ctx, .{
        .connection = alias,
        .method = "GET",
        .path = "/",
        .query = &.{.{ .name = "max-buckets", .value = "1" }},
    });
    if (reply.transport == 42) return error.Interrupted;
    if (reply.transport != 0) return error.EndpointUnreachable;
    if (reply.status >= 500 or reply.status == 429) return error.EndpointUnavailable;
    if (reply.status >= 300 and reply.status < 400) return error.EndpointRedirect;
    const node = xml.parse(a, reply.body) catch return error.NotS3Endpoint;
    if (reply.status == 200 and eq(node.name, "ListAllMyBucketsResult")) return;
    if (!eq(node.name, "Error")) return error.NotS3Endpoint;
    const code = xml.child(node, "Code") orelse return error.NotS3Endpoint;
    for ([_][]const u8{ "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidToken", "ExpiredToken", "TokenRefreshRequired" }) |invalid| {
        if (eq(code, invalid)) return error.EndpointCredentialsRejected;
    }
    if (eq(code, "AccessDenied") or eq(code, "AllAccessDisabled")) return error.EndpointPermissionDenied;
    return error.EndpointCheckFailed;
}

// Safe view excludes all three credential fields, including the access-key identifier.
const PublicAlias = struct {
    name: []const u8,
    endpoint: []const u8,
    region: []const u8,
    signature: []const u8,
    bucket_lookup: []const u8,
    insecure: bool,
    ca_cert: []const u8,
    connect_timeout: u32,
    timeout: u32,
    management_endpoint: []const u8,
};
fn public(alias: Alias) PublicAlias {
    var result: PublicAlias = undefined;
    inline for (@typeInfo(PublicAlias).@"struct".field_names) |field_name| @field(result, field_name) = @field(alias, field_name);
    return result;
}
fn views(a: A, aliases: []const Alias) ![]PublicAlias {
    const result = try a.alloc(PublicAlias, aliases.len);
    for (aliases, result) |alias, *out| out.* = public(alias);
    return result;
}
fn payload(a: A, value: anytype) !Output {
    return .{
        .json = try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = "aliases", .status = "success", .data = value }, .{}),
        .human = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }),
    };
}

pub fn execute(a: A, ctx: Context, action: []const u8, args: []const []const u8, explicit_path: ?[]const u8, json: bool) anyerror!Output {
    const r = try parseRequest(a, action, args);
    const path = try configPath(a, ctx.env, explicit_path);
    const mutation = eq(action, "set") or eq(action, "remove") or eq(action, "import");
    // Validate inputs before creating a lock directory or reading existing credentials.
    var prepared: ?Alias = null;
    var imported: ?Config = null;
    if (eq(action, "set")) {
        prepared = try setAlias(a, ctx, r, json);
        if (!r.flags.contains("--skip-check")) try verifyEndpoint(a, ctx, prepared.?);
    }
    if ((eq(action, "list") and r.count != 0) or ((eq(action, "info") or eq(action, "remove") or eq(action, "import")) and r.count != 1)) return error.InvalidAliasInput;
    if (eq(action, "info") or eq(action, "remove")) try validName(r.positionals[0]);
    if (eq(action, "import")) {
        const input = try readFileData(a, ctx.io, r.positionals[0]);
        const bytes = input.bytes;
        const parsed = std.json.parseFromSlice(struct { schema_version: u32, aliases: []const Alias }, a, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidConfiguration;
        const incoming: Config = .{ .schema_version = parsed.value.schema_version, .aliases = parsed.value.aliases };
        try validateConfig(incoming);
        for (parsed.value.aliases) |alias| if (alias.secret_key.len > 0) {
            if (!input.owner_only) return error.InsecurePermissions;
            break;
        };
        imported = incoming;
    }
    var lock: ?Io.File = null;
    defer if (lock) |file| file.close(ctx.io);
    if (mutation) {
        const parent = std.fs.path.dirname(path) orelse return error.InvalidConfiguration;
        _ = try Io.Dir.cwd().createDirPathStatus(ctx.io, parent, if (builtin.os.tag == .windows) .default_dir else @fromBackingInt(@intCast(0o700)));
        const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{path});
        lock = Io.Dir.cwd().openFile(ctx.io, lock_path, .{ .mode = .read_write, .follow_symlinks = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
            error.FileNotFound => try Io.Dir.cwd().createFile(ctx.io, lock_path, .{ .exclusive = true, .permissions = private_mode, .lock = .exclusive, .lock_nonblocking = true }),
            else => return err,
        };
        if ((try lock.?.stat(ctx.io)).kind != .file) return error.InvalidConfiguration;
    }
    const config = try load(a, ctx.io, path);
    var aliases: std.ArrayList(Alias) = .empty;
    try aliases.appendSlice(a, config.aliases);
    if (prepared) |alias| {
        if (find(config, alias.name)) |i| aliases.items[i] = alias else try aliases.append(a, alias);
    } else if (eq(action, "remove")) {
        const i = find(config, r.positionals[0]) orelse return error.AliasNotFound;
        _ = aliases.orderedRemove(i);
    } else if (imported) |incoming| {
        for (incoming.aliases) |alias| {
            if (find(config, alias.name)) |i| {
                if (!r.flags.contains("--replace")) return error.AliasConflict;
                aliases.items[i] = alias;
            } else try aliases.append(a, alias);
        }
    }
    std.mem.sort(Alias, aliases.items, {}, less);
    if (mutation) {
        const next: Config = .{ .aliases = aliases.items };
        try validateConfig(next);
        const bytes = try encodeToml(a, next);
        if (bytes.len > max_bytes) return error.InvalidConfiguration;
        try save(ctx.io, path, bytes, true);
        if (prepared != null) {
            return payload(a, .{
                .operation = action,
                .name = r.positionals[0],
                .count = @as(usize, 1),
                .verification = if (r.flags.contains("--skip-check")) "skipped" else "verified",
            });
        }
        return payload(a, .{ .operation = action, .name = if (imported != null) @as(?[]const u8, null) else r.positionals[0], .count = if (imported) |incoming| incoming.aliases.len else @as(usize, 1) });
    }
    if (eq(action, "info")) {
        const alias = aliases.items[find(.{ .aliases = aliases.items }, r.positionals[0]) orelse return error.AliasNotFound];
        return payload(a, .{ .alias = public(alias), .credentials_configured = alias.secret_key.len != 0, .session_token_configured = alias.session_token.len != 0 });
    }
    if (eq(action, "list")) return payload(a, .{ .aliases = try views(a, aliases.items) });
    if (eq(action, "export")) {
        const include = r.flags.contains("--include-credentials");
        if (include != r.flags.contains("--acknowledge-credentials")) return error.CredentialExportConfirmation;
        var selected: std.ArrayList(Alias) = .empty;
        if (r.count == 0) try selected.appendSlice(a, aliases.items) else {
            for (r.positionals[0..r.count]) |name| {
                if (find(.{ .aliases = selected.items }, name) != null) return error.DuplicateAlias;
                const i = find(.{ .aliases = aliases.items }, name) orelse return error.AliasNotFound;
                try selected.append(a, aliases.items[i]);
            }
        }
        std.mem.sort(Alias, selected.items, {}, less);
        const doc = if (include) try std.json.Stringify.valueAlloc(a, Config{ .aliases = selected.items }, .{ .whitespace = .indent_2 }) else try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .aliases = try views(a, selected.items) }, .{ .whitespace = .indent_2 });
        if (r.values.get("--output")) |target| {
            const target_parent = std.fs.path.dirname(target) orelse ".";
            const real_parent = try Io.Dir.cwd().realPathFileAlloc(ctx.io, target_parent, a);
            const resolved = try std.fs.path.join(a, &.{ real_parent, std.fs.path.basename(target) });
            const real_config_parent = Io.Dir.cwd().realPathFileAlloc(ctx.io, std.fs.path.dirname(path).?, a) catch |err| switch (err) {
                error.FileNotFound => std.fs.path.dirname(path).?,
                else => return err,
            };
            const real_config = try std.fs.path.join(a, &.{ real_config_parent, std.fs.path.basename(path) });
            if (eq(resolved, real_config) or eq(resolved, try std.fmt.allocPrint(a, "{s}.lock", .{real_config}))) return error.InvalidAliasInput;
            if (eq(resolved, path) or eq(resolved, try std.fmt.allocPrint(a, "{s}.lock", .{path}))) return error.InvalidAliasInput;
            try save(ctx.io, resolved, doc, r.flags.contains("--force"));
            return payload(a, .{ .operation = "export", .count = selected.items.len, .includes_credentials = include });
        }
        if (r.flags.contains("--force")) return error.InvalidAliasInput;
        return .{ .json = doc, .human = doc, .raw = true };
    }
    return error.InvalidAliasInput;
}

pub const help =
    \\Alias configuration commands (set verifies S3 before saving):
    \\  alias set NAME ENDPOINT [ACCESS_KEY [SECRET_KEY]] [OPTIONS]
    \\  alias list [-l|--long]
    \\  alias info NAME
    \\  alias remove NAME
    \\  alias export [NAME]... [-o|--output FILE] [--force]
    \\               [--include-credentials --acknowledge-credentials]
    \\  alias import FILE [--replace]
    \\
    \\Set options: --secret-key-from-env NAME | --secret-key-file FILE
    \\  --skip-check  Save without connecting (offline or restricted credentials)
    \\  --session-token TOKEN  --region REGION  --signature v4
    \\  --bucket-lookup path|dns|auto (default path)  --insecure
    \\  --ca-cert FILE  --connect-timeout SECONDS (10)  --timeout SECONDS (300)
    \\  --management-endpoint URL
    \\URLs must be http(s) origins without userinfo, query or non-root path.
    \\Timeouts must be 1..86400; connect timeout must not exceed total timeout.
    \\Credential sources are mutually exclusive: positional pair, named env/file,
    \\or the complete ZC_ACCESS_KEY_ID/ZC_SECRET_ACCESS_KEY/ZC_SESSION_TOKEN group.
    \\An ACCESS_KEY without a secret source prompts only in a human POSIX terminal.
    \\JSON/noninteractive use requires explicit credentials. set replaces all fields.
    \\A signed ListBuckets probe must succeed before saving; failures preserve the old alias.
    \\AccessDenied means the probe lacks permission, not necessarily invalid credentials.
    \\--skip-check explicitly bypasses verification; success then reports verification=skipped.
    \\Import validates all entries first; --replace replaces conflicting aliases,
    \\including credentials (redacted imports contain no usable credentials).
    \\Export omits credentials unless both confirmation flags are present.
    \\Config and credential files require owner-only permissions on Unix.
    \\Examples: zc alias set local http://127.0.0.1:9000 AK --secret-key-file secret.txt
    \\          zc alias export local --output aliases.json
    \\
;

test "TOML roundtrip and atomic credential group validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config: Config = .{ .aliases = &.{.{ .name = "local", .endpoint = "https://example.com", .access_key = "a", .secret_key = "quote\"hash#back\\" }} };
    const decoded = try decodeToml(a, try encodeToml(a, config));
    try std.testing.expectEqualStrings(config.aliases[0].secret_key, decoded.aliases[0].secret_key);
    try std.testing.expectError(error.InvalidConfiguration, decodeToml(a, "schema_version=1\nschema_version=1"));
    try std.testing.expectError(error.InvalidConfiguration, decodeToml(a, "schema_version=1\n[[aliases]]\nname=\"a\""));
    try std.testing.expectError(error.IncompleteCredentials, validate(.{ .name = "a", .endpoint = "https://example.com", .access_key = "only-ak" }));
    try std.testing.expectError(error.InvalidEndpoint, endpointValid("https://secret@example.com"));
    try std.testing.expectError(error.InvalidEndpoint, endpointValid("https://example.com/bucket"));
}

test "runtime explicit environment and alias precedence does not mix credentials" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const saved: Alias = .{ .name = "saved", .endpoint = "https://example.test", .access_key = "saved-ak", .secret_key = "saved-sk", .session_token = "saved-token" };
    try std.testing.expectEqualStrings("saved-token", (try resolveConnection(saved, &env, .{})).session_token);
    try env.put("ZC_ACCESS_KEY_ID", "env-ak");
    try std.testing.expectError(error.IncompleteCredentials, resolveConnection(saved, &env, .{}));
    try env.put("ZC_SECRET_ACCESS_KEY", "env-sk");
    try env.put("ZC_REGION", "env-1");
    const resolved = try resolveConnection(saved, &env, .{});
    try std.testing.expectEqualStrings("env-sk", resolved.secret_key);
    try std.testing.expectEqualStrings("", resolved.session_token);
    try std.testing.expectEqualStrings("env-1", resolved.region);
    const explicit = try resolveConnection(saved, &env, .{ .credentials = .{ .access_key = "explicit-ak", .secret_key = "explicit-sk" }, .region = "explicit-1" });
    try std.testing.expectEqualStrings("explicit-sk", explicit.secret_key);
    try std.testing.expectEqualStrings("explicit-1", explicit.region);
    try std.testing.expectEqualStrings("saved-token", saved.session_token);
}

// The HTTP client loads a saved alias and resolves runtime overrides without mutation.
pub fn connection(a: A, ctx: Context, explicit_path: ?[]const u8, name: []const u8, overrides: Overrides) !Alias {
    try validName(name);
    const config = try load(a, ctx.io, try configPath(a, ctx.env, explicit_path));
    const index = find(config, name) orelse return error.AliasNotFound;
    return resolveConnection(config.aliases[index], ctx.env, overrides);
}
