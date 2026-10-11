//! Dates and times for templates: parsing the forms dates take in
//! frontmatter and data files, and formatting them with `strftime`
//! directives as Ruby (and so Liquid and Jekyll) does.
//!
//! Times carry a fixed offset from UTC. A time written without one is
//! taken as UTC, so builds do not depend on the machine's time zone.

const std = @import("std");
const Writer = std.Io.Writer;

pub const DateTime = struct {
    year: i32,
    /// 1 to 12.
    month: u8,
    /// 1 to 31.
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    nanosecond: u32 = 0,
    /// Seconds east of UTC.
    offset: i32 = 0,

    /// The time `ts` seconds after the Unix epoch, as seen at `offset`.
    pub fn fromUnix(ts: i64, offset: i32) DateTime {
        const local = ts + offset;
        const days = @divFloor(local, 86400);
        const secs: u32 = @intCast(local - days * 86400);
        const ymd = civilFromDays(days);
        return .{
            .year = ymd.year,
            .month = ymd.month,
            .day = ymd.day,
            .hour = @intCast(secs / 3600),
            .minute = @intCast(secs / 60 % 60),
            .second = @intCast(secs % 60),
            .offset = offset,
        };
    }

    /// Seconds since the Unix epoch.
    pub fn unix(dt: DateTime) i64 {
        return dt.dayNumber() * 86400 + @as(i64, dt.hour) * 3600 + @as(i64, dt.minute) * 60 + dt.second - dt.offset;
    }

    /// Days from 1970-01-01 to the local date.
    fn dayNumber(dt: DateTime) i64 {
        return daysFromCivil(dt.year, dt.month, dt.day);
    }

    /// 0 for Sunday to 6 for Saturday.
    pub fn weekday(dt: DateTime) u8 {
        return @intCast(@mod(dt.dayNumber() + 4, 7));
    }

    /// 1 for January 1st.
    pub fn yearDay(dt: DateTime) u16 {
        return @intCast(dt.dayNumber() - daysFromCivil(dt.year, 1, 1) + 1);
    }
};

/// Days from 1970-01-01 to a proleptic Gregorian date.
fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(n: i64) struct { year: i32, month: u8, day: u8 } {
    const z = n + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

pub fn isLeap(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

// ---------------------------------------------------------------------------
// Parsing

/// Parses a date or time in one of these forms, with or without
/// surrounding space:
///
///   2024-01-05                      2024/01/05
///   2024-01-05 14:30                2024-01-05T14:30:00Z
///   2024-01-05 14:30:00 +0100       2024-01-05T14:30:00.250-05:00
///   Fri, 05 Jan 2024 14:30:00 +0000 5 January 2024
///   Jan 5, 2024                     January 5, 2024 2:30 PM
///
/// A zone is `Z`, `UTC`, `GMT`, or an offset such as `+01:00`, `+0100` or
/// `+01`; without one the time is UTC.
pub fn parse(text: []const u8) ?DateTime {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    inline for (.{ parseNumeric, parseNamed }) |f| {
        var s: Scanner = .{ .s = t };
        if (f(&s)) |dt| {
            s.skipSpace();
            if (s.done()) return dt;
        }
    }
    return null;
}

const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn done(sc: *Scanner) bool {
        return sc.i >= sc.s.len;
    }

    fn peek(sc: *Scanner) u8 {
        return if (sc.i < sc.s.len) sc.s[sc.i] else 0;
    }

    fn eat(sc: *Scanner, c: u8) bool {
        if (sc.peek() != c) return false;
        sc.i += 1;
        return true;
    }

    fn skipSpace(sc: *Scanner) void {
        while (sc.peek() == ' ' or sc.peek() == '\t') sc.i += 1;
    }

    /// Between `min` and `max` digits.
    fn number(sc: *Scanner, min: usize, max: usize) ?u32 {
        const start = sc.i;
        var n: u32 = 0;
        while (sc.i < sc.s.len and sc.i - start < max and std.ascii.isDigit(sc.s[sc.i])) : (sc.i += 1) {
            n = n * 10 + (sc.s[sc.i] - '0');
        }
        if (sc.i - start < min) {
            sc.i = start;
            return null;
        }
        return n;
    }

    fn word(sc: *Scanner) []const u8 {
        const start = sc.i;
        while (sc.i < sc.s.len and std.ascii.isAlphabetic(sc.s[sc.i])) sc.i += 1;
        return sc.s[start..sc.i];
    }
};

fn parseNumeric(s: *Scanner) ?DateTime {
    const year = s.number(4, 4) orelse return null;
    const sep = s.peek();
    if (sep != '-' and sep != '/') return null;
    s.i += 1;
    const month = s.number(1, 2) orelse return null;
    if (!s.eat(sep)) return null;
    const day = s.number(1, 2) orelse return null;
    var dt = (makeDate(@intCast(year), month, day)) orelse return null;
    if (s.done()) return dt;
    if (!(s.eat('T') or s.eat('t'))) {
        s.skipSpace();
        if (s.done()) return dt;
    }
    if (!parseTime(s, &dt)) return null;
    return dt;
}

fn parseNamed(s: *Scanner) ?DateTime {
    // An optional weekday: `Fri,` or `Friday`.
    const first = s.word();
    var month_word = first;
    if (weekdayIndex(first) != null) {
        _ = s.eat(',');
        s.skipSpace();
        month_word = s.word();
    }
    var dt: DateTime = undefined;
    if (month_word.len == 0) {
        // `05 Jan 2024`
        const day = s.number(1, 2) orelse return null;
        s.skipSpace();
        const m = monthIndex(s.word()) orelse return null;
        s.skipSpace();
        const year = s.number(4, 4) orelse return null;
        dt = makeDate(@intCast(year), m, day) orelse return null;
    } else {
        // `Jan 5, 2024`
        const m = monthIndex(month_word) orelse return null;
        s.skipSpace();
        const day = s.number(1, 2) orelse return null;
        _ = s.eat(',');
        s.skipSpace();
        const year = s.number(4, 4) orelse return null;
        dt = makeDate(@intCast(year), m, day) orelse return null;
    }
    s.skipSpace();
    if (s.done()) return dt;
    if (!parseTime(s, &dt)) return null;
    return dt;
}

fn makeDate(year: i32, month: u32, day: u32) ?DateTime {
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, @intCast(month))) return null;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

/// `HH:MM[:SS[.fraction]] [AM|PM] [zone]`
fn parseTime(s: *Scanner, dt: *DateTime) bool {
    var hour = s.number(1, 2) orelse return false;
    if (!s.eat(':')) return false;
    const minute = s.number(2, 2) orelse return false;
    var second: u32 = 0;
    if (s.eat(':')) second = s.number(2, 2) orelse return false;
    if (s.eat('.') or s.eat(',')) {
        const start = s.i;
        var nanos: u32 = 0;
        var digits: usize = 0;
        while (std.ascii.isDigit(s.peek())) : (s.i += 1) {
            if (digits < 9) {
                nanos = nanos * 10 + (s.peek() - '0');
                digits += 1;
            }
        }
        if (s.i == start) return false;
        while (digits < 9) : (digits += 1) nanos *= 10;
        dt.nanosecond = nanos;
    }
    s.skipSpace();
    const save = s.i;
    const meridian = s.word();
    if (std.ascii.eqlIgnoreCase(meridian, "am") or std.ascii.eqlIgnoreCase(meridian, "pm")) {
        if (hour < 1 or hour > 12) return false;
        hour %= 12;
        if (std.ascii.eqlIgnoreCase(meridian, "pm")) hour += 12;
        s.skipSpace();
    } else s.i = save;
    if (hour > 23 or minute > 59 or second > 60) return false;
    dt.hour = @intCast(hour);
    dt.minute = @intCast(minute);
    dt.second = @intCast(@min(second, 59));
    if (s.done()) return true;
    dt.offset = parseZone(s) orelse return false;
    return true;
}

fn parseZone(s: *Scanner) ?i32 {
    const c = s.peek();
    if (c == 'Z' or c == 'z') {
        s.i += 1;
        return 0;
    }
    if (c == '+' or c == '-') {
        s.i += 1;
        const h = s.number(2, 2) orelse return null;
        var m: u32 = 0;
        if (s.eat(':')) {
            m = s.number(2, 2) orelse return null;
        } else if (std.ascii.isDigit(s.peek())) {
            m = s.number(2, 2) orelse return null;
        }
        if (h > 23 or m > 59) return null;
        const off: i32 = @intCast(h * 3600 + m * 60);
        return if (c == '-') -off else off;
    }
    const w = s.word();
    if (std.ascii.eqlIgnoreCase(w, "UTC") or std.ascii.eqlIgnoreCase(w, "GMT")) return 0;
    return null;
}

fn monthIndex(w: []const u8) ?u8 {
    if (w.len < 3) return null;
    for (month_names, 1..) |name, i| {
        if (std.ascii.eqlIgnoreCase(w, name) or std.ascii.eqlIgnoreCase(w, name[0..3]) or
            (w.len == 4 and std.ascii.eqlIgnoreCase(w, "sept") and i == 9))
        {
            return @intCast(i);
        }
    }
    return null;
}

fn weekdayIndex(w: []const u8) ?u8 {
    if (w.len < 3) return null;
    for (day_names, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(w, name) or std.ascii.eqlIgnoreCase(w, name[0..3])) return @intCast(i);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Formatting

pub const Style = enum {
    /// Ruby's `strftime`, which Liquid uses: `%e` pads with a space, and an
    /// unknown directive is written as it is.
    ruby,
    /// Mortise's: `%e` is not padded, and an unknown directive is an error.
    mortise,
};

pub const FormatError = Writer.Error || error{UnknownDirective};

/// Writes `dt` formatted by `fmt`, a `strftime` format. On
/// `error.UnknownDirective` (only with `.mortise`), `unknown` holds the
/// directive's letter.
pub fn format(w: *Writer, dt: DateTime, fmt: []const u8, style: Style, unknown: *u8) FormatError!void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            try w.writeByte(fmt[i]);
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        var spec: Spec = .{};
        while (i < fmt.len) : (i += 1) switch (fmt[i]) {
            '-' => spec.pad = .none,
            '_' => spec.pad = .space,
            '0' => spec.pad = .zero,
            '^' => spec.upper = true,
            '#' => spec.swap = true,
            else => break,
        };
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            spec.width = (spec.width orelse 0) *| 10 +| (fmt[i] - '0');
        }
        while (i < fmt.len and fmt[i] == ':') : (i += 1) spec.colons += 1;
        if (i >= fmt.len) {
            try w.writeAll(fmt[start..]);
            break;
        }
        const conv = fmt[i];
        i += 1;
        if (!try directive(w, dt, conv, spec, style)) {
            if (style == .mortise) {
                unknown.* = conv;
                return error.UnknownDirective;
            }
            try w.writeAll(fmt[start..i]);
        }
    }
}

const Spec = struct {
    pad: ?enum { none, space, zero } = null,
    upper: bool = false,
    swap: bool = false,
    width: ?usize = null,
    colons: u8 = 0,
};

/// Writes one directive; false when `conv` is not one.
fn directive(w: *Writer, dt: DateTime, conv: u8, spec: Spec, style: Style) FormatError!bool {
    const hour12: u8 = if (dt.hour % 12 == 0) 12 else dt.hour % 12;
    switch (conv) {
        'Y' => try num(w, dt.year, 4, '0', spec),
        'C' => try num(w, @divFloor(dt.year, 100), 2, '0', spec),
        'y' => try num(w, @mod(dt.year, 100), 2, '0', spec),
        'm' => try num(w, dt.month, 2, '0', spec),
        'd' => try num(w, dt.day, 2, '0', spec),
        'e' => try num(w, dt.day, if (style == .ruby) 2 else 1, ' ', spec),
        'j' => try num(w, dt.yearDay(), 3, '0', spec),
        'H' => try num(w, dt.hour, 2, '0', spec),
        'k' => try num(w, dt.hour, 2, ' ', spec),
        'I' => try num(w, hour12, 2, '0', spec),
        'l' => try num(w, hour12, 2, ' ', spec),
        'M' => try num(w, dt.minute, 2, '0', spec),
        'S' => try num(w, dt.second, 2, '0', spec),
        'L', 'N' => {
            // Fractional seconds: milliseconds for %L, else as many digits
            // as the width asks for (9 by default).
            const digits = @min(spec.width orelse @as(usize, if (conv == 'L') 3 else 9), 9);
            var buf: [9]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{dt.nanosecond}) catch unreachable;
            try w.writeAll(buf[0..digits]);
        },
        'u' => try num(w, if (dt.weekday() == 0) 7 else dt.weekday(), 1, '0', spec),
        'w' => try num(w, dt.weekday(), 1, '0', spec),
        'U' => try num(w, (dt.yearDay() - 1 + 7 - @as(u16, dt.weekday())) / 7, 2, '0', spec),
        'W' => try num(w, (dt.yearDay() - 1 + 7 - @as(u16, (dt.weekday() + 6) % 7)) / 7, 2, '0', spec),
        'G' => try num(w, isoWeek(dt).year, 4, '0', spec),
        'g' => try num(w, @mod(isoWeek(dt).year, 100), 2, '0', spec),
        'V' => try num(w, isoWeek(dt).week, 2, '0', spec),
        's' => try num(w, dt.unix(), 1, '0', spec),
        'B' => try str(w, month_names[dt.month - 1], spec),
        'b', 'h' => try str(w, month_names[dt.month - 1][0..3], spec),
        'A' => try str(w, day_names[dt.weekday()], spec),
        'a' => try str(w, day_names[dt.weekday()][0..3], spec),
        'p', 'P' => {
            const pm = dt.hour >= 12;
            var s: Spec = spec;
            const lower = conv == 'P' or spec.swap;
            s.swap = false;
            try str(w, if (lower) (if (pm) "pm" else "am") else if (pm) "PM" else "AM", s);
        },
        'z' => {
            const off = dt.offset;
            const a: u32 = @abs(off);
            try w.writeByte(if (off < 0) '-' else '+');
            switch (spec.colons) {
                0 => try w.print("{d:0>2}{d:0>2}", .{ a / 3600, a / 60 % 60 }),
                1 => try w.print("{d:0>2}:{d:0>2}", .{ a / 3600, a / 60 % 60 }),
                else => try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ a / 3600, a / 60 % 60, a % 60 }),
            }
        },
        'Z' => try str(w, if (dt.offset == 0) "UTC" else "", spec),
        'n' => try w.writeByte('\n'),
        't' => try w.writeByte('\t'),
        '%' => try w.writeByte('%'),
        'c' => try composite(w, dt, "%a %b %e %H:%M:%S %Y", spec, style),
        'D', 'x' => try composite(w, dt, "%m/%d/%y", spec, style),
        'F' => try composite(w, dt, "%Y-%m-%d", spec, style),
        'T', 'X' => try composite(w, dt, "%H:%M:%S", spec, style),
        'R' => try composite(w, dt, "%H:%M", spec, style),
        'r' => try composite(w, dt, "%I:%M:%S %p", spec, style),
        'v' => try composite(w, dt, "%e-%^b-%4Y", spec, style),
        '+' => try composite(w, dt, "%a %b %e %H:%M:%S %Z %Y", spec, style),
        else => return false,
    }
    return true;
}

fn num(w: *Writer, n: i64, default_width: usize, default_pad: u8, spec: Spec) Writer.Error!void {
    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}) catch unreachable;
    const pad: u8 = if (spec.pad) |p| switch (p) {
        .none => 0,
        .space => ' ',
        .zero => '0',
    } else default_pad;
    const width = if (spec.pad == .none) 0 else spec.width orelse default_width;
    const len = digits.len + @intFromBool(n < 0);
    if (n < 0 and pad == '0') try w.writeByte('-');
    if (width > len) try w.splatByteAll(pad, width - len);
    if (n < 0 and pad != '0') try w.writeByte('-');
    try w.writeAll(digits);
}

fn str(w: *Writer, s: []const u8, spec: Spec) Writer.Error!void {
    const width = spec.width orelse 0;
    if (width > s.len) try w.splatByteAll(if (spec.pad == .zero) '0' else ' ', width - s.len);
    if (spec.upper or spec.swap) {
        for (s) |c| try w.writeByte(std.ascii.toUpper(c));
    } else try w.writeAll(s);
}

fn composite(w: *Writer, dt: DateTime, fmt: []const u8, spec: Spec, style: Style) FormatError!void {
    var buf: [128]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    var unknown: u8 = 0;
    format(&fw, dt, fmt, style, &unknown) catch unreachable;
    try str(w, fw.buffered(), .{ .width = spec.width, .upper = spec.upper, .pad = spec.pad });
}

/// The ISO 8601 week-numbering year and week of `dt`.
fn isoWeek(dt: DateTime) struct { year: i32, week: u8 } {
    const wday: i32 = (dt.weekday() + 6) % 7; // Monday = 0
    const yday: i32 = dt.yearDay();
    // The week's Thursday decides its year.
    const week = @divFloor(yday - wday + 9, 7);
    if (week < 1) {
        const prev: DateTime = .{ .year = dt.year - 1, .month = 12, .day = 31 };
        return isoWeek(prev);
    }
    const year_len: i32 = if (isLeap(dt.year)) 366 else 365;
    if (week == 53 and yday - wday + 3 > year_len) return .{ .year = dt.year + 1, .week = 1 };
    return .{ .year = dt.year, .week = @intCast(week) };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFormat(expected: []const u8, dt: DateTime, fmt: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var unknown: u8 = 0;
    try format(&w, dt, fmt, .ruby, &unknown);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "unix round trip and weekdays" {
    const dt = parse("2008-11-07 13:07:54 -0800").?;
    try testing.expectEqual(@as(i64, 1226092074), dt.unix());
    try testing.expectEqual(@as(u8, 5), dt.weekday());
    const back = DateTime.fromUnix(1226092074, -8 * 3600);
    try testing.expectEqual(dt, back);
    try testing.expectEqual(DateTime{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 }, DateTime.fromUnix(-1, 0));
    try testing.expectEqual(@as(u16, 366), (DateTime{ .year = 2024, .month = 12, .day = 31 }).yearDay());
}

test "parse accepts common date forms" {
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5 }, parse(" 2024-01-05 ").?);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5 }, parse("2024/1/5").?);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5, .hour = 14, .minute = 30 }, parse("2024-01-05 14:30").?);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5, .hour = 14, .minute = 30, .second = 1, .nanosecond = 250_000_000, .offset = -5 * 3600 }, parse("2024-01-05T14:30:01.25-05:00").?);
    try testing.expectEqual(@as(i32, 3600), parse("2024-01-05 14:30:00 +0100").?.offset);
    try testing.expectEqual(@as(i32, 0), parse("2024-01-05T14:30:00Z").?.offset);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5, .hour = 14, .minute = 30 }, parse("Fri, 05 Jan 2024 14:30:00 GMT").?);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5 }, parse("5 January 2024").?);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5 }, parse("Jan 5, 2024").?);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 5, .hour = 14, .minute = 30 }, parse("January 5, 2024 2:30 PM").?);
    try testing.expect(parse("2023-02-29") == null);
    try testing.expect(parse("2024-01-05 25:00") == null);
    try testing.expect(parse("2024-01-05x") == null);
    try testing.expect(parse("Smarch 5, 2024") == null);
    try testing.expect(parse("") == null);
}

test "strftime directives" {
    const dt = parse("2008-11-07 13:07:54.123456 -0800").?;
    try expectFormat("2008-11-07 13:07:54", dt, "%Y-%m-%d %H:%M:%S");
    try expectFormat("Fri, 07 Nov 2008 13:07:54 -0800", dt, "%a, %d %b %Y %H:%M:%S %z");
    try expectFormat("2008-11-07T13:07:54-08:00", dt, "%Y-%m-%dT%H:%M:%S%:z");
    try expectFormat("Friday November  7 7 01 PM pm", dt, "%A %B %e %-d %I %p %P");
    try expectFormat("FRIDAY NOV  1:07 PM", dt, "%^A %^b %l:%M %p");
    try expectFormat("312 5 5 44 44 2008 08 45", dt, "%j %u %w %U %W %G %g %V");
    try expectFormat("123 123456 08 20", dt, "%L %6N %y %C");
    try expectFormat("11/07/08 13:07:54 2008-11-07 13:07 01:07:54 PM", dt, "%D %T %F %R %r");
    try expectFormat("Fri Nov  7 13:07:54 2008", dt, "%c");
    try expectFormat(" 7-NOV-2008", dt, "%v");
    try expectFormat("1226092074 % %Q", dt, "%s %% %Q");
    try expectFormat("00011 0011 11", dt, "%5m %04m %_m");
}

test "ISO weeks at year boundaries" {
    try expectFormat("2020-W53", parse("2021-01-03").?, "%G-W%V");
    try expectFormat("2021-W01", parse("2021-01-04").?, "%G-W%V");
    try expectFormat("2025-W01", parse("2024-12-30").?, "%G-W%V");
}

test "mortise style rejects unknown directives" {
    var buf: [32]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var unknown: u8 = 0;
    try format(&w, parse("2024-01-05").?, "%e", .mortise, &unknown);
    try testing.expectEqualStrings("5", w.buffered());
    try testing.expectError(error.UnknownDirective, format(&w, parse("2024-01-05").?, "%Q", .mortise, &unknown));
    try testing.expectEqual(@as(u8, 'Q'), unknown);
}
