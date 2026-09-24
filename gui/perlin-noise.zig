const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 480;
const RENDER_H: usize = 320;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_SHIFT_L: i32 = 0xFFE1;
const XK_SHIFT_R: i32 = 0xFFE2;

const FLAG_KEY_DOWN: i32 = 1 << 0;

const KEY_UP: u8 = 1 << 0;
const KEY_DOWN: u8 = 1 << 1;
const KEY_LEFT: u8 = 1 << 2;
const KEY_RIGHT: u8 = 1 << 3;

const MOVE_INTERVAL_MS: i64 = 16;
const PAN_PIXELS_PER_STEP: f64 = 4.0;
const SHIFT_SPEED_MULTIPLIER: f64 = 3.0;
const BASE_SCALE: f64 = 0.020;
const ZOOM_IN_FACTOR: f64 = 0.80;
const ZOOM_OUT_FACTOR: f64 = 1.25;
const MIN_ZOOM: f64 = 0.10;
const MAX_ZOOM: f64 = 8.0;

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;

var needs_redraw: bool = true;
var keys_down: u8 = 0;
var has_last_move: bool = false;
var last_move_ms: i64 = 0;
var shift_down: bool = false;

var camera_x: f64 = 0.0;
var camera_y: f64 = 0.0;
var zoom: f64 = 1.0;
var world_seed: u64 = 0xC8E9_4A77_31BD_5F20;

const Phase = enum { initializing, ready, updating };

var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var next_wake_at_ms: i64 = 0;

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
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    next_wake_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const is_down = (flags & FLAG_KEY_DOWN) != 0;

    if (x11_key == XK_SHIFT_L or x11_key == XK_SHIFT_R) {
        shift_down = is_down;
        return 1;
    }

    // R regenerates with a new seed and recenters view.
    if (is_down and (x11_key == 'r' or x11_key == 'R')) {
        const now_bits: u64 = @bitCast(begun_at_ms);
        world_seed = mix64(world_seed ^ now_bits ^ 0x9E37_79B9_7F4A_7C15);
        camera_x = 0.0;
        camera_y = 0.0;
        zoom = 1.0;
        needs_redraw = true;
        return 1;
    }

    if (is_down and (x11_key == '=' or x11_key == '+')) {
        zoom *= ZOOM_IN_FACTOR;
        if (zoom < MIN_ZOOM) zoom = MIN_ZOOM;
        needs_redraw = true;
        return 1;
    }

    if (is_down and x11_key == '-') {
        zoom *= ZOOM_OUT_FACTOR;
        if (zoom > MAX_ZOOM) zoom = MAX_ZOOM;
        needs_redraw = true;
        return 1;
    }

    const key_bit: u8 = switch (x11_key) {
        XK_UP => KEY_UP,
        XK_DOWN => KEY_DOWN,
        XK_LEFT => KEY_LEFT,
        XK_RIGHT => KEY_RIGHT,
        else => return 0,
    };

    if (is_down) {
        keys_down |= key_bit;
    } else {
        keys_down &= ~key_bit;
    }

    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    return 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    if (!has_last_move) {
        has_last_move = true;
        last_move_ms = begun_at_ms;
    }

    if (keys_down != 0) {
        var elapsed = begun_at_ms - last_move_ms;
        if (elapsed < 0) elapsed = 0;
        const steps = @divFloor(elapsed, MOVE_INTERVAL_MS);
        if (steps > 0) {
            _ = moveCameraSteps(@intCast(steps));
            last_move_ms += steps * MOVE_INTERVAL_MS;
        }
    } else {
        last_move_ms = begun_at_ms;
    }

    setNextWake();
}

fn setNextWake() void {
    next_wake_at_ms = if (keys_down != 0 and last_move_ms <= std.math.maxInt(i64) - MOVE_INTERVAL_MS)
        last_move_ms + MOVE_INTERVAL_MS
    else
        begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    renderPerlin();
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    needs_redraw = false;
    phase = .ready;
    return @intCast(OUTPUT_BYTES);
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
    advanceTransactionTime();
    // Events run after time reaches begun_at_ms and can change whether another
    // movement step is needed.
    setNextWake();
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    phase = .ready;
    return wake;
}

fn moveCameraSteps(steps: u64) bool {
    const up = (keys_down & KEY_UP) != 0;
    const down = (keys_down & KEY_DOWN) != 0;
    const left = (keys_down & KEY_LEFT) != 0;
    const right = (keys_down & KEY_RIGHT) != 0;

    var dx: f64 = 0.0;
    var dy: f64 = 0.0;

    const speed_per_step = if (shift_down) PAN_PIXELS_PER_STEP * SHIFT_SPEED_MULTIPLIER else PAN_PIXELS_PER_STEP;
    const speed = speed_per_step * @as(f64, @floatFromInt(steps));

    if (up and !down) dy -= speed;
    if (down and !up) dy += speed;
    if (left and !right) dx -= speed;
    if (right and !left) dx += speed;

    if (dx == 0.0 and dy == 0.0) return false;

    camera_x += dx;
    camera_y += dy;
    needs_redraw = true;
    return true;
}

fn renderPerlin() void {
    const sample_scale = BASE_SCALE * zoom;
    var fy = camera_y * sample_scale;

    var py: usize = 0;
    while (py < RENDER_H) : (py += 1) {
        var fx = camera_x * sample_scale;
        var px: usize = 0;
        while (px < RENDER_W) : (px += 1) {
            const n = fbm2(fx, fy); // ~[-1, 1]
            const t = clamp01(n * 0.5 + 0.5);
            const c = terrainColor(t);

            const idx = (py * RENDER_W + px) * 4;
            pixel_buf[idx + 0] = c[0];
            pixel_buf[idx + 1] = c[1];
            pixel_buf[idx + 2] = c[2];
            pixel_buf[idx + 3] = 255;
            fx += sample_scale;
        }
        fy += sample_scale;
    }
}

fn clamp01(v: f64) f64 {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

fn terrainColor(t: f64) [3]u8 {
    if (t < 0.33) {
        const k = t / 0.33;
        return .{ lerpU8(8, 22, k), lerpU8(24, 72, k), lerpU8(70, 168, k) };
    }
    if (t < 0.45) {
        const k = (t - 0.33) / 0.12;
        return .{ lerpU8(194, 216, k), lerpU8(176, 195, k), lerpU8(120, 140, k) };
    }
    if (t < 0.80) {
        const k = (t - 0.45) / 0.35;
        return .{ lerpU8(44, 72, k), lerpU8(106, 138, k), lerpU8(48, 80, k) };
    }
    const k = (t - 0.80) / 0.20;
    return .{ lerpU8(132, 244, k), lerpU8(128, 244, k), lerpU8(136, 248, k) };
}

fn lerpU8(a: u8, b: u8, t: f64) u8 {
    const ft = clamp01(t);
    const av = @as(f64, @floatFromInt(a));
    const bv = @as(f64, @floatFromInt(b));
    return @as(u8, @intFromFloat(av + (bv - av) * ft));
}

fn fbm2(x: f64, y: f64) f64 {
    var amp: f64 = 1.0;
    var freq: f64 = 1.0;
    var sum: f64 = 0.0;
    var norm: f64 = 0.0;

    var octave: usize = 0;
    while (octave < 5) : (octave += 1) {
        sum += perlin2(x * freq, y * freq) * amp;
        norm += amp;
        amp *= 0.5;
        freq *= 2.0;
    }

    return sum / norm;
}

fn perlin2(x: f64, y: f64) f64 {
    const x0i: i64 = @intFromFloat(@floor(x));
    const y0i: i64 = @intFromFloat(@floor(y));
    const x1i = x0i + 1;
    const y1i = y0i + 1;

    const xf = x - @as(f64, @floatFromInt(x0i));
    const yf = y - @as(f64, @floatFromInt(y0i));

    const u = fade(xf);
    const v = fade(yf);

    const g00 = gradDot(hash2(x0i, y0i), xf, yf);
    const g10 = gradDot(hash2(x1i, y0i), xf - 1.0, yf);
    const g01 = gradDot(hash2(x0i, y1i), xf, yf - 1.0);
    const g11 = gradDot(hash2(x1i, y1i), xf - 1.0, yf - 1.0);

    const nx0 = lerp(g00, g10, u);
    const nx1 = lerp(g01, g11, u);
    return lerp(nx0, nx1, v);
}

fn fade(t: f64) f64 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

fn gradDot(h: u64, x: f64, y: f64) f64 {
    return switch (h & 7) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        4 => x,
        5 => -x,
        6 => y,
        else => -y,
    };
}

fn hash2(x: i64, y: i64) u64 {
    const ux: u64 = @bitCast(x);
    const uy: u64 = @bitCast(y);
    return mix64(world_seed ^ mix64(ux) ^ mix64(uy ^ 0x9E37_79B9_7F4A_7C15));
}

fn mix64(x: u64) u64 {
    var z = x +% 0x9E37_79B9_7F4A_7C15;
    z ^= z >> 30;
    z *%= 0xBF58_476D_1CE4_E5B9;
    z ^= z >> 27;
    z *%= 0x94D0_49BB_1331_11EB;
    z ^= z >> 31;
    return z;
}

test "perlin deterministic at same seed" {
    world_seed = 0x0123_4567_89AB_CDEF;
    const a = perlin2(12.25, -9.75);
    const b = perlin2(12.25, -9.75);
    try std.testing.expect(a == b);
}

test "camera moves with key state" {
    camera_x = 0.0;
    camera_y = 0.0;
    keys_down = KEY_RIGHT | KEY_DOWN;
    shift_down = false;
    needs_redraw = false;

    const moved = moveCameraSteps(1);
    try std.testing.expect(moved);
    try std.testing.expect(camera_x == PAN_PIXELS_PER_STEP);
    try std.testing.expect(camera_y == PAN_PIXELS_PER_STEP);
    try std.testing.expect(needs_redraw);
}

test "camera moves faster while shift held" {
    camera_x = 0.0;
    camera_y = 0.0;
    keys_down = KEY_RIGHT;
    shift_down = true;
    needs_redraw = false;

    const moved = moveCameraSteps(1);
    try std.testing.expect(moved);
    try std.testing.expect(camera_x == PAN_PIXELS_PER_STEP * SHIFT_SPEED_MULTIPLIER);
    try std.testing.expect(camera_y == 0.0);
}
