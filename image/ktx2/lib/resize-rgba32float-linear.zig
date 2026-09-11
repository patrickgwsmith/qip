//! Shared separable resampling for a strict linear RGBA32F KTX2 profile.
//! RGB is premultiplied by alpha while filtering, then returned to straight
//! alpha. RGB remains unclamped so negative and HDR values survive.

const std = @import("std");
const root = @import("root");
const rgba32f = @import("ktx2_rgba32float_profile");

pub const Kernel = enum { lanczos3_down, mitchell_up };
pub const CONTENT_TYPE = rgba32f.CONTENT_TYPE;

const USE_SIMD = @hasDecl(root, "RESIZE_SIMD") and root.RESIZE_SIMD;
const Vec4 = @Vector(4, f32);
const CAP: usize = rgba32f.MAX_FILE_SIZE;
const MAX_PIXELS = rgba32f.MAX_PIXELS;
const MAX_DIMENSION = rgba32f.MAX_DIMENSION;
const MAX_AXIS_WEIGHTS = MAX_DIMENSION * 8;

pub const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

var input: [CAP]u8 align(16) = undefined;
var output: [CAP]u8 align(16) = undefined;
var intermediate: [MAX_PIXELS]f32 align(16) = undefined;
var axis_first: [MAX_DIMENSION]u16 = undefined;
var axis_offsets: [MAX_DIMENSION + 1]u32 = undefined;
var axis_weights: [MAX_AXIS_WEIGHTS]f32 = undefined;
var target_width: u32 = 0;
var target_height: u32 = 0;

pub fn inputPtr() u32 {
    return @intCast(@intFromPtr(&input));
}

pub fn inputBytesCap() u32 {
    return CAP;
}

pub fn outputBytesCap() u32 {
    return CAP;
}

pub fn setWidth(value: u32) u32 {
    target_width = @min(value, MAX_DIMENSION);
    return target_width;
}

pub fn setHeight(value: u32) u32 {
    target_height = @min(value, MAX_DIMENSION);
    return target_height;
}

fn resetUniforms() void {
    target_width = 0;
    target_height = 0;
}

fn rejected() RenderResult {
    return .{ .output_size = 0, .output_ptr = 0, .failed = 1 };
}

fn sinc(value: f32) f32 {
    if (@abs(value) < 0.000001) return 1.0;
    const radians = value * std.math.pi;
    return @sin(radians) / radians;
}

fn lanczos3(value: f32) f32 {
    const distance = @abs(value);
    if (distance >= 3.0) return 0.0;
    return sinc(distance) * sinc(distance / 3.0);
}

fn mitchell(value: f32) f32 {
    const x = @abs(value);
    if (x >= 2.0) return 0.0;
    if (x < 1.0) return ((7.0 * x - 12.0) * x * x + 16.0 / 3.0) / 6.0;
    return (((-7.0 / 3.0 * x + 12.0) * x - 20.0) * x + 32.0 / 3.0) / 6.0;
}

fn buildAxisPlan(source_size: usize, destination_size: usize, comptime kernel: Kernel) void {
    if (source_size == destination_size) {
        var index: usize = 0;
        axis_offsets[0] = 0;
        while (index < destination_size) : (index += 1) {
            axis_first[index] = @intCast(index);
            axis_weights[index] = 1.0;
            axis_offsets[index + 1] = @intCast(index + 1);
        }
        return;
    }
    const scale = @as(f32, @floatFromInt(destination_size)) / @as(f32, @floatFromInt(source_size));
    const radius: f32 = switch (kernel) {
        .lanczos3_down => 3.0 / scale,
        .mitchell_up => 2.0,
    };
    var weight_cursor: usize = 0;
    axis_offsets[0] = 0;

    var destination: usize = 0;
    while (destination < destination_size) : (destination += 1) {
        const center = (@as(f32, @floatFromInt(destination)) + 0.5) / scale - 0.5;
        const first_unclamped: i32 = @intFromFloat(@ceil(center - radius));
        const last_unclamped: i32 = @intFromFloat(@floor(center + radius));
        const first = @max(first_unclamped, 0);
        const last = @min(last_unclamped, @as(i32, @intCast(source_size - 1)));
        if (first > last) @trap();
        axis_first[destination] = @intCast(first);

        const start = weight_cursor;
        const stored_count: usize = @intCast(last - first + 1);
        if (weight_cursor + stored_count > axis_weights.len) @trap();
        @memset(axis_weights[weight_cursor .. weight_cursor + stored_count], 0.0);
        weight_cursor += stored_count;

        var source = first_unclamped;
        while (source <= last_unclamped) : (source += 1) {
            const clamped_source = @min(@max(source, first), last);
            const distance = @as(f32, @floatFromInt(source)) - center;
            const weight = switch (kernel) {
                .lanczos3_down => lanczos3(distance * scale),
                .mitchell_up => mitchell(distance),
            };
            axis_weights[start + @as(usize, @intCast(clamped_source - first))] += weight;
        }

        var total: f32 = 0.0;
        var index = start;
        while (index < weight_cursor) : (index += 1) total += axis_weights[index];
        if (!std.math.isFinite(total) or @abs(total) < 0.000001) @trap();
        index = start;
        while (index < weight_cursor) : (index += 1) axis_weights[index] /= total;
        axis_offsets[destination + 1] = @intCast(weight_cursor);
    }
}

fn sourceChannel(pixels: []align(1) const f32, pixel: usize, channel: usize) f32 {
    const offset = pixel * 4;
    const alpha = pixels[offset + 3];
    if (channel == 3) return alpha;
    return pixels[offset + channel] * alpha;
}

// Keep this large global behind a many-item pointer. Zig 0.15.2's LLVM Wasm
// backend can materialize a directly runtime-indexed array as a stack
// temporary, which attempts to copy this approximately 100 MiB buffer and
// traps. The pointer makes each access an explicit scalar or unaligned vector
// load or store instead.
fn intermediateSet(index: usize, value: f32) void {
    if (index >= MAX_PIXELS) @trap();
    const pixels: [*]f32 = @ptrCast(&intermediate[0]);
    pixels[index] = value;
}

fn intermediateGet(index: usize) f32 {
    if (index >= MAX_PIXELS) @trap();
    const pixels: [*]const f32 = @ptrCast(&intermediate[0]);
    return pixels[index];
}

fn intermediateGet4(index: usize) Vec4 {
    if (index + 4 > MAX_PIXELS) @trap();
    const pixels: [*]const f32 = @ptrCast(&intermediate[0]);
    return @as(*align(1) const Vec4, @ptrCast(&pixels[index])).*;
}

fn horizontalPass(source: rgba32f.Image, destination_width: usize, channel: usize) void {
    var y: usize = 0;
    while (y < source.height) : (y += 1) {
        var x: usize = 0;
        while (x < destination_width) : (x += 1) {
            var sum: f32 = 0.0;
            var source_x: usize = axis_first[x];
            var weight_index: usize = axis_offsets[x];
            const weight_end: usize = axis_offsets[x + 1];
            while (weight_index < weight_end) : (weight_index += 1) {
                sum += sourceChannel(source.pixels, y * source.width + source_x, channel) * axis_weights[weight_index];
                source_x += 1;
            }
            intermediateSet(y * destination_width + x, sum);
        }
    }
}

fn verticalPass(destination_width: usize, destination_height: usize, channel: usize, destination: []align(1) f32) void {
    var y: usize = 0;
    while (y < destination_height) : (y += 1) {
        var x: usize = 0;
        if (USE_SIMD) {
            while (x + 4 <= destination_width) : (x += 4) {
                var sum: Vec4 = @splat(0.0);
                var source_y: usize = axis_first[y];
                var weight_index: usize = axis_offsets[y];
                const weight_end: usize = axis_offsets[y + 1];
                while (weight_index < weight_end) : (weight_index += 1) {
                    const samples = intermediateGet4(source_y * destination_width + x);
                    sum += samples * @as(Vec4, @splat(axis_weights[weight_index]));
                    source_y += 1;
                }

                if (channel == 3) {
                    const clamped = @min(@as(Vec4, @splat(1.0)), @max(@as(Vec4, @splat(0.0)), sum));
                    inline for (0..4) |lane| {
                        const offset = (y * destination_width + x + lane) * 4;
                        destination[offset + 3] = clamped[lane];
                    }
                } else {
                    const base = (y * destination_width + x) * 4;
                    const alpha = Vec4{
                        destination[base + 3],
                        destination[base + 7],
                        destination[base + 11],
                        destination[base + 15],
                    };
                    const values = @select(f32, alpha > @as(Vec4, @splat(0.000001)), sum / alpha, @as(Vec4, @splat(0.0)));
                    inline for (0..4) |lane| {
                        destination[base + lane * 4 + channel] = values[lane];
                    }
                }
            }
        }
        while (x < destination_width) : (x += 1) {
            var sum: f32 = 0.0;
            var source_y: usize = axis_first[y];
            var weight_index: usize = axis_offsets[y];
            const weight_end: usize = axis_offsets[y + 1];
            while (weight_index < weight_end) : (weight_index += 1) {
                sum += intermediateGet(source_y * destination_width + x) * axis_weights[weight_index];
                source_y += 1;
            }

            const offset = (y * destination_width + x) * 4;
            if (channel == 3) {
                destination[offset + 3] = @min(@as(f32, 1.0), @max(@as(f32, 0.0), sum));
            } else {
                const alpha = destination[offset + 3];
                destination[offset + channel] = if (alpha > 0.000001) sum / alpha else 0.0;
            }
        }
    }
}

fn resample(source: rgba32f.Image, destination_width: usize, destination_height: usize, comptime kernel: Kernel, destination: []align(1) f32) void {
    buildAxisPlan(source.width, destination_width, kernel);
    horizontalPass(source, destination_width, 3);
    buildAxisPlan(source.height, destination_height, kernel);
    verticalPass(destination_width, destination_height, 3, destination);

    var channel: usize = 0;
    while (channel < 3) : (channel += 1) {
        buildAxisPlan(source.width, destination_width, kernel);
        horizontalPass(source, destination_width, channel);
        buildAxisPlan(source.height, destination_height, kernel);
        verticalPass(destination_width, destination_height, channel, destination);
    }
}

pub fn render(input_size_in: u32, comptime kernel: Kernel) RenderResult {
    var width: usize = target_width;
    var height: usize = target_height;
    defer resetUniforms();

    const input_size: usize = input_size_in;
    if (input_size > input.len) @trap();
    const source = rgba32f.parse(input[0..input_size]) orelse @trap();
    if (width == 0 and height == 0) {
        switch (kernel) {
            .lanczos3_down => {
                width = @max(1, (source.width + 1) / 2);
                height = @max(1, (source.height + 1) / 2);
            },
            .mitchell_up => {
                width = std.math.mul(usize, source.width, 2) catch @trap();
                height = std.math.mul(usize, source.height, 2) catch @trap();
            },
        }
    } else if (width == 0) {
        width = @max(1, (height * source.width + source.height / 2) / source.height);
    } else if (height == 0) {
        height = @max(1, (width * source.height + source.width / 2) / source.width);
    }
    const destination_width = width;
    const destination_height = height;
    const output_size = rgba32f.fileSize(destination_width, destination_height) orelse @trap();

    switch (kernel) {
        .lanczos3_down => if (destination_width > source.width or destination_height > source.height) return rejected(),
        .mitchell_up => if (destination_width < source.width or destination_height < source.height) return rejected(),
    }

    _ = rgba32f.writeHeader(&output, destination_width, destination_height) orelse @trap();
    const payload = output[rgba32f.HEADER_SIZE..output_size];
    const destination_ptr: [*]align(1) f32 = @ptrCast(payload.ptr);
    const destination = destination_ptr[0 .. payload.len / 4];
    resample(source, destination_width, destination_height, kernel, destination);
    return .{ .output_size = @intCast(output_size), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
