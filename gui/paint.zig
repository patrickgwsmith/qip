const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const CANVAS_X: i32 = 52;
const CANVAS_Y: i32 = 30;
const CANVAS_W: usize = 256;
const CANVAS_H: usize = 176;
const CANVAS_PIXELS: usize = CANVAS_W * CANVAS_H;

const TOOL_X: i32 = 8;
const TOOL_Y: i32 = 30;
const TOOL_W: i32 = 16;
const TOOL_H: i32 = 16;
const TOOL_GAP: i32 = 6;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const Color = [4]u8;
const C_BG: Color = .{ 0xB8, 0xB8, 0xB8, 0xFF };
const C_PANEL: Color = .{ 0xDF, 0xDF, 0xDF, 0xFF };
const C_DARK: Color = .{ 0x1F, 0x1F, 0x1F, 0xFF };
const C_MID: Color = .{ 0x78, 0x78, 0x78, 0xFF };
const C_LIGHT: Color = .{ 0xF4, 0xF4, 0xF4, 0xFF };
const C_WHITE: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_BLACK: Color = .{ 0x00, 0x00, 0x00, 0xFF };
const C_ACCENT: Color = .{ 0x4C, 0x7A, 0xC7, 0xFF };

const Tool = enum(u8) {
    pencil,
    eraser,
    brush,
    line,
    rect,
    oval,
    fill,
    spray,
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var bitmap: [CANVAS_PIXELS]u8 = [_]u8{0} ** CANVAS_PIXELS;
var undo_bitmap: [CANVAS_PIXELS]u8 = [_]u8{0} ** CANVAS_PIXELS;
var fill_queue: [CANVAS_PIXELS]u16 = undefined;

var tool: Tool = .pencil;
var brush_size: i32 = 1;
var primary_down: bool = false;
var secondary_down: bool = false;
var dragging: bool = false;
var drag_color: u8 = 1;
var drag_start_x: i32 = 0;
var drag_start_y: i32 = 0;
var drag_last_x: i32 = 0;
var drag_last_y: i32 = 0;
var needs_redraw: bool = true;

const Phase = enum { initializing, ready, updating };
var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

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
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (x11_key) {
        'p', 'P' => tool = .pencil,
        'e', 'E' => tool = .eraser,
        'b', 'B' => tool = .brush,
        'l', 'L' => tool = .line,
        'r', 'R' => tool = .rect,
        'o', 'O' => tool = .oval,
        'f', 'F' => tool = .fill,
        's', 'S' => tool = .spray,
        'z', 'Z' => restoreUndo(),
        'c', 'C' => clearCanvas(),
        'i', 'I' => invertCanvas(),
        '[', '-' => {
            if (brush_size > 1) brush_size -= 1;
        },
        ']', '+', '=' => {
            if (brush_size < 8) brush_size += 1;
        },
        else => return 0,
    }

    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;
    const any_down = primary or secondary;

    if (any_down and !primary_down and !secondary_down) {
        if (handlePress(x_px, y_px, if (secondary) 0 else 1)) {
            primary_down = primary;
            secondary_down = secondary;
            needs_redraw = true;
            return 1;
        }
    } else if (dragging and any_down) {
        handleDrag(x_px, y_px);
        primary_down = primary;
        secondary_down = secondary;
        needs_redraw = true;
        return 1;
    } else if (dragging and !any_down) {
        handleRelease(x_px, y_px);
        primary_down = false;
        secondary_down = false;
        needs_redraw = true;
        return 1;
    }

    primary_down = primary;
    secondary_down = secondary;
    return 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
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
    committed_at_ms = begun_at_ms;
    transaction_phase = .ready;
    return begun_at_ms;
}

fn resetState() void {
    bitmap = [_]u8{0} ** CANVAS_PIXELS;
    undo_bitmap = [_]u8{0} ** CANVAS_PIXELS;
    tool = .pencil;
    brush_size = 1;
    primary_down = false;
    secondary_down = false;
    dragging = false;
    drag_color = 1;
    drag_start_x = 0;
    drag_start_y = 0;
    drag_last_x = 0;
    drag_last_y = 0;
    needs_redraw = true;
}

fn handlePress(x_px: i32, y_px: i32, color: u8) bool {
    if (handleToolbar(x_px, y_px)) return true;

    const pos = canvasPoint(x_px, y_px) orelse return false;
    saveUndo();
    drag_color = if (tool == .eraser) 0 else color;
    drag_start_x = pos[0];
    drag_start_y = pos[1];
    drag_last_x = pos[0];
    drag_last_y = pos[1];
    dragging = true;

    switch (tool) {
        .pencil => setBitmap(pos[0], pos[1], drag_color),
        .eraser, .brush => drawBrush(pos[0], pos[1], drag_color),
        .spray => sprayAt(pos[0], pos[1], drag_color),
        .fill => {
            floodFill(pos[0], pos[1], drag_color);
            dragging = false;
        },
        .line, .rect, .oval => {},
    }
    return true;
}

fn handleDrag(x_px: i32, y_px: i32) void {
    const pos = canvasPoint(x_px, y_px) orelse return;
    switch (tool) {
        .pencil => drawLineBitmap(drag_last_x, drag_last_y, pos[0], pos[1], drag_color, 1),
        .eraser, .brush => drawLineBitmap(drag_last_x, drag_last_y, pos[0], pos[1], drag_color, brush_size),
        .spray => sprayAt(pos[0], pos[1], drag_color),
        .line, .rect, .oval, .fill => {},
    }
    drag_last_x = pos[0];
    drag_last_y = pos[1];
}

fn handleRelease(x_px: i32, y_px: i32) void {
    const pos = canvasPoint(x_px, y_px) orelse .{ drag_last_x, drag_last_y };
    switch (tool) {
        .line => drawLineBitmap(drag_start_x, drag_start_y, pos[0], pos[1], drag_color, brush_size),
        .rect => drawRectBitmap(drag_start_x, drag_start_y, pos[0], pos[1], drag_color, brush_size),
        .oval => drawOvalBitmap(drag_start_x, drag_start_y, pos[0], pos[1], drag_color, brush_size),
        .pencil, .eraser, .brush, .fill, .spray => {},
    }
    drag_last_x = pos[0];
    drag_last_y = pos[1];
    dragging = false;
}

fn handleToolbar(x: i32, y: i32) bool {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const by = TOOL_Y + @as(i32, @intCast(i)) * (TOOL_H + TOOL_GAP);
        if (x >= TOOL_X and x < TOOL_X + TOOL_W and y >= by and y < by + TOOL_H) {
            tool = @as(Tool, @enumFromInt(@as(u8, @intCast(i))));
            return true;
        }
    }

    if (buttonHit(x, y, 30, 190, 20, 16)) {
        restoreUndo();
        return true;
    }
    if (buttonHit(x, y, 56, 190, 20, 16)) {
        clearCanvas();
        return true;
    }
    if (buttonHit(x, y, 82, 190, 20, 16)) {
        invertCanvas();
        return true;
    }
    return false;
}

fn saveUndo() void {
    var i: usize = 0;
    while (i < CANVAS_PIXELS) : (i += 1) undo_bitmap[i] = bitmap[i];
}

fn restoreUndo() void {
    var i: usize = 0;
    while (i < CANVAS_PIXELS) : (i += 1) bitmap[i] = undo_bitmap[i];
}

fn clearCanvas() void {
    saveUndo();
    bitmap = [_]u8{0} ** CANVAS_PIXELS;
}

fn invertCanvas() void {
    saveUndo();
    var i: usize = 0;
    while (i < CANVAS_PIXELS) : (i += 1) bitmap[i] = if (bitmap[i] == 0) 1 else 0;
}

fn canvasPoint(x: i32, y: i32) ?[2]i32 {
    if (x < CANVAS_X or y < CANVAS_Y) return null;
    const cx = x - CANVAS_X;
    const cy = y - CANVAS_Y;
    if (cx >= @as(i32, @intCast(CANVAS_W)) or cy >= @as(i32, @intCast(CANVAS_H))) return null;
    return .{ cx, cy };
}

fn buttonHit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

fn setBitmap(x: i32, y: i32, value: u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(CANVAS_W)) or y >= @as(i32, @intCast(CANVAS_H))) return;
    const idx = @as(usize, @intCast(y)) * CANVAS_W + @as(usize, @intCast(x));
    bitmap[idx] = value;
}

fn getBitmap(x: i32, y: i32) u8 {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(CANVAS_W)) or y >= @as(i32, @intCast(CANVAS_H))) return 0;
    const idx = @as(usize, @intCast(y)) * CANVAS_W + @as(usize, @intCast(x));
    return bitmap[idx];
}

fn drawBrush(cx: i32, cy: i32, color: u8) void {
    const r = @divFloor(brush_size, 2);
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            setBitmap(x, y, color);
        }
    }
}

fn drawLineBitmap(x0_in: i32, y0_in: i32, x1: i32, y1: i32, color: u8, width: i32) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    while (true) {
        drawPointWidth(x0, y0, color, width);
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

fn drawPointWidth(x: i32, y: i32, color: u8, width: i32) void {
    if (width <= 1) {
        setBitmap(x, y, color);
    } else {
        const saved = brush_size;
        brush_size = width;
        drawBrush(x, y, color);
        brush_size = saved;
    }
}

fn drawRectBitmap(x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: u8, width: i32) void {
    const x0 = @min(x0_in, x1_in);
    const x1 = @max(x0_in, x1_in);
    const y0 = @min(y0_in, y1_in);
    const y1 = @max(y0_in, y1_in);
    drawLineBitmap(x0, y0, x1, y0, color, width);
    drawLineBitmap(x1, y0, x1, y1, color, width);
    drawLineBitmap(x1, y1, x0, y1, color, width);
    drawLineBitmap(x0, y1, x0, y0, color, width);
}

fn drawOvalBitmap(x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: u8, width: i32) void {
    const x0 = @min(x0_in, x1_in);
    const x1 = @max(x0_in, x1_in);
    const y0 = @min(y0_in, y1_in);
    const y1 = @max(y0_in, y1_in);
    const rx = @max(1, @divFloor(x1 - x0, 2));
    const ry = @max(1, @divFloor(y1 - y0, 2));
    const cx = x0 + rx;
    const cy = y0 + ry;
    const rx2 = @as(i64, rx) * rx;
    const ry2 = @as(i64, ry) * ry;
    const edge = rx2 * ry2;
    const tolerance = @max(rx2, ry2) * @as(i64, @max(2, width * 2));

    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const v = @as(i64, dx) * dx * ry2 + @as(i64, dy) * dy * rx2;
            if (absI64(v - edge) <= tolerance) setBitmap(x, y, color);
        }
    }
}

fn floodFill(x: i32, y: i32, color: u8) void {
    const target = getBitmap(x, y);
    if (target == color) return;

    var head: usize = 0;
    var tail: usize = 0;
    setBitmap(x, y, color);
    fill_queue[tail] = @as(u16, @intCast(@as(usize, @intCast(y)) * CANVAS_W + @as(usize, @intCast(x))));
    tail += 1;

    while (head < tail) {
        const idx = fill_queue[head];
        head += 1;
        const px = @as(i32, @intCast(@as(usize, idx) % CANVAS_W));
        const py = @as(i32, @intCast(@as(usize, idx) / CANVAS_W));
        enqueueFill(px + 1, py, target, &tail);
        enqueueFill(px - 1, py, target, &tail);
        enqueueFill(px, py + 1, target, &tail);
        enqueueFill(px, py - 1, target, &tail);
    }
}

fn enqueueFill(x: i32, y: i32, target: u8, tail: *usize) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(CANVAS_W)) or y >= @as(i32, @intCast(CANVAS_H))) return;
    if (getBitmap(x, y) != target) return;
    if (tail.* >= CANVAS_PIXELS) return;
    setBitmap(x, y, if (target == 0) 1 else 0);
    fill_queue[tail.*] = @as(u16, @intCast(@as(usize, @intCast(y)) * CANVAS_W + @as(usize, @intCast(x))));
    tail.* += 1;
}

fn sprayAt(cx: i32, cy: i32, color: u8) void {
    var i: i32 = 0;
    while (i < brush_size * 5) : (i += 1) {
        const n = hash2(cx + i * 13, cy - i * 17);
        const dx = @as(i32, @intCast(@mod(n, 17))) - 8;
        const dy = @as(i32, @intCast(@mod(n / 17, 17))) - 8;
        if (dx * dx + dy * dy <= 64) setBitmap(cx + dx, cy + dy, color);
    }
}

fn hash2(x: i32, y: i32) u32 {
    var n = @as(u32, @bitCast(x *% 374761393 + y *% 668265263));
    n = (n ^ (n >> 13)) *% 1274126177;
    return n ^ (n >> 16);
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), 22, C_PANEL);
    drawBorder(0, 0, @as(i32, @intCast(RENDER_W)), 22, C_LIGHT, C_MID);

    drawToolbar();
    drawCanvas();
    drawStatus();
}

fn drawToolbar() void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const by = TOOL_Y + @as(i32, @intCast(i)) * (TOOL_H + TOOL_GAP);
        const active = @intFromEnum(tool) == i;
        fillRectI32(TOOL_X, by, TOOL_W, TOOL_H, if (active) C_ACCENT else C_PANEL);
        drawBorder(TOOL_X, by, TOOL_W, TOOL_H, C_LIGHT, C_DARK);
        drawToolIcon(@as(Tool, @enumFromInt(@as(u8, @intCast(i)))), TOOL_X + 2, by + 2, if (active) C_WHITE else C_BLACK);
    }

    drawCommandButton(30, 190, 'Z');
    drawCommandButton(56, 190, 'C');
    drawCommandButton(82, 190, 'I');
}

fn drawToolIcon(t: Tool, x: i32, y: i32, c: Color) void {
    switch (t) {
        .pencil => drawLineScreen(x + 1, y + 12, x + 12, y + 1, c),
        .eraser => fillRectI32(x + 2, y + 7, 10, 5, c),
        .brush => fillRectI32(x + 5, y + 2, 4, 10, c),
        .line => drawLineScreen(x + 1, y + 12, x + 12, y + 2, c),
        .rect => drawRectScreen(x + 2, y + 3, 10, 8, c),
        .oval => drawOvalScreen(x + 2, y + 3, 10, 8, c),
        .fill => {
            drawRectScreen(x + 3, y + 4, 7, 6, c);
            fillRectI32(x + 9, y + 10, 4, 2, c);
        },
        .spray => {
            setPixelI32(x + 3, y + 4, c);
            setPixelI32(x + 7, y + 3, c);
            setPixelI32(x + 10, y + 7, c);
            setPixelI32(x + 5, y + 10, c);
            setPixelI32(x + 12, y + 11, c);
        },
    }
}

fn drawCommandButton(x: i32, y: i32, label: u8) void {
    fillRectI32(x, y, 20, 16, C_PANEL);
    drawBorder(x, y, 20, 16, C_LIGHT, C_DARK);
    drawLetter(x + 7, y + 5, label, C_BLACK);
}

fn drawCanvas() void {
    fillRectI32(CANVAS_X - 2, CANVAS_Y - 2, @as(i32, @intCast(CANVAS_W)) + 4, @as(i32, @intCast(CANVAS_H)) + 4, C_DARK);
    fillRectI32(CANVAS_X, CANVAS_Y, @as(i32, @intCast(CANVAS_W)), @as(i32, @intCast(CANVAS_H)), C_WHITE);

    var y: usize = 0;
    while (y < CANVAS_H) : (y += 1) {
        var x: usize = 0;
        while (x < CANVAS_W) : (x += 1) {
            if (bitmap[y * CANVAS_W + x] != 0) {
                setPixelI32(CANVAS_X + @as(i32, @intCast(x)), CANVAS_Y + @as(i32, @intCast(y)), C_BLACK);
            }
        }
    }

    if (dragging) {
        switch (tool) {
            .line => drawLinePreview(drag_start_x, drag_start_y, drag_last_x, drag_last_y),
            .rect => drawRectPreview(drag_start_x, drag_start_y, drag_last_x, drag_last_y),
            .oval => drawOvalPreview(drag_start_x, drag_start_y, drag_last_x, drag_last_y),
            .pencil, .eraser, .brush, .fill, .spray => {},
        }
    }
}

fn drawStatus() void {
    drawLetter(8, 8, toolLetter(tool), C_BLACK);
    fillRectI32(24, 8, brush_size * 2, 5, C_BLACK);
    drawNumber(112, 8, brush_size, C_BLACK);
    drawNumber(236, 8, @as(i32, @intCast(countInk())), C_BLACK);
}

fn toolLetter(t: Tool) u8 {
    return switch (t) {
        .pencil => 'P',
        .eraser => 'E',
        .brush => 'B',
        .line => 'L',
        .rect => 'R',
        .oval => 'O',
        .fill => 'F',
        .spray => 'S',
    };
}

fn countInk() usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < CANVAS_PIXELS) : (i += 1) {
        if (bitmap[i] != 0) n += 1;
    }
    return n;
}

fn drawLinePreview(x0: i32, y0: i32, x1: i32, y1: i32) void {
    drawLineScreen(CANVAS_X + x0, CANVAS_Y + y0, CANVAS_X + x1, CANVAS_Y + y1, C_ACCENT);
}

fn drawRectPreview(x0: i32, y0: i32, x1: i32, y1: i32) void {
    drawRectScreen(CANVAS_X + @min(x0, x1), CANVAS_Y + @min(y0, y1), absI32(x1 - x0) + 1, absI32(y1 - y0) + 1, C_ACCENT);
}

fn drawOvalPreview(x0: i32, y0: i32, x1: i32, y1: i32) void {
    drawOvalScreen(CANVAS_X + @min(x0, x1), CANVAS_Y + @min(y0, y1), absI32(x1 - x0) + 1, absI32(y1 - y0) + 1, C_ACCENT);
}

fn drawBorder(x: i32, y: i32, w: i32, h: i32, hi: Color, lo: Color) void {
    fillRectI32(x, y, w, 1, hi);
    fillRectI32(x, y, 1, h, hi);
    fillRectI32(x, y + h - 1, w, 1, lo);
    fillRectI32(x + w - 1, y, 1, h, lo);
}

fn drawRectScreen(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn drawOvalScreen(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    const rx = @max(1, @divFloor(w, 2));
    const ry = @max(1, @divFloor(h, 2));
    const cx = x + rx;
    const cy = y + ry;
    const rx2 = @as(i64, rx) * rx;
    const ry2 = @as(i64, ry) * ry;
    const edge = rx2 * ry2;
    const tolerance = @max(rx2, ry2) * 2;
    var py = y;
    while (py < y + h) : (py += 1) {
        var px = x;
        while (px < x + w) : (px += 1) {
            const dx = px - cx;
            const dy = py - cy;
            const v = @as(i64, dx) * dx * ry2 + @as(i64, dy) * dy * rx2;
            if (absI64(v - edge) <= tolerance) setPixelI32(px, py, c);
        }
    }
}

fn drawLineScreen(x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: Color) void {
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

fn drawNumber(x0: i32, y0: i32, n: i32, color: Color) void {
    var value = if (n < 0) 0 else n;
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    if (value == 0) {
        digits[0] = 0;
        count = 1;
    } else {
        while (value > 0 and count < digits.len) : (count += 1) {
            digits[count] = @as(u8, @intCast(@mod(value, 10)));
            value = @divFloor(value, 10);
        }
    }
    var i: usize = 0;
    while (i < count) : (i += 1) drawDigit(x0 + @as(i32, @intCast(i * 4)), y0, digits[count - 1 - i], color);
}

fn drawLetter(x: i32, y: i32, letter: u8, color: Color) void {
    const rows = switch (letter) {
        'B' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C' => [_]u8{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'E' => [_]u8{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F' => [_]u8{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'I' => [_]u8{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'L' => [_]u8{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'O' => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P' => [_]u8{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'R' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S' => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'Z' => [_]u8{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };
    drawRows(x, y, rows, color);
}

fn drawDigit(x: i32, y: i32, digit: u8, color: Color) void {
    const rows = switch (digit) {
        0 => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        1 => [_]u8{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        2 => [_]u8{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        3 => [_]u8{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        4 => [_]u8{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        5 => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        6 => [_]u8{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        7 => [_]u8{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        8 => [_]u8{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        9 => [_]u8{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };
    drawRows(x, y, rows, color);
}

fn drawRows(x0: i32, y0: i32, rows: [5]u8, color: Color) void {
    var y: usize = 0;
    while (y < 5) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            if ((rows[y] & (@as(u8, 1) << @as(u3, @intCast(2 - x)))) != 0) {
                setPixelI32(x0 + @as(i32, @intCast(x)), y0 + @as(i32, @intCast(y)), color);
            }
        }
    }
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
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn absI64(v: i64) i64 {
    return if (v < 0) -v else v;
}

test "line draws endpoints" {
    clearCanvas();
    drawLineBitmap(0, 0, 5, 0, 1, 1);
    try std.testing.expect(getBitmap(0, 0) == 1);
    try std.testing.expect(getBitmap(5, 0) == 1);
}

test "fill changes enclosed area" {
    clearCanvas();
    drawRectBitmap(1, 1, 5, 5, 1, 1);
    floodFill(3, 3, 1);
    try std.testing.expect(getBitmap(3, 3) == 1);
    try std.testing.expect(getBitmap(0, 0) == 0);
}
