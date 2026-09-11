//! zlib compression with one final dynamic-Huffman DEFLATE block, using the
//! shared engine in lib/deflate.zig.

const std = @import("std");
const deflate = @import("lib/deflate.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
// A literal costs at most 15 bits. A match costs at most 48 bits and consumes
// at least 3 input bytes. Matches have the higher cost per input byte, so the
// maximum uses as many three-byte matches as possible and charges any remainder
// as literals.
// The shared encoder has at most 664 code-length RLE entries; each costs at
// most a 7-bit code plus 7 extra bits.
const MIN_MATCH: usize = 3;
const MAX_LITERAL_BITS: usize = 15;
const MAX_MATCH_BITS: usize = 48;
const MAX_TOKEN_BITS: usize =
    (INPUT_CAP / MIN_MATCH) * MAX_MATCH_BITS + (INPUT_CAP % MIN_MATCH) * MAX_LITERAL_BITS;
const CL_CODE_COUNT: usize = 19;
const MAX_CODELEN_RLE: usize = (286 + 30) * 2 + 32;
const DYNAMIC_BLOCK_OVERHEAD_BITS: usize =
    3 + 5 + 5 + 4 + CL_CODE_COUNT * 3 + MAX_CODELEN_RLE * (7 + 7) + 15;
const ZLIB_WRAPPER_BYTES: usize = 2 + 4;
const OUTPUT_CAP: usize = ZLIB_WRAPPER_BYTES +
    (MAX_TOKEN_BITS + DYNAMIC_BLOCK_OVERHEAD_BITS + 7) / 8;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var token_buf: [INPUT_CAP]u32 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    const written = deflate.compressZlib(input, &output_buf, &token_buf) orelse @trap();
    return @as(u32, @intCast(written));
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

fn decompressZlib(compressed: []const u8, out: []u8) !usize {
    var in: std.Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var out_writer: std.Io.Writer = .fixed(out);

    const n = try decompress.reader.streamRemaining(&out_writer);

    var trailing: [1]u8 = undefined;
    if (try in.readSliceShort(&trailing) != 0) return error.TrailingBytes;
    return n;
}

test "round trips short text" {
    const plain = "dynamic huffman in qip";
    @memcpy(input_buf[0..plain.len], plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    // Verify dynamic block type: lower 3 bits should be BFINAL=1,BTYPE=10 => 0b101.
    try std.testing.expectEqual(@as(u8, 0b101), output_buf[2] & 0x07);

    var out: [128]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualStrings(plain, out[0..n]);
}

test "round trips empty input" {
    const written = renderImpl(0);
    try std.testing.expect(written > 0);

    var out: [1]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "round trips repetitive data" {
    var plain: [65536]u8 = undefined;
    for (&plain, 0..) |*b, i| {
        b.* = if ((i % 64) < 48) 'a' else 'b';
    }
    @memcpy(input_buf[0..plain.len], &plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [65536]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualSlices(u8, &plain, out[0..n]);
}

test "length and distance symbol tables match RFC 1951" {
    try std.testing.expectEqual(@as(u16, 257), deflate.encodeLength(3).symbol);
    try std.testing.expectEqual(@as(u16, 283), deflate.encodeLength(226).symbol);
    try std.testing.expectEqual(@as(u16, 284), deflate.encodeLength(227).symbol);
    try std.testing.expectEqual(@as(u16, 284), deflate.encodeLength(257).symbol);
    try std.testing.expectEqual(@as(u16, 285), deflate.encodeLength(258).symbol);
    try std.testing.expectEqual(@as(u8, 0), deflate.encodeLength(258).extra_bits);

    var d: usize = 1;
    while (d <= 32768) : (d += 1) {
        const e = deflate.encodeDistance(d);
        const base = deflate.DIST_BASE[e.symbol];
        try std.testing.expect(d >= base);
        try std.testing.expect(d - base < (@as(usize, 1) << @intCast(e.extra_bits)));
    }
}

test "round trips max-length matches" {
    const plain = [_]u8{'a'} ** 300;
    @memcpy(input_buf[0..plain.len], &plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [512]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualSlices(u8, &plain, out[0..n]);
}

test "maximum input stays within the derived output capacity" {
    @memset(input_buf[0..], 0);
    const written = renderImpl(@intCast(INPUT_CAP));
    try std.testing.expect(written > 0);
    try std.testing.expect(written <= OUTPUT_CAP);
}

test "shared dynamic code limits obey the output bound" {
    var max_length_extra: usize = 0;
    for (deflate.LENGTH_EXTRA) |extra| max_length_extra = @max(max_length_extra, extra);

    var max_distance_extra: usize = 0;
    for (deflate.DIST_EXTRA) |extra| max_distance_extra = @max(max_distance_extra, extra);

    const max_match_bits = 15 + max_length_extra + 15 + max_distance_extra;
    try std.testing.expect(15 <= MAX_LITERAL_BITS);
    try std.testing.expect(max_match_bits <= MAX_MATCH_BITS);
    try std.testing.expect(MAX_CODELEN_RLE >= (286 + 30) * 2);
}
