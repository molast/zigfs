//! Client upload policy v1. Keep aligned with Admin upload-policy.ts and the
//! boundary cases in docs/validation/upload-policy-cases.json.
const std = @import("std");
pub const mib: u64 = 1024 * 1024;
pub const threshold: u64 = 16 * mib;
pub const max_size: u64 = 5 * 1024 * 1024 * mib;
pub const Plan = struct { part_size: u64, concurrency: usize };

pub fn choose(length: u64, max_parts: u64) !Plan {
    if (length > max_size or max_parts == 0 or max_parts > 10000) return error.InvalidInput;
    const preferred: u64 = if (length < 128 * mib) 8 * mib else if (length < 1024 * mib) 16 * mib else if (length < 10 * 1024 * mib) 32 * mib else if (length < 100 * 1024 * mib) 64 * mib else 128 * mib;
    const required = std.math.divCeil(u64, length, max_parts) catch return error.InvalidInput;
    const part_size = (std.math.divCeil(u64, @max(preferred, required), mib) catch return error.InvalidInput) * mib;
    if (part_size > 5 * 1024 * mib) return error.InvalidInput;
    return .{ .part_size = part_size, .concurrency = if (length < threshold) 1 else if (length < 128 * mib) 2 else 4 };
}

test "upload policy boundaries and maximum part count" {
    const cases = [_]struct { length: u64, part: u64, lanes: usize }{
        .{ .length = threshold - 1, .part = 8, .lanes = 1 },
        .{ .length = threshold, .part = 8, .lanes = 2 },
        .{ .length = 128 * mib - 1, .part = 8, .lanes = 2 },
        .{ .length = 128 * mib, .part = 16, .lanes = 4 },
        .{ .length = 1024 * mib, .part = 32, .lanes = 4 },
        .{ .length = 10 * 1024 * mib, .part = 64, .lanes = 4 },
        .{ .length = 100 * 1024 * mib, .part = 128, .lanes = 4 },
        .{ .length = max_size, .part = 525, .lanes = 4 },
    };
    for (cases) |case| {
        const plan = try choose(case.length, 10000);
        try std.testing.expectEqual(case.part * mib, plan.part_size);
        try std.testing.expectEqual(case.lanes, plan.concurrency);
        try std.testing.expect((case.length + plan.part_size - 1) / plan.part_size <= 10000);
    }
    try std.testing.expectEqual(64 * mib, (try choose(128 * mib, 2)).part_size);
    try std.testing.expectError(error.InvalidInput, choose(max_size + 1, 10000));
}
