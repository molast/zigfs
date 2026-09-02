const std = @import("std");

pub const ValidationError = error{
    InvalidLength,
    InvalidCharacter,
    InvalidBoundary,
};

pub fn validateName(name: []const u8) ValidationError!void {
    if (name.len < 3 or name.len > 63) return error.InvalidLength;
    if (!isAlphaNumeric(name[0]) or !isAlphaNumeric(name[name.len - 1])) {
        return error.InvalidBoundary;
    }

    for (name) |character| {
        if (!isAlphaNumeric(character) and character != '-' and character != '.') {
            return error.InvalidCharacter;
        }
    }
}

fn isAlphaNumeric(character: u8) bool {
    return (character >= 'a' and character <= 'z') or
        (character >= '0' and character <= '9');
}

test "accept valid bucket name" {
    try validateName("project-assets-01");
}

test "reject uppercase bucket name" {
    try std.testing.expectError(error.InvalidCharacter, validateName("Project-assets"));
}
