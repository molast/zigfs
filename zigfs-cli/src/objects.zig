const std = @import("std");
const aliases = @import("alias.zig");
const multipart = @import("multipart.zig");
const mutations = @import("mutations.zig");
const api = @import("s3api.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const fields = .{
    .{ "--server-side-encryption", "ServerSideEncryption" },
    .{ "--ssekms-key-id", "SSEKMSKeyId" },
    .{ "--ssekms-encryption-context", "SSEKMSEncryptionContext" },
    .{ "--sse-customer-algorithm", "SSECustomerAlgorithm" },
    .{ "--sse-customer-key", "SSECustomerKey" },
    .{ "--sse-customer-key-md5", "SSECustomerKeyMD5" },
    .{ "--storage-class", "StorageClass" },
    .{ "--tagging", "Tagging" },
    .{ "--object-lock-mode", "ObjectLockMode" },
    .{ "--object-lock-retain-until-date", "ObjectLockRetainUntilDate" },
    .{ "--object-lock-legal-hold-status", "ObjectLockLegalHoldStatus" },
    .{ "--version-id", "VersionId" },
    .{ "--content-type", "ContentType" },
    .{ "--content-encoding", "ContentEncoding" },
    .{ "--content-disposition", "ContentDisposition" },
    .{ "--content-language", "ContentLanguage" },
    .{ "--cache-control", "CacheControl" },
    .{ "--if-match", "IfMatch" },
    .{ "--if-none-match", "IfNoneMatch" },
    .{ "--if-modified-since", "IfModifiedSince" },
    .{ "--if-unmodified-since", "IfUnmodifiedSince" },
    .{ "--range", "Range" },
    .{ "--expected-bucket-owner", "ExpectedBucketOwner" },
    .{ "--request-payer", "RequestPayer" },
};
pub fn isFlag(n: []const u8) bool {
    return eq(n, "--resume") or eq(n, "--overwrite") or eq(n, "--yes") or eq(n, "--dry-run") or eq(n, "--insecure");
}
pub fn isValueOption(n: []const u8) bool {
    inline for (fields) |f| if (eq(n, f[0])) return true;
    for ([_][]const u8{ "--multipart-threshold", "--part-size", "--max-parts", "--state-file", "--metadata", "--metadata-directive", "--source-if-match", "--source-if-none-match", "--source-if-modified-since", "--source-if-unmodified-since", "--keys-file", "--file", "--checksum", "--checksum-sha256", "--offset", "--length", "--bytes", "--lines" }) |f| if (eq(n, f)) return true;
    return api.isValueOption(n) and !eq(n, "--body") and !eq(n, "--output") and !eq(n, "--input-json");
}
fn put(a: A, input: *V, key: []const u8, value: []const u8) !void {
    try input.object.put(a, key, .{ .string = value });
}
fn number(values: std.StringHashMapUnmanaged([]const u8), key: []const u8) !?u64 {
    return if (values.get(key)) |v| std.fmt.parseInt(u64, v, 10) catch return error.InvalidInput else null;
}
fn isRemote(a: A, ctx: aliases.Context, config: ?[]const u8, path: []const u8) !bool {
    if (std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or eq(path, "-")) return false;
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    _ = aliases.connection(a, ctx, config, path[0..slash], .{}) catch |err| switch (err) {
        error.AliasNotFound, error.InvalidAliasInput => return false,
        else => return err,
    };
    return true;
}
pub fn execute(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool) anyerror!api.Output {
    return executeAt(a, ctx, action, args, config, json, quiet, null);
}
pub fn executeAt(a: A, ctx: aliases.Context, action: []const u8, args: []const []const u8, config: ?[]const u8, json: bool, quiet: bool, output_dir: ?std.Io.Dir) anyerror!api.Output {
    var operands: std.ArrayList([]const u8) = .empty;
    var pass: std.ArrayList([]const u8) = .empty;
    var values: std.StringHashMapUnmanaged([]const u8) = .empty;
    var flags: std.StringHashMapUnmanaged(void) = .empty;
    var metadata: V = .{ .object = .{} };
    var ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ended and eq(arg, "--")) {
            ended = true;
            continue;
        }
        if (!ended and arg.len > 1 and arg[0] == '-') {
            const split = std.mem.indexOfScalar(u8, arg, '=');
            const n = if (split) |s| arg[0..s] else arg;
            if (flags.contains(n) or values.contains(n)) return error.InvalidInput;
            if (isFlag(n)) {
                if (split != null) return error.InvalidInput;
                try flags.put(a, n, {});
                if (eq(n, "--insecure")) try pass.append(a, n);
            } else if (isValueOption(n)) {
                const v = if (split) |s| arg[s + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return error.InvalidInput;
                    break :blk args[i];
                };
                if (v.len == 0) return error.InvalidInput;
                if (eq(n, "--metadata")) {
                    const at = std.mem.indexOfScalar(u8, v, '=') orelse return error.InvalidInput;
                    const key = try std.ascii.allocLowerString(a, v[0..at]);
                    if (key.len == 0 or metadata.object.contains(key)) return error.InvalidInput;
                    try put(a, &metadata, key, v[at + 1 ..]);
                } else if (eq(n, "-H") or eq(n, "--header")) try pass.appendSlice(a, &.{ n, v }) else try values.put(a, n, v);
            } else return error.InvalidInput;
        } else try operands.append(a, arg);
    }
    if (eq(action, "object move") or eq(action, "object remove") or eq(action, "object remove-batch"))
        return mutations.execute(a, ctx, action, operands.items, pass.items, values, flags, metadata, config, json, quiet);
    var op = action;
    if (eq(action, "object copy")) {
        if (operands.items.len != 2) return error.InvalidInput;
        const source = try isRemote(a, ctx, config, operands.items[0]);
        const destination = try isRemote(a, ctx, config, operands.items[1]);
        if (source and destination) return mutations.execute(a, ctx, action, operands.items, pass.items, values, flags, metadata, config, json, quiet);
        if (!source and !destination) return error.UnsupportedOperation;
        op = if (source) "object get" else "object put";
    }
    for ([_][]const u8{ "--metadata-directive", "--source-if-match", "--source-if-none-match", "--source-if-modified-since", "--source-if-unmodified-since", "--keys-file" }) |n| if (values.contains(n)) return error.InvalidInput;
    const upload = eq(op, "object put");
    if (upload) {
        if (operands.items.len != 2) return error.InvalidInput;
        const threshold = if (values.get("--multipart-threshold")) |v| try multipart.size(v) else 64 * 1024 * 1024;
        const source_path = operands.items[0];
        if (!eq(source_path, "-")) {
            const stat_source = std.Io.Dir.cwd().statFile(ctx.io, source_path, .{}) catch |err| blk: {
                if (!flags.contains("--dry-run")) return err;
                break :blk null;
            };
            if ((stat_source != null and stat_source.?.size >= threshold) or flags.contains("--resume") or values.contains("--part-size") or values.contains("--state-file") or values.contains("--max-parts"))
                return multipart.autoUpload(a, ctx, source_path, operands.items[1], pass.items, values, flags, metadata, config, json, quiet);
        }
    } else {
        if (flags.contains("--resume")) return error.InvalidInput;
        for ([_][]const u8{ "--multipart-threshold", "--part-size", "--max-parts", "--state-file" }) |n| if (values.contains(n)) return error.InvalidInput;
    }

    const download = eq(op, "object get");
    const stat = eq(op, "object stat");
    const head = eq(op, "object head");
    if (operands.items.len != @as(usize, if (upload or download) 2 else 1)) return error.InvalidInput;
    const remote = operands.items[if (upload) 1 else 0];
    const slash = std.mem.indexOfScalar(u8, remote, '/') orelse return error.InvalidInput;
    const rest = remote[slash + 1 ..];
    const cut = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidInput;
    if (slash == 0 or cut == 0 or cut + 1 == rest.len) return error.InvalidInput;
    const local = if (upload) operands.items[0] else if (download) operands.items[1] else "-";
    const overwrite = flags.contains("--overwrite");
    const yes = flags.contains("--yes");
    const dry = flags.contains("--dry-run");
    if (overwrite and !yes) return error.ConfirmationRequired;
    if ((overwrite or yes or dry) and !upload and !download) return error.InvalidInput;
    if (overwrite and eq(local, "-") and download) return error.InvalidInput;
    if (upload and eq(local, "-")) return error.UnsupportedOperation;
    if (json and !upload and !stat and eq(local, "-")) return error.RawOutputConflict;
    var input: V = .{ .object = .{} };
    try put(a, &input, "Bucket", rest[0..cut]);
    try put(a, &input, "Key", rest[cut + 1 ..]);
    inline for (fields) |f| if (values.get(f[0])) |v| {
        try put(a, &input, f[1], v);
    };
    if (metadata.object.count() > 0) try input.object.put(a, "Metadata", metadata);
    const offset = try number(values, "--offset");
    const length = try number(values, "--length");
    const bytes = try number(values, "--bytes");
    const lines = try number(values, "--lines");
    if ((bytes != null or lines != null) and !head) return error.InvalidInput;
    if (bytes != null and lines != null) return error.InvalidInput;
    if ((offset != null or length != null) and (upload or stat or head)) return error.InvalidInput;
    if ((bytes != null or offset != null or length != null or head) and input.object.contains("Range")) return error.InvalidInput;
    var transfer: api.TransferOptions = .{ .overwrite = overwrite and download, .output_dir = output_dir };
    if (head and bytes == null) {
        transfer.lines = lines orelse 10;
        if (transfer.lines.? == 0) return error.InvalidInput;
    }
    if (bytes orelse length) |n| {
        if (n == 0) return error.InvalidInput;
        const start = offset orelse 0;
        const end = std.math.add(u64, start, n - 1) catch return error.InvalidInput;
        try put(a, &input, "Range", try std.fmt.allocPrint(a, "bytes={d}-{d}", .{ start, end }));
    } else if (offset) |n| try put(a, &input, "Range", try std.fmt.allocPrint(a, "bytes={d}-", .{n}));
    if (values.get("--checksum-sha256")) |expected| {
        if (!download or eq(local, "-") or input.object.contains("Range") or expected.len != 64) return error.InvalidInput;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, expected) catch return error.InvalidInput;
        const encoded = try a.alloc(u8, 44);
        _ = std.base64.standard.Encoder.encode(encoded, &digest);
        transfer.expected_sha256 = encoded;
        transfer.verify_sha256 = true;
    }
    if (values.get("--checksum")) |algorithm| {
        if (!std.ascii.eqlIgnoreCase(algorithm, "SHA256")) return error.UnsupportedOperation;
        if (upload) try put(a, &input, "ChecksumAlgorithm", "SHA256") else {
            if (head or (!stat and (eq(local, "-") or input.object.contains("Range")))) return error.InvalidInput;
            try put(a, &input, "ChecksumMode", "ENABLED");
            transfer.verify_sha256 = !stat;
        }
    }
    if (upload) {
        if (overwrite and input.object.contains("IfNoneMatch")) return error.InvalidInput;
        if (!overwrite) {
            if (input.object.get("IfNoneMatch")) |v| {
                if (!eq(v.string, "*")) return error.InvalidInput;
            } else try put(a, &input, "IfNoneMatch", "*");
            if (input.object.contains("IfMatch")) return error.InvalidInput;
        }
        try pass.appendSlice(a, &.{ "--body", local, "--yes" });
    } else if (!stat) try pass.appendSlice(a, &.{ "--output", local });
    // Validate operation-specific fields even for previews.
    const operation: []const u8 = if (upload) "put-object" else if (stat) "head-object" else "get-object";
    api.validateInput(std.meta.stringToEnum(api.Operation, operation).?, input) catch |err| switch (err) {
        error.UnknownInputField, error.UnsupportedOperation => try @import("modeled.zig").validateRequest(a, operation, input),
        else => return err,
    };
    var it = values.iterator();
    while (it.next()) |e| if (api.isValueOption(e.key_ptr.*)) try pass.appendSlice(a, &.{ e.key_ptr.*, e.value_ptr.* });
    try pass.append(a, remote[0..slash]);
    if (dry) return .{ .stdout = if (quiet and !json) "" else try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .schema_version = 1, .type = op, .status = "success", .data = .{ .dry_run = true, .source = operands.items[0], .destination = operands.items[1] } }, .{})}) };
    return api.executeTransfer(a, ctx, operation, pass.items, config, json, quiet, input, transfer);
}
pub const help =
    \\zc object put LOCAL ALIAS/BUCKET/KEY | zc put LOCAL ALIAS/BUCKET/KEY
    \\zc object get ALIAS/BUCKET/KEY LOCAL|- | zc get ALIAS/BUCKET/KEY LOCAL|-
    \\zc object stat/show/head ALIAS/BUCKET/KEY | zc stat/cat/head ALIAS/BUCKET/KEY
    \\zc cp LOCAL ALIAS/BUCKET/KEY | zc cp ALIAS/BUCKET/KEY LOCAL
    \\cp recognizes saved aliases; use ./ or absolute paths to force a local path.
    \\Single objects only; same-alias remote copy/move and remove are supported.
    \\Default: refuse replacement. --overwrite --yes explicitly permits replacement.
    \\--dry-run previews put/get/cp without network or local file validation.
    \\Reads: --range bytes=N-M or --offset N [--length N]; stat accepts --range.
    \\head: --lines N (default 10; streams and discards remainder), or --bytes N.
    \\Conditions: --if-match --if-none-match --if-modified-since --if-unmodified-since
    \\Put: --content-type --content-encoding --content-disposition --content-language
    \\  --cache-control --metadata KEY=VALUE (repeatable)
    \\--checksum SHA256: put computes, get verifies before publishing, stat reports.
    \\--checksum-sha256 HEX: verify full download against an explicit trusted digest.
    \\Verified get needs a file and full object; absent/mismatched checksum fails.
    \\--expected-bucket-owner --request-payer requester; connection options as s3api.
    \\Raw stdout remains raw even with --quiet; JSON reads require a destination file.
    \\cp/mv REMOTE REMOTE: same alias, unversioned buckets only; mv requires --yes.
    \\rm REMOTE --yes | object remove-batch ALIAS/BUCKET --file FILE --yes
    \\Batch --file: JSON {Objects:[{Key:...}],Quiet:false}; 1..1000 unique keys, 1 MiB.
    \\Alternative --keys-file accepts a JSON string array. --dry-run previews.
    \\Copy options: --source-if-match/none-match/modified-since/unmodified-since
    \\  --metadata-directive COPY|REPLACE; metadata/content options require REPLACE.
    \\Move verifies source and destination before deleting; not an atomic transaction.
    \\Avoid concurrent writes during moves: server has no conditional source deletion.
    \\Automatic multipart: --multipart-threshold SIZE --part-size SIZE --max-parts N
    \\--resume --state-file FILE; see zc multipart --help for checkpoints and limits.
    \\Version selection and other checksum algorithms await subsequent steps.
    \\
;
