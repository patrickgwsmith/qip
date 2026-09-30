//! Render a Unicode emoji search from UTF-8 input and an active result index.
const std = @import("std");
const data = @import("lib/emoji-data.zig");

const INPUT_CAP: usize = 1024;
const OUTPUT_CAP: usize = 32 * 1024;
const CONTENT_TYPE = "text/plain";
const DEFAULT_COLUMNS: usize = 80;
const DEFAULT_LINES: usize = 24;

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var columns: usize = DEFAULT_COLUMNS;
var lines: usize = DEFAULT_LINES;
var requested_active_index: usize = 0;
// Result metadata and scratch storage are replaced on every render.
var result_count: usize = 0;
var results: [data.emojis.len]u16 = undefined;

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

    fn textClipped(self: *Writer, value: []const u8, end_column: usize) void {
        const limit = @min(end_column, self.width);
        if (self.line >= self.height or self.column >= limit) return;
        const available = limit - self.column;
        const count = std.unicode.utf8CountCodepoints(value) catch @trap();
        if (count <= available) return self.text(value);
        var byte_end: usize = 0;
        for (0..available - 1) |_| {
            byte_end += std.unicode.utf8ByteSequenceLength(value[byte_end]) catch @trap();
        }
        self.text(value[0..byte_end]);
        self.text("…");
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

fn matches(emoji: data.Emoji, query: []const u8) bool {
    var iterator = std.mem.tokenizeAny(u8, query, " \t\r\n");
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

fn wordByte(value: u8) bool {
    return std.ascii.isAlphanumeric(value) or value >= 0x80;
}

fn containsWordFolded(name: []const u8, term: []const u8) bool {
    if (term.len > name.len) return false;
    for (0..name.len - term.len + 1) |start| {
        const end = start + term.len;
        if (start > 0 and wordByte(name[start - 1])) continue;
        if (end < name.len and wordByte(name[end])) continue;
        if (std.ascii.eqlIgnoreCase(name[start..end], term)) return true;
    }
    return false;
}

fn matchesNameWords(name: []const u8, query: []const u8) bool {
    var terms = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (terms.next()) |term| {
        if (!containsWordFolded(name, term)) return false;
    }
    return true;
}

const MatchRank = enum { exact_name, exact_words, name_prefix, other };

fn matchRank(emoji: data.Emoji, query: []const u8) MatchRank {
    if (query.len == 0 or query.len > emoji.name.len) return .other;
    if (std.ascii.eqlIgnoreCase(emoji.name, query)) return .exact_name;
    if (matchesNameWords(emoji.name, query)) return .exact_words;
    if (std.ascii.eqlIgnoreCase(emoji.name[0..query.len], query)) return .name_prefix;
    return .other;
}

fn findResults(query: []const u8) void {
    result_count = 0;
    for ([_]bool{ false, true }) |newest_release| {
        for ([_]MatchRank{ .exact_name, .exact_words, .name_prefix, .other }) |rank| {
            for (data.emojis, 0..) |emoji, index| {
                if (std.mem.eql(u8, emoji.introduced, data.version) != newest_release or
                    matchRank(emoji, query) != rank or !matches(emoji, query)) continue;
                results[result_count] = @intCast(index);
                result_count += 1;
            }
        }
    }
}

fn detailLine(writer: *Writer, label: []const u8, value: []const u8) void {
    writer.text(label);
    writer.padTo(16);
    writer.text(value);
    writer.newline();
}

fn renderFrame(writer: *Writer, active: usize) void {
    writer.text("EMOJI FINDER  ");
    writer.number(result_count);
    writer.text(" / ");
    writer.number(data.emojis.len);
    writer.newline();
    writer.padTo(6);
    writer.text("Unicode name");
    writer.newline();
    if (result_count == 0) {
        writer.text("  No matches. Try another name, emoji, or code point.");
        writer.newline();
        return;
    }
    // At small heights, prioritize the list. Otherwise keep details in view.
    const show_details = writer.height >= 11;
    const reserved: usize = if (show_details) 10 else 2;
    const visible = @max(1, writer.height -| reserved);
    const first = active -| (visible / 2);
    const end = @min(result_count, first + visible);
    for (first..end) |index| {
        const emoji = data.emojis[results[index]];
        writer.text(if (index == active) "> " else "  ");
        writer.emoji(emoji.glyph);
        writer.text("  ");
        writer.textClipped(emoji.name, writer.width);
        writer.newline();
    }
    if (!show_details) return;
    for (end - first..visible) |_| writer.newline();
    writer.newline();
    const emoji = data.emojis[results[active]];
    writer.text("ACTIVE EMOJI  ");
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

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn uniform_set_columns(value: u32) u32 {
    columns = @max(1, @min(value, 160));
    return @intCast(columns);
}

export fn uniform_set_lines(value: u32) u32 {
    lines = @max(1, @min(value, 60));
    return @intCast(lines);
}

export fn uniform_set_active_index(value: u32) u32 {
    requested_active_index = @min(value, data.emojis.len - 1);
    return @intCast(requested_active_index);
}

// Number of navigable results from the last successful render; not input state.
export fn active_count() u32 {
    return @intCast(result_count);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    if (input_size > INPUT_CAP) @trap();
    const query = std.mem.trim(u8, input[0..input_size], " \t\r\n");
    findResults(query);
    const active = @min(requested_active_index, result_count -| 1);
    var writer = Writer{ .width = columns, .height = lines };
    renderFrame(&writer, active);
    columns = DEFAULT_COLUMNS;
    lines = DEFAULT_LINES;
    requested_active_index = 0;
    return .{ .output_size = @intCast(writer.index), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
