const std = @import("std");

pub const Point = enum {
    multipart_upload_cleanup,
    object_data_write,
    object_stage_synced,
    object_generation_published,
    metadata_before_commit,
    metadata_after_commit,
};

pub const Injector = struct {
    context: ?*anyopaque = null,
    trigger_fn: ?*const fn (context: *anyopaque, point: Point) bool = null,

    pub const disabled: Injector = .{};

    pub fn trigger(self: Injector, point: Point) bool {
        const context = self.context orelse return false;
        const trigger_fn = self.trigger_fn orelse return false;
        return trigger_fn(context, point);
    }
};

pub const FailOnce = struct {
    point: Point,
    skip_hits: usize = 0,
    hits: usize = 0,
    triggered: bool = false,

    pub fn init(point: Point, skip_hits: usize) FailOnce {
        return .{ .point = point, .skip_hits = skip_hits };
    }

    pub fn interface(self: *FailOnce) Injector {
        return .{ .context = self, .trigger_fn = trigger };
    }

    fn trigger(context: *anyopaque, point: Point) bool {
        const self: *FailOnce = @ptrCast(@alignCast(context));
        if (self.triggered or point != self.point) return false;
        self.hits += 1;
        if (self.hits <= self.skip_hits) return false;
        self.triggered = true;
        return true;
    }
};

test "fail once injector targets one checkpoint after optional skipped hits" {
    var injector = FailOnce.init(.object_data_write, 1);
    const interface = injector.interface();
    try std.testing.expect(!interface.trigger(.metadata_after_commit));
    try std.testing.expect(!interface.trigger(.object_data_write));
    try std.testing.expect(interface.trigger(.object_data_write));
    try std.testing.expect(!interface.trigger(.object_data_write));
    try std.testing.expect(injector.triggered);
    try std.testing.expectEqual(@as(usize, 2), injector.hits);
}
