const credential_domain = @import("../domain/credential.zig");

pub const Error = error{AccessDenied};

pub fn authorize(
    policy: credential_domain.Policy,
    action: credential_domain.Action,
) Error!void {
    if (!policy.allows(action)) return error.AccessDenied;
}

test "read-only policy blocks object mutations" {
    try authorize(.read_only, .get_object);
    try @import("std").testing.expectError(
        error.AccessDenied,
        authorize(.read_only, .put_object),
    );
}
