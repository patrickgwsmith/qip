//! Search IANA delegated top-level domains by label, type, and manager.
const std = @import("std");
const data = @import("lib/tld-data.zig");

const OUTPUT_CAP: usize = 16 * 1024;
const QUERY_CAP: usize = 48;
const KEY_DOWN: i32 = 1;
const MODIFIER_MASK: i32 = 8 | 16 | 32; // Control, Alt, Meta.
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
const XK_END: i32 = 0xff57;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var columns: usize = 80;
var lines: usize = 24;
var query: [QUERY_CAP]u8 = undefined;
var query_len: usize = 0;
var selected: usize = 0;
var details: bool = false;
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
        var i: usize = 0;
        while (i < value.len and self.column < self.width) {
            const count: usize = std.unicode.utf8ByteSequenceLength(value[i]) catch @trap();
            if (i + count > value.len) @trap();
            for (value[i..][0..count]) |part| self.byte(part);
            self.column += 1;
            i += count;
        }
    }

    fn padTo(self: *Writer, target: usize) void {
        if (self.line >= self.height) return;
        while (self.column < @min(target, self.width)) {
            self.byte(' ');
            self.column += 1;
        }
    }

    fn number(self: *Writer, value: usize) void {
        var digits: [20]u8 = undefined;
        var position: usize = digits.len;
        var number_value = value;
        while (true) {
            position -= 1;
            digits[position] = @as(u8, @intCast(number_value % 10)) + '0';
            number_value /= 10;
            if (number_value == 0) break;
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

fn matches(tld: data.Tld) bool {
    const term = query[0..query_len];
    return containsFolded(tld.ascii, term) or
        containsFolded(tld.display, term) or
        containsFolded(tld.kind, term) or
        containsFolded(tld.manager, term);
}

fn matchCount() usize {
    var count: usize = 0;
    for (data.tlds) |tld| {
        if (matches(tld)) count += 1;
    }
    return count;
}

fn selectedTld() ?data.Tld {
    var index: usize = 0;
    for (data.tlds) |tld| {
        if (!matches(tld)) continue;
        if (index == selected) return tld;
        index += 1;
    }
    return null;
}

fn visibleRows() usize {
    return if (lines > 5) @min(lines - 5, 55) else 1;
}

fn listRow(writer: *Writer, tld: data.Tld, active: bool) void {
    writer.text(if (active) "> " else "  ");
    writer.text(tld.ascii);
    writer.padTo(27);
    if (writer.width >= 70) {
        writer.text(tld.kind);
        writer.padTo(48);
        writer.text(tld.manager);
    } else {
        writer.text(tld.kind);
    }
    writer.newline();
}

fn renderList(writer: *Writer) void {
    const count = matchCount();
    writer.text("TLD FINDER  ");
    writer.number(count);
    writer.text(" / ");
    writer.number(data.tlds.len);
    writer.newline();

    writer.text("Find: ");
    writer.text(query[0..query_len]);
    writer.text("_");
    writer.newline();

    if (writer.width >= 70) {
        writer.text("  Domain");
        writer.padTo(27);
        writer.text("Type");
        writer.padTo(48);
        writer.text("Manager");
    } else {
        writer.text("  Domain");
        writer.padTo(27);
        writer.text("Type");
    }
    writer.newline();

    if (count == 0) {
        writer.text("  No matches. Backspace or Esc to change the filter.");
        writer.newline();
    } else {
        const visible = visibleRows();
        const first = (selected / visible) * visible;
        var match_index: usize = 0;
        for (data.tlds) |tld| {
            if (!matches(tld)) continue;
            if (match_index >= first and match_index < first + visible) {
                listRow(writer, tld, match_index == selected);
            }
            match_index += 1;
        }
    }

    if (lines >= 5) {
        writer.text("Type to filter  Up/Down select  Enter details  Esc clear");
        writer.newline();
    }
}

fn detailLine(writer: *Writer, label: []const u8, value: []const u8) void {
    writer.text(label);
    writer.padTo(18);
    writer.text(if (value.len == 0) "-" else value);
    writer.newline();
}

fn renderDetails(writer: *Writer) void {
    const tld = selectedTld() orelse return renderList(writer);
    writer.text("TLD DETAILS  Enter or Esc: back");
    writer.newline();
    writer.text(tld.display);
    writer.newline();
    detailLine(writer, "ASCII / IDNA", tld.ascii);
    detailLine(writer, "Type", tld.kind);
    detailLine(writer, "Manager", tld.manager);
    detailLine(writer, "IANA snapshot", data.snapshot);
    writer.text("Delegated does not imply open registration.");
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

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & KEY_DOWN) == 0 or (flags & MODIFIER_MASK) != 0) return 0;
    if (details) {
        if (x11_key == XK_ENTER or x11_key == XK_ESCAPE or x11_key == XK_LEFT) {
            details = false;
            return 1;
        }
        return 0;
    }
    const count = matchCount();
    switch (x11_key) {
        XK_BACKSPACE => {
            if (query_len == 0) return 0;
            query_len -= 1;
            while (query_len > 0 and (query[query_len] & 0xc0) == 0x80) query_len -= 1;
            selected = 0;
            return 1;
        },
        XK_ESCAPE => {
            if (query_len == 0) return 0;
            query_len = 0;
            selected = 0;
            return 1;
        },
        XK_UP => {
            if (selected == 0) return 0;
            selected -= 1;
            return 1;
        },
        XK_DOWN => {
            if (selected + 1 >= count) return 0;
            selected += 1;
            return 1;
        },
        XK_PAGE_UP => {
            if (selected == 0) return 0;
            selected -|= visibleRows();
            return 1;
        },
        XK_PAGE_DOWN => {
            if (selected + 1 >= count) return 0;
            selected = @min(count - 1, selected + visibleRows());
            return 1;
        },
        XK_HOME => {
            if (selected == 0) return 0;
            selected = 0;
            return 1;
        },
        XK_END => {
            if (count == 0 or selected == count - 1) return 0;
            selected = count - 1;
            return 1;
        },
        XK_ENTER, XK_RIGHT => {
            if (count == 0) return 0;
            details = true;
            return 1;
        },
        else => {},
    }
    const raw: u32 = @bitCast(x11_key);
    const codepoint: u32 = if ((raw & 0xff000000) == 0x01000000) raw & 0x00ffffff else raw;
    if (codepoint < 32 or codepoint > 0x10ffff or
        (codepoint >= 0xd800 and codepoint <= 0xdfff) or
        (raw >= 0xff00 and raw <= 0xffff)) return 0;
    var utf8: [4]u8 = undefined;
    const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8) catch return 0;
    if (query_len + utf8_len > QUERY_CAP) return 0;
    @memcpy(query[query_len..][0..utf8_len], utf8[0..utf8_len]);
    query_len += utf8_len;
    selected = 0;
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
    if (details) renderDetails(&writer) else renderList(&writer);
    phase = .ready;
    return .{
        .output_size = @intCast(writer.index),
        .output_ptr = @intCast(@intFromPtr(&output)),
        .failed = 0,
    };
}
