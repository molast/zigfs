const std = @import("std");

pub const version = "0.1.0";

pub const application = @import("application/mod.zig");
pub const auth = @import("auth/mod.zig");
pub const backend = @import("backend/mod.zig");
pub const common = @import("common/mod.zig");
pub const config = @import("config.zig");
pub const domain = @import("domain/mod.zig");
pub const metadata = @import("metadata/mod.zig");
pub const ports = @import("ports/mod.zig");
pub const transport = @import("transport/mod.zig");

test "version follows semantic versioning shape" {
    try std.testing.expect(std.mem.count(u8, version, ".") == 2);
}
