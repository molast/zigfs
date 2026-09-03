const std = @import("std");

pub const Error = error{ InvalidTimestamp, NoSpaceLeft };

pub fn formatIso8601(
    unix_seconds: i64,
    buffer: *[20]u8,
) Error![]const u8 {
    const parts = try partsFromUnix(unix_seconds);
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    ) catch error.NoSpaceLeft;
}

pub fn formatAmzDate(
    unix_seconds: i64,
    buffer: *[16]u8,
) Error![]const u8 {
    const parts = try partsFromUnix(unix_seconds);
    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    ) catch error.NoSpaceLeft;
}

pub fn formatHttpDate(
    unix_seconds: i64,
    buffer: *[29]u8,
) Error![]const u8 {
    const parts = try partsFromUnix(unix_seconds);
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    return std.fmt.bufPrint(
        buffer,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekdays[parts.weekday],
            parts.day,
            months[parts.month - 1],
            parts.year,
            parts.hour,
            parts.minute,
            parts.second,
        },
    ) catch error.NoSpaceLeft;
}

const Parts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};

fn partsFromUnix(unix_seconds: i64) Error!Parts {
    if (unix_seconds < 0) return error.InvalidTimestamp;
    const seconds: u64 = @intCast(unix_seconds);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
        .weekday = @intCast((epoch_day.day + 4) % 7),
    };
}

test "S3 timestamps use UTC ISO-8601 and RFC 7231 formats" {
    var iso_buffer: [20]u8 = undefined;
    var amz_buffer: [16]u8 = undefined;
    var http_buffer: [29]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2013-05-24T00:00:00Z",
        try formatIso8601(1_369_353_600, &iso_buffer),
    );
    try std.testing.expectEqualStrings(
        "20130524T000000Z",
        try formatAmzDate(1_369_353_600, &amz_buffer),
    );
    try std.testing.expectEqualStrings(
        "Fri, 24 May 2013 00:00:00 GMT",
        try formatHttpDate(1_369_353_600, &http_buffer),
    );
}
