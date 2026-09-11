//! Rotates canonical RGBA8 sRGB KTX2 images by right angles and optionally
//! flips the rotated image horizontally and vertically.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const INPUT_CAP = ktx.MAX_FILE_SIZE;
const OUTPUT_CAP = ktx.MAX_FILE_SIZE;
const CONTENT_TYPE = ktx.CONTENT_TYPE;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var rotation_degrees: u32 = 0;
var flip_horizontal: bool = false;
var flip_vertical: bool = false;

export fn input_ptr() u32 { return @intCast(@intFromPtr(&input_buf)); }
export fn input_bytes_cap() u32 { return INPUT_CAP; }
export fn output_bytes_cap() u32 { return OUTPUT_CAP; }
export fn input_content_type_ptr() u32 { return @intCast(@intFromPtr(CONTENT_TYPE.ptr)); }
export fn input_content_type_size() u32 { return CONTENT_TYPE.len; }
export fn output_content_type_ptr() u32 { return @intCast(@intFromPtr(CONTENT_TYPE.ptr)); }
export fn output_content_type_size() u32 { return CONTENT_TYPE.len; }

/// Applies one of 0, 90, 180, or 270 degrees clockwise. Other values apply 0.
export fn uniform_set_rotation_degrees(value: u32) u32 {
    rotation_degrees = switch (value) {
        90, 180, 270 => value,
        else => 0,
    };
    return rotation_degrees;
}

export fn uniform_set_flip_horizontal(value: u32) u32 {
    flip_horizontal = value != 0;
    return @intFromBool(flip_horizontal);
}

export fn uniform_set_flip_vertical(value: u32) u32 {
    flip_vertical = value != 0;
    return @intFromBool(flip_vertical);
}

fn resetUniforms() void {
    rotation_degrees = 0;
    flip_horizontal = false;
    flip_vertical = false;
}

fn sourceOffset(source_width: usize, source_height: usize, x: usize, y: usize) usize {
    const flipped_x = if (flip_horizontal) (if (rotation_degrees == 90 or rotation_degrees == 270) source_height else source_width) - 1 - x else x;
    const flipped_y = if (flip_vertical) (if (rotation_degrees == 90 or rotation_degrees == 270) source_width else source_height) - 1 - y else y;
    const source_x, const source_y = switch (rotation_degrees) {
        90 => .{ flipped_y, source_height - 1 - flipped_x },
        180 => .{ source_width - 1 - flipped_x, source_height - 1 - flipped_y },
        270 => .{ source_width - 1 - flipped_y, flipped_x },
        else => .{ flipped_x, flipped_y },
    };
    return ktx.HEADER_SIZE + (source_y * source_width + source_x) * 4;
}

fn renderImpl(input_size_in: u32) u32 {
    defer resetUniforms();
    const input_size: usize = input_size_in;
    if (input_size > INPUT_CAP) @trap();
    const image = ktx.parse(input_buf[0..input_size]) orelse @trap();
    const output_width = if (rotation_degrees == 90 or rotation_degrees == 270) image.height else image.width;
    const output_height = if (rotation_degrees == 90 or rotation_degrees == 270) image.width else image.height;
    const output_size = ktx.writeHeader(output_buf[0..], output_width, output_height) orelse @trap();

    var y: usize = 0;
    while (y < output_height) : (y += 1) {
        var x: usize = 0;
        while (x < output_width) : (x += 1) {
            const source = sourceOffset(image.width, image.height, x, y);
            const target = ktx.HEADER_SIZE + (y * output_width + x) * 4;
            @memcpy(output_buf[target .. target + 4], input_buf[source .. source + 4]);
        }
    }
    return @intCast(output_size);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{ .output_size = renderImpl(input_size_in), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "rotates clockwise before a horizontal flip" {
    const input_size = ktx.writeHeader(input_buf[0..], 2, 3) orelse unreachable;
    var pixel: usize = 0;
    while (pixel < 6) : (pixel += 1) {
        const offset = ktx.HEADER_SIZE + pixel * 4;
        input_buf[offset] = @intCast(pixel + 1);
        input_buf[offset + 1] = 0;
        input_buf[offset + 2] = 0;
        input_buf[offset + 3] = 255;
    }
    try std.testing.expectEqual(@as(u32, 90), uniform_set_rotation_degrees(90));
    _ = uniform_set_flip_horizontal(1);
    const output_size = renderImpl(@intCast(input_size));
    const output = ktx.parse(output_buf[0..output_size]) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), output.width);
    try std.testing.expectEqual(@as(usize, 2), output.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 5, 2, 4, 6 }, &[_]u8{
        output.pixels[0], output.pixels[4], output.pixels[8], output.pixels[12], output.pixels[16], output.pixels[20],
    });
}

test "resets transforms after rendering" {
    const input_size = ktx.writeHeader(input_buf[0..], 2, 1) orelse unreachable;
    @memcpy(input_buf[ktx.HEADER_SIZE..input_size], &[_]u8{ 1, 0, 0, 255, 2, 0, 0, 255 });
    _ = uniform_set_flip_horizontal(1);
    _ = renderImpl(@intCast(input_size));
    const output_size = renderImpl(@intCast(input_size));
    try std.testing.expectEqualSlices(u8, input_buf[ktx.HEADER_SIZE..input_size], output_buf[ktx.HEADER_SIZE..output_size]);
}
