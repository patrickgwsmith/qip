const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 720;
const RENDER_H: usize = 480;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_RIGHT: i32 = 0xFF53;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;

const COVER: i32 = 190;
const FLOOR_Y: i32 = 282;
const CENTER_X: i32 = @divTrunc(@as(i32, @intCast(RENDER_W)), 2);
const MAX_ALBUMS: usize = 10;

const Color = [4]u8;

const Album = struct {
    title: []const u8,
    artist: []const u8,
    a: Color,
    b: Color,
    c: Color,
    motif: u8,
};

const Point = struct {
    x: i32,
    y: i32,
};

const PointF = struct {
    x: f32,
    y: f32,
};

const Quad = struct {
    tl: Point,
    tr: Point,
    br: Point,
    bl: Point,
};

const Matrix3 = struct {
    m00: f32,
    m01: f32,
    m02: f32,
    m10: f32,
    m11: f32,
    m12: f32,
    m20: f32,
    m21: f32,
    m22: f32,
};

const albums = [_]Album{
    .{ .title = "MIDNIGHT RUN", .artist = "THE ARCADES", .a = .{ 0x13, 0x29, 0x5B, 0xFF }, .b = .{ 0xE7, 0x46, 0x8A, 0xFF }, .c = .{ 0x42, 0xDF, 0xE7, 0xFF }, .motif = 0 },
    .{ .title = "GLASS HOUSES", .artist = "NORTH PIER", .a = .{ 0xD9, 0xE8, 0xF0, 0xFF }, .b = .{ 0x1E, 0x73, 0x8F, 0xFF }, .c = .{ 0x0F, 0x21, 0x2C, 0xFF }, .motif = 1 },
    .{ .title = "LOW SUN", .artist = "JUNE ATLAS", .a = .{ 0xF1, 0xB1, 0x49, 0xFF }, .b = .{ 0xD8, 0x42, 0x3B, 0xFF }, .c = .{ 0x39, 0x20, 0x45, 0xFF }, .motif = 2 },
    .{ .title = "TAPE ECHO", .artist = "MONO FIELD", .a = .{ 0x21, 0x24, 0x26, 0xFF }, .b = .{ 0xDB, 0xD2, 0xB4, 0xFF }, .c = .{ 0x9B, 0xE2, 0x80, 0xFF }, .motif = 3 },
    .{ .title = "OCEAN STATIC", .artist = "THE SIGNALS", .a = .{ 0x04, 0x3B, 0x53, 0xFF }, .b = .{ 0x11, 0xA6, 0xC7, 0xFF }, .c = .{ 0xEE, 0xF6, 0xFF, 0xFF }, .motif = 4 },
    .{ .title = "RED LINE", .artist = "CITY INDEX", .a = .{ 0x24, 0x11, 0x16, 0xFF }, .b = .{ 0xB9, 0x1F, 0x36, 0xFF }, .c = .{ 0xF6, 0xE5, 0xB7, 0xFF }, .motif = 5 },
    .{ .title = "SOFT CIRCUITS", .artist = "ADA VIEW", .a = .{ 0x61, 0x78, 0x8A, 0xFF }, .b = .{ 0xE7, 0xE0, 0xC4, 0xFF }, .c = .{ 0x1C, 0x32, 0x45, 0xFF }, .motif = 6 },
    .{ .title = "LATE CHECKOUT", .artist = "HOTEL MIRROR", .a = .{ 0x12, 0x16, 0x1C, 0xFF }, .b = .{ 0xC4, 0xA0, 0x5E, 0xFF }, .c = .{ 0x79, 0xD3, 0xFF, 0xFF }, .motif = 7 },
    .{ .title = "BLUEPRINTS", .artist = "PAPER TIGER", .a = .{ 0xF8, 0xF6, 0xED, 0xFF }, .b = .{ 0x2D, 0x5D, 0x8F, 0xFF }, .c = .{ 0xE2, 0x51, 0x43, 0xFF }, .motif = 8 },
    .{ .title = "AFTER HOURS", .artist = "BLACK RAIN", .a = .{ 0x08, 0x08, 0x0D, 0xFF }, .b = .{ 0x5E, 0x44, 0x8F, 0xFF }, .c = .{ 0xF1, 0x5A, 0x7B, 0xFF }, .motif = 9 },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var needs_redraw = true;
var selected_q8: i32 = 3 * 256;
var target_q8: i32 = 3 * 256;
var velocity_q8: i32 = 0;
var primary_down = false;
var press_x: i32 = 0;
var last_x: i32 = 0;
var last_dx: i32 = 0;
var press_selected_q8: i32 = 0;
var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var pulse: i32 = 0;

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
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    switch (x11_key) {
        XK_LEFT, 'a', 'A' => stepSelection(-1),
        XK_RIGHT, 'd', 'D' => stepSelection(1),
        XK_HOME => setSelection(0),
        XK_END => setSelection(@as(i32, @intCast(albums.len)) - 1),
        else => return 0,
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    pointer_x = x_px;
    pointer_y = y_px;
    const down = (button_mask & BTN_PRIMARY) != 0;

    if (down and !primary_down) {
        press_x = x_px;
        last_x = x_px;
        last_dx = 0;
        press_selected_q8 = selected_q8;
        target_q8 = selected_q8;
        velocity_q8 = 0;
    } else if (down and primary_down) {
        const dx = x_px - press_x;
        last_dx = x_px - last_x;
        last_x = x_px;
        selected_q8 = clampSelected(press_selected_q8 - @divTrunc(dx * 256, 129), true);
        target_q8 = selected_q8;
        velocity_q8 = @divTrunc((-last_dx) * 256, 129);
        needs_redraw = true;
    } else if (!down and primary_down) {
        if (absI32(x_px - press_x) < 5) {
            const hit = hitAlbum(x_px, y_px);
            if (hit >= 0) setSelection(hit);
        }
        needs_redraw = true;
    }
    primary_down = down;
    return if (needs_redraw) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    pulse = @mod(pulse + 1, 4096);
    var active = primary_down;
    if (!primary_down) {
        if (velocity_q8 != 0) {
            selected_q8 = clampSelected(selected_q8 + velocity_q8, true);
            velocity_q8 = @divTrunc(velocity_q8 * 88, 100);
            if (absI32(velocity_q8) < 3) {
                velocity_q8 = 0;
                target_q8 = nearestIndex() * 256;
            }
            needs_redraw = true;
            active = true;
        } else {
            const delta = target_q8 - selected_q8;
            if (absI32(delta) > 1) {
                var step = @divTrunc(delta, 6);
                if (step == 0) step = if (delta < 0) -1 else 1;
                selected_q8 += step;
                needs_redraw = true;
                active = true;
            } else {
                selected_q8 = target_q8;
            }
        }
    }
    next_wake_at_ms = if (active and begun_at_ms <= std.math.maxInt(i64) - 16)
        begun_at_ms + 16
    else
        begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
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
    const active = primary_down or velocity_q8 != 0 or absI32(target_q8 - selected_q8) > 1;
    next_wake_at_ms = if (active and begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    phase = .ready;
    return wake;
}

fn stepSelection(delta: i32) void {
    setSelection(nearestIndex() + delta);
}

fn setSelection(index: i32) void {
    target_q8 = clampSelected(index * 256, false);
    velocity_q8 = 0;
}

fn nearestIndex() i32 {
    const rounded = @divTrunc(selected_q8 + 128, 256);
    return clampI32(rounded, 0, @as(i32, @intCast(albums.len)) - 1);
}

fn targetIndex() i32 {
    const rounded = @divTrunc(target_q8 + 128, 256);
    return clampI32(rounded, 0, @as(i32, @intCast(albums.len)) - 1);
}

fn clampSelected(value: i32, overscroll: bool) i32 {
    const max_q8 = (@as(i32, @intCast(albums.len)) - 1) * 256;
    if (overscroll) return clampI32(value, -120, max_q8 + 120);
    return clampI32(value, 0, max_q8);
}

fn hitAlbum(x: i32, y: i32) i32 {
    var best: i32 = -1;
    var best_abs: i32 = 100000;
    var i: i32 = 0;
    while (i < @as(i32, @intCast(albums.len))) : (i += 1) {
        const d_q8 = i * 256 - selected_q8;
        if (absI32(d_q8) > 4 * 256) continue;
        const q = coverQuad(i, false);
        const min_x = min4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
        const max_x = max4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
        const min_y = min4(q.tl.y, q.tr.y, q.br.y, q.bl.y);
        const max_y = max4(q.tl.y, q.tr.y, q.br.y, q.bl.y);
        if (x >= min_x and x <= max_x and y >= min_y and y <= max_y) {
            const ad = absI32(d_q8);
            if (ad < best_abs) {
                best_abs = ad;
                best = i;
            }
        }
    }
    return best;
}

fn drawFrame() void {
    drawBackground();
    drawReflections();
    drawAlbums();
    drawChrome();
}

fn drawBackground() void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        const t = @divTrunc(y * 255, @as(i32, @intCast(RENDER_H - 1)));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 1) {
            const cx = absI32(x - CENTER_X);
            const vignette = clampI32(@divTrunc(cx * 85, CENTER_X) + @divTrunc(absI32(y - 198) * 34, 240), 0, 105);
            const glow = clampI32(78 - @divTrunc(cx, 6) - @divTrunc(absI32(y - 156), 5), 0, 78);
            const r = clampU8(6 + @divTrunc(t, 18) + @divTrunc(glow, 5) - @divTrunc(vignette, 6));
            const g = clampU8(7 + @divTrunc(t, 20) + @divTrunc(glow, 4) - @divTrunc(vignette, 6));
            const b = clampU8(10 + @divTrunc(t, 12) + @divTrunc(glow, 2) - @divTrunc(vignette, 4));
            setPixel(x, y, .{ r, g, b, 0xFF });
        }
    }

    var fy = FLOOR_Y;
    while (fy < @as(i32, @intCast(RENDER_H))) : (fy += 1) {
        const fade = clampI32(170 - (fy - FLOOR_Y) * 2, 0, 170);
        blendRect(0, fy, @as(i32, @intCast(RENDER_W)), 1, .{ 0x00, 0x00, 0x00, @as(u8, @intCast(fade)) });
    }
    blendRect(0, FLOOR_Y - 1, @as(i32, @intCast(RENDER_W)), 1, .{ 0xC6, 0xD6, 0xEA, 0x30 });
    drawFloorShine();
}

fn drawFloorShine() void {
    var y: i32 = FLOOR_Y;
    while (y < FLOOR_Y + 64) : (y += 1) {
        const row_alpha = clampI32(42 - (y - FLOOR_Y), 0, 42);
        var x: i32 = 63;
        while (x < @as(i32, @intCast(RENDER_W)) - 63) : (x += 1) {
            const dx = absI32(x - CENTER_X);
            const a = clampI32(row_alpha - @divTrunc(dx, 15), 0, 42);
            if (a > 0) blendPixel(x, y, .{ 0xD8, 0xE9, 0xFF, @as(u8, @intCast(a)) });
        }
    }
}

fn drawReflections() void {
    var pass: i32 = 5;
    while (pass >= -5) : (pass -= 1) {
        const idx = nearestIndex() + pass;
        if (idx < 0 or idx >= @as(i32, @intCast(albums.len))) continue;
        drawAlbum(idx, true);
    }
}

fn drawAlbums() void {
    var pass: i32 = 5;
    while (pass >= 1) : (pass -= 1) {
        const left = nearestIndex() - pass;
        if (left >= 0) drawAlbum(left, false);
        const right = nearestIndex() + pass;
        if (right < @as(i32, @intCast(albums.len))) drawAlbum(right, false);
    }
    const center = nearestIndex();
    if (center >= 0 and center < @as(i32, @intCast(albums.len))) drawAlbum(center, false);
}

fn drawAlbum(index: i32, reflection: bool) void {
    const q = coverQuad(index, reflection);
    const delta_q8 = index * 256 - selected_q8;
    const dist = absI32(delta_q8);
    const side_dark = clampI32(@divTrunc(dist, 8), 0, 90);
    const alpha: u8 = if (reflection)
        @as(u8, @intCast(clampI32(88 - @divTrunc(dist, 12), 14, 84)))
    else
        0xFF;
    if (!reflection) {
        drawSoftShadow(q);
    }
    drawTexturedQuad(q, @as(usize, @intCast(index)), side_dark, alpha, reflection);
    if (!reflection) {
        drawQuadEdge(q, if (dist < 90) .{ 0xF4, 0xF8, 0xFF, 0xE0 } else .{ 0xB8, 0xC6, 0xD4, 0x8F });
        drawSpecular(q, dist);
    }
}

fn coverQuad(index: i32, reflection: bool) Quad {
    const d_q8 = index * 256 - selected_q8;
    const rel = @as(f32, @floatFromInt(d_q8)) / 256.0;
    const ad = absF32(rel);
    const sign: f32 = if (rel < 0) -1.0 else 1.0;
    const turn = smoothstep(0.18, 0.82, ad);
    const yaw = sign * (turn * 1.08 + (1.0 - turn) * rel * 0.18);
    const cos_y = @cos(yaw);
    const sin_y = @sin(yaw);
    const center_push = rel * 60.0;
    const side_push = sign * (126.0 + (ad - 1.0) * 86.0);
    const x_push = lerpF32(center_push, side_push, turn);
    const x_world = clampF32(x_push, -500.0, 500.0);
    const z_world = clampF32(ad * 51.0, 0.0, 270.0);
    const y_center = 171.0 + clampF32(ad * 6.0, 0.0, 36.0);
    const half = @as(f32, @floatFromInt(COVER)) * (1.0 - clampF32(ad * 0.025, 0.0, 0.12)) * 0.5;
    const q = Quad{
        .tl = projectCoverCorner(-half, -half, x_world, y_center, z_world, cos_y, sin_y),
        .tr = projectCoverCorner(half, -half, x_world, y_center, z_world, cos_y, sin_y),
        .br = projectCoverCorner(half, half, x_world, y_center, z_world, cos_y, sin_y),
        .bl = projectCoverCorner(-half, half, x_world, y_center, z_world, cos_y, sin_y),
    };
    return if (reflection) reflectQuad(q) else q;
}

fn projectCoverCorner(local_x: f32, local_y: f32, x_world: f32, y_center: f32, z_world: f32, cos_y: f32, sin_y: f32) Point {
    const rotated_x = local_x * cos_y;
    const rotated_z = -local_x * sin_y;
    const z = z_world + rotated_z;
    const perspective = 780.0 / (780.0 + z);
    return .{
        .x = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(CENTER_X)) + (x_world + rotated_x) * perspective))),
        .y = @as(i32, @intFromFloat(@round(y_center + local_y * perspective))),
    };
}

fn reflectQuad(q: Quad) Quad {
    const gap = 4;
    return .{
        .tl = .{ .x = q.bl.x, .y = FLOOR_Y + gap },
        .tr = .{ .x = q.br.x, .y = FLOOR_Y + gap },
        .br = .{ .x = q.tr.x, .y = FLOOR_Y + gap + @divTrunc((q.br.y - q.tr.y) * 3, 4) },
        .bl = .{ .x = q.tl.x, .y = FLOOR_Y + gap + @divTrunc((q.bl.y - q.tl.y) * 3, 4) },
    };
}

fn drawTexturedQuad(q: Quad, album_idx: usize, darken: i32, alpha: u8, reflection: bool) void {
    const inv = inverseHomography(q) orelse return;
    const min_x = clampI32(min4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, @as(i32, @intCast(RENDER_W)) - 1);
    const max_x = clampI32(max4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, @as(i32, @intCast(RENDER_W)) - 1);
    const min_y = clampI32(min4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, @as(i32, @intCast(RENDER_H)) - 1);
    const max_y = clampI32(max4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, @as(i32, @intCast(RENDER_H)) - 1);
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const uv = mapPoint(inv, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5) orelse continue;
            if (uv.x < -0.002 or uv.x > 1.002 or uv.y < -0.002 or uv.y > 1.002) continue;
            const u = clampI32(@as(i32, @intFromFloat(@round(clampF32(uv.x, 0.0, 1.0) * 255.0))), 0, 255);
            const v = clampI32(@as(i32, @intFromFloat(@round(clampF32(uv.y, 0.0, 1.0) * 255.0))), 0, 255);
            var c = sampleAlbum(albums[album_idx], u, if (reflection) 255 - v else v);
            const shade = darken + @divTrunc(absI32(u - 128), 9);
            c = shadeColor(c, shade);
            if (reflection) {
                const fade = clampI32(@as(i32, alpha) - @divTrunc((y - FLOOR_Y) * 3, 2), 0, @as(i32, alpha));
                c[3] = @as(u8, @intCast(fade));
                c = shadeColor(c, 48);
                blendPixel(x, y, c);
            } else {
                c[3] = alpha;
                blendPixel(x, y, c);
            }
        }
    }
}

fn inverseHomography(q: Quad) ?Matrix3 {
    const x0 = @as(f32, @floatFromInt(q.tl.x));
    const y0 = @as(f32, @floatFromInt(q.tl.y));
    const x1 = @as(f32, @floatFromInt(q.tr.x));
    const y1 = @as(f32, @floatFromInt(q.tr.y));
    const x2 = @as(f32, @floatFromInt(q.br.x));
    const y2 = @as(f32, @floatFromInt(q.br.y));
    const x3 = @as(f32, @floatFromInt(q.bl.x));
    const y3 = @as(f32, @floatFromInt(q.bl.y));

    const dx1 = x1 - x2;
    const dy1 = y1 - y2;
    const dx2 = x3 - x2;
    const dy2 = y3 - y2;
    const dx3 = x0 - x1 + x2 - x3;
    const dy3 = y0 - y1 + y2 - y3;

    var g: f32 = 0.0;
    var h: f32 = 0.0;
    if (absF32(dx3) > 0.0001 or absF32(dy3) > 0.0001) {
        const det = dx1 * dy2 - dx2 * dy1;
        if (absF32(det) < 0.0001) return null;
        g = (dx3 * dy2 - dx2 * dy3) / det;
        h = (dx1 * dy3 - dx3 * dy1) / det;
    }

    const forward = Matrix3{
        .m00 = x1 - x0 + g * x1,
        .m01 = x3 - x0 + h * x3,
        .m02 = x0,
        .m10 = y1 - y0 + g * y1,
        .m11 = y3 - y0 + h * y3,
        .m12 = y0,
        .m20 = g,
        .m21 = h,
        .m22 = 1.0,
    };
    return invertMatrix3(forward);
}

fn invertMatrix3(m: Matrix3) ?Matrix3 {
    const c00 = m.m11 * m.m22 - m.m12 * m.m21;
    const c01 = -(m.m10 * m.m22 - m.m12 * m.m20);
    const c02 = m.m10 * m.m21 - m.m11 * m.m20;
    const c10 = -(m.m01 * m.m22 - m.m02 * m.m21);
    const c11 = m.m00 * m.m22 - m.m02 * m.m20;
    const c12 = -(m.m00 * m.m21 - m.m01 * m.m20);
    const c20 = m.m01 * m.m12 - m.m02 * m.m11;
    const c21 = -(m.m00 * m.m12 - m.m02 * m.m10);
    const c22 = m.m00 * m.m11 - m.m01 * m.m10;
    const det = m.m00 * c00 + m.m01 * c01 + m.m02 * c02;
    if (absF32(det) < 0.0001) return null;
    const inv_det = 1.0 / det;
    return .{
        .m00 = c00 * inv_det,
        .m01 = c10 * inv_det,
        .m02 = c20 * inv_det,
        .m10 = c01 * inv_det,
        .m11 = c11 * inv_det,
        .m12 = c21 * inv_det,
        .m20 = c02 * inv_det,
        .m21 = c12 * inv_det,
        .m22 = c22 * inv_det,
    };
}

fn mapPoint(m: Matrix3, x: f32, y: f32) ?PointF {
    const denom = m.m20 * x + m.m21 * y + m.m22;
    if (absF32(denom) < 0.0001) return null;
    return .{
        .x = (m.m00 * x + m.m01 * y + m.m02) / denom,
        .y = (m.m10 * x + m.m11 * y + m.m12) / denom,
    };
}

fn sampleAlbum(album: Album, u: i32, v: i32) Color {
    var base = mixColor(album.a, album.b, clampI32(@divTrunc((u + v) * 255, 510), 0, 255));
    const grain = ((u * 17 + v * 29 + @as(i32, album.motif) * 37) & 31) - 15;
    base = addColor(base, grain);

    switch (album.motif) {
        0 => {
            if (absI32(u - v) < 9 or absI32((255 - u) - v) < 8) base = mixColor(base, album.c, 180);
            if (circle(u, v, 128, 116, 42)) base = mixColor(base, .{ 0x10, 0x10, 0x18, 0xFF }, 130);
        },
        1 => {
            if (@mod(@divTrunc(u, 28), 2) == 0 or @mod(@divTrunc(v, 25), 2) == 0) base = mixColor(base, album.c, 78);
            if (absI32(u - 132) < 3) base = mixColor(base, .{ 0xFF, 0xFF, 0xFF, 0xFF }, 150);
        },
        2 => {
            if (circle(u, v, 128, 132, 70)) base = mixColor(base, album.a, 170);
            if (v > 154 and ((u + v) & 18) < 7) base = mixColor(base, album.c, 92);
        },
        3 => {
            if (circle(u, v, 128, 128, 72) and !circle(u, v, 128, 128, 32)) base = mixColor(base, album.c, 165);
            if (absI32(v - 128) < 4 or absI32(u - 128) < 4) base = mixColor(base, .{ 0x12, 0x12, 0x12, 0xFF }, 160);
        },
        4 => {
            const wave = @mod(u + @divTrunc(v * v, 37), 42);
            if (wave < 12) base = mixColor(base, album.c, 130);
            if (v < 52) base = mixColor(base, .{ 0x02, 0x18, 0x2A, 0xFF }, 120);
        },
        5 => {
            if (absI32(u - 128) < 18 or absI32(v - 128) < 18) base = mixColor(base, album.b, 160);
            if (absI32(u - v) < 5) base = mixColor(base, album.c, 180);
        },
        6 => {
            if (@mod(@divTrunc(u, 32) + @divTrunc(v, 32), 2) == 0) base = mixColor(base, album.b, 90);
            if (absI32(u - 64) < 4 or absI32(u - 192) < 4 or absI32(v - 64) < 4 or absI32(v - 192) < 4) base = mixColor(base, album.c, 150);
        },
        7 => {
            if (u > 70 and u < 185 and v > 42 and v < 210) base = mixColor(base, album.b, 105);
            if (absI32(u - 128) + absI32(v - 126) < 62) base = mixColor(base, album.c, 125);
        },
        8 => {
            if (@mod(u + 2 * v, 47) < 4 or @mod(2 * u + v, 53) < 4) base = mixColor(base, album.b, 150);
            if (u > 40 and u < 214 and v > 56 and v < 196 and ((u + v) & 16) == 0) base = mixColor(base, album.c, 80);
        },
        else => {
            if (circle(u, v, 92, 96, 44) or circle(u, v, 164, 160, 52)) base = mixColor(base, album.b, 170);
            if (absI32(u - 128) < 5) base = mixColor(base, album.c, 130);
        },
    }

    if (u < 8 or u > 247 or v < 8 or v > 247) base = shadeColor(base, 58);
    if (v < 62 and u > 18 and u < 237) base = mixColor(base, .{ 0xFF, 0xFF, 0xFF, 0xFF }, @divTrunc((62 - v) * 90, 62));
    return base;
}

fn drawSoftShadow(q: Quad) void {
    const x0 = min4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
    const x1 = max4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
    const y = FLOOR_Y - 1;
    var yy: i32 = y - 10;
    while (yy <= y + 10) : (yy += 1) {
        var x: i32 = x0 - 12;
        while (x <= x1 + 12) : (x += 1) {
            const cx = if (x < x0) x0 - x else if (x > x1) x - x1 else 0;
            const cy = absI32(yy - y);
            const a = clampI32(42 - cx * 2 - cy * 4, 0, 42);
            if (a > 0) blendPixel(x, yy, .{ 0, 0, 0, @as(u8, @intCast(a)) });
        }
    }
}

fn drawQuadEdge(q: Quad, c: Color) void {
    drawLine(q.tl.x, q.tl.y, q.tr.x, q.tr.y, c);
    drawLine(q.tr.x, q.tr.y, q.br.x, q.br.y, c);
    drawLine(q.br.x, q.br.y, q.bl.x, q.bl.y, c);
    drawLine(q.bl.x, q.bl.y, q.tl.x, q.tl.y, c);
}

fn drawSpecular(q: Quad, dist: i32) void {
    const a = @as(u8, @intCast(clampI32(84 - @divTrunc(dist, 5), 18, 84)));
    const y0 = lerpI32(q.tl.y, q.bl.y, 38);
    const y1 = lerpI32(q.tr.y, q.br.y, 38);
    drawLine(q.tl.x + 8, y0, q.tr.x - 8, y1, .{ 0xFF, 0xFF, 0xFF, a });
}

fn drawChrome() void {
    blendRect(0, 0, @as(i32, @intCast(RENDER_W)), 42, .{ 0x00, 0x00, 0x00, 0x8F });
    drawText(27, 15, "COVER FLOW", .{ 0xEA, 0xF3, 0xFF, 0xFF }, 3);
    drawText(@as(i32, @intCast(RENDER_W)) - 213, 18, "DRAG OR ARROWS", .{ 0xA7, 0xB7, 0xC8, 0xFF }, 2);

    const idx = @as(usize, @intCast(targetIndex()));
    const album = albums[idx];
    const title_w = @as(i32, @intCast(album.title.len)) * 12;
    const artist_w = @as(i32, @intCast(album.artist.len)) * 8;
    drawText(CENTER_X - @divTrunc(title_w, 2), 378, album.title, .{ 0xF8, 0xFA, 0xFF, 0xFF }, 3);
    drawText(CENTER_X - @divTrunc(artist_w, 2), 411, album.artist, .{ 0xA9, 0xB5, 0xC3, 0xFF }, 2);

    const dots_w = @as(i32, @intCast(albums.len)) * 15 - 6;
    var i: usize = 0;
    while (i < albums.len) : (i += 1) {
        const x = CENTER_X - @divTrunc(dots_w, 2) + @as(i32, @intCast(i)) * 15;
        const active = i == idx;
        fillCircle(x, 447, if (active) 5 else 3, if (active) .{ 0xF5, 0xF7, 0xFF, 0xFF } else .{ 0x78, 0x84, 0x92, 0xC8 });
    }
}

fn clear(c: Color) void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        var x: i32 = 0;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 1) setPixel(x, y, c);
    }
}

fn setPixel(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn blendPixel(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const a = @as(i32, c[3]);
    if (a <= 0) return;
    if (a >= 255) {
        setPixel(x, y, c);
        return;
    }
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    pixel_buf[idx + 0] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 0]) * (255 - a) + @as(i32, c[0]) * a, 255)));
    pixel_buf[idx + 1] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 1]) * (255 - a) + @as(i32, c[1]) * a, 255)));
    pixel_buf[idx + 2] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 2]) * (255 - a) + @as(i32, c[2]) * a, 255)));
    pixel_buf[idx + 3] = 0xFF;
}

fn blendRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) blendPixel(x + xx, y + yy, c);
    }
}

fn drawLine(x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, c: Color) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const x1 = x1_in;
    const y1 = y1_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        blendPixel(x0, y0, c);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawChar(x + @as(i32, @intCast(i)) * 4 * scale, y, text[i], c, scale);
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            blendRect(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, c);
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b000, 0b000, 0b010, 0b000, 0b000 },
    };
}

fn fillCircle(cx: i32, cy: i32, radius: i32, c: Color) void {
    var y = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= radius * radius) blendPixel(x, y, c);
        }
    }
}

fn circle(u: i32, v: i32, cx: i32, cy: i32, r: i32) bool {
    const dx = u - cx;
    const dy = v - cy;
    return dx * dx + dy * dy <= r * r;
}

fn mixColor(a: Color, b: Color, t: i32) Color {
    return .{
        @as(u8, @intCast(lerpI32(a[0], b[0], t))),
        @as(u8, @intCast(lerpI32(a[1], b[1], t))),
        @as(u8, @intCast(lerpI32(a[2], b[2], t))),
        0xFF,
    };
}

fn addColor(c: Color, delta: i32) Color {
    return .{ clampU8(@as(i32, c[0]) + delta), clampU8(@as(i32, c[1]) + delta), clampU8(@as(i32, c[2]) + delta), c[3] };
}

fn shadeColor(c: Color, darken: i32) Color {
    const factor = clampI32(255 - darken, 0, 255);
    return .{
        @as(u8, @intCast(@divTrunc(@as(i32, c[0]) * factor, 255))),
        @as(u8, @intCast(@divTrunc(@as(i32, c[1]) * factor, 255))),
        @as(u8, @intCast(@divTrunc(@as(i32, c[2]) * factor, 255))),
        c[3],
    };
}

fn lerpI32(a: i32, b: i32, t: i32) i32 {
    return a + @divTrunc((b - a) * clampI32(t, 0, 255), 255);
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = clampF32((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * clampF32(t, 0.0, 1.0);
}

fn clampF32(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absF32(v: f32) f32 {
    return if (v < 0.0) -v else v;
}

fn clampU8(v: i32) u8 {
    return @as(u8, @intCast(clampI32(v, 0, 255)));
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn min4(a: i32, b: i32, c: i32, d: i32) i32 {
    return @min(@min(a, b), @min(c, d));
}

fn max4(a: i32, b: i32, c: i32, d: i32) i32 {
    return @max(@max(a, b), @max(c, d));
}
