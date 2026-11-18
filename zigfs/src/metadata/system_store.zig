const std = @import("std");
const port = @import("../ports/metadata_repository.zig");

const Type = @import("metadata_engine").Type;

pub const document_namespaces = [_]Type{
    .identity,            .policy,       .role,           .bucket_policy,     .object_tag,          .oidc, .settings,
    .monitoring_settings, .log_settings, .audit_settings, .event_destination, .bucket_subscription, .kms,
};

/// Route known business documents explicitly. A new kind must choose a namespace;
/// unknown keys never fall back to the reserved system namespace.
pub fn namespaceFor(key: []const u8) error{InvalidKey}!Type {
    const routes = .{
        .{ "system/identities.json", Type.identity },
        .{ "system/policies.json", Type.policy },
        .{ "system/roles.json", Type.role },
        .{ "system/oidc-providers.enc", Type.oidc },
        .{ "config/instance.json", Type.settings },
        .{ "config/authentication.json", Type.settings },
        .{ "config/display.json", Type.settings },
        .{ "config/listener.json", Type.settings },
        .{ "config/region.json", Type.settings },
        .{ "config/network.json", Type.settings },
        .{ "config/monitoring-rules.json", Type.monitoring_settings },
        .{ "config/log_config.json", Type.log_settings },
        .{ "config/audit_log_config.json", Type.audit_settings },
        .{ "config/event-destinations.enc", Type.event_destination },
        .{ "config/kms.enc", Type.kms },
    };
    inline for (routes) |route| {
        if (std.mem.eql(u8, key, route[0])) return route[1];
    }
    const prefixes = .{
        .{ "system/bucket-policies/", Type.bucket_policy },
        .{ "system/object-tags/", Type.object_tag },
        .{ "config/bucket-subscriptions/", Type.bucket_subscription },
    };
    inline for (prefixes) |route| {
        if (key.len > route[0].len and std.mem.startsWith(u8, key, route[0])) return route[1];
    }
    return error.InvalidKey;
}

/// System documents share the application's engine and durable commit queue.
/// Callers serialize read/modify/write operations with their business mutex.
/// Unconditional replacements do not depend on tombstone GC epochs.
pub const SystemStore = struct {
    repository: ?port.MetadataRepository,

    /// Returns an owned payload. Missing and deleted documents are NotFound.
    pub fn read(self: SystemStore, allocator: std.mem.Allocator, key: []const u8, limit: usize) ![]u8 {
        const record = try (self.repository orelse return error.Unavailable).get(allocator, try namespaceFor(key), key);
        allocator.free(record.key);
        if (record.tombstone) {
            allocator.free(record.payload);
            return error.NotFound;
        }
        if (record.payload.len > limit) {
            allocator.free(record.payload);
            return error.StreamTooLong;
        }
        return record.payload;
    }

    pub fn put(self: SystemStore, allocator: std.mem.Allocator, key: []const u8, payload: []const u8) !void {
        _ = try (self.repository orelse return error.Unavailable).put(allocator, try namespaceFor(key), key, .any, payload);
    }

    pub fn remove(self: SystemStore, allocator: std.mem.Allocator, key: []const u8) !void {
        _ = try (self.repository orelse return error.Unavailable).tombstone(allocator, try namespaceFor(key), key, .any);
    }

    /// Scan one business namespace without reading unrelated configuration or identities.
    pub fn scanNamespace(self: SystemStore, allocator: std.mem.Allocator, namespace: Type) !port.ScanResult {
        for (document_namespaces) |allowed| {
            if (namespace == allowed) {
                return (self.repository orelse return error.Unavailable).scan(allocator, namespace);
            }
        }
        return error.InvalidKey;
    }

    /// Caller owns all returned records, including tombstones. Each namespace is
    /// scanned consistently; callers needing a cross-namespace snapshot must hold
    /// the appropriate business locks or use the engine's online backup API.
    pub fn scan(self: SystemStore, allocator: std.mem.Allocator) !port.ScanResult {
        var records: std.ArrayList(port.Record) = .empty;
        errdefer {
            for (records.items) |record| record.deinit(allocator);
            records.deinit(allocator);
        }
        for (document_namespaces) |namespace| {
            const page = try self.scanNamespace(allocator, namespace);
            records.appendSlice(allocator, page.records) catch |err| {
                page.deinit(allocator);
                return err;
            };
            // Transfer record ownership to the aggregate, freeing only the page array.
            allocator.free(page.records);
        }
        return .{ .records = try records.toOwnedSlice(allocator) };
    }
};

test "system documents route to independent namespaces and never fall back" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repository = try @import("engine_repository.zig").EngineRepository.open(a, tmp.dir, std.testing.io);
    defer repository.deinit();
    const store: SystemStore = .{ .repository = repository.interface() };
    const cases = .{
        .{ "system/identities.json", Type.identity },
        .{ "system/policies.json", Type.policy },
        .{ "system/roles.json", Type.role },
        .{ "system/bucket-policies/bucket.json", Type.bucket_policy },
        .{ "system/object-tags/object.json", Type.object_tag },
        .{ "system/oidc-providers.enc", Type.oidc },
        .{ "config/network.json", Type.settings },
        .{ "config/monitoring-rules.json", Type.monitoring_settings },
        .{ "config/log_config.json", Type.log_settings },
        .{ "config/audit_log_config.json", Type.audit_settings },
        .{ "config/event-destinations.enc", Type.event_destination },
        .{ "config/bucket-subscriptions/bucket.json", Type.bucket_subscription },
        .{ "config/kms.enc", Type.kms },
    };
    inline for (cases) |case| {
        try store.put(a, case[0], "document");
        const record = try repository.interface().get(a, case[1], case[0]);
        defer record.deinit(a);
        try std.testing.expectEqualStrings("document", record.payload);
        try std.testing.expectError(error.NotFound, repository.interface().get(a, .system, case[0]));
        const page = try store.scanNamespace(a, case[1]);
        defer page.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), page.records.len);
    }
    try std.testing.expectError(error.InvalidKey, store.put(a, "system/unknown.json", "not-stored"));
    try std.testing.expectError(error.InvalidKey, store.put(a, "system/object-tags/", "not-stored"));
    try store.remove(a, "system/object-tags/object.json");
    _ = try repository.collect();
    try store.put(a, "system/object-tags/object.json", "recreated");
    const restored = try store.read(a, "system/object-tags/object.json", 128);
    defer a.free(restored);
    try std.testing.expectEqualStrings("recreated", restored);
}
