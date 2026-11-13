const std = @import("std");

/// Transport-neutral event. The caller retains ownership for the duration of send.
/// Retries must retain the same id and payload so consumers can deduplicate.
pub const Event = struct {
    id: []const u8,
    payload: []const u8,
    content_type: []const u8 = "application/json",
};
pub const Error = error{
    OutOfMemory,
    Canceled,
    Timeout,
    Unavailable,
    RateLimited,
    AuthenticationFailed,
    InvalidConfiguration,
    InvalidEvent,
    Rejected,
};
pub fn retryable(err: Error) bool {
    return switch (err) {
        error.Timeout, error.Unavailable, error.RateLimited => true,
        else => false,
    };
}

/// One adapter instance binds one destination's protocol, credentials and settings.
/// The owner manages its lifetime and synchronization; callers know no protocol.
/// Success means the transport accepted the event according to its configured
/// protocol/QoS, not that the final consumer processed it. No automatic retries
/// occur inside this interface. Network implementations are registered separately.
pub const Sender = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (*anyopaque, std.mem.Allocator, std.Io, Event) Error!void,
    };

    pub fn send(self: Sender, a: std.mem.Allocator, io: std.Io, event: Event) Error!void {
        if (event.id.len == 0 or event.payload.len == 0) return error.InvalidEvent;
        try self.vtable.send(self.context, a, io, event);
    }
};
