//! Render a 1200x630 Open Graph title card with Inter Display paths.
//!
//! Input is application/x-www-form-urlencoded with a required, possibly empty
//! `title` and an optional `subtitle`. The left-aligned text block is vertically centered.
//! Layout uses proportional advances and precomputed pair kerning. The
//! `font_max_size` uniform sets the auto-fit ceiling from 32px to 160px; zero
//! uses the default 112px ceiling. The renderer can select a smaller size.

const std = @import("std");
const regular = @import("lib/inter_display_latin_paths.zig");
const bold = @import("lib/inter_display_bold_latin_paths.zig");

const INPUT_CAP: usize = 4 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/x-www-form-urlencoded";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const WIDTH: u32 = 1200;
const HEIGHT: u32 = 630;
const PADDING_X: f32 = 96;
const PADDING_Y: f32 = 72;
const AUTO_MAX_FONT_SIZE: u32 = 112;
const MIN_FONT_SIZE: u32 = 32;
const MAX_FONT_SIZE: u32 = 160;
const FONT_SIZE_STEP: u32 = 2;
const SUBTITLE_MIN_FONT_SIZE: u32 = 24;
const SUBTITLE_SIZE_NUMERATOR: u32 = 2;
const SUBTITLE_SIZE_DENOMINATOR: u32 = 5;
const BLOCK_GAP_RATIO: f32 = 0.32;
const MAX_CODEPOINTS: usize = 1_024;
const MAX_LINES_PER_FIELD: usize = 16;
const FIELD_BYTES_CAP: usize = 2 * 1024;

const DEFAULT_TEXT_COLOR_RGBA: u32 = 0x101010ff;
const DEFAULT_BACKGROUND_COLOR_RGBA: u32 = 0xeecc33ff;
const DEFAULT_FONT_WEIGHT: u32 = 700;
const DEFAULT_REQUESTED_MAX_FONT_SIZE: u32 = 0;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var title_buf: [FIELD_BYTES_CAP]u8 = undefined;
var subtitle_buf: [FIELD_BYTES_CAP]u8 = undefined;
var title_codepoints: [MAX_CODEPOINTS]u32 = undefined;
var subtitle_codepoints: [MAX_CODEPOINTS]u32 = undefined;
var title_lines: [MAX_LINES_PER_FIELD]Line = undefined;
var subtitle_lines: [MAX_LINES_PER_FIELD]Line = undefined;

var text_color_rgba: u32 = DEFAULT_TEXT_COLOR_RGBA;
var background_color_rgba: u32 = DEFAULT_BACKGROUND_COLOR_RGBA;
var font_weight: u32 = DEFAULT_FONT_WEIGHT;
var requested_max_font_size: u32 = DEFAULT_REQUESTED_MAX_FONT_SIZE;

const RenderError = error{
    InvalidForm,
    MissingTitle,
    DuplicateField,
    FieldTooLong,
    InvalidUtf8,
    UnsupportedCodepoint,
    TooManyCodepoints,
    TooManyLines,
    TextDoesNotFit,
    OutputOverflow,
};

const Line = struct {
    start: usize,
    end: usize,
    width_units: i32,
};

const Layout = struct {
    title_font_size: u32,
    title_scale: f32,
    title_line_advance: f32,
    title_height: f32,
    title_baseline_from_top: f32,
    title_line_count: usize,
    subtitle_font_size: u32,
    subtitle_scale: f32,
    subtitle_line_advance: f32,
    subtitle_height: f32,
    subtitle_baseline_from_top: f32,
    subtitle_line_count: usize,
    gap: f32,
    block_height: f32,
};

const FormFields = struct {
    title: []const u8,
    subtitle: []const u8,
};

const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Writer, value: []const u8) RenderError!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    fn integer(self: *Writer, value: anytype) RenderError!void {
        var buffer: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.write(value_text);
    }

    fn float(self: *Writer, value: f32) RenderError!void {
        var buffer: [48]u8 = undefined;
        const value_text = std.fmt.bufPrint(&buffer, "{d:.3}", .{value}) catch return error.OutputOverflow;
        try self.write(value_text);
    }

    fn color(self: *Writer, rgba: u32) RenderError!void {
        var buffer: [9]u8 = undefined;
        buffer[0] = '#';
        hexByte(buffer[1..3], @truncate(rgba >> 24));
        hexByte(buffer[3..5], @truncate(rgba >> 16));
        hexByte(buffer[5..7], @truncate(rgba >> 8));
        const alpha: u8 = @truncate(rgba);
        if (alpha == 0xff) {
            try self.write(buffer[0..7]);
        } else {
            hexByte(buffer[7..9], alpha);
            try self.write(&buffer);
        }
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_utf8_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

export fn uniform_set_text_color_rgba(value: u32) u32 {
    text_color_rgba = value;
    return text_color_rgba;
}

export fn uniform_set_background_color_rgba(value: u32) u32 {
    background_color_rgba = value;
    return background_color_rgba;
}

export fn uniform_set_font_weight(value: u32) u32 {
    font_weight = if (value < 550) 400 else 700;
    return font_weight;
}

export fn uniform_set_font_max_size(value: u32) u32 {
    if (value == 0) {
        requested_max_font_size = 0;
    } else {
        requested_max_font_size = std.math.clamp(value, MIN_FONT_SIZE, MAX_FONT_SIZE);
    }
    return requested_max_font_size;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > input_buf.len) @trap();
    const output_size = renderSvg(input_buf[0..input_size], &output_buf) catch @trap();
    resetUniforms();
    return @intCast(output_size);
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn resetUniforms() void {
    text_color_rgba = DEFAULT_TEXT_COLOR_RGBA;
    background_color_rgba = DEFAULT_BACKGROUND_COLOR_RGBA;
    font_weight = DEFAULT_FONT_WEIGHT;
    requested_max_font_size = DEFAULT_REQUESTED_MAX_FONT_SIZE;
}

fn renderSvg(input: []const u8, output: []u8) RenderError!usize {
    const fields = try parseForm(input);
    const title_count = try normalizeText(fields.title, &title_codepoints);
    const subtitle_count = try normalizeText(fields.subtitle, &subtitle_codepoints);
    const title = title_codepoints[0..title_count];
    const subtitle = subtitle_codepoints[0..subtitle_count];
    const layout = try chooseLayout(title, subtitle);
    var out = Writer{ .bytes = output };

    try out.write("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"630\" viewBox=\"0 0 1200 630\">");
    try out.write("<rect width=\"1200\" height=\"630\" fill=\"");
    try out.color(background_color_rgba);
    try out.write("\"/>");

    const block_top = (@as(f32, @floatFromInt(HEIGHT)) - layout.block_height) / 2;
    const title_baseline = block_top + layout.title_baseline_from_top;
    try writeTextGroup(
        &out,
        "title",
        title,
        title_lines[0..layout.title_line_count],
        layout.title_font_size,
        layout.title_scale,
        layout.title_line_advance,
        title_baseline,
        font_weight == 700,
    );

    if (layout.subtitle_line_count != 0) {
        const subtitle_top = block_top + layout.title_height + layout.gap;
        const subtitle_baseline = subtitle_top + layout.subtitle_baseline_from_top;
        try writeTextGroup(
            &out,
            "subtitle",
            subtitle,
            subtitle_lines[0..layout.subtitle_line_count],
            layout.subtitle_font_size,
            layout.subtitle_scale,
            layout.subtitle_line_advance,
            subtitle_baseline,
            false,
        );
    }
    try out.write("</svg>\n");
    return out.index;
}

fn writeTextGroup(
    out: *Writer,
    role: []const u8,
    text: []const u32,
    line_set: []const Line,
    font_size: u32,
    scale: f32,
    line_advance: f32,
    first_baseline: f32,
    use_bold: bool,
) RenderError!void {
    try out.write("<g fill=\"");
    try out.color(text_color_rgba);
    try out.write("\" stroke=\"none\" data-role=\"");
    try out.write(role);
    try out.write("\" data-font-family=\"Inter Display\" data-font-weight=\"");
    try out.integer(if (use_bold) @as(u32, 700) else 400);
    try out.write("\" data-font-size=\"");
    try out.integer(font_size);
    try out.write("\">");

    for (line_set, 0..) |line, line_index| {
        const baseline_y = first_baseline + @as(f32, @floatFromInt(line_index)) * line_advance;
        var cursor_units: i32 = 0;
        var index = line.start;
        while (index < line.end) : (index += 1) {
            const glyph_index = glyphIndex(text[index]) orelse return error.UnsupportedCodepoint;
            const path = glyphPath(glyph_index, use_bold);
            if (path.len != 0) {
                try out.write("<path d=\"");
                try out.write(path);
                try out.write("\" transform=\"translate(");
                try out.float(PADDING_X + @as(f32, @floatFromInt(cursor_units)) * scale);
                try out.write(" ");
                try out.float(baseline_y);
                try out.write(") scale(");
                try out.float(scale);
                try out.write(")\"/>");
            }
            cursor_units += glyphAdvance(glyph_index, use_bold);
            if (index + 1 < line.end) {
                const next_glyph_index = glyphIndex(text[index + 1]) orelse return error.UnsupportedCodepoint;
                cursor_units += glyphKerning(glyph_index, next_glyph_index, use_bold);
            }
        }
    }
    try out.write("</g>");
}

fn parseForm(input: []const u8) RenderError!FormFields {
    var title: ?[]const u8 = null;
    var subtitle: ?[]const u8 = null;
    var position: usize = 0;
    while (position <= input.len) {
        const pair_end = std.mem.indexOfScalarPos(u8, input, position, '&') orelse input.len;
        const pair = input[position..pair_end];
        if (pair.len == 0) return error.InvalidForm;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidForm;
        var key_buf: [16]u8 = undefined;
        const key = try decodeFormPart(pair[0..equals], &key_buf);
        const value = pair[equals + 1 ..];
        if (std.mem.eql(u8, key, "title")) {
            if (title != null) return error.DuplicateField;
            title = try decodeFormPart(value, &title_buf);
        } else if (std.mem.eql(u8, key, "subtitle")) {
            if (subtitle != null) return error.DuplicateField;
            subtitle = try decodeFormPart(value, &subtitle_buf);
        } else {
            return error.InvalidForm;
        }
        if (pair_end == input.len) break;
        position = pair_end + 1;
    }
    return .{
        .title = title orelse return error.MissingTitle,
        .subtitle = subtitle orelse "",
    };
}

fn decodeFormPart(input: []const u8, output: []u8) RenderError![]const u8 {
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < input.len) {
        if (output_index >= output.len) return error.FieldTooLong;
        const byte = input[input_index];
        if (byte == '+') {
            output[output_index] = ' ';
            input_index += 1;
        } else if (byte == '%') {
            if (input.len - input_index < 3) return error.InvalidForm;
            const high = hexValue(input[input_index + 1]) orelse return error.InvalidForm;
            const low = hexValue(input[input_index + 2]) orelse return error.InvalidForm;
            output[output_index] = high * 16 + low;
            input_index += 3;
        } else {
            output[output_index] = byte;
            input_index += 1;
        }
        output_index += 1;
    }
    return output[0..output_index];
}

fn normalizeText(input: []const u8, output: []u32) RenderError!usize {
    var input_index: usize = 0;
    var count: usize = 0;
    var at_line_start = true;
    while (input_index < input.len) {
        var codepoint = try decodeUtf8(input, &input_index);
        if (codepoint == '\r') {
            if (input_index < input.len and input[input_index] == '\n') input_index += 1;
            codepoint = '\n';
        }
        if (codepoint == '\t' or codepoint == 0x00a0) codepoint = ' ';

        if (codepoint == '\n') {
            if (count > 0 and output[count - 1] == ' ') count -= 1;
            if (!at_line_start and count < output.len) {
                output[count] = '\n';
                count += 1;
            }
            at_line_start = true;
            continue;
        }
        if (codepoint == ' ') {
            if (!at_line_start and (count == 0 or output[count - 1] != ' ')) {
                if (count >= output.len) return error.TooManyCodepoints;
                output[count] = ' ';
                count += 1;
            }
            continue;
        }
        if (glyphIndex(codepoint) == null or codepoint == 0x00ad) return error.UnsupportedCodepoint;
        if (count >= output.len) return error.TooManyCodepoints;
        output[count] = codepoint;
        count += 1;
        at_line_start = false;
    }
    while (count > 0 and (output[count - 1] == ' ' or output[count - 1] == '\n')) count -= 1;
    return count;
}

fn chooseLayout(title: []const u32, subtitle: []const u32) RenderError!Layout {
    var font_size = if (requested_max_font_size == 0) AUTO_MAX_FONT_SIZE else requested_max_font_size;
    while (font_size >= MIN_FONT_SIZE) : (font_size -= FONT_SIZE_STEP) {
        if (layoutForSize(title, subtitle, font_size)) |layout| return layout else |err| switch (err) {
            error.TextDoesNotFit, error.TooManyLines => {},
            else => return err,
        }
        if (font_size == MIN_FONT_SIZE) break;
    }
    return error.TextDoesNotFit;
}

fn layoutForSize(title: []const u32, subtitle: []const u32, title_font_size: u32) RenderError!Layout {
    const subtitle_font_size = @max(
        SUBTITLE_MIN_FONT_SIZE,
        title_font_size * SUBTITLE_SIZE_NUMERATOR / SUBTITLE_SIZE_DENOMINATOR,
    );
    const title_scale = @as(f32, @floatFromInt(title_font_size)) / regular.UNITS_PER_EM;
    const subtitle_scale = @as(f32, @floatFromInt(subtitle_font_size)) / regular.UNITS_PER_EM;
    const drawable_width = @as(f32, @floatFromInt(WIDTH)) - 2 * PADDING_X;
    const drawable_height = @as(f32, @floatFromInt(HEIGHT)) - 2 * PADDING_Y;
    const title_max_width_units: i32 = @intFromFloat(@floor(drawable_width / title_scale));
    const subtitle_max_width_units: i32 = @intFromFloat(@floor(drawable_width / subtitle_scale));
    if (title_max_width_units < 1 or subtitle_max_width_units < 1) return error.TextDoesNotFit;
    const title_line_count = try wrapLines(title, title_max_width_units, &title_lines, font_weight == 700);
    const subtitle_line_count = try wrapLines(subtitle, subtitle_max_width_units, &subtitle_lines, false);
    const line_height_units = regular.ASCENDER - regular.DESCENDER + regular.LINE_GAP;
    const title_line_advance = line_height_units * title_scale;
    const subtitle_line_advance = line_height_units * subtitle_scale;
    const title_height = title_line_advance * @as(f32, @floatFromInt(title_line_count));
    const subtitle_height = subtitle_line_advance * @as(f32, @floatFromInt(subtitle_line_count));
    const gap = if (title_line_count == 0 or subtitle_line_count == 0)
        @as(f32, 0)
    else
        @as(f32, @floatFromInt(title_font_size)) * BLOCK_GAP_RATIO;
    const block_height = title_height + gap + subtitle_height;
    if (block_height > drawable_height) return error.TextDoesNotFit;
    return .{
        .title_font_size = title_font_size,
        .title_scale = title_scale,
        .title_line_advance = title_line_advance,
        .title_height = title_height,
        .title_baseline_from_top = regular.ASCENDER * title_scale,
        .title_line_count = title_line_count,
        .subtitle_font_size = subtitle_font_size,
        .subtitle_scale = subtitle_scale,
        .subtitle_line_advance = subtitle_line_advance,
        .subtitle_height = subtitle_height,
        .subtitle_baseline_from_top = regular.ASCENDER * subtitle_scale,
        .subtitle_line_count = subtitle_line_count,
        .gap = gap,
        .block_height = block_height,
    };
}

fn wrapLines(text: []const u32, max_width_units: i32, line_output: []Line, use_bold: bool) RenderError!usize {
    if (text.len == 0) return 0;
    var line_count: usize = 0;
    var position: usize = 0;
    while (position < text.len) {
        if (line_count >= line_output.len) return error.TooManyLines;
        while (position < text.len and text[position] == ' ') position += 1;
        if (position >= text.len) break;
        if (text[position] == '\n') {
            position += 1;
            continue;
        }

        const start = position;
        var end: usize = position;
        var last_space: ?usize = null;
        var width_units: i32 = 0;
        var previous_glyph: ?usize = null;
        while (position < text.len and text[position] != '\n') {
            const glyph_index = glyphIndex(text[position]) orelse return error.UnsupportedCodepoint;
            var next_width = width_units + glyphAdvance(glyph_index, use_bold);
            if (previous_glyph) |previous| next_width += glyphKerning(previous, glyph_index, use_bold);
            if (next_width > max_width_units) {
                if (position == start) return error.TextDoesNotFit;
                if (last_space) |space| {
                    end = space;
                    position = space + 1;
                }
                break;
            }
            width_units = next_width;
            if (text[position] == ' ') last_space = position;
            previous_glyph = glyph_index;
            position += 1;
            end = position;
        }
        while (end > start and text[end - 1] == ' ') end -= 1;
        if (end == start) return error.TextDoesNotFit;
        line_output[line_count] = .{
            .start = start,
            .end = end,
            .width_units = try measureLine(text[start..end], use_bold),
        };
        line_count += 1;
        if (position < text.len and text[position] == '\n') position += 1;
    }
    return line_count;
}

fn glyphIndex(codepoint: u32) ?usize {
    return regular.glyphIndex(codepoint);
}

fn glyphAdvance(glyph_index: usize, use_bold: bool) i32 {
    const value = if (use_bold) bold.advances[glyph_index] else regular.advances[glyph_index];
    return value;
}

fn glyphKerning(left: usize, right: usize, use_bold: bool) i32 {
    const value = if (use_bold) bold.kerning(left, right) else regular.kerning(left, right);
    return value;
}

fn glyphPath(glyph_index: usize, use_bold: bool) []const u8 {
    return if (use_bold) bold.glyph_paths[glyph_index] else regular.glyph_paths[glyph_index];
}

fn measureLine(text: []const u32, use_bold: bool) RenderError!i32 {
    var width: i32 = 0;
    var previous_glyph: ?usize = null;
    for (text) |codepoint| {
        const glyph_index = glyphIndex(codepoint) orelse return error.UnsupportedCodepoint;
        if (previous_glyph) |previous| width += glyphKerning(previous, glyph_index, use_bold);
        width += glyphAdvance(glyph_index, use_bold);
        previous_glyph = glyph_index;
    }
    return width;
}

fn decodeUtf8(input: []const u8, index: *usize) RenderError!u32 {
    if (index.* >= input.len) return error.InvalidUtf8;
    const first = input[index.*];
    index.* += 1;
    if (first < 0x80) return first;

    var remaining: usize = undefined;
    var value: u32 = undefined;
    var minimum: u32 = undefined;
    if ((first & 0xe0) == 0xc0) {
        remaining = 1;
        value = first & 0x1f;
        minimum = 0x80;
    } else if ((first & 0xf0) == 0xe0) {
        remaining = 2;
        value = first & 0x0f;
        minimum = 0x800;
    } else if ((first & 0xf8) == 0xf0) {
        remaining = 3;
        value = first & 0x07;
        minimum = 0x10000;
    } else return error.InvalidUtf8;

    if (remaining > input.len - index.*) return error.InvalidUtf8;
    var continuation: usize = 0;
    while (continuation < remaining) : (continuation += 1) {
        const byte = input[index.*];
        if ((byte & 0xc0) != 0x80) return error.InvalidUtf8;
        index.* += 1;
        value = (value << 6) | (byte & 0x3f);
    }
    if (value < minimum or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.InvalidUtf8;
    return value;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn hexByte(output: []u8, value: u8) void {
    output[0] = hexNibble(value >> 4);
    output[1] = hexNibble(value & 0x0f);
}

fn hexNibble(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

test "lays out a left-aligned title and smaller subtitle" {
    const fields = try parseForm("subtitle=A+smaller+supporting+line&title=A+large+display+title+that+wraps");
    const title_count = try normalizeText(fields.title, &title_codepoints);
    const subtitle_count = try normalizeText(fields.subtitle, &subtitle_codepoints);
    const layout = try chooseLayout(title_codepoints[0..title_count], subtitle_codepoints[0..subtitle_count]);
    try std.testing.expect(layout.title_font_size >= MIN_FONT_SIZE);
    try std.testing.expect(layout.title_font_size > layout.subtitle_font_size);
    try std.testing.expect(layout.title_line_count >= 1);
    try std.testing.expect(layout.subtitle_line_count >= 1);
    var rendered: [1024 * 1024]u8 = undefined;
    const size = try renderSvg("title=A+large+display+title+that+wraps&subtitle=A+smaller+supporting+line", &rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "<rect width=\"1200\" height=\"630\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "data-role=\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "data-role=\"subtitle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "translate(96.000 ") != null);
}

test "switches between regular and bold and formats colors" {
    text_color_rgba = 0x11223344;
    background_color_rgba = 0xaabbccff;
    font_weight = 400;
    var rendered: [1024 * 1024]u8 = undefined;
    const size = try renderSvg("title=Caf%C3%A9%21&subtitle=Cr%C3%A8me+br%C3%BBl%C3%A9e", &rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "fill=\"#aabbcc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "fill=\"#11223344\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0..size], "data-font-weight=\"400\"") != null);
    resetUniforms();
}

test "render resets all uniforms to authored defaults" {
    const input = "title=A";
    @memcpy(input_buf[0..input.len], input);
    _ = uniform_set_text_color_rgba(0x11223344);
    _ = uniform_set_background_color_rgba(0xaabbccff);
    _ = uniform_set_font_weight(400);
    _ = uniform_set_font_max_size(64);
    const configured_size = renderImpl(input.len);
    const configured = output_buf[0..configured_size];
    try std.testing.expect(std.mem.indexOf(u8, configured, "fill=\"#aabbcc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, configured, "fill=\"#11223344\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, configured, "data-font-weight=\"400\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, configured, "data-font-size=\"64\"") != null);

    const default_size = renderImpl(input.len);
    const defaults = output_buf[0..default_size];
    try std.testing.expect(std.mem.indexOf(u8, defaults, "fill=\"#eecc33\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, defaults, "fill=\"#101010\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, defaults, "data-font-weight=\"700\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, defaults, "data-font-size=\"112\"") != null);
}

test "supports common title punctuation and rejects unsupported scripts" {
    const count = try normalizeText("“Inter”—fast, clear… €42™", &title_codepoints);
    try std.testing.expect(count > 0);
    try std.testing.expectError(error.UnsupportedCodepoint, normalizeText("Greek Ω is outside this renderer", &title_codepoints));
}

test "applies Inter pair kerning to measurement" {
    const a = glyphIndex('A').?;
    const v = glyphIndex('V').?;
    const unkerned = glyphAdvance(a, false) + glyphAdvance(v, false);
    try std.testing.expectEqual(unkerned + glyphKerning(a, v, false), try measureLine(&.{ 'A', 'V' }, false));
    try std.testing.expect(glyphKerning(a, v, false) < 0);
}

test "form decoder requires one title and rejects malformed escapes" {
    const fields = try parseForm("subtitle=By+QIP&title=Hello%2C+world%21");
    try std.testing.expectEqualStrings("Hello, world!", fields.title);
    try std.testing.expectEqualStrings("By QIP", fields.subtitle);
    try std.testing.expectError(error.MissingTitle, parseForm("subtitle=Only"));
    try std.testing.expectError(error.DuplicateField, parseForm("title=One&title=Two"));
    try std.testing.expectError(error.InvalidForm, parseForm("title=Bad%2"));
}

test "empty title and blank card are valid" {
    var rendered: [1024 * 1024]u8 = undefined;
    _ = try renderSvg("title=&subtitle=Subtitle+only", &rendered);
    _ = try renderSvg("title=&subtitle=", &rendered);
}
