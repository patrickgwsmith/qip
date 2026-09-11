//! Converts canonical VK_FORMAT_R8G8B8A8_SRGB KTX2 into a BMP-backed ICO
//! favicon. The ICO holds one 32-bit BGRA image and preserves straight alpha.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const MAX_DIMENSION: usize = 256;
const MAX_PIXELS: usize = MAX_DIMENSION * MAX_DIMENSION;
const INPUT_CAP: usize = ktx.HEADER_SIZE + MAX_PIXELS * 4;
const ICON_FILE_HEADER_SIZE: usize = 22; // ICONDIR (6) + one ICONDIRENTRY (16)
const BMP_INFO_HEADER_SIZE: usize = 40;
const MAX_AND_MASK_BYTES: usize = (MAX_DIMENSION / 8) * MAX_DIMENSION;
const OUTPUT_CAP: usize = ICON_FILE_HEADER_SIZE + BMP_INFO_HEADER_SIZE + MAX_PIXELS * 4 + MAX_AND_MASK_BYTES;
const INPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const OUTPUT_CONTENT_TYPE = "image/x-icon";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn writeU16(offset: usize, value: u16) void {
    std.mem.writeInt(u16, output_buf[offset..][0..2], value, .little);
}

fn writeU32(offset: usize, value: u32) void {
    std.mem.writeInt(u32, output_buf[offset..][0..4], value, .little);
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > INPUT_CAP) @trap();
    const image = ktx.parse(input_buf[0..input_size]) orelse @trap();
    if (image.width > MAX_DIMENSION or image.height > MAX_DIMENSION) @trap();

    const pixel_count = std.math.mul(usize, image.width, image.height) catch @trap();
    const xor_bytes = std.math.mul(usize, pixel_count, 4) catch @trap();
    const and_stride = (image.width + 31) / 32 * 4;
    const and_bytes = std.math.mul(usize, and_stride, image.height) catch @trap();
    const image_bytes = BMP_INFO_HEADER_SIZE + xor_bytes + and_bytes;
    const output_size = ICON_FILE_HEADER_SIZE + image_bytes;
    if (output_size > OUTPUT_CAP) @trap();

    // ICONDIR
    writeU16(0, 0);
    writeU16(2, 1);
    writeU16(4, 1);

    // ICONDIRENTRY. A zero dimension represents 256 pixels.
    output_buf[6] = if (image.width == MAX_DIMENSION) 0 else @intCast(image.width);
    output_buf[7] = if (image.height == MAX_DIMENSION) 0 else @intCast(image.height);
    output_buf[8] = 0;
    output_buf[9] = 0;
    writeU16(10, 1);
    writeU16(12, 32);
    writeU32(14, @intCast(image_bytes));
    writeU32(18, ICON_FILE_HEADER_SIZE);

    // BITMAPINFOHEADER. ICO height includes the XOR bitmap and AND mask.
    const dib_offset = ICON_FILE_HEADER_SIZE;
    writeU32(dib_offset + 0, BMP_INFO_HEADER_SIZE);
    writeU32(dib_offset + 4, @intCast(image.width));
    writeU32(dib_offset + 8, @intCast(image.height * 2));
    writeU16(dib_offset + 12, 1);
    writeU16(dib_offset + 14, 32);
    writeU32(dib_offset + 16, 0);
    writeU32(dib_offset + 20, @intCast(xor_bytes + and_bytes));
    writeU32(dib_offset + 24, 0);
    writeU32(dib_offset + 28, 0);
    writeU32(dib_offset + 32, 0);
    writeU32(dib_offset + 36, 0);

    // ICO's BMP payload stores rows bottom-up in BGRA order.
    const xor_offset = dib_offset + BMP_INFO_HEADER_SIZE;
    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        const source_y = image.height - 1 - y;
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const source = (source_y * image.width + x) * 4;
            const target = xor_offset + (y * image.width + x) * 4;
            output_buf[target] = image.pixels[source + 2];
            output_buf[target + 1] = image.pixels[source + 1];
            output_buf[target + 2] = image.pixels[source];
            output_buf[target + 3] = image.pixels[source + 3];
        }
    }

    // The 32-bit XOR alpha has the transparency information. The AND mask is opaque.
    @memset(output_buf[xor_offset + xor_bytes .. output_size], 0);
    return @intCast(output_size);
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

test "converts canonical RGBA8 KTX2 to a bottom-up BGRA ICO bitmap" {
    @memset(input_buf[0..], 0);

    const input_size = ktx.writeHeader(input_buf[0..], 2, 2) orelse unreachable;
    // KTX2 pixels are top-down RGBA: red, green, blue, white with alpha 64.
    @memcpy(input_buf[ktx.HEADER_SIZE..input_size], &[_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x80,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x40,
    });

    const written = renderImpl(@intCast(input_size));
    try std.testing.expectEqual(@as(u32, 86), written);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 1, 0, 1, 0, 2, 2 }, output_buf[0..8]);
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, output_buf[12..14], .little));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, output_buf[30..34], .little));

    const xor_offset = ICON_FILE_HEADER_SIZE + BMP_INFO_HEADER_SIZE;
    // Bottom row is written first, in BGRA order.
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x40,
        0x00, 0x00, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0x80,
    }, output_buf[xor_offset .. xor_offset + 16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, output_buf[xor_offset + 16 .. xor_offset + 24]);
}
