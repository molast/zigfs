//! Local report scheduler. Output is ordinary, same-owner S3 objects; completion
//! checkpoints follow durable output publication and survive service restarts.
const std = @import("std");
const App = @import("mod.zig").Application;
const bucket_domain = @import("../domain/bucket.zig");
const configuration = @import("s3_configuration.zig");
const xml = @import("../common/xml.zig");
const Source = @import("s3_access_logging.zig").Source;
const A = std.mem.Allocator;
const kinds = [_][]const u8{ "inventory", "analytics", "metrics" };

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
pub fn documents(a: A, app: *App, bucket_id: [16]u8, kind: []const u8) !std.json.Value {
    const key = try std.fmt.allocPrint(a, "config/s3-buckets/{s}/{s}.json", .{ std.fmt.bytesToHex(bucket_id, .lower), kind });
    const bytes = app.systemStore().read(a, key, 4 * 1024 * 1024) catch |err| switch (err) {
        error.NotFound => return .{ .object = .{} },
        else => return err,
    };
    const value = (try std.json.parseFromSlice(std.json.Value, a, bytes, .{})).value;
    if (value != .object) return error.InvalidConfiguration;
    return value;
}
fn prefix(node: xml.Node) []const u8 {
    const filter = configuration.child(node, "Filter") orelse return "";
    return configuration.text(filter, "Prefix") orelse "";
}
pub fn destination(node: xml.Node, kind: []const u8) ?xml.Node {
    if (eq(kind, "inventory")) {
        const target = configuration.child(node, "Destination") orelse return null;
        return configuration.child(target, "S3BucketDestination");
    }
    const analysis = configuration.child(node, "StorageClassAnalysis") orelse return null;
    const output = configuration.child(analysis, "DataExport") orelse return null;
    const target = configuration.child(output, "Destination") orelse return null;
    return configuration.child(target, "S3BucketDestination");
}
pub fn targetName(node: xml.Node) ![]const u8 {
    const arn = configuration.text(node, "Bucket") orelse return error.InvalidDestination;
    const marker = "arn:aws:s3:::";
    if (!std.mem.startsWith(u8, arn, marker)) return error.InvalidDestination;
    return arn[marker.len..];
}
pub fn validate(node: xml.Node, kind: []const u8) !void {
    // Local inventory has a fixed schema; reject fields it cannot produce.
    if (eq(kind, "inventory") and configuration.child(node, "OptionalFields") != null) {
        return error.UnsupportedFields;
    }
    if (configuration.child(node, "Filter")) |filter| {
        for (filter.children) |field| if (!eq(field.name, "Prefix")) return error.UnsupportedFilter;
    }
    if (destination(node, kind)) |target| {
        _ = try targetName(target);
        if (!eq(configuration.text(target, "Format") orelse "CSV", "CSV")) return error.UnsupportedFormat;
        if (configuration.child(target, "Encryption") != null) return error.UnsupportedEncryption;
    } else if (eq(kind, "inventory")) return error.InvalidDestination;
    if (eq(kind, "inventory")) {
        const schedule = configuration.child(node, "Schedule") orelse return error.InvalidSchedule;
        const frequency = configuration.text(schedule, "Frequency") orelse return error.InvalidSchedule;
        if (!eq(frequency, "Daily") and !eq(frequency, "Weekly")) return error.InvalidSchedule;
        const versions = configuration.text(node, "IncludedObjectVersions") orelse return error.InvalidVersions;
        if (!eq(versions, "Current") and !eq(versions, "All")) return error.InvalidVersions;
        const enabled = configuration.text(node, "IsEnabled") orelse return error.InvalidConfiguration;
        if (!eq(enabled, "true") and !eq(enabled, "false")) return error.InvalidConfiguration;
    }
}
fn csv(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}
fn writeObject(app: *App, bucket: []const u8, key: []const u8, bytes: []const u8, content_type: []const u8) !void {
    var objects = app.objectService() orelse return error.Unavailable;
    objects.event_sink = null;
    var source: Source = .{ .bytes = bytes };
    const object = try objects.put(bucket, key, source.interface(), .{ .content_type = content_type });
    object.deinit(app.allocator);
}

pub fn scan(app: *App, now: i64) !usize {
    var completed: usize = 0;
    const buckets = (app.bucketService() orelse return error.Unavailable).list() catch return error.Unavailable;
    defer buckets.deinit(app.allocator);
    for (buckets.buckets) |bucket| {
        for (kinds) |kind| {
            var arena = std.heap.ArenaAllocator.init(app.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const configs = try documents(a, app, bucket.id, kind);
            var iterator = configs.object.iterator();
            while (iterator.next()) |item| {
                if (item.value_ptr.* != .string) return error.InvalidConfiguration;
                const node = try xml.parse(a, item.value_ptr.string);
                if (eq(kind, "inventory") and eq(configuration.text(node, "IsEnabled") orelse "false", "false")) continue;
                try validate(node, kind);
                const interval: i64 = if (eq(kind, "metrics")) 60 else if (configuration.child(node, "Schedule")) |schedule|
                    (if (eq(configuration.text(schedule, "Frequency") orelse "Daily", "Weekly")) 7 * 86400 else 86400)
                else
                    86400;
                const period = @divFloor(now, interval);
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(item.value_ptr.string, &hash, .{});
                const checkpoint = try std.fmt.allocPrint(a, "config/s3-buckets/{s}/report-{s}-{s}.json", .{ std.fmt.bytesToHex(bucket.id, .lower), kind, std.fmt.bytesToHex(hash, .lower) });
                const previous = app.systemStore().read(a, checkpoint, 128) catch |err| switch (err) {
                    error.NotFound => "",
                    else => return err,
                };
                const stamp = try std.fmt.allocPrint(a, "{d}", .{period});
                if (eq(previous, stamp)) continue;
                try generate(a, app, bucket, kind, item.key_ptr.*, node, period);
                try app.systemStore().put(a, checkpoint, stamp);
                completed += 1;
            }
        }
    }
    return completed;
}

fn generate(a: A, app: *App, bucket: bucket_domain.Bucket, kind: []const u8, id: []const u8, node: xml.Node, period: i64) !void {
    var target_name = bucket.name;
    var output_prefix: []const u8 = "";
    if (destination(node, kind)) |target| {
        target_name = @constCast(try targetName(target));
        output_prefix = configuration.text(target, "Prefix") orelse "";
    }
    const target = try app.bucketService().?.head(target_name);
    defer target.deinit(app.allocator);
    if (!eq(target.owner, bucket.owner)) return error.AccessDenied;
    const versions = try app.objectService().?.listVersions(bucket.name, prefix(node));
    defer versions.deinit(app.allocator);
    var output: std.Io.Writer.Allocating = .init(a);
    const inventory = eq(kind, "inventory");
    const all_versions = eq(configuration.text(node, "IncludedObjectVersions") orelse "Current", "All");
    var count: u64 = 0;
    var size: u64 = 0;
    var class_counts: [4]u64 = @splat(0);
    var class_sizes: [4]u64 = @splat(0);
    if (inventory) try output.writer.writeAll("Bucket,Key,VersionId,IsLatest,DeleteMarker,Size,LastModifiedDate,ETag,StorageClass\n");
    for (versions.entries) |entry| {
        if (std.mem.indexOf(u8, entry.key, ".zigfs-reports/") != null) continue;
        if (!all_versions and (!entry.is_latest or entry.is_delete_marker)) continue;
        if (!entry.is_delete_marker) {
            count += 1;
            size += entry.size;
            class_counts[@backingInt(entry.storage_class)] += 1;
            class_sizes[@backingInt(entry.storage_class)] += entry.size;
        }
        if (!inventory) continue;
        try csv(&output.writer, bucket.name);
        try output.writer.writeByte(',');
        try csv(&output.writer, entry.key);
        try output.writer.writeByte(',');
        var version_buffer: [32]u8 = undefined;
        try csv(&output.writer, entry.version_id.write(&version_buffer));
        try output.writer.print(",{s},{s},{d},{d},", .{ if (entry.is_latest) "true" else "false", if (entry.is_delete_marker) "true" else "false", entry.size, entry.last_modified_unix_seconds });
        if (!entry.is_delete_marker) try csv(&output.writer, &std.fmt.bytesToHex(entry.etag_md5, .lower)) else try csv(&output.writer, "");
        try output.writer.print(",{s}\n", .{entry.storage_class.wire()});
    }
    if (eq(kind, "metrics")) {
        const measured = try counters(a, app, try counterPath(a, bucket.id, id));
        try output.writer.writeAll("Bucket,ConfigurationId,Period,Objects,Bytes,CumulativeRequests,GetRequests,PutRequests,DeleteRequests,ClientErrors,ServerErrors\n");
        try csv(&output.writer, bucket.name);
        try output.writer.writeByte(',');
        try csv(&output.writer, id);
        try output.writer.print(",{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{ period, count, size, measured.requests, measured.get_requests, measured.put_requests, measured.delete_requests, measured.client_errors, measured.server_errors });
    } else if (eq(kind, "analytics")) {
        try output.writer.writeAll("Bucket,ConfigurationId,Period,StorageClass,Objects,Bytes\n");
        for ([_]@import("../domain/object.zig").StorageClass{ .standard, .glacier, .deep_archive, .intelligent_tiering }) |class| {
            try csv(&output.writer, bucket.name);
            try output.writer.writeByte(',');
            try csv(&output.writer, id);
            const index = @backingInt(class);
            try output.writer.print(",{d},{s},{d},{d}\n", .{ period, class.wire(), class_counts[index], class_sizes[index] });
        }
    }
    var id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &id_hash, .{});
    const key = try std.fmt.allocPrint(a, "{s}.zigfs-reports/{s}/{s}/{d}.csv", .{ output_prefix, kind, std.fmt.bytesToHex(id_hash, .lower), period });
    try writeObject(app, target_name, key, output.written(), "text/csv");
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(output.written(), &md5, .{});
    const manifest = try std.json.Stringify.valueAlloc(a, .{
        .sourceBucket = bucket.name,
        .configurationId = id,
        .kind = kind,
        .files = .{.{ .key = key, .size = output.written().len, .MD5checksum = try std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(md5, .lower)}) }},
    }, .{});
    try writeObject(app, target_name, try std.fmt.allocPrint(a, "{s}.manifest.json", .{key}), manifest, "application/json");
}

const Counters = struct {
    requests: u64 = 0,
    get_requests: u64 = 0,
    put_requests: u64 = 0,
    delete_requests: u64 = 0,
    client_errors: u64 = 0,
    server_errors: u64 = 0,
};
fn counterPath(a: A, bucket_id: [16]u8, id: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &hash, .{});
    return std.fmt.allocPrint(a, "config/s3-buckets/{s}/metrics-counters-{s}.json", .{ std.fmt.bytesToHex(bucket_id, .lower), std.fmt.bytesToHex(hash, .lower) });
}
fn counters(a: A, app: *App, key: []const u8) !Counters {
    const bytes = app.systemStore().read(a, key, 4096) catch |err| switch (err) {
        error.NotFound => return .{},
        else => return err,
    };
    return (try std.json.parseFromSlice(Counters, a, bytes, .{})).value;
}
pub fn recordRequest(a: A, app: *App, bucket_id: [16]u8, key: ?[]const u8, method: []const u8, status: u16) !void {
    const configs = try documents(a, app, bucket_id, "metrics");
    var iterator = configs.object.iterator();
    while (iterator.next()) |item| {
        const node = try xml.parse(a, item.value_ptr.string);
        if (!std.mem.startsWith(u8, key orelse "", prefix(node))) continue;
        const filename = try counterPath(a, bucket_id, item.key_ptr.*);
        app.state_mutex.lockUncancelable(app.io.?);
        defer app.state_mutex.unlock(app.io.?);
        var current = try counters(a, app, filename);
        current.requests +|= 1;
        if (eq(method, "GET")) current.get_requests +|= 1;
        if (eq(method, "PUT")) current.put_requests +|= 1;
        if (eq(method, "DELETE")) current.delete_requests +|= 1;
        if (status >= 400 and status < 500) current.client_errors +|= 1;
        if (status >= 500) current.server_errors +|= 1;
        try app.systemStore().put(a, filename, try std.json.Stringify.valueAlloc(a, current, .{}));
    }
}
