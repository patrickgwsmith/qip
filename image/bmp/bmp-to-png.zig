//! Converts BMP (BITMAPINFOHEADER, uncompressed 24-bit BGR or 32-bit BGRA,
//! bottom-up or top-down) to PNG (8-bit truecolor, one IDAT chunk). Each
//! scanline gets the filter with the smallest sum of absolute residuals, and
//! the filtered stream is deflated with the shared engine in lib/deflate.zig.
//!
//! 32-bit alpha passes through unchanged: BMPs produced in this repository
//! carry meaningful alpha (0xff when opaque).

const std = @import("std");
const deflate = @import("lib/deflate.zig");
const root = @import("root");

const INPUT_KTX2 = @hasDecl(root, "PNG_INPUT_KTX2") and root.PNG_INPUT_KTX2;
const ktx2_rgba = if (INPUT_KTX2) @import("ktx2_rgba8_srgb") else struct {};
const ktx2_bgra = if (INPUT_KTX2) @import("ktx2_bgra8_srgb") else struct {};

const MAX_PIXELS: usize = 25_000_000;
const MAX_DIMENSION: usize = 8192;
const BMP_HEADER_CAP: usize = 64 * 1024;
const INPUT_CAP: usize = MAX_PIXELS * 4 + if (INPUT_KTX2) 224 else BMP_HEADER_CAP;
const FILTERED_CAP: usize = MAX_PIXELS * 4 + MAX_DIMENSION;
const OUTPUT_CAP: usize = FILTERED_CAP + FILTERED_CAP / 8 + 4096;
const TOKEN_CAP: usize = 8 * 1024 * 1024;
const ROW_CAP: usize = MAX_DIMENSION * 4;
const INPUT_CONTENT_TYPE = if (INPUT_KTX2) "image/ktx2" else "image/bmp";
const OUTPUT_CONTENT_TYPE = "image/png";

var input_buf: [INPUT_CAP]u8 = undefined;
var filtered_buf: [FILTERED_CAP]u8 = undefined;
var token_buf: [TOKEN_CAP]u32 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var row_a: [ROW_CAP]u8 = undefined;
var row_b: [ROW_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

const CRC_TABLE = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, n| {
        var c: u32 = n;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        e.* = c;
    }
    break :blk t;
};

fn crc32Update(crc: u32, bytes: []const u8) u32 {
    var c = crc;
    for (bytes) |b| {
        c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >> 8);
    }
    return c;
}

fn crc32(bytes: []const u8) u32 {
    return crc32Update(0xFFFFFFFF, bytes) ^ 0xFFFFFFFF;
}

fn readU16LE(off: usize) u16 {
    return std.mem.readInt(u16, input_buf[off..][0..2], .little);
}

fn readU32LE(off: usize) u32 {
    return std.mem.readInt(u32, input_buf[off..][0..4], .little);
}

fn writeU32BE(out: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, out[off..][0..4], value, .big);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn predict(filter: u8, a: u8, b: u8, c: u8) u8 {
    return switch (filter) {
        0 => 0,
        1 => a,
        2 => b,
        3 => @intCast((@as(u16, a) + @as(u16, b)) >> 1),
        else => paeth(a, b, c),
    };
}

// Minimum-sum-of-absolute-residuals heuristic from the PNG spec: residuals
// are treated as signed bytes and the cheapest filter wins.
fn filterCost(filter: u8, cur: []const u8, prior: []const u8, bpp: usize) u64 {
    var cost: u64 = 0;
    for (cur, 0..) |x, i| {
        const a = if (i >= bpp) cur[i - bpp] else 0;
        const b = prior[i];
        const c = if (i >= bpp) prior[i - bpp] else 0;
        const r = x -% predict(filter, a, b, c);
        cost += @abs(@as(i8, @bitCast(r)));
    }
    return cost;
}

fn writeFiltered(filter: u8, cur: []const u8, prior: []const u8, bpp: usize, out: []u8) void {
    for (cur, 0..) |x, i| {
        const a = if (i >= bpp) cur[i - bpp] else 0;
        const b = prior[i];
        const c = if (i >= bpp) prior[i - bpp] else 0;
        out[i] = x -% predict(filter, a, b, c);
    }
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    var pixel_offset: u64 = 0;
    var width: u64 = 0;
    var height: u64 = 0;
    var bytes_pp: u64 = 4;
    var src_stride: u64 = 0;
    var top_down = true;
    var source_is_rgba = true;

    if (INPUT_KTX2) {
        const input = input_buf[0..input_size];
        if (ktx2_rgba.parse(input)) |image| {
            width = image.width;
            height = image.height;
            pixel_offset = ktx2_rgba.HEADER_SIZE;
        } else if (ktx2_bgra.parse(input)) |image| {
            width = image.width;
            height = image.height;
            pixel_offset = ktx2_bgra.HEADER_SIZE;
            source_is_rgba = false;
        } else return 0;
        src_stride = width * 4;
    } else {
        if (input_size < 54) return 0;
        if (input_buf[0] != 'B' or input_buf[1] != 'M') return 0;

        pixel_offset = readU32LE(10);
        const dib_size = readU32LE(14);
        const width_raw: i32 = @bitCast(readU32LE(18));
        const height_raw: i32 = @bitCast(readU32LE(22));
        const planes = readU16LE(26);
        const bpp_bits = readU16LE(28);
        const compression = readU32LE(30);

        if (dib_size < 40 or pixel_offset < 54) return 0;
        if (planes != 1 or compression != 0) return 0;
        if (bpp_bits != 24 and bpp_bits != 32) return 0;
        if (width_raw <= 0 or height_raw == 0) return 0;

        width = @intCast(width_raw);
        top_down = height_raw < 0;
        height = if (top_down) @intCast(-@as(i64, height_raw)) else @intCast(height_raw);
        if (width > MAX_DIMENSION or height > MAX_DIMENSION or width * height > MAX_PIXELS) return 0;

        bytes_pp = bpp_bits / 8;
        src_stride = (width * bytes_pp + 3) & ~@as(u64, 3);
        source_is_rgba = false;
        if (pixel_offset + src_stride * height > input_size) return 0;
    }

    const row_bytes: u64 = width * bytes_pp;
    if (row_bytes > ROW_CAP) return 0;
    const filtered_len: u64 = (1 + row_bytes) * height;
    if (filtered_len > FILTERED_CAP) return 0;

    const rb: usize = @intCast(row_bytes);
    const bpp: usize = @intCast(bytes_pp);
    var cur: []u8 = row_a[0..rb];
    var prior: []u8 = row_b[0..rb];
    @memset(prior, 0);

    var out_f: usize = 0;
    var y: u64 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (top_down) y else height - 1 - y;
        const src: usize = @intCast(pixel_offset + src_y * src_stride);

        // Normalize either RGB(A), BGR(A), or BGRA source bytes to PNG order.
        const red_offset: usize = if (source_is_rgba) 0 else 2;
        const blue_offset: usize = if (source_is_rgba) 2 else 0;
        var x: usize = 0;
        while (x < rb) : (x += bpp) {
            cur[x] = input_buf[src + x + red_offset];
            cur[x + 1] = input_buf[src + x + 1];
            cur[x + 2] = input_buf[src + x + blue_offset];
            if (bpp == 4) cur[x + 3] = input_buf[src + x + 3];
        }

        var best_filter: u8 = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        var f: u8 = 0;
        while (f < 5) : (f += 1) {
            const cost = filterCost(f, cur, prior, bpp);
            if (cost < best_cost) {
                best_cost = cost;
                best_filter = f;
            }
        }

        filtered_buf[out_f] = best_filter;
        writeFiltered(best_filter, cur, prior, bpp, filtered_buf[out_f + 1 ..][0..rb]);
        out_f += 1 + rb;

        const tmp = cur;
        cur = prior;
        prior = tmp;
    }

    // PNG signature.
    const sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    @memcpy(output_buf[0..8], &sig);

    // IHDR chunk.
    writeU32BE(&output_buf, 8, 13);
    @memcpy(output_buf[12..16], "IHDR");
    writeU32BE(&output_buf, 16, @intCast(width));
    writeU32BE(&output_buf, 20, @intCast(height));
    output_buf[24] = 8; // bit depth
    output_buf[25] = if (bpp == 4) 6 else 2; // color type: RGBA or RGB
    output_buf[26] = 0; // compression
    output_buf[27] = 0; // filter method
    output_buf[28] = 0; // interlace
    writeU32BE(&output_buf, 29, crc32(output_buf[12..29]));

    // IDAT chunk: deflate the filtered stream straight into place.
    const idat_data_start: usize = 41;
    if (idat_data_start >= OUTPUT_CAP) return 0;
    const compressed_len = (if (out_f <= TOKEN_CAP)
        deflate.compressZlib(
            filtered_buf[0..out_f],
            output_buf[idat_data_start .. OUTPUT_CAP - 16],
            &token_buf,
        )
    else
        deflate.compressZlibFixed(
            filtered_buf[0..out_f],
            output_buf[idat_data_start .. OUTPUT_CAP - 16],
        )) orelse return 0;
    writeU32BE(&output_buf, 33, @intCast(compressed_len));
    @memcpy(output_buf[37..41], "IDAT");
    writeU32BE(&output_buf, idat_data_start + compressed_len, crc32(output_buf[37 .. idat_data_start + compressed_len]));

    // IEND chunk.
    const iend_start = idat_data_start + compressed_len + 4;
    if (iend_start + 12 > OUTPUT_CAP) return 0;
    writeU32BE(&output_buf, iend_start, 0);
    @memcpy(output_buf[iend_start + 4 .. iend_start + 8], "IEND");
    writeU32BE(&output_buf, iend_start + 8, crc32(output_buf[iend_start + 4 .. iend_start + 8]));

    return @as(u32, @intCast(iend_start + 12));
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

test "crc32 matches the PNG check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "declares the standard 25 MP image capacities" {
    try std.testing.expectEqual(@as(u32, MAX_PIXELS * 4 + if (INPUT_KTX2) 224 else BMP_HEADER_CAP), input_bytes_cap());
    try std.testing.expectEqual(@as(u32, FILTERED_CAP + FILTERED_CAP / 8 + 4096), output_bytes_cap());
}
