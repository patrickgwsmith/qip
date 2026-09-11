//! Generates a solid, straight-alpha linear Display P3 RGBA32F KTX2 surface.
//! `color_rgba` is transfer-encoded Display P3 in `0xRRGGBBAA` order.

const std = @import("std");
const ktx = @import("ktx2_rgba32float_display_p3_linear");

const MAX_PIXELS: usize = 8_000_000;
const CAP: usize = ktx.HEADER_SIZE + MAX_PIXELS * 16;
const DEFAULT_WIDTH: u32 = 1200;
const DEFAULT_HEIGHT: u32 = 630;
const CONTENT_TYPE = ktx.CONTENT_TYPE;

var buffer: [CAP]u8 align(16) = undefined;
var width: u32 = DEFAULT_WIDTH;
var height: u32 = DEFAULT_HEIGHT;
var color_rgba: u32 = 0x000000ff;

export fn output_bytes_cap() u32 {
    return CAP;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn uniform_set_width(value: u32) u32 {
    width = @max(1, @min(value, ktx.MAX_DIMENSION));
    return width;
}

export fn uniform_set_height(value: u32) u32 {
    height = @max(1, @min(value, ktx.MAX_DIMENSION));
    return height;
}

export fn uniform_set_color_rgba(value: u32) u32 {
    color_rgba = value;
    return color_rgba;
}

fn channel(value: u32, shift: u5) f32 {
    const encoded: f32 = @as(f32, @floatFromInt((value >> shift) & 0xff)) / 255.0;
    return ktx.srgbToLinear(encoded);
}

fn renderImpl() u32 {
    const total_size = ktx.writeHeader(&buffer, width, height) orelse return 0;
    const pixels: [*]align(1) f32 = @ptrCast(buffer[ktx.HEADER_SIZE..total_size].ptr);
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const red = channel(color_rgba, 24);
    const green = channel(color_rgba, 16);
    const blue = channel(color_rgba, 8);
    const alpha: f32 = @as(f32, @floatFromInt(color_rgba & 0xff)) / 255.0;

    for (0..pixel_count) |pixel| {
        const offset = pixel * 4;
        pixels[offset] = red;
        pixels[offset + 1] = green;
        pixels[offset + 2] = blue;
        pixels[offset + 3] = alpha;
    }
    return @intCast(total_size);
}

export fn render(_: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const output_size = renderImpl();
    return .{
        .output_size = output_size,
        .output_ptr = @intCast(@intFromPtr(&buffer)),
        .failed = @intFromBool(output_size == 0),
    };
}

test "renders the selected size and color" {
    _ = uniform_set_width(2);
    _ = uniform_set_height(1);
    _ = uniform_set_color_rgba(0xff000080);
    const output_size = renderImpl();
    try std.testing.expectEqual(@as(u32, ktx.HEADER_SIZE + 32), output_size);
    const image = ktx.parse(buffer[0..output_size]).?;
    try std.testing.expectEqual(@as(usize, 2), image.width);
    try std.testing.expectEqual(@as(usize, 1), image.height);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), image.pixels[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), image.pixels[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), image.pixels[3], 0.0001);
}
