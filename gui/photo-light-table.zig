const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const DISPLAY_W: usize = 800;
const DISPLAY_H: usize = 520;
const RETINA_SCALE: i32 = 2;
const RETINA_SCALE_SQ: i32 = RETINA_SCALE * RETINA_SCALE;
const RETINA_SCALE_USIZE: usize = 2;
const RENDER_W: usize = DISPLAY_W * RETINA_SCALE_USIZE;
const RENDER_H: usize = DISPLAY_H * RETINA_SCALE_USIZE;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const TEX_SIZE: usize = 256;
const TEX_COORD_MAX: i32 = @as(i32, @intCast(TEX_SIZE - 1));
const TEX_BYTES: usize = TEX_SIZE * TEX_SIZE * 4;
const PHOTO_COUNT: usize = 12;
const TGA_BGRA8_256_HEADER = [_]u8{
    0, 0,  2,
    0, 0,  0,
    0, 0,  0,
    0, 0,  0,
    0, 1,  0,
    1, 32, 0x28,
};

const CENTER_X: i32 = @as(i32, @intCast(RENDER_W / 2));
const CENTER_Y: i32 = @as(i32, @intCast(RENDER_H / 2)) + 10 * RETINA_SCALE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;

const photo00 = tgaBgra8(@embedFile("assets/photo-light-table/tga/00.tga"));
const photo01 = tgaBgra8(@embedFile("assets/photo-light-table/tga/01.tga"));
const photo02 = tgaBgra8(@embedFile("assets/photo-light-table/tga/02.tga"));
const photo03 = tgaBgra8(@embedFile("assets/photo-light-table/tga/03.tga"));
const photo04 = tgaBgra8(@embedFile("assets/photo-light-table/tga/04.tga"));
const photo05 = tgaBgra8(@embedFile("assets/photo-light-table/tga/05.tga"));
const photo06 = tgaBgra8(@embedFile("assets/photo-light-table/tga/06.tga"));
const photo07 = tgaBgra8(@embedFile("assets/photo-light-table/tga/07.tga"));
const photo08 = tgaBgra8(@embedFile("assets/photo-light-table/tga/08.tga"));
const photo09 = tgaBgra8(@embedFile("assets/photo-light-table/tga/09.tga"));
const photo10 = tgaBgra8(@embedFile("assets/photo-light-table/tga/10.tga"));
const photo11 = tgaBgra8(@embedFile("assets/photo-light-table/tga/11.tga"));

comptime {
    if (photo00.len != TEX_BYTES) @compileError("photo 00 must be 256x256 RGBA8");
    if (photo01.len != TEX_BYTES) @compileError("photo 01 must be 256x256 RGBA8");
    if (photo02.len != TEX_BYTES) @compileError("photo 02 must be 256x256 RGBA8");
    if (photo03.len != TEX_BYTES) @compileError("photo 03 must be 256x256 RGBA8");
    if (photo04.len != TEX_BYTES) @compileError("photo 04 must be 256x256 RGBA8");
    if (photo05.len != TEX_BYTES) @compileError("photo 05 must be 256x256 RGBA8");
    if (photo06.len != TEX_BYTES) @compileError("photo 06 must be 256x256 RGBA8");
    if (photo07.len != TEX_BYTES) @compileError("photo 07 must be 256x256 RGBA8");
    if (photo08.len != TEX_BYTES) @compileError("photo 08 must be 256x256 RGBA8");
    if (photo09.len != TEX_BYTES) @compileError("photo 09 must be 256x256 RGBA8");
    if (photo10.len != TEX_BYTES) @compileError("photo 10 must be 256x256 RGBA8");
    if (photo11.len != TEX_BYTES) @compileError("photo 11 must be 256x256 RGBA8");
}

const photos = [_][]const u8{
    photo00[0..TEX_BYTES],
    photo01[0..TEX_BYTES],
    photo02[0..TEX_BYTES],
    photo03[0..TEX_BYTES],
    photo04[0..TEX_BYTES],
    photo05[0..TEX_BYTES],
    photo06[0..TEX_BYTES],
    photo07[0..TEX_BYTES],
    photo08[0..TEX_BYTES],
    photo09[0..TEX_BYTES],
    photo10[0..TEX_BYTES],
    photo11[0..TEX_BYTES],
};

fn tgaBgra8(comptime bytes: []const u8) []const u8 {
    comptime {
        if (bytes.len != TGA_BGRA8_256_HEADER.len + TEX_BYTES) @compileError("TGA texture must be 256x256 BGRA8");
        if (!std.mem.eql(u8, bytes[0..TGA_BGRA8_256_HEADER.len], TGA_BGRA8_256_HEADER[0..])) @compileError("TGA texture header must be canonical 256x256 top-left BGRA8");
        const payload = bytes[TGA_BGRA8_256_HEADER.len..];
        if (payload.len != TEX_BYTES) @compileError("TGA texture payload must be 256x256 BGRA8");
        return payload;
    }
}

const Point = struct {
    x: i32,
    y: i32,
};

const Quad = struct {
    tl: Point,
    tr: Point,
    br: Point,
    bl: Point,
};

const AffineMap = struct {
    u_x: f32,
    u_y: f32,
    u_c: f32,
    v_x: f32,
    v_y: f32,
    v_c: f32,
};

const Card = struct {
    x: i32,
    y: i32,
    cos_q14: i32,
    sin_q14: i32,
    scale_q8: i32,
    light_q8: i32,
};

const cards = [_]Card{
    .{ .x = -310, .y = -176, .cos_q14 = 16135, .sin_q14 = -2845, .scale_q8 = 234, .light_q8 = 226 },
    .{ .x = -102, .y = -196, .cos_q14 = 16225, .sin_q14 = 2280, .scale_q8 = 242, .light_q8 = 236 },
    .{ .x = 126, .y = -166, .cos_q14 = 15826, .sin_q14 = 4240, .scale_q8 = 230, .light_q8 = 222 },
    .{ .x = 330, .y = -122, .cos_q14 = 15582, .sin_q14 = -5063, .scale_q8 = 224, .light_q8 = 218 },
    .{ .x = -350, .y = 16, .cos_q14 = 16322, .sin_q14 = 1428, .scale_q8 = 238, .light_q8 = 230 },
    .{ .x = -130, .y = 10, .cos_q14 = 16294, .sin_q14 = -1712, .scale_q8 = 250, .light_q8 = 238 },
    .{ .x = 98, .y = 18, .cos_q14 = 16027, .sin_q14 = 3406, .scale_q8 = 236, .light_q8 = 226 },
    .{ .x = 315, .y = 68, .cos_q14 = 15883, .sin_q14 = -3975, .scale_q8 = 228, .light_q8 = 220 },
    .{ .x = -258, .y = 202, .cos_q14 = 16362, .sin_q14 = 858, .scale_q8 = 232, .light_q8 = 224 },
    .{ .x = -28, .y = 190, .cos_q14 = 15396, .sin_q14 = -5604, .scale_q8 = 244, .light_q8 = 236 },
    .{ .x = 210, .y = 214, .cos_q14 = 15582, .sin_q14 = 5063, .scale_q8 = 230, .light_q8 = 224 },
    .{ .x = 420, .y = 205, .cos_q14 = 16027, .sin_q14 = -3406, .scale_q8 = 222, .light_q8 = 216 },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var background_buf: [PIXEL_BYTES]u8 = undefined;
var initialized = false;
var needs_redraw = true;
var selected: i32 = 5;
var pan_x_q8: i32 = -cards[5].x * RETINA_SCALE * 256;
var pan_y_q8: i32 = -cards[5].y * RETINA_SCALE * 256;
var target_pan_x_q8: i32 = -cards[5].x * RETINA_SCALE * 256;
var target_pan_y_q8: i32 = -cards[5].y * RETINA_SCALE * 256;
var primary_down = false;
var press_x: i32 = 0;
var press_y: i32 = 0;
var press_pan_x_q8: i32 = 0;
var press_pan_y_q8: i32 = 0;
var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
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
    if (transaction_phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    next_wake_at_ms = now_ms;
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    switch (x11_key) {
        XK_LEFT, 'a', 'A' => stepSelection(-1),
        XK_RIGHT, 'd', 'D' => stepSelection(1),
        XK_UP, 'w', 'W' => stepSelection(-4),
        XK_DOWN, 's', 'S' => stepSelection(4),
        XK_HOME => setSelection(0),
        XK_END => setSelection(@as(i32, @intCast(PHOTO_COUNT)) - 1),
        else => return 0,
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    ensureInit();
    pointer_x = x_px;
    pointer_y = y_px;

    const down = (button_mask & BTN_PRIMARY) != 0;
    if (down and !primary_down) {
        press_x = x_px;
        press_y = y_px;
        press_pan_x_q8 = pan_x_q8;
        press_pan_y_q8 = pan_y_q8;
        target_pan_x_q8 = pan_x_q8;
        target_pan_y_q8 = pan_y_q8;
        needs_redraw = true;
    } else if (down and primary_down) {
        pan_x_q8 = press_pan_x_q8 + (x_px - press_x) * 256;
        pan_y_q8 = press_pan_y_q8 + (y_px - press_y) * 256;
        target_pan_x_q8 = pan_x_q8;
        target_pan_y_q8 = pan_y_q8;
        needs_redraw = true;
    } else if (!down and primary_down) {
        const drag_dist = absI32(x_px - press_x) + absI32(y_px - press_y);
        if (drag_dist < 8 * RETINA_SCALE) {
            const hit = hitCard(x_px, y_px);
            if (hit >= 0) setSelection(hit);
        }
        needs_redraw = true;
    }

    primary_down = down;
    return if (needs_redraw) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    ensureInit();
    var active = primary_down;
    if (!primary_down) {
        const dx = target_pan_x_q8 - pan_x_q8;
        const dy = target_pan_y_q8 - pan_y_q8;
        if (absI32(dx) > 1 or absI32(dy) > 1) {
            pan_x_q8 += easedStep(dx);
            pan_y_q8 += easedStep(dy);
            needs_redraw = true;
            active = true;
        } else {
            pan_x_q8 = target_pan_x_q8;
            pan_y_q8 = target_pan_y_q8;
        }
    }
    next_wake_at_ms = if (active and begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    ensureInit();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    transaction_phase = .ready;
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
    if (transaction_phase != .updating) @trap();
    advanceTransactionTime();
    const active = primary_down or absI32(target_pan_x_q8 - pan_x_q8) > 1 or absI32(target_pan_y_q8 - pan_y_q8) > 1;
    next_wake_at_ms = if (active and begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn ensureInit() void {
    if (initialized) return;
    drawBackground();
    @memcpy(background_buf[0..], pixel_buf[0..]);
    initialized = true;
    needs_redraw = true;
}

fn stepSelection(delta: i32) void {
    setSelection(selected + delta);
}

fn setSelection(index: i32) void {
    selected = clampI32(index, 0, @as(i32, @intCast(PHOTO_COUNT)) - 1);
    target_pan_x_q8 = -cards[@as(usize, @intCast(selected))].x * RETINA_SCALE * 256;
    target_pan_y_q8 = -cards[@as(usize, @intCast(selected))].y * RETINA_SCALE * 256;
}

fn easedStep(delta: i32) i32 {
    var step = @divTrunc(delta, 5);
    if (step == 0 and delta != 0) step = if (delta < 0) -1 else 1;
    return step;
}

fn drawFrame() void {
    @memcpy(pixel_buf[0..], background_buf[0..]);

    var i: usize = 0;
    while (i < PHOTO_COUNT) : (i += 1) {
        drawCardShadow(makeCardQuad(@as(i32, @intCast(i)), false), i == @as(usize, @intCast(selected)));
    }

    const selected_idx = @as(usize, @intCast(selected));
    const selected_quad = makeCardQuad(selected, true);
    drawPhotoQuad(photos[selected_idx], makeReflectionQuad(selected_quad), 74, 168, true, true);

    i = 0;
    while (i < PHOTO_COUNT) : (i += 1) {
        if (i == selected_idx) continue;
        const light = cards[i].light_q8;
        drawPhotoQuad(photos[i], makeCardQuad(@as(i32, @intCast(i)), false), 255, light, false, false);
    }

    drawPhotoQuad(photos[selected_idx], selected_quad, 255, 270, false, false);
    drawPointerGlint();
}

fn drawBackground() void {
    const horizon = 178 * RETINA_SCALE;
    var y: usize = 0;
    while (y < RENDER_H) : (y += 1) {
        const yi = @as(i32, @intCast(y));
        var x: usize = 0;
        while (x < RENDER_W) : (x += 1) {
            const xi = @as(i32, @intCast(x));
            const dx = absI32(xi - CENTER_X);
            const dy = absI32(yi - CENTER_Y);
            const vignette = @divTrunc(dx * dx, 2200 * RETINA_SCALE_SQ) + @divTrunc(dy * dy, 2500 * RETINA_SCALE_SQ);
            var r: i32 = 16;
            var g: i32 = 18;
            var b: i32 = 22;

            if (yi < horizon) {
                const sky = @divTrunc(horizon - yi, 8 * RETINA_SCALE);
                r += sky;
                g += sky + 2;
                b += sky + 8;
            } else {
                const table = @divTrunc(yi - horizon, 13 * RETINA_SCALE);
                r += table;
                g += table + 2;
                b += table + 5;
                if (@mod(xi + yi, 38 * RETINA_SCALE) == 0) {
                    r += 4;
                    g += 5;
                    b += 7;
                }
            }

            if (yi >= horizon and yi < horizon + 2 * RETINA_SCALE) {
                r += 35;
                g += 38;
                b += 44;
            }

            r = clampI32(r - vignette, 0, 255);
            g = clampI32(g - vignette, 0, 255);
            b = clampI32(b - vignette, 0, 255);
            storePixel(xi, yi, packRgb(@as(u8, @intCast(r)), @as(u8, @intCast(g)), @as(u8, @intCast(b))));
        }
    }
}

fn makeCardQuad(index: i32, force_selected: bool) Quad {
    const card = cards[@as(usize, @intCast(index))];
    const is_selected = force_selected or index == selected;
    const scale_q8: i32 = if (is_selected) 416 else card.scale_q8;
    const half = @divTrunc(64 * RETINA_SCALE * scale_q8, 256);
    const lift: i32 = if (is_selected) -16 * RETINA_SCALE else 0;
    const cx = CENTER_X + @divTrunc(card.x * RETINA_SCALE * 256 + pan_x_q8, 256);
    const cy = CENTER_Y + @divTrunc(card.y * RETINA_SCALE * 256 + pan_y_q8, 256) + lift;
    const ux = @divTrunc(half * card.cos_q14, 16384);
    const uy = @divTrunc(half * card.sin_q14, 16384);
    const vx = -@divTrunc(half * card.sin_q14, 16384);
    const vy = @divTrunc(half * card.cos_q14, 16384);
    return .{
        .tl = .{ .x = cx - ux - vx, .y = cy - uy - vy },
        .tr = .{ .x = cx + ux - vx, .y = cy + uy - vy },
        .br = .{ .x = cx + ux + vx, .y = cy + uy + vy },
        .bl = .{ .x = cx - ux + vx, .y = cy - uy + vy },
    };
}

fn makeReflectionQuad(q: Quad) Quad {
    const drop = 11 * RETINA_SCALE;
    const fade_q8 = 168;
    return .{
        .tl = .{ .x = q.bl.x, .y = q.bl.y + drop },
        .tr = .{ .x = q.br.x, .y = q.br.y + drop },
        .br = .{
            .x = q.tr.x,
            .y = q.br.y + drop + @divTrunc((q.br.y - q.tr.y) * fade_q8, 256),
        },
        .bl = .{
            .x = q.tl.x,
            .y = q.bl.y + drop + @divTrunc((q.bl.y - q.tl.y) * fade_q8, 256),
        },
    };
}

fn drawCardShadow(q: Quad, strong: bool) void {
    const alpha: u8 = if (strong) 82 else 46;
    const spread: i32 = if (strong) 13 * RETINA_SCALE else 8 * RETINA_SCALE;
    const shadow = offsetQuad(q, spread, spread + 5);
    drawSolidQuadFast(shadow, packRgb(0, 0, 0), alpha);
}

fn drawPointerGlint() void {
    if (pointer_x < 0 or pointer_y < 0) return;
    const hit = hitCard(pointer_x, pointer_y);
    if (hit < 0) return;
    const q = makeCardQuad(hit, hit == selected);
    const highlight = insetTopBand(q);
    drawSolidQuad(highlight, packRgb(255, 255, 255), 34);
}

fn offsetQuad(q: Quad, dx: i32, dy: i32) Quad {
    return .{
        .tl = .{ .x = q.tl.x + dx, .y = q.tl.y + dy },
        .tr = .{ .x = q.tr.x + dx, .y = q.tr.y + dy },
        .br = .{ .x = q.br.x + dx, .y = q.br.y + dy },
        .bl = .{ .x = q.bl.x + dx, .y = q.bl.y + dy },
    };
}

fn insetTopBand(q: Quad) Quad {
    return .{
        .tl = q.tl,
        .tr = q.tr,
        .br = lerpPoint(q.tr, q.br, 60),
        .bl = lerpPoint(q.tl, q.bl, 60),
    };
}

fn lerpPoint(a: Point, b: Point, t_q8: i32) Point {
    return .{
        .x = a.x + @divTrunc((b.x - a.x) * t_q8, 256),
        .y = a.y + @divTrunc((b.y - a.y) * t_q8, 256),
    };
}

fn drawPhotoQuad(photo: []const u8, q: Quad, alpha: u8, light_q8: i32, flip_v: bool, reflection: bool) void {
    const map = inverseAffine(q) orelse return;
    const bounds = boundsForQuad(q);
    if (bounds.max_x < bounds.min_x or bounds.max_y < bounds.min_y) return;

    const min_y = bounds.min_y;
    const max_y = bounds.max_y;
    const height = @max(1, max_y - min_y + 1);
    const coord_scale = @as(f32, @floatFromInt(TEX_COORD_MAX * 256));
    const step_u = map.u_x * coord_scale;
    const step_v = map.v_x * coord_scale;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y)) + 0.5;
        var u_f = (map.u_x * (@as(f32, @floatFromInt(bounds.min_x)) + 0.5) + map.u_y * yf + map.u_c) * coord_scale;
        var v_f = (map.v_x * (@as(f32, @floatFromInt(bounds.min_x)) + 0.5) + map.v_y * yf + map.v_c) * coord_scale;
        const row_fade = if (reflection)
            @divTrunc((max_y - y) * @as(i32, alpha), height)
        else
            @as(i32, alpha);

        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            if (pointInQuad(q, @as(f32, @floatFromInt(x)) + 0.5, yf)) {
                var uq = @as(i32, @intFromFloat(u_f));
                var vq = @as(i32, @intFromFloat(v_f));
                if (flip_v) vq = TEX_COORD_MAX * 256 - vq;
                uq = clampI32(uq, 0, TEX_COORD_MAX * 256);
                vq = clampI32(vq, 0, TEX_COORD_MAX * 256);
                var src = samplePhotoBilinear(photo, uq, vq);
                src = shadePacked(src, light_q8);
                const out_alpha = row_fade;
                if (out_alpha >= 255) {
                    storePixel(x, y, src);
                } else if (out_alpha > 0) {
                    blendPixel(x, y, src, @as(u8, @intCast(out_alpha)));
                }
            }
            u_f += step_u;
            v_f += step_v;
        }
    }
}

fn drawSolidQuad(q: Quad, color: u32, alpha: u8) void {
    const bounds = boundsForQuad(q);
    if (bounds.max_x < bounds.min_x or bounds.max_y < bounds.min_y) return;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            const coverage = coverage4(q, x, y);
            if (coverage != 0) {
                const out_alpha = @divTrunc(@as(i32, alpha) * @as(i32, coverage), 4);
                if (out_alpha > 0) blendPixel(x, y, color, @as(u8, @intCast(out_alpha)));
            }
        }
    }
}

fn drawSolidQuadFast(q: Quad, color: u32, alpha: u8) void {
    const bounds = boundsForQuad(q);
    if (bounds.max_x < bounds.min_x or bounds.max_y < bounds.min_y) return;
    var y = bounds.min_y;
    while (y <= bounds.max_y) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y)) + 0.5;
        var x = bounds.min_x;
        while (x <= bounds.max_x) : (x += 1) {
            if (pointInQuad(q, @as(f32, @floatFromInt(x)) + 0.5, yf)) {
                blendPixel(x, y, color, alpha);
            }
        }
    }
}

const Bounds = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
};

fn boundsForQuad(q: Quad) Bounds {
    return .{
        .min_x = clampI32(min4(q.tl.x, q.tr.x, q.br.x, q.bl.x) - 2, 0, @as(i32, @intCast(RENDER_W)) - 1),
        .min_y = clampI32(min4(q.tl.y, q.tr.y, q.br.y, q.bl.y) - 2, 0, @as(i32, @intCast(RENDER_H)) - 1),
        .max_x = clampI32(max4(q.tl.x, q.tr.x, q.br.x, q.bl.x) + 2, 0, @as(i32, @intCast(RENDER_W)) - 1),
        .max_y = clampI32(max4(q.tl.y, q.tr.y, q.br.y, q.bl.y) + 2, 0, @as(i32, @intCast(RENDER_H)) - 1),
    };
}

fn inverseAffine(q: Quad) ?AffineMap {
    const tlx = @as(f32, @floatFromInt(q.tl.x));
    const tly = @as(f32, @floatFromInt(q.tl.y));
    const dxu = @as(f32, @floatFromInt(q.tr.x - q.tl.x));
    const dyu = @as(f32, @floatFromInt(q.tr.y - q.tl.y));
    const dxv = @as(f32, @floatFromInt(q.bl.x - q.tl.x));
    const dyv = @as(f32, @floatFromInt(q.bl.y - q.tl.y));
    const det = dxu * dyv - dyu * dxv;
    if (det > -0.001 and det < 0.001) return null;
    const inv_det = 1.0 / det;
    return .{
        .u_x = dyv * inv_det,
        .u_y = -dxv * inv_det,
        .u_c = (dxv * tly - dyv * tlx) * inv_det,
        .v_x = -dyu * inv_det,
        .v_y = dxu * inv_det,
        .v_c = (dyu * tlx - dxu * tly) * inv_det,
    };
}

fn coverage4(q: Quad, x: i32, y: i32) u8 {
    const xf = @as(f32, @floatFromInt(x));
    const yf = @as(f32, @floatFromInt(y));
    var covered: u8 = 0;
    if (pointInQuad(q, xf + 0.25, yf + 0.25)) covered += 1;
    if (pointInQuad(q, xf + 0.75, yf + 0.25)) covered += 1;
    if (pointInQuad(q, xf + 0.25, yf + 0.75)) covered += 1;
    if (pointInQuad(q, xf + 0.75, yf + 0.75)) covered += 1;
    return covered;
}

fn pointInQuad(q: Quad, x: f32, y: f32) bool {
    return edge(q.tl, q.tr, x, y) >= -0.01 and
        edge(q.tr, q.br, x, y) >= -0.01 and
        edge(q.br, q.bl, x, y) >= -0.01 and
        edge(q.bl, q.tl, x, y) >= -0.01;
}

fn edge(a: Point, b: Point, x: f32, y: f32) f32 {
    const ax = @as(f32, @floatFromInt(a.x));
    const ay = @as(f32, @floatFromInt(a.y));
    const bx = @as(f32, @floatFromInt(b.x));
    const by = @as(f32, @floatFromInt(b.y));
    return (bx - ax) * (y - ay) - (by - ay) * (x - ax);
}

fn hitCard(x: i32, y: i32) i32 {
    var i: i32 = @as(i32, @intCast(PHOTO_COUNT)) - 1;
    while (i >= 0) : (i -= 1) {
        const q = makeCardQuad(i, i == selected);
        if (pointInQuad(q, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5)) return i;
        if (i == 0) break;
    }
    return -1;
}

fn samplePhotoBilinear(photo: []const u8, u_q8: i32, v_q8: i32) u32 {
    const ux = @as(usize, @intCast(u_q8 >> 8));
    const uy = @as(usize, @intCast(v_q8 >> 8));
    const tx = u_q8 & 255;
    const ty = v_q8 & 255;
    const ux1 = @min(ux + 1, TEX_SIZE - 1);
    const uy1 = @min(uy + 1, TEX_SIZE - 1);
    const p00 = readTexel(photo, ux, uy);
    const p10 = readTexel(photo, ux1, uy);
    const p01 = readTexel(photo, ux, uy1);
    const p11 = readTexel(photo, ux1, uy1);
    const r = bilerpChannel(p00, p10, p01, p11, tx, ty, 0);
    const g = bilerpChannel(p00, p10, p01, p11, tx, ty, 8);
    const b = bilerpChannel(p00, p10, p01, p11, tx, ty, 16);
    return packRgb(r, g, b);
}

fn readTexel(photo: []const u8, x: usize, y: usize) u32 {
    const idx = (y * TEX_SIZE + x) * 4;
    return packRgb(photo[idx + 2], photo[idx + 1], photo[idx]);
}

fn bilerpChannel(p00: u32, p10: u32, p01: u32, p11: u32, tx: i32, ty: i32, shift: u5) u8 {
    const a = @as(i32, @intCast((p00 >> shift) & 0xFF));
    const b = @as(i32, @intCast((p10 >> shift) & 0xFF));
    const c = @as(i32, @intCast((p01 >> shift) & 0xFF));
    const d = @as(i32, @intCast((p11 >> shift) & 0xFF));
    const top = a * (256 - tx) + b * tx;
    const bottom = c * (256 - tx) + d * tx;
    return @as(u8, @intCast((top * (256 - ty) + bottom * ty + 32768) >> 16));
}

fn shadePacked(pixel: u32, light_q8: i32) u32 {
    const r = shadeChannel(@as(i32, @intCast(pixel & 0xFF)), light_q8);
    const g = shadeChannel(@as(i32, @intCast((pixel >> 8) & 0xFF)), light_q8);
    const b = shadeChannel(@as(i32, @intCast((pixel >> 16) & 0xFF)), light_q8);
    return packRgb(r, g, b);
}

fn shadeChannel(value: i32, light_q8: i32) u8 {
    return @as(u8, @intCast(clampI32(@divTrunc(value * light_q8 + 128, 256), 0, 255)));
}

fn blendPixel(x: i32, y: i32, src: u32, alpha: u8) void {
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const dst = std.mem.readInt(u32, pixel_buf[idx..][0..4], .little);
    const a = @as(i32, alpha);
    const inv = 255 - a;
    const sr = @as(i32, @intCast(src & 0xFF));
    const sg = @as(i32, @intCast((src >> 8) & 0xFF));
    const sb = @as(i32, @intCast((src >> 16) & 0xFF));
    const dr = @as(i32, @intCast(dst & 0xFF));
    const dg = @as(i32, @intCast((dst >> 8) & 0xFF));
    const db = @as(i32, @intCast((dst >> 16) & 0xFF));
    const r = div255Positive(sr * a + dr * inv);
    const g = div255Positive(sg * a + dg * inv);
    const b = div255Positive(sb * a + db * inv);
    std.mem.writeInt(u32, pixel_buf[idx..][0..4], packRgb(@as(u8, @intCast(r)), @as(u8, @intCast(g)), @as(u8, @intCast(b))), .little);
}

fn storePixel(x: i32, y: i32, pixel: u32) void {
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    std.mem.writeInt(u32, pixel_buf[idx..][0..4], pixel, .little);
}

fn packRgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, 0xFF) << 24);
}

fn div255Positive(value: i32) i32 {
    return @divTrunc(value + 128 + @divTrunc(value + 128, 256), 256);
}

fn min4(a: i32, b: i32, c: i32, d: i32) i32 {
    return @min(@min(a, b), @min(c, d));
}

fn max4(a: i32, b: i32, c: i32, d: i32) i32 {
    return @max(@max(a, b), @max(c, d));
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}
