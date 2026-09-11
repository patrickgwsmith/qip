//! Generates a solid, straight-alpha linear Display P3 RGBA32F KTX2 surface.
//! The color uniforms are CSS-style OKLCH: lightness 0 through 1, chroma, and
//! hue in degrees. Colours outside Display P3 retain lightness and hue while
//! their chroma is reduced to the Display P3 gamut boundary.

const std = @import("std");
const ktx = @import("ktx2_rgba32float_display_p3_linear");

const MAX_PIXELS: usize = 8_000_000;
const CAP: usize = ktx.HEADER_SIZE + MAX_PIXELS * 16;
const DEFAULT_WIDTH: u32 = 1200;
const DEFAULT_HEIGHT: u32 = 630;
const DEFAULT_LIGHTNESS: f32 = 0.5;
const DEFAULT_CHROMA: f32 = 0.0;
const DEFAULT_HUE_DEGREES: f32 = 0.0;
const DEFAULT_ALPHA: f32 = 1.0;
const CONTENT_TYPE = ktx.CONTENT_TYPE;
const TAU: f32 = 2.0 * std.math.pi;

const Color = struct {
    red: f32,
    green: f32,
    blue: f32,
};

var buffer: [CAP]u8 align(16) = undefined;
var width: u32 = DEFAULT_WIDTH;
var height: u32 = DEFAULT_HEIGHT;
var lightness: f32 = DEFAULT_LIGHTNESS;
var chroma: f32 = DEFAULT_CHROMA;
var hue_degrees: f32 = DEFAULT_HUE_DEGREES;
var alpha: f32 = DEFAULT_ALPHA;

fn resetUniforms() void {
    width = DEFAULT_WIDTH;
    height = DEFAULT_HEIGHT;
    lightness = DEFAULT_LIGHTNESS;
    chroma = DEFAULT_CHROMA;
    hue_degrees = DEFAULT_HUE_DEGREES;
    alpha = DEFAULT_ALPHA;
}

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

export fn uniform_set_lightness(value: f32) f32 {
    lightness = if (std.math.isFinite(value)) @max(0.0, @min(value, 1.0)) else 0.5;
    return lightness;
}

export fn uniform_set_chroma(value: f32) f32 {
    // No in-gamut Display P3 colour needs more than 0.5 OKLCH chroma.
    chroma = if (std.math.isFinite(value)) @max(0.0, @min(value, 0.5)) else 0.0;
    return chroma;
}

export fn uniform_set_hue_degrees(value: f32) f32 {
    if (!std.math.isFinite(value)) {
        hue_degrees = 0.0;
    } else {
        hue_degrees = value - 360.0 * @floor(value / 360.0);
    }
    return hue_degrees;
}

export fn uniform_set_alpha(value: f32) f32 {
    alpha = if (std.math.isFinite(value)) @max(0.0, @min(value, 1.0)) else 1.0;
    return alpha;
}

fn oklchToLinearDisplayP3(l: f32, c: f32, h_degrees: f32) Color {
    const h = h_degrees * TAU / 360.0;
    const a = c * std.math.cos(h);
    const b = c * std.math.sin(h);

    // OKLab to XYZ D65. The matrices are the revised 2021 OKLab values.
    const lms_l = l + 0.3963377774 * a + 0.2158037573 * b;
    const lms_m = l - 0.1055613458 * a - 0.0638541728 * b;
    const lms_s = l - 0.0894841775 * a - 1.2914855480 * b;
    const lms_l3 = lms_l * lms_l * lms_l;
    const lms_m3 = lms_m * lms_m * lms_m;
    const lms_s3 = lms_s * lms_s * lms_s;
    const x = 1.2270138511 * lms_l3 - 0.5577999807 * lms_m3 + 0.2812561490 * lms_s3;
    const y = -0.0405801784 * lms_l3 + 1.1122568696 * lms_m3 - 0.0716766787 * lms_s3;
    const z = -0.0763812845 * lms_l3 - 0.4214819784 * lms_m3 + 1.5861632204 * lms_s3;

    // XYZ D65 to linear Display P3.
    return .{
        .red = 2.4934969119 * x - 0.9313836179 * y - 0.4027107845 * z,
        .green = -0.8294889696 * x + 1.7626640603 * y + 0.0236246858 * z,
        .blue = 0.0358458302 * x - 0.0761723893 * y + 0.9568845240 * z,
    };
}

fn isInDisplayP3(color: Color) bool {
    return std.math.isFinite(color.red) and std.math.isFinite(color.green) and std.math.isFinite(color.blue) and
        color.red >= 0.0 and color.red <= 1.0 and
        color.green >= 0.0 and color.green <= 1.0 and
        color.blue >= 0.0 and color.blue <= 1.0;
}

fn gamutMapToDisplayP3(l: f32, requested_chroma: f32, h: f32) Color {
    const requested = oklchToLinearDisplayP3(l, requested_chroma, h);
    if (isInDisplayP3(requested)) return requested;

    var low: f32 = 0.0;
    var high = requested_chroma;
    for (0..24) |_| {
        const middle = (low + high) * 0.5;
        if (isInDisplayP3(oklchToLinearDisplayP3(l, middle, h))) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return oklchToLinearDisplayP3(l, low, h);
}

fn renderImpl() u32 {
    const total_size = ktx.writeHeader(&buffer, width, height) orelse return 0;
    const pixels: [*]align(1) f32 = @ptrCast(buffer[ktx.HEADER_SIZE..total_size].ptr);
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const color = gamutMapToDisplayP3(lightness, chroma, hue_degrees);

    for (0..pixel_count) |pixel| {
        const offset = pixel * 4;
        pixels[offset] = color.red;
        pixels[offset + 1] = color.green;
        pixels[offset + 2] = color.blue;
        pixels[offset + 3] = alpha;
    }
    return @intCast(total_size);
}

export fn render(_: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    defer resetUniforms();
    const output_size = renderImpl();
    return .{
        .output_size = output_size,
        .output_ptr = @intCast(@intFromPtr(&buffer)),
        .failed = @intFromBool(output_size == 0),
    };
}

test "maps neutral OKLCH to neutral linear Display P3" {
    const color = gamutMapToDisplayP3(0.5, 0.0, 0.0);
    try std.testing.expectApproxEqAbs(color.red, color.green, 0.0001);
    try std.testing.expectApproxEqAbs(color.green, color.blue, 0.0001);
    try std.testing.expect(color.red > 0.0 and color.red < 1.0);
}

test "reduces out-of-gamut chroma" {
    const requested = oklchToLinearDisplayP3(0.7, 0.5, 30.0);
    try std.testing.expect(!isInDisplayP3(requested));
    const mapped = gamutMapToDisplayP3(0.7, 0.5, 30.0);
    try std.testing.expect(isInDisplayP3(mapped));
}

test "renders straight alpha KTX2 pixels" {
    _ = uniform_set_width(2);
    _ = uniform_set_height(1);
    _ = uniform_set_lightness(0.7);
    _ = uniform_set_chroma(0.5);
    _ = uniform_set_hue_degrees(30.0);
    _ = uniform_set_alpha(0.25);
    const output_size = renderImpl();
    try std.testing.expectEqual(@as(u32, ktx.HEADER_SIZE + 32), output_size);
    const image = ktx.parse(buffer[0..output_size]).?;
    try std.testing.expect(isInDisplayP3(.{ .red = image.pixels[0], .green = image.pixels[1], .blue = image.pixels[2] }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), image.pixels[3], 0.00001);
    try std.testing.expectApproxEqAbs(image.pixels[0], image.pixels[4], 0.00001);
    try std.testing.expectApproxEqAbs(image.pixels[1], image.pixels[5], 0.00001);
    try std.testing.expectApproxEqAbs(image.pixels[2], image.pixels[6], 0.00001);
    try std.testing.expectApproxEqAbs(image.pixels[3], image.pixels[7], 0.00001);
}
