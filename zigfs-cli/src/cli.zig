const std = @import("std");

pub const version = "0.1.0";

const help_text =
    \\ZigFS CLI (zc)
    \\Usage: zc [OPTIONS] <COMMAND> [ARGS...]
    \\
    \\Options:
    \\  -h, --help       Show this help message
    \\  -V, --version    Show the CLI version
    \\
    \\Commands:
    \\  help             Show help
    \\  version          Show the CLI version
    \\
    \\More commands will be added as the S3 and ZigFS management clients land.
    \\
;

pub const Command = enum {
    help,
    version,
};

pub const ParseError = error{
    UnknownOption,
    UnknownCommand,
};

pub const Invocation = struct {
    command: Command,
    arguments: []const []const u8,
};

pub fn parse(args: []const []const u8) ParseError!Invocation {
    if (args.len == 0) return .{ .command = .help, .arguments = &.{} };

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .{ .command = .help, .arguments = args[index + 1 ..] };
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .{ .command = .version, .arguments = args[index + 1 ..] };
        }
        if (arg.len > 0 and arg[0] == '-') return error.UnknownOption;

        if (std.mem.eql(u8, arg, "help")) return .{ .command = .help, .arguments = args[index + 1 ..] };
        if (std.mem.eql(u8, arg, "version")) return .{ .command = .version, .arguments = args[index + 1 ..] };
        return error.UnknownCommand;
    }
    return .{ .command = .help, .arguments = &.{} };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    const invocation = parse(args) catch |err| {
        try writeError(io, switch (err) {
            error.UnknownOption => "unknown option\n",
            error.UnknownCommand => "unknown command\n",
        });
        try std.Io.File.stderr().writeStreamingAll(io, help_text);
        return err;
    };

    switch (invocation.command) {
        .help => try std.Io.File.stdout().writeStreamingAll(io, help_text),
        .version => try std.Io.File.stdout().writeStreamingAll(io, "zc " ++ version ++ "\n"),
    }
}

fn writeError(io: std.Io, message: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, "zc: ");
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

test "empty arguments show help" {
    const invocation = try parse(&.{});
    try std.testing.expectEqual(Command.help, invocation.command);
}

test "short and long global options" {
    try std.testing.expectEqual(Command.help, (try parse(&.{"--help"})).command);
    try std.testing.expectEqual(Command.help, (try parse(&.{"-h"})).command);
    try std.testing.expectEqual(Command.version, (try parse(&.{"--version"})).command);
    try std.testing.expectEqual(Command.version, (try parse(&.{"-V"})).command);
}

test "commands preserve trailing arguments" {
    const invocation = try parse(&.{ "version", "extra" });
    try std.testing.expectEqual(Command.version, invocation.command);
    try std.testing.expectEqual(@as(usize, 1), invocation.arguments.len);
    try std.testing.expectEqualStrings("extra", invocation.arguments[0]);
}

test "unknown input is rejected" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"bucket"}));
    try std.testing.expectError(error.UnknownOption, parse(&.{"--json"}));
}
