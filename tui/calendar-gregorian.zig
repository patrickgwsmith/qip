//! Inputless TUI calendar. Up and Down move between Gregorian months.

const std = @import("std");

const OUTPUT_CAP: usize = 1024;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_UP: i32 = 0xff52;
const XK_DOWN: i32 = 0xff54;

const Phase = enum { initializing, ready, updating };

const YearMonth = struct {
    year: u16 = 2024,
    month: u8 = 1,
};

const month_names = [_][]const u8{
    "January",   "February", "March",    "April",
    "May",       "June",     "July",     "August",
    "September", "October",  "November", "December",
};

var output_buf: [OUTPUT_CAP]u8 = undefined;
var displayed: YearMonth = .{};
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

const Writer = struct {
    buf: []u8,
    index: usize = 0,

    fn writeByte(self: *Writer, byte: u8) void {
        if (self.index >= self.buf.len) @trap();
        self.buf[self.index] = byte;
        self.index += 1;
    }

    fn write(self: *Writer, bytes: []const u8) void {
        if (bytes.len > self.buf.len - self.index) @trap();
        @memcpy(self.buf[self.index..][0..bytes.len], bytes);
        self.index += bytes.len;
    }
};

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    return switch (x11_key) {
        XK_UP => if (previousMonth()) 1 else 0,
        XK_DOWN => if (nextMonth()) 1 else 0,
        else => 0,
    };
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return committed_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();

    const written = renderCalendar(displayed.year, displayed.month, &output_buf);
    phase = .ready;
    return @intCast(written);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn previousMonth() bool {
    if (displayed.month > 1) {
        displayed.month -= 1;
        return true;
    }
    if (displayed.year == 1) return false;
    displayed.year -= 1;
    displayed.month = 12;
    return true;
}

fn nextMonth() bool {
    if (displayed.month < 12) {
        displayed.month += 1;
        return true;
    }
    if (displayed.year == 9999) return false;
    displayed.year += 1;
    displayed.month = 1;
    return true;
}

fn isLeapYear(year: u16) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => @trap(),
    };
}

// Returns 0 for Sunday through 6 for Saturday.
fn dayOfWeekGregorian(year: u16, month: u8, day: u8) u8 {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i32 = year;
    const m: i32 = month;
    if (m < 3) y -= 1;
    const value = y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + offsets[@intCast(m - 1)] + day;
    return @intCast(@mod(value, 7));
}

fn mondayFirstOffset(sunday_first: u8) u8 {
    return @intCast((@as(u16, sunday_first) + 6) % 7);
}

fn writeYear(writer: *Writer, year: u16) void {
    writer.writeByte(@intCast('0' + year / 1000));
    writer.writeByte(@intCast('0' + (year / 100) % 10));
    writer.writeByte(@intCast('0' + (year / 10) % 10));
    writer.writeByte(@intCast('0' + year % 10));
}

fn writeTitle(writer: *Writer, year: u16, month: u8) void {
    const name = month_names[month - 1];
    const title_width = name.len + 5;
    const table_width: usize = 36;
    var padding = (table_width - title_width) / 2;
    while (padding > 0) : (padding -= 1) writer.writeByte(' ');
    writer.write(name);
    writer.writeByte(' ');
    writeYear(writer, year);
    writer.write("\n\n");
}

fn writeHorizontalRule(writer: *Writer) void {
    writer.write("+----+----+----+----+----+----+----+\n");
}

fn writeDayCell(writer: *Writer, day: ?u8) void {
    writer.write("| ");
    if (day) |value| {
        if (value < 10) {
            writer.writeByte(' ');
            writer.writeByte('0' + value);
        } else {
            writer.writeByte('0' + value / 10);
            writer.writeByte('0' + value % 10);
        }
    } else {
        writer.write("  ");
    }
    writer.writeByte(' ');
}

fn renderCalendar(year: u16, month: u8, output: []u8) usize {
    var writer = Writer{ .buf = output };
    writeTitle(&writer, year, month);
    writer.write("Up: previous month    Down: next month\n\n");
    writeHorizontalRule(&writer);
    writer.write("| Mo | Tu | We | Th | Fr | Sa | Su |\n");
    writeHorizontalRule(&writer);

    const offset = mondayFirstOffset(dayOfWeekGregorian(year, month, 1));
    const days = daysInMonth(year, month);
    const weeks: u16 = @divFloor(@as(u16, offset) + days + 6, 7);

    var week: u16 = 0;
    while (week < weeks) : (week += 1) {
        var column: u8 = 0;
        while (column < 7) : (column += 1) {
            const cell: u16 = week * 7 + column;
            if (cell < offset or cell >= @as(u16, offset) + days) {
                writeDayCell(&writer, null);
            } else {
                writeDayCell(&writer, @intCast(cell - offset + 1));
            }
        }
        writer.write("|\n");
        writeHorizontalRule(&writer);
    }
    return writer.index;
}

fn resetForTest(year: u16, month: u8) void {
    displayed = .{ .year = year, .month = month };
    phase = .ready;
    begun_at_ms = 0;
    committed_at_ms = 0;
}

test "renders an inputless January calendar" {
    resetForTest(2024, 1);
    const size = renderImpl(0);
    const text = output_buf[0..size];
    try std.testing.expect(std.mem.indexOf(u8, text, "January 2024") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "|  1 |  2 |  3 |  4 |  5 |  6 |  7 |") != null);
}

test "up and down navigate across year boundaries" {
    resetForTest(2024, 1);

    begin_update_at(1);
    try std.testing.expectEqual(@as(i32, 1), key_event(XK_UP, FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), key_event(XK_UP, 0));
    try std.testing.expectEqual(@as(i64, 1), finish_update());
    try std.testing.expectEqual(YearMonth{ .year = 2023, .month = 12 }, displayed);

    begin_update_at(2);
    try std.testing.expectEqual(@as(i32, 1), key_event(XK_DOWN, FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i64, 2), finish_update());
    try std.testing.expectEqual(YearMonth{ .year = 2024, .month = 1 }, displayed);
}

test "navigation stops at supported year limits" {
    resetForTest(1, 1);
    begin_update_at(1);
    try std.testing.expectEqual(@as(i32, 0), key_event(XK_UP, FLAG_KEY_DOWN));
    _ = finish_update();

    resetForTest(9999, 12);
    begin_update_at(1);
    try std.testing.expectEqual(@as(i32, 0), key_event(XK_DOWN, FLAG_KEY_DOWN));
    _ = finish_update();
}
