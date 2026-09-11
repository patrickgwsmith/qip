const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const STORED_BLOCK_MAX: usize = 65535;
const STORED_BLOCKS_MAX: usize = (INPUT_CAP + STORED_BLOCK_MAX - 1) / STORED_BLOCK_MAX;
const OUTPUT_CAP: usize = INPUT_CAP + (STORED_BLOCKS_MAX * 5) + 6; // zlib hdr + stored block overhead + adler32

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn writeU16LE(off: usize, value: u16) void {
    output_buf[off] = @intCast(value & 0xff);
    output_buf[off + 1] = @intCast((value >> 8) & 0xff);
}

fn writeU32BE(off: usize, value: u32) void {
    output_buf[off] = @intCast((value >> 24) & 0xff);
    output_buf[off + 1] = @intCast((value >> 16) & 0xff);
    output_buf[off + 2] = @intCast((value >> 8) & 0xff);
    output_buf[off + 3] = @intCast(value & 0xff);
}

/// Writes a valid zlib stream using stored (uncompressed) DEFLATE blocks.
/// This keeps the implementation tiny and deterministic while still producing
/// standards-compliant zlib bytes.
fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    var out_i: usize = 0;

    // zlib header (CMF/FLG) for deflate + 32K window.
    output_buf[out_i] = 0x78;
    output_buf[out_i + 1] = 0x01;
    out_i += 2;

    const adler = std.hash.Adler32.hash(input);

    var pos: usize = 0;
    while (true) {
        const remaining = input_size - pos;
        const chunk_len: usize = if (remaining > STORED_BLOCK_MAX) STORED_BLOCK_MAX else remaining;
        const is_final = (pos + chunk_len) == input_size;

        if (out_i + 5 + chunk_len + 4 > OUTPUT_CAP) @trap();

        // Stored block header: BFINAL + BTYPE=00 and align to byte boundary.
        output_buf[out_i] = if (is_final) 0x01 else 0x00;
        out_i += 1;

        const len: u16 = @intCast(chunk_len);
        const nlen: u16 = ~len;
        writeU16LE(out_i, len);
        out_i += 2;
        writeU16LE(out_i, nlen);
        out_i += 2;

        if (chunk_len > 0) {
            @memcpy(output_buf[out_i..][0..chunk_len], input[pos..][0..chunk_len]);
            out_i += chunk_len;
            pos += chunk_len;
        }

        if (is_final) break;
    }

    writeU32BE(out_i, adler);
    out_i += 4;

    return @as(u32, @intCast(out_i));
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
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    var out_writer: std.Io.Writer = .fixed(out);

    const n = try decompress.reader.streamRemaining(&out_writer);

    var trailing: [1]u8 = undefined;
    if (try in.readSliceShort(&trailing) != 0) return error.TrailingBytes;
    return n;
}

test "compresses empty input to valid zlib stream" {
    const written = renderImpl(0);
    try std.testing.expectEqual(@as(u32, 11), written);

    var out: [1]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "round trips short text" {
    const plain = "qip wasm";
    @memcpy(input_buf[0..plain.len], plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [64]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualStrings(plain, out[0..n]);
}

test "round trips across multiple stored blocks" {
    var plain: [70000]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @intCast(i % 251);
    @memcpy(input_buf[0..plain.len], &plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [70000]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualSlices(u8, &plain, out[0..n]);
}

test "maximum input exactly fits the derived output capacity" {
    @memset(input_buf[0..], 0);
    try std.testing.expectEqual(
        @as(u32, @intCast(OUTPUT_CAP)),
        renderImpl(@intCast(INPUT_CAP)),
    );
}
