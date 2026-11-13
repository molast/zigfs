const std = @import("std");
const time = @import("../common/time.zig");
const object_domain = @import("../domain/object.zig");
const BucketService = @import("bucket_service.zig").BucketService;
const object_tags = @import("object_tag_store.zig");
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
    tags: []object_tags.Tag = &.{},
    enabled: bool,
    expiration_days: ?u32 = null,
    expiration_date: ?i64 = null,
    noncurrent_days: ?u32 = null,
    newer_noncurrent_versions: u32 = 0,
    expired_object_delete_marker: bool = false,

    fn deinit(self: Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        for (self.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(self.tags);
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
    data_root: ?std.Io.Dir = null,

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
                    var tag_arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer tag_arena.deinit();
                    var tags: []const object_tags.Tag = &.{};
                    if (!entry.is_delete_marker) {
                        for (configuration.rules) |rule| {
                            if (!rule.enabled or rule.tags.len == 0 or !std.mem.startsWith(u8, entry.key, rule.prefix)) continue;
                            const root = self.data_root orelse return error.ObjectFailure;
                            var version_buffer: [32]u8 = undefined;
                            self.objects.state_mutex.lockUncancelable(self.objects.io);
                            defer self.objects.state_mutex.unlock(self.objects.io);
                            const record = object_tags.load(tag_arena.allocator(), root, self.objects.io, bucket.name, entry.key, entry.version_id.write(&version_buffer)) catch return error.ObjectFailure;
                            tags = record.tags;
                            break;
                        }
                    }
                    if (relative_index == 0) {
                        if (entry.is_delete_marker) {
                            if (key_end - key_start == 1 and shouldRemoveExpiredMarker(configuration.rules, entry.key)) {
                                _ = self.objects.deleteVersion(bucket.name, entry.key, entry.version_id) catch return error.ObjectFailure;
                                report.delete_markers_removed += 1;
                            }
                        } else if (shouldExpireCurrent(configuration.rules, entry.key, tags, entry.last_modified_unix_seconds, now)) {
                            _ = self.objects.delete(bucket.name, entry.key) catch return error.ObjectFailure;
                            report.current_expired += 1;
                        }
                    } else if (!entry.is_delete_marker) {
                        if (shouldExpireNoncurrent(
                            configuration.rules,
                            entry.key,
                            tags,
                            // The immediately newer version (including a delete
                            // marker) made this version noncurrent. Use the scan
                            // snapshot even if that successor was just expired.
                            versions.entries[key_start + relative_index - 1].last_modified_unix_seconds,
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
        if (std.mem.indexOf(u8, body, "<ObjectSize") != null or
            std.mem.indexOf(u8, body, "<Transition>") != null or
            std.mem.indexOf(u8, body, "<AbortIncompleteMultipartUpload>") != null) return error.UnsupportedFeature;
        if (std.mem.count(u8, body, "<Filter>") > 1) return error.MalformedXml;
        var rule: Rule = .{ .prefix = try allocator.dupe(u8, ""), .enabled = enabled };
        errdefer rule.deinit(allocator);
        if (elementBody(body, "Filter")) |filter| {
            try parseFilter(allocator, filter, &rule);
        } else {
            if (std.mem.indexOf(u8, body, "<Tag") != null or std.mem.indexOf(u8, body, "<And") != null) return error.MalformedXml;
            const prefix = try decodeXmlText(allocator, elementText(body, "Prefix") orelse "");
            allocator.free(rule.prefix);
            rule.prefix = prefix;
        }
        if (std.mem.count(u8, body, "<Tag>") != rule.tags.len or std.mem.count(u8, body, "<And>") > 1) return error.MalformedXml;
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
        if (rule.tags.len > 0 and elementBody(body, "Expiration") != null and elementText(elementBody(body, "Expiration").?, "ExpiredObjectDeleteMarker") != null) return error.MalformedXml;
        rules.append(allocator, rule) catch return error.OutOfMemory;
        remainder = remainder[content_start + relative_end + "</Rule>".len ..];
    }
    if (rules.items.len == 0) return error.MalformedXml;
    return .{ .rules = rules.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

const XmlChild = struct { name: []const u8, body: []const u8 };
fn nextChild(remaining: *[]const u8) Error!?XmlChild {
    const xml = std.mem.trim(u8, remaining.*, " \t\r\n");
    if (xml.len == 0) return null;
    if (xml[0] != '<') return error.MalformedXml;
    const end = std.mem.indexOfScalar(u8, xml, '>') orelse return error.MalformedXml;
    const self_closing = end > 1 and xml[end - 1] == '/';
    const name = xml[1..if (self_closing) end - 1 else end];
    for (name) |byte| if (!std.ascii.isAlphabetic(byte)) return error.MalformedXml;
    if (name.len == 0) return error.MalformedXml;
    if (self_closing) {
        remaining.* = xml[end + 1 ..];
        return .{ .name = name, .body = "" };
    }
    var closing: [128]u8 = undefined;
    const close = std.fmt.bufPrint(&closing, "</{s}>", .{name}) catch return error.MalformedXml;
    const last = std.mem.indexOf(u8, xml[end + 1 ..], close) orelse return error.MalformedXml;
    remaining.* = xml[end + 1 + last + close.len ..];
    return .{ .name = name, .body = xml[end + 1 .. end + 1 + last] };
}
fn filterText(a: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (std.mem.indexOfScalar(u8, raw, '<') != null) return error.MalformedXml;
    const value = try decodeXmlText(a, raw);
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        a.free(value);
        return error.MalformedXml;
    }
    return value;
}
fn parseFilter(a: std.mem.Allocator, xml: []const u8, rule: *Rule) Error!void {
    var remaining = xml;
    const first = try nextChild(&remaining) orelse return;
    if (try nextChild(&remaining) != null) return error.MalformedXml;
    var children = if (std.mem.eql(u8, first.name, "And")) first.body else xml;
    const is_and = std.mem.eql(u8, first.name, "And");
    var prefix_seen = false;
    var count: usize = 0;
    var tags: std.ArrayList(object_tags.Tag) = .empty;
    errdefer {
        for (tags.items) |tag| {
            a.free(tag.key);
            a.free(tag.value);
        }
        tags.deinit(a);
    }
    while (try nextChild(&children)) |child| {
        count += 1;
        if (std.mem.eql(u8, child.name, "Prefix")) {
            if (prefix_seen) return error.MalformedXml;
            prefix_seen = true;
            const prefix = try filterText(a, child.body);
            a.free(rule.prefix);
            rule.prefix = prefix;
        } else if (std.mem.eql(u8, child.name, "Tag")) {
            if (tags.items.len >= 10) return error.MalformedXml;
            var fields = child.body;
            var key: ?[]u8 = null;
            var value: ?[]u8 = null;
            errdefer {
                if (key) |v| a.free(v);
                if (value) |v| a.free(v);
            }
            while (try nextChild(&fields)) |field| {
                if (std.mem.eql(u8, field.name, "Key") and key == null) key = try filterText(a, field.body) else if (std.mem.eql(u8, field.name, "Value") and value == null) value = try filterText(a, field.body) else return error.MalformedXml;
            }
            if (key == null or value == null or key.?.len == 0 or key.?.len > 128 or value.?.len > 256) return error.MalformedXml;
            for (key.?) |byte| if (byte < 32 or byte == 127) return error.MalformedXml;
            for (value.?) |byte| if (byte < 32 or byte == 127) return error.MalformedXml;
            for (tags.items) |tag| if (std.mem.eql(u8, tag.key, key.?)) return error.MalformedXml;
            try tags.append(a, .{ .key = key.?, .value = value.? });
        } else return error.UnsupportedFeature;
    }
    if (is_and and count < 2) return error.MalformedXml;
    rule.tags = try tags.toOwnedSlice(a);
}
fn matchesTags(required: []const object_tags.Tag, actual: []const object_tags.Tag) bool {
    for (required) |wanted| {
        var found = false;
        for (actual) |tag| if (std.mem.eql(u8, wanted.key, tag.key) and std.mem.eql(u8, wanted.value, tag.value)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

fn shouldExpireCurrent(rules: []const Rule, key: []const u8, tags: []const object_tags.Tag, modified_at: i64, now: i64) bool {
    for (rules) |rule| {
        if (!rule.enabled or !std.mem.startsWith(u8, key, rule.prefix) or !matchesTags(rule.tags, tags)) continue;
        if (rule.expiration_date) |date| if (now >= date) return true;
        if (rule.expiration_days) |days| if (ageReached(modified_at, now, days)) return true;
    }
    return false;
}

fn shouldExpireNoncurrent(
    rules: []const Rule,
    key: []const u8,
    tags: []const object_tags.Tag,
    noncurrent_since: i64,
    newer_noncurrent_count: u32,
    now: i64,
) bool {
    for (rules) |rule| {
        if (!rule.enabled or !std.mem.startsWith(u8, key, rule.prefix) or !matchesTags(rule.tags, tags)) continue;
        const days = rule.noncurrent_days orelse continue;
        if (newer_noncurrent_count < rule.newer_noncurrent_versions) continue;
        if (noncurrentAgeReached(noncurrent_since, now, days)) return true;
    }
    return false;
}

fn shouldRemoveExpiredMarker(rules: []const Rule, key: []const u8) bool {
    for (rules) |rule| if (rule.enabled and rule.tags.len == 0 and rule.expired_object_delete_marker and
        std.mem.startsWith(u8, key, rule.prefix)) return true;
    return false;
}

fn ageReached(modified_at: i64, now: i64, days: u32) bool {
    if (now <= modified_at) return false;
    const seconds = @as(i64, days) * 86_400;
    return now - modified_at >= seconds;
}

// S3 NoncurrentDays starts at the successor's creation and rounds the
// resulting deadline up to midnight UTC. Overflow must never cause deletion.
fn noncurrentAgeReached(noncurrent_since: i64, now: i64, days: u32) bool {
    const deadline = @addWithOverflow(noncurrent_since, @as(i64, days) * 86_400);
    if (deadline[1] != 0) return false;
    const remainder = @mod(deadline[0], 86_400);
    const rounded = @addWithOverflow(deadline[0], if (remainder == 0) @as(i64, 0) else 86_400 - remainder);
    return rounded[1] == 0 and now >= rounded[0];
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
        null,
        &index,
        &state_mutex,
        &object_locks,
        null,
    );
    const scanner: LifecycleService = .{ .allocator = std.testing.allocator, .buckets = buckets, .objects = objects, .data_root = tmp.dir };

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

    const report = try scanner.scan(@max(first.last_modified_unix_seconds, second.last_modified_unix_seconds) + 2 * 86_400);
    try std.testing.expectEqual(@as(usize, 1), report.noncurrent_expired);
    try std.testing.expectEqual(@as(usize, 1), report.delete_markers_removed);
    const versions = try objects.listVersions("lifecycle-data", "history/");
    defer versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), versions.entries.len);
    try std.testing.expect(object_domain.VersionId.eql(second.version_id, versions.entries[0].version_id));
    const marker_versions = try objects.listVersions("lifecycle-data", "markers/");
    defer marker_versions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), marker_versions.entries.len);

    // Upload age must not expire a version just superseded by an overwrite,
    // a restore (another PUT), or a newly created delete marker.
    (try buckets.putLifecycle("lifecycle-data", "<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Prefix>timing/</Prefix></Filter><NoncurrentVersionExpiration><NoncurrentDays>1</NoncurrentDays></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>")).deinit(std.testing.allocator);
    const since: i64 = 100 * 86_400 + 12 * 3600;
    const deadline: i64 = 102 * 86_400;
    for ([_][]const u8{ "timing/overwrite", "timing/deleted", "timing/restore" }) |key| {
        var original_source = test_streams.SliceSource.init("old contents");
        const original = try objects.put("lifecycle-data", key, original_source.interface(), .{});
        defer original.deinit(std.testing.allocator);
        if (std.mem.eql(u8, key, "timing/deleted")) {
            _ = try objects.delete("lifecycle-data", key);
        } else {
            var replacement_source = test_streams.SliceSource.init(if (std.mem.eql(u8, key, "timing/restore")) "old contents" else "new contents");
            (try objects.put("lifecycle-data", key, replacement_source.interface(), .{})).deinit(std.testing.allocator);
        }
        try setTestVersionTimes(object_store.interface(), &index, memory.interface(), key, &.{ since, since - 30 * 86_400 });
    }
    try std.testing.expectEqual(@as(usize, 0), (try scanner.scan(since + 1)).noncurrent_expired);
    try std.testing.expectEqual(@as(usize, 0), (try scanner.scan(deadline - 1)).noncurrent_expired);
    const before_deadline = try objects.listVersions("lifecycle-data", "timing/");
    defer before_deadline.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), before_deadline.entries.len);
    try std.testing.expectEqual(@as(usize, 3), (try scanner.scan(deadline)).noncurrent_expired);
    const after_deadline = try objects.listVersions("lifecycle-data", "timing/");
    defer after_deadline.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), after_deadline.entries.len);
    for (after_deadline.entries) |entry| try std.testing.expect(entry.is_latest);

    // Older versions use their own immediate successor, not the newest
    // object's timestamp. A single scan can expire the oldest and retain
    // the version that only just became noncurrent.
    for (0..3) |_| {
        var source = test_streams.SliceSource.init("multiple versions");
        (try objects.put("lifecycle-data", "timing/multiple", source.interface(), .{})).deinit(std.testing.allocator);
    }
    try setTestVersionTimes(object_store.interface(), &index, memory.interface(), "timing/multiple", &.{ since, since - 3 * 86_400, since - 30 * 86_400 });
    try std.testing.expectEqual(@as(usize, 1), (try scanner.scan(since + 1)).noncurrent_expired);
    const multiple_remaining = try objects.listVersions("lifecycle-data", "timing/multiple");
    defer multiple_remaining.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), multiple_remaining.entries.len);
    (try buckets.putLifecycle("lifecycle-data", "<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Prefix>timing/</Prefix></Filter><NoncurrentVersionExpiration><NoncurrentDays>1</NoncurrentDays><NewerNoncurrentVersions>1</NewerNoncurrentVersions></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>")).deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), (try scanner.scan(deadline + 30 * 86_400)).noncurrent_expired);

    // A historical version has its own tags; an untagged current version must survive.
    (try buckets.putLifecycle("lifecycle-data", "<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><And><Prefix>tagged/</Prefix><Tag><Key>expire</Key><Value>yes</Value></Tag><Tag><Key>empty</Key><Value/></Tag></And></Filter><Expiration><Days>1</Days></Expiration><NoncurrentVersionExpiration><NoncurrentDays>1</NoncurrentDays></NoncurrentVersionExpiration></Rule></LifecycleConfiguration>")).deinit(std.testing.allocator);
    var newest_time: i64 = 0;
    var tag_version: [32]u8 = undefined;
    for ([_][]const u8{ "tagged/match", "tagged/missing", "tagged/wrong", "outside/match", "tagged/history" }) |key| {
        var source = test_streams.SliceSource.init("body");
        const object = try objects.put("lifecycle-data", key, source.interface(), .{});
        defer object.deinit(std.testing.allocator);
        newest_time = @max(newest_time, object.last_modified_unix_seconds);
        if (!std.mem.eql(u8, key, "tagged/missing")) {
            try object_tags.save(std.testing.allocator, tmp.dir, std.testing.io, "lifecycle-data", key, object.version_id.write(&tag_version), .{ .tags = &.{
                .{ .key = "expire", .value = if (std.mem.eql(u8, key, "tagged/wrong")) "no" else "yes" },
                .{ .key = "empty", .value = "" },
            } });
        }
    }
    var latest_source = test_streams.SliceSource.init("new untagged version");
    const latest = try objects.put("lifecycle-data", "tagged/history", latest_source.interface(), .{});
    defer latest.deinit(std.testing.allocator);
    const tag_report = try scanner.scan(@max(newest_time, latest.last_modified_unix_seconds) + 2 * 86_400);
    try std.testing.expectEqual(@as(usize, 1), tag_report.current_expired);
    try std.testing.expectEqual(@as(usize, 1), tag_report.noncurrent_expired);
    try std.testing.expectError(error.ObjectNotFound, objects.head("lifecycle-data", "tagged/match"));
    for ([_][]const u8{ "tagged/missing", "tagged/wrong", "outside/match", "tagged/history" }) |key| (try objects.head("lifecycle-data", key)).deinit(std.testing.allocator);
    const historical = try objects.listVersions("lifecycle-data", "tagged/history");
    defer historical.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), historical.entries.len);
}

test "lifecycle tag filters use exact AND matching and reject ambiguous filters" {
    const a = std.testing.allocator;
    const xml = "<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><And><Prefix>logs/</Prefix><Tag><Key>team</Key><Value>a&amp;b</Value></Tag><Tag><Key>empty</Key><Value/></Tag></And></Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>";
    const config = try parse(a, xml);
    defer config.deinit(a);
    const tags = [_]object_tags.Tag{ .{ .key = "team", .value = "a&b" }, .{ .key = "empty", .value = "" } };
    try std.testing.expect(shouldExpireCurrent(config.rules, "logs/a", &tags, 0, 86401));
    try std.testing.expect(!shouldExpireCurrent(config.rules, "other/a", &tags, 0, 86401));
    try std.testing.expect(!shouldExpireCurrent(config.rules, "logs/a", tags[0..1], 0, 86401));
    try std.testing.expect(!shouldExpireCurrent(config.rules, "logs/a", &.{ .{ .key = "team", .value = "wrong" }, tags[1] }, 0, 86401));
    const bad_filters = [_][]const u8{
        "<And><Tag><Key>a</Key><Value>b</Value></Tag></And>",
        "<Tag><Key>a</Key></Tag>",
        "<Tag><Key/><Value>b</Value></Tag>",
        "<And><Tag><Key>a</Key><Value>b</Value></Tag><Tag><Key>a</Key><Value>c</Value></Tag></And>",
        "<Prefix>a</Prefix><Tag><Key>a</Key><Value>b</Value></Tag>",
        "<And><Prefix>a</Prefix><Prefix>b</Prefix></And>",
    };
    for (bad_filters) |filter| {
        const invalid = try std.fmt.allocPrint(a, "<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter>{s}</Filter><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>", .{filter});
        defer a.free(invalid);
        try std.testing.expectError(error.MalformedXml, parse(a, invalid));
    }
    try std.testing.expectError(error.MalformedXml, parse(a, "<LifecycleConfiguration><Rule><Status>Enabled</Status><Filter><Tag><Key>a</Key><Value>b</Value></Tag></Filter><Expiration><ExpiredObjectDeleteMarker>true</ExpiredObjectDeleteMarker></Expiration></Rule></LifecycleConfiguration>"));
}

test "noncurrent expiration rounds successor age to UTC midnight and preserves newest versions" {
    const since = 10 * 86_400 + 12 * 3600;
    const deadline = 12 * 86_400;
    try std.testing.expect(!noncurrentAgeReached(since, since - 1, 1));
    try std.testing.expect(!noncurrentAgeReached(since, since + 86_400, 1));
    try std.testing.expect(!noncurrentAgeReached(since, deadline - 1, 1));
    try std.testing.expect(noncurrentAgeReached(since, deadline, 1));
    try std.testing.expect(noncurrentAgeReached(10 * 86_400, 11 * 86_400, 1));
    try std.testing.expect(!noncurrentAgeReached(std.math.maxInt(i64) - 1, std.math.maxInt(i64), 1));
    const rules = [_]Rule{.{ .prefix = "", .enabled = true, .noncurrent_days = 1, .newer_noncurrent_versions = 1 }};
    try std.testing.expect(!shouldExpireNoncurrent(&rules, "file", &.{}, since, 0, deadline));
    try std.testing.expect(shouldExpireNoncurrent(&rules, "file", &.{}, since, 1, deadline));
}

fn setTestVersionTimes(store: @import("../ports/object_store.zig").ObjectStore, index: *@import("../metadata/index.zig").MetadataIndex, repository: @import("../ports/metadata_repository.zig").MetadataRepository, key: []const u8, times: []const i64) !void {
    var record = try store.getHistory(std.testing.allocator, "lifecycle-data", key);
    defer record.deinit(std.testing.allocator);
    const history = &record.active;
    try std.testing.expectEqual(times.len, history.entries.len);
    for (history.entries, times) |*entry, timestamp| switch (entry.*) {
        .object => |*object| object.last_modified_unix_seconds = timestamp,
        .delete_marker => |*marker| marker.last_modified_unix_seconds = timestamp,
    };
    _ = try store.putHistory(std.testing.allocator, history, .{ .exact = history.metadata_generation });
    try index.rebuild(repository);
}
