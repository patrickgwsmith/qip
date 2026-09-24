const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const MENU_BAR_H: i32 = 22;
const WINDOW_TITLEBAR_H: i32 = 16;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;
const XK_SHIFT_L: i32 = 0xFFE1;
const XK_SHIFT_R: i32 = 0xFFE2;
const ICON_W: i32 = 38;
const ICON_H: i32 = 32;
const WINDOW_W: i32 = 136;
const WINDOW_H: i32 = 76;
const WINDOW_MIN_W: i32 = 104;
const WINDOW_MIN_H: i32 = 58;
const WINDOW_MAX_W: i32 = 220;
const WINDOW_MAX_H: i32 = 130;
const WINDOW_BYTES: usize = @as(usize, @intCast(WINDOW_MAX_W)) * @as(usize, @intCast(WINDOW_MAX_H)) * 4;
const WINDOW_CORNER_R: i32 = 7;
const SHADOW_PAD: i32 = 16;
const SHADOW_OFFSET_X: i32 = 8;
const SHADOW_OFFSET_Y: i32 = 12;
const SHADOW_TILE_CORE: i32 = 48;
const SHADOW_RADIUS: i32 = 4;
const SHADOW_KERNEL_R: i32 = 2;
const SHADOW_TILE_EXT: i32 = SHADOW_TILE_CORE + SHADOW_RADIUS * 2;
const SHADOW_TILE_PIXELS: usize = @as(usize, @intCast(SHADOW_TILE_EXT * SHADOW_TILE_EXT));
const DOCK_N: usize = 7;
const DOCK_SLOT_STEP: i32 = 31;
const DOCK_MINIMIZED_SLOT: usize = DOCK_N - 1;
const DOCK_BASE_SIZE: i32 = 22;
const DOCK_MAX_BOOST: i32 = 12;
const DOCK_Y: i32 = 176;
const DOCK_PANEL_Y: i32 = DOCK_Y + 4;
const GENIE_FRAMES: i32 = 12;
const GENIE_SHIFT_FRAMES: i32 = 48;
const SCROLL_CONTENT_W: i32 = 320;
const SCROLL_CONTENT_H: i32 = 280;

const Color = [4]u8;
const C_SKY_TOP: Color = .{ 0x52, 0x7D, 0xB9, 0xFF };
const C_SKY_BOTTOM: Color = .{ 0x18, 0x2D, 0x52, 0xFF };
const C_BAR_TOP: Color = .{ 0xEE, 0xF2, 0xF8, 0xFF };
const C_BAR_BOTTOM: Color = .{ 0xAA, 0xB6, 0xC7, 0xFF };
const C_LIGHT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_DARK: Color = .{ 0x08, 0x0A, 0x0E, 0xFF };
const C_TEXT: Color = .{ 0xF8, 0xF8, 0xF8, 0xFF };
const C_SELECT: Color = .{ 0x2D, 0x68, 0xD8, 0xFF };
const C_DOCK: Color = .{ 0xD5, 0xE1, 0xEF, 0x78 };
const C_DOCK_EDGE: Color = .{ 0x5E, 0x74, 0x90, 0x96 };
const C_FOLDER: Color = .{ 0x37, 0x8D, 0xE8, 0xFF };
const C_DRIVE: Color = .{ 0xD7, 0xDD, 0xE4, 0xFF };
const C_DOC: Color = .{ 0xF4, 0xF4, 0xF7, 0xFF };
const C_GREEN: Color = .{ 0x56, 0xC8, 0x5C, 0xFF };
const C_RED: Color = .{ 0xE8, 0x56, 0x4F, 0xFF };
const C_YELLOW: Color = .{ 0xF2, 0xC7, 0x4D, 0xFF };
const C_PURPLE: Color = .{ 0x91, 0x62, 0xD9, 0xFF };

const IconKind = enum(u8) { drive, folder, document, disk, app };
const DockKind = enum(u8) { finder, safari, mail, calendar, photos, terminal, trash };
const TrafficLight = enum(u8) { none, close, minimize, zoom };
const ScrollAxis = enum(u8) { vertical, horizontal };
const ScrollArrowDir = enum(u8) { up, down, left, right };

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

const GenieMode = enum(u8) { none, minimizing, restoring };
const MenuId = enum(u8) { none, finder, file, edit, view };
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
var window_buf: [WINDOW_BYTES]u8 = undefined;
var shadow_src_tile: [SHADOW_TILE_PIXELS]u16 = [_]u16{0} ** SHADOW_TILE_PIXELS;
var shadow_tmp_a: [SHADOW_TILE_PIXELS]u16 = [_]u16{0} ** SHADOW_TILE_PIXELS;
var shadow_tmp_b: [SHADOW_TILE_PIXELS]u16 = [_]u16{0} ** SHADOW_TILE_PIXELS;
var icons: [5]Icon = undefined;
var selected_icon: i32 = -1;
var selected_mask: u8 = 0;
var mode: InteractionMode = .idle;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var scroll_drag_delta: i32 = 0;
var drag_icon_proxy_x: i32 = 0;
var drag_icon_proxy_y: i32 = 0;
var scroll_x: i32 = 0;
var scroll_y: i32 = 0;
var window_x: i32 = 80;
var window_y: i32 = 42;
var window_w: i32 = WINDOW_W;
var window_h: i32 = WINDOW_H;
var window_restore_x: i32 = 80;
var window_restore_y: i32 = 42;
var window_restore_w: i32 = WINDOW_W;
var window_restore_h: i32 = WINDOW_H;
var window_zoomed: bool = false;
var window_minimized: bool = false;
var genie_mode: GenieMode = .none;
var genie_frame: i32 = 0;
var genie_total_frames: i32 = GENIE_FRAMES;
var menu_open: MenuId = .none;
var desktop_menu_open: bool = false;
var desktop_menu_x: i32 = 0;
var desktop_menu_y: i32 = 0;
var marquee_x0: i32 = 0;
var marquee_y0: i32 = 0;
var marquee_x1: i32 = 0;
var marquee_y1: i32 = 0;
var shift_down: bool = false;
var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var dock_hover_active: bool = false;
var primary_down: bool = false;
var secondary_down: bool = false;
var needs_redraw: bool = true;
var initialized: bool = false;

const dock_icons = [_]DockKind{ .finder, .safari, .mail, .calendar, .photos, .terminal, .trash };

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
var time_advanced = false;

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle_state != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    time_advanced = false;
    lifecycle_state = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    return keyEventForTest(x11_key, flags, 0);
}

fn keyEventForTest(x11_key: i32, flags: i32, _: i64) i32 {
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (x11_key == XK_SHIFT_L or x11_key == XK_SHIFT_R) {
        shift_down = is_down;
        return 1;
    }
    if (!is_down) return 0;
    if (x11_key == 'r' or x11_key == 'R') {
        resetDesktop();
        return 1;
    }
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    return pointerEventForTest(button_mask, x_px, y_px, 0);
}

fn pointerEventForTest(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    pointer_x = x_px;
    pointer_y = y_px;
    updateDockHoverState();
    const down = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;
    if (genie_mode != .none) {
        primary_down = down;
        secondary_down = secondary;
        return 0;
    }

    if (secondary and !secondary_down) {
        mode = .idle;
        primary_down = false;
        if (desktopSurfaceAt(x_px, y_px)) {
            openDesktopMenu(x_px, y_px);
        } else {
            desktop_menu_open = false;
        }
        menu_open = .none;
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
        if (desktop_menu_open) {
            if (desktopMenuAt(x_px, y_px)) {
                const item = desktopMenuItemAt(x_px, y_px);
                if (item >= 0) handleDesktopMenuAction(item);
            }
            desktop_menu_open = false;
            mode = .idle;
        } else if (handleMenuPress(x_px, y_px)) {
            mode = .idle;
        } else if (window_minimized and minimizedWindowAt(x_px, y_px)) {
            startGenie(.restoring);
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else if (!window_minimized and zoomButtonAt(x_px, y_px)) {
            toggleTigerZoom();
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else if (!window_minimized and minimizeButtonAt(x_px, y_px)) {
            startGenie(.minimizing);
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else if (!window_minimized and resizeHandleAt(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
            mode = .resizing_window;
            drag_dx = x_px - window_w;
            drag_dy = y_px - window_h;
            window_zoomed = false;
        } else if (!window_minimized and handleTigerScrollbarPress(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
        } else if (!window_minimized and titlebarAt(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
            mode = .dragging_window;
            drag_dx = x_px - window_x;
            drag_dy = y_px - window_y;
            window_zoomed = false;
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
                selected_mask = @as(u8, 1) << @as(u3, @intCast(idx));
                drag_dx = x_px - icon.x;
                drag_dy = y_px - icon.y;
                drag_icon_proxy_x = icon.x;
                drag_icon_proxy_y = icon.y;
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
        primary_down = true;
        needs_redraw = true;
        return 1;
    }
    if (down) {
        switch (mode) {
            .dragging_window => {
                window_x = clampI32(x_px - drag_dx, -window_w + 28, @as(i32, @intCast(RENDER_W)) - 28);
                const max_window_y = DOCK_PANEL_Y - WINDOW_TITLEBAR_H;
                window_y = clampI32(y_px - drag_dy, MENU_BAR_H, max_window_y);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .resizing_window => {
                window_w = clampI32(x_px - drag_dx, WINDOW_MIN_W, @min(WINDOW_MAX_W, @as(i32, @intCast(RENDER_W)) - window_x - 4));
                const max_window_h = @max(WINDOW_MIN_H, @min(WINDOW_MAX_H, DOCK_PANEL_Y - window_y));
                window_h = clampI32(y_px - drag_dy, WINDOW_MIN_H, max_window_h);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .dragging_icon => |idx| {
                _ = idx;
                drag_icon_proxy_x = clampI32(x_px - drag_dx, 6, @as(i32, @intCast(RENDER_W)) - ICON_W - 6);
                drag_icon_proxy_y = clampI32(y_px - drag_dy, 24, 154);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .dragging_scroll => |axis| {
                switch (axis) {
                    .vertical => dragTigerVScrollTo((y_px - window_y) - scroll_drag_delta),
                    .horizontal => dragTigerHScrollTo((x_px - window_x) - scroll_drag_delta),
                }
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
            .idle => {},
        }
    }
    if (!down and primary_down) {
        if (mode == .marquee_select) applyMarqueeSelection();
        if (mode == .dragging_icon) {
            const idx = mode.dragging_icon;
            icons[idx].x = drag_icon_proxy_x;
            icons[idx].y = drag_icon_proxy_y;
        }
        mode = .idle;
        primary_down = false;
        needs_redraw = true;
        return 1;
    }
    if (pointer_y >= 155 or primary_down or dock_hover_active) {
        needs_redraw = true;
    }
    primary_down = down;
    return if (needs_redraw) 1 else 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    advanceGenieFrameForTest();
}

fn advanceGenieFrameForTest() void {
    if (genie_mode != .none) {
        genie_frame += 1;
        if (genie_frame >= genie_total_frames) {
            if (genie_mode == .restoring) window_minimized = false;
            genie_mode = .none;
            genie_frame = 0;
            genie_total_frames = GENIE_FRAMES;
        }
        needs_redraw = true;
    }
}

export fn finish_update() i64 {
    requireUpdate();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    const wake = if (genie_mode != .none) begun_at_ms +| 16 else begun_at_ms;
    lifecycle_state = .ready;
    return wake;
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
        .{ .x = 246, .y = 34, .kind = .drive, .label = "Macintosh HD" },
        .{ .x = 246, .y = 86, .kind = .disk, .label = "Backup" },
        .{ .x = 28, .y = 42, .kind = .folder, .label = "Projects" },
        .{ .x = 28, .y = 96, .kind = .document, .label = "Notes" },
        .{ .x = 128, .y = 62, .kind = .app, .label = "Preview" },
    };
    selected_icon = -1;
    selected_mask = 0;
    mode = .idle;
    window_x = 80;
    window_y = 42;
    window_w = WINDOW_W;
    window_h = WINDOW_H;
    window_restore_x = window_x;
    window_restore_y = window_y;
    window_restore_w = window_w;
    window_restore_h = window_h;
    window_zoomed = false;
    scroll_x = 0;
    scroll_y = 0;
    scroll_drag_delta = 0;
    drag_icon_proxy_x = 0;
    drag_icon_proxy_y = 0;
    window_minimized = false;
    genie_mode = .none;
    genie_frame = 0;
    genie_total_frames = GENIE_FRAMES;
    menu_open = .none;
    desktop_menu_open = false;
    desktop_menu_x = 0;
    desktop_menu_y = 0;
    marquee_x0 = 0;
    marquee_y0 = 0;
    marquee_x1 = 0;
    marquee_y1 = 0;
    shift_down = false;
    pointer_x = -1000;
    pointer_y = -1000;
    dock_hover_active = false;
    primary_down = false;
    secondary_down = false;
    needs_redraw = true;
}

fn handleMenuPress(x: i32, y: i32) bool {
    const bar_hit = menuBarHit(x, y);
    if (bar_hit != .none) {
        menu_open = if (menu_open == bar_hit) .none else bar_hit;
        needs_redraw = true;
        return true;
    }
    if (menu_open != .none) {
        const item = menuItemAt(menu_open, x, y);
        if (item >= 0) applyMenuAction(menu_open, item);
        menu_open = .none;
        needs_redraw = true;
        return true;
    }
    return false;
}

fn menuBarHit(x: i32, y: i32) MenuId {
    if (y < 0 or y >= MENU_BAR_H) return .none;
    if (x >= 26 and x < 74) return .finder;
    if (x >= 78 and x < 116) return .file;
    if (x >= 118 and x < 156) return .edit;
    if (x >= 158 and x < 196) return .view;
    return .none;
}

fn menuPanelX(menu: MenuId) i32 {
    return switch (menu) {
        .finder => 24,
        .file => 76,
        .edit => 116,
        .view => 156,
        .none => 0,
    };
}

fn menuPanelWidth(menu: MenuId) i32 {
    return switch (menu) {
        .finder => 76,
        .file => 70,
        .edit => 76,
        .view => 72,
        .none => 0,
    };
}

fn menuItemCount(menu: MenuId) i32 {
    return switch (menu) {
        .finder => 3,
        else => 2,
    };
}

fn menuItemLabel(menu: MenuId, item: i32) []const u8 {
    return switch (menu) {
        .finder => switch (item) {
            0 => "Open",
            1 => "Mini",
            2 => "Reset",
            else => "",
        },
        .file => switch (item) {
            0 => "Open",
            1 => "Reset",
            else => "",
        },
        .edit => switch (item) {
            0 => "Select",
            1 => "Clear",
            else => "",
        },
        .view => switch (item) {
            0 => "Close",
            1 => "Open",
            else => "",
        },
        .none => "",
    };
}

fn menuItemAt(menu: MenuId, x: i32, y: i32) i32 {
    if (menu == .none) return -1;
    const panel_x = menuPanelX(menu);
    const panel_y: i32 = 22;
    const panel_w = menuPanelWidth(menu);
    const panel_h = 8 + menuItemCount(menu) * 14;
    if (x < panel_x or x >= panel_x + panel_w or y < panel_y or y >= panel_y + panel_h) return -1;
    const rel = y - (panel_y + 4);
    if (rel < 0) return -1;
    const idx = @divFloor(rel, 14);
    if (idx < 0 or idx >= menuItemCount(menu)) return -1;
    return idx;
}

fn applyMenuAction(menu: MenuId, item: i32) void {
    switch (menu) {
        .finder => switch (item) {
            0 => {
                if (window_minimized and genie_mode == .none) startGenie(.restoring);
            },
            1 => {
                if (!window_minimized and genie_mode == .none) startGenie(.minimizing);
            },
            2 => {
                resetDesktop();
                return;
            },
            else => {},
        },
        .file => switch (item) {
            0 => {
                if (window_minimized and genie_mode == .none) startGenie(.restoring);
            },
            1 => {
                resetDesktop();
                return;
            },
            else => {},
        },
        .edit => switch (item) {
            0 => {
                selected_icon = 3;
                selected_mask = 1 << 3;
            },
            1 => {
                selected_icon = -1;
                selected_mask = 0;
            },
            else => {},
        },
        .view => switch (item) {
            0 => {
                if (!window_minimized and genie_mode == .none) startGenie(.minimizing);
            },
            1 => {
                if (window_minimized and genie_mode == .none) startGenie(.restoring);
            },
            else => {},
        },
        .none => {},
    }
    mode = .idle;
    needs_redraw = true;
}

fn desktopSurfaceAt(x: i32, y: i32) bool {
    if (y < 22 or y >= 170) return false;
    if (!window_minimized and x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + window_h) return false;
    return true;
}

fn openDesktopMenu(x: i32, y: i32) void {
    desktop_menu_open = true;
    desktop_menu_x = clampI32(x, 2, @as(i32, @intCast(RENDER_W)) - 104);
    desktop_menu_y = clampI32(y, 24, @as(i32, @intCast(RENDER_H)) - 58);
}

fn desktopMenuAt(x: i32, y: i32) bool {
    return x >= desktop_menu_x and x < desktop_menu_x + 102 and y >= desktop_menu_y and y < desktop_menu_y + 52;
}

fn desktopMenuItemAt(x: i32, y: i32) i32 {
    if (!desktopMenuAt(x, y)) return -1;
    const rel = y - (desktop_menu_y + 5);
    if (rel < 0) return -1;
    const idx = @divFloor(rel, 14);
    if (idx < 0 or idx >= 3) return -1;
    return idx;
}

fn handleDesktopMenuAction(item: i32) void {
    switch (item) {
        0 => resetDesktop(),
        1 => {
            if (!window_minimized and genie_mode == .none) startGenie(.minimizing);
        },
        2 => {
            selected_icon = -1;
            selected_mask = 0;
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

fn startGenie(genie: GenieMode) void {
    genie_mode = genie;
    genie_frame = 0;
    genie_total_frames = if (shift_down) GENIE_SHIFT_FRAMES else GENIE_FRAMES;
    if (genie == .minimizing) window_minimized = true;
    needs_redraw = true;
}

fn titlebarAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + WINDOW_TITLEBAR_H;
}

fn minimizeButtonAt(x: i32, y: i32) bool {
    return x >= window_x + 20 and x < window_x + 27 and y >= window_y + 5 and y < window_y + 12;
}

fn zoomButtonAt(x: i32, y: i32) bool {
    return circleHit(x, y, window_x + 35, window_y + 8, 5);
}

fn toggleTigerZoom() void {
    if (window_zoomed) {
        window_x = window_restore_x;
        window_y = window_restore_y;
        window_w = window_restore_w;
        window_h = window_restore_h;
        window_zoomed = false;
    } else {
        window_restore_x = window_x;
        window_restore_y = window_y;
        window_restore_w = window_w;
        window_restore_h = window_h;
        window_x = 8;
        window_y = MENU_BAR_H + 4;
        window_w = @min(WINDOW_MAX_W, @as(i32, @intCast(RENDER_W)) - 16);
        window_h = @max(WINDOW_MIN_H, @min(WINDOW_MAX_H, DOCK_PANEL_Y - window_y));
        window_zoomed = true;
    }
    setTigerScrollX(scroll_x);
    setTigerScrollY(scroll_y);
}

fn hoveredTrafficLight() TrafficLight {
    if (window_minimized or genie_mode != .none) return .none;
    if (pointer_y < window_y + 2 or pointer_y > window_y + 14) return .none;
    if (circleHit(pointer_x, pointer_y, window_x + 11, window_y + 8, 5)) return .close;
    if (circleHit(pointer_x, pointer_y, window_x + 23, window_y + 8, 5)) return .minimize;
    if (circleHit(pointer_x, pointer_y, window_x + 35, window_y + 8, 5)) return .zoom;
    return .none;
}

fn circleHit(px: i32, py: i32, cx: i32, cy: i32, r: i32) bool {
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

fn resizeHandleAt(x: i32, y: i32) bool {
    return x >= window_x + window_w - 14 and x < window_x + window_w and y >= window_y + window_h - 14 and y < window_y + window_h;
}

fn windowFrameAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + window_h;
}

fn tigerClientLocalRect() Rect {
    return .{ .x = 3, .y = 17, .w = window_w - 6, .h = window_h - 20 };
}

fn tigerViewportLocalRect() Rect {
    const c = tigerClientLocalRect();
    return .{ .x = c.x + 1, .y = c.y + 1, .w = c.w - 15, .h = c.h - 15 };
}

fn tigerMaxScrollX() i32 {
    const vp = tigerViewportLocalRect();
    return @max(0, SCROLL_CONTENT_W - vp.w);
}

fn tigerMaxScrollY() i32 {
    const vp = tigerViewportLocalRect();
    return @max(0, SCROLL_CONTENT_H - vp.h);
}

fn setTigerScrollX(v: i32) void {
    scroll_x = clampI32(v, 0, tigerMaxScrollX());
}

fn setTigerScrollY(v: i32) void {
    scroll_y = clampI32(v, 0, tigerMaxScrollY());
}

fn tigerVScrollLocalRect() Rect {
    const c = tigerClientLocalRect();
    return .{ .x = c.x + c.w - 14, .y = c.y, .w = 14, .h = c.h - 14 };
}

fn tigerHScrollLocalRect() Rect {
    const c = tigerClientLocalRect();
    return .{ .x = c.x, .y = c.y + c.h - 14, .w = c.w - 14, .h = 14 };
}

fn tigerVThumbLocalRect() Rect {
    const track = tigerVScrollLocalRect();
    const vp = tigerViewportLocalRect();
    const track_span = @max(1, track.h - 28);
    const thumb_h: i32 = if (tigerMaxScrollY() == 0) track_span else clampI32(@divTrunc(track_span * vp.h, SCROLL_CONTENT_H), 12, track_span);
    const top = track.y + 14;
    const span = @max(1, track_span - thumb_h);
    const max_scroll = @max(1, tigerMaxScrollY());
    const t = @divTrunc(scroll_y * span, max_scroll);
    return .{ .x = track.x + 2, .y = top + t, .w = track.w - 4, .h = thumb_h };
}

fn tigerHThumbLocalRect() Rect {
    const track = tigerHScrollLocalRect();
    const vp = tigerViewportLocalRect();
    const track_span = @max(1, track.w - 28);
    const thumb_w: i32 = if (tigerMaxScrollX() == 0) track_span else clampI32(@divTrunc(track_span * vp.w, SCROLL_CONTENT_W), 12, track_span);
    const left = track.x + 14;
    const span = @max(1, track_span - thumb_w);
    const max_scroll = @max(1, tigerMaxScrollX());
    const t = @divTrunc(scroll_x * span, max_scroll);
    return .{ .x = left + t, .y = track.y + 2, .w = thumb_w, .h = track.h - 4 };
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn dragTigerVScrollTo(local_thumb_y: i32) void {
    const track = tigerVScrollLocalRect();
    const thumb = tigerVThumbLocalRect();
    const min_y = track.y + 14;
    const max_y = track.y + track.h - 14 - thumb.h;
    const clamped = clampI32(local_thumb_y, min_y, max_y);
    const span = @max(1, max_y - min_y);
    setTigerScrollY(@divTrunc((clamped - min_y) * tigerMaxScrollY(), span));
}

fn dragTigerHScrollTo(local_thumb_x: i32) void {
    const track = tigerHScrollLocalRect();
    const thumb = tigerHThumbLocalRect();
    const min_x = track.x + 14;
    const max_x = track.x + track.w - 14 - thumb.w;
    const clamped = clampI32(local_thumb_x, min_x, max_x);
    const span = @max(1, max_x - min_x);
    setTigerScrollX(@divTrunc((clamped - min_x) * tigerMaxScrollX(), span));
}

fn handleTigerScrollbarPress(screen_x: i32, screen_y: i32) bool {
    const lx = screen_x - window_x;
    const ly = screen_y - window_y;
    const vbar = tigerVScrollLocalRect();
    const hbar = tigerHScrollLocalRect();
    const vthumb = tigerVThumbLocalRect();
    const hthumb = tigerHThumbLocalRect();

    if (pointInRect(lx, ly, vthumb)) {
        mode = .{ .dragging_scroll = .vertical };
        scroll_drag_delta = ly - vthumb.y;
        return true;
    }
    if (pointInRect(lx, ly, hthumb)) {
        mode = .{ .dragging_scroll = .horizontal };
        scroll_drag_delta = lx - hthumb.x;
        return true;
    }
    if (pointInRect(lx, ly, vbar)) {
        if (ly < vbar.y + 14) setTigerScrollY(scroll_y - 12) else if (ly >= vbar.y + vbar.h - 14) setTigerScrollY(scroll_y + 12) else if (ly < vthumb.y) setTigerScrollY(scroll_y - 40) else if (ly >= vthumb.y + vthumb.h) setTigerScrollY(scroll_y + 40);
        return true;
    }
    if (pointInRect(lx, ly, hbar)) {
        if (lx < hbar.x + 14) setTigerScrollX(scroll_x - 12) else if (lx >= hbar.x + hbar.w - 14) setTigerScrollX(scroll_x + 12) else if (lx < hthumb.x) setTigerScrollX(scroll_x - 40) else if (lx >= hthumb.x + hthumb.w) setTigerScrollX(scroll_x + 40);
        return true;
    }
    return false;
}

fn minimizedWindowAt(x: i32, y: i32) bool {
    if (!window_minimized) return false;
    const r = minimizedWindowRect();
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn minimizedWindowRect() Rect {
    const center = dockSlotCenter(DOCK_MINIMIZED_SLOT);
    const size = dockSizeFor(center);
    return .{
        .x = center - @divFloor(size + 3, 2),
        .y = 204 - size,
        .w = size + 3,
        .h = size,
    };
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

fn drawFrame() void {
    drawWallpaper();
    var i: usize = 0;
    while (i < icons.len) : (i += 1) drawDesktopIcon(i);
    renderWindowBuffer();
    if (genie_mode != .none) {
        drawGenie();
    } else if (!window_minimized) {
        drawWindowShadow(window_x, window_y, window_w, window_h);
        blitWindow(window_x, window_y);
    }
    if (mode == .marquee_select) drawMarqueeRect();
    drawDock();
    if (desktop_menu_open) drawDesktopMenu();
    drawMenuBar();
    if (menu_open != .none) drawMenuPanel(menu_open);
    switch (mode) {
        .dragging_icon => |idx| drawDesktopIconProxy(idx, drag_icon_proxy_x, drag_icon_proxy_y),
        else => {},
    }
}

fn drawWallpaper() void {
    var y: usize = 0;
    while (y < RENDER_H) : (y += 1) {
        const t = @as(u16, @intCast((y * 255) / (RENDER_H - 1)));
        const r = lerp(C_SKY_TOP[0], C_SKY_BOTTOM[0], t);
        const g = lerp(C_SKY_TOP[1], C_SKY_BOTTOM[1], t);
        const b = lerp(C_SKY_TOP[2], C_SKY_BOTTOM[2], t);
        fillRect(0, y, RENDER_W, 1, .{ r, g, b, 0xFF });
    }

    drawSoftOval(36, 64, 100, 60, .{ 0x83, 0xB1, 0xE4, 0xFF });
    drawSoftOval(160, 94, 150, 82, .{ 0x2D, 0x5B, 0x96, 0xFF });
    drawSoftOval(52, 136, 130, 58, .{ 0x1B, 0x3F, 0x72, 0xFF });
}

fn drawSoftOval(cx: i32, cy: i32, rx: i32, ry: i32, c: Color) void {
    var y = cy - ry;
    while (y <= cy + ry) : (y += 1) {
        var x = cx - rx;
        while (x <= cx + rx) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry) {
                if (((x + y) & 3) == 0) setPixelI32(x, y, c);
            }
        }
    }
}

fn drawMenuBar() void {
    var y: i32 = 0;
    while (y < MENU_BAR_H) : (y += 1) {
        const t = @as(u16, @intCast(@divTrunc(y * 255, MENU_BAR_H - 1)));
        fillRectI32(0, y, 320, 1, .{ lerp(C_BAR_TOP[0], C_BAR_BOTTOM[0], t), lerp(C_BAR_TOP[1], C_BAR_BOTTOM[1], t), lerp(C_BAR_TOP[2], C_BAR_BOTTOM[2], t), 0xFF });
    }
    fillRectI32(0, MENU_BAR_H - 1, 320, 1, .{ 0x69, 0x72, 0x7E, 0xFF });
    drawApple(12, 7);
    drawMenuTitle(.finder, 28, 10, 46, "Finder");
    drawMenuTitle(.file, 80, 10, 36, "File");
    drawMenuTitle(.edit, 118, 10, 36, "Edit");
    drawMenuTitle(.view, 158, 10, 36, "View");
    drawText(246, 10, "Thu 4:11", C_DARK);
}

fn drawMenuTitle(menu: MenuId, x: i32, y: i32, w: i32, text: []const u8) void {
    const selected = menu_open == menu;
    if (selected) fillRectI32(x - 2, y - 2, w, 11, C_SELECT);
    drawText(x, y, text, if (selected) C_LIGHT else C_DARK);
}

fn drawMenuPanel(menu: MenuId) void {
    const panel_x = menuPanelX(menu);
    const panel_y: i32 = 22;
    const panel_w = menuPanelWidth(menu);
    const panel_h = 8 + menuItemCount(menu) * 14;
    fillRectI32(panel_x, panel_y, panel_w, panel_h, .{ 0xF4, 0xF6, 0xF9, 0xFF });
    drawRect(panel_x, panel_y, panel_w, panel_h, .{ 0x62, 0x6B, 0x75, 0xFF });
    var i: i32 = 0;
    while (i < menuItemCount(menu)) : (i += 1) {
        const item_y = panel_y + 4 + i * 14;
        fillRectI32(panel_x + 3, item_y, panel_w - 6, 12, .{ 0xE7, 0xEB, 0xF2, 0xFF });
        drawText(panel_x + 8, item_y + 3, menuItemLabel(menu, i), C_DARK);
    }
}

fn drawApple(x: i32, y: i32) void {
    fillRectI32(x + 3, y + 3, 7, 7, C_DARK);
    fillRectI32(x + 5, y, 3, 3, C_DARK);
    setPixelI32(x + 10, y + 4, C_BAR_TOP);
}

fn renderWindowBuffer() void {
    const hover = hoveredTrafficLight();
    const lights_hovered = hover != .none;
    clearWindowBuffer();
    fillWindowRect(0, 0, window_w, window_h, .{ 0xE7, 0xEC, 0xF2, 0xFF });
    drawWindowRect(0, 0, window_w, window_h, .{ 0x4B, 0x55, 0x63, 0xFF });
    var y: i32 = 1;
    while (y < 16) : (y += 1) {
        const t = @as(u16, @intCast(@divTrunc((y - 1) * 255, 14)));
        fillWindowRect(1, y, window_w - 2, 1, .{
            lerp(0xE7, 0xB8, t),
            lerp(0xEC, 0xC3, t),
            lerp(0xF3, 0xD2, t),
            0xFF,
        });
    }
    drawWindowLine(1, 2, window_w - 2, 2, .{ 0xF8, 0xFB, 0xFF, 0xFF });
    drawWindowLine(1, 15, window_w - 2, 15, .{ 0x8D, 0x98, 0xA7, 0xFF });
    drawWindowTrafficLight(11, 8, C_RED, .close, lights_hovered);
    drawWindowTrafficLight(23, 8, C_YELLOW, .minimize, lights_hovered);
    drawWindowTrafficLight(35, 8, C_GREEN, .zoom, lights_hovered);
    drawWindowText(54, 7, "Desktop", .{ 0x1A, 0x1E, 0x24, 0xFF });
    const c = tigerClientLocalRect();
    drawTigerContent();
    drawTigerScrollbars(c.x, c.y, c.w, c.h);
    drawWindowLine(window_w - 13, window_h - 5, window_w - 5, window_h - 13, C_DOCK_EDGE);
    drawWindowLine(window_w - 9, window_h - 5, window_w - 5, window_h - 9, C_DOCK_EDGE);
}

fn drawTigerContent() void {
    const vp = tigerViewportLocalRect();
    fillWindowRect(vp.x, vp.y, vp.w, vp.h, .{ 0xF7, 0xF9, 0xFC, 0xFF });
    var row: i32 = 0;
    while (row < 24) : (row += 1) {
        const y = vp.y + row * 12 - scroll_y;
        if (y >= vp.y - 6 and y < vp.y + vp.h) {
            var label_buf: [32]u8 = undefined;
            const label = buildNumberedLabel(&label_buf, row + 1, "Tiger Item");
            drawWindowText(vp.x + 6 - scroll_x, y + 2, label, C_DARK);
        }
    }
}

fn drawWindowTrafficLight(cx: i32, cy: i32, c: Color, kind: TrafficLight, hovered_group: bool) void {
    const ring: Color = .{ 0x3A, 0x40, 0x47, 0xFF };
    const inner = if (hovered_group) lighten(c, 26) else c;
    drawWindowCircle(cx, cy, 5, ring);
    drawWindowCircle(cx, cy, 4, inner);
    drawWindowCircle(cx - 1, cy - 2, 1, .{ 0xFF, 0xFF, 0xFF, 0x9A });
    if (hovered_group) drawTrafficLightGlyph(cx, cy, kind);
}

fn drawTrafficLightGlyph(cx: i32, cy: i32, kind: TrafficLight) void {
    const glyph_c: Color = .{ 0x30, 0x35, 0x3C, 0xFF };
    switch (kind) {
        .close => {
            drawWindowLine(cx - 2, cy - 2, cx + 2, cy + 2, glyph_c);
            drawWindowLine(cx + 2, cy - 2, cx - 2, cy + 2, glyph_c);
        },
        .minimize => {
            drawWindowLine(cx - 2, cy + 1, cx + 2, cy + 1, glyph_c);
        },
        .zoom => {
            drawWindowLine(cx - 2, cy, cx + 2, cy, glyph_c);
            drawWindowLine(cx, cy - 2, cx, cy + 2, glyph_c);
        },
        .none => {},
    }
}

fn drawTigerScrollbars(cx: i32, cy: i32, cw: i32, ch: i32) void {
    const sb: i32 = 14;
    if (cw < sb + 10 or ch < sb + 10) return;
    const track_c: Color = .{ 0xD9, 0xE4, 0xF2, 0xFF };
    const edge_c: Color = .{ 0x8A, 0xA2, 0xBC, 0xFF };
    const btn_c: Color = .{ 0xEB, 0xF2, 0xFA, 0xFF };
    const thumb_c: Color = .{ 0x79, 0xA5, 0xD6, 0xFF };

    const vbar = tigerVScrollLocalRect();
    const vbar_x = vbar.x;
    const vbar_h = vbar.h;
    fillWindowRect(vbar_x, cy, sb, vbar_h, track_c);
    drawWindowRect(vbar_x, cy, sb, vbar_h, edge_c);
    const up_btn = Rect{ .x = vbar_x, .y = cy, .w = sb, .h = sb };
    const down_btn = Rect{ .x = vbar_x, .y = cy + vbar_h - sb, .w = sb, .h = sb };
    fillWindowRect(up_btn.x + 1, up_btn.y + 1, up_btn.w - 2, up_btn.h - 2, btn_c);
    drawWindowRect(up_btn.x, up_btn.y, up_btn.w, up_btn.h, edge_c);
    fillWindowRect(down_btn.x + 1, down_btn.y + 1, down_btn.w - 2, down_btn.h - 2, btn_c);
    drawWindowRect(down_btn.x, down_btn.y, down_btn.w, down_btn.h, edge_c);
    drawTigerScrollArrow(up_btn, .up);
    drawTigerScrollArrow(down_btn, .down);
    const vthumb = tigerVThumbLocalRect();
    drawWindowPillThumb(vthumb.x, vthumb.y, vthumb.w, vthumb.h, thumb_c, .{ 0x5E, 0x85, 0xAE, 0xFF }, vbar.x, vbar.y);

    const hbar = tigerHScrollLocalRect();
    const hbar_y = hbar.y;
    const hbar_w = hbar.w;
    fillWindowRect(cx, hbar_y, hbar_w, sb, track_c);
    drawWindowRect(cx, hbar_y, hbar_w, sb, edge_c);
    const left_btn = Rect{ .x = cx, .y = hbar_y, .w = sb, .h = sb };
    const right_btn = Rect{ .x = cx + hbar_w - sb, .y = hbar_y, .w = sb, .h = sb };
    fillWindowRect(left_btn.x + 1, left_btn.y + 1, left_btn.w - 2, left_btn.h - 2, btn_c);
    drawWindowRect(left_btn.x, left_btn.y, left_btn.w, left_btn.h, edge_c);
    fillWindowRect(right_btn.x + 1, right_btn.y + 1, right_btn.w - 2, right_btn.h - 2, btn_c);
    drawWindowRect(right_btn.x, right_btn.y, right_btn.w, right_btn.h, edge_c);
    drawTigerScrollArrow(left_btn, .left);
    drawTigerScrollArrow(right_btn, .right);
    const hthumb = tigerHThumbLocalRect();
    drawWindowPillThumb(hthumb.x, hthumb.y, hthumb.w, hthumb.h, thumb_c, .{ 0x5E, 0x85, 0xAE, 0xFF }, hbar.x, hbar.y);

    fillWindowRect(vbar_x, hbar_y, sb, sb, .{ 0xC8, 0xD8, 0xEA, 0xFF });
    drawWindowRect(vbar_x, hbar_y, sb, sb, edge_c);
}

fn drawTigerScrollArrow(r: Rect, dir: ScrollArrowDir) void {
    const cx = r.x + @divFloor(r.w, 2);
    const cy = r.y + @divFloor(r.h, 2);
    const c: Color = .{ 0x4E, 0x67, 0x84, 0xFF };
    var d: i32 = 0;
    while (d < 3) : (d += 1) {
        switch (dir) {
            .up => fillWindowRect(cx - d, cy - 1 + d, d * 2 + 1, 1, c),
            .down => fillWindowRect(cx - d, cy + 1 - d, d * 2 + 1, 1, c),
            .left => fillWindowRect(cx - 1 + d, cy - d, 1, d * 2 + 1, c),
            .right => fillWindowRect(cx + 1 - d, cy - d, 1, d * 2 + 1, c),
        }
    }
}

fn drawWindowPillThumb(x: i32, y: i32, w: i32, h: i32, fill_c: Color, border_c: Color, pattern_anchor_x: i32, pattern_anchor_y: i32) void {
    if (w <= 0 or h <= 0) return;
    drawWindowRoundedRectFill(x, y, w, h, @divFloor(@min(w, h), 2), fill_c);
    drawWindowBarberPole(x + 1, y + 1, w - 2, h - 2, pattern_anchor_x, pattern_anchor_y);
    drawWindowRoundedRectStroke(x, y, w, h, @divFloor(@min(w, h), 2), border_c);
}

fn drawWindowBarberPole(x: i32, y: i32, w: i32, h: i32, anchor_x: i32, anchor_y: i32) void {
    if (w <= 0 or h <= 0) return;
    const r = @max(1, @divFloor(@min(w, h), 2));
    var py = y;
    while (py < y + h) : (py += 1) {
        var px = x;
        while (px < x + w) : (px += 1) {
            if (!roundedRectContains(px, py, x, y, w, h, r)) continue;
            const phase = (px - anchor_x) + (py - anchor_y);
            if ((phase & 3) == 0) {
                setWindowPixel(px, py, .{ 0xA9, 0xCB, 0xEE, 0xFF });
            } else if ((phase & 3) == 2) {
                setWindowPixel(px, py, .{ 0x6B, 0x96, 0xC4, 0xFF });
            }
        }
    }
}

fn drawWindowRoundedRectFill(x: i32, y: i32, w: i32, h: i32, radius: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const r = clampI32(radius, 0, @divFloor(@min(w, h), 2));
    var py = y;
    while (py < y + h) : (py += 1) {
        var px = x;
        while (px < x + w) : (px += 1) {
            if (roundedRectContains(px, py, x, y, w, h, r)) setWindowPixel(px, py, c);
        }
    }
}

fn drawWindowRoundedRectStroke(x: i32, y: i32, w: i32, h: i32, radius: i32, c: Color) void {
    if (w <= 1 or h <= 1) return;
    const r = clampI32(radius, 0, @divFloor(@min(w, h), 2));
    var py = y;
    while (py < y + h) : (py += 1) {
        var px = x;
        while (px < x + w) : (px += 1) {
            if (!roundedRectContains(px, py, x, y, w, h, r)) continue;
            if (!roundedRectContains(px - 1, py, x, y, w, h, r) or
                !roundedRectContains(px + 1, py, x, y, w, h, r) or
                !roundedRectContains(px, py - 1, x, y, w, h, r) or
                !roundedRectContains(px, py + 1, x, y, w, h, r))
            {
                setWindowPixel(px, py, c);
            }
        }
    }
}

fn roundedRectContains(px: i32, py: i32, x: i32, y: i32, w: i32, h: i32, radius: i32) bool {
    if (w <= 0 or h <= 0) return false;
    if (radius <= 0) return px >= x and px < x + w and py >= y and py < y + h;
    if (px < x or px >= x + w or py < y or py >= y + h) return false;

    const inner_left = x + radius;
    const inner_right = x + w - radius - 1;
    const inner_top = y + radius;
    const inner_bottom = y + h - radius - 1;
    const nx = clampI32(px, inner_left, inner_right);
    const ny = clampI32(py, inner_top, inner_bottom);
    const dx = px - nx;
    const dy = py - ny;
    return dx * dx + dy * dy <= radius * radius;
}

fn drawWindowCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) setWindowPixel(x, y, c);
        }
    }
}

fn blitWindow(dst_x: i32, dst_y: i32) void {
    var y: i32 = 0;
    while (y < window_h) : (y += 1) {
        var x: i32 = 0;
        while (x < window_w) : (x += 1) {
            const c = windowPixel(x, y);
            blendPixelI32(dst_x + x, dst_y + y, c);
        }
    }
}

fn drawGenie() void {
    var frame = genie_frame;
    if (genie_mode == .restoring) frame = genie_total_frames - genie_frame;
    const target = minimizedWindowRect();
    var src_y: i32 = 0;
    while (src_y < window_h) : (src_y += 1) {
        const row_t = @divTrunc(src_y * genie_total_frames, window_h - 1);
        const eased = clampI32(@divTrunc(frame * (genie_total_frames + row_t), genie_total_frames), 0, genie_total_frames);
        const curve = @divTrunc(src_y * (window_h - 1 - src_y) * 16, (window_h - 1) * (window_h - 1));
        const row_w = @max(2, lerpI32(window_w, target.w, eased, genie_total_frames) - curve);
        const row_x = lerpI32(window_x, target.x, eased, genie_total_frames) + @divTrunc(curve, 2);
        const row_y = lerpI32(window_y + src_y, target.y + @divTrunc(src_y * target.h, window_h), eased, genie_total_frames);
        blitGenieShadowRow(row_x, row_y, row_w);
        blitWindowRowScaled(src_y, row_x, row_y, row_w);
    }
    drawRect(
        lerpI32(window_x, target.x, frame, genie_total_frames),
        lerpI32(window_y, target.y, frame, genie_total_frames),
        @max(3, lerpI32(window_w, target.w, frame, genie_total_frames)),
        @max(3, lerpI32(window_h, target.h, frame, genie_total_frames)),
        C_DARK,
    );
}

fn drawWindowShadow(x: i32, y: i32, _: i32, _: i32) void {
    const shadow_w = window_w + SHADOW_PAD * 2;
    const shadow_h = window_h + SHADOW_PAD * 2;
    var tile_y: i32 = 0;
    while (tile_y < shadow_h) : (tile_y += SHADOW_TILE_CORE) {
        const core_h = @min(SHADOW_TILE_CORE, shadow_h - tile_y);
        var tile_x: i32 = 0;
        while (tile_x < shadow_w) : (tile_x += SHADOW_TILE_CORE) {
            const core_w = @min(SHADOW_TILE_CORE, shadow_w - tile_x);
            buildShadowTile(tile_x, tile_y, core_w, core_h);
            var cy: i32 = 0;
            while (cy < core_h) : (cy += 1) {
                var cx: i32 = 0;
                while (cx < core_w) : (cx += 1) {
                    const alpha_16 = shadow_tmp_b[shadowTileIndex(cx + SHADOW_RADIUS, cy + SHADOW_RADIUS)];
                    const a = @as(u8, @intCast(@min(120, @divTrunc(alpha_16 * 118, 255))));
                    if (a != 0) {
                        blendPixelI32(
                            x + tile_x + cx - SHADOW_PAD + SHADOW_OFFSET_X,
                            y + tile_y + cy - SHADOW_PAD + SHADOW_OFFSET_Y,
                            .{ 0x0A, 0x0D, 0x14, a },
                        );
                    }
                }
            }
        }
    }
}

fn buildShadowTile(tile_x: i32, tile_y: i32, core_w: i32, core_h: i32) void {
    const ext_w = core_w + SHADOW_RADIUS * 2;
    const ext_h = core_h + SHADOW_RADIUS * 2;
    const src_x0 = tile_x - SHADOW_RADIUS;
    const src_y0 = tile_y - SHADOW_RADIUS;

    var y: i32 = 0;
    while (y < ext_h) : (y += 1) {
        var x: i32 = 0;
        while (x < ext_w) : (x += 1) {
            shadow_src_tile[shadowTileIndex(x, y)] = windowShadowSourceAlpha(src_x0 + x, src_y0 + y);
        }
    }
    blurShadowHorizontalTile(ext_w, ext_h, &shadow_src_tile, &shadow_tmp_a);
    blurShadowVerticalTile(ext_w, ext_h, &shadow_tmp_a, &shadow_tmp_b);
    blurShadowHorizontalTile(ext_w, ext_h, &shadow_tmp_b, &shadow_tmp_a);
    blurShadowVerticalTile(ext_w, ext_h, &shadow_tmp_a, &shadow_tmp_b);
}

fn blurShadowHorizontalTile(ext_w: i32, ext_h: i32, src: *[SHADOW_TILE_PIXELS]u16, dst: *[SHADOW_TILE_PIXELS]u16) void {
    var y: i32 = 0;
    while (y < ext_h) : (y += 1) {
        var x: i32 = 0;
        while (x < ext_w) : (x += 1) {
            dst[shadowTileIndex(x, y)] = weightedShadowSampleTile(src, ext_w, ext_h, x - SHADOW_KERNEL_R, y, x - 1, y, x, y, x + 1, y, x + SHADOW_KERNEL_R, y);
        }
    }
}

fn blurShadowVerticalTile(ext_w: i32, ext_h: i32, src: *[SHADOW_TILE_PIXELS]u16, dst: *[SHADOW_TILE_PIXELS]u16) void {
    var y: i32 = 0;
    while (y < ext_h) : (y += 1) {
        var x: i32 = 0;
        while (x < ext_w) : (x += 1) {
            dst[shadowTileIndex(x, y)] = weightedShadowSampleTile(src, ext_w, ext_h, x, y - SHADOW_KERNEL_R, x, y - 1, x, y, x, y + 1, x, y + SHADOW_KERNEL_R);
        }
    }
}

fn weightedShadowSampleTile(src: *[SHADOW_TILE_PIXELS]u16, ext_w: i32, ext_h: i32, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, x3: i32, y3: i32, x4: i32, y4: i32) u16 {
    const sum =
        shadowSampleTile(src, ext_w, ext_h, x0, y0) +
        shadowSampleTile(src, ext_w, ext_h, x1, y1) * 4 +
        shadowSampleTile(src, ext_w, ext_h, x2, y2) * 6 +
        shadowSampleTile(src, ext_w, ext_h, x3, y3) * 4 +
        shadowSampleTile(src, ext_w, ext_h, x4, y4);
    return @divTrunc(sum + 8, 16);
}

fn shadowSampleTile(src: *[SHADOW_TILE_PIXELS]u16, ext_w: i32, ext_h: i32, x: i32, y: i32) u16 {
    const sx = clampI32(x, 0, ext_w - 1);
    const sy = clampI32(y, 0, ext_h - 1);
    return src[shadowTileIndex(sx, sy)];
}

fn shadowTileIndex(x: i32, y: i32) usize {
    return @as(usize, @intCast(y)) * @as(usize, @intCast(SHADOW_TILE_EXT)) + @as(usize, @intCast(x));
}

fn windowShadowSourceAlpha(shadow_x: i32, shadow_y: i32) u16 {
    const wx = shadow_x - SHADOW_PAD;
    const wy = shadow_y - SHADOW_PAD;
    if (wx < 0 or wy < 0 or wx >= window_w or wy >= window_h) return 0;
    return @as(u16, windowPixel(wx, wy)[3]);
}

fn blitGenieShadowRow(dst_x: i32, dst_y: i32, dst_w: i32) void {
    if ((dst_y & 1) == 0) blendRectI32(dst_x + 6, dst_y + 9, dst_w, 1, .{ 0x16, 0x1A, 0x22, 0x32 });
    if ((dst_y & 3) == 0) blendRectI32(dst_x + 3, dst_y + 5, dst_w, 1, .{ 0x32, 0x38, 0x46, 0x28 });
}

fn blitWindowRowScaled(src_y: i32, dst_x: i32, dst_y: i32, dst_w: i32) void {
    if (dst_w <= 0) return;
    var dx: i32 = 0;
    while (dx < dst_w) : (dx += 1) {
        const src_x = clampI32(@divTrunc(dx * window_w, dst_w), 0, window_w - 1);
        const c = windowPixel(src_x, src_y);
        blendPixelI32(dst_x + dx, dst_y, c);
    }
}

fn drawDesktopIcon(i: usize) void {
    const icon = icons[i];
    const selected = ((selected_mask & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) or selected_icon == @as(i32, @intCast(i));
    drawDesktopIconAt(icon.kind, icon.label, icon.x, icon.y, selected);
}

fn drawDesktopIconAt(kind: IconKind, label: []const u8, x: i32, y: i32, selected: bool) void {
    drawIconGlyph(kind, x + 7, y, 24);
    const label_w = textWidth(label);
    const label_x = x + @divFloor(ICON_W - label_w, 2);
    if (selected) fillRectI32(label_x - 2, y + ICON_H + 2, label_w + 4, 9, C_SELECT);
    drawText(label_x, y + ICON_H + 4, label, C_TEXT);
}

fn drawDesktopIconProxy(i: usize, x: i32, y: i32) void {
    const icon = icons[i];
    drawDesktopIconAt(icon.kind, icon.label, x, y, true);
    blendRectI32(x, y, ICON_W, ICON_H + 13, .{ 0xD8, 0xE8, 0xFB, 0x96 });
    drawRect(x, y, ICON_W, ICON_H + 13, .{ 0xAF, 0xC7, 0xE7, 0xB8 });
}

fn drawMarqueeRect() void {
    const x = @min(marquee_x0, marquee_x1);
    const y = @min(marquee_y0, marquee_y1);
    const w = @max(1, @max(marquee_x0, marquee_x1) - x + 1);
    const h = @max(1, @max(marquee_y0, marquee_y1) - y + 1);
    drawRect(x, y, w, h, C_LIGHT);
    blendRectI32(x + 1, y + 1, @max(0, w - 2), @max(0, h - 2), .{ 0xA6, 0xCC, 0xFF, 0x24 });
}

fn drawDesktopMenu() void {
    fillRectI32(desktop_menu_x, desktop_menu_y, 102, 52, .{ 0xF4, 0xF6, 0xF9, 0xFF });
    drawRect(desktop_menu_x, desktop_menu_y, 102, 52, .{ 0x62, 0x6B, 0x75, 0xFF });
    drawDesktopMenuItem(0, "Clean Up");
    drawDesktopMenuItem(1, "Hide Win");
    drawDesktopMenuItem(2, "Clear");
}

fn drawDesktopMenuItem(item: i32, label: []const u8) void {
    const y = desktop_menu_y + 5 + item * 14;
    fillRectI32(desktop_menu_x + 4, y, 94, 12, .{ 0xE7, 0xEB, 0xF2, 0xFF });
    drawRect(desktop_menu_x + 4, y, 94, 12, .{ 0x62, 0x6B, 0x75, 0xFF });
    drawText(desktop_menu_x + 10, y + 3, label, C_DARK);
}

fn drawDock() void {
    const dock_y: i32 = DOCK_Y;
    const panel = dockPanelRect();
    const dock_x = panel.x;
    const dock_w = panel.w;
    const panel_y = dock_y + 4;
    blendRectI32(dock_x, panel_y, dock_w, 28, C_DOCK);
    blendRectI32(dock_x, panel_y, dock_w, 1, C_DOCK_EDGE);
    blendRectI32(dock_x, panel_y + 27, dock_w, 1, C_DOCK_EDGE);
    blendRectI32(dock_x, panel_y, 1, 28, C_DOCK_EDGE);
    blendRectI32(dock_x + dock_w - 1, panel_y, 1, 28, C_DOCK_EDGE);
    blendRectI32(dock_x + 2, dock_y + 6, dock_w - 4, 1, .{ 0xF3, 0xF8, 0xFF, 0x8A });
    blendRectI32(dock_x + 2, dock_y + 29, dock_w - 4, 1, .{ 0x4F, 0x65, 0x80, 0x72 });
    const split_x = dockSlotCenter(DOCK_N - 1) + 16;
    blendRectI32(split_x, dock_y + 7, 1, 24, .{ 0x5B, 0x73, 0x8F, 0x78 });
    blendRectI32(split_x + 1, dock_y + 7, 1, 24, .{ 0xE1, 0xEC, 0xFA, 0x66 });

    var i: usize = 0;
    while (i < DOCK_N) : (i += 1) {
        if (window_minimized and i == DOCK_MINIMIZED_SLOT) {
            drawDockMinimizedWindow(i, dock_y);
        }
        const slot = dockSlotForIcon(i);
        const center = dockSlotCenter(slot);
        const size = dockSizeFor(center);
        const top = dock_y + 26 - size;
        drawDockIcon(dock_icons[i], center - @divFloor(size, 2), top, size);
    }
}

fn dockPanelRect() Rect {
    const dock_x: i32 = if (window_minimized) 32 else 36;
    const dock_w: i32 = if (window_minimized) 256 else 248;
    return .{ .x = dock_x, .y = DOCK_PANEL_Y, .w = dock_w, .h = 28 };
}

fn dockSlotForIcon(i: usize) usize {
    return if (window_minimized and i >= DOCK_MINIMIZED_SLOT) i + 1 else i;
}

fn dockSlotCenter(slot: usize) i32 {
    const start: i32 = if (window_minimized) 57 else 68;
    return start + @as(i32, @intCast(slot)) * DOCK_SLOT_STEP;
}

fn dockSizeFor(center_x: i32) i32 {
    const radius: i32 = 58;
    if (!dock_hover_active or dockMagnificationBlocked()) return DOCK_BASE_SIZE;

    const d = absI32(pointer_x - center_x);
    if (d >= radius) return DOCK_BASE_SIZE;

    const vertical_top = DOCK_Y - 18;
    const vertical_bottom = DOCK_Y + 32;
    const vertical_span = vertical_bottom - vertical_top;
    const vertical = clampI32(pointer_y - vertical_top, 0, vertical_span);
    const vertical_scaled = @divTrunc(vertical * 1024, vertical_span);
    const proximity = radius - d;
    const horizontal_scaled = @divTrunc(proximity * proximity * 1024, radius * radius);
    const boost = @divTrunc(DOCK_MAX_BOOST * horizontal_scaled * vertical_scaled, 1024 * 1024);
    return DOCK_BASE_SIZE + boost;
}

fn dockMagnificationBlocked() bool {
    if (!primary_down) return false;
    return switch (mode) {
        .idle => false,
        else => true,
    };
}

fn updateDockHoverState() void {
    const was_active = dock_hover_active;
    const panel = dockPanelRect();
    if (pointInRect(pointer_x, pointer_y, panel)) {
        dock_hover_active = true;
    } else if (dock_hover_active) {
        dock_hover_active = pointerOverDockHoverTargets();
    } else {
        dock_hover_active = false;
    }
    if (dock_hover_active != was_active) needs_redraw = true;
}

fn pointerOverDockHoverTargets() bool {
    const panel = dockPanelRect();
    const hover_pad_x: i32 = 18;
    const hover_top: i32 = DOCK_Y - 24;
    const hover_bottom: i32 = DOCK_Y + 40;
    if (pointInRect(pointer_x, pointer_y, .{
        .x = panel.x - hover_pad_x,
        .y = hover_top,
        .w = panel.w + hover_pad_x * 2,
        .h = hover_bottom - hover_top,
    })) return true;

    const max_size: i32 = DOCK_BASE_SIZE + DOCK_MAX_BOOST;
    var i: usize = 0;
    while (i < DOCK_N) : (i += 1) {
        const slot = dockSlotForIcon(i);
        const center = dockSlotCenter(slot);
        const r = Rect{
            .x = center - @divFloor(max_size, 2) - 3,
            .y = DOCK_Y + 26 - max_size - 4,
            .w = max_size + 6,
            .h = max_size + 18,
        };
        if (pointInRect(pointer_x, pointer_y, r)) return true;
    }
    return false;
}

fn drawDockIcon(kind: DockKind, x: i32, y: i32, size: i32) void {
    switch (kind) {
        .finder => {
            fillRectI32(x, y, size, size, .{ 0x5A, 0xA5, 0xED, 0xFF });
            fillRectI32(x + @divFloor(size, 2), y, @divFloor(size, 2), size, .{ 0xD9, 0xED, 0xFF, 0xFF });
            drawRect(x, y, size, size, C_DARK);
            fillRectI32(x + @divFloor(size, 4), y + @divFloor(size, 3), 2, 2, C_DARK);
            fillRectI32(x + size - @divFloor(size, 3), y + @divFloor(size, 3), 2, 2, C_DARK);
            drawLine(x + @divFloor(size, 4), y + size - @divFloor(size, 4), x + size - @divFloor(size, 4), y + size - @divFloor(size, 4), C_DARK);
        },
        .safari => drawCircleIcon(x, y, size, .{ 0x4C, 0xA6, 0xF0, 0xFF }, C_RED),
        .mail => drawEnvelopeIcon(x, y, size),
        .calendar => {
            fillRectI32(x, y, size, size, C_DOC);
            drawRect(x, y, size, size, C_DARK);
            fillRectI32(x, y, size, @max(5, @divFloor(size, 4)), C_RED);
            drawText(x + @divFloor(size, 3), y + @divFloor(size, 2), "28", C_DARK);
        },
        .photos => drawCircleIcon(x, y, size, C_YELLOW, C_PURPLE),
        .terminal => {
            fillRectI32(x, y, size, size, .{ 0x18, 0x1C, 0x20, 0xFF });
            drawRect(x, y, size, size, C_LIGHT);
            drawText(x + 5, y + @divFloor(size, 2), ">", C_GREEN);
        },
        .trash => {
            fillRectI32(x + @divFloor(size, 5), y + @divFloor(size, 4), size - @divFloor(size, 3), size - @divFloor(size, 4), .{ 0xD8, 0xE0, 0xEA, 0xFF });
            drawRect(x + @divFloor(size, 5), y + @divFloor(size, 4), size - @divFloor(size, 3), size - @divFloor(size, 4), C_DARK);
            drawLine(x + @divFloor(size, 4), y + @divFloor(size, 5), x + size - @divFloor(size, 5), y + @divFloor(size, 5), C_DARK);
        },
    }
}

fn drawDockMinimizedWindow(slot: usize, dock_y: i32) void {
    _ = slot;
    _ = dock_y;
    const r = minimizedWindowRect();
    fillRectI32(r.x, r.y, r.w, r.h, .{ 0xEC, 0xF0, 0xF5, 0xFF });
    drawRect(r.x, r.y, r.w, r.h, C_DARK);
    fillRectI32(r.x + 2, r.y + 2, r.w - 4, @max(5, @divFloor(r.h, 4)), .{ 0xC9, 0xD8, 0xEB, 0xFF });
    fillRectI32(r.x + 4, r.y + @divFloor(r.h, 2), r.w - 8, @max(4, @divFloor(r.h, 4)), C_LIGHT);
}

fn lighten(c: Color, amount: u8) Color {
    return .{
        satAdd(c[0], amount),
        satAdd(c[1], amount),
        satAdd(c[2], amount),
        c[3],
    };
}

fn satAdd(a: u8, b: u8) u8 {
    const s = @as(u16, a) + @as(u16, b);
    return if (s > 255) 255 else @as(u8, @intCast(s));
}

fn clearWindowBuffer() void {
    var i: usize = 0;
    while (i < WINDOW_BYTES) : (i += 4) {
        window_buf[i + 0] = 0;
        window_buf[i + 1] = 0;
        window_buf[i + 2] = 0;
        window_buf[i + 3] = 0;
    }
}

fn fillWindowRect(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = clampI32(x0, 0, window_w);
    const sy = clampI32(y0, 0, window_h);
    const ex = clampI32(x0 + w, 0, window_w);
    const ey = clampI32(y0 + h, 0, window_h);
    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) setWindowPixel(x, y, c);
    }
}

fn drawWindowRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillWindowRect(x, y, w, 1, c);
    fillWindowRect(x, y + h - 1, w, 1, c);
    fillWindowRect(x, y, 1, h, c);
    fillWindowRect(x + w - 1, y, 1, h, c);
}

fn drawWindowLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: Color) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setWindowPixel(x0, y0, c);
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

fn drawWindowText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawWindowChar(x + @as(i32, @intCast(i * 4)), y, text[i], c);
}

fn drawWindowChar(x: i32, y: i32, ch: u8, c: Color) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) != 0) {
                setWindowPixel(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), c);
            }
        }
    }
}

fn setWindowPixel(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= window_w or y >= window_h) return;
    const mask_alpha = windowMaskAlpha(x, y);
    if (mask_alpha == 0) return;
    const out_alpha = @as(u8, @intCast(@divTrunc(@as(u16, c[3]) * @as(u16, mask_alpha) + 127, 255)));
    if (out_alpha == 0) return;
    const idx = (@as(usize, @intCast(y)) * @as(usize, @intCast(WINDOW_MAX_W)) + @as(usize, @intCast(x))) * 4;
    window_buf[idx + 0] = c[0];
    window_buf[idx + 1] = c[1];
    window_buf[idx + 2] = c[2];
    window_buf[idx + 3] = out_alpha;
}

fn windowMaskAlpha(x: i32, y: i32) u8 {
    if (y >= WINDOW_CORNER_R) return 0xFF;
    const r = WINDOW_CORNER_R - 1;
    if (x < WINDOW_CORNER_R) {
        return circleCoverageAlpha(r, r, x, y, r);
    }
    if (x >= window_w - WINDOW_CORNER_R) {
        return circleCoverageAlpha(window_w - WINDOW_CORNER_R, r, x, y, r);
    }
    return 0xFF;
}

fn circleCoverageAlpha(cx: i32, cy: i32, px: i32, py: i32, r: i32) u8 {
    var covered: u8 = 0;
    const rr = r * r;
    const sample_off = [_]i32{ 1, 3, 5, 7 };
    var sy: usize = 0;
    while (sy < sample_off.len) : (sy += 1) {
        var sx: usize = 0;
        while (sx < sample_off.len) : (sx += 1) {
            const sample_x = px * 8 + sample_off[sx];
            const sample_y = py * 8 + sample_off[sy];
            const dx8 = cx * 8 + 4 - sample_x;
            const dy8 = cy * 8 + 4 - sample_y;
            if (dx8 * dx8 + dy8 * dy8 <= rr * 64) covered += 1;
        }
    }
    return @as(u8, @intCast(@divTrunc(@as(u16, covered) * 255 + 8, 16)));
}

fn windowPixel(x: i32, y: i32) Color {
    const sx = clampI32(x, 0, window_w - 1);
    const sy = clampI32(y, 0, window_h - 1);
    const idx = (@as(usize, @intCast(sy)) * @as(usize, @intCast(WINDOW_MAX_W)) + @as(usize, @intCast(sx))) * 4;
    return .{ window_buf[idx + 0], window_buf[idx + 1], window_buf[idx + 2], window_buf[idx + 3] };
}

fn drawIconGlyph(kind: IconKind, x: i32, y: i32, size: i32) void {
    switch (kind) {
        .drive => {
            fillRectI32(x, y + 8, size, 13, C_DRIVE);
            drawRect(x, y + 8, size, 13, C_DARK);
            fillRectI32(x + 4, y + 5, size - 8, 5, C_LIGHT);
            drawRect(x + 4, y + 5, size - 8, 5, C_DARK);
        },
        .folder => {
            fillRectI32(x, y + 8, size, 16, C_FOLDER);
            fillRectI32(x + 4, y + 5, 10, 4, C_FOLDER);
            drawRect(x, y + 8, size, 16, C_DARK);
        },
        .document => {
            fillRectI32(x + 4, y + 2, size - 8, 24, C_DOC);
            drawRect(x + 4, y + 2, size - 8, 24, C_DARK);
            drawLine(x + 8, y + 9, x + size - 8, y + 9, C_DOCK_EDGE);
            drawLine(x + 8, y + 14, x + size - 8, y + 14, C_DOCK_EDGE);
            drawLine(x + 8, y + 19, x + size - 12, y + 19, C_DOCK_EDGE);
        },
        .disk => drawCircleIcon(x, y + 2, size, .{ 0xE8, 0xE8, 0xEA, 0xFF }, .{ 0x75, 0x84, 0x93, 0xFF }),
        .app => drawCircleIcon(x, y + 2, size, C_PURPLE, C_YELLOW),
    }
}

fn drawCircleIcon(x: i32, y: i32, size: i32, bg: Color, fg: Color) void {
    const r = @divFloor(size, 2);
    const cx = x + r;
    const cy = y + r;
    var py = y;
    while (py < y + size) : (py += 1) {
        var px = x;
        while (px < x + size) : (px += 1) {
            const dx = px - cx;
            const dy = py - cy;
            if (dx * dx + dy * dy <= r * r) setPixelI32(px, py, bg);
        }
    }
    drawLine(x + @divFloor(size, 3), y + size - @divFloor(size, 3), x + size - @divFloor(size, 4), y + @divFloor(size, 4), fg);
    drawRect(x, y, size, size, C_DARK);
}

fn drawEnvelopeIcon(x: i32, y: i32, size: i32) void {
    fillRectI32(x, y + @divFloor(size, 6), size, size - @divFloor(size, 3), C_DOC);
    drawRect(x, y + @divFloor(size, 6), size, size - @divFloor(size, 3), C_DARK);
    drawLine(x, y + @divFloor(size, 6), x + @divFloor(size, 2), y + @divFloor(size, 2), C_DOCK_EDGE);
    drawLine(x + size - 1, y + @divFloor(size, 6), x + @divFloor(size, 2), y + @divFloor(size, 2), C_DOCK_EDGE);
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

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
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
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
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

fn blendRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) blendPixelI32(x, y, c);
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    setPixel(@as(usize, @intCast(x)), @as(usize, @intCast(y)), c);
}

fn blendPixelI32(x: i32, y: i32, src: Color) void {
    if (src[3] == 0) return;
    if (src[3] == 0xFF) {
        setPixelI32(x, y, src);
        return;
    }
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const a = @as(u16, src[3]);
    const inv = 255 - a;
    output_buf[idx + 0] = blendChannel(src[0], output_buf[idx + 0], a, inv);
    output_buf[idx + 1] = blendChannel(src[1], output_buf[idx + 1], a, inv);
    output_buf[idx + 2] = blendChannel(src[2], output_buf[idx + 2], a, inv);
    output_buf[idx + 3] = 0xFF;
}

fn blendChannel(src: u8, dst: u8, a: u16, inv: u16) u8 {
    return @as(u8, @intCast(@divTrunc(@as(u16, src) * a + @as(u16, dst) * inv + 127, 255)));
}

fn setPixel(x: usize, y: usize, c: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

fn lerp(a: u8, b: u8, t: u16) u8 {
    return @as(u8, @intCast((@as(u16, a) * (255 - t) + @as(u16, b) * t) / 255));
}

fn lerpI32(a: i32, b: i32, t: i32, total: i32) i32 {
    return a + @divTrunc((b - a) * t, total);
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

test "dock magnifies near pointer" {
    resetDesktop();
    _ = pointerEventForTest(0, 68, DOCK_PANEL_Y + 10, 0);
    try std.testing.expect(dock_hover_active);
    try std.testing.expect(dockSizeFor(68) > DOCK_BASE_SIZE);
    try std.testing.expect(dockSizeFor(84) > dockSizeFor(112));
    try std.testing.expect(dockSizeFor(132) == DOCK_BASE_SIZE);
    _ = pointerEventForTest(0, 68, 120, 0);
    try std.testing.expect(!dock_hover_active);
    try std.testing.expect(dockSizeFor(68) == DOCK_BASE_SIZE);
}

test "dock does not magnify while primary drag is active" {
    resetDesktop();
    dock_hover_active = true;
    pointer_x = 68;
    pointer_y = 190;
    primary_down = true;
    mode = .dragging_window;
    try std.testing.expect(dockSizeFor(68) == DOCK_BASE_SIZE);
}

test "dock magnification activates only after entering dock" {
    resetDesktop();
    pointer_x = 68;
    pointer_y = 190;
    try std.testing.expect(dockSizeFor(68) == DOCK_BASE_SIZE);
    _ = pointerEventForTest(0, 68, DOCK_PANEL_Y + 8, 0);
    try std.testing.expect(dock_hover_active);
    try std.testing.expect(dockSizeFor(68) > DOCK_BASE_SIZE);
}

test "window moves live while dragging titlebar" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 88, 49, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 130, 74, 0);
    try std.testing.expect(window_x != 80 or window_y != 42);
    try std.testing.expect(mode == .dragging_window);
    _ = pointerEventForTest(0, 130, 74, 0);
    try std.testing.expect(mode == .idle);
}

test "window can move offscreen but stays below menu bar" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 88, 49, 0);
    _ = pointerEventForTest(BTN_PRIMARY, -80, 20, 0);
    try std.testing.expect(window_x < 0);
    try std.testing.expect(window_y >= MENU_BAR_H);
    _ = pointerEventForTest(0, -80, 20, 0);
}

test "window titlebar cannot cross dock band while dragging" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 88, 49, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 120, 400, 0);
    try std.testing.expect(window_y <= DOCK_PANEL_Y - WINDOW_TITLEBAR_H);
    _ = pointerEventForTest(0, 120, 400, 0);
}

test "zoom traffic light toggles fit size and restore" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, window_x + 35, window_y + 8, 0);
    _ = pointerEventForTest(0, window_x + 35, window_y + 8, 0);
    try std.testing.expect(window_zoomed);
    try std.testing.expect(window_w >= WINDOW_W and window_h >= WINDOW_H);

    _ = pointerEventForTest(BTN_PRIMARY, window_x + 35, window_y + 8, 0);
    _ = pointerEventForTest(0, window_x + 35, window_y + 8, 0);
    try std.testing.expect(!window_zoomed);
    try std.testing.expect(window_x == 80 and window_y == 42 and window_w == WINDOW_W and window_h == WINDOW_H);
}

test "desktop icon drag uses transparent proxy and commits on release" {
    resetDesktop();
    const idx: usize = 0;
    const start_x = icons[idx].x;
    const start_y = icons[idx].y;

    _ = pointerEventForTest(BTN_PRIMARY, start_x + 4, start_y + 4, 0);
    _ = pointerEventForTest(BTN_PRIMARY, start_x - 42, start_y + 26, 0);
    try std.testing.expect(mode == .dragging_icon);
    try std.testing.expect(icons[idx].x == start_x and icons[idx].y == start_y);
    try std.testing.expect(drag_icon_proxy_x != start_x or drag_icon_proxy_y != start_y);

    _ = pointerEventForTest(0, start_x - 42, start_y + 26, 0);
    try std.testing.expect(mode == .idle);
    try std.testing.expect(icons[idx].x == drag_icon_proxy_x and icons[idx].y == drag_icon_proxy_y);
    try std.testing.expect(icons[idx].x != start_x or icons[idx].y != start_y);
}

test "window resizes live from lower right handle" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 211, 113, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 246, 140, 0);
    try std.testing.expect(window_w > WINDOW_W and window_h > WINDOW_H);
    try std.testing.expect(mode == .resizing_window);
    _ = pointerEventForTest(0, 246, 140, 0);
    try std.testing.expect(mode == .idle);
}

test "window resize can extend down to dock top" {
    resetDesktop();
    window_y = 104;
    window_h = WINDOW_MIN_H;
    const start_x = window_x + window_w - 1;
    const start_y = window_y + window_h - 1;
    _ = pointerEventForTest(BTN_PRIMARY, start_x, start_y, 0);
    _ = pointerEventForTest(BTN_PRIMARY, start_x, 500, 0);
    try std.testing.expect(window_y + window_h == DOCK_PANEL_Y);
    _ = pointerEventForTest(0, start_x, 500, 0);
}

test "window backing buffer has rounded top corners" {
    resetDesktop();
    renderWindowBuffer();
    try std.testing.expect(windowPixel(0, 0)[3] == 0);
    try std.testing.expect(windowPixel(window_w - 1, 0)[3] == 0);
    try std.testing.expect(windowPixel(@divTrunc(window_w, 2), 0)[3] != 0);
}

test "window corners are anti-aliased" {
    resetDesktop();
    renderWindowBuffer();
    var found_partial = false;
    var y: i32 = 0;
    while (y < WINDOW_CORNER_R and !found_partial) : (y += 1) {
        var x: i32 = 0;
        while (x < WINDOW_CORNER_R and !found_partial) : (x += 1) {
            const a = windowPixel(x, y)[3];
            if (a > 0 and a < 0xFF) found_partial = true;
        }
    }
    try std.testing.expect(found_partial);
}

test "traffic lights are round buttons" {
    resetDesktop();
    renderWindowBuffer();
    const center = windowPixel(11, 8);
    const outer = windowPixel(8, 5);
    try std.testing.expect(center[0] > center[1]);
    try std.testing.expect(center[0] > center[2]);
    try std.testing.expect(!(outer[0] == center[0] and outer[1] == center[1] and outer[2] == center[2]));
}

test "traffic light hover brightens control" {
    resetDesktop();
    pointer_x = -100;
    pointer_y = -100;
    renderWindowBuffer();
    const base = windowPixel(23, 8);
    pointer_x = window_x + 23;
    pointer_y = window_y + 8;
    renderWindowBuffer();
    const hovered = windowPixel(23, 8);
    try std.testing.expect(hovered[0] >= base[0]);
    try std.testing.expect(hovered[1] >= base[1]);
}

test "hovering one traffic light activates all glyphs" {
    resetDesktop();
    pointer_x = window_x + 23;
    pointer_y = window_y + 8;
    renderWindowBuffer();
    const close_center = windowPixel(11, 8);
    const zoom_center = windowPixel(35, 8);
    try std.testing.expect(close_center[0] < 120 and close_center[1] < 120 and close_center[2] < 120);
    try std.testing.expect(zoom_center[0] < 140 and zoom_center[1] < 140 and zoom_center[2] < 140);
}

test "tiger scrollbars render blue barber-pole thumb" {
    resetDesktop();
    renderWindowBuffer();
    const sx = window_w - 6;
    const sy = 45;
    const a = windowPixel(sx, sy);
    const b = windowPixel(sx, sy + 1);
    try std.testing.expect(a[2] > a[0]);
    try std.testing.expect(a[2] > a[1]);
    try std.testing.expect(a[0] != b[0] or a[1] != b[1] or a[2] != b[2]);
}

test "tiger barber-pole pattern is anchored while thumb moves" {
    resetDesktop();
    renderWindowBuffer();
    const t0 = tigerVThumbLocalRect();
    const c0a = windowPixel(t0.x + 2, t0.y + 3);
    const c0b = windowPixel(t0.x + 4, t0.y + 5);

    var target_scroll: i32 = -1;
    var s: i32 = 1;
    while (s <= tigerMaxScrollY()) : (s += 1) {
        setTigerScrollY(s);
        const t = tigerVThumbLocalRect();
        const dy = t.y - t0.y;
        if (dy != 0 and (dy & 3) != 0) {
            target_scroll = s;
            break;
        }
    }
    try std.testing.expect(target_scroll >= 0);

    setTigerScrollY(target_scroll);
    renderWindowBuffer();
    const t1 = tigerVThumbLocalRect();
    const c1a = windowPixel(t1.x + 2, t1.y + 3);
    const c1b = windowPixel(t1.x + 4, t1.y + 5);
    const changed_a = c0a[0] != c1a[0] or c0a[1] != c1a[1] or c0a[2] != c1a[2];
    const changed_b = c0b[0] != c1b[0] or c0b[1] != c1b[1] or c0b[2] != c1b[2];
    try std.testing.expect(changed_a or changed_b);
}

test "tiger vertical scrollbar drag updates scroll position" {
    resetDesktop();
    const thumb = tigerVThumbLocalRect();
    _ = pointerEventForTest(BTN_PRIMARY, window_x + thumb.x + 2, window_y + thumb.y + 2, 0);
    _ = pointerEventForTest(BTN_PRIMARY, window_x + thumb.x + 2, window_y + thumb.y + 22, 0);
    _ = pointerEventForTest(0, window_x + thumb.x + 2, window_y + thumb.y + 22, 0);
    try std.testing.expect(scroll_y > 0);
}

test "compositor blends partial alpha pixels" {
    fillRect(0, 0, 1, 1, .{ 100, 100, 100, 0xFF });
    blendPixelI32(0, 0, .{ 200, 0, 0, 128 });
    try std.testing.expect(output_buf[0] > 140 and output_buf[0] < 160);
    try std.testing.expect(output_buf[1] > 45 and output_buf[1] < 55);
    try std.testing.expect(output_buf[2] > 45 and output_buf[2] < 55);
    try std.testing.expect(output_buf[3] == 0xFF);
}

test "window shadow is blurred from window alpha" {
    resetDesktop();
    fillRect(0, 0, RENDER_W, RENDER_H, .{ 0xF0, 0xF0, 0xF0, 0xFF });
    renderWindowBuffer();
    drawWindowShadow(40, 40, window_w, window_h);
    const center_idx = outputIndex(40 + SHADOW_OFFSET_X + @divTrunc(window_w, 2), 40 + SHADOW_OFFSET_Y + @divTrunc(window_h, 2));
    const feather_idx = outputIndex(40 + SHADOW_OFFSET_X - 2, 40 + SHADOW_OFFSET_Y + @divTrunc(window_h, 2));
    const far_idx = outputIndex(8, 8);
    try std.testing.expect(output_buf[center_idx + 0] < output_buf[feather_idx + 0]);
    try std.testing.expect(output_buf[feather_idx + 0] < output_buf[far_idx + 0]);
}

test "minimize hides window and dock thumbnail restores it" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 104, 49, 0);
    _ = pointerEventForTest(0, 104, 49, 0);
    try std.testing.expect(window_minimized);
    try std.testing.expect(genie_mode == .minimizing);
    advanceGenieForTest();
    _ = pointerEventForTest(BTN_PRIMARY, 246, 190, 0);
    _ = pointerEventForTest(0, 246, 190, 0);
    try std.testing.expect(genie_mode == .restoring);
    advanceGenieForTest();
    try std.testing.expect(!window_minimized);
}

test "dock slots shift when window is minimized" {
    resetDesktop();
    const trash_center_open = dockSlotCenter(DOCK_N - 1);
    _ = pointerEventForTest(BTN_PRIMARY, 104, 49, 0);
    _ = pointerEventForTest(0, 104, 49, 0);
    try std.testing.expect(window_minimized);
    try std.testing.expect(dockSlotCenter(DOCK_N) > trash_center_open);
    try std.testing.expect(minimizedWindowAt(dockSlotCenter(DOCK_MINIMIZED_SLOT), 190));
}

test "shift slows genie animation" {
    resetDesktop();
    _ = keyEventForTest(XK_SHIFT_L, FLAG_KEY_DOWN, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 104, 49, 0);
    _ = pointerEventForTest(0, 104, 49, 0);
    try std.testing.expect(window_minimized);
    try std.testing.expect(genie_mode == .minimizing);
    try std.testing.expect(genie_total_frames == GENIE_SHIFT_FRAMES);
    var i: i32 = 0;
    while (i < GENIE_FRAMES) : (i += 1) _ = advanceGenieFrameForTest();
    try std.testing.expect(genie_mode == .minimizing);
    advanceGenieForTest();
    try std.testing.expect(genie_mode == .none);
}

test "menubar opens and closes on outside click" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 84, 9, 0);
    _ = pointerEventForTest(0, 84, 9, 0);
    try std.testing.expect(menu_open == .file);
    _ = pointerEventForTest(BTN_PRIMARY, 260, 120, 0);
    _ = pointerEventForTest(0, 260, 120, 0);
    try std.testing.expect(menu_open == .none);
}

test "menubar mini action starts minimize" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 36, 9, 0);
    _ = pointerEventForTest(0, 36, 9, 0);
    try std.testing.expect(menu_open == .finder);
    _ = pointerEventForTest(BTN_PRIMARY, 32, 41, 0);
    _ = pointerEventForTest(0, 32, 41, 0);
    try std.testing.expect(window_minimized);
    try std.testing.expect(genie_mode == .minimizing);
    try std.testing.expect(menu_open == .none);
}

test "desktop context menu opens on right click" {
    resetDesktop();
    try std.testing.expect(desktopSurfaceAt(260, 150));
    _ = pointerEventForTest(BTN_SECONDARY, 260, 150, 0);
    _ = pointerEventForTest(0, 260, 150, 0);
    try std.testing.expect(desktop_menu_open);
}

test "marquee selection can select multiple icons" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 20, 24, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 170, 152, 0);
    _ = pointerEventForTest(0, 170, 152, 0);
    try std.testing.expect((selected_mask & 0b0001_1100) != 0);
}

fn advanceGenieForTest() void {
    var i: i32 = 0;
    while (i < GENIE_SHIFT_FRAMES) : (i += 1) _ = advanceGenieFrameForTest();
}

fn outputIndex(x: i32, y: i32) usize {
    return (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
}
