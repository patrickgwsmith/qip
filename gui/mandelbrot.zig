// A Mandelbrot set explorer drawn at 2x.
//
// Colour comes from the smooth (continuous) escape count, so there are no
// iteration bands, and the iteration limit grows with the zoom so deep views
// keep their detail.
//
// Escape counts are component state, computed during updates rather than in
// render. Each update spends a fixed iteration budget refining 8x8 tiles from
// the centre outwards: first one sample per 4x4 block, then per 2x2 block,
// then every pixel. While work remains, finish_update asks for another update,
// so a deep view sharpens over several frames instead of blocking for a second.
// The budget counts iterations, not wall time, so the same updates always
// produce the same state.
//
// Zooms animate. Each animation frame resamples the previous counts, so the
// picture moves immediately and refines as it settles. Panning moves the view
// by whole pixels; the computed pixels shift with it and only the exposed strip
// needs work. Tiles are aligned to the view's pixel grid rather than the
// screen, so a fully refined view is identical however it was reached.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const font = @import("inter_regular");

const W: usize = 960;
const H: usize = 640;
const PIXEL_BYTES: usize = W * H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_HOME: i32 = 0xFF50;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_KP_ADD: i32 = 0xFFAB;
const XK_KP_SUBTRACT: i32 = 0xFFAD;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const HOME_X: f64 = -0.65;
const HOME_Y: f64 = 0.0;
const HOME_SPAN: f64 = 3.4;
const MIN_SPAN: f64 = 4e-12; // Below this, f64 pixel coordinates start to repeat.
const MAX_SPAN: f64 = 8.0;
const ZOOM_DURATION_MS: i64 = 240;
const FRAME_MS: i64 = 16;
const DRAG_THRESHOLD: i32 = 6;
const PAN_STEP_PX: i64 = 64;
const INTERIOR: f32 = -1;

// ---- State ---------------------------------------------------------------------

const View = struct {
    // The pixel grid is anchored at (anchor_x, anchor_y) and shifted by a whole
    // number of pixels, so panning never moves the grid between pixels.
    anchor_x: f64 = HOME_X,
    anchor_y: f64 = HOME_Y,
    offset_x: i64 = 0,
    offset_y: i64 = 0,
    span: f64 = HOME_SPAN,

    fn step(v: View) f64 {
        return v.span / @as(f64, W);
    }

    fn centerX(v: View) f64 {
        return v.anchor_x + @as(f64, @floatFromInt(v.offset_x)) * v.step();
    }

    fn centerY(v: View) f64 {
        return v.anchor_y - @as(f64, @floatFromInt(v.offset_y)) * v.step();
    }

    // The complex coordinate under the centre of pixel (px, py).
    fn pointX(v: View, px: f64) f64 {
        return v.anchor_x + (@as(f64, @floatFromInt(v.offset_x)) + px + 0.5 - @as(f64, W) * 0.5) * v.step();
    }

    fn pointY(v: View, py: f64) f64 {
        return v.anchor_y - (@as(f64, @floatFromInt(v.offset_y)) + py + 0.5 - @as(f64, H) * 0.5) * v.step();
    }

    fn centered(cx: f64, cy: f64, span: f64) View {
        return .{ .anchor_x = cx, .anchor_y = cy, .span = span };
    }
};

const Zoom = struct {
    from: View,
    to: View,
    start_ms: i64,
};

const State = struct {
    view: View = .{},
    zoom: ?Zoom = null,
    palette: u8 = 0,
    show_hud: bool = true,
    interacted: bool = false,

    primary_down: bool = false,
    secondary_down: bool = false,
    dragging: bool = false,
    press_x: i32 = 0,
    press_y: i32 = 0,
    last_x: i32 = 0,
    last_y: i32 = 0,
};

const Phase = enum { initializing, ready, updating };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var state: State = .{};
var phase: Phase = .initializing;
var now_ms: i64 = 0;
var committed_at_ms: i64 = 0;

// ---- QIP exports ---------------------------------------------------------------

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_BYTES);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(time_ms: i64) void {
    if (phase != .ready) @trap();
    if (time_ms <= 0 or time_ms <= committed_at_ms) @trap();
    now_ms = time_ms;
    phase = .updating;
    advanceZoom();
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    phase = .ready;
    committed_at_ms = now_ms;
    const more_work = refine(UPDATE_BUDGET);
    if (state.zoom) |z| {
        // Ask for the next animation frame, or the end of the animation if sooner.
        const frame = now_ms + FRAME_MS;
        return @min(frame, @max(now_ms + 1, z.start_ms + ZOOM_DURATION_MS));
    }
    return if (more_work) now_ms + FRAME_MS else now_ms;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    const pan: i64 = if ((flags & FLAG_SHIFT) != 0) PAN_STEP_PX * 4 else PAN_STEP_PX;
    const changed = switch (x11_key) {
        XK_LEFT => panBy(-pan, 0),
        XK_RIGHT => panBy(pan, 0),
        XK_UP => panBy(0, -pan),
        XK_DOWN => panBy(0, pan),
        '=', '+', XK_KP_ADD => zoomAt(@as(f64, W) * 0.5, @as(f64, H) * 0.5, 0.5),
        '-', '_', XK_KP_SUBTRACT => zoomAt(@as(f64, W) * 0.5, @as(f64, H) * 0.5, 2.0),
        'r', 'R', '0', XK_HOME, XK_ESCAPE => resetView(),
        'p', 'P' => blk: {
            state.palette = (state.palette + 1) % @as(u8, palettes.len);
            break :blk true;
        },
        'h', 'H' => blk: {
            state.show_hud = !state.show_hud;
            break :blk true;
        },
        else => false,
    };
    if (changed) state.interacted = true;
    return if (changed) 1 else 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireEventPhase();
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const inside = x_px >= 0 and y_px >= 0 and x_px < W and y_px < H;
    var changed = false;

    if (primary and !state.primary_down) {
        if (!inside) return 0;
        state.primary_down = true;
        state.dragging = false;
        state.press_x = x_px;
        state.press_y = y_px;
        state.last_x = x_px;
        state.last_y = y_px;
        return 0;
    }

    if (primary and state.primary_down) {
        if (x_px < 0 and y_px < 0) return 0;
        if (!state.dragging) {
            const dx = x_px - state.press_x;
            const dy = y_px - state.press_y;
            if (dx * dx + dy * dy < DRAG_THRESHOLD * DRAG_THRESHOLD) return 0;
            state.dragging = true;
        }
        changed = panBy(state.last_x - x_px, state.last_y - y_px);
        state.last_x = x_px;
        state.last_y = y_px;
        if (changed) state.interacted = true;
        return if (changed) 1 else 0;
    }

    if (!primary and state.primary_down) {
        state.primary_down = false;
        if (!state.dragging and inside) {
            changed = zoomAt(@floatFromInt(x_px), @floatFromInt(y_px), 0.5);
        }
        state.dragging = false;
    }

    const secondary = (button_mask & BTN_SECONDARY) != 0;
    if (secondary and !state.secondary_down and inside and !state.primary_down) {
        _ = zoomAt(@floatFromInt(x_px), @floatFromInt(y_px), 2.0);
        // Accept the press even at the zoom limit so the browser does not open
        // its context menu.
        changed = true;
    }
    state.secondary_down = secondary;

    if (changed) state.interacted = true;
    return if (changed) 1 else 0;
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

fn requireEventPhase() void {
    if (phase != .updating) @trap();
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, W, H) orelse @trap();
    // The time-zero Content frame is complete; later frames show whatever the
    // updates have refined so far.
    if (phase == .initializing) {
        invalidateAll();
        _ = refine(std.math.maxInt(u64));
    }
    drawFrame();
    phase = .ready;
    return @intCast(OUTPUT_BYTES);
}

// ---- View changes --------------------------------------------------------------

fn panBy(dx: i64, dy: i64) bool {
    if (dx == 0 and dy == 0) return false;
    // Panning during a zoom lands the zoom first so the drag moves a still grid.
    if (state.zoom) |z| {
        setView(z.to);
        state.zoom = null;
    }
    var v = state.view;
    v.offset_x += dx;
    v.offset_y += dy;
    setView(v);
    return true;
}

// Zooms so the point under pixel (px, py) stays under it, scaling the span by
// `factor`. Repeated zooms during an animation build on its target.
fn zoomAt(px: f64, py: f64, factor: f64) bool {
    const from = state.view;
    const base = if (state.zoom) |z| z.to else from;
    const span = std.math.clamp(base.span * factor, MIN_SPAN, MAX_SPAN);
    if (span == base.span) return false;
    const fx = from.pointX(px - 0.5);
    const fy = from.pointY(py - 0.5);
    const step = span / @as(f64, W);
    const to = View.centered(
        fx - (px - @as(f64, W) * 0.5) * step,
        fy + (py - @as(f64, H) * 0.5) * step,
        span,
    );
    state.zoom = .{ .from = from, .to = to, .start_ms = now_ms };
    return true;
}

fn resetView() bool {
    const home: View = .{};
    const cur = state.view;
    if (state.zoom == null and cur.anchor_x == home.anchor_x and cur.anchor_y == home.anchor_y and
        cur.offset_x == 0 and cur.offset_y == 0 and cur.span == home.span) return false;
    state.zoom = null;
    setView(home);
    return true;
}

fn advanceZoom() void {
    const z = state.zoom orelse return;
    const elapsed = now_ms - z.start_ms;
    if (elapsed >= ZOOM_DURATION_MS) {
        setView(z.to);
        state.zoom = null;
        return;
    }
    const s = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ZOOM_DURATION_MS));
    const e = 1 - (1 - s) * (1 - s) * (1 - s);
    const a = z.from;
    const b = z.to;
    const span = a.span * std.math.pow(f64, b.span / a.span, e);
    // Moving the centre in proportion to the span keeps the zoom's focus point
    // fixed on screen for the whole animation.
    const k = if (b.span != a.span) (span - a.span) / (b.span - a.span) else e;
    const ax = a.centerX();
    const ay = a.centerY();
    setView(View.centered(ax + (b.centerX() - ax) * k, ay + (b.centerY() - ay) * k, span));
}

fn maxIterations(span: f64) u32 {
    const depth = @max(0, std.math.log2(HOME_SPAN / span));
    return @intFromFloat(@min(5000, 200 + depth * 110));
}

// ---- Iteration -----------------------------------------------------------------

// Smooth escape count per pixel for state.view; INTERIOR inside the set, NaN
// where nothing has been computed yet.
var counts: [W * H]f32 = undefined;
var scratch: [W * H]f32 = undefined;
var work_spent: u64 = 0;

// About 10 ms of iteration in V8.
const UPDATE_BUDGET: u64 = 6_000_000;
const UNKNOWN: f32 = std.math.nan(f32);
const BAILOUT2: f64 = 256.0 * 256.0;
const LOG2_LOG2_BAILOUT: f64 = 3.0; // log2(log2(256))

fn isKnownInterior(cx: f64, cy: f64) bool {
    const x = cx - 0.25;
    const y2 = cy * cy;
    const q = x * x + y2;
    if (q * (q + x) <= 0.25 * y2) return true;
    const bulb_x = cx + 1.0;
    return bulb_x * bulb_x + y2 <= 0.0625;
}

fn escapeCount(cx: f64, cy: f64, max_iter: u32, eps: f64) f32 {
    work_spent += 1;
    if (isKnownInterior(cx, cy)) return INTERIOR;
    var zx: f64 = 0;
    var zy: f64 = 0;
    var zx2: f64 = 0;
    var zy2: f64 = 0;
    // Brent-style periodicity check: an orbit that comes back to within `eps`
    // of a saved point has settled into a cycle and will not escape.
    var saved_x: f64 = 0;
    var saved_y: f64 = 0;
    var period_len: u32 = 8;
    var period_i: u32 = 0;
    var n: u32 = 0;
    while (n < max_iter) : (n += 1) {
        zy = 2 * zx * zy + cy;
        zx = zx2 - zy2 + cx;
        zx2 = zx * zx;
        zy2 = zy * zy;
        if (zx2 + zy2 > BAILOUT2) {
            // log2(log2|z|) = log2(0.5 * log2|z|^2)
            const nu = @as(f64, @floatFromInt(n + 1)) - (std.math.log2(0.5 * std.math.log2(zx2 + zy2)) - LOG2_LOG2_BAILOUT);
            work_spent += n + 1;
            return @floatCast(@max(0, nu));
        }
        if (@abs(zx - saved_x) + @abs(zy - saved_y) < eps) {
            work_spent += n + 1;
            return INTERIOR;
        }
        period_i += 1;
        if (period_i == period_len) {
            period_i = 0;
            period_len *= 2;
            saved_x = zx;
            saved_y = zy;
        }
    }
    work_spent += max_iter;
    return INTERIOR;
}

// ---- Tiles ---------------------------------------------------------------------
// The screen is covered by TILE x TILE tiles aligned to the view's whole-pixel
// grid. Screen tile (i, j) is grid tile (tileOrigin + i, tileOrigin + j). Each
// tile records how far it has been refined.

const TILE: usize = 8;
const TILES_X: usize = W / TILE + 1;
const TILES_Y: usize = H / TILE + 1;
const LEVEL_EXACT: u8 = 3;
var levels: [TILES_X * TILES_Y]u8 = undefined;
var tile_order: [TILES_X * TILES_Y]u16 = undefined;
var tile_order_ready = false;
var tile_buf: [TILE * TILE]f32 = undefined;

fn tileOriginX(v: View) i64 {
    return @divFloor(v.offset_x, @as(i64, TILE));
}

fn tileOriginY(v: View) i64 {
    return @divFloor(v.offset_y, @as(i64, TILE));
}

// Screen x of the left edge of screen tile column i (can be negative).
fn tileScreenX(v: View, i: usize) i64 {
    return (tileOriginX(v) + @as(i64, @intCast(i))) * @as(i64, TILE) - v.offset_x;
}

fn tileScreenY(v: View, j: usize) i64 {
    return (tileOriginY(v) + @as(i64, @intCast(j))) * @as(i64, TILE) - v.offset_y;
}

fn invalidateAll() void {
    @memset(&counts, UNKNOWN);
    @memset(&levels, 0);
}

// Refines tiles nearest the centre first, coarsest level first, until `budget`
// iterations are spent. Returns whether any tile still needs work.
fn refine(budget: u64) bool {
    if (!tile_order_ready) buildTileOrder();
    work_spent = 0;
    const v = state.view;
    const max_iter = maxIterations(v.span);
    var level: u8 = 1;
    while (level <= LEVEL_EXACT) : (level += 1) {
        for (tile_order) |t| {
            if (levels[t] >= level) continue;
            if (work_spent >= budget) return true;
            refineTile(v, t % TILES_X, t / TILES_X, level, max_iter);
            levels[t] = level;
        }
    }
    return false;
}

fn buildTileOrder() void {
    for (&tile_order, 0..) |*t, i| t.* = @intCast(i);
    std.sort.pdq(u16, &tile_order, {}, struct {
        fn dist(t: u16) usize {
            const x: isize = @as(isize, @intCast(t % TILES_X)) * 2 - @as(isize, TILES_X - 1);
            const y: isize = @as(isize, @intCast(t / TILES_X)) * 2 - @as(isize, TILES_Y - 1);
            return @intCast(x * x + y * y);
        }
        fn lessThan(_: void, a: u16, b: u16) bool {
            const da = dist(a);
            const db = dist(b);
            return if (da != db) da < db else a < b;
        }
    }.lessThan);
    tile_order_ready = true;
}

// Sample at doubled grid coordinates (2 * pixel + 1 is a pixel centre), so
// every sample position is exact in f64.
fn sampleAt(v: View, gx2: i64, gy2: i64, max_iter: u32, eps: f64) f32 {
    const step = v.step();
    const cx = v.anchor_x + (@as(f64, @floatFromInt(gx2)) * 0.5 - @as(f64, W) * 0.5) * step;
    const cy = v.anchor_y - (@as(f64, @floatFromInt(gy2)) * 0.5 - @as(f64, H) * 0.5) * step;
    return escapeCount(cx, cy, max_iter, eps);
}

fn refineTile(v: View, i: usize, j: usize, level: u8, max_iter: u32) void {
    const eps = v.step() * 1e-3;
    const gx: i64 = (tileOriginX(v) + @as(i64, @intCast(i))) * @as(i64, TILE);
    const gy: i64 = (tileOriginY(v) + @as(i64, @intCast(j))) * @as(i64, TILE);
    if (level < LEVEL_EXACT) {
        // One sample at the centre of each stride x stride block.
        const stride: usize = if (level == 1) 4 else 2;
        var by: usize = 0;
        while (by < TILE) : (by += stride) {
            var bx: usize = 0;
            while (bx < TILE) : (bx += stride) {
                const c = sampleAt(v, 2 * (gx + @as(i64, @intCast(bx))) + @as(i64, @intCast(stride)), 2 * (gy + @as(i64, @intCast(by))) + @as(i64, @intCast(stride)), max_iter, eps);
                for (0..stride) |dy| {
                    for (0..stride) |dx| tile_buf[(by + dy) * TILE + bx + dx] = c;
                }
            }
        }
    } else {
        // Every pixel. A tile whose border is entirely inside the set is filled
        // without iterating its middle: the set is connected and has no holes,
        // so nothing outside it can be enclosed by the border.
        var all_interior = true;
        for (0..TILE) |y| {
            for (0..TILE) |x| {
                if (x != 0 and y != 0 and x != TILE - 1 and y != TILE - 1) continue;
                const c = sampleAt(v, 2 * (gx + @as(i64, @intCast(x))) + 1, 2 * (gy + @as(i64, @intCast(y))) + 1, max_iter, eps);
                tile_buf[y * TILE + x] = c;
                if (!(c < 0)) all_interior = false;
            }
        }
        for (1..TILE - 1) |y| {
            for (1..TILE - 1) |x| {
                tile_buf[y * TILE + x] = if (all_interior) INTERIOR else sampleAt(v, 2 * (gx + @as(i64, @intCast(x))) + 1, 2 * (gy + @as(i64, @intCast(y))) + 1, max_iter, eps);
            }
        }
    }
    // Copy the on-screen part of the tile.
    const sx = tileScreenX(v, i);
    const sy = tileScreenY(v, j);
    for (0..TILE) |y| {
        const py = sy + @as(i64, @intCast(y));
        if (py < 0 or py >= H) continue;
        for (0..TILE) |x| {
            const px = sx + @as(i64, @intCast(x));
            if (px < 0 or px >= W) continue;
            counts[@as(usize, @intCast(py)) * W + @as(usize, @intCast(px))] = tile_buf[y * TILE + x];
        }
    }
}

fn sameGrid(a: View, b: View) bool {
    return a.anchor_x == b.anchor_x and a.anchor_y == b.anchor_y and a.span == b.span;
}

// Moves to a new view, carrying over whatever counts still apply.
fn setView(nv: View) void {
    const old = state.view;
    state.view = nv;
    if (std.meta.eql(old, nv)) return;
    if (sameGrid(old, nv) and @abs(nv.offset_x - old.offset_x) < W and @abs(nv.offset_y - old.offset_y) < H) {
        shiftCounts(old, nv);
    } else {
        resampleCounts(old, nv);
    }
}

// Same grid, new whole-pixel offset: move pixels and tile levels, and mark the
// tiles that touch the newly exposed strips as unrefined.
fn shiftCounts(old: View, nv: View) void {
    const dx = nv.offset_x - old.offset_x;
    const dy = nv.offset_y - old.offset_y;
    @memcpy(&scratch, &counts);
    for (0..H) |y| {
        const oy = @as(i64, @intCast(y)) + dy;
        const row = counts[y * W ..][0..W];
        if (oy < 0 or oy >= H) {
            @memset(row, UNKNOWN);
            continue;
        }
        const src = scratch[@as(usize, @intCast(oy)) * W ..][0..W];
        for (row, 0..) |*c, x| {
            const ox = @as(i64, @intCast(x)) + dx;
            c.* = if (ox < 0 or ox >= W) UNKNOWN else src[@intCast(ox)];
        }
    }

    const dtx = tileOriginX(nv) - tileOriginX(old);
    const dty = tileOriginY(nv) - tileOriginY(old);
    var old_levels: [TILES_X * TILES_Y]u8 = undefined;
    @memcpy(&old_levels, &levels);
    for (0..TILES_Y) |j| {
        for (0..TILES_X) |i| {
            const oi = @as(i64, @intCast(i)) + dtx;
            const oj = @as(i64, @intCast(j)) + dty;
            var level: u8 = 0;
            if (oi >= 0 and oi < TILES_X and oj >= 0 and oj < TILES_Y) {
                level = old_levels[@as(usize, @intCast(oj)) * TILES_X + @as(usize, @intCast(oi))];
            }
            // A tile is only as good as its worst on-screen pixel; any pixel
            // that was off screen in the old view is unknown now.
            const sx = tileScreenX(nv, i);
            const sy = tileScreenY(nv, j);
            const x0 = @max(sx, 0) + dx;
            const x1 = @min(sx + @as(i64, TILE), W) + dx;
            const y0 = @max(sy, 0) + dy;
            const y1 = @min(sy + @as(i64, TILE), H) + dy;
            if (x0 < 0 or y0 < 0 or x1 > W or y1 > H) level = 0;
            levels[j * TILES_X + i] = level;
        }
    }
}

// New scale or anchor: resample the old counts at the nearest old pixel so the
// picture follows the zoom immediately, and mark every tile unrefined.
fn resampleCounts(old: View, nv: View) void {
    @memcpy(&scratch, &counts);
    var map_x: [W]i32 = undefined;
    var map_y: [H]i32 = undefined;
    const old_step = old.step();
    const old_x0 = old.pointX(0);
    const old_y0 = old.pointY(0);
    for (&map_x, 0..) |*m, x| {
        const f = @round((nv.pointX(@floatFromInt(x)) - old_x0) / old_step);
        m.* = if (f >= 0 and f < W) @intFromFloat(f) else -1;
    }
    for (&map_y, 0..) |*m, y| {
        const f = @round((old_y0 - nv.pointY(@floatFromInt(y))) / old_step);
        m.* = if (f >= 0 and f < H) @intFromFloat(f) else -1;
    }
    for (0..H) |y| {
        const row = counts[y * W ..][0..W];
        if (map_y[y] < 0) {
            @memset(row, UNKNOWN);
            continue;
        }
        const src = scratch[@as(usize, @intCast(map_y[y])) * W ..][0..W];
        for (row, map_x) |*c, mx| c.* = if (mx < 0) UNKNOWN else src[@intCast(mx)];
    }
    @memset(&levels, 0);
}

// ---- Colour --------------------------------------------------------------------

const Color = [3]u8;
const Stop = struct { t: f32, c: Color };

const palettes = [_][]const Stop{
    // Deep blue through white to amber.
    &.{
        .{ .t = 0.0, .c = .{ 0x00, 0x07, 0x64 } },
        .{ .t = 0.16, .c = .{ 0x20, 0x6B, 0xCB } },
        .{ .t = 0.42, .c = .{ 0xED, 0xFF, 0xFF } },
        .{ .t = 0.6425, .c = .{ 0xFF, 0xAA, 0x00 } },
        .{ .t = 0.8575, .c = .{ 0x30, 0x02, 0x00 } },
        .{ .t = 1.0, .c = .{ 0x00, 0x07, 0x64 } },
    },
    // Embers.
    &.{
        .{ .t = 0.0, .c = .{ 0x0B, 0x02, 0x10 } },
        .{ .t = 0.25, .c = .{ 0x7A, 0x0E, 0x2A } },
        .{ .t = 0.5, .c = .{ 0xF2, 0x6B, 0x1D } },
        .{ .t = 0.7, .c = .{ 0xFF, 0xE3, 0x8A } },
        .{ .t = 0.85, .c = .{ 0x6E, 0x2A, 0x5C } },
        .{ .t = 1.0, .c = .{ 0x0B, 0x02, 0x10 } },
    },
    // Teal and ivory.
    &.{
        .{ .t = 0.0, .c = .{ 0x03, 0x14, 0x1C } },
        .{ .t = 0.3, .c = .{ 0x0E, 0x6E, 0x73 } },
        .{ .t = 0.55, .c = .{ 0xC9, 0xF2, 0xE4 } },
        .{ .t = 0.75, .c = .{ 0x3E, 0x9E, 0x8F } },
        .{ .t = 1.0, .c = .{ 0x03, 0x14, 0x1C } },
    },
};
const palette_interior = [_]Color{ .{ 0x00, 0x00, 0x00 }, .{ 0x05, 0x01, 0x08 }, .{ 0x01, 0x0A, 0x0E } };

const LUT_SIZE: usize = 1024;

fn buildLut(stops: []const Stop) [LUT_SIZE]Color {
    var lut: [LUT_SIZE]Color = undefined;
    for (0..LUT_SIZE) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, LUT_SIZE);
        var s: usize = 0;
        while (s + 2 < stops.len and stops[s + 1].t <= t) s += 1;
        const a = stops[s];
        const b = stops[s + 1];
        // Smoothstep between stops avoids visible creases at each stop.
        const u = std.math.clamp((t - a.t) / (b.t - a.t), 0, 1);
        const w = u * u * (3 - 2 * u);
        for (0..3) |ch| {
            const av: f32 = @floatFromInt(a.c[ch]);
            const bv: f32 = @floatFromInt(b.c[ch]);
            lut[i][ch] = @intFromFloat(@round(av + (bv - av) * w));
        }
    }
    return lut;
}

const luts = blk: {
    @setEvalBranchQuota(200_000);
    var out: [palettes.len][LUT_SIZE]Color = undefined;
    for (palettes, 0..) |p, i| out[i] = buildLut(p);
    break :blk out;
};

fn colorize() void {
    const lut = &luts[state.palette];
    const inside = palette_interior[state.palette];
    const px = output_buf[ktx.HEADER_SIZE..];
    for (&counts, 0..) |c, i| {
        const rgb = if (!(c >= 0)) inside else blk: {
            // The square root keeps colour bands a similar width as counts grow
            // with depth.
            const t = @sqrt(c) * 0.11 + 0.02;
            const idx: usize = @intFromFloat((t - @floor(t)) * @as(f32, LUT_SIZE));
            break :blk lut[@min(idx, LUT_SIZE - 1)];
        };
        px[i * 4 + 0] = rgb[0];
        px[i * 4 + 1] = rgb[1];
        px[i * 4 + 2] = rgb[2];
        px[i * 4 + 3] = 0xFF;
    }
}

// ---- Frame ---------------------------------------------------------------------

fn drawFrame() void {
    colorize();
    if (state.show_hud) drawHud();
}

const HUD_PX: f32 = 26;
const HINT_PX: f32 = 24;
const HUD_MARGIN: f32 = 20;
const HUD_PAD_X: f32 = 18;
const HUD_H: f32 = 48;
const C_TEXT: Color = .{ 0xF4, 0xF5, 0xF7 };
const C_DIM: Color = .{ 0xA9, 0xAE, 0xBA };
const C_PILL: Color = .{ 0x0B, 0x0D, 0x12 };

fn drawHud() void {
    const v = state.view;
    var coords: TextBuf = .{};
    // Enough decimals that the last digit changes about once per pixel.
    const decimals: usize = @intFromFloat(std.math.clamp(@ceil(-std.math.log10(v.step())), 2, 15));
    formatFixed(&coords, v.centerX(), decimals);
    coords.add(if (v.centerY() < 0) " − " else " + ");
    formatFixed(&coords, @abs(v.centerY()), decimals);
    coords.add("i");

    var zoom: TextBuf = .{};
    zoom.add("×");
    formatMagnification(&zoom, HOME_SPAN / v.span);

    const coord_w = textWidth(coords.slice(), HUD_PX, true);
    const zoom_w = textWidth(zoom.slice(), HUD_PX, true);
    const gap: f32 = 26;
    const pill_w = HUD_PAD_X * 2 + coord_w + gap + zoom_w;
    const top = @as(f32, H) - HUD_MARGIN - HUD_H;
    fillRoundRect(.{ .x = HUD_MARGIN, .y = top, .w = pill_w, .h = HUD_H }, HUD_H * 0.5, C_PILL, 0.62);
    const baseline = top + HUD_H * 0.5 + CAP_HEIGHT * HUD_PX / font.UNITS_PER_EM * 0.5;
    drawText(coords.slice(), HUD_MARGIN + HUD_PAD_X, baseline, HUD_PX, true, C_TEXT);
    drawText(zoom.slice(), HUD_MARGIN + HUD_PAD_X + coord_w + gap, baseline, HUD_PX, true, C_DIM);

    if (!state.interacted) {
        const hint = hint_text;
        const hint_w = textWidth(hint, HINT_PX, false);
        const hint_pill_w = hint_w + HUD_PAD_X * 2;
        const hx = (@as(f32, W) - hint_pill_w) * 0.5;
        const hy = HUD_MARGIN;
        fillRoundRect(.{ .x = hx, .y = hy, .w = hint_pill_w, .h = HUD_H }, HUD_H * 0.5, C_PILL, 0.62);
        const hb = hy + HUD_H * 0.5 + CAP_HEIGHT * HINT_PX / font.UNITS_PER_EM * 0.5;
        drawText(hint, hx + HUD_PAD_X, hb, HINT_PX, false, C_TEXT);
    }
}

// ---- Number formatting -------------------------------------------------------------

const TextBuf = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn add(self: *TextBuf, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn addDigits(self: *TextBuf, value: u64, min_digits: usize) void {
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        var x = value;
        while (x > 0 or n < min_digits) : (n += 1) {
            tmp[tmp.len - 1 - n] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
        }
        self.add(tmp[tmp.len - n ..]);
    }

    fn slice(self: *const TextBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

// Formats with a fixed number of decimals. Values stay within |v| < 10, so the
// scaled integer fits in a u64 for up to 15 decimals.
fn formatFixed(out: *TextBuf, v: f64, decimals: usize) void {
    if (v < 0) out.add("−");
    const scale = std.math.pow(f64, 10, @floatFromInt(decimals));
    const clamped = @min(@abs(v), 9.0);
    const scaled: u64 = @intFromFloat(@round(clamped * scale));
    const unit: u64 = @intFromFloat(scale);
    out.addDigits(scaled / unit, 1);
    out.add(".");
    out.addDigits(scaled % unit, decimals);
}

// 1,234× below a million, then 3.4e9× style.
fn formatMagnification(out: *TextBuf, m: f64) void {
    if (m < 9.95) {
        const tenths: u64 = @intFromFloat(@round(m * 10));
        out.addDigits(tenths / 10, 1);
        if (tenths % 10 != 0) {
            out.add(".");
            out.addDigits(tenths % 10, 1);
        }
        return;
    }
    if (m < 999_999.5) {
        const n: u64 = @intFromFloat(@round(m));
        var groups: [3]u64 = undefined;
        var count: usize = 0;
        var x = n;
        while (true) {
            groups[count] = x % 1000;
            count += 1;
            x /= 1000;
            if (x == 0) break;
        }
        var i = count;
        while (i > 0) {
            i -= 1;
            out.addDigits(groups[i], if (i == count - 1) 1 else 3);
            if (i > 0) out.add(",");
        }
        return;
    }
    var exp: i32 = @intFromFloat(@floor(std.math.log10(m)));
    var mant = m / std.math.pow(f64, 10, @floatFromInt(exp));
    var tenths: u64 = @intFromFloat(@round(mant * 10));
    if (tenths >= 100) {
        exp += 1;
        mant /= 10;
        tenths = @intFromFloat(@round(mant * 10));
    }
    out.addDigits(tenths / 10, 1);
    out.add(".");
    out.addDigits(tenths % 10, 1);
    out.add("e");
    out.addDigits(@intCast(exp), 1);
}

// ---- Glyphs ------------------------------------------------------------------------
// Only the glyphs the HUD draws are copied out of the font.

const Glyph = struct { codepoint: u21, advance: f32, path: []const u8 };

const hint_text = "Click to zoom in · Right-click to zoom out · Drag to pan";
const glyph_set = "0123456789.,+−×ei ·-CDRacdghiklmnoprtuz";

const glyphs = blk: {
    @setEvalBranchQuota(100_000);
    const view = std.unicode.Utf8View.initComptime(glyph_set);
    var it = view.iterator();
    var list: []const Glyph = &.{};
    while (it.nextCodepoint()) |cp| {
        const index = font.glyphIndex(cp) orelse @compileError("missing glyph");
        list = list ++ [_]Glyph{.{ .codepoint = cp, .advance = font.advances[index], .path = font.glyph_paths[index] }};
    }
    break :blk list[0..list.len].*;
};

comptime {
    @setEvalBranchQuota(100_000);
    var it = std.unicode.Utf8View.initComptime(hint_text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (std.mem.indexOf(u8, glyph_set, &std.unicode.utf8EncodeComptime(cp)) == null) {
            @compileError("hint_text uses a glyph missing from glyph_set");
        }
    }
}

// Digits share one advance so the coordinates do not jitter while panning.
const TABULAR_ADVANCE: f32 = blk: {
    var widest: f32 = 0;
    for (glyphs) |g| {
        if (g.codepoint >= '0' and g.codepoint <= '9') widest = @max(widest, g.advance);
    }
    break :blk widest;
};
const CAP_HEIGHT: f32 = 1490;

fn glyphFor(cp: u21) ?*const Glyph {
    for (&glyphs) |*g| {
        if (g.codepoint == cp) return g;
    }
    return null;
}

fn glyphAdvance(g: *const Glyph, tabular: bool) f32 {
    return if (tabular and g.codepoint >= '0' and g.codepoint <= '9') TABULAR_ADVANCE else g.advance;
}

fn textWidth(text: []const u8, size_px: f32, tabular: bool) f32 {
    var width: f32 = 0;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (glyphFor(cp)) |g| width += glyphAdvance(g, tabular);
    }
    return width * size_px / font.UNITS_PER_EM;
}

fn drawText(text: []const u8, left: f32, baseline: f32, size_px: f32, tabular: bool, c: Color) void {
    const scale = size_px / font.UNITS_PER_EM;
    var x = left;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        const g = glyphFor(cp) orelse continue;
        const advance = glyphAdvance(g, tabular);
        const inset = (advance - g.advance) * 0.5 * scale;
        drawPath(g.path, @round(x + inset), baseline, scale, c);
        x += advance * scale;
    }
}

// ---- Path rasterizer ---------------------------------------------------------------
// Glyph outlines are M/L/Q/Z paths in font units with y pointing down. Each
// outline is flattened to lines and accumulated as signed area per pixel, which
// gives exact coverage for the nonzero fill rule.

const ACC_W: usize = 96;
const ACC_H: usize = 96;
var acc: [ACC_W * ACC_H]f32 = undefined;

const Pt = struct { x: f32, y: f32 };

const PathReader = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSpace(self: *PathReader) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == ',')) self.i += 1;
    }

    fn command(self: *PathReader) ?u8 {
        self.skipSpace();
        if (self.i >= self.s.len) return null;
        const ch = self.s[self.i];
        self.i += 1;
        return ch;
    }

    fn number(self: *PathReader) f32 {
        self.skipSpace();
        var negative = false;
        if (self.i < self.s.len and self.s[self.i] == '-') {
            negative = true;
            self.i += 1;
        }
        var value: f32 = 0;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') : (self.i += 1) {
            value = value * 10 + @as(f32, @floatFromInt(self.s[self.i] - '0'));
        }
        if (self.i < self.s.len and self.s[self.i] == '.') {
            self.i += 1;
            var place: f32 = 0.1;
            while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') : (self.i += 1) {
                value += place * @as(f32, @floatFromInt(self.s[self.i] - '0'));
                place *= 0.1;
            }
        }
        return if (negative) -value else value;
    }

    fn point(self: *PathReader) Pt {
        const x = self.number();
        return .{ .x = x, .y = self.number() };
    }
};

fn walkPath(path: []const u8, sink: anytype) void {
    var r: PathReader = .{ .s = path };
    var start: Pt = .{ .x = 0, .y = 0 };
    var cur = start;
    while (r.command()) |cmd| {
        switch (cmd) {
            'M' => {
                if (cur.x != start.x or cur.y != start.y) sink.line(cur, start);
                start = r.point();
                cur = start;
            },
            'L' => {
                const p = r.point();
                sink.line(cur, p);
                cur = p;
            },
            'Q' => {
                const c = r.point();
                const p = r.point();
                const steps = 6;
                var prev = cur;
                for (1..steps + 1) |s| {
                    const t = @as(f32, @floatFromInt(s)) / steps;
                    const u = 1 - t;
                    const q: Pt = .{
                        .x = u * u * cur.x + 2 * u * t * c.x + t * t * p.x,
                        .y = u * u * cur.y + 2 * u * t * c.y + t * t * p.y,
                    };
                    sink.line(prev, q);
                    prev = q;
                }
                cur = p;
            },
            'Z' => {
                sink.line(cur, start);
                cur = start;
            },
            else => return,
        }
    }
    if (cur.x != start.x or cur.y != start.y) sink.line(cur, start);
}

const Bounds = struct {
    min_x: f32 = std.math.inf(f32),
    min_y: f32 = std.math.inf(f32),
    max_x: f32 = -std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),

    fn line(self: *Bounds, a: Pt, b: Pt) void {
        _ = b;
        self.min_x = @min(self.min_x, a.x);
        self.max_x = @max(self.max_x, a.x);
        self.min_y = @min(self.min_y, a.y);
        self.max_y = @max(self.max_y, a.y);
    }
};

const Accumulator = struct {
    ox: f32,
    oy: f32,
    scale: f32,
    w: usize,
    h: usize,

    fn line(self: *Accumulator, a: Pt, b: Pt) void {
        accumulateLine(
            .{ .x = a.x * self.scale + self.ox, .y = a.y * self.scale + self.oy },
            .{ .x = b.x * self.scale + self.ox, .y = b.y * self.scale + self.oy },
            self.w,
            self.h,
        );
    }
};

fn accumulateLine(a: Pt, b: Pt, w: usize, h: usize) void {
    if (a.y == b.y) return;
    const dir: f32 = if (a.y < b.y) 1 else -1;
    const p0 = if (a.y < b.y) a else b;
    const p1 = if (a.y < b.y) b else a;
    const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
    var x = p0.x;
    const y_start: usize = @intFromFloat(@max(0, @floor(p0.y)));
    const y_end: usize = @min(h, @as(usize, @intFromFloat(@max(0, @ceil(p1.y)))));
    if (p0.y < 0) x -= p0.y * dxdy;
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const row = y * ACC_W;
        const fy: f32 = @floatFromInt(y);
        const dy = @min(fy + 1, p1.y) - @max(fy, p0.y);
        const xnext = x + dxdy * dy;
        const d = dy * dir;
        const x0 = @max(0, @min(x, xnext));
        const x1 = @min(@as(f32, @floatFromInt(w)), @max(x, xnext));
        const x0floor = @floor(x0);
        const x0i: usize = @intFromFloat(x0floor);
        const x1ceil = @ceil(x1);
        const x1i: usize = @intFromFloat(x1ceil);
        if (x1i <= x0i + 1) {
            const xmf = 0.5 * (x + xnext) - x0floor;
            acc[row + x0i] += d - d * xmf;
            acc[row + x0i + 1] += d * xmf;
        } else {
            const s = 1 / (x1 - x0);
            const x0f = x0 - x0floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = x1 - x1ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            acc[row + x0i] += d * a0;
            if (x1i == x0i + 2) {
                acc[row + x0i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                acc[row + x0i + 1] += d * (a1 - a0);
                var xi = x0i + 2;
                while (xi < x1i - 1) : (xi += 1) acc[row + xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                acc[row + x1i - 1] += d * (1 - a2 - am);
            }
            acc[row + x1i] += d * am;
        }
        x = xnext;
    }
}

fn drawPath(path: []const u8, origin_x: f32, origin_y: f32, scale: f32, c: Color) void {
    var bounds: Bounds = .{};
    walkPath(path, &bounds);
    if (bounds.min_x > bounds.max_x) return;
    const left = @floor(origin_x + bounds.min_x * scale) - 1;
    const top = @floor(origin_y + bounds.min_y * scale) - 1;
    const w: usize = @min(ACC_W - 2, @as(usize, @intFromFloat(@ceil(origin_x + bounds.max_x * scale) + 1 - left)));
    const h: usize = @min(ACC_H, @as(usize, @intFromFloat(@ceil(origin_y + bounds.max_y * scale) + 1 - top)));
    for (0..h) |y| @memset(acc[y * ACC_W ..][0 .. w + 2], 0);
    var sink: Accumulator = .{ .ox = origin_x - left, .oy = origin_y - top, .scale = scale, .w = w, .h = h };
    walkPath(path, &sink);
    const left_i: i32 = @intFromFloat(left);
    const top_i: i32 = @intFromFloat(top);
    for (0..h) |y| {
        var sum: f32 = 0;
        for (0..w) |x| {
            sum += acc[y * ACC_W + x];
            const coverage = @min(1, @abs(sum));
            if (coverage > 0.002) blend(left_i + @as(i32, @intCast(x)), top_i + @as(i32, @intCast(y)), c, coverage);
        }
    }
}

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

fn fillRoundRect(r: Rect, radius: f32, c: Color, alpha: f32) void {
    const x0: i32 = @intFromFloat(@floor(r.x));
    const x1: i32 = @intFromFloat(@ceil(r.x + r.w));
    const y0: i32 = @intFromFloat(@floor(r.y));
    const y1: i32 = @intFromFloat(@ceil(r.y + r.h));
    const hx = r.w * 0.5 - radius;
    const hy = r.h * 0.5 - radius;
    const cx = r.x + r.w * 0.5;
    const cy = r.y + r.h * 0.5;
    var y = y0;
    while (y < y1) : (y += 1) {
        const qy = @max(@abs(@as(f32, @floatFromInt(y)) + 0.5 - cy) - hy, 0);
        var x = x0;
        while (x < x1) : (x += 1) {
            const qx = @max(@abs(@as(f32, @floatFromInt(x)) + 0.5 - cx) - hx, 0);
            const coverage = std.math.clamp(radius + 0.5 - @sqrt(qx * qx + qy * qy), 0, 1);
            if (coverage > 0) blend(x, y, c, coverage * alpha);
        }
    }
}

fn blend(x: i32, y: i32, c: Color, coverage: f32) void {
    if (x < 0 or y < 0 or x >= W or y >= H) return;
    const idx = ktx.HEADER_SIZE + (@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))) * 4;
    for (0..3) |i| {
        const dst: f32 = @floatFromInt(output_buf[idx + i]);
        const src: f32 = @floatFromInt(c[i]);
        output_buf[idx + i] = @intFromFloat(@round(dst + (src - dst) * coverage));
    }
}

// ---- Tests ---------------------------------------------------------------------------

fn resetForTest() void {
    state = .{};
    phase = .ready;
    now_ms = 0;
    committed_at_ms = 0;
    invalidateAll();
}

test "known Mandelbrot interiors skip iteration" {
    try std.testing.expect(isKnownInterior(0.0, 0.0));
    try std.testing.expect(isKnownInterior(-1.0, 0.0));
    try std.testing.expect(!isKnownInterior(1.0, 1.0));
}

test "escape counts are smooth and interior points never escape" {
    try std.testing.expectEqual(INTERIOR, escapeCount(-0.1, 0.0, 500, 1e-9));
    // Period-3 bulb, outside the cardioid and period-2 checks.
    try std.testing.expectEqual(INTERIOR, escapeCount(-0.122, 0.745, 5000, 1e-9));
    const a = escapeCount(0.3, 0.0, 500, 1e-9);
    const b = escapeCount(0.3001, 0.0, 500, 1e-9);
    try std.testing.expect(a > 0 and b > 0);
    try std.testing.expect(@abs(a - b) < 0.5);
}

test "iteration limit grows with zoom" {
    try std.testing.expectEqual(@as(u32, 200), maxIterations(HOME_SPAN));
    try std.testing.expect(maxIterations(HOME_SPAN / 1024) > maxIterations(HOME_SPAN / 2));
    try std.testing.expect(maxIterations(MIN_SPAN) <= 5000);
}

test "a zoom keeps the clicked point under the pointer" {
    resetForTest();
    const before = state.view;
    const px: f64 = 700;
    const py: f64 = 150;
    const fx = before.pointX(px - 0.5);
    const fy = before.pointY(py - 0.5);
    now_ms = 10;
    try std.testing.expect(zoomAt(px, py, 0.5));
    now_ms = 10 + ZOOM_DURATION_MS / 2;
    advanceZoom();
    try std.testing.expect(state.zoom != null);
    try std.testing.expectApproxEqAbs(fx, state.view.pointX(px - 0.5), 1e-12);
    try std.testing.expectApproxEqAbs(fy, state.view.pointY(py - 0.5), 1e-12);
    now_ms = 10 + ZOOM_DURATION_MS;
    advanceZoom();
    try std.testing.expect(state.zoom == null);
    try std.testing.expectEqual(before.span * 0.5, state.view.span);
    try std.testing.expectApproxEqAbs(fx, state.view.pointX(px - 0.5), 1e-12);
}

test "panned frames match the same view refined from scratch" {
    resetForTest();
    setView(View.centered(-0.745, 0.11, 0.05));
    invalidateAll();
    try std.testing.expect(!refine(std.math.maxInt(u64)));
    var v = state.view;
    v.offset_x += 37;
    v.offset_y -= 23;
    setView(v);
    try std.testing.expect(refine(std.math.maxInt(u64)) == false);
    const shifted = try std.testing.allocator.dupe(f32, &counts);
    defer std.testing.allocator.free(shifted);
    invalidateAll();
    _ = refine(std.math.maxInt(u64));
    try std.testing.expectEqualSlices(f32, &counts, shifted);
}

test "refinement stops at the budget and resumes" {
    resetForTest();
    setView(View.centered(-0.7436, 0.1318, 0.001));
    invalidateAll();
    try std.testing.expect(refine(100_000));
    try std.testing.expect(work_spent >= 100_000);
    // The centre is refined first.
    try std.testing.expect(!std.math.isNan(counts[(H / 2) * W + W / 2]));
    var rounds: usize = 0;
    while (refine(UPDATE_BUDGET)) rounds += 1;
    try std.testing.expect(rounds > 0);
    for (counts) |c| try std.testing.expect(!std.math.isNan(c));
    for (levels) |l| try std.testing.expectEqual(LEVEL_EXACT, l);
}

test "number formatting" {
    var t: TextBuf = .{};
    formatFixed(&t, -0.7436438, 4);
    try std.testing.expectEqualStrings("−0.7436", t.slice());
    t = .{};
    formatMagnification(&t, 1.0);
    try std.testing.expectEqualStrings("1", t.slice());
    t = .{};
    formatMagnification(&t, 1520.4);
    try std.testing.expectEqualStrings("1,520", t.slice());
    t = .{};
    formatMagnification(&t, 2.46e9);
    try std.testing.expectEqualStrings("2.5e9", t.slice());
}
