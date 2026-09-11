const std = @import("std");
const font = @import("dejavu_sans_mono_56_latin1_bitmap.zig");
const output_ktx2 = @hasDecl(@import("root"), "qip_text_output_ktx2");
const ktx = if (output_ktx2) @import("ktx2_rgba8_srgb") else struct {};

const INPUT_CAP: usize = 65536;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const OUTPUT_CONTENT_TYPE = if (output_ktx2) "image/ktx2" else "image/bmp";

const OG_WIDTH: u32 = 1200;
const OG_HEIGHT: u32 = 630;
const PADDING_LEFT: u32 = 72;
const PADDING_RIGHT: u32 = 72;
const PADDING_TOP: u32 = 72;
const PADDING_BOTTOM: u32 = 72;
const LEADING: u32 = 8;

const DRAWABLE_W: u32 = OG_WIDTH - PADDING_LEFT - PADDING_RIGHT;
const DRAWABLE_H: u32 = OG_HEIGHT - PADDING_TOP - PADDING_BOTTOM;
const ROW_H: u32 = font.GLYPH_H + LEADING;
const MAX_COLS: u32 = DRAWABLE_W / font.GLYPH_W;
const MAX_ROWS: u32 = DRAWABLE_H / ROW_H;
const DEFAULT_TEXT_COLOR_RGBA: u32 = 0x000000FF;
const DEFAULT_BACKGROUND_COLOR_RGBA: u32 = 0xFFFFFFFF;
const BMP_OUTPUT_SIZE: usize = 54 + @as(usize, OG_WIDTH) * @as(usize, OG_HEIGHT) * 4;
const OUTPUT_HEADER_SIZE: usize = if (output_ktx2) ktx.HEADER_SIZE else 54;
const RASTER_OUTPUT_SIZE: usize = OUTPUT_HEADER_SIZE + @as(usize, OG_WIDTH) * @as(usize, OG_HEIGHT) * 4;

comptime {
    if (MAX_COLS == 0 or MAX_ROWS == 0) @compileError("the authored canvas must fit text");
    if (RASTER_OUTPUT_SIZE > OUTPUT_CAP) @compileError("the raster output must fit its buffer");
}

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var text_color_rgba: u32 = DEFAULT_TEXT_COLOR_RGBA; // 0xRRGGBBAA
var background_color_rgba: u32 = DEFAULT_BACKGROUND_COLOR_RGBA; // 0xRRGGBBAA

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

export fn uniform_set_text_color_rgba(value: u32) u32 {
    text_color_rgba = value;
    return text_color_rgba;
}

export fn uniform_set_background_color_rgba(value: u32) u32 {
    background_color_rgba = value;
    return background_color_rgba;
}

fn writeU16LE(off: u32, value: u16) void {
    const idx: usize = @intCast(off);
    output_buf[idx] = @intCast(value & 0xFF);
    output_buf[idx + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32LE(off: u32, value: u32) void {
    const idx: usize = @intCast(off);
    output_buf[idx] = @intCast(value & 0xFF);
    output_buf[idx + 1] = @intCast((value >> 8) & 0xFF);
    output_buf[idx + 2] = @intCast((value >> 16) & 0xFF);
    output_buf[idx + 3] = @intCast((value >> 24) & 0xFF);
}

fn colorR(c: u32) u8 {
    return @intCast((c >> 24) & 0xFF);
}

fn colorG(c: u32) u8 {
    return @intCast((c >> 16) & 0xFF);
}

fn colorB(c: u32) u8 {
    return @intCast((c >> 8) & 0xFF);
}

fn colorA(c: u32) u8 {
    return @intCast(c & 0xFF);
}

fn setPixel(width: u32, height: u32, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) void {
    if (x >= width or y >= height) return;
    const row: u32 = if (output_ktx2) y else height - 1 - y;
    const idx: usize = @intCast(OUTPUT_HEADER_SIZE + (row * width + x) * 4);
    output_buf[idx] = if (output_ktx2) r else b;
    output_buf[idx + 1] = g;
    output_buf[idx + 2] = if (output_ktx2) b else r;
    output_buf[idx + 3] = a;
}

fn glyphIndexForCodepoint(cp: u32) ?usize {
    if (cp >= font.ASCII_START and cp <= font.ASCII_END) {
        return @intCast(cp - font.ASCII_START);
    }
    if (cp >= font.LATIN1_START and cp <= font.LATIN1_END) {
        return font.ASCII_COUNT + @as(usize, @intCast(cp - font.LATIN1_START));
    }
    return null;
}

fn decodeUtf8One(input: []const u8, idx: *usize) u32 {
    if (idx.* >= input.len) return '?';

    const b0 = input[idx.*];
    idx.* += 1;
    if (b0 < 0x80) return b0;

    if ((b0 & 0xE0) == 0xC0) {
        if (idx.* >= input.len) return '?';
        const b1 = input[idx.*];
        if ((b1 & 0xC0) != 0x80) return '?';
        idx.* += 1;
        const cp: u32 = ((@as(u32, b0 & 0x1F)) << 6) | @as(u32, b1 & 0x3F);
        if (cp < 0x80) return '?';
        return cp;
    }

    if ((b0 & 0xF0) == 0xE0) {
        if (idx.* + 1 >= input.len) return '?';
        const b1 = input[idx.*];
        const b2 = input[idx.* + 1];
        if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80) return '?';
        idx.* += 2;
        const cp: u32 = ((@as(u32, b0 & 0x0F)) << 12) | ((@as(u32, b1 & 0x3F)) << 6) | @as(u32, b2 & 0x3F);
        if (cp < 0x800) return '?';
        return cp;
    }

    if ((b0 & 0xF8) == 0xF0) {
        if (idx.* + 2 >= input.len) return '?';
        const b1 = input[idx.*];
        const b2 = input[idx.* + 1];
        const b3 = input[idx.* + 2];
        if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80 or (b3 & 0xC0) != 0x80) return '?';
        idx.* += 3;
        const cp: u32 = ((@as(u32, b0 & 0x07)) << 18) | ((@as(u32, b1 & 0x3F)) << 12) | ((@as(u32, b2 & 0x3F)) << 6) | @as(u32, b3 & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) return '?';
        return cp;
    }

    return '?';
}

fn isWordDelimiter(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn measureWordCols(input: []const u8, start: usize) u32 {
    var i: usize = start;
    var cols: u32 = 0;
    while (i < input.len and cols < MAX_COLS) {
        if (isWordDelimiter(input[i])) break;
        _ = decodeUtf8One(input, &i);
        cols += 1;
    }
    return cols;
}

fn countRows(input: []const u8) u32 {
    var rows: u32 = 1;
    var col: u32 = 0;
    var i: usize = 0;
    var prev_was_delim = true;
    while (i < input.len and rows < MAX_ROWS) {
        const c = input[i];
        if (c == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
            rows += 1;
            col = 0;
            i += 1;
            prev_was_delim = true;
            continue;
        }
        if (c == '\n') {
            rows += 1;
            col = 0;
            i += 1;
            prev_was_delim = true;
            continue;
        }
        if (c == '\t') {
            const spaces: u32 = 4 - (col % 4);
            var s: u32 = 0;
            while (s < spaces and rows < MAX_ROWS) : (s += 1) {
                col += 1;
                if (col >= MAX_COLS) {
                    rows += 1;
                    col = 0;
                }
            }
            i += 1;
            prev_was_delim = true;
            continue;
        }

        if (prev_was_delim and c != ' ' and col > 0) {
            const word_cols = measureWordCols(input, i);
            if (word_cols <= MAX_COLS and col + word_cols > MAX_COLS) {
                rows += 1;
                if (rows >= MAX_ROWS) return MAX_ROWS;
                col = 0;
            }
        }

        _ = decodeUtf8One(input, &i);
        col += 1;
        if (col >= MAX_COLS) {
            rows += 1;
            col = 0;
        }
        prev_was_delim = (c == ' ');
    }
    return rows;
}

fn drawGlyph(base_x: u32, base_y: u32, glyph_index: usize, r: u8, g: u8, b: u8, a: u8) void {
    var gy: u32 = 0;
    while (gy < font.GLYPH_H) : (gy += 1) {
        const row_bits = font.glyph_rows[glyph_index][gy];
        var gx: u32 = 0;
        while (gx < font.GLYPH_W) : (gx += 1) {
            if (((row_bits >> @intCast(gx)) & 1) != 0) {
                setPixel(OG_WIDTH, OG_HEIGHT, base_x + gx, base_y + gy, r, g, b, a);
            }
        }
    }
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    const use_size: usize = input_size;
    const input = input_buf[0..use_size];

    const rows = countRows(input);
    const width: u32 = OG_WIDTH;
    const height: u32 = OG_HEIGHT;
    const pixel_bytes: u64 = @as(u64, width) * @as(u64, height) * 4;
    const total: u64 = RASTER_OUTPUT_SIZE;

    const bg_r = colorR(background_color_rgba);
    const bg_g = colorG(background_color_rgba);
    const bg_b = colorB(background_color_rgba);
    const bg_a = colorA(background_color_rgba);
    const fg_r = colorR(text_color_rgba);
    const fg_g = colorG(text_color_rgba);
    const fg_b = colorB(text_color_rgba);
    const fg_a = colorA(text_color_rgba);

    @memset(output_buf[0..OUTPUT_HEADER_SIZE], 0);
    var off: usize = OUTPUT_HEADER_SIZE;
    while (off < total) : (off += 4) {
        output_buf[off] = if (output_ktx2) bg_r else bg_b;
        output_buf[off + 1] = bg_g;
        output_buf[off + 2] = if (output_ktx2) bg_b else bg_r;
        output_buf[off + 3] = bg_a;
    }

    if (output_ktx2) {
        _ = ktx.writeHeader(output_buf[0..], width, height) orelse return 0;
    } else {
        output_buf[0] = 'B';
        output_buf[1] = 'M';
        writeU32LE(2, @intCast(total));
        writeU32LE(6, 0);
        writeU32LE(10, 54);
        writeU32LE(14, 40);
        writeU32LE(18, width);
        writeU32LE(22, height);
        writeU16LE(26, 1);
        writeU16LE(28, 32);
        writeU32LE(30, 0);
        writeU32LE(34, @intCast(pixel_bytes));
        writeU32LE(38, 2835);
        writeU32LE(42, 2835);
        writeU32LE(46, 0);
        writeU32LE(50, 0);
    }

    var row: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    var prev_was_delim = true;
    while (i < input.len and row < rows and row < MAX_ROWS) {
        const c = input[i];
        if (c == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
            row += 1;
            col = 0;
            i += 1;
            prev_was_delim = true;
            continue;
        }
        if (c == '\n') {
            row += 1;
            col = 0;
            i += 1;
            prev_was_delim = true;
            continue;
        }
        if (c == '\t') {
            const spaces: u32 = 4 - (col % 4);
            var s: u32 = 0;
            while (s < spaces and row < rows and row < MAX_ROWS) : (s += 1) {
                col += 1;
                if (col >= MAX_COLS) {
                    row += 1;
                    col = 0;
                }
            }
            i += 1;
            prev_was_delim = true;
            continue;
        }

        if (prev_was_delim and c != ' ' and col > 0) {
            const word_cols = measureWordCols(input, i);
            if (word_cols <= MAX_COLS and col + word_cols > MAX_COLS) {
                row += 1;
                col = 0;
                if (row >= rows or row >= MAX_ROWS) break;
            }
        }

        const cp = decodeUtf8One(input, &i);
        const fallback_idx = glyphIndexForCodepoint('?').?;
        const glyph_idx = glyphIndexForCodepoint(cp) orelse fallback_idx;
        const base_x = PADDING_LEFT + col * font.GLYPH_W;
        const base_y = PADDING_TOP + row * ROW_H;
        drawGlyph(base_x, base_y, glyph_idx, fg_r, fg_g, fg_b, fg_a);

        col += 1;
        if (col >= MAX_COLS) {
            row += 1;
            col = 0;
        }
        prev_was_delim = (c == ' ');
    }

    resetUniforms();
    return @intCast(total);
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

fn resetUniforms() void {
    text_color_rgba = DEFAULT_TEXT_COLOR_RGBA;
    background_color_rgba = DEFAULT_BACKGROUND_COLOR_RGBA;
}

fn outputHasPixel(b: u8, g: u8, r: u8, a: u8) bool {
    var i: usize = 54;
    while (i + 3 < BMP_OUTPUT_SIZE) : (i += 4) {
        if (output_buf[i] == b and output_buf[i + 1] == g and output_buf[i + 2] == r and output_buf[i + 3] == a) return true;
    }
    return false;
}

test "supports latin-1 glyph lookup including e-acute" {
    try std.testing.expect(glyphIndexForCodepoint('A') != null);
    try std.testing.expect(glyphIndexForCodepoint(0x00E9) != null); // é
    try std.testing.expect(glyphIndexForCodepoint(0x20AC) == null); // €
}

test "render resets colors to black text on white" {
    input_buf[0] = 'A';
    _ = uniform_set_text_color_rgba(0xff0000ff);
    _ = uniform_set_background_color_rgba(0x0000ffff);
    try std.testing.expectEqual(@as(u32, BMP_OUTPUT_SIZE), renderImpl(1));
    try std.testing.expect(outputHasPixel(0, 0, 255, 255));
    try std.testing.expect(outputHasPixel(255, 0, 0, 255));

    try std.testing.expectEqual(@as(u32, BMP_OUTPUT_SIZE), renderImpl(1));
    try std.testing.expect(outputHasPixel(0, 0, 0, 255));
    try std.testing.expect(outputHasPixel(255, 255, 255, 255));
}
