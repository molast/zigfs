const std = @import("std");
const App = @import("mod.zig").Application;
const subscriptions = @import("bucket_subscriptions.zig");
const destinations = @import("event_destinations.zig");
const notifications = @import("../ports/bucket_events.zig");
const delivery = @import("../ports/event_delivery.zig");
const Targets = @import("../backend/event_targets.zig").Targets;
const durable = @import("../metadata/durable.zig");

pub const Entry = struct {
    id: []const u8,
    destination_generation: []const u8,
    payload: []const u8,
    attempts: u32 = 0,
    next_attempt: i64 = 0,
    blocked: bool = false,
    configuration_hash: []const u8 = "",
    last_error: []const u8 = "",
};
pub fn matches(rule: subscriptions.Subscription, event: notifications.Event) bool {
    if (rule.destination.len == 0 or !std.mem.startsWith(u8, event.key, rule.prefix) or !std.mem.endsWith(u8, event.key, rule.suffix)) return false;
    for (rule.events) |category| if (std.mem.eql(u8, category, @tagName(event.category))) return true;
    return false;
}
pub fn capture(ctx: *anyopaque, event: notifications.Event) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    captureEvent(app, event) catch |err| std.log.err("Bucket event enqueue failed bucket={s} category={s} error={s}", .{ event.bucket, @tagName(event.category), @errorName(err) });
}
pub fn captureEvent(app: *App, event: notifications.Event) !void {
    const io = app.io orelse return;
    const root = app.data_root orelse return;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    app.policy_mutex.lockUncancelable(io);
    defer app.policy_mutex.unlock(io);
    const rules = try subscriptions.load(a, root, io, event.bucket_id);
    var any = false;
    for (rules.items) |rule| if (matches(rule, event)) {
        any = true;
        break;
    };
    if (!any) return;
    const configured = try destinations.load(root, io, a, (app.master_key orelse return).bytes);
    defer configured.deinit();
    const uuid = try @import("../common/id.zig").randomV4(io);
    const id = try std.fmt.allocPrint(a, "evt_{s}", .{std.fmt.bytesToHex(uuid, .lower)});
    var time_buffer: [24]u8 = undefined;
    const event_time = try @import("../common/time.zig").formatIso8601Milliseconds(@intCast(std.Io.Clock.real.now(io).toMilliseconds()), &time_buffer);
    for (configured.value.items) |target| {
        var rule_id: ?[]const u8 = null;
        for (rules.items) |rule| if (std.mem.eql(u8, rule.destination, target.name) and matches(rule, event)) {
            rule_id = rule.id;
            break;
        };
        if (rule_id == null) continue;
        const payload = try std.json.Stringify.valueAlloc(a, .{
            .event_id = id,
            .eventCategory = @tagName(event.category),
            .Records = .{.{
                .eventVersion = "2.1",
                .eventSource = "zigfs:s3",
                .awsRegion = app.config.s3_region,
                .eventTime = event_time,
                .eventName = event.name,
                .s3 = .{
                    .s3SchemaVersion = "1.0",
                    .configurationId = rule_id.?,
                    .bucket = .{ .name = event.bucket, .arn = try std.fmt.allocPrint(a, "arn:aws:s3:::{s}", .{event.bucket}), .id = try a.dupe(u8, &std.fmt.bytesToHex(event.bucket_id, .lower)) },
                    .object = .{ .key = try encodeKey(a, event.key), .size = event.size, .eTag = event.etag, .versionId = event.version_id, .sequencer = try std.fmt.allocPrint(a, "{x}", .{event.generation}) },
                },
            }},
        }, .{});
        app.event_mutex.lockUncancelable(io);
        defer app.event_mutex.unlock(io);
        const dir = try queueDirectory(a, target);
        if (try count(root, io, dir) >= target.queue_limit) {
            std.log.err("Bucket event queue full destination={s} bucket={s} event={s}", .{ target.name, event.bucket, id });
            continue;
        }
        try ensureQueue(root, io, a, dir);
        const filename = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, id });
        try save(root, io, a, filename, .{ .id = id, .destination_generation = target.generation_id, .payload = payload });
    }
}
fn encodeKey(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (key) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) try out.append(a, byte) else if (byte == ' ') try out.append(a, '+') else try out.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
    return out.toOwnedSlice(a);
}
pub fn queueDirectory(a: std.mem.Allocator, target: destinations.Destination) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ if (target.queue_directory.len > 0) target.queue_directory else ".zigfs/events/queues", target.name });
}
pub fn count(root: std.Io.Dir, io: std.Io, path: []const u8) !usize {
    var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    var result: usize = 0;
    while (try iterator.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
        result += 1;
    };
    return result;
}
fn ensureQueue(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    try root.createDirPath(io, path);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try root.realPath(io, &buffer);
    const actual = try root.realPathFileAlloc(io, path, a);
    const parent = std.mem.trimEnd(u8, buffer[0..n], "/");
    if (!std.mem.startsWith(u8, actual, parent) or actual.len <= parent.len or actual[parent.len] != '/') return error.InvalidQueueDirectory;
}
fn save(root: std.Io.Dir, io: std.Io, a: std.mem.Allocator, filename: []const u8, entry: Entry) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, entry, .{});
    var file = try root.createFileAtomic(io, filename, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
    try durable.syncParent(root, io, filename);
}
fn configurationHash(a: std.mem.Allocator, value: destinations.Destination) ![]const u8 {
    const data = try std.json.Stringify.valueAlloc(a, value, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
/// Sends a bounded batch per target each pass, giving every target a turn. No configuration or queue
/// lock is held while a remote endpoint is contacted.
pub fn dispatchOnce(app: *App) !void {
    const io = app.io orelse return;
    const root = app.data_root orelse return;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    app.policy_mutex.lockUncancelable(io);
    const configured = destinations.load(root, io, a, (app.master_key orelse {
        app.policy_mutex.unlock(io);
        return;
    }).bytes) catch |err| {
        app.policy_mutex.unlock(io);
        return err;
    };
    app.policy_mutex.unlock(io);
    defer configured.deinit();
    for (configured.value.items) |target| {
        for (0..64) |_| {
            var record_arena = std.heap.ArenaAllocator.init(app.allocator);
            defer record_arena.deinit();
            const processed = processTarget(app, record_arena.allocator(), target) catch |err| {
                std.log.err("Bucket event worker failed destination={s} error={s}", .{ target.name, @errorName(err) });
                break;
            };
            if (!processed) break;
        }
    }
}
fn processTarget(app: *App, a: std.mem.Allocator, target: destinations.Destination) !bool {
    const io = app.io.?;
    const root = app.data_root.?;
    const path = try queueDirectory(a, target);
    const hash = try configurationHash(a, target);
    const now = std.Io.Clock.real.now(io).toSeconds();
    const selected = blk: {
        app.event_mutex.lockUncancelable(io);
        defer app.event_mutex.unlock(io);
        var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |file| {
            if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".json")) continue;
            var candidate_arena = std.heap.ArenaAllocator.init(app.allocator);
            defer candidate_arena.deinit();
            const candidate = candidate_arena.allocator();
            const filename = try std.fmt.allocPrint(candidate, "{s}/{s}", .{ path, file.name });
            const bytes = try root.readFileAlloc(io, filename, candidate, .limited(2 * 1024 * 1024));
            const parsed = std.json.parseFromSlice(Entry, candidate, bytes, .{ .allocate = .alloc_always }) catch {
                try root.rename(filename, root, try std.fmt.allocPrint(candidate, "{s}.corrupt", .{filename}), io);
                std.log.err("Corrupt bucket event quarantined destination={s}", .{target.name});
                continue;
            };
            const entry = parsed.value;
            if (!std.mem.eql(u8, entry.destination_generation, target.generation_id)) {
                try root.deleteFile(io, filename);
                continue;
            }
            const changed = !std.mem.eql(u8, entry.configuration_hash, hash);
            if ((!changed and entry.blocked) or (!changed and entry.next_attempt > now)) continue;
            break :blk .{ .filename = try a.dupe(u8, filename), .entry = (try std.json.parseFromSlice(Entry, a, bytes, .{ .allocate = .alloc_always })).value };
        }
        return false;
    };
    var entry = selected.entry;
    const targets = try Targets.init(a, root, &.{target}, 5);
    defer targets.deinit();
    var failure: ?delivery.Error = null;
    targets.deliver(a, io, target.name, .{ .id = entry.id, .payload = entry.payload }) catch |err| {
        failure = if (err == error.DestinationNotRegistered) error.InvalidConfiguration else @errorCast(err);
    };
    app.event_mutex.lockUncancelable(io);
    defer app.event_mutex.unlock(io);
    if (failure) |err| {
        entry.attempts +|= 1;
        entry.blocked = !delivery.retryable(err);
        entry.configuration_hash = hash;
        entry.last_error = @errorName(err);
        const base_ms = targets.policy(target.name).?.retry_interval_ms;
        const delay_seconds = @min(300, @max(1, (base_ms + 999) / 1000) * (@as(u64, 1) << @as(u6, @intCast(@min(entry.attempts - 1, 8)))));
        entry.next_attempt = now + @as(i64, @intCast(delay_seconds));
        try save(root, io, a, selected.filename, entry);
        std.log.warn("Bucket event delivery failed destination={s} event={s} attempt={d} blocked={} error={s}", .{ target.name, entry.id, entry.attempts, entry.blocked, entry.last_error });
    } else {
        try root.deleteFile(io, selected.filename);
        try durable.syncParent(root, io, selected.filename);
    }
    return failure == null;
}
pub fn serve(app: *App) void {
    const io = app.io orelse return;
    while (true) {
        dispatchOnce(app) catch |err| std.log.err("Bucket event dispatch failed error={s}", .{@errorName(err)});
        const pause: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromSeconds(1) };
        pause.sleep(io) catch return;
    }
}

test "subscription matching supports all categories and exact raw prefix/suffix filters" {
    var event: notifications.Event = .{ .category = .PUT, .name = "test", .bucket_id = @splat(0), .bucket = "test", .key = "photos/a b.jpg" };
    const rule: subscriptions.Subscription = .{ .id = "test", .destination = "TARGET", .prefix = "photos/", .suffix = ".jpg", .events = &.{ "PUT", "GET", "DELETE", "ILM", "SCANNER" } };
    inline for ([_]notifications.Category{ .PUT, .GET, .DELETE, .ILM, .SCANNER }) |category| {
        event.category = category;
        try std.testing.expect(matches(rule, event));
    }
    event.key = "other/a.jpg";
    try std.testing.expect(!matches(rule, event));
    event.key = "photos/a.png";
    try std.testing.expect(!matches(rule, event));
    const encoded = try encodeKey(std.testing.allocator, "photos/a +b.jpg");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("photos%2Fa+%2Bb.jpg", encoded);
}

const Alert = struct { name: []const u8, key: []const u8 };
/// Emit on threshold crossings, with persisted state to avoid repeating alerts
/// on every scan or process restart. Only subscribed buckets are inspected.
pub fn scanAlerts(app: *App) !void {
    return scanAlertsWithLimits(app, 1000, 10000, 1024 * 1024 * 1024 * 1024);
}
fn scanAlertsWithLimits(app: *App, version_limit: usize, folder_limit: usize, size_limit: u64) !void {
    const io = app.io orelse return;
    const root = app.data_root orelse return;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buckets = try (app.bucketService() orelse return).list();
    defer buckets.deinit(app.allocator);
    for (buckets.buckets) |bucket| {
        const enabled = blk: {
            app.policy_mutex.lockUncancelable(io);
            defer app.policy_mutex.unlock(io);
            const rules = try subscriptions.load(a, root, io, bucket.id);
            for (rules.items) |rule| {
                if (rule.destination.len == 0) continue;
                for (rule.events) |category| if (std.mem.eql(u8, category, "SCANNER")) break :blk true;
            }
            break :blk false;
        };
        if (!enabled) continue;
        var alerts: std.ArrayList(Alert) = .empty;
        const objects = app.objectService() orelse return;
        const versions = try objects.listVersions(bucket.name, "");
        defer versions.deinit(app.allocator);
        var counts: std.StringHashMapUnmanaged(usize) = .empty;
        var sizes: std.StringHashMapUnmanaged(u64) = .empty;
        for (versions.entries) |entry| {
            if (!entry.is_delete_marker) {
                const total = try sizes.getOrPut(a, entry.key);
                if (!total.found_existing) total.value_ptr.* = 0;
                total.value_ptr.* +|= entry.size;
            }
            const value = try counts.getOrPut(a, entry.key);
            if (!value.found_existing) value.value_ptr.* = 0;
            value.value_ptr.* += 1;
        }
        var iterator = counts.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.* > version_limit) {
            try alerts.append(a, .{ .name = "Scanner:ManyVersions", .key = entry.key_ptr.* });
        };
        var size_iterator = sizes.iterator();
        while (size_iterator.next()) |entry| if (entry.value_ptr.* > size_limit) {
            try alerts.append(a, .{ .name = "Scanner:LargeVersions", .key = entry.key_ptr.* });
        };
        var folders: std.StringHashMapUnmanaged(usize) = .empty;
        {
            app.state_mutex.lockUncancelable(io);
            defer app.state_mutex.unlock(io);
            for (app.metadata_index.?.directoryEntries()) |entry| {
                if (!std.mem.eql(u8, entry.bucket, bucket.name)) continue;
                const key = std.mem.trimEnd(u8, entry.key, "/");
                if (key.len == 0) continue;
                const parent = if (std.mem.lastIndexOfScalar(u8, key, '/')) |end| key[0 .. end + 1] else "";
                const value = try folders.getOrPut(a, try a.dupe(u8, parent));
                if (!value.found_existing) value.value_ptr.* = 0;
                value.value_ptr.* += 1;
            }
        }
        var folder_iterator = folders.iterator();
        while (folder_iterator.next()) |entry| if (entry.value_ptr.* > folder_limit) {
            try alerts.append(a, .{ .name = "Scanner:BigPrefix", .key = entry.key_ptr.* });
        };
        const directory = ".zigfs/events/scanner-state";
        try root.createDirPath(io, directory);
        const filename = try std.fmt.allocPrint(a, directory ++ "/{s}.json", .{std.fmt.bytesToHex(bucket.id, .lower)});
        const bytes = root.readFileAlloc(io, filename, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => "[]",
            else => return err,
        };
        const previous = try std.json.parseFromSlice([]Alert, a, bytes, .{ .allocate = .alloc_always });
        for (alerts.items) |alert| {
            if (containsAlert(previous.value, alert)) continue;
            try captureEvent(app, .{ .category = .SCANNER, .name = alert.name, .bucket_id = bucket.id, .bucket = bucket.name, .key = alert.key });
        }
        const data = try std.json.Stringify.valueAlloc(a, alerts.items, .{});
        var file = try root.createFileAtomic(io, filename, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, data);
        try file.file.sync(io);
        try file.replace(io);
        try durable.syncParent(root, io, filename);
    }
}
fn containsAlert(previous: []const Alert, alert: Alert) bool {
    for (previous) |value| {
        const same_name = std.mem.eql(u8, value.name, alert.name) or
            (std.mem.eql(u8, value.name, "Scanner:ManySubfolders") and std.mem.eql(u8, alert.name, "Scanner:BigPrefix"));
        if (same_name and std.mem.eql(u8, value.key, alert.key)) return true;
    }
    return false;
}
test "scanner warning state distinguishes object and warning type" {
    try std.testing.expect(containsAlert(&.{.{ .name = "Scanner:ManySubfolders", .key = "photos/" }}, .{ .name = "Scanner:BigPrefix", .key = "photos/" }));
    const previous = [_]Alert{.{ .name = "Scanner:ManyVersions", .key = "photos/a" }};
    try std.testing.expect(containsAlert(&previous, previous[0]));
    try std.testing.expect(!containsAlert(&previous, .{ .name = "Scanner:BigPrefix", .key = "photos/a" }));
    try std.testing.expect(!containsAlert(&previous, .{ .name = "Scanner:ManyVersions", .key = "photos/b" }));
}

test "scanner crossings persist and resume below threshold while outbox deduplicates targets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root_path);
    var app = App.initWithAllocator(.{ .data_root = root_path, .metrics_enabled = false }, a);
    defer app.deinit(io);
    try app.initialize(io);
    const bucket = try app.bucketService().?.create("event-test", "owner");
    defer bucket.deinit(a);
    (try app.bucketService().?.setVersioning("event-test", .enabled)).deinit(a);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const target: destinations.Destination = .{ .name = "HTTP", .generation_id = "generation-one", .endpoint = "http://127.0.0.1:1" };
    try destinations.save(tmp.dir, io, scratch, app.master_key.?.bytes, .{ .items = &.{target} });
    try subscriptions.save(scratch, tmp.dir, io, bucket.bucket.id, .{ .items = &.{
        .{ .id = "one", .destination = "HTTP", .events = &.{"SCANNER"} },
        .{ .id = "two", .destination = "HTTP", .events = &.{"SCANNER"} },
    } });
    var version: @import("../domain/object.zig").VersionId = undefined;
    for (0..3) |_| {
        var source = @import("../testing/streams.zig").SliceSource.init("body");
        const object = try app.objectService().?.put("event-test", "photos/a.jpg", source.interface(), .{});
        version = object.version_id;
        object.deinit(a);
    }
    const queue = try queueDirectory(scratch, target);
    try scanAlertsWithLimits(&app, 2, 10000, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 1), try count(tmp.dir, io, queue));
    try scanAlertsWithLimits(&app, 2, 10000, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 1), try count(tmp.dir, io, queue));
    _ = try app.objectService().?.deleteVersion("event-test", "photos/a.jpg", version);
    try scanAlertsWithLimits(&app, 2, 10000, std.math.maxInt(u64));
    var source = @import("../testing/streams.zig").SliceSource.init("body");
    (try app.objectService().?.put("event-test", "photos/a.jpg", source.interface(), .{})).deinit(a);
    try scanAlertsWithLimits(&app, 2, 10000, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 2), try count(tmp.dir, io, queue));
    // Direct child directories are counted per parent, not recursively.
    (try app.directoryService().?.create("event-test", "folders/one/")).deinit(a);
    (try app.directoryService().?.create("event-test", "folders/two/")).deinit(a);
    try scanAlertsWithLimits(&app, 2, 1, std.math.maxInt(u64));
    const after_folders = try count(tmp.dir, io, queue);
    try std.testing.expect(after_folders > 2);
    try scanAlertsWithLimits(&app, 2, 1, std.math.maxInt(u64));
    try std.testing.expectEqual(after_folders, try count(tmp.dir, io, queue));
    try scanAlertsWithLimits(&app, 2, 1, 11);
    try std.testing.expectEqual(after_folders + 1, try count(tmp.dir, io, queue));
    try scanAlertsWithLimits(&app, 2, 1, 11);
    try std.testing.expectEqual(after_folders + 1, try count(tmp.dir, io, queue));
    // A recreated destination must never receive the previous destination's records.
    var replacement = target;
    replacement.generation_id = "generation-two";
    try destinations.save(tmp.dir, io, scratch, app.master_key.?.bytes, .{ .items = &.{replacement} });
    try dispatchOnce(&app);
    try std.testing.expectEqual(@as(usize, 0), try count(tmp.dir, io, queue));
}

test "object creation and lifecycle deletion emit distinct events after successful operations" {
    const Recorder = struct {
        names: [8][]const u8 = undefined,
        categories: [8]notifications.Category = undefined,
        len: usize = 0,
        fn emit(context: *anyopaque, event: notifications.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.names[self.len] = event.name;
            self.categories[self.len] = event.category;
            self.len += 1;
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root_path);
    var app = App.initWithAllocator(.{ .data_root = root_path, .metrics_enabled = false }, a);
    defer app.deinit(io);
    try app.initialize(io);
    (try app.bucketService().?.create("event-types", "owner")).deinit(a);
    (try app.bucketService().?.setVersioning("event-types", .enabled)).deinit(a);
    var recorder: Recorder = .{};
    var objects = app.objectService().?;
    objects.event_sink = .{ .context = &recorder, .emit_fn = Recorder.emit };
    var source = @import("../testing/streams.zig").SliceSource.init("body");
    const object = try objects.put("event-types", "form.txt", source.interface(), .{ .creation_event = .post });
    defer object.deinit(a);
    try std.testing.expectEqualStrings("ObjectCreated:Post", recorder.names[0]);
    try std.testing.expectEqual(notifications.Category.PUT, recorder.categories[0]);
    objects.deletion_category = .ILM;
    const marker = try objects.delete("event-types", "form.txt");
    try std.testing.expectEqualStrings("LifecycleExpiration:DeleteMarkerCreated", recorder.names[1]);
    _ = try objects.deleteVersion("event-types", "form.txt", object.version_id);
    try std.testing.expectEqualStrings("LifecycleExpiration:Delete", recorder.names[2]);
    _ = try objects.deleteVersion("event-types", "form.txt", marker.version_id.?);
    try std.testing.expectEqualStrings("LifecycleDelMarkerExpiration:Delete", recorder.names[3]);
    for (recorder.categories[1..4]) |category| try std.testing.expectEqual(notifications.Category.ILM, category);
    _ = try objects.deleteVersion("event-types", "form.txt", marker.version_id.?);
    try std.testing.expectEqual(@as(usize, 4), recorder.len);
}
