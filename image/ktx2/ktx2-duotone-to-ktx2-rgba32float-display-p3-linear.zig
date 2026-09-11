//! Maps RGBA8 sRGB or linear Display P3 RGBA32F luminance between two authored
//! colors. Alpha is preserved and the output is linear Display P3 RGBA32F.

const std = @import("std");
const ktx_hdr = @import("ktx2_rgba32float_display_p3_linear");
const ktx_sdr = @import("ktx2_rgba8_srgb");

const MAX_PIXELS: usize = 1_000_000;
const CAP: usize = ktx_hdr.HEADER_SIZE + MAX_PIXELS * 16;
const CONTENT_TYPE = ktx_hdr.CONTENT_TYPE;
const Color = @Vector(3, f32);
const Lanes = @Vector(4, f32);

var input_buf: [CAP]u8 align(16) = undefined;
var output_buf: [CAP]u8 align(16) = undefined;
var shadow = Color{ 0.004, 0.0, 0.006 };
var highlight = Color{ 2.40, 0.12, 0.75 };
var input_white: f32 = 1.0;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_bytes_cap() u32 {
    return CAP;
}
export fn output_bytes_cap() u32 {
    return CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn uniform_set_shadow_r(value: f32) f32 {
    shadow[0] = finite(value, 0.004);
    return shadow[0];
}
export fn uniform_set_shadow_g(value: f32) f32 {
    shadow[1] = finite(value, 0.0);
    return shadow[1];
}
export fn uniform_set_shadow_b(value: f32) f32 {
    shadow[2] = finite(value, 0.006);
    return shadow[2];
}
export fn uniform_set_highlight_r(value: f32) f32 {
    highlight[0] = finite(value, 2.40);
    return highlight[0];
}
export fn uniform_set_highlight_g(value: f32) f32 {
    highlight[1] = finite(value, 0.12);
    return highlight[1];
}
export fn uniform_set_highlight_b(value: f32) f32 {
    highlight[2] = finite(value, 0.75);
    return highlight[2];
}
export fn uniform_set_input_white(value: f32) f32 {
    input_white = if (std.math.isFinite(value) and value > 0.0001) value else 1.0;
    return input_white;
}

fn finite(value: f32, fallback: f32) f32 {
    return if (std.math.isFinite(value)) value else fallback;
}

fn lanesFinite(values: Lanes) bool {
    const maximum: Lanes = @splat(std.math.floatMax(f32));
    return @reduce(.And, @abs(values) <= maximum);
}

fn mapLanes(red: Lanes, green: Lanes, blue: Lanes, alpha: Lanes, output_pixels: []align(1) f32, pixel: usize, span: Color, weights: Color) void {
    if (!lanesFinite(red) or !lanesFinite(green) or !lanesFinite(blue) or !lanesFinite(alpha)) @trap();
    const first = pixel * 4;
    const zero: Lanes = @splat(0.0);
    const one: Lanes = @splat(1.0);
    const luminance = red * @as(Lanes, @splat(weights[0])) +
        green * @as(Lanes, @splat(weights[1])) +
        blue * @as(Lanes, @splat(weights[2]));
    const amount = @min(one, @max(zero, luminance / @as(Lanes, @splat(input_white))));
    const mapped_red = @as(Lanes, @splat(shadow[0])) + @as(Lanes, @splat(span[0])) * amount;
    const mapped_green = @as(Lanes, @splat(shadow[1])) + @as(Lanes, @splat(span[1])) * amount;
    const mapped_blue = @as(Lanes, @splat(shadow[2])) + @as(Lanes, @splat(span[2])) * amount;

    var lane: usize = 0;
    while (lane < 4) : (lane += 1) {
        const offset = first + lane * 4;
        output_pixels[offset] = mapped_red[lane];
        output_pixels[offset + 1] = mapped_green[lane];
        output_pixels[offset + 2] = mapped_blue[lane];
        output_pixels[offset + 3] = alpha[lane];
    }
}

fn mapFourHDR(input_pixels: []align(1) const f32, output_pixels: []align(1) f32, pixel: usize, span: Color) void {
    const first = pixel * 4;
    mapLanes(
        .{ input_pixels[first], input_pixels[first + 4], input_pixels[first + 8], input_pixels[first + 12] },
        .{ input_pixels[first + 1], input_pixels[first + 5], input_pixels[first + 9], input_pixels[first + 13] },
        .{ input_pixels[first + 2], input_pixels[first + 6], input_pixels[first + 10], input_pixels[first + 14] },
        .{ input_pixels[first + 3], input_pixels[first + 7], input_pixels[first + 11], input_pixels[first + 15] },
        output_pixels,
        pixel,
        span,
        .{ 0.2289746, 0.6917385, 0.0792869 },
    );
}

fn mapFourSDR(input_pixels: []const u8, output_pixels: []align(1) f32, pixel: usize, span: Color) void {
    const first = pixel * 4;
    const alpha_scale: f32 = 1.0 / 255.0;
    mapLanes(
        .{ ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 4]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 8]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 12]] },
        .{ ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 1]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 5]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 9]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 13]] },
        .{ ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 2]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 6]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 10]], ktx_hdr.SRGB8_TO_LINEAR[input_pixels[first + 14]] },
        .{ @as(f32, @floatFromInt(input_pixels[first + 3])) * alpha_scale, @as(f32, @floatFromInt(input_pixels[first + 7])) * alpha_scale, @as(f32, @floatFromInt(input_pixels[first + 11])) * alpha_scale, @as(f32, @floatFromInt(input_pixels[first + 15])) * alpha_scale },
        output_pixels,
        pixel,
        span,
        .{ 0.2126, 0.7152, 0.0722 },
    );
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > CAP) @trap();
    if (input_size < 28) @trap();
    const vk_format = std.mem.readInt(u32, input_buf[12..16], .little);
    const width: usize = std.mem.readInt(u32, input_buf[20..24], .little);
    const height: usize = std.mem.readInt(u32, input_buf[24..28], .little);
    const pixel_count = std.math.mul(usize, width, height) catch @trap();
    if (pixel_count > MAX_PIXELS) @trap();
    const output_size = ktx_hdr.writeHeader(&output_buf, width, height) orelse @trap();
    const output_image = ktx_hdr.parse(output_buf[0..output_size]) orelse @trap();
    const span = highlight - shadow;

    if (vk_format == 43) {
        const input_image = ktx_sdr.parse(input_buf[0..input_size]) orelse @trap();
        var pixel: usize = 0;
        while (pixel + 4 <= pixel_count) : (pixel += 4) {
            mapFourSDR(input_image.pixels, output_image.pixels, pixel, span);
        }
        while (pixel < pixel_count) : (pixel += 1) {
            const offset = pixel * 4;
            const red = ktx_hdr.SRGB8_TO_LINEAR[input_image.pixels[offset]];
            const green = ktx_hdr.SRGB8_TO_LINEAR[input_image.pixels[offset + 1]];
            const blue = ktx_hdr.SRGB8_TO_LINEAR[input_image.pixels[offset + 2]];
            const luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
            const amount = @min(1.0, @max(0.0, luminance / input_white));
            const mapped = shadow + span * @as(Color, @splat(amount));
            output_image.pixels[offset] = mapped[0];
            output_image.pixels[offset + 1] = mapped[1];
            output_image.pixels[offset + 2] = mapped[2];
            output_image.pixels[offset + 3] = @as(f32, @floatFromInt(input_image.pixels[offset + 3])) / 255.0;
        }
    } else if (vk_format == 109) {
        const input_image = ktx_hdr.parse(input_buf[0..input_size]) orelse @trap();
        var pixel: usize = 0;
        while (pixel + 4 <= pixel_count) : (pixel += 4) {
            mapFourHDR(input_image.pixels, output_image.pixels, pixel, span);
        }
        while (pixel < pixel_count) : (pixel += 1) {
            const offset = pixel * 4;
            const red = input_image.pixels[offset];
            const green = input_image.pixels[offset + 1];
            const blue = input_image.pixels[offset + 2];
            const alpha = input_image.pixels[offset + 3];
            if (!std.math.isFinite(red) or !std.math.isFinite(green) or
                !std.math.isFinite(blue) or !std.math.isFinite(alpha)) @trap();
            const luminance = red * 0.2289746 + green * 0.6917385 + blue * 0.0792869;
            const amount = @min(1.0, @max(0.0, luminance / input_white));
            const mapped = shadow + span * @as(Color, @splat(amount));
            output_image.pixels[offset] = mapped[0];
            output_image.pixels[offset + 1] = mapped[1];
            output_image.pixels[offset + 2] = mapped[2];
            output_image.pixels[offset + 3] = alpha;
        }
    } else {
        @trap();
    }
    return @intCast(output_size);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "duotone maps black and white while preserving alpha" {
    const size = ktx_hdr.writeHeader(&input_buf, 2, 1).?;
    const input = ktx_hdr.parse(input_buf[0..size]).?;
    input.pixels[0] = 0;
    input.pixels[1] = 0;
    input.pixels[2] = 0;
    input.pixels[3] = 0.25;
    input.pixels[4] = 1;
    input.pixels[5] = 1;
    input.pixels[6] = 1;
    input.pixels[7] = 0.75;
    const output_size = renderImpl(@intCast(size));
    const result = ktx_hdr.parse(output_buf[0..output_size]).?;
    try std.testing.expectApproxEqAbs(shadow[0], result.pixels[0], 0.0001);
    try std.testing.expectApproxEqAbs(shadow[1], result.pixels[1], 0.0001);
    try std.testing.expectApproxEqAbs(shadow[2], result.pixels[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), result.pixels[3], 0.0001);
    try std.testing.expectApproxEqAbs(highlight[0], result.pixels[4], 0.0001);
    try std.testing.expectApproxEqAbs(highlight[1], result.pixels[5], 0.0001);
    try std.testing.expectApproxEqAbs(highlight[2], result.pixels[6], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), result.pixels[7], 0.0001);
}

test "RGBA8 white becomes HDR pink" {
    const size = ktx_sdr.writeHeader(&input_buf, 1, 1).?;
    const input = ktx_sdr.parse(input_buf[0..size]).?;
    input.pixels[0] = 255;
    input.pixels[1] = 255;
    input.pixels[2] = 255;
    input.pixels[3] = 255;
    const output_size = renderImpl(@intCast(size));
    const result = ktx_hdr.parse(output_buf[0..output_size]).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.40), result.pixels[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), result.pixels[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), result.pixels[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.pixels[3], 0.0001);
}
