const std = @import("std");

const INPUT_CAP: u32 = 4 * 1024 * 1024;
// Recoloring cannot expand the input: every replaced 12-byte `currentColor`
// token becomes a seven- or nine-byte CSS hex color, and all other bytes are
// copied once.
const OUTPUT_CAP: u32 = INPUT_CAP;
const CONTENT_TYPE = "image/svg+xml";
const DEFAULT_COLOR_RGBA: u32 = 0x000000FF; // 0xRRGGBBAA

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var color_rgba: u32 = DEFAULT_COLOR_RGBA;
var color_css_buf: [9]u8 = [_]u8{ '#', '0', '0', '0', '0', '0', '0', 0, 0 };
var color_css_len: usize = 7;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(CONTENT_TYPE.len));
}

// Uniform accepts packed RGBA as 0xRRGGBBAA.
// Wasm i32 is interpreted as raw bits, so qip can pass full u32 via 0x-prefixed hex.
export fn uniform_set_color_rgba(value: u32) u32 {
    color_rgba = value;
    color_css_len = formatColorHex(color_rgba, &color_css_buf);
    return color_rgba;
}

fn resetColorUniform() void {
    color_rgba = DEFAULT_COLOR_RGBA;
    color_css_len = formatColorHex(color_rgba, &color_css_buf);
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

fn isASCIIWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn startsWithWordIgnoreCase(input: []const u8, start: usize, word: []const u8) bool {
    if (start + word.len > input.len) return false;
    if (start > 0 and isIdentChar(input[start - 1])) return false;
    for (word, 0..) |c, i| {
        if (asciiLower(input[start + i]) != asciiLower(c)) return false;
    }
    const after = start + word.len;
    if (after < input.len and isIdentChar(input[after])) return false;
    return true;
}

fn trimASCII(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isASCIIWhitespace(s[start])) : (start += 1) {}
    while (end > start and isASCIIWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn appendByte(output: []u8, out_idx: *usize, byte: u8) !void {
    if (out_idx.* >= output.len) return error.OutputOverflow;
    output[out_idx.*] = byte;
    out_idx.* += 1;
}

fn appendSlice(output: []u8, out_idx: *usize, slice: []const u8) !void {
    if (out_idx.* + slice.len > output.len) return error.OutputOverflow;
    @memcpy(output[out_idx.* .. out_idx.* + slice.len], slice);
    out_idx.* += slice.len;
}

fn replacePropertyValue(
    input: []const u8,
    start: usize,
    key: []const u8,
    replacement: []const u8,
    output: []u8,
    out_idx: *usize,
) !?usize {
    if (!startsWithWordIgnoreCase(input, start, key)) return null;

    var i = start + key.len;
    while (i < input.len and isASCIIWhitespace(input[i])) : (i += 1) {}
    if (i >= input.len) return null;

    const separator = input[i];
    if (separator != '=' and separator != ':') return null;
    i += 1;

    while (i < input.len and isASCIIWhitespace(input[i])) : (i += 1) {}
    if (i >= input.len) return null;

    if (separator == '=') {
        const quote = input[i];
        if (quote == '\'' or quote == '"') {
            const value_start = i + 1;
            var value_end = value_start;
            while (value_end < input.len and input[value_end] != quote) : (value_end += 1) {}
            if (value_end >= input.len) return null;
            if (!eqlIgnoreCase(trimASCII(input[value_start..value_end]), "currentColor")) return null;

            try appendSlice(output, out_idx, input[start..value_start]);
            try appendSlice(output, out_idx, replacement);
            try appendByte(output, out_idx, quote);
            return value_end + 1;
        }

        const value_start = i;
        var value_end = value_start;
        while (value_end < input.len) : (value_end += 1) {
            const ch = input[value_end];
            if (isASCIIWhitespace(ch) or ch == '/' or ch == '>') break;
        }
        if (value_end == value_start) return null;
        if (!eqlIgnoreCase(trimASCII(input[value_start..value_end]), "currentColor")) return null;

        try appendSlice(output, out_idx, input[start..value_start]);
        try appendSlice(output, out_idx, replacement);
        return value_end;
    }

    const value_start = i;
    var value_end = value_start;
    while (value_end < input.len) : (value_end += 1) {
        const ch = input[value_end];
        if (ch == ';' or ch == '}' or ch == '\n' or ch == '\r' or ch == '"' or ch == '\'') break;
    }

    var token_end = value_start;
    while (token_end < value_end) : (token_end += 1) {
        const ch = input[token_end];
        if (isASCIIWhitespace(ch) or ch == '!') break;
    }
    if (token_end == value_start) return null;
    if (!eqlIgnoreCase(input[value_start..token_end], "currentColor")) return null;

    try appendSlice(output, out_idx, input[start..value_start]);
    try appendSlice(output, out_idx, replacement);
    try appendSlice(output, out_idx, input[token_end..value_end]);
    return value_end;
}

fn recolorSVGCurrentColor(input: []const u8, output: []u8, replacement: []const u8) !usize {
    var i: usize = 0;
    var out: usize = 0;

    while (i < input.len) {
        if (try replacePropertyValue(input, i, "fill", replacement, output, &out)) |next| {
            i = next;
            continue;
        }
        if (try replacePropertyValue(input, i, "stroke", replacement, output, &out)) |next| {
            i = next;
            continue;
        }
        try appendByte(output, &out, input[i]);
        i += 1;
    }

    return out;
}

fn hexNibble(n: u8) u8 {
    return if (n < 10) ('0' + n) else ('a' + (n - 10));
}

fn writeHexByte(dst: []u8, byte: u8) void {
    dst[0] = hexNibble((byte >> 4) & 0x0F);
    dst[1] = hexNibble(byte & 0x0F);
}

fn formatColorHex(rgba: u32, out: *[9]u8) usize {
    const r: u8 = @as(u8, @intCast((rgba >> 24) & 0xFF));
    const g: u8 = @as(u8, @intCast((rgba >> 16) & 0xFF));
    const b: u8 = @as(u8, @intCast((rgba >> 8) & 0xFF));
    const a: u8 = @as(u8, @intCast(rgba & 0xFF));

    out[0] = '#';
    writeHexByte(out[1..3], r);
    writeHexByte(out[3..5], g);
    writeHexByte(out[5..7], b);
    if (a == 0xFF) return 7;
    writeHexByte(out[7..9], a);
    return 9;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const replacement = color_css_buf[0..color_css_len];
    const out_len = recolorSVGCurrentColor(input_buf[0..input_size], output_buf[0..], replacement) catch @trap();
    resetColorUniform();
    return @as(u32, @intCast(out_len));
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "render resets the color uniform to opaque black" {
    const input = "<svg fill=\"currentColor\"/>";
    @memcpy(input_buf[0..input.len], input);

    _ = uniform_set_color_rgba(0xff0000ff);
    const red_len: usize = @intCast(renderImpl(input.len));
    try std.testing.expectEqualStrings("<svg fill=\"#ff0000\"/>", output_buf[0..red_len]);

    const default_len: usize = @intCast(renderImpl(input.len));
    try std.testing.expectEqualStrings("<svg fill=\"#000000\"/>", output_buf[0..default_len]);
}

test "replaces fill and stroke currentColor attributes" {
    const input =
        \\<svg><path fill="currentColor" stroke='currentColor' fill-opacity="0.5"/></svg>
    ;
    var out: [256]u8 = undefined;
    const out_len = try recolorSVGCurrentColor(input, out[0..], "#112233");
    try std.testing.expectEqualStrings(
        "<svg><path fill=\"#112233\" stroke='#112233' fill-opacity=\"0.5\"/></svg>",
        out[0..out_len],
    );
}

test "replaces currentColor in fill and stroke css declarations" {
    const input =
        \\<svg><g style="fill: currentColor; stroke:currentColor!important; color:currentColor"/></svg>
    ;
    var out: [256]u8 = undefined;
    const out_len = try recolorSVGCurrentColor(input, out[0..], "#abcdef80");
    try std.testing.expectEqualStrings(
        "<svg><g style=\"fill: #abcdef80; stroke:#abcdef80!important; color:currentColor\"/></svg>",
        out[0..out_len],
    );
}

test "ignores non-target names and non-currentColor values" {
    const input =
        \\<svg><path fill-opacity="currentColor" style="fill-opacity:currentColor;stroke:#fff"/></svg>
    ;
    var out: [256]u8 = undefined;
    const out_len = try recolorSVGCurrentColor(input, out[0..], "#334455");
    try std.testing.expectEqualStrings(input, out[0..out_len]);
}

test "formats packed rgba as css hex" {
    var buf: [9]u8 = undefined;
    const opaque_len = formatColorHex(0x112233FF, &buf);
    try std.testing.expectEqual(@as(usize, 7), opaque_len);
    try std.testing.expectEqualStrings("#112233", buf[0..opaque_len]);

    const alpha_len = formatColorHex(0x11223344, &buf);
    try std.testing.expectEqual(@as(usize, 9), alpha_len);
    try std.testing.expectEqualStrings("#11223344", buf[0..alpha_len]);
}
