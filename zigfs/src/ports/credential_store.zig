const std = @import("std");
const credential_domain = @import("../domain/credential.zig");

pub const Error = error{
    OutOfMemory,
    NotFound,
    Conflict,
    InvalidValue,
    CorruptMetadata,
    Unavailable,
};

pub const ExpectedGeneration = union(enum) {
    missing,
    exact: u64,
};

pub const Record = union(enum) {
    active: credential_domain.Credential,
    tombstone: u64,

    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        switch (self) {
            .active => |credential| credential.deinit(allocator),
            .tombstone => {},
        }
    }
};

pub const CredentialStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            access_key: []const u8,
        ) Error!Record,
        put: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            value: credential_domain.View,
            expected_generation: ExpectedGeneration,
        ) Error!u64,
        tombstone: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            access_key: []const u8,
            expected_generation: u64,
        ) Error!u64,
    };

    pub fn get(
        self: CredentialStore,
        allocator: std.mem.Allocator,
        access_key: []const u8,
    ) Error!Record {
        return self.vtable.get(self.context, allocator, access_key);
    }

    pub fn put(
        self: CredentialStore,
        allocator: std.mem.Allocator,
        value: credential_domain.View,
        expected_generation: ExpectedGeneration,
    ) Error!u64 {
        return self.vtable.put(self.context, allocator, value, expected_generation);
    }

    pub fn tombstone(
        self: CredentialStore,
        allocator: std.mem.Allocator,
        access_key: []const u8,
        expected_generation: u64,
    ) Error!u64 {
        return self.vtable.tombstone(
            self.context,
            allocator,
            access_key,
            expected_generation,
        );
    }
};
