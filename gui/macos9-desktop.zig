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
const ICON_W: i32 = 40;
const ICON_H: i32 = 32;
const WINDOW_W: i32 = 196;
const WINDOW_H: i32 = 126;
const WINDOW_SHADED_H: i32 = 20;
const WINDOW_MIN_W: i32 = 138;
const WINDOW_MIN_H: i32 = 78;
const WINDOW_MAX_W: i32 = 292;
const WINDOW_MAX_H: i32 = 188;
const SCROLLBAR_SIZE: i32 = 15;
const SCROLL_CONTENT_W: i32 = 290;
const SCROLL_CONTENT_H: i32 = 250;

const Color = [4]u8;
const C_DESK: Color = .{ 0x66, 0x65, 0x99, 0xFF };
const C_DESK_LIGHT: Color = .{ 0x75, 0x74, 0xA8, 0xFF };
const C_DESK_DARK: Color = .{ 0x58, 0x57, 0x88, 0xFF };
const C_BAR: Color = .{ 0xDD, 0xDD, 0xDD, 0xFF };
const C_LIGHT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_HILITE: Color = .{ 0xF3, 0xF3, 0xF3, 0xFF };
const C_MID: Color = .{ 0x99, 0x99, 0x99, 0xFF };
const C_SHADOW: Color = .{ 0x66, 0x66, 0x66, 0xFF };
const C_DARK: Color = .{ 0x22, 0x22, 0x22, 0xFF };
const C_SELECT: Color = .{ 0x33, 0x66, 0xCC, 0xFF };
const C_FOLDER: Color = .{ 0xF6, 0xCF, 0x59, 0xFF };
const C_FOLDER_SHADOW: Color = .{ 0xC3, 0x8D, 0x24, 0xFF };
const C_DRIVE: Color = .{ 0xCC, 0xCC, 0xCC, 0xFF };
const C_WINDOW: Color = .{ 0xDD, 0xDD, 0xDD, 0xFF };

const IconKind = enum(u8) { drive, folder, trash, document, app };

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
const ScrollArrowDir = enum(u8) { up, down, left, right };

const InteractionMode = union(enum) {
    idle,
    dragging_icon: usize,
    dragging_window,
    resizing_window,
    marquee_select,
    dragging_scroll: ScrollAxis,
};

const MenuId = enum(u8) { none, system, file, edit, view };

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;
var icons: [5]Icon = undefined;
var selected_icon: i32 = -1;
var selected_mask: u8 = 0;
var mode: InteractionMode = .idle;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var icon_drag_x: i32 = 0;
var icon_drag_y: i32 = 0;
var window_x: i32 = 54;
var window_y: i32 = 46;
var window_w: i32 = WINDOW_W;
var window_h: i32 = WINDOW_H;
var window_restore_x: i32 = 54;
var window_restore_y: i32 = 46;
var window_restore_w: i32 = WINDOW_W;
var window_restore_h: i32 = WINDOW_H;
var window_drag_x: i32 = 54;
var window_drag_y: i32 = 46;
var window_drag_w: i32 = WINDOW_W;
var window_drag_h: i32 = WINDOW_H;
var scroll_x: i32 = 0;
var scroll_y: i32 = 0;
var scroll_drag_delta: i32 = 0;
var scroll_drag_thumb_pos: i32 = 0;
var window_minimized: bool = false;
var window_shaded: bool = false;
var window_zoomed: bool = false;
var menu_open: MenuId = .none;
var menu_tracking: bool = false;
var desktop_menu_open: bool = false;
var desktop_menu_x: i32 = 0;
var desktop_menu_y: i32 = 0;
var marquee_x0: i32 = 0;
var marquee_y0: i32 = 0;
var marquee_x1: i32 = 0;
var marquee_y1: i32 = 0;
var primary_down: bool = false;
var secondary_down: bool = false;
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
        menu_tracking = false;
        menu_open = .none;
        if (desktopSurfaceAt(x_px, y_px)) {
            openDesktopMenu(x_px, y_px);
        } else {
            desktop_menu_open = false;
        }
        secondary_down = true;
        needs_redraw = true;
        return 1;
    }
    if (!secondary and secondary_down) {
        secondary_down = false;
        needs_redraw = true;
        return 1;
    }

    if (menu_tracking) {
        if (down) {
            const bar_hit = menuBarHit(x_px, y_px);
            if (bar_hit != .none) menu_open = bar_hit;
            primary_down = true;
            needs_redraw = true;
            return 1;
        }
        if (!down and primary_down) {
            const item = menuItemAt(menu_open, x_px, y_px);
            if (item >= 0) applyMenuAction(menu_open, item);
            menu_open = .none;
            menu_tracking = false;
            primary_down = false;
            needs_redraw = true;
            return 1;
        }
    }

    if (down and !primary_down) {
        if (desktop_menu_open) {
            if (desktopMenuAt(x_px, y_px)) {
                const item = desktopMenuItemAt(x_px, y_px);
                if (item >= 0) handleDesktopMenuAction(item);
            }
            desktop_menu_open = false;
            selected_icon = -1;
            mode = .idle;
        } else if (menuBarHit(x_px, y_px) != .none) {
            menu_open = menuBarHit(x_px, y_px);
            menu_tracking = true;
            mode = .idle;
        } else if (!window_minimized and closeButtonAt(x_px, y_px)) {
            window_minimized = true;
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else if (!window_minimized and zoomButtonAt(x_px, y_px)) {
            toggleMac9Zoom();
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else if (!window_minimized and collapseButtonAt(x_px, y_px)) {
            window_shaded = !window_shaded;
            selected_icon = -1;
            selected_mask = 0;
            mode = .idle;
        } else if (!window_minimized and !window_shaded and resizeHandleAt(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
            mode = .resizing_window;
            drag_dx = x_px - window_w;
            drag_dy = y_px - window_h;
            window_zoomed = false;
            window_drag_w = window_w;
            window_drag_h = window_h;
        } else if (!window_minimized and !window_shaded and handleMac9ScrollbarPress(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
        } else if (!window_minimized and titlebarAt(x_px, y_px)) {
            selected_icon = -1;
            selected_mask = 0;
            mode = .dragging_window;
            drag_dx = x_px - window_x;
            drag_dy = y_px - window_y;
            window_zoomed = false;
            window_drag_x = window_x;
            window_drag_y = window_y;
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
                icon_drag_x = icon.x;
                icon_drag_y = icon.y;
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
        if (!menu_tracking) menu_open = .none;
        primary_down = true;
        needs_redraw = true;
        return 1;
    }
    if (down) {
        switch (mode) {
            .dragging_window => {
                const active_window_h = currentWindowHeight();
                window_drag_x = clampI32(x_px - drag_dx, 4, @as(i32, @intCast(RENDER_W)) - window_w - 4);
                window_drag_y = clampI32(y_px - drag_dy, 22, @as(i32, @intCast(RENDER_H)) - active_window_h - 4);
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .resizing_window => {
                window_drag_w = clampI32(x_px - drag_dx, WINDOW_MIN_W, @min(WINDOW_MAX_W, @as(i32, @intCast(RENDER_W)) - window_x - 4));
                window_drag_h = clampI32(y_px - drag_dy, WINDOW_MIN_H, @min(WINDOW_MAX_H, @as(i32, @intCast(RENDER_H)) - window_y - 4));
                primary_down = true;
                needs_redraw = true;
                return 1;
            },
            .dragging_icon => {
                icon_drag_x = clampI32(x_px - drag_dx, 6, @as(i32, @intCast(RENDER_W)) - ICON_W - 6);
                icon_drag_y = clampI32(y_px - drag_dy, 24, @as(i32, @intCast(RENDER_H)) - ICON_H - 14);
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
                    .vertical => previewMac9VScrollTo(y_px - scroll_drag_delta),
                    .horizontal => previewMac9HScrollTo(x_px - scroll_drag_delta),
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
            .dragging_icon => |idx| {
                icons[idx].x = icon_drag_x;
                icons[idx].y = icon_drag_y;
            },
            .marquee_select => applyMarqueeSelection(),
            .dragging_scroll => |axis| switch (axis) {
                .vertical => commitMac9VScrollTo(scroll_drag_thumb_pos),
                .horizontal => commitMac9HScrollTo(scroll_drag_thumb_pos),
            },
            .idle => {},
        }
        mode = .idle;
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
        .{ .x = 266, .y = 28, .kind = .drive, .label = "Macintosh HD" },
        .{ .x = 266, .y = 82, .kind = .folder, .label = "Documents" },
        .{ .x = 18, .y = 151, .kind = .app, .label = "SimpleText" },
        .{ .x = 18, .y = 82, .kind = .document, .label = "Notes" },
        .{ .x = 268, .y = 164, .kind = .trash, .label = "Trash" },
    };
    selected_icon = -1;
    selected_mask = 0;
    mode = .idle;
    icon_drag_x = 0;
    icon_drag_y = 0;
    window_x = 54;
    window_y = 46;
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
    scroll_drag_thumb_pos = 0;
    window_minimized = false;
    window_shaded = false;
    window_zoomed = false;
    menu_open = .none;
    menu_tracking = false;
    desktop_menu_open = false;
    marquee_x0 = 0;
    marquee_y0 = 0;
    marquee_x1 = 0;
    marquee_y1 = 0;
    primary_down = false;
    secondary_down = false;
    needs_redraw = true;
}

fn menuBarHit(x: i32, y: i32) MenuId {
    if (y < 0 or y >= 20) return .none;
    if (x >= 5 and x < 28) return .system;
    if (x >= 28 and x < 58) return .file;
    if (x >= 58 and x < 88) return .edit;
    if (x >= 88 and x < 124) return .view;
    return .none;
}

fn menuPanelX(menu: MenuId) i32 {
    return switch (menu) {
        .system => 5,
        .file => 28,
        .edit => 58,
        .view => 88,
        .none => 0,
    };
}

fn menuPanelWidth(menu: MenuId) i32 {
    return switch (menu) {
        .system => 132,
        .file => 108,
        .edit => 104,
        .view => 100,
        .none => 0,
    };
}

fn menuItemCount(menu: MenuId) i32 {
    return switch (menu) {
        .none => 0,
        else => 2,
    };
}

fn menuItemLabel(menu: MenuId, item: i32) []const u8 {
    return switch (menu) {
        .system => switch (item) {
            0 => "About This Mac",
            1 => "Control Panels",
            else => "",
        },
        .file => switch (item) {
            0 => "Open",
            1 => "Close Window",
            else => "",
        },
        .edit => switch (item) {
            0 => "Select All",
            1 => "Clear",
            else => "",
        },
        .view => switch (item) {
            0 => "Collapse",
            1 => "Close Window",
            else => "",
        },
        .none => "",
    };
}

fn menuItemAt(menu: MenuId, x: i32, y: i32) i32 {
    if (menu == .none) return -1;
    const panel_x = menuPanelX(menu);
    const panel_y: i32 = 20;
    const panel_w = menuPanelWidth(menu);
    const panel_h = 8 + menuItemCount(menu) * 16;
    if (x < panel_x or x >= panel_x + panel_w or y < panel_y or y >= panel_y + panel_h) return -1;
    const rel = y - (panel_y + 4);
    if (rel < 0) return -1;
    const idx = @divFloor(rel, 16);
    if (idx < 0 or idx >= menuItemCount(menu)) return -1;
    return idx;
}

fn applyMenuAction(menu: MenuId, item: i32) void {
    switch (menu) {
        .system => switch (item) {
            0 => {
                resetDesktop();
                return;
            },
            1 => {
                selected_icon = 4;
                selected_mask = 1 << 4;
            },
            else => {},
        },
        .file => switch (item) {
            0 => {
                window_minimized = false;
                window_shaded = false;
            },
            1 => {
                window_minimized = true;
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
                if (!window_minimized) window_shaded = !window_shaded;
            },
            1 => {
                window_minimized = true;
            },
            else => {},
        },
        .none => {},
    }
    mode = .idle;
    needs_redraw = true;
}

fn desktopSurfaceAt(x: i32, y: i32) bool {
    if (y < 20) return false;
    if (!window_minimized) {
        const h = currentWindowHeight();
        if (x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + h) return false;
    }
    return true;
}

fn openDesktopMenu(x: i32, y: i32) void {
    desktop_menu_open = true;
    desktop_menu_x = clampI32(x, 2, @as(i32, @intCast(RENDER_W)) - 102);
    desktop_menu_y = clampI32(y, 22, @as(i32, @intCast(RENDER_H)) - 56);
}

fn desktopMenuAt(x: i32, y: i32) bool {
    return x >= desktop_menu_x and x < desktop_menu_x + 100 and y >= desktop_menu_y and y < desktop_menu_y + 50;
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
            window_minimized = true;
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

fn titlebarAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + WINDOW_SHADED_H;
}

const Mac9CaptionButton = enum(u8) { close, collapse, zoom };

fn mac9CaptionButtonRect(which: Mac9CaptionButton) Rect {
    const btn_w: i32 = 11;
    const btn_h: i32 = 11;
    const btn_y = window_y + 4;
    const zoom_x = window_x + window_w - btn_w - 5;
    return switch (which) {
        .close => .{ .x = window_x + 5, .y = btn_y, .w = btn_w, .h = btn_h },
        .zoom => .{ .x = zoom_x, .y = btn_y, .w = btn_w, .h = btn_h },
        .collapse => .{ .x = zoom_x - btn_w - 3, .y = btn_y, .w = btn_w, .h = btn_h },
    };
}

fn closeButtonAt(x: i32, y: i32) bool {
    const r = mac9CaptionButtonRect(.close);
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn collapseButtonAt(x: i32, y: i32) bool {
    const r = mac9CaptionButtonRect(.collapse);
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn zoomButtonAt(x: i32, y: i32) bool {
    const r = mac9CaptionButtonRect(.zoom);
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn toggleMac9Zoom() void {
    if (window_zoomed) {
        window_x = window_restore_x;
        window_y = window_restore_y;
        window_w = window_restore_w;
        window_h = window_restore_h;
        window_drag_x = window_x;
        window_drag_y = window_y;
        window_drag_w = window_w;
        window_drag_h = window_h;
        window_zoomed = false;
        return;
    }
    window_restore_x = window_x;
    window_restore_y = window_y;
    window_restore_w = window_w;
    window_restore_h = window_h;
    window_shaded = false;
    window_x = 8;
    window_y = 24;
    window_w = @min(WINDOW_MAX_W, @as(i32, @intCast(RENDER_W)) - 16);
    window_h = @min(WINDOW_MAX_H, @as(i32, @intCast(RENDER_H)) - 32);
    window_drag_x = window_x;
    window_drag_y = window_y;
    window_drag_w = window_w;
    window_drag_h = window_h;
    window_zoomed = true;
}

fn resizeHandleAt(x: i32, y: i32) bool {
    const handle_x = window_x + window_w - SCROLLBAR_SIZE - 2;
    const handle_y = window_y + window_h - SCROLLBAR_SIZE - 2;
    return x >= handle_x and x < handle_x + SCROLLBAR_SIZE and y >= handle_y and y < handle_y + SCROLLBAR_SIZE;
}

fn mac9ClientRect() Rect {
    return .{ .x = window_x + 3, .y = window_y + WINDOW_SHADED_H, .w = window_w - 6, .h = window_h - WINDOW_SHADED_H - 3 };
}

fn mac9ViewportRect() Rect {
    const c = mac9ClientRect();
    return .{ .x = c.x + 1, .y = c.y + 1, .w = c.w - SCROLLBAR_SIZE - 1, .h = c.h - SCROLLBAR_SIZE - 1 };
}

fn mac9MaxScrollX() i32 {
    const vp = mac9ViewportRect();
    return @max(0, SCROLL_CONTENT_W - vp.w);
}

fn mac9MaxScrollY() i32 {
    const vp = mac9ViewportRect();
    return @max(0, SCROLL_CONTENT_H - vp.h);
}

fn setMac9ScrollX(v: i32) void {
    scroll_x = clampI32(v, 0, mac9MaxScrollX());
}

fn setMac9ScrollY(v: i32) void {
    scroll_y = clampI32(v, 0, mac9MaxScrollY());
}

fn mac9VScrollRect() Rect {
    const c = mac9ClientRect();
    return .{ .x = c.x + c.w - SCROLLBAR_SIZE, .y = c.y, .w = SCROLLBAR_SIZE, .h = c.h - SCROLLBAR_SIZE };
}

fn mac9HScrollRect() Rect {
    const c = mac9ClientRect();
    return .{ .x = c.x, .y = c.y + c.h - SCROLLBAR_SIZE, .w = c.w - SCROLLBAR_SIZE, .h = SCROLLBAR_SIZE };
}

fn mac9VThumbRect() Rect {
    const track = mac9VScrollRect();
    const thumb_size: i32 = 13;
    const top = track.y + SCROLLBAR_SIZE;
    const span = @max(1, track.h - SCROLLBAR_SIZE * 2 - thumb_size);
    const max_scroll = @max(1, mac9MaxScrollY());
    const t = @divTrunc(scroll_y * span, max_scroll);
    return .{ .x = track.x + 1, .y = top + t, .w = track.w - 2, .h = thumb_size };
}

fn mac9HThumbRect() Rect {
    const track = mac9HScrollRect();
    const thumb_size: i32 = 13;
    const left = track.x + SCROLLBAR_SIZE;
    const span = @max(1, track.w - SCROLLBAR_SIZE * 2 - thumb_size);
    const max_scroll = @max(1, mac9MaxScrollX());
    const t = @divTrunc(scroll_x * span, max_scroll);
    return .{ .x = left + t, .y = track.y + 1, .w = thumb_size, .h = track.h - 2 };
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn clampMac9VThumbY(thumb_y: i32) i32 {
    const track = mac9VScrollRect();
    const thumb = mac9VThumbRect();
    const min_y = track.y + SCROLLBAR_SIZE;
    const max_y = track.y + track.h - SCROLLBAR_SIZE - thumb.h;
    return clampI32(thumb_y, min_y, max_y);
}

fn previewMac9VScrollTo(thumb_y: i32) void {
    scroll_drag_thumb_pos = clampMac9VThumbY(thumb_y);
}

fn commitMac9VScrollTo(thumb_y: i32) void {
    const track = mac9VScrollRect();
    const clamped = clampMac9VThumbY(thumb_y);
    const min_y = track.y + SCROLLBAR_SIZE;
    const max_y = track.y + track.h - SCROLLBAR_SIZE - mac9VThumbRect().h;
    const span = @max(1, max_y - min_y);
    setMac9ScrollY(@divTrunc((clamped - min_y) * mac9MaxScrollY(), span));
}

fn clampMac9HThumbX(thumb_x: i32) i32 {
    const track = mac9HScrollRect();
    const thumb = mac9HThumbRect();
    const min_x = track.x + SCROLLBAR_SIZE;
    const max_x = track.x + track.w - SCROLLBAR_SIZE - thumb.w;
    return clampI32(thumb_x, min_x, max_x);
}

fn previewMac9HScrollTo(thumb_x: i32) void {
    scroll_drag_thumb_pos = clampMac9HThumbX(thumb_x);
}

fn commitMac9HScrollTo(thumb_x: i32) void {
    const track = mac9HScrollRect();
    const clamped = clampMac9HThumbX(thumb_x);
    const min_x = track.x + SCROLLBAR_SIZE;
    const max_x = track.x + track.w - SCROLLBAR_SIZE - mac9HThumbRect().w;
    const span = @max(1, max_x - min_x);
    setMac9ScrollX(@divTrunc((clamped - min_x) * mac9MaxScrollX(), span));
}

fn handleMac9ScrollbarPress(x: i32, y: i32) bool {
    const vbar = mac9VScrollRect();
    const hbar = mac9HScrollRect();
    const vthumb = mac9VThumbRect();
    const hthumb = mac9HThumbRect();

    if (pointInRect(x, y, vthumb)) {
        mode = .{ .dragging_scroll = .vertical };
        scroll_drag_delta = y - vthumb.y;
        scroll_drag_thumb_pos = vthumb.y;
        return true;
    }
    if (pointInRect(x, y, hthumb)) {
        mode = .{ .dragging_scroll = .horizontal };
        scroll_drag_delta = x - hthumb.x;
        scroll_drag_thumb_pos = hthumb.x;
        return true;
    }
    if (pointInRect(x, y, vbar)) {
        if (y < vbar.y + SCROLLBAR_SIZE) setMac9ScrollY(scroll_y - 12) else if (y >= vbar.y + vbar.h - SCROLLBAR_SIZE) setMac9ScrollY(scroll_y + 12) else if (y < vthumb.y) setMac9ScrollY(scroll_y - 40) else if (y >= vthumb.y + vthumb.h) setMac9ScrollY(scroll_y + 40);
        mode = .idle;
        return true;
    }
    if (pointInRect(x, y, hbar)) {
        if (x < hbar.x + SCROLLBAR_SIZE) setMac9ScrollX(scroll_x - 12) else if (x >= hbar.x + hbar.w - SCROLLBAR_SIZE) setMac9ScrollX(scroll_x + 12) else if (x < hthumb.x) setMac9ScrollX(scroll_x - 40) else if (x >= hthumb.x + hthumb.w) setMac9ScrollX(scroll_x + 40);
        mode = .idle;
        return true;
    }
    return false;
}

fn currentWindowHeight() i32 {
    return if (window_shaded) WINDOW_SHADED_H else window_h;
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
    drawDesktopPattern();
    drawMenuBar();
    var i: usize = 0;
    while (i < icons.len) : (i += 1) drawIcon(i);
    if (!window_minimized) {
        drawWindow(window_x, window_y, window_w, currentWindowHeight());
    }
    drawTrails();
    if (menu_open != .none) drawMenuPanel(menu_open);
    if (desktop_menu_open) drawDesktopMenu();
}

fn drawMenuBar() void {
    fillRectI32(0, 0, @intCast(RENDER_W), 20, C_BAR);
    fillRectI32(0, 0, @intCast(RENDER_W), 1, C_LIGHT);
    fillRectI32(0, 18, @intCast(RENDER_W), 1, C_SHADOW);
    fillRectI32(0, 19, @intCast(RENDER_W), 1, C_DARK);
    if (menu_open == .system) fillRectI32(5, 1, 23, 18, C_SELECT);
    drawAppleLogo(11, 4, if (menu_open == .system) C_LIGHT else C_DARK);
    drawMenuTitle(.file, 31, 7, 27, "File");
    drawMenuTitle(.edit, 61, 7, 27, "Edit");
    drawMenuTitle(.view, 91, 7, 33, "View");
    drawText(127, 7, "Special", C_DARK);
    drawText(172, 7, "Help", C_DARK);
    drawFinderBadge(228, 5);
    drawText(246, 7, "Finder", C_DARK);
    drawText(286, 7, "11:45", C_DARK);
}

fn drawMenuTitle(menu: MenuId, x: i32, y: i32, w: i32, text: []const u8) void {
    const selected = menu_open == menu;
    if (selected) fillRectI32(x - 3, 1, w + 2, 18, C_SELECT);
    drawText(x, y, text, if (selected) C_LIGHT else C_DARK);
}

fn drawMenuPanel(menu: MenuId) void {
    const panel_x = menuPanelX(menu);
    const panel_y: i32 = 20;
    const panel_w = menuPanelWidth(menu);
    const panel_h = 8 + menuItemCount(menu) * 16;
    fillRectI32(panel_x + 3, panel_y + 3, panel_w, panel_h, C_SHADOW);
    fillRectI32(panel_x, panel_y, panel_w, panel_h, C_WINDOW);
    drawBevel(panel_x, panel_y, panel_w, panel_h, false);
    var i: i32 = 0;
    while (i < menuItemCount(menu)) : (i += 1) {
        const item_y = panel_y + 4 + i * 16;
        drawText(panel_x + 11, item_y + 4, menuItemLabel(menu, i), C_DARK);
    }
}

fn drawWindow(x: i32, y: i32, w: i32, h: i32) void {
    fillRectI32(x + 3, y + 3, w, h, C_DESK_DARK);
    fillRectI32(x, y, w, h, C_WINDOW);
    drawRect(x, y, w, h, C_DARK);
    drawRect(x + 1, y + 1, w - 2, h - 2, C_LIGHT);
    fillRectI32(x + 2, y + 2, w - 4, WINDOW_SHADED_H - 3, C_BAR);
    drawTitlebarStripes(x, y, w);
    drawMac9CaptionButton(mac9CaptionButtonRect(.close), .close);
    drawMac9CaptionButton(mac9CaptionButtonRect(.collapse), .collapse);
    drawMac9CaptionButton(mac9CaptionButtonRect(.zoom), .zoom);
    const title = "Macintosh HD";
    const title_x = x + @divFloor(w - textWidth(title), 2);
    fillRectI32(title_x - 4, y + 3, textWidth(title) + 8, 14, C_BAR);
    drawText(title_x, y + 7, title, C_DARK);
    if (h <= WINDOW_SHADED_H) return;
    const c = mac9ClientRect();
    fillRectI32(c.x, c.y, c.w, c.h, C_LIGHT);
    drawBevel(c.x, c.y, c.w, c.h, true);
    drawMac9Content();
    drawMac9Scrollbars(c.x, c.y, c.w, c.h);
}

fn drawMac9CaptionButton(r: Rect, which: Mac9CaptionButton) void {
    fillRectI32(r.x, r.y, r.w, r.h, C_WINDOW);
    drawBevel(r.x, r.y, r.w, r.h, false);
    switch (which) {
        .close => {},
        .collapse => {
            fillRectI32(r.x + 3, r.y + 4, r.w - 6, 2, C_DARK);
        },
        .zoom => {
            if (window_zoomed) {
                drawRect(r.x + 3, r.y + 4, 4, 4, C_DARK);
                drawRect(r.x + 4, r.y + 3, 4, 4, C_DARK);
            } else {
                drawRect(r.x + 3, r.y + 3, r.w - 6, r.h - 6, C_DARK);
            }
        },
    }
}

fn drawMac9Content() void {
    const vp = mac9ViewportRect();
    fillRectI32(vp.x, vp.y, vp.w, vp.h, C_LIGHT);
    fillRectI32(vp.x, vp.y, vp.w, 14, C_WINDOW);
    drawBevel(vp.x, vp.y, vp.w, 14, false);
    drawTextClipped(vp.x + 19, vp.y + 4, "Name", C_DARK, vp);
    drawLine(vp.x + vp.w - 45, vp.y + 2, vp.x + vp.w - 45, vp.y + 11, C_SHADOW);
    drawTextClipped(vp.x + vp.w - 38, vp.y + 4, "Size", C_DARK, vp);
    var row: i32 = 0;
    while (row < 18) : (row += 1) {
        const y = vp.y + 15 + row * 14 - scroll_y;
        if (y >= vp.y + 12 and y < vp.y + vp.h) {
            var label_buf: [32]u8 = undefined;
            const label = buildNumberedLabel(&label_buf, row + 1, if (row < 5) "System Folder" else "Finder Item");
            drawListIcon(vp.x + 4 - scroll_x, y + 2, @mod(row, 3));
            drawTextClipped(vp.x + 19 - scroll_x, y + 4, label, C_DARK, vp);
        }
    }
}

fn drawMac9Scrollbars(cx: i32, cy: i32, cw: i32, ch: i32) void {
    const sb: i32 = SCROLLBAR_SIZE;
    if (cw < sb + 8 or ch < sb + 8) return;

    const vbar_x = cx + cw - sb;
    const vbar_h = ch - sb;
    fillRectI32(vbar_x, cy, sb, vbar_h, C_BAR);
    drawBevel(vbar_x, cy, sb, vbar_h, true);
    const up_btn = Rect{ .x = vbar_x + 1, .y = cy + 1, .w = sb - 2, .h = sb - 2 };
    const down_btn = Rect{ .x = vbar_x + 1, .y = cy + vbar_h - sb + 1, .w = sb - 2, .h = sb - 2 };
    fillRectI32(up_btn.x, up_btn.y, up_btn.w, up_btn.h, C_WINDOW);
    drawBevel(up_btn.x, up_btn.y, up_btn.w, up_btn.h, false);
    fillRectI32(down_btn.x, down_btn.y, down_btn.w, down_btn.h, C_WINDOW);
    drawBevel(down_btn.x, down_btn.y, down_btn.w, down_btn.h, false);
    drawMac9ScrollArrow(up_btn, .up);
    drawMac9ScrollArrow(down_btn, .down);
    const vthumb = mac9VThumbRect();
    fillRectI32(vthumb.x, vthumb.y, vthumb.w, vthumb.h, C_WINDOW);
    drawBevel(vthumb.x, vthumb.y, vthumb.w, vthumb.h, false);

    const hbar_y = cy + ch - sb;
    const hbar_w = cw - sb;
    fillRectI32(cx, hbar_y, hbar_w, sb, C_BAR);
    drawBevel(cx, hbar_y, hbar_w, sb, true);
    const left_btn = Rect{ .x = cx + 1, .y = hbar_y + 1, .w = sb - 2, .h = sb - 2 };
    const right_btn = Rect{ .x = cx + hbar_w - sb + 1, .y = hbar_y + 1, .w = sb - 2, .h = sb - 2 };
    fillRectI32(left_btn.x, left_btn.y, left_btn.w, left_btn.h, C_WINDOW);
    drawBevel(left_btn.x, left_btn.y, left_btn.w, left_btn.h, false);
    fillRectI32(right_btn.x, right_btn.y, right_btn.w, right_btn.h, C_WINDOW);
    drawBevel(right_btn.x, right_btn.y, right_btn.w, right_btn.h, false);
    drawMac9ScrollArrow(left_btn, .left);
    drawMac9ScrollArrow(right_btn, .right);
    const hthumb = mac9HThumbRect();
    fillRectI32(hthumb.x, hthumb.y, hthumb.w, hthumb.h, C_WINDOW);
    drawBevel(hthumb.x, hthumb.y, hthumb.w, hthumb.h, false);

    fillRectI32(vbar_x, hbar_y, sb, sb, C_BAR);
    drawBevel(vbar_x, hbar_y, sb, sb, true);
    drawLine(vbar_x + 3, hbar_y + sb - 3, vbar_x + sb - 3, hbar_y + 3, C_SHADOW);
    drawLine(vbar_x + 7, hbar_y + sb - 3, vbar_x + sb - 3, hbar_y + 7, C_SHADOW);
}

fn drawMac9ScrollArrow(r: Rect, dir: ScrollArrowDir) void {
    const cx = r.x + @divFloor(r.w, 2);
    const cy = r.y + @divFloor(r.h, 2);
    var d: i32 = 0;
    while (d < 3) : (d += 1) {
        switch (dir) {
            .up => fillRectI32(cx - d, cy - 1 + d, d * 2 + 1, 1, C_DARK),
            .down => fillRectI32(cx - d, cy + 1 - d, d * 2 + 1, 1, C_DARK),
            .left => fillRectI32(cx - 1 + d, cy - d, 1, d * 2 + 1, C_DARK),
            .right => fillRectI32(cx + 1 - d, cy - d, 1, d * 2 + 1, C_DARK),
        }
    }
}

fn drawTitlebarStripes(x: i32, y: i32, w: i32) void {
    const title_w = textWidth("Macintosh HD") + 10;
    const title_x = x + @divFloor(w - title_w, 2);
    drawPlatinumStripes(x + 19, title_x - 4, y + 4, y + 15);
    drawPlatinumStripes(title_x + title_w + 4, x + w - 34, y + 4, y + 15);
}

fn drawTrails() void {
    switch (mode) {
        .dragging_icon => drawDottedRect(icon_drag_x - 2, icon_drag_y - 2, ICON_W + 4, ICON_H + 16, C_LIGHT),
        .dragging_window => drawDottedRect(window_drag_x, window_drag_y, window_w, currentWindowHeight(), C_LIGHT),
        .resizing_window => drawDottedRect(window_x, window_y, window_drag_w, window_drag_h, C_LIGHT),
        .marquee_select => {
            const x = @min(marquee_x0, marquee_x1);
            const y = @min(marquee_y0, marquee_y1);
            const w = @max(1, @max(marquee_x0, marquee_x1) - x + 1);
            const h = @max(1, @max(marquee_y0, marquee_y1) - y + 1);
            drawDottedRect(x, y, w, h, C_LIGHT);
        },
        .dragging_scroll => |axis| {
            switch (axis) {
                .vertical => {
                    const thumb = mac9VThumbRect();
                    drawDottedRect(thumb.x - 1, scroll_drag_thumb_pos - 1, thumb.w + 2, thumb.h + 2, C_DARK);
                },
                .horizontal => {
                    const thumb = mac9HThumbRect();
                    drawDottedRect(scroll_drag_thumb_pos - 1, thumb.y - 1, thumb.w + 2, thumb.h + 2, C_DARK);
                },
            }
        },
        .idle => {},
    }
}

fn drawIcon(i: usize) void {
    const icon = icons[i];
    const selected = ((selected_mask & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) or selected_icon == @as(i32, @intCast(i));
    drawIconGlyph(icon.kind, icon.x + 4, icon.y);
    const label_w = textWidth(icon.label);
    const label_x = icon.x + @divFloor(ICON_W - label_w, 2);
    if (selected) fillRectI32(label_x - 3, icon.y + ICON_H + 2, label_w + 6, 11, C_SELECT);
    drawText(label_x + 1, icon.y + ICON_H + 5, icon.label, C_DARK);
    drawText(label_x, icon.y + ICON_H + 4, icon.label, C_LIGHT);
}

fn drawDesktopMenu() void {
    fillRectI32(desktop_menu_x + 3, desktop_menu_y + 3, 100, 50, C_SHADOW);
    fillRectI32(desktop_menu_x, desktop_menu_y, 100, 50, C_WINDOW);
    drawBevel(desktop_menu_x, desktop_menu_y, 100, 50, false);
    drawDesktopMenuItem(0, "Clean Up");
    drawDesktopMenuItem(1, "Hide Win");
    drawDesktopMenuItem(2, "Clear");
}

fn drawDesktopMenuItem(item: i32, label: []const u8) void {
    const y = desktop_menu_y + 5 + item * 14;
    drawText(desktop_menu_x + 10, y + 3, label, C_DARK);
}

fn drawIconGlyph(kind: IconKind, x: i32, y: i32) void {
    switch (kind) {
        .drive => {
            fillRectI32(x + 2, y + 10, 31, 18, C_DRIVE);
            drawBevel(x + 2, y + 10, 31, 18, false);
            fillRectI32(x + 5, y + 6, 25, 8, C_HILITE);
            drawBevel(x + 5, y + 6, 25, 8, false);
            fillRectI32(x + 10, y + 21, 15, 2, C_SHADOW);
            fillRectI32(x + 27, y + 21, 2, 2, .{ 0x36, 0xA8, 0x4A, 0xFF });
        },
        .folder => {
            fillRectI32(x + 3, y + 10, 30, 18, C_FOLDER_SHADOW);
            fillRectI32(x + 3, y + 7, 14, 6, C_FOLDER);
            drawRect(x + 3, y + 7, 14, 6, C_DARK);
            fillRectI32(x + 2, y + 11, 32, 17, C_FOLDER);
            drawBevel(x + 2, y + 11, 32, 17, false);
            drawLine(x + 6, y + 15, x + 30, y + 15, C_LIGHT);
        },
        .trash => {
            fillRectI32(x + 8, y + 8, 20, 22, C_DRIVE);
            drawBevel(x + 8, y + 8, 20, 22, false);
            fillRectI32(x + 6, y + 6, 24, 4, C_HILITE);
            drawBevel(x + 6, y + 6, 24, 4, false);
            fillRectI32(x + 13, y + 3, 10, 4, C_DRIVE);
            drawRect(x + 13, y + 3, 10, 4, C_DARK);
            drawLine(x + 13, y + 12, x + 14, y + 26, C_SHADOW);
            drawLine(x + 18, y + 12, x + 18, y + 26, C_SHADOW);
            drawLine(x + 23, y + 12, x + 22, y + 26, C_SHADOW);
        },
        .document => {
            fillRectI32(x + 8, y + 2, 22, 29, C_LIGHT);
            drawRect(x + 8, y + 2, 22, 29, C_DARK);
            fillRectI32(x + 23, y + 2, 7, 7, C_WINDOW);
            drawLine(x + 23, y + 2, x + 30, y + 9, C_DARK);
            drawLine(x + 23, y + 2, x + 23, y + 9, C_DARK);
            drawLine(x + 23, y + 9, x + 30, y + 9, C_DARK);
            drawLine(x + 12, y + 13, x + 25, y + 13, C_SELECT);
            drawLine(x + 12, y + 17, x + 25, y + 17, C_MID);
            drawLine(x + 12, y + 21, x + 23, y + 21, C_MID);
        },
        .app => {
            fillRectI32(x + 3, y + 5, 30, 24, C_LIGHT);
            drawBevel(x + 3, y + 5, 30, 24, false);
            fillRectI32(x + 5, y + 7, 26, 6, C_SELECT);
            drawText(x + 9, y + 7, "TXT", C_LIGHT);
            drawLine(x + 9, y + 17, x + 27, y + 17, C_DARK);
            drawLine(x + 9, y + 21, x + 25, y + 21, C_DARK);
            drawLine(x + 9, y + 25, x + 21, y + 25, C_DARK);
        },
    }
}

fn drawDesktopPattern() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_DESK);
    var y: i32 = 27;
    var row: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 28) {
        var x: i32 = 8 + @mod(row, 2) * 14;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 28) drawDesktopFace(x, y);
        row += 1;
    }
}

fn drawDesktopFace(x: i32, y: i32) void {
    drawRect(x, y, 9, 9, C_DESK_DARK);
    drawLine(x + 4, y + 1, x + 4, y + 7, C_DESK_LIGHT);
    setPixelI32(x + 2, y + 3, C_DESK_LIGHT);
    setPixelI32(x + 6, y + 3, C_DESK_LIGHT);
    drawLine(x + 2, y + 6, x + 3, y + 7, C_DESK_LIGHT);
    drawLine(x + 5, y + 7, x + 7, y + 5, C_DESK_LIGHT);
}

fn drawAppleLogo(x: i32, y: i32, c: Color) void {
    fillRectI32(x + 3, y, 2, 2, c);
    setPixelI32(x + 5, y - 1, c);
    fillRectI32(x + 1, y + 3, 7, 6, c);
    fillRectI32(x, y + 5, 9, 3, c);
    setPixelI32(x + 8, y + 4, C_BAR);
    setPixelI32(x + 1, y + 9, c);
    setPixelI32(x + 7, y + 9, c);
}

fn drawFinderBadge(x: i32, y: i32) void {
    fillRectI32(x, y, 13, 11, C_LIGHT);
    drawRect(x, y, 13, 11, C_DARK);
    drawLine(x + 6, y + 1, x + 6, y + 9, C_MID);
    setPixelI32(x + 3, y + 4, C_DARK);
    setPixelI32(x + 9, y + 4, C_DARK);
    drawLine(x + 3, y + 7, x + 5, y + 8, C_DARK);
    drawLine(x + 7, y + 8, x + 10, y + 6, C_DARK);
}

fn drawListIcon(x: i32, y: i32, kind: i32) void {
    if (kind == 0) {
        fillRectI32(x, y + 2, 11, 7, C_FOLDER);
        fillRectI32(x + 1, y, 5, 3, C_FOLDER);
        drawRect(x, y + 2, 11, 7, C_DARK);
    } else {
        fillRectI32(x + 2, y, 8, 10, C_LIGHT);
        drawRect(x + 2, y, 8, 10, C_DARK);
    }
}

fn drawBevel(x: i32, y: i32, w: i32, h: i32, inset: bool) void {
    const top_left = if (inset) C_SHADOW else C_LIGHT;
    const bottom_right = if (inset) C_LIGHT else C_SHADOW;
    drawLine(x, y, x + w - 1, y, top_left);
    drawLine(x, y, x, y + h - 1, top_left);
    drawLine(x, y + h - 1, x + w - 1, y + h - 1, bottom_right);
    drawLine(x + w - 1, y, x + w - 1, y + h - 1, bottom_right);
    drawRect(x + 1, y + 1, w - 2, h - 2, C_DARK);
}

fn drawPlatinumStripes(x0: i32, x1: i32, y0: i32, y1: i32) void {
    if (x1 <= x0) return;
    var y = y0;
    while (y <= y1) : (y += 3) {
        drawLine(x0, y, x1, y, C_LIGHT);
        if (y + 1 <= y1) drawLine(x0, y + 1, x1, y + 1, C_MID);
    }
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
    while (i < text.len) : (i += 1) drawChar(x + @as(i32, @intCast(i * 6)), y, text[i], c);
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

fn drawTextClipped(x: i32, y: i32, text: []const u8, c: Color, clip: Rect) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const cx = x + @as(i32, @intCast(i * 6));
        if (cx + 5 <= clip.x or cx >= clip.x + clip.w) continue;
        drawCharClipped(cx, y, text[i], c, clip);
    }
}

fn textWidth(text: []const u8) i32 {
    if (text.len == 0) return 0;
    return @as(i32, @intCast(text.len * 6 - 1));
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 7) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 5) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(4 - rx)))) != 0) setPixelI32(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), c);
        }
    }
}

fn drawCharClipped(x: i32, y: i32, ch: u8, c: Color, clip: Rect) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 7) : (ry += 1) {
        const py = y + @as(i32, @intCast(ry));
        if (py < clip.y or py >= clip.y + clip.h) continue;
        var rx: usize = 0;
        while (rx < 5) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(4 - rx)))) == 0) continue;
            const px = x + @as(i32, @intCast(rx));
            if (px < clip.x or px >= clip.x + clip.w) continue;
            setPixelI32(px, py, c);
        }
    }
}

fn glyph(ch: u8) [7]u8 {
    return switch (ch) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01111, 0b10000, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        'a' => .{ 0, 0, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111 },
        'b' => .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11110 },
        'c' => .{ 0, 0, 0b01111, 0b10000, 0b10000, 0b10000, 0b01111 },
        'd' => .{ 0b00001, 0b00001, 0b01101, 0b10011, 0b10001, 0b10001, 0b01111 },
        'e' => .{ 0, 0, 0b01110, 0b10001, 0b11111, 0b10000, 0b01111 },
        'f' => .{ 0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000 },
        'g' => .{ 0, 0, 0b01111, 0b10001, 0b01111, 0b00001, 0b01110 },
        'h' => .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
        'i' => .{ 0b00100, 0, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'j' => .{ 0b00010, 0, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100 },
        'k' => .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010 },
        'l' => .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'm' => .{ 0, 0, 0b11010, 0b10101, 0b10101, 0b10101, 0b10101 },
        'n' => .{ 0, 0, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
        'o' => .{ 0, 0, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 },
        'p' => .{ 0, 0, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 },
        'q' => .{ 0, 0, 0b01111, 0b10001, 0b01111, 0b00001, 0b00001 },
        'r' => .{ 0, 0, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000 },
        's' => .{ 0, 0, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 },
        't' => .{ 0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110 },
        'u' => .{ 0, 0, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101 },
        'v' => .{ 0, 0, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'w' => .{ 0, 0, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010 },
        'x' => .{ 0, 0, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 },
        'y' => .{ 0, 0, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 },
        'z' => .{ 0, 0, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
        '.' => .{ 0, 0, 0, 0, 0, 0b01100, 0b01100 },
        ':' => .{ 0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0 },
        '-' => .{ 0, 0, 0, 0b11111, 0, 0, 0 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => .{ 0b01110, 0b10001, 0b00010, 0b00100, 0b00100, 0, 0b00100 },
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

test "icon outline commits on release" {
    resetDesktop();
    const original_x = icons[0].x;
    const original_y = icons[0].y;
    _ = pointerEventForTest(BTN_PRIMARY, original_x + 8, original_y + 8, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 190, 90, 0);
    try std.testing.expect(icons[0].x == original_x and icons[0].y == original_y);
    try std.testing.expect(icon_drag_x != original_x or icon_drag_y != original_y);
    _ = pointerEventForTest(0, 190, 90, 0);
    try std.testing.expect(icons[0].x == icon_drag_x and icons[0].y == icon_drag_y);
}

test "window outline commits on release" {
    resetDesktop();
    const original_x = window_x;
    const original_y = window_y;
    _ = pointerEventForTest(BTN_PRIMARY, window_x + 30, window_y + 9, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 140, 88, 0);
    try std.testing.expect(window_x == original_x and window_y == original_y);
    try std.testing.expect(window_drag_x != original_x or window_drag_y != original_y);
    _ = pointerEventForTest(0, 140, 88, 0);
    try std.testing.expect(window_x == window_drag_x and window_y == window_drag_y);
}

test "view menu Collapse toggles window shade state" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 96, 8, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 98, 28, 0);
    _ = pointerEventForTest(0, 98, 28, 0);
    try std.testing.expect(window_shaded);
    try std.testing.expect(!window_minimized);
    _ = pointerEventForTest(BTN_PRIMARY, 96, 8, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 98, 28, 0);
    _ = pointerEventForTest(0, 98, 28, 0);
    try std.testing.expect(!window_shaded);
}

test "collapse box toggles window shade" {
    resetDesktop();
    const collapse_btn = mac9CaptionButtonRect(.collapse);
    _ = pointerEventForTest(BTN_PRIMARY, collapse_btn.x + 2, collapse_btn.y + 2, 0);
    _ = pointerEventForTest(0, collapse_btn.x + 2, collapse_btn.y + 2, 0);
    try std.testing.expect(window_shaded);
    try std.testing.expect(!window_minimized);
    try std.testing.expect(mode == .idle);
    _ = pointerEventForTest(BTN_PRIMARY, collapse_btn.x + 2, collapse_btn.y + 2, 0);
    _ = pointerEventForTest(0, collapse_btn.x + 2, collapse_btn.y + 2, 0);
    try std.testing.expect(!window_shaded);
}

test "zoom button toggles fit size and restore" {
    resetDesktop();
    const zoom_btn = mac9CaptionButtonRect(.zoom);
    _ = pointerEventForTest(BTN_PRIMARY, zoom_btn.x + 2, zoom_btn.y + 2, 0);
    _ = pointerEventForTest(0, zoom_btn.x + 2, zoom_btn.y + 2, 0);
    try std.testing.expect(window_zoomed);
    try std.testing.expect(window_w > WINDOW_W and window_h > WINDOW_H);

    const zoom_btn_rest = mac9CaptionButtonRect(.zoom);
    _ = pointerEventForTest(BTN_PRIMARY, zoom_btn_rest.x + 2, zoom_btn_rest.y + 2, 0);
    _ = pointerEventForTest(0, zoom_btn_rest.x + 2, zoom_btn_rest.y + 2, 0);
    try std.testing.expect(!window_zoomed);
    try std.testing.expect(window_x == 54 and window_y == 46 and window_w == WINDOW_W and window_h == WINDOW_H);
}

test "resize outline commits on release" {
    resetDesktop();
    const handle_x = window_x + window_w - 8;
    const handle_y = window_y + window_h - 8;
    _ = pointerEventForTest(BTN_PRIMARY, handle_x, handle_y, 0);
    _ = pointerEventForTest(BTN_PRIMARY, handle_x + 28, handle_y + 28, 0);
    try std.testing.expect(window_w == WINDOW_W and window_h == WINDOW_H);
    try std.testing.expect(window_drag_w > WINDOW_W and window_drag_h > WINDOW_H);
    _ = pointerEventForTest(0, 244, 146, 0);
    try std.testing.expect(window_w == window_drag_w and window_h == window_drag_h);
}

test "menubar opens while holding and closes on release" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 40, 8, 0);
    try std.testing.expect(menu_open == .file);
    try std.testing.expect(menu_tracking);
    _ = pointerEventForTest(BTN_PRIMARY, 70, 8, 0);
    try std.testing.expect(menu_open == .edit);
    _ = pointerEventForTest(0, 280, 120, 0);
    try std.testing.expect(menu_open == .none);
    try std.testing.expect(!menu_tracking);
}

test "menubar file close item closes window on release" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 40, 8, 0);
    try std.testing.expect(menu_open == .file);
    _ = pointerEventForTest(BTN_PRIMARY, 42, 44, 0);
    _ = pointerEventForTest(0, 42, 44, 0);
    try std.testing.expect(window_minimized);
    try std.testing.expect(menu_open == .none);
}

test "desktop context menu opens on right click" {
    resetDesktop();
    _ = pointerEventForTest(BTN_SECONDARY, 210, 205, 0);
    _ = pointerEventForTest(0, 210, 205, 0);
    try std.testing.expect(desktop_menu_open);
}

test "marquee selection selects multiple icons" {
    resetDesktop();
    _ = pointerEventForTest(BTN_PRIMARY, 20, 30, 0);
    _ = pointerEventForTest(BTN_PRIMARY, 180, 180, 0);
    _ = pointerEventForTest(0, 180, 180, 0);
    try std.testing.expect((selected_mask & 0b0000_1110) != 0);
}

test "macos9 vertical scrollbar drag commits scroll on release" {
    resetDesktop();
    const thumb = mac9VThumbRect();
    _ = pointerEventForTest(BTN_PRIMARY, thumb.x + 2, thumb.y + 2, 0);
    _ = pointerEventForTest(BTN_PRIMARY, thumb.x + 2, thumb.y + 20, 0);
    try std.testing.expect(scroll_y == 0);
    _ = pointerEventForTest(0, thumb.x + 2, thumb.y + 20, 0);
    try std.testing.expect(scroll_y > 0);
}
