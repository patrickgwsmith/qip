//! UTC-to-local time conversion using a pinned IANA transition table.
const std = @import("std");
const data = @import("lib/time-zone-data.zig");

const OUTPUT_CAP: usize = 16 * 1024;
const FILTER_CAP: usize = 48;
const EDIT_CAP: usize = 16;
const MIN_UTC: i64 = 1577836800; // 2020-01-01 00:00 UTC.
const END_UTC: i64 = 2145916800; // 2038-01-01 00:00 UTC, exclusive.
const DEFAULT_UTC: i64 = 1790251200; // 2026-09-24 12:00 UTC.
const KEY_DOWN: i32 = 1;
const MODIFIER_MASK: i32 = 8 | 16 | 32;
const XK_TAB: i32 = 0xff09;
const XK_BACKSPACE: i32 = 0xff08;
const XK_ENTER: i32 = 0xff0d;
const XK_ESCAPE: i32 = 0xff1b;
const XK_HOME: i32 = 0xff50;
const XK_LEFT: i32 = 0xff51;
const XK_UP: i32 = 0xff52;
const XK_RIGHT: i32 = 0xff53;
const XK_DOWN: i32 = 0xff54;
const XK_PAGE_UP: i32 = 0xff55;
const XK_PAGE_DOWN: i32 = 0xff56;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var columns: usize = 80;
var lines: usize = 24;
var utc_seconds: i64 = DEFAULT_UTC;
var filter: [FILTER_CAP]u8 = undefined;
var filter_len: usize = 0;
var page: usize = 0;
var editing: bool = false;
var edit: [EDIT_CAP]u8 = undefined;
var edit_len: usize = 0;
var invalid_edit: bool = false;
var output: [OUTPUT_CAP]u8 = undefined;

const Writer = struct {
    index: usize = 0,
    column: usize = 0,
    line: usize = 0,
    width: usize,
    height: usize,

    fn byte(self: *Writer, value: u8) void {
        if (self.index >= OUTPUT_CAP) @trap();
        output[self.index] = value;
        self.index += 1;
    }

    fn text(self: *Writer, value: []const u8) void {
        if (self.line >= self.height) return;
        for (value) |part| {
            if (self.column >= self.width) break;
            self.byte(part);
            self.column += 1;
        }
    }

    fn padTo(self: *Writer, target: usize) void {
        if (self.line >= self.height) return;
        while (self.column < @min(target, self.width)) {
            self.byte(' ');
            self.column += 1;
        }
    }

    fn digit(self: *Writer, value: u8) void {
        self.byte('0' + value);
        self.column += 1;
    }

    fn two(self: *Writer, value: u8) void {
        if (self.line >= self.height or self.column + 2 > self.width) return;
        self.digit(value / 10);
        self.digit(value % 10);
    }

    fn four(self: *Writer, value: u16) void {
        if (self.line >= self.height or self.column + 4 > self.width) return;
        self.digit(@intCast(value / 1000));
        self.digit(@intCast(value / 100 % 10));
        self.digit(@intCast(value / 10 % 10));
        self.digit(@intCast(value % 10));
    }

    fn number(self: *Writer, value: usize) void {
        var digits: [20]u8 = undefined;
        var position: usize = digits.len;
        var remaining = value;
        while (true) {
            position -= 1;
            digits[position] = @as(u8, @intCast(remaining % 10)) + '0';
            remaining /= 10;
            if (remaining == 0) break;
        }
        self.text(digits[position..]);
    }

    fn newline(self: *Writer) void {
        if (self.line >= self.height) return;
        self.byte('\n');
        self.column = 0;
        self.line += 1;
    }
};

fn leapYear(year: u16) bool {
    return year % 400 == 0 or (year % 4 == 0 and year % 100 != 0);
}

fn monthDays(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leapYear(year)) 29 else 28,
        else => 0,
    };
}

fn epochDays(year: u16, month: u8, day: u8) i64 {
    var total: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) total += if (leapYear(y)) @as(i64, 366) else 365;
    var m: u8 = 1;
    while (m < month) : (m += 1) total += monthDays(year, m);
    return total + day - 1;
}

const DateTime = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8 };

fn fromEpoch(seconds: i64) DateTime {
    var days = @divFloor(seconds, 86400);
    const rest = @mod(seconds, 86400);
    var year: u16 = 1970;
    while (true) {
        const span: i64 = if (leapYear(year)) 366 else 365;
        if (days < span) break;
        days -= span;
        year += 1;
    }
    var month: u8 = 1;
    while (true) {
        const span = monthDays(year, month);
        if (days < span) break;
        days -= span;
        month += 1;
    }
    return .{
        .year = year,
        .month = month,
        .day = @intCast(days + 1),
        .hour = @intCast(@divTrunc(rest, 3600)),
        .minute = @intCast(@mod(@divTrunc(rest, 60), 60)),
    };
}

fn writeDateTime(writer: *Writer, seconds: i64) void {
    const date = fromEpoch(seconds);
    writer.four(date.year);
    writer.text("-");
    writer.two(date.month);
    writer.text("-");
    writer.two(date.day);
    writer.text(" ");
    writer.two(date.hour);
    writer.text(":");
    writer.two(date.minute);
}

fn parseTwo(value: []const u8) ?u8 {
    if (value.len != 2 or value[0] < '0' or value[0] > '9' or value[1] < '0' or value[1] > '9') return null;
    return (value[0] - '0') * 10 + value[1] - '0';
}

fn parseEdit() ?i64 {
    if (edit_len != EDIT_CAP or edit[4] != '-' or edit[7] != '-' or edit[10] != ' ' or edit[13] != ':') return null;
    const century = parseTwo(edit[0..2]) orelse return null;
    const year_part = parseTwo(edit[2..4]) orelse return null;
    const year: u16 = @as(u16, century) * 100 + year_part;
    if (year < 2020 or year > 2037) return null;
    const month = parseTwo(edit[5..7]) orelse return null;
    const day = parseTwo(edit[8..10]) orelse return null;
    const hour = parseTwo(edit[11..13]) orelse return null;
    const minute = parseTwo(edit[14..16]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > monthDays(year, month) or hour > 23 or minute > 59) return null;
    return epochDays(year, month, day) * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
}

fn lower(value: u8) u8 {
    return if (value >= 'A' and value <= 'Z') value + 32 else value;
}

fn containsFolded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len and lower(haystack[start + i]) == lower(needle[i])) : (i += 1) {}
        if (i == needle.len) return true;
    }
    return false;
}

fn matches(zone: data.Zone) bool {
    return containsFolded(zone.name, filter[0..filter_len]) or containsFolded(zone.country, filter[0..filter_len]);
}

fn matchCount() usize {
    var count: usize = 0;
    for (data.zones) |zone| {
        if (matches(zone)) count += 1;
    }
    return count;
}

fn visibleRows() usize {
    const row_lines: usize = if (columns >= 72) 1 else 2;
    return if (lines > 6) @max(1, @min((lines - 6) / row_lines, 54)) else 1;
}

fn zoneOffset(zone: data.Zone, at: i64) i32 {
    const first: usize = zone.first;
    var low: usize = 0;
    var high: usize = zone.count;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (data.transitions[first + middle].at <= at) low = middle else high = middle;
    }
    return data.transitions[first + low].offset;
}

fn writeOffset(writer: *Writer, seconds: i32) void {
    writer.text(if (seconds >= 0) "UTC+" else "UTC-");
    const positive: u32 = @intCast(if (seconds < 0) -seconds else seconds);
    writer.two(@intCast(positive / 3600));
    writer.text(":");
    writer.two(@intCast((positive / 60) % 60));
}

fn renderRow(writer: *Writer, zone: data.Zone) void {
    const offset = zoneOffset(zone, utc_seconds);
    writer.text("  ");
    writer.text(zone.name);
    if (writer.width >= 72) {
        writer.padTo(35);
        writeDateTime(writer, utc_seconds + offset);
        writer.padTo(54);
        writeOffset(writer, offset);
    } else {
        writer.newline();
        writer.text("  ");
        writeDateTime(writer, utc_seconds + offset);
        writer.text("  ");
        writeOffset(writer, offset);
    }
    writer.newline();
}

fn renderScreen(writer: *Writer) void {
    writer.text("TIME ZONE CONVERTER  tzdb ");
    writer.text(data.version);
    writer.newline();

    if (editing) {
        writer.text("Set UTC: ");
        writer.text(edit[0..edit_len]);
        writer.text("_");
    } else {
        writer.text("UTC: ");
        writeDateTime(writer, utc_seconds);
        writer.text("  [Tab to set]");
    }
    writer.newline();

    writer.text("Find zone: ");
    writer.text(filter[0..filter_len]);
    writer.text("_");
    writer.text("  (");
    writer.number(matchCount());
    writer.text(" / ");
    writer.number(data.zones.len);
    writer.text(")");
    writer.newline();

    if (writer.width >= 72) {
        writer.text("  IANA zone");
        writer.padTo(35);
        writer.text("Local date/time");
        writer.padTo(54);
        writer.text("Offset");
    } else {
        writer.text("  IANA zone / local date-time / offset");
    }
    writer.newline();

    const count = matchCount();
    if (count == 0) {
        writer.text("  No zones match. Backspace or Esc to change the filter.");
        writer.newline();
    } else {
        const first = @min(page * visibleRows(), ((count - 1) / visibleRows()) * visibleRows());
        var index: usize = 0;
        for (data.zones) |zone| {
            if (!matches(zone)) continue;
            if (index >= first and index < first + visibleRows()) renderRow(writer, zone);
            index += 1;
        }
    }

    if (lines >= 6) {
        if (invalid_edit) {
            writer.text("Invalid UTC time. Enter YYYY-MM-DD HH:MM in 2020-2037.");
        } else if (editing) {
            writer.text("YYYY-MM-DD HH:MM  Enter: apply  Esc: cancel");
        } else {
            writer.text("Arrows: hour/day  PageUp/Down: zones  Tab: set UTC  Esc: clear");
        }
        writer.newline();
    }
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn uniform_set_columns(value: u32) u32 {
    columns = @max(1, @min(value, 160));
    return @intCast(columns);
}

export fn uniform_set_lines(value: u32) u32 {
    lines = @max(1, @min(value, 60));
    return @intCast(lines);
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

fn editKey(key: i32) i32 {
    switch (key) {
        XK_ESCAPE => {
            editing = false;
            invalid_edit = false;
            return 1;
        },
        XK_BACKSPACE => {
            if (edit_len == 0) return 0;
            edit_len -= 1;
            invalid_edit = false;
            return 1;
        },
        XK_ENTER => {
            const parsed = parseEdit() orelse {
                invalid_edit = true;
                return 1;
            };
            utc_seconds = parsed;
            editing = false;
            invalid_edit = false;
            return 1;
        },
        else => {},
    }
    if (key < 32 or key > 126 or edit_len == EDIT_CAP) return 0;
    edit[edit_len] = @intCast(key);
    edit_len += 1;
    invalid_edit = false;
    return 1;
}

fn shiftUTC(delta: i64) i32 {
    const next = utc_seconds + delta;
    if (next < MIN_UTC or next >= END_UTC) return 0;
    utc_seconds = next;
    return 1;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & KEY_DOWN) == 0 or (flags & MODIFIER_MASK) != 0) return 0;
    if (editing) return editKey(x11_key);
    switch (x11_key) {
        XK_TAB => {
            editing = true;
            edit_len = 0;
            invalid_edit = false;
            return 1;
        },
        XK_LEFT => return shiftUTC(-3600),
        XK_RIGHT => return shiftUTC(3600),
        XK_UP => return shiftUTC(86400),
        XK_DOWN => return shiftUTC(-86400),
        XK_BACKSPACE => {
            if (filter_len == 0) return 0;
            filter_len -= 1;
            page = 0;
            return 1;
        },
        XK_ESCAPE => {
            if (filter_len == 0) return 0;
            filter_len = 0;
            page = 0;
            return 1;
        },
        XK_PAGE_UP, XK_HOME => {
            if (page == 0) return 0;
            page = if (x11_key == XK_HOME) 0 else page - 1;
            return 1;
        },
        XK_PAGE_DOWN => {
            if ((page + 1) * visibleRows() >= matchCount()) return 0;
            page += 1;
            return 1;
        },
        else => {},
    }
    if (x11_key < 32 or x11_key > 126 or filter_len == FILTER_CAP) return 0;
    filter[filter_len] = @intCast(x11_key);
    filter_len += 1;
    page = 0;
    return 1;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return committed_at_ms;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    if (input_size != 0 or phase == .updating) @trap();
    var writer = Writer{ .width = columns, .height = lines };
    renderScreen(&writer);
    phase = .ready;
    return .{
        .output_size = @intCast(writer.index),
        .output_ptr = @intCast(@intFromPtr(&output)),
        .failed = 0,
    };
}
