const std = @import("std");

pub const Error = error{ InvalidTimestamp, InvalidDate, NoSpaceLeft };

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

/// Parses the IMF-fixdate form required by HTTP conditional request headers.
pub fn parseHttpDate(value: []const u8) Error!i64 {
    if (value.len != 29 or
        value[3] != ',' or value[4] != ' ' or value[7] != ' ' or
        value[11] != ' ' or value[16] != ' ' or value[19] != ':' or
        value[22] != ':' or value[25] != ' ' or
        !std.mem.eql(u8, value[26..29], "GMT")) return error.InvalidDate;

    const weekday = value[0..3];
    if (!std.mem.eql(u8, weekday, "Sun") and !std.mem.eql(u8, weekday, "Mon") and
        !std.mem.eql(u8, weekday, "Tue") and !std.mem.eql(u8, weekday, "Wed") and
        !std.mem.eql(u8, weekday, "Thu") and !std.mem.eql(u8, weekday, "Fri") and
        !std.mem.eql(u8, weekday, "Sat")) return error.InvalidDate;
    const month = monthNumber(value[8..11]) orelse return error.InvalidDate;
    const day = parseDecimal(value[5..7]) orelse return error.InvalidDate;
    const year = parseDecimal(value[12..16]) orelse return error.InvalidDate;
    const hour = parseDecimal(value[17..19]) orelse return error.InvalidDate;
    const minute = parseDecimal(value[20..22]) orelse return error.InvalidDate;
    const second = parseDecimal(value[23..25]) orelse return error.InvalidDate;
    if (year < 1970 or year > 9999 or day < 1 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59) return error.InvalidDate;
    return daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
}

/// Parses the UTC ISO-8601 form used by S3 POST policy expirations. Fractional
/// seconds are accepted and intentionally truncated to whole seconds.
pub fn parseIso8601(value: []const u8) Error!i64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or
        value[10] != 'T' or value[13] != ':' or value[16] != ':') return error.InvalidDate;
    const year = parseDecimal(value[0..4]) orelse return error.InvalidDate;
    const month = parseDecimal(value[5..7]) orelse return error.InvalidDate;
    const day = parseDecimal(value[8..10]) orelse return error.InvalidDate;
    const hour = parseDecimal(value[11..13]) orelse return error.InvalidDate;
    const minute = parseDecimal(value[14..16]) orelse return error.InvalidDate;
    const second = parseDecimal(value[17..19]) orelse return error.InvalidDate;
    var suffix = value[19..];
    if (suffix.len > 0 and suffix[0] == '.') {
        var digits: usize = 1;
        while (digits < suffix.len and std.ascii.isDigit(suffix[digits])) : (digits += 1) {}
        if (digits == 1) return error.InvalidDate;
        suffix = suffix[digits..];
    }
    if (!std.mem.eql(u8, suffix, "Z") or year < 1970 or year > 9999 or
        month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59) return error.InvalidDate;
    return daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
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

fn parseDecimal(value: []const u8) ?i64 {
    var result: i64 = 0;
    for (value) |character| {
        if (!std.ascii.isDigit(character)) return null;
        result = result * 10 + character - '0';
    }
    return result;
}

fn monthNumber(value: []const u8) ?i64 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 1..) |month, number| {
        if (std.mem.eql(u8, value, month)) return @intCast(number);
    }
    return null;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year_value: i64, month_value: i64, day: i64) i64 {
    const year = year_value - @intFromBool(month_value <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month_value + (if (month_value > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
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
    try std.testing.expectEqual(
        @as(i64, 1_369_353_600),
        try parseHttpDate("Fri, 24 May 2013 00:00:00 GMT"),
    );
    try std.testing.expectError(error.InvalidDate, parseHttpDate("Fri, 29 Feb 2013 00:00:00 GMT"));
    try std.testing.expectError(error.InvalidDate, parseHttpDate("Friday, 24 May 2013 00:00:00 GMT"));
}
