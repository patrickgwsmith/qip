const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const inter_regular = @import("inter_regular");
const inter_bold = @import("inter_bold");

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
const CENTER_X: i32 = @divTrunc(@as(i32, @intCast(RENDER_W)), 2);

// Geometry in display px, after the 2006-era iTunes/iPod layout: one cover
// faces the viewer, and the rest stand in two tight stacks turned ~70 degrees
// towards the center, all at the same depth.
const RETINA_F: f32 = @as(f32, @floatFromInt(RETINA_SCALE));
const COVER_CENTER_Y: f32 = 168.0 * RETINA_F;
const FOCAL: f32 = 780.0 * RETINA_F;
const SIDE_YAW: f32 = 1.22;
const SIDE_OFFSET: f32 = 165.0 * RETINA_F;
const SIDE_SPACING: f32 = 34.0 * RETINA_F;
const SIDE_DEPTH: f32 = 120.0 * RETINA_F;
const CENTER_SLIDE: f32 = 60.0 * RETINA_F;
const SIDE_DARKEN_MAX: f32 = 90.0;
// Each cover is mirrored in a black glossy floor. The mirror image starts
// REFLECTION_ALPHA/255 bright at the cover's bottom edge and fades linearly
// to black over REFLECTION_SPAN of the cover's height.
const REFLECTION_GAP: f32 = 2.0 * RETINA_F;
const REFLECTION_SPAN: f32 = 0.55;
const REFLECTION_ALPHA: f32 = 92.0;
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
    side_dark: i32,
};

const CoverPose = struct {
    q: Quad,
    reflection_q: Quad,
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
    .{ .title = "Midnight Run", .artist = "The Arcades", .a = .{ 0x13, 0x29, 0x5B, 0xFF }, .b = .{ 0xE7, 0x46, 0x8A, 0xFF }, .c = .{ 0x42, 0xDF, 0xE7, 0xFF }, .motif = 0 },
    .{ .title = "Glass Houses", .artist = "North Pier", .a = .{ 0xD9, 0xE8, 0xF0, 0xFF }, .b = .{ 0x1E, 0x73, 0x8F, 0xFF }, .c = .{ 0x0F, 0x21, 0x2C, 0xFF }, .motif = 1 },
    .{ .title = "Low Sun", .artist = "June Atlas", .a = .{ 0xF1, 0xB1, 0x49, 0xFF }, .b = .{ 0xD8, 0x42, 0x3B, 0xFF }, .c = .{ 0x39, 0x20, 0x45, 0xFF }, .motif = 2 },
    .{ .title = "Tape Echo", .artist = "Mono Field", .a = .{ 0x21, 0x24, 0x26, 0xFF }, .b = .{ 0xDB, 0xD2, 0xB4, 0xFF }, .c = .{ 0x9B, 0xE2, 0x80, 0xFF }, .motif = 3 },
    .{ .title = "Ocean Static", .artist = "The Signals", .a = .{ 0x04, 0x3B, 0x53, 0xFF }, .b = .{ 0x11, 0xA6, 0xC7, 0xFF }, .c = .{ 0xEE, 0xF6, 0xFF, 0xFF }, .motif = 4 },
    .{ .title = "Red Line", .artist = "City Index", .a = .{ 0x24, 0x11, 0x16, 0xFF }, .b = .{ 0xB9, 0x1F, 0x36, 0xFF }, .c = .{ 0xF6, 0xE5, 0xB7, 0xFF }, .motif = 5 },
    .{ .title = "Soft Circuits", .artist = "Ada View", .a = .{ 0x61, 0x78, 0x8A, 0xFF }, .b = .{ 0xE7, 0xE0, 0xC4, 0xFF }, .c = .{ 0x1C, 0x32, 0x45, 0xFF }, .motif = 6 },
    .{ .title = "Late Checkout", .artist = "Hotel Mirror", .a = .{ 0x12, 0x16, 0x1C, 0xFF }, .b = .{ 0xC4, 0xA0, 0x5E, 0xFF }, .c = .{ 0x79, 0xD3, 0xFF, 0xFF }, .motif = 7 },
    .{ .title = "Blueprints", .artist = "Paper Tiger", .a = .{ 0xF8, 0xF6, 0xED, 0xFF }, .b = .{ 0x2D, 0x5D, 0x8F, 0xFF }, .c = .{ 0xE2, 0x51, 0x43, 0xFF }, .motif = 8 },
    .{ .title = "After Hours", .artist = "Black Rain", .a = .{ 0x08, 0x08, 0x0D, 0xFF }, .b = .{ 0x5E, 0x44, 0x8F, 0xFF }, .c = .{ 0xF1, 0x5A, 0x7B, 0xFF }, .motif = 9 },
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
var scrub_active = false;
var scrub_grab_dx: i32 = 0;
var feature_mask: u32 = FEATURE_RENDERING | FEATURE_ALL;
var cover_edges: [MAX_ALBUMS]QuadEdges = undefined;
var reflection_edges: [MAX_ALBUMS]QuadEdges = undefined;
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
    const was_selected_q8 = selected_q8;

    if (down and !primary_down and scrollBarHit(x_px, y_px)) {
        const thumb = scrollThumb();
        scrub_active = true;
        scrub_grab_dx = if (x_px >= thumb.x and x_px < thumb.x + thumb.w) x_px - thumb.x else @divTrunc(thumb.w, 2);
        scrubTo(x_px);
    } else if (down and primary_down and scrub_active) {
        scrubTo(x_px);
    } else if (!down and primary_down and scrub_active) {
        scrub_active = false;
        target_q8 = nearestIndex() * 256;
        needs_redraw = true;
    } else if (down and !primary_down) {
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
    // A held pointer that hasn't moved the covers leaves the frame unchanged.
    return if (was_down != down or selected_q8 != was_selected_q8) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    var active = false;
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
    // Nothing animates while the pointer is held; pointer events drive the
    // frames instead, so a still press needs no wake.
    const active = !primary_down and (velocity_q8 != 0 or absI32(target_q8 - selected_q8) > 1 or absI32(spring_velocity_q8) > 2);
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
        if (valid[i]) {
            cover_edges[i] = makeQuadEdges(covers[i].q);
            reflection_edges[i] = makeQuadEdges(covers[i].reflection_q);
        }
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

// Reflections stack the same way as their covers, so both use this.
inline fn clipCoverRowToVisibleX(comptime reflection: bool, album_idx: usize, y: i32, row_min_x: *i32, row_max_x: *i32) void {
    const side = cover_clip_side[album_idx];
    if (side == 0) return;
    const neighbor = cover_clip_neighbor[album_idx];
    if (neighbor == ROW_CLIP_NONE) return;

    const neighbor_edges = if (reflection) reflection_edges[neighbor] else cover_edges[neighbor];
    const span = rowFullCoverageSpan(neighbor_edges, y, 0, @as(i32, @intCast(RENDER_W)) - 1);
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
    // The original stage is pure black: no floor line, glow or vignette.
    // The floor only shows through the covers' reflections.
    clear(.{ 0x00, 0x00, 0x00, 0xFF });
    drawScrollTrack();
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
    return .{
        .index = index,
        .q = pose.q,
        .reflection_q = pose.reflection_q,
        .side_dark = if (featureEnabled(FEATURE_LIGHTING)) sideDarken(pose.normal) else 0,
    };
}

// Reflections are written opaque (a faded copy over a black floor), so they
// are drawn back to front like the covers and nearer ones hide farther ones.
fn drawReflections(nearest: i32, covers: *const [MAX_ALBUMS]FrameCover, valid: *const [MAX_ALBUMS]bool) void {
    drawBackToFront(true, nearest, covers, valid);
}

fn drawAlbums(nearest: i32, covers: *const [MAX_ALBUMS]FrameCover, valid: *const [MAX_ALBUMS]bool) void {
    drawBackToFront(false, nearest, covers, valid);
}

fn drawBackToFront(comptime reflection: bool, nearest: i32, covers: *const [MAX_ALBUMS]FrameCover, valid: *const [MAX_ALBUMS]bool) void {
    var pass: i32 = 5;
    while (pass >= 1) : (pass -= 1) {
        const left = nearest - pass;
        if (left >= 0) {
            const slot = @as(usize, @intCast(left));
            if (valid[slot]) drawAlbumPrepared(reflection, covers[slot]);
        }
        const right = nearest + pass;
        if (right < @as(i32, @intCast(albums.len))) {
            const slot = @as(usize, @intCast(right));
            if (valid[slot]) drawAlbumPrepared(reflection, covers[slot]);
        }
    }
    if (nearest >= 0 and nearest < @as(i32, @intCast(albums.len))) {
        const slot = @as(usize, @intCast(nearest));
        if (valid[slot]) drawAlbumPrepared(reflection, covers[slot]);
    }
}

fn drawAlbumPrepared(comptime reflection: bool, cover: FrameCover) void {
    const q = if (reflection) cover.reflection_q else cover.q;
    drawTexturedQuad(reflection, q, @as(usize, @intCast(cover.index)), cover.side_dark);
}

fn coverQuad(comptime reflection: bool, index: i32) Quad {
    const pose = coverPose(index);
    return if (reflection) pose.reflection_q else pose.q;
}

fn coverPose(index: i32) CoverPose {
    const d_q8 = index * 256 - selected_q8;
    const rel = @as(f32, @floatFromInt(d_q8)) / 256.0;
    const ad = absF32(rel);
    const sign: f32 = if (rel < 0) -1.0 else 1.0;
    const turn = smoothstep(0.1, 0.9, ad);
    // Side covers turn to face the center, so their inner edges tuck behind
    // their neighbors and only the nearer, outer edges show.
    const yaw = sign * turn * SIDE_YAW;
    const cos_y = @cos(yaw);
    const sin_y = @sin(yaw);
    const side_x = sign * (SIDE_OFFSET + (ad - 1.0) * SIDE_SPACING);
    const x_world = lerpF32(rel * CENTER_SLIDE, side_x, turn);
    const z_world = turn * SIDE_DEPTH;
    const half = @as(f32, @floatFromInt(COVER)) * 0.5;
    // The reflection is the cover mirrored in the floor plane at its bottom
    // edge, trimmed to the part that is still visible before it fades out.
    const mirror_top = half + REFLECTION_GAP;
    const mirror_bottom = mirror_top + 2.0 * half * REFLECTION_SPAN;
    return .{
        .q = .{
            .tl = projectCoverCorner(-half, -half, x_world, z_world, cos_y, sin_y),
            .tr = projectCoverCorner(half, -half, x_world, z_world, cos_y, sin_y),
            .br = projectCoverCorner(half, half, x_world, z_world, cos_y, sin_y),
            .bl = projectCoverCorner(-half, half, x_world, z_world, cos_y, sin_y),
        },
        .reflection_q = .{
            .tl = projectCoverCorner(-half, mirror_top, x_world, z_world, cos_y, sin_y),
            .tr = projectCoverCorner(half, mirror_top, x_world, z_world, cos_y, sin_y),
            .br = projectCoverCorner(half, mirror_bottom, x_world, z_world, cos_y, sin_y),
            .bl = projectCoverCorner(-half, mirror_bottom, x_world, z_world, cos_y, sin_y),
        },
        .normal = .{ .x = sin_y, .y = 0.0, .z = cos_y },
    };
}

fn projectCoverCorner(local_x: f32, local_y: f32, x_world: f32, z_world: f32, cos_y: f32, sin_y: f32) Point {
    const rotated_x = local_x * cos_y;
    const rotated_z = -local_x * sin_y;
    const z = z_world + rotated_z;
    const perspective = FOCAL / (FOCAL + z);
    return .{
        .x = @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(CENTER_X)) + (x_world + rotated_x) * perspective))),
        .y = @as(i32, @intFromFloat(@round(COVER_CENTER_Y + local_y * perspective))),
    };
}

noinline fn drawTexturedQuad(comptime reflection: bool, q: Quad, album_idx: usize, darken: i32) void {
    switch (feature_mask & (FEATURE_BILINEAR | FEATURE_ANTIALIAS)) {
        0 => drawTexturedQuadMode(reflection, false, false, q, album_idx, darken),
        FEATURE_BILINEAR => drawTexturedQuadMode(reflection, true, false, q, album_idx, darken),
        FEATURE_ANTIALIAS => drawTexturedQuadMode(reflection, false, true, q, album_idx, darken),
        FEATURE_BILINEAR | FEATURE_ANTIALIAS => drawTexturedQuadMode(reflection, true, true, q, album_idx, darken),
        else => unreachable,
    }
}

fn drawTexturedQuadMode(comptime reflection: bool, comptime use_bilinear: bool, comptime use_antialias: bool, q: Quad, album_idx: usize, darken: i32) void {
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
        var row_min_x = min_x;
        var row_max_x = max_x;
        clipCoverRowToVisibleX(reflection, album_idx, y, &row_min_x, &row_max_x);
        if (row_min_x > row_max_x) continue;
        var x = row_min_x;
        if (use_bilinear and use_antialias) {
            const full_span = rowFullCoverageSpan(edges, y, row_min_x, row_max_x);
            const full_start = firstBatchXAtOrAfter(row_min_x, full_span.min_x);
            const full_end = lastBatchXAtOrBefore(row_min_x, @min(full_span.max_x - 3, row_max_x - 3));

            while (x + 3 <= row_max_x and x < full_start) : (x += 4) {
                drawTexturedQuadBatch4BilinearAA(reflection, edges, inv, row_u_y, row_v_y, row_d_y, x, y, album_idx, darken);
            }
            while (x <= full_end) : (x += 4) {
                drawTexturedQuadBatch4BilinearFullCached(reflection, inv, row_v_y, x, y, album_idx, darken);
            }
            while (x + 3 <= row_max_x) : (x += 4) {
                drawTexturedQuadBatch4BilinearAA(reflection, edges, inv, row_u_y, row_v_y, row_d_y, x, y, album_idx, darken);
            }
        } else {
            while (x + 3 <= row_max_x) : (x += 4) {
                if (!reflection and use_bilinear and !use_antialias) {
                    drawTexturedQuadBatch4OpaqueNoAA(use_bilinear, inv, x, y, album_idx, darken);
                } else {
                    drawTexturedQuadBatch4(reflection, use_bilinear, use_antialias, inv, x, y, album_idx, darken);
                }
            }
        }
        while (x <= row_max_x) : (x += 1) {
            const uv = mapPoint(inv, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5) orelse continue;
            drawTexturedQuadMappedPixel(reflection, use_bilinear, use_antialias, inv, x, y, uv, album_idx, darken);
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

// A reflection quad's v runs from 0 at the cover's bottom edge to 1 where the
// fade reaches black, so it samples the bottom REFLECTION_SPAN of the cover,
// flipped.
inline fn reflectionTexV(v_clamped: f32) f32 {
    return 255.0 - v_clamped * (255.0 * REFLECTION_SPAN);
}

inline fn reflectionFade(v_clamped: f32) i32 {
    return @as(i32, @intFromFloat(@round(REFLECTION_ALPHA * (1.0 - v_clamped))));
}

inline fn coverTexVBatch4(comptime reflection: bool, v_clamped: Vec4f) Vec4f {
    if (reflection) return @as(Vec4f, @splat(255.0)) - v_clamped * @as(Vec4f, @splat(255.0 * REFLECTION_SPAN));
    return v_clamped * @as(Vec4f, @splat(255.0));
}

inline fn reflectionFadeBatch4(v_clamped: Vec4f) Vec4i {
    return @intFromFloat(@round(@as(Vec4f, @splat(REFLECTION_ALPHA)) * (@as(Vec4f, @splat(1.0)) - v_clamped)));
}

inline fn drawTexturedQuadBatch4OpaqueNoAA(comptime use_bilinear: bool, inv: Matrix3, x: i32, y: i32, album_idx: usize, darken: i32) void {
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
        drawTexturedQuadBatch4(false, use_bilinear, false, inv, x, y, album_idx, darken);
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
            out[lane] = shadeOpaque(c, u_mid[lane], darken);
        }
    } else {
        inline for (0..4) |lane| {
            const c = sampleCoverNearest(album_idx, u_f[lane], v_f[lane]);
            out[lane] = shadeOpaque(c, u_mid[lane], darken);
        }
    }
    setPixel4OpaqueUnchecked(x, y, out);
}

inline fn drawTexturedQuadBatch4BilinearFullCached(comptime reflection: bool, inv: Matrix3, row_v_y: f32, x: i32, y: i32, album_idx: usize, darken: i32) void {
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
    const v_clamped = @min(@max(vs, @as(Vec4f, @splat(0.0))), @as(Vec4f, @splat(1.0)));
    const colors = sampleCoverBilinearBatch4(album_idx, u_f, coverTexVBatch4(reflection, v_clamped));
    const u_mid: Vec4i = .{
        project_u_mid[idx],
        project_u_mid[idx + 1],
        project_u_mid[idx + 2],
        project_u_mid[idx + 3],
    };

    const out = if (reflection)
        shadePackedOpaqueBatch4(colors, u_mid, darken, reflectionFadeBatch4(v_clamped))
    else
        shadePackedOpaqueBatch4(colors, u_mid, darken, @splat(255));
    setPixel4PackedOpaqueUnchecked(x, y, out);
}

inline fn drawTexturedQuadBatch4BilinearAA(comptime reflection: bool, edges: QuadEdges, inv: Matrix3, row_u_y: f32, row_v_y: f32, row_d_y: f32, x: i32, y: i32, album_idx: usize, darken: i32) void {
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
    const v_clamped = @min(@max(vs, zero), one);
    const colors = sampleCoverBilinearBatch4(album_idx, u_f, coverTexVBatch4(reflection, v_clamped));
    const u_mid: Vec4i = @intFromFloat(@round(u_f));
    const strength: Vec4i = if (reflection) reflectionFadeBatch4(v_clamped) else @splat(255);

    if (coverage[0] == 4 and coverage[1] == 4 and coverage[2] == 4 and coverage[3] == 4) {
        setPixel4PackedOpaqueUnchecked(x, y, shadePackedOpaqueBatch4(colors, u_mid, darken, strength));
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
            drawSampledPixelInsideKnownCoverage(x + @as(i32, @intCast(lane)), y, c, u_mid[lane], darken, strength[lane], coverage[lane]);
        }
    }
}

inline fn drawTexturedQuadBatch4(comptime reflection: bool, comptime use_bilinear: bool, comptime use_antialias: bool, inv: Matrix3, x: i32, y: i32, album_idx: usize, darken: i32) void {
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
            drawTexturedQuadMappedPixel(reflection, use_bilinear, use_antialias, inv, x + @as(i32, @intCast(lane)), y, uv, album_idx, darken);
        }
    }
}

inline fn drawTexturedQuadMappedPixel(comptime reflection: bool, comptime use_bilinear: bool, comptime use_antialias: bool, inv: Matrix3, x: i32, y: i32, uv: PointF, album_idx: usize, darken: i32) void {
    if (uv.x < -0.002 or uv.x > 1.002 or uv.y < -0.002 or uv.y > 1.002) return;
    const coverage = if (use_antialias) quadCoverage(inv, x, y) else 4;
    if (coverage <= 0) return;
    const u_f = clampF32(uv.x, 0.0, 1.0) * 255.0;
    const v_clamped = clampF32(uv.y, 0.0, 1.0);
    const v_f = if (reflection) reflectionTexV(v_clamped) else v_clamped * 255.0;
    const c = if (use_bilinear)
        sampleCoverBilinear(album_idx, u_f, v_f)
    else
        sampleCoverNearest(album_idx, u_f, v_f);
    const u_mid = @as(i32, @intFromFloat(@round(u_f)));
    const strength = if (reflection) reflectionFade(v_clamped) else 255;
    drawSampledPixelInsideKnownCoverage(x, y, c, u_mid, darken, strength, coverage);
}

// Shades a batch and scales it by strength/255 towards black. Covers use 255;
// reflections use their fade, which over the black floor is the same as
// blending, but stays opaque so nearer reflections hide farther ones.
inline fn shadePackedOpaqueBatch4(colors: ColorBatch, u_mid: Vec4i, darken: i32, strength: Vec4i) [4]u32 {
    const zero: Vec4i = @splat(0);
    const mid: Vec4i = @splat(128);
    const centered = u_mid - mid;
    const abs_mid = @select(i32, centered < zero, -centered, centered);
    const shade = @as(Vec4i, @splat(darken)) + div11PositiveVec(abs_mid);
    const factor = div255PositiveVec((@as(Vec4i, @splat(255)) - shade) * strength);
    const r = div255PositiveVec(colors.r * factor);
    const g = div255PositiveVec(colors.g * factor);
    const b = div255PositiveVec(colors.b * factor);

    var out: [4]u32 = undefined;
    inline for (0..4) |lane| {
        out[lane] = packRGB(@intCast(r[lane]), @intCast(g[lane]), @intCast(b[lane]));
    }
    return out;
}

inline fn div255PositiveVec(v: Vec4i) Vec4i {
    const scaled = (v + @as(Vec4i, @splat(1))) * @as(Vec4i, @splat(257));
    return scaled >> @as(@Vector(4, u5), @splat(16));
}

inline fn div11PositiveVec(v: Vec4i) Vec4i {
    return (v * @as(Vec4i, @splat(187))) >> @as(@Vector(4, u5), @splat(11));
}

inline fn shadeOpaque(c_in: Color, u_mid: i32, darken: i32) Color {
    const shade = darken + @divTrunc(absI32(u_mid - 128), 11);
    return shadeColor(c_in, shade);
}

inline fn drawSampledPixelInsideKnownCoverage(x: i32, y: i32, c_in: Color, u_mid: i32, darken: i32, strength: i32, coverage: i32) void {
    if (coverage <= 0) return;
    var c = shadeOpaque(c_in, u_mid, darken);
    if (strength < 255) c = shadeColor(c, 255 - strength);
    if (coverage == 4) {
        setPixelOpaqueUnchecked(x, y, c);
    } else {
        c[3] = @as(u8, @intCast(coverage * 63));
        blendPixelUnchecked(x, y, c);
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
    return base;
}

// With lighting on, side covers darken as they turn away from the viewer.
fn sideDarken(normal: Vec3) i32 {
    const facing = clampF32(normal.z, 0.0, 1.0);
    return @as(i32, @intFromFloat(@round((1.0 - facing) * SIDE_DARKEN_MAX)));
}

fn drawChrome() void {
    drawFeatureFlags();

    const idx = @as(usize, @intCast(targetIndex()));
    const album = albums[idx];
    drawTextCentered(inter_bold, CENTER_X, TITLE_BASELINE, album.title, TITLE_SIZE, .{ 0xFF, 0xFF, 0xFF, 0xFF });
    drawTextCentered(inter_regular, CENTER_X, ARTIST_BASELINE, album.artist, ARTIST_SIZE, .{ 0x9A, 0x9A, 0x9A, 0xFF });
    drawScrollBar();
}

// The iTunes-style scroll bar: a dark rounded track, cached with the
// background, and a lighter thumb that follows the animated position, not
// just the selected album. Dragging the thumb scrubs through the covers, and
// pressing the track jumps the thumb to the pointer.
const SCROLL_TRACK_W: i32 = 300 * RETINA_SCALE;
const SCROLL_TRACK_H: i32 = 12 * RETINA_SCALE;
const SCROLL_TRACK_X: i32 = CENTER_X - @divTrunc(SCROLL_TRACK_W, 2);
const SCROLL_TRACK_Y: i32 = 442 * RETINA_SCALE;
// Presses this far above or below the track still grab it.
const SCROLL_HIT_SLOP: i32 = 8 * RETINA_SCALE;

const ScrollThumb = struct {
    x: i32,
    w: i32,
};

fn scrollThumbWidth() i32 {
    return @max(SCROLL_TRACK_H * 3, @divTrunc(SCROLL_TRACK_W * 2, @as(i32, @intCast(albums.len))));
}

fn scrollThumb() ScrollThumb {
    const thumb_w = scrollThumbWidth();
    const max_q8 = (@as(i32, @intCast(albums.len)) - 1) * 256;
    const pos_q8 = clampI32(selected_q8, 0, max_q8);
    return .{
        .x = SCROLL_TRACK_X + @divTrunc((SCROLL_TRACK_W - thumb_w) * pos_q8, @max(1, max_q8)),
        .w = thumb_w,
    };
}

fn scrollBarHit(x: i32, y: i32) bool {
    return x >= SCROLL_TRACK_X - SCROLL_HIT_SLOP and x < SCROLL_TRACK_X + SCROLL_TRACK_W + SCROLL_HIT_SLOP and
        y >= SCROLL_TRACK_Y - SCROLL_HIT_SLOP and y < SCROLL_TRACK_Y + SCROLL_TRACK_H + SCROLL_HIT_SLOP;
}

// Places the thumb's left edge at x - scrub_grab_dx and moves the covers to
// match, without snapping to an album until the pointer is released.
fn scrubTo(x: i32) void {
    const max_q8 = (@as(i32, @intCast(albums.len)) - 1) * 256;
    const travel = @max(1, SCROLL_TRACK_W - scrollThumbWidth());
    const offset = clampI32(x - scrub_grab_dx - SCROLL_TRACK_X, 0, travel);
    selected_q8 = @divTrunc(offset * max_q8 + @divTrunc(travel, 2), travel);
    target_q8 = selected_q8;
    velocity_q8 = 0;
    spring_velocity_q8 = 0;
    needs_redraw = true;
}

fn drawScrollTrack() void {
    const track_w = SCROLL_TRACK_W;
    const track_h = SCROLL_TRACK_H;
    const track_x = SCROLL_TRACK_X;
    const track_y = SCROLL_TRACK_Y;
    fillCapsule(track_x, track_y, track_w, track_h, .{ 0x50, 0x50, 0x50, 0xFF }, .{ 0x3A, 0x3A, 0x3A, 0xFF });
    fillCapsule(track_x + RETINA_SCALE, track_y + RETINA_SCALE, track_w - 2 * RETINA_SCALE, track_h - 2 * RETINA_SCALE, .{ 0x0C, 0x0C, 0x0C, 0xFF }, .{ 0x1E, 0x1E, 0x1E, 0xFF });
}

fn drawScrollBar() void {
    const track_h = SCROLL_TRACK_H;
    const track_y = SCROLL_TRACK_Y;

    const thumb = scrollThumb();
    // The thumb brightens while it is held.
    const lift: i32 = if (scrub_active) 0x1C else 0;
    fillCapsule(thumb.x, track_y, thumb.w, track_h, addColor(.{ 0xB4, 0xB4, 0xB4, 0xFF }, lift), addColor(.{ 0x70, 0x70, 0x70, 0xFF }, lift));
    fillCapsule(thumb.x + RETINA_SCALE, track_y + RETINA_SCALE, thumb.w - 2 * RETINA_SCALE, track_h - 2 * RETINA_SCALE, addColor(.{ 0x8C, 0x8C, 0x8C, 0xFF }, lift), addColor(.{ 0x50, 0x50, 0x50, 0xFF }, lift));
}

fn drawFeatureFlags() void {
    const x = 16.0 * RETINA_F;
    drawFlagLabel(x, "L LIGHT", featureEnabled(FEATURE_LIGHTING));
    drawFlagLabel(x + textWidth(inter_regular, "L LIGHT", FLAG_SIZE) + 14.0 * RETINA_F, "S SPRING", featureEnabled(FEATURE_SPRING));
}

fn drawFlagLabel(x: f32, label: []const u8, enabled: bool) void {
    drawText(inter_regular, x, FLAG_BASELINE, label, FLAG_SIZE, if (enabled) .{ 0x8A, 0x8A, 0x8A, 0xFF } else .{ 0x40, 0x40, 0x40, 0xFF });
}

// Horizontal capsule with a vertical top-to-bottom gradient and an
// antialiased edge.
fn fillCapsule(x: i32, y: i32, w: i32, h: i32, top: Color, bottom: Color) void {
    if (w <= 0 or h <= 0) return;
    const r = @as(f32, @floatFromInt(h)) * 0.5;
    const cy = @as(f32, @floatFromInt(y)) + r;
    const left = @as(f32, @floatFromInt(x)) + r;
    const right = @as(f32, @floatFromInt(x + w)) - r;
    var yy = y;
    while (yy < y + h) : (yy += 1) {
        var c = lerpColorF32(top, bottom, (@as(f32, @floatFromInt(yy - y)) + 0.5) / @as(f32, @floatFromInt(h)));
        const py = @as(f32, @floatFromInt(yy)) + 0.5;
        var xx = x;
        while (xx < x + w) : (xx += 1) {
            const px = @as(f32, @floatFromInt(xx)) + 0.5;
            const nx = clampF32(px, left, @max(left, right));
            const dx = px - nx;
            const dy = py - cy;
            const coverage = clampF32(r - @sqrt(dx * dx + dy * dy) + 0.5, 0.0, 1.0);
            if (coverage <= 0.0) continue;
            c[3] = @as(u8, @intFromFloat(@round(coverage * 255.0)));
            blendPixel(xx, yy, c);
        }
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

// Text is drawn from Inter Display's outlines with its pair kerning, as the
// Open Graph image component does. Sizes and baselines are in render px.
const TITLE_SIZE: f32 = 17.0 * RETINA_F;
const TITLE_BASELINE: f32 = 394.0 * RETINA_F;
const ARTIST_SIZE: f32 = 13.0 * RETINA_F;
const ARTIST_BASELINE: f32 = 416.0 * RETINA_F;
const FLAG_SIZE: f32 = 10.0 * RETINA_F;
const FLAG_BASELINE: f32 = 24.0 * RETINA_F;

// One line of text at a time is accumulated as signed area into this strip,
// in the manner of font-rs, then blended into the frame.
const TEXT_STRIP_H: usize = 40 * RETINA_SCALE_USIZE;
const TEXT_MAX_CURVE_SEGMENTS: usize = 16;
var text_cells: [RENDER_W * TEXT_STRIP_H]f32 = @splat(0);
var text_dirty_x0: usize = RENDER_W;
var text_dirty_x1: usize = 0;

fn textScale(comptime font: type, size_px: f32) f32 {
    return size_px / font.UNITS_PER_EM;
}

fn textWidth(comptime font: type, text: []const u8, size_px: f32) f32 {
    var units: i32 = 0;
    var previous: ?usize = null;
    for (text) |ch| {
        const glyph = font.glyphIndex(ch) orelse continue;
        if (previous) |left| units += font.kerning(left, glyph);
        units += font.advances[glyph];
        previous = glyph;
    }
    return @as(f32, @floatFromInt(units)) * textScale(font, size_px);
}

fn drawTextCentered(comptime font: type, center_x: i32, baseline: f32, text: []const u8, size_px: f32, c: Color) void {
    const w = textWidth(font, text, size_px);
    drawText(font, @round(@as(f32, @floatFromInt(center_x)) - w * 0.5), baseline, text, size_px, c);
}

fn drawText(comptime font: type, x: f32, baseline: f32, text: []const u8, size_px: f32, c: Color) void {
    const scale = textScale(font, size_px);
    const strip_top = @floor(baseline - font.ASCENDER * scale) - 1.0;
    const strip_baseline = baseline - strip_top;
    var units: i32 = 0;
    var previous: ?usize = null;
    for (text) |ch| {
        const glyph = font.glyphIndex(ch) orelse continue;
        if (previous) |left| units += font.kerning(left, glyph);
        drawGlyphOutline(font, glyph, x + @as(f32, @floatFromInt(units)) * scale, strip_baseline, scale);
        units += font.advances[glyph];
        previous = glyph;
    }
    blendTextStrip(@as(i32, @intFromFloat(strip_top)), c);
}

// Turns the strip's accumulated area into coverage, blends it into the frame
// and clears the strip. Each closed outline sums to zero across a row, so a
// row's running sum is 0 again right of the dirty cells.
fn blendTextStrip(top: i32, c: Color) void {
    if (text_dirty_x0 < text_dirty_x1) {
        var row_index: usize = 0;
        while (row_index < TEXT_STRIP_H) : (row_index += 1) {
            const row = text_cells[row_index * RENDER_W ..][text_dirty_x0..text_dirty_x1];
            const y = top + @as(i32, @intCast(row_index));
            var sum: f32 = 0;
            for (row, 0..) |*cell, i| {
                sum += cell.*;
                cell.* = 0;
                const coverage = @min(@abs(sum), 1.0);
                if (coverage <= 0.0) continue;
                var cc = c;
                cc[3] = @as(u8, @intFromFloat(@round(coverage * @as(f32, @floatFromInt(c[3])))));
                blendPixel(@as(i32, @intCast(text_dirty_x0 + i)), y, cc);
            }
        }
    }
    text_dirty_x0 = RENDER_W;
    text_dirty_x1 = 0;
}

fn clampTextX(x: f32) f32 {
    return clampF32(x, 0, @as(f32, @floatFromInt(RENDER_W - 2)));
}

// Adds the signed area a line contributes to each cell of the strip: a
// pixel's coverage is the running sum of its row up to it.
fn accumulateTextLine(a: PointF, b: PointF) void {
    if (a.y == b.y) return;
    const dir: f32 = if (a.y < b.y) 1 else -1;
    const p0 = if (a.y < b.y) a else b;
    const p1 = if (a.y < b.y) b else a;
    const height_f: f32 = @floatFromInt(TEXT_STRIP_H);
    if (p1.y <= 0 or p0.y >= height_f) return;
    const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
    var x = p0.x;
    if (p0.y < 0) x -= p0.y * dxdy;
    const y_start: usize = @intFromFloat(@max(0, @floor(p0.y)));
    const y_end: usize = @intFromFloat(@min(height_f, @ceil(p1.y)));
    text_dirty_x0 = @min(text_dirty_x0, @as(usize, @intFromFloat(@floor(clampTextX(@min(p0.x, p1.x))))));
    // A line on a cell boundary also writes the cell to its right.
    text_dirty_x1 = @max(text_dirty_x1, @min(RENDER_W, @as(usize, @intFromFloat(@ceil(clampTextX(@max(p0.x, p1.x))))) + 2));
    for (y_start..y_end) |y| {
        const row = text_cells[y * RENDER_W ..][0..RENDER_W];
        const y_f: f32 = @floatFromInt(y);
        const dy = @min(y_f + 1, p1.y) - @max(y_f, p0.y);
        const x_next = x + dxdy * dy;
        const d = dy * dir;
        const x0 = clampTextX(@min(x, x_next));
        const x1 = clampTextX(@max(x, x_next));
        const x0_floor = @floor(x0);
        const x0i: usize = @intFromFloat(x0_floor);
        const x1_ceil = @ceil(x1);
        const x1i: usize = @intFromFloat(x1_ceil);
        if (x1i <= x0i + 1) {
            const xmf = 0.5 * (x0 + x1) - x0_floor;
            row[x0i] += d - d * xmf;
            row[x0i + 1] += d * xmf;
        } else {
            const s = 1 / (x1 - x0);
            const x0f = x0 - x0_floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = x1 - x1_ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            row[x0i] += d * a0;
            if (x1i == x0i + 2) {
                row[x0i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                row[x0i + 1] += d * (a1 - a0);
                for (x0i + 2..x1i - 1) |xi| row[xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                row[x1i - 1] += d * (1 - a2 - am);
            }
            row[x1i] += d * am;
        }
        x = x_next;
    }
}

// Flattens a quadratic curve into lines no more than about a third of a
// pixel from it.
fn accumulateTextQuad(p0: PointF, p1: PointF, p2: PointF) void {
    const ddx = p0.x - 2 * p1.x + p2.x;
    const ddy = p0.y - 2 * p1.y + p2.y;
    const deviation2 = ddx * ddx + ddy * ddy;
    if (deviation2 < 0.333) {
        accumulateTextLine(p0, p2);
        return;
    }
    const steps_f = @min(@floor(@sqrt(@sqrt(3 * deviation2))), @as(f32, TEXT_MAX_CURVE_SEGMENTS - 1));
    const steps: usize = 1 + @as(usize, @intFromFloat(steps_f));
    const steps_inv = 1 / @as(f32, @floatFromInt(steps));
    var previous = p0;
    for (1..steps) |i| {
        const t = @as(f32, @floatFromInt(i)) * steps_inv;
        const mt = 1 - t;
        const point = PointF{
            .x = mt * mt * p0.x + 2 * t * mt * p1.x + t * t * p2.x,
            .y = mt * mt * p0.y + 2 * t * mt * p1.y + t * t * p2.y,
        };
        accumulateTextLine(previous, point);
        previous = point;
    }
    accumulateTextLine(previous, p2);
}

// Packed glyph coordinates are half font units with y pointing down.
fn drawGlyphOutline(comptime font: type, glyph_index: usize, origin_x: f32, baseline_y: f32, scale: f32) void {
    const commands = font.glyph_commands[font.glyph_command_offsets[glyph_index]..font.glyph_command_offsets[glyph_index + 1]];
    const coords = font.glyph_coords;
    var coord_index: usize = font.glyph_coord_offsets[glyph_index];
    const half_scale = scale * 0.5;
    const point = struct {
        fn at(cs: []const i16, i: usize, ox: f32, oy: f32, s: f32) PointF {
            return .{ .x = ox + @as(f32, @floatFromInt(cs[i])) * s, .y = oy + @as(f32, @floatFromInt(cs[i + 1])) * s };
        }
    }.at;
    var start = PointF{ .x = origin_x, .y = baseline_y };
    var current = start;
    for (commands) |command| {
        switch (command) {
            'M' => {
                // A fill closes any open subpath.
                accumulateTextLine(current, start);
                start = point(&coords, coord_index, origin_x, baseline_y, half_scale);
                current = start;
                coord_index += 2;
            },
            'L' => {
                const next = point(&coords, coord_index, origin_x, baseline_y, half_scale);
                accumulateTextLine(current, next);
                current = next;
                coord_index += 2;
            },
            'Q' => {
                const control = point(&coords, coord_index, origin_x, baseline_y, half_scale);
                const next = point(&coords, coord_index + 2, origin_x, baseline_y, half_scale);
                accumulateTextQuad(current, control, next);
                current = next;
                coord_index += 4;
            },
            'Z' => {
                accumulateTextLine(current, start);
                current = start;
            },
            else => unreachable,
        }
    }
    accumulateTextLine(current, start);
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
