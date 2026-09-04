const std = @import("std");

pub const http = @import("http.zig");
pub const management = @import("management.zig");
pub const aws_chunked = @import("aws_chunked.zig");
pub const s3 = @import("s3.zig");
pub const s3_delete_objects = @import("s3_delete_objects.zig");
pub const s3_multipart = @import("s3_multipart.zig");
pub const s3_post_policy = @import("s3_post_policy.zig");
pub const s3_protocol = @import("s3_protocol.zig");

pub const health_live_path = http.health_live_path;
pub const health_ready_path = http.health_ready_path;
pub const metrics_path = http.metrics_path;

test {
    std.testing.refAllDecls(@This());
}
