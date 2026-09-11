const std = @import("std");
const font = @import("dejavu_sans_mono_paths.zig");

const INPUT_CAP: usize = 65536;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const MIN_DIM: i32 = 64;
const MAX_DIM: i32 = 8192;
const DEFAULT_WIDTH: u32 = 1200;
const DEFAULT_HEIGHT: u32 = 630;
const MIN_FONT_SIZE: i32 = 8;
const MAX_FONT_SIZE: i32 = 1024;
const DEFAULT_FONT_SIZE: f32 = 56.0;
const PADDING_X: f32 = 72.0;
const PADDING_Y: f32 = 72.0;
const EXTRA_LEADING: f32 = 8.0;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var canvas_width: u32 = DEFAULT_WIDTH;
var canvas_height: u32 = DEFAULT_HEIGHT;
var font_size_px: f32 = DEFAULT_FONT_SIZE;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

export fn uniform_set_width(value: i32) i32 {
    var v = value;
    if (v < MIN_DIM) v = MIN_DIM;
    if (v > MAX_DIM) v = MAX_DIM;
    canvas_width = @intCast(v);
    return v;
}

export fn uniform_set_height(value: i32) i32 {
    var v = value;
    if (v < MIN_DIM) v = MIN_DIM;
    if (v > MAX_DIM) v = MAX_DIM;
    canvas_height = @intCast(v);
    return v;
}

export fn uniform_set_font_size(value: i32) i32 {
    var v = value;
    if (v < MIN_FONT_SIZE) v = MIN_FONT_SIZE;
    if (v > MAX_FONT_SIZE) v = MAX_FONT_SIZE;
    font_size_px = @floatFromInt(v);
    return v;
}

fn appendByte(out_idx: *usize, b: u8) !void {
    if (out_idx.* >= OUTPUT_CAP) return error.OutputOverflow;
    output_buf[out_idx.*] = b;
    out_idx.* += 1;
}

fn appendSlice(out_idx: *usize, s: []const u8) !void {
    if (out_idx.* + s.len > OUTPUT_CAP) return error.OutputOverflow;
    @memcpy(output_buf[out_idx.* .. out_idx.* + s.len], s);
    out_idx.* += s.len;
}

fn appendInt(out_idx: *usize, value: u32) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try appendSlice(out_idx, s);
}

fn appendFloat(out_idx: *usize, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.3}", .{value});
    try appendSlice(out_idx, s);
}

fn glyphIndexForCodepoint(cp: u32) ?usize {
    return font.glyphIndex(cp);
}

fn isCombiningMark(cp: u32) bool {
    return cp >= 0x0300 and cp <= 0x036F;
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

const Layout = struct {
    scale: f32,
    advance: f32,
    row_h: f32,
    baseline: f32,
    max_cols: u32,
    max_rows: u32,
};

fn computeLayout() Layout {
    const scale = font_size_px / font.UNITS_PER_EM;
    const advance = font.ADVANCE_X * scale;
    const row_h = font.LINE_HEIGHT * scale + EXTRA_LEADING * (font_size_px / DEFAULT_FONT_SIZE);
    const baseline = font.ASCENDER * scale;
    const drawable_w = @as(f32, @floatFromInt(canvas_width)) - 2.0 * PADDING_X;
    const drawable_h = @as(f32, @floatFromInt(canvas_height)) - 2.0 * PADDING_Y;

    var cols_f = if (advance > 0) @floor(drawable_w / advance) else 0;
    var rows_f = if (row_h > 0) @floor(drawable_h / row_h) else 0;
    if (cols_f < 1) cols_f = 1;
    if (rows_f < 1) rows_f = 1;

    return .{
        .scale = scale,
        .advance = advance,
        .row_h = row_h,
        .baseline = baseline,
        .max_cols = @intFromFloat(cols_f),
        .max_rows = @intFromFloat(rows_f),
    };
}

fn measureWordCols(input: []const u8, start: usize, max_cols: u32) u32 {
    var i = start;
    var cols: u32 = 0;
    while (i < input.len and cols < max_cols) {
        if (isWordDelimiter(input[i])) break;
        const cp = decodeUtf8One(input, &i);
        if (!isCombiningMark(cp)) cols += 1;
    }
    return cols;
}

fn countRows(input: []const u8, layout: Layout) u32 {
    var rows: u32 = 1;
    var col: u32 = 0;
    var i: usize = 0;
    var prev_was_delim = true;
    while (i < input.len and rows < layout.max_rows) {
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
            while (s < spaces and rows < layout.max_rows) : (s += 1) {
                col += 1;
                if (col >= layout.max_cols) {
                    rows += 1;
                    col = 0;
                }
            }
            i += 1;
            prev_was_delim = true;
            continue;
        }

        if (prev_was_delim and c != ' ' and col > 0) {
            const word_cols = measureWordCols(input, i, layout.max_cols);
            if (word_cols <= layout.max_cols and col + word_cols > layout.max_cols) {
                rows += 1;
                if (rows >= layout.max_rows) return layout.max_rows;
                col = 0;
            }
        }

        const cp = decodeUtf8One(input, &i);
        if (!isCombiningMark(cp)) {
            col += 1;
            if (col >= layout.max_cols) {
                rows += 1;
                col = 0;
            }
            prev_was_delim = (c == ' ');
        }
    }
    return rows;
}

fn renderImpl(input_size: u32) u32 {
    const size: usize = @min(@as(usize, input_size), INPUT_CAP);
    const input = input_buf[0..size];
    const layout = computeLayout();
    const rows = countRows(input, layout);

    var out_idx: usize = 0;
    appendSlice(&out_idx, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"") catch return 0;
    appendInt(&out_idx, canvas_width) catch return 0;
    appendSlice(&out_idx, "\" height=\"") catch return 0;
    appendInt(&out_idx, canvas_height) catch return 0;
    appendSlice(&out_idx, "\" viewBox=\"0 0 ") catch return 0;
    appendInt(&out_idx, canvas_width) catch return 0;
    appendByte(&out_idx, ' ') catch return 0;
    appendInt(&out_idx, canvas_height) catch return 0;
    appendSlice(&out_idx, "\"><g fill=\"#000000\" stroke=\"none\">") catch return 0;

    var row: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    var prev_was_delim = true;
    var last_base_row: u32 = 0;
    var last_base_col: u32 = 0;
    var has_base = false;
    const fallback_idx = glyphIndexForCodepoint('?').?;

    while (i < input.len and row < rows and row < layout.max_rows) {
        const c = input[i];
        if (c == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
            row += 1;
            col = 0;
            i += 1;
            prev_was_delim = true;
            has_base = false;
            continue;
        }
        if (c == '\n') {
            row += 1;
            col = 0;
            i += 1;
            prev_was_delim = true;
            has_base = false;
            continue;
        }
        if (c == '\t') {
            const spaces: u32 = 4 - (col % 4);
            var s: u32 = 0;
            while (s < spaces and row < rows and row < layout.max_rows) : (s += 1) {
                col += 1;
                if (col >= layout.max_cols) {
                    row += 1;
                    col = 0;
                }
            }
            i += 1;
            prev_was_delim = true;
            has_base = false;
            continue;
        }

        const glyph_start = i;
        const cp = decodeUtf8One(input, &i);
        const combining = isCombiningMark(cp);
        if (!combining and prev_was_delim and c != ' ' and col > 0) {
            const word_cols = measureWordCols(input, glyph_start, layout.max_cols);
            if (word_cols <= layout.max_cols and col + word_cols > layout.max_cols) {
                row += 1;
                col = 0;
                if (row >= rows or row >= layout.max_rows) break;
            }
        }

        const glyph_idx = glyphIndexForCodepoint(cp) orelse fallback_idx;
        const path_d = font.glyph_paths[glyph_idx];
        if (path_d.len > 0) {
            if (combining and !has_base) continue;
            const draw_col = if (combining) last_base_col else col;
            const draw_row = if (combining) last_base_row else row;
            const x = PADDING_X + @as(f32, @floatFromInt(draw_col)) * layout.advance;
            const y = PADDING_Y + layout.baseline + @as(f32, @floatFromInt(draw_row)) * layout.row_h;
            appendSlice(&out_idx, "<path d=\"") catch return 0;
            appendSlice(&out_idx, path_d) catch return 0;
            appendSlice(&out_idx, "\" transform=\"translate(") catch return 0;
            appendFloat(&out_idx, x) catch return 0;
            appendByte(&out_idx, ' ') catch return 0;
            appendFloat(&out_idx, y) catch return 0;
            appendSlice(&out_idx, ") scale(") catch return 0;
            appendFloat(&out_idx, layout.scale) catch return 0;
            appendSlice(&out_idx, ")\"/>") catch return 0;
        }

        if (combining) continue;
        last_base_row = row;
        last_base_col = col;
        has_base = true;
        col += 1;
        if (col >= layout.max_cols) {
            row += 1;
            col = 0;
        }
        prev_was_delim = (c == ' ');
    }

    appendSlice(&out_idx, "</g></svg>") catch return 0;
    return @intCast(out_idx);
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

test "uses native font metrics for size-independent tracking" {
    font_size_px = 56.0;
    const at_base_size = computeLayout();
    try std.testing.expectApproxEqAbs(@as(f32, 1233.0 / 2048.0 * 56.0), at_base_size.advance, 0.0001);

    font_size_px = 1024.0;
    const at_large_size = computeLayout();
    try std.testing.expectApproxEqAbs(at_base_size.advance * (1024.0 / 56.0), at_large_size.advance, 0.001);
    font_size_px = DEFAULT_FONT_SIZE;
}

test "supports terminal diagram glyph path lookup" {
    try std.testing.expect(glyphIndexForCodepoint('A') != null);
    try std.testing.expect(glyphIndexForCodepoint(0x00E9) != null); // é
    try std.testing.expect(glyphIndexForCodepoint(0x010D) != null); // č
    try std.testing.expect(glyphIndexForCodepoint(0x03A9) != null); // Ω
    try std.testing.expect(glyphIndexForCodepoint(0x0416) != null); // Ж
    try std.testing.expect(glyphIndexForCodepoint(0x1EA1) != null); // ạ
    try std.testing.expect(glyphIndexForCodepoint(0x2070) != null); // ⁰
    try std.testing.expect(glyphIndexForCodepoint(0x2081) != null); // ₁
    try std.testing.expect(glyphIndexForCodepoint(0x2153) != null); // ⅓
    try std.testing.expect(glyphIndexForCodepoint(0x2014) != null); // —
    try std.testing.expect(glyphIndexForCodepoint(0x20AC) != null); // €
    try std.testing.expect(glyphIndexForCodepoint(0x250C) != null); // ┌
    try std.testing.expect(glyphIndexForCodepoint(0x2500) != null); // ─
    try std.testing.expect(glyphIndexForCodepoint(0x2192) != null); // →
    try std.testing.expect(glyphIndexForCodepoint(0x21AF) != null); // ↯
    try std.testing.expect(glyphIndexForCodepoint(0x25E7) != null); // ◧
    try std.testing.expect(glyphIndexForCodepoint(0x29D7) != null); // ⧗
    try std.testing.expect(glyphIndexForCodepoint(0x2200) != null); // ∀
    try std.testing.expect(glyphIndexForCodepoint(0x2318) != null); // ⌘
    try std.testing.expect(glyphIndexForCodepoint(0x2605) != null); // ★
    try std.testing.expect(glyphIndexForCodepoint(0x2713) != null); // ✓
    try std.testing.expect(glyphIndexForCodepoint(0x27F6) != null); // ⟶
    try std.testing.expect(glyphIndexForCodepoint(0x2A2F) != null); // ⨯
    try std.testing.expect(glyphIndexForCodepoint(0x1F642) == null); // 🙂
}

test "combining marks share their base glyph transform" {
    const input = "A\xCC\x81"; // A + combining acute accent
    @memcpy(input_buf[0..input.len], input);
    const output_size = renderImpl(input.len);
    const svg = output_buf[0..output_size];
    const marker = "transform=\"";
    const first_marker = std.mem.indexOf(u8, svg, marker).?;
    const first_start = first_marker + marker.len;
    const first_end = first_start + std.mem.indexOf(u8, svg[first_start..], "\"/>").?;
    const second_marker = first_end + std.mem.indexOf(u8, svg[first_end..], marker).?;
    const second_start = second_marker + marker.len;
    const second_end = second_start + std.mem.indexOf(u8, svg[second_start..], "\"/>").?;
    try std.testing.expectEqualStrings(svg[first_start..first_end], svg[second_start..second_end]);
}
