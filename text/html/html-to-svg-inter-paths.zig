//! Render a small, fixed-viewport HTML subset as self-contained Inter SVG paths.
//!
//! This is a mobile document renderer, not a browser. It uses a 390 by 844 CSS
//! pixel viewport, inline style attributes, block/inline flow, and the embedded
//! Inter Regular and Bold outlines. It deliberately ignores scripts, external
//! resources, style sheets, and unsupported CSS rather than attempting browser
//! compatibility.

const std = @import("std");
const regular = @import("inter_regular");
const bold = @import("inter_bold");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const VIEWPORT_WIDTH: f32 = 390.0;
const VIEWPORT_HEIGHT: f32 = 844.0;
const MAX_FRAMES: usize = 64;
const MAX_RECTS: usize = 512;
const MAX_GLYPHS: usize = 16 * 1024;
const WHITE: u32 = 0xffffffff;
const INK: u32 = 0x111827ff;
const LINK: u32 = 0x2563ebff;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var rects: [MAX_RECTS]Rect = undefined;
var glyphs: [MAX_GLYPHS]Glyph = undefined;
var frames: [MAX_FRAMES]Frame = undefined;

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

const Align = enum { left, center, right };

const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

const Width = struct {
    value: f32,
    percent: bool,
};

const Style = struct {
    font_size: f32 = 16,
    font_weight: u16 = 400,
    line_height: f32 = 24,
    color: u32 = INK,
    background: ?u32 = null,
    border_color: ?u32 = null,
    border_width: f32 = 0,
    border_radius: f32 = 0,
    padding: Edges = .{},
    margin: Edges = .{},
    width: ?Width = null,
    text_align: Align = .left,
};

const Layout = struct {
    x: f32,
    width: f32,
    y: f32,
    line_x: f32,
    line_top: f32,
    line_height: f32 = 0,
    has_line: bool = false,
    line_glyph_start: usize = 0,
    line_align: Align = .left,
    previous: ?usize = null,
    previous_bold: bool = false,
};

const FrameKind = enum { root, block, in_flow, ignored };

const Frame = struct {
    kind: FrameKind,
    tag: []const u8,
    style: Style,
    parent_layout: Layout = undefined,
    rect_index: ?usize = null,
    rect_y: f32 = 0,
};

const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32 = 0,
    fill: ?u32,
    stroke: ?u32,
    stroke_width: f32,
    radius: f32,
};

const Glyph = struct {
    index: usize,
    x: f32,
    y: f32,
    scale: f32,
    color: u32,
    use_bold: bool,
};

const Writer = struct {
    index: usize = 0,

    fn byte(self: *Writer, value: u8) void {
        if (self.index >= output_buf.len) @trap();
        output_buf[self.index] = value;
        self.index += 1;
    }

    fn bytes(self: *Writer, value: []const u8) void {
        if (value.len > output_buf.len - self.index) @trap();
        @memcpy(output_buf[self.index .. self.index + value.len], value);
        self.index += value.len;
    }

    fn float(self: *Writer, value: f32) void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d:.3}", .{value}) catch @trap();
        self.bytes(text);
    }

    fn color(self: *Writer, value: u32) void {
        const channels = [_]u8{
            @intCast((value >> 24) & 0xff),
            @intCast((value >> 16) & 0xff),
            @intCast((value >> 8) & 0xff),
        };
        self.byte('#');
        for (channels) |channel| {
            self.byte(hex(channel >> 4));
            self.byte(hex(channel & 0x0f));
        }
    }
};

fn hex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn trim(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end = bytes.len;
    while (start < end and isSpace(bytes[start])) : (start += 1) {}
    while (end > start and isSpace(bytes[end - 1])) : (end -= 1) {}
    return bytes[start..end];
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn inherited(style: Style) Style {
    return .{
        .font_size = style.font_size,
        .font_weight = style.font_weight,
        .line_height = style.line_height,
        .color = style.color,
        .text_align = style.text_align,
    };
}

fn defaultForTag(tag: []const u8, parent: Style) Style {
    var style = inherited(parent);
    if (eqlIgnoreCase(tag, "h1")) {
        style.font_size = 32;
        style.font_weight = 700;
        style.line_height = 40;
        style.margin.bottom = 16;
    } else if (eqlIgnoreCase(tag, "h2")) {
        style.font_size = 24;
        style.font_weight = 700;
        style.line_height = 32;
        style.margin.top = 8;
        style.margin.bottom = 12;
    } else if (eqlIgnoreCase(tag, "h3")) {
        style.font_size = 20;
        style.font_weight = 700;
        style.line_height = 28;
        style.margin.top = 8;
        style.margin.bottom = 8;
    } else if (eqlIgnoreCase(tag, "p")) {
        style.margin.bottom = 16;
    } else if (eqlIgnoreCase(tag, "a")) {
        style.color = LINK;
    } else if (eqlIgnoreCase(tag, "strong") or eqlIgnoreCase(tag, "b")) {
        style.font_weight = 700;
    } else if (eqlIgnoreCase(tag, "button")) {
        style.font_weight = 700;
        style.color = WHITE;
        style.background = INK;
        style.padding = .{ .top = 12, .right = 16, .bottom = 12, .left = 16 };
        style.border_radius = 8;
        style.margin.bottom = 12;
    } else if (eqlIgnoreCase(tag, "li")) {
        style.margin.bottom = 8;
    }
    return style;
}

fn isBlockTag(tag: []const u8) bool {
    return eqlIgnoreCase(tag, "body") or eqlIgnoreCase(tag, "main") or eqlIgnoreCase(tag, "header") or
        eqlIgnoreCase(tag, "footer") or eqlIgnoreCase(tag, "article") or eqlIgnoreCase(tag, "section") or
        eqlIgnoreCase(tag, "div") or eqlIgnoreCase(tag, "p") or eqlIgnoreCase(tag, "h1") or
        eqlIgnoreCase(tag, "h2") or eqlIgnoreCase(tag, "h3") or eqlIgnoreCase(tag, "ul") or
        eqlIgnoreCase(tag, "ol") or eqlIgnoreCase(tag, "li") or eqlIgnoreCase(tag, "button") or
        eqlIgnoreCase(tag, "input") or eqlIgnoreCase(tag, "hr");
}

fn isVoidTag(tag: []const u8) bool {
    return eqlIgnoreCase(tag, "area") or eqlIgnoreCase(tag, "base") or eqlIgnoreCase(tag, "br") or
        eqlIgnoreCase(tag, "col") or eqlIgnoreCase(tag, "embed") or eqlIgnoreCase(tag, "hr") or
        eqlIgnoreCase(tag, "img") or eqlIgnoreCase(tag, "input") or eqlIgnoreCase(tag, "link") or
        eqlIgnoreCase(tag, "meta") or eqlIgnoreCase(tag, "param") or eqlIgnoreCase(tag, "source") or
        eqlIgnoreCase(tag, "track") or eqlIgnoreCase(tag, "wbr");
}

fn findAttribute(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        const name_start = i;
        while (i < tag.len and !isSpace(tag[i]) and tag[i] != '=' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}
        const name = tag[name_start..i];
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') {
            while (i < tag.len and !isSpace(tag[i])) : (i += 1) {}
            continue;
        }
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len) break;
        const quote = tag[i];
        const value_start: usize = if (quote == '\'' or quote == '"') blk: {
            i += 1;
            break :blk i;
        } else i;
        if (quote == '\'' or quote == '"') {
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
        } else {
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>') : (i += 1) {}
        }
        const value = tag[value_start..i];
        if (quote == '\'' or quote == '"') {
            if (i < tag.len) i += 1;
        }
        if (eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

fn parseNumber(value: []const u8) ?f32 {
    var end = value.len;
    while (end > 0 and ((value[end - 1] >= 'a' and value[end - 1] <= 'z') or value[end - 1] == '%')) : (end -= 1) {}
    return std.fmt.parseFloat(f32, trim(value[0..end])) catch null;
}

fn parseColor(value_in: []const u8) ?u32 {
    const value = trim(value_in);
    if (eqlIgnoreCase(value, "black")) return 0x000000ff;
    if (eqlIgnoreCase(value, "white")) return WHITE;
    if (eqlIgnoreCase(value, "transparent")) return null;
    if (value.len != 4 and value.len != 7) return null;
    if (value[0] != '#') return null;
    const digits = value[1..];
    const stride: usize = if (digits.len == 3) 1 else 2;
    var channels: [3]u8 = undefined;
    var channel: usize = 0;
    while (channel < 3) : (channel += 1) {
        const first = std.fmt.charToDigit(digits[channel * stride], 16) catch return null;
        const second = if (digits.len == 3) first else std.fmt.charToDigit(digits[channel * 2 + 1], 16) catch return null;
        channels[channel] = first * 16 + second;
    }
    return (@as(u32, channels[0]) << 24) | (@as(u32, channels[1]) << 16) | (@as(u32, channels[2]) << 8) | 0xff;
}

fn applyEdges(edges: *Edges, value: []const u8) void {
    var values: [4]f32 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    while (start < value.len and count < values.len) {
        while (start < value.len and isSpace(value[start])) : (start += 1) {}
        const end_start = start;
        while (start < value.len and !isSpace(value[start])) : (start += 1) {}
        if (parseNumber(value[end_start..start])) |number| {
            values[count] = @max(number, 0);
            count += 1;
        }
    }
    if (count == 1) edges.* = .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] } else if (count == 2) edges.* = .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] } else if (count == 3) edges.* = .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] } else if (count == 4) edges.* = .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] };
}

fn applyStyle(style: *Style, value: []const u8) void {
    var start: usize = 0;
    while (start < value.len) {
        const end = std.mem.indexOfScalarPos(u8, value, start, ';') orelse value.len;
        const declaration = value[start..end];
        if (std.mem.indexOfScalar(u8, declaration, ':')) |colon| {
            const key = trim(declaration[0..colon]);
            const item = trim(declaration[colon + 1 ..]);
            if (eqlIgnoreCase(key, "color")) {
                if (parseColor(item)) |color| style.color = color;
            } else if (eqlIgnoreCase(key, "background") or eqlIgnoreCase(key, "background-color")) {
                style.background = parseColor(item);
            } else if (eqlIgnoreCase(key, "font-size")) {
                if (parseNumber(item)) |size| {
                    if (size >= 8 and size <= 96) style.font_size = size;
                }
            } else if (eqlIgnoreCase(key, "font-weight")) {
                if (std.fmt.parseInt(u16, item, 10) catch null) |weight| {
                    style.font_weight = if (weight >= 600) 700 else 400;
                }
            } else if (eqlIgnoreCase(key, "line-height")) {
                if (parseNumber(item)) |height| {
                    if (height >= 8 and height <= 160) style.line_height = height;
                }
            } else if (eqlIgnoreCase(key, "padding")) {
                applyEdges(&style.padding, item);
            } else if (eqlIgnoreCase(key, "margin")) {
                applyEdges(&style.margin, item);
            } else if (eqlIgnoreCase(key, "padding-top")) {
                if (parseNumber(item)) |n| style.padding.top = @max(n, 0);
            } else if (eqlIgnoreCase(key, "padding-right")) {
                if (parseNumber(item)) |n| style.padding.right = @max(n, 0);
            } else if (eqlIgnoreCase(key, "padding-bottom")) {
                if (parseNumber(item)) |n| style.padding.bottom = @max(n, 0);
            } else if (eqlIgnoreCase(key, "padding-left")) {
                if (parseNumber(item)) |n| style.padding.left = @max(n, 0);
            } else if (eqlIgnoreCase(key, "width")) {
                if (parseNumber(item)) |n| {
                    style.width = .{ .value = @max(n, 0), .percent = std.mem.endsWith(u8, item, "%") };
                }
            } else if (eqlIgnoreCase(key, "text-align")) {
                if (eqlIgnoreCase(item, "center")) style.text_align = .center else if (eqlIgnoreCase(item, "right")) style.text_align = .right else style.text_align = .left;
            } else if (eqlIgnoreCase(key, "border-radius")) {
                if (parseNumber(item)) |n| style.border_radius = @max(n, 0);
            } else if (eqlIgnoreCase(key, "border") or eqlIgnoreCase(key, "border-color")) {
                if (std.mem.lastIndexOfScalar(u8, item, '#')) |color_start| {
                    if (parseColor(item[color_start..])) |color| style.border_color = color;
                }
                if (eqlIgnoreCase(key, "border")) {
                    if (parseNumber(item)) |n| style.border_width = @max(n, 0);
                }
            }
        }
        if (end == value.len) break;
        start = end + 1;
    }
}

fn glyphIndex(cp: u32) usize {
    return regular.glyphIndex(cp) orelse regular.glyphIndex('?').?;
}

fn glyphAdvance(index: usize, use_bold: bool) f32 {
    return @floatFromInt(if (use_bold) bold.advances[index] else regular.advances[index]);
}

fn glyphKerning(left: usize, right: usize, use_bold: bool) f32 {
    return @floatFromInt(if (use_bold) bold.kerning(left, right) else regular.kerning(left, right));
}

fn flushLine(layout: *Layout, style: Style, force: bool, glyph_len: usize) void {
    if (!layout.has_line and !force) return;
    const remaining = @max(@as(f32, 0), layout.width - (layout.line_x - layout.x));
    const offset = switch (layout.line_align) {
        .left => 0,
        .center => remaining / 2,
        .right => remaining,
    };
    if (offset > 0) {
        for (glyphs[layout.line_glyph_start..glyph_len]) |*glyph| glyph.x += offset;
    }
    const height = @max(layout.line_height, style.line_height);
    layout.y = layout.line_top + height;
    layout.line_top = layout.y;
    layout.line_x = layout.x;
    layout.line_height = 0;
    layout.has_line = false;
    layout.previous = null;
}

fn emitGlyph(layout: *Layout, style: Style, cp: u32, glyph_len: *usize) void {
    const index = glyphIndex(cp);
    const use_bold = style.font_weight >= 600;
    const scale = style.font_size / regular.UNITS_PER_EM;
    var advance = glyphAdvance(index, use_bold) * scale;
    if (layout.previous) |previous| {
        if (layout.previous_bold == use_bold) advance += glyphKerning(previous, index, use_bold) * scale;
    }
    if (layout.has_line and layout.line_x + advance > layout.x + layout.width) flushLine(layout, style, false, glyph_len.*);
    if (!layout.has_line) {
        layout.line_top = layout.y;
        layout.line_x = layout.x;
        layout.has_line = true;
        layout.line_glyph_start = glyph_len.*;
        layout.line_align = style.text_align;
    }
    if (layout.line_top < VIEWPORT_HEIGHT) {
        if (glyph_len.* >= glyphs.len) @trap();
        glyphs[glyph_len.*] = .{
            .index = index,
            .x = layout.line_x,
            .y = layout.line_top + regular.ASCENDER * scale,
            .scale = scale,
            .color = style.color,
            .use_bold = use_bold,
        };
        glyph_len.* += 1;
    }
    layout.line_x += advance;
    layout.line_height = @max(layout.line_height, style.line_height);
    layout.previous = index;
    layout.previous_bold = use_bold;
}

fn emitSpace(layout: *Layout, style: Style, glyph_len: usize) void {
    const scale = style.font_size / regular.UNITS_PER_EM;
    const advance = glyphAdvance(regular.glyphIndex(' ').?, false) * scale;
    if (!layout.has_line) return;
    if (layout.line_x + advance > layout.x + layout.width) {
        flushLine(layout, style, false, glyph_len);
        return;
    }
    layout.line_x += advance;
    layout.previous = null;
}

fn decodeUtf8(input: []const u8, position: *usize) u32 {
    const first = input[position.*];
    position.* += 1;
    if (first < 0x80) return first;
    const extra: usize = if ((first & 0xe0) == 0xc0) 1 else if ((first & 0xf0) == 0xe0) 2 else if ((first & 0xf8) == 0xf0) 3 else return '?';
    if (position.* + extra > input.len) return '?';
    var cp: u32 = first & (@as(u8, 0x7f) >> @intCast(extra));
    var count: usize = 0;
    while (count < extra) : (count += 1) {
        const byte = input[position.*];
        if ((byte & 0xc0) != 0x80) return '?';
        position.* += 1;
        cp = (cp << 6) | (byte & 0x3f);
    }
    return cp;
}

fn entityAt(input: []const u8, position: usize) ?struct { cp: u32, len: usize } {
    const rest = input[position..];
    if (std.mem.startsWith(u8, rest, "&amp;")) return .{ .cp = '&', .len = 5 };
    if (std.mem.startsWith(u8, rest, "&lt;")) return .{ .cp = '<', .len = 4 };
    if (std.mem.startsWith(u8, rest, "&gt;")) return .{ .cp = '>', .len = 4 };
    if (std.mem.startsWith(u8, rest, "&quot;")) return .{ .cp = '"', .len = 6 };
    if (std.mem.startsWith(u8, rest, "&nbsp;")) return .{ .cp = ' ', .len = 6 };
    return null;
}

fn runAdvance(run: []const u8, layout: *const Layout, style: Style) f32 {
    const use_bold = style.font_weight >= 600;
    const scale = style.font_size / regular.UNITS_PER_EM;
    var position: usize = 0;
    var previous = layout.previous;
    var previous_bold = layout.previous_bold;
    var advance: f32 = 0;
    while (position < run.len) {
        const cp = if (run[position] < 0x80) blk: {
            const value = run[position];
            position += 1;
            break :blk @as(u32, value);
        } else decodeUtf8(run, &position);
        const index = glyphIndex(cp);
        advance += glyphAdvance(index, use_bold) * scale;
        if (previous) |left| {
            if (previous_bold == use_bold) advance += glyphKerning(left, index, use_bold) * scale;
        }
        previous = index;
        previous_bold = use_bold;
    }
    return advance;
}

fn emitRun(run: []const u8, layout: *Layout, style: Style, glyph_len: *usize) void {
    var position: usize = 0;
    while (position < run.len) {
        const cp = if (run[position] < 0x80) blk: {
            const value = run[position];
            position += 1;
            break :blk @as(u32, value);
        } else decodeUtf8(run, &position);
        emitGlyph(layout, style, cp, glyph_len);
    }
}

fn processText(text: []const u8, layout: *Layout, style: Style, glyph_len: *usize) void {
    var i: usize = 0;
    var pending_space = false;
    while (i < text.len) {
        if (text[i] == '&') {
            if (entityAt(text, i)) |entity| {
                if (entity.cp == ' ') pending_space = true else {
                    if (pending_space) emitSpace(layout, style, glyph_len.*);
                    pending_space = false;
                    emitGlyph(layout, style, entity.cp, glyph_len);
                }
                i += entity.len;
                continue;
            }
            if (pending_space) emitSpace(layout, style, glyph_len.*);
            pending_space = false;
            emitGlyph(layout, style, '&', glyph_len);
            i += 1;
            continue;
        }
        if (isSpace(text[i])) {
            pending_space = true;
            i += 1;
        } else {
            if (pending_space) emitSpace(layout, style, glyph_len.*);
            pending_space = false;
            const run_start = i;
            while (i < text.len and !isSpace(text[i]) and text[i] != '&') {
                if (text[i] < 0x80) i += 1 else _ = decodeUtf8(text, &i);
            }
            const run = text[run_start..i];
            const advance = runAdvance(run, layout, style);
            if (layout.has_line and advance <= layout.width and layout.line_x + advance > layout.x + layout.width) {
                flushLine(layout, style, false, glyph_len.*);
            }
            emitRun(run, layout, style, glyph_len);
        }
    }
}

fn writeSvg(rect_len: usize, glyph_len: usize) u32 {
    var out = Writer{};
    out.bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"390\" height=\"844\" viewBox=\"0 0 390 844\"><rect width=\"390\" height=\"844\" fill=\"");
    out.color(WHITE);
    out.bytes("\"/>");
    for (rects[0..rect_len]) |rect| {
        if (rect.height <= 0) continue;
        out.bytes("<rect x=\"");
        out.float(rect.x);
        out.bytes("\" y=\"");
        out.float(rect.y);
        out.bytes("\" width=\"");
        out.float(rect.width);
        out.bytes("\" height=\"");
        out.float(rect.height);
        out.bytes("\"");
        if (rect.radius > 0) {
            out.bytes(" rx=\"");
            out.float(rect.radius);
            out.bytes("\"");
        }
        if (rect.fill) |fill| {
            out.bytes(" fill=\"");
            out.color(fill);
            out.bytes("\"");
        } else out.bytes(" fill=\"none\"");
        if (rect.stroke) |stroke| {
            out.bytes(" stroke=\"");
            out.color(stroke);
            out.bytes("\" stroke-width=\"");
            out.float(rect.stroke_width);
            out.bytes("\"");
        }
        out.bytes("/>");
    }
    for (glyphs[0..glyph_len]) |glyph| {
        const path = if (glyph.use_bold) bold.glyph_paths[glyph.index] else regular.glyph_paths[glyph.index];
        if (path.len == 0) continue;
        out.bytes("<path fill=\"");
        out.color(glyph.color);
        out.bytes("\" d=\"");
        out.bytes(path);
        out.bytes("\" transform=\"translate(");
        out.float(glyph.x);
        out.byte(' ');
        out.float(glyph.y);
        out.bytes(") scale(");
        out.float(glyph.scale);
        out.bytes(")\"/>");
    }
    out.bytes("</svg>");
    return @intCast(out.index);
}

fn renderHtml(input: []const u8) u32 {
    var frame_len: usize = 1;
    frames[0] = .{
        .kind = .root,
        .tag = "",
        .style = .{},
    };
    var layout = Layout{ .x = 0, .width = VIEWPORT_WIDTH, .y = 0, .line_x = 0, .line_top = 0 };
    var rect_len: usize = 0;
    var glyph_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, input, i, '<') orelse input.len;
            if (frames[frame_len - 1].kind != .ignored) processText(input[i..end], &layout, frames[frame_len - 1].style, &glyph_len);
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "<!--")) {
            const comment_end = std.mem.indexOfPos(u8, input, i + 4, "-->") orelse input.len;
            i = if (comment_end == input.len) input.len else comment_end + 3;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, input, i, '>') orelse break;
        const raw = input[i + 1 .. close];
        i = close + 1;
        if (raw.len == 0 or raw[0] == '!' or raw[0] == '?') continue;
        const ending = raw[0] == '/';
        const tag_bytes = trim(if (ending) raw[1..] else raw);
        var name_end: usize = 0;
        while (name_end < tag_bytes.len and !isSpace(tag_bytes[name_end]) and tag_bytes[name_end] != '/') : (name_end += 1) {}
        const tag = tag_bytes[0..name_end];
        if (tag.len == 0) continue;
        if (frames[frame_len - 1].kind == .ignored) {
            if (ending and eqlIgnoreCase(tag, frames[frame_len - 1].tag)) frame_len -= 1;
            continue;
        }
        if (ending) {
            if (frame_len <= 1) continue;
            const frame = frames[frame_len - 1];
            if (!eqlIgnoreCase(tag, frame.tag)) continue;
            frame_len -= 1;
            if (frame.kind == .block) {
                flushLine(&layout, frame.style, false, glyph_len);
                const inner_end = layout.y + frame.style.padding.bottom + frame.style.border_width;
                if (frame.rect_index) |index| rects[index].height = inner_end - frame.rect_y;
                const parent = frame.parent_layout;
                layout = parent;
                layout.y = inner_end + frame.style.margin.bottom;
                layout.line_top = layout.y;
                layout.line_x = layout.x;
            }
            continue;
        }
        if (eqlIgnoreCase(tag, "br")) {
            flushLine(&layout, frames[frame_len - 1].style, true, glyph_len);
            continue;
        }
        if (eqlIgnoreCase(tag, "script") or eqlIgnoreCase(tag, "style") or eqlIgnoreCase(tag, "head") or eqlIgnoreCase(tag, "title") or eqlIgnoreCase(tag, "template")) {
            if (frame_len >= frames.len) @trap();
            frames[frame_len] = .{ .kind = .ignored, .tag = tag, .style = frames[frame_len - 1].style };
            frame_len += 1;
            continue;
        }
        const parent_style = frames[frame_len - 1].style;
        var style = defaultForTag(tag, parent_style);
        if (findAttribute(tag_bytes[name_end..], "style")) |style_attr| applyStyle(&style, style_attr);
        if (isVoidTag(tag) and !isBlockTag(tag)) continue;
        if (eqlIgnoreCase(tag, "input")) {
            style.background = style.background orelse WHITE;
            style.border_color = style.border_color orelse 0xd1d5dbff;
            style.border_width = if (style.border_width == 0) 1 else style.border_width;
            style.padding = .{ .top = 10, .right = 12, .bottom = 10, .left = 12 };
        }
        const self_closing = tag_bytes[tag_bytes.len - 1] == '/' or isVoidTag(tag);
        if (!isBlockTag(tag)) {
            if (frame_len >= frames.len) @trap();
            frames[frame_len] = .{ .kind = .in_flow, .tag = tag, .style = style };
            frame_len += 1;
            continue;
        }
        flushLine(&layout, parent_style, false, glyph_len);
        layout.y += style.margin.top;
        const outer_x = layout.x + style.margin.left;
        const available_width = layout.width - style.margin.left - style.margin.right;
        const requested_width = if (style.width) |width| if (width.percent) available_width * width.value / 100 else width.value else available_width;
        const outer_width = @max(@as(f32, 0), @min(requested_width, available_width));
        var rect_index: ?usize = null;
        if (style.background != null or style.border_color != null) {
            if (rect_len >= rects.len) @trap();
            rects[rect_len] = .{ .x = outer_x, .y = layout.y, .width = outer_width, .fill = style.background, .stroke = style.border_color, .stroke_width = style.border_width, .radius = style.border_radius };
            rect_index = rect_len;
            rect_len += 1;
        }
        const child_x = outer_x + style.border_width + style.padding.left;
        const child_width = @max(@as(f32, 0), outer_width - style.border_width * 2 - style.padding.left - style.padding.right);
        const child_y = layout.y + style.border_width + style.padding.top;
        if (self_closing) {
            if (eqlIgnoreCase(tag, "hr")) {
                if (rect_len >= rects.len) @trap();
                rects[rect_len] = .{ .x = outer_x, .y = child_y, .width = outer_width, .height = 1, .fill = 0xd1d5dbff, .stroke = null, .stroke_width = 0, .radius = 0 };
                rect_len += 1;
            } else if (eqlIgnoreCase(tag, "input")) {
                const value = findAttribute(tag_bytes[name_end..], "value") orelse findAttribute(tag_bytes[name_end..], "placeholder") orelse "";
                var child = Layout{ .x = child_x, .width = child_width, .y = child_y, .line_x = child_x, .line_top = child_y };
                processText(value, &child, style, &glyph_len);
                flushLine(&child, style, true, glyph_len);
                if (rect_index) |index| rects[index].height = child.y + style.padding.bottom + style.border_width - layout.y;
                layout.y = child.y + style.padding.bottom + style.border_width + style.margin.bottom;
            }
            layout.line_top = layout.y;
            layout.line_x = layout.x;
            continue;
        }
        if (frame_len >= frames.len) @trap();
        const parent_layout = layout;
        frames[frame_len] = .{ .kind = .block, .tag = tag, .style = style, .parent_layout = parent_layout, .rect_index = rect_index, .rect_y = layout.y };
        frame_len += 1;
        layout = .{ .x = child_x, .width = child_width, .y = child_y, .line_x = child_x, .line_top = child_y };
        if (eqlIgnoreCase(tag, "li")) {
            emitGlyph(&layout, style, 0x2022, &glyph_len);
            emitSpace(&layout, style, glyph_len);
        }
    }
    while (frame_len > 1) {
        const frame = frames[frame_len - 1];
        frame_len -= 1;
        if (frame.kind == .block) {
            flushLine(&layout, frame.style, false, glyph_len);
            const inner_end = layout.y + frame.style.padding.bottom + frame.style.border_width;
            if (frame.rect_index) |index| rects[index].height = inner_end - frame.rect_y;
            const parent = frame.parent_layout;
            layout = parent;
            layout.y = inner_end + frame.style.margin.bottom;
            layout.line_top = layout.y;
            layout.line_x = layout.x;
        }
    }
    return writeSvg(rect_len, glyph_len);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const size: usize = input_size;
    if (size > INPUT_CAP) @trap();
    return .{ .output_size = renderHtml(input_buf[0..size]), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "renders mobile HTML as Inter paths" {
    const html = "<main style='padding:24px'><h1>Small web page</h1><p>A <strong>bold</strong> paragraph.</p><button>Continue</button><input placeholder='Email'></main>";
    const size = renderHtml(html);
    const svg = output_buf[0..size];
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"390\""));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<path fill=\"#111827\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "rx=\"8.000\"") != null);
}
