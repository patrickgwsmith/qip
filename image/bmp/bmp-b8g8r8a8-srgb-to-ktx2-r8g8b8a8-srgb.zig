//! Converts QIP's 32-bit sRGB BGRA BMP to canonical top-down
//! VK_FORMAT_R8G8B8A8_SRGB KTX2.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const INPUT_CAP: usize = 100_000_054 + 64 * 1024;
const OUTPUT_CAP: usize = ktx.MAX_FILE_SIZE;
const INPUT_CONTENT_TYPE = "image/bmp";
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

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

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, input_buf[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, input_buf[offset..][0..4], .little);
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > INPUT_CAP or input_size < 54) @trap();
    if (input_buf[0] != 'B' or input_buf[1] != 'M') @trap();

    const pixel_offset: usize = readU32(10);
    const dib_size: usize = readU32(14);
    const dib_end = std.math.add(usize, 14, dib_size) catch @trap();
    if (dib_size < 40 or pixel_offset < dib_end or pixel_offset > input_size) @trap();
    const width_signed: i32 = @bitCast(readU32(18));
    const height_signed: i32 = @bitCast(readU32(22));
    if (width_signed <= 0 or height_signed == 0 or height_signed == std.math.minInt(i32)) @trap();
    if (readU16(26) != 1 or readU16(28) != 32 or readU32(30) != 0) @trap();

    const width: usize = @intCast(width_signed);
    const height: usize = @intCast(if (height_signed < 0) -height_signed else height_signed);
    const output_size = ktx.writeHeader(&output_buf, width, height) orelse @trap();
    const pixel_count = std.math.mul(usize, width, height) catch @trap();
    const pixel_bytes = std.math.mul(usize, pixel_count, 4) catch @trap();
    const pixel_end = std.math.add(usize, pixel_offset, pixel_bytes) catch @trap();
    if (pixel_end > input_size) @trap();

    const top_down = height_signed < 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const source_y = if (top_down) y else height - 1 - y;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const source = pixel_offset + (source_y * width + x) * 4;
            const target = ktx.HEADER_SIZE + (y * width + x) * 4;
            output_buf[target] = input_buf[source + 2];
            output_buf[target + 1] = input_buf[source + 1];
            output_buf[target + 2] = input_buf[source];
            output_buf[target + 3] = input_buf[source + 3];
        }
    }
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
