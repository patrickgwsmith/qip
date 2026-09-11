const std = @import("std");

const INPUT_CAP: u32 = 0x10000;
const OUTPUT_CAP: u32 = 0x20000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

const Writer = struct {
    buf: []u8,
    idx: usize,
    overflow: bool,

    fn init(buf: []u8) Writer {
        return .{ .buf = buf, .idx = 0, .overflow = false };
    }

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.idx >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow) return;
        if (self.idx + s.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const YearMonth = struct {
    year: u32,
    month: u8,
};

fn parseYearMonth(raw: []const u8) ?YearMonth {
    const input = std.mem.trim(u8, raw, " \t\r\n");
    if (input.len != 7) return null;
    if (input[4] != '-') return null;

    var year: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const c = input[i];
        if (!isDigit(c)) return null;
        year = year * 10 + @as(u32, c - '0');
    }
    if (year == 0) return null;

    if (!isDigit(input[5]) or !isDigit(input[6])) return null;
    const month: u8 = (input[5] - '0') * 10 + (input[6] - '0');
    if (month < 1 or month > 12) return null;

    return .{ .year = year, .month = month };
}

fn isLeapYear(year: u32) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
}

fn daysInMonth(year: u32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

// Returns weekday where 0 = Sunday, 1 = Monday, ... 6 = Saturday.
fn dayOfWeekGregorian(year: u32, month: u8, day: u8) u8 {
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i32 = @as(i32, @intCast(year));
    const m: i32 = @as(i32, @intCast(month));
    if (m < 3) y -= 1;
    const d: i32 = @as(i32, @intCast(day));
    const value = y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[@as(usize, @intCast(m - 1))] + d;
    return @as(u8, @intCast(@mod(value, 7)));
}

// Converts Sunday-first weekday index to Monday-first column index.
fn mondayFirstOffset(sundayFirstWeekday: u8) u8 {
    return @as(u8, @intCast((@as(u16, sundayFirstWeekday) + 6) % 7));
}

fn writeHorizontalRule(w: *Writer) void {
    w.writeSlice("+----+----+----+----+----+----+----+\n");
}

fn writeHeaderRow(w: *Writer) void {
    w.writeSlice("| Mo | Tu | We | Th | Fr | Sa | Su |\n");
}

fn writeDayCell(w: *Writer, day: ?u8) void {
    w.writeSlice("| ");
    if (day) |d| {
        if (d < 10) {
            w.writeByte(' ');
            w.writeByte('0' + d);
        } else {
            w.writeByte('0' + d / 10);
            w.writeByte('0' + d % 10);
        }
    } else {
        w.writeSlice("  ");
    }
    w.writeByte(' ');
}

fn renderCalendar(year: u32, month: u8, out: []u8) usize {
    var w = Writer.init(out);
    const first_weekday = dayOfWeekGregorian(year, month, 1);
    const offset = mondayFirstOffset(first_weekday);
    const days = daysInMonth(year, month);

    const cell_count: u16 = @as(u16, offset) + @as(u16, days);
    const weeks: u16 = @divFloor(cell_count + 6, 7);

    writeHorizontalRule(&w);
    writeHeaderRow(&w);
    writeHorizontalRule(&w);

    var week: u16 = 0;
    while (week < weeks and !w.overflow) : (week += 1) {
        var col: u8 = 0;
        while (col < 7 and !w.overflow) : (col += 1) {
            const idx: u16 = week * 7 + col;
            if (idx < offset or idx >= offset + days) {
                writeDayCell(&w, null);
            } else {
                const day: u8 = @as(u8, @intCast(idx - offset + 1));
                writeDayCell(&w, day);
            }
        }
        w.writeSlice("|\n");
        writeHorizontalRule(&w);
    }

    if (w.overflow) return 0;
    return w.idx;
}

fn renderImpl(input_size: u32) u32 {
    const size = @min(@as(usize, @intCast(input_size)), @as(usize, INPUT_CAP));
    const ym = parseYearMonth(input_buf[0..size]) orelse return 0;
    const written = renderCalendar(ym.year, ym.month, output_buf[0..]);
    if (written == 0) return 0;
    return @as(u32, @intCast(written));
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

test "renders January 2024 Monday-first table" {
    var out: [2048]u8 = undefined;
    const parsed = parseYearMonth("2024-01") orelse return error.InvalidInput;
    const written = renderCalendar(parsed.year, parsed.month, out[0..]);
    try std.testing.expectEqualStrings(
        \\+----+----+----+----+----+----+----+
        \\| Mo | Tu | We | Th | Fr | Sa | Su |
        \\+----+----+----+----+----+----+----+
        \\|  1 |  2 |  3 |  4 |  5 |  6 |  7 |
        \\+----+----+----+----+----+----+----+
        \\|  8 |  9 | 10 | 11 | 12 | 13 | 14 |
        \\+----+----+----+----+----+----+----+
        \\| 15 | 16 | 17 | 18 | 19 | 20 | 21 |
        \\+----+----+----+----+----+----+----+
        \\| 22 | 23 | 24 | 25 | 26 | 27 | 28 |
        \\+----+----+----+----+----+----+----+
        \\| 29 | 30 | 31 |    |    |    |    |
        \\+----+----+----+----+----+----+----+
        \\
    ,
        out[0..written],
    );
}

test "renders leap year February and starts on Thursday column" {
    var out: [2048]u8 = undefined;
    const parsed = parseYearMonth("2024-02\n") orelse return error.InvalidInput;
    const written = renderCalendar(parsed.year, parsed.month, out[0..]);
    const text = out[0..written];

    try std.testing.expect(std.mem.indexOf(u8, text, "|    |    |    |  1 |  2 |  3 |  4 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| 26 | 27 | 28 | 29 |    |    |    |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| 30 |") == null);
}

test "rejects invalid yyyy-mm input" {
    try std.testing.expect(parseYearMonth("2024-13") == null);
    try std.testing.expect(parseYearMonth("2024-00") == null);
    try std.testing.expect(parseYearMonth("24-01") == null);
    try std.testing.expect(parseYearMonth("0000-01") == null);
}
