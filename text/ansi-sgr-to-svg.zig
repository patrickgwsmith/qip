//! Render the supported ANSI SGR subset as browser-native monospace SVG text.

const std = @import("std");
const ansi = @import("lib/ansi-sgr.zig");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/plain";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";
const DEFAULT_WIDTH: u32 = 1200;
const DEFAULT_HEIGHT: u32 = 630;
const PADDING: f32 = 24;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var canvas_width: u32 = DEFAULT_WIDTH;
var canvas_height: u32 = DEFAULT_HEIGHT;
var font_size: u32 = 16;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn uniform_set_width(value: i32) i32 {
    canvas_width = @intCast(@max(64, @min(value, 8192)));
    return @intCast(canvas_width);
}

export fn uniform_set_height(value: i32) i32 {
    canvas_height = @intCast(@max(64, @min(value, 8192)));
    return @intCast(canvas_height);
}

export fn uniform_set_font_size(value: i32) i32 {
    font_size = @intCast(@max(8, @min(value, 256)));
    return @intCast(font_size);
}

const Writer = struct {
    index: usize = 0,

    fn bytes(self: *Writer, text: []const u8) !void {
        if (text.len > output_buf.len - self.index) return error.OutputOverflow;
        @memcpy(output_buf[self.index .. self.index + text.len], text);
        self.index += text.len;
    }

    fn byte(self: *Writer, value: u8) !void {
        if (self.index >= output_buf.len) return error.OutputOverflow;
        output_buf[self.index] = value;
        self.index += 1;
    }

    fn int(self: *Writer, value: u32) !void {
        var buffer: [16]u8 = undefined;
        try self.bytes(try std.fmt.bufPrint(&buffer, "{d}", .{value}));
    }

    fn float(self: *Writer, value: f32) !void {
        var buffer: [32]u8 = undefined;
        try self.bytes(try std.fmt.bufPrint(&buffer, "{d:.3}", .{value}));
    }
};

fn decodeOne(text: []const u8, index: *usize) struct { codepoint: u32, len: usize } {
    const start = index.*;
    const first = text[index.*];
    index.* += 1;
    if (first < 0x80) return .{ .codepoint = first, .len = 1 };
    const extra: usize = if ((first & 0xe0) == 0xc0) 1 else if ((first & 0xf0) == 0xe0) 2 else if ((first & 0xf8) == 0xf0) 3 else return .{ .codepoint = '?', .len = 1 };
    if (index.* + extra > text.len) return .{ .codepoint = '?', .len = 1 };
    var codepoint: u32 = first & (@as(u8, 0x7f) >> @intCast(extra));
    var count: usize = 0;
    while (count < extra) : (count += 1) {
        const byte = text[index.*];
        if ((byte & 0xc0) != 0x80) return .{ .codepoint = '?', .len = 1 };
        index.* += 1;
        codepoint = (codepoint << 6) | (byte & 0x3f);
    }
    return .{ .codepoint = codepoint, .len = index.* - start };
}

fn isCombiningMark(codepoint: u32) bool {
    return codepoint >= 0x0300 and codepoint <= 0x036f;
}

const Context = struct {
    out: Writer,
    col: u32 = 0,
    row: u32 = 0,
    advance: f32,
    line_height: f32,
    max_cols: u32,
    max_rows: u32,

    fn emit(self: *@This(), text: []const u8, style: ansi.Style) !void {
        var index: usize = 0;
        while (index < text.len) {
            const start = index;
            const decoded = decodeOne(text, &index);
            if (decoded.codepoint == '\r') continue;
            if (decoded.codepoint == '\n') {
                self.row += 1;
                self.col = 0;
                continue;
            }
            if (decoded.codepoint == '\t') {
                self.col += 4 - self.col % 4;
                continue;
            }
            const combining = isCombiningMark(decoded.codepoint);
            const draw_col = if (combining and self.col > 0) self.col - 1 else self.col;
            if (self.row < self.max_rows and draw_col < self.max_cols) try self.draw(text[start..index], style, draw_col);
            if (!combining) {
                self.col += 1;
                if (self.col >= self.max_cols) {
                    self.col = 0;
                    self.row += 1;
                }
            }
        }
    }

    fn draw(self: *@This(), text: []const u8, style: ansi.Style, column: u32) !void {
        const x = PADDING + @as(f32, @floatFromInt(column)) * self.advance;
        const top = PADDING + @as(f32, @floatFromInt(self.row)) * self.line_height;
        if (style.background) |color| {
            try self.out.bytes("<rect x=\"");
            try self.out.float(x);
            try self.out.bytes("\" y=\"");
            try self.out.float(top);
            try self.out.bytes("\" width=\"");
            try self.out.float(self.advance);
            try self.out.bytes("\" height=\"");
            try self.out.float(self.line_height);
            try self.out.bytes("\" fill=\"");
            try self.out.bytes(ansi.colorHex(color));
            try self.out.bytes("\"/>");
        }
        try self.out.bytes("<text xml:space=\"preserve\" x=\"");
        try self.out.float(x);
        try self.out.bytes("\" y=\"");
        try self.out.float(top + @as(f32, @floatFromInt(font_size)));
        try self.out.bytes("\" fill=\"");
        try self.out.bytes(if (style.foreground) |color| ansi.colorHex(color) else "#e5e5e5");
        try self.out.bytes("\"");
        if (style.bold) try self.out.bytes(" font-weight=\"bold\"");
        if (style.dim) try self.out.bytes(" opacity=\"0.65\"");
        if (style.underline) try self.out.bytes(" text-decoration=\"underline\"");
        try self.out.bytes(">");
        for (text) |byte| switch (byte) {
            '&' => try self.out.bytes("&amp;"),
            '<' => try self.out.bytes("&lt;"),
            '>' => try self.out.bytes("&gt;"),
            else => try self.out.byte(byte),
        };
        try self.out.bytes("</text>");
    }
};

fn renderImpl(input: []const u8) u32 {
    const size: f32 = @floatFromInt(font_size);
    const advance = size * 0.602;
    const line_height = size * 1.45;
    const width: f32 = @floatFromInt(canvas_width);
    const height: f32 = @floatFromInt(canvas_height);
    const max_cols: u32 = @max(1, @as(u32, @intFromFloat(@floor((width - PADDING * 2) / advance))));
    const max_rows: u32 = @max(1, @as(u32, @intFromFloat(@floor((height - PADDING * 2) / line_height))));
    var context = Context{ .out = .{}, .advance = advance, .line_height = line_height, .max_cols = max_cols, .max_rows = max_rows };
    context.out.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"") catch @trap();
    context.out.int(canvas_width) catch @trap();
    context.out.bytes("\" height=\"") catch @trap();
    context.out.int(canvas_height) catch @trap();
    context.out.bytes("\" viewBox=\"0 0 ") catch @trap();
    context.out.int(canvas_width) catch @trap();
    context.out.byte(' ') catch @trap();
    context.out.int(canvas_height) catch @trap();
    context.out.bytes("\" font-family=\"ui-monospace, SFMono-Regular, Menlo, Consolas, monospace\" font-size=\"") catch @trap();
    context.out.int(font_size) catch @trap();
    context.out.bytes("\"><rect width=\"100%\" height=\"100%\" fill=\"#111827\"/>") catch @trap();
    ansi.parse(input, Context, &context, Context.emit) catch @trap();
    context.out.bytes("</svg>") catch @trap();
    return @intCast(context.out.index);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const size: usize = input_size;
    if (size > INPUT_CAP) @trap();
    return .{ .output_size = renderImpl(input_buf[0..size]), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "renders SGR colour and bold as SVG text" {
    const input = "\x1b[1;93mwarning\x1b[0m";
    const output_len = renderImpl(input);
    const output = output_buf[0..output_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "font-family=\"ui-monospace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "fill=\"#f5f543\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "font-weight=\"bold\"") != null);
}
