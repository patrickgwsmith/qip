// God Rays — optimized port of paper-design/shaders god-rays fragment shader.
// https://github.com/paper-design/shaders/blob/main/packages/shaders/src/shaders/god-rays.ts
//
// The GLSL fragment shader is evaluated per pixel in f32, including the
// v_objectUV vertex-shader sizing math (fit/scale/rotation/offset/origin).
// The u_noiseTexture sampler is reproduced as an embedded 128x128 R-channel
// table sampled with bilinear filtering and CLAMP_TO_EDGE, matching the
// WebGL texture parameters used by shader-mount.
//
// Uniforms mirror the original set. Colors are packed 0xRRGGBBAA.
// Defaults are the library's "Default" preset.
//
// Optimized relative to god-rays.zig (the straight port): fast polynomial
// pow/atan2, one atan2 per color instead of two, and the seam mix branch
// is skipped where the smoothstep factor saturates. Output differs from
// the straight port by at most 1/255 per channel.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const noise = @import("assets/god_rays_noise_r_128.zig");

const RENDER_W: usize = 640;
const RENDER_H: usize = 360;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const MAX_COLOR_COUNT: usize = 5;

const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

var output_buf: [OUTPUT_BYTES]u8 = undefined;

// ---- Fragment shader uniforms (defaults: "Default" preset) ----

var u_color_back: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 }; // #000000
var u_color_bloom: [4]f32 = .{ 0.0, 0.0, 1.0, 1.0 }; // #0000ff
var u_colors: [MAX_COLOR_COUNT][4]f32 = .{
    rgbaFromPacked(0xa600ff6e), // #a600ff6e
    rgbaFromPacked(0x6200fff0), // #6200fff0
    rgbaFromPacked(0xffffffff), // #ffffff
    rgbaFromPacked(0x33fff5ff), // #33fff5
    .{ 0.0, 0.0, 0.0, 0.0 },
};
var u_colors_count: f32 = 4.0;
var u_density: f32 = 0.3;
var u_spotty: f32 = 0.3;
var u_mid_size: f32 = 0.2;
var u_mid_intensity: f32 = 0.4;
var u_intensity: f32 = 0.8;
var u_bloom: f32 = 0.4;

// ---- Vertex shader (sizing) uniforms ----

var u_fit: f32 = 1.0; // 0 none, 1 contain, 2 cover
var u_scale: f32 = 1.0;
var u_rotation: f32 = 0.0; // degrees
var u_origin_x: f32 = 0.5;
var u_origin_y: f32 = 0.5;
var u_offset_x: f32 = 0.0;
var u_offset_y: f32 = -0.55;
var u_world_width: f32 = 0.0;
var u_world_height: f32 = 0.0;
var u_pixel_ratio: f32 = 1.0;

// ---- Motion params (ShaderMount: u_time = (frame + speed * elapsed_ms) / 1000) ----

var u_speed: f32 = 0.75;
var frame_offset_ms: f32 = 0.0;

const Uniform = enum(u5) {
    density,
    spotty,
    mid_size,
    mid_intensity,
    intensity,
    bloom,
    colors_count,
    color_back,
    color_bloom,
    color_1,
    color_2,
    color_3,
    color_4,
    color_5,
    fit,
    scale,
    rotation,
    origin_x,
    origin_y,
    offset_x,
    offset_y,
    world_width,
    world_height,
    pixel_ratio,
    speed,
    frame,
};

const Phase = enum {
    initializing,
    ready,
    updating,
};

var phase: Phase = .initializing;
var uniform_mask: u32 = 0;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

fn rgbaFromPacked(v: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((v >> 24) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(v & 0xFF)) / 255.0,
    };
}

fn packedFromRgba(c: [4]f32) u32 {
    const r: u32 = @intFromFloat(@round(c[0] * 255.0));
    const g: u32 = @intFromFloat(@round(c[1] * 255.0));
    const b: u32 = @intFromFloat(@round(c[2] * 255.0));
    const a: u32 = @intFromFloat(@round(c[3] * 255.0));
    return (r << 24) | (g << 16) | (b << 8) | a;
}

// ---- Timed ABI ----

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or uniform_mask != 0) @trap();
    if (now_ms <= committed_at_ms) @trap();
    resetUniforms();
    uniform_mask = 0;
    begun_at_ms = now_ms;
    phase = .updating;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    renderFrame();
    finishUniforms();
    return OUTPUT_BYTES;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf[0])),
        .failed = 0,
    };
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    const speed = u_speed;
    committed_at_ms = begun_at_ms;
    finishUniforms();
    if (speed == 0.0) return begun_at_ms;
    return begun_at_ms +| 16;
}

fn finishUniforms() void {
    resetUniforms();
    uniform_mask = 0;
    phase = .ready;
}

fn resetUniforms() void {
    u_color_back = .{ 0.0, 0.0, 0.0, 1.0 };
    u_color_bloom = .{ 0.0, 0.0, 1.0, 1.0 };
    u_colors = .{
        rgbaFromPacked(0xa600ff6e),
        rgbaFromPacked(0x6200fff0),
        rgbaFromPacked(0xffffffff),
        rgbaFromPacked(0x33fff5ff),
        .{ 0.0, 0.0, 0.0, 0.0 },
    };
    u_colors_count = 4.0;
    u_density = 0.3;
    u_spotty = 0.3;
    u_mid_size = 0.2;
    u_mid_intensity = 0.4;
    u_intensity = 0.8;
    u_bloom = 0.4;
    u_fit = 1.0;
    u_scale = 1.0;
    u_rotation = 0.0;
    u_origin_x = 0.5;
    u_origin_y = 0.5;
    u_offset_x = 0.0;
    u_offset_y = -0.55;
    u_world_width = 0.0;
    u_world_height = 0.0;
    u_pixel_ratio = 1.0;
    u_speed = 0.75;
    frame_offset_ms = 0.0;
}

fn markUniform(uniform: Uniform) void {
    if (phase != .initializing and phase != .ready and phase != .updating) @trap();
    uniform_mask |= @as(u32, 1) << @intFromEnum(uniform);
}

// ---- Uniform setters ----

export fn uniform_set_density(v: f32) f32 {
    markUniform(.density);
    u_density = v;
    return u_density;
}
export fn uniform_set_spotty(v: f32) f32 {
    markUniform(.spotty);
    u_spotty = v;
    return u_spotty;
}
export fn uniform_set_mid_size(v: f32) f32 {
    markUniform(.mid_size);
    u_mid_size = v;
    return u_mid_size;
}
export fn uniform_set_mid_intensity(v: f32) f32 {
    markUniform(.mid_intensity);
    u_mid_intensity = v;
    return u_mid_intensity;
}
export fn uniform_set_intensity(v: f32) f32 {
    markUniform(.intensity);
    u_intensity = v;
    return u_intensity;
}
export fn uniform_set_bloom(v: f32) f32 {
    markUniform(.bloom);
    u_bloom = v;
    return u_bloom;
}
export fn uniform_set_colors_count(v: f32) f32 {
    markUniform(.colors_count);
    u_colors_count = std.math.clamp(v, 0.0, @as(f32, MAX_COLOR_COUNT));
    return u_colors_count;
}
export fn uniform_set_color_back(v: u32) u32 {
    markUniform(.color_back);
    u_color_back = rgbaFromPacked(v);
    return packedFromRgba(u_color_back);
}
export fn uniform_set_color_bloom(v: u32) u32 {
    markUniform(.color_bloom);
    u_color_bloom = rgbaFromPacked(v);
    return packedFromRgba(u_color_bloom);
}
export fn uniform_set_color_1(v: u32) u32 {
    markUniform(.color_1);
    u_colors[0] = rgbaFromPacked(v);
    return packedFromRgba(u_colors[0]);
}
export fn uniform_set_color_2(v: u32) u32 {
    markUniform(.color_2);
    u_colors[1] = rgbaFromPacked(v);
    return packedFromRgba(u_colors[1]);
}
export fn uniform_set_color_3(v: u32) u32 {
    markUniform(.color_3);
    u_colors[2] = rgbaFromPacked(v);
    return packedFromRgba(u_colors[2]);
}
export fn uniform_set_color_4(v: u32) u32 {
    markUniform(.color_4);
    u_colors[3] = rgbaFromPacked(v);
    return packedFromRgba(u_colors[3]);
}
export fn uniform_set_color_5(v: u32) u32 {
    markUniform(.color_5);
    u_colors[4] = rgbaFromPacked(v);
    return packedFromRgba(u_colors[4]);
}
export fn uniform_set_fit(v: f32) f32 {
    markUniform(.fit);
    u_fit = std.math.clamp(v, 0.0, 2.0);
    return u_fit;
}
export fn uniform_set_scale(v: f32) f32 {
    markUniform(.scale);
    u_scale = v;
    return u_scale;
}
export fn uniform_set_rotation(v: f32) f32 {
    markUniform(.rotation);
    u_rotation = v;
    return u_rotation;
}
export fn uniform_set_origin_x(v: f32) f32 {
    markUniform(.origin_x);
    u_origin_x = v;
    return u_origin_x;
}
export fn uniform_set_origin_y(v: f32) f32 {
    markUniform(.origin_y);
    u_origin_y = v;
    return u_origin_y;
}
export fn uniform_set_offset_x(v: f32) f32 {
    markUniform(.offset_x);
    u_offset_x = v;
    return u_offset_x;
}
export fn uniform_set_offset_y(v: f32) f32 {
    markUniform(.offset_y);
    u_offset_y = v;
    return u_offset_y;
}
export fn uniform_set_world_width(v: f32) f32 {
    markUniform(.world_width);
    u_world_width = v;
    return u_world_width;
}
export fn uniform_set_world_height(v: f32) f32 {
    markUniform(.world_height);
    u_world_height = v;
    return u_world_height;
}
export fn uniform_set_pixel_ratio(v: f32) f32 {
    markUniform(.pixel_ratio);
    u_pixel_ratio = v;
    return u_pixel_ratio;
}
export fn uniform_set_speed(v: f32) f32 {
    markUniform(.speed);
    u_speed = v;
    return u_speed;
}
export fn uniform_set_frame(v: f32) f32 {
    markUniform(.frame);
    frame_offset_ms = v;
    return frame_offset_ms;
}

// ---- GLSL builtins (f32, matching GLSL semantics) ----

fn fractf(x: f32) f32 {
    return x - @floor(x);
}

fn mixf(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn clampf(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

fn smoothstepf(edge0: f32, edge1: f32, x: f32) f32 {
    const t = clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn stepf(edge: f32, x: f32) f32 {
    return if (x < edge) 0.0 else 1.0;
}

// Fast log2/exp2 pair (Mineiro-style); relative error ~1e-4, well inside
// GLSL mediump pow() tolerance.
fn fastLog2(x: f32) f32 {
    const vx: u32 = @bitCast(x);
    const mx: f32 = @bitCast((vx & 0x007FFFFF) | 0x3F000000);
    const y = @as(f32, @floatFromInt(vx)) * 1.1920928955078125e-7;
    return y - 124.22551499 - 1.498030302 * mx - 1.72587999 / (0.3520887068 + mx);
}

fn fastExp2(p0: f32) f32 {
    const p = @max(p0, -126.0);
    const w = @floor(p);
    const z = p - w;
    const bits: u32 = @intFromFloat((1 << 23) * (p + 121.2740575 + 27.7280233 / (4.84252568 - z) - 1.49012907 * z));
    return @bitCast(bits);
}

fn powf(x: f32, y: f32) f32 {
    if (x <= 0.0) return 0.0;
    return fastExp2(y * fastLog2(x));
}

// Polynomial atan2; max error ~1e-5 rad.
fn fastAtan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    const mx = @max(ax, ay);
    if (mx == 0.0) return 0.0;
    const z = @min(ax, ay) / mx;
    const z2 = z * z;
    var r = z * (0.9998660 + z2 * (-0.3302995 + z2 * (0.1801410 + z2 * (-0.0851330 + z2 * 0.0208351))));
    if (ay > ax) r = (PI / 2.0) - r;
    if (x < 0.0) r = PI - r;
    return if (y < 0.0) -r else r;
}

// ---- Shader helpers ----

// texture(u_noiseTexture, uv).r with LINEAR filtering, CLAMP_TO_EDGE, level 0.
fn texNoiseR(u: f32, v: f32) f32 {
    const fw: f32 = @floatFromInt(noise.width);
    const fh: f32 = @floatFromInt(noise.height);
    const x = u * fw - 0.5;
    const y = v * fh - 0.5;
    const xf = @floor(x);
    const yf = @floor(y);
    const tx = x - xf;
    const ty = y - yf;
    const max_x: i32 = @intCast(noise.width - 1);
    const max_y: i32 = @intCast(noise.height - 1);
    const x0: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(xf)), 0, max_x));
    const x1: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(xf)) + 1, 0, max_x));
    const y0: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(yf)), 0, max_y));
    const y1: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(yf)) + 1, 0, max_y));
    const s00: f32 = @floatFromInt(noise.r[y0 * noise.width + x0]);
    const s10: f32 = @floatFromInt(noise.r[y0 * noise.width + x1]);
    const s01: f32 = @floatFromInt(noise.r[y1 * noise.width + x0]);
    const s11: f32 = @floatFromInt(noise.r[y1 * noise.width + x1]);
    const top = mixf(s00, s10, tx);
    const bottom = mixf(s01, s11, tx);
    return mixf(top, bottom, ty) / 255.0;
}

fn randomR(px: f32, py: f32) f32 {
    const u = fractf(@floor(px) / 100.0 + 0.5);
    const v = fractf(@floor(py) / 100.0 + 0.5);
    return texNoiseR(u, v);
}

fn valueNoise(sx: f32, sy: f32) f32 {
    const ix = @floor(sx);
    const iy = @floor(sy);
    const fx = sx - ix;
    const fy = sy - iy;
    const a = randomR(ix, iy);
    const b = randomR(ix + 1.0, iy);
    const c = randomR(ix, iy + 1.0);
    const d = randomR(ix + 1.0, iy + 1.0);
    const ux = fx * fx * (3.0 - 2.0 * fx);
    const uy = fy * fy * (3.0 - 2.0 * fy);
    const x1 = mixf(a, b, ux);
    const x2 = mixf(c, d, ux);
    return mixf(x1, x2, uy);
}

fn hash11(p0: f32) f32 {
    var p = fractf(p0 * 0.3183099) + 0.1;
    p *= p + 19.19;
    return fractf(p * p);
}

// raysShape with the angle and seam mix factor hoisted: both raysShape calls
// per color share atan2 and smoothstep, and when the seam mix factor
// saturates (|uv.x| >= 0.15, i.e. most pixels) only one noise branch is
// evaluated.
fn raysShapeFast(a_left: f32, a_right: f32, mix_fac: f32, r: f32, freq: f32, intensity: f32) f32 {
    if (mix_fac <= 0.0) {
        return powf(valueNoise(a_right * freq, r), intensity);
    }
    if (mix_fac >= 1.0) {
        return powf(valueNoise(a_left * freq, r), intensity);
    }
    const n_left = powf(valueNoise(a_left * freq, r), intensity);
    const n_right = powf(valueNoise(a_right * freq, r), intensity);
    return mixf(n_right, n_left, mix_fac);
}

// getBoxSize from vertex-shader.ts, specialized to boxRatio = 1 (objectUV path).
fn objectBoxSize(given_x: f32, given_y: f32) f32 {
    var box_x = @min(given_x, given_y);
    if (u_fit == 1.0) {
        box_x = @min(@as(f32, RENDER_W), @as(f32, RENDER_H));
    } else if (u_fit == 2.0) {
        box_x = @max(@as(f32, RENDER_W), @as(f32, RENDER_H));
    }
    return box_x;
}

fn renderFrame() void {
    const res_x: f32 = @floatFromInt(RENDER_W);
    const res_y: f32 = @floatFromInt(RENDER_H);

    const u_time: f32 = (frame_offset_ms + u_speed * @as(f32, @floatFromInt(begun_at_ms))) * 0.001;
    const t = 0.2 * u_time;

    // ---- v_objectUV affine constants (vertex shader, objectUV path) ----
    const box_origin_x = 0.5 - u_origin_x;
    const box_origin_y = u_origin_y - 0.5;
    const given_x = if (u_world_width == 0.0) res_x else @max(u_world_width, 1.0) * u_pixel_ratio;
    const given_y = if (u_world_height == 0.0) res_y else @max(u_world_height, 1.0) * u_pixel_ratio;
    const box = objectBoxSize(given_x, given_y);
    const ows_x = res_x / box;
    const ows_y = res_y / box;
    const base_x = box_origin_x * (ows_x - 1.0) - u_offset_x;
    const base_y = box_origin_y * (ows_y - 1.0) + u_offset_y;
    const rot = u_rotation * PI / 180.0;
    const cos_r = @cos(rot);
    const sin_r = @sin(rot);

    // ---- Uniform-only fragment expressions ----
    const spots = 6.5 * @abs(u_spotty);
    const intensity = 4.0 - 3.0 * clampf(u_intensity, 0.0, 1.0);
    const mid_size = 10.0 * @abs(u_mid_size);
    const ms_lo = 0.02 * mid_size;
    const ms_hi = @max(mid_size, 1e-6);
    const mid_intensity_pow = powf(u_mid_intensity, 0.3);
    const t3 = 3.0 * t;
    const t2 = 2.0 * t;

    const d = u_density;
    const d_shift = 4.5 * (d - 0.5);
    const d_shift2 = d_shift * d_shift;
    const density = 6.0 * d + stepf(0.5, d) * (d_shift2 * d_shift2);

    const colors_count: usize = @min(@as(usize, @intFromFloat(@max(u_colors_count, 0.0))), MAX_COLOR_COUNT);

    // Per-color constants (uniform + loop-index expressions).
    var rot_cos: [MAX_COLOR_COUNT]f32 = undefined;
    var rot_sin: [MAX_COLOR_COUNT]f32 = undefined;
    var r1_scale: [MAX_COLOR_COUNT]f32 = undefined;
    var freq5: [MAX_COLOR_COUNT]f32 = undefined;
    var freq4: [MAX_COLOR_COUNT]f32 = undefined;
    for (0..colors_count) |i| {
        const fi: f32 = @floatFromInt(i);
        rot_cos[i] = @cos(fi + 1.0);
        rot_sin[i] = @sin(fi + 1.0);
        r1_scale[i] = 1.0 + 0.4 * fi;
        const f = mixf(1.0, 3.0 + 0.5 * fi, hash11(fi * 15.0)) * density;
        freq5[i] = 5.0 * f;
        freq4[i] = 4.0 * f;
    }

    const overlay_alpha = u_color_bloom[3];
    const overlay_r = u_color_bloom[0] * overlay_alpha;
    const overlay_g = u_color_bloom[1] * overlay_alpha;
    const overlay_b = u_color_bloom[2] * overlay_alpha;

    const bg_r = u_color_back[0] * u_color_back[3];
    const bg_g = u_color_back[1] * u_color_back[3];
    const bg_b = u_color_back[2] * u_color_back[3];
    const bg_a = u_color_back[3];

    var py: usize = 0;
    while (py < RENDER_H) : (py += 1) {
        const fy: f32 = @floatFromInt(py);
        const uv_y = 0.5 - (fy + 0.5) / res_y;
        // gl_FragCoord has a bottom-left origin.
        const frag_y = (res_y - 1.0 - fy) + 0.5;

        var px: usize = 0;
        while (px < RENDER_W) : (px += 1) {
            const fx: f32 = @floatFromInt(px);
            const uv_x = (fx + 0.5) / res_x - 0.5;

            var ox = uv_x * ows_x + base_x;
            var oy = uv_y * ows_y + base_y;
            ox /= u_scale;
            oy /= u_scale;
            const shape_x = cos_r * ox - sin_r * oy;
            const shape_y = sin_r * ox + cos_r * oy;

            const radius = @sqrt(shape_x * shape_x + shape_y * shape_y);

            var middle_shape = mid_intensity_pow * (1.0 - smoothstepf(ms_lo, ms_hi, 3.0 * radius));
            middle_shape = middle_shape * middle_shape * middle_shape * middle_shape * middle_shape;

            var accum_r: f32 = 0.0;
            var accum_g: f32 = 0.0;
            var accum_b: f32 = 0.0;
            var accum_a: f32 = 0.0;

            const r2 = 0.5 * radius * (1.0 + spots) - t2;

            for (0..colors_count) |i| {
                const rux = rot_cos[i] * shape_x - rot_sin[i] * shape_y;
                const ruy = rot_sin[i] * shape_x + rot_cos[i] * shape_y;

                const r1 = radius * r1_scale[i] - t3;

                const a_left = fastAtan2(ruy, rux);
                const a_right = fractf(a_left / TWO_PI) * TWO_PI;
                const mix_fac = smoothstepf(-0.15, 0.15, rux);

                var ray = raysShapeFast(a_left, a_right, mix_fac, r1, freq5[i], intensity);
                ray *= raysShapeFast(a_left, a_right, mix_fac, r2, freq4[i], intensity);
                ray += (1.0 + 4.0 * ray) * middle_shape;
                ray = clampf(ray, 0.0, 1.0);

                const src_a = u_colors[i][3] * ray;
                const src_r = u_colors[i][0] * src_a;
                const src_g = u_colors[i][1] * src_a;
                const src_b = u_colors[i][2] * src_a;

                const one_minus = 1.0 - accum_a;
                accum_r = mixf(accum_r + one_minus * src_r, accum_r + src_r, u_bloom);
                accum_g = mixf(accum_g + one_minus * src_g, accum_g + src_g, u_bloom);
                accum_b = mixf(accum_b + one_minus * src_b, accum_b + src_b, u_bloom);
                accum_a = mixf(accum_a + one_minus * src_a, accum_a + src_a, u_bloom);
            }

            accum_r = mixf(accum_r, accum_r + accum_a * overlay_r, u_bloom);
            accum_g = mixf(accum_g, accum_g + accum_a * overlay_g, u_bloom);
            accum_b = mixf(accum_b, accum_b + accum_a * overlay_b, u_bloom);

            var color_r = accum_r + (1.0 - accum_a) * bg_r;
            var color_g = accum_g + (1.0 - accum_a) * bg_g;
            var color_b = accum_b + (1.0 - accum_a) * bg_b;
            var opacity = accum_a + (1.0 - accum_a) * bg_a;
            color_r = clampf(color_r, 0.0, 1.0);
            color_g = clampf(color_g, 0.0, 1.0);
            color_b = clampf(color_b, 0.0, 1.0);
            opacity = clampf(opacity, 0.0, 1.0);

            // colorBandingFix dither.
            const frag_x = fx + 0.5;
            const dither_dot = 0.014 * frag_x * 12.9898 + 0.014 * frag_y * 78.233;
            const dither = (fractf(@sin(dither_dot) * 43758.5453123) - 0.5) / 256.0;
            color_r += dither;
            color_g += dither;
            color_b += dither;

            // The GL pipeline outputs premultiplied color; the interactive ABI
            // wants straight alpha.
            if (opacity > 0.0) {
                color_r = clampf(color_r / opacity, 0.0, 1.0);
                color_g = clampf(color_g / opacity, 0.0, 1.0);
                color_b = clampf(color_b / opacity, 0.0, 1.0);
            } else {
                color_r = 0.0;
                color_g = 0.0;
                color_b = 0.0;
            }

            const idx = ktx.HEADER_SIZE + (py * RENDER_W + px) * 4;
            output_buf[idx + 0] = @intFromFloat(@round(clampf(color_r, 0.0, 1.0) * 255.0));
            output_buf[idx + 1] = @intFromFloat(@round(clampf(color_g, 0.0, 1.0) * 255.0));
            output_buf[idx + 2] = @intFromFloat(@round(clampf(color_b, 0.0, 1.0) * 255.0));
            output_buf[idx + 3] = @intFromFloat(@round(opacity * 255.0));
        }
    }
}

test "default preset renders opaque KTX2 frame" {
    resetForTest();
    setEveryDefaultUniform(0.75);
    const output_size = renderImpl(0);
    const image = ktx.parse(output_buf[0..output_size]).?;
    try std.testing.expectEqual(RENDER_W, image.width);
    try std.testing.expectEqual(RENDER_H, image.height);
    try std.testing.expectEqual(@as(u8, 255), image.pixels[3]);
}

test "renderless Timed update leaves output bytes unchanged" {
    resetForTest();
    setEveryDefaultUniform(0.75);
    const output_size = renderImpl(0);
    const before = std.hash.Wyhash.hash(0, output_buf[0..output_size]);

    begin_update_at(1);
    setEveryDefaultUniform(0.75);
    try std.testing.expectEqual(@as(i64, 17), finish_update());
    try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, output_buf[0..output_size]));
}

test "same presentation uniforms render deterministically after an update" {
    resetForTest();
    setEveryDefaultUniform(0.0);
    const first_size = renderImpl(0);
    const first = std.hash.Wyhash.hash(0, output_buf[0..first_size]);

    begin_update_at(1);
    setEveryDefaultUniform(0.0);
    try std.testing.expectEqual(@as(i64, 1), finish_update());

    setEveryDefaultUniform(0.0);
    const second_size = renderImpl(0);
    const second = std.hash.Wyhash.hash(0, output_buf[0..second_size]);
    try std.testing.expectEqual(first_size, second_size);
    try std.testing.expectEqual(first, second);
}

test "render resets presentation uniforms" {
    resetForTest();
    setEveryDefaultUniform(0.0);
    const output_size = renderImpl(0);
    try std.testing.expectEqual(@as(u32, 0), uniform_mask);
    setEveryDefaultUniform(0.0);
    try std.testing.expectEqual(output_size, renderImpl(0));
    try std.testing.expectEqual(@as(u32, 0), uniform_mask);
}

fn resetForTest() void {
    resetUniforms();
    phase = .initializing;
    uniform_mask = 0;
    begun_at_ms = 0;
    committed_at_ms = 0;
}

fn setEveryDefaultUniform(speed: f32) void {
    _ = uniform_set_density(0.3);
    _ = uniform_set_spotty(0.3);
    _ = uniform_set_mid_size(0.2);
    _ = uniform_set_mid_intensity(0.4);
    _ = uniform_set_intensity(0.8);
    _ = uniform_set_bloom(0.4);
    _ = uniform_set_colors_count(4.0);
    _ = uniform_set_color_back(0x000000ff);
    _ = uniform_set_color_bloom(0x0000ffff);
    _ = uniform_set_color_1(0xa600ff6e);
    _ = uniform_set_color_2(0x6200fff0);
    _ = uniform_set_color_3(0xffffffff);
    _ = uniform_set_color_4(0x33fff5ff);
    _ = uniform_set_color_5(0x00000000);
    _ = uniform_set_fit(1.0);
    _ = uniform_set_scale(1.0);
    _ = uniform_set_rotation(0.0);
    _ = uniform_set_origin_x(0.5);
    _ = uniform_set_origin_y(0.5);
    _ = uniform_set_offset_x(0.0);
    _ = uniform_set_offset_y(-0.55);
    _ = uniform_set_world_width(0.0);
    _ = uniform_set_world_height(0.0);
    _ = uniform_set_pixel_ratio(1.0);
    _ = uniform_set_speed(speed);
    _ = uniform_set_frame(0.0);
}
