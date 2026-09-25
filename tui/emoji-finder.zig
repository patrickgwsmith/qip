//! Search Unicode emoji and extend one with listed RGI sequences.
const std = @import("std");
const data = @import("lib/emoji-data.zig");

const OUTPUT_CAP: usize = 32 * 1024;
const QUERY_CAP: usize = 64;
const KEY_DOWN: i32 = 1;
const MODIFIER_MASK: i32 = 8 | 16 | 32;
const XK_BACKSPACE: i32 = 0xff08;
const XK_TAB: i32 = 0xff09;
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
var combining: bool = false;
var base_index: usize = 0;
var saved_query: [QUERY_CAP]u8 = undefined;
var saved_query_len: usize = 0;
var saved_selected: usize = 0;
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

    fn emoji(self: *Writer, glyph: []const u8) void {
        if (self.line >= self.height or self.column + 2 > self.width) return;
        for (glyph) |part| self.byte(part);
        self.column += 2;
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

fn significantCount(scalars: []const u32) usize {
    var count: usize = 0;
    for (scalars) |scalar| {
        if (scalar != 0x200d and scalar != 0xfe0e and scalar != 0xfe0f) count += 1;
    }
    return count;
}

fn extends(base: data.Emoji, candidate: data.Emoji) bool {
    if (candidate.component or significantCount(candidate.scalars) <= significantCount(base.scalars)) return false;
    var next: usize = 0;
    for (base.scalars) |scalar| {
        if (scalar == 0x200d or scalar == 0xfe0e or scalar == 0xfe0f) continue;
        var found = false;
        while (next < candidate.scalars.len) : (next += 1) {
            if (candidate.scalars[next] == scalar) {
                next += 1;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn matches(emoji: data.Emoji) bool {
    if (combining and !extends(data.emojis[base_index], emoji)) return false;
    const search = query[0..query_len];
    var iterator = std.mem.tokenizeScalar(u8, search, ' ');
    while (iterator.next()) |term| {
        if (!(containsFolded(emoji.name, term) or
            containsFolded(emoji.group, term) or
            containsFolded(emoji.subgroup, term) or
            containsFolded(emoji.glyph, term) or
            containsFolded(emoji.codepoints, term) or
            containsFolded(emoji.parts, term))) return false;
    }
    return true;
}

fn matchCount() usize {
    var count: usize = 0;
    for (data.emojis) |emoji| {
        if (matches(emoji)) count += 1;
    }
    return count;
}

fn selectedIndex() ?usize {
    var match_index: usize = 0;
    for (data.emojis, 0..) |emoji, index| {
        if (!matches(emoji)) continue;
        if (match_index == selected) return index;
        match_index += 1;
    }
    return null;
}

fn visibleRows() usize {
    return if (lines > 6) @min(lines - 6, 54) else 1;
}

fn renderList(writer: *Writer) void {
    const count = matchCount();
    writer.text(if (combining) "EMOJI COMBINATIONS  " else "EMOJI FINDER  ");
    writer.number(count);
    if (!combining) {
        writer.text(" / ");
        writer.number(data.emojis.len);
    }
    writer.newline();
    if (combining) {
        writer.text("Extend: ");
        writer.emoji(data.emojis[base_index].glyph);
        writer.text(" ");
        writer.text(data.emojis[base_index].name);
        writer.newline();
    }
    writer.text("Find: ");
    writer.text(query[0..query_len]);
    writer.text("_");
    writer.newline();
    writer.text("  Emoji  Name");
    writer.newline();
    if (count == 0) {
        writer.text(if (combining) "  No listed combination. Try another term or Esc." else "  No matches. Backspace or Esc to change the filter.");
        writer.newline();
    } else {
        const visible = @max(1, visibleRows() -| @intFromBool(combining));
        const first = (selected / @max(visible, 1)) * @max(visible, 1);
        var match_index: usize = 0;
        for (data.emojis) |emoji| {
            if (!matches(emoji)) continue;
            if (match_index >= first and match_index < first + visible) {
                writer.text(if (match_index == selected) "> " else "  ");
                writer.emoji(emoji.glyph);
                writer.text("  ");
                writer.text(emoji.name);
                writer.newline();
            }
            match_index += 1;
        }
    }
    if (lines >= 6) {
        writer.text(if (combining) "Type partner  Tab extend selected  Enter details  Esc back" else "Type to filter  Tab combine  Enter details  Esc clear");
        writer.newline();
    }
}

fn detailLine(writer: *Writer, label: []const u8, value: []const u8) void {
    writer.text(label);
    writer.padTo(16);
    writer.text(value);
    writer.newline();
}

fn renderDetails(writer: *Writer) void {
    const emoji = data.emojis[selectedIndex() orelse return renderList(writer)];
    writer.text("EMOJI DETAILS  Enter or Esc: back  Tab: combine");
    writer.newline();
    writer.emoji(emoji.glyph);
    writer.text("  ");
    writer.text(emoji.name);
    writer.newline();
    detailLine(writer, "Group", emoji.group);
    detailLine(writer, "Subgroup", emoji.subgroup);
    detailLine(writer, "Added in Emoji", emoji.introduced);
    detailLine(writer, "Code points", emoji.codepoints);
    detailLine(writer, "Status", if (emoji.component) "Emoji component" else "Fully qualified RGI emoji");
    writer.text("Rendering depends on the platform's emoji font.");
}

fn startCombining() i32 {
    const index = selectedIndex() orelse return 0;
    if (!combining) {
        @memcpy(saved_query[0..query_len], query[0..query_len]);
        saved_query_len = query_len;
        saved_selected = selected;
    }
    base_index = index;
    combining = true;
    details = false;
    query_len = 0;
    selected = 0;
    return 1;
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
        switch (x11_key) {
            XK_ENTER, XK_ESCAPE, XK_LEFT => {
                details = false;
                return 1;
            },
            XK_TAB => return startCombining(),
            else => return 0,
        }
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
            if (combining) {
                combining = false;
                @memcpy(query[0..saved_query_len], saved_query[0..saved_query_len]);
                query_len = saved_query_len;
                selected = saved_selected;
                return 1;
            }
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
        XK_TAB => return startCombining(),
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
    return .{ .output_size = @intCast(writer.index), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
