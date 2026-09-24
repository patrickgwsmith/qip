const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const ui_font = @import("assets/dejavu_sans_mono_56_ascii_subset.zig");

const DISPLAY_W: usize = 900;
const DISPLAY_H: usize = 420;
const SCALE: i32 = 2;
const SCALE_USIZE: usize = 2;
const RENDER_W: usize = DISPLAY_W * SCALE_USIZE;
const RENDER_H: usize = DISPLAY_H * SCALE_USIZE;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

const ICON_N: usize = 10;
const BASE_ICON: i32 = 96;
const MAX_ICON: i32 = 196;
const ICON_GAP: i32 = 18;
const DIVIDER_GAP: i32 = 34;
const MAG_RADIUS: i32 = 260;
const ICON_BOTTOM: i32 = @as(i32, @intCast(RENDER_H)) - 84;
const SHELF_TOP: i32 = ICON_BOTTOM - 38;
const SHELF_H: i32 = 104;
const DOCK_CENTER_X: i32 = @as(i32, @intCast(RENDER_W / 2));
const BOUNCE_HOP_FRAMES: i32 = 22;
const BOUNCE_TOTAL_FRAMES: i32 = BOUNCE_HOP_FRAMES * 3;
const HOVER_EASE_FRAMES: i32 = 12;
const EASE_SCALE: i32 = 1024;

const Color = u32;

const PointF = struct {
    x: f32,
    y: f32,
};

const Span = struct {
    start: i32,
    end: i32,
};

const IconKind = enum(u8) {
    finder,
    browser,
    mail,
    calendar,
    photos,
    music,
    terminal,
    settings,
    notes,
    trash,
};

const Icon = struct {
    kind: IconKind,
    label: []const u8,
};

const Layout = struct {
    x: [ICON_N]i32,
    size: [ICON_N]i32,
    top: [ICON_N]i32,
    center: [ICON_N]i32,
    total_w: i32,
};

const icons = [_]Icon{
    .{ .kind = .finder, .label = "FINDER" },
    .{ .kind = .browser, .label = "SAFARI" },
    .{ .kind = .mail, .label = "MAIL" },
    .{ .kind = .calendar, .label = "CALENDAR" },
    .{ .kind = .photos, .label = "PHOTOS" },
    .{ .kind = .music, .label = "MUSIC" },
    .{ .kind = .terminal, .label = "TERMINAL" },
    .{ .kind = .settings, .label = "SETTINGS" },
    .{ .kind = .notes, .label = "NOTES" },
    .{ .kind = .trash, .label = "TRASH" },
};

const initial_app_open = [_]bool{
    true, // Finder
    true, // Safari
    true, // Mail
    false,
    false,
    false,
    true, // Terminal
    false,
    false,
    false, // Trash is never treated as an app.
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var pointer_x: i32 = DOCK_CENTER_X;
var pointer_y: i32 = ICON_BOTTOM - 24;
var pointer_seen = false;
var primary_down = false;
var bounce_index: i32 = -1;
var bounce_frame: i32 = 0;
var hover_ease_frame: i32 = 0;
var hover_ease_animating = false;
var app_open = initial_app_open;
var needs_redraw = true;

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
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    if (x11_key == 'r' or x11_key == 'R') {
        bounce_index = -1;
        bounce_frame = 0;
        resetAppOpenState();
        needs_redraw = true;
        return 1;
    }
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    advanceTransactionTime();
    const old_x = pointer_x;
    const old_y = pointer_y;
    const was_seen = pointer_seen;
    const was_hover = dockHoverActive();
    const was_primary_down = primary_down;
    pointer_x = clampI32(x_px, 0, @as(i32, @intCast(RENDER_W)) - 1);
    pointer_y = clampI32(y_px, 0, @as(i32, @intCast(RENDER_H)) - 1);
    pointer_seen = true;
    const is_hover = dockHoverActive();
    var redraw = false;
    if (is_hover and !was_hover) {
        hover_ease_frame = 0;
        hover_ease_animating = true;
        redraw = true;
    } else if (!is_hover and was_hover) {
        hover_ease_frame = 0;
        hover_ease_animating = false;
        redraw = true;
    } else if (!is_hover) {
        hover_ease_frame = 0;
        hover_ease_animating = false;
    }

    const down = (button_mask & BTN_PRIMARY) != 0;
    if (down and !was_primary_down) {
        const hit = if (is_hover) hitIcon() else -1;
        if (hit >= 0 and hit < @as(i32, @intCast(ICON_N - 1))) {
            const index = @as(usize, @intCast(hit));
            if (!app_open[index]) {
                app_open[index] = true;
                bounce_index = hit;
                bounce_frame = 0;
                redraw = true;
            }
        }
    }
    primary_down = down;

    if (is_hover and was_hover and (pointer_x != old_x or pointer_y != old_y or !was_seen)) {
        redraw = true;
    }

    if (redraw) needs_redraw = true;
    return if (redraw) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    var should_continue = false;
    if (bounce_index >= 0) {
        bounce_frame += 1;
        if (bounce_frame > BOUNCE_TOTAL_FRAMES) {
            bounce_index = -1;
            bounce_frame = 0;
        } else {
            should_continue = true;
        }
        needs_redraw = true;
    }
    if (hover_ease_animating) {
        hover_ease_frame += 1;
        if (hover_ease_frame >= HOVER_EASE_FRAMES) {
            hover_ease_frame = HOVER_EASE_FRAMES;
            hover_ease_animating = false;
        } else {
            should_continue = true;
        }
        needs_redraw = true;
    }
    next_wake_at_ms = if (should_continue and begun_at_ms <= std.math.maxInt(i64) - 16)
        begun_at_ms + 16
    else
        begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    needs_redraw = false;
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
    next_wake_at_ms = if ((bounce_index >= 0 or hover_ease_animating) and begun_at_ms <= std.math.maxInt(i64) - 16)
        begun_at_ms + 16
    else
        begun_at_ms;
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn drawFrame() void {
    drawDesktopBackground();

    var layout = computeLayout();
    drawDockShadow(layout.total_w);
    drawGlassShelf(layout.total_w);
    drawDivider(&layout);

    var i: usize = 0;
    while (i < ICON_N) : (i += 1) drawIconReflection(i, &layout);
    i = 0;
    while (i < ICON_N) : (i += 1) drawIconShadow(i, &layout);
    i = 0;
    while (i < ICON_N) : (i += 1) drawDockIcon(i, &layout);

    const hover = hitIconFromLayout(&layout);
    if (hover >= 0 and dockHoverActive()) drawLabel(@as(usize, @intCast(hover)), &layout);
}

fn computeLayout() Layout {
    var layout: Layout = undefined;
    var total: i32 = 0;
    var i: usize = 0;
    while (i < ICON_N) : (i += 1) {
        const size = dockSizeFor(baseCenterFor(i));
        layout.size[i] = size;
        total += size;
        if (i + 1 < ICON_N) total += if (i == ICON_N - 2) DIVIDER_GAP else ICON_GAP;
    }
    layout.total_w = total;
    var x = DOCK_CENTER_X - @divTrunc(total, 2);
    i = 0;
    while (i < ICON_N) : (i += 1) {
        const size = layout.size[i];
        const bounce = if (bounce_index == @as(i32, @intCast(i))) bounceOffset() else 0;
        layout.x[i] = x;
        layout.top[i] = ICON_BOTTOM - size + bounce;
        layout.center[i] = x + @divTrunc(size, 2);
        x += size + if (i == ICON_N - 2) DIVIDER_GAP else ICON_GAP;
    }
    return layout;
}

fn baseCenterFor(i: usize) i32 {
    const base_total = baseDockTotal();
    var x = DOCK_CENTER_X - @divTrunc(base_total, 2);
    var n: usize = 0;
    while (n < i) : (n += 1) x += BASE_ICON + if (n == ICON_N - 2) DIVIDER_GAP else ICON_GAP;
    return x + @divTrunc(BASE_ICON, 2);
}

fn baseDockTotal() i32 {
    return @as(i32, @intCast(ICON_N)) * BASE_ICON + @as(i32, @intCast(ICON_N - 2)) * ICON_GAP + DIVIDER_GAP;
}

fn dockHoverActive() bool {
    if (!pointer_seen) return false;
    const min_y = ICON_BOTTOM - MAX_ICON - 60;
    const max_y = SHELF_TOP + SHELF_H + 12;
    const half_w = @divTrunc(baseDockTotal(), 2) + 34;
    return pointer_x >= DOCK_CENTER_X - half_w and
        pointer_x <= DOCK_CENTER_X + half_w and
        pointer_y >= min_y and
        pointer_y <= max_y;
}

fn dockSizeFor(base_center: i32) i32 {
    if (!dockHoverActive()) return BASE_ICON;
    const d = absI32(pointer_x - base_center);
    if (d >= MAG_RADIUS) return BASE_ICON;
    const t = @divTrunc((MAG_RADIUS - d) * EASE_SCALE, MAG_RADIUS);
    const smooth = smoothstepQ10(t);
    const hover = hoverEaseQ10();
    return BASE_ICON + @divTrunc((MAX_ICON - BASE_ICON) * smooth * hover, EASE_SCALE * EASE_SCALE);
}

fn hoverEaseQ10() i32 {
    if (!dockHoverActive()) return 0;
    if (!hover_ease_animating and hover_ease_frame >= HOVER_EASE_FRAMES) return EASE_SCALE;
    const t = clampI32(@divTrunc(hover_ease_frame * EASE_SCALE, HOVER_EASE_FRAMES), 0, EASE_SCALE);
    return smoothstepQ10(t);
}

fn smoothstepQ10(t: i32) i32 {
    return @divTrunc(t * t * (3 * EASE_SCALE - 2 * t), EASE_SCALE * EASE_SCALE);
}

fn bounceOffset() i32 {
    const frame = bounce_frame;
    if (frame < 0 or frame > BOUNCE_TOTAL_FRAMES) return 0;
    const half_hop = @divTrunc(BOUNCE_HOP_FRAMES, 2);
    const hop_frame = @mod(frame, BOUNCE_HOP_FRAMES);
    const phase = if (hop_frame < half_hop) hop_frame else BOUNCE_HOP_FRAMES - hop_frame;
    const hop = @divTrunc(frame, BOUNCE_HOP_FRAMES);
    const amp: i32 = switch (hop) {
        0 => 58,
        1 => 34,
        else => 18,
    };
    return -@divTrunc(phase * amp, half_hop);
}

fn resetAppOpenState() void {
    app_open = initial_app_open;
}

fn hitIcon() i32 {
    var layout = computeLayout();
    return hitIconFromLayout(&layout);
}

fn hitIconFromLayout(layout: *const Layout) i32 {
    var i: usize = 0;
    while (i < ICON_N) : (i += 1) {
        const size = layout.size[i];
        const x = layout.x[i];
        const y = layout.top[i];
        if (pointer_x >= x and pointer_x <= x + size and pointer_y >= y and pointer_y <= ICON_BOTTOM + 32) {
            return @as(i32, @intCast(i));
        }
    }
    return -1;
}

fn drawDesktopBackground() void {
    var y: usize = 0;
    while (y < RENDER_H) : (y += 1) {
        const yi = @as(i32, @intCast(y));
        const t = @divTrunc(yi * 255, @as(i32, @intCast(RENDER_H - 1)));
        var c = packRgb(
            @intCast(clampI32(28 + @divTrunc(t, 12), 0, 255)),
            @intCast(clampI32(68 + @divTrunc(t, 8), 0, 255)),
            @intCast(clampI32(124 + @divTrunc(t, 5), 0, 255)),
        );
        if (yi >= SHELF_TOP - 24) {
            c = blendOpaque(c, packRgb(4, 10, 19), 78);
        }
        fillRowOpaque(y, c);
    }
}

fn drawDockShadow(total_w: i32) void {
    const w = total_w + 94;
    blendEllipse(DOCK_CENTER_X, ICON_BOTTOM + 24, @divTrunc(w, 2), 38, packRgb(0, 0, 0), 54);
}

fn drawGlassShelf(total_w: i32) void {
    const x = DOCK_CENTER_X - @divTrunc(total_w, 2) - 34;
    const w = total_w + 68;
    const y = SHELF_TOP;
    fillRoundedGradient(x, y, w, SHELF_H, 28, packRgb(238, 247, 255), packRgb(42, 58, 76), 108);
    fillRoundedGradient(x + 8, y + 6, w - 16, 32, 22, packRgb(255, 255, 255), packRgb(164, 204, 242), 74);
    fillRoundedGradient(x + 10, y + 50, w - 20, 40, 18, packRgb(18, 28, 42), packRgb(5, 8, 13), 52);
    drawRoundedBorder(x, y, w, SHELF_H, 28, packRgb(242, 250, 255), 112);
    blendLine(x + 28, y + 14, x + w - 28, y + 5, packRgb(255, 255, 255), 86);
}

fn drawDivider(layout: *const Layout) void {
    const x = layout.x[ICON_N - 1] - @divTrunc(DIVIDER_GAP, 2);
    blendLine(x, SHELF_TOP + 18, x + 6, SHELF_TOP + SHELF_H - 22, packRgb(12, 22, 34), 118);
    blendLine(x + 2, SHELF_TOP + 18, x + 8, SHELF_TOP + SHELF_H - 22, packRgb(255, 255, 255), 70);
}

fn drawIconReflection(index: usize, layout: *const Layout) void {
    const size = layout.size[index];
    const x = layout.x[index];
    const y = ICON_BOTTOM + 7;
    const h = @divTrunc(size * 3, 5);
    fillRoundedGradientFade(x, y, size, h, @divTrunc(size, 5), iconBottomColor(icons[index].kind), iconTopColor(icons[index].kind), 58);
}

fn drawIconShadow(index: usize, layout: *const Layout) void {
    const size = layout.size[index];
    blendEllipse(layout.center[index], ICON_BOTTOM + 12, @divTrunc(size, 2), @max(8, @divTrunc(size, 11)), packRgb(0, 0, 0), 54);
}

fn drawDockIcon(index: usize, layout: *const Layout) void {
    const kind = icons[index].kind;
    const size = layout.size[index];
    const x = layout.x[index];
    const y = layout.top[index];
    if (kind == .trash) {
        drawTrashIcon(x, y, size);
        drawRunningDot(layout.center[index], ICON_BOTTOM + 30, false);
        return;
    }
    drawIconShell(x, y, size, iconTopColor(kind), iconBottomColor(kind));
    switch (kind) {
        .finder => drawFinderGlyph(x, y, size),
        .browser => drawCompassGlyph(x, y, size),
        .mail => drawMailGlyph(x, y, size),
        .calendar => drawCalendarGlyph(x, y, size),
        .photos => drawPhotosGlyph(x, y, size),
        .music => drawMusicGlyph(x, y, size),
        .terminal => drawTerminalGlyph(x, y, size),
        .settings => drawSettingsGlyph(x, y, size),
        .notes => drawNotesGlyph(x, y, size),
        .trash => {},
    }
    drawRunningDot(layout.center[index], ICON_BOTTOM + 30, appIsOpen(index));
}

fn iconTopColor(kind: IconKind) Color {
    return switch (kind) {
        .finder => packRgb(30, 132, 196),
        .browser => packRgb(245, 196, 54),
        .mail => packRgb(230, 80, 54),
        .calendar => packRgb(245, 238, 216),
        .photos => packRgb(34, 128, 132),
        .music => packRgb(202, 58, 96),
        .terminal => packRgb(35, 37, 36),
        .settings => packRgb(210, 205, 190),
        .notes => packRgb(246, 198, 60),
        .trash => packRgb(214, 232, 244),
    };
}

fn iconBottomColor(kind: IconKind) Color {
    return switch (kind) {
        .finder => packRgb(8, 68, 138),
        .browser => packRgb(210, 116, 34),
        .mail => packRgb(134, 32, 42),
        .calendar => packRgb(214, 204, 184),
        .photos => packRgb(20, 78, 92),
        .music => packRgb(83, 42, 108),
        .terminal => packRgb(8, 10, 10),
        .settings => packRgb(102, 112, 126),
        .notes => packRgb(182, 112, 24),
        .trash => packRgb(112, 148, 178),
    };
}

fn drawIconShell(x: i32, y: i32, size: i32, top: Color, bottom: Color) void {
    const r = @divTrunc(size, 7);
    fillRoundedGradient(x, y, size, size, r, top, bottom, 255);
    fillRectBlend(x + @divTrunc(size, 8), y + @divTrunc(size, 8), @max(3, @divTrunc(size, 18)), size - @divTrunc(size, 4), packRgb(255, 250, 224), 32);
    fillRoundedGradient(x + @divTrunc(size, 12), y + @divTrunc(size, 12), size - @divTrunc(size, 6), @divTrunc(size, 5), @divTrunc(size, 14), packRgb(255, 255, 255), packRgb(255, 255, 255), 28);
    drawRoundedBorder(x, y, size, size, r, packRgb(250, 246, 228), 78);
    drawRoundedBorder(x + 1, y + 1, size - 2, size - 2, r - 1, packRgb(0, 0, 0), 58);
}

fn drawFinderGlyph(x: i32, y: i32, size: i32) void {
    const cream = packRgb(244, 232, 192);
    const ink = packRgb(8, 22, 42);
    fillDiamondBlend(x + @divTrunc(size, 3), y + @divTrunc(size, 2), @divTrunc(size, 4), @divTrunc(size, 4), cream, 235);
    fillRectBlend(x + @divTrunc(size, 2), y + @divTrunc(size, 6), @max(5, @divTrunc(size, 12)), @divTrunc(size * 2, 3), ink, 235);
    fillRectBlend(x + @divTrunc(size, 4), y + @divTrunc(size * 2, 3), @divTrunc(size, 2), @max(4, @divTrunc(size, 18)), cream, 230);
    fillDiamondBlend(x + @divTrunc(size * 2, 3), y + @divTrunc(size, 3), @max(5, @divTrunc(size, 13)), @max(5, @divTrunc(size, 13)), packRgb(230, 80, 48), 245);
    blendLine(x + @divTrunc(size, 5), y + @divTrunc(size, 5), x + @divTrunc(size * 4, 5), y + @divTrunc(size * 4, 5), packRgb(250, 250, 244), 210);
}

fn drawCompassGlyph(x: i32, y: i32, size: i32) void {
    const cx = x + @divTrunc(size, 2);
    const cy = y + @divTrunc(size, 2);
    fillDiamondBlend(cx - @divTrunc(size, 10), cy, @divTrunc(size, 3), @divTrunc(size, 3), packRgb(20, 75, 132), 230);
    fillDiamondBlend(cx + @divTrunc(size, 6), cy - @divTrunc(size, 7), @divTrunc(size, 5), @divTrunc(size, 5), packRgb(230, 58, 50), 238);
    fillTriangleBlend(cx - @divTrunc(size, 3), cy + @divTrunc(size, 4), cx + @divTrunc(size, 3), cy - @divTrunc(size, 4), cx + @divTrunc(size, 4), cy + @divTrunc(size, 3), packRgb(246, 238, 206), 235);
    fillRectBlend(cx - @divTrunc(size, 3), cy + @divTrunc(size, 5), @divTrunc(size * 2, 3), @max(4, @divTrunc(size, 18)), packRgb(18, 24, 32), 210);
}

fn drawMailGlyph(x: i32, y: i32, size: i32) void {
    const paper = packRgb(246, 236, 198);
    fillRoundedGradient(x + @divTrunc(size, 5), y + @divTrunc(size, 5), @divTrunc(size * 3, 5), @divTrunc(size * 3, 5), @divTrunc(size, 18), paper, packRgb(220, 206, 170), 245);
    fillRectBlend(x + @divTrunc(size, 5), y + @divTrunc(size, 5), @divTrunc(size * 3, 5), @max(5, @divTrunc(size, 11)), packRgb(24, 78, 128), 230);
    fillDiamondBlend(x + @divTrunc(size * 7, 10), y + @divTrunc(size, 3), @divTrunc(size, 8), @divTrunc(size, 8), packRgb(245, 196, 54), 245);
    blendLine(x + @divTrunc(size, 4), y + @divTrunc(size * 3, 5), x + @divTrunc(size * 3, 4), y + @divTrunc(size * 3, 5), packRgb(30, 28, 24), 150);
    blendLine(x + @divTrunc(size, 4), y + @divTrunc(size * 7, 10), x + @divTrunc(size * 13, 20), y + @divTrunc(size * 7, 10), packRgb(30, 28, 24), 110);
}

fn drawCalendarGlyph(x: i32, y: i32, size: i32) void {
    fillRectBlend(x + @divTrunc(size, 5), y + @divTrunc(size, 5), @divTrunc(size * 3, 5), @divTrunc(size * 3, 5), packRgb(246, 240, 220), 245);
    fillRectBlend(x + @divTrunc(size, 5), y + @divTrunc(size, 5), @divTrunc(size * 3, 5), @divTrunc(size, 5), packRgb(210, 42, 36), 255);
    fillRectBlend(x + @divTrunc(size * 3, 5), y + @divTrunc(size * 3, 5), @divTrunc(size, 5), @divTrunc(size, 5), packRgb(26, 80, 128), 230);
    drawTextScaled(x + @divTrunc(size, 2) - @divTrunc(8 * size, 34), y + @divTrunc(size, 2), "28", packRgb(28, 28, 28), @max(3, @divTrunc(size, 34)));
}

fn drawPhotosGlyph(x: i32, y: i32, size: i32) void {
    const cx = x + @divTrunc(size, 2);
    const cy = y + @divTrunc(size, 2);
    fillDiamondBlend(cx - @divTrunc(size, 6), cy - @divTrunc(size, 8), @divTrunc(size, 5), @divTrunc(size, 5), packRgb(232, 64, 58), 245);
    fillRectBlend(cx - @divTrunc(size, 20), cy - @divTrunc(size, 4), @divTrunc(size, 3), @divTrunc(size, 3), packRgb(245, 190, 48), 245);
    fillTriangleBlend(cx - @divTrunc(size, 3), cy + @divTrunc(size, 3), cx + @divTrunc(size, 3), cy + @divTrunc(size, 3), cx + @divTrunc(size, 8), cy - @divTrunc(size, 4), packRgb(230, 232, 216), 245);
    fillRectBlend(cx + @divTrunc(size, 6), cy - @divTrunc(size, 3), @divTrunc(size, 8), @divTrunc(size, 2), packRgb(24, 28, 32), 220);
    fillDiamondBlend(cx + @divTrunc(size, 5), cy + @divTrunc(size, 5), @divTrunc(size, 7), @divTrunc(size, 7), packRgb(86, 174, 156), 235);
}

fn drawMusicGlyph(x: i32, y: i32, size: i32) void {
    const cx = x + @divTrunc(size, 2);
    const cy = y + @divTrunc(size, 2);
    fillDiamondBlend(cx - @divTrunc(size, 7), cy + @divTrunc(size, 7), @divTrunc(size, 5), @divTrunc(size, 5), packRgb(246, 232, 196), 245);
    fillRectBlend(cx + @divTrunc(size, 7), y + @divTrunc(size, 5), @max(5, @divTrunc(size, 13)), @divTrunc(size * 3, 5), packRgb(246, 232, 196), 245);
    fillRectBlend(cx - @divTrunc(size, 8), y + @divTrunc(size, 4), @divTrunc(size, 2), @max(5, @divTrunc(size, 12)), packRgb(18, 20, 28), 210);
    fillTriangleBlend(cx - @divTrunc(size, 8), y + @divTrunc(size, 4), cx + @divTrunc(size, 3), y + @divTrunc(size, 6), cx + @divTrunc(size, 3), y + @divTrunc(size, 3), packRgb(246, 232, 196), 245);
    fillDiamondBlend(cx - @divTrunc(size, 10), cy + @divTrunc(size, 8), @max(4, @divTrunc(size, 13)), @max(4, @divTrunc(size, 13)), packRgb(238, 82, 60), 245);
}

fn drawTerminalGlyph(x: i32, y: i32, size: i32) void {
    const green = packRgb(74, 232, 104);
    fillRectBlend(x + @divTrunc(size, 5), y + @divTrunc(size, 4), @divTrunc(size, 7), @divTrunc(size, 2), green, 230);
    fillTriangleBlend(x + @divTrunc(size, 3), y + @divTrunc(size, 3), x + @divTrunc(size * 3, 5), y + @divTrunc(size, 2), x + @divTrunc(size, 3), y + @divTrunc(size * 2, 3), green, 230);
    fillRectBlend(x + @divTrunc(size * 3, 5), y + @divTrunc(size * 2, 3), @divTrunc(size, 4), @max(4, @divTrunc(size, 18)), packRgb(244, 196, 58), 220);
    fillRectBlend(x + @divTrunc(size * 3, 5), y + @divTrunc(size, 5), @divTrunc(size, 5), @divTrunc(size, 5), packRgb(60, 70, 72), 210);
}

fn drawSettingsGlyph(x: i32, y: i32, size: i32) void {
    const cx = x + @divTrunc(size, 2);
    const cy = y + @divTrunc(size, 2);
    fillDiamondBlend(cx, cy, @divTrunc(size, 3), @divTrunc(size, 3), packRgb(34, 40, 48), 235);
    fillRectBlend(cx - @divTrunc(size, 6), cy - @divTrunc(size, 6), @divTrunc(size, 3), @divTrunc(size, 3), packRgb(238, 224, 186), 235);
    fillRectBlend(cx - @divTrunc(size, 2), cy - @divTrunc(size, 14), size, @max(5, @divTrunc(size, 12)), packRgb(218, 66, 48), 230);
    fillRectBlend(cx - @divTrunc(size, 14), cy - @divTrunc(size, 2), @max(5, @divTrunc(size, 12)), size, packRgb(36, 100, 160), 210);
    fillDiamondBlend(cx + @divTrunc(size, 4), cy - @divTrunc(size, 4), @divTrunc(size, 8), @divTrunc(size, 8), packRgb(244, 194, 58), 245);
}

fn drawNotesGlyph(x: i32, y: i32, size: i32) void {
    const paper = packRgb(246, 232, 190);
    fillRectBlend(x + @divTrunc(size, 5), y + @divTrunc(size, 6), @divTrunc(size * 3, 5), @divTrunc(size * 2, 3), paper, 240);
    fillRectBlend(x + @divTrunc(size, 5), y + @divTrunc(size, 6), @divTrunc(size * 3, 5), @divTrunc(size, 8), packRgb(44, 56, 70), 200);
    fillDiamondBlend(x + @divTrunc(size, 4), y + @divTrunc(size * 3, 4), @divTrunc(size, 8), @divTrunc(size, 8), packRgb(216, 54, 42), 245);
    var line: i32 = 0;
    while (line < 3) : (line += 1) {
        const yy = y + @divTrunc(size, 3) + line * @divTrunc(size, 8);
        fillRectBlend(x + @divTrunc(size, 3), yy, @divTrunc(size, 3), @max(2, @divTrunc(size, 36)), packRgb(48, 42, 34), 150);
    }
}

fn drawTrashIcon(x: i32, y: i32, size: i32) void {
    const bx = x + @divTrunc(size, 7);
    const by = y + @divTrunc(size, 9);
    const bw = size - @divTrunc(size * 2, 7);
    const bh = size - @divTrunc(size, 7);
    fillRoundedGradient(bx, by + @divTrunc(size, 8), bw, bh, @divTrunc(size, 11), packRgb(224, 240, 250), packRgb(112, 148, 178), 156);
    fillRoundedGradient(bx - @divTrunc(size, 12), by, bw + @divTrunc(size, 6), @divTrunc(size, 9), @divTrunc(size, 20), packRgb(238, 250, 255), packRgb(150, 176, 200), 215);
    fillRectBlend(bx + @divTrunc(bw, 4), by - @divTrunc(size, 18), @divTrunc(bw, 2), @max(3, @divTrunc(size, 24)), packRgb(215, 236, 250), 180);
    var n: i32 = 1;
    while (n < 5) : (n += 1) {
        const xx = bx + @divTrunc(bw * n, 4);
        blendLine(xx, by + @divTrunc(size, 5), xx - @divTrunc(size, 18), by + bh, packRgb(255, 255, 255), 82);
        blendLine(xx + 2, by + @divTrunc(size, 5), xx - @divTrunc(size, 18) + 2, by + bh, packRgb(20, 38, 54), 42);
    }
    drawRoundedBorder(bx, by + @divTrunc(size, 8), bw, bh, @divTrunc(size, 12), packRgb(255, 255, 255), 92);
}

fn drawRunningDot(cx: i32, cy: i32, active: bool) void {
    if (!active) return;
    fillCircle(cx, cy, 5, packRgb(232, 240, 255));
}

fn appIsOpen(index: usize) bool {
    return index < ICON_N - 1 and app_open[index];
}

fn drawLabel(index: usize, layout: *const Layout) void {
    const text = icons[index].label;
    const text_size_px: i32 = 27;
    const w = labelTextWidth(text, text_size_px) + 34;
    const h = 48;
    const cx = layout.center[index];
    const y = layout.top[index] - 62;
    const x = clampI32(cx - @divTrunc(w, 2), 8, @as(i32, @intCast(RENDER_W)) - w - 8);
    fillRoundedGradient(x, y, w, h, 18, packRgb(38, 42, 50), packRgb(5, 8, 12), 224);
    drawRoundedBorder(x, y, w, h, 18, packRgb(255, 255, 255), 84);
    drawLabelText(x + 18, y + 11, text, packRgb(0, 0, 0), 92, text_size_px);
    drawLabelText(x + 17, y + 10, text, packRgb(255, 255, 255), 238, text_size_px);
}

fn fillRoundedGradient(x0: i32, y0: i32, w: i32, h: i32, radius: i32, top: Color, bottom: Color, alpha: u8) void {
    if (w <= 0 or h <= 0) return;
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ey = clampI32(y0 + h, 0, @as(i32, @intCast(RENDER_H)));
    var y = sy;
    while (y < ey) : (y += 1) {
        const t = @divTrunc((y - y0) * 255, @max(1, h - 1));
        const c = lerpColor(top, bottom, t);
        const span = roundedSpanForRow(x0, y0, w, h, radius, y);
        fillSpanBlend(span.start, span.end, y, c, alpha);
    }
}

fn fillRoundedGradientFade(x0: i32, y0: i32, w: i32, h: i32, radius: i32, top: Color, bottom: Color, alpha_top: u8) void {
    if (w <= 0 or h <= 0) return;
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ey = clampI32(y0 + h, 0, @as(i32, @intCast(RENDER_H)));
    var y = sy;
    while (y < ey) : (y += 1) {
        const t = @divTrunc((y - y0) * 255, @max(1, h - 1));
        const c = lerpColor(top, bottom, t);
        const alpha = @as(u8, @intCast(@divTrunc(@as(i32, alpha_top) * (255 - t), 255)));
        if (alpha == 0) continue;
        const span = roundedSpanForRow(x0, y0, w, h, radius, y);
        fillSpanBlend(span.start, span.end, y, c, alpha);
    }
}

fn roundedSpanForRow(x0: i32, y0: i32, w: i32, h: i32, radius_in: i32, y: i32) Span {
    const r = clampI32(radius_in, 0, @divTrunc(@min(w, h), 2));
    if (r <= 0) return .{ .start = x0, .end = x0 + w };
    var inset: i32 = 0;
    if (y < y0 + r) {
        inset = roundedInset(r, y - (y0 + r));
    } else if (y >= y0 + h - r) {
        inset = roundedInset(r, y - (y0 + h - r - 1));
    }
    return .{ .start = x0 + inset, .end = x0 + w - inset };
}

fn roundedInset(radius: i32, dy: i32) i32 {
    const rr = radius * radius;
    var inset: i32 = 0;
    while (inset < radius) : (inset += 1) {
        const dx = radius - inset;
        if (dx * dx + dy * dy <= rr) return inset;
    }
    return radius;
}

fn drawRoundedBorder(x0: i32, y0: i32, w: i32, h: i32, radius: i32, color: Color, alpha: u8) void {
    if (w <= 0 or h <= 0) return;
    const thickness: i32 = 2;
    const r = clampI32(radius, 0, @divTrunc(@min(w, h), 2));
    if (r <= thickness) {
        fillRectBlend(x0, y0, w, thickness, color, alpha);
        fillRectBlend(x0, y0 + h - thickness, w, thickness, color, alpha);
        fillRectBlend(x0, y0, thickness, h, color, alpha);
        fillRectBlend(x0 + w - thickness, y0, thickness, h, color, alpha);
        return;
    }

    fillRectBlend(x0 + r, y0, w - 2 * r, thickness, color, alpha);
    fillRectBlend(x0 + r, y0 + h - thickness, w - 2 * r, thickness, color, alpha);
    fillRectBlend(x0, y0 + r, thickness, h - 2 * r, color, alpha);
    fillRectBlend(x0 + w - thickness, y0 + r, thickness, h - 2 * r, color, alpha);

    drawCornerBorder(x0 + r, y0 + r, r, x0, x0 + r, y0, y0 + r, color, alpha);
    drawCornerBorder(x0 + w - r - 1, y0 + r, r, x0 + w - r, x0 + w, y0, y0 + r, color, alpha);
    drawCornerBorder(x0 + r, y0 + h - r - 1, r, x0, x0 + r, y0 + h - r, y0 + h, color, alpha);
    drawCornerBorder(x0 + w - r - 1, y0 + h - r - 1, r, x0 + w - r, x0 + w, y0 + h - r, y0 + h, color, alpha);
}

fn drawCornerBorder(cx: i32, cy: i32, radius: i32, x0: i32, x1: i32, y0: i32, y1: i32, color: Color, alpha: u8) void {
    const sx = clampI32(x0, 0, @as(i32, @intCast(RENDER_W)));
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ex = clampI32(x1, 0, @as(i32, @intCast(RENDER_W)));
    const ey = clampI32(y1, 0, @as(i32, @intCast(RENDER_H)));
    const outer = radius * radius;
    const inner_r = @max(0, radius - 2);
    const inner = inner_r * inner_r;
    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const d = dx * dx + dy * dy;
            if (d <= outer and d >= inner) blendPixel(x, y, color, alpha);
        }
    }
}

fn insideRoundedRect(px: i32, py: i32, x: i32, y: i32, w: i32, h: i32, radius_in: i32) bool {
    const r = @max(0, radius_in);
    if (px < x or py < y or px >= x + w or py >= y + h) return false;
    if (r <= 0) return true;
    const cx = if (px < x + r) x + r else if (px >= x + w - r) x + w - r - 1 else px;
    const cy = if (py < y + r) y + r else if (py >= y + h - r) y + h - r - 1 else py;
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

fn fillRectBlend(x0: i32, y0: i32, w: i32, h: i32, color: Color, alpha: u8) void {
    if (w <= 0 or h <= 0) return;
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ey = clampI32(y0 + h, 0, @as(i32, @intCast(RENDER_H)));
    var y = sy;
    while (y < ey) : (y += 1) {
        fillSpanBlend(x0, x0 + w, y, color, alpha);
    }
}

fn fillTriangleBlend(ax: i32, ay: i32, bx: i32, by: i32, cx: i32, cy: i32, color: Color, alpha: u8) void {
    if (alpha == 0) return;
    const sx = clampI32(@min(ax, @min(bx, cx)), 0, @as(i32, @intCast(RENDER_W)));
    const ex = clampI32(@max(ax, @max(bx, cx)) + 1, 0, @as(i32, @intCast(RENDER_W)));
    const sy = clampI32(@min(ay, @min(by, cy)), 0, @as(i32, @intCast(RENDER_H)));
    const ey = clampI32(@max(ay, @max(by, cy)) + 1, 0, @as(i32, @intCast(RENDER_H)));
    if (sx >= ex or sy >= ey) return;

    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) {
            const e0 = edgeI64(bx, by, cx, cy, x, y);
            const e1 = edgeI64(cx, cy, ax, ay, x, y);
            const e2 = edgeI64(ax, ay, bx, by, x, y);
            const has_neg = e0 < 0 or e1 < 0 or e2 < 0;
            const has_pos = e0 > 0 or e1 > 0 or e2 > 0;
            if (!(has_neg and has_pos)) blendPixel(x, y, color, alpha);
        }
    }
}

fn fillDiamondBlend(cx: i32, cy: i32, rx: i32, ry: i32, color: Color, alpha: u8) void {
    if (rx <= 0 or ry <= 0 or alpha == 0) return;
    const sy = clampI32(cy - ry, 0, @as(i32, @intCast(RENDER_H)));
    const ey = clampI32(cy + ry + 1, 0, @as(i32, @intCast(RENDER_H)));
    var y = sy;
    while (y < ey) : (y += 1) {
        const dy = absI32(y - cy);
        if (dy > ry) continue;
        const half = @divTrunc(rx * (ry - dy), ry);
        fillSpanBlend(cx - half, cx + half + 1, y, color, alpha);
    }
}

fn edgeI64(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i64 {
    return @as(i64, px - ax) * @as(i64, by - ay) - @as(i64, py - ay) * @as(i64, bx - ax);
}

fn blendEllipse(cx: i32, cy: i32, rx: i32, ry: i32, color: Color, alpha: u8) void {
    if (rx <= 0 or ry <= 0) return;
    const sx = clampI32(cx - rx, 0, @as(i32, @intCast(RENDER_W)));
    const sy = clampI32(cy - ry, 0, @as(i32, @intCast(RENDER_H)));
    const ex = clampI32(cx + rx + 1, 0, @as(i32, @intCast(RENDER_W)));
    const ey = clampI32(cy + ry + 1, 0, @as(i32, @intCast(RENDER_H)));
    const rx2 = @as(i64, rx) * rx;
    const ry2 = @as(i64, ry) * ry;
    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) {
            const dx = @as(i64, x - cx);
            const dy = @as(i64, y - cy);
            const v = dx * dx * ry2 + dy * dy * rx2;
            const limit = rx2 * ry2;
            if (v <= limit) {
                const fade = @as(i32, @intCast(@divTrunc((limit - v) * 255, limit)));
                blendPixel(x, y, color, @as(u8, @intCast(@divTrunc(@as(i32, alpha) * fade, 255))));
            }
        }
    }
}

fn fillCircle(cx: i32, cy: i32, r: i32, color: Color) void {
    blendEllipse(cx, cy, r, r, color, 255);
}

fn blendLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, color: Color, alpha: u8) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        blendPixel(x0, y0, color, alpha);
        blendPixel(x0 + 1, y0, color, @divTrunc(alpha, 2));
        blendPixel(x0, y0 + 1, color, @divTrunc(alpha, 2));
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

fn drawLabelText(x: i32, y: i32, text: []const u8, color: Color, alpha: u8, size_px: i32) void {
    var cursor_x = x;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawLabelFontChar(cursor_x, y, text[i], color, alpha, size_px);
        cursor_x += labelFontAdvance(size_px);
    }
}

fn labelTextWidth(text: []const u8, size_px: i32) i32 {
    return @as(i32, @intCast(text.len)) * labelFontAdvance(size_px);
}

fn labelFontAdvance(size_px: i32) i32 {
    return @max(1, @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(ui_font.GLYPH_W)) * labelFontScale(size_px)))));
}

fn labelFontScale(size_px: i32) f32 {
    return @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(ui_font.GLYPH_H));
}

fn drawLabelFontChar(x: i32, y: i32, ch: u8, color: Color, alpha: u8, size_px: i32) void {
    const glyph_index = labelGlyphIndexForByte(ch) orelse return;
    const scale = labelFontScale(size_px);
    const w = labelFontAdvance(size_px);
    var dy: i32 = 0;
    while (dy < size_px) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const coverage = labelFontCoverage(glyph_index, dx, dy, scale);
            if (coverage == 0) continue;
            blendPixel(x + dx, y + dy, color, @as(u8, @intCast(@divTrunc(@as(i32, alpha) * coverage, 4))));
        }
    }
}

fn labelGlyphIndexForByte(ch: u8) ?usize {
    const code = @as(u32, ch);
    if (code >= ui_font.ASCII_START and code <= ui_font.ASCII_END) {
        return @as(usize, @intCast(code - ui_font.ASCII_START));
    }
    return null;
}

fn labelFontCoverage(glyph_index: usize, dx: i32, dy: i32, scale: f32) i32 {
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
        if (labelFontBit(glyph_index, sx, sy)) covered += 1;
    }
    return covered;
}

fn labelFontBit(glyph_index: usize, sx: i32, sy: i32) bool {
    if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(ui_font.GLYPH_W)) or sy >= @as(i32, @intCast(ui_font.GLYPH_H))) return false;
    const row = ui_font.glyph_rows[glyph_index][@as(usize, @intCast(sy))];
    return ((row >> @as(u6, @intCast(sx))) & 1) != 0;
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, color: Color, scale: i32) void {
    var i: usize = 0;
    var cx = x;
    while (i < text.len) : (i += 1) {
        drawCharScaled(cx, y, text[i], color, scale);
        cx += 4 * scale;
    }
}

fn textWidth(text: []const u8, scale: i32) i32 {
    return @as(i32, @intCast(text.len)) * 4 * scale;
}

fn drawCharScaled(x: i32, y: i32, ch: u8, color: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) != 0) {
                fillRectBlend(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, color, 255);
            }
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
        'L' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N' => .{ 0b101, 0b111, 0b111, 0b111, 0b101 },
        'O', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'R' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'Y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '_' => .{ 0b000, 0b000, 0b000, 0b000, 0b111 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillRowOpaque(y: usize, color: Color) void {
    const idx = y * RENDER_W * 4;
    const end = idx + RENDER_W * 4;
    fillPackedOpaqueRange(idx, end, color);
}

fn fillSpanBlend(x0: i32, x1: i32, y: i32, color: Color, alpha: u8) void {
    if (alpha == 0 or y < 0 or y >= @as(i32, @intCast(RENDER_H))) return;
    const sx = clampI32(x0, 0, @as(i32, @intCast(RENDER_W)));
    const ex = clampI32(x1, 0, @as(i32, @intCast(RENDER_W)));
    if (sx >= ex) return;
    var idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(sx))) * 4;
    const end = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(ex))) * 4;
    if (alpha == 255) {
        fillPackedOpaqueRange(idx, end, color);
        return;
    }
    while (idx < end) : (idx += 4) {
        blendPixelAtIndex(idx, color, alpha);
    }
}

fn fillPackedOpaqueRange(start: usize, end: usize, color: Color) void {
    var idx = start;
    const pair = @as(u64, color) | (@as(u64, color) << 32);
    while (idx + 8 <= end) : (idx += 8) {
        std.mem.writeInt(u64, pixel_buf[idx..][0..8], pair, .little);
    }
    if (idx < end) {
        std.mem.writeInt(u32, pixel_buf[idx..][0..4], color, .little);
    }
}

fn setPixel(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    std.mem.writeInt(u32, pixel_buf[idx..][0..4], color, .little);
}

fn blendPixel(x: i32, y: i32, src: Color, alpha: u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    if (alpha == 255) {
        setPixel(x, y, src);
        return;
    }
    if (alpha == 0) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    blendPixelAtIndex(idx, src, alpha);
}

fn blendPixelAtIndex(idx: usize, src: Color, alpha: u8) void {
    const dst = std.mem.readInt(u32, pixel_buf[idx..][0..4], .little);
    const a = @as(i32, alpha);
    const inv = 255 - a;
    const sr = @as(i32, @intCast(src & 0xFF));
    const sg = @as(i32, @intCast((src >> 8) & 0xFF));
    const sb = @as(i32, @intCast((src >> 16) & 0xFF));
    const dr = @as(i32, @intCast(dst & 0xFF));
    const dg = @as(i32, @intCast((dst >> 8) & 0xFF));
    const db = @as(i32, @intCast((dst >> 16) & 0xFF));
    const r = div255(sr * a + dr * inv);
    const g = div255(sg * a + dg * inv);
    const b = div255(sb * a + db * inv);
    std.mem.writeInt(u32, pixel_buf[idx..][0..4], packRgb(@intCast(r), @intCast(g), @intCast(b)), .little);
}

fn lerpColor(a: Color, b: Color, t: i32) Color {
    const ar = @as(i32, @intCast(a & 0xFF));
    const ag = @as(i32, @intCast((a >> 8) & 0xFF));
    const ab = @as(i32, @intCast((a >> 16) & 0xFF));
    const br = @as(i32, @intCast(b & 0xFF));
    const bg = @as(i32, @intCast((b >> 8) & 0xFF));
    const bb = @as(i32, @intCast((b >> 16) & 0xFF));
    const inv = 255 - t;
    return packRgb(@intCast(@divTrunc(ar * inv + br * t, 255)), @intCast(@divTrunc(ag * inv + bg * t, 255)), @intCast(@divTrunc(ab * inv + bb * t, 255)));
}

fn blendOpaque(dst: Color, src: Color, alpha: i32) Color {
    const inv = 255 - alpha;
    const sr = @as(i32, @intCast(src & 0xFF));
    const sg = @as(i32, @intCast((src >> 8) & 0xFF));
    const sb = @as(i32, @intCast((src >> 16) & 0xFF));
    const dr = @as(i32, @intCast(dst & 0xFF));
    const dg = @as(i32, @intCast((dst >> 8) & 0xFF));
    const db = @as(i32, @intCast((dst >> 16) & 0xFF));
    return packRgb(
        @intCast(div255(sr * alpha + dr * inv)),
        @intCast(div255(sg * alpha + dg * inv)),
        @intCast(div255(sb * alpha + db * inv)),
    );
}

fn packRgb(r: u8, g: u8, b: u8) Color {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, 0xFF) << 24);
}

fn div255(value: i32) i32 {
    return @divTrunc(value + 128 + @divTrunc(value + 128, 256), 256);
}

fn dirX(i: i32) i32 {
    return switch (i) {
        0 => 1024,
        1 => 724,
        2 => 0,
        3 => -724,
        4 => -1024,
        5 => -724,
        6 => 0,
        else => 724,
    };
}

fn dirY(i: i32) i32 {
    return switch (i) {
        0 => 0,
        1 => 724,
        2 => 1024,
        3 => 724,
        4 => 0,
        5 => -724,
        6 => -1024,
        else => -724,
    };
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}
