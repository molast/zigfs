const std = @import("std");

pub const signature_version = "AWS4-HMAC-SHA256";
pub const management_session = @import("management_session.zig");
pub const iam_policy = @import("iam_policy.zig");
pub const policy = @import("policy.zig");
pub const secret_box = @import("secret_box.zig");
pub const sigv4 = @import("sigv4.zig");

test {
    std.testing.refAllDecls(@This());
}
