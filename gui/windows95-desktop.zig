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
const ICON_W: i32 = 34;
const ICON_H: i32 = 30;
const WINDOW_W: i32 = 112;
const WINDOW_H: i32 = 78;
const WINDOW_MIN_W: i32 = 92;
const WINDOW_MIN_H: i32 = 58;
const WINDOW_MAX_W: i32 = 210;
const WINDOW_MAX_H: i32 = 140;
const TRAIL_MAX: usize = 2;
const SCROLL_CONTENT_W: i32 = 288;
const SCROLL_CONTENT_H: i32 = 260;
const TASKBAR_Y: i32 = 196;
const START_BTN_X: i32 = 4;
const START_BTN_Y: i32 = 200;
const START_BTN_W: i32 = 54;
const START_BTN_H: i32 = 16;
const START_MENU_X: i32 = 4;
const START_MENU_W: i32 = 124;
const START_BAND_W: i32 = 20;
const START_ITEM_H: i32 = 16;
const START_ITEM_GAP: i32 = 2;
const START_MENU_ITEMS: i32 = 6;
const START_MENU_H: i32 = 16 + START_MENU_ITEMS * (START_ITEM_H + START_ITEM_GAP);
const START_MENU_Y: i32 = TASKBAR_Y - START_MENU_H;
const START_ITEM_X: i32 = START_MENU_X + START_BAND_W + 4;
const START_ITEM_W: i32 = START_MENU_W - START_BAND_W - 8;
const START_ITEM_Y0: i32 = START_MENU_Y + 8;
const START_PROGRAMS_X: i32 = START_MENU_X + START_MENU_W - 2;
const START_PROGRAMS_Y: i32 = START_ITEM_Y0;
const START_PROGRAMS_W: i32 = 110;
const START_PROGRAMS_H: i32 = 8 + 3 * (START_ITEM_H + START_ITEM_GAP);

const Color = [4]u8;
const C_TEAL: Color = .{ 0x00, 0x80, 0x80, 0xFF };
const C_PANEL: Color = .{ 0xC0, 0xC0, 0xC0, 0xFF };
const C_LIGHT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_SHADOW: Color = .{ 0x80, 0x80, 0x80, 0xFF };
const C_DARK: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_BLUE: Color = .{ 0x00, 0x00, 0x80, 0xFF };
const C_SELECT: Color = .{ 0x00, 0x00, 0xA8, 0xFF };
const C_FOLDER: Color = .{ 0xF2, 0xD4, 0x5C, 0xFF };
const C_PAPER: Color = .{ 0xF5, 0xF5, 0xF5, 0xFF };
const C_GHOST: Color = .{ 0xEE, 0xEE, 0xEE, 0xFF };

const IconKind = enum(u8) { computer, network, bin, folder, document };

const Icon = struct {
    x: i32,
    y: i32,
    kind: IconKind,
    label: []const u8,
};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const ScrollAxis = enum(u8) { vertical, horizontal };

const InteractionMode = union(enum) {
    idle,
    dragging_icon: usize,
    dragging_window,
    resizing_window,
    marquee_select,
    dragging_scroll: ScrollAxis,
};

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;
var icons: [5]Icon = undefined;
var selected_icon: i32 = -1;
var selected_mask: u8 = 0;
var mode: InteractionMode = .idle;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var window_x: i32 = 92;
var window_y: i32 = 48;
var window_w: i32 = WINDOW_W;
var window_h: i32 = WINDOW_H;
var window_restore_x: i32 = 92;
var window_restore_y: i32 = 48;
var window_restore_w: i32 = WINDOW_W;
var window_restore_h: i32 = WINDOW_H;
var window_drag_x: i32 = 92;
var window_drag_y: i32 = 48;
var window_drag_w: i32 = WINDOW_W;
var window_drag_h: i32 = WINDOW_H;
var scroll_x: i32 = 0;
var scroll_y: i32 = 0;
var scroll_drag_delta: i32 = 0;
var window_minimized: bool = false;
var window_maximized: bool = false;
var start_menu_open: bool = false;
var start_programs_open: bool = false;
var desktop_menu_open: bool = false;
var desktop_menu_x: i32 = 0;
var desktop_menu_y: i32 = 0;
var marquee_x0: i32 = 0;
var marquee_y0: i32 = 0;
var marquee_x1: i32 = 0;
var marquee_y1: i32 = 0;
var primary_down: bool = false;
var secondary_down: bool = false;
var trail_x: [TRAIL_MAX]i32 = [_]i32{0} ** TRAIL_MAX;
var trail_y: [TRAIL_MAX]i32 = [_]i32{0} ** TRAIL_MAX;
var trail_len: usize = 0;
var needs_redraw: bool = true;
var initialized: bool = false;

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const LifecycleState = enum { initializing, ready, updating };
var lifecycle_state: LifecycleState = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle_state != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    lifecycle_state = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    if (x11_key == 'r' or x11_key == 'R') {
        resetDesktop();
        return 1;
    }
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    return pointerEventForTest(button_mask, x_px, y_px, 0);
}

fn pointerEventForTest(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    const down = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;
    if (secondary and !secondary_down) {
        mode = .idle;
        primary_down = false;
        trail_len = 0;
        if (desktopSurfaceAt(x_px, y_px)) {
            openDesktopMenu(x_px, y_px);
        } else {
            desktop_menu_open = false;
        }
        start_menu_open = false;
        start_programs_open = false;
        secondary_down = true;
        needs_redraw = true;
        return 1;
    }
    if (!secondary and secondary_down) {
        secondary_down = false;
        needs_redraw = true;
        return 1;
    }
    if (down and !primary_down) {
        trail_len = 0;
        if (desktop_menu_open) {
            if (desktopMenuAt(x_px, y_px)) {
                const item = desktopMenuItemAt(x_px, y_px);
                if (item >= 0) handleDesktopMenuAction(item);
                desktop_menu_open = false;
            } else {
                desktop_menu_open = false;
            }
            mode = .idle;
        } else if (startButtonAt(x_px, y_px)) {
            start_menu_open = !start_menu_open;
            start_programs_open = false;
            selected_icon = -1;
            mode = .idle;
        } else if (start_menu_open) {
            const item = startMenuItemAt(x_px, y_px);
            if (item >= 0) {
                if (item == 0) {
                    start_programs_open = !start_programs_open;
                } else {
                    handleStartMenuAction(item);
                    start_programs_open = false;
                }
            } else if (start_programs_open and startProgramsMenuAt(x_px, y_px)) {
                const sub_item = startProgramsItemAt(x_px, y_px);
                if (sub_item >= 0) handleStartProgramsAction(sub_item);
                start_menu_open = false;
                start_programs_open = false;
            } else {
                start_menu_open = false;
                start_programs_open = false;
            }
            mode = .idle;
        } else if (window_minimized and taskbarWindowButtonAt(x_px, y_px)) {
            window_minimized = false;
            selected_icon = -1;
            mode = .idle;
        } else if (!window_minimized and closeButtonAt(x_px, y_px)) {
            window_minimized = true;
            selected_icon = -1;
            mode = .idle;
        } else if (!window_minimized and maximizeButtonAt(x_px, y_px)) {
            toggleWin95Maximize();
            selected_icon = -1;
            mode = .idle;
        } else if (!window_minimized and minimizeButtonAt(x_px, y_px)) {
            window_minimized = true;
            selected_icon = -1;
            mode = .idle;
        } else if (!window_minimized and !window_maximized and resizeHandleAt(x_px, y_px)) {
            selected_icon = -1;
            mode = .resizing_window;
            drag_dx = x_px - window_w;
            drag_dy = y_px - window_h;
            window_drag_w = window_w;
            window_drag_h = window_h;
        } else if (!window_minimized and handleWin95ScrollbarPress(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
        } else if (!window_minimized and !window_maximized and titlebarAt(x_px, y_px)) {
            selected_icon = -1;
            mode = .dragging_window;
            drag_dx = x_px - window_x;
            drag_dy = y_px - window_y;
            window_drag_x = window_x;
            window_drag_y = window_y;
        } else if (!window_minimized and windowFrameAt(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else {
            const idx = iconAt(x_px, y_px);
            selected_icon = idx;
            mode = .idle;
            if (idx >= 0) {
                const icon_idx = @as(usize, @intCast(idx));
                const icon = icons[icon_idx];
                mode = .{ .dragging_icon = icon_idx };
                drag_dx = x_px - icon.x;
                drag_dy = y_px - icon.y;
                selected_mask = @as(u8, 1) << @as(u3, @intCast(icon_idx));
            } else if (desktopSurfaceAt(x_px, y_px)) {
                mode = .marquee_select;
                marquee_x0 = x_px;
                marquee_y0 = y_px;
                marquee_x1 = x_px;
                marquee_y1 = y_px;
                selected_mask = 0;
                selected_icon = -1;
            }
        }
        desktop_menu_open = false;
        start_menu_open = if (startButtonAt(x_px, y_px) or start_menu_open) start_menu_open else false;
        primary_down = true;
        needs_redraw = true;
        return 1;
    }
    if (down) {
        switch (mode) {
            .dragging_window => {
                window_drag_x = clampI32(x_px - drag_dx, 4, @as(i32, @intCast(RENDER_W)) - window_w - 4);
                window_drag_y = clampI32(y_px - drag_dy, 6, @as(i32, @intCast(RENDER_H)) - window_h - 34);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .resizing_window => {
                window_drag_w = clampI32(x_px - drag_dx, WINDOW_MIN_W, @min(WINDOW_MAX_W, @as(i32, @intCast(RENDER_W)) - window_x - 4));
                window_drag_h = clampI32(y_px - drag_dy, WINDOW_MIN_H, @min(WINDOW_MAX_H, @as(i32, @intCast(RENDER_H)) - window_y - 34));
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .dragging_icon => |idx| {
                pushTrail(icons[idx].x, icons[idx].y);
                icons[idx].x = clampI32(x_px - drag_dx, 4, @as(i32, @intCast(RENDER_W)) - ICON_W - 4);
                icons[idx].y = clampI32(y_px - drag_dy, 6, @as(i32, @intCast(RENDER_H)) - 34 - ICON_H);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .marquee_select => {
                marquee_x1 = clampI32(x_px, 0, @as(i32, @intCast(RENDER_W)) - 1);
                marquee_y1 = clampI32(y_px, 0, @as(i32, @intCast(RENDER_H)) - 1);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .dragging_scroll => |axis| {
                switch (axis) {
                    .vertical => dragWin95VScrollTo(y_px - scroll_drag_delta),
                    .horizontal => dragWin95HScrollTo(x_px - scroll_drag_delta),
                }
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .idle => {},
        }
    }
    if (!down and primary_down) {
        switch (mode) {
            .dragging_window => {
                window_x = window_drag_x;
                window_y = window_drag_y;
            },
            .resizing_window => {
                window_w = window_drag_w;
                window_h = window_drag_h;
            },
            .marquee_select => applyMarqueeSelection(),
            .dragging_scroll => {},
            .dragging_icon, .idle => {},
        }
        mode = .idle;
        trail_len = 0;
        primary_down = false;
        needs_redraw = true;
        return 1;
    }
    primary_down = down;
    return 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

export fn finish_update() i64 {
    requireUpdate();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    return begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or (lifecycle_state != .initializing and lifecycle_state != .ready)) @trap();
    ensureInit();
    drawFrame();
    needs_redraw = false;
    _ = ktx.writeHeader(&ktx_buf, RENDER_W, RENDER_H) orelse @trap();
    @memcpy(ktx_buf[ktx.HEADER_SIZE..], output_buf[0..]);
    lifecycle_state = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&ktx_buf[0])),
        .failed = 0,
    };
}

fn ensureInit() void {
    if (initialized) return;
    resetDesktop();
    initialized = true;
}

fn resetDesktop() void {
    icons = .{
        .{ .x = 18, .y = 18, .kind = .computer, .label = "My Computer" },
        .{ .x = 18, .y = 78, .kind = .network, .label = "Network" },
        .{ .x = 18, .y = 138, .kind = .bin, .label = "Recycle Bin" },
        .{ .x = 96, .y = 28, .kind = .folder, .label = "Projects" },
        .{ .x = 170, .y = 82, .kind = .document, .label = "Readme" },
    };
    selected_icon = -1;
    selected_mask = 0;
    mode = .idle;
    window_x = 92;
    window_y = 48;
    window_w = WINDOW_W;
    window_h = WINDOW_H;
    window_restore_x = window_x;
    window_restore_y = window_y;
    window_restore_w = window_w;
    window_restore_h = window_h;
    window_drag_x = window_x;
    window_drag_y = window_y;
    window_drag_w = window_w;
    window_drag_h = window_h;
    scroll_x = 0;
    scroll_y = 0;
    scroll_drag_delta = 0;
    window_minimized = false;
    window_maximized = false;
    start_menu_open = false;
    start_programs_open = false;
    desktop_menu_open = false;
    marquee_x0 = 0;
    marquee_y0 = 0;
    marquee_x1 = 0;
    marquee_y1 = 0;
    trail_len = 0;
    primary_down = false;
    secondary_down = false;
    needs_redraw = true;
}

fn titlebarAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + 16;
}

fn closeButtonAt(x: i32, y: i32) bool {
    const b = win95CaptionButtonRect(.close);
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
}

fn maximizeButtonAt(x: i32, y: i32) bool {
    const b = win95CaptionButtonRect(.maximize);
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
}

fn minimizeButtonAt(x: i32, y: i32) bool {
    const b = win95CaptionButtonRect(.minimize);
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
}

const Win95CaptionButton = enum(u8) { close, maximize, minimize };

fn win95CaptionButtonRect(which: Win95CaptionButton) Rect {
    const btn_w: i32 = 12;
    const btn_h: i32 = 10;
    const btn_y = window_y + 4;
    const close_x = window_x + window_w - btn_w - 4;
    return switch (which) {
        .close => .{ .x = close_x, .y = btn_y, .w = btn_w, .h = btn_h },
        .maximize => .{ .x = close_x - btn_w - 2, .y = btn_y, .w = btn_w, .h = btn_h },
        .minimize => .{ .x = close_x - (btn_w + 2) * 2, .y = btn_y, .w = btn_w, .h = btn_h },
    };
}

fn toggleWin95Maximize() void {
    if (window_maximized) {
        window_x = window_restore_x;
        window_y = window_restore_y;
        window_w = window_restore_w;
        window_h = window_restore_h;
        window_drag_x = window_x;
        window_drag_y = window_y;
        window_drag_w = window_w;
        window_drag_h = window_h;
        window_maximized = false;
        return;
    }
    window_restore_x = window_x;
    window_restore_y = window_y;
    window_restore_w = window_w;
    window_restore_h = window_h;
    window_x = 0;
    window_y = 0;
    window_w = @as(i32, @intCast(RENDER_W));
    window_h = TASKBAR_Y;
    window_drag_x = window_x;
    window_drag_y = window_y;
    window_drag_w = window_w;
    window_drag_h = window_h;
    window_maximized = true;
}

fn resizeHandleAt(x: i32, y: i32) bool {
    const handle_x = window_x + window_w - 21;
    const handle_y = window_y + window_h - 21;
    return x >= handle_x and x < handle_x + 13 and y >= handle_y and y < handle_y + 13;
}

fn windowFrameAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + window_h;
}

fn win95ClientRect() Rect {
    return .{ .x = window_x + 4, .y = window_y + 19, .w = window_w - 8, .h = window_h - 23 };
}

fn win95ViewportRect() Rect {
    const c = win95ClientRect();
    return .{ .x = c.x + 1, .y = c.y + 1, .w = c.w - 14, .h = c.h - 14 };
}

fn win95MaxScrollX() i32 {
    const vp = win95ViewportRect();
    return @max(0, SCROLL_CONTENT_W - vp.w);
}

fn win95MaxScrollY() i32 {
    const vp = win95ViewportRect();
    return @max(0, SCROLL_CONTENT_H - vp.h);
}

fn setWin95ScrollX(v: i32) void {
    scroll_x = clampI32(v, 0, win95MaxScrollX());
}

fn setWin95ScrollY(v: i32) void {
    scroll_y = clampI32(v, 0, win95MaxScrollY());
}

fn win95VScrollRect() Rect {
    const c = win95ClientRect();
    return .{ .x = c.x + c.w - 13, .y = c.y, .w = 13, .h = c.h - 13 };
}

fn win95HScrollRect() Rect {
    const c = win95ClientRect();
    return .{ .x = c.x, .y = c.y + c.h - 13, .w = c.w - 13, .h = 13 };
}

fn win95VThumbRect() Rect {
    const track = win95VScrollRect();
    const vp = win95ViewportRect();
    const track_span = track.h - 26;
    const thumb_h: i32 = if (win95MaxScrollY() == 0) track_span else clampI32(@divTrunc(track_span * vp.h, SCROLL_CONTENT_H), 8, track_span);
    const top = track.y + 13;
    const span = @max(1, track.h - 26 - thumb_h);
    const max_scroll = @max(1, win95MaxScrollY());
    const t = @divTrunc(scroll_y * span, max_scroll);
    return .{ .x = track.x + 2, .y = top + t, .w = 9, .h = thumb_h };
}

fn win95HThumbRect() Rect {
    const track = win95HScrollRect();
    const vp = win95ViewportRect();
    const track_span = track.w - 26;
    const thumb_w: i32 = if (win95MaxScrollX() == 0) track_span else clampI32(@divTrunc(track_span * vp.w, SCROLL_CONTENT_W), 8, track_span);
    const left = track.x + 13;
    const span = @max(1, track.w - 26 - thumb_w);
    const max_scroll = @max(1, win95MaxScrollX());
    const t = @divTrunc(scroll_x * span, max_scroll);
    return .{ .x = left + t, .y = track.y + 2, .w = thumb_w, .h = 9 };
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn dragWin95VScrollTo(thumb_y: i32) void {
    const track = win95VScrollRect();
    const thumb = win95VThumbRect();
    const min_y = track.y + 13;
    const max_y = track.y + track.h - 13 - thumb.h;
    const clamped = clampI32(thumb_y, min_y, max_y);
    const span = @max(1, max_y - min_y);
    setWin95ScrollY(@divTrunc((clamped - min_y) * win95MaxScrollY(), span));
}

fn dragWin95HScrollTo(thumb_x: i32) void {
    const track = win95HScrollRect();
    const thumb = win95HThumbRect();
    const min_x = track.x + 13;
    const max_x = track.x + track.w - 13 - thumb.w;
    const clamped = clampI32(thumb_x, min_x, max_x);
    const span = @max(1, max_x - min_x);
    setWin95ScrollX(@divTrunc((clamped - min_x) * win95MaxScrollX(), span));
}

fn handleWin95ScrollbarPress(x: i32, y: i32) bool {
    const vbar = win95VScrollRect();
    const hbar = win95HScrollRect();
    const vthumb = win95VThumbRect();
    const hthumb = win95HThumbRect();

    if (pointInRect(x, y, vthumb)) {
        mode = .{ .dragging_scroll = .vertical };
        scroll_drag_delta = y - vthumb.y;
        return true;
    }
    if (pointInRect(x, y, hthumb)) {
        mode = .{ .dragging_scroll = .horizontal };
        scroll_drag_delta = x - hthumb.x;
        return true;
    }
    if (pointInRect(x, y, vbar)) {
        if (y < vbar.y + 13) setWin95ScrollY(scroll_y - 12) else if (y >= vbar.y + vbar.h - 13) setWin95ScrollY(scroll_y + 12) else if (y < vthumb.y) setWin95ScrollY(scroll_y - 40) else if (y >= vthumb.y + vthumb.h) setWin95ScrollY(scroll_y + 40);
        mode = .idle;
        return true;
    }
    if (pointInRect(x, y, hbar)) {
        if (x < hbar.x + 13) setWin95ScrollX(scroll_x - 12) else if (x >= hbar.x + hbar.w - 13) setWin95ScrollX(scroll_x + 12) else if (x < hthumb.x) setWin95ScrollX(scroll_x - 40) else if (x >= hthumb.x + hthumb.w) setWin95ScrollX(scroll_x + 40);
        mode = .idle;
        return true;
    }
    return false;
}

fn taskbarWindowButtonAt(x: i32, y: i32) bool {
    return x >= 64 and x < 142 and y >= 200 and y < 216;
}

fn startButtonAt(x: i32, y: i32) bool {
    return x >= START_BTN_X and x < START_BTN_X + START_BTN_W and y >= START_BTN_Y and y < START_BTN_Y + START_BTN_H;
}

fn startMenuAt(x: i32, y: i32) bool {
    return x >= START_MENU_X and x < START_MENU_X + START_MENU_W and y >= START_MENU_Y and y < START_MENU_Y + START_MENU_H;
}

fn startMenuItemAt(x: i32, y: i32) i32 {
    if (!startMenuAt(x, y)) return -1;
    if (x < START_ITEM_X or x >= START_ITEM_X + START_ITEM_W) return -1;
    const rel_y = y - START_ITEM_Y0;
    if (rel_y < 0) return -1;
    const block = START_ITEM_H + START_ITEM_GAP;
    const idx = @divFloor(rel_y, block);
    if (idx < 0 or idx >= START_MENU_ITEMS) return -1;
    const in_item = (rel_y - idx * block) < START_ITEM_H;
    if (!in_item) return -1;
    return idx;
}

fn startMenuItemY(item: i32) i32 {
    return START_ITEM_Y0 + item * (START_ITEM_H + START_ITEM_GAP);
}

fn handleStartMenuAction(item: i32) void {
    switch (item) {
        1 => {
            window_minimized = false;
            selected_icon = -1;
        },
        2 => {
            selected_icon = 4;
            selected_mask = 1 << 4;
        },
        3 => {
            selected_icon = 1;
            selected_mask = 1 << 1;
        },
        4 => {
            selected_icon = 3;
            selected_mask = 1 << 3;
        },
        5 => {
            resetDesktop();
            return;
        },
        else => {},
    }
    start_menu_open = false;
    mode = .idle;
    trail_len = 0;
}

fn startProgramsMenuAt(x: i32, y: i32) bool {
    return x >= START_PROGRAMS_X and x < START_PROGRAMS_X + START_PROGRAMS_W and y >= START_PROGRAMS_Y and y < START_PROGRAMS_Y + START_PROGRAMS_H;
}

fn startProgramsItemAt(x: i32, y: i32) i32 {
    if (!startProgramsMenuAt(x, y)) return -1;
    const rel_y = y - (START_PROGRAMS_Y + 4);
    if (rel_y < 0) return -1;
    const idx = @divFloor(rel_y, START_ITEM_H + START_ITEM_GAP);
    if (idx < 0 or idx >= 3) return -1;
    if ((rel_y - idx * (START_ITEM_H + START_ITEM_GAP)) >= START_ITEM_H) return -1;
    return idx;
}

fn handleStartProgramsAction(item: i32) void {
    switch (item) {
        0 => {
            window_minimized = false;
            selected_icon = -1;
            selected_mask = 0;
        },
        1 => {
            selected_icon = 3;
            selected_mask = 1 << 3;
        },
        2 => {
            selected_icon = 4;
            selected_mask = 1 << 4;
        },
        else => {},
    }
}

fn desktopSurfaceAt(x: i32, y: i32) bool {
    if (y >= TASKBAR_Y) return false;
    if (!window_minimized and x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + window_h) return false;
    return true;
}

fn openDesktopMenu(x: i32, y: i32) void {
    desktop_menu_open = true;
    desktop_menu_x = clampI32(x, 2, @as(i32, @intCast(RENDER_W)) - 96);
    desktop_menu_y = clampI32(y, 2, @as(i32, @intCast(RENDER_H)) - 56);
}

fn desktopMenuAt(x: i32, y: i32) bool {
    return x >= desktop_menu_x and x < desktop_menu_x + 94 and y >= desktop_menu_y and y < desktop_menu_y + 50;
}

fn desktopMenuItemAt(x: i32, y: i32) i32 {
    if (!desktopMenuAt(x, y)) return -1;
    const rel_y = y - (desktop_menu_y + 5);
    if (rel_y < 0) return -1;
    const idx = @divFloor(rel_y, 14);
    if (idx < 0 or idx >= 3) return -1;
    return idx;
}

fn handleDesktopMenuAction(item: i32) void {
    switch (item) {
        0 => resetDesktop(),
        1 => {
            selected_icon = -1;
            selected_mask = 0;
        },
        2 => {
            selected_icon = 3;
            selected_mask = 1 << 3;
        },
        else => {},
    }
}

fn applyMarqueeSelection() void {
    const x0 = @min(marquee_x0, marquee_x1);
    const y0 = @min(marquee_y0, marquee_y1);
    const x1 = @max(marquee_x0, marquee_x1);
    const y1 = @max(marquee_y0, marquee_y1);
    var mask: u8 = 0;
    var i: usize = 0;
    while (i < icons.len) : (i += 1) {
        const icon = icons[i];
        if (rectsOverlap(x0, y0, x1 - x0 + 1, y1 - y0 + 1, icon.x, icon.y, ICON_W, ICON_H + 13)) {
            mask |= @as(u8, 1) << @as(u3, @intCast(i));
        }
    }
    selected_mask = mask;
    selected_icon = firstSelectedIcon(mask);
}

fn firstSelectedIcon(mask: u8) i32 {
    var i: usize = 0;
    while (i < icons.len) : (i += 1) {
        if ((mask & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) return @as(i32, @intCast(i));
    }
    return -1;
}

fn rectsOverlap(ax: i32, ay: i32, aw: i32, ah: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by;
}

fn iconAt(x: i32, y: i32) i32 {
    var i = icons.len;
    while (i > 0) {
        i -= 1;
        const icon = icons[i];
        if (x >= icon.x and y >= icon.y and x < icon.x + ICON_W and y < icon.y + ICON_H + 13) return @as(i32, @intCast(i));
    }
    return -1;
}

fn pushTrail(x: i32, y: i32) void {
    if (trail_len > 0 and trail_x[trail_len - 1] == x and trail_y[trail_len - 1] == y) return;
    if (trail_len < TRAIL_MAX) {
        trail_x[trail_len] = x;
        trail_y[trail_len] = y;
        trail_len += 1;
    } else {
        var i: usize = 1;
        while (i < TRAIL_MAX) : (i += 1) {
            trail_x[i - 1] = trail_x[i];
            trail_y[i - 1] = trail_y[i];
        }
        trail_x[TRAIL_MAX - 1] = x;
        trail_y[TRAIL_MAX - 1] = y;
    }
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_TEAL);
    var i: usize = 0;
    while (i < icons.len) : (i += 1) drawIcon(i);
    if (!window_minimized) drawWindow(window_x, window_y, window_w, window_h);
    drawTrails();
    drawTaskbar();
    if (start_menu_open) drawStartMenu();
    if (desktop_menu_open) drawDesktopMenu();
}

fn drawTrails() void {
    var i: usize = 0;
    while (i < trail_len) : (i += 1) {
        drawDottedRect(trail_x[i] - 2, trail_y[i] - 2, ICON_W + 4, ICON_H + 16, C_GHOST);
    }
    switch (mode) {
        .dragging_icon => |idx| {
            const icon = icons[idx];
            drawDottedRect(icon.x - 2, icon.y - 2, ICON_W + 4, ICON_H + 16, C_LIGHT);
        },
        .dragging_window => drawDottedRect(window_drag_x, window_drag_y, window_w, window_h, C_LIGHT),
        .resizing_window => drawDottedRect(window_x, window_y, window_drag_w, window_drag_h, C_LIGHT),
        .marquee_select => {
            const x = @min(marquee_x0, marquee_x1);
            const y = @min(marquee_y0, marquee_y1);
            const w = @max(1, @max(marquee_x0, marquee_x1) - x + 1);
            const h = @max(1, @max(marquee_y0, marquee_y1) - y + 1);
            drawDottedRect(x, y, w, h, C_LIGHT);
        },
        .dragging_scroll => {},
        .idle => {},
    }
}

fn drawWindow(x: i32, y: i32, w: i32, h: i32) void {
    fillRectI32(x, y, w, h, C_PANEL);
    drawRaised(x, y, w, h);
    fillRectI32(x + 3, y + 3, w - 6, 13, C_BLUE);
    drawText(x + 8, y + 7, "Explorer", C_LIGHT);
    const b_close = win95CaptionButtonRect(.close);
    const b_max = win95CaptionButtonRect(.maximize);
    const b_min = win95CaptionButtonRect(.minimize);
    drawWin95CaptionButton(b_close, .close);
    drawWin95CaptionButton(b_max, .maximize);
    drawWin95CaptionButton(b_min, .minimize);
    const c = win95ClientRect();
    fillRectI32(c.x, c.y, c.w, c.h, C_LIGHT);
    drawSunken(c.x, c.y, c.w, c.h);
    drawWin95Content();
    drawWin95Scrollbars(c.x, c.y, c.w, c.h);
}

fn drawWin95CaptionButton(r: Rect, which: Win95CaptionButton) void {
    fillRectI32(r.x, r.y, r.w, r.h, C_PANEL);
    drawRaised(r.x, r.y, r.w, r.h);
    switch (which) {
        .close => {
            drawLine(r.x + 3, r.y + 3, r.x + r.w - 4, r.y + r.h - 4, C_DARK);
            drawLine(r.x + r.w - 4, r.y + 3, r.x + 3, r.y + r.h - 4, C_DARK);
        },
        .maximize => {
            if (window_maximized) {
                drawRect(r.x + 3, r.y + 4, 5, 4, C_DARK);
                drawRect(r.x + 5, r.y + 2, 5, 4, C_DARK);
            } else {
                drawRect(r.x + 3, r.y + 2, r.w - 6, r.h - 5, C_DARK);
                fillRectI32(r.x + 3, r.y + 3, r.w - 6, 1, C_DARK);
            }
        },
        .minimize => {
            fillRectI32(r.x + 3, r.y + r.h - 3, r.w - 6, 1, C_DARK);
        },
    }
}

fn drawWin95Content() void {
    const vp = win95ViewportRect();
    fillRectI32(vp.x, vp.y, vp.w, vp.h, .{ 0xFF, 0xFF, 0xFF, 0xFF });
    var row: i32 = 0;
    while (row < 20) : (row += 1) {
        const y = vp.y + row * 12 - scroll_y;
        if (y >= vp.y - 6 and y < vp.y + vp.h) {
            var label_buf: [32]u8 = undefined;
            const label = buildNumberedLabel(&label_buf, row + 1, "Folder Item");
            drawTextClipped(vp.x + 4 - scroll_x, y + 2, label, C_DARK, vp);
        }
    }
}

fn drawWin95Scrollbars(cx: i32, cy: i32, cw: i32, ch: i32) void {
    const sb: i32 = 13;
    if (cw < sb + 8 or ch < sb + 8) return;

    const vbar_x = cx + cw - sb;
    const vbar_h = ch - sb;
    fillRectI32(vbar_x, cy, sb, vbar_h, C_PANEL);
    drawRect(vbar_x, cy, sb, vbar_h, C_SHADOW);
    fillRectI32(vbar_x + 1, cy + 1, sb - 2, sb - 2, C_PANEL);
    drawRaised(vbar_x + 1, cy + 1, sb - 2, sb - 2);
    fillRectI32(vbar_x + 1, cy + vbar_h - sb + 1, sb - 2, sb - 2, C_PANEL);
    drawRaised(vbar_x + 1, cy + vbar_h - sb + 1, sb - 2, sb - 2);
    const vthumb = win95VThumbRect();
    fillRectI32(vthumb.x, vthumb.y, vthumb.w, vthumb.h, C_PANEL);
    drawRaised(vthumb.x, vthumb.y, vthumb.w, vthumb.h);
    drawLine(vbar_x + @divFloor(sb, 2), cy + 4, vbar_x + 3, cy + 8, C_DARK);
    drawLine(vbar_x + @divFloor(sb, 2), cy + 4, vbar_x + sb - 4, cy + 8, C_DARK);
    drawLine(vbar_x + @divFloor(sb, 2), cy + vbar_h - 5, vbar_x + 3, cy + vbar_h - 9, C_DARK);
    drawLine(vbar_x + @divFloor(sb, 2), cy + vbar_h - 5, vbar_x + sb - 4, cy + vbar_h - 9, C_DARK);

    const hbar_y = cy + ch - sb;
    const hbar_w = cw - sb;
    fillRectI32(cx, hbar_y, hbar_w, sb, C_PANEL);
    drawRect(cx, hbar_y, hbar_w, sb, C_SHADOW);
    fillRectI32(cx + 1, hbar_y + 1, sb - 2, sb - 2, C_PANEL);
    drawRaised(cx + 1, hbar_y + 1, sb - 2, sb - 2);
    fillRectI32(cx + hbar_w - sb + 1, hbar_y + 1, sb - 2, sb - 2, C_PANEL);
    drawRaised(cx + hbar_w - sb + 1, hbar_y + 1, sb - 2, sb - 2);
    const hthumb = win95HThumbRect();
    fillRectI32(hthumb.x, hthumb.y, hthumb.w, hthumb.h, C_PANEL);
    drawRaised(hthumb.x, hthumb.y, hthumb.w, hthumb.h);
    drawLine(cx + 4, hbar_y + @divFloor(sb, 2), cx + 8, hbar_y + 3, C_DARK);
    drawLine(cx + 4, hbar_y + @divFloor(sb, 2), cx + 8, hbar_y + sb - 4, C_DARK);
    drawLine(cx + hbar_w - 5, hbar_y + @divFloor(sb, 2), cx + hbar_w - 9, hbar_y + 3, C_DARK);
    drawLine(cx + hbar_w - 5, hbar_y + @divFloor(sb, 2), cx + hbar_w - 9, hbar_y + sb - 4, C_DARK);

    fillRectI32(vbar_x, hbar_y, sb, sb, C_PANEL);
    drawRect(vbar_x, hbar_y, sb, sb, C_SHADOW);
    drawLine(vbar_x + 2, hbar_y + sb - 3, vbar_x + sb - 3, hbar_y + 2, C_SHADOW);
}

fn drawIcon(i: usize) void {
    const icon = icons[i];
    const selected = ((selected_mask & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) or selected_icon == @as(i32, @intCast(i));
    if (selected) drawDottedRect(icon.x - 3, icon.y - 3, ICON_W + 6, ICON_H + 18, C_LIGHT);
    drawIconGlyph(icon.kind, icon.x + 7, icon.y);
    const label_w = textWidth(icon.label);
    const label_x = icon.x + @divFloor(ICON_W - label_w, 2);
    if (selected) fillRectI32(label_x - 2, icon.y + ICON_H + 2, label_w + 4, 9, C_SELECT);
    drawText(label_x, icon.y + ICON_H + 4, icon.label, C_LIGHT);
}

fn drawIconGlyph(kind: IconKind, x: i32, y: i32) void {
    switch (kind) {
        .computer => {
            fillRectI32(x + 2, y + 4, 18, 14, C_PANEL);
            drawSunken(x + 2, y + 4, 18, 14);
            fillRectI32(x + 7, y + 19, 8, 3, C_PANEL);
            fillRectI32(x + 4, y + 22, 14, 2, C_PANEL);
            fillRectI32(x + 5, y + 7, 12, 7, C_BLUE);
        },
        .network => {
            fillRectI32(x + 2, y + 4, 10, 8, C_PANEL);
            fillRectI32(x + 15, y + 4, 10, 8, C_PANEL);
            fillRectI32(x + 8, y + 17, 10, 8, C_PANEL);
            drawLine(x + 7, y + 12, x + 13, y + 17, C_LIGHT);
            drawLine(x + 20, y + 12, x + 15, y + 17, C_LIGHT);
        },
        .bin => {
            fillRectI32(x + 6, y + 7, 14, 17, C_PANEL);
            drawRect(x + 6, y + 7, 14, 17, C_DARK);
            fillRectI32(x + 4, y + 4, 18, 3, C_PANEL);
            drawLine(x + 9, y + 10, x + 9, y + 21, C_SHADOW);
            drawLine(x + 15, y + 10, x + 15, y + 21, C_SHADOW);
        },
        .folder => {
            fillRectI32(x + 2, y + 8, 22, 15, C_FOLDER);
            fillRectI32(x + 4, y + 5, 9, 4, C_FOLDER);
            drawRect(x + 2, y + 8, 22, 15, C_DARK);
        },
        .document => {
            fillRectI32(x + 6, y + 3, 16, 22, C_PAPER);
            drawRect(x + 6, y + 3, 16, 22, C_DARK);
            drawLine(x + 10, y + 9, x + 18, y + 9, C_SHADOW);
            drawLine(x + 10, y + 13, x + 18, y + 13, C_SHADOW);
            drawLine(x + 10, y + 17, x + 16, y + 17, C_SHADOW);
        },
    }
}

fn drawTaskbar() void {
    fillRectI32(0, TASKBAR_Y, 320, 24, C_PANEL);
    drawRaised(0, TASKBAR_Y, 320, 24);
    fillRectI32(START_BTN_X, START_BTN_Y, START_BTN_W, START_BTN_H, C_PANEL);
    if (start_menu_open) {
        drawSunken(START_BTN_X, START_BTN_Y, START_BTN_W, START_BTN_H);
    } else {
        drawRaised(START_BTN_X, START_BTN_Y, START_BTN_W, START_BTN_H);
    }
    drawText(22, 205, "Start", C_DARK);
    fillRectI32(10, 204, 8, 8, C_BLUE);
    fillRectI32(64, 200, 78, 16, C_PANEL);
    if (window_minimized) {
        drawRaised(64, 200, 78, 16);
    } else {
        drawSunken(64, 200, 78, 16);
    }
    drawText(74, 205, "Explorer", C_DARK);
    fillRectI32(256, 200, 58, 16, C_PANEL);
    drawSunken(256, 200, 58, 16);
    drawText(270, 205, "4:11 PM", C_DARK);
}

fn drawStartMenu() void {
    fillRectI32(START_MENU_X, START_MENU_Y, START_MENU_W, START_MENU_H, C_PANEL);
    drawRaised(START_MENU_X, START_MENU_Y, START_MENU_W, START_MENU_H);
    fillRectI32(START_MENU_X + 2, START_MENU_Y + 2, START_BAND_W - 2, START_MENU_H - 4, C_BLUE);
    drawText(START_MENU_X + 6, START_MENU_Y + START_MENU_H - 14, "Win95", C_LIGHT);
    drawStartMenuItem(0, "Programs");
    drawStartMenuItem(1, "Open");
    drawStartMenuItem(2, "Documents");
    drawStartMenuItem(3, "Settings");
    drawStartMenuItem(4, "Find");
    drawStartMenuItem(5, "Shut Down");
    if (start_programs_open) drawProgramsMenu();
}

fn drawStartMenuItem(item: i32, label: []const u8) void {
    const y = startMenuItemY(item);
    fillRectI32(START_ITEM_X, y, START_ITEM_W, START_ITEM_H, C_PANEL);
    drawRaised(START_ITEM_X, y, START_ITEM_W, START_ITEM_H);
    drawText(START_ITEM_X + 8, y + 5, label, C_DARK);
    if (item == 0) drawText(START_ITEM_X + START_ITEM_W - 10, y + 5, ">", C_DARK);
}

fn drawProgramsMenu() void {
    fillRectI32(START_PROGRAMS_X, START_PROGRAMS_Y, START_PROGRAMS_W, START_PROGRAMS_H, C_PANEL);
    drawRaised(START_PROGRAMS_X, START_PROGRAMS_Y, START_PROGRAMS_W, START_PROGRAMS_H);
    drawProgramMenuItem(0, "Explorer");
    drawProgramMenuItem(1, "Projects");
    drawProgramMenuItem(2, "Readme");
}

fn drawProgramMenuItem(item: i32, label: []const u8) void {
    const y = START_PROGRAMS_Y + 4 + item * (START_ITEM_H + START_ITEM_GAP);
    fillRectI32(START_PROGRAMS_X + 3, y, START_PROGRAMS_W - 6, START_ITEM_H, C_PANEL);
    drawRaised(START_PROGRAMS_X + 3, y, START_PROGRAMS_W - 6, START_ITEM_H);
    drawText(START_PROGRAMS_X + 10, y + 5, label, C_DARK);
}

fn drawDesktopMenu() void {
    fillRectI32(desktop_menu_x, desktop_menu_y, 94, 50, C_PANEL);
    drawRaised(desktop_menu_x, desktop_menu_y, 94, 50);
    drawDesktopMenuItem(0, "Arrange");
    drawDesktopMenuItem(1, "Clear");
    drawDesktopMenuItem(2, "New");
}

fn drawDesktopMenuItem(item: i32, label: []const u8) void {
    const y = desktop_menu_y + 5 + item * 14;
    fillRectI32(desktop_menu_x + 4, y, 86, 12, C_PANEL);
    drawRaised(desktop_menu_x + 4, y, 86, 12);
    drawText(desktop_menu_x + 10, y + 3, label, C_DARK);
}

fn drawRaised(x: i32, y: i32, w: i32, h: i32) void {
    fillRectI32(x, y, w, 1, C_LIGHT);
    fillRectI32(x, y, 1, h, C_LIGHT);
    fillRectI32(x, y + h - 1, w, 1, C_DARK);
    fillRectI32(x + w - 1, y, 1, h, C_DARK);
    fillRectI32(x + 1, y + h - 2, w - 2, 1, C_SHADOW);
    fillRectI32(x + w - 2, y + 1, 1, h - 2, C_SHADOW);
}

fn drawSunken(x: i32, y: i32, w: i32, h: i32) void {
    fillRectI32(x, y, w, 1, C_DARK);
    fillRectI32(x, y, 1, h, C_DARK);
    fillRectI32(x, y + h - 1, w, 1, C_LIGHT);
    fillRectI32(x + w - 1, y, 1, h, C_LIGHT);
}

fn drawDottedRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    var i: i32 = 0;
    while (i < w) : (i += 2) {
        setPixelI32(x + i, y, c);
        setPixelI32(x + i, y + h - 1, c);
    }
    i = 0;
    while (i < h) : (i += 2) {
        setPixelI32(x, y + i, c);
        setPixelI32(x + w - 1, y + i, c);
    }
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn drawLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: Color) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setPixelI32(x0, y0, c);
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

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawChar(x + @as(i32, @intCast(i * 4)), y, text[i], c);
}

fn drawTextClipped(x: i32, y: i32, text: []const u8, c: Color, clip: Rect) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const cx = x + @as(i32, @intCast(i * 4));
        if (cx + 3 <= clip.x or cx >= clip.x + clip.w) continue;
        drawCharClipped(cx, y, text[i], c, clip);
    }
}

fn buildNumberedLabel(buf: *[32]u8, number: i32, item: []const u8) []const u8 {
    var value: u32 = @as(u32, @intCast(@max(1, number)));
    var digits_rev: [10]u8 = undefined;
    var digits_len: usize = 0;
    while (true) {
        digits_rev[digits_len] = @as(u8, @intCast('0')) + @as(u8, @intCast(value % 10));
        digits_len += 1;
        value = @divTrunc(value, 10);
        if (value == 0) break;
    }

    var out: usize = 0;
    var i = digits_len;
    while (i > 0) {
        i -= 1;
        buf[out] = digits_rev[i];
        out += 1;
    }
    buf[out] = '.';
    out += 1;
    buf[out] = ' ';
    out += 1;

    const copy_len = @min(item.len, buf.len - out);
    std.mem.copyForwards(u8, buf[out .. out + copy_len], item[0..copy_len]);
    return buf[0 .. out + copy_len];
}

fn textWidth(text: []const u8) i32 {
    return @as(i32, @intCast(text.len * 4));
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) != 0) setPixelI32(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), c);
        }
    }
}

fn drawCharClipped(x: i32, y: i32, ch: u8, c: Color, clip: Rect) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        const py = y + @as(i32, @intCast(ry));
        if (py < clip.y or py >= clip.y + clip.h) continue;
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            const px = x + @as(i32, @intCast(rx));
            if (px < clip.x or px >= clip.x + clip.w) continue;
            setPixelI32(px, py, c);
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
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '.' => .{ 0b000, 0b000, 0b000, 0b000, 0b010 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, c: Color) void {
    var y = y0;
    while (y < y0 + h and y < RENDER_H) : (y += 1) {
        var x = x0;
        while (x < x0 + w and x < RENDER_W) : (x += 1) setPixel(x, y, c);
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = clampI32(x0, 0, @as(i32, @intCast(RENDER_W)));
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ex = clampI32(x0 + w, 0, @as(i32, @intCast(RENDER_W)));
    const ey = clampI32(y0 + h, 0, @as(i32, @intCast(RENDER_H)));
    if (sx >= ex or sy >= ey) return;
    fillRect(@as(usize, @intCast(sx)), @as(usize, @intCast(sy)), @as(usize, @intCast(ex - sx)), @as(usize, @intCast(ey - sy)), c);
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    setPixel(@as(usize, @intCast(x)), @as(usize, @intCast(y)), c);
}

fn setPixel(x: usize, y: usize, c: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

test "drag moves selected icon" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 20, 20, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 80, 80, 0);
    _ = pointerEventForTest(0, 80, 80, 0);
    try std.testing.expect(icons[0].x != 18 or icons[0].y != 18);
}

test "window outline commits on release" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 100, 55, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 150, 85, 0);
    try std.testing.expect(window_x == 92 and window_y == 48);
    try std.testing.expect(window_drag_x != 92 or window_drag_y != 48);
    _ = pointerEventForTest(0, 150, 85, 0);
    try std.testing.expect(window_x == window_drag_x and window_y == window_drag_y);
}

test "minimize hides window and taskbar restores it" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 194, 58, 0);
    _ = pointerEventForTest(0, 194, 58, 0);
    try std.testing.expect(window_minimized);
    _ = pointerEventForTest(BTN_PRIMARY, 80, 208, 0);
    _ = pointerEventForTest(0, 80, 208, 0);
    try std.testing.expect(!window_minimized);
}

test "maximize toggles to work area and restore" {
    resetDesktop();
    const max_btn = win95CaptionButtonRect(.maximize);
    _ = pointerEventForTest(BTN_PRIMARY, max_btn.x + 2, max_btn.y + 2, 0);
    _ = pointerEventForTest(0, max_btn.x + 2, max_btn.y + 2, 0);
    try std.testing.expect(window_maximized);
    try std.testing.expect(window_x == 0 and window_y == 0);
    try std.testing.expect(window_w == @as(i32, @intCast(RENDER_W)) and window_h == TASKBAR_Y);

    const max_btn_rest = win95CaptionButtonRect(.maximize);
    _ = pointerEventForTest(BTN_PRIMARY, max_btn_rest.x + 2, max_btn_rest.y + 2, 0);
    _ = pointerEventForTest(0, max_btn_rest.x + 2, max_btn_rest.y + 2, 0);
    try std.testing.expect(!window_maximized);
    try std.testing.expect(window_x == 92 and window_y == 48 and window_w == WINDOW_W and window_h == WINDOW_H);
}

test "resize outline commits on release" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 188, 111, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 232, 152, 0);
    try std.testing.expect(window_w == WINDOW_W and window_h == WINDOW_H);
    try std.testing.expect(window_drag_w > WINDOW_W and window_drag_h > WINDOW_H);
    _ = pointerEventForTest(0, 232, 152, 0);
    try std.testing.expect(window_w == window_drag_w and window_h == window_drag_h);
}

test "start button toggles menu and outside click closes it" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 12, 206, 0);
    _ = pointerEventForTest(0, 12, 206, 0);
    try std.testing.expect(start_menu_open);
    _ = pointerEventForTest(BTN_PRIMARY, 200, 140, 0);
    _ = pointerEventForTest(0, 200, 140, 0);
    try std.testing.expect(!start_menu_open);
}

test "start menu Open restores minimized window" {
    resetDesktop();
    window_minimized = true;
    _ = pointerEventForTest(BTN_PRIMARY, 12, 206, 0);
    _ = pointerEventForTest(0, 12, 206, 0);
    try std.testing.expect(start_menu_open);
    const open_y = startMenuItemY(1) + 6;
    _ = pointerEventForTest(BTN_PRIMARY, START_ITEM_X + 6, open_y, 0);
    _ = pointerEventForTest(0, START_ITEM_X + 6, open_y, 0);
    try std.testing.expect(!window_minimized);
    try std.testing.expect(!start_menu_open);
}

test "start menu Programs opens submenu" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 12, 206, 0);
    _ = pointerEventForTest(0, 12, 206, 0);
    try std.testing.expect(start_menu_open);
    _ = pointerEventForTest(BTN_PRIMARY, START_ITEM_X + 8, START_ITEM_Y0 + 6, 0);
    _ = pointerEventForTest(0, START_ITEM_X + 8, START_ITEM_Y0 + 6, 0);
    try std.testing.expect(start_programs_open);
    _ = pointerEventForTest(BTN_PRIMARY, START_PROGRAMS_X + 12, START_PROGRAMS_Y + 10, 0);
    _ = pointerEventForTest(0, START_PROGRAMS_X + 12, START_PROGRAMS_Y + 10, 0);
    try std.testing.expect(!start_menu_open);
    try std.testing.expect(!start_programs_open);
}

test "start menu Restart resets desktop state" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 20, 20, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 80, 80, 0);
    _ = pointerEventForTest(0, 80, 80, 0);
    try std.testing.expect(icons[0].x != 18 or icons[0].y != 18);
    _ = pointerEventForTest(BTN_PRIMARY, 12, 206, 0);
    _ = pointerEventForTest(0, 12, 206, 0);
    const shutdown_y = startMenuItemY(5) + 6;
    _ = pointerEventForTest(BTN_PRIMARY, START_ITEM_X + 6, shutdown_y, 0);
    _ = pointerEventForTest(0, START_ITEM_X + 6, shutdown_y, 0);
    try std.testing.expect(icons[0].x == 18 and icons[0].y == 18);
    try std.testing.expect(!start_menu_open);
}

test "desktop context menu opens on right click and action clears selection" {
    resetDesktop();
    selected_icon = 2;
    selected_mask = 1 << 2;
    try std.testing.expect(desktopSurfaceAt(250, 150));
    _ = pointerEventForTest(BTN_SECONDARY, 250, 150, 0);
    _ = pointerEventForTest(0, 250, 150, 0);
    try std.testing.expect(desktop_menu_open);
    _ = pointerEventForTest(BTN_PRIMARY, desktop_menu_x + 10, desktop_menu_y + 20, 0);
    _ = pointerEventForTest(0, desktop_menu_x + 10, desktop_menu_y + 20, 0);
    try std.testing.expect(selected_icon == -1);
    try std.testing.expect(selected_mask == 0);
}

test "marquee selection can select multiple icons" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 8, 8, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 70, 170, 0);
    _ = pointerEventForTest(0, 70, 170, 0);
    try std.testing.expect((selected_mask & 0b0000_0111) == 0b0000_0111);
}

test "clicking window client does not click-through to desktop icons" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 170, 90, 0);
    _ = pointerEventForTest(0, 170, 90, 0);
    try std.testing.expect(selected_icon == -1);
}

test "windows95 vertical scrollbar drag updates scroll position" {
    resetDesktop();
    const thumb = win95VThumbRect();
    _ = pointerEventForTest(BTN_PRIMARY, thumb.x + 2, thumb.y + 2, 0);
    _ = pointerEventForTest(BTN_PRIMARY, thumb.x + 2, thumb.y + 20, 0);
    _ = pointerEventForTest(0, thumb.x + 2, thumb.y + 20, 0);
    try std.testing.expect(scroll_y > 0);
}
