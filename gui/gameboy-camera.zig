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

const LCD_X: i32 = 22;
const LCD_Y: i32 = 24;
const LCD_W: i32 = 276;
const LCD_H: i32 = 172;

const PHOTO_W: i32 = 32;
const PHOTO_H: i32 = 32;
const PHOTO_PIXELS: usize = @as(usize, @intCast(PHOTO_W * PHOTO_H));
const MAX_PHOTOS: usize = 30;
const ALBUM_PAGE_SIZE: i32 = 15;

const GB_DARK: [4]u8 = .{ 0x0F, 0x38, 0x0F, 0xFF };
const GB_MID_DARK: [4]u8 = .{ 0x30, 0x62, 0x30, 0xFF };
const GB_MID_LIGHT: [4]u8 = .{ 0x8B, 0xAC, 0x0F, 0xFF };
const GB_LIGHT: [4]u8 = .{ 0x9B, 0xBC, 0x0F, 0xFF };

const Mode = enum(u8) {
    menu,
    shoot,
    album,
    view,
    stamp,
    info,
};

const MenuItem = enum(u8) {
    shoot,
    view,
    album,
    stamp,
    play,
    link,
};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;
var photos: [MAX_PHOTOS][PHOTO_PIXELS]u8 = undefined;
var initialized: bool = false;
var needs_redraw: bool = true;

var mode: Mode = .menu;
var menu_selected: i32 = 0;
var photo_count: i32 = 0;
var next_slot: i32 = 0;
var pulse: i32 = 0;

var album_selected: i32 = 0;
var album_page: i32 = 0;
var view_index: i32 = 0;

var stamp_photo: i32 = 0;
var stamp_cursor_x: i32 = 16;
var stamp_cursor_y: i32 = 16;
var stamp_kind: i32 = 0;

var info_title: []const u8 = "";
var info_body: []const u8 = "";

var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;

const menu_labels = [_][]const u8{
    "SHOOT",
    "VIEW",
    "ALBUM",
    "STAMP",
    "PLAY",
    "LINK",
};

const stamp_labels = [_][]const u8{
    "STAR",
    "HEART",
    "SMILE",
};

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

const Phase = enum { initializing, ready, updating };
var lifecycle_state: Phase = .initializing;
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
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (mode) {
        .menu => handleMenuKey(x11_key),
        .shoot => handleShootKey(x11_key),
        .album => handleAlbumKey(x11_key),
        .view => handleViewKey(x11_key),
        .stamp => handleStampKey(x11_key),
        .info => handleInfoKey(x11_key),
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    advanceUpdateTime();
    ensureInit();
    pointer_x = x_px;
    pointer_y = y_px;
    const down = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;

    if (secondary and !secondary_down) {
        backAction();
        primary_down = down;
        secondary_down = true;
        needs_redraw = true;
        return 1;
    }

    if (down and !primary_down) {
        switch (mode) {
            .menu => pointerMenuPress(x_px, y_px),
            .shoot => pointerShootPress(x_px, y_px),
            .album => pointerAlbumPress(x_px, y_px),
            .view => pointerViewPress(x_px, y_px),
            .stamp => pointerStampPress(x_px, y_px),
            .info => mode = .menu,
        }
        needs_redraw = true;
    }

    primary_down = down;
    secondary_down = secondary;
    return if (needs_redraw) 1 else 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

fn advanceUpdateTime() void {
    if (time_advanced) return;
    time_advanced = true;
    ensureInit();
    pulse = @mod(pulse + 1, 4096);
    needs_redraw = true;
}

export fn finish_update() i64 {
    requireUpdate();
    advanceUpdateTime();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    return if (begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
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
    resetState();
    initialized = true;
}

fn resetState() void {
    mode = .menu;
    menu_selected = 0;
    photo_count = 0;
    next_slot = 0;
    pulse = 0;
    album_selected = 0;
    album_page = 0;
    view_index = 0;
    stamp_photo = 0;
    stamp_cursor_x = 16;
    stamp_cursor_y = 16;
    stamp_kind = 0;
    info_title = "";
    info_body = "";
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    var i: usize = 0;
    while (i < MAX_PHOTOS) : (i += 1) {
        var p: usize = 0;
        while (p < PHOTO_PIXELS) : (p += 1) photos[i][p] = 3;
    }
    needs_redraw = true;
}

fn handleMenuKey(key: i32) void {
    switch (key) {
        XK_LEFT, 'a', 'A' => menuStep(-1, 0),
        XK_RIGHT, 'd', 'D' => menuStep(1, 0),
        XK_UP, 'w', 'W' => menuStep(0, -1),
        XK_DOWN, 's', 'S' => menuStep(0, 1),
        XK_RETURN, ' ', 'x', 'X' => openMenuItem(menu_selected),
        else => {},
    }
}

fn handleShootKey(key: i32) void {
    switch (key) {
        XK_RETURN, ' ', 'x', 'X' => captureCurrentFrame(),
        XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => mode = .menu,
        else => {},
    }
}

fn handleAlbumKey(key: i32) void {
    switch (key) {
        XK_LEFT, 'a', 'A' => moveAlbumSelection(-1, 0),
        XK_RIGHT, 'd', 'D' => moveAlbumSelection(1, 0),
        XK_UP, 'w', 'W' => moveAlbumSelection(0, -1),
        XK_DOWN, 's', 'S' => moveAlbumSelection(0, 1),
        XK_RETURN, ' ', 'x', 'X' => openSelectedPhoto(),
        'p', 'P' => setAlbumPage(album_page - 1),
        'n', 'N' => setAlbumPage(album_page + 1),
        't', 'T' => startStampModeFromAlbum(),
        XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => mode = .menu,
        else => {},
    }
}

fn handleViewKey(key: i32) void {
    if (photo_count <= 0) {
        mode = .menu;
        return;
    }
    switch (key) {
        XK_LEFT, 'a', 'A' => view_index = @mod(view_index - 1 + photo_count, photo_count),
        XK_RIGHT, 'd', 'D' => view_index = @mod(view_index + 1, photo_count),
        's', 'S' => beginStampMode(view_index),
        XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => mode = .album,
        else => {},
    }
}

fn handleStampKey(key: i32) void {
    switch (key) {
        XK_LEFT, 'a', 'A' => stampCursorStep(-1, 0),
        XK_RIGHT, 'd', 'D' => stampCursorStep(1, 0),
        XK_UP, 'w', 'W' => stampCursorStep(0, -1),
        XK_DOWN, 's', 'S' => stampCursorStep(0, 1),
        'c', 'C' => stamp_kind = @mod(stamp_kind + 1, @as(i32, @intCast(stamp_labels.len))),
        XK_RETURN, ' ', 'x', 'X' => placeStamp(stamp_photo, stamp_cursor_x, stamp_cursor_y, stamp_kind),
        XK_ESCAPE, XK_BACKSPACE, 'o', 'O', 'b', 'B' => mode = .view,
        else => {},
    }
}

fn handleInfoKey(key: i32) void {
    switch (key) {
        XK_ESCAPE, XK_BACKSPACE, XK_RETURN, ' ', 'x', 'X', 'o', 'O', 'b', 'B' => mode = .menu,
        else => {},
    }
}

fn backAction() void {
    switch (mode) {
        .menu => {},
        .shoot => mode = .menu,
        .album => mode = .menu,
        .view => mode = .album,
        .stamp => mode = .view,
        .info => mode = .menu,
    }
}

fn menuStep(dx: i32, dy: i32) void {
    var col = @mod(menu_selected, 3);
    var row = @divTrunc(menu_selected, 3);
    col = clampI32(col + dx, 0, 2);
    row = clampI32(row + dy, 0, 1);
    menu_selected = row * 3 + col;
}

fn openMenuItem(index: i32) void {
    const item = @as(MenuItem, @enumFromInt(@as(u8, @intCast(index))));
    switch (item) {
        .shoot => mode = .shoot,
        .view => {
            if (photo_count <= 0) {
                openInfo("VIEW", "NO PHOTOS YET.");
            } else {
                view_index = photo_count - 1;
                mode = .view;
            }
        },
        .album => mode = .album,
        .stamp => {
            if (photo_count <= 0) {
                openInfo("STAMP", "TAKE A PHOTO FIRST.");
            } else {
                beginStampMode(photo_count - 1);
            }
        },
        .play => openInfo("PLAY", "MINIGAMES NOT IN THIS DEMO."),
        .link => openInfo("LINK", "LINK CABLE MODE NOT CONNECTED."),
    }
}

fn openInfo(title: []const u8, body: []const u8) void {
    info_title = title;
    info_body = body;
    mode = .info;
}

fn captureCurrentFrame() void {
    var slot: i32 = 0;
    if (photo_count < @as(i32, @intCast(MAX_PHOTOS))) {
        slot = photo_count;
        photo_count += 1;
    } else {
        slot = next_slot;
    }
    next_slot = @mod(slot + 1, @as(i32, @intCast(MAX_PHOTOS)));
    generatePhoto(slot, pulse + slot * 37);
    view_index = slot;
    album_selected = slot;
    album_page = @divTrunc(slot, ALBUM_PAGE_SIZE);
}

fn generatePhoto(slot: i32, seed: i32) void {
    const s = @as(usize, @intCast(slot));
    var y: i32 = 0;
    while (y < PHOTO_H) : (y += 1) {
        var x: i32 = 0;
        while (x < PHOTO_W) : (x += 1) {
            const n = @mod((x * 23 + y * 11 + seed * 3 + (x ^ y) * 7), 256);
            var p: u8 = 0;
            if (n < 50) p = 0 else if (n < 110) p = 1 else if (n < 182) p = 2 else p = 3;

            // simple "face-like" structure to make captures recognizable
            const eye_y = 11 + @mod(seed, 3);
            if ((x - 11) * (x - 11) + (y - eye_y) * (y - eye_y) <= 4) p = 0;
            if ((x - 21) * (x - 21) + (y - eye_y) * (y - eye_y) <= 4) p = 0;
            if (y > 20 and y < 25 and absI32(x - 16) < 6 and absI32(y - 22) < 2) p = 1;

            photos[s][@as(usize, @intCast(y * PHOTO_W + x))] = p;
        }
    }
}

fn moveAlbumSelection(dx: i32, dy: i32) void {
    if (photo_count <= 0) {
        album_selected = 0;
        return;
    }
    var local = album_selected - album_page * ALBUM_PAGE_SIZE;
    var col = @mod(local, 5);
    var row = @divTrunc(local, 5);
    col = clampI32(col + dx, 0, 4);
    row = clampI32(row + dy, 0, 2);
    local = row * 5 + col;
    const candidate = album_page * ALBUM_PAGE_SIZE + local;
    if (candidate < photo_count) {
        album_selected = candidate;
    } else {
        // Walk back until we hit a valid slot on this page.
        var c = candidate;
        while (c >= album_page * ALBUM_PAGE_SIZE and c >= photo_count) : (c -= 1) {}
        if (c >= album_page * ALBUM_PAGE_SIZE and c < photo_count) album_selected = c;
    }
}

fn setAlbumPage(page: i32) void {
    const max_page = @divTrunc(@max(0, photo_count - 1), ALBUM_PAGE_SIZE);
    album_page = clampI32(page, 0, max_page);
    const min_idx = album_page * ALBUM_PAGE_SIZE;
    const max_idx = @min(photo_count - 1, min_idx + ALBUM_PAGE_SIZE - 1);
    album_selected = clampI32(album_selected, min_idx, @max(min_idx, max_idx));
}

fn openSelectedPhoto() void {
    if (photo_count <= 0) {
        openInfo("ALBUM", "EMPTY. TAKE A PHOTO.");
        return;
    }
    view_index = clampI32(album_selected, 0, photo_count - 1);
    mode = .view;
}

fn startStampModeFromAlbum() void {
    if (photo_count <= 0) {
        openInfo("STAMP", "NO PHOTO SELECTED.");
        return;
    }
    beginStampMode(album_selected);
}

fn beginStampMode(index: i32) void {
    stamp_photo = clampI32(index, 0, @max(0, photo_count - 1));
    stamp_cursor_x = 16;
    stamp_cursor_y = 16;
    stamp_kind = 0;
    mode = .stamp;
}

fn stampCursorStep(dx: i32, dy: i32) void {
    stamp_cursor_x = clampI32(stamp_cursor_x + dx, 0, PHOTO_W - 1);
    stamp_cursor_y = clampI32(stamp_cursor_y + dy, 0, PHOTO_H - 1);
}

fn placeStamp(photo_index: i32, cx: i32, cy: i32, kind: i32) void {
    if (photo_index < 0 or photo_index >= photo_count) return;
    const pi = @as(usize, @intCast(photo_index));
    const pattern = stampPattern(kind);
    var sy: i32 = 0;
    while (sy < 5) : (sy += 1) {
        var sx: i32 = 0;
        while (sx < 5) : (sx += 1) {
            if ((pattern[@as(usize, @intCast(sy))] & (@as(u8, 1) << @as(u3, @intCast(4 - sx)))) == 0) continue;
            const px = cx + sx - 2;
            const py = cy + sy - 2;
            if (px < 0 or py < 0 or px >= PHOTO_W or py >= PHOTO_H) continue;
            photos[pi][@as(usize, @intCast(py * PHOTO_W + px))] = 0;
        }
    }
}

fn stampPattern(kind: i32) [5]u8 {
    return switch (@mod(kind, 3)) {
        0 => .{ 0b00100, 0b11111, 0b01110, 0b11111, 0b00100 }, // star-ish
        1 => .{ 0b01010, 0b11111, 0b11111, 0b01110, 0b00100 }, // heart-ish
        else => .{ 0b00000, 0b10001, 0b00000, 0b10001, 0b01110 }, // smile
    };
}

fn pointerMenuPress(x: i32, y: i32) void {
    if (menuItemAt(x, y)) |idx| {
        menu_selected = idx;
        openMenuItem(idx);
    }
}

fn pointerShootPress(x: i32, y: i32) void {
    if (pointInRect(x, y, .{ .x = 198, .y = 148, .w = 70, .h = 18 })) {
        captureCurrentFrame();
    } else if (pointInRect(x, y, .{ .x = 198, .y = 170, .w = 70, .h = 18 })) {
        mode = .menu;
    }
}

fn pointerAlbumPress(x: i32, y: i32) void {
    if (pointInRect(x, y, .{ .x = 34, .y = 170, .w = 20, .h = 16 })) {
        setAlbumPage(album_page - 1);
        return;
    }
    if (pointInRect(x, y, .{ .x = 266, .y = 170, .w = 20, .h = 16 })) {
        setAlbumPage(album_page + 1);
        return;
    }
    if (albumThumbAt(x, y)) |idx| {
        if (idx < photo_count) {
            if (idx == album_selected) {
                view_index = idx;
                mode = .view;
            } else {
                album_selected = idx;
            }
        }
    }
}

fn pointerViewPress(x: i32, y: i32) void {
    if (photo_count <= 0) return;
    if (pointInRect(x, y, .{ .x = 34, .y = 170, .w = 24, .h = 16 })) {
        view_index = @mod(view_index - 1 + photo_count, photo_count);
        return;
    }
    if (pointInRect(x, y, .{ .x = 262, .y = 170, .w = 24, .h = 16 })) {
        view_index = @mod(view_index + 1, photo_count);
        return;
    }
    if (pointInRect(x, y, .{ .x = 142, .y = 170, .w = 40, .h = 16 })) {
        beginStampMode(view_index);
        return;
    }
    if (pointInRect(x, y, .{ .x = 198, .y = 170, .w = 70, .h = 16 })) {
        mode = .album;
    }
}

fn pointerStampPress(x: i32, y: i32) void {
    const area = Rect{ .x = 60, .y = 40, .w = 128, .h = 128 };
    if (pointInRect(x, y, area)) {
        const px = clampI32(@divTrunc((x - area.x) * PHOTO_W, area.w), 0, PHOTO_W - 1);
        const py = clampI32(@divTrunc((y - area.y) * PHOTO_H, area.h), 0, PHOTO_H - 1);
        stamp_cursor_x = px;
        stamp_cursor_y = py;
        placeStamp(stamp_photo, px, py, stamp_kind);
        return;
    }
    if (pointInRect(x, y, .{ .x = 204, .y = 58, .w = 64, .h = 16 })) {
        stamp_kind = @mod(stamp_kind + 1, @as(i32, @intCast(stamp_labels.len)));
        return;
    }
    if (pointInRect(x, y, .{ .x = 204, .y = 80, .w = 64, .h = 16 })) {
        placeStamp(stamp_photo, stamp_cursor_x, stamp_cursor_y, stamp_kind);
        return;
    }
    if (pointInRect(x, y, .{ .x = 204, .y = 170, .w = 64, .h = 16 })) {
        mode = .view;
        return;
    }
}

fn drawFrame() void {
    drawShell();
    drawLcdBase();
    switch (mode) {
        .menu => drawMenu(),
        .shoot => drawShoot(),
        .album => drawAlbum(),
        .view => drawView(),
        .stamp => drawStamp(),
        .info => drawInfo(),
    }
    drawFooterHints();
}

fn drawShell() void {
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), .{ 0xC8, 0xC8, 0xBC, 0xFF });
    blendRectI32(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), .{ 0x18, 0x1A, 0x14, 0x20 });
    fillRectI32(8, 8, @as(i32, @intCast(RENDER_W - 16)), @as(i32, @intCast(RENDER_H - 16)), .{ 0xD6, 0xD4, 0xC8, 0xFF });
    drawRect(8, 8, @as(i32, @intCast(RENDER_W - 16)), @as(i32, @intCast(RENDER_H - 16)), .{ 0x7A, 0x78, 0x6C, 0xFF });
    drawTextScaled(16, 12, "GAME BOY CAMERA", .{ 0x30, 0x30, 0x2A, 0xFF }, 1);
}

fn drawLcdBase() void {
    fillRectI32(LCD_X - 4, LCD_Y - 4, LCD_W + 8, LCD_H + 8, .{ 0x62, 0x66, 0x58, 0xFF });
    fillRectI32(LCD_X, LCD_Y, LCD_W, LCD_H, GB_LIGHT);
    drawRect(LCD_X - 4, LCD_Y - 4, LCD_W + 8, LCD_H + 8, .{ 0x34, 0x36, 0x30, 0xFF });
}

fn drawMenu() void {
    drawTextScaled(LCD_X + 8, LCD_Y + 8, "POCKET CAMERA", GB_DARK, 2);
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        const r = menuItemRect(i);
        const selected = (i == menu_selected);
        const fill = if (selected) GB_MID_DARK else GB_MID_LIGHT;
        fillRectI32(r.x, r.y, r.w, r.h, fill);
        drawRect(r.x, r.y, r.w, r.h, GB_DARK);
        drawMenuGlyph(i, r.x + 5, r.y + 5, if (selected) GB_LIGHT else GB_DARK);
        drawTextScaled(r.x + 22, r.y + 15, menu_labels[@as(usize, @intCast(i))], if (selected) GB_LIGHT else GB_DARK, 1);
    }
}

fn drawShoot() void {
    drawTextScaled(LCD_X + 8, LCD_Y + 8, "SHOOT", GB_DARK, 2);
    const area = Rect{ .x = 48, .y = 40, .w = 128, .h = 128 };
    drawLivePreview(area, pulse);
    drawRect(area.x - 2, area.y - 2, area.w + 4, area.h + 4, GB_DARK);

    drawButton(.{ .x = 198, .y = 148, .w = 70, .h = 18 }, "A SHOT", true);
    drawButton(.{ .x = 198, .y = 170, .w = 70, .h = 18 }, "B MENU", false);

    drawTextScaled(198, 118, "PHOTOS", GB_DARK, 1);
    drawNumber(242, 118, photo_count, GB_DARK, 1);
}

fn drawAlbum() void {
    drawTextScaled(LCD_X + 8, LCD_Y + 8, "ALBUM", GB_DARK, 2);
    drawTextScaled(LCD_X + 100, LCD_Y + 8, "PAGE", GB_DARK, 1);
    drawNumber(LCD_X + 128, LCD_Y + 8, album_page + 1, GB_DARK, 1);

    const start = album_page * ALBUM_PAGE_SIZE;
    var row: i32 = 0;
    while (row < 3) : (row += 1) {
        var col: i32 = 0;
        while (col < 5) : (col += 1) {
            const idx = start + row * 5 + col;
            const x = 32 + col * 50;
            const y = 42 + row * 40;
            drawThumbSlot(x, y, idx);
        }
    }
    drawButton(.{ .x = 34, .y = 170, .w = 20, .h = 16 }, "<", false);
    drawButton(.{ .x = 266, .y = 170, .w = 20, .h = 16 }, ">", false);
}

fn drawView() void {
    if (photo_count <= 0) {
        drawTextScaled(88, 98, "NO PHOTO", GB_DARK, 2);
        return;
    }
    drawTextScaled(LCD_X + 8, LCD_Y + 8, "VIEW", GB_DARK, 2);
    drawTextScaled(LCD_X + 74, LCD_Y + 8, "PHOTO", GB_DARK, 1);
    drawNumber(LCD_X + 106, LCD_Y + 8, view_index + 1, GB_DARK, 1);
    drawTextScaled(LCD_X + 122, LCD_Y + 8, "/", GB_DARK, 1);
    drawNumber(LCD_X + 128, LCD_Y + 8, photo_count, GB_DARK, 1);

    drawPhotoScaled(view_index, 96, 40, 4);
    drawRect(94, 38, 132, 132, GB_DARK);

    drawButton(.{ .x = 34, .y = 170, .w = 24, .h = 16 }, "<", false);
    drawButton(.{ .x = 262, .y = 170, .w = 24, .h = 16 }, ">", false);
    drawButton(.{ .x = 142, .y = 170, .w = 40, .h = 16 }, "STAMP", true);
    drawButton(.{ .x = 198, .y = 170, .w = 70, .h = 16 }, "B ALBUM", false);
}

fn drawStamp() void {
    if (photo_count <= 0) {
        drawTextScaled(92, 98, "NO PHOTO", GB_DARK, 2);
        return;
    }
    drawTextScaled(LCD_X + 8, LCD_Y + 8, "STAMP", GB_DARK, 2);
    drawPhotoScaled(stamp_photo, 60, 40, 4);
    drawRect(58, 38, 132, 132, GB_DARK);

    const cursor_x = 60 + stamp_cursor_x * 4;
    const cursor_y = 40 + stamp_cursor_y * 4;
    drawRect(cursor_x - 1, cursor_y - 1, 6, 6, GB_DARK);

    drawTextScaled(204, 40, "TOOL", GB_DARK, 1);
    drawTextScaled(204, 48, stamp_labels[@as(usize, @intCast(stamp_kind))], GB_DARK, 1);
    drawButton(.{ .x = 204, .y = 58, .w = 64, .h = 16 }, "C NEXT", false);
    drawButton(.{ .x = 204, .y = 80, .w = 64, .h = 16 }, "A PLACE", true);
    drawButton(.{ .x = 204, .y = 170, .w = 64, .h = 16 }, "B VIEW", false);
}

fn drawInfo() void {
    fillRectI32(42, 52, 236, 110, GB_MID_LIGHT);
    drawRect(42, 52, 236, 110, GB_DARK);
    drawTextScaled(54, 66, info_title, GB_DARK, 2);
    drawTextScaled(54, 94, info_body, GB_DARK, 1);
    drawTextScaled(54, 130, "PRESS A OR B", GB_DARK, 1);
}

fn drawFooterHints() void {
    const y = LCD_Y + LCD_H - 12;
    blendRectI32(LCD_X, y, LCD_W, 12, .{ 0x0F, 0x38, 0x0F, 0x34 });
    switch (mode) {
        .menu => drawTextScaled(LCD_X + 6, y + 3, "D-PAD MOVE  A SELECT", GB_DARK, 1),
        .shoot => drawTextScaled(LCD_X + 6, y + 3, "A SHOT  B MENU", GB_DARK, 1),
        .album => drawTextScaled(LCD_X + 6, y + 3, "A VIEW  B MENU  P/N PAGE", GB_DARK, 1),
        .view => drawTextScaled(LCD_X + 6, y + 3, "L/R PHOTO  S STAMP  B ALBUM", GB_DARK, 1),
        .stamp => drawTextScaled(LCD_X + 6, y + 3, "A PLACE  C TOOL  B VIEW", GB_DARK, 1),
        .info => drawTextScaled(LCD_X + 6, y + 3, "A OR B TO CLOSE", GB_DARK, 1),
    }
}

fn menuItemRect(index: i32) Rect {
    const col = @mod(index, 3);
    const row = @divTrunc(index, 3);
    return .{
        .x = 34 + col * 84,
        .y = 56 + row * 52,
        .w = 78,
        .h = 44,
    };
}

fn menuItemAt(x: i32, y: i32) ?i32 {
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        if (pointInRect(x, y, menuItemRect(i))) return i;
    }
    return null;
}

fn drawMenuGlyph(index: i32, x: i32, y: i32, color: [4]u8) void {
    switch (index) {
        0 => { // camera
            drawRect(x, y + 4, 14, 10, color);
            fillRectI32(x + 4, y + 2, 6, 2, color);
            fillCircle(x + 7, y + 9, 3, color);
            fillCircle(x + 7, y + 9, 1, GB_MID_LIGHT);
        },
        1 => { // eye
            drawRect(x, y + 6, 14, 6, color);
            fillCircle(x + 7, y + 9, 2, color);
        },
        2 => { // album
            drawRect(x, y + 3, 14, 11, color);
            drawLine(x + 4, y + 3, x + 4, y + 14, color);
        },
        3 => { // stamp
            fillRectI32(x + 3, y + 3, 8, 8, color);
            fillRectI32(x + 5, y + 11, 4, 3, color);
        },
        4 => { // play
            fillRectI32(x + 2, y + 4, 2, 8, color);
            fillRectI32(x + 5, y + 6, 2, 4, color);
            fillRectI32(x + 8, y + 5, 2, 6, color);
            fillRectI32(x + 11, y + 7, 2, 2, color);
        },
        else => { // link
            drawLine(x + 1, y + 6, x + 7, y + 2, color);
            drawLine(x + 7, y + 2, x + 13, y + 6, color);
            drawLine(x + 7, y + 2, x + 7, y + 13, color);
        },
    }
}

fn drawLivePreview(area: Rect, phase: i32) void {
    var y: i32 = 0;
    while (y < PHOTO_H) : (y += 1) {
        var x: i32 = 0;
        while (x < PHOTO_W) : (x += 1) {
            const idx = liveSample(x, y, phase);
            fillRectI32(area.x + x * 4, area.y + y * 4, 4, 4, paletteColor(idx));
        }
    }
}

fn liveSample(x: i32, y: i32, phase: i32) u8 {
    const v = @mod((x * 17 + y * 29 + phase * 5 + (x ^ (y * 3)) * 11), 256);
    if (v < 52) return 0;
    if (v < 112) return 1;
    if (v < 188) return 2;
    return 3;
}

fn drawThumbSlot(x: i32, y: i32, idx: i32) void {
    fillRectI32(x, y, 44, 36, GB_MID_LIGHT);
    drawRect(x, y, 44, 36, GB_DARK);
    if (idx < photo_count) {
        drawPhotoScaled(idx, x + 6, y + 2, 1);
        drawRect(x + 5, y + 1, 34, 34, GB_DARK);
        drawNumber(x + 32, y + 28, idx + 1, GB_DARK, 1);
    } else {
        drawTextScaled(x + 15, y + 15, "--", GB_DARK, 1);
    }
    if (idx == album_selected) drawRect(x - 1, y - 1, 46, 38, GB_DARK);
}

fn albumThumbAt(x: i32, y: i32) ?i32 {
    const start = album_page * ALBUM_PAGE_SIZE;
    var row: i32 = 0;
    while (row < 3) : (row += 1) {
        var col: i32 = 0;
        while (col < 5) : (col += 1) {
            const r = Rect{ .x = 32 + col * 50, .y = 42 + row * 40, .w = 44, .h = 36 };
            if (pointInRect(x, y, r)) return start + row * 5 + col;
        }
    }
    return null;
}

fn drawPhotoScaled(photo_index: i32, x: i32, y: i32, scale: i32) void {
    if (photo_index < 0 or photo_index >= photo_count) return;
    const p = photos[@as(usize, @intCast(photo_index))];
    var py: i32 = 0;
    while (py < PHOTO_H) : (py += 1) {
        var px: i32 = 0;
        while (px < PHOTO_W) : (px += 1) {
            const idx = p[@as(usize, @intCast(py * PHOTO_W + px))];
            fillRectI32(x + px * scale, y + py * scale, scale, scale, paletteColor(idx));
        }
    }
}

fn paletteColor(index: u8) [4]u8 {
    return switch (index & 3) {
        0 => GB_DARK,
        1 => GB_MID_DARK,
        2 => GB_MID_LIGHT,
        else => GB_LIGHT,
    };
}

fn drawButton(r: Rect, label: []const u8, primary: bool) void {
    fillRectI32(r.x, r.y, r.w, r.h, if (primary) GB_MID_DARK else GB_MID_LIGHT);
    drawRect(r.x, r.y, r.w, r.h, GB_DARK);
    drawTextScaled(r.x + 5, r.y + 5, label, if (primary) GB_LIGHT else GB_DARK, 1);
}

fn drawNumber(x: i32, y: i32, n: i32, c: [4]u8, scale: i32) void {
    var buf: [12]u8 = undefined;
    const len = formatInt(n, &buf);
    drawTextScaled(x, y, buf[0..len], c, scale);
}

fn formatInt(n: i32, out: []u8) usize {
    if (out.len == 0) return 0;
    if (n == 0) {
        out[0] = '0';
        return 1;
    }
    var value = if (n < 0) -n else n;
    var tmp: [12]u8 = undefined;
    var tlen: usize = 0;
    while (value > 0 and tlen < tmp.len) : (tlen += 1) {
        tmp[tlen] = @as(u8, @intCast('0' + @mod(value, 10)));
        value = @divTrunc(value, 10);
    }
    var i: usize = 0;
    if (n < 0 and i < out.len) {
        out[i] = '-';
        i += 1;
    }
    var j: usize = 0;
    while (j < tlen and i < out.len) : (j += 1) {
        out[i] = tmp[tlen - 1 - j];
        i += 1;
    }
    return i;
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn drawLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: [4]u8) void {
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

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: [4]u8) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: [4]u8) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) setPixelI32(x, y, c);
        }
    }
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
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
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

fn setPixelI32(x: i32, y: i32, c: [4]u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
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
