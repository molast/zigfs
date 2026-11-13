const std = @import("std");
pub const Category = enum { PUT, GET, DELETE, ILM, SCANNER };
pub const Event = struct {
    category: Category,
    name: []const u8,
    bucket_id: [16]u8,
    bucket: []const u8,
    key: []const u8,
    size: ?u64 = null,
    etag: []const u8 = "",
    version_id: []const u8 = "",
    generation: u64 = 0,
};
/// Invoked only after the operation succeeds and storage locks are released.
/// Captures a durable outbox record; it never connects to a remote destination.
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, Event) void,
    pub fn emit(self: Sink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};
test {
    std.testing.refAllDecls(@This());
}
