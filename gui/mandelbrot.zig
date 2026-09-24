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

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;

var center_x: f64 = -0.5;
var center_y: f64 = 0.0;
var span_x: f64 = 3.0;
const Phase = enum { initializing, ready, updating };

var phase: Phase = .initializing;
var committed_at_ms: i64 = 0;

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
    committed_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;

    const span_y = span_x * @as(f64, @floatFromInt(RENDER_H)) / @as(f64, @floatFromInt(RENDER_W));
    const pan_step_x = span_x * 0.12;
    const pan_step_y = span_y * 0.12;

    switch (x11_key) {
        XK_LEFT => center_x -= pan_step_x,
        XK_RIGHT => center_x += pan_step_x,
        XK_UP => center_y -= pan_step_y,
        XK_DOWN => center_y += pan_step_y,
        // '=' and '+' zoom in.
        '=' => span_x *= 0.80,
        '+' => span_x *= 0.80,
        // '-' zooms out.
        '-' => span_x *= 1.25,
        else => return 0,
    }

    if (span_x < 0.0000003) span_x = 0.0000003;
    if (span_x > 6.0) span_x = 6.0;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((button_mask & BTN_PRIMARY) == 0) return 0;
    if (x_px < 0 or y_px < 0) return 0;
    if (x_px >= @as(i32, @intCast(RENDER_W)) or y_px >= @as(i32, @intCast(RENDER_H))) return 0;

    const fx = @as(f64, @floatFromInt(x_px)) / @as(f64, @floatFromInt(RENDER_W));
    const fy = @as(f64, @floatFromInt(y_px)) / @as(f64, @floatFromInt(RENDER_H));

    const span_y = span_x * @as(f64, @floatFromInt(RENDER_H)) / @as(f64, @floatFromInt(RENDER_W));
    center_x = (center_x - span_x * 0.5) + fx * span_x;
    center_y = (center_y - span_y * 0.5) + fy * span_y;
    return 1;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    renderMandelbrot();
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
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
    phase = .ready;
    return committed_at_ms;
}

fn renderMandelbrot() void {
    const span_y = span_x * @as(f64, @floatFromInt(RENDER_H)) / @as(f64, @floatFromInt(RENDER_W));
    const x0 = center_x - span_x * 0.5;
    const y0 = center_y - span_y * 0.5;
    const step_x = span_x / @as(f64, @floatFromInt(RENDER_W));
    const step_y = span_y / @as(f64, @floatFromInt(RENDER_H));

    const max_iter: i32 = 96;

    var cy = y0;
    var py: usize = 0;
    while (py < RENDER_H) : (py += 1) {
        var cx = x0;
        var px: usize = 0;
        while (px < RENDER_W) : (px += 1) {
            var iter: i32 = max_iter;
            if (!isKnownInterior(cx, cy)) {
                var zx: f64 = 0.0;
                var zy: f64 = 0.0;
                iter = 0;
                while (iter < max_iter) : (iter += 1) {
                    const zx2 = zx * zx;
                    const zy2 = zy * zy;
                    if (zx2 + zy2 > 4.0) break;
                    zy = 2.0 * zx * zy + cy;
                    zx = zx2 - zy2 + cx;
                }
            }

            const idx = (py * RENDER_W + px) * 4;
            if (iter >= max_iter) {
                pixel_buf[idx + 0] = 5;
                pixel_buf[idx + 1] = 6;
                pixel_buf[idx + 2] = 12;
                pixel_buf[idx + 3] = 255;
            } else {
                const c = @as(u8, @intCast(@divFloor(iter * 255, max_iter)));
                pixel_buf[idx + 0] = 20 + @as(u8, @intCast((@as(u16, c) * 2) / 3));
                pixel_buf[idx + 1] = @as(u8, @intCast((@as(u16, c) * 7) / 10));
                pixel_buf[idx + 2] = 120 + @as(u8, @intCast((@as(u16, c) * 5) / 10));
                pixel_buf[idx + 3] = 255;
            }
            cx += step_x;
        }
        cy += step_y;
    }
}

fn isKnownInterior(cx: f64, cy: f64) bool {
    const x = cx - 0.25;
    const y2 = cy * cy;
    const q = x * x + y2;
    if (q * (q + x) <= 0.25 * y2) return true;
    const bulb_x = cx + 1.0;
    return bulb_x * bulb_x + y2 <= 0.0625;
}

test "known Mandelbrot interiors skip iteration" {
    try std.testing.expect(isKnownInterior(0.0, 0.0));
    try std.testing.expect(isKnownInterior(-1.0, 0.0));
    try std.testing.expect(!isKnownInterior(1.0, 1.0));
}
