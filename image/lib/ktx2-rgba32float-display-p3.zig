const std = @import("std");
const linear = @import("ktx2_rgba32float_display_p3_linear");

pub const MAX_PIXELS = linear.MAX_PIXELS;
pub const MAX_DIMENSION = linear.MAX_DIMENSION;
pub const HEADER_SIZE = linear.HEADER_SIZE;
pub const MAX_FILE_SIZE = linear.MAX_FILE_SIZE;
pub const CONTENT_TYPE = linear.CONTENT_TYPE;
pub const Image = linear.Image;

const DFD_TRANSFER_OFFSET: usize = 118;
const TRANSFER_LINEAR: u8 = 1;
const TRANSFER_SRGB: u8 = 2;

pub fn fileSize(width: usize, height: usize) ?usize {
    return linear.fileSize(width, height);
}

pub fn writeHeader(output: []u8, width: usize, height: usize) ?usize {
    const size = linear.writeHeader(output, width, height) orelse return null;
    output[DFD_TRANSFER_OFFSET] = TRANSFER_SRGB;
    return size;
}

pub fn parse(data: []u8) ?Image {
    if (data.len <= DFD_TRANSFER_OFFSET or data[DFD_TRANSFER_OFFSET] != TRANSFER_SRGB) return null;
    data[DFD_TRANSFER_OFFSET] = TRANSFER_LINEAR;
    defer data[DFD_TRANSFER_OFFSET] = TRANSFER_SRGB;
    return linear.parse(data);
}

pub fn linearToDisplayP3(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    const magnitude = @abs(value);
    if (magnitude <= 0.0031308) return value * 12.92;
    const encoded = 1.055 * std.math.pow(f32, magnitude, 1.0 / 2.4) - 0.055;
    return if (value < 0) -encoded else encoded;
}

test "writes and parses transfer-encoded Display P3" {
    var output: [HEADER_SIZE + 16]u8 align(16) = undefined;
    const size = writeHeader(&output, 1, 1).?;
    try std.testing.expectEqual(TRANSFER_SRGB, output[DFD_TRANSFER_OFFSET]);
    const image = parse(output[0..size]).?;
    try std.testing.expectEqual(@as(usize, 1), image.width);
    try std.testing.expectEqual(TRANSFER_SRGB, output[DFD_TRANSFER_OFFSET]);
    try std.testing.expect(linearToDisplayP3(2.0) > 1.0);
}
