const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const ui_font = @import("assets/dejavu_sans_mono_56_ascii_subset.zig");

const DISPLAY_W: usize = 720;
const DISPLAY_H: usize = 480;
const RETINA_SCALE: i32 = 2;
const RETINA_SCALE_USIZE: usize = 2;
const RENDER_W: usize = DISPLAY_W * RETINA_SCALE_USIZE;
const RENDER_H: usize = DISPLAY_H * RETINA_SCALE_USIZE;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_RIGHT: i32 = 0xFF53;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;

const COVER: i32 = 190 * RETINA_SCALE;
const COVER_TEX_SIZE: usize = 256;
const COVER_TEX_SHIFT: usize = 8;
const COVER_TEX_COORD_MAX: i32 = @as(i32, @intCast(COVER_TEX_SIZE - 1));
const COVER_TEXELS_PER_ALBUM: usize = COVER_TEX_SIZE * COVER_TEX_SIZE;
const FLOOR_Y: i32 = 282 * RETINA_SCALE;
const CENTER_X: i32 = @divTrunc(@as(i32, @intCast(RENDER_W)), 2);
const MAX_ALBUMS: usize = 10;
const ROW_CLIP_NONE: u8 = 0xFF;

const FEATURE_BILINEAR: u32 = 1 << 0;
const FEATURE_ANTIALIAS: u32 = 1 << 1;
const FEATURE_LIGHTING: u32 = 1 << 2;
const FEATURE_SPRING: u32 = 1 << 3;
const FEATURE_ALL: u32 = FEATURE_LIGHTING | FEATURE_SPRING;
// The hifi path forces bilinear + AA on, but this internal dispatch shape
// currently produces faster wasm than deleting the alternate rasterizers.
const FEATURE_RENDERING: u32 = FEATURE_BILINEAR | FEATURE_ANTIALIAS;

comptime {
    if (COVER_TEX_SIZE != (@as(usize, 1) << COVER_TEX_SHIFT)) @compileError("cover texture size must match its shift");
    if (COVER_TEX_SIZE % 8 != 0) @compileError("cover texture size must be divisible by 8");
}

const Color = [4]u8;
const Vec4f = @Vector(4, f32);
const Vec4i = @Vector(4, i32);

const ColorBatch = struct {
    r: Vec4i,
    g: Vec4i,
    b: Vec4i,
};

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

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Quad = struct {
    tl: Point,
    tr: Point,
    br: Point,
    bl: Point,
};

const EdgeEquation = struct {
    x: f32,
    y: f32,
    c: f32,
};

const QuadEdges = struct {
    top: EdgeEquation,
    right: EdgeEquation,
    bottom: EdgeEquation,
    left: EdgeEquation,
};

const RowFullCoverageSpan = struct {
    min_x: i32,
    max_x: i32,

    inline fn containsBatch4(self: RowFullCoverageSpan, x: i32) bool {
        return x >= self.min_x and x + 3 <= self.max_x;
    }
};

const FrameCover = struct {
    index: i32,
    q: Quad,
    reflection_q: Quad,
    dist: i32,
    side_dark: i32,
    light_boost: i32,
    reflection_alpha: u8,
};

const CoverPose = struct {
    q: Quad,
    normal: Vec3,
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
var background_buf: [PIXEL_BYTES]u8 = undefined;
var cover_texels: [MAX_ALBUMS * COVER_TEXELS_PER_ALBUM]u32 = undefined;
var cache_initialized = false;
var needs_redraw = true;
var selected_q8: i32 = 3 * 256;
var target_q8: i32 = 3 * 256;
var velocity_q8: i32 = 0;
var spring_velocity_q8: i32 = 0;
var primary_down = false;
var press_x: i32 = 0;
var last_x: i32 = 0;
var last_dx: i32 = 0;
var press_selected_q8: i32 = 0;
var feature_mask: u32 = FEATURE_RENDERING | FEATURE_ALL;
var cover_edges: [MAX_ALBUMS]QuadEdges = undefined;
var cover_clip_neighbor: [MAX_ALBUMS]u8 = undefined;
var cover_clip_side: [MAX_ALBUMS]i8 = undefined;
var project_u_f: [RENDER_W]f32 = undefined;
var project_v_x: [RENDER_W]f32 = undefined;
var project_inv_d: [RENDER_W]f32 = undefined;
var project_u_mid: [RENDER_W]i32 = undefined;

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
        'l', 'L' => toggleFeature(FEATURE_LIGHTING),
        's', 'S' => toggleFeature(FEATURE_SPRING),
        else => return 0,
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const down = (button_mask & BTN_PRIMARY) != 0;
    const was_down = primary_down;

    if (down and !primary_down) {
        press_x = x_px;
        last_x = x_px;
        last_dx = 0;
        press_selected_q8 = selected_q8;
        target_q8 = selected_q8;
        velocity_q8 = 0;
        spring_velocity_q8 = 0;
    } else if (down and primary_down) {
        const dx = x_px - press_x;
        last_dx = x_px - last_x;
        last_x = x_px;
        selected_q8 = clampSelected(press_selected_q8 - @divTrunc(dx * 256, 129 * RETINA_SCALE), true);
        target_q8 = selected_q8;
        velocity_q8 = @divTrunc((-last_dx) * 256, 129 * RETINA_SCALE);
        spring_velocity_q8 = 0;
        needs_redraw = true;
    } else if (!down and primary_down) {
        if (absI32(x_px - press_x) < 5 * RETINA_SCALE) {
            const hit = hitAlbum(x_px, y_px);
            if (hit >= 0) setSelection(hit);
        }
        needs_redraw = true;
    }
    primary_down = down;
    return if (was_down != down or (down and was_down)) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    var active = primary_down;
    if (!primary_down) {
        if (velocity_q8 != 0) {
            selected_q8 = clampSelected(selected_q8 + velocity_q8, true);
            velocity_q8 = @divTrunc(velocity_q8 * 88, 100);
            if (absI32(velocity_q8) < 3) {
                velocity_q8 = 0;
                target_q8 = nearestIndex() * 256;
                spring_velocity_q8 = 0;
            }
            needs_redraw = true;
            active = true;
        } else {
            const delta = target_q8 - selected_q8;
            if (featureEnabled(FEATURE_SPRING)) {
                if (absI32(delta) > 1 or absI32(spring_velocity_q8) > 2) {
                    spring_velocity_q8 += @divTrunc(delta, 7);
                    spring_velocity_q8 = @divTrunc(spring_velocity_q8 * 72, 100);
                    if (spring_velocity_q8 == 0 and delta != 0) spring_velocity_q8 = if (delta < 0) -1 else 1;
                    selected_q8 += spring_velocity_q8;
                    needs_redraw = true;
                    active = true;
                } else {
                    selected_q8 = target_q8;
                    spring_velocity_q8 = 0;
                }
            } else {
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
    }
    next_wake_at_ms = if (active and begun_at_ms <= std.math.maxInt(i64) - 16)
        begun_at_ms + 16
    else
        begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    ensureCache();
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
    const active = primary_down or velocity_q8 != 0 or absI32(target_q8 - selected_q8) > 1 or absI32(spring_velocity_q8) > 2;
    next_wake_at_ms = if (active and begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    phase = .ready;
    return wake;
}

fn ensureCache() void {
    if (cache_initialized) return;
    buildCoverTextures();
    drawBackground();
    @memcpy(background_buf[0..], pixel_buf[0..]);
    cache_initialized = true;
    needs_redraw = true;
}

fn buildCoverTextures() void {
    var album_idx: usize = 0;
    while (album_idx < albums.len) : (album_idx += 1) {
        var v: usize = 0;
        while (v < COVER_TEX_SIZE) : (v += 1) {
            var u: usize = 0;
            while (u < COVER_TEX_SIZE) : (u += 1) {
                cover_texels[0..][coverTexelIndexUnchecked(album_idx, u, v)] = packPixel(sampleAlbumByIndex(album_idx, @as(i32, @intCast(u)), @as(i32, @intCast(v))));
            }
        }
    }
}

fn stepSelection(delta: i32) void {
    setSelection(nearestIndex() + delta);
}

fn setSelection(index: i32) void {
    target_q8 = clampSelected(index * 256, false);
    velocity_q8 = 0;
    spring_velocity_q8 = 0;
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
        const q = coverQuad(false, i);
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
    @memcpy(pixel_buf[0..], background_buf[0..]);
    const nearest = nearestIndex();
    var covers: [MAX_ALBUMS]FrameCover = undefined;
    var valid = [_]bool{false} ** MAX_ALBUMS;
    buildFrameCovers(nearest, &covers, &valid);
    buildCoverRowVisibility(nearest, &covers, &valid);
    drawReflections(nearest, &covers, &valid);
    drawAlbums(nearest, &covers, &valid);
    drawChrome();
}

fn buildCoverRowVisibility(nearest: i32, covers: *const [MAX_ALBUMS]FrameCover, valid: *const [MAX_ALBUMS]bool) void {
    @memset(cover_clip_neighbor[0..], ROW_CLIP_NONE);
    @memset(cover_clip_side[0..], 0);

    var i: usize = 0;
    while (i < MAX_ALBUMS) : (i += 1) {
        if (valid[i]) cover_edges[i] = makeQuadEdges(covers[i].q);
    }

    var pass: i32 = 1;
    while (pass <= 5) : (pass += 1) {
        const left = nearest - pass;
        if (left >= 0) {
            const slot = @as(usize, @intCast(left));
            if (valid[slot]) {
                cover_clip_neighbor[slot] = @as(u8, @intCast(slot + 1));
                cover_clip_side[slot] = -1;
            }
        }
        const right = nearest + pass;
        if (right < @as(i32, @intCast(albums.len))) {
            const slot = @as(usize, @intCast(right));
            if (valid[slot]) {
                cover_clip_neighbor[slot] = @as(u8, @intCast(slot - 1));
                cover_clip_side[slot] = 1;
            }
        }
    }
}

inline fn clipCoverRowToVisibleX(album_idx: usize, y: i32, row_min_x: *i32, row_max_x: *i32) void {
    const side = cover_clip_side[album_idx];
    if (side == 0) return;
    const neighbor = cover_clip_neighbor[album_idx];
    if (neighbor == ROW_CLIP_NONE) return;

    const span = rowFullCoverageSpan(cover_edges[neighbor], y, 0, @as(i32, @intCast(RENDER_W)) - 1);
    if (span.min_x > span.max_x) return;

    if (side < 0) {
        if (row_max_x.* >= span.min_x and row_max_x.* <= span.max_x) {
            row_max_x.* = @min(row_max_x.*, span.min_x - 1);
        }
    } else {
        if (row_min_x.* >= span.min_x and row_min_x.* <= span.max_x) {
            row_min_x.* = @max(row_min_x.*, span.max_x + 1);
        }
    }
}

fn drawBackground() void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        const t = @divTrunc(y * 255, @as(i32, @intCast(RENDER_H - 1)));
        const floor_fade = if (y >= FLOOR_Y) clampI32(170 - @divTrunc((y - FLOOR_Y) * 2, RETINA_SCALE), 0, 170) else 0;
        var x: i32 = 0;
        var out_idx = (@as(usize, @intCast(y)) * RENDER_W) * 4;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 1) {
            const cx = absI32(x - CENTER_X);
            const vignette = clampI32(@divTrunc(cx * 85, CENTER_X) + @divTrunc(absI32(y - 198 * RETINA_SCALE) * 34, 240 * RETINA_SCALE), 0, 105);
            const glow = clampI32(78 - @divTrunc(cx, 6 * RETINA_SCALE) - @divTrunc(absI32(y - 156 * RETINA_SCALE), 5 * RETINA_SCALE), 0, 78);
            var r = clampI32(6 + @divTrunc(t, 18) + @divTrunc(glow, 5) - @divTrunc(vignette, 6), 0, 255);
            var g = clampI32(7 + @divTrunc(t, 20) + @divTrunc(glow, 4) - @divTrunc(vignette, 6), 0, 255);
            var b = clampI32(10 + @divTrunc(t, 12) + @divTrunc(glow, 2) - @divTrunc(vignette, 4), 0, 255);
            if (floor_fade > 0) {
                const keep = 255 - floor_fade;
                r = @divTrunc(r * keep, 255);
                g = @divTrunc(g * keep, 255);
                b = @divTrunc(b * keep, 255);
            }
            pixel_buf[out_idx + 0] = @as(u8, @intCast(r));
            pixel_buf[out_idx + 1] = @as(u8, @intCast(g));
            pixel_buf[out_idx + 2] = @as(u8, @intCast(b));
            pixel_buf[out_idx + 3] = 0xFF;
            out_idx += 4;
        }
    }

    blendRect(0, FLOOR_Y - RETINA_SCALE, @as(i32, @intCast(RENDER_W)), RETINA_SCALE, .{ 0xC6, 0xD6, 0xEA, 0x30 });
    drawFloorShine();
}

fn drawFloorShine() void {
    var y: i32 = FLOOR_Y;
    while (y < FLOOR_Y + 64 * RETINA_SCALE) : (y += 1) {
        const row_alpha = clampI32(42 - @divTrunc(y - FLOOR_Y, RETINA_SCALE), 0, 42);
        var x: i32 = 63 * RETINA_SCALE;
        while (x < @as(i32, @intCast(RENDER_W)) - 63 * RETINA_SCALE) : (x += 1) {
            const dx = absI32(x - CENTER_X);
            const a = clampI32(row_alpha - @divTrunc(dx, 15 * RETINA_SCALE), 0, 42);
            if (a > 0) blendPixelUnchecked(x, y, .{ 0xD8, 0xE9, 0xFF, @as(u8, @intCast(a)) });
        }
    }
}

fn buildFrameCovers(nearest: i32, covers: *[MAX_ALBUMS]FrameCover, valid: *[MAX_ALBUMS]bool) void {
    var pass: i32 = -5;
    while (pass <= 5) : (pass += 1) {
        const idx = nearest + pass;
        if (idx < 0 or idx >= @as(i32, @intCast(albums.len))) continue;
        const slot = @as(usize, @intCast(idx));
        covers[slot] = buildFrameCover(idx);
        valid[slot] = true;
    }
}

fn buildFrameCover(index: i32) FrameCover {
    const pose = coverPose(index);
    const q = pose.q;
    const delta_q8 = index * 256 - selected_q8;
    const dist = absI32(delta_q8);
    return .{
        .index = index,
        .q = q,
        .reflection_q = reflectQuad(q),
        .dist = dist,
        .side_dark = clampI32(@divTrunc(dist, 9), 0, 72),
        .light_boost = if (!featureEnabled(FEATURE_LIGHTING)) 0 else lightingBoost(pose.normal),
        .reflection_alpha = @as(u8, @intCast(clampI32(88 - @divTrunc(dist, 12), 14, 84))),
    };
}

fn drawReflections(nearest: i32, covers: *const [MAX_ALBUMS]FrameCover, valid: *const [MAX_ALBUMS]bool) void {
    var pass: i32 = 5;
    while (pass >= -5) : (pass -= 1) {
        const idx = nearest + pass;
        if (idx < 0 or idx >= @as(i32, @intCast(albums.len))) continue;
        const slot = @as(usize, @intCast(idx));
        if (valid[slot]) drawAlbumPrepared(true, covers[slot]);
    }
}

fn drawAlbums(nearest: i32, covers: *const [MAX_ALBUMS]FrameCover, valid: *const [MAX_ALBUMS]bool) void {
    var pass: i32 = 5;
    while (pass >= 1) : (pass -= 1) {
        const left = nearest - pass;
        if (left >= 0) {
            const slot = @as(usize, @intCast(left));
            if (valid[slot]) drawAlbumPrepared(false, covers[slot]);
        }
        const right = nearest + pass;
        if (right < @as(i32, @intCast(albums.len))) {
            const slot = @as(usize, @intCast(right));
            if (valid[slot]) drawAlbumPrepared(false, covers[slot]);
        }
    }
    if (nearest >= 0 and nearest < @as(i32, @intCast(albums.len))) {
        const slot = @as(usize, @intCast(nearest));
        if (valid[slot]) drawAlbumPrepared(false, covers[slot]);
    }
}

fn drawAlbumPrepared(comptime reflection: bool, cover: FrameCover) void {
    const q = if (reflection) cover.reflection_q else cover.q;
    const light_boost = if (reflection) 0 else cover.light_boost;
    const alpha: u8 = if (reflection) cover.reflection_alpha else 0xFF;
    if (!reflection) {
        drawSoftShadow(q);
    }
    drawTexturedQuad(reflection, q, @as(usize, @intCast(cover.index)), cover.side_dark, light_boost, alpha);
    if (!reflection) {
        drawSpecular(q, cover.dist);
    }
}

fn coverQuad(comptime reflection: bool, index: i32) Quad {
    const q = coverPose(index).q;
    return if (reflection) reflectQuad(q) else q;
}

fn coverPose(index: i32) CoverPose {
    const d_q8 = index * 256 - selected_q8;
    const rel = @as(f32, @floatFromInt(d_q8)) / 256.0;
    const ad = absF32(rel);
    const sign: f32 = if (rel < 0) -1.0 else 1.0;
    const turn = smoothstep(0.18, 0.82, ad);
    const yaw = sign * (turn * 1.08 + (1.0 - turn) * rel * 0.18);
    const cos_y = @cos(yaw);
    const sin_y = @sin(yaw);
    const center_push = rel * 60.0 * @as(f32, @floatFromInt(RETINA_SCALE));
    const side_push = sign * (126.0 + (ad - 1.0) * 86.0) * @as(f32, @floatFromInt(RETINA_SCALE));
    const x_push = lerpF32(center_push, side_push, turn);
    const x_world = clampF32(x_push, -500.0 * @as(f32, @floatFromInt(RETINA_SCALE)), 500.0 * @as(f32, @floatFromInt(RETINA_SCALE)));
    const z_world = clampF32(ad * 51.0 * @as(f32, @floatFromInt(RETINA_SCALE)), 0.0, 270.0 * @as(f32, @floatFromInt(RETINA_SCALE)));
    const y_center = 171.0 * @as(f32, @floatFromInt(RETINA_SCALE)) + clampF32(ad * 6.0 * @as(f32, @floatFromInt(RETINA_SCALE)), 0.0, 36.0 * @as(f32, @floatFromInt(RETINA_SCALE)));
    const half = @as(f32, @floatFromInt(COVER)) * (1.0 - clampF32(ad * 0.025, 0.0, 0.12)) * 0.5;
    return .{
        .q = .{
            .tl = projectCoverCorner(-half, -half, x_world, y_center, z_world, cos_y, sin_y),
            .tr = projectCoverCorner(half, -half, x_world, y_center, z_world, cos_y, sin_y),
            .br = projectCoverCorner(half, half, x_world, y_center, z_world, cos_y, sin_y),
            .bl = projectCoverCorner(-half, half, x_world, y_center, z_world, cos_y, sin_y),
        },
        .normal = .{ .x = sin_y, .y = 0.0, .z = cos_y },
    };
}

fn projectCoverCorner(local_x: f32, local_y: f32, x_world: f32, y_center: f32, z_world: f32, cos_y: f32, sin_y: f32) Point {
    const rotated_x = local_x * cos_y;
    const rotated_z = -local_x * sin_y;
    const z = z_world + rotated_z;
    const perspective = (780.0 * @as(f32, @floatFromInt(RETINA_SCALE))) / (780.0 * @as(f32, @floatFromInt(RETINA_SCALE)) + z);
    return .{
        .x = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(CENTER_X)) + (x_world + rotated_x) * perspective))),
        .y = @as(i32, @intFromFloat(@round(y_center + local_y * perspective))),
    };
}

fn reflectQuad(q: Quad) Quad {
    const gap = 4 * RETINA_SCALE;
    return .{
        .tl = .{ .x = q.bl.x, .y = FLOOR_Y + gap },
        .tr = .{ .x = q.br.x, .y = FLOOR_Y + gap },
        .br = .{ .x = q.tr.x, .y = FLOOR_Y + gap + @divTrunc((q.br.y - q.tr.y) * 3, 4) },
        .bl = .{ .x = q.tl.x, .y = FLOOR_Y + gap + @divTrunc((q.bl.y - q.tl.y) * 3, 4) },
    };
}

noinline fn drawTexturedQuad(comptime reflection: bool, q: Quad, album_idx: usize, darken: i32, light_boost: i32, alpha: u8) void {
    switch (feature_mask & (FEATURE_BILINEAR | FEATURE_ANTIALIAS)) {
        0 => drawTexturedQuadMode(reflection, false, false, q, album_idx, darken, light_boost, alpha),
        FEATURE_BILINEAR => drawTexturedQuadMode(reflection, true, false, q, album_idx, darken, light_boost, alpha),
        FEATURE_ANTIALIAS => drawTexturedQuadMode(reflection, false, true, q, album_idx, darken, light_boost, alpha),
        FEATURE_BILINEAR | FEATURE_ANTIALIAS => drawTexturedQuadMode(reflection, true, true, q, album_idx, darken, light_boost, alpha),
        else => unreachable,
    }
}

fn drawTexturedQuadMode(comptime reflection: bool, comptime use_bilinear: bool, comptime use_antialias: bool, q: Quad, album_idx: usize, darken: i32, light_boost: i32, alpha: u8) void {
    const inv = inverseHomography(q) orelse return;
    const edges: QuadEdges = if (use_bilinear and use_antialias) makeQuadEdges(q) else undefined;
    const min_x = clampI32(min4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, @as(i32, @intCast(RENDER_W)) - 1);
    const max_x = clampI32(max4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, @as(i32, @intCast(RENDER_W)) - 1);
    const min_y = clampI32(min4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, @as(i32, @intCast(RENDER_H)) - 1);
    const max_y = clampI32(max4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, @as(i32, @intCast(RENDER_H)) - 1);
    if (use_bilinear and use_antialias) buildProjectXCache(inv, min_x, max_x);
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const yf = @as(f32, @floatFromInt(y)) + 0.5;
        const row_u_y = inv.m01 * yf;
        const row_v_y = inv.m11 * yf;
        const row_d_y = inv.m21 * yf;
        const row_fade = if (reflection) clampI32(@as(i32, alpha) - @divTrunc((y - FLOOR_Y) * 3, 2), 0, @as(i32, alpha)) else 0;
        if (reflection and row_fade <= 0) continue;
        var row_min_x = min_x;
        var row_max_x = max_x;
        if (!reflection) {
            clipCoverRowToVisibleX(album_idx, y, &row_min_x, &row_max_x);
            if (row_min_x > row_max_x) continue;
        }
        var x = row_min_x;
        if (use_bilinear and use_antialias) {
            const full_span = rowFullCoverageSpan(edges, y, row_min_x, row_max_x);
            const full_start = firstBatchXAtOrAfter(row_min_x, full_span.min_x);
            const full_end = lastBatchXAtOrBefore(row_min_x, @min(full_span.max_x - 3, row_max_x - 3));

            while (x + 3 <= row_max_x and x < full_start) : (x += 4) {
                drawTexturedQuadBatch4BilinearAA(reflection, edges, inv, row_u_y, row_v_y, row_d_y, x, y, album_idx, darken, light_boost, alpha, row_fade);
            }
            while (x <= full_end) : (x += 4) {
                drawTexturedQuadBatch4BilinearFullCached(reflection, inv, row_v_y, x, y, album_idx, darken, light_boost, row_fade);
            }
            while (x + 3 <= row_max_x) : (x += 4) {
                drawTexturedQuadBatch4BilinearAA(reflection, edges, inv, row_u_y, row_v_y, row_d_y, x, y, album_idx, darken, light_boost, alpha, row_fade);
            }
        } else {
            while (x + 3 <= row_max_x) : (x += 4) {
                if (!reflection and use_bilinear and !use_antialias and alpha == 0xFF) {
                    drawTexturedQuadBatch4OpaqueNoAA(use_bilinear, inv, x, y, album_idx, darken, light_boost);
                } else {
                    drawTexturedQuadBatch4(reflection, use_bilinear, use_antialias, inv, x, y, album_idx, darken, light_boost, alpha);
                }
            }
        }
        while (x <= row_max_x) : (x += 1) {
            const uv = mapPoint(inv, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5) orelse continue;
            drawTexturedQuadMappedPixel(reflection, use_bilinear, use_antialias, inv, x, y, uv, album_idx, darken, light_boost, alpha);
        }
    }
}

fn buildProjectXCache(inv: Matrix3, min_x: i32, max_x: i32) void {
    var x = min_x;
    while (x <= max_x) : (x += 1) {
        const xf = @as(f32, @floatFromInt(x)) + 0.5;
        const denom = (inv.m20 * xf + 0.0) + inv.m22;
        const u = ((inv.m00 * xf + 0.0) + inv.m02) / denom;
        const u_f = clampF32(u, 0.0, 1.0) * 255.0;
        const idx = @as(usize, @intCast(x));
        project_u_f[idx] = u_f;
        project_v_x[idx] = inv.m10 * xf;
        project_inv_d[idx] = 1.0 / denom;
        project_u_mid[idx] = @as(i32, @intFromFloat(@round(u_f)));
    }
}

inline fn firstBatchXAtOrAfter(min_x: i32, lower: i32) i32 {
    if (lower <= min_x) return min_x;
    return min_x + @divTrunc(lower - min_x + 3, 4) * 4;
}

inline fn lastBatchXAtOrBefore(min_x: i32, upper: i32) i32 {
    if (upper < min_x) return min_x - 4;
    return min_x + @divTrunc(upper - min_x, 4) * 4;
}

inline fn drawTexturedQuadBatch4OpaqueNoAA(comptime use_bilinear: bool, inv: Matrix3, x: i32, y: i32, album_idx: usize, darken: i32, light_boost: i32) void {
    const xf: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const yf: f32 = @as(f32, @floatFromInt(y)) + 0.5;
    const xs: Vec4f = .{ xf, xf + 1.0, xf + 2.0, xf + 3.0 };
    const ys: Vec4f = @splat(yf);
    const denom = @as(Vec4f, @splat(inv.m20)) * xs + @as(Vec4f, @splat(inv.m21)) * ys + @as(Vec4f, @splat(inv.m22));
    const us = (@as(Vec4f, @splat(inv.m00)) * xs + @as(Vec4f, @splat(inv.m01)) * ys + @as(Vec4f, @splat(inv.m02))) / denom;
    const vs = (@as(Vec4f, @splat(inv.m10)) * xs + @as(Vec4f, @splat(inv.m11)) * ys + @as(Vec4f, @splat(inv.m12))) / denom;
    var all_valid = true;
    inline for (0..4) |lane| {
        const u = us[lane];
        const v = vs[lane];
        if (!(absF32(denom[lane]) >= 0.0001 and u >= -0.002 and u <= 1.002 and v >= -0.002 and v <= 1.002)) {
            all_valid = false;
        }
    }
    if (!all_valid) {
        drawTexturedQuadBatch4(false, use_bilinear, false, inv, x, y, album_idx, darken, light_boost, 0xFF);
        return;
    }

    const zero: Vec4f = @splat(0.0);
    const one: Vec4f = @splat(1.0);
    const tex_max: Vec4f = @splat(255.0);
    const u_f = @min(@max(us, zero), one) * tex_max;
    const v_f = @min(@max(vs, zero), one) * tex_max;
    const u_mid: Vec4i = @intFromFloat(@round(u_f));
    var out: [4]Color = undefined;
    if (use_bilinear) {
        const colors = sampleCoverBilinearBatch4(album_idx, u_f, v_f);
        inline for (0..4) |lane| {
            const c: Color = .{
                @as(u8, @intCast(colors.r[lane])),
                @as(u8, @intCast(colors.g[lane])),
                @as(u8, @intCast(colors.b[lane])),
                0xFF,
            };
            out[lane] = shadeAndBrightenOpaque(c, u_mid[lane], darken, light_boost);
        }
    } else {
        inline for (0..4) |lane| {
            const c = sampleCoverNearest(album_idx, u_f[lane], v_f[lane]);
            out[lane] = shadeAndBrightenOpaque(c, u_mid[lane], darken, light_boost);
        }
    }
    setPixel4OpaqueUnchecked(x, y, out);
}

inline fn drawTexturedQuadBatch4BilinearFull(comptime reflection: bool, inv: Matrix3, row_u_y: f32, row_v_y: f32, row_d_y: f32, x: i32, y: i32, album_idx: usize, darken: i32, light_boost: i32, row_fade: i32) void {
    const xf: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const xs: Vec4f = .{ xf, xf + 1.0, xf + 2.0, xf + 3.0 };
    const denom = (@as(Vec4f, @splat(inv.m20)) * xs + @as(Vec4f, @splat(row_d_y))) + @as(Vec4f, @splat(inv.m22));
    const us = ((@as(Vec4f, @splat(inv.m00)) * xs + @as(Vec4f, @splat(row_u_y))) + @as(Vec4f, @splat(inv.m02))) / denom;
    const vs = ((@as(Vec4f, @splat(inv.m10)) * xs + @as(Vec4f, @splat(row_v_y))) + @as(Vec4f, @splat(inv.m12))) / denom;
    const zero: Vec4f = @splat(0.0);
    const one: Vec4f = @splat(1.0);
    const tex_max: Vec4f = @splat(255.0);
    const u_f = @min(@max(us, zero), one) * tex_max;
    const v_f_raw = @min(@max(vs, zero), one) * tex_max;
    const v_f = if (reflection) tex_max - v_f_raw else v_f_raw;
    const colors = sampleCoverBilinearBatch4(album_idx, u_f, v_f);
    const u_mid: Vec4i = @intFromFloat(@round(u_f));

    if (reflection) {
        const fade = row_fade;
        if (fade <= 0) return;
        blendReflectionPackedBatch4(x, y, colors, u_mid, darken, fade);
    } else {
        const out = shadeAndBrightenPackedOpaqueBatch4(colors, u_mid, darken, light_boost);
        setPixel4PackedOpaqueUnchecked(x, y, out);
    }
}

inline fn drawTexturedQuadBatch4BilinearFullCached(comptime reflection: bool, inv: Matrix3, row_v_y: f32, x: i32, y: i32, album_idx: usize, darken: i32, light_boost: i32, row_fade: i32) void {
    const idx = @as(usize, @intCast(x));
    const u_f: Vec4f = .{
        project_u_f[idx],
        project_u_f[idx + 1],
        project_u_f[idx + 2],
        project_u_f[idx + 3],
    };
    const v_x: Vec4f = .{
        project_v_x[idx],
        project_v_x[idx + 1],
        project_v_x[idx + 2],
        project_v_x[idx + 3],
    };
    const inv_d: Vec4f = .{
        project_inv_d[idx],
        project_inv_d[idx + 1],
        project_inv_d[idx + 2],
        project_inv_d[idx + 3],
    };
    const vs = ((v_x + @as(Vec4f, @splat(row_v_y))) + @as(Vec4f, @splat(inv.m12))) * inv_d;
    const zero: Vec4f = @splat(0.0);
    const one: Vec4f = @splat(1.0);
    const tex_max: Vec4f = @splat(255.0);
    const v_f_raw = @min(@max(vs, zero), one) * tex_max;
    const v_f = if (reflection) tex_max - v_f_raw else v_f_raw;
    const colors = sampleCoverBilinearBatch4(album_idx, u_f, v_f);
    const u_mid: Vec4i = .{
        project_u_mid[idx],
        project_u_mid[idx + 1],
        project_u_mid[idx + 2],
        project_u_mid[idx + 3],
    };

    if (reflection) {
        const fade = row_fade;
        if (fade <= 0) return;
        blendReflectionPackedBatch4(x, y, colors, u_mid, darken, fade);
    } else {
        const out = shadeAndBrightenPackedOpaqueBatch4(colors, u_mid, darken, light_boost);
        setPixel4PackedOpaqueUnchecked(x, y, out);
    }
}

inline fn drawTexturedQuadBatch4BilinearAA(comptime reflection: bool, edges: QuadEdges, inv: Matrix3, row_u_y: f32, row_v_y: f32, row_d_y: f32, x: i32, y: i32, album_idx: usize, darken: i32, light_boost: i32, alpha: u8, row_fade: i32) void {
    const full_coverage = quadCoverageBatch4EdgesAllFull(edges, x, y);
    const coverage: Vec4i = if (full_coverage) @splat(4) else quadCoverageBatch4Edges(edges, x, y);
    if (coverage[0] == 0 and coverage[1] == 0 and coverage[2] == 0 and coverage[3] == 0) return;

    const xf: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const xs: Vec4f = .{ xf, xf + 1.0, xf + 2.0, xf + 3.0 };
    const denom = (@as(Vec4f, @splat(inv.m20)) * xs + @as(Vec4f, @splat(row_d_y))) + @as(Vec4f, @splat(inv.m22));
    const us = ((@as(Vec4f, @splat(inv.m00)) * xs + @as(Vec4f, @splat(row_u_y))) + @as(Vec4f, @splat(inv.m02))) / denom;
    const vs = ((@as(Vec4f, @splat(inv.m10)) * xs + @as(Vec4f, @splat(row_v_y))) + @as(Vec4f, @splat(inv.m12))) / denom;
    const zero: Vec4f = @splat(0.0);
    const one: Vec4f = @splat(1.0);
    const tex_max: Vec4f = @splat(255.0);
    const u_f = @min(@max(us, zero), one) * tex_max;
    const v_f_raw = @min(@max(vs, zero), one) * tex_max;
    const v_f = if (reflection) tex_max - v_f_raw else v_f_raw;
    const colors = sampleCoverBilinearBatch4(album_idx, u_f, v_f);
    const u_mid: Vec4i = @intFromFloat(@round(u_f));

    if (reflection and coverage[0] == 4 and coverage[1] == 4 and coverage[2] == 4 and coverage[3] == 4) {
        const fade = row_fade;
        if (fade <= 0) return;
        blendReflectionPackedBatch4(x, y, colors, u_mid, darken, fade);
        return;
    }

    if (!reflection and alpha == 0xFF and coverage[0] == 4 and coverage[1] == 4 and coverage[2] == 4 and coverage[3] == 4) {
        const out = shadeAndBrightenPackedOpaqueBatch4(colors, u_mid, darken, light_boost);
        setPixel4PackedOpaqueUnchecked(x, y, out);
        return;
    }

    inline for (0..4) |lane| {
        const d = denom[lane];
        const u = us[lane];
        const v = vs[lane];
        if (absF32(d) >= 0.0001 and u >= -0.002 and u <= 1.002 and v >= -0.002 and v <= 1.002) {
            const c: Color = .{
                @as(u8, @intCast(colors.r[lane])),
                @as(u8, @intCast(colors.g[lane])),
                @as(u8, @intCast(colors.b[lane])),
                0xFF,
            };
            drawSampledPixelInsideKnownCoverage(reflection, x + @as(i32, @intCast(lane)), y, c, u_mid[lane], darken, light_boost, alpha, coverage[lane]);
        }
    }
}

inline fn drawTexturedQuadBatch4(comptime reflection: bool, comptime use_bilinear: bool, comptime use_antialias: bool, inv: Matrix3, x: i32, y: i32, album_idx: usize, darken: i32, light_boost: i32, alpha: u8) void {
    const xf: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const yf: f32 = @as(f32, @floatFromInt(y)) + 0.5;
    const xs: Vec4f = .{ xf, xf + 1.0, xf + 2.0, xf + 3.0 };
    const ys: Vec4f = @splat(yf);
    const denom = @as(Vec4f, @splat(inv.m20)) * xs + @as(Vec4f, @splat(inv.m21)) * ys + @as(Vec4f, @splat(inv.m22));
    const us = (@as(Vec4f, @splat(inv.m00)) * xs + @as(Vec4f, @splat(inv.m01)) * ys + @as(Vec4f, @splat(inv.m02))) / denom;
    const vs = (@as(Vec4f, @splat(inv.m10)) * xs + @as(Vec4f, @splat(inv.m11)) * ys + @as(Vec4f, @splat(inv.m12))) / denom;

    inline for (0..4) |lane| {
        const d = denom[lane];
        if (absF32(d) >= 0.0001) {
            const uv = PointF{ .x = us[lane], .y = vs[lane] };
            drawTexturedQuadMappedPixel(reflection, use_bilinear, use_antialias, inv, x + @as(i32, @intCast(lane)), y, uv, album_idx, darken, light_boost, alpha);
        }
    }
}

inline fn drawTexturedQuadMappedPixel(comptime reflection: bool, comptime use_bilinear: bool, comptime use_antialias: bool, inv: Matrix3, x: i32, y: i32, uv: PointF, album_idx: usize, darken: i32, light_boost: i32, alpha: u8) void {
    if (uv.x < -0.002 or uv.x > 1.002 or uv.y < -0.002 or uv.y > 1.002) return;
    const coverage = if (use_antialias) quadCoverage(inv, x, y) else 4;
    drawTexturedQuadMappedPixelInsideKnownCoverage(reflection, use_bilinear, x, y, uv, album_idx, darken, light_boost, alpha, coverage);
}

inline fn drawTexturedQuadMappedPixelInsideKnownCoverage(comptime reflection: bool, comptime use_bilinear: bool, x: i32, y: i32, uv: PointF, album_idx: usize, darken: i32, light_boost: i32, alpha: u8, coverage: i32) void {
    if (coverage <= 0) return;
    const u_f = clampF32(uv.x, 0.0, 1.0) * 255.0;
    const v_f_raw = clampF32(uv.y, 0.0, 1.0) * 255.0;
    const v_f = if (reflection) 255.0 - v_f_raw else v_f_raw;
    const c = if (use_bilinear)
        sampleCoverBilinear(album_idx, u_f, v_f)
    else
        sampleCoverNearest(album_idx, u_f, v_f);
    const u_mid = @as(i32, @intFromFloat(@round(u_f)));
    drawSampledPixelInsideKnownCoverage(reflection, x, y, c, u_mid, darken, light_boost, alpha, coverage);
}

inline fn drawTexturedQuadPixelBilinearAA(comptime reflection: bool, edges: QuadEdges, inv: Matrix3, x: i32, y: i32, album_idx: usize, darken: i32, light_boost: i32, alpha: u8) void {
    const uv = mapPoint(inv, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5) orelse return;
    if (uv.x < -0.002 or uv.x > 1.002 or uv.y < -0.002 or uv.y > 1.002) return;
    const coverage = quadCoverageEdges(edges, x, y);
    if (coverage <= 0) return;
    const u_f = clampF32(uv.x, 0.0, 1.0) * 255.0;
    const v_f_raw = clampF32(uv.y, 0.0, 1.0) * 255.0;
    const v_f = if (reflection) 255.0 - v_f_raw else v_f_raw;
    const c = sampleCoverBilinear(album_idx, u_f, v_f);
    const u_mid = @as(i32, @intFromFloat(@round(u_f)));
    drawSampledPixelInsideKnownCoverage(reflection, x, y, c, u_mid, darken, light_boost, alpha, coverage);
}

inline fn shadeAndBrightenOpaque(c_in: Color, u_mid: i32, darken: i32, light_boost: i32) Color {
    return brightenColor(shadeOpaque(c_in, u_mid, darken), light_boost);
}

inline fn shadeAndBrightenPackedOpaqueBatch4(colors: ColorBatch, u_mid: Vec4i, darken: i32, light_boost: i32) [4]u32 {
    const zero: Vec4i = @splat(0);
    const mid: Vec4i = @splat(128);
    const centered = u_mid - mid;
    const abs_mid = @select(i32, centered < zero, -centered, centered);
    const shade = @as(Vec4i, @splat(darken)) + div11PositiveVec(abs_mid);
    const factor = @as(Vec4i, @splat(255)) - shade;
    var r = div255PositiveVec(colors.r * factor);
    var g = div255PositiveVec(colors.g * factor);
    var b = div255PositiveVec(colors.b * factor);
    const boost: Vec4i = @splat(light_boost);
    r += div100PositiveVec((@as(Vec4i, @splat(255)) - r) * boost);
    g += div100PositiveVec((@as(Vec4i, @splat(255)) - g) * boost);
    b += div100PositiveVec((@as(Vec4i, @splat(255)) - b) * boost);

    var out: [4]u32 = undefined;
    inline for (0..4) |lane| {
        out[lane] = packRGB(@intCast(r[lane]), @intCast(g[lane]), @intCast(b[lane]));
    }
    return out;
}

inline fn blendReflectionPackedBatch4(x: i32, y: i32, colors: ColorBatch, u_mid: Vec4i, darken: i32, fade: i32) void {
    const zero: Vec4i = @splat(0);
    const mid: Vec4i = @splat(128);
    const centered = u_mid - mid;
    const abs_mid = @select(i32, centered < zero, -centered, centered);
    const shade = @as(Vec4i, @splat(darken)) + div11PositiveVec(abs_mid);
    const factor = @as(Vec4i, @splat(255)) - shade;
    var src_r = div255PositiveVec(colors.r * factor);
    var src_g = div255PositiveVec(colors.g * factor);
    var src_b = div255PositiveVec(colors.b * factor);
    src_r = div255PositiveVec(src_r * @as(Vec4i, @splat(207)));
    src_g = div255PositiveVec(src_g * @as(Vec4i, @splat(207)));
    src_b = div255PositiveVec(src_b * @as(Vec4i, @splat(207)));

    var dst_r: Vec4i = undefined;
    var dst_g: Vec4i = undefined;
    var dst_b: Vec4i = undefined;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    inline for (0..4) |lane| {
        const p = std.mem.readInt(u32, pixel_buf[idx + lane * 4 ..][0..4], .little);
        dst_r[lane] = @intCast(p & 0xFF);
        dst_g[lane] = @intCast((p >> 8) & 0xFF);
        dst_b[lane] = @intCast((p >> 16) & 0xFF);
    }

    const fade_v: Vec4i = @splat(fade);
    const inv_v: Vec4i = @splat(255 - fade);
    const out_r = div255PositiveVec(dst_r * inv_v + src_r * fade_v);
    const out_g = div255PositiveVec(dst_g * inv_v + src_g * fade_v);
    const out_b = div255PositiveVec(dst_b * inv_v + src_b * fade_v);

    var out: [4]u32 = undefined;
    inline for (0..4) |lane| {
        out[lane] = packRGB(@intCast(out_r[lane]), @intCast(out_g[lane]), @intCast(out_b[lane]));
    }
    setPixel4PackedOpaqueUnchecked(x, y, out);
}

inline fn div255PositiveVec(v: Vec4i) Vec4i {
    const scaled = (v + @as(Vec4i, @splat(1))) * @as(Vec4i, @splat(257));
    return scaled >> @as(@Vector(4, u5), @splat(16));
}

inline fn div100PositiveVec(v: Vec4i) Vec4i {
    return (v * @as(Vec4i, @splat(5243))) >> @as(@Vector(4, u5), @splat(19));
}

inline fn div11PositiveVec(v: Vec4i) Vec4i {
    return (v * @as(Vec4i, @splat(187))) >> @as(@Vector(4, u5), @splat(11));
}

inline fn shadeOpaque(c_in: Color, u_mid: i32, darken: i32) Color {
    const shade = darken + @divTrunc(absI32(u_mid - 128), 11);
    return shadeColor(c_in, shade);
}

inline fn drawSampledPixelInsideKnownCoverage(comptime reflection: bool, x: i32, y: i32, c_in: Color, u_mid: i32, darken: i32, light_boost: i32, alpha: u8, coverage: i32) void {
    if (coverage <= 0) return;
    if (reflection) {
        var c = shadeOpaque(c_in, u_mid, darken);
        const fade = clampI32(@as(i32, alpha) - @divTrunc((y - FLOOR_Y) * 3, 2), 0, @as(i32, alpha));
        c[3] = @as(u8, @intCast(@divTrunc(fade * coverage, 4)));
        c = shadeColor(c, 48);
        blendPixelUnchecked(x, y, c);
    } else {
        var c = shadeAndBrightenOpaque(c_in, u_mid, darken, light_boost);
        if (alpha == 0xFF and coverage == 4) {
            setPixelOpaqueUnchecked(x, y, c);
        } else {
            c[3] = @as(u8, @intCast(@divTrunc(@as(i32, alpha) * coverage, 4)));
            blendPixelUnchecked(x, y, c);
        }
    }
}

fn rowFullCoverageSpan(edges: QuadEdges, y: i32, min_x: i32, max_x: i32) RowFullCoverageSpan {
    var lo: f32 = -1000000.0;
    var hi: f32 = 1000000.0;
    if (!constrainFullCoverageX(edges.top, y, &lo, &hi) or
        !constrainFullCoverageX(edges.right, y, &lo, &hi) or
        !constrainFullCoverageX(edges.bottom, y, &lo, &hi) or
        !constrainFullCoverageX(edges.left, y, &lo, &hi))
    {
        return .{ .min_x = 1, .max_x = 0 };
    }

    const start = clampI32(@as(i32, @intFromFloat(@ceil(lo + 0.001))), min_x, max_x);
    const end = clampI32(@as(i32, @intFromFloat(@floor(hi - 0.001))), min_x, max_x);
    if (start > end) return .{ .min_x = 1, .max_x = 0 };
    return .{ .min_x = start, .max_x = end };
}

inline fn constrainFullCoverageX(edge: EdgeEquation, y: i32, lo: *f32, hi: *f32) bool {
    const yf = @as(f32, @floatFromInt(y));
    const sample_off: f32 = if (edge.y >= 0.0) 0.25 else 0.75;
    const sample_y = yf + sample_off;
    const row_term = edge.y * sample_y + edge.c;
    if (absF32(edge.x) < 0.0001) return row_term >= 0.0;

    if (edge.x > 0.0) {
        const bound = (-row_term / edge.x) - 0.25;
        if (bound > lo.*) lo.* = bound;
    } else {
        const bound = (-row_term / edge.x) - 0.75;
        if (bound < hi.*) hi.* = bound;
    }
    return lo.* <= hi.*;
}

fn quadCoverageBatch4EdgesAllFull(edges: QuadEdges, x: i32, y: i32) bool {
    const xf = @as(f32, @floatFromInt(x));
    const yf = @as(f32, @floatFromInt(y));
    const x0 = xf + 0.25;
    const x1 = xf + 3.75;
    const y0 = yf + 0.25;
    const y1 = yf + 0.75;
    return edgeBoxInside(edges.top, x0, x1, y0, y1) and
        edgeBoxInside(edges.right, x0, x1, y0, y1) and
        edgeBoxInside(edges.bottom, x0, x1, y0, y1) and
        edgeBoxInside(edges.left, x0, x1, y0, y1);
}

inline fn edgeBoxInside(edge: EdgeEquation, x0: f32, x1: f32, y0: f32, y1: f32) bool {
    const min_x = if (edge.x >= 0.0) x0 else x1;
    const min_y = if (edge.y >= 0.0) y0 else y1;
    return edgeContains(edge, min_x, min_y);
}

fn quadCoverageBatch4Edges(edges: QuadEdges, x: i32, y: i32) Vec4i {
    const xf = @as(f32, @floatFromInt(x));
    const yf = @as(f32, @floatFromInt(y));
    const base_xs: Vec4f = .{ xf, xf + 1.0, xf + 2.0, xf + 3.0 };
    const yes: Vec4i = @splat(1);
    const no: Vec4i = @splat(0);
    var covered: Vec4i = @splat(0);

    inline for (0..4) |sub| {
        const ox: f32 = if ((sub & 1) == 0) 0.25 else 0.75;
        const oy: f32 = if ((sub & 2) == 0) 0.25 else 0.75;
        const xs = base_xs + @as(Vec4f, @splat(ox));
        const ys: Vec4f = @splat(yf + oy);
        const inside = edgeMask(edges.top, xs, ys) &
            edgeMask(edges.right, xs, ys) &
            edgeMask(edges.bottom, xs, ys) &
            edgeMask(edges.left, xs, ys);
        covered += @select(i32, inside, yes, no);
    }
    return covered;
}

fn quadCoverageEdges(edges: QuadEdges, x: i32, y: i32) i32 {
    const xf = @as(f32, @floatFromInt(x));
    const yf = @as(f32, @floatFromInt(y));
    var covered: i32 = 0;

    inline for (0..4) |sub| {
        const sx = xf + if ((sub & 1) == 0) 0.25 else 0.75;
        const sy = yf + if ((sub & 2) == 0) 0.25 else 0.75;
        if (edgeContains(edges.top, sx, sy) and
            edgeContains(edges.right, sx, sy) and
            edgeContains(edges.bottom, sx, sy) and
            edgeContains(edges.left, sx, sy))
        {
            covered += 1;
        }
    }
    return covered;
}

fn quadCoverage(inv: Matrix3, x: i32, y: i32) i32 {
    const xf = @as(f32, @floatFromInt(x));
    const yf = @as(f32, @floatFromInt(y));
    const xs: Vec4f = .{ xf + 0.25, xf + 0.75, xf + 0.25, xf + 0.75 };
    const ys: Vec4f = .{ yf + 0.25, yf + 0.25, yf + 0.75, yf + 0.75 };
    const denom = @as(Vec4f, @splat(inv.m20)) * xs + @as(Vec4f, @splat(inv.m21)) * ys + @as(Vec4f, @splat(inv.m22));
    const us = (@as(Vec4f, @splat(inv.m00)) * xs + @as(Vec4f, @splat(inv.m01)) * ys + @as(Vec4f, @splat(inv.m02))) / denom;
    const vs = (@as(Vec4f, @splat(inv.m10)) * xs + @as(Vec4f, @splat(inv.m11)) * ys + @as(Vec4f, @splat(inv.m12))) / denom;
    var covered: i32 = 0;
    inline for (0..4) |lane| {
        if (absF32(denom[lane]) >= 0.0001 and us[lane] >= 0.0 and us[lane] <= 1.0 and vs[lane] >= 0.0 and vs[lane] <= 1.0) covered += 1;
    }
    return covered;
}

fn makeQuadEdges(q: Quad) QuadEdges {
    const sign: f32 = if (quadSignedArea(q) >= 0.0) 1.0 else -1.0;
    return .{
        .top = makeEdgeEquation(q.tl, q.tr, sign),
        .right = makeEdgeEquation(q.tr, q.br, sign),
        .bottom = makeEdgeEquation(q.br, q.bl, sign),
        .left = makeEdgeEquation(q.bl, q.tl, sign),
    };
}

inline fn makeEdgeEquation(a: Point, b: Point, sign: f32) EdgeEquation {
    const ax = @as(f32, @floatFromInt(a.x));
    const ay = @as(f32, @floatFromInt(a.y));
    const bx = @as(f32, @floatFromInt(b.x));
    const by = @as(f32, @floatFromInt(b.y));
    const edge_x = bx - ax;
    const edge_y = by - ay;
    return .{
        .x = -edge_y * sign,
        .y = edge_x * sign,
        .c = (edge_y * ax - edge_x * ay) * sign,
    };
}

inline fn edgeMask(edge: EdgeEquation, xs: Vec4f, ys: Vec4f) @Vector(4, bool) {
    const value = @as(Vec4f, @splat(edge.x)) * xs + @as(Vec4f, @splat(edge.y)) * ys + @as(Vec4f, @splat(edge.c));
    return value >= @as(Vec4f, @splat(0.0));
}

inline fn edgeContains(edge: EdgeEquation, x: f32, y: f32) bool {
    return edge.x * x + edge.y * y + edge.c >= 0.0;
}

fn quadSignedArea(q: Quad) f32 {
    const x0 = @as(f32, @floatFromInt(q.tl.x));
    const y0 = @as(f32, @floatFromInt(q.tl.y));
    const x1 = @as(f32, @floatFromInt(q.tr.x));
    const y1 = @as(f32, @floatFromInt(q.tr.y));
    const x2 = @as(f32, @floatFromInt(q.br.x));
    const y2 = @as(f32, @floatFromInt(q.br.y));
    const x3 = @as(f32, @floatFromInt(q.bl.x));
    const y3 = @as(f32, @floatFromInt(q.bl.y));
    return x0 * y1 - y0 * x1 +
        x1 * y2 - y1 * x2 +
        x2 * y3 - y2 * x3 +
        x3 * y0 - y3 * x0;
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

fn featureEnabled(feature: u32) bool {
    return (feature_mask & feature) != 0;
}

fn toggleFeature(feature: u32) void {
    feature_mask ^= feature;
    velocity_q8 = 0;
    spring_velocity_q8 = 0;
}

inline fn coverTexelIndexUnchecked(album_idx: usize, u: usize, v: usize) usize {
    return album_idx * COVER_TEXELS_PER_ALBUM + (v << COVER_TEX_SHIFT) + u;
}

inline fn sampleCoverTexelUnchecked(album_idx: usize, u: usize, v: usize) Color {
    return unpackPixel(sampleCoverPackedTexelUnchecked(album_idx, u, v));
}

inline fn sampleCoverPackedTexelUnchecked(album_idx: usize, u: usize, v: usize) u32 {
    return cover_texels[0..][coverTexelIndexUnchecked(album_idx, u, v)];
}

inline fn sampleCoverNearest(album_idx: usize, u_f: f32, v_f: f32) Color {
    const u: usize = @intCast(@as(i32, @intFromFloat(@round(u_f))));
    const v: usize = @intCast(@as(i32, @intFromFloat(@round(v_f))));
    return sampleCoverTexelUnchecked(album_idx, u, v);
}

inline fn sampleCoverBilinear(album_idx: usize, u_f: f32, v_f: f32) Color {
    const ux0 = clampI32(@as(i32, @intFromFloat(@floor(u_f))), 0, COVER_TEX_COORD_MAX);
    const vy0 = clampI32(@as(i32, @intFromFloat(@floor(v_f))), 0, COVER_TEX_COORD_MAX);
    const ux1 = @min(ux0 + 1, COVER_TEX_COORD_MAX);
    const vy1 = @min(vy0 + 1, COVER_TEX_COORD_MAX);
    const tx = u_f - @as(f32, @floatFromInt(ux0));
    const ty = v_f - @as(f32, @floatFromInt(vy0));

    const x0: usize = @intCast(ux0);
    const y0: usize = @intCast(vy0);
    const x1: usize = @intCast(ux1);
    const y1: usize = @intCast(vy1);
    const c00 = sampleCoverTexelUnchecked(album_idx, x0, y0);
    const c10 = sampleCoverTexelUnchecked(album_idx, x1, y0);
    const c01 = sampleCoverTexelUnchecked(album_idx, x0, y1);
    const c11 = sampleCoverTexelUnchecked(album_idx, x1, y1);
    const top = lerpColorOpaqueF32(c00, c10, tx);
    const bottom = lerpColorOpaqueF32(c01, c11, tx);
    return lerpColorOpaqueF32(top, bottom, ty);
}

inline fn sampleCoverBilinearBatch4(album_idx: usize, u_f: Vec4f, v_f: Vec4f) ColorBatch {
    var tx: Vec4f = undefined;
    var ty: Vec4f = undefined;
    var r00: Vec4f = undefined;
    var g00: Vec4f = undefined;
    var b00: Vec4f = undefined;
    var r10: Vec4f = undefined;
    var g10: Vec4f = undefined;
    var b10: Vec4f = undefined;
    var r01: Vec4f = undefined;
    var g01: Vec4f = undefined;
    var b01: Vec4f = undefined;
    var r11: Vec4f = undefined;
    var g11: Vec4f = undefined;
    var b11: Vec4f = undefined;

    inline for (0..4) |lane| {
        const ux0 = clampI32(@as(i32, @intFromFloat(@floor(u_f[lane]))), 0, COVER_TEX_COORD_MAX);
        const vy0 = clampI32(@as(i32, @intFromFloat(@floor(v_f[lane]))), 0, COVER_TEX_COORD_MAX);
        const ux1 = @min(ux0 + 1, COVER_TEX_COORD_MAX);
        const vy1 = @min(vy0 + 1, COVER_TEX_COORD_MAX);
        tx[lane] = u_f[lane] - @as(f32, @floatFromInt(ux0));
        ty[lane] = v_f[lane] - @as(f32, @floatFromInt(vy0));

        const x0: usize = @intCast(ux0);
        const y0: usize = @intCast(vy0);
        const x1: usize = @intCast(ux1);
        const y1: usize = @intCast(vy1);
        const c00 = sampleCoverPackedTexelUnchecked(album_idx, x0, y0);
        const c10 = sampleCoverPackedTexelUnchecked(album_idx, x1, y0);
        const c01 = sampleCoverPackedTexelUnchecked(album_idx, x0, y1);
        const c11 = sampleCoverPackedTexelUnchecked(album_idx, x1, y1);
        r00[lane] = @floatFromInt(c00 & 0xFF);
        g00[lane] = @floatFromInt((c00 >> 8) & 0xFF);
        b00[lane] = @floatFromInt((c00 >> 16) & 0xFF);
        r10[lane] = @floatFromInt(c10 & 0xFF);
        g10[lane] = @floatFromInt((c10 >> 8) & 0xFF);
        b10[lane] = @floatFromInt((c10 >> 16) & 0xFF);
        r01[lane] = @floatFromInt(c01 & 0xFF);
        g01[lane] = @floatFromInt((c01 >> 8) & 0xFF);
        b01[lane] = @floatFromInt((c01 >> 16) & 0xFF);
        r11[lane] = @floatFromInt(c11 & 0xFF);
        g11[lane] = @floatFromInt((c11 >> 8) & 0xFF);
        b11[lane] = @floatFromInt((c11 >> 16) & 0xFF);
    }

    const top_r = @round(r00 + (r10 - r00) * tx);
    const top_g = @round(g00 + (g10 - g00) * tx);
    const top_b = @round(b00 + (b10 - b00) * tx);
    const bottom_r = @round(r01 + (r11 - r01) * tx);
    const bottom_g = @round(g01 + (g11 - g01) * tx);
    const bottom_b = @round(b01 + (b11 - b01) * tx);
    return .{
        .r = @intFromFloat(@round(top_r + (bottom_r - top_r) * ty)),
        .g = @intFromFloat(@round(top_g + (bottom_g - top_g) * ty)),
        .b = @intFromFloat(@round(top_b + (bottom_b - top_b) * ty)),
    };
}

fn sampleAlbumBilinearByIndex(album_idx: usize, u_f: f32, v_f: f32) Color {
    return switch (album_idx) {
        inline 0...albums.len - 1 => |idx| sampleAlbumBilinearStatic(idx, u_f, v_f),
        else => unreachable,
    };
}

fn sampleAlbumByIndex(album_idx: usize, u: i32, v: i32) Color {
    return switch (album_idx) {
        inline 0...albums.len - 1 => |idx| sampleAlbumStatic(idx, u, v),
        else => unreachable,
    };
}

fn sampleAlbumBilinearStatic(comptime album_idx: usize, u_f: f32, v_f: f32) Color {
    const ux0 = clampI32(@as(i32, @intFromFloat(@floor(u_f))), 0, 255);
    const vy0 = clampI32(@as(i32, @intFromFloat(@floor(v_f))), 0, 255);
    const ux1 = clampI32(ux0 + 1, 0, 255);
    const vy1 = clampI32(vy0 + 1, 0, 255);
    const tx = u_f - @as(f32, @floatFromInt(ux0));
    const ty = v_f - @as(f32, @floatFromInt(vy0));

    const c00 = sampleAlbumStatic(album_idx, ux0, vy0);
    const c10 = sampleAlbumStatic(album_idx, ux1, vy0);
    const c01 = sampleAlbumStatic(album_idx, ux0, vy1);
    const c11 = sampleAlbumStatic(album_idx, ux1, vy1);
    const top = lerpColorOpaqueF32(c00, c10, tx);
    const bottom = lerpColorOpaqueF32(c01, c11, tx);
    return lerpColorOpaqueF32(top, bottom, ty);
}

inline fn sampleAlbumStatic(comptime album_idx: usize, u: i32, v: i32) Color {
    const album = albums[album_idx];
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

fn lightingBoost(normal: Vec3) i32 {
    const light = normalize3(.{ .x = -0.42, .y = -0.22, .z = 0.88 });
    const facing = clampF32(dot3(normal, .{ .x = 0.0, .y = 0.0, .z = 1.0 }), 0.0, 1.0);
    const diffuse = clampF32(dot3(normal, light), 0.0, 1.0);
    const rim = clampF32(1.0 - facing, 0.0, 1.0);
    return @as(i32, @intFromFloat(@round(diffuse * 34.0 + rim * 18.0)));
}

fn drawSoftShadow(q: Quad) void {
    const x0 = min4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
    const x1 = max4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
    const y = FLOOR_Y - 1;
    var yy: i32 = y - 10 * RETINA_SCALE;
    while (yy <= y + 10 * RETINA_SCALE) : (yy += 1) {
        var x: i32 = x0 - 12 * RETINA_SCALE;
        while (x <= x1 + 12 * RETINA_SCALE) : (x += 1) {
            const cx = if (x < x0) x0 - x else if (x > x1) x - x1 else 0;
            const cy = absI32(yy - y);
            const a = clampI32(42 - @divTrunc(cx * 2, RETINA_SCALE) - @divTrunc(cy * 4, RETINA_SCALE), 0, 42);
            if (a > 0) blendPixel(x, yy, .{ 0, 0, 0, @as(u8, @intCast(a)) });
        }
    }
}

fn drawSpecular(q: Quad, dist: i32) void {
    const a = @as(u8, @intCast(clampI32(84 - @divTrunc(dist, 5), 18, 84)));
    const y0 = lerpI32(q.tl.y, q.bl.y, 38);
    const y1 = lerpI32(q.tr.y, q.br.y, 38);
    drawLine(q.tl.x + 8 * RETINA_SCALE, y0, q.tr.x - 8 * RETINA_SCALE, y1, .{ 0xFF, 0xFF, 0xFF, a });
    drawLine(q.tl.x + 8 * RETINA_SCALE, y0 + 1, q.tr.x - 8 * RETINA_SCALE, y1 + 1, .{ 0xFF, 0xFF, 0xFF, @as(u8, @intCast(@divTrunc(@as(i32, a), 2))) });
}

fn drawChrome() void {
    blendRectUnchecked(0, 0, @as(i32, @intCast(RENDER_W)), 42 * RETINA_SCALE, .{ 0x00, 0x00, 0x00, 0x8F });
    drawText(27 * RETINA_SCALE, 15 * RETINA_SCALE, "COVER FLOW", .{ 0xEA, 0xF3, 0xFF, 0xFF }, 3);
    drawText(@as(i32, @intCast(RENDER_W)) - 213 * RETINA_SCALE, 18 * RETINA_SCALE, "DRAG OR ARROWS", .{ 0xA7, 0xB7, 0xC8, 0xFF }, 2);
    drawFeatureFlags();

    const idx = @as(usize, @intCast(targetIndex()));
    const album = albums[idx];
    const title_w = textWidth(album.title, 3);
    const artist_w = textWidth(album.artist, 2);
    drawText(CENTER_X - @divTrunc(title_w, 2), 378 * RETINA_SCALE, album.title, .{ 0xF8, 0xFA, 0xFF, 0xFF }, 3);
    drawText(CENTER_X - @divTrunc(artist_w, 2), 411 * RETINA_SCALE, album.artist, .{ 0xA9, 0xB5, 0xC3, 0xFF }, 2);

    const dots_w = @as(i32, @intCast(albums.len)) * 15 * RETINA_SCALE - 6 * RETINA_SCALE;
    var i: usize = 0;
    while (i < albums.len) : (i += 1) {
        const x = CENTER_X - @divTrunc(dots_w, 2) + @as(i32, @intCast(i)) * 15 * RETINA_SCALE;
        const active = i == idx;
        const radius: i32 = if (active) 5 * RETINA_SCALE else 3 * RETINA_SCALE;
        fillCircle(x, 447 * RETINA_SCALE, radius, if (active) .{ 0xF5, 0xF7, 0xFF, 0xFF } else .{ 0x78, 0x84, 0x92, 0xC8 });
    }
}

fn drawFeatureFlags() void {
    drawFlagLabel(28 * RETINA_SCALE, 54 * RETINA_SCALE, "L LIGHT", featureEnabled(FEATURE_LIGHTING));
    drawFlagLabel(126 * RETINA_SCALE, 54 * RETINA_SCALE, "S SPRING", featureEnabled(FEATURE_SPRING));
}

fn drawFlagLabel(x: i32, y: i32, label: []const u8, enabled: bool) void {
    const w = textWidth(label, 2) + 12 * RETINA_SCALE;
    const h = 18 * RETINA_SCALE;
    blendRect(x, y, w, h, if (enabled) .{ 0xE8, 0xF1, 0xFF, 0x22 } else .{ 0x00, 0x00, 0x00, 0x32 });
    drawRect(x, y, w, h, if (enabled) .{ 0xD8, 0xE8, 0xFF, 0x92 } else .{ 0x7A, 0x86, 0x95, 0x72 });
    drawText(x + 6 * RETINA_SCALE, y + 5 * RETINA_SCALE, label, if (enabled) .{ 0xF2, 0xF7, 0xFF, 0xFF } else .{ 0x7D, 0x89, 0x97, 0xFF }, 2);
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
    setPixelOpaqueUnchecked(x, y, c);
}

fn setPixelOpaqueUnchecked(x: i32, y: i32, c: Color) void {
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    writePixelAtIndexUnchecked(idx, c);
}

fn setPixel4OpaqueUnchecked(x: i32, y: i32, c: [4]Color) void {
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const first = packTwoPixels(c[0], c[1]);
    const second = packTwoPixels(c[2], c[3]);
    std.mem.writeInt(u64, pixel_buf[idx..][0..8], first, .little);
    std.mem.writeInt(u64, pixel_buf[idx..][8..16], second, .little);
}

fn setPixel4PackedOpaqueUnchecked(x: i32, y: i32, c: [4]u32) void {
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const first = @as(u64, c[0]) | (@as(u64, c[1]) << 32);
    const second = @as(u64, c[2]) | (@as(u64, c[3]) << 32);
    std.mem.writeInt(u64, pixel_buf[idx..][0..8], first, .little);
    std.mem.writeInt(u64, pixel_buf[idx..][8..16], second, .little);
}

inline fn packTwoPixels(a: Color, b: Color) u64 {
    return @as(u64, a[0]) |
        (@as(u64, a[1]) << 8) |
        (@as(u64, a[2]) << 16) |
        (@as(u64, a[3]) << 24) |
        (@as(u64, b[0]) << 32) |
        (@as(u64, b[1]) << 40) |
        (@as(u64, b[2]) << 48) |
        (@as(u64, b[3]) << 56);
}

fn writePixelAtIndexUnchecked(idx: usize, c: Color) void {
    std.mem.writeInt(u32, pixel_buf[idx..][0..4], packPixel(c), .little);
}

inline fn packPixel(c: Color) u32 {
    return @as(u32, c[0]) |
        (@as(u32, c[1]) << 8) |
        (@as(u32, c[2]) << 16) |
        (@as(u32, c[3]) << 24);
}

inline fn packRGB(r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16) | 0xFF000000;
}

inline fn unpackPixel(p: u32) Color {
    return .{
        @as(u8, @intCast(p & 0xFF)),
        @as(u8, @intCast((p >> 8) & 0xFF)),
        @as(u8, @intCast((p >> 16) & 0xFF)),
        @as(u8, @intCast((p >> 24) & 0xFF)),
    };
}

fn blendPixel(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    blendPixelUnchecked(x, y, c);
}

fn blendPixelUnchecked(x: i32, y: i32, c: Color) void {
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    blendPixelAtIndexUnchecked(idx, c);
}

fn blendPixelAtIndexUnchecked(idx: usize, c: Color) void {
    const a = @as(i32, c[3]);
    if (a <= 0) return;
    if (a >= 255) {
        writePixelAtIndexUnchecked(idx, c);
        return;
    }
    pixel_buf[idx + 0] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 0]) * (255 - a) + @as(i32, c[0]) * a, 255)));
    pixel_buf[idx + 1] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 1]) * (255 - a) + @as(i32, c[1]) * a, 255)));
    pixel_buf[idx + 2] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 2]) * (255 - a) + @as(i32, c[2]) * a, 255)));
    pixel_buf[idx + 3] = 0xFF;
}

fn blendPixelAtIndexAlphaUnchecked(idx: usize, c: Color, a: i32, inv_a: i32) void {
    pixel_buf[idx + 0] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 0]) * inv_a + @as(i32, c[0]) * a, 255)));
    pixel_buf[idx + 1] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 1]) * inv_a + @as(i32, c[1]) * a, 255)));
    pixel_buf[idx + 2] = @as(u8, @intCast(@divTrunc(@as(i32, pixel_buf[idx + 2]) * inv_a + @as(i32, c[2]) * a, 255)));
    pixel_buf[idx + 3] = 0xFF;
}

fn blendRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) blendPixel(x + xx, y + yy, c);
    }
}

fn blendRectUnchecked(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var out_idx = (@as(usize, @intCast(y + yy)) * RENDER_W + @as(usize, @intCast(x))) * 4;
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            blendPixelAtIndexUnchecked(out_idx, c);
            out_idx += 4;
        }
    }
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    blendRect(x, y, w, 1, c);
    blendRect(x, y + h - 1, w, 1, c);
    blendRect(x, y, 1, h, c);
    blendRect(x + w - 1, y, 1, h, c);
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
    const size_px = textSizeForScale(scale);
    var cursor_x = x;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawFontChar(cursor_x, y, text[i], c, size_px);
        cursor_x += fontAdvance(size_px);
    }
}

fn textWidth(text: []const u8, scale: i32) i32 {
    return @as(i32, @intCast(text.len)) * fontAdvance(textSizeForScale(scale));
}

fn textSizeForScale(scale: i32) i32 {
    return switch (scale) {
        3 => 22 * RETINA_SCALE,
        2 => 14 * RETINA_SCALE,
        else => 10 * RETINA_SCALE,
    };
}

fn fontAdvance(size_px: i32) i32 {
    return @max(1, @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(ui_font.GLYPH_W)) * fontScale(size_px)))));
}

fn fontScale(size_px: i32) f32 {
    return @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(ui_font.GLYPH_H));
}

fn drawFontChar(x: i32, y: i32, ch: u8, c: Color, size_px: i32) void {
    const glyph_index = glyphIndexForByte(ch) orelse return;
    const scale = fontScale(size_px);
    const w = fontAdvance(size_px);
    const h = size_px;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const coverage = fontCoverage(glyph_index, dx, dy, scale);
            if (coverage == 0) continue;
            var cc = c;
            cc[3] = @as(u8, @intCast(@divTrunc(@as(i32, c[3]) * coverage, 4)));
            blendPixel(x + dx, y + dy, cc);
        }
    }
}

fn glyphIndexForByte(ch: u8) ?usize {
    if (ch >= ui_font.ASCII_START and ch <= ui_font.ASCII_END) {
        return @as(usize, @intCast(ch - ui_font.ASCII_START));
    }
    return null;
}

fn fontCoverage(glyph_index: usize, dx: i32, dy: i32, scale: f32) i32 {
    const offsets = [_]PointF{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };
    var covered: i32 = 0;
    for (offsets) |off| {
        const sx = @as(i32, @intFromFloat(@floor((@as(f32, @floatFromInt(dx)) + off.x) / scale)));
        const sy = @as(i32, @intFromFloat(@floor((@as(f32, @floatFromInt(dy)) + off.y) / scale)));
        if (fontBit(glyph_index, sx, sy)) covered += 1;
    }
    return covered;
}

fn fontBit(glyph_index: usize, sx: i32, sy: i32) bool {
    if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(ui_font.GLYPH_W)) or sy >= @as(i32, @intCast(ui_font.GLYPH_H))) return false;
    const row = ui_font.glyph_rows[glyph_index][@as(usize, @intCast(sy))];
    return ((row >> @as(u6, @intCast(sx))) & 1) != 0;
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

fn lerpColorF32(a: Color, b: Color, t: f32) Color {
    const clamped = clampF32(t, 0.0, 1.0);
    return .{
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[0])), @as(f32, @floatFromInt(b[0])), clamped)))), 0, 255))),
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[1])), @as(f32, @floatFromInt(b[1])), clamped)))), 0, 255))),
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[2])), @as(f32, @floatFromInt(b[2])), clamped)))), 0, 255))),
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[3])), @as(f32, @floatFromInt(b[3])), clamped)))), 0, 255))),
    };
}

inline fn lerpColorOpaqueF32(a: Color, b: Color, t: f32) Color {
    const clamped = clampF32(t, 0.0, 1.0);
    return .{
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[0])), @as(f32, @floatFromInt(b[0])), clamped)))), 0, 255))),
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[1])), @as(f32, @floatFromInt(b[1])), clamped)))), 0, 255))),
        @as(u8, @intCast(clampI32(@as(i32, @intFromFloat(@round(lerpF32(@as(f32, @floatFromInt(a[2])), @as(f32, @floatFromInt(b[2])), clamped)))), 0, 255))),
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

fn brightenColor(c: Color, boost: i32) Color {
    return .{
        clampU8(@as(i32, c[0]) + @divTrunc((255 - @as(i32, c[0])) * boost, 100)),
        clampU8(@as(i32, c[1]) + @divTrunc((255 - @as(i32, c[1])) * boost, 100)),
        clampU8(@as(i32, c[2]) + @divTrunc((255 - @as(i32, c[2])) * boost, 100)),
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

fn dot3(a: Vec3, b: Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn normalize3(v: Vec3) Vec3 {
    const len = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len <= 0.0001) return .{ .x = 0.0, .y = 0.0, .z = 1.0 };
    return .{ .x = v.x / len, .y = v.y / len, .z = v.z / len };
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
