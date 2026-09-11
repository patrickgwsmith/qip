//! Converts canonical VK_FORMAT_R8G8B8A8_SRGB KTX2 to QIP's bottom-up
//! 32-bit BGRA BMP.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const INPUT_CAP: usize = ktx.MAX_FILE_SIZE;
const OUTPUT_CAP: usize = 54 + ktx.MAX_PIXELS * 4;
const INPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const OUTPUT_CONTENT_TYPE = "image/bmp";

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
    const pixel_count = std.math.mul(usize, image.width, image.height) catch @trap();
    const pixel_bytes = std.math.mul(usize, pixel_count, 4) catch @trap();
    const output_size = 54 + pixel_bytes;

    @memset(output_buf[0..54], 0);
    output_buf[0] = 'B';
    output_buf[1] = 'M';
    writeU32(2, @intCast(output_size));
    writeU32(10, 54);
    writeU32(14, 40);
    writeU32(18, @intCast(image.width));
    writeU32(22, @intCast(image.height));
    writeU16(26, 1);
    writeU16(28, 32);
    writeU32(34, @intCast(pixel_bytes));

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        const target_y = image.height - 1 - y;
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const source = (y * image.width + x) * 4;
            const target = 54 + (target_y * image.width + x) * 4;
            output_buf[target] = image.pixels[source + 2];
            output_buf[target + 1] = image.pixels[source + 1];
            output_buf[target + 2] = image.pixels[source];
            output_buf[target + 3] = image.pixels[source + 3];
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
