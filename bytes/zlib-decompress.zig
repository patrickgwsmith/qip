//! zlib decompression using the shared engine in lib/inflate.zig, which
//! validates the header FCHECK/FDICT bits, Huffman tree shapes, and the
//! Adler-32 trailer, and rejects trailing bytes for strict one-stream
//! semantics.

const std = @import("std");
const inflate = @import("lib/inflate.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
// TODO: Distinguish malformed input from output exhaustion and report useful
// input progress when the inflater exposes it.

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size_in: u32) RenderOutcome {
    if (input_size_in > INPUT_CAP) @trap();

    const input_size: usize = @intCast(input_size_in);
    const out_len = inflate.inflateZlib(input_buf[0..input_size], &output_buf) orelse {
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{ .output_size_or_failure = @intCast(out_len), .output_ptr = @intFromPtr(&output_buf), .failed = 0 };
}

export fn render(input_size_in: u32) RenderResult {
    const result = renderOutcome(input_size_in);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}

test "decompresses valid zlib bytes" {
    const compressed = [_]u8{
        0x78, 0x9c, 0x01, 0x0c, 0x00, 0xf3, 0xff,
        'H',  'e',  'l',  'l',  'o',  ' ',  'w',
        'o',  'r',  'l',  'd',  '\n', 0x1c, 0xf2,
        0x04, 0x47,
    };

    @memcpy(input_buf[0..compressed.len], &compressed);
    const result = renderOutcome(@intCast(compressed.len));

    try std.testing.expectEqual(@as(u1, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 12), result.output_size_or_failure);
    try std.testing.expectEqualStrings("Hello world\n", output_buf[0..result.output_size_or_failure]);
}

test "accepts a valid empty stream" {
    const compressed = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    @memcpy(input_buf[0..compressed.len], &compressed);
    const result = renderOutcome(compressed.len);
    try std.testing.expectEqual(@as(u1, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 0), result.output_size_or_failure);
}

test "rejects trailing bytes" {
    const compressed_with_trailing = [_]u8{
        0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    };

    @memcpy(input_buf[0..compressed_with_trailing.len], &compressed_with_trailing);
    try std.testing.expectEqual(@as(u1, 1), renderOutcome(@intCast(compressed_with_trailing.len)).failed);
}

test "rejects invalid header and recovers" {
    const bad = [_]u8{ 0x78, 0x00, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(input_buf[0..bad.len], &bad);
    try std.testing.expectEqual(@as(u1, 1), renderOutcome(@intCast(bad.len)).failed);

    const empty = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    @memcpy(input_buf[0..empty.len], &empty);
    try std.testing.expectEqual(@as(u1, 0), renderOutcome(empty.len).failed);
}

test "rejects corrupted Adler-32 trailer" {
    const compressed = [_]u8{
        0x78, 0x9c, 0x01, 0x0c, 0x00, 0xf3, 0xff,
        'H',  'e',  'l',  'l',  'o',  ' ',  'w',
        'o',  'r',  'l',  'd',  '\n',
        0x1c, 0xf2, 0x04, 0x48, // last byte off by one
    };
    @memcpy(input_buf[0..compressed.len], &compressed);
    try std.testing.expectEqual(@as(u1, 1), renderOutcome(@intCast(compressed.len)).failed);
}

test "rejects FDICT preset dictionary streams" {
    // CMF 0x78, FLG 0x20 (FDICT set): 0x7820 % 31 == 0 so the header
    // passes the mod-31 check and rejection is down to the FDICT bit.
    const bad = [_]u8{ 0x78, 0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(input_buf[0..bad.len], &bad);
    try std.testing.expectEqual(@as(u1, 1), renderOutcome(@intCast(bad.len)).failed);
}

test "handles a trailing empty stored block with exactly-full output" {
    // Go's NoCompression zlib streams end with an empty final stored block.
    const data = "abcdefgh";
    const compressed = [_]u8{
        0x78, 0x01,
        0x00, 0x08, 0x00, 0xf7, 0xff, // stored block, 8 bytes
        'a',  'b',  'c',  'd',  'e',
        'f',  'g',  'h',
        0x01, 0x00, 0x00, 0xff, 0xff, // final empty stored block
        0x0e, 0x00, 0x03, 0x25, // adler32("abcdefgh")
    };
    @memcpy(input_buf[0..compressed.len], &compressed);
    const result = renderOutcome(@intCast(compressed.len));
    try std.testing.expectEqual(@as(u1, 0), result.failed);
    try std.testing.expectEqual(@as(u32, data.len), result.output_size_or_failure);
    try std.testing.expectEqualStrings(data, output_buf[0..result.output_size_or_failure]);
}
