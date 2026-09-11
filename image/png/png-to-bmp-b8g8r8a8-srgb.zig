//! Converts PNG (8-bit depth; grayscale, truecolor, palette, and alpha
//! variants; non-interlaced) to BMP (BITMAPINFOHEADER, 32-bit BGRA,
//! bottom-up) so PNGs can flow into every bmp-consuming component.
//!
//! Strict by default: chunk CRCs are verified here, the shared inflater in
//! lib/inflate.zig verifies the zlib header and Adler-32 trailer, and unknown
//! critical chunks are rejected. 16-bit depths, sub-8-bit depths, and Adam7
//! interlacing return 0.
//!
//! IDAT payloads are compacted inside the disposable input buffer. DEFLATE
//! then emits fixed, whole-row batches which are immediately unfiltered,
//! converted, and written to their final bottom-up BMP positions.

const std = @import("std");
const inflate = @import("lib/inflate.zig");
const root = @import("root");

const OUTPUT_KTX2 = @hasDecl(root, "PNG_OUTPUT_KTX2") and root.PNG_OUTPUT_KTX2;
const ktx2 = if (OUTPUT_KTX2) @import("ktx2_rgba8_srgb") else struct {};

const MAX_PIXELS: usize = 25_000_000;
const MAX_DIMENSION: usize = 8192;
const INPUT_CAP: usize = 64 * 1024 * 1024;
const OUTPUT_HEADER_SIZE: usize = if (OUTPUT_KTX2) 224 else 54;
const OUTPUT_CAP: usize = MAX_PIXELS * 4 + OUTPUT_HEADER_SIZE;
const DECODE_BATCH_TARGET: usize = 1 * 1024 * 1024;
const DEFLATE_WINDOW: usize = 32 * 1024;
const MAX_ROW_BYTES: usize = MAX_DIMENSION * 4;
const INPUT_CONTENT_TYPE = "image/png";
const OUTPUT_CONTENT_TYPE = if (OUTPUT_KTX2) "image/ktx2" else "image/bmp";
const USE_SIMD = @hasDecl(root, "PNG_TO_BMP_SIMD") and root.PNG_TO_BMP_SIMD;

const Vec16 = @Vector(16, u8);
const RGB_TO_BGRA = @Vector(16, i32){
    2,  1,  0, -1,
    5,  4,  3, -1,
    8,  7,  6, -1,
    11, 10, 9, -1,
};
const RGBA_TO_BGRA = @Vector(16, i32){
    2,  1,  0,  3,
    6,  5,  4,  7,
    10, 9,  8,  11,
    14, 13, 12, 15,
};
const OPAQUE = @as(Vec16, @splat(255));

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var decode_work: [DEFLATE_WINDOW + DECODE_BATCH_TARGET]u8 = undefined;
var history_scratch: [DEFLATE_WINDOW]u8 = undefined;
var prior_row_buf: [MAX_ROW_BYTES]u8 = undefined;
var palette_buf: [768]u8 = undefined;
var trns_buf: [256]u8 = undefined;

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

fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

fn readU32BE(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .big);
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

const Header = struct {
    width: u32,
    height: u32,
    color_type: u8,
    channels: usize,
};

const DecodeContext = struct {
    header: Header,
    palette_len: usize,
    trns_len: usize,
    row_bytes: usize,
    row_span: usize,
    out_stride: usize,
    next_y: usize = 0,
    has_prior: bool = false,
};

fn unfilterRow(filter: u8, line: []u8, prior: []const u8, bpp: usize) void {
    if (filter == 0) return;

    var i: usize = 0;
    if (USE_SIMD and filter == 2 and prior.len != 0) {
        while (i + 16 <= line.len) : (i += 16) {
            const filtered = @as(*align(1) const Vec16, @ptrCast(&line[i])).*;
            const above = @as(*align(1) const Vec16, @ptrCast(&prior[i])).*;
            @as(*align(1) Vec16, @ptrCast(&line[i])).* = filtered +% above;
        }
    }

    while (i < line.len) : (i += 1) {
        const a = if (i >= bpp) line[i - bpp] else 0;
        const b = if (prior.len != 0) prior[i] else 0;
        const c = if (i >= bpp and prior.len != 0) prior[i - bpp] else 0;
        line[i] = switch (filter) {
            1 => line[i] +% a,
            2 => line[i] +% b,
            3 => line[i] +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) >> 1)),
            else => line[i] +% paeth(a, b, c),
        };
    }
}

fn convertPixel(context: *const DecodeContext, line: []const u8, dst: usize, x: usize) bool {
    switch (context.header.color_type) {
        0 => {
            const g = line[x];
            output_buf[dst] = g;
            output_buf[dst + 1] = g;
            output_buf[dst + 2] = g;
            output_buf[dst + 3] = 255;
        },
        4 => {
            const g = line[x * 2];
            output_buf[dst] = g;
            output_buf[dst + 1] = g;
            output_buf[dst + 2] = g;
            output_buf[dst + 3] = line[x * 2 + 1];
        },
        2 => {
            output_buf[dst] = line[x * 3 + if (OUTPUT_KTX2) 0 else 2];
            output_buf[dst + 1] = line[x * 3 + 1];
            output_buf[dst + 2] = line[x * 3 + if (OUTPUT_KTX2) 2 else 0];
            output_buf[dst + 3] = 255;
        },
        6 => {
            output_buf[dst] = line[x * 4 + if (OUTPUT_KTX2) 0 else 2];
            output_buf[dst + 1] = line[x * 4 + 1];
            output_buf[dst + 2] = line[x * 4 + if (OUTPUT_KTX2) 2 else 0];
            output_buf[dst + 3] = line[x * 4 + 3];
        },
        else => {
            const idx: usize = line[x];
            if (idx * 3 + 3 > context.palette_len) return false;
            output_buf[dst] = palette_buf[idx * 3 + if (OUTPUT_KTX2) 0 else 2];
            output_buf[dst + 1] = palette_buf[idx * 3 + 1];
            output_buf[dst + 2] = palette_buf[idx * 3 + if (OUTPUT_KTX2) 2 else 0];
            output_buf[dst + 3] = if (idx < context.trns_len) trns_buf[idx] else 255;
        },
    }
    return true;
}

fn convertRow(context: *const DecodeContext, line: []const u8, dst_row: usize) bool {
    var x: usize = 0;
    if (USE_SIMD and !OUTPUT_KTX2 and context.header.color_type == 2) {
        while (x + 4 <= context.header.width and x * 3 + 16 <= line.len) : (x += 4) {
            const rgb = @as(*align(1) const Vec16, @ptrCast(&line[x * 3])).*;
            const bgra = @shuffle(u8, rgb, OPAQUE, RGB_TO_BGRA);
            @as(*align(1) Vec16, @ptrCast(&output_buf[dst_row + x * 4])).* = bgra;
        }
    } else if (USE_SIMD and !OUTPUT_KTX2 and context.header.color_type == 6) {
        while (x + 4 <= context.header.width) : (x += 4) {
            const rgba = @as(*align(1) const Vec16, @ptrCast(&line[x * 4])).*;
            const bgra = @shuffle(u8, rgba, rgba, RGBA_TO_BGRA);
            @as(*align(1) Vec16, @ptrCast(&output_buf[dst_row + x * 4])).* = bgra;
        }
    }

    while (x < context.header.width) : (x += 1) {
        if (!convertPixel(context, line, dst_row + x * 4, x)) return false;
    }
    return true;
}

fn consumeRows(context: *DecodeContext, batch: []u8) bool {
    if (batch.len == 0 or batch.len % context.row_span != 0) return false;

    var pos: usize = 0;
    var prior: []const u8 = if (context.has_prior)
        prior_row_buf[0..context.row_bytes]
    else
        &.{};
    var final_line: []const u8 = &.{};

    while (pos < batch.len) : (pos += context.row_span) {
        if (context.next_y >= context.header.height) return false;
        const filter = batch[pos];
        if (filter > 4) return false;
        const line = batch[pos + 1 .. pos + context.row_span];
        unfilterRow(filter, line, prior, context.header.channels);

        const dst_y = if (OUTPUT_KTX2) context.next_y else context.header.height - 1 - context.next_y;
        const dst_row = OUTPUT_HEADER_SIZE + dst_y * context.out_stride;
        if (!convertRow(context, line, dst_row)) return false;

        prior = line;
        final_line = line;
        context.next_y += 1;
    }

    @memcpy(prior_row_buf[0..context.row_bytes], final_line);
    context.has_prior = true;
    return true;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const input = input_buf[0..input_size];

    const sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (input.len < sig.len + 12 or !std.mem.eql(u8, input[0..8], &sig)) return 0;

    var header: ?Header = null;
    var palette_len: usize = 0;
    var trns_len: usize = 0;
    var idat_len: usize = 0;
    var seen_iend = false;

    var pos: usize = 8;
    while (pos + 12 <= input.len) {
        const chunk_len: usize = readU32BE(input, pos);
        if (pos + 12 + chunk_len > input.len) return 0;
        const chunk_type = input[pos + 4 .. pos + 8];
        const data = input[pos + 8 .. pos + 8 + chunk_len];
        const stored_crc = readU32BE(input, pos + 8 + chunk_len);
        if (crc32(input[pos + 4 .. pos + 8 + chunk_len]) != stored_crc) return 0;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (header != null or chunk_len != 13) return 0;
            const color_type = data[9];
            const channels: usize = switch (color_type) {
                0, 3 => 1,
                2 => 3,
                4 => 2,
                6 => 4,
                else => return 0,
            };
            // 8-bit depth, deflate compression, standard filtering,
            // no interlacing.
            if (data[8] != 8 or data[10] != 0 or data[11] != 0 or data[12] != 0) return 0;
            header = .{
                .width = readU32BE(data, 0),
                .height = readU32BE(data, 4),
                .color_type = color_type,
                .channels = channels,
            };
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (chunk_len == 0 or chunk_len > 768 or chunk_len % 3 != 0) return 0;
            @memcpy(palette_buf[0..chunk_len], data);
            palette_len = chunk_len;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            if (chunk_len > trns_buf.len) return 0;
            @memcpy(trns_buf[0..chunk_len], data);
            trns_len = chunk_len;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (idat_len + chunk_len > INPUT_CAP) return 0;
            std.mem.copyForwards(u8, input_buf[idat_len..][0..chunk_len], data);
            idat_len += chunk_len;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (chunk_len != 0 or pos + 12 != input.len) return 0;
            seen_iend = true;
        } else if (chunk_type[0] & 0x20 == 0) {
            // Unknown critical chunk.
            return 0;
        }

        pos += 12 + chunk_len;
    }

    const h = header orelse return 0;
    if (!seen_iend or idat_len == 0) return 0;
    if (h.width == 0 or h.height == 0) return 0;
    if (h.color_type == 3 and palette_len == 0) return 0;

    const width: u64 = h.width;
    const height: u64 = h.height;
    if (width > MAX_DIMENSION or height > MAX_DIMENSION or width * height > MAX_PIXELS) return 0;
    const row_bytes: u64 = width * h.channels;
    const raw_len: u64 = (1 + row_bytes) * height;

    const out_stride: u64 = width * 4;
    const out_total: u64 = OUTPUT_HEADER_SIZE + out_stride * height;
    if (out_total > OUTPUT_CAP) return 0;

    if (OUTPUT_KTX2) {
        _ = ktx2.writeHeader(&output_buf, @intCast(width), @intCast(height)) orelse return 0;
    } else {
        // BMP header: BITMAPINFOHEADER, 32-bit BGRA, bottom-up.
        @memset(output_buf[0..54], 0);
        output_buf[0] = 'B';
        output_buf[1] = 'M';
        std.mem.writeInt(u32, output_buf[2..6], @intCast(out_total), .little);
        std.mem.writeInt(u32, output_buf[10..14], 54, .little);
        std.mem.writeInt(u32, output_buf[14..18], 40, .little);
        std.mem.writeInt(i32, output_buf[18..22], @intCast(width), .little);
        std.mem.writeInt(i32, output_buf[22..26], @intCast(height), .little);
        std.mem.writeInt(u16, output_buf[26..28], 1, .little);
        std.mem.writeInt(u16, output_buf[28..30], 32, .little);
        std.mem.writeInt(u32, output_buf[34..38], @intCast(out_stride * height), .little);
        std.mem.writeInt(u32, output_buf[38..42], 2835, .little);
        std.mem.writeInt(u32, output_buf[42..46], 2835, .little);
    }

    const row_span: usize = @intCast(row_bytes + 1);
    const rows_per_batch = @max(@as(usize, 1), DECODE_BATCH_TARGET / row_span);
    const batch_bytes = rows_per_batch * row_span;
    var context = DecodeContext{
        .header = h,
        .palette_len = palette_len,
        .trns_len = trns_len,
        .row_bytes = @intCast(row_bytes),
        .row_span = row_span,
        .out_stride = @intCast(out_stride),
    };
    const inflated = inflate.inflateZlibBatches(
        DecodeContext,
        input_buf[0..idat_len],
        &decode_work,
        &history_scratch,
        batch_bytes,
        &context,
        consumeRows,
    ) orelse return 0;
    if (inflated != raw_len or context.next_y != h.height) return 0;

    return @as(u32, @intCast(out_total));
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

test "crc32 matches the PNG check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "declares the standard 25 MP image capacities" {
    try std.testing.expectEqual(@as(u32, 64 * 1024 * 1024), input_bytes_cap());
    try std.testing.expectEqual(@as(u32, MAX_PIXELS * 4 + OUTPUT_HEADER_SIZE), output_bytes_cap());
}
