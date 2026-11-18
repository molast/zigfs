const SystemStore = @import("../metadata/system_store.zig").SystemStore;
const std = @import("std");
const Point = @import("monitoring.zig").Point;

pub const Trend = struct { samples: usize = 0, seconds: i64 = 0, delta: ?f64 = null, per_hour: ?f64 = null, rising_fraction: ?f64 = null, status: enum { insufficient, stable, growing } = .insufficient };
pub const Analysis = struct { rss: Trend, heap: Trend, descriptors: Trend, allocations: Trend };

/// Same-run contiguous observations only. Growth is evidence, never proof of leakage.
pub fn trend(points: []const Point, next: usize, latest: Point, comptime field: []const u8, minimum_growth: f64) Trend {
    var result: Trend = .{};
    var first: ?f64 = null;
    var last: f64 = 0;
    var start: i64 = 0;
    var previous_time: i64 = 0;
    var rises: usize = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (0..points.len) |i| {
        const point = points[(next + i) % points.len];
        if (point.run_id != latest.run_id or point.timestamp < latest.timestamp - 900) continue;
        const value: ?f64 = if (comptime std.mem.eql(u8, field, "active_allocations")) (if (point.allocations != null and point.frees != null and point.allocations.? >= point.frees.?) @floatFromInt(point.allocations.? - point.frees.?) else null) else @field(point, field);
        if (value == null or (previous_time != 0 and (point.timestamp <= previous_time or point.timestamp - previous_time > 30))) {
            result = .{};
            first = null;
            rises = 0;
            sx = 0;
            sy = 0;
            sxx = 0;
            sxy = 0;
        }
        if (value) |v| {
            if (first == null) {
                first = v;
                start = point.timestamp;
            } else if (v > last) {
                rises += 1;
            }
            const x: f64 = @floatFromInt(point.timestamp - start);
            sx += x;
            sy += v;
            sxx += x * x;
            sxy += x * v;
            result.samples += 1;
            last = v;
            previous_time = point.timestamp;
        }
    }
    result.seconds = if (first != null) previous_time - start else 0;
    if (result.samples < 20 or result.seconds < 300 or latest.timestamp - previous_time > 30) return result;
    const n: f64 = @floatFromInt(result.samples);
    const divisor = n * sxx - sx * sx;
    if (divisor <= 0) return result;
    result.delta = last - first.?;
    result.per_hour = (n * sxy - sx * sy) / divisor * 3600;
    result.rising_fraction = @as(f64, @floatFromInt(rises)) / (n - 1);
    result.status = if (result.delta.? >= minimum_growth and result.per_hour.? > 0 and result.rising_fraction.? >= 0.8) .growing else .stable;
    return result;
}
pub fn analyze(points: []const Point, next: usize, latest: Point) Analysis {
    return .{ .rss = trend(points, next, latest, "rss", 32 * 1024 * 1024), .heap = trend(points, next, latest, "heap", 16 * 1024 * 1024), .descriptors = trend(points, next, latest, "descriptors", 32), .allocations = trend(points, next, latest, "active_allocations", 1024) };
}

pub const RuleId = enum { cpu_high, rss_high, heap_growth, fd_growth, fd_high, storage_low, thread_high, api_errors, api_latency, allocation_failure };
pub const rule_count = @typeInfo(RuleId).@"enum".field_names.len;
pub const Severity = enum { info, warning, err, critical };
pub const Rule = struct { severity: Severity = .warning, id: RuleId, enabled: bool = true, threshold: f64, duration_seconds: u32 = 60 };
pub const Rules = [rule_count]Rule;
pub const defaults: Rules = .{
    .{ .id = .cpu_high, .threshold = 90 },                                         .{ .id = .rss_high, .threshold = 4 * 1024 * 1024 * 1024 },
    .{ .id = .heap_growth, .threshold = 16 * 1024 * 1024, .duration_seconds = 0 }, .{ .id = .fd_growth, .threshold = 32, .duration_seconds = 0 },
    .{ .id = .fd_high, .threshold = 80 },                                          .{ .id = .storage_low, .threshold = 10 },
    .{ .id = .thread_high, .threshold = 256 },                                     .{ .id = .api_errors, .threshold = 5 },
    .{ .id = .api_latency, .threshold = 1000 },                                    .{ .id = .allocation_failure, .threshold = 0, .duration_seconds = 0 },
};
pub fn validate(rules: Rules) !void {
    for (rules, 0..) |rule, i| {
        if (@backingInt(rule.id) != i or !std.math.isFinite(rule.threshold) or rule.threshold < 0 or rule.threshold > 1e15 or rule.duration_seconds > 3600) return error.InvalidMonitoringRules;
        if ((rule.id == .cpu_high or rule.id == .fd_high or rule.id == .storage_low or rule.id == .api_errors) and rule.threshold > 100) return error.InvalidMonitoringRules;
    }
}
pub const State = enum { disabled, no_data, normal, pending, firing };
pub const Alert = struct { id: RuleId, state: State = .no_data, value: ?f64 = null, since: ?i64 = null, acknowledged: bool = false };
pub const Event = struct { severity: Severity = .warning, id: RuleId, timestamp: i64, state: State };
pub const Engine = struct {
    rules: Rules = defaults,
    alerts: [rule_count]Alert = initAlerts(),
    events: [128]Event = undefined,
    event_count: usize = 0,
    previous_timestamp: i64 = 0,
    previous_failures: ?u64 = null,
    pub fn reset(self: *Engine, rules: Rules) void {
        self.rules = rules;
        self.alerts = initAlerts();
        self.previous_timestamp = 0;
        self.previous_failures = null;
    }
    pub fn evaluate(self: *Engine, p: Point, analysis: Analysis, interval: u64) void {
        const failure_delta: ?f64 = if (p.allocation_failures) |n| (if (self.previous_failures) |old| (if (n >= old) @floatFromInt(n - old) else null) else null) else null;
        for (&self.alerts, self.rules) |*alert, rule| {
            const old_state = alert.state;
            alert.value = switch (rule.id) {
                .cpu_high => p.host_cpu,
                .rss_high => p.rss,
                .thread_high => p.threads,
                .heap_growth => if (analysis.heap.status == .insufficient) null else if ((analysis.heap.rising_fraction orelse 0) >= 0.8) analysis.heap.delta else 0,
                .fd_growth => if (analysis.descriptors.status == .insufficient) null else if ((analysis.descriptors.rising_fraction orelse 0) >= 0.8) analysis.descriptors.delta else 0,
                .fd_high => ratio(p.descriptors, p.descriptor_limit),
                .storage_low => ratio(if (p.storage_available) |v| @as(f64, @floatFromInt(v)) else null, if (p.storage_total) |v| @as(f64, @floatFromInt(v)) else null),
                .api_errors => p.error_percent,
                .api_latency => p.p99,
                .allocation_failure => failure_delta,
            };
            if (!rule.enabled) {
                alert.state = .disabled;
                alert.since = null;
                alert.acknowledged = false;
            } else if (alert.value == null) {
                alert.state = .no_data;
                alert.since = null;
                alert.acknowledged = false;
            } else {
                const breached = if (rule.id == .storage_low) alert.value.? < rule.threshold else alert.value.? > rule.threshold;
                if (!breached) {
                    alert.state = .normal;
                    alert.since = null;
                    alert.acknowledged = false;
                } else {
                    if (alert.since == null or p.timestamp <= self.previous_timestamp or p.timestamp - self.previous_timestamp > @as(i64, @intCast(interval * 3))) alert.since = p.timestamp;
                    alert.state = if (p.timestamp - alert.since.? >= rule.duration_seconds) .firing else .pending;
                    if (old_state != .firing and alert.state == .firing) alert.acknowledged = false;
                }
            }
            if (old_state != alert.state and (old_state == .firing or alert.state == .firing)) {
                if (self.event_count == self.events.len) {
                    std.mem.copyForwards(Event, self.events[0 .. self.events.len - 1], self.events[1..]);
                    self.event_count -= 1;
                }
                self.events[self.event_count] = .{ .id = rule.id, .timestamp = p.timestamp, .state = alert.state, .severity = rule.severity };
                self.event_count += 1;
            }
        }
        self.previous_timestamp = p.timestamp;
        self.previous_failures = p.allocation_failures;
    }
};
fn initAlerts() [rule_count]Alert {
    var result: [rule_count]Alert = undefined;
    for (&result, 0..) |*a, i| a.* = .{ .id = @fromBackingInt(@intCast(i)) };
    return result;
}
fn ratio(value: ?f64, total: ?f64) ?f64 {
    if (value == null or total == null or total.? <= 0) return null;
    return value.? / total.? * 100;
}

pub fn load(a: std.mem.Allocator, root: SystemStore, io: std.Io) !Rules {
    _ = io;
    const bytes = root.read(a, "config/monitoring-rules.json", 8192) catch |err| switch (err) {
        error.NotFound => return defaults,
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Rules, a, bytes, .{});
    defer parsed.deinit();
    try validate(parsed.value);
    return parsed.value;
}
pub fn save(a: std.mem.Allocator, root: SystemStore, io: std.Io, rules: Rules) !void {
    _ = io;
    try validate(rules);
    const bytes = try std.json.Stringify.valueAlloc(a, rules, .{});
    defer a.free(bytes);
    try root.put(a, "config/monitoring-rules.json", bytes);
}

test "growth requires five minutes of contiguous same-run evidence" {
    var points: [61]Point = undefined;
    for (&points, 0..) |*p, i| p.* = .{ .timestamp = @intCast(1000 + i * 10), .run_id = 1, .heap = @floatFromInt(i * 1024 * 1024) };
    try std.testing.expectEqual(.growing, analyze(&points, 0, points[60]).heap.status);
    points[60].run_id = 2;
    try std.testing.expectEqual(.insufficient, analyze(&points, 0, points[60]).heap.status);
}
test "alerts require sustained evidence and reset pending timers across gaps" {
    var engine: Engine = .{};
    const analysis = analyze(&.{}, 0, .{});
    engine.evaluate(.{ .timestamp = 100, .host_cpu = 99 }, analysis, 10);
    try std.testing.expectEqual(.pending, engine.alerts[0].state);
    for (1..7) |i| engine.evaluate(.{ .timestamp = @intCast(100 + i * 10), .host_cpu = 99 }, analysis, 10);
    try std.testing.expectEqual(.firing, engine.alerts[0].state);
    engine.evaluate(.{ .timestamp = 300, .host_cpu = 99 }, analysis, 10);
    try std.testing.expectEqual(.pending, engine.alerts[0].state);
    engine.evaluate(.{ .timestamp = 310 }, analysis, 10);
    try std.testing.expectEqual(.no_data, engine.alerts[0].state);
}

test "alert recovery clears acknowledgement and records bounded severity transitions" {
    var engine: Engine = .{};
    engine.rules[0].duration_seconds = 0;
    engine.rules[0].severity = .critical;
    const analysis = analyze(&.{}, 0, .{});
    for (0..150) |i| {
        engine.evaluate(.{ .timestamp = @intCast(100 + i * 2), .host_cpu = 99 }, analysis, 1);
        engine.alerts[0].acknowledged = true;
        engine.evaluate(.{ .timestamp = @intCast(101 + i * 2), .host_cpu = 1 }, analysis, 1);
        try std.testing.expectEqual(.normal, engine.alerts[0].state);
        try std.testing.expect(!engine.alerts[0].acknowledged);
    }
    try std.testing.expectEqual(@as(usize, 128), engine.event_count);
    try std.testing.expectEqual(.critical, engine.events[127].severity);
    try std.testing.expectEqual(.normal, engine.events[127].state);
}

test "rule validation rejects out of range and reordered configurations" {
    var rules = defaults;
    rules[0].threshold = 101;
    try std.testing.expectError(error.InvalidMonitoringRules, validate(rules));
    rules = defaults;
    rules[0].duration_seconds = 3601;
    try std.testing.expectError(error.InvalidMonitoringRules, validate(rules));
    rules = defaults;
    rules[0].id = .rss_high;
    try std.testing.expectError(error.InvalidMonitoringRules, validate(rules));
}

test "stable resource trends are normal rather than missing observations" {
    var engine: Engine = .{};
    var analysis = analyze(&.{}, 0, .{});
    analysis.heap = .{ .status = .stable, .delta = 0, .rising_fraction = 0 };
    engine.evaluate(.{ .timestamp = 100 }, analysis, 1);
    try std.testing.expectEqual(.normal, engine.alerts[@backingInt(RuleId.heap_growth)].state);
    try std.testing.expectEqual(.no_data, engine.alerts[@backingInt(RuleId.fd_growth)].state);
}
