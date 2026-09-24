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

const C_DIAL: Color = .{ 0xD9, 0xDE, 0xE1, 0xFF };
const C_INK: Color = .{ 0x08, 0x27, 0x45, 0xFF };
const C_TICK: Color = .{ 0x16, 0x3A, 0x5B, 0xFF };
const C_ACCENT: Color = .{ 0x00, 0x72, 0xAD, 0xFF };
const C_ACCENT_DARK: Color = .{ 0x00, 0x38, 0x68, 0xFF };
const C_SHADOW: Color = .{ 0x0A, 0x1D, 0x2D, 0x4A };
const CHROME_GRADIENT = makeChromeGradient();

var output_buf: [HDR_OUTPUT_BYTES]u8 align(16) = undefined;

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
        const hdr_rgb = expandHighlight(r, g, b, a);
        const destination_index = ktx_hdr.HEADER_SIZE + pixel_index * 16;
        writeF32(output, destination_index, hdr_rgb[0]);
        writeF32(output, destination_index + 4, hdr_rgb[1]);
        writeF32(output, destination_index + 8, hdr_rgb[2]);
        writeF32(output, destination_index + 12, a);
    }
    return ktx_hdr.writeHeader(output, RENDER_W, RENDER_H) orelse @trap();
}

fn expandHighlight(r: f32, g: f32, b: f32, alpha: f32) [3]f32 {
    if (alpha <= 0.0) return .{ 0.0, 0.0, 0.0 };

    // Raise neutral silver reflections above diffuse white. Saturated blue
    // receives a smaller lift so the hand catches an HDR display without
    // changing the authored hue on SDR fallback paths.
    const luma = r * 0.22897 + g * 0.69174 + b * 0.07929;
    const neutral = 1.0 - std.math.clamp((@max(r, @max(g, b)) - @min(r, @min(g, b))) * 4.0, 0.0, 1.0);
    const reflection = std.math.clamp((luma - 0.68) / 0.32, 0.0, 1.0) * neutral * alpha;
    const reflection_scale = 1.0 + 1.5 * reflection;
    const blue_lift = std.math.clamp(b - r - 0.12, 0.0, 1.0) * alpha;
    return .{
        r * reflection_scale,
        g * reflection_scale + blue_lift * 0.18,
        b * reflection_scale + blue_lift * 1.35,
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
    drawStaticDial();
    drawHand(seconds);
    drawGlassReflection();
}

fn drawStaticDial() void {
    drawBackground();
    drawCaseAndDial();
    drawDialGlow();
    drawBezelReflection();
    drawChapterRing();
    drawLabels();
}

fn drawCaseAndDial() void {
    // The rear case and raised bezel use the same continuous chrome profile
    // at different depths. Their offset reveals a rounded sidewall under yaw
    // instead of exposing the edges of stacked flat-color discs.
    drawMetalAnnulus(scale(143), scale(164), scaleF(1));
    drawMetalAnnulus(scale(143), scale(160), scaleF(7));
    render_layer_offset_x = 0;
    fillCircle(CX, CY, scale(144), C_DIAL);
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
            blendPixelCoverage(x, y, chromeGradient(radial), coverage);
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
        blendPixelCoverage(x, y, chromeGradient(radial), coverage);
    }
}

fn chromeGradient(radial: f32) Color {
    const gradient_index: usize = @intFromFloat(@round(std.math.clamp(radial, 0.0, 1.0) * 63.0));
    return CHROME_GRADIENT[gradient_index];
}

fn makeChromeGradient() [64]Color {
    var gradient: [64]Color = undefined;
    for (&gradient, 0..) |*color, index| {
        color.* = chromeBaseColor(@as(f32, @floatFromInt(index)) / 63.0);
    }
    return gradient;
}

fn chromeBaseColor(radial: f32) Color {
    const crest: f32 = 0.44;
    if (radial < crest) {
        return mixColor(
            .{ 0x48, 0x58, 0x64, 0xFF },
            .{ 0xF4, 0xF8, 0xFA, 0xFF },
            smoothStep(radial / crest),
        );
    }
    return mixColor(
        .{ 0xF4, 0xF8, 0xFA, 0xFF },
        .{ 0x58, 0x68, 0x72, 0xFF },
        smoothStep((radial - crest) / (1.0 - crest)),
    );
}

fn smoothStep(value: f32) f32 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

fn mixColor(a: Color, b: Color, amount: f32) Color {
    var mixed: Color = undefined;
    var channel: usize = 0;
    while (channel < 4) : (channel += 1) {
        mixed[channel] = @intFromFloat(@round(
            @as(f32, @floatFromInt(a[channel])) +
                (@as(f32, @floatFromInt(b[channel])) - @as(f32, @floatFromInt(a[channel]))) * amount,
        ));
    }
    return mixed;
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
                blendPixelCoverage(x, y, .{ 0xF1, 0xF8, 0xFC, 0x82 }, broad);
            }
            const sharp = std.math.clamp(1.0 - @abs(near - 0.64) / 0.055, 0.0, 1.0) * tilt_strength;
            if (sharp > 0.0) {
                blendPixelCoverage(x, y, .{ 0xFF, 0xFF, 0xFF, 0xD0 }, sharp);
            }
            const shade = std.math.clamp(1.0 - @abs(near + 0.48) / 0.42, 0.0, 1.0) * tilt_strength;
            if (shade > 0.0) {
                blendPixelCoverage(x, y, .{ 0x0C, 0x2A, 0x40, 0x58 }, shade);
            }
        }
    }
}

fn drawChapterRing() void {
    drawRing(CX, CY, scale(140), scale(1), C_INK);
    drawRing(CX, CY, scale(117), scale(1), .{ 0x08, 0x27, 0x45, 0x98 });

    var tick: u32 = 0;
    while (tick < 300) : (tick += 1) {
        const second_tick = tick % 5 == 0;
        const major = tick % 25 == 0;
        const cardinal = tick % 75 == 0;
        const outer_radius: f32 = scaleF(136);
        const inner_radius: f32 = if (cardinal) scaleF(119) else if (major) scaleF(123) else if (second_tick) scaleF(129) else scaleF(133);
        const angle = @as(f32, @floatFromInt(tick)) * std.math.tau / 300.0;
        const x0 = CX + @as(i32, @intFromFloat(@round(std.math.sin(angle) * inner_radius)));
        const y0 = CY - @as(i32, @intFromFloat(@round(std.math.cos(angle) * inner_radius)));
        const x1 = CX + @as(i32, @intFromFloat(@round(std.math.sin(angle) * outer_radius)));
        const y1 = CY - @as(i32, @intFromFloat(@round(std.math.cos(angle) * outer_radius)));
        drawLine(
            x0,
            y0,
            x1,
            y1,
            if (cardinal) scale(3) else if (major) scale(2) else scale(1),
            if (cardinal) C_INK else if (second_tick) C_TICK else .{ 0x16, 0x3A, 0x5B, 0x8C },
        );
    }
}

fn drawLabels() void {
    drawCenteredText("60", CX, CY - scale(105), C_INK);
    drawCenteredText("15", CX + scale(104), CY, C_INK);
    drawCenteredText("30", CX, CY + scale(105), C_INK);
    drawCenteredText("45", CX - scale(104), CY, C_INK);

    drawRing(CX, CY, scale(92), scale(1), .{ 0x4B, 0x62, 0x75, 0x66 });
    drawRing(CX, CY, scale(6), scale(1), C_ACCENT_DARK);
}

fn drawHand(seconds: f32) void {
    defer render_layer_offset_x = 0;
    const hand_angle = seconds * std.math.tau / 60.0;
    const hand_x = CX + @as(i32, @intFromFloat(@round(std.math.sin(hand_angle) * scaleF(114))));
    const hand_y = CY - @as(i32, @intFromFloat(@round(std.math.cos(hand_angle) * scaleF(114))));
    const tail_x = CX - @as(i32, @intFromFloat(@round(std.math.sin(hand_angle) * scaleF(27))));
    const tail_y = CY + @as(i32, @intFromFloat(@round(std.math.cos(hand_angle) * scaleF(27))));
    // Separate the shadow, hand, and cap into shallow depth planes. Yaw moves
    // each plane by a different amount, which gives the hand parallax without
    // allocating or compositing an intermediate image.
    setRenderLayerDepth(scaleF(1));
    drawLine(tail_x + scale(3), tail_y + scale(4), hand_x + scale(3), hand_y + scale(4), scale(5), C_SHADOW);
    setRenderLayerDepth(scaleF(5));
    drawLine(tail_x, tail_y, hand_x, hand_y, scale(4), C_ACCENT_DARK);
    setRenderLayerDepth(scaleF(7));
    drawLine(CX, CY, hand_x, hand_y, scale(2), C_ACCENT);
    setRenderLayerDepth(scaleF(6));
    fillCircle(CX, CY, scale(8), C_ACCENT_DARK);
    setRenderLayerDepth(scaleF(9));
    fillCircle(CX, CY, scale(4), .{ 0xB9, 0xD3, 0xE2, 0xFF });
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
            if (wash > 0.0) blendPixelCoverage(x, y, .{ 0xF4, 0xFA, 0xFF, 0x2A }, wash);

            const broad = std.math.clamp((scaleF(27) - curve_distance) / scaleF(20), 0.0, 1.0) * end_fade;
            if (broad > 0.0) blendPixelCoverage(x, y, .{ 0xF7, 0xFB, 0xFF, 0x34 }, broad);

            const sharp = std.math.clamp(1.0 - curve_distance / scaleF(2), 0.0, 1.0) * end_fade;
            if (sharp > 0.0) blendPixelCoverage(x, y, .{ 0xFF, 0xFF, 0xFF, 0xA8 }, sharp);

            const echo_distance = @abs(across - (curve + scaleF(21)));
            const echo = std.math.clamp(1.0 - echo_distance / scaleF(4), 0.0, 1.0) * end_fade;
            if (echo > 0.0) blendPixelCoverage(x, y, .{ 0xE8, 0xF4, 0xFF, 0x3C }, echo);
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
            if (edge > 0.0) blendPixelCoverage(x, y, .{ 0xF7, 0xFC, 0xFF, 0x82 }, edge);

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
            if (wash > 0.0) blendPixelCoverage(x, y, .{ 0xF4, 0xFA, 0xFF, 0x2A }, wash);

            const broad = std.math.clamp((scaleF(27) - curve_distance) / scaleF(20), 0.0, 1.0) * end_fade;
            if (broad > 0.0) blendPixelCoverage(x, y, .{ 0xF7, 0xFB, 0xFF, 0x34 }, broad);
            const sharp = std.math.clamp(1.0 - curve_distance / scaleF(2), 0.0, 1.0) * end_fade;
            if (sharp > 0.0) blendPixelCoverage(x, y, .{ 0xFF, 0xFF, 0xFF, 0xA8 }, sharp);
            const echo_distance = @abs(across - (curve + scaleF(21)));
            const echo = std.math.clamp(1.0 - echo_distance / scaleF(4), 0.0, 1.0) * end_fade;
            if (echo > 0.0) blendPixelCoverage(x, y, .{ 0xE8, 0xF4, 0xFF, 0x3C }, echo);
        }
    }
}

fn drawBackground() void {
    @memset(pixels(), 0);
}

fn drawDialGlow() void {
    if (isTilted()) {
        drawTiltedDialGlow();
        return;
    }
    var y: i32 = CY - scale(143);
    while (y <= CY + scale(143)) : (y += 1) {
        var x: i32 = CX - scale(143);
        while (x <= CX + scale(143)) : (x += 1) {
            const dx = x - CX;
            const dy = y - CY;
            if (dx * dx + dy * dy > scale(143) * scale(143)) continue;
            const light = @max(0, 12 - @divTrunc(@abs(dx + dy), @as(u32, @intCast(scale(18)))));
            if (light > 0) blendPixel(x, y, .{ 0xFF, 0xFF, 0xFF, @intCast(light) });

            // Fine deterministic grain gives the silver dial a blasted finish.
            const grain = @mod(x * 37 + y * 19, 17);
            if (grain == 0) {
                blendPixel(x, y, .{ 0xFF, 0xFF, 0xFF, 0x15 });
            } else if (grain == 1) {
                blendPixel(x, y, .{ 0x3D, 0x52, 0x62, 0x0C });
            }

            // Cut the concentric finish into the same dial pass. Computing one
            // distance per inner-dial pixel is cheaper than scanning the dial
            // again for every ring.
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared >= scale(19) * scale(19) and distance_squared <= scale(93) * scale(93)) {
                const distance = std.math.sqrt(@as(f32, @floatFromInt(distance_squared)));
                const ring_index = @round((distance - scaleF(20)) / scaleF(4));
                const ring_radius = scaleF(20) + ring_index * scaleF(4) - 0.5;
                const coverage = std.math.clamp(1.0 - @abs(distance - ring_radius), 0.0, 1.0);
                blendPixelCoverage(x, y, .{ 0x3D, 0x52, 0x62, 0x12 }, coverage);
            }
        }
    }
}

fn drawTiltedDialGlow() void {
    const radius = scale(143);
    const radius_f: f32 = @floatFromInt(radius);
    const min_x = projectedFloor(CX - radius) - 1;
    const max_x = projectedCeil(CX + radius) + 1;
    const tilt_strength = std.math.clamp(@abs(render_tilt_sine) * 3.0, 0.0, 1.0);
    const direction = std.math.sign(render_tilt_sine);
    var y: i32 = CY - radius;
    while (y <= CY + radius) : (y += 1) {
        const local_y = y - CY;
        const local_y_f: f32 = @floatFromInt(local_y);
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const local_x_f = inverseProjectedX(@as(f32, @floatFromInt(x)) + 0.5) - @as(f32, @floatFromInt(CX));
            const distance_squared = local_x_f * local_x_f + local_y_f * local_y_f;
            if (distance_squared > radius_f * radius_f) continue;
            const local_x: i32 = @intFromFloat(@floor(local_x_f));
            const light: i32 = @max(0, 12 - @as(i32, @intFromFloat(@floor(@abs(local_x_f + local_y_f) / scaleF(18)))));
            if (light > 0) blendPixel(x, y, .{ 0xFF, 0xFF, 0xFF, @intCast(light) });

            const grain = @mod((local_x + CX) * 37 + y * 19, 17);
            if (grain == 0) {
                blendPixel(x, y, .{ 0xFF, 0xFF, 0xFF, 0x15 });
            } else if (grain == 1) {
                blendPixel(x, y, .{ 0x3D, 0x52, 0x62, 0x0C });
            }

            if (distance_squared >= scaleF(19) * scaleF(19) and distance_squared <= scaleF(93) * scaleF(93)) {
                const distance = std.math.sqrt(distance_squared);
                const ring_index = @round((distance - scaleF(20)) / scaleF(4));
                const ring_radius = scaleF(20) + ring_index * scaleF(4) - 0.5;
                const groove_offset = distance - ring_radius;
                const coverage = std.math.clamp(1.0 - @abs(groove_offset), 0.0, 1.0);
                if (coverage <= 0.0) continue;
                blendPixelCoverage(x, y, .{ 0x3D, 0x52, 0x62, 0x12 }, coverage);

                // Azurage is a cut circular texture, not printed rings. Let
                // opposite slopes of each groove catch and lose light as the
                // dial yaws. The response also changes around the circle
                // because the groove normal faces the light differently.
                const incidence = local_x_f / distance * direction;
                const lit_slope = std.math.clamp(0.55 + groove_offset * direction, 0.0, 1.0);
                const broad = std.math.clamp(1.0 - @abs(incidence - 0.48) / 0.48, 0.0, 1.0) *
                    coverage * lit_slope * tilt_strength;
                if (broad > 0.0) {
                    blendPixelCoverage(x, y, .{ 0xF5, 0xFA, 0xFD, 0x4A }, broad);
                }
                const sharp = std.math.clamp(1.0 - @abs(incidence - 0.62) / 0.10, 0.0, 1.0) *
                    coverage * lit_slope * tilt_strength;
                if (sharp > 0.0) {
                    blendPixelCoverage(x, y, .{ 0xFF, 0xFF, 0xFF, 0x78 }, sharp);
                }
                const shade = std.math.clamp(1.0 - @abs(incidence + 0.46) / 0.42, 0.0, 1.0) *
                    coverage * (1.0 - lit_slope * 0.5) * tilt_strength;
                if (shade > 0.0) {
                    blendPixelCoverage(x, y, .{ 0x20, 0x3E, 0x54, 0x28 }, shade);
                }
            }
        }
    }
}

fn scale(value: i32) i32 {
    return value * DRAW_SCALE;
}

fn scaleF(value: comptime_int) f32 {
    return @floatFromInt(value * DRAW_SCALE);
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

fn drawLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, thickness: i32, color: Color) void {
    const projected_x0: f32 = if (isTilted()) projectedX(@floatFromInt(x0_in)) else @floatFromInt(x0_in);
    const projected_x1: f32 = if (isTilted()) projectedX(@floatFromInt(x1)) else @floatFromInt(x1);
    const ax = projected_x0;
    const ay: f32 = @floatFromInt(y0_in);
    const vx: f32 = projected_x1 - projected_x0;
    const vy: f32 = @floatFromInt(y1 - y0_in);
    const length_squared = vx * vx + vy * vy;
    const local_vx: f32 = @floatFromInt(x1 - x0_in);
    const local_vy: f32 = @floatFromInt(y1 - y0_in);
    const local_length = std.math.sqrt(local_vx * local_vx + local_vy * local_vy);
    const normal_scale = if (!isTilted() or local_length == 0)
        1.0
    else
        std.math.sqrt((local_vy / local_length * render_tilt_scale_x) * (local_vy / local_length * render_tilt_scale_x) +
            (local_vx / local_length) * (local_vx / local_length));
    const half_width = @as(f32, @floatFromInt(@max(1, thickness))) * 0.5 * normal_scale;
    const padding = @as(i32, @intFromFloat(@ceil(half_width))) + 1;

    const x0_screen: i32 = @intFromFloat(@floor(projected_x0));
    const x1_screen: i32 = @intFromFloat(@floor(projected_x1));

    var y = @min(y0_in, y1) - padding;
    while (y <= @max(y0_in, y1) + padding) : (y += 1) {
        var x = @min(x0_screen, x1_screen) - padding;
        while (x <= @max(x0_screen, x1_screen) + padding) : (x += 1) {
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
    const index = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    @memcpy(pixels()[index .. index + 4], &color);
}

fn blendPixel(x: i32, y: i32, source: Color) void {
    if (source[3] == 0 or x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    if (source[3] == 255) {
        setPixel(x, y, source);
        return;
    }
    const index = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const source_alpha: u32 = source[3];
    const destination_alpha: u32 = pixels()[index + 3];
    if (destination_alpha == 0) {
        setPixel(x, y, source);
        return;
    }
    const inverse: u32 = 255 - source_alpha;
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
        pixels()[index + channel] = @intCast(@divTrunc(source_term + destination_term + output_alpha / 2, output_alpha));
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
    resetUniform();
}
