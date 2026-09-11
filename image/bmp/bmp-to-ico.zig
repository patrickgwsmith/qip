const std = @import("std");

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = 24 * 1024 * 1024;
const ICON_FILE_HEADER_SIZE: u32 = 22; // ICONDIR (6) + one ICONDIRENTRY (16)
const BMP_INFO_HEADER_SIZE: u32 = 40;
const INPUT_CONTENT_TYPE = "image/bmp";
const OUTPUT_CONTENT_TYPE = "image/x-icon";

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

fn readU16LE(off: u32) u16 {
    const i: usize = @intCast(off);
    return @as(u16, input_buf[i]) | (@as(u16, input_buf[i + 1]) << 8);
}

fn readU32LE(off: u32) u32 {
    const i: usize = @intCast(off);
    return @as(u32, input_buf[i]) |
        (@as(u32, input_buf[i + 1]) << 8) |
        (@as(u32, input_buf[i + 2]) << 16) |
        (@as(u32, input_buf[i + 3]) << 24);
}

fn readI32LE(off: u32) i32 {
    return @as(i32, @bitCast(readU32LE(off)));
}

fn writeU16LE(off: u32, value: u16) void {
    const i: usize = @intCast(off);
    output_buf[i] = @intCast(value & 0xFF);
    output_buf[i + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32LE(off: u32, value: u32) void {
    const i: usize = @intCast(off);
    output_buf[i] = @intCast(value & 0xFF);
    output_buf[i + 1] = @intCast((value >> 8) & 0xFF);
    output_buf[i + 2] = @intCast((value >> 16) & 0xFF);
    output_buf[i + 3] = @intCast((value >> 24) & 0xFF);
}

fn rowStrideBytes(width: u32, bits_per_pixel: u32) ?u32 {
    const bits_per_row: u64 = @as(u64, width) * @as(u64, bits_per_pixel);
    const dwords_per_row: u64 = (bits_per_row + 31) / 32;
    const bytes_per_row: u64 = dwords_per_row * 4;
    if (bytes_per_row > std.math.maxInt(u32)) return null;
    return @intCast(bytes_per_row);
}

fn renderImpl(input_size_in: u32) u32 {
    var input_size: u32 = input_size_in;
    if (input_size > INPUT_CAP) {
        input_size = @intCast(INPUT_CAP);
    }
    if (input_size < 54) {
        return 0;
    }
    if (input_buf[0] != 'B' or input_buf[1] != 'M') {
        return 0;
    }

    const dib_size = readU32LE(14);
    if (dib_size < BMP_INFO_HEADER_SIZE) {
        return 0;
    }

    const pixel_offset = readU32LE(10);
    const dib_end_u64: u64 = 14 + dib_size;
    if (pixel_offset < dib_end_u64 or pixel_offset > input_size) {
        return 0;
    }

    const width_i32 = readI32LE(18);
    const height_i32 = readI32LE(22);
    const planes = readU16LE(26);
    const bpp = readU16LE(28);
    const compression = readU32LE(30);

    if (planes != 1) {
        return 0;
    }
    if (!(bpp == 24 or bpp == 32)) {
        return 0;
    }
    if (compression != 0) {
        return 0;
    }
    if (width_i32 <= 0 or height_i32 == 0 or height_i32 == std.math.minInt(i32)) {
        return 0;
    }

    const width: u32 = @intCast(width_i32);
    const top_down = height_i32 < 0;
    const height_abs: u32 = if (top_down) @intCast(-height_i32) else @intCast(height_i32);

    // BMP-backed ICO directory entries only encode 1..256 directly (0 means 256).
    if (width == 0 or height_abs == 0 or width > 256 or height_abs > 256) {
        return 0;
    }

    const src_stride = rowStrideBytes(width, bpp) orelse return 0;
    const src_bytes: u64 = @as(u64, src_stride) * @as(u64, height_abs);
    if (@as(u64, pixel_offset) + src_bytes > input_size) {
        return 0;
    }

    const and_stride = rowStrideBytes(width, 1) orelse return 0;
    const xor_bytes: u64 = src_bytes;
    const and_bytes: u64 = @as(u64, and_stride) * @as(u64, height_abs);
    const image_bytes_u64: u64 = BMP_INFO_HEADER_SIZE + xor_bytes + and_bytes;
    const ico_size_u64: u64 = ICON_FILE_HEADER_SIZE + image_bytes_u64;

    if (image_bytes_u64 > std.math.maxInt(u32)) {
        return 0;
    }
    if (ico_size_u64 > std.math.maxInt(u32) or ico_size_u64 > OUTPUT_CAP) {
        return 0;
    }

    const image_bytes: u32 = @intCast(image_bytes_u64);
    const ico_size: u32 = @intCast(ico_size_u64);
    const image_offset: u32 = ICON_FILE_HEADER_SIZE;
    const dib_offset: u32 = image_offset;
    const xor_offset: u32 = dib_offset + BMP_INFO_HEADER_SIZE;
    const and_offset: u32 = xor_offset + @as(u32, @intCast(xor_bytes));

    // ICONDIR
    writeU16LE(0, 0);
    writeU16LE(2, 1);
    writeU16LE(4, 1);

    // ICONDIRENTRY
    output_buf[6] = if (width == 256) 0 else @intCast(width);
    output_buf[7] = if (height_abs == 256) 0 else @intCast(height_abs);
    output_buf[8] = 0;
    output_buf[9] = 0;
    writeU16LE(10, 1);
    writeU16LE(12, bpp);
    writeU32LE(14, image_bytes);
    writeU32LE(18, image_offset);

    // BITMAPINFOHEADER for the ICO image payload.
    writeU32LE(dib_offset + 0, BMP_INFO_HEADER_SIZE);
    writeU32LE(dib_offset + 4, @as(u32, @bitCast(width_i32)));
    writeU32LE(dib_offset + 8, @as(u32, @bitCast(@as(i32, @intCast(height_abs * 2)))));
    writeU16LE(dib_offset + 12, 1);
    writeU16LE(dib_offset + 14, bpp);
    writeU32LE(dib_offset + 16, 0);
    writeU32LE(dib_offset + 20, @as(u32, @intCast(xor_bytes + and_bytes)));
    writeU32LE(dib_offset + 24, 0);
    writeU32LE(dib_offset + 28, 0);
    writeU32LE(dib_offset + 32, 0);
    writeU32LE(dib_offset + 36, 0);

    // XOR bitmap (same format as source BMP, but ensure bottom-up ordering in output).
    var row: u32 = 0;
    while (row < height_abs) : (row += 1) {
        const src_row = if (top_down) (height_abs - 1 - row) else row;
        const src_off = pixel_offset + src_row * src_stride;
        const dst_off = xor_offset + row * src_stride;

        var col_byte: u32 = 0;
        while (col_byte < src_stride) : (col_byte += 1) {
            output_buf[@intCast(dst_off + col_byte)] = input_buf[@intCast(src_off + col_byte)];
        }
    }

    // AND mask (all opaque / no extra transparency bits).
    @memset(output_buf[@intCast(and_offset)..@intCast(and_offset + @as(u32, @intCast(and_bytes)))], 0);

    return ico_size;
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

fn putU16LE(buf: []u8, off: usize, v: u16) void {
    buf[off] = @intCast(v & 0xFF);
    buf[off + 1] = @intCast((v >> 8) & 0xFF);
}

fn putU32LE(buf: []u8, off: usize, v: u32) void {
    buf[off] = @intCast(v & 0xFF);
    buf[off + 1] = @intCast((v >> 8) & 0xFF);
    buf[off + 2] = @intCast((v >> 16) & 0xFF);
    buf[off + 3] = @intCast((v >> 24) & 0xFF);
}

test "converts 24bpp BI_RGB BMP to ICO" {
    @memset(input_buf[0..], 0);

    const bmp = [_]u8{
        0x42, 0x4D, // BM
        0x3A, 0x00, 0x00, 0x00, // file size 58
        0x00, 0x00, 0x00, 0x00,
        0x36, 0x00, 0x00, 0x00, // pixel offset 54
        0x28, 0x00, 0x00, 0x00, // DIB size 40
        0x01, 0x00, 0x00, 0x00, // width 1
        0x01, 0x00, 0x00, 0x00, // height 1 (bottom-up)
        0x01, 0x00, // planes
        0x18, 0x00, // bpp 24
        0x00, 0x00, 0x00, 0x00, // BI_RGB
        0x04, 0x00, 0x00, 0x00, // image size (1 row with padding)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xFF, 0x00, // one red pixel + row padding
    };

    @memcpy(input_buf[0..bmp.len], bmp[0..]);

    const written = renderImpl(@intCast(bmp.len));
    try std.testing.expectEqual(@as(u32, 70), written);

    try std.testing.expectEqual(@as(u8, 0), output_buf[0]);
    try std.testing.expectEqual(@as(u8, 0), output_buf[1]);
    try std.testing.expectEqual(@as(u8, 1), output_buf[2]);
    try std.testing.expectEqual(@as(u8, 0), output_buf[3]);

    try std.testing.expectEqual(@as(u8, 1), output_buf[6]);
    try std.testing.expectEqual(@as(u8, 1), output_buf[7]);
    try std.testing.expectEqual(@as(u16, 24), @as(u16, output_buf[12]) | (@as(u16, output_buf[13]) << 8));

    try std.testing.expectEqual(@as(u32, 40), @as(u32, output_buf[22]) | (@as(u32, output_buf[23]) << 8));
    try std.testing.expectEqual(@as(u32, 1), @as(u32, output_buf[26]) | (@as(u32, output_buf[27]) << 8));
    try std.testing.expectEqual(@as(u32, 2), @as(u32, output_buf[30]) | (@as(u32, output_buf[31]) << 8));

    try std.testing.expectEqual(@as(u8, 0x00), output_buf[62]);
    try std.testing.expectEqual(@as(u8, 0x00), output_buf[63]);
    try std.testing.expectEqual(@as(u8, 0xFF), output_buf[64]);
    try std.testing.expectEqual(@as(u8, 0x00), output_buf[65]);

    try std.testing.expectEqual(@as(u8, 0), output_buf[66]);
    try std.testing.expectEqual(@as(u8, 0), output_buf[67]);
    try std.testing.expectEqual(@as(u8, 0), output_buf[68]);
    try std.testing.expectEqual(@as(u8, 0), output_buf[69]);
}

test "converts top-down 32bpp BI_RGB BMP to bottom-up ICO XOR bitmap" {
    @memset(input_buf[0..], 0);

    var bmp = [_]u8{0} ** 70;
    bmp[0] = 0x42;
    bmp[1] = 0x4D;
    putU32LE(bmp[0..], 2, 70);
    putU32LE(bmp[0..], 10, 54);
    putU32LE(bmp[0..], 14, 40);
    putU32LE(bmp[0..], 18, 2);
    putU32LE(bmp[0..], 22, 0xFFFF_FFFE); // -2 (top-down)
    putU16LE(bmp[0..], 26, 1);
    putU16LE(bmp[0..], 28, 32);
    putU32LE(bmp[0..], 30, 0);
    putU32LE(bmp[0..], 34, 16);

    // Source top row (top-down BMP): blue, green(alpha=128)
    bmp[54] = 0xFF;
    bmp[55] = 0x00;
    bmp[56] = 0x00;
    bmp[57] = 0xFF;
    bmp[58] = 0x00;
    bmp[59] = 0xFF;
    bmp[60] = 0x00;
    bmp[61] = 0x80;

    // Source bottom row: red, white(alpha=64)
    bmp[62] = 0x00;
    bmp[63] = 0x00;
    bmp[64] = 0xFF;
    bmp[65] = 0xFF;
    bmp[66] = 0xFF;
    bmp[67] = 0xFF;
    bmp[68] = 0xFF;
    bmp[69] = 0x40;

    @memcpy(input_buf[0..bmp.len], bmp[0..]);

    const written = renderImpl(@intCast(bmp.len));
    try std.testing.expectEqual(@as(u32, 86), written);

    try std.testing.expectEqual(@as(u8, 2), output_buf[6]);
    try std.testing.expectEqual(@as(u8, 2), output_buf[7]);
    try std.testing.expectEqual(@as(u16, 32), @as(u16, output_buf[12]) | (@as(u16, output_buf[13]) << 8));

    // DIB height should be doubled (XOR + AND).
    try std.testing.expectEqual(@as(u32, 4), @as(u32, output_buf[30]) | (@as(u32, output_buf[31]) << 8));

    const xor_off: usize = 62;
    // First row in output XOR must be bottom row (red, white).
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x40 }, output_buf[xor_off .. xor_off + 8]);
    // Second row must be original top row (blue, green).
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x80 }, output_buf[xor_off + 8 .. xor_off + 16]);

    const and_off: usize = xor_off + 16;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, output_buf[and_off .. and_off + 8]);
}

test "rejects unsupported BMP bit depth" {
    @memset(input_buf[0..], 0);

    var bmp = [_]u8{0} ** 54;
    bmp[0] = 0x42;
    bmp[1] = 0x4D;
    putU32LE(bmp[0..], 2, 54);
    putU32LE(bmp[0..], 10, 54);
    putU32LE(bmp[0..], 14, 40);
    putU32LE(bmp[0..], 18, 1);
    putU32LE(bmp[0..], 22, 1);
    putU16LE(bmp[0..], 26, 1);
    putU16LE(bmp[0..], 28, 8);
    putU32LE(bmp[0..], 30, 0);

    @memcpy(input_buf[0..bmp.len], bmp[0..]);

    const written = renderImpl(@intCast(bmp.len));
    try std.testing.expectEqual(@as(u32, 0), written);
}
