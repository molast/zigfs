//! Local intelligent-tiering access tracking and archive transitions. The scanner
//! receives its clock explicitly so age, access resets and recovery can be tested.
const std = @import("std");
const App = @import("mod.zig").Application;
const object_domain = @import("../domain/object.zig");
const configuration = @import("s3_configuration.zig");
const reports = @import("s3_reports.zig");
const xml = @import("../common/xml.zig");
const A = std.mem.Allocator;
fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

pub fn validate(node: xml.Node) !void {
    const status = configuration.text(node, "Status") orelse return error.InvalidConfiguration;
    if (!eq(status, "Enabled") and !eq(status, "Disabled")) return error.InvalidConfiguration;
    if (configuration.child(node, "Filter")) |filter| {
        for (filter.children) |field| if (!eq(field.name, "Prefix")) return error.UnsupportedFilter;
    }
    var count: usize = 0;
    var seen_archive = false;
    var seen_deep = false;
    for (node.children) |entry| {
        if (!eq(entry.name, "Tiering")) continue;
        count += 1;
        const tier = configuration.text(entry, "AccessTier") orelse return error.InvalidTier;
        const days = std.fmt.parseInt(u32, configuration.text(entry, "Days") orelse "", 10) catch return error.InvalidTier;
        if (eq(tier, "ARCHIVE_ACCESS") and !seen_archive and days >= 90 and days <= 730) {
            seen_archive = true;
        } else if (eq(tier, "DEEP_ARCHIVE_ACCESS") and !seen_deep and days >= 180 and days <= 730) {
            seen_deep = true;
        } else return error.InvalidTier;
    }
    if (count == 0 or count > 2) return error.InvalidTier;
}
fn accessPath(a: A, bucket_id: [16]u8, key: []const u8, version: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &hash, .{});
    return std.fmt.allocPrint(a, "config/s3-objects/{s}/{s}/{s}.access", .{ std.fmt.bytesToHex(bucket_id, .lower), std.fmt.bytesToHex(hash, .lower), version });
}
pub fn recordAccess(app: *App, event: @import("../ports/bucket_events.zig").Event) !void {
    if (event.category != .GET or !event.intelligent_tiering) return;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try accessPath(a, event.bucket_id, event.key, if (event.version_id.len == 0) "null" else event.version_id);
    app.state_mutex.lockUncancelable(app.io.?);
    defer app.state_mutex.unlock(app.io.?);
    const previous = app.systemStore().read(a, key, 64) catch |err| switch (err) {
        error.NotFound => "0",
        else => return err,
    };
    const now = std.Io.Clock.real.now(app.io.?).toSeconds();
    const latest = @max(now, try std.fmt.parseInt(i64, previous, 10));
    try app.systemStore().put(a, key, try std.fmt.allocPrint(a, "{d}", .{latest}));
}
pub fn selectedTier(node: xml.Node, last_access: i64, now: i64) !object_domain.ArchiveTier {
    var selected: object_domain.ArchiveTier = .none;
    for (node.children) |entry| {
        if (!eq(entry.name, "Tiering")) continue;
        const days = try std.fmt.parseInt(i64, configuration.text(entry, "Days") orelse return error.InvalidTier, 10);
        if (now < last_access or now - last_access < days * 86400) continue;
        const tier: object_domain.ArchiveTier = if (eq(configuration.text(entry, "AccessTier") orelse "", "DEEP_ARCHIVE_ACCESS")) .deep_archive_access else .archive_access;
        if (@backingInt(tier) > @backingInt(selected)) selected = tier;
    }
    return selected;
}
pub fn scan(app: *App, now: i64) !usize {
    const buckets = try app.bucketService().?.list();
    defer buckets.deinit(app.allocator);
    var transitioned: usize = 0;
    for (buckets.buckets) |bucket| {
        var arena = std.heap.ArenaAllocator.init(app.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const configs = try reports.documents(a, app, bucket.id, "intelligent-tiering");
        if (configs.object.count() == 0) continue;
        const versions = try app.objectService().?.listVersions(bucket.name, "");
        defer versions.deinit(app.allocator);
        for (versions.entries) |entry| {
            if (entry.is_delete_marker or entry.storage_class != .intelligent_tiering) continue;
            var version_buffer: [32]u8 = undefined;
            const filename = try accessPath(a, bucket.id, entry.key, entry.version_id.write(&version_buffer));
            const stamp = app.systemStore().read(a, filename, 64) catch |err| switch (err) {
                error.NotFound => "0",
                else => return err,
            };
            const last_access = @max(entry.last_modified_unix_seconds, try std.fmt.parseInt(i64, stamp, 10));
            var selected = entry.archive_tier;
            var iterator = configs.object.iterator();
            while (iterator.next()) |item| {
                const node = try xml.parse(a, item.value_ptr.string);
                if (!eq(configuration.text(node, "Status") orelse "Disabled", "Enabled")) continue;
                try validate(node);
                if (configuration.child(node, "Filter")) |filter| {
                    if (!std.mem.startsWith(u8, entry.key, configuration.text(filter, "Prefix") orelse "")) continue;
                }
                const candidate = try selectedTier(node, last_access, now);
                if (@backingInt(candidate) > @backingInt(selected)) selected = candidate;
            }
            if (selected == entry.archive_tier) continue;
            var lease = try app.objectService().?.openVersion(bucket.name, entry.key, entry.version_id);
            const generation = lease.metadata().data_generation;
            const unchanged = lease.metadata().last_modified_unix_seconds == entry.last_modified_unix_seconds and
                lease.metadata().archive_tier == entry.archive_tier;
            lease.deinit();
            if (!unchanged) continue;
            const updated = app.objectService().?.setArchiveTier(bucket.name, entry.key, entry.version_id, selected, generation, app.systemStore(), filename, stamp) catch |err| switch (err) {
                error.ConditionNotMet, error.Conflict, error.ObjectNotFound => continue,
                else => return err,
            };
            updated.deinit(app.allocator);
            transitioned += 1;
        }
    }
    return transitioned;
}

test "tiering requires quiet access window and selects deepest eligible tier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try xml.parse(arena.allocator(), "<IntelligentTieringConfiguration><Status>Enabled</Status><Tiering><Days>90</Days><AccessTier>ARCHIVE_ACCESS</AccessTier></Tiering><Tiering><Days>180</Days><AccessTier>DEEP_ARCHIVE_ACCESS</AccessTier></Tiering></IntelligentTieringConfiguration>");
    try validate(node);
    try std.testing.expectEqual(object_domain.ArchiveTier.none, try selectedTier(node, 100, 100 + 89 * 86400));
    try std.testing.expectEqual(object_domain.ArchiveTier.archive_access, try selectedTier(node, 100, 100 + 90 * 86400));
    try std.testing.expectEqual(object_domain.ArchiveTier.deep_archive_access, try selectedTier(node, 100, 100 + 180 * 86400));
    try std.testing.expectEqual(object_domain.ArchiveTier.none, try selectedTier(node, 100 + 179 * 86400, 100 + 180 * 86400));
}
