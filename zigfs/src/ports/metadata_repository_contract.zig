const std = @import("std");
const repository_port = @import("metadata_repository.zig");

pub fn run(repository: repository_port.MetadataRepository) !void {
    try std.testing.expectError(
        error.NotFound,
        repository.get(std.testing.allocator, .bucket, "contract-missing"),
    );

    const first_generation = try repository.put(
        std.testing.allocator,
        .bucket,
        "contract-primary",
        .missing,
        "first",
    );
    try std.testing.expect(first_generation > 0);
    try std.testing.expectError(
        error.Conflict,
        repository.put(
            std.testing.allocator,
            .bucket,
            "contract-primary",
            .missing,
            "duplicate",
        ),
    );

    const first = try repository.get(std.testing.allocator, .bucket, "contract-primary");
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(first_generation, first.generation);
    try std.testing.expect(!first.tombstone);
    try std.testing.expectEqualStrings("first", first.payload);

    const second_generation = try repository.put(
        std.testing.allocator,
        .bucket,
        "contract-primary",
        .{ .exact = first_generation },
        "second",
    );
    try std.testing.expect(second_generation > first_generation);
    try std.testing.expectError(
        error.Conflict,
        repository.put(
            std.testing.allocator,
            .bucket,
            "contract-primary",
            .{ .exact = first_generation },
            "stale",
        ),
    );

    var last_generation = second_generation;
    const separated_types = [_]struct {
        record_type: @import("../metadata/record.zig").Type,
        payload: []const u8,
    }{
        .{ .record_type = .system, .payload = "system-value" },
        .{ .record_type = .object, .payload = "object-value" },
        .{ .record_type = .multipart, .payload = "multipart-value" },
        .{ .record_type = .credential, .payload = "credential-value" },
    };
    for (separated_types) |expected| {
        const item_generation = try repository.put(
            std.testing.allocator,
            expected.record_type,
            "contract-primary",
            .missing,
            expected.payload,
        );
        try std.testing.expect(item_generation > last_generation);
        last_generation = item_generation;

        const item = try repository.get(
            std.testing.allocator,
            expected.record_type,
            "contract-primary",
        );
        defer item.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected.payload, item.payload);
    }

    _ = try repository.put(
        std.testing.allocator,
        .bucket,
        "contract-secondary",
        .missing,
        "third",
    );
    const scan = try repository.scan(std.testing.allocator, .bucket);
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.records.len);
    try std.testing.expectEqualStrings("contract-primary", scan.records[0].key);
    try std.testing.expectEqualStrings("contract-secondary", scan.records[1].key);
    try std.testing.expectEqualStrings("second", scan.records[0].payload);

    const tombstone_generation = try repository.tombstone(
        std.testing.allocator,
        .bucket,
        "contract-secondary",
        .{ .exact = scan.records[1].generation },
    );
    try std.testing.expect(tombstone_generation > scan.records[1].generation);
    const tombstone = try repository.get(
        std.testing.allocator,
        .bucket,
        "contract-secondary",
    );
    defer tombstone.deinit(std.testing.allocator);
    try std.testing.expect(tombstone.tombstone);
    try std.testing.expectEqual(@as(usize, 0), tombstone.payload.len);
}
