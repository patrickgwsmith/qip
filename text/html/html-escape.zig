const std = @import("std");

const INPUT_CAP: usize = 512 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

// The longest entity is 6 bytes and every byte is written as one 8-byte store,
// so a full input always fits with room for the store's spare bytes.
const MAX_ESCAPED_LEN: usize = "&quot;".len;
const STORE_SLACK: usize = 8;
comptime {
    std.debug.assert(INPUT_CAP * MAX_ESCAPED_LEN + STORE_SLACK <= OUTPUT_CAP);
}

// Each byte's output packed little-endian into a u64 (the byte itself when it
// is not escaped), and how many of those bytes to keep.
const escaped_word: [256]u64 = blk: {
    var table: [256]u64 = undefined;
    for (&table, 0..) |*word, b| word.* = b;
    table['&'] = std.mem.readInt(u40, "&amp;", .little);
    table['<'] = std.mem.readInt(u32, "&lt;", .little);
    table['>'] = std.mem.readInt(u32, "&gt;", .little);
    table['"'] = std.mem.readInt(u48, "&quot;", .little);
    table['\''] = std.mem.readInt(u40, "&#39;", .little);
    break :blk table;
};
const escaped_len: [256]u8 = blk: {
    var table = [_]u8{1} ** 256;
    table['&'] = "&amp;".len;
    table['<'] = "&lt;".len;
    table['>'] = "&gt;".len;
    table['"'] = "&quot;".len;
    table['\''] = "&#39;".len;
    break :blk table;
};

// Writes one byte's output without branching. The store may write up to 7
// bytes past the returned index; later bytes overwrite them.
inline fn writeEscapedByte(out: [*]u8, index: usize, b: u8) usize {
    std.mem.writeInt(u64, out[index..][0..8], escaped_word[b], .little);
    return index + escaped_len[b];
}

const ones: u64 = 0x0101010101010101;
const highs: u64 = 0x8080808080808080;

inline fn hasByte(word: u64, comptime b: u8) bool {
    const x = word ^ (ones * b);
    return ((x -% ones) & ~x & highs) != 0;
}

// & (0x26) and ' (0x27) differ only in bit 0, and < (0x3c) and > (0x3e) only
// in bit 1, so three compares find all five.
inline fn wordNeedsEscape(word: u64) bool {
    return hasByte(word | ones, 0x27) or hasByte(word | (ones * 2), 0x3e) or hasByte(word, '"');
}

fn escapeHtml(input: []const u8, out: []u8) usize {
    if (input.len * MAX_ESCAPED_LEN + STORE_SLACK > out.len) @trap();
    const dst = out.ptr;

    // Most 8-byte words of text and markup contain none of & < > " ', so
    // they are copied with one 64-bit store. Words that do are written byte
    // by byte from the entity table. This needs no SIMD, so the component
    // still translates with qip-component-to-c.
    var index: usize = 0;
    var i: usize = 0;
    while (i + 8 <= input.len) : (i += 8) {
        const word = std.mem.readInt(u64, input[i..][0..8], .little);
        if (!wordNeedsEscape(word)) {
            std.mem.writeInt(u64, dst[index..][0..8], word, .little);
            index += 8;
            continue;
        }
        inline for (0..8) |k| index = writeEscapedByte(dst, index, input[i + k]);
    }
    while (i < input.len) : (i += 1) index = writeEscapedByte(dst, index, input[i]);
    return index;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    return @as(u32, @intCast(escapeHtml(input_buf[0..input_size], output_buf[0..])));
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

pub const native_output_capacity: usize = OUTPUT_CAP;

pub fn nativeRender(input: []const u8, output: []u8) u32 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const output_size = renderImpl(@intCast(input.len));
    if (output_size > output.len) @trap();
    @memcpy(output[0..output_size], output_buf[0..output_size]);
    return output_size;
}

test "escapes text node and quoted attribute characters" {
    var out: [256]u8 = undefined;
    const len = escapeHtml("<input value=\"Tom & 'QIP'\">", out[0..]);
    try std.testing.expectEqualStrings("&lt;input value=&quot;Tom &amp; &#39;QIP&#39;&quot;&gt;", out[0..len]);
}

test "leaves ordinary text unchanged" {
    var out: [256]u8 = undefined;
    const len = escapeHtml("plain UTF-8 text", out[0..]);
    try std.testing.expectEqualStrings("plain UTF-8 text", out[0..len]);
}

fn referenceEscape(input: []const u8, out: []u8) usize {
    var index: usize = 0;
    for (input) |b| {
        const escaped: []const u8 = switch (b) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &[_]u8{b},
        };
        @memcpy(out[index..][0..escaped.len], escaped);
        index += escaped.len;
    }
    return index;
}

test "matches a scalar escape at every word position and tail length" {
    const specials = "&<>\"'";
    var input: [50]u8 = undefined;
    var out: [50 * MAX_ESCAPED_LEN + STORE_SLACK]u8 = undefined;
    var expected: [50 * MAX_ESCAPED_LEN]u8 = undefined;
    for (0..input.len + 1) |len| {
        for (0..len) |pos| {
            for (specials) |special| {
                for (input[0..len], 0..) |*b, k| b.* = 'a' + @as(u8, @intCast(k % 26));
                input[pos] = special;
                // A second escape in the same or the next word.
                if (len > 0) input[(pos * 7 + 3) % len] = '&';
                const got = escapeHtml(input[0..len], out[0..]);
                const want = referenceEscape(input[0..len], expected[0..]);
                try std.testing.expectEqualStrings(expected[0..want], out[0..got]);
            }
        }
    }
}

test "escapes words made only of special bytes" {
    var out: [32 * MAX_ESCAPED_LEN + STORE_SLACK]u8 = undefined;
    var expected: [32 * MAX_ESCAPED_LEN]u8 = undefined;
    const input = "<&>\"'<&>\"'<&>\"'<&>\"'<&>\"'<&>\"'<&";
    const got = escapeHtml(input, out[0..]);
    const want = referenceEscape(input, expected[0..]);
    try std.testing.expectEqualStrings(expected[0..want], out[0..got]);
}
