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
const XK_RETURN: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_UP: i32 = 0xFF52;
const XK_DOWN: i32 = 0xFF54;

const MENU_X: i32 = 176;
const MENU_Y: i32 = 58;
const MENU_W: i32 = 118;
const MENU_H: i32 = 30;
const MENU_GAP: i32 = 7;
const SUB_X: i32 = 86;
const SUB_Y: i32 = 44;
const SUB_W: i32 = 212;
const SUB_H: i32 = 132;

const Color = [4]u8;
const C_TEXT: Color = .{ 0xD6, 0xF8, 0xD2, 0xFF };
const C_TEXT_DIM: Color = .{ 0x9A, 0xC6, 0x96, 0xFF };
const C_DARK: Color = .{ 0x04, 0x0E, 0x08, 0xFF };
const C_BLACK: Color = .{ 0x00, 0x00, 0x00, 0xFF };

const Menu = enum(u8) { memory, music, live, settings };
const View = enum(u8) { main, submenu };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var view: View = .main;
var selected: Menu = .memory;
var submenu_selected: i32 = 0;
var sel_pos_q8: i32 = 0;
var pulse: i32 = 0;
var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;
var needs_redraw: bool = true;
var initialized: bool = false;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var time_advanced: bool = false;
var next_wake_at_ms: i64 = 0;

const memory_items = [_][]const u8{ "HARDDISK", "MEMORY UNIT A", "MEMORY UNIT B", "FREE BLOCKS" };
const music_items = [_][]const u8{ "SOUNDTRACKS", "RIP CD", "PLAYLISTS", "COPY TO HDD" };
const live_items = [_][]const u8{ "SIGN IN", "ACCOUNT", "NETWORK", "CONNECT" };
const settings_items = [_][]const u8{ "CLOCK", "VIDEO", "AUDIO", "NETWORK" };

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
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    if (view == .main) {
        switch (x11_key) {
            XK_UP, 'w', 'W' => stepMenu(-1),
            XK_DOWN, 's', 'S' => stepMenu(1),
            XK_RETURN, ' ', 'a', 'A' => openSelectedMenu(),
            else => return 0,
        }
    } else {
        switch (x11_key) {
            XK_UP, 'w', 'W' => stepSubmenu(-1),
            XK_DOWN, 's', 'S' => stepSubmenu(1),
            XK_ESCAPE, XK_BACKSPACE, 'b', 'B' => closeSubmenu(),
            else => return 0,
        }
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

    if (view == .main) {
        if (menuIndexAt(x_px, y_px)) |idx| {
            selected = @as(Menu, @enumFromInt(@as(u8, @intCast(idx))));
            needs_redraw = true;
            if (down and !primary_down) openSelectedMenu();
        }
    } else {
        if (down and !primary_down) {
            if (submenuBackAt(x_px, y_px)) {
                closeSubmenu();
            } else if (submenuItemAt(x_px, y_px)) |idx| {
                submenu_selected = idx;
            } else if (!pointInRect(x_px, y_px, .{ .x = SUB_X, .y = SUB_Y, .w = SUB_W, .h = SUB_H })) {
                closeSubmenu();
            }
            needs_redraw = true;
        }
    }

    if (secondary and !secondary_down and view == .submenu) {
        closeSubmenu();
        needs_redraw = true;
    }

    primary_down = down;
    secondary_down = secondary;
    return if (needs_redraw) 1 else 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn advanceTransactionTime() void {
    if (time_advanced) return;
    time_advanced = true;
    ensureInit();
    pulse = @intCast(@mod(@divTrunc(begun_at_ms, 16), 1024));
    const target = @as(i32, @intFromEnum(selected)) * 256;
    sel_pos_q8 += @divTrunc(target - sel_pos_q8, 4);
    needs_redraw = true;
    next_wake_at_ms = if (begun_at_ms <= std.math.maxInt(i64) - 16) begun_at_ms + 16 else begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    ensureInit();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    needs_redraw = false;
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
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
    committed_at_ms = begun_at_ms;
    const wake = next_wake_at_ms;
    transaction_phase = .ready;
    return wake;
}

fn ensureInit() void {
    if (initialized) return;
    resetState();
    initialized = true;
}

fn resetState() void {
    view = .main;
    selected = .memory;
    submenu_selected = 0;
    sel_pos_q8 = 0;
    pulse = 0;
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    needs_redraw = true;
}

fn menuLabel(menu: Menu) []const u8 {
    return switch (menu) {
        .memory => "MEMORY",
        .music => "MUSIC",
        .live => "XBOX LIVE",
        .settings => "SETTINGS",
    };
}

fn menuIndexAt(x: i32, y: i32) ?i32 {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const r = Rect{ .x = MENU_X, .y = MENU_Y + i * (MENU_H + MENU_GAP), .w = MENU_W, .h = MENU_H };
        if (pointInRect(x, y, r)) return i;
    }
    return null;
}

fn submenuItems(menu: Menu) []const []const u8 {
    return switch (menu) {
        .memory => &memory_items,
        .music => &music_items,
        .live => &live_items,
        .settings => &settings_items,
    };
}

fn submenuItemAt(x: i32, y: i32) ?i32 {
    const items = submenuItems(selected);
    var i: i32 = 0;
    while (i < @as(i32, @intCast(items.len))) : (i += 1) {
        const r = Rect{ .x = SUB_X + 14, .y = SUB_Y + 35 + i * 20, .w = SUB_W - 28, .h = 16 };
        if (pointInRect(x, y, r)) return i;
    }
    return null;
}

fn submenuBackAt(x: i32, y: i32) bool {
    return pointInRect(x, y, .{ .x = SUB_X + SUB_W - 54, .y = SUB_Y + SUB_H - 24, .w = 44, .h = 14 });
}

fn openSelectedMenu() void {
    view = .submenu;
    submenu_selected = 0;
}

fn closeSubmenu() void {
    view = .main;
}

fn stepMenu(delta: i32) void {
    const now = @as(i32, @intFromEnum(selected));
    const next = @mod(now + delta + 4, 4);
    selected = @as(Menu, @enumFromInt(@as(u8, @intCast(next))));
}

fn stepSubmenu(delta: i32) void {
    const count = @as(i32, @intCast(submenuItems(selected).len));
    submenu_selected = @mod(submenu_selected + delta + count, count);
}

fn drawFrame() void {
    drawBackground();
    drawOrbAndBrand();
    drawMainMenu();
    if (view == .submenu) drawSubmenu();
}

fn drawBackground() void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(RENDER_H))) : (y += 1) {
        const g_base: u8 = @as(u8, @intCast(18 + @divTrunc(y * 34, @as(i32, @intCast(RENDER_H)))));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(RENDER_W))) : (x += 1) {
            const drift = ((x * 3 + y * 5 + pulse) & 31) - 15;
            const g = clampU8(g_base, drift);
            const r = clampU8(5, @divTrunc(drift, 4));
            const b = clampU8(8, @divTrunc(drift, 3));
            setPixelI32(x, y, .{ r, g, b, 0xFF });
        }
    }

    drawSoftRing(76, 104, 72, .{ 0x16, 0x54, 0x22, 0x62 });
    drawSoftRing(76, 104, 48, .{ 0x34, 0x92, 0x3E, 0x78 });
    drawSoftRing(250, 36, 40, .{ 0x20, 0x62, 0x2A, 0x48 });
    drawSoftRing(278, 182, 52, .{ 0x14, 0x4A, 0x1D, 0x3E });
}

fn drawSoftRing(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const d2 = dx * dx + dy * dy;
            if (d2 <= r * r and d2 >= (r - 10) * (r - 10)) {
                if (((x + y + pulse) & 1) == 0) blendPixelI32(x, y, c);
            }
        }
    }
}

fn drawOrbAndBrand() void {
    fillCircle(76, 104, 34, .{ 0x1D, 0x72, 0x2A, 0xFF });
    fillCircle(76, 104, 26, .{ 0x2D, 0xA8, 0x3E, 0xFF });
    drawRing(76, 104, 34, .{ 0x0A, 0x31, 0x11, 0xFF });
    drawLine(58, 84, 94, 124, .{ 0xD5, 0xF7, 0x8D, 0xFF });
    drawLine(94, 84, 58, 124, .{ 0xD5, 0xF7, 0x8D, 0xFF });
    drawTextScaled(34, 148, "XBOX", .{ 0xC6, 0xF3, 0x82, 0xFF }, 3);
}

fn drawMainMenu() void {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const y = MENU_Y + i * (MENU_H + MENU_GAP);
        const dist = absI32(sel_pos_q8 - i * 256);
        const hot = @max(0, 176 - @divTrunc(dist, 2));
        const glow: Color = .{
            0x22,
            @as(u8, @intCast(@min(255, 54 + hot))),
            0x2B,
            @as(u8, @intCast(@min(220, 52 + @divTrunc(hot, 2)))),
        };
        blendRectI32(MENU_X, y, MENU_W, MENU_H, glow);
        drawRect(MENU_X, y, MENU_W, MENU_H, .{ 0x23, 0x66, 0x2D, 0xFF });

        const menu = @as(Menu, @enumFromInt(@as(u8, @intCast(i))));
        const label = menuLabel(menu);
        const txt = if (menu == selected) C_TEXT else C_TEXT_DIM;
        drawTextScaled(MENU_X + 10, y + 9, label, txt, 2);
    }

    drawTextScaled(176, 192, "A SELECT", C_TEXT_DIM, 2);
    drawTextScaled(252, 192, "B BACK", C_TEXT_DIM, 2);
}

fn drawSubmenu() void {
    blendRectI32(SUB_X, SUB_Y, SUB_W, SUB_H, .{ 0x08, 0x24, 0x12, 0xC8 });
    drawRect(SUB_X, SUB_Y, SUB_W, SUB_H, .{ 0x3A, 0x88, 0x44, 0xFF });
    drawTextScaled(SUB_X + 14, SUB_Y + 12, menuLabel(selected), C_TEXT, 2);

    const items = submenuItems(selected);
    var i: i32 = 0;
    while (i < @as(i32, @intCast(items.len))) : (i += 1) {
        const row_y = SUB_Y + 35 + i * 20;
        if (i == submenu_selected) {
            blendRectI32(SUB_X + 12, row_y - 2, SUB_W - 24, 18, .{ 0x39, 0x99, 0x4B, 0xA8 });
        }
        drawTextScaled(SUB_X + 18, row_y + 3, items[@as(usize, @intCast(i))], if (i == submenu_selected) C_TEXT else C_TEXT_DIM, 2);
    }

    drawTextScaled(SUB_X + SUB_W - 50, SUB_Y + SUB_H - 20, "BACK", C_TEXT_DIM, 2);
}

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: Color) void {
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

fn drawRing(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const d2 = dx * dx + dy * dy;
            if (d2 <= r * r and d2 >= (r - 1) * (r - 1)) setPixelI32(x, y, c);
        }
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

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            const px = x + @as(i32, @intCast(rx)) * scale;
            const py = y + @as(i32, @intCast(ry)) * scale;
            fillRectI32(px, py, scale, scale, c);
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
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn blendRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) blendPixelI32(x, y, c);
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) setPixelI32(x, y, c);
    }
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
    pixel_buf[idx + 0] = blendChannel(src[0], pixel_buf[idx + 0], a, inv);
    pixel_buf[idx + 1] = blendChannel(src[1], pixel_buf[idx + 1], a, inv);
    pixel_buf[idx + 2] = blendChannel(src[2], pixel_buf[idx + 2], a, inv);
    pixel_buf[idx + 3] = 0xFF;
}

fn blendChannel(src: u8, dst: u8, a: u16, inv: u16) u8 {
    return @as(u8, @intCast(@divTrunc(@as(u16, src) * a + @as(u16, dst) * inv + 127, 255)));
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
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

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}
