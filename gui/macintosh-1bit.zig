const std = @import("std");
const ktx_sdr = @import("ktx2_rgba8_srgb");

const WIDTH: usize = 512;
const HEIGHT: usize = 342;
const PIXELS: usize = WIDTH * HEIGHT;
const ROW_BYTES: usize = WIDTH / 8;
const BITPLANE_BYTES: usize = ROW_BYTES * HEIGHT;
const SDR_BYTES: usize = ktx_sdr.HEADER_SIZE + PIXELS * 4;
const OUTPUT_CONTENT_TYPE = ktx_sdr.CONTENT_TYPE;
const BTN_PRIMARY: i32 = 1;
const FLAG_KEY_DOWN: i32 = 1;

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};
const Mode = enum { idle, drag_window, drag_disk };
const Menu = enum { none, apple, file, edit, view };
const Lifecycle = enum { initializing, ready, updating };

var bitplane: [BITPLANE_BYTES]u8 = [_]u8{0} ** BITPLANE_BYTES;
var output: [SDR_BYTES]u8 align(16) = undefined;
var lifecycle: Lifecycle = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var render_count: u32 = 0;

var window_x: i32 = 54;
var window_y: i32 = 49;
var window_visible: bool = true;
var disk_x: i32 = 442;
var disk_y: i32 = 41;
var disk_selected: bool = false;
var menu: Menu = .none;
var mode: Mode = .idle;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var primary_down: bool = false;
var cursor_x: i32 = 275;
var cursor_y: i32 = 185;
var cursor_visible: bool = true;

export fn input_ptr() u32 {
    return 0;
}
export fn input_bytes_cap() u32 {
    return 0;
}
export fn output_bytes_cap() u32 {
    return @intCast(SDR_BYTES);
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    lifecycle = .updating;
}

export fn finish_update() i64 {
    requireUpdate();
    committed_at_ms = begun_at_ms;
    lifecycle = .ready;
    return begun_at_ms;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    requireUpdate();
    const was_x = cursor_x;
    const was_y = cursor_y;
    const was_visible = cursor_visible;
    if (x < 0 or y < 0) {
        cursor_visible = false;
        primary_down = false;
        mode = .idle;
        return @intFromBool(was_visible);
    }

    cursor_x = clamp(x, 0, @as(i32, @intCast(WIDTH)) - 1);
    cursor_y = clamp(y, 0, @as(i32, @intCast(HEIGHT)) - 1);
    cursor_visible = true;
    const down = (button_mask & BTN_PRIMARY) != 0;

    if (down and !primary_down) {
        const hit_menu = menuAt(cursor_x, cursor_y);
        if (hit_menu != .none) {
            menu = if (menu == hit_menu) .none else hit_menu;
            mode = .idle;
        } else if (menu != .none) {
            menu = .none;
        } else if (window_visible and closeBox().contains(cursor_x, cursor_y)) {
            window_visible = false;
        } else if (window_visible and titleBar().contains(cursor_x, cursor_y)) {
            mode = .drag_window;
            drag_dx = cursor_x - window_x;
            drag_dy = cursor_y - window_y;
        } else if (diskRect().contains(cursor_x, cursor_y)) {
            disk_selected = true;
            mode = .drag_disk;
            drag_dx = cursor_x - disk_x;
            drag_dy = cursor_y - disk_y;
        } else if (!window_visible and cursor_x > 420 and cursor_y < 120) {
            window_visible = true;
        } else {
            disk_selected = false;
            mode = .idle;
        }
    } else if (down) {
        switch (mode) {
            .drag_window => {
                window_x = clamp(cursor_x - drag_dx, 3, @as(i32, @intCast(WIDTH)) - 355);
                window_y = clamp(cursor_y - drag_dy, 22, @as(i32, @intCast(HEIGHT)) - 240);
            },
            .drag_disk => {
                disk_x = clamp(cursor_x - drag_dx, 6, @as(i32, @intCast(WIDTH)) - 64);
                disk_y = clamp(cursor_y - drag_dy, 24, @as(i32, @intCast(HEIGHT)) - 62);
            },
            .idle => {},
        }
    } else if (primary_down) {
        mode = .idle;
    }
    primary_down = down;
    return @intFromBool(was_x != cursor_x or was_y != cursor_y or !was_visible or down or menu != .none);
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    if (x11_key == 0xff1b) {
        menu = .none;
        mode = .idle;
        return 1;
    }
    if (x11_key == 'r' or x11_key == 'R') {
        resetState();
        return 1;
    }
    return 0;
}

export fn render(input_size: u32) packed struct(u64) { output_size: u32, output_ptr: u31, failed: u1 } {
    if (input_size != 0 or (lifecycle != .initializing and lifecycle != .ready)) @trap();
    drawDesktop();
    const size = expandSDR();
    lifecycle = .ready;
    render_count +%= 1;
    return .{ .output_size = @intCast(size), .output_ptr = @intCast(@intFromPtr(&output[0])), .failed = 0 };
}

fn requireUpdate() void {
    if (lifecycle != .updating) @trap();
}

fn resetState() void {
    window_x = 54;
    window_y = 49;
    window_visible = true;
    disk_x = 442;
    disk_y = 41;
    disk_selected = false;
    menu = .none;
    mode = .idle;
    primary_down = false;
    cursor_x = 275;
    cursor_y = 185;
    cursor_visible = true;
}

fn expandSDR() usize {
    const size = ktx_sdr.writeHeader(&output, WIDTH, HEIGHT) orelse @trap();
    var dst = ktx_sdr.HEADER_SIZE;
    var pixel: usize = 0;
    while (pixel < PIXELS) : (pixel += 1) {
        const black: u8 = (bitplane[pixel >> 3] >> @as(u3, @intCast(7 - (pixel & 7)))) & 1;
        const value: u8 = if (black != 0) 0 else 255;
        output[dst] = value;
        output[dst + 1] = value;
        output[dst + 2] = value;
        output[dst + 3] = 255;
        dst += 4;
    }
    return size;
}

fn drawDesktop() void {
    @memset(&bitplane, 0);
    fillPattern(0, 20, @intCast(WIDTH), @intCast(HEIGHT - 20), 0b10000000, 0b00001000);
    drawMenuBar();
    drawDisk(disk_x, disk_y, disk_selected);
    drawTrash(449, 274);
    if (window_visible) drawWindow();
    if (menu != .none) drawMenu();
    if (cursor_visible) drawCursor(cursor_x, cursor_y);
}

fn drawMenuBar() void {
    fillRect(0, 0, @intCast(WIDTH), 20, false);
    hline(0, 19, @intCast(WIDTH));
    drawApple(12, 4);
    drawText(38, 6, "File");
    drawText(78, 6, "Edit");
    drawText(118, 6, "View");
    drawText(164, 6, "Special");
    drawText(421, 6, "Finder");
    drawMenuBarStatus(489, 4);

    switch (menu) {
        .apple => invertRect(5, 1, 26, 18),
        .file => invertRect(33, 1, 39, 18),
        .edit => invertRect(74, 1, 38, 18),
        .view => invertRect(114, 1, 44, 18),
        .none => {},
    }
}

fn drawApple(x: i32, y: i32) void {
    fillRect(x + 7, y, 3, 2, true);
    setPixel(x + 10, y - 1, true);
    fillRect(x + 3, y + 3, 9, 9, true);
    fillRect(x + 1, y + 5, 13, 5, true);
    setPixel(x + 13, y + 4, false);
    setPixel(x + 2, y + 11, true);
    setPixel(x + 12, y + 11, true);
}

fn drawMenuBarStatus(x: i32, y: i32) void {
    rect(x, y + 1, 13, 12);
    rect(x + 2, y + 3, 9, 8);
    fillRect(x + 5, y, 3, 2, true);
    fillRect(x + 5, y + 6, 3, 3, true);
}

fn drawWindow() void {
    const x = window_x;
    const y = window_y;
    const w: i32 = 350;
    const h: i32 = 236;
    fillPattern(x + 5, y + 5, w, h, 0b10101010, 0b01010101);
    fillRect(x, y, w, h, false);
    rect(x, y, w, h);
    rect(x + 1, y + 1, w - 2, h - 2);
    rect(x + 3, y + 3, w - 6, h - 6);
    hline(x + 2, y + 19, w - 4);
    drawTitleStripes(x + 28, x + 117, y + 5);
    drawTitleStripes(x + 231, x + w - 7, y + 5);
    fillRect(x + 8, y + 5, 12, 11, false);
    rect(x + 8, y + 5, 12, 11);
    drawText(x + 126, y + 7, "QIP Disk");

    drawFolder(x + 42, y + 48);
    centeredLabel(x + 60, y + 88, "System");
    drawDocument(x + 139, y + 45, false);
    centeredLabel(x + 153, y + 88, "Read Me");
    drawPaintIcon(x + 236, y + 45);
    centeredLabel(x + 252, y + 88, "MacPaint");

    drawWindowScrollBars(x, y, w, h);
    rect(x + w - 15, y + h - 15, 12, 12);
    hline(x + w - 13, y + h - 5, 8);
    hline(x + w - 10, y + h - 8, 5);
}

fn drawWindowScrollBars(x: i32, y: i32, w: i32, h: i32) void {
    const right = x + w - 16;
    const bottom = y + h - 16;
    vline(right, y + 20, h - 20);
    hline(x + 3, bottom, w - 3);

    rect(right + 1, y + 21, 14, 14);
    drawTriangleUp(right + 5, y + 25);
    rect(right + 1, bottom - 14, 14, 14);
    drawTriangleDown(right + 5, bottom - 10);
    fillPattern(right + 2, y + 36, 12, h - 67, 0b10101010, 0b01010101);
    fillRect(right + 2, y + 56, 12, 28, false);
    rect(right + 2, y + 56, 12, 28);

    rect(x + 3, bottom + 1, 14, 14);
    drawTriangleLeft(x + 7, bottom + 5);
    rect(right - 14, bottom + 1, 14, 14);
    drawTriangleRight(right - 10, bottom + 5);
    fillPattern(x + 18, bottom + 2, w - 50, 12, 0b10101010, 0b01010101);
    fillRect(x + 62, bottom + 2, 55, 12, false);
    rect(x + 62, bottom + 2, 55, 12);
}

fn drawTriangleUp(x: i32, y: i32) void {
    hline(x + 3, y, 1);
    hline(x + 2, y + 1, 3);
    hline(x + 1, y + 2, 5);
    hline(x, y + 3, 7);
}

fn drawTriangleDown(x: i32, y: i32) void {
    hline(x, y, 7);
    hline(x + 1, y + 1, 5);
    hline(x + 2, y + 2, 3);
    hline(x + 3, y + 3, 1);
}

fn drawTriangleLeft(x: i32, y: i32) void {
    vline(x, y + 3, 1);
    vline(x + 1, y + 2, 3);
    vline(x + 2, y + 1, 5);
    vline(x + 3, y, 7);
}

fn drawTriangleRight(x: i32, y: i32) void {
    vline(x, y, 7);
    vline(x + 1, y + 1, 5);
    vline(x + 2, y + 2, 3);
    vline(x + 3, y + 3, 1);
}

fn drawTitleStripes(x0: i32, x1: i32, y: i32) void {
    var yy = y;
    while (yy < y + 11) : (yy += 3) hline(x0, yy, x1 - x0);
}

fn drawDisk(x: i32, y: i32, selected: bool) void {
    fillRect(x + 3, y + 4, 43, 31, false);
    rect(x + 3, y + 4, 43, 31);
    rect(x + 6, y + 7, 37, 8);
    hline(x + 10, y + 26, 28);
    fillRect(x + 35, y + 27, 3, 3, true);
    if (selected) fillRect(x - 3, y + 39, 55, 10, true);
    centeredLabel(x + 24, y + 41, "QIP Disk");
    if (selected) invertRect(x - 3, y + 39, 55, 10);
}

fn drawTrash(x: i32, y: i32) void {
    rect(x + 8, y + 8, 28, 34);
    fillPattern(x + 10, y + 10, 24, 30, 0b10001000, 0b00100010);
    rect(x + 5, y + 5, 34, 5);
    rect(x + 14, y + 1, 16, 5);
    drawText(x + 7, y + 47, "Trash");
}

fn drawFolder(x: i32, y: i32) void {
    fillRect(x + 2, y + 9, 37, 27, false);
    rect(x + 2, y + 9, 37, 27);
    rect(x + 6, y + 5, 17, 7);
    hline(x + 5, y + 14, 31);
    fillPattern(x + 5, y + 17, 31, 16, 0b10101010, 0b01010101);
}

fn drawDocument(x: i32, y: i32, selected: bool) void {
    fillRect(x, y, 29, 39, false);
    rect(x, y, 29, 39);
    hline(x + 5, y + 9, 18);
    hline(x + 5, y + 15, 18);
    hline(x + 5, y + 21, 15);
    hline(x + 5, y + 27, 18);
    if (selected) invertRect(x - 2, y - 2, 33, 43);
}

fn drawPaintIcon(x: i32, y: i32) void {
    rect(x, y, 34, 39);
    rect(x + 3, y + 3, 28, 9);
    drawLine(x + 7, y + 31, x + 25, y + 16);
    drawLine(x + 8, y + 32, x + 27, y + 17);
    fillRect(x + 5, y + 16, 5, 5, true);
    fillPattern(x + 18, y + 26, 10, 8, 0b10101010, 0b01010101);
}

fn drawMenu() void {
    const r = menuRect(menu);
    fillPattern(r.x + 4, r.y + 4, r.w, r.h, 0b10101010, 0b01010101);
    fillRect(r.x, r.y, r.w, r.h, false);
    rect(r.x, r.y, r.w, r.h);
    switch (menu) {
        .apple => {
            drawText(r.x + 9, r.y + 8, "About QIP");
            hline(r.x + 4, r.y + 20, r.w - 8);
            drawText(r.x + 9, r.y + 27, "Finder");
        },
        .file => {
            drawText(r.x + 9, r.y + 8, "Open");
            drawText(r.x + 9, r.y + 23, "Close");
            hline(r.x + 4, r.y + 35, r.w - 8);
            drawText(r.x + 9, r.y + 42, "Print");
        },
        .edit => {
            drawText(r.x + 9, r.y + 8, "Undo");
            hline(r.x + 4, r.y + 20, r.w - 8);
            drawText(r.x + 9, r.y + 27, "Cut");
            drawText(r.x + 9, r.y + 42, "Copy");
            drawText(r.x + 9, r.y + 57, "Paste");
        },
        .view => {
            drawText(r.x + 9, r.y + 8, "by Icon");
            drawText(r.x + 9, r.y + 23, "by Name");
        },
        .none => {},
    }
}

fn drawCursor(x: i32, y: i32) void {
    const rows = [_]u16{
        0b1000000000000000, 0b1100000000000000, 0b1010000000000000, 0b1001000000000000,
        0b1000100000000000, 0b1000010000000000, 0b1000001000000000, 0b1000000100000000,
        0b1001111110000000, 0b1010010000000000, 0b1100010000000000, 0b0000001000000000,
        0b0000001000000000, 0b0000000100000000, 0b0000000100000000, 0,
    };
    var ry: usize = 0;
    while (ry < rows.len) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 16) : (rx += 1) {
            if ((rows[ry] & (@as(u16, 1) << @as(u4, @intCast(15 - rx)))) != 0)
                setPixel(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), true);
        }
    }
}

fn menuAt(x: i32, y: i32) Menu {
    if (y < 0 or y >= 19) return .none;
    if (x >= 5 and x < 31) return .apple;
    if (x >= 33 and x < 72) return .file;
    if (x >= 74 and x < 112) return .edit;
    if (x >= 114 and x < 158) return .view;
    return .none;
}

fn menuRect(which: Menu) Rect {
    return switch (which) {
        .apple => .{ .x = 5, .y = 19, .w = 90, .h = 47 },
        .file => .{ .x = 33, .y = 19, .w = 82, .h = 61 },
        .edit => .{ .x = 74, .y = 19, .w = 82, .h = 76 },
        .view => .{ .x = 114, .y = 19, .w = 91, .h = 47 },
        .none => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
}

fn titleBar() Rect {
    return .{ .x = window_x + 22, .y = window_y + 2, .w = 323, .h = 17 };
}
fn closeBox() Rect {
    return .{ .x = window_x + 8, .y = window_y + 5, .w = 12, .h = 11 };
}
fn diskRect() Rect {
    return .{ .x = disk_x, .y = disk_y, .w = 51, .h = 51 };
}

fn centeredLabel(cx: i32, y: i32, text: []const u8) void {
    drawText(cx - @as(i32, @intCast((text.len * 6) / 2)), y, text);
}

fn drawText(x: i32, y: i32, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawChar(x + @as(i32, @intCast(i * 6)), y, text[i]);
}

fn drawChar(x: i32, y: i32, character: u8) void {
    const rows = glyph(character);
    for (rows, 0..) |row, ry| {
        var rx: usize = 0;
        while (rx < 5) : (rx += 1) {
            if ((row & (@as(u8, 1) << @as(u3, @intCast(4 - rx)))) != 0)
                setPixel(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), true);
        }
    }
}

fn glyph(ch: u8) [7]u8 {
    return switch (ch) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 15, 16, 16, 16, 16, 16, 15 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 15, 16, 16, 23, 17, 17, 15 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
        'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 27, 17 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        'a' => .{ 0, 0, 14, 1, 15, 17, 15 },
        'b' => .{ 16, 16, 22, 25, 17, 17, 30 },
        'c' => .{ 0, 0, 15, 16, 16, 16, 15 },
        'd' => .{ 1, 1, 13, 19, 17, 17, 15 },
        'e' => .{ 0, 0, 14, 17, 31, 16, 15 },
        'f' => .{ 6, 9, 8, 28, 8, 8, 8 },
        'g' => .{ 0, 0, 15, 17, 15, 1, 14 },
        'h' => .{ 16, 16, 22, 25, 17, 17, 17 },
        'i' => .{ 4, 0, 12, 4, 4, 4, 14 },
        'j' => .{ 2, 0, 6, 2, 2, 18, 12 },
        'k' => .{ 16, 16, 18, 20, 24, 20, 18 },
        'l' => .{ 12, 4, 4, 4, 4, 4, 14 },
        'm' => .{ 0, 0, 26, 21, 21, 21, 21 },
        'n' => .{ 0, 0, 22, 25, 17, 17, 17 },
        'o' => .{ 0, 0, 14, 17, 17, 17, 14 },
        'p' => .{ 0, 0, 30, 17, 30, 16, 16 },
        'q' => .{ 0, 0, 15, 17, 15, 1, 1 },
        'r' => .{ 0, 0, 22, 25, 16, 16, 16 },
        's' => .{ 0, 0, 15, 16, 14, 1, 30 },
        't' => .{ 8, 8, 28, 8, 8, 9, 6 },
        'u' => .{ 0, 0, 17, 17, 17, 19, 13 },
        'v' => .{ 0, 0, 17, 17, 17, 10, 4 },
        'w' => .{ 0, 0, 17, 17, 21, 21, 10 },
        'x' => .{ 0, 0, 17, 10, 4, 10, 17 },
        'y' => .{ 0, 0, 17, 17, 15, 1, 14 },
        'z' => .{ 0, 0, 31, 2, 4, 8, 31 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => .{ 14, 17, 2, 4, 4, 0, 4 },
    };
}

fn setPixel(x: i32, y: i32, black: bool) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(WIDTH)) or y >= @as(i32, @intCast(HEIGHT))) return;
    const pixel = @as(usize, @intCast(y)) * WIDTH + @as(usize, @intCast(x));
    const mask = @as(u8, 1) << @as(u3, @intCast(7 - (pixel & 7)));
    if (black) bitplane[pixel >> 3] |= mask else bitplane[pixel >> 3] &= ~mask;
}

fn fillRect(x: i32, y: i32, w: i32, h: i32, black: bool) void {
    if (w <= 0 or h <= 0) return;
    var yy = @max(y, 0);
    const end_y = @min(y + h, @as(i32, @intCast(HEIGHT)));
    const start_x = @max(x, 0);
    const end_x = @min(x + w, @as(i32, @intCast(WIDTH)));
    while (yy < end_y) : (yy += 1) {
        var xx = start_x;
        while (xx < end_x) : (xx += 1) setPixel(xx, yy, black);
    }
}

fn fillPattern(x: i32, y: i32, w: i32, h: i32, even: u8, odd: u8) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        const pattern = if ((yy & 1) == 0) even else odd;
        while (xx < w) : (xx += 1) if ((pattern & (@as(u8, 1) << @as(u3, @intCast(7 - @as(u32, @intCast(xx)) % 8)))) != 0) setPixel(x + xx, y + yy, true);
    }
}

fn invertRect(x: i32, y: i32, w: i32, h: i32) void {
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < w) : (xx += 1) {
            const px = x + xx;
            const py = y + yy;
            if (px < 0 or py < 0 or px >= @as(i32, @intCast(WIDTH)) or py >= @as(i32, @intCast(HEIGHT))) continue;
            const pixel = @as(usize, @intCast(py)) * WIDTH + @as(usize, @intCast(px));
            bitplane[pixel >> 3] ^= @as(u8, 1) << @as(u3, @intCast(7 - (pixel & 7)));
        }
    }
}

fn rect(x: i32, y: i32, w: i32, h: i32) void {
    hline(x, y, w);
    hline(x, y + h - 1, w);
    vline(x, y, h);
    vline(x + w - 1, y, h);
}
fn hline(x: i32, y: i32, w: i32) void {
    fillRect(x, y, w, 1, true);
}
fn vline(x: i32, y: i32, h: i32) void {
    fillRect(x, y, 1, h, true);
}

fn drawLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = abs(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -abs(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setPixel(x0, y0, true);
        if (x0 == x1 and y0 == y1) break;
        const e2 = err * 2;
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

fn clamp(value: i32, low: i32, high: i32) i32 {
    return @min(@max(value, low), high);
}
fn abs(value: i32) i32 {
    return if (value < 0) -value else value;
}

test "packed working buffer is one bit per pixel" {
    try std.testing.expectEqual(@as(usize, 21_888), bitplane.len);
}

test "packed bitmap expands to RGBA8 only at presentation" {
    resetState();
    drawDesktop();
    const first_byte = bitplane[0];
    const sdr_size = expandSDR();
    try std.testing.expectEqual(SDR_BYTES, sdr_size);
    try std.testing.expectEqual(@as(u32, 43), std.mem.readInt(u32, output[12..16], .little));
    try std.testing.expectEqual(first_byte, bitplane[0]);
}

test "window drag changes component state" {
    resetState();
    const old_x = window_x;
    lifecycle = .updating;
    _ = pointer_event(BTN_PRIMARY, window_x + 50, window_y + 10);
    _ = pointer_event(BTN_PRIMARY, window_x + 90, window_y + 30);
    _ = pointer_event(0, window_x + 90, window_y + 30);
    try std.testing.expect(window_x != old_x);
    lifecycle = .initializing;
}
