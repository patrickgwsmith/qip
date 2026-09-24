const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_RETURN: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_BACKSPACE: i32 = 0xFF08;

const STATUS_H: i32 = 18;
const GESTURE_H: i32 = 16;
const CARD_W: i32 = 178;
const CARD_H: i32 = 130;
const CARD_BASE_Y: i32 = 40;
const CARD_SPACING: i32 = 96;
const MAX_CARDS: usize = 6;

const Scene = enum(u8) {
    cards,
    app,
};

const InteractionMode = enum(u8) {
    idle,
    strip_drag,
    card_drag,
};

const Card = struct {
    title: []const u8,
    subtitle: []const u8,
    top: [4]u8,
    bottom: [4]u8,
};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const cards_seed = [_]Card{
    .{ .title = "EMAIL", .subtitle = "3 NEW", .top = .{ 0x4E, 0x84, 0xD8, 0xFF }, .bottom = .{ 0x2A, 0x4E, 0x89, 0xFF } },
    .{ .title = "WEB", .subtitle = "TAB: QIP", .top = .{ 0x62, 0x96, 0xE2, 0xFF }, .bottom = .{ 0x2F, 0x57, 0x97, 0xFF } },
    .{ .title = "MUSIC", .subtitle = "NOW PLAYING", .top = .{ 0x8D, 0x76, 0xDA, 0xFF }, .bottom = .{ 0x4B, 0x3C, 0x94, 0xFF } },
    .{ .title = "MAPS", .subtitle = "HOME", .top = .{ 0x4A, 0xAF, 0x97, 0xFF }, .bottom = .{ 0x2C, 0x6F, 0x60, 0xFF } },
    .{ .title = "CHAT", .subtitle = "DEV TEAM", .top = .{ 0xDA, 0x7C, 0x8A, 0xFF }, .bottom = .{ 0x8D, 0x47, 0x54, 0xFF } },
    .{ .title = "PHOTOS", .subtitle = "ALBUM", .top = .{ 0xD2, 0xA1, 0x53, 0xFF }, .bottom = .{ 0x8D, 0x64, 0x2E, 0xFF } },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var cards: [MAX_CARDS]Card = cards_seed;
var card_count: usize = 5;
var initialized: bool = false;
var needs_redraw: bool = true;

var scene: Scene = .cards;
var mode: InteractionMode = .idle;

var scroll_q8: i32 = 0;
var velocity_q8: i32 = 0;
var active_card: i32 = 0;

var press_x: i32 = 0;
var press_y: i32 = 0;
var last_x: i32 = 0;
var last_y: i32 = 0;
var last_dx: i32 = 0;
var last_dy: i32 = 0;
var press_scroll_q8: i32 = 0;
var pressed_card_idx: i32 = -1;

var drag_card_idx: i32 = -1;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;

var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;
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
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (scene) {
        .cards => switch (x11_key) {
            XK_LEFT, 'a', 'A' => {
                moveSelection(-1);
                snapToNearest();
            },
            XK_RIGHT, 'd', 'D' => {
                moveSelection(1);
                snapToNearest();
            },
            XK_RETURN, ' ', 'x', 'X' => openCenteredCard(),
            XK_UP, 'w', 'W' => closeCenteredCard(),
            else => return 0,
        },
        .app => switch (x11_key) {
            XK_ESCAPE, XK_BACKSPACE, 'o', 'O' => scene = .cards,
            XK_UP, 'w', 'W' => scene = .cards,
            else => return 0,
        },
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
    const secondary = (button_mask & BTN_SECONDARY) != 0;

    if (scene == .app) {
        if (down and !primary_down) {
            if (appBackButtonAt(x_px, y_px) or gestureCenterAt(x_px, y_px)) {
                scene = .cards;
                needs_redraw = true;
            }
        } else if (secondary and !secondary_down) {
            scene = .cards;
            needs_redraw = true;
        }
        primary_down = down;
        secondary_down = secondary;
        return if (needs_redraw) 1 else 0;
    }

    if (secondary and !secondary_down) {
        closeCenteredCard();
        secondary_down = true;
        primary_down = down;
        needs_redraw = true;
        return 1;
    }

    if (down and !primary_down) {
        if (gestureCenterAt(x_px, y_px)) {
            openCenteredCard();
            primary_down = down;
            secondary_down = secondary;
            needs_redraw = true;
            return 1;
        }
        beginPointerPress(x_px, y_px);
    } else if (down and primary_down) {
        pointerDrag(x_px, y_px);
    } else if (!down and primary_down) {
        endPointerPress(x_px, y_px);
    } else {
        if (secondary_down != secondary) needs_redraw = true;
        secondary_down = secondary;
    }

    primary_down = down;
    secondary_down = secondary;
    return if (needs_redraw) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    ensureInit();
    pulse = @mod(pulse + 1, 8192);

    if (scene == .cards and !primary_down and mode == .idle) {
        if (velocity_q8 != 0) {
            scroll_q8 += velocity_q8;
            velocity_q8 = @divTrunc(velocity_q8 * 89, 100);
            scroll_q8 = clampScroll(scroll_q8, true);
            if (absI32(velocity_q8) < 4) velocity_q8 = 0;
            needs_redraw = true;
        } else {
            const target = snapQ8ForIndex(centeredIndex());
            const delta = target - scroll_q8;
            if (absI32(delta) > 1) {
                scroll_q8 += @divTrunc(delta, 4);
                needs_redraw = true;
            } else {
                scroll_q8 = target;
            }
        }
    }
    next_wake_at_ms = if (begun_at_ms <= std.math.maxInt(i64) - 16)
        begun_at_ms + 16
    else
        begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    ensureInit();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
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
    advanceTransactionTime();
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    phase = .ready;
    return wake;
}

fn ensureInit() void {
    if (initialized) return;
    resetState();
    initialized = true;
}

fn resetState() void {
    cards = cards_seed;
    card_count = 5;
    scene = .cards;
    mode = .idle;
    scroll_q8 = 0;
    velocity_q8 = 0;
    active_card = 0;
    press_x = 0;
    press_y = 0;
    last_x = 0;
    last_y = 0;
    last_dx = 0;
    last_dy = 0;
    press_scroll_q8 = 0;
    pressed_card_idx = -1;
    drag_card_idx = -1;
    drag_dx = 0;
    drag_dy = 0;
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    pulse = 0;
    needs_redraw = true;
}

fn beginPointerPress(x: i32, y: i32) void {
    mode = .idle;
    pressed_card_idx = cardAt(x, y);
    press_x = x;
    press_y = y;
    last_x = x;
    last_y = y;
    last_dx = 0;
    last_dy = 0;
    press_scroll_q8 = scroll_q8;
    drag_card_idx = -1;
    drag_dx = 0;
    drag_dy = 0;
}

fn pointerDrag(x: i32, y: i32) void {
    last_dx = x - last_x;
    last_dy = y - last_y;
    last_x = x;
    last_y = y;

    if (pressed_card_idx < 0) {
        mode = .strip_drag;
    }

    if (mode == .idle) {
        const dx = x - press_x;
        const dy = y - press_y;
        const centered = centeredIndex();
        if (pressed_card_idx == centered and absI32(dy) > absI32(dx) + 6 and dy < 0) {
            mode = .card_drag;
            drag_card_idx = centered;
            drag_dx = dx;
            drag_dy = dy;
        } else if (absI32(dx) > 4) {
            mode = .strip_drag;
        }
    }

    switch (mode) {
        .strip_drag => {
            const dx = x - press_x;
            scroll_q8 = clampScroll(press_scroll_q8 - @divTrunc(dx * 256, CARD_SPACING), true);
            velocity_q8 = @divTrunc((-last_dx) * 256, CARD_SPACING);
            needs_redraw = true;
        },
        .card_drag => {
            drag_dx = x - press_x;
            drag_dy = y - press_y;
            reorderDraggedCard();
            needs_redraw = true;
        },
        .idle => {},
    }
}

fn endPointerPress(x: i32, y: i32) void {
    _ = x;
    _ = y;
    if (scene != .cards) return;

    switch (mode) {
        .card_drag => {
            const close_fast = drag_dy < -24 and last_dy < -4;
            if (drag_dy < -50 or close_fast) {
                closeCard(drag_card_idx);
            } else if (drag_card_idx >= 0) {
                scroll_q8 = snapQ8ForIndex(drag_card_idx);
            }
            drag_card_idx = -1;
            drag_dx = 0;
            drag_dy = 0;
            velocity_q8 = 0;
        },
        .strip_drag => {
            if (absI32(velocity_q8) < 2) velocity_q8 = 0;
        },
        .idle => {
            if (pressed_card_idx >= 0 and pressed_card_idx == centeredIndex()) {
                openCenteredCard();
            } else if (pressed_card_idx >= 0) {
                scroll_q8 = snapQ8ForIndex(pressed_card_idx);
                velocity_q8 = 0;
            }
        },
    }

    mode = .idle;
    pressed_card_idx = -1;
    needs_redraw = true;
}

fn moveSelection(delta: i32) void {
    const idx = clampI32(centeredIndex() + delta, 0, @as(i32, @intCast(card_count)) - 1);
    scroll_q8 = snapQ8ForIndex(idx);
    velocity_q8 = 0;
}

fn openCenteredCard() void {
    if (card_count == 0) return;
    active_card = centeredIndex();
    scene = .app;
}

fn closeCenteredCard() void {
    closeCard(centeredIndex());
}

fn closeCard(index: i32) void {
    if (card_count <= 1) return;
    if (index < 0 or index >= @as(i32, @intCast(card_count))) return;
    const idx = @as(usize, @intCast(index));
    var i = idx;
    while (i + 1 < card_count) : (i += 1) {
        cards[i] = cards[i + 1];
    }
    card_count -= 1;
    const new_idx = clampI32(index, 0, @as(i32, @intCast(card_count)) - 1);
    scroll_q8 = snapQ8ForIndex(new_idx);
    velocity_q8 = 0;
    if (active_card >= @as(i32, @intCast(card_count))) active_card = @as(i32, @intCast(card_count)) - 1;
}

fn reorderDraggedCard() void {
    if (drag_card_idx < 0) return;
    if (drag_dy > -8) return;
    while (drag_dx > CARD_SPACING / 2 and drag_card_idx < @as(i32, @intCast(card_count)) - 1) {
        const a = @as(usize, @intCast(drag_card_idx));
        const b = a + 1;
        const t = cards[a];
        cards[a] = cards[b];
        cards[b] = t;
        drag_card_idx += 1;
        press_x += CARD_SPACING;
        drag_dx -= CARD_SPACING;
        scroll_q8 = snapQ8ForIndex(drag_card_idx);
    }
    while (drag_dx < -CARD_SPACING / 2 and drag_card_idx > 0) {
        const a = @as(usize, @intCast(drag_card_idx));
        const b = a - 1;
        const t = cards[a];
        cards[a] = cards[b];
        cards[b] = t;
        drag_card_idx -= 1;
        press_x -= CARD_SPACING;
        drag_dx += CARD_SPACING;
        scroll_q8 = snapQ8ForIndex(drag_card_idx);
    }
}

fn cardAt(x: i32, y: i32) i32 {
    if (card_count == 0) return -1;
    const centered = centeredIndex();
    const centered_rect = cardRectFor(centered);
    if (pointInRect(x, y, centered_rect)) return centered;

    var best_idx: i32 = -1;
    var best_depth: i32 = -99999;
    var i: i32 = 0;
    while (i < @as(i32, @intCast(card_count))) : (i += 1) {
        if (i == centered) continue;
        const r = cardRectFor(i);
        if (!pointInRect(x, y, r)) continue;
        const cx = r.x + @divTrunc(r.w, 2);
        const depth = -absI32(cx - @divTrunc(@as(i32, @intCast(RENDER_W)), 2));
        if (depth > best_depth) {
            best_depth = depth;
            best_idx = i;
        }
    }
    return best_idx;
}

fn centeredIndex() i32 {
    if (card_count == 0) return 0;
    const rounded = @divTrunc(scroll_q8 + 128, 256);
    return clampI32(rounded, 0, @as(i32, @intCast(card_count)) - 1);
}

fn snapToNearest() void {
    scroll_q8 = snapQ8ForIndex(centeredIndex());
    velocity_q8 = 0;
}

fn snapQ8ForIndex(i: i32) i32 {
    return i * 256;
}

fn clampScroll(value_q8: i32, allow_overscroll: bool) i32 {
    if (card_count == 0) return 0;
    const max_q8 = (@as(i32, @intCast(card_count)) - 1) * 256;
    if (allow_overscroll) {
        return clampI32(value_q8, -100, max_q8 + 100);
    }
    return clampI32(value_q8, 0, max_q8);
}

fn cardRectFor(index: i32) Rect {
    const mid_x = @divTrunc(@as(i32, @intCast(RENDER_W)), 2);
    const delta_q8 = index * 256 - scroll_q8;
    const cx = mid_x + @divTrunc(delta_q8 * CARD_SPACING, 256);
    const dist = absI32(cx - mid_x);
    const scale_pct = clampI32(100 - @divTrunc(dist, 3), 64, 100);
    var w = @divTrunc(CARD_W * scale_pct, 100);
    var h = @divTrunc(CARD_H * scale_pct, 100);
    if (mode == .card_drag and index == drag_card_idx) {
        w = CARD_W;
        h = CARD_H;
    }
    var x = cx - @divTrunc(w, 2);
    var y = CARD_BASE_Y + @divTrunc(100 - scale_pct, 2);

    if (mode == .card_drag and index == drag_card_idx) {
        x += drag_dx;
        y += drag_dy;
    }
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn appBackButtonAt(x: i32, y: i32) bool {
    return pointInRect(x, y, .{ .x = 8, .y = 4, .w = 42, .h = 10 });
}

fn gestureCenterAt(x: i32, y: i32) bool {
    const gy = @as(i32, @intCast(RENDER_H)) - GESTURE_H;
    const cx = @divTrunc(@as(i32, @intCast(RENDER_W)), 2);
    return pointInRect(x, y, .{ .x = cx - 18, .y = gy, .w = 36, .h = GESTURE_H });
}

fn drawFrame() void {
    drawBackground();
    drawStatusBar();
    if (scene == .cards) {
        drawCardStrip();
        drawGestureBar();
    } else {
        drawActiveCardApp();
        drawGestureBar();
    }
}

fn drawBackground() void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        const gy = @divTrunc(y * 90, @as(i32, @intCast(RENDER_H)));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 1) {
            const wave_a = ((x * 7 + pulse) & 63) - 31;
            const wave_b = ((y * 5 - @divTrunc(pulse, 2)) & 63) - 31;
            const r = clampU8(4, @divTrunc(wave_b, 10));
            const g = clampU8(18, @divTrunc(gy, 3) + @divTrunc(wave_a, 7));
            const b = clampU8(32, gy + @divTrunc(wave_b, 4));
            setPixelI32(x, y, .{ r, g, b, 0xFF });
        }
    }
    drawEnergyStreak(44, 0, 14, .{ 0x95, 0xC8, 0xFF, 0x34 });
    drawEnergyStreak(143, 0, 12, .{ 0x88, 0xBD, 0xFF, 0x2E });
    drawEnergyStreak(247, 0, 15, .{ 0xA8, 0xD6, 0xFF, 0x32 });
}

fn drawEnergyStreak(x: i32, y0: i32, w: i32, c: [4]u8) void {
    var y = y0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        const alpha = clampI32(@as(i32, c[3]) + @divTrunc((((y + pulse) & 31) - 15), 2), 8, 96);
        blendRectI32(x, y, w, 1, .{ c[0], c[1], c[2], @as(u8, @intCast(alpha)) });
    }
}

fn drawStatusBar() void {
    blendRectI32(0, 0, @as(i32, @intCast(RENDER_W)), STATUS_H, .{ 0x04, 0x0C, 0x17, 0xD8 });
    drawTextScaled(8, 6, "PALM", .{ 0xDA, 0xE9, 0xFF, 0xFF }, 1);
    drawTextScaled(39, 6, "webOS", .{ 0xA8, 0xD3, 0xFF, 0xFF }, 1);
    drawTextScaled(123, 6, "CARD VIEW", .{ 0x9E, 0xC6, 0xEC, 0xFF }, 1);
    drawSignalGlyph(286, 4);
}

fn drawSignalGlyph(x: i32, y: i32) void {
    fillRectI32(x, y + 7, 2, 3, .{ 0xD4, 0xE8, 0xFF, 0xFF });
    fillRectI32(x + 3, y + 5, 2, 5, .{ 0xD4, 0xE8, 0xFF, 0xFF });
    fillRectI32(x + 6, y + 3, 2, 7, .{ 0xD4, 0xE8, 0xFF, 0xFF });
    fillRectI32(x + 9, y + 1, 2, 9, .{ 0xD4, 0xE8, 0xFF, 0xFF });
    drawBatteryGlyph(x + 16, y + 2);
}

fn drawBatteryGlyph(x: i32, y: i32) void {
    drawRect(x, y, 11, 6, .{ 0xD4, 0xE8, 0xFF, 0xFF });
    fillRectI32(x + 11, y + 2, 1, 2, .{ 0xD4, 0xE8, 0xFF, 0xFF });
    fillRectI32(x + 1, y + 1, 7, 4, .{ 0x85, 0xD2, 0x7C, 0xFF });
}

fn drawCardStrip() void {
    if (card_count == 0) return;
    const centered = centeredIndex();

    var i: i32 = 0;
    while (i < @as(i32, @intCast(card_count))) : (i += 1) {
        if (i == centered) continue;
        drawSingleCard(i, false);
    }
    drawSingleCard(centered, true);

    drawTextScaled(10, 188, "DRAG LEFT/RIGHT TO SWITCH", .{ 0x97, 0xB9, 0xD8, 0xFF }, 1);
    drawTextScaled(10, 198, "FLICK UP TO CLOSE / DRAG TO REORDER", .{ 0x97, 0xB9, 0xD8, 0xFF }, 1);
    drawTextScaled(10, 208, "TAP CENTER CARD TO OPEN", .{ 0x97, 0xB9, 0xD8, 0xFF }, 1);
}

fn drawSingleCard(index: i32, emphasize: bool) void {
    const idx = @as(usize, @intCast(index));
    const card = cards[idx];
    const r = cardRectFor(index);

    const shadow_a: u8 = if (emphasize) 86 else 48;
    blendRoundedRect(r.x + 2, r.y + 4, r.w, r.h, 7, .{ 0x00, 0x00, 0x00, shadow_a });
    drawCardBody(r, card);
    drawRoundedRectOutline(r.x, r.y, r.w, r.h, 7, if (emphasize) .{ 0xF0, 0xF8, 0xFF, 0xFF } else .{ 0xA7, 0xC2, 0xDD, 0xFF });

    drawTextScaled(r.x + 9, r.y + 9, card.title, .{ 0xEB, 0xF6, 0xFF, 0xFF }, 2);
    drawTextScaled(r.x + 9, r.y + 24, card.subtitle, .{ 0xD1, 0xE6, 0xFF, 0xFF }, 1);
    drawAppMock(r, index);

    if (mode == .card_drag and index == drag_card_idx) {
        drawDragAffordance(r);
    }
}

fn drawCardBody(r: Rect, card: Card) void {
    var y: i32 = 0;
    while (y < r.h) : (y += 1) {
        const t = @divTrunc(y * 255, @max(1, r.h - 1));
        const row: [4]u8 = .{
            lerpU8(card.top[0], card.bottom[0], t),
            lerpU8(card.top[1], card.bottom[1], t),
            lerpU8(card.top[2], card.bottom[2], t),
            0xFF,
        };
        blendRoundedRect(r.x, r.y + y, r.w, 1, 7, row);
    }
    blendRoundedRect(r.x, r.y + 36, r.w, r.h - 36, 7, .{ 0x0A, 0x11, 0x1A, 0x92 });
}

fn drawAppMock(r: Rect, index: i32) void {
    const inner = Rect{ .x = r.x + 8, .y = r.y + 42, .w = r.w - 16, .h = r.h - 52 };
    blendRoundedRect(inner.x, inner.y, inner.w, inner.h, 5, .{ 0x07, 0x0B, 0x13, 0xC8 });
    drawRoundedRectOutline(inner.x, inner.y, inner.w, inner.h, 5, .{ 0x8E, 0xA8, 0xC3, 0xFF });

    var line: i32 = 0;
    while (line < 5) : (line += 1) {
        const y = inner.y + 8 + line * 11;
        const w = inner.w - 16 - @mod(line * 13 + index * 7, 32);
        blendRectI32(inner.x + 7, y, w, 2, .{ 0x91, 0xAF, 0xCF, 0x76 });
    }
}

fn drawDragAffordance(r: Rect) void {
    drawTextScaled(r.x + r.w - 18, r.y + 8, "X", .{ 0xEF, 0xFA, 0xFF, 0xFF }, 1);
}

fn drawActiveCardApp() void {
    if (card_count == 0) return;
    const idx = @as(usize, @intCast(clampI32(active_card, 0, @as(i32, @intCast(card_count)) - 1)));
    const card = cards[idx];
    const app = Rect{ .x = 14, .y = 24, .w = @as(i32, @intCast(RENDER_W)) - 28, .h = @as(i32, @intCast(RENDER_H)) - 24 - GESTURE_H - 6 };

    blendRoundedRect(app.x + 3, app.y + 4, app.w, app.h, 8, .{ 0x00, 0x00, 0x00, 0x8A });
    drawCardBody(app, card);
    drawRoundedRectOutline(app.x, app.y, app.w, app.h, 8, .{ 0xE8, 0xF4, 0xFF, 0xFF });

    blendRectI32(app.x, app.y, app.w, 14, .{ 0x08, 0x12, 0x1D, 0xB8 });
    drawTextScaled(app.x + 8, app.y + 4, "< CARDS", .{ 0xD0, 0xE8, 0xFF, 0xFF }, 1);
    drawTextScaled(app.x + 72, app.y + 4, card.title, .{ 0xEC, 0xF7, 0xFF, 0xFF }, 1);

    drawTextScaled(app.x + 14, app.y + 26, "APP CONTENT CONTINUES RUNNING", .{ 0xE7, 0xF4, 0xFF, 0xFF }, 1);
    drawTextScaled(app.x + 14, app.y + 38, "IN BACKGROUND WHILE IN CARD VIEW.", .{ 0xE7, 0xF4, 0xFF, 0xFF }, 1);
    drawTextScaled(app.x + 14, app.y + 58, "RIGHT CLICK OR O TO RETURN.", .{ 0xC8, 0xDD, 0xF7, 0xFF }, 1);
}

fn drawGestureBar() void {
    const y = @as(i32, @intCast(RENDER_H)) - GESTURE_H;
    blendRectI32(0, y, @as(i32, @intCast(RENDER_W)), GESTURE_H, .{ 0x03, 0x06, 0x0A, 0xC8 });
    fillCircle(@divTrunc(@as(i32, @intCast(RENDER_W)), 2), y + @divTrunc(GESTURE_H, 2), 4, .{ 0xC9, 0xDE, 0xF5, 0xFF });
    if (scene == .app) {
        drawTextScaled(10, y + 5, "TAP CENTER GESTURE AREA OR O TO GO TO CARDS", .{ 0x9C, 0xBA, 0xD9, 0xFF }, 1);
    } else {
        drawTextScaled(10, y + 5, "CENTER GESTURE AREA = OPEN SELECTED APP", .{ 0x9C, 0xBA, 0xD9, 0xFF }, 1);
    }
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn blendRoundedRect(x: i32, y: i32, w: i32, h: i32, radius: i32, color: [4]u8) void {
    if (w <= 0 or h <= 0) return;
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            if (!insideRoundedRect(xx, yy, w, h, radius)) continue;
            blendPixelI32(x + xx, y + yy, color);
        }
    }
}

fn drawRoundedRectOutline(x: i32, y: i32, w: i32, h: i32, radius: i32, color: [4]u8) void {
    if (w <= 0 or h <= 0) return;
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            if (!insideRoundedRect(xx, yy, w, h, radius)) continue;
            const inner = insideRoundedRect(xx - 1, yy, w, h, radius) and
                insideRoundedRect(xx + 1, yy, w, h, radius) and
                insideRoundedRect(xx, yy - 1, w, h, radius) and
                insideRoundedRect(xx, yy + 1, w, h, radius);
            if (!inner) setPixelI32(x + xx, y + yy, color);
        }
    }
}

fn insideRoundedRect(x: i32, y: i32, w: i32, h: i32, r: i32) bool {
    if (x < 0 or y < 0 or x >= w or y >= h) return false;
    const rx = if (x < r) r - x else if (x >= w - r) x - (w - r - 1) else 0;
    const ry = if (y < r) r - y else if (y >= h - r) y - (h - r - 1) else 0;
    if (rx == 0 or ry == 0) return true;
    return rx * rx + ry * ry <= r * r;
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: [4]u8) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: [4]u8, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: [4]u8, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            fillRectI32(x + @as(i32, @intCast(rx)) * scale, y + @as(i32, @intCast(ry)) * scale, scale, scale, c);
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G', 'g' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q', 'q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z', 'z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillCircle(cx: i32, cy: i32, radius: i32, c: [4]u8) void {
    var y = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= radius * radius) setPixelI32(x, y, c);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: [4]u8) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) setPixelI32(x, y, c);
    }
}

fn blendRectI32(x0: i32, y0: i32, w: i32, h: i32, c: [4]u8) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) blendPixelI32(x, y, c);
    }
}

fn blendPixelI32(x: i32, y: i32, src: [4]u8) void {
    if (src[3] == 0) return;
    if (src[3] == 0xFF) {
        setPixelI32(x, y, src);
        return;
    }
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const alpha = @as(u16, src[3]);
    const inv = 255 - alpha;
    pixel_buf[idx + 0] = blendChannel(src[0], pixel_buf[idx + 0], alpha, inv);
    pixel_buf[idx + 1] = blendChannel(src[1], pixel_buf[idx + 1], alpha, inv);
    pixel_buf[idx + 2] = blendChannel(src[2], pixel_buf[idx + 2], alpha, inv);
    pixel_buf[idx + 3] = 0xFF;
}

fn blendChannel(src: u8, dst: u8, alpha: u16, inv: u16) u8 {
    return @as(u8, @intCast(@divTrunc(@as(u16, src) * alpha + @as(u16, dst) * inv + 127, 255)));
}

fn setPixelI32(x: i32, y: i32, c: [4]u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn clampU8(base: u8, delta: i32) u8 {
    const v = @as(i32, base) + delta;
    return @as(u8, @intCast(clampI32(v, 0, 255)));
}

fn lerpU8(a: u8, b: u8, t255: i32) u8 {
    const inv = 255 - t255;
    const v = @divTrunc(@as(i32, a) * inv + @as(i32, b) * t255 + 127, 255);
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
