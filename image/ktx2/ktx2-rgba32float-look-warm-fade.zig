//! Applies an authored 17x17x17 "Warm Fade" LUT to the canonical QIP linear
//! RGBA32F KTX2 profile. The LUT adds a restrained S-curve, slightly muted
//! colour, cool shadows, and warm highlights. Alpha and the KTX2 container are
//! preserved. Values outside [0, 1] retain their distance from the LUT domain.

const std = @import("std");
const ktx = @import("ktx2_rgba32float");

const CAP: usize = ktx.MAX_FILE_SIZE;
const CONTENT_TYPE = ktx.CONTENT_TYPE;
const LUT_SIZE: usize = 17;
const LUT_ENTRIES: usize = LUT_SIZE * LUT_SIZE * LUT_SIZE;

var input_buf: [CAP]u8 = undefined;
var output_buf: [CAP]u8 = undefined;
var strength: f32 = 1.0;

const Color = @Vector(3, f32);

fn clamp01(value: f32) f32 {
    return @min(1.0, @max(0.0, value));
}

fn authoredLook(input: Color) Color {
    const luminance = input[0] * 0.2126 + input[1] * 0.7152 + input[2] * 0.0722;
    var color = input * @as(Color, @splat(0.92)) + @as(Color, @splat(luminance * 0.08));
    var channel: usize = 0;
    while (channel < 3) : (channel += 1) {
        const value = color[channel];
        const centered = value - 0.5;
        color[channel] = value + centered * (1.0 - @abs(centered) * 2.0) * 0.14;
    }
    const shadow = (1.0 - luminance) * (1.0 - luminance);
    const highlight = luminance * luminance;
    color += Color{
        0.010 * shadow + 0.024 * highlight,
        0.004 * highlight,
        0.018 * shadow - 0.020 * highlight,
    };
    color = color * @as(Color, @splat(0.965)) + Color{ 0.014, 0.012, 0.016 };
    return Color{ clamp01(color[0]), clamp01(color[1]), clamp01(color[2]) };
}

const LUT = blk: {
    @setEvalBranchQuota(200_000);
    var entries: [LUT_ENTRIES]Color = undefined;
    var blue: usize = 0;
    while (blue < LUT_SIZE) : (blue += 1) {
        var green: usize = 0;
        while (green < LUT_SIZE) : (green += 1) {
            var red: usize = 0;
            while (red < LUT_SIZE) : (red += 1) {
                const index = (blue * LUT_SIZE + green) * LUT_SIZE + red;
                entries[index] = authoredLook(.{
                    @as(f32, @floatFromInt(red)) / @as(f32, LUT_SIZE - 1),
                    @as(f32, @floatFromInt(green)) / @as(f32, LUT_SIZE - 1),
                    @as(f32, @floatFromInt(blue)) / @as(f32, LUT_SIZE - 1),
                });
            }
        }
    }
    break :blk entries;
};

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

export fn uniform_set_strength(value: f32) f32 {
    strength = if (std.math.isFinite(value)) @min(1.0, @max(0.0, value)) else 1.0;
    return strength;
}

fn table(red: usize, green: usize, blue: usize) Color {
    return LUT[(blue * LUT_SIZE + green) * LUT_SIZE + red];
}

fn lookup(input: Color) Color {
    const clamped = Color{ clamp01(input[0]), clamp01(input[1]), clamp01(input[2]) };
    const scaled = clamped * @as(Color, @splat(@as(f32, LUT_SIZE - 1)));
    const r0: usize = @intFromFloat(@floor(scaled[0]));
    const g0: usize = @intFromFloat(@floor(scaled[1]));
    const b0: usize = @intFromFloat(@floor(scaled[2]));
    const r1 = @min(r0 + 1, LUT_SIZE - 1);
    const g1 = @min(g0 + 1, LUT_SIZE - 1);
    const b1 = @min(b0 + 1, LUT_SIZE - 1);
    const fraction = scaled - Color{
        @floatFromInt(r0),
        @floatFromInt(g0),
        @floatFromInt(b0),
    };
    const one = @as(Color, @splat(1.0));
    const c00 = table(r0, g0, b0) * @as(Color, @splat(one[0] - fraction[0])) + table(r1, g0, b0) * @as(Color, @splat(fraction[0]));
    const c10 = table(r0, g1, b0) * @as(Color, @splat(one[0] - fraction[0])) + table(r1, g1, b0) * @as(Color, @splat(fraction[0]));
    const c01 = table(r0, g0, b1) * @as(Color, @splat(one[0] - fraction[0])) + table(r1, g0, b1) * @as(Color, @splat(fraction[0]));
    const c11 = table(r0, g1, b1) * @as(Color, @splat(one[0] - fraction[0])) + table(r1, g1, b1) * @as(Color, @splat(fraction[0]));
    const c0 = c00 * @as(Color, @splat(one[1] - fraction[1])) + c10 * @as(Color, @splat(fraction[1]));
    const c1 = c01 * @as(Color, @splat(one[1] - fraction[1])) + c11 * @as(Color, @splat(fraction[1]));
    const mapped = c0 * @as(Color, @splat(one[2] - fraction[2])) + c1 * @as(Color, @splat(fraction[2]));
    return mapped + (input - clamped);
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > CAP) @trap();
    const input_image = ktx.parse(input_buf[0..input_size]) orelse @trap();
    _ = ktx.writeHeader(&output_buf, input_image.width, input_image.height) orelse @trap();
    const output_image = ktx.parse(output_buf[0..input_size]) orelse @trap();
    const amount = strength;
    const inverse = 1.0 - amount;
    var pixel: usize = 0;
    const pixel_count = input_image.width * input_image.height;
    while (pixel < pixel_count) : (pixel += 1) {
        const offset = pixel * 4;
        const original = Color{ input_image.pixels[offset], input_image.pixels[offset + 1], input_image.pixels[offset + 2] };
        if (!std.math.isFinite(original[0]) or !std.math.isFinite(original[1]) or !std.math.isFinite(original[2])) @trap();
        const mapped = lookup(original);
        const result = original * @as(Color, @splat(inverse)) + mapped * @as(Color, @splat(amount));
        output_image.pixels[offset] = result[0];
        output_image.pixels[offset + 1] = result[1];
        output_image.pixels[offset + 2] = result[2];
        output_image.pixels[offset + 3] = input_image.pixels[offset + 3];
    }
    return input_size_in;
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
