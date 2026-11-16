const std = @import("std");
const builtin = @import("builtin");

extern fn zigfs_process_metrics(rss: *u64, cpu: *f64, sampled: *f64) c_int;

pub const Sample = struct { resident_bytes: u64, cpu_seconds: f64, sampled_at_seconds: f64 };

pub fn read() ?Sample {
    var sample: Sample = undefined;
    if (zigfs_process_metrics(&sample.resident_bytes, &sample.cpu_seconds, &sample.sampled_at_seconds) != 0) return null;
    return sample;
}

test "process telemetry measures current process with monotonic counters" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const first = read() orelse return error.TestUnexpectedResult;
    const next = read() orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.resident_bytes > 0);
    try std.testing.expect(first.cpu_seconds >= 0);
    try std.testing.expect(next.cpu_seconds >= first.cpu_seconds);
    try std.testing.expect(next.sampled_at_seconds >= first.sampled_at_seconds);
}
