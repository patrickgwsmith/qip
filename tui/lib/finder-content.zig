//! Host-managed text search, active entries, and paged details for offline finders.
const std = @import("std");
const finder = @import("root");

const INPUT_CAP = 1024;
const OUTPUT_CAP = finder.output_capacity;
const CONTENT_TYPE = "text/plain";
var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var columns: usize = 80;
var lines: usize = 24;
var requested_active_index: usize = 0;
var entry_count: usize = 0;
var requested_detail_offset: usize = 0;
var detail_lines: usize = 0;
var detail_visible: usize = 0;

pub fn containsFolded(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

/// With no destination, this writer counts the same rows that it would emit.
/// Detail pagination selects a range of wrapped rows, without retaining a frame.
pub const Writer = struct {
    destination: ?*[OUTPUT_CAP]u8 = null,
    index: usize = 0,
    column: usize = 0,
    row: usize = 0,
    width: usize,
    skip: usize = 0,
    height: usize = std.math.maxInt(usize),

    fn byte(self: *Writer, value: u8) void {
        if (self.row < self.skip or self.row - self.skip >= self.height) return;
        if (self.destination) |destination| {
            if (self.index == OUTPUT_CAP) @trap();
            destination[self.index] = value;
            self.index += 1;
        }
    }

    fn cellWidth(scalar: u21) usize {
        if ((scalar >= 0x0300 and scalar <= 0x036f) or (scalar >= 0xfe00 and scalar <= 0xfe0f)) return 0;
        if (scalar >= 0x1100 and (scalar <= 0x115f or
            (scalar >= 0x2e80 and scalar <= 0xa4cf) or
            (scalar >= 0xac00 and scalar <= 0xd7a3) or
            (scalar >= 0xf900 and scalar <= 0xfaff) or
            (scalar >= 0xfe10 and scalar <= 0xfe6f) or
            (scalar >= 0xff01 and scalar <= 0xff60) or
            (scalar >= 0x20000 and scalar <= 0x3fffd))) return 2;
        return 1;
    }

    pub fn text(self: *Writer, value: []const u8) void {
        var i: usize = 0;
        while (i < value.len) {
            const length: usize = std.unicode.utf8ByteSequenceLength(value[i]) catch @trap();
            if (i + length > value.len) @trap();
            const scalar = std.unicode.utf8Decode(value[i..][0..length]) catch @trap();
            const width = cellWidth(scalar);
            if (self.column + width > self.width) break;
            for (value[i..][0..length]) |part| self.byte(part);
            self.column += width;
            i += length;
        }
    }

    pub fn newline(self: *Writer) void {
        self.byte('\n');
        self.row += 1;
        self.column = 0;
    }

    pub fn number(self: *Writer, value: usize) void {
        var buffer: [20]u8 = undefined;
        self.text(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch @trap());
    }

    pub fn padTo(self: *Writer, target: usize) void {
        while (self.column < @min(target, self.width)) self.text(" ");
    }

    /// Wrap at words when possible; split words wider than the viewport.
    pub fn wrap(self: *Writer, value: []const u8) void {
        var i: usize = 0;
        var space = false;
        while (i < value.len) {
            if (value[i] == '\n') {
                self.newline();
                i += 1;
                space = false;
                continue;
            }
            if (value[i] == ' ' or value[i] == '\t' or value[i] == '\r') {
                space = true;
                i += 1;
                continue;
            }
            var end = i;
            while (end < value.len and value[end] != ' ' and value[end] != '\n' and
                value[end] != '\t' and value[end] != '\r') : (end += 1)
            {}
            var width: usize = 0;
            var position = i;
            while (position < end) {
                const length: usize = std.unicode.utf8ByteSequenceLength(value[position]) catch @trap();
                width += cellWidth(std.unicode.utf8Decode(value[position..][0..length]) catch @trap());
                position += length;
            }
            if (space and self.column > 0) {
                if (self.column + 1 + width > self.width) self.newline() else self.text(" ");
            }
            space = false;
            while (i < end) {
                if (self.column == self.width) self.newline();
                const length: usize = std.unicode.utf8ByteSequenceLength(value[i]) catch @trap();
                const scalar_width = cellWidth(std.unicode.utf8Decode(value[i..][0..length]) catch @trap());
                if (self.column + scalar_width > self.width and self.column > 0) self.newline();
                self.text(value[i..][0..length]);
                i += length;
            }
        }
        if (self.column > 0) self.newline();
    }

    pub fn field(self: *Writer, label: []const u8, value: []const u8) void {
        self.text(label);
        self.text(": ");
        self.wrap(if (value.len == 0) "-" else value);
    }
};

const Layout = struct {
    list_rows: usize,
    detail_rows: usize,

    fn current() Layout {
        if (lines < 10) return .{ .list_rows = lines -| 1, .detail_rows = 0 };
        const list_rows = @max(1, (lines - 3) / 3);
        return .{ .list_rows = list_rows, .detail_rows = lines - list_rows - 3 };
    }
};

fn frame(query: []const u8) usize {
    const layout = Layout.current();
    entry_count = 0;
    detail_lines = 0;
    detail_visible = 0;
    for (0..finder.record_count) |record| {
        if (finder.matches(record, query)) entry_count += 1;
    }
    const active = @min(requested_active_index, entry_count -| 1);
    var writer = Writer{ .destination = &output, .width = columns, .height = lines };
    writer.text(finder.title);
    writer.text("  ");
    writer.number(entry_count);
    writer.text(" / ");
    writer.number(finder.record_count);
    writer.newline();
    if (entry_count == 0) {
        writer.text("No matches. Try another search.");
        writer.newline();
        return writer.index;
    }
    const first = @min(active -| (layout.list_rows / 2), entry_count -| layout.list_rows);
    const end = @min(entry_count, first + layout.list_rows);
    var selected: usize = 0;
    var ordinal: usize = 0;
    for (0..finder.rank_count) |rank| {
        for (0..finder.record_count) |record| {
            if (!finder.matches(record, query) or finder.rank(record, query) != rank) continue;
            if (ordinal == active) selected = record;
            if (ordinal >= first and ordinal < end) {
                writer.text(if (ordinal == active) "> " else "  ");
                finder.label(&writer, record);
                writer.newline();
            }
            ordinal += 1;
        }
    }
    var measure = Writer{ .width = columns };
    finder.details(&measure, selected);
    detail_lines = measure.row;
    detail_visible = layout.detail_rows;
    if (layout.detail_rows == 0) return writer.index;
    const offset = @min(requested_detail_offset, detail_lines -| detail_visible);
    for (end - first..layout.list_rows) |_| writer.newline();
    writer.newline();
    writer.text("DETAILS");
    if (detail_lines > detail_visible) {
        writer.text("  ");
        writer.number(offset + 1);
        writer.text("-");
        writer.number(@min(detail_lines, offset + detail_visible));
        writer.text(" / ");
        writer.number(detail_lines);
        writer.text("  Page Up/Down");
    }
    writer.newline();
    var detail_writer = Writer{
        .destination = &output,
        .index = writer.index,
        .width = columns,
        .skip = offset,
        .height = layout.detail_rows,
    };
    finder.details(&detail_writer, selected);
    return detail_writer.index;
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
    requested_active_index = value;
    return value;
}
export fn uniform_set_detail_offset(value: u32) u32 {
    requested_detail_offset = value;
    return value;
}
export fn detail_count() u32 {
    return @intCast(detail_lines);
}
export fn detail_page_size() u32 {
    return @intCast(detail_visible);
}
export fn active_count() u32 {
    return @intCast(entry_count);
}
export fn render(input_size: u32) packed struct(u64) { output_size: u32, output_ptr: u31, failed: u1 } {
    if (input_size > INPUT_CAP) @trap();
    const size = frame(std.mem.trim(u8, input[0..input_size], " \t\r\n"));
    columns = 80;
    lines = 24;
    requested_active_index = 0;
    requested_detail_offset = 0;
    return .{ .output_size = @intCast(size), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
