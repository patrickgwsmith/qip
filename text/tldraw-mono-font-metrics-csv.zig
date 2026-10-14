//! Measure UTF-8 text with tldraw's `mono` font.
//!
//! This first pass uses IBM Plex Mono Medium glyph advances, bounding boxes,
//! and generated browser-default shaping data from the font program. It is
//! still a font-specific subset, not a full shaper.

const std = @import("std");
const font_metrics = @import("lib/tldraw_mono_ibm_plex_mono_medium_metrics.zig");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const MAX_CODEPOINTS: usize = 8192;
const MAX_LINES: usize = 1024;
const DEFAULT_FONT_SIZE: f64 = 24;
const DEFAULT_MEASURE: f64 = 0;
const DEFAULT_LINE_HEIGHT: f64 = 0;
const DEFAULT_LEADING: f64 = 0;
const TLDRAW_AUTOSIZE_WIDTH_PADDING: f64 = 1;
const INPUT_CONTENT_TYPE = "text/plain";
const OUTPUT_CONTENT_TYPE = "text/csv";

const Error = error{
    InvalidUtf8,
    UnsupportedCodepoint,
    TooManyCodepoints,
    TooManyLines,
    TextDoesNotFit,
    OutputOverflow,
};

const Glyph = struct {
    codepoint: u32,
    variant: u8,
    advance_x: i32,
    pair_codepoint: u32,
    hidden: bool,
    start_byte: usize,
    end_byte: usize,
    metrics: font_metrics.GlyphMetrics,
};

const Line = struct {
    start_glyph: usize,
    end_glyph: usize,
    start_byte: usize,
    end_byte: usize,
    width_units: i32,
    x_min_units: i32,
    y_min_units: i32,
    x_max_units: i32,
    y_max_units: i32,
};

const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    fn write(self: *Writer, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.index) return error.OutputOverflow;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    fn integer(self: *Writer, value: anytype) Error!void {
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.write(text);
    }

    fn coordinate(self: *Writer, input: f64) Error!void {
        const value = if (@abs(input) < 0.0000001) @as(f64, 0) else input;
        var buffer: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.write(text);
    }
};

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var glyphs: [MAX_CODEPOINTS]Glyph = undefined;
var lines: [MAX_LINES]Line = undefined;
var font_size: f64 = DEFAULT_FONT_SIZE;
var measure: f64 = DEFAULT_MEASURE;
var line_height: f64 = DEFAULT_LINE_HEIGHT;
var leading: f64 = DEFAULT_LEADING;

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

export fn uniform_set_font_size(value: f64) f64 {
    font_size = if (std.math.isFinite(value)) @max(0.0, value) else DEFAULT_FONT_SIZE;
    return font_size;
}

export fn uniform_set_measure(value: f64) f64 {
    measure = if (std.math.isFinite(value)) @max(0.0, value) else DEFAULT_MEASURE;
    return measure;
}

export fn uniform_set_line_height(value: f64) f64 {
    line_height = if (std.math.isFinite(value)) @max(0.0, value) else DEFAULT_LINE_HEIGHT;
    return line_height;
}

export fn uniform_set_leading(value: f64) f64 {
    leading = if (std.math.isFinite(value)) @max(0.0, value) else DEFAULT_LEADING;
    return leading;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > input_buf.len) @trap();
    const output_size = renderMetrics(input_buf[0..input_size], &output_buf) catch @trap();
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
    font_size = DEFAULT_FONT_SIZE;
    measure = DEFAULT_MEASURE;
    line_height = DEFAULT_LINE_HEIGHT;
    leading = DEFAULT_LEADING;
}

fn renderMetrics(input: []const u8, output: []u8) Error!usize {
    const glyph_count = try decodeGlyphs(input);
    shapeGlyphs(glyph_count);
    applyLigatures(glyph_count);
    const line_count = try layoutLines(glyph_count);

    var out = Writer{ .bytes = output };
    try out.write("line_index,start_byte,end_byte,text,codepoints,glyphs,width,advance_x,baseline_y,line_top,line_bottom,ascender,descender,line_gap,line_height,x_min,y_min,x_max,y_max,units_per_em,font_size,measure\n");

    const natural_line_height = scale(font_metrics.ASCENDER - font_metrics.DESCENDER + font_metrics.LINE_GAP);
    const used_line_height = (if (line_height > 0) line_height else natural_line_height) + leading;
    const ascender = scale(font_metrics.ASCENDER);
    const descender_depth = scale(-font_metrics.DESCENDER);
    const line_gap = scale(font_metrics.LINE_GAP);

    for (lines[0..line_count], 0..) |line, line_index| {
        const baseline = ascender + used_line_height * @as(f64, @floatFromInt(line_index));
        try out.integer(line_index);
        try out.write(",");
        try out.integer(line.start_byte);
        try out.write(",");
        try out.integer(line.end_byte);
        try out.write(",\"");
        try writeCsvEscaped(&out, input[line.start_byte..line.end_byte]);
        try out.write("\",");
        try out.integer(line.end_glyph - line.start_glyph);
        try out.write(",");
        try out.integer(line.end_glyph - line.start_glyph);
        try out.write(",");
        try out.coordinate(scale(line.width_units) + lineWidthPadding(line));
        try out.write(",");
        try outScaled(&out, line.width_units);
        try out.write(",");
        try out.coordinate(baseline);
        try out.write(",");
        try out.coordinate(baseline - ascender);
        try out.write(",");
        try out.coordinate(baseline + descender_depth);
        try out.write(",");
        try out.coordinate(ascender);
        try out.write(",");
        try out.coordinate(descender_depth);
        try out.write(",");
        try out.coordinate(line_gap);
        try out.write(",");
        try out.coordinate(used_line_height);
        try out.write(",");
        try outScaled(&out, line.x_min_units);
        try out.write(",");
        try out.coordinate(baseline - scale(line.y_max_units));
        try out.write(",");
        try outScaled(&out, line.x_max_units);
        try out.write(",");
        try out.coordinate(baseline - scale(line.y_min_units));
        try out.write(",");
        try out.integer(font_metrics.UNITS_PER_EM);
        try out.write(",");
        try out.coordinate(font_size);
        try out.write(",");
        try out.coordinate(measure);
        try out.write("\n");
    }
    return out.index;
}

fn decodeGlyphs(input: []const u8) Error!usize {
    var input_index: usize = 0;
    var glyph_count: usize = 0;
    while (input_index < input.len) {
        if (glyph_count == glyphs.len) return error.TooManyCodepoints;
        const start = input_index;
        const codepoint = try decodeUtf8(input, &input_index);
        if (codepoint == '\r') continue;
        if (codepoint == '\n') {
            glyphs[glyph_count] = .{
                .codepoint = codepoint,
                .variant = 0,
                .advance_x = 0,
                .pair_codepoint = codepoint,
                .hidden = false,
                .start_byte = start,
                .end_byte = input_index,
                .metrics = emptyMetrics(),
            };
        } else {
            const metrics = font_metrics.glyphMetrics(codepoint, 0) orelse return error.UnsupportedCodepoint;
            glyphs[glyph_count] = .{
                .codepoint = codepoint,
                .variant = 0,
                .advance_x = metrics.advance_x,
                .pair_codepoint = codepoint,
                .hidden = false,
                .start_byte = start,
                .end_byte = input_index,
                .metrics = metrics,
            };
        }
        glyph_count += 1;
    }
    return glyph_count;
}

fn shapeGlyphs(glyph_count: usize) void {
    for (glyphs[0..glyph_count], 0..) |*glyph, index| {
        if (glyph.codepoint == '\n') continue;
        const variant = contextualVariant(index);
        if (variant == glyph.variant) continue;
        if (font_metrics.glyphMetrics(glyph.codepoint, variant)) |metrics| {
            glyph.variant = variant;
            glyph.metrics = metrics;
            glyph.advance_x = metrics.advance_x;
            glyph.pair_codepoint = glyph.codepoint;
        }
    }
}

fn contextualVariant(index: usize) u8 {
    for (font_metrics.context_rules) |rule| {
        if (!font_metrics.coverageContains(rule.input_coverage, glyphs[index].codepoint, glyphs[index].variant)) continue;
        if (!backtrackMatches(index, rule)) continue;
        return rule.result_variant;
    }
    return glyphs[index].variant;
}

fn backtrackMatches(index: usize, rule: font_metrics.ContextRule) bool {
    if (rule.backtrack_len > index) return false;
    if (rule.backtrack_len >= 1 and !backtrackCoverageMatches(index, 1, rule.backtrack_0)) return false;
    if (rule.backtrack_len >= 2 and !backtrackCoverageMatches(index, 2, rule.backtrack_1)) return false;
    if (rule.backtrack_len >= 3 and !backtrackCoverageMatches(index, 3, rule.backtrack_2)) return false;
    return true;
}

fn backtrackCoverageMatches(index: usize, distance: usize, coverage: u16) bool {
    const glyph = glyphs[index - distance];
    if (glyph.codepoint == '\n') return false;
    return font_metrics.coverageContains(coverage, glyph.codepoint, glyph.variant);
}

fn applyLigatures(glyph_count: usize) void {
    var index: usize = 0;
    while (index < glyph_count) {
        defer index += 1;
        if (glyphs[index].codepoint == '\n') continue;
        if (glyphs[index].hidden) continue;
        for (font_metrics.ligature_rules, 0..) |rule, rule_index| {
            const span = font_metrics.ligature_spans[rule.span];
            if (index + span.len > glyph_count) continue;
            if (containsNewline(index, span.len)) continue;
            if (containsHidden(index, span.len)) continue;
            if (!ligatureMatchesAt(rule_index, index, span.len)) continue;
            glyphs[index].advance_x = rule.advance_x;
            glyphs[index].pair_codepoint = rule.pair_codepoint;
            glyphs[index].variant = 0;
            if (span.len > 1) {
                var hidden_index = index + 1;
                while (hidden_index < index + span.len) : (hidden_index += 1) {
                    glyphs[hidden_index].advance_x = 0;
                    glyphs[hidden_index].hidden = true;
                }
            }
            index += span.len - 1;
            break;
        }
    }
}

fn containsNewline(start: usize, len: usize) bool {
    var index = start;
    while (index < start + len) : (index += 1) {
        if (glyphs[index].codepoint == '\n') return true;
    }
    return false;
}

fn containsHidden(start: usize, len: usize) bool {
    var index = start;
    while (index < start + len) : (index += 1) {
        if (glyphs[index].hidden) return true;
    }
    return false;
}

fn ligatureMatchesAt(rule_index: usize, start: usize, len: usize) bool {
    var codepoints: [64]u32 = undefined;
    if (len > codepoints.len) return false;
    for (codepoints[0..len], 0..) |*codepoint, offset| {
        codepoint.* = glyphs[start + offset].codepoint;
    }
    return font_metrics.ligatureMatches(rule_index, codepoints[0..len]);
}

fn layoutLines(glyph_count: usize) Error!usize {
    const max_width_units = if (measure > 0 and font_size > 0)
        @as(i32, @intFromFloat(@floor(measure * @as(f64, @floatFromInt(font_metrics.UNITS_PER_EM)) / font_size)))
    else
        std.math.maxInt(i32);

    var line_count: usize = 0;
    var start: usize = 0;
    while (start <= glyph_count) {
        if (line_count == lines.len) return error.TooManyLines;
        const line = try nextLine(start, glyph_count, max_width_units);
        lines[line_count] = line;
        line_count += 1;
        start = line.end_glyph;
        if (start < glyph_count and glyphs[start].codepoint == '\n') {
            start += 1;
            if (start == glyph_count) {
                if (line_count == lines.len) return error.TooManyLines;
                lines[line_count] = emptyLine(glyph_count, glyph_count);
                line_count += 1;
                break;
            }
        } else if (start >= glyph_count) {
            break;
        }
    }
    return line_count;
}

fn nextLine(start: usize, glyph_count: usize, max_width_units: i32) Error!Line {
    var index = start;
    var width: i32 = 0;
    var last_space: ?usize = null;
    while (index < glyph_count and glyphs[index].codepoint != '\n') {
        var next_width = width + glyphs[index].advance_x;
        if (index > start) next_width += pairAdjustment(index - 1, index);
        if (next_width > max_width_units) {
            if (index == start) return error.TextDoesNotFit;
            if (last_space) |space_index| {
                return buildLine(start, space_index, false);
            }
            return buildLine(start, index, false);
        }
        width = next_width;
        if (glyphs[index].codepoint == ' ' or glyphs[index].codepoint == '\t') last_space = index + 1;
        index += 1;
    }
    return buildLine(start, index, true);
}

fn buildLine(start: usize, end: usize, allow_empty: bool) Error!Line {
    if (end <= start) {
        if (!allow_empty) return error.TextDoesNotFit;
        return emptyLine(start, end);
    }
    var width: i32 = 0;
    var x_min: i32 = std.math.maxInt(i32);
    var y_min: i32 = std.math.maxInt(i32);
    var x_max: i32 = std.math.minInt(i32);
    var y_max: i32 = std.math.minInt(i32);
    var index = start;
    while (index < end) : (index += 1) {
        if (index > start) width += pairAdjustment(index - 1, index);
        const glyph = glyphs[index];
        const metrics = glyph.metrics;
        if (!glyph.hidden) {
            x_min = @min(x_min, width + metrics.x_min);
            y_min = @min(y_min, metrics.y_min);
            x_max = @max(x_max, width + metrics.x_max);
            y_max = @max(y_max, metrics.y_max);
        }
        width += glyph.advance_x;
    }
    return .{
        .start_glyph = start,
        .end_glyph = end,
        .start_byte = glyphs[start].start_byte,
        .end_byte = glyphs[end - 1].end_byte,
        .width_units = width,
        .x_min_units = x_min,
        .y_min_units = y_min,
        .x_max_units = x_max,
        .y_max_units = y_max,
    };
}

fn emptyLine(start: usize, end: usize) Line {
    const byte = if (start > 0) glyphs[start - 1].end_byte else 0;
    return .{
        .start_glyph = start,
        .end_glyph = end,
        .start_byte = byte,
        .end_byte = byte,
        .width_units = 0,
        .x_min_units = 0,
        .y_min_units = 0,
        .x_max_units = 0,
        .y_max_units = 0,
    };
}

fn emptyMetrics() font_metrics.GlyphMetrics {
    return .{
        .codepoint = 0,
        .variant = 0,
        .advance_x = 0,
        .left_side_bearing = 0,
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
    };
}

fn scale(value: anytype) f64 {
    return @as(f64, @floatFromInt(value)) * font_size / @as(f64, @floatFromInt(font_metrics.UNITS_PER_EM));
}

fn pairAdjustment(left_index: usize, right_index: usize) i32 {
    if (glyphs[right_index].hidden) return 0;
    var visible_left = left_index;
    while (glyphs[visible_left].hidden) {
        if (visible_left == 0) return 0;
        visible_left -= 1;
    }
    return font_metrics.pairAdvanceX(
        glyphs[visible_left].pair_codepoint,
        glyphs[visible_left].variant,
        glyphs[right_index].pair_codepoint,
        glyphs[right_index].variant,
    );
}

fn outScaled(out: *Writer, value: anytype) Error!void {
    try out.coordinate(scale(value));
}

fn lineWidthPadding(line: Line) f64 {
    return if (line.end_glyph > line.start_glyph) TLDRAW_AUTOSIZE_WIDTH_PADDING else 0;
}

fn writeCsvEscaped(out: *Writer, value: []const u8) Error!void {
    for (value, 0..) |byte, index| {
        if (byte == '"') {
            try out.write("\"\"");
        } else {
            try out.write(value[index..][0..1]);
        }
    }
}

fn decodeUtf8(input: []const u8, index: *usize) Error!u32 {
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

test "measures one explicit line" {
    const output_size = try renderMetrics("Hello", &output_buf);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..output_size], "0,0,5,\"Hello\",5,5,") != null);
}
