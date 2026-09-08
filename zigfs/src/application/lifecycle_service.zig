const std = @import("std");
const time = @import("../common/time.zig");
const object_domain = @import("../domain/object.zig");
const BucketService = @import("bucket_service.zig").BucketService;
const ObjectService = @import("object_service.zig").ObjectService;

pub const Error = error{
    OutOfMemory,
    MalformedXml,
    UnsupportedFeature,
    BucketFailure,
    ObjectFailure,
};

pub const Rule = struct {
    prefix: []u8,
    enabled: bool,
    expiration_days: ?u32 = null,
    expiration_date: ?i64 = null,
    noncurrent_days: ?u32 = null,
    newer_noncurrent_versions: u32 = 0,
    expired_object_delete_marker: bool = false,

    fn deinit(self: Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
    }
};

pub const Configuration = struct {
    rules: []Rule,

    pub fn deinit(self: Configuration, allocator: std.mem.Allocator) void {
        for (self.rules) |rule| rule.deinit(allocator);
        allocator.free(self.rules);
    }
};

pub const Report = struct {
    buckets_scanned: usize = 0,
    versions_scanned: usize = 0,
    current_expired: usize = 0,
    noncurrent_expired: usize = 0,
    delete_markers_removed: usize = 0,
};

pub const LifecycleService = struct {
    allocator: std.mem.Allocator,
    buckets: BucketService,
    objects: ObjectService,

    pub fn scan(self: LifecycleService, now: i64) Error!Report {
        var report: Report = .{};
        const buckets = self.buckets.list() catch return error.BucketFailure;
        defer buckets.deinit(self.allocator);
        for (buckets.buckets) |bucket| {
            const xml = bucket.lifecycle_configuration orelse continue;
            const configuration = parse(self.allocator, xml) catch |err| return err;
            defer configuration.deinit(self.allocator);
            const versions = self.objects.listVersions(bucket.name, "") catch return error.ObjectFailure;
            defer versions.deinit(self.allocator);
            report.buckets_scanned += 1;

            var key_start: usize = 0;
            while (key_start < versions.entries.len) {
                var key_end = key_start + 1;
                while (key_end < versions.entries.len and
                    std.mem.eql(u8, versions.entries[key_start].key, versions.entries[key_end].key)) : (key_end += 1)
                {}
                var noncurrent_object_ordinal: u32 = 0;
                for (versions.entries[key_start..key_end], 0..) |entry, relative_index| {
                    report.versions_scanned += 1;
                    if (relative_index == 0) {
                        if (entry.is_delete_marker) {
                            if (key_end - key_start == 1 and shouldRemoveExpiredMarker(configuration.rules, entry.key)) {
                                _ = self.objects.deleteVersion(bucket.name, entry.key, entry.version_id) catch return error.ObjectFailure;
                                report.delete_markers_removed += 1;
                            }
                        } else if (shouldExpireCurrent(configuration.rules, entry.key, entry.last_modified_unix_seconds, now)) {
                            _ = self.objects.delete(bucket.name, entry.key) catch return error.ObjectFailure;
                            report.current_expired += 1;
                        }
                    } else if (!entry.is_delete_marker) {
                        if (shouldExpireNoncurrent(
                            configuration.rules,
                            entry.key,
                            entry.last_modified_unix_seconds,
                            noncurrent_object_ordinal,
                            now,
                        )) {
                            _ = self.objects.deleteVersion(bucket.name, entry.key, entry.version_id) catch return error.ObjectFailure;
                            report.noncurrent_expired += 1;
                        }
                        noncurrent_object_ordinal += 1;
                    }
                }
                key_start = key_end;
            }
        }
        return report;
    }
};

pub fn parse(allocator: std.mem.Allocator, xml: []const u8) Error!Configuration {
    if (std.mem.indexOf(u8, xml, "<LifecycleConfiguration") == null or
        std.mem.indexOf(u8, xml, "</LifecycleConfiguration>") == null) return error.MalformedXml;
    var rules: std.ArrayList(Rule) = .empty;
    errdefer {
        for (rules.items) |rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }
    var remainder = xml;
    while (std.mem.indexOf(u8, remainder, "<Rule>")) |start| {
        const content_start = start + "<Rule>".len;
        const relative_end = std.mem.indexOf(u8, remainder[content_start..], "</Rule>") orelse return error.MalformedXml;
        const body = remainder[content_start .. content_start + relative_end];
        if (rules.items.len == 1000) return error.MalformedXml;
        const status = elementText(body, "Status") orelse return error.MalformedXml;
        const enabled = if (std.mem.eql(u8, status, "Enabled"))
            true
        else if (std.mem.eql(u8, status, "Disabled"))
            false
        else
            return error.MalformedXml;
        if (std.mem.indexOf(u8, body, "<Tag>") != null or
            std.mem.indexOf(u8, body, "<And>") != null or
            std.mem.indexOf(u8, body, "<ObjectSize") != null or
            std.mem.indexOf(u8, body, "<Transition>") != null or
            std.mem.indexOf(u8, body, "<AbortIncompleteMultipartUpload>") != null) return error.UnsupportedFeature;
        const filter_body = elementBody(body, "Filter");
        const raw_prefix = if (filter_body) |filter| elementText(filter, "Prefix") orelse "" else elementText(body, "Prefix") orelse "";
        const prefix = try decodeXmlText(allocator, raw_prefix);
        errdefer allocator.free(prefix);

        var rule: Rule = .{ .prefix = prefix, .enabled = enabled };
        var has_action = false;
        if (elementBody(body, "Expiration")) |expiration| {
            has_action = true;
            if (elementText(expiration, "Days")) |days| rule.expiration_days = try positiveU32(days);
            if (elementText(expiration, "Date")) |date| rule.expiration_date = time.parseIso8601(date) catch return error.MalformedXml;
            if (elementText(expiration, "ExpiredObjectDeleteMarker")) |value| {
                if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.MalformedXml;
                rule.expired_object_delete_marker = std.mem.eql(u8, value, "true");
            }
            const count = @intFromBool(rule.expiration_days != null) +
                @intFromBool(rule.expiration_date != null) +
                @intFromBool(elementText(expiration, "ExpiredObjectDeleteMarker") != null);
            if (count != 1) return error.MalformedXml;
        }
        if (elementBody(body, "NoncurrentVersionExpiration")) |noncurrent| {
            has_action = true;
            rule.noncurrent_days = try positiveU32(elementText(noncurrent, "NoncurrentDays") orelse return error.MalformedXml);
            if (elementText(noncurrent, "NewerNoncurrentVersions")) |count| {
                rule.newer_noncurrent_versions = try positiveU32(count);
            }
        }
        if (!has_action) return error.UnsupportedFeature;
        rules.append(allocator, rule) catch return error.OutOfMemory;
        remainder = remainder[content_start + relative_end + "</Rule>".len ..];
    }
    if (rules.items.len == 0) return error.MalformedXml;
    return .{ .rules = rules.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

fn shouldExpireCurrent(rules: []const Rule, key: []const u8, modified_at: i64, now: i64) bool {
    for (rules) |rule| {
        if (!rule.enabled or !std.mem.startsWith(u8, key, rule.prefix)) continue;
        if (rule.expiration_date) |date| if (now >= date) return true;
        if (rule.expiration_days) |days| if (ageReached(modified_at, now, days)) return true;
    }
    return false;
}

fn shouldExpireNoncurrent(
    rules: []const Rule,
    key: []const u8,
    modified_at: i64,
    newer_noncurrent_count: u32,
    now: i64,
) bool {
    for (rules) |rule| {
        if (!rule.enabled or !std.mem.startsWith(u8, key, rule.prefix)) continue;
        const days = rule.noncurrent_days orelse continue;
        if (newer_noncurrent_count < rule.newer_noncurrent_versions) continue;
        if (ageReached(modified_at, now, days)) return true;
    }
    return false;
}

fn shouldRemoveExpiredMarker(rules: []const Rule, key: []const u8) bool {
    for (rules) |rule| if (rule.enabled and rule.expired_object_delete_marker and
        std.mem.startsWith(u8, key, rule.prefix)) return true;
    return false;
}

fn ageReached(modified_at: i64, now: i64, days: u32) bool {
    if (now <= modified_at) return false;
    const seconds = @as(i64, days) * 86_400;
    return now - modified_at >= seconds;
}

fn positiveU32(value: []const u8) Error!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.MalformedXml;
    if (parsed == 0) return error.MalformedXml;
    return parsed;
}

fn elementBody(xml: []const u8, name: []const u8) ?[]const u8 {
    var open_buffer: [128]u8 = undefined;
    var close_buffer: [128]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buffer, "<{s}>", .{name}) catch return null;
    const close = std.fmt.bufPrint(&close_buffer, "</{s}>", .{name}) catch return null;
    const start = std.mem.indexOf(u8, xml, open) orelse return null;
    const body_start = start + open.len;
    const end = std.mem.indexOf(u8, xml[body_start..], close) orelse return null;
    return xml[body_start .. body_start + end];
}

fn elementText(xml: []const u8, name: []const u8) ?[]const u8 {
    const body = elementBody(xml, name) orelse return null;
    if (std.mem.indexOfScalar(u8, body, '<') != null) return null;
    return std.mem.trim(u8, body, " \t\r\n");
}

fn decodeXmlText(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var offset: usize = 0;
    while (offset < value.len) {
        if (value[offset] != '&') {
            output.append(allocator, value[offset]) catch return error.OutOfMemory;
            offset += 1;
            continue;
        }
        const entities = [_]struct { encoded: []const u8, decoded: u8 }{
            .{ .encoded = "&amp;", .decoded = '&' },
            .{ .encoded = "&lt;", .decoded = '<' },
            .{ .encoded = "&gt;", .decoded = '>' },
            .{ .encoded = "&quot;", .decoded = '"' },
            .{ .encoded = "&apos;", .decoded = '\'' },
        };
        var matched = false;
        for (entities) |entity| if (std.mem.startsWith(u8, value[offset..], entity.encoded)) {
            output.append(allocator, entity.decoded) catch return error.OutOfMemory;
            offset += entity.encoded.len;
            matched = true;
            break;
        };
        if (!matched) return error.MalformedXml;
    }
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

test "lifecycle parser supports current noncurrent and marker expiration" {
    const configuration = try parse(std.testing.allocator, "<LifecycleConfiguration><Rule><ID>cleanup</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status>" ++
        "<Expiration><Days>30</Days></Expiration><NoncurrentVersionExpiration><NoncurrentDays>7</NoncurrentDays>" ++
        "<NewerNoncurrentVersions>2</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>");
    defer configuration.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), configuration.rules.len);
    try std.testing.expectEqualStrings("logs/", configuration.rules[0].prefix);
    try std.testing.expectEqual(@as(?u32, 30), configuration.rules[0].expiration_days);
    try std.testing.expectEqual(@as(u32, 2), configuration.rules[0].newer_noncurrent_versions);
}

test "lifecycle scanner expires noncurrent versions and sole delete markers" {
    const MemoryMetadataRepository = @import("../testing/memory_metadata_repository.zig").MemoryMetadataRepository;
    const MetadataBucketStore = @import("../metadata/bucket_store.zig").MetadataBucketStore;
    const MetadataObjectStore = @import("../metadata/object_store.zig").MetadataObjectStore;
    const LocalObjectDataStore = @import("../backend/local_object_data.zig").LocalObjectDataStore;
    const MetadataIndex = @import("../metadata/index.zig").MetadataIndex;
    const ObjectLockPool = @import("object_lock_pool.zig").ObjectLockPool;
    const streaming = @import("../common/streaming.zig");
    const test_streams = @import("../testing/streams.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".zigfs/tmp");
    try tmp.dir.createDirPath(std.testing.io, "objects");
    var memory = MemoryMetadataRepository.init(std.testing.allocator);
    defer memory.deinit();
    var bucket_store = MetadataBucketStore.init(memory.interface());
    var object_store = MetadataObjectStore.init(memory.interface());
    var data_store = LocalObjectDataStore.init(
        std.testing.allocator,
        tmp.dir,
        std.testing.io,
        streaming.min_buffer_size,
    );
    var index = MetadataIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.rebuild(memory.interface());
    var state_mutex: std.Io.Mutex = .init;
    var object_locks: ObjectLockPool = .{};
    const buckets = BucketService.init(std.testing.allocator, std.testing.io, bucket_store.interface(), &index, &state_mutex);
    const created = try buckets.create("lifecycle-data", "owner-a");
    created.deinit(std.testing.allocator);
    const enabled = try buckets.setVersioning("lifecycle-data", .enabled);
    enabled.deinit(std.testing.allocator);
    const lifecycle_bucket = try buckets.putLifecycle("lifecycle-data", "<LifecycleConfiguration>" ++
        "<Rule><ID>old-versions</ID><Filter><Prefix>history/</Prefix></Filter><Status>Enabled</Status>" ++
        "<NoncurrentVersionExpiration><NoncurrentDays>1</NoncurrentDays></NoncurrentVersionExpiration></Rule>" ++
        "<Rule><ID>markers</ID><Filter><Prefix>markers/</Prefix></Filter><Status>Enabled</Status>" ++
        "<Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration></Rule>" ++
        "</LifecycleConfiguration>");
    lifecycle_bucket.deinit(std.testing.allocator);
    const objects = ObjectService.init(
        std.testing.allocator,
        std.testing.io,
        bucket_store.interface(),
        object_store.interface(),
        data_store.interface(),
        null,
        &index,
        &state_mutex,
        &object_locks,
    );
    const scanner: LifecycleService = .{ .allocator = std.testing.allocator, .buckets = buckets, .objects = objects };

    var first_source = test_streams.SliceSource.init("first");
    const first = try objects.put("lifecycle-data", "history/file.txt", first_source.interface(), .{});
    defer first.deinit(std.testing.allocator);
    var second_source = test_streams.SliceSource.init("second");
    const second = try objects.put("lifecycle-data", "history/file.txt", second_source.interface(), .{});
    defer second.deinit(std.testing.allocator);

    var marker_source = test_streams.SliceSource.init("marker body");
    const marker_object = try objects.put("lifecycle-data", "markers/removed.txt", marker_source.interface(), .{});
    defer marker_object.deinit(std.testing.allocator);
    const marker_delete = try objects.delete("lifecycle-data", "markers/removed.txt");
    try std.testing.expect(marker_delete.delete_marker);
    try std.testing.expect((try objects.deleteVersion("lifecycle-data", "markers/removed.txt", marker_object.version_id)).deleted);

    const report = try scanner.scan(@max(first.last_modified_unix_seconds, second.last_modified_unix_seconds) + 86_401);
    try std.testing.expectEqual(@as(usize, 1), report.noncurrent_expired);
    try std.testing.expectEqual(@as(usize, 1), report.delete_markers_removed);
    const versions = try objects.listVersions("lifecycle-data", "history/");
    defer versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), versions.entries.len);
    try std.testing.expect(object_domain.VersionId.eql(second.version_id, versions.entries[0].version_id));
    const marker_versions = try objects.listVersions("lifecycle-data", "markers/");
    defer marker_versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), marker_versions.entries.len);
}
