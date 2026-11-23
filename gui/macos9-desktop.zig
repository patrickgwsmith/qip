const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

// A Mac OS 9 "Platinum" Finder desktop drawn at real pixel scale.

const RENDER_W: usize = 640;
const RENDER_H: usize = 480;
const SCREEN_W: i32 = @intCast(RENDER_W);
const SCREEN_H: i32 = @intCast(RENDER_H);
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const MENUBAR_H: i32 = 20;
const MENU_TOP: i32 = MENUBAR_H - 1;
const ICON_SIZE: i32 = 32;
const LABEL_H: i32 = 11;

const WINDOW_X: i32 = 72;
const WINDOW_Y: i32 = 64;
const WINDOW_W: i32 = 400;
const WINDOW_H: i32 = 232;
const WINDOW_MIN_W: i32 = 150;
const WINDOW_MIN_H: i32 = 104;
const WINDOW_MAX_W: i32 = SCREEN_W - 16;
const WINDOW_MAX_H: i32 = SCREEN_H - MENUBAR_H - 8;
const TITLE_H: i32 = 20;
const WINDOW_SHADED_H: i32 = TITLE_H;
const INFO_H: i32 = 13;
const FRAME: i32 = 4;
const COLHDR_H: i32 = 15;
const SCROLLBAR_SIZE: i32 = 16;
const ROW_H: i32 = 16;

const Color = [4]u8;

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ r, g, b, 0xFF };
}

const C_BLACK = rgb(0x00, 0x00, 0x00);
const C_WHITE = rgb(0xFF, 0xFF, 0xFF);
const C_G1 = rgb(0xEE, 0xEE, 0xEE);
const C_G2 = rgb(0xDD, 0xDD, 0xDD);
const C_G3 = rgb(0xCC, 0xCC, 0xCC);
const C_G4 = rgb(0xBB, 0xBB, 0xBB);
const C_G5 = rgb(0xAA, 0xAA, 0xAA);
const C_G6 = rgb(0x99, 0x99, 0x99);
const C_G7 = rgb(0x88, 0x88, 0x88);
const C_G8 = rgb(0x77, 0x77, 0x77);
const C_G9 = rgb(0x55, 0x55, 0x55);
const C_ACC_PALE = rgb(0xCC, 0xCC, 0xFF);
const C_ACC_LIGHT = rgb(0x99, 0x99, 0xFF);
const C_ACC_MID = rgb(0x66, 0x66, 0xCC);
const C_ACC_DARK = rgb(0x33, 0x33, 0x99);
const C_MENU_HILITE = rgb(0x44, 0x44, 0xBB);
const C_DESK = rgb(0x5E, 0x5E, 0xA8);

// ---------------------------------------------------------------------------
// Desktop model

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

const MenuId = enum(u8) { none, apple, file, edit, view, special, help, context };

const Action = enum(u8) { none, open_window, close_window, select_all, clear_selection, clean_up, collapse_window };

const MenuItem = struct {
    label: []const u8 = "",
    key: u8 = 0,
    enabled: bool = true,
    separator: bool = false,
    checked: bool = false,
    action: Action = .none,
};

const SEP = MenuItem{ .separator = true, .enabled = false };

const APPLE_ITEMS = [_]MenuItem{
    .{ .label = "About This Computer" },
    SEP,
    .{ .label = "Apple System Profiler" },
    .{ .label = "Calculator" },
    .{ .label = "Chooser" },
    .{ .label = "Control Panels" },
    .{ .label = "Note Pad" },
    .{ .label = "Recent Applications" },
};

const FILE_ITEMS = [_]MenuItem{
    .{ .label = "New Folder", .key = 'N', .enabled = false },
    .{ .label = "Open", .key = 'O', .action = .open_window },
    .{ .label = "Print", .key = 'P', .enabled = false },
    .{ .label = "Close Window", .key = 'W', .action = .close_window },
    SEP,
    .{ .label = "Get Info", .key = 'I' },
    .{ .label = "Duplicate", .key = 'D', .enabled = false },
    .{ .label = "Make Alias", .key = 'M', .enabled = false },
    SEP,
    .{ .label = "Find...", .key = 'F' },
};

const EDIT_ITEMS = [_]MenuItem{
    .{ .label = "Undo", .key = 'Z', .enabled = false },
    SEP,
    .{ .label = "Cut", .key = 'X', .enabled = false },
    .{ .label = "Copy", .key = 'C', .enabled = false },
    .{ .label = "Paste", .key = 'V', .enabled = false },
    .{ .label = "Clear", .action = .clear_selection },
    .{ .label = "Select All", .key = 'A', .action = .select_all },
    SEP,
    .{ .label = "Preferences..." },
};

const VIEW_ITEMS = [_]MenuItem{
    .{ .label = "as Icons" },
    .{ .label = "as Buttons" },
    .{ .label = "as List", .checked = true },
    SEP,
    .{ .label = "Clean Up", .action = .clean_up },
    .{ .label = "Arrange", .enabled = false },
    SEP,
    .{ .label = "Collapse Window", .action = .collapse_window },
};

const SPECIAL_ITEMS = [_]MenuItem{
    .{ .label = "Empty Trash..." },
    SEP,
    .{ .label = "Eject", .key = 'E', .enabled = false },
    .{ .label = "Erase Disk...", .enabled = false },
    SEP,
    .{ .label = "Sleep" },
    .{ .label = "Restart" },
    .{ .label = "Shut Down" },
};

const HELP_ITEMS = [_]MenuItem{
    .{ .label = "Help Center" },
    .{ .label = "Show Balloons" },
    SEP,
    .{ .label = "Mac Help", .key = '?' },
};

const CONTEXT_ITEMS = [_]MenuItem{
    .{ .label = "Help" },
    SEP,
    .{ .label = "New Folder", .enabled = false },
    .{ .label = "Clean Up", .action = .clean_up },
    .{ .label = "Close Window", .action = .close_window },
    SEP,
    .{ .label = "Deselect All", .action = .clear_selection },
};

const BAR_MENUS = [_]MenuId{ .apple, .file, .edit, .view, .special, .help };

fn menuItems(menu: MenuId) []const MenuItem {
    return switch (menu) {
        .apple => &APPLE_ITEMS,
        .file => &FILE_ITEMS,
        .edit => &EDIT_ITEMS,
        .view => &VIEW_ITEMS,
        .special => &SPECIAL_ITEMS,
        .help => &HELP_ITEMS,
        .context => &CONTEXT_ITEMS,
        .none => &.{},
    };
}

fn menuTitle(menu: MenuId) []const u8 {
    return switch (menu) {
        .file => "File",
        .edit => "Edit",
        .view => "View",
        .special => "Special",
        .help => "Help",
        else => "",
    };
}

const ListKind = enum(u8) { folder, document, app };

const ListItem = struct {
    kind: ListKind,
    name: []const u8,
    date: []const u8,
    size: []const u8,
    type: []const u8,
};

const LIST_ITEMS = [_]ListItem{
    .{ .kind = .folder, .name = "Apple Extras", .date = "Fri, Oct 22, 1999", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Applications", .date = "Fri, Oct 22, 1999", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Assistants", .date = "Fri, Oct 22, 1999", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Documents", .date = "Today, 11:40 AM", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Internet", .date = "Fri, Oct 22, 1999", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Mac OS Read Me Files", .date = "Fri, Oct 22, 1999", .size = "--", .type = "folder" },
    .{ .kind = .document, .name = "Notes", .date = "Today, 11:38 AM", .size = "4 K", .type = "SimpleText document" },
    .{ .kind = .app, .name = "SimpleText", .date = "Mon, Sep 13, 1999", .size = "396 K", .type = "application program" },
    .{ .kind = .folder, .name = "System Folder", .date = "Today, 11:42 AM", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Utilities", .date = "Fri, Oct 22, 1999", .size = "--", .type = "folder" },
    .{ .kind = .folder, .name = "Web Pages", .date = "Thu, Oct 14, 1999", .size = "--", .type = "folder" },
};
const LIST_INFO = "11 items, 1.84 GB available";

const Column = struct { x: i32, w: i32, title: []const u8, right: bool = false };
const COLUMNS = [_]Column{
    .{ .x = 0, .w = 168, .title = "Name" },
    .{ .x = 168, .w = 108, .title = "Date Modified" },
    .{ .x = 276, .w = 48, .title = "Size", .right = true },
    .{ .x = 324, .w = 118, .title = "Kind" },
};
const SCROLL_CONTENT_W: i32 = 442;
const SCROLL_CONTENT_H: i32 = @as(i32, LIST_ITEMS.len) * ROW_H;
const NAME_TEXT_X: i32 = 34;

// ---------------------------------------------------------------------------
// State

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;
var icons: [5]Icon = undefined;
var selected_icon: i32 = -1;
var selected_mask: u8 = 0;
var list_selected: i32 = -1;
var mode: InteractionMode = .idle;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var icon_drag_x: i32 = 0;
var icon_drag_y: i32 = 0;
var window_x: i32 = WINDOW_X;
var window_y: i32 = WINDOW_Y;
var window_w: i32 = WINDOW_W;
var window_h: i32 = WINDOW_H;
var window_restore_x: i32 = WINDOW_X;
var window_restore_y: i32 = WINDOW_Y;
var window_restore_w: i32 = WINDOW_W;
var window_restore_h: i32 = WINDOW_H;
var window_drag_x: i32 = WINDOW_X;
var window_drag_y: i32 = WINDOW_Y;
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
var menu_sticky: bool = false;
var desktop_menu_open: bool = false;
var desktop_menu_x: i32 = 0;
var desktop_menu_y: i32 = 0;
var pointer_x: i32 = -1;
var pointer_y: i32 = -1;
var marquee_x0: i32 = 0;
var marquee_y0: i32 = 0;
var marquee_x1: i32 = 0;
var marquee_y1: i32 = 0;
var primary_down: bool = false;
var secondary_down: bool = false;
var needs_redraw: bool = true;
var initialized: bool = false;

// ---------------------------------------------------------------------------
// Content ABI

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

const DEFAULT_ICONS = [_]Icon{
    .{ .x = 584, .y = 30, .kind = .drive, .label = "Macintosh HD" },
    .{ .x = 584, .y = 86, .kind = .folder, .label = "Documents" },
    .{ .x = 584, .y = 198, .kind = .app, .label = "SimpleText" },
    .{ .x = 584, .y = 142, .kind = .document, .label = "Notes" },
    .{ .x = 584, .y = 422, .kind = .trash, .label = "Trash" },
};

fn resetDesktop() void {
    icons = DEFAULT_ICONS;
    selected_icon = -1;
    selected_mask = 0;
    list_selected = -1;
    mode = .idle;
    icon_drag_x = 0;
    icon_drag_y = 0;
    window_x = WINDOW_X;
    window_y = WINDOW_Y;
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
    closeMenus();
    desktop_menu_open = false;
    marquee_x0 = 0;
    marquee_y0 = 0;
    marquee_x1 = 0;
    marquee_y1 = 0;
    primary_down = false;
    secondary_down = false;
    needs_redraw = true;
}

// ---------------------------------------------------------------------------
// Input

fn pointerEventForTest(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    const down = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;
    const prev_hover = hoveredMenuItem();
    pointer_x = x_px;
    pointer_y = y_px;

    if (secondary and !secondary_down) {
        mode = .idle;
        primary_down = false;
        closeMenus();
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

    if (menu_open != .none) return menuPointer(down, x_px, y_px, prev_hover);

    if (down and !primary_down) {
        primary_down = true;
        needs_redraw = true;
        if (desktop_menu_open) {
            const item = menuItemAt(.context, x_px, y_px);
            desktop_menu_open = false;
            mode = .idle;
            if (item >= 0) applyAction(CONTEXT_ITEMS[@intCast(item)].action);
            return 1;
        }
        const bar = menuBarHit(x_px, y_px);
        if (bar != .none) {
            menu_open = bar;
            menu_tracking = true;
            menu_sticky = false;
            mode = .idle;
            return 1;
        }
        if (!window_minimized and closeButtonAt(x_px, y_px)) {
            window_minimized = true;
            clearIconSelection();
            mode = .idle;
        } else if (!window_minimized and zoomButtonAt(x_px, y_px)) {
            toggleMac9Zoom();
            clearIconSelection();
            mode = .idle;
        } else if (!window_minimized and collapseButtonAt(x_px, y_px)) {
            window_shaded = !window_shaded;
            clearIconSelection();
            mode = .idle;
        } else if (!window_minimized and !window_shaded and resizeHandleAt(x_px, y_px)) {
            clearIconSelection();
            mode = .resizing_window;
            drag_dx = x_px - window_w;
            drag_dy = y_px - window_h;
            window_zoomed = false;
            window_drag_w = window_w;
            window_drag_h = window_h;
        } else if (!window_minimized and !window_shaded and handleMac9ScrollbarPress(x_px, y_px)) {
            clearIconSelection();
        } else if (!window_minimized and titlebarAt(x_px, y_px)) {
            clearIconSelection();
            mode = .dragging_window;
            drag_dx = x_px - window_x;
            drag_dy = y_px - window_y;
            window_zoomed = false;
            window_drag_x = window_x;
            window_drag_y = window_y;
        } else if (!window_minimized and windowAt(x_px, y_px)) {
            clearIconSelection();
            mode = .idle;
            if (!window_shaded and pointInRect(x_px, y_px, mac9ViewportRect())) {
                const row = @divFloor(y_px - mac9ViewportRect().y + scroll_y, ROW_H);
                list_selected = if (row >= 0 and row < LIST_ITEMS.len) row else -1;
            }
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
        return 1;
    }
    if (down) {
        switch (mode) {
            .dragging_window => {
                const active_window_h = currentWindowHeight();
                window_drag_x = clampI32(x_px - drag_dx, 4 - window_w + 40, SCREEN_W - 40);
                window_drag_y = clampI32(y_px - drag_dy, MENUBAR_H + 2, SCREEN_H - @min(active_window_h, TITLE_H + 8));
                return 1;
            },
            .resizing_window => {
                window_drag_w = clampI32(x_px - drag_dx, WINDOW_MIN_W, @min(WINDOW_MAX_W, SCREEN_W - window_x - 4));
                window_drag_h = clampI32(y_px - drag_dy, WINDOW_MIN_H, @min(WINDOW_MAX_H, SCREEN_H - window_y - 4));
                return 1;
            },
            .dragging_icon => {
                icon_drag_x = clampI32(x_px - drag_dx, 4, SCREEN_W - ICON_SIZE - 4);
                icon_drag_y = clampI32(y_px - drag_dy, MENUBAR_H + 4, SCREEN_H - ICON_SIZE - LABEL_H - 4);
                return 1;
            },
            .marquee_select => {
                marquee_x1 = clampI32(x_px, 0, SCREEN_W - 1);
                marquee_y1 = clampI32(y_px, MENUBAR_H, SCREEN_H - 1);
                return 1;
            },
            .dragging_scroll => |axis| {
                switch (axis) {
                    .vertical => previewMac9VScrollTo(y_px - scroll_drag_delta),
                    .horizontal => previewMac9HScrollTo(x_px - scroll_drag_delta),
                }
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
                setMac9ScrollX(scroll_x);
                setMac9ScrollY(scroll_y);
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
    if (desktop_menu_open and hoveredMenuItem() != prev_hover) return 1;
    return 0;
}

fn clearIconSelection() void {
    selected_icon = -1;
    selected_mask = 0;
}

fn closeMenus() void {
    menu_open = .none;
    menu_tracking = false;
    menu_sticky = false;
}

// Menus open on press, track while held and choose on release. Releasing over
// the title leaves the menu open until the next click, as in Mac OS 8 and 9.
fn menuPointer(down: bool, x: i32, y: i32, prev_hover: i32) i32 {
    needs_redraw = true;
    if (down and !primary_down) {
        primary_down = true;
        const bar = menuBarHit(x, y);
        if (bar != .none) {
            if (menu_sticky and bar == menu_open) {
                closeMenus();
                return 1;
            }
            menu_open = bar;
            menu_tracking = true;
            menu_sticky = false;
            return 1;
        }
        if (pointInRect(x, y, menuPanelRect(menu_open))) {
            menu_tracking = true;
            menu_sticky = false;
            return 1;
        }
        closeMenus();
        return 1;
    }
    if (down) {
        const bar = menuBarHit(x, y);
        if (bar != .none and bar != menu_open) {
            menu_open = bar;
            return 1;
        }
        return if (hoveredMenuItem() != prev_hover) 1 else 0;
    }
    if (primary_down) {
        primary_down = false;
        const item = menuItemAt(menu_open, x, y);
        if (item >= 0) {
            const action = menuItems(menu_open)[@intCast(item)].action;
            closeMenus();
            applyAction(action);
            return 1;
        }
        if (menuBarHit(x, y) == menu_open) {
            menu_sticky = true;
            menu_tracking = false;
            return 1;
        }
        closeMenus();
        return 1;
    }
    return if (hoveredMenuItem() != prev_hover) 1 else 0;
}

fn applyAction(action: Action) void {
    switch (action) {
        .none => {},
        .open_window => {
            window_minimized = false;
            window_shaded = false;
        },
        .close_window => window_minimized = true,
        .select_all => {
            selected_mask = (@as(u8, 1) << @as(u3, @intCast(icons.len))) - 1;
            selected_icon = 0;
        },
        .clear_selection => {
            clearIconSelection();
            list_selected = -1;
        },
        .clean_up => icons = DEFAULT_ICONS,
        .collapse_window => {
            if (!window_minimized) window_shaded = !window_shaded;
        },
    }
    mode = .idle;
    needs_redraw = true;
}

fn hoveredMenuItem() i32 {
    if (menu_open != .none) return menuItemAt(menu_open, pointer_x, pointer_y) + @as(i32, @intFromEnum(menu_open)) * 64;
    if (desktop_menu_open) return menuItemAt(.context, pointer_x, pointer_y);
    return -1;
}

// ---------------------------------------------------------------------------
// Menu geometry

fn menuTitleRect(menu: MenuId) Rect {
    var x: i32 = 6;
    for (BAR_MENUS) |id| {
        const w = if (id == .apple) @as(i32, 26) else textWidth(&BOLD, menuTitle(id)) + 12;
        if (id == menu) return .{ .x = x, .y = 1, .w = w, .h = MENUBAR_H - 2 };
        x += w;
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

fn menuBarHit(x: i32, y: i32) MenuId {
    if (y < 0 or y >= MENUBAR_H) return .none;
    for (BAR_MENUS) |id| {
        const r = menuTitleRect(id);
        if (x >= r.x and x < r.x + r.w) return id;
    }
    return .none;
}

fn menuItemHeight(item: MenuItem) i32 {
    return if (item.separator) 9 else 16;
}

fn menuPanelWidth(menu: MenuId) i32 {
    var w: i32 = 0;
    for (menuItems(menu)) |item| {
        if (item.separator) continue;
        var iw = 18 + textWidth(&BOLD, item.label) + 14;
        if (item.key != 0) iw += 10 + textWidth(&BOLD, "\x11") + 1 + glyphAdvance(&BOLD, item.key);
        w = @max(w, iw);
    }
    return w;
}

fn menuPanelHeight(menu: MenuId) i32 {
    var h: i32 = 8;
    for (menuItems(menu)) |item| h += menuItemHeight(item);
    return h;
}

fn menuPanelRect(menu: MenuId) Rect {
    const w = menuPanelWidth(menu);
    const h = menuPanelHeight(menu);
    if (menu == .context) return .{ .x = desktop_menu_x, .y = desktop_menu_y, .w = w, .h = h };
    const title = menuTitleRect(menu);
    return .{ .x = @min(title.x, SCREEN_W - w - 3), .y = MENU_TOP, .w = w, .h = h };
}

fn menuItemRect(menu: MenuId, index: usize) Rect {
    const panel = menuPanelRect(menu);
    var y = panel.y + 4;
    for (menuItems(menu), 0..) |item, i| {
        const h = menuItemHeight(item);
        if (i == index) return .{ .x = panel.x + 1, .y = y, .w = panel.w - 2, .h = h };
        y += h;
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

fn menuItemAt(menu: MenuId, x: i32, y: i32) i32 {
    if (menu == .none) return -1;
    if (!pointInRect(x, y, menuPanelRect(menu))) return -1;
    for (menuItems(menu), 0..) |item, i| {
        if (!pointInRect(x, y, menuItemRect(menu, i))) continue;
        if (item.separator or !item.enabled) return -1;
        return @intCast(i);
    }
    return -1;
}

fn openDesktopMenu(x: i32, y: i32) void {
    desktop_menu_open = true;
    desktop_menu_x = clampI32(x, 2, SCREEN_W - menuPanelWidth(.context) - 4);
    desktop_menu_y = clampI32(y, MENUBAR_H + 1, SCREEN_H - menuPanelHeight(.context) - 4);
}

// ---------------------------------------------------------------------------
// Desktop geometry

fn windowAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + currentWindowHeight();
}

fn desktopSurfaceAt(x: i32, y: i32) bool {
    if (y < MENUBAR_H) return false;
    if (!window_minimized and windowAt(x, y)) return false;
    return true;
}

fn iconLabelRect(icon: Icon) Rect {
    const w = textWidth(&SMALL, icon.label) + 5;
    const x = clampI32(icon.x + @divFloor(ICON_SIZE - w, 2), 1, SCREEN_W - w - 1);
    return .{ .x = x, .y = icon.y + ICON_SIZE + 1, .w = w, .h = LABEL_H };
}

fn iconImageRect(icon: Icon) Rect {
    return .{ .x = icon.x, .y = icon.y, .w = ICON_SIZE, .h = ICON_SIZE };
}

fn applyMarqueeSelection() void {
    const x0 = @min(marquee_x0, marquee_x1);
    const y0 = @min(marquee_y0, marquee_y1);
    const x1 = @max(marquee_x0, marquee_x1);
    const y1 = @max(marquee_y0, marquee_y1);
    const box = Rect{ .x = x0, .y = y0, .w = x1 - x0 + 1, .h = y1 - y0 + 1 };
    var mask: u8 = 0;
    for (icons, 0..) |icon, i| {
        if (rectsOverlap(box, iconImageRect(icon)) or rectsOverlap(box, iconLabelRect(icon))) {
            mask |= @as(u8, 1) << @as(u3, @intCast(i));
        }
    }
    selected_mask = mask;
    selected_icon = firstSelectedIcon(mask);
}

fn firstSelectedIcon(mask: u8) i32 {
    for (icons, 0..) |_, i| {
        if ((mask & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) return @as(i32, @intCast(i));
    }
    return -1;
}

fn rectsOverlap(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

fn iconAt(x: i32, y: i32) i32 {
    var i = icons.len;
    while (i > 0) {
        i -= 1;
        const icon = icons[i];
        if (pointInRect(x, y, iconImageRect(icon)) or pointInRect(x, y, iconLabelRect(icon))) return @as(i32, @intCast(i));
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Window geometry

fn titlebarAt(x: i32, y: i32) bool {
    return x >= window_x and x < window_x + window_w and y >= window_y and y < window_y + WINDOW_SHADED_H;
}

const Mac9CaptionButton = enum(u8) { close, collapse, zoom };

fn mac9CaptionButtonRect(which: Mac9CaptionButton) Rect {
    const size: i32 = 11;
    const btn_y = window_y + 4;
    const zoom_x = window_x + window_w - size - 10;
    return switch (which) {
        .close => .{ .x = window_x + 10, .y = btn_y, .w = size, .h = size },
        .zoom => .{ .x = zoom_x, .y = btn_y, .w = size, .h = size },
        .collapse => .{ .x = zoom_x - size - 5, .y = btn_y, .w = size, .h = size },
    };
}

fn closeButtonAt(x: i32, y: i32) bool {
    return pointInRect(x, y, mac9CaptionButtonRect(.close));
}

fn collapseButtonAt(x: i32, y: i32) bool {
    return pointInRect(x, y, mac9CaptionButtonRect(.collapse));
}

fn zoomButtonAt(x: i32, y: i32) bool {
    return pointInRect(x, y, mac9CaptionButtonRect(.zoom));
}

fn toggleMac9Zoom() void {
    if (window_zoomed) {
        window_x = window_restore_x;
        window_y = window_restore_y;
        window_w = window_restore_w;
        window_h = window_restore_h;
    } else {
        window_restore_x = window_x;
        window_restore_y = window_y;
        window_restore_w = window_w;
        window_restore_h = window_h;
        // Like the Finder, zoom to fit the list's contents rather than the screen.
        window_shaded = false;
        window_w = @min(WINDOW_MAX_W, SCROLL_CONTENT_W + FRAME * 2 + SCROLLBAR_SIZE);
        window_h = @min(WINDOW_MAX_H, TITLE_H + INFO_H + COLHDR_H + SCROLL_CONTENT_H + SCROLLBAR_SIZE + FRAME);
        window_x = clampI32(window_x, 8, SCREEN_W - window_w - 8);
        window_y = clampI32(window_y, MENUBAR_H + 3, SCREEN_H - window_h - 4);
    }
    window_zoomed = !window_zoomed;
    window_drag_x = window_x;
    window_drag_y = window_y;
    window_drag_w = window_w;
    window_drag_h = window_h;
    setMac9ScrollX(scroll_x);
    setMac9ScrollY(scroll_y);
}

fn mac9ClientRect() Rect {
    return .{
        .x = window_x + FRAME,
        .y = window_y + TITLE_H + INFO_H,
        .w = window_w - FRAME * 2,
        .h = window_h - TITLE_H - INFO_H - FRAME,
    };
}

fn mac9GrowRect() Rect {
    const c = mac9ClientRect();
    return .{ .x = c.x + c.w - SCROLLBAR_SIZE, .y = c.y + c.h - SCROLLBAR_SIZE, .w = SCROLLBAR_SIZE, .h = SCROLLBAR_SIZE };
}

fn resizeHandleAt(x: i32, y: i32) bool {
    return pointInRect(x, y, mac9GrowRect());
}

fn mac9HeaderRect() Rect {
    const c = mac9ClientRect();
    return .{ .x = c.x, .y = c.y, .w = c.w - SCROLLBAR_SIZE, .h = COLHDR_H };
}

fn mac9ViewportRect() Rect {
    const c = mac9ClientRect();
    return .{ .x = c.x, .y = c.y + COLHDR_H, .w = c.w - SCROLLBAR_SIZE, .h = c.h - COLHDR_H - SCROLLBAR_SIZE };
}

fn mac9MaxScrollX() i32 {
    return @max(0, SCROLL_CONTENT_W - mac9ViewportRect().w);
}

fn mac9MaxScrollY() i32 {
    return @max(0, SCROLL_CONTENT_H - mac9ViewportRect().h);
}

fn setMac9ScrollX(v: i32) void {
    scroll_x = clampI32(v, 0, mac9MaxScrollX());
}

fn setMac9ScrollY(v: i32) void {
    scroll_y = clampI32(v, 0, mac9MaxScrollY());
}

// Scroll bars overlap their neighbours by one pixel so borders are shared.
fn mac9VScrollRect() Rect {
    const c = mac9ClientRect();
    const grow = mac9GrowRect();
    const y = c.y + COLHDR_H - 1;
    return .{ .x = grow.x, .y = y, .w = SCROLLBAR_SIZE, .h = grow.y - y + 1 };
}

fn mac9HScrollRect() Rect {
    const c = mac9ClientRect();
    const grow = mac9GrowRect();
    const x = c.x - 1;
    return .{ .x = x, .y = grow.y, .w = grow.x - x + 1, .h = SCROLLBAR_SIZE };
}

fn mac9VThumbSpan() [2]i32 {
    const track = mac9VScrollRect();
    return .{ track.y + SCROLLBAR_SIZE - 1, track.y + track.h - SCROLLBAR_SIZE * 2 + 1 };
}

fn mac9HThumbSpan() [2]i32 {
    const track = mac9HScrollRect();
    return .{ track.x + SCROLLBAR_SIZE - 1, track.x + track.w - SCROLLBAR_SIZE * 2 + 1 };
}

fn mac9VThumbRect() Rect {
    const track = mac9VScrollRect();
    const span = mac9VThumbSpan();
    const range = @max(1, span[1] - span[0]);
    const t = @divTrunc(scroll_y * range, @max(1, mac9MaxScrollY()));
    return .{ .x = track.x, .y = span[0] + t, .w = SCROLLBAR_SIZE, .h = SCROLLBAR_SIZE };
}

fn mac9HThumbRect() Rect {
    const track = mac9HScrollRect();
    const span = mac9HThumbSpan();
    const range = @max(1, span[1] - span[0]);
    const t = @divTrunc(scroll_x * range, @max(1, mac9MaxScrollX()));
    return .{ .x = span[0] + t, .y = track.y, .w = SCROLLBAR_SIZE, .h = SCROLLBAR_SIZE };
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn previewMac9VScrollTo(thumb_y: i32) void {
    const span = mac9VThumbSpan();
    scroll_drag_thumb_pos = clampI32(thumb_y, span[0], span[1]);
}

fn commitMac9VScrollTo(thumb_y: i32) void {
    const span = mac9VThumbSpan();
    const clamped = clampI32(thumb_y, span[0], span[1]);
    setMac9ScrollY(@divTrunc((clamped - span[0]) * mac9MaxScrollY(), @max(1, span[1] - span[0])));
}

fn previewMac9HScrollTo(thumb_x: i32) void {
    const span = mac9HThumbSpan();
    scroll_drag_thumb_pos = clampI32(thumb_x, span[0], span[1]);
}

fn commitMac9HScrollTo(thumb_x: i32) void {
    const span = mac9HThumbSpan();
    const clamped = clampI32(thumb_x, span[0], span[1]);
    setMac9ScrollX(@divTrunc((clamped - span[0]) * mac9MaxScrollX(), @max(1, span[1] - span[0])));
}

fn handleMac9ScrollbarPress(x: i32, y: i32) bool {
    const vbar = mac9VScrollRect();
    const hbar = mac9HScrollRect();
    const page_y = @max(ROW_H, mac9ViewportRect().h - ROW_H);
    const page_x = @max(ROW_H, mac9ViewportRect().w - ROW_H);

    if (mac9MaxScrollY() > 0 and pointInRect(x, y, mac9VThumbRect())) {
        const thumb = mac9VThumbRect();
        mode = .{ .dragging_scroll = .vertical };
        scroll_drag_delta = y - thumb.y;
        scroll_drag_thumb_pos = thumb.y;
        return true;
    }
    if (mac9MaxScrollX() > 0 and pointInRect(x, y, mac9HThumbRect())) {
        const thumb = mac9HThumbRect();
        mode = .{ .dragging_scroll = .horizontal };
        scroll_drag_delta = x - thumb.x;
        scroll_drag_thumb_pos = thumb.x;
        return true;
    }
    if (pointInRect(x, y, vbar)) {
        const thumb = mac9VThumbRect();
        if (y < vbar.y + SCROLLBAR_SIZE) setMac9ScrollY(scroll_y - ROW_H) else if (y >= vbar.y + vbar.h - SCROLLBAR_SIZE) setMac9ScrollY(scroll_y + ROW_H) else if (y < thumb.y) setMac9ScrollY(scroll_y - page_y) else if (y >= thumb.y + thumb.h) setMac9ScrollY(scroll_y + page_y);
        mode = .idle;
        return true;
    }
    if (pointInRect(x, y, hbar)) {
        const thumb = mac9HThumbRect();
        if (x < hbar.x + SCROLLBAR_SIZE) setMac9ScrollX(scroll_x - ROW_H) else if (x >= hbar.x + hbar.w - SCROLLBAR_SIZE) setMac9ScrollX(scroll_x + ROW_H) else if (x < thumb.x) setMac9ScrollX(scroll_x - page_x) else if (x >= thumb.x + thumb.w) setMac9ScrollX(scroll_x + page_x);
        mode = .idle;
        return true;
    }
    return false;
}

fn currentWindowHeight() i32 {
    return if (window_shaded) WINDOW_SHADED_H else window_h;
}

// ---------------------------------------------------------------------------
// Frame

fn drawFrame() void {
    resetClip();
    drawDesktopPattern();
    for (icons, 0..) |_, i| drawDesktopIcon(i);
    if (!window_minimized) drawWindow();
    drawTrails();
    drawMenuBar();
    if (menu_open != .none) drawMenuPanel(menu_open);
    if (desktop_menu_open) drawMenuPanel(.context);
    drawScreenCorners();
}

fn drawDesktopPattern() void {
    // A fine, tiled texture in the spirit of the default Mac OS 9 desktop.
    var y: usize = 0;
    while (y < RENDER_H) : (y += 1) {
        var x: usize = 0;
        while (x < RENDER_W) : (x += 1) {
            const h = hash32(@intCast((x & 31) | ((y & 31) << 5)));
            const n: i32 = @as(i32, @intCast(h % 9)) - 4;
            const tint: i32 = @as(i32, @intCast((h >> 8) % 3)) - 1;
            setPixel(x, y, .{
                addU8(C_DESK[0], n + tint),
                addU8(C_DESK[1], n),
                addU8(C_DESK[2], n * 2 - tint),
                0xFF,
            });
        }
    }
}

fn hash32(v: u32) u32 {
    var x = v *% 0x9E3779B1;
    x ^= x >> 15;
    x *%= 0x85EBCA77;
    x ^= x >> 13;
    x *%= 0xC2B2AE3D;
    x ^= x >> 16;
    return x;
}

fn addU8(v: u8, d: i32) u8 {
    return @intCast(clampI32(@as(i32, v) + d, 0, 255));
}

fn drawScreenCorners() void {
    // Classic Mac OS rounds the corners of the main screen.
    const runs = [_]i32{ 4, 2, 1, 1 };
    for (runs, 0..) |n, i| {
        const r: i32 = @intCast(i);
        fillRectI32(0, r, n, 1, C_BLACK);
        fillRectI32(SCREEN_W - n, r, n, 1, C_BLACK);
        fillRectI32(0, SCREEN_H - 1 - r, n, 1, C_BLACK);
        fillRectI32(SCREEN_W - n, SCREEN_H - 1 - r, n, 1, C_BLACK);
    }
}

// ---------------------------------------------------------------------------
// Menu bar and menus

fn drawMenuBar() void {
    fillRectI32(0, 0, SCREEN_W, MENUBAR_H - 1, C_G2);
    fillRectI32(0, 0, SCREEN_W, 1, C_WHITE);
    fillRectI32(0, MENUBAR_H - 2, SCREEN_W, 1, C_G5);
    fillRectI32(0, MENUBAR_H - 1, SCREEN_W, 1, C_BLACK);

    for (BAR_MENUS) |id| {
        const r = menuTitleRect(id);
        const open = menu_open == id;
        if (open) fillRectI32(r.x, r.y - 1, r.w, r.h + 1, C_MENU_HILITE);
        if (id == .apple) {
            drawSprite(&SPR_APPLE, r.x + 8, 3, .normal);
        } else {
            _ = drawText(&BOLD, r.x + 6, 5, menuTitle(id), if (open) C_WHITE else C_BLACK);
        }
    }

    // The application menu and the clock.
    const app_x = appMenuX();
    fillRectI32(app_x, 2, 1, MENUBAR_H - 5, C_G6);
    fillRectI32(app_x + 1, 2, 1, MENUBAR_H - 5, C_WHITE);
    drawFinderFace(app_x + 8, 2);
    _ = drawText(&BOLD, app_x + 8 + 16 + 5, 5, APP_NAME, C_BLACK);
    _ = drawText(&BOLD, clockX(), 5, CLOCK_TEXT, C_BLACK);
}

const CLOCK_TEXT = "11:45 AM";
const APP_NAME = "Finder";

fn appMenuX() i32 {
    return SCREEN_W - 8 - 16 - 5 - textWidth(&BOLD, APP_NAME) - 12;
}

fn clockX() i32 {
    return appMenuX() - 9 - textWidth(&BOLD, CLOCK_TEXT);
}

fn drawMenuPanel(menu: MenuId) void {
    const p = menuPanelRect(menu);
    blendRect(p.x + 2, p.y + p.h, p.w, 1, C_BLACK, 90);
    blendRect(p.x + p.w, p.y + 2, 1, p.h - 1, C_BLACK, 90);
    blendRect(p.x + 3, p.y + p.h + 1, p.w, 1, C_BLACK, 40);
    blendRect(p.x + p.w + 1, p.y + 3, 1, p.h - 1, C_BLACK, 40);
    fillRectI32(p.x, p.y, p.w, p.h, C_G1);
    drawRect(p.x, p.y, p.w, p.h, C_BLACK);

    const hover = menuItemAt(menu, pointer_x, pointer_y);
    for (menuItems(menu), 0..) |item, i| {
        const r = menuItemRect(menu, i);
        if (item.separator) {
            fillRectI32(r.x + 1, r.y + 4, r.w - 2, 1, C_G6);
            fillRectI32(r.x + 1, r.y + 5, r.w - 2, 1, C_WHITE);
            continue;
        }
        const hot = hover == @as(i32, @intCast(i)) and (menu_tracking or menu_sticky or menu == .context);
        if (hot) fillRectI32(r.x, r.y, r.w, r.h, C_MENU_HILITE);
        const fg = if (hot) C_WHITE else if (item.enabled) C_BLACK else C_G6;
        if (item.checked) _ = drawText(&BOLD, r.x + 4, r.y + 4, "\x12", fg);
        _ = drawText(&BOLD, r.x + 17, r.y + 4, item.label, fg);
        if (item.key != 0) {
            const key = [1]u8{item.key};
            const kx = r.x + r.w - 9 - glyphAdvance(&BOLD, item.key) - textWidth(&BOLD, "\x11");
            _ = drawText(&BOLD, kx, r.y + 4, "\x11", fg);
            _ = drawText(&BOLD, kx + textWidth(&BOLD, "\x11") + 2, r.y + 4, &key, fg);
        }
    }
}

fn drawFinderFace(x: i32, y: i32) void {
    // The two-tone Finder face: dark blue profile on the left, light blue on the right.
    const dark = rgb(0x33, 0x55, 0xCC);
    const light = rgb(0x99, 0xCC, 0xFF);
    var row: i32 = 1;
    while (row < 15) : (row += 1) {
        // The divide wobbles to suggest a nose and lips.
        const divide: i32 = switch (row) {
            5, 6 => 7,
            7 => 6,
            8 => 5,
            9 => 6,
            else => 8,
        };
        fillRectI32(x + 1, y + row, divide - 1, 1, dark);
        fillRectI32(x + divide, y + row, 15 - divide, 1, light);
    }
    drawRect(x, y, 16, 16, C_BLACK);
    fillRectI32(x + 4, y + 4, 1, 3, C_BLACK);
    fillRectI32(x + 11, y + 4, 1, 3, C_BLACK);
    fillRectI32(x + 4, y + 10, 1, 1, C_BLACK);
    fillRectI32(x + 5, y + 11, 6, 1, C_BLACK);
    fillRectI32(x + 11, y + 10, 1, 1, C_BLACK);
    fillRectI32(x + 8, y + 1, 1, 4, C_BLACK);
}

// ---------------------------------------------------------------------------
// Desktop icons

fn iconSelected(i: usize) bool {
    return ((selected_mask & (@as(u8, 1) << @as(u3, @intCast(i)))) != 0) or selected_icon == @as(i32, @intCast(i));
}

fn drawDesktopIcon(i: usize) void {
    const icon = icons[i];
    const selected = iconSelected(i);
    drawIconImage(icon.kind, icon.x, icon.y, if (selected) .selected else .normal);
    const label = iconLabelRect(icon);
    fillRectI32(label.x, label.y, label.w, label.h, if (selected) C_BLACK else C_WHITE);
    _ = drawText(&SMALL, label.x + 3, label.y + 1, icon.label, if (selected) C_WHITE else C_BLACK);
}

fn drawIconImage(kind: IconKind, x: i32, y: i32, tint: Tint) void {
    switch (kind) {
        .drive => drawSprite(&SPR_HD, x, y, tint),
        .folder => drawSprite(&SPR_FOLDER, x, y, tint),
        .trash => drawSprite(&SPR_TRASH, x, y, tint),
        .document => drawSprite(&SPR_DOC, x, y, tint),
        .app => {
            drawSprite(&SPR_PAGE, x, y, tint);
            drawPencil(x + 26, y + 5, 17, 2, tint);
        },
    }
}

// A 45-degree pencil running down and to the left from (x, y).
fn drawPencil(x: i32, y: i32, len: i32, half: i32, tint: Tint) void {
    const eraser = rgb(0xEE, 0x88, 0x99);
    const ferrule = rgb(0xAA, 0xAA, 0xBB);
    const body_hi = rgb(0xFF, 0xE0, 0x66);
    const body = rgb(0xF0, 0xB8, 0x10);
    const body_lo = rgb(0xB8, 0x80, 0x00);
    const wood = rgb(0xF2, 0xD2, 0xA0);
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const cx = x - i;
        const cy = y + i;
        const tip = len - i;
        var shrink: i32 = 0;
        if (tip <= half + 2) shrink = half + 2 - tip;
        var d: i32 = -half + shrink;
        while (d <= half - shrink) : (d += 1) {
            const edge = d == -half + shrink or d == half - shrink;
            var c = body;
            if (i < 3) c = eraser else if (i == 3) c = ferrule else if (tip <= 2) c = C_G9 else if (tip <= half + 3) c = wood else if (d < 0) c = body_hi else if (d > 0) c = body_lo;
            if (edge and tip > 2) c = C_BLACK;
            plot(cx + d, cy, c, tint);
        }
    }
    var d: i32 = -half;
    while (d <= half) : (d += 1) plot(x + d + 1, y - 1, C_BLACK, tint);
}

// ---------------------------------------------------------------------------
// Window

fn drawWindow() void {
    const x = window_x;
    const y = window_y;
    const w = window_w;
    const h = currentWindowHeight();

    blendRect(x + w, y + 3, 2, h - 1, C_BLACK, 60);
    blendRect(x + 3, y + h, w - 1, 2, C_BLACK, 60);

    fillRectI32(x, y, w, h, C_G2);
    drawRect(x, y, w, h, C_BLACK);
    fillRectI32(x + 1, y + 1, w - 2, 1, C_WHITE);
    fillRectI32(x + 1, y + 1, 1, h - 2, C_WHITE);
    fillRectI32(x + w - 2, y + 2, 1, h - 3, C_G6);
    fillRectI32(x + 2, y + h - 2, w - 3, 1, C_G6);

    drawTitleBar(x, y, w);
    if (window_shaded) return;

    fillRectI32(x + 2, y + TITLE_H - 1, w - 4, 1, C_G6);
    fillRectI32(x + 2, y + TITLE_H, w - 4, 1, C_WHITE);
    const info_w = textWidth(&SMALL, LIST_INFO);
    const info_clip = Rect{ .x = x + FRAME, .y = y + TITLE_H, .w = w - FRAME * 2, .h = INFO_H };
    const saved = pushClip(info_clip);
    _ = drawText(&SMALL, x + @divFloor(w - info_w, 2), y + TITLE_H + 3, LIST_INFO, C_BLACK);
    popClip(saved);

    const c = mac9ClientRect();
    drawRect(c.x - 1, c.y - 1, c.w + 2, c.h + 2, C_G8);
    drawListView(c);
    drawMac9Scrollbars();
}

fn drawTitleBar(x: i32, y: i32, w: i32) void {
    const close = mac9CaptionButtonRect(.close);
    const collapse = mac9CaptionButtonRect(.collapse);
    const zoom = mac9CaptionButtonRect(.zoom);

    const title = "Macintosh HD";
    const group_w = 16 + 4 + textWidth(&BOLD, title);
    const left_limit = close.x + close.w + 8;
    const right_limit = collapse.x - 8;
    var gx = x + @divFloor(w - group_w, 2);
    gx = clampI32(gx, left_limit, @max(left_limit, right_limit - group_w));

    drawTitleRidges(x + 4, close.x - 4, y);
    drawTitleRidges(close.x + close.w + 3, gx - 6, y);
    drawTitleRidges(gx + group_w + 6, collapse.x - 4, y);
    drawTitleRidges(zoom.x + zoom.w + 3, x + w - 5, y);

    drawMac9CaptionButton(close, .close);
    drawMac9CaptionButton(collapse, .collapse);
    drawMac9CaptionButton(zoom, .zoom);

    const saved = pushClip(.{ .x = left_limit - 4, .y = y, .w = right_limit - left_limit + 8, .h = TITLE_H });
    drawSprite(&SPR_SMALL_HD, gx, y + 2, .normal);
    _ = drawText(&BOLD, gx + 20, y + 5, title, C_BLACK);
    popClip(saved);
}

fn drawTitleRidges(x0: i32, x1: i32, y: i32) void {
    if (x1 <= x0) return;
    var row: i32 = 0;
    while (row < 6) : (row += 1) {
        const ry = y + 4 + row * 2;
        fillRectI32(x0, ry, x1 - x0 + 1, 1, C_WHITE);
        fillRectI32(x0 + 1, ry + 1, x1 - x0 + 1, 1, C_G6);
    }
}

fn drawMac9CaptionButton(r: Rect, which: Mac9CaptionButton) void {
    // Recessed well around the box.
    fillRectI32(r.x - 1, r.y - 1, r.w + 2, 1, C_G6);
    fillRectI32(r.x - 1, r.y - 1, 1, r.h + 2, C_G6);
    fillRectI32(r.x - 1, r.y + r.h, r.w + 2, 1, C_WHITE);
    fillRectI32(r.x + r.w, r.y - 1, 1, r.h + 2, C_WHITE);
    drawRect(r.x, r.y, r.w, r.h, C_BLACK);
    var j: i32 = 1;
    while (j < r.h - 1) : (j += 1) {
        var i: i32 = 1;
        while (i < r.w - 1) : (i += 1) {
            const t = i + j; // 2 .. 18
            const v: u8 = @intCast(clampI32(0xFF - (t - 2) * 6, 0x99, 0xFF));
            setPixelI32(r.x + i, r.y + j, .{ v, v, v, 0xFF });
        }
    }
    fillRectI32(r.x + 1, r.y + 1, r.w - 2, 1, C_WHITE);
    fillRectI32(r.x + 1, r.y + 1, 1, r.h - 2, C_WHITE);
    switch (which) {
        .close => {},
        .collapse => {
            fillRectI32(r.x + 1, r.y + 5, r.w - 2, 1, C_BLACK);
        },
        .zoom => {
            if (window_zoomed) {
                drawRect(r.x + 2, r.y + 2, 4, 4, C_BLACK);
            } else {
                drawRect(r.x + 2, r.y + 2, 5, 5, C_BLACK);
            }
        },
    }
}

fn drawListView(c: Rect) void {
    const list = mac9ViewportRect();
    const hdr = mac9HeaderRect();
    const sx = @min(scroll_x, mac9MaxScrollX());
    const sy = @min(scroll_y, mac9MaxScrollY());
    const ox = list.x - sx;

    // Rows
    var saved = pushClip(list);
    fillRectI32(list.x, list.y, list.w, list.h, C_WHITE);
    fillRectI32(ox + COLUMNS[0].x, list.y, COLUMNS[0].w, list.h, C_G1);
    for (LIST_ITEMS, 0..) |item, idx| {
        const i: i32 = @intCast(idx);
        const ry = list.y + i * ROW_H - sy;
        if (ry + ROW_H <= list.y or ry >= list.y + list.h) continue;
        const selected = list_selected == i;
        if (selected) fillRectI32(list.x, ry, list.w, ROW_H, C_ACC_PALE);
        if (item.kind == .folder) drawDisclosure(ox + 5, ry + 4);
        drawSmallIcon(item.kind, ox + 15, ry, if (selected) .selected else .normal);
        drawCell(list, ox, COLUMNS[0], ry, item.name, NAME_TEXT_X);
        drawCell(list, ox, COLUMNS[1], ry, item.date, 6);
        drawCell(list, ox, COLUMNS[2], ry, item.size, 0);
        drawCell(list, ox, COLUMNS[3], ry, item.type, 8);
    }
    popClip(saved);

    // Column headers
    saved = pushClip(hdr);
    fillRectI32(hdr.x, hdr.y, hdr.w, hdr.h, C_G2);
    for (COLUMNS, 0..) |col, i| {
        const cx = ox + col.x;
        const sorted = i == 0;
        fillRectI32(cx, hdr.y, col.w, hdr.h - 1, if (sorted) C_G4 else C_G2);
        fillRectI32(cx, hdr.y, col.w, 1, C_WHITE);
        fillRectI32(cx, hdr.y, 1, hdr.h - 1, C_WHITE);
        fillRectI32(cx + col.w - 1, hdr.y, 1, hdr.h - 1, C_G7);
        const tx = if (col.right) cx + col.w - 6 - textWidth(&SMALL, col.title) else cx + @as(i32, if (i == 0) NAME_TEXT_X else if (i == 3) 8 else 6);
        _ = drawText(&SMALL, tx, hdr.y + 4, col.title, C_BLACK);
    }
    fillRectI32(hdr.x, hdr.y + hdr.h - 1, hdr.w, 1, C_BLACK);
    popClip(saved);

    // Sort direction button above the vertical scroll bar.
    const sb = Rect{ .x = c.x + c.w - SCROLLBAR_SIZE, .y = c.y, .w = SCROLLBAR_SIZE, .h = COLHDR_H };
    fillRectI32(sb.x, sb.y, sb.w, sb.h, C_G2);
    fillRectI32(sb.x, sb.y, 1, sb.h, C_BLACK);
    fillRectI32(sb.x + 1, sb.y, sb.w - 1, 1, C_WHITE);
    fillRectI32(sb.x + 1, sb.y, 1, sb.h - 1, C_WHITE);
    fillRectI32(sb.x, sb.y + sb.h - 1, sb.w, 1, C_BLACK);
    // Sort direction: stacked lines narrowing towards the top.
    var r: i32 = 0;
    while (r < 4) : (r += 1) fillRectI32(sb.x + 8 - r - 1, sb.y + 3 + r * 2, r * 2 + 3, 1, C_BLACK);
}

fn drawCell(list: Rect, ox: i32, col: Column, ry: i32, text: []const u8, pad: i32) void {
    const cell = intersect(list, .{ .x = ox + col.x, .y = ry, .w = col.w - 4, .h = ROW_H });
    if (cell.w <= 0 or cell.h <= 0) return;
    const saved = pushClip(cell);
    const tx = if (col.right) ox + col.x + col.w - 6 - textWidth(&SMALL, text) else ox + col.x + pad;
    _ = drawText(&SMALL, tx, ry + 4, text, C_BLACK);
    popClip(saved);
}

fn drawDisclosure(x: i32, y: i32) void {
    // Right-pointing Platinum disclosure triangle.
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        fillRectI32(x, y + i, i + 1, 1, C_G9);
        fillRectI32(x, y + 6 - i, i + 1, 1, C_G9);
    }
    fillRectI32(x, y, 1, 7, C_BLACK);
    var j: i32 = 0;
    while (j < 4) : (j += 1) {
        setPixelI32(x + j, y + j, C_BLACK);
        setPixelI32(x + j, y + 6 - j, C_BLACK);
    }
}

fn drawSmallIcon(kind: ListKind, x: i32, y: i32, tint: Tint) void {
    switch (kind) {
        .folder => drawSprite(&SPR_SMALL_FOLDER, x, y, tint),
        .document => drawSprite(&SPR_SMALL_DOC, x, y, tint),
        .app => {
            drawSprite(&SPR_SMALL_PAGE, x, y, tint);
            drawPencil(x + 13, y + 3, 9, 1, tint);
        },
    }
}

fn drawMac9Scrollbars() void {
    const vbar = mac9VScrollRect();
    const hbar = mac9HScrollRect();
    drawScrollTrack(vbar, .vertical, mac9MaxScrollY() > 0);
    drawScrollTrack(hbar, .horizontal, mac9MaxScrollX() > 0);
    if (mac9MaxScrollY() > 0) drawScrollThumb(mac9VThumbRect(), .vertical);
    if (mac9MaxScrollX() > 0) drawScrollThumb(mac9HThumbRect(), .horizontal);
    drawGrowBox(mac9GrowRect());
}

fn drawScrollTrack(r: Rect, axis: ScrollAxis, active: bool) void {
    fillRectI32(r.x, r.y, r.w, r.h, if (active) C_G5 else C_G1);
    if (active) {
        // Inner shadow along the leading edges of the trough.
        if (axis == .vertical) {
            fillRectI32(r.x + 1, r.y + 1, 1, r.h - 2, C_G7);
            fillRectI32(r.x + 2, r.y + 1, 1, r.h - 2, C_G6);
            fillRectI32(r.x + r.w - 2, r.y + 1, 1, r.h - 2, C_G4);
        } else {
            fillRectI32(r.x + 1, r.y + 1, r.w - 2, 1, C_G7);
            fillRectI32(r.x + 1, r.y + 2, r.w - 2, 1, C_G6);
            fillRectI32(r.x + 1, r.y + r.h - 2, r.w - 2, 1, C_G4);
        }
    }
    drawRect(r.x, r.y, r.w, r.h, C_BLACK);
    const sb = SCROLLBAR_SIZE;
    if (axis == .vertical) {
        drawArrowButton(.{ .x = r.x, .y = r.y, .w = sb, .h = sb }, .up, active);
        drawArrowButton(.{ .x = r.x, .y = r.y + r.h - sb, .w = sb, .h = sb }, .down, active);
    } else {
        drawArrowButton(.{ .x = r.x, .y = r.y, .w = sb, .h = sb }, .left, active);
        drawArrowButton(.{ .x = r.x + r.w - sb, .y = r.y, .w = sb, .h = sb }, .right, active);
    }
}

fn drawBevelBox(r: Rect, face: Color) void {
    fillRectI32(r.x, r.y, r.w, r.h, face);
    drawRect(r.x, r.y, r.w, r.h, C_BLACK);
    fillRectI32(r.x + 1, r.y + 1, r.w - 2, 1, C_WHITE);
    fillRectI32(r.x + 1, r.y + 1, 1, r.h - 2, C_WHITE);
    fillRectI32(r.x + 1, r.y + r.h - 2, r.w - 2, 1, C_G6);
    fillRectI32(r.x + r.w - 2, r.y + 1, 1, r.h - 2, C_G6);
    setPixelI32(r.x + 1, r.y + r.h - 2, face);
    setPixelI32(r.x + r.w - 2, r.y + 1, face);
}

fn drawArrowButton(r: Rect, dir: ScrollArrowDir, active: bool) void {
    drawBevelBox(r, C_G2);
    const c = if (active) C_BLACK else C_G6;
    const cx = r.x + 7;
    const cy = r.y + 7;
    var d: i32 = 0;
    while (d < 4) : (d += 1) {
        switch (dir) {
            .up => fillRectI32(cx - d, cy - 2 + d, d * 2 + 1, 1, c),
            .down => fillRectI32(cx - d, cy + 2 - d, d * 2 + 1, 1, c),
            .left => fillRectI32(cx - 2 + d, cy - d, 1, d * 2 + 1, c),
            .right => fillRectI32(cx + 2 - d, cy - d, 1, d * 2 + 1, c),
        }
    }
}

fn drawScrollThumb(r: Rect, axis: ScrollAxis) void {
    fillRectI32(r.x, r.y, r.w, r.h, C_ACC_LIGHT);
    drawRect(r.x, r.y, r.w, r.h, C_BLACK);
    fillRectI32(r.x + 1, r.y + 1, r.w - 2, 1, C_ACC_PALE);
    fillRectI32(r.x + 1, r.y + 1, 1, r.h - 2, C_ACC_PALE);
    fillRectI32(r.x + 1, r.y + r.h - 2, r.w - 2, 1, C_ACC_MID);
    fillRectI32(r.x + r.w - 2, r.y + 1, 1, r.h - 2, C_ACC_MID);
    // Grip ridges.
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const o = 4 + i * 2;
        if (axis == .vertical) {
            fillRectI32(r.x + 4, r.y + o, 7, 1, C_ACC_PALE);
            fillRectI32(r.x + 5, r.y + o + 1, 7, 1, C_ACC_DARK);
        } else {
            fillRectI32(r.x + o, r.y + 4, 1, 7, C_ACC_PALE);
            fillRectI32(r.x + o + 1, r.y + 5, 1, 7, C_ACC_DARK);
        }
    }
}

fn drawGrowBox(r: Rect) void {
    drawBevelBox(r, C_G2);
    // Three diagonal grip ridges in the lower-right corner.
    var k: i32 = 0;
    while (k < 3) : (k += 1) {
        const off = 4 + k * 3;
        var t: i32 = 0;
        while (t <= 12 - off) : (t += 1) {
            setPixelI32(r.x + off + t, r.y + 12 - t, C_WHITE);
            setPixelI32(r.x + off + t + 1, r.y + 12 - t, C_G7);
        }
    }
}

fn drawTrails() void {
    switch (mode) {
        .dragging_icon => |idx| {
            const icon = icons[idx];
            drawIconImage(icon.kind, icon_drag_x, icon_drag_y, .ghost);
            var ghost = icon;
            ghost.x = icon_drag_x;
            ghost.y = icon_drag_y;
            const label = iconLabelRect(ghost);
            blendRect(label.x, label.y, label.w, label.h, C_BLACK, 110);
            _ = drawText(&SMALL, label.x + 3, label.y + 1, icon.label, C_WHITE);
        },
        .dragging_window => {
            const h = currentWindowHeight();
            drawXorRect(window_drag_x, window_drag_y, window_w, h);
            if (h > TITLE_H) drawXorRect(window_drag_x, window_drag_y, window_w, TITLE_H);
        },
        .resizing_window => {
            drawXorRect(window_x, window_y, window_drag_w, window_drag_h);
            drawXorRect(window_x, window_y, window_drag_w, TITLE_H);
        },
        .marquee_select => {
            const x = @min(marquee_x0, marquee_x1);
            const y = @min(marquee_y0, marquee_y1);
            const w = @max(1, @max(marquee_x0, marquee_x1) - x + 1);
            const h = @max(1, @max(marquee_y0, marquee_y1) - y + 1);
            drawXorRect(x, y, w, h);
        },
        .dragging_scroll => |axis| {
            switch (axis) {
                .vertical => {
                    const thumb = mac9VThumbRect();
                    drawXorRect(thumb.x, scroll_drag_thumb_pos, thumb.w, thumb.h);
                },
                .horizontal => {
                    const thumb = mac9HThumbRect();
                    drawXorRect(scroll_drag_thumb_pos, thumb.y, thumb.w, thumb.h);
                },
            }
        },
        .idle => {},
    }
}

// The classic gray-pattern XOR outline used for drags and marquees.
fn drawXorRect(x: i32, y: i32, w: i32, h: i32) void {
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        invertDotted(x + i, y);
        if (h > 1) invertDotted(x + i, y + h - 1);
    }
    i = 1;
    while (i < h - 1) : (i += 1) {
        invertDotted(x, y + i);
        if (w > 1) invertDotted(x + w - 1, y + i);
    }
}

fn invertDotted(x: i32, y: i32) void {
    if (@mod(x + y, 2) != 0) return;
    if (!clipContains(x, y)) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    output_buf[idx + 0] = 0xFF - output_buf[idx + 0];
    output_buf[idx + 1] = 0xFF - output_buf[idx + 1];
    output_buf[idx + 2] = 0xFF - output_buf[idx + 2];
}

// ---------------------------------------------------------------------------
// Sprites

const Tint = enum(u8) { normal, selected, ghost };

fn spriteColor(ch: u8) ?Color {
    return switch (ch) {
        'k' => C_BLACK,
        'w' => C_WHITE,
        '1' => C_G1,
        '2' => C_G2,
        '3' => C_G3,
        '4' => C_G4,
        '5' => C_G5,
        '6' => C_G6,
        '7' => C_G7,
        '8' => C_G8,
        '9' => C_G9,
        'a' => C_ACC_PALE,
        'b' => C_ACC_LIGHT,
        'c' => C_ACC_MID,
        'd' => C_ACC_DARK,
        'g' => rgb(0x22, 0xCC, 0x33),
        // Six-stripe Apple logo colours.
        'G' => rgb(0x5E, 0xBD, 0x3E),
        'Y' => rgb(0xFF, 0xB9, 0x00),
        'O' => rgb(0xF7, 0x82, 0x00),
        'R' => rgb(0xE2, 0x38, 0x38),
        'P' => rgb(0x97, 0x39, 0x99),
        'B' => rgb(0x00, 0x9C, 0xDF),
        else => null,
    };
}

fn plot(x: i32, y: i32, c: Color, tint: Tint) void {
    switch (tint) {
        .normal => setPixelI32(x, y, c),
        .selected => setPixelI32(x, y, .{ c[0] / 2, c[1] / 2, c[2] / 2, 0xFF }),
        .ghost => blendPixel(x, y, c, 130),
    }
}

fn drawSprite(rows: []const []const u8, x: i32, y: i32, tint: Tint) void {
    for (rows, 0..) |row, j| {
        for (row, 0..) |ch, i| {
            const c = spriteColor(ch) orelse continue;
            plot(x + @as(i32, @intCast(i)), y + @as(i32, @intCast(j)), c, tint);
        }
    }
}

const SPR_APPLE = [_][]const u8{
    ".......GG..",
    "......GG...",
    "......G....",
    "..GGG.GGG..",
    ".GGGGGGGGG.",
    "YYYYYYYYY..",
    "YYYYYYYY...",
    "OOOOOOOO...",
    "RRRRRRRRR..",
    "PPPPPPPPPPP",
    ".PPPPPPPPP.",
    ".BBBBBBBBB.",
    "..BBB.BBB..",
};

const HD_FRONT = ".kw" ++ "3" ** 22 ++ "5k666k";
const SPR_HD = [_][]const u8{
    "",                                            "",                                            "", "", "", "", "", "", "",
    "....." ++ "k" ** 26,
    "....k" ++ "1" ** 24 ++ "kk",
    "...k" ++ "1" ** 24 ++ "k6k",
    "..k" ++ "1" ** 24 ++ "k66k",
    "." ++ "k" ** 26 ++ "666k",
    HD_FRONT,
    HD_FRONT,
    HD_FRONT,
    HD_FRONT,
    HD_FRONT,
    ".kw" ++ "3" ** 2 ++ "9" ** 12 ++ "3" ** 8 ++ "5k666k",
    ".kw" ++ "3" ** 2 ++ "w" ** 12 ++ "3" ** 8 ++ "5k666k",
    ".kw" ++ "3" ** 18 ++ "gg" ++ "3" ** 2 ++ "5k666k",
    HD_FRONT,
    ".kw" ++ "3" ** 22 ++ "5k66k",
    ".kw" ++ "3" ** 22 ++ "5k6k",
    ".k" ++ "5" ** 24 ++ "kk",
    "." ++ "k" ** 26,
};

const FOLDER_BODY = "k" ++ "a" ++ "b" ** 28 ++ "c" ++ "k";
const SPR_FOLDER = [_][]const u8{
    "",                         "", "", "", "", "", "",
    ".." ++ "k" ** 9,
    ".k" ++ "a" ** 9 ++ "k",
    "k" ++ "a" ** 11 ++ "k" ** 20,
    "k" ++ "a" ** 30 ++ "k",
    "k" ++ "b" ** 30 ++ "k",
    "k" ++ "d" ** 30 ++ "k",
    "k" ++ "a" ** 30 ++ "k",
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    FOLDER_BODY,
    "k" ++ "c" ** 30 ++ "k",
    "." ++ "k" ** 30,
};

const TRASH_BODY = "." ** 7 ++ "k" ++ "w" ++ "2w36" ** 3 ++ "2w3" ++ "k";
const TRASH_LOW = "." ** 8 ++ "k" ++ "w" ++ "2w36" ** 3 ++ "6" ++ "k";
const SPR_TRASH = [_][]const u8{
    "",                                       "", "", "",
    "." ** 12 ++ "k" ** 8,
    "." ** 12 ++ "k" ++ "." ** 6 ++ "k",
    "." ** 5 ++ "k" ** 22,
    "." ** 5 ++ "kw" ++ "2" ** 18 ++ "6k",
    "." ** 5 ++ "k" ++ "6" ** 20 ++ "k",
    "." ** 5 ++ "k" ** 22,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_BODY,
    TRASH_LOW,
    TRASH_LOW,
    TRASH_LOW,
    TRASH_LOW,
    "." ** 8 ++ "k" ** 16,
};

const DOC_BODY = "." ** 6 ++ "k" ++ "w" ** 19 ++ "k";
fn docLine(comptime n: usize) []const u8 {
    return "." ** 6 ++ "k" ++ "ww" ++ "6" ** n ++ "w" ** (17 - n) ++ "k";
}
const DOC_TOP = [_][]const u8{
    "",
    "",
    "." ** 6 ++ "k" ** 15,
    "." ** 6 ++ "k" ++ "w" ** 13 ++ "kk",
    "." ** 6 ++ "k" ++ "w" ** 13 ++ "k3k",
    "." ** 6 ++ "k" ++ "w" ** 13 ++ "k33k",
    "." ** 6 ++ "k" ++ "w" ** 13 ++ "k333k",
    "." ** 6 ++ "k" ++ "w" ** 13 ++ "k3333k",
    "." ** 6 ++ "k" ++ "w" ** 13 ++ "k" ** 7,
};
const SPR_DOC = DOC_TOP ++ [_][]const u8{
    DOC_BODY, DOC_BODY, docLine(15), DOC_BODY, docLine(15), DOC_BODY, docLine(12), DOC_BODY,  docLine(15), DOC_BODY,
    docLine(9), DOC_BODY, docLine(15), DOC_BODY, docLine(13), DOC_BODY, docLine(7), DOC_BODY, DOC_BODY,    DOC_BODY,
    "." ** 6 ++ "k" ** 21,
};
const SPR_PAGE = DOC_TOP ++ [_][]const u8{
    DOC_BODY, DOC_BODY, docLine(12), DOC_BODY, docLine(9), DOC_BODY, docLine(11), DOC_BODY, DOC_BODY, DOC_BODY,
    DOC_BODY, DOC_BODY, DOC_BODY,    DOC_BODY, DOC_BODY,   DOC_BODY, DOC_BODY,    DOC_BODY, DOC_BODY, DOC_BODY,
    "." ** 6 ++ "k" ** 21,
};

const SM_FOLDER_BODY = "k" ++ "a" ++ "b" ** 11 ++ "c" ++ "k";
const SPR_SMALL_FOLDER = [_][]const u8{
    "",
    "",
    "",
    ".kkkkk",
    "k" ++ "a" ** 5 ++ "k",
    "k" ++ "a" ** 6 ++ "k" ** 8,
    "k" ++ "a" ** 13 ++ "k",
    "k" ++ "d" ** 13 ++ "k",
    SM_FOLDER_BODY,
    SM_FOLDER_BODY,
    SM_FOLDER_BODY,
    SM_FOLDER_BODY,
    SM_FOLDER_BODY,
    "k" ++ "c" ** 13 ++ "k",
    "." ++ "k" ** 13,
};

const SM_DOC_BODY = "..k" ++ "w" ** 10 ++ "k";
const SM_DOC_TOP = [_][]const u8{
    "",
    ".." ++ "k" ** 8,
    "..k" ++ "w" ** 6 ++ "kk",
    "..k" ++ "w" ** 6 ++ "k3k",
    "..k" ++ "w" ** 6 ++ "k33k",
    "..k" ++ "w" ** 6 ++ "k" ** 5,
    SM_DOC_BODY,
};
const SPR_SMALL_DOC = SM_DOC_TOP ++ [_][]const u8{
    "..kw" ++ "6" ** 8 ++ "wk",
    SM_DOC_BODY,
    "..kw" ++ "6" ** 6 ++ "www" ++ "k",
    SM_DOC_BODY,
    "..kw" ++ "6" ** 8 ++ "wk",
    SM_DOC_BODY,
    SM_DOC_BODY,
    ".." ++ "k" ** 12,
};
const SPR_SMALL_PAGE = SM_DOC_TOP ++ [_][]const u8{
    SM_DOC_BODY, SM_DOC_BODY, SM_DOC_BODY, SM_DOC_BODY, SM_DOC_BODY, SM_DOC_BODY, SM_DOC_BODY,
    ".." ++ "k" ** 12,
};

const SPR_SMALL_HD = [_][]const u8{
    "",
    "",
    "",
    "....kkkkkkkkkkk",
    "...k" ++ "1" ** 10 ++ "k",
    "..k" ++ "1" ** 10 ++ "kk",
    ".kkkkkkkkkkkk6k",
    ".kw" ++ "3" ** 9 ++ "k6k",
    ".kw" ++ "6666333g3" ++ "k6k",
    ".kw" ++ "3" ** 9 ++ "kk",
    ".k" ++ "5" ** 10 ++ "k",
    ".kkkkkkkkkkkk",
};

// ---------------------------------------------------------------------------
// Bitmap fonts
//
// BOLD follows the 12-point system font of Mac OS 8 and 9: two-pixel stems,
// a nine-pixel cap height and proportional advances. SMALL follows the
// 9-point Finder font: one-pixel stems and a seven-pixel cap height.

const Glyph = struct {
    w: u8,
    rows: [11]u16,
};

const Font = struct {
    glyphs: [128]Glyph,
    space: i32,
};

const EMPTY_GLYPH = Glyph{ .w = 0, .rows = [_]u16{0} ** 11 };

fn makeGlyph(rows: []const []const u8) Glyph {
    var g = EMPTY_GLYPH;
    for (rows, 0..) |row, i| {
        if (row.len > g.w) g.w = @intCast(row.len);
        for (row, 0..) |ch, x| {
            if (ch == '#') g.rows[i] |= @as(u16, 1) << @intCast(x);
        }
    }
    return g;
}

fn buildGlyphs(comptime rowsFor: fn (u8) ?[]const []const u8) [128]Glyph {
    @setEvalBranchQuota(4_000_000);
    var t = [_]Glyph{EMPTY_GLYPH} ** 128;
    for (0..128) |i| {
        if (rowsFor(@intCast(i))) |rows| t[i] = makeGlyph(rows);
    }
    return t;
}

const BOLD = Font{ .glyphs = buildGlyphs(boldRows), .space = 4 };
const SMALL = Font{ .glyphs = buildGlyphs(smallRows), .space = 3 };

fn glyphAdvance(font: *const Font, ch: u8) i32 {
    if (ch == ' ') return font.space;
    const g = font.glyphs[ch & 0x7F];
    if (g.w == 0) return 6;
    return @as(i32, g.w) + 1;
}

fn textWidth(font: *const Font, text: []const u8) i32 {
    if (text.len == 0) return 0;
    var w: i32 = 0;
    for (text) |ch| w += glyphAdvance(font, ch);
    return w - 1;
}

fn drawText(font: *const Font, x: i32, y: i32, text: []const u8, c: Color) i32 {
    var cx = x;
    for (text) |ch| {
        if (ch != ' ') {
            const g = font.glyphs[ch & 0x7F];
            if (g.w == 0) {
                drawRect(cx, y + 1, 5, 7, c);
            } else {
                for (g.rows, 0..) |bits, ry| {
                    if (bits == 0) continue;
                    var rx: u5 = 0;
                    while (rx < g.w) : (rx += 1) {
                        if (((bits >> @intCast(rx)) & 1) != 0) setPixelI32(cx + rx, y + @as(i32, @intCast(ry)), c);
                    }
                }
            }
        }
        cx += glyphAdvance(font, ch);
    }
    return cx - x;
}

fn boldRows(c: u8) ?[]const []const u8 {
    return switch (c) {
        'A' => &.{ "..###..", ".##.##.", "##...##", "##...##", "##...##", "#######", "##...##", "##...##", "##...##" },
        'B' => &.{ "######.", "##...##", "##...##", "##...##", "######.", "##...##", "##...##", "##...##", "######." },
        'C' => &.{ ".#####.", "##...##", "##.....", "##.....", "##.....", "##.....", "##.....", "##...##", ".#####." },
        'D' => &.{ "######.", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "######." },
        'E' => &.{ "######", "##....", "##....", "##....", "#####.", "##....", "##....", "##....", "######" },
        'F' => &.{ "######", "##....", "##....", "##....", "#####.", "##....", "##....", "##....", "##...." },
        'G' => &.{ ".#####.", "##...##", "##.....", "##.....", "##.####", "##...##", "##...##", "##...##", ".#####." },
        'H' => &.{ "##...##", "##...##", "##...##", "##...##", "#######", "##...##", "##...##", "##...##", "##...##" },
        'I' => &.{ "##", "##", "##", "##", "##", "##", "##", "##", "##" },
        'J' => &.{ "....##", "....##", "....##", "....##", "....##", "....##", "##..##", "##..##", ".####." },
        'K' => &.{ "##...##", "##..##.", "##.##..", "####...", "###....", "####...", "##.##..", "##..##.", "##...##" },
        'L' => &.{ "##....", "##....", "##....", "##....", "##....", "##....", "##....", "##....", "######" },
        'M' => &.{ "##.....##", "###...###", "####.####", "##.###.##", "##..#..##", "##.....##", "##.....##", "##.....##", "##.....##" },
        'N' => &.{ "##...##", "###..##", "###..##", "####.##", "##.####", "##..###", "##..###", "##...##", "##...##" },
        'O' => &.{ ".#####.", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", ".#####." },
        'P' => &.{ "######.", "##...##", "##...##", "##...##", "######.", "##.....", "##.....", "##.....", "##....." },
        'Q' => &.{ ".#####.", "##...##", "##...##", "##...##", "##...##", "##...##", "##.#.##", "##..##.", ".###.##" },
        'R' => &.{ "######.", "##...##", "##...##", "##...##", "######.", "##.##..", "##..##.", "##...##", "##...##" },
        'S' => &.{ ".#####.", "##...##", "##.....", "###....", ".#####.", "....###", ".....##", "##...##", ".#####." },
        'T' => &.{ "######", "..##..", "..##..", "..##..", "..##..", "..##..", "..##..", "..##..", "..##.." },
        'U' => &.{ "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", ".#####." },
        'V' => &.{ "##...##", "##...##", "##...##", "##...##", "##...##", ".##.##.", ".##.##.", "..###..", "...#..." },
        'W' => &.{ "##.....##", "##.....##", "##.....##", "##..#..##", "##.###.##", "##.###.##", "#########", ".###.###.", ".##...##." },
        'X' => &.{ "##...##", "##...##", ".##.##.", "..###..", "..###..", "..###..", ".##.##.", "##...##", "##...##" },
        'Y' => &.{ "##..##", "##..##", "##..##", ".####.", "..##..", "..##..", "..##..", "..##..", "..##.." },
        'Z' => &.{ "#######", ".....##", "....##.", "...##..", "...##..", "..##...", ".##....", "##.....", "#######" },
        'a' => &.{ "", "", "", ".####.", "....##", ".#####", "##..##", "##..##", ".#####" },
        'b' => &.{ "##....", "##....", "##....", "#####.", "##..##", "##..##", "##..##", "##..##", "#####." },
        'c' => &.{ "", "", "", ".####.", "##..##", "##....", "##....", "##..##", ".####." },
        'd' => &.{ "....##", "....##", "....##", ".#####", "##..##", "##..##", "##..##", "##..##", ".#####" },
        'e' => &.{ "", "", "", ".####.", "##..##", "######", "##....", "##..##", ".####." },
        'f' => &.{ "..###", ".##..", ".##..", "####.", ".##..", ".##..", ".##..", ".##..", ".##.." },
        'g' => &.{ "", "", "", ".#####", "##..##", "##..##", "##..##", "##..##", ".#####", "....##", ".####." },
        'h' => &.{ "##....", "##....", "##....", "#####.", "##..##", "##..##", "##..##", "##..##", "##..##" },
        'i' => &.{ "", "##", "", "##", "##", "##", "##", "##", "##" },
        'j' => &.{ "", "..##", "", "..##", "..##", "..##", "..##", "..##", "..##", "..##", "###." },
        'k' => &.{ "##....", "##....", "##....", "##..##", "##.##.", "####..", "####..", "##.##.", "##..##" },
        'l' => &.{ "##", "##", "##", "##", "##", "##", "##", "##", "##" },
        'm' => &.{ "", "", "", "#########.", "##..##..##", "##..##..##", "##..##..##", "##..##..##", "##..##..##" },
        'n' => &.{ "", "", "", "#####.", "##..##", "##..##", "##..##", "##..##", "##..##" },
        'o' => &.{ "", "", "", ".####.", "##..##", "##..##", "##..##", "##..##", ".####." },
        'p' => &.{ "", "", "", "#####.", "##..##", "##..##", "##..##", "##..##", "#####.", "##....", "##...." },
        'q' => &.{ "", "", "", ".#####", "##..##", "##..##", "##..##", "##..##", ".#####", "....##", "....##" },
        'r' => &.{ "", "", "", "##.###", "###...", "##....", "##....", "##....", "##...." },
        's' => &.{ "", "", "", ".#####", "##....", "####..", "..####", "....##", "#####." },
        't' => &.{ "", ".##..", ".##..", "#####", ".##..", ".##..", ".##..", ".##..", "..###" },
        'u' => &.{ "", "", "", "##..##", "##..##", "##..##", "##..##", "##..##", ".#####" },
        'v' => &.{ "", "", "", "##..##", "##..##", "##..##", ".####.", ".####.", "..##.." },
        'w' => &.{ "", "", "", "##..##..##", "##..##..##", "##..##..##", "##..##..##", "##..##..##", ".###..###." },
        'x' => &.{ "", "", "", "##..##", ".####.", "..##..", "..##..", ".####.", "##..##" },
        'y' => &.{ "", "", "", "##..##", "##..##", "##..##", "##..##", "##..##", ".#####", "....##", ".####." },
        'z' => &.{ "", "", "", "######", "...##.", "..##..", ".##...", "##....", "######" },
        '0' => &.{ ".####.", "##..##", "##..##", "##..##", "##..##", "##..##", "##..##", "##..##", ".####." },
        '1' => &.{ "..##", "####", "..##", "..##", "..##", "..##", "..##", "..##", "..##" },
        '2' => &.{ ".####.", "##..##", "....##", "....##", "...##.", "..##..", ".##...", "##....", "######" },
        '3' => &.{ ".####.", "##..##", "....##", "....##", "..###.", "....##", "....##", "##..##", ".####." },
        '4' => &.{ "...###", "..####", ".##.##", "##..##", "##..##", "######", "....##", "....##", "....##" },
        '5' => &.{ "######", "##....", "##....", "#####.", "....##", "....##", "....##", "##..##", ".####." },
        '6' => &.{ ".####.", "##....", "##....", "#####.", "##..##", "##..##", "##..##", "##..##", ".####." },
        '7' => &.{ "######", "....##", "....##", "...##.", "..##..", "..##..", ".##...", ".##...", ".##..." },
        '8' => &.{ ".####.", "##..##", "##..##", "##..##", ".####.", "##..##", "##..##", "##..##", ".####." },
        '9' => &.{ ".####.", "##..##", "##..##", "##..##", "##..##", ".#####", "....##", "....##", ".####." },
        ':' => &.{ "", "", "", "##", "##", "", "", "##", "##" },
        '.' => &.{ "", "", "", "", "", "", "", "##", "##" },
        ',' => &.{ "", "", "", "", "", "", "", "##", "##", ".#", "#." },
        '-' => &.{ "", "", "", "", "", "#####" },
        '?' => &.{ ".####.", "##..##", "....##", "...##.", "..##..", "..##..", "", "..##..", "..##.." },
        '(' => &.{ "..##", ".##.", "##..", "##..", "##..", "##..", "##..", ".##.", "..##" },
        ')' => &.{ "##..", ".##.", "..##", "..##", "..##", "..##", "..##", ".##.", "##.." },
        '\'' => &.{ "##", "##", "#." },
        '/' => &.{ "....##", "....##", "...##.", "...##.", "..##..", ".##...", ".##...", "##....", "##...." },
        // Command key.
        0x11 => &.{ ".##...##.", "#..#.#..#", "#..#.#..#", ".#######.", "...#.#...", ".#######.", "#..#.#..#", "#..#.#..#", ".##...##." },
        // Check mark.
        0x12 => &.{ "", "......##", ".....##.", ".....##.", "##..##..", ".####...", ".####...", "..##....", "..##...." },
        else => null,
    };
}

fn smallRows(c: u8) ?[]const []const u8 {
    return switch (c) {
        'A' => &.{ ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" },
        'B' => &.{ "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####." },
        'C' => &.{ ".###.", "#...#", "#....", "#....", "#....", "#...#", ".###." },
        'D' => &.{ "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####." },
        'E' => &.{ "####", "#...", "#...", "###.", "#...", "#...", "####" },
        'F' => &.{ "####", "#...", "#...", "###.", "#...", "#...", "#..." },
        'G' => &.{ ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###." },
        'H' => &.{ "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" },
        'I' => &.{ "#", "#", "#", "#", "#", "#", "#" },
        'J' => &.{ "...#", "...#", "...#", "...#", "...#", "#..#", ".##." },
        'K' => &.{ "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" },
        'L' => &.{ "#...", "#...", "#...", "#...", "#...", "#...", "####" },
        'M' => &.{ "#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#" },
        'N' => &.{ "#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#" },
        'O' => &.{ ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." },
        'P' => &.{ "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." },
        'Q' => &.{ ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#" },
        'R' => &.{ "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" },
        'S' => &.{ ".###.", "#...#", "#....", ".###.", "....#", "#...#", ".###." },
        'T' => &.{ "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." },
        'U' => &.{ "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." },
        'V' => &.{ "#...#", "#...#", "#...#", "#...#", ".#.#.", ".#.#.", "..#.." },
        'W' => &.{ "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#" },
        'X' => &.{ "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#" },
        'Y' => &.{ "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.." },
        'Z' => &.{ "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####" },
        'a' => &.{ "", "", ".###", "...#", ".###", "#..#", ".###" },
        'b' => &.{ "#...", "#...", "###.", "#..#", "#..#", "#..#", "###." },
        'c' => &.{ "", "", ".##", "#..", "#..", "#..", ".##" },
        'd' => &.{ "...#", "...#", ".###", "#..#", "#..#", "#..#", ".###" },
        'e' => &.{ "", "", ".##.", "#..#", "####", "#...", ".###" },
        'f' => &.{ ".##", "#..", "###", "#..", "#..", "#..", "#.." },
        'g' => &.{ "", "", ".###", "#..#", "#..#", "#..#", ".###", "...#", ".##." },
        'h' => &.{ "#...", "#...", "###.", "#..#", "#..#", "#..#", "#..#" },
        'i' => &.{ "#", "", "#", "#", "#", "#", "#" },
        'j' => &.{ ".#", "", ".#", ".#", ".#", ".#", ".#", ".#", "#." },
        'k' => &.{ "#...", "#...", "#..#", "#.#.", "##..", "#.#.", "#..#" },
        'l' => &.{ "#", "#", "#", "#", "#", "#", "#" },
        'm' => &.{ "", "", "####.", "#.#.#", "#.#.#", "#.#.#", "#.#.#" },
        'n' => &.{ "", "", "###.", "#..#", "#..#", "#..#", "#..#" },
        'o' => &.{ "", "", ".##.", "#..#", "#..#", "#..#", ".##." },
        'p' => &.{ "", "", "###.", "#..#", "#..#", "#..#", "###.", "#...", "#..." },
        'q' => &.{ "", "", ".###", "#..#", "#..#", "#..#", ".###", "...#", "...#" },
        'r' => &.{ "", "", "#.#", "##.", "#..", "#..", "#.." },
        's' => &.{ "", "", ".###", "#...", ".##.", "...#", "###." },
        't' => &.{ "#..", "#..", "###", "#..", "#..", "#..", ".##" },
        'u' => &.{ "", "", "#..#", "#..#", "#..#", "#..#", ".###" },
        'v' => &.{ "", "", "#...#", "#...#", ".#.#.", ".#.#.", "..#.." },
        'w' => &.{ "", "", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#." },
        'x' => &.{ "", "", "#...#", ".#.#.", "..#..", ".#.#.", "#...#" },
        'y' => &.{ "", "", "#..#", "#..#", "#..#", "#..#", ".###", "...#", ".##." },
        'z' => &.{ "", "", "####", "...#", ".##.", "#...", "####" },
        '0' => &.{ ".##.", "#..#", "#..#", "#..#", "#..#", "#..#", ".##." },
        '1' => &.{ ".#", "##", ".#", ".#", ".#", ".#", ".#" },
        '2' => &.{ ".##.", "#..#", "...#", "..#.", ".#..", "#...", "####" },
        '3' => &.{ ".##.", "#..#", "...#", "..#.", "...#", "#..#", ".##." },
        '4' => &.{ "..#.", ".##.", "#.#.", "#.#.", "####", "..#.", "..#." },
        '5' => &.{ "####", "#...", "###.", "...#", "...#", "#..#", ".##." },
        '6' => &.{ ".##.", "#...", "#...", "###.", "#..#", "#..#", ".##." },
        '7' => &.{ "####", "...#", "..#.", "..#.", ".#..", ".#..", ".#.." },
        '8' => &.{ ".##.", "#..#", "#..#", ".##.", "#..#", "#..#", ".##." },
        '9' => &.{ ".##.", "#..#", "#..#", ".###", "...#", "...#", ".##." },
        '.' => &.{ "", "", "", "", "", "", "#" },
        ',' => &.{ "", "", "", "", "", "", "#", "#" },
        ':' => &.{ "", "", "#", "", "", "", "#" },
        '-' => &.{ "", "", "", "###" },
        '(' => &.{ ".#", "#.", "#.", "#.", "#.", "#.", ".#" },
        ')' => &.{ "#.", ".#", ".#", ".#", ".#", ".#", "#." },
        '/' => &.{ "...#", "...#", "..#.", ".#..", ".#..", "#...", "#..." },
        '\'' => &.{ "#", "#" },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Raster primitives with a single clip rectangle

const FULL_CLIP = Rect{ .x = 0, .y = 0, .w = SCREEN_W, .h = SCREEN_H };
var clip: Rect = FULL_CLIP;

fn resetClip() void {
    clip = FULL_CLIP;
}

fn pushClip(r: Rect) Rect {
    const saved = clip;
    clip = intersect(clip, r);
    return saved;
}

fn popClip(saved: Rect) void {
    clip = saved;
}

fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

fn clipContains(x: i32, y: i32) bool {
    return x >= clip.x and y >= clip.y and x < clip.x + clip.w and y < clip.y + clip.h;
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const r = intersect(clip, .{ .x = x0, .y = y0, .w = w, .h = h });
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        var x = r.x;
        while (x < r.x + r.w) : (x += 1) setPixel(@intCast(x), @intCast(y), c);
    }
}

fn blendRect(x0: i32, y0: i32, w: i32, h: i32, c: Color, alpha: u8) void {
    if (w <= 0 or h <= 0) return;
    const r = intersect(clip, .{ .x = x0, .y = y0, .w = w, .h = h });
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        var x = r.x;
        while (x < r.x + r.w) : (x += 1) blendPixel(x, y, c, alpha);
    }
}

fn blendPixel(x: i32, y: i32, c: Color, alpha: u8) void {
    if (!clipContains(x, y)) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const a: u32 = alpha;
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const d: u32 = output_buf[idx + k];
        output_buf[idx + k] = @intCast((d * (255 - a) + @as(u32, c[k]) * a + 127) / 255);
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (!clipContains(x, y)) return;
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

// ---------------------------------------------------------------------------
// Tests

fn press(x: i32, y: i32) void {
    _ = pointerEventForTest(BTN_PRIMARY, x, y, 0);
}

fn release(x: i32, y: i32) void {
    _ = pointerEventForTest(0, x, y, 0);
}

fn itemCenter(menu: MenuId, action: Action) [2]i32 {
    for (menuItems(menu), 0..) |item, i| {
        if (item.action == action) {
            const r = menuItemRect(menu, i);
            return .{ r.x + 8, r.y + @divFloor(r.h, 2) };
        }
    }
    unreachable;
}

fn titleCenter(menu: MenuId) [2]i32 {
    const r = menuTitleRect(menu);
    return .{ r.x + @divFloor(r.w, 2), 8 };
}

test "menu bar fits the screen" {
    const help = menuTitleRect(.help);
    try std.testing.expect(help.x + help.w + 3 <= clockX());
    try std.testing.expect(clockX() + textWidth(&BOLD, CLOCK_TEXT) < appMenuX());
}

test "default layout keeps icons and the window apart" {
    resetDesktop();
    const win = Rect{ .x = window_x, .y = window_y, .w = window_w, .h = window_h };
    for (icons) |icon| {
        const label = iconLabelRect(icon);
        try std.testing.expect(label.x >= 0 and label.x + label.w <= SCREEN_W);
        try std.testing.expect(label.y + label.h <= SCREEN_H);
        try std.testing.expect(!pointInRect(icon.x, icon.y, win));
        try std.testing.expect(label.x > win.x + win.w);
    }
    try std.testing.expect(mac9MaxScrollX() > 0 and mac9MaxScrollY() > 0);
}

test "zoom fits the list without scrolling" {
    resetDesktop();
    toggleMac9Zoom();
    try std.testing.expect(mac9MaxScrollX() == 0 and mac9MaxScrollY() == 0);
    try std.testing.expect(window_x >= 0 and window_x + window_w <= SCREEN_W);
    try std.testing.expect(window_y >= MENUBAR_H and window_y + window_h <= SCREEN_H);
}

test "icon outline commits on release" {
    resetDesktop();
    const original_x = icons[0].x;
    const original_y = icons[0].y;
    press(original_x + 8, original_y + 12);
    press(190, 90);
    try std.testing.expect(icons[0].x == original_x and icons[0].y == original_y);
    try std.testing.expect(icon_drag_x != original_x or icon_drag_y != original_y);
    release(190, 90);
    try std.testing.expect(icons[0].x == icon_drag_x and icons[0].y == icon_drag_y);
}

test "window outline commits on release" {
    resetDesktop();
    const original_x = window_x;
    const original_y = window_y;
    press(window_x + 30, window_y + 9);
    press(140, 88);
    try std.testing.expect(window_x == original_x and window_y == original_y);
    try std.testing.expect(window_drag_x != original_x or window_drag_y != original_y);
    release(140, 88);
    try std.testing.expect(window_x == window_drag_x and window_y == window_drag_y);
}

test "view menu Collapse Window toggles window shade state" {
    resetDesktop();
    const title = titleCenter(.view);
    const item = itemCenter(.view, .collapse_window);
    press(title[0], title[1]);
    press(item[0], item[1]);
    release(item[0], item[1]);
    try std.testing.expect(window_shaded);
    try std.testing.expect(!window_minimized);
    press(title[0], title[1]);
    press(item[0], item[1]);
    release(item[0], item[1]);
    try std.testing.expect(!window_shaded);
}

test "collapse box toggles window shade" {
    resetDesktop();
    const collapse_btn = mac9CaptionButtonRect(.collapse);
    press(collapse_btn.x + 2, collapse_btn.y + 2);
    release(collapse_btn.x + 2, collapse_btn.y + 2);
    try std.testing.expect(window_shaded);
    try std.testing.expect(!window_minimized);
    try std.testing.expect(mode == .idle);
    press(collapse_btn.x + 2, collapse_btn.y + 2);
    release(collapse_btn.x + 2, collapse_btn.y + 2);
    try std.testing.expect(!window_shaded);
}

test "zoom button toggles fit size and restore" {
    resetDesktop();
    const zoom_btn = mac9CaptionButtonRect(.zoom);
    press(zoom_btn.x + 2, zoom_btn.y + 2);
    release(zoom_btn.x + 2, zoom_btn.y + 2);
    try std.testing.expect(window_zoomed);
    try std.testing.expect(window_w > WINDOW_W and window_h > WINDOW_H);

    const zoom_btn_rest = mac9CaptionButtonRect(.zoom);
    press(zoom_btn_rest.x + 2, zoom_btn_rest.y + 2);
    release(zoom_btn_rest.x + 2, zoom_btn_rest.y + 2);
    try std.testing.expect(!window_zoomed);
    try std.testing.expect(window_x == WINDOW_X and window_y == WINDOW_Y and window_w == WINDOW_W and window_h == WINDOW_H);
}

test "resize outline commits on release" {
    resetDesktop();
    const handle_x = window_x + window_w - 8;
    const handle_y = window_y + window_h - 8;
    press(handle_x, handle_y);
    press(handle_x + 28, handle_y + 28);
    try std.testing.expect(window_w == WINDOW_W and window_h == WINDOW_H);
    try std.testing.expect(window_drag_w > WINDOW_W and window_drag_h > WINDOW_H);
    release(handle_x + 28, handle_y + 28);
    try std.testing.expect(window_w == window_drag_w and window_h == window_drag_h);
}

test "menubar opens while holding and closes on release" {
    resetDesktop();
    const file = titleCenter(.file);
    const edit = titleCenter(.edit);
    press(file[0], file[1]);
    try std.testing.expect(menu_open == .file);
    try std.testing.expect(menu_tracking);
    press(edit[0], edit[1]);
    try std.testing.expect(menu_open == .edit);
    release(280, 200);
    try std.testing.expect(menu_open == .none);
    try std.testing.expect(!menu_tracking);
}

test "releasing on a menu title keeps the menu open until the next click" {
    resetDesktop();
    const file = titleCenter(.file);
    press(file[0], file[1]);
    release(file[0], file[1]);
    try std.testing.expect(menu_open == .file and menu_sticky);
    const item = itemCenter(.file, .close_window);
    try std.testing.expect(pointerEventForTest(0, item[0], item[1], 0) == 1);
    press(item[0], item[1]);
    release(item[0], item[1]);
    try std.testing.expect(window_minimized);
    try std.testing.expect(menu_open == .none);
}

test "menubar file close item closes window on release" {
    resetDesktop();
    const file = titleCenter(.file);
    const item = itemCenter(.file, .close_window);
    press(file[0], file[1]);
    try std.testing.expect(menu_open == .file);
    press(item[0], item[1]);
    release(item[0], item[1]);
    try std.testing.expect(window_minimized);
    try std.testing.expect(menu_open == .none);
}

test "disabled menu items do nothing" {
    resetDesktop();
    const file = titleCenter(.file);
    const r = menuItemRect(.file, 0);
    press(file[0], file[1]);
    press(r.x + 8, r.y + 8);
    try std.testing.expect(menuItemAt(.file, r.x + 8, r.y + 8) == -1);
    release(r.x + 8, r.y + 8);
    try std.testing.expect(menu_open == .none and !window_minimized);
}

test "desktop context menu opens on right click" {
    resetDesktop();
    _ = pointerEventForTest(BTN_SECONDARY, 300, 400, 0);
    _ = pointerEventForTest(0, 300, 400, 0);
    try std.testing.expect(desktop_menu_open);
}

test "marquee selection selects multiple icons" {
    resetDesktop();
    press(SCREEN_W - 2, MENUBAR_H + 70);
    press(SCREEN_W - 70, MENUBAR_H + 230);
    release(SCREEN_W - 70, MENUBAR_H + 230);
    try std.testing.expect(selected_mask == 0b0000_1110);
}

test "clicking a list row selects it" {
    resetDesktop();
    const list = mac9ViewportRect();
    press(list.x + 40, list.y + ROW_H + 4);
    release(list.x + 40, list.y + ROW_H + 4);
    try std.testing.expect(list_selected == 1);
}

test "macos9 vertical scrollbar drag commits scroll on release" {
    resetDesktop();
    const thumb = mac9VThumbRect();
    press(thumb.x + 2, thumb.y + 2);
    press(thumb.x + 2, thumb.y + 20);
    try std.testing.expect(scroll_y == 0);
    release(thumb.x + 2, thumb.y + 20);
    try std.testing.expect(scroll_y > 0);
}
