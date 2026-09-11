//! Extract Unicode-mapped TrueType glyph outlines into SVG `<path>` elements.
//!
//! Paths live in `<defs>` and have codepoint IDs such as `u-0041`. The
//! default range is U+0020 through U+00FF. Numeric uniforms may select a range
//! of at most 4,096 codepoints. Coordinates retain font units, use SVG's
//! Y-down convention, and place the baseline at zero.

const ttf = @import("lib/ttf.zig");
const path_output = @import("lib/path-output.zig");

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = 32 * 1024 * 1024;
const MAX_CODEPOINT_SPAN: u32 = 4_096;
const DEFAULT_FIRST_CODEPOINT: u32 = 0x20;
const DEFAULT_LAST_CODEPOINT: u32 = 0xff;
const INPUT_CONTENT_TYPE = "font/ttf";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var scratch: ttf.Scratch = undefined;
var first_codepoint: u32 = DEFAULT_FIRST_CODEPOINT;
var last_codepoint: u32 = DEFAULT_LAST_CODEPOINT;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
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

export fn uniform_set_first_codepoint(value: u32) u32 {
    first_codepoint = @min(value, 0x10ffff);
    return first_codepoint;
}

export fn uniform_set_last_codepoint(value: u32) u32 {
    last_codepoint = @min(value, 0x10ffff);
    return last_codepoint;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > input_buf.len) @trap();
    const output_size = renderFont(input_buf[0..input_size], &output_buf) catch @trap();
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
    first_codepoint = DEFAULT_FIRST_CODEPOINT;
    last_codepoint = DEFAULT_LAST_CODEPOINT;
}

fn renderFont(input: []const u8, output: []u8) ttf.Error!usize {
    if (last_codepoint < first_codepoint or last_codepoint - first_codepoint + 1 > MAX_CODEPOINT_SPAN) return error.InvalidTtf;
    const font = try ttf.Font.init(input);
    var out = path_output.Writer{ .bytes = output };
    try out.write("<svg xmlns=\"http://www.w3.org/2000/svg\" data-units-per-em=\"");
    try out.integer(font.units_per_em);
    try out.write("\" data-ascender=\"");
    try out.integer(-@as(i32, font.ascender));
    try out.write("\" data-descender=\"");
    try out.integer(-@as(i32, font.descender));
    try out.write("\" data-line-gap=\"");
    try out.integer(font.line_gap);
    try out.write("\"><defs>\n");

    var codepoint = first_codepoint;
    while (codepoint <= last_codepoint) : (codepoint += 1) {
        const glyph_id = (try font.glyphIndex(codepoint)) orelse {
            if (codepoint == last_codepoint) break;
            continue;
        };
        const metrics = try font.metrics(glyph_id);
        try out.write("<path id=\"u-");
        try out.codepointHex(codepoint);
        try out.write("\" data-codepoint=\"U+");
        try out.codepointHex(codepoint);
        try out.write("\" data-glyph-id=\"");
        try out.integer(glyph_id);
        try out.write("\" data-advance-x=\"");
        try out.integer(metrics.advance_x);
        try out.write("\" data-left-side-bearing=\"");
        try out.integer(metrics.left_side_bearing);
        try out.write("\" d=\"");
        var path = path_output.PathWriter{ .out = &out };
        try font.writeGlyphPath(glyph_id, &scratch, &path);
        try out.write("\"/>\n");
        if (codepoint == last_codepoint) break;
    }
    try out.write("</defs></svg>\n");
    return out.index;
}

test "rejects a range larger than the component limit" {
    first_codepoint = 0;
    last_codepoint = MAX_CODEPOINT_SPAN;
    var output: [256]u8 = undefined;
    try @import("std").testing.expectError(error.InvalidTtf, renderFont("", &output));
    resetUniforms();
}
