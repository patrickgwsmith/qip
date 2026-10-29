const std = @import("std");
const ktx_sdr = @import("ktx2_rgba8_srgb");
const ktx_hdr = @import("ktx2_rgba32float_display_p3_linear");
const font = @import("assets/inter_display_bold_chronograph_digits.zig");

const DRAW_SCALE: i32 = 1;
const RENDER_W: usize = 360;
const RENDER_H: usize = 360;
const PIXEL_COUNT: usize = RENDER_W * RENDER_H;
const SDR_PIXEL_BYTES: usize = PIXEL_COUNT * 4;
const SDR_OUTPUT_BYTES: usize = ktx_sdr.HEADER_SIZE + SDR_PIXEL_BYTES;
const HDR_PIXEL_BYTES: usize = PIXEL_COUNT * 16;
const HDR_OUTPUT_BYTES: usize = ktx_hdr.HEADER_SIZE + HDR_PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx_sdr.CONTENT_TYPE;
const WAKE_INTERVAL_MS: i64 = 200;
const MAX_TILT_RADIANS: f32 = 36.0 * std.math.pi / 180.0;
const TILT_RADIANS_PER_PIXEL: f32 = 0.25 * std.math.pi / 180.0;

const CX: i32 = @intCast(RENDER_W / 2);
const CY: i32 = @intCast(RENDER_H / 2);
const Color = [4]u8;
// sRGB-encoded channels in 0...1, used while shading before quantizing.
const Rgb = [3]f32;

const C_PRINT: Color = .{ 0xF6, 0xEA, 0xD4, 0xFF };
const C_SHADOW: Color = .{ 0x01, 0x05, 0x14, 0x80 };
const GOLD_DEEP: Rgb = .{ 0.34, 0.15, 0.13 };
const GOLD_MID: Rgb = .{ 0.86, 0.57, 0.50 };
const GOLD_LIGHT: Rgb = .{ 1.0, 0.88, 0.82 };
const GOLD_GLINT: Rgb = .{ 1.0, 0.97, 0.93 };
const ENAMEL_CENTER: Rgb = .{ 0.09, 0.29, 0.70 };
const ENAMEL_EDGE: Rgb = .{ 0.02, 0.06, 0.21 };
const ENAMEL_SHEEN: Rgb = .{ 0.50, 0.74, 1.0 };
const LUME: Rgb = .{ 0.80, 1.0, 0.70 };

// Emission marks pixels which should exceed diffuse white on HDR output.
// 255 scales the linear colour by 1 + HDR_EMISSION_GAIN, eight times SDR
// white for the brightest glints. SDR output ignores it.
const HDR_EMISSION_GAIN: f32 = 7.0;
const HDR_SATURATION: f32 = 1.2;

var output_buf: [HDR_OUTPUT_BYTES]u8 align(16) = undefined;
var emission_buf: [PIXEL_COUNT]u8 = undefined;
var paint_emission: u8 = 0;

// The face-on dial below the hand never changes, so cache it after the first
// face-on frame and copy it for each later tick.
var static_pixels: [SDR_PIXEL_BYTES]u8 = undefined;
var static_emission: [PIXEL_COUNT]u8 = undefined;
var static_cached: bool = false;

// Key light from the upper left. Yaw swings it so reflections travel across
// the gold and enamel as the watch is tilted.
var light_x: f32 = 0;
var light_y: f32 = 0;
var light_z: f32 = 1;
var half_x: f32 = 0;
var half_y: f32 = 0;
var half_z: f32 = 1;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var clock_seconds: f32 = 0;
var committed_seconds: f32 = 0;
var uniform_seconds: f32 = 0;
var uniform_seconds_set: bool = false;
var uniform_hdr: bool = false;
var last_host_seconds: f32 = 0;
var host_seconds_seen: bool = false;
var tilt_angle: f32 = 0;
var tilt_velocity: f32 = 0;
var tilt_dragging: bool = false;
var tilt_drag_start_x: i32 = 0;
var tilt_drag_start_angle: f32 = 0;
var tilt_last_x: i32 = 0;
var tilt_last_event_at_ms: i64 = 0;

var render_tilt_scale_x: f32 = 1;
var render_tilt_inverse_x: f32 = 1;
var render_tilt_sine: f32 = 0;
var render_layer_offset_x: f32 = 0;

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @intCast(HDR_OUTPUT_BYTES);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn uniform_set_current_seconds(value: f32) f32 {
    if (!std.math.isFinite(value)) @trap();
    const normalized = normalizeSeconds(value);
    if (host_seconds_seen and normalized == last_host_seconds) {
        uniform_seconds_set = false;
        return quantizeSeconds(normalized);
    }
    last_host_seconds = normalized;
    host_seconds_seen = true;
    uniform_seconds = normalized;
    uniform_seconds_set = true;
    return quantizeSeconds(normalized);
}

export fn uniform_set_hdr(value: u32) u32 {
    uniform_hdr = value != 0;
    return @intFromBool(uniform_hdr);
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (phase != .updating) @trap();
    const primary_down = button_mask & 1 != 0;
    const inside = x >= 0 and y >= 0 and x < @as(i32, @intCast(RENDER_W)) and y < @as(i32, @intCast(RENDER_H));

    if (primary_down and inside) {
        if (!tilt_dragging) {
            tilt_dragging = true;
            tilt_drag_start_x = x;
            tilt_drag_start_angle = tilt_angle;
            tilt_velocity = 0;
        } else {
            const next_angle = std.math.clamp(
                tilt_drag_start_angle + @as(f32, @floatFromInt(x - tilt_drag_start_x)) * TILT_RADIANS_PER_PIXEL,
                -MAX_TILT_RADIANS,
                MAX_TILT_RADIANS,
            );
            const elapsed_ms = begun_at_ms - tilt_last_event_at_ms;
            if (tilt_last_event_at_ms == 0 or elapsed_ms <= 0 or elapsed_ms > 100) {
                tilt_velocity = 0;
            } else {
                const instantaneous_velocity =
                    @as(f32, @floatFromInt(x - tilt_last_x)) * TILT_RADIANS_PER_PIXEL * 1000.0 /
                    @as(f32, @floatFromInt(elapsed_ms));
                tilt_velocity = std.math.clamp(instantaneous_velocity, -2.0, 2.0);
            }
            tilt_angle = next_angle;
        }
        tilt_last_x = x;
        tilt_last_event_at_ms = begun_at_ms;
        return 1;
    }

    if (tilt_dragging) {
        tilt_dragging = false;
        tilt_last_event_at_ms = begun_at_ms;
        return 1;
    }
    return 0;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    if (uniform_seconds_set) {
        clock_seconds = uniform_seconds;
    } else {
        const elapsed_ms = begun_at_ms - committed_at_ms;
        clock_seconds = normalizeSeconds(clock_seconds + @as(f32, @floatFromInt(elapsed_ms)) / 1000.0);
    }
    committed_seconds = quantizeSeconds(clock_seconds);
    if (!tilt_dragging and tilt_last_event_at_ms != begun_at_ms) updateTiltSpring(begun_at_ms - committed_at_ms);
    resetUniform();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    if (tiltIsAnimating()) return nextAnimationWake(begun_at_ms);
    if (begun_at_ms > std.math.maxInt(i64) - WAKE_INTERVAL_MS) return begun_at_ms;
    return begun_at_ms + WAKE_INTERVAL_MS;
}

fn updateTiltSpring(elapsed_ms: i64) void {
    if (!tiltIsAnimating()) return;
    if (elapsed_ms > 250) {
        tilt_angle = 0;
        tilt_velocity = 0;
        return;
    }
    const dt = @as(f32, @floatFromInt(@max(@as(i64, 0), elapsed_ms))) / 1000.0;
    tilt_velocity += (-38.0 * tilt_angle - 11.5 * tilt_velocity) * dt;
    tilt_angle = std.math.clamp(tilt_angle + tilt_velocity * dt, -MAX_TILT_RADIANS, MAX_TILT_RADIANS);
    if (@abs(tilt_angle) < 0.00035 and @abs(tilt_velocity) < 0.0025) {
        tilt_angle = 0;
        tilt_velocity = 0;
    }
}

fn tiltIsAnimating() bool {
    return !tilt_dragging and (tilt_angle != 0 or tilt_velocity != 0);
}

fn nextAnimationWake(now_ms: i64) i64 {
    if (now_ms > std.math.maxInt(i64) - 50) return now_ms;
    const remainder = @mod(now_ms, 50);
    const delta: i64 = if (remainder < 17)
        17 - remainder
    else if (remainder < 33)
        33 - remainder
    else
        50 - remainder;
    return now_ms + delta;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or phase == .updating) @trap();
    if (phase == .initializing) {
        if (uniform_seconds_set) {
            clock_seconds = uniform_seconds;
            committed_seconds = quantizeSeconds(clock_seconds);
        }
        phase = .ready;
    } else if (phase != .ready) {
        @trap();
    } else if (uniform_seconds_set) {
        clock_seconds = uniform_seconds;
        committed_seconds = quantizeSeconds(clock_seconds);
    }

    const output_size = if (uniform_hdr)
        renderHDR(committed_seconds)
    else
        renderSDR(committed_seconds);
    resetUniform();
    return @intCast(output_size);
}

noinline fn renderSDR(seconds: f32) usize {
    _ = ktx_sdr.writeHeader(output_buf[0..SDR_OUTPUT_BYTES], RENDER_W, RENDER_H) orelse @trap();
    drawChronograph(seconds);
    return SDR_OUTPUT_BYTES;
}

noinline fn renderHDR(seconds: f32) usize {
    _ = renderSDR(seconds);
    return expandToHDR();
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

fn resetUniform() void {
    uniform_seconds = 0;
    uniform_seconds_set = false;
    uniform_hdr = false;
}

fn normalizeSeconds(value: f32) f32 {
    var normalized = value - @floor(value / 60.0) * 60.0;
    if (normalized < 0) normalized += 60.0;
    return normalized;
}

fn quantizeSeconds(value: f32) f32 {
    return @floor(normalizeSeconds(value) * 5.0) / 5.0;
}

fn pixels() []u8 {
    return output_buf[ktx_sdr.HEADER_SIZE..SDR_OUTPUT_BYTES];
}

noinline fn expandToHDR() usize {
    // Expand backward so the float32 destination cannot overwrite RGBA8
    // source pixels which the conversion has not read yet.
    const output = output_buf[0..];
    var pixel_index = PIXEL_COUNT;
    while (pixel_index > 0) {
        pixel_index -= 1;
        const source_index = ktx_sdr.HEADER_SIZE + pixel_index * 4;
        const r = ktx_hdr.SRGB8_TO_LINEAR[output[source_index]];
        const g = ktx_hdr.SRGB8_TO_LINEAR[output[source_index + 1]];
        const b = ktx_hdr.SRGB8_TO_LINEAR[output[source_index + 2]];
        const a = @as(f32, @floatFromInt(output[source_index + 3])) / 255.0;
        const hdr_rgb = expandHighlight(r, g, b, emission_buf[pixel_index]);
        const destination_index = ktx_hdr.HEADER_SIZE + pixel_index * 16;
        writeF32(output, destination_index, hdr_rgb[0]);
        writeF32(output, destination_index + 4, hdr_rgb[1]);
        writeF32(output, destination_index + 8, hdr_rgb[2]);
        writeF32(output, destination_index + 12, a);
    }
    return ktx_hdr.writeHeader(output, RENDER_W, RENDER_H) orelse @trap();
}

fn expandHighlight(r: f32, g: f32, b: f32, emission: u8) [3]f32 {
    // The authored sRGB values are reinterpreted as Display P3 primaries,
    // then pushed further from grey so the enamel blue, rose gold and lume
    // reach colours an sRGB display cannot show. Emissive pixels scale in
    // linear light, which keeps their hue while lifting them past white.
    const luma = r * 0.22897 + g * 0.69174 + b * 0.07929;
    const gain = 1.0 + @as(f32, @floatFromInt(emission)) * (HDR_EMISSION_GAIN / 255.0);
    return .{
        @max(0.0, luma + (r - luma) * HDR_SATURATION) * gain,
        @max(0.0, luma + (g - luma) * HDR_SATURATION) * gain,
        @max(0.0, luma + (b - luma) * HDR_SATURATION) * gain,
    };
}

fn writeF32(output: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, output[offset..][0..4], @bitCast(value), .little);
}

fn drawChronograph(seconds: f32) void {
    if (tilt_angle == 0) {
        render_tilt_scale_x = 1;
        render_tilt_inverse_x = 1;
        render_tilt_sine = 0;
    } else {
        render_tilt_scale_x = std.math.cos(tilt_angle);
        render_tilt_inverse_x = 1.0 / render_tilt_scale_x;
        render_tilt_sine = std.math.sin(tilt_angle);
    }
    updateLight();
    drawStaticDial();
    drawHand(seconds);
    drawGlassReflection();
}

fn updateLight() void {
    const angle = -0.75 * std.math.pi + render_tilt_sine * 2.2;
    const planar: f32 = 0.74;
    light_x = std.math.cos(angle) * planar;
    light_y = std.math.sin(angle) * planar;
    light_z = std.math.sqrt(1.0 - planar * planar);
    const half_length = std.math.sqrt(light_x * light_x + light_y * light_y + (light_z + 1.0) * (light_z + 1.0));
    half_x = light_x / half_length;
    half_y = light_y / half_length;
    half_z = (light_z + 1.0) / half_length;
}

fn drawStaticDial() void {
    const face_on = !isTilted();
    if (face_on and static_cached) {
        @memcpy(pixels(), &static_pixels);
        @memcpy(&emission_buf, &static_emission);
        return;
    }
    drawBackground();
    drawCase();
    drawDialSurface();
    drawBezelReflection();
    drawChapterRing();
    drawIndices();
    drawLabels();
    if (face_on) {
        @memcpy(&static_pixels, pixels());
        @memcpy(&static_emission, &emission_buf);
        static_cached = true;
    }
}

fn drawCase() void {
    // The rear case and raised bezel use the same continuous rose-gold
    // profile at different depths. Their offset reveals a rounded sidewall
    // under yaw instead of exposing the edges of stacked flat-color discs.
    drawMetalAnnulus(scale(143), scale(164), scaleF(1));
    drawMetalAnnulus(scale(143), scale(160), scaleF(7));
    render_layer_offset_x = 0;
}

const Shade = struct { color: Rgb, emission: f32 };

// Polished rose gold: a warm diffuse ramp plus a tight specular lobe that
// carries most of the HDR emission.
fn shadeGold(nx_in: f32, ny_in: f32, nz_in: f32) Shade {
    const inverse_length = 1.0 / std.math.sqrt(nx_in * nx_in + ny_in * ny_in + nz_in * nz_in);
    const nx = nx_in * inverse_length;
    const ny = ny_in * inverse_length;
    const nz = nz_in * inverse_length;
    const diffuse = std.math.clamp(nx * light_x + ny * light_y + nz * light_z, 0.0, 1.0);
    var specular = std.math.clamp(nx * half_x + ny * half_y + nz * half_z, 0.0, 1.0);
    specular *= specular;
    specular *= specular;
    specular *= specular;
    specular *= specular;
    specular *= specular;
    var color = mixRgb(GOLD_DEEP, GOLD_MID, smoothStep(diffuse * 1.3));
    color = mixRgb(color, GOLD_LIGHT, smoothStep((diffuse - 0.62) / 0.38) * 0.75);
    color = mixRgb(color, GOLD_GLINT, specular);
    return .{ .color = color, .emission = specular * 255.0 };
}

fn mixRgb(a: Rgb, b: Rgb, amount: f32) Rgb {
    return .{
        a[0] + (b[0] - a[0]) * amount,
        a[1] + (b[1] - a[1]) * amount,
        a[2] + (b[2] - a[2]) * amount,
    };
}

fn toColor(rgb: Rgb, alpha: u8) Color {
    return .{
        @intFromFloat(@round(std.math.clamp(rgb[0], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(rgb[1], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(rgb[2], 0.0, 1.0) * 255.0)),
        alpha,
    };
}

fn toEmission(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 255.0)));
}

fn blendEmissive(x: i32, y: i32, color: Color, coverage: f32, emission: f32) void {
    paint_emission = toEmission(emission);
    defer paint_emission = 0;
    blendPixelCoverage(x, y, color, coverage);
}

fn blendShade(x: i32, y: i32, shade: Shade, coverage: f32) void {
    blendEmissive(x, y, toColor(shade.color, 0xFF), coverage, shade.emission);
}

// Local-space antialiasing width. Yaw compresses x, so a local unit spans
// less than a screen pixel; averaging both axes keeps edges crisp enough.
inline fn edgeScale() f32 {
    return 2.0 / (1.0 + render_tilt_scale_x);
}

const ScreenBounds = struct { min_x: i32, max_x: i32, min_y: i32, max_y: i32 };

fn screenBounds(min_local_x: f32, max_local_x: f32, min_local_y: f32, max_local_y: f32) ScreenBounds {
    const center_x: f32 = @floatFromInt(CX);
    const center_y: f32 = @floatFromInt(CY);
    return .{
        .min_x = @as(i32, @intFromFloat(@floor(projectedX(center_x + min_local_x)))) - 1,
        .max_x = @as(i32, @intFromFloat(@ceil(projectedX(center_x + max_local_x)))) + 1,
        .min_y = @as(i32, @intFromFloat(@floor(center_y + min_local_y))) - 1,
        .max_y = @as(i32, @intFromFloat(@ceil(center_y + max_local_y))) + 1,
    };
}

inline fn localX(x: i32) f32 {
    return inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5) - @as(f32, @floatFromInt(CX));
}

inline fn localY(y: i32) f32 {
    return @as(f32, @floatFromInt(y - CY)) + 0.5;
}

fn drawMetalAnnulus(inner_radius: i32, outer_radius: i32, depth: f32) void {
    if (!isTilted()) {
        drawFaceOnMetalAnnulus(inner_radius, outer_radius);
        return;
    }
    defer render_layer_offset_x = 0;
    setRenderLayerDepth(depth);

    const inner: f32 = @floatFromInt(inner_radius);
    const outer: f32 = @floatFromInt(outer_radius);
    const reject_inner = @max(0.0, inner - 0.75);
    const reject_outer = outer + 0.75;
    const reject_inner_squared = reject_inner * reject_inner;
    const reject_outer_squared = reject_outer * reject_outer;
    const min_x = projectedFloor(CX - outer_radius) - 1;
    const max_x = projectedCeil(CX + outer_radius) + 1;
    var y = CY - outer_radius - 1;
    while (y <= CY + outer_radius + 1) : (y += 1) {
        const local_y = @as(f32, @floatFromInt(y - CY)) + 0.5;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const local_x = inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5) -
                @as(f32, @floatFromInt(CX));
            const distance_squared = local_x * local_x + local_y * local_y;
            if (distance_squared <= reject_inner_squared or distance_squared >= reject_outer_squared) continue;
            const distance = std.math.sqrt(distance_squared);
            const signed_distance = @max(distance - outer, inner - distance);
            const normal_x = local_x / distance;
            const normal_y = local_y / distance;
            const inverse_derivative = inverseProjectedDerivative(@as(f32, @floatFromInt(x)) + 0.5);
            const gradient = std.math.sqrt(
                normal_x * normal_x * inverse_derivative * inverse_derivative +
                    normal_y * normal_y,
            );
            const coverage = std.math.clamp(0.5 - signed_distance / gradient, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            const radial = std.math.clamp((distance - inner) / (outer - inner), 0.0, 1.0);
            blendShade(x, y, shadeBezel(radial, normal_x, normal_y), coverage);
        }
    }
}

fn drawFaceOnMetalAnnulus(inner_radius: i32, outer_radius: i32) void {
    const inner: f32 = @floatFromInt(inner_radius);
    const outer: f32 = @floatFromInt(outer_radius);
    const reject_inner = @max(0.0, inner - 0.75);
    const reject_outer = outer + 0.75;
    const reject_inner_squared = reject_inner * reject_inner;
    const reject_outer_squared = reject_outer * reject_outer;
    var y = CY - outer_radius - 1;
    while (y <= CY + outer_radius + 1) : (y += 1) {
        const local_y = @as(f32, @floatFromInt(y - CY)) + 0.5;
        const outer_remaining = reject_outer_squared - local_y * local_y;
        if (outer_remaining <= 0.0) continue;
        const outer_extent: i32 = @intFromFloat(@ceil(std.math.sqrt(outer_remaining)));
        const inner_remaining = reject_inner_squared - local_y * local_y;
        if (inner_remaining > 0.0) {
            const inner_extent: i32 = @intFromFloat(@floor(std.math.sqrt(inner_remaining)));
            drawFaceOnMetalSpan(y, CX - outer_extent, CX - inner_extent, inner, outer);
            drawFaceOnMetalSpan(y, CX + inner_extent - 1, CX + outer_extent, inner, outer);
        } else {
            drawFaceOnMetalSpan(y, CX - outer_extent, CX + outer_extent, inner, outer);
        }
    }
}

fn drawFaceOnMetalSpan(y: i32, min_x: i32, max_x: i32, inner: f32, outer: f32) void {
    const local_y = @as(f32, @floatFromInt(y - CY)) + 0.5;
    var x = min_x;
    while (x <= max_x) : (x += 1) {
        const local_x = @as(f32, @floatFromInt(x - CX)) + 0.5;
        const distance = std.math.sqrt(local_x * local_x + local_y * local_y);
        const signed_distance = @max(distance - outer, inner - distance);
        const coverage = std.math.clamp(0.5 - signed_distance, 0.0, 1.0);
        if (coverage <= 0.0) continue;
        const radial = std.math.clamp((distance - inner) / (outer - inner), 0.0, 1.0);
        blendShade(x, y, shadeBezel(radial, local_x / distance, local_y / distance), coverage);
    }
}

// The bezel is a rounded rose-gold profile. Its normal leans toward the
// centre on the inner slope and away on the outer slope, so the key light
// draws a bright arc on the upper-left outside and the lower-right inside.
fn shadeBezel(radial: f32, normal_x: f32, normal_y: f32) Shade {
    const crest: f32 = 0.42;
    const slope = std.math.clamp((radial - crest) * 1.5, -0.95, 0.95);
    const nx = normal_x * slope;
    const ny = normal_y * slope;
    const nz = std.math.sqrt(1.0 - slope * slope);
    var shade = shadeGold(nx, ny, nz);
    // Polished metal mirrors its surroundings: a broad sheen around the
    // glint, and a dark horizon band on the inner slope.
    var broad = std.math.clamp(nx * half_x + ny * half_y + nz * half_z, 0.0, 1.0);
    broad *= broad;
    broad *= broad;
    broad *= broad;
    shade.color = mixRgb(shade.color, GOLD_LIGHT, broad * 0.45);
    shade.emission += broad * 45.0;
    const horizon = std.math.clamp(1.0 - @abs(slope + 0.32) / 0.2, 0.0, 1.0);
    shade.color = mixRgb(shade.color, GOLD_DEEP, horizon * 0.5);
    // A narrow polished bevel where the bezel meets the crystal.
    const bevel = std.math.clamp(1.0 - radial / 0.07, 0.0, 1.0);
    shade.color = mixRgb(shade.color, GOLD_LIGHT, bevel * 0.55);
    shade.emission += bevel * 70.0;
    return shade;
}

fn smoothStep(value: f32) f32 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

fn drawBezelReflection() void {
    if (!isTilted()) return;
    defer render_layer_offset_x = 0;
    setRenderLayerDepth(scaleF(7));

    const outer = scaleF(159);
    const inner = scaleF(145);
    const min_x = projectedFloor(CX - scale(160)) - 1;
    const max_x = projectedCeil(CX + scale(160)) + 1;
    const tilt_strength = std.math.clamp(@abs(render_tilt_sine) * 3.0, 0.0, 1.0);
    const direction = std.math.sign(render_tilt_sine);
    var y = CY - scale(160);
    while (y <= CY + scale(160)) : (y += 1) {
        const local_y = @as(f32, @floatFromInt(y - CY)) + 0.5;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const local_x = inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5) -
                @as(f32, @floatFromInt(CX));
            const distance = std.math.sqrt(local_x * local_x + local_y * local_y);
            if (distance < inner or distance > outer) continue;
            const normal_x = local_x / distance;
            const near = normal_x * direction;
            const broad = std.math.clamp(1.0 - @abs(near - 0.58) / 0.34, 0.0, 1.0) * tilt_strength;
            if (broad > 0.0) {
                blendEmissive(x, y, .{ 0xFF, 0xD9, 0xC4, 0x82 }, broad, 90);
            }
            const sharp = std.math.clamp(1.0 - @abs(near - 0.64) / 0.055, 0.0, 1.0) * tilt_strength;
            if (sharp > 0.0) {
                blendEmissive(x, y, .{ 0xFF, 0xF6, 0xEE, 0xD0 }, sharp, 255);
            }
            const shade = std.math.clamp(1.0 - @abs(near + 0.48) / 0.42, 0.0, 1.0) * tilt_strength;
            if (shade > 0.0) {
                blendPixelCoverage(x, y, .{ 0x2A, 0x0C, 0x06, 0x60 }, shade);
            }
        }
    }
}

fn drawChapterRing() void {
    drawRing(CX, CY, scale(140), scale(1), .{ 0xF6, 0xEA, 0xD4, 0xC8 });
    drawRing(CX, CY, scale(118), scale(1), .{ 0xF6, 0xEA, 0xD4, 0x90 });
    drawRing(CX, CY, scale(92), scale(1), .{ 0xF6, 0xEA, 0xD4, 0x50 });

    // Five divisions per second for an 18,000 vph movement. Float endpoints
    // keep every tick the same length instead of snapping to the pixel grid.
    var tick: u32 = 0;
    while (tick < 300) : (tick += 1) {
        const second_tick = tick % 5 == 0;
        const major = tick % 25 == 0;
        const outer_radius: f32 = scaleF(138);
        const inner_radius: f32 = if (major) scaleF(126) else if (second_tick) scaleF(131) else scaleF(134.5);
        const angle = @as(f32, @floatFromInt(tick)) * std.math.tau / 300.0;
        const sine = std.math.sin(angle);
        const cosine = std.math.cos(angle);
        const center_x: f32 = @floatFromInt(CX);
        const center_y: f32 = @floatFromInt(CY);
        drawLine(
            center_x + sine * inner_radius,
            center_y - cosine * inner_radius,
            center_x + sine * outer_radius,
            center_y - cosine * outer_radius,
            if (major) scaleF(2.2) else if (second_tick) scaleF(1.4) else scaleF(0.9),
            if (major) C_PRINT else if (second_tick) .{ 0xF6, 0xEA, 0xD4, 0xE0 } else .{ 0xF6, 0xEA, 0xD4, 0x88 },
        );
    }
}

fn drawIndices() void {
    // Applied rose-gold batons at the eight hours without a numeral.
    var hour: u32 = 0;
    while (hour < 12) : (hour += 1) {
        if (hour % 3 == 0) continue;
        const angle = @as(f32, @floatFromInt(hour)) * std.math.tau / 12.0;
        drawAppliedBaton(angle, scaleF(95), scaleF(116), scaleF(3.9));
    }
}

fn batonDistance(along: f32, across: f32, middle: f32, half_length: f32, half_width: f32) f32 {
    return @max(@abs(across) - half_width, @abs(along - middle) - half_length);
}

fn drawAppliedBaton(angle: f32, inner: f32, outer: f32, half_width: f32) void {
    defer render_layer_offset_x = 0;
    const dir_x = std.math.sin(angle);
    const dir_y = -std.math.cos(angle);
    const middle = (inner + outer) * 0.5;
    const half_length = (outer - inner) * 0.5;
    const pad = half_width + 5.0;
    const min_lx = @min(dir_x * inner, dir_x * outer) - pad;
    const max_lx = @max(dir_x * inner, dir_x * outer) + pad;
    const min_ly = @min(dir_y * inner, dir_y * outer) - pad;
    const max_ly = @max(dir_y * inner, dir_y * outer) + pad;
    const aa = edgeScale();

    // A soft drop shadow on the dial sells the applied height.
    setRenderLayerDepth(scaleF(1));
    var bounds = screenBounds(min_lx, max_lx, min_ly, max_ly);
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const ly = localY(y) - 2.2;
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const lx = localX(x) - 1.4;
            const distance = batonDistance(lx * dir_x + ly * dir_y, lx * -dir_y + ly * dir_x, middle, half_length, half_width);
            blendPixelCoverage(x, y, C_SHADOW, std.math.clamp(0.5 - distance / 1.8, 0.0, 1.0));
        }
    }

    setRenderLayerDepth(scaleF(3));
    bounds = screenBounds(min_lx, max_lx, min_ly, max_ly);
    y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const ly = localY(y);
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const lx = localX(x);
            const along = lx * dir_x + ly * dir_y;
            const across = lx * -dir_y + ly * dir_x;
            const distance = batonDistance(along, across, middle, half_length, half_width);
            const coverage = std.math.clamp(0.5 - distance * aa, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            // Two long facets meet at a centre ridge; the ends are bevelled.
            const facet = std.math.clamp(across * 1.6, -1.0, 1.0) * 0.62;
            const end_offset = along - middle;
            const end = std.math.clamp((@abs(end_offset) - (half_length - 1.6)) / 1.6, 0.0, 1.0) *
                std.math.sign(end_offset) * 0.62;
            const nx = -dir_y * facet + dir_x * end;
            const ny = dir_x * facet + dir_y * end;
            blendShade(x, y, shadeGold(nx, ny, 0.78), coverage);
        }
    }
}

fn drawLabels() void {
    drawAppliedNumeral("60", CX, CY - scale(104));
    drawAppliedNumeral("15", CX + scale(103), CY);
    drawAppliedNumeral("30", CX, CY + scale(104));
    drawAppliedNumeral("45", CX - scale(103), CY);
}

fn drawAppliedNumeral(text: []const u8, center_x: i32, center_y: i32) void {
    // Shadow, lit upper-left rim, then the body: three passes of the same
    // glyph read as raised, polished metal.
    drawCenteredText(text, center_x + 1, center_y + 2, C_SHADOW);
    paint_emission = 150;
    drawCenteredText(text, center_x - 1, center_y - 1, toColor(GOLD_LIGHT, 0xFF));
    paint_emission = 0;
    drawCenteredText(text, center_x, center_y, toColor(.{ 0.80, 0.50, 0.39 }, 0xFF));
}

const HAND_TIP: f32 = 132.0;
const HAND_TAIL: f32 = -31.0;
const HAND_LOLLIPOP: f32 = 101.0;
const HAND_LOLLIPOP_RADIUS: f32 = 6.6;
const HAND_LUME_RADIUS: f32 = 4.5;
const HAND_WEIGHT: f32 = -23.0;
const HAND_WEIGHT_RADIUS: f32 = 5.8;
const HAND_CAP_RADIUS: f32 = 7.5;

fn handDistance(along: f32, across: f32) f32 {
    const taper = std.math.clamp(along / HAND_TIP, 0.0, 1.0);
    const half_width: f32 = if (along < 0.0) 2.2 else 2.9 - 1.9 * taper;
    const shaft = @max(@abs(across) - half_width, @max(HAND_TAIL - along, along - HAND_TIP));
    const lollipop = std.math.hypot(along - HAND_LOLLIPOP, across) - HAND_LOLLIPOP_RADIUS;
    const weight = std.math.hypot(along - HAND_WEIGHT, across) - HAND_WEIGHT_RADIUS;
    return @min(shaft, @min(lollipop, weight));
}

fn drawHand(seconds: f32) void {
    defer render_layer_offset_x = 0;
    const hand_angle = seconds * std.math.tau / 60.0;
    const dir_x = std.math.sin(hand_angle);
    const dir_y = -std.math.cos(hand_angle);
    const pad: f32 = HAND_WEIGHT_RADIUS + 6.0;
    const min_lx = @min(dir_x * HAND_TAIL, dir_x * HAND_TIP) - pad;
    const max_lx = @max(dir_x * HAND_TAIL, dir_x * HAND_TIP) + pad;
    const min_ly = @min(dir_y * HAND_TAIL, dir_y * HAND_TIP) - pad;
    const max_ly = @max(dir_y * HAND_TAIL, dir_y * HAND_TIP) + pad;
    const aa = edgeScale();

    // Separate the shadow, hand, and cap into shallow depth planes. Yaw moves
    // each plane by a different amount, which gives the hand parallax without
    // allocating or compositing an intermediate image.
    setRenderLayerDepth(scaleF(1));
    var bounds = screenBounds(min_lx, max_lx, min_ly, max_ly);
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const ly = localY(y) - 4.0;
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const lx = localX(x) - 3.0;
            const distance = handDistance(lx * dir_x + ly * dir_y, lx * -dir_y + ly * dir_x);
            blendPixelCoverage(x, y, C_SHADOW, std.math.clamp(0.5 - distance / 2.4, 0.0, 1.0));
        }
    }

    setRenderLayerDepth(scaleF(6));
    bounds = screenBounds(min_lx, max_lx, min_ly, max_ly);
    y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const ly = localY(y);
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const lx = localX(x);
            const along = lx * dir_x + ly * dir_y;
            const across = lx * -dir_y + ly * dir_x;
            const distance = handDistance(along, across);
            const coverage = std.math.clamp(0.5 - distance * aa, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            blendShade(x, y, shadeHand(along, across, dir_x, dir_y), coverage);
        }
    }

    // Domed centre cap with a dark pinion at its heart.
    setRenderLayerDepth(scaleF(9));
    const cap = HAND_CAP_RADIUS + 1.0;
    bounds = screenBounds(-cap, cap, -cap, cap);
    y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const ly = localY(y);
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const lx = localX(x);
            const radius = std.math.sqrt(lx * lx + ly * ly);
            const coverage = std.math.clamp(0.5 - (radius - HAND_CAP_RADIUS) * aa, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            var shade = shadeGold(lx / HAND_CAP_RADIUS * 0.85, ly / HAND_CAP_RADIUS * 0.85, 0.75);
            const pinion = std.math.clamp(1.6 - radius, 0.0, 1.0);
            shade.color = mixRgb(shade.color, GOLD_DEEP, pinion * 0.9);
            shade.emission *= 1.0 - pinion;
            blendShade(x, y, shade, coverage);
        }
    }
}

fn shadeHand(along: f32, across: f32, dir_x: f32, dir_y: f32) Shade {
    const lollipop_along = along - HAND_LOLLIPOP;
    const lollipop_radius = std.math.hypot(lollipop_along, across);
    if (lollipop_radius < HAND_LOLLIPOP_RADIUS + 0.5) {
        if (lollipop_radius < HAND_LUME_RADIUS) {
            // Lume glows well past diffuse white on HDR displays.
            const fade = std.math.clamp(HAND_LUME_RADIUS - lollipop_radius, 0.0, 1.0);
            var shade = shadeGold(0, 0, 1);
            shade.color = mixRgb(shade.color, LUME, fade);
            shade.emission = 165.0 * fade;
            return shade;
        }
        // The lume frame is a rounded bezel.
        const slope = std.math.clamp((lollipop_radius - (HAND_LUME_RADIUS + HAND_LOLLIPOP_RADIUS) * 0.5) * 0.55, -0.7, 0.7);
        return shadeLocalNormal(lollipop_along / lollipop_radius * slope, across / lollipop_radius * slope, dir_x, dir_y);
    }
    const weight_along = along - HAND_WEIGHT;
    const weight_radius = std.math.hypot(weight_along, across);
    if (weight_radius < HAND_WEIGHT_RADIUS + 0.5) {
        // Domed counterweight with an engraved ring.
        const dome = std.math.clamp(weight_radius / HAND_WEIGHT_RADIUS, 0.0, 1.0) * 0.8;
        const inverse = 1.0 / @max(weight_radius, 0.001);
        var shade = shadeLocalNormal(weight_along * inverse * dome, across * inverse * dome, dir_x, dir_y);
        const groove = std.math.clamp(1.0 - @abs(weight_radius - 3.4) / 0.7, 0.0, 1.0);
        shade.color = mixRgb(shade.color, GOLD_DEEP, groove * 0.75);
        shade.emission *= 1.0 - groove;
        return shade;
    }
    // Two facets meet along the centre of the shaft, one lit, one shaded.
    return shadeLocalNormal(0, std.math.clamp(across * 1.8, -1.0, 1.0) * 0.7, dir_x, dir_y);
}

fn shadeLocalNormal(normal_along: f32, normal_across: f32, dir_x: f32, dir_y: f32) Shade {
    return shadeGold(
        dir_x * normal_along - dir_y * normal_across,
        dir_y * normal_along + dir_x * normal_across,
        std.math.sqrt(@max(0.05, 1.0 - normal_along * normal_along - normal_across * normal_across)),
    );
}

fn drawGlassReflection() void {
    if (isTilted()) {
        drawTiltedGlassReflection();
        return;
    }
    // A rotated, shallow curve reads as a reflected window across domed
    // crystal. Draw it after the hand so the highlight belongs to the glass,
    // not the dial. The HDR expansion lifts its near-neutral bright pixels
    // above diffuse white while the same geometry remains visible in SDR.
    const crystal_radius_squared = scale(143) * scale(143);

    // The curved window reflection occupies only the upper portion of the
    // crystal. Restricting the scan avoids paying for transparent glass over
    // the complete dial on every frame.
    var y = CY - scale(143);
    while (y <= CY + scale(38)) : (y += 1) {
        const dy_i = y - CY;
        const dy: f32 = @floatFromInt(dy_i);
        var x = CX - scale(143);
        var along = -scaleF(143) * 0.819152 - dy * 0.573576;
        var across = -scaleF(143) * 0.573576 + dy * 0.819152;
        while (x <= CX + scale(132)) : ({
            x += 1;
            along += 0.819152;
            across += 0.573576;
        }) {
            const dx_i = x - CX;
            const distance_squared_i = dx_i * dx_i + dy_i * dy_i;
            if (distance_squared_i > crystal_radius_squared) continue;

            // Rotate the reflected window about 35 degrees. A small quadratic
            // bend follows the convex crystal instead of making a flat stripe.
            if (along < -scaleF(132) or along > scaleF(120) or
                across < -scaleF(136) or across > -scaleF(30)) continue;

            const end_fade = @min(
                std.math.clamp((along + scaleF(132)) / scaleF(28), 0.0, 1.0),
                std.math.clamp((scaleF(108) - along) / scaleF(28), 0.0, 1.0),
            );
            const curve = -scaleF(76) + along * along * 0.00075;
            const curve_distance = @abs(across - curve);

            const wash_ellipse =
                ((along - scaleF(4)) * (along - scaleF(4))) / (scaleF(116) * scaleF(116)) +
                ((across + scaleF(83)) * (across + scaleF(83))) / (scaleF(52) * scaleF(52));
            const wash = std.math.clamp((1.0 - wash_ellipse) / 0.72, 0.0, 1.0);
            if (wash > 0.0) blendEmissive(x, y, .{ 0xF0, 0xF2, 0xFF, 0x26 }, wash, 40);

            const broad = std.math.clamp((scaleF(27) - curve_distance) / scaleF(20), 0.0, 1.0) * end_fade;
            if (broad > 0.0) blendEmissive(x, y, .{ 0xF6, 0xF6, 0xFF, 0x38 }, broad, 90);

            const sharp = std.math.clamp(1.0 - curve_distance / scaleF(2), 0.0, 1.0) * end_fade;
            if (sharp > 0.0) blendEmissive(x, y, .{ 0xFF, 0xFF, 0xFF, 0x90 }, sharp, 230);

            const echo_distance = @abs(across - (curve + scaleF(21)));
            const echo = std.math.clamp(1.0 - echo_distance / scaleF(4), 0.0, 1.0) * end_fade;
            if (echo > 0.0) blendEmissive(x, y, .{ 0xD8, 0xD0, 0xFF, 0x44 }, echo, 110);
        }
    }
}

fn drawTiltedGlassReflection() void {
    defer render_layer_offset_x = 0;
    setRenderLayerDepth(scaleF(12));
    const crystal_radius = scaleF(143);
    const crystal_radius_squared = crystal_radius * crystal_radius;
    const min_x = projectedFloor(CX - scale(143)) - 1;
    const max_x = projectedCeil(CX + scale(143)) + 1;
    const reflection_shift = render_tilt_sine * scaleF(72);
    const tilt_strength = std.math.clamp(@abs(render_tilt_sine) * 3.2, 0.0, 1.0);
    // The face-on reflection fits above CY + 38. Positive yaw moves the
    // rotated band down by reflection_shift / cos(35deg); extend the bounded
    // scan with it instead of clipping the moving highlight at the old limit.
    const reflection_y_extension: i32 = if (reflection_shift > 0.0)
        @intFromFloat(@ceil(reflection_shift / 0.819152))
    else
        0;
    const max_y = @min(CY + scale(143), CY + scale(38) + reflection_y_extension);

    var y = CY - scale(143);
    while (y <= max_y) : (y += 1) {
        const dy: f32 = @floatFromInt(y - CY);
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const local_x = inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5);
            const dx = local_x - @as(f32, @floatFromInt(CX));
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared > crystal_radius_squared) continue;

            const along = dx * 0.819152 - dy * 0.573576;
            const across = dx * 0.573576 + dy * 0.819152 - reflection_shift;
            const side = std.math.clamp(
                0.5 + dx / crystal_radius * std.math.sign(render_tilt_sine) * 0.85,
                0.0,
                1.0,
            );
            const edge = if (distance_squared > scaleF(134) * scaleF(134))
                std.math.clamp(
                    (std.math.sqrt(distance_squared) - scaleF(134)) / scaleF(8),
                    0.0,
                    1.0,
                ) * side * tilt_strength
            else
                0.0;
            if (edge > 0.0) blendEmissive(x, y, .{ 0xF4, 0xF0, 0xFF, 0x82 }, edge, 120);

            if (along < -scaleF(132) or along > scaleF(120) or
                across < -scaleF(136) or across > -scaleF(30)) continue;

            const end_fade = @min(
                std.math.clamp((along + scaleF(132)) / scaleF(28), 0.0, 1.0),
                std.math.clamp((scaleF(108) - along) / scaleF(28), 0.0, 1.0),
            );
            const curve = -scaleF(76) + along * along * 0.00075;
            const curve_distance = @abs(across - curve);
            const wash_ellipse =
                ((along - scaleF(4)) * (along - scaleF(4))) / (scaleF(116) * scaleF(116)) +
                ((across + scaleF(83)) * (across + scaleF(83))) / (scaleF(52) * scaleF(52));
            const wash = std.math.clamp((1.0 - wash_ellipse) / 0.72, 0.0, 1.0);
            if (wash > 0.0) blendEmissive(x, y, .{ 0xF0, 0xF2, 0xFF, 0x26 }, wash, 40);

            const broad = std.math.clamp((scaleF(27) - curve_distance) / scaleF(20), 0.0, 1.0) * end_fade;
            if (broad > 0.0) blendEmissive(x, y, .{ 0xF6, 0xF6, 0xFF, 0x38 }, broad, 90);
            const sharp = std.math.clamp(1.0 - curve_distance / scaleF(2), 0.0, 1.0) * end_fade;
            if (sharp > 0.0) blendEmissive(x, y, .{ 0xFF, 0xFF, 0xFF, 0x90 }, sharp, 230);
            const echo_distance = @abs(across - (curve + scaleF(21)));
            const echo = std.math.clamp(1.0 - echo_distance / scaleF(4), 0.0, 1.0) * end_fade;
            if (echo > 0.0) blendEmissive(x, y, .{ 0xD8, 0xD0, 0xFF, 0x44 }, echo, 110);
        }
    }
}

fn drawBackground() void {
    @memset(pixels(), 0);
    @memset(&emission_buf, 0);
}

fn drawDialSurface() void {
    // Deep blue enamel shading from a bright centre to a smoked edge. The
    // centre is engine-turned in a clous de Paris hobnail, the middle ring is
    // snailed with concentric grooves, and the chapter ring is flat. A radial
    // sunburst sheen follows the key light, so it sweeps as the watch tilts.
    const radius: f32 = scaleF(144);
    const bounds = screenBounds(-radius - 1.0, radius + 1.0, -radius - 1.0, radius + 1.0);
    const sheen_gain = 0.7 + std.math.clamp(@abs(render_tilt_sine) * 2.5, 0.0, 0.6);
    const planar_inverse = 1.0 / std.math.sqrt(light_x * light_x + light_y * light_y);
    const light_dir_x = light_x * planar_inverse;
    const light_dir_y = light_y * planar_inverse;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const ly = localY(y);
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const lx = localX(x);
            const distance_squared = lx * lx + ly * ly;
            if (distance_squared >= (radius + 1.0) * (radius + 1.0)) continue;
            const distance = std.math.sqrt(distance_squared);
            const coverage = std.math.clamp(radius + 0.5 - distance, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            const normalized = distance / radius;
            var color = mixRgb(ENAMEL_CENTER, ENAMEL_EDGE, smoothStep(normalized * 1.08));

            const inverse = 1.0 / @max(distance, 0.5);
            const facing = (lx * light_dir_x + ly * light_dir_y) * inverse;
            const facing_squared = facing * facing;
            var sheen = facing_squared * facing_squared;
            sheen *= sheen * sheen_gain;

            var light: f32 = 0;
            var emission: f32 = 0;
            if (distance < scaleF(90)) {
                const facet = shadeHobnail(lx, ly);
                light = facet.light + sheen * 0.16;
                emission = facet.glint * (25.0 + 110.0 * sheen) + sheen * 30.0;
                color = mixRgb(color, ENAMEL_EDGE, facet.groove * 0.65);
            } else if (distance < scaleF(92)) {
                // A polished border frames the engine-turned centre.
                light = 0.08 + sheen * 0.45;
                emission = sheen * 60.0;
            } else if (distance < scaleF(118)) {
                const groove = std.math.sin(distance * (std.math.tau / 3.0));
                light = 0.05 * groove * facing + sheen * 0.24;
                emission = sheen * 40.0;
                color = mixRgb(color, ENAMEL_EDGE, 0.12);
            } else {
                light = sheen * 0.14;
                emission = sheen * 18.0;
                color = mixRgb(color, ENAMEL_EDGE, 0.28);
            }
            color = .{
                color[0] + light * ENAMEL_SHEEN[0],
                color[1] + light * ENAMEL_SHEEN[1],
                color[2] + light * ENAMEL_SHEEN[2],
            };
            blendEmissive(x, y, toColor(color, 0xFF), coverage, emission);
        }
    }
}

const HOBNAIL_PERIOD: f32 = 7.0;
const Hobnail = struct { light: f32, glint: f32, groove: f32 };

// Clous de Paris: a grid of small pyramids cut on the diagonal. Each pixel
// takes the normal of the pyramid face it lies on, so faces turned toward
// the light glitter while their opposites fall dark.
fn shadeHobnail(lx: f32, ly: f32) Hobnail {
    const u = (lx + ly) * (std.math.sqrt1_2 / HOBNAIL_PERIOD);
    const v = (lx - ly) * (std.math.sqrt1_2 / HOBNAIL_PERIOD);
    const fu = u - @floor(u) - 0.5;
    const fv = v - @floor(v) - 0.5;
    const slope: f32 = 0.42;
    var nx: f32 = 0;
    var ny: f32 = 0;
    // The u axis points along (1, 1) and v along (1, -1) in dial space.
    if (@abs(fu) > @abs(fv)) {
        const sign = std.math.sign(fu) * slope * std.math.sqrt1_2;
        nx = sign;
        ny = sign;
    } else {
        const sign = std.math.sign(fv) * slope * std.math.sqrt1_2;
        nx = sign;
        ny = -sign;
    }
    const nz = std.math.sqrt(1.0 - slope * slope);
    const diffuse = nx * light_x + ny * light_y + nz * light_z - light_z;
    var glint = std.math.clamp(nx * half_x + ny * half_y + nz * half_z, 0.0, 1.0);
    glint *= glint;
    glint *= glint;
    glint *= glint;
    glint *= glint;
    const groove = std.math.clamp((@max(@abs(fu), @abs(fv)) - 0.44) / 0.06, 0.0, 1.0);
    return .{
        .light = (diffuse * 0.32 + glint * 0.30) * (1.0 - groove),
        .glint = glint * (1.0 - groove),
        .groove = groove,
    };
}

fn scale(value: i32) i32 {
    return value * DRAW_SCALE;
}

fn scaleF(comptime value: f32) f32 {
    return value * @as(f32, @floatFromInt(DRAW_SCALE));
}

inline fn isTilted() bool {
    return @abs(render_tilt_sine) > 0.0001;
}

inline fn projectedX(local_x: f32) f32 {
    const center: f32 = @floatFromInt(CX);
    return center + (local_x - center) * render_tilt_scale_x + render_layer_offset_x;
}

inline fn inverseProjectedX(screen_x: f32) f32 {
    const center: f32 = @floatFromInt(CX);
    return center + (screen_x - center - render_layer_offset_x) * render_tilt_inverse_x;
}

inline fn inverseProjectedDerivative(_: f32) f32 {
    return render_tilt_inverse_x;
}

inline fn setRenderLayerDepth(depth: f32) void {
    render_layer_offset_x = render_tilt_sine * depth;
}

fn projectedFloor(local_x: i32) i32 {
    return @intFromFloat(@floor(projectedX(@floatFromInt(local_x))));
}

fn projectedCeil(local_x: i32) i32 {
    return @intFromFloat(@ceil(projectedX(@floatFromInt(local_x))));
}

fn drawCenteredText(text: []const u8, center_x: i32, center_y: i32, color: Color) void {
    var width: i32 = 0;
    for (text) |character| width += glyphAdvance(character);
    var x = center_x - @divTrunc(width, 2);
    for (text) |character| {
        drawGlyph(character, x, center_y - @as(i32, @intCast(font.GLYPH_H / 2)), color);
        x += glyphAdvance(character);
    }
}

fn glyphAdvance(character: u8) i32 {
    const index = glyphIndex(character) orelse return 0;
    return font.advances[index];
}

fn glyphIndex(character: u8) ?usize {
    for (font.codepoints, 0..) |codepoint, index| {
        if (codepoint == character) return index;
    }
    return null;
}

fn drawGlyph(character: u8, origin_x: i32, origin_y: i32, color: Color) void {
    const glyph_index = glyphIndex(character) orelse return;
    if (isTilted()) {
        const min_x = projectedFloor(origin_x) - 1;
        const max_x = projectedCeil(origin_x + @as(i32, @intCast(font.GLYPH_W))) + 1;
        var destination_y: usize = 0;
        while (destination_y < font.GLYPH_H) : (destination_y += 1) {
            var destination_x = min_x;
            while (destination_x <= max_x) : (destination_x += 1) {
                const local_x = inverseProjectedX(@as(f32, @floatFromInt(destination_x)) + 0.5) - @as(f32, @floatFromInt(origin_x));
                if (local_x < 0 or local_x >= @as(f32, @floatFromInt(font.GLYPH_W))) continue;
                const source_x: usize = @intFromFloat(@floor(local_x));
                const pixel_index = destination_y * font.GLYPH_W + source_x;
                const byte = font.glyph_alpha4[glyph_index][pixel_index / 2];
                const alpha4 = if (pixel_index % 2 == 0) byte >> 4 else byte & 0x0F;
                if (alpha4 == 0) continue;
                var source = color;
                source[3] = @intCast((@as(u16, color[3]) * alpha4) / 15);
                blendPixel(destination_x, origin_y + @as(i32, @intCast(destination_y)), source);
            }
        }
        return;
    }
    var y: usize = 0;
    while (y < font.GLYPH_H) : (y += 1) {
        var x: usize = 0;
        while (x < font.GLYPH_W) : (x += 1) {
            const pixel_index = y * font.GLYPH_W + x;
            const byte = font.glyph_alpha4[glyph_index][pixel_index / 2];
            const alpha4 = if (pixel_index % 2 == 0) byte >> 4 else byte & 0x0F;
            if (alpha4 == 0) continue;
            var source = color;
            source[3] = @intCast((@as(u16, color[3]) * alpha4) / 15);
            blendPixel(origin_x + @as(i32, @intCast(x)), origin_y + @as(i32, @intCast(y)), source);
        }
    }
}

fn drawLine(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: Color) void {
    const projected_x0: f32 = if (isTilted()) projectedX(x0) else x0;
    const projected_x1: f32 = if (isTilted()) projectedX(x1) else x1;
    const ax = projected_x0;
    const ay = y0;
    const vx = projected_x1 - projected_x0;
    const vy = y1 - y0;
    const length_squared = vx * vx + vy * vy;
    const local_vx = x1 - x0;
    const local_vy = y1 - y0;
    const local_length = std.math.sqrt(local_vx * local_vx + local_vy * local_vy);
    const normal_scale = if (!isTilted() or local_length == 0)
        1.0
    else
        std.math.sqrt((local_vy / local_length * render_tilt_scale_x) * (local_vy / local_length * render_tilt_scale_x) +
            (local_vx / local_length) * (local_vx / local_length));
    const half_width = @max(0.5, thickness * 0.5) * normal_scale;
    const padding: f32 = @ceil(half_width) + 1.0;

    const min_x: i32 = @intFromFloat(@floor(@min(projected_x0, projected_x1) - padding));
    const max_x: i32 = @intFromFloat(@ceil(@max(projected_x0, projected_x1) + padding));
    const min_y: i32 = @intFromFloat(@floor(@min(y0, y1) - padding));
    const max_y: i32 = @intFromFloat(@ceil(@max(y0, y1) + padding));

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const t = if (length_squared == 0)
                0.0
            else
                std.math.clamp(((px - ax) * vx + (py - ay) * vy) / length_squared, 0.0, 1.0);
            const dx = px - (ax + vx * t);
            const dy = py - (ay + vy * t);
            const coverage = std.math.clamp(half_width + 0.5 - std.math.sqrt(dx * dx + dy * dy), 0.0, 1.0);
            blendPixelCoverage(x, y, color, coverage);
        }
    }
}

fn fillCircle(cx: i32, cy: i32, radius: i32, color: Color) void {
    if (isTilted()) {
        fillTiltedCircle(cx, cy, radius, color);
        return;
    }
    var y = cy - radius - 1;
    while (y <= cy + radius + 1) : (y += 1) {
        var x = cx - radius - 1;
        while (x <= cx + radius + 1) : (x += 1) {
            const coverage = circleCoverage(x, y, cx, cy, radius);
            if (coverage >= 1.0) {
                blendPixel(x, y, color);
                continue;
            }
            blendPixelCoverage(x, y, color, coverage);
        }
    }
}

fn fillTiltedCircle(cx: i32, cy: i32, radius: i32, color: Color) void {
    const radius_f: f32 = @floatFromInt(radius);
    const antialias_local: f32 = 0.75;
    const opaque_radius = @max(0.0, radius_f - antialias_local);
    const transparent_radius = radius_f + antialias_local;
    const opaque_radius_squared = opaque_radius * opaque_radius;
    const transparent_radius_squared = transparent_radius * transparent_radius;
    const min_x = projectedFloor(cx - radius) - 1;
    const max_x = projectedCeil(cx + radius) + 1;
    var y = cy - radius - 1;
    while (y <= cy + radius + 1) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const local_dx = inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5) - @as(f32, @floatFromInt(cx));
            const local_dy = @as(f32, @floatFromInt(y - cy)) + 0.5;
            const distance_squared = local_dx * local_dx + local_dy * local_dy;
            if (distance_squared <= opaque_radius_squared) {
                blendPixel(x, y, color);
                continue;
            }
            if (distance_squared >= transparent_radius_squared) continue;
            const distance = std.math.sqrt(distance_squared);
            if (distance == 0) {
                blendPixel(x, y, color);
                continue;
            }
            const nx = local_dx / distance;
            const ny = local_dy / distance;
            const inverse_derivative = inverseProjectedDerivative(@as(f32, @floatFromInt(x)) + 0.5);
            const gradient = std.math.sqrt(nx * nx * inverse_derivative * inverse_derivative + ny * ny);
            const screen_distance = (distance - radius_f) / gradient;
            const coverage = std.math.clamp(0.5 - screen_distance, 0.0, 1.0);
            if (coverage >= 1.0) {
                blendPixel(x, y, color);
            } else {
                blendPixelCoverage(x, y, color, coverage);
            }
        }
    }
}

inline fn circleCoverage(x: i32, y: i32, cx: i32, cy: i32, radius: i32) f32 {
    const radius_f: f32 = @floatFromInt(radius);
    const dx = @as(f32, @floatFromInt(x - cx)) + 0.5;
    const dy = @as(f32, @floatFromInt(y - cy)) + 0.5;
    const distance_squared = dx * dx + dy * dy;
    const opaque_radius = radius_f - 0.5;
    const transparent_radius = radius_f + 0.5;
    if (distance_squared <= opaque_radius * opaque_radius) return 1.0;
    if (distance_squared >= transparent_radius * transparent_radius) return 0.0;
    return transparent_radius - std.math.sqrt(distance_squared);
}

fn drawRing(cx: i32, cy: i32, radius: i32, thickness: i32, color: Color) void {
    if (isTilted()) {
        drawTiltedRing(cx, cy, radius, thickness, color);
        return;
    }
    const outer: f32 = @floatFromInt(radius);
    const inner: f32 = @floatFromInt(@max(0, radius - thickness));
    const reject_inside_squared = @max(0.0, inner - 0.5) * @max(0.0, inner - 0.5);
    const reject_outside_squared = (outer + 0.5) * (outer + 0.5);
    const full_inside_squared = (inner + 0.5) * (inner + 0.5);
    const full_outside_squared = @max(0.0, outer - 0.5) * @max(0.0, outer - 0.5);
    var y = cy - radius - 1;
    while (y <= cy + radius + 1) : (y += 1) {
        var x = cx - radius - 1;
        while (x <= cx + radius + 1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x - cx)) + 0.5;
            const dy = @as(f32, @floatFromInt(y - cy)) + 0.5;
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared <= reject_inside_squared or distance_squared >= reject_outside_squared) continue;
            if (distance_squared >= full_inside_squared and distance_squared <= full_outside_squared) {
                blendPixel(x, y, color);
                continue;
            }
            const distance = std.math.sqrt(distance_squared);
            const outer_coverage = outer + 0.5 - distance;
            const inner_coverage = distance - inner + 0.5;
            const coverage = std.math.clamp(@min(outer_coverage, inner_coverage), 0.0, 1.0);
            blendPixelCoverage(x, y, color, coverage);
        }
    }
}

fn drawTiltedRing(cx: i32, cy: i32, radius: i32, thickness: i32, color: Color) void {
    const outer: f32 = @floatFromInt(radius);
    const inner: f32 = @floatFromInt(@max(0, radius - thickness));
    const antialias_local: f32 = 0.75;
    const reject_inner = @max(0.0, inner - antialias_local);
    const reject_outer = outer + antialias_local;
    const full_inner = inner + antialias_local;
    const full_outer = @max(0.0, outer - antialias_local);
    const reject_inner_squared = reject_inner * reject_inner;
    const reject_outer_squared = reject_outer * reject_outer;
    const full_inner_squared = full_inner * full_inner;
    const full_outer_squared = full_outer * full_outer;
    const min_x = projectedFloor(cx - radius) - 1;
    const max_x = projectedCeil(cx + radius) + 1;
    var y = cy - radius - 1;
    while (y <= cy + radius + 1) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const local_dx = inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5) - @as(f32, @floatFromInt(cx));
            const local_dy = @as(f32, @floatFromInt(y - cy)) + 0.5;
            const distance_squared = local_dx * local_dx + local_dy * local_dy;
            if (distance_squared <= reject_inner_squared or distance_squared >= reject_outer_squared) continue;
            if (distance_squared >= full_inner_squared and distance_squared <= full_outer_squared) {
                blendPixel(x, y, color);
                continue;
            }
            const distance = std.math.sqrt(distance_squared);
            if (distance == 0) continue;
            const signed_distance = @max(distance - outer, inner - distance);
            const nx = local_dx / distance;
            const ny = local_dy / distance;
            const inverse_derivative = inverseProjectedDerivative(@as(f32, @floatFromInt(x)) + 0.5);
            const gradient = std.math.sqrt(nx * nx * inverse_derivative * inverse_derivative + ny * ny);
            const coverage = std.math.clamp(0.5 - signed_distance / gradient, 0.0, 1.0);
            if (coverage >= 1.0) {
                blendPixel(x, y, color);
            } else {
                blendPixelCoverage(x, y, color, coverage);
            }
        }
    }
}

fn blendPixelCoverage(x: i32, y: i32, color: Color, coverage: f32) void {
    if (coverage <= 0.0) return;
    var covered = color;
    covered[3] = @intFromFloat(@round(@as(f32, @floatFromInt(color[3])) * coverage));
    blendPixel(x, y, covered);
}

fn setPixel(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const pixel_index = @as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x));
    const index = pixel_index * 4;
    @memcpy(pixels()[index .. index + 4], &color);
    emission_buf[pixel_index] = paint_emission;
}

fn blendPixel(x: i32, y: i32, source: Color) void {
    if (source[3] == 0 or x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    if (source[3] == 255) {
        setPixel(x, y, source);
        return;
    }
    const pixel_index = @as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x));
    const index = pixel_index * 4;
    const source_alpha: u32 = source[3];
    const destination_alpha: u32 = pixels()[index + 3];
    if (destination_alpha == 0) {
        setPixel(x, y, source);
        return;
    }
    const inverse: u32 = 255 - source_alpha;
    emission_buf[pixel_index] = @intCast(@divTrunc(
        @as(u32, paint_emission) * source_alpha + @as(u32, emission_buf[pixel_index]) * inverse + 127,
        255,
    ));
    if (destination_alpha == 255) {
        var channel: usize = 0;
        while (channel < 3) : (channel += 1) {
            const mixed = @as(u32, source[channel]) * source_alpha +
                @as(u32, pixels()[index + channel]) * inverse;
            pixels()[index + channel] = @intCast(@divTrunc(mixed + 127, 255));
        }
        return;
    }
    const output_alpha: u32 = source_alpha + @divTrunc(destination_alpha * inverse + 127, 255);
    if (output_alpha == 0) return;
    var channel: usize = 0;
    while (channel < 3) : (channel += 1) {
        const source_term = @as(u32, source[channel]) * source_alpha;
        const destination_term = @divTrunc(@as(u32, pixels()[index + channel]) * destination_alpha * inverse + 127, 255);
        // Rounding both terms can land one step above 255 on bright edges.
        pixels()[index + channel] = @intCast(@min(255, @divTrunc(source_term + destination_term + output_alpha / 2, output_alpha)));
    }
    pixels()[index + 3] = @intCast(output_alpha);
}

test "renders the requested second as canonical KTX2" {
    resetForTest();
    try std.testing.expectApproxEqAbs(@as(f32, 15.2), uniform_set_current_seconds(75.39), 0.001);
    const size = renderImpl(0);
    const image = ktx_sdr.parse(output_buf[0..size]).?;
    try std.testing.expectEqual(RENDER_W, image.width);
    try std.testing.expectEqual(RENDER_H, image.height);
    try std.testing.expectEqual(@as(u8, 0), image.pixels[3]);
    const center = (RENDER_H / 2 * RENDER_W + RENDER_W / 2) * 4;
    try std.testing.expectEqual(@as(u8, 255), image.pixels[center + 3]);
    var has_antialiased_silhouette = false;
    var pixel_index: usize = 3;
    while (pixel_index < image.pixels.len) : (pixel_index += 4) {
        const alpha = image.pixels[pixel_index];
        if (alpha > 0 and alpha < 255) {
            has_antialiased_silhouette = true;
            break;
        }
    }
    try std.testing.expect(has_antialiased_silhouette);
}

test "HDR uniform emits linear Display P3 float pixels with extended highlights" {
    resetForTest();
    _ = uniform_set_current_seconds(15.2);
    try std.testing.expectEqual(@as(u32, 1), uniform_set_hdr(7));
    const size = renderImpl(0);
    try std.testing.expectEqual(HDR_OUTPUT_BYTES, size);
    const image = ktx_hdr.parse(output_buf[0..size]).?;
    try std.testing.expectEqual(RENDER_W, image.width);
    try std.testing.expectEqual(RENDER_H, image.height);
    try std.testing.expectEqual(@as(f32, 0), image.pixels[3]);

    var has_extended_value = false;
    var channel: usize = 0;
    while (channel < image.pixels.len) : (channel += 4) {
        if (image.pixels[channel] > 1.0 or image.pixels[channel + 1] > 1.0 or image.pixels[channel + 2] > 1.0) {
            has_extended_value = true;
            break;
        }
    }
    try std.testing.expect(has_extended_value);
    try std.testing.expect(!uniform_hdr);
}

test "Timed update commits a fifth-second step and schedules 200 ms" {
    resetForTest();
    _ = uniform_set_current_seconds(14.0);
    _ = renderImpl(0);
    begin_update_at(1);
    _ = uniform_set_current_seconds(15.2);
    try std.testing.expectEqual(@as(i64, 201), finish_update());
    try std.testing.expectApproxEqAbs(@as(f32, 15.2), committed_seconds, 0.001);
    try std.testing.expect(!uniform_seconds_set);
}

test "repeated initial clock input does not stop lifecycle time" {
    resetForTest();
    _ = uniform_set_current_seconds(14.0);
    _ = renderImpl(0);
    begin_update_at(201);
    _ = uniform_set_current_seconds(14.0);
    try std.testing.expectEqual(@as(i64, 401), finish_update());
    try std.testing.expectApproxEqAbs(@as(f32, 14.2), committed_seconds, 0.001);
}

test "horizontal drag tilts and release schedules spring frames" {
    resetForTest();
    _ = renderImpl(0);
    begin_update_at(1);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(1, CX, CY));
    try std.testing.expectEqual(@as(i64, 201), finish_update());
    begin_update_at(2);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(1, CX + 80, CY));
    _ = finish_update();
    try std.testing.expect(tilt_angle > 0.3);
    begin_update_at(3);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(0, CX + 80, CY));
    try std.testing.expectEqual(@as(i64, 17), finish_update());
    begin_update_at(17);
    try std.testing.expectEqual(@as(i64, 33), finish_update());
    try std.testing.expect(tilt_velocity > 0.0 and tilt_velocity < 2.0);
}

fn resetForTest() void {
    phase = .initializing;
    begun_at_ms = 0;
    committed_at_ms = 0;
    clock_seconds = 0.0;
    committed_seconds = 0.0;
    last_host_seconds = 0.0;
    host_seconds_seen = false;
    tilt_angle = 0;
    tilt_velocity = 0;
    tilt_dragging = false;
    tilt_drag_start_x = 0;
    tilt_drag_start_angle = 0;
    tilt_last_x = 0;
    tilt_last_event_at_ms = 0;
    render_tilt_scale_x = 1;
    render_tilt_inverse_x = 1;
    render_tilt_sine = 0;
    render_layer_offset_x = 0;
    static_cached = false;
    resetUniform();
}
