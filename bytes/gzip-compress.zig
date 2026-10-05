//! gzip (RFC 1952) compression: one member with MTIME 0 and no file name,
//! so the same input always gives the same bytes. The DEFLATE payload uses
//! the shared engine in lib/deflate.zig in 1 MiB batches; each batch is a
//! stored, fixed-Huffman, or dynamic-Huffman block.

const std = @import("std");
const deflate = @import("lib/deflate.zig");
const gzip = @import("lib/gzip.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
// Match history resets at each batch, so a larger batch compresses slightly
// better but needs four token bytes for every input byte in the batch.
const BATCH_BYTES: usize = 1024 * 1024;
const BATCH_COUNT: usize = (INPUT_CAP + BATCH_BYTES - 1) / BATCH_BYTES;

// Each batch is bounded by its dynamic-Huffman cost, which is larger than
// its stored or fixed-Huffman cost. A literal costs at most 15 bits. A match
// costs at most 48 bits and consumes at least 3 input bytes. Each code-length
// RLE entry costs at most a 7-bit code plus 7 extra bits.
const MIN_MATCH: usize = 3;
const MAX_LITERAL_BITS: usize = 15;
const MAX_MATCH_BITS: usize = 48;
const MAX_BATCH_TOKEN_BITS: usize =
    (BATCH_BYTES / MIN_MATCH) * MAX_MATCH_BITS + (BATCH_BYTES % MIN_MATCH) * MAX_LITERAL_BITS;
const CL_CODE_COUNT: usize = 19;
const MAX_CODELEN_RLE: usize = (286 + 30) * 2 + 32;
const DYNAMIC_BLOCK_OVERHEAD_BITS: usize =
    3 + 5 + 5 + 4 + CL_CODE_COUNT * 3 + MAX_CODELEN_RLE * (7 + 7) + 15;
const GZIP_WRAPPER_BYTES: usize = gzip.HEADER_SIZE + gzip.TRAILER_SIZE;
const OUTPUT_CAP: usize = GZIP_WRAPPER_BYTES +
    (BATCH_COUNT * (MAX_BATCH_TOKEN_BITS + DYNAMIC_BLOCK_OVERHEAD_BITS) + 7) / 8;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var token_buf: [BATCH_BYTES]u32 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(gzip.CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(gzip.CONTENT_TYPE.len));
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    gzip.writeHeader(&output_buf);
    const payload = output_buf[gzip.HEADER_SIZE .. OUTPUT_CAP - gzip.TRAILER_SIZE];
    const raw_size = deflate.compressRawBlocksWithOptions(input, payload, &token_buf, .{}) orelse @trap();
    const trailer = gzip.HEADER_SIZE + raw_size;
    gzip.writeTrailer(output_buf[trailer..], input);
    return @as(u32, @intCast(trailer + gzip.TRAILER_SIZE));
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

fn decompressGzip(compressed: []const u8, out: []u8) !usize {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out_writer: std.Io.Writer = .fixed(out);

    const n = try decompress.reader.streamRemaining(&out_writer);

    var trailing: [1]u8 = undefined;
    if (try in.readSliceShort(&trailing) != 0) return error.TrailingBytes;
    return n;
}

test "writes a deterministic header" {
    const written = renderImpl(0);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff },
        output_buf[0..gzip.HEADER_SIZE],
    );

    var out: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try decompressGzip(output_buf[0..written], &out));
}

test "round trips short text" {
    const plain = "qip + gzip";
    @memcpy(input_buf[0..plain.len], plain);
    const written = renderImpl(@intCast(plain.len));

    var out: [64]u8 = undefined;
    const n = try decompressGzip(output_buf[0..written], &out);
    try std.testing.expectEqualStrings(plain, out[0..n]);
}

test "round trips across batches" {
    const len = BATCH_BYTES + 70000;
    for (input_buf[0..len], 0..) |*b, i| b.* = @truncate((i * 7) ^ (i >> 9));
    const written = renderImpl(len);

    const out = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(len, try decompressGzip(output_buf[0..written], out));
    try std.testing.expectEqualSlices(u8, input_buf[0..len], out);
}

test "maximum input stays within the derived output capacity" {
    @memset(input_buf[0..], 0);
    const written = renderImpl(@intCast(INPUT_CAP));
    try std.testing.expect(written <= OUTPUT_CAP);
}
