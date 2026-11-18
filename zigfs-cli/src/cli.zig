const std = @import("std");
const aliases = @import("alias.zig");
const management = @import("management.zig");
const modeled = @import("modeled.zig");
const share = @import("share.zig");
const versions = @import("versions.zig");
const bulk = @import("bulk.zig");
const multipart = @import("multipart.zig");
const objects = @import("objects.zig");
const browse = @import("browse.zig");
const s3api = @import("s3api.zig");

pub const version = "0.1.0";
pub const Format = enum { auto, human, json };
pub const Options = struct {
    format: Format = .auto,
    no_color: bool = false,
    no_progress: bool = false,
    quiet: bool = false,
    debug: bool = false,
};
pub const Command = enum { help, version, alias, s3api, browse, objects, multipart, share, modeled, unavailable };
pub const ParseError = error{ UnknownOption, UnknownCommand, MissingValue, InvalidFormat, ConflictingOptions, UnexpectedArgument, TooManyArguments };

const Entry = struct {
    path: []const u8,
    alias: ?[]const u8 = null,
    description: []const u8,
    group: bool = false,
    implemented: bool = false,
    modeled: bool = false,
};

// Reserved entries provide help only. Add real handlers when their implementation lands.
const base_registry = [_]Entry{
    .{ .path = "object share", .alias = "share", .description = "Generate a presigned S3 URL", .implemented = true },
    .{ .path = "share post", .description = "Generate signed POST form fields", .implemented = true },
    .{ .path = "object post", .description = "Upload a signed browser POST form", .implemented = true },
    .{ .path = "multipart", .description = "Manage multipart uploads", .group = true, .implemented = true },
    .{ .path = "pipe", .description = "Upload stdin using bounded multipart buffering", .implemented = true },
    .{ .path = "multipart create", .description = "create multipart upload", .implemented = true },
    .{ .path = "multipart upload-part", .description = "upload-part multipart upload", .implemented = true },
    .{ .path = "multipart parts", .description = "parts multipart upload", .implemented = true },
    .{ .path = "multipart list", .description = "list multipart upload", .implemented = true },
    .{ .path = "multipart complete", .description = "complete multipart upload", .implemented = true },
    .{ .path = "multipart abort", .description = "abort multipart upload", .implemented = true },
    .{ .path = "s3api", .description = "S3 protocol operations", .group = true, .implemented = true },
    .{ .path = "s3api create-multipart-upload", .description = "create-multipart-upload", .implemented = true },
    .{ .path = "s3api upload-part", .description = "upload-part", .implemented = true },
    .{ .path = "s3api list-parts", .description = "list-parts", .implemented = true },
    .{ .path = "s3api list-multipart-uploads", .description = "list-multipart-uploads", .implemented = true },
    .{ .path = "s3api complete-multipart-upload", .description = "complete-multipart-upload", .implemented = true },
    .{ .path = "s3api abort-multipart-upload", .description = "abort-multipart-upload", .implemented = true },
    .{ .path = "s3api copy-object", .description = "copy-object", .implemented = true },
    .{ .path = "s3api delete-object", .description = "delete-object", .implemented = true },
    .{ .path = "s3api delete-objects", .description = "delete-objects", .implemented = true },
    .{ .path = "s3api get-bucket-versioning", .description = "get-bucket-versioning", .implemented = true },
    .{ .path = "s3api delete-bucket", .description = "Delete an empty bucket (--yes required)", .implemented = true },
    .{ .path = "s3api create-bucket", .description = "Create a bucket with an optional XML location constraint", .implemented = true },
    .{ .path = "s3api list-buckets", .description = "List one page of buckets", .implemented = true },
    .{ .path = "s3api head-bucket", .description = "Check bucket metadata", .implemented = true },
    .{ .path = "s3api get-bucket-location", .description = "Read bucket location", .implemented = true },
    .{ .path = "s3api list-objects-v2", .description = "List one page of objects", .implemented = true },
    .{ .path = "s3api head-object", .description = "Read object metadata", .implemented = true },
    .{ .path = "s3api get-object", .description = "Stream object content", .implemented = true },
    .{ .path = "s3api put-object", .description = "Stream a signed object upload", .implemented = true },

    .{ .path = "alias", .description = "Manage local connection aliases", .group = true, .implemented = true },
    .{ .path = "alias set", .description = "Configure an endpoint and credentials", .implemented = true },
    .{ .path = "alias list", .description = "List aliases without credentials", .implemented = true },
    .{ .path = "alias info", .description = "Inspect saved alias settings", .implemented = true },
    .{ .path = "alias remove", .description = "Remove a saved alias", .implemented = true },
    .{ .path = "alias export", .description = "Export portable alias JSON", .implemented = true },
    .{ .path = "alias import", .description = "Validate and import alias JSON", .implemented = true },
    .{ .path = "bucket", .description = "Bucket command group", .group = true, .implemented = true },
    .{ .path = "object", .description = "Object command group", .group = true, .implemented = true },
    .{ .path = "bucket list", .description = "List buckets", .implemented = true },
    .{ .path = "bucket create", .alias = "mb", .description = "Create a bucket", .implemented = true },
    .{ .path = "bucket remove", .alias = "rb", .description = "Remove a bucket", .implemented = true },
    .{ .path = "bucket stat", .description = "Check bucket access", .implemented = true },
    .{ .path = "bucket location", .description = "Read bucket region", .implemented = true },
    .{ .path = "bucket version", .alias = "version", .description = "Manage bucket versioning; use --version for the CLI version", .group = true, .implemented = true, .modeled = true },
    .{ .path = "object put", .alias = "put", .description = "Upload one object", .implemented = true },
    .{ .path = "object get", .alias = "get", .description = "Download one object", .implemented = true },
    .{ .path = "object list", .description = "List objects", .implemented = true },
    .{ .path = "object copy", .alias = "cp", .description = "Copy, upload or download objects", .implemented = true },
    .{ .path = "object move", .alias = "mv", .description = "Move objects", .implemented = true },
    .{ .path = "object remove-batch", .description = "Delete up to 1000 explicit keys", .implemented = true },
    .{ .path = "object remove", .alias = "rm", .description = "Remove objects", .implemented = true },
    .{ .path = "object stat", .alias = "stat", .description = "Inspect object metadata", .implemented = true },
    .{ .path = "object show", .alias = "cat", .description = "Print object content", .implemented = true },
    .{ .path = "object head", .alias = "head", .description = "Print the beginning of an object", .implemented = true },
    .{ .path = "ls", .description = "List buckets or objects according to the remote path", .implemented = true },
};

const workflows = @import("workflows.zig");
const convenience = @import("convenience.zig");
const catalog = struct {
    const entries = @import("catalog.zig").entries ++ @import("management_catalog.zig").entries ++ workflows.entries ++ @import("compat_catalog.zig").entries;
};
const registry_data = buildRegistry();
const registry = registry_data.items[0..registry_data.len];
const RegistryData = struct { items: [base_registry.len + catalog.entries.len * 5]Entry, len: usize };
fn buildRegistry() RegistryData {
    @setEvalBranchQuota(500000);
    var result: RegistryData = undefined;
    result.len = base_registry.len;
    @memcpy(result.items[0..base_registry.len], &base_registry);
    for (catalog.entries) |entry| {
        for (entry.path, 0..) |c, i| {
            if (c != ' ') continue;
            const prefix = entry.path[0..i];
            var found = false;
            for (result.items[0..result.len]) |old| if (std.mem.eql(u8, old.path, prefix)) {
                found = true;
                break;
            };
            if (!found) {
                result.items[result.len] = .{ .path = prefix, .description = "Pending-validation command group", .group = true, .implemented = true, .modeled = true };
                result.len += 1;
            }
        }
        result.items[result.len] = .{ .path = entry.path, .description = "Connected; pending validation", .implemented = true, .modeled = true };
        result.len += 1;
    }
    return result;
}

pub const Invocation = struct {
    command: Command = .help,
    options: Options = .{},
    entry: ?usize = null,
    config_path: ?[]const u8 = null,
    args: [256][]const u8 = undefined,
    arg_count: usize = 0,

    fn append(self: *Invocation, arg: []const u8) ParseError!void {
        if (self.arg_count == self.args.len) return error.TooManyArguments;
        self.args[self.arg_count] = arg;
        self.arg_count += 1;
    }
};

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn rootEntry(name: []const u8) ?usize {
    for (registry, 0..) |entry, i| {
        if (equal(entry.path, name)) return i;
        if (entry.alias) |alias| if (equal(alias, name)) return i;
    }
    return null;
}

fn childEntry(parent: usize, name: []const u8) ?usize {
    const prefix = registry[parent].path;
    for (registry, 0..) |entry, i| {
        if (std.mem.startsWith(u8, entry.path, prefix) and entry.path.len > prefix.len and
            entry.path[prefix.len] == ' ' and equal(entry.path[prefix.len + 1 ..], name)) return i;
    }
    return null;
}

fn setFormat(options: *Options, value: []const u8, explicit: *?Format) ParseError!void {
    const format = std.meta.stringToEnum(Format, value) orelse return error.InvalidFormat;
    if (explicit.*) |previous| if (previous != format) return error.ConflictingOptions;
    explicit.* = format;
    options.format = format;
}

pub fn parse(args: []const []const u8) ParseError!Invocation {
    var result: Invocation = .{};
    var explicit_format: ?Format = null;
    var help = false;
    var show_version = false;
    var end_options = false;
    var operands: usize = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!end_options and equal(arg, "--")) {
            if (result.entry) |id| if (registry[id].implemented and !registry[id].group) try result.append(arg);
            end_options = true;
            continue;
        }
        if (!end_options and arg.len > 1 and std.mem.startsWith(u8, arg, "-")) {
            if (equal(arg, "-H") or equal(arg, "--header") or std.mem.startsWith(u8, arg, "--header=")) {
                try result.append(arg);
                if (std.mem.indexOfScalar(u8, arg, '=') == null) {
                    index += 1;
                    if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingValue;
                    try result.append(args[index]);
                }
            } else if (equal(arg, "--config") or std.mem.startsWith(u8, arg, "--config=")) {
                if (result.config_path != null) return error.ConflictingOptions;
                const value = if (equal(arg, "--config")) blk: {
                    index += 1;
                    if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingValue;
                    break :blk args[index];
                } else arg[9..];
                if (value.len == 0) return error.MissingValue;
                result.config_path = value;
            } else if (equal(arg, "--help") or equal(arg, "-h")) {
                help = true;
            } else if (equal(arg, "--version") or equal(arg, "-V")) {
                show_version = true;
            } else if (equal(arg, "--json")) {
                try setFormat(&result.options, "json", &explicit_format);
            } else if (equal(arg, "--format")) {
                index += 1;
                if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingValue;
                try setFormat(&result.options, args[index], &explicit_format);
            } else if (std.mem.startsWith(u8, arg, "--format=")) {
                const value = arg[9..];
                if (value.len == 0) return error.MissingValue;
                try setFormat(&result.options, value, &explicit_format);
            } else if (equal(arg, "--no-color")) {
                result.options.no_color = true;
            } else if (equal(arg, "--no-progress")) {
                result.options.no_progress = true;
            } else if (equal(arg, "--quiet") or equal(arg, "-q")) {
                result.options.quiet = true;
            } else if (equal(arg, "--debug")) {
                result.options.debug = true;
            } else if (result.entry != null and registry[result.entry.?].implemented and !registry[result.entry.?].group) {
                const split = std.mem.indexOfScalar(u8, arg, '=');
                const name = if (split) |at| arg[0..at] else arg;
                const protocol = std.mem.startsWith(u8, registry[result.entry.?].path, "s3api ");
                const sharing = share.wanted(registry[result.entry.?].path);
                const multi = std.mem.startsWith(u8, registry[result.entry.?].path, "multipart ") or equal(registry[result.entry.?].path, "pipe");
                const transfer = std.mem.startsWith(u8, registry[result.entry.?].path, "object ") and !equal(registry[result.entry.?].path, "object list");
                const high = !std.mem.startsWith(u8, registry[result.entry.?].path, "alias ");
                const flag = if (registry[result.entry.?].modeled) modeled.isFlag(name) else if (sharing) share.isFlag(name) else if (bulk.isFlag(name)) true else if (multi) multipart.isFlag(name) else if (transfer) objects.isFlag(name) else if (high and !protocol) browse.isFlag(name) else if (protocol) s3api.isFlag(name) else aliases.isFlag(name);
                const value_option = if (registry[result.entry.?].modeled) !modeled.isFlag(name) else if (sharing) share.isValueOption(name) else if (bulk.isValueOption(name)) true else if (multi) multipart.isValueOption(name) else if (transfer) objects.isValueOption(name) else if (high and !protocol) browse.isValueOption(name) else if (protocol) s3api.isValueOption(name) else aliases.isValueOption(name);
                if (!flag and !value_option) return error.UnknownOption;
                try result.append(arg);
                if (value_option and split == null) {
                    index += 1;
                    if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingValue;
                    try result.append(args[index]);
                }
            } else return error.UnknownOption;
            continue;
        }
        if (result.entry) |entry| {
            if (!end_options and equal(registry[entry].path, "object share") and equal(arg, "post") and operands == 0) {
                result.entry = childEntryByShare();
            } else if (registry[entry].group) {
                result.entry = childEntry(entry, arg) orelse return error.UnknownCommand;
                if (end_options and registry[result.entry.?].implemented) try result.append("--");
            } else {
                operands += 1;
                try result.append(arg);
            }
        } else if (equal(arg, "help") and !help) {
            help = true;
        } else {
            result.entry = rootEntry(arg) orelse return error.UnknownCommand;
            if (end_options and registry[result.entry.?].implemented and !registry[result.entry.?].group) try result.append("--");
        }
    }
    if (show_version) {
        if (help or result.entry != null or operands != 0) return error.ConflictingOptions;
        result.command = .version;
    } else if (help) {
        if (operands != 0) return error.UnexpectedArgument;
        result.command = .help;
    } else if (result.entry) |entry| {
        result.command = if (registry[entry].group) .help else if (registry[entry].implemented) if (registry[entry].modeled) .modeled else if (share.wanted(registry[entry].path)) .share else if (std.mem.startsWith(u8, registry[entry].path, "s3api ")) .s3api else if (std.mem.startsWith(u8, registry[entry].path, "alias ")) .alias else if (std.mem.startsWith(u8, registry[entry].path, "multipart ") or equal(registry[entry].path, "pipe")) .multipart else if (std.mem.startsWith(u8, registry[entry].path, "object ") and !equal(registry[entry].path, "object list")) .objects else .browse else .unavailable;
    }
    return result;
}

const global_help =
    \\Options (before or after a command):
    \\  -h, --help                 Show help without connecting to a server
    \\  -V, --version              Show CLI version (cannot accompany a command)
    \\  --format auto|human|json   Output format; default: auto (human in step 01)
    \\  --json                     Equivalent to --format json
    \\  --config FILE              Override ZC_CONFIG_FILE / XDG / HOME config path
    \\  -H, --header NAME:VALUE     Add a signed x-amz-* header (S3 commands)
    \\  --no-color                 Disable colors (currently no color output)
    \\  --no-progress              Disable progress (currently no transfers)
    \\  -q, --quiet                Suppress human success output; keep JSON/errors
    \\  --debug                    Enable diagnostics; never echo arguments/secrets
    \\  --                         End option parsing
    \\
    \\Different explicit formats conflict. Short options cannot be combined.
    \\Exit codes: 0 success, 1 general, 2 usage, 3 network, 4 permission,
    \\            5 not found, 6 conflict, 7 unsupported, 130 interrupted.
    \\
;

fn helpText(allocator: std.mem.Allocator, entry_id: ?usize) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    const w = &text.writer;
    if (entry_id) |id| {
        const entry = registry[id];
        try w.print("ZigFS CLI (zc)\nUsage: zc {s} [OPTIONS]\n{s}\n", .{ entry.path, entry.description });
        if (entry.modeled and std.mem.startsWith(u8, entry.path, "admin ") and !entry.group) try w.writeAll(try management.describe(allocator, convenience.canonical(entry.path)));
        if (entry.alias) |alias| try w.print("Alias: {s}\n", .{alias});
        if (entry.implemented) {
            try w.writeAll(if (entry.modeled) if (convenience.wanted(entry.path)) (if (std.mem.startsWith(u8, entry.path, "admin ")) @import("admin_workflows.zig").help(convenience.canonical(entry.path)) else convenience.help) else if (std.mem.startsWith(u8, entry.path, "admin")) management.help else if (workflows.wanted(entry.path)) workflows.help else modeled.help else if (share.wanted(entry.path)) share.help else if (std.mem.startsWith(u8, entry.path, "s3api")) s3api.help else if (std.mem.startsWith(u8, entry.path, "alias")) aliases.help else if (std.mem.startsWith(u8, entry.path, "object ") and !equal(entry.path, "object list")) objects.help else if (std.mem.startsWith(u8, entry.path, "multipart") or equal(entry.path, "pipe")) multipart.help else browse.help);
        } else try w.writeAll("Status: reserved, not implemented. Help is available; business execution exits 7.\n");
        if (entry.implemented and (std.mem.startsWith(u8, entry.path, "object") or equal(entry.path, "bucket remove"))) try w.writeAll(bulk.help);
        if (entry.implemented and (equal(entry.path, "object remove") or equal(entry.path, "bucket remove"))) try w.writeAll(versions.help);
        if (entry.group) {
            try w.writeAll(if (entry.implemented) "Subcommands:\n" else "Reserved subcommands (help only):\n");
            for (registry) |child| {
                if (std.mem.startsWith(u8, child.path, entry.path) and child.path.len > entry.path.len and child.path[entry.path.len] == ' ')
                    try w.print("  {s}{s}\n", .{ child.path[entry.path.len + 1 ..], if (child.implemented) "" else " (reserved)" });
            }
        }
        try w.print("Example: zc {s} --help\n\n", .{entry.path});
    } else {
        try w.writeAll("ZigFS CLI (zc)\nUsage: zc [OPTIONS] [COMMAND]\n       zc help [COMMAND [SUBCOMMAND]]\n\nAvailable: help, --version, alias set/list/info/remove/export/import, s3api\nAvailable: bucket list/create/stat/location/remove, object list/put/get/stat/show/head/copy, ls/mb/rb/put/get/cat/head/stat/cp\nAvailable: mv/rm, object remove-batch, multipart create/upload-part/parts/list/complete/abort, pipe\nAvailable: share, object share, share post, object post\nAvailable: version, tag, cors, retention, legalhold, ilm, event, quota, anonymous\nAvailable: find/tree/du/diff/mirror/watch/completions and admin command groups (pending validation)\ns3api performs signed HTTP requests; alias commands only manage local settings.\nUse --version for the CLI version; version manages bucket versioning.\nExamples: zc --version; zc bucket --help; zc help object copy\n\n");
    }
    try w.writeAll(global_help);
    return try allocator.dupe(u8, text.written());
}

fn errorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.UnknownOption => "unknown option; use --help",
        error.UnknownCommand => "unknown command; use --help",
        error.MissingValue => "option requires a nonempty value; use --help",
        error.TooManyArguments => "too many arguments",
        error.InvalidFormat => "invalid format; expected auto, human or json",
        error.ConflictingOptions => "conflicting options or --version combined with a command",
        error.UnexpectedArgument => "unexpected argument after help command",
    };
}

// Inspect only output selectors before '--' so even malformed invocations have JSON errors.
// Do not echo raw arguments: future commands may contain secrets.
fn wantsJson(args: []const []const u8) bool {
    for (args, 0..) |arg, i| {
        if (equal(arg, "--")) break;
        if (equal(arg, "--json") or equal(arg, "--format=json")) return true;
        if (equal(arg, "--format") and i + 1 < args.len and equal(args[i + 1], "json")) return true;
    }
    return false;
}

pub const Response = struct {
    exit_code: u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

fn failure(allocator: std.mem.Allocator, json: bool, code: []const u8, message: []const u8, exit_code: u8) !Response {
    const body = if (json)
        try std.json.Stringify.valueAlloc(allocator, .{ .schema_version = 1, .type = "error", .status = "error", .@"error" = .{ .code = code, .message = message } }, .{})
    else
        try std.fmt.allocPrint(allocator, "zc: {s}", .{message});
    defer allocator.free(body);
    return .{ .exit_code = exit_code, .stderr = try std.fmt.allocPrint(allocator, "{s}\n", .{body}) };
}

// Response allocations belong to the caller's arena; this also makes output contracts testable.
pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !Response {
    return executeWithContext(allocator, args, null);
}

fn completions(a: std.mem.Allocator, args: []const []const u8) !Response {
    if (args.len != 1) return error.InvalidInput;
    const shell = args[0];
    var out: std.Io.Writer.Allocating = .init(a);
    if (equal(shell, "bash")) {
        try out.writer.writeAll("_zc_complete() { local prefix=\"${COMP_WORDS[*]:1:COMP_CWORD-1}\" line tail; COMPREPLY=(); while IFS= read -r line; do if [[ -z \"$prefix\" ]]; then tail=\"$line\"; elif [[ \"$line\" == \"$prefix \"* ]]; then tail=\"${line#\"$prefix \"}\"; else continue; fi; tail=\"${tail%% *}\"; [[ \"$tail\" == \"${COMP_WORDS[COMP_CWORD]}\"* ]] && COMPREPLY+=(\"$tail\"); done <<'ZC_COMMANDS'\n");
        for (registry) |entry| if (entry.implemented) {
            try out.writer.print("{s}\n", .{entry.path});
            if (entry.alias) |alias| try out.writer.print("{s}\n", .{alias});
        };
        try out.writer.writeAll("ZC_COMMANDS\n}\ncomplete -F _zc_complete zc\n");
    } else if (equal(shell, "zsh")) {
        try out.writer.writeAll("#compdef zc\n_zc() { local prefix=\"${(j: :)words[2,CURRENT-1]}\" line tail; local -a choices; while IFS= read -r line; do if [[ -z \"$prefix\" ]]; then tail=\"$line\"; elif [[ \"$line\" == \"$prefix \"* ]]; then tail=\"${line#\"$prefix \"}\"; else continue; fi; choices+=(\"${tail%% *}\"); done <<'ZC_COMMANDS'\n");
        for (registry) |entry| if (entry.implemented) {
            try out.writer.print("{s}\n", .{entry.path});
            if (entry.alias) |alias| try out.writer.print("{s}\n", .{alias});
        };
        try out.writer.writeAll("ZC_COMMANDS\ncompadd -a choices\n}\ncompdef _zc zc\n");
    } else if (equal(shell, "fish")) {
        for (registry) |entry| if (entry.implemented) {
            const cut = std.mem.lastIndexOfScalar(u8, entry.path, ' ');
            if (cut) |i| try out.writer.print("complete -c zc -f -n '__fish_seen_subcommand_from {s}' -a '{s}'\n", .{ entry.path[0..i], entry.path[i + 1 ..] }) else try out.writer.print("complete -c zc -f -n '__fish_use_subcommand' -a '{s}'\n", .{entry.path});
        };
    } else return error.InvalidInput;
    return .{ .exit_code = 0, .stdout = out.written() };
}
fn executeWithContext(allocator: std.mem.Allocator, args: []const []const u8, context: ?aliases.Context) !Response {
    const invocation = parse(args) catch |err| return failure(allocator, wantsJson(args), "USAGE_ERROR", errorMessage(err), 2);
    const json = invocation.options.format == .json;
    if (invocation.command == .modeled and equal(registry[invocation.entry.?].path, "completions")) return completions(allocator, invocation.args[0..invocation.arg_count]) catch return failure(allocator, json, "USAGE_ERROR", "completions requires bash, zsh or fish", 2);
    if (invocation.command == .s3api or invocation.command == .browse or invocation.command == .objects or invocation.command == .multipart or invocation.command == .share or invocation.command == .modeled) {
        const ctx = context orelse return failure(allocator, json, "GENERAL_ERROR", "network context unavailable", 1);
        const bulk_command = bulk.wanted(registry[invocation.entry.?].path, invocation.args[0..invocation.arg_count]);
        const handler: *const @TypeOf(s3api.execute) = if (versions.wanted(registry[invocation.entry.?].path, invocation.args[0..invocation.arg_count])) &versions.execute else if (invocation.command == .modeled) if (convenience.wanted(registry[invocation.entry.?].path)) &convenience.execute else if (std.mem.startsWith(u8, registry[invocation.entry.?].path, "admin ")) &management.execute else if (workflows.wanted(registry[invocation.entry.?].path)) &workflows.execute else &modeled.execute else if (invocation.command == .share) &share.execute else if (bulk_command) &bulk.execute else if (invocation.command == .multipart) &multipart.execute else if (invocation.command == .objects) &objects.execute else if (invocation.command == .browse) &browse.execute else &s3api.execute;
        const path = registry[invocation.entry.?].path;
        const output = handler(allocator, ctx, if (invocation.command != .s3api) path else path[6..], invocation.args[0..invocation.arg_count], invocation.config_path, json, invocation.options.quiet) catch |err| {
            const code: u8 = switch (err) {
                error.AliasNotFound, error.FileNotFound => 5,
                error.PathAlreadyExists, error.ResumeMismatch, error.WouldBlock => 6,
                error.AccessDenied, error.InsecurePermissions => 4,
                error.UnsupportedOperation, error.UnsupportedSignature => 7,
                error.Interrupted, error.Canceled, error.Cancelled => 130,
                error.InvalidInput, error.ConflictingOptions, error.UnknownInputField, error.ConfirmationRequired, error.RawOutputConflict, error.InvalidHeader, error.DuplicateHeader, error.InvalidAliasInput, error.InvalidEndpoint, error.InvalidConfiguration, error.DuplicateAlias, error.IncompleteCredentials, error.CredentialsRequired, error.MissingHome => 2,
                else => 1,
            };
            const message = switch (err) {
                error.ResumeMismatch => "resume source, layout, identity or remote parts differ; upload was not completed",
                error.InvalidResponse => "invalid server response, pagination, resume data or safety limit exceeded",
                error.ScanLimitExceeded => "cumulative scan budget exceeded; no complete result available",
                error.ConflictingOptions => "conflicting options; file input cannot be combined with shortcut fields",
                error.Interrupted, error.Canceled, error.Cancelled => "interrupted; in-flight mutations may have an unknown outcome",
                error.UnknownInputField => "unknown or not-yet-supported operation input field",
                error.ConfirmationRequired => "write/delete operation requires --yes",
                error.RawOutputConflict => "JSON downloads require --output FILE; raw stdout cannot contain JSON metadata",
                error.PathAlreadyExists => "output file already exists; choose a new path",
                error.AliasNotFound => "alias not found",
                error.IncompleteCredentials => "incomplete credential group; sources are not mixed",
                error.CredentialsRequired => "alias or environment credentials are required",
                error.InvalidHeader, error.DuplicateHeader => "invalid, duplicate or reserved request header",
                else => "invalid request or local I/O failure; check input schema, configuration and file permissions (values redacted)",
            };
            return failure(allocator, json, switch (code) {
                2 => "USAGE_ERROR",
                4 => "PERMISSION_DENIED",
                5 => "NOT_FOUND",
                6 => "CONFLICT",
                7 => "NOT_SUPPORTED",
                else => "GENERAL_ERROR",
            }, message, code);
        };
        return .{ .exit_code = output.exit_code, .stdout = output.stdout, .stderr = output.stderr };
    }
    if (invocation.command == .alias) {
        const ctx = context orelse return failure(allocator, json, "GENERAL_ERROR", "alias commands require a local configuration context", 1);
        const action = registry[invocation.entry.?].path[6..];
        const output = aliases.execute(allocator, ctx, action, invocation.args[0..invocation.arg_count], invocation.config_path, json) catch |err| {
            const code: u8 = switch (err) {
                error.AliasNotFound, error.FileNotFound => 5,
                error.AliasConflict, error.PathAlreadyExists, error.WouldBlock => 6,
                error.AccessDenied, error.InsecurePermissions => 4,
                error.Interrupted => 130,
                error.UnsupportedSignature, error.PromptUnavailable => 7,
                error.InvalidAliasInput, error.InvalidEndpoint, error.InvalidConfiguration, error.DuplicateAlias, error.IncompleteCredentials, error.CredentialsRequired, error.CredentialExportConfirmation, error.MissingHome, error.InvalidCertificate, error.SymLinkLoop => 2,
                else => 1,
            };
            const message = switch (err) {
                error.AliasNotFound => "alias not found",
                error.AliasConflict => "alias conflict; use --replace to replace existing entries",
                error.PathAlreadyExists => "output or lock already exists; retry or explicitly select --force for export",
                error.WouldBlock => "configuration is locked by another writer; retry",
                error.InsecurePermissions => "credential-bearing files require owner-only permissions (chmod 600)",
                error.IncompleteCredentials => "incomplete credential group; access key, secret key and token cannot mix sources",
                error.CredentialsRequired => "credentials required; supply a complete environment group or explicit secret source",
                error.CredentialExportConfirmation => "credential export requires --include-credentials and --acknowledge-credentials",
                error.UnsupportedSignature => "only Signature V4 is supported",
                error.InvalidEndpoint => "invalid endpoint; use an http(s) origin without userinfo, query or path",
                error.InvalidConfiguration => "invalid or unsupported configuration; no aliases were written",
                error.FileNotFound => "input file or directory not found",
                error.InvalidCertificate => "CA file must contain PEM certificate markers; TLS verification occurs when connecting",
                error.Interrupted => "interrupted; configuration not changed",
                else => "alias operation failed; check arguments, file permissions and configuration (values redacted)",
            };
            return failure(allocator, json, switch (code) {
                2 => "USAGE_ERROR",
                4 => "PERMISSION_DENIED",
                5 => "NOT_FOUND",
                6 => "CONFLICT",
                7 => "NOT_SUPPORTED",
                130 => "INTERRUPTED",
                else => "GENERAL_ERROR",
            }, message, code);
        };
        if (invocation.options.quiet and !json and !output.raw) return .{ .exit_code = 0 };
        return .{ .exit_code = 0, .stdout = try std.fmt.allocPrint(allocator, "{s}\n", .{if (json) output.json else output.human}) };
    }
    if (invocation.command == .unavailable)
        return failure(allocator, json, "NOT_IMPLEMENTED", "command is reserved and not implemented; use --help (CLI version: --version)", 7);
    if (invocation.options.quiet and !json) return .{ .exit_code = 0 };
    const body = switch (invocation.command) {
        .help => try helpText(allocator, invocation.entry),
        .version => try std.fmt.allocPrint(allocator, "zc {s}\n", .{version}),
        .unavailable, .alias, .s3api, .browse, .objects, .multipart, .share, .modeled => unreachable,
    };
    if (!json) return .{ .exit_code = 0, .stdout = body };
    defer allocator.free(body);
    const output = if (invocation.command == .version)
        try std.json.Stringify.valueAlloc(allocator, .{ .schema_version = 1, .type = "version", .status = "success", .data = .{ .version = version } }, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, .{ .schema_version = 1, .type = "help", .status = "success", .data = .{ .text = body } }, .{});
    defer allocator.free(output);
    return .{ .exit_code = 0, .stdout = try std.fmt.allocPrint(allocator, "{s}\n", .{output}) };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, env: *const std.process.Environ.Map) !u8 {
    const response = try executeWithContext(allocator, args, .{ .io = io, .env = env });
    if (response.stdout.len != 0) try std.Io.File.stdout().writeStreamingAll(io, response.stdout);
    if (response.stderr.len != 0) try std.Io.File.stderr().writeStreamingAll(io, response.stderr);
    return response.exit_code;
}

test "help and version dispatch with strict option validation" {
    try std.testing.expectEqual(Command.help, (try parse(&.{})).command);
    for ([_][]const u8{ "-V", "--version" }) |flag|
        try std.testing.expectEqual(Command.version, (try parse(&.{flag})).command);
    try std.testing.expectEqual(Command.help, (try parse(&.{"version"})).command);
    try std.testing.expectError(error.UnknownOption, parse(&.{ "--help", "--typo" }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "bucket", "--version" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "help", "mv", "extra" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "bucket", "missing" }));
}

test "global options work before and after canonical commands and aliases" {
    const canonical = try parse(&.{ "--json", "bucket", "--debug", "version", "--help", "-q", "--no-color", "--no-progress" });
    const alias = try parse(&.{ "version", "--help", "--format=json" });
    try std.testing.expectEqual(canonical.entry, alias.entry);
    try std.testing.expectEqual(Format.json, canonical.options.format);
    try std.testing.expect(canonical.options.debug and canonical.options.quiet and canonical.options.no_color and canonical.options.no_progress);
    try std.testing.expectEqual(Command.help, (try parse(&.{ "help", "object", "move" })).command);
    try std.testing.expectEqual(Command.help, (try parse(&.{"bucket"})).command);
}

test "format values conflicts and end of options" {
    try std.testing.expectError(error.MissingValue, parse(&.{"--format"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--format="}));
    try std.testing.expectError(error.InvalidFormat, parse(&.{ "--format", "xml" }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "--format", "human", "--json" }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "--json", "--format=auto" }));
    try std.testing.expectEqual(Format.json, (try parse(&.{ "--json", "--format=json" })).options.format);
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "--", "--version" }));
    const literal = try parse(&.{ "version", "info", "--", "--json" });
    try std.testing.expectEqual(Format.auto, literal.options.format);
    try std.testing.expectEqual(Command.modeled, literal.command);
}

test "responses use correct streams codes and JSON without leaking arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try execute(a, &.{ "--json", "--secret=DO_NOT_ECHO" });
    try std.testing.expectEqual(@as(u8, 2), bad.exit_code);
    try std.testing.expectEqualStrings("", bad.stdout);
    try std.testing.expect(std.mem.indexOf(u8, bad.stderr, "DO_NOT_ECHO") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bad.stderr, .{});
    try std.testing.expectEqualStrings("USAGE_ERROR", parsed.value.object.get("error").?.object.get("code").?.string);
    const group_help = try execute(a, &.{ "--json", "version" });
    try std.testing.expectEqual(@as(u8, 0), group_help.exit_code);
    const result = try execute(a, &.{ "--quiet", "--json", "--version" });
    try std.testing.expectEqualStrings("", result.stderr);
    const v = try std.json.parseFromSlice(std.json.Value, a, result.stdout, .{});
    try std.testing.expectEqualStrings(version, v.value.object.get("data").?.object.get("version").?.string);
    const quiet = try execute(a, &.{ "-q", "--version" });
    try std.testing.expectEqualStrings("", quiet.stdout);
    const help = try execute(a, &.{ "bucket", "version", "--help", "--json" });
    _ = try std.json.parseFromSlice(std.json.Value, a, help.stdout, .{});
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "not implemented") == null);
}

test {
    std.testing.refAllDecls(aliases);
}

test "end of options before alias group remains literal in alias handler" {
    const invocation = try parse(&.{ "--", "alias", "set", "local", "http://localhost", "AK", "--secret" });
    try std.testing.expectEqualStrings("--", invocation.args[0]);
    try std.testing.expectEqualStrings("--secret", invocation.args[invocation.arg_count - 1]);
}

test {
    std.testing.refAllDecls(s3api);
}

test "single object aliases and literal stdout target" {
    for ([_][]const u8{ "put", "get", "cat", "head", "stat", "cp" }) |name| {
        try std.testing.expectEqual(Command.objects, (try parse(&.{name})).command);
    }
    const download = try parse(&.{ "get", "local/bucket/key", "-", "--quiet" });
    try std.testing.expectEqualStrings("-", download.args[1]);
    try std.testing.expect(download.options.quiet);
    try std.testing.expectEqual((try parse(&.{ "object", "copy" })).entry, (try parse(&.{"cp"})).entry);
}

test {
    std.testing.refAllDecls(multipart);
    std.testing.refAllDecls(share);
}

test {
    std.testing.refAllDecls(bulk);
}

fn childEntryByShare() usize {
    for (registry, 0..) |entry, i| if (equal(entry.path, "share post")) return i;
    unreachable;
}

test "scan budget enforces cumulative record and byte limits without changing failed accounting" {
    var budget: modeled.ScanBudget = .{};
    try budget.charge(60000, 32 * 1024 * 1024);
    try budget.charge(40000, 32 * 1024 * 1024);
    try std.testing.expectError(error.ScanLimitExceeded, budget.charge(1, 0));
    try std.testing.expectError(error.ScanLimitExceeded, budget.charge(0, 1));
    try std.testing.expectEqual(@as(usize, 100000), budget.records);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), budget.bytes);
}
