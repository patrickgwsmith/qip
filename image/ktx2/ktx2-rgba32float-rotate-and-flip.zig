//! Rotates supported RGBA32F KTX2 profiles by right angles and optionally
//! flips the rotated image horizontally and vertically.

const std = @import("std");
const bt709 = @import("ktx2_rgba32float");
const display_p3_linear = @import("ktx2_rgba32float_display_p3_linear");
const display_p3 = @import("ktx2_rgba32float_display_p3");

const INPUT_CAP = bt709.MAX_FILE_SIZE;
const OUTPUT_CAP = bt709.MAX_FILE_SIZE;
const CONTENT_TYPE = bt709.CONTENT_TYPE;
const HEADER_SIZE = bt709.HEADER_SIZE;

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
    return HEADER_SIZE + (source_y * source_width + source_x) * 16;
}

const Dimensions = struct { width: usize, height: usize };

fn parseSupported(input: []u8) ?Dimensions {
    if (bt709.parse(input)) |image| return .{ .width = image.width, .height = image.height };
    if (display_p3_linear.parse(input)) |image| return .{ .width = image.width, .height = image.height };
    if (display_p3.parse(input)) |image| return .{ .width = image.width, .height = image.height };
    return null;
}

fn renderImpl(input_size_in: u32) u32 {
    defer resetUniforms();
    const input_size: usize = input_size_in;
    if (input_size > INPUT_CAP) @trap();
    const image = parseSupported(input_buf[0..input_size]) orelse @trap();
    const output_width = if (rotation_degrees == 90 or rotation_degrees == 270) image.height else image.width;
    const output_height = if (rotation_degrees == 90 or rotation_degrees == 270) image.width else image.height;
    @memcpy(output_buf[0..HEADER_SIZE], input_buf[0..HEADER_SIZE]);
    std.mem.writeInt(u32, output_buf[20..24], @intCast(output_width), .little);
    std.mem.writeInt(u32, output_buf[24..28], @intCast(output_height), .little);

    var y: usize = 0;
    while (y < output_height) : (y += 1) {
        var x: usize = 0;
        while (x < output_width) : (x += 1) {
            const source = sourceOffset(image.width, image.height, x, y);
            const target = HEADER_SIZE + (y * output_width + x) * 16;
            @memcpy(output_buf[target .. target + 16], input_buf[source .. source + 16]);
        }
    }
    return @intCast(input_size);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{ .output_size = renderImpl(input_size_in), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "rotates clockwise before a horizontal flip" {
    const input_size = bt709.writeHeader(input_buf[0..], 2, 3) orelse unreachable;
    var pixel: usize = 0;
    while (pixel < 6) : (pixel += 1) {
        const offset = HEADER_SIZE + pixel * 16;
        input_buf[offset] = @intCast(pixel + 1);
        input_buf[offset + 1] = 0;
        input_buf[offset + 2] = 0;
        @memset(input_buf[offset + 1 .. offset + 16], 0);
    }
    try std.testing.expectEqual(@as(u32, 90), uniform_set_rotation_degrees(90));
    _ = uniform_set_flip_horizontal(1);
    const output_size = renderImpl(@intCast(input_size));
    const output = bt709.parse(output_buf[0..output_size]) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), output.width);
    try std.testing.expectEqual(@as(usize, 2), output.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 5, 2, 4, 6 }, &[_]u8{
        output_buf[HEADER_SIZE], output_buf[HEADER_SIZE + 16], output_buf[HEADER_SIZE + 32],
        output_buf[HEADER_SIZE + 48], output_buf[HEADER_SIZE + 64], output_buf[HEADER_SIZE + 80],
    });
}

test "resets transforms after rendering" {
    const input_size = bt709.writeHeader(input_buf[0..], 2, 1) orelse unreachable;
    @memset(input_buf[HEADER_SIZE..input_size], 0);
    input_buf[HEADER_SIZE] = 1;
    input_buf[HEADER_SIZE + 16] = 2;
    _ = uniform_set_flip_horizontal(1);
    _ = renderImpl(@intCast(input_size));
    const output_size = renderImpl(@intCast(input_size));
    try std.testing.expectEqualSlices(u8, input_buf[HEADER_SIZE..input_size], output_buf[HEADER_SIZE..output_size]);
}

test "preserves linear and transfer-encoded Display P3 profile metadata" {
    inline for (.{ display_p3_linear.writeHeader, display_p3.writeHeader }) |write_header| {
        const input_size = write_header(input_buf[0..], 2, 1) orelse unreachable;
        @memset(input_buf[HEADER_SIZE..input_size], 0);
        const dfd = input_buf[104..196];
        _ = uniform_set_rotation_degrees(90);
        const output_size = renderImpl(@intCast(input_size));
        try std.testing.expectEqualSlices(u8, dfd, output_buf[104..196]);
        try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, output_buf[20..24], .little));
        try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, output_buf[24..28], .little));
        try std.testing.expectEqual(@as(usize, input_size), output_size);
        try std.testing.expect(parseSupported(output_buf[0..output_size]) != null);
    }
}
