const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const GRAPH_X: i32 = 12;
const GRAPH_Y: i32 = 42;
const GRAPH_W: i32 = 296;
const GRAPH_H: i32 = 166;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_ESCAPE: i32 = 0xFF1B;

const Color = [4]u8;
const C_BG: Color = .{ 0x16, 0x21, 0x2A, 0xFF };
const C_PANEL: Color = .{ 0xD9, 0xDD, 0xC8, 0xFF };
const C_SCREEN: Color = .{ 0xB7, 0xC5, 0xA3, 0xFF };
const C_GRID: Color = .{ 0x8F, 0x9E, 0x83, 0xFF };
const C_AXIS: Color = .{ 0x35, 0x40, 0x31, 0xFF };
const C_PLOT: Color = .{ 0x11, 0x1A, 0x12, 0xFF };
const C_TEXT: Color = .{ 0x0B, 0x13, 0x0B, 0xFF };
const C_FRAME: Color = .{ 0x05, 0x08, 0x0A, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var expr: [48]u8 = [_]u8{0} ** 48;
var expr_len: usize = 0;
var initialized: bool = false;
var x_min: f64 = -10.0;
var x_max: f64 = 10.0;
var y_min: f64 = -6.0;
var y_max: f64 = 6.0;
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
    ensureDefault();

    switch (x11_key) {
        XK_BACKSPACE => {
            if (expr_len > 0) expr_len -= 1;
        },
        XK_ESCAPE => setExpr("sin(x)"),
        XK_RETURN => {},
        '+', '-', '*', '/', '^', '(', ')', '.', 'x', 'X' => appendChar(@as(u8, @intCast(if (x11_key == 'X') 'x' else x11_key))),
        '0'...'9' => appendChar(@as(u8, @intCast(x11_key))),
        's', 'S' => appendText("sin("),
        'c' => appendText("cos("),
        'C' => setExpr(""),
        't', 'T' => appendText("tan("),
        'q', 'Q' => appendText("sqrt("),
        'z', 'Z' => zoom(0.7),
        'a', 'A' => zoom(1.3),
        else => return 0,
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    return 0;
}

fn eventPhaseIsValid() bool {
    if (transaction_phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (transaction_phase != .initializing and transaction_phase != .ready) @trap();
    ensureDefault();
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
    committed_at_ms = begun_at_ms;
    transaction_phase = .ready;
    return begun_at_ms;
}

fn ensureDefault() void {
    if (initialized) return;
    setExpr("sin(x)");
    initialized = true;
}

fn setExpr(text: []const u8) void {
    expr_len = @min(text.len, expr.len);
    var i: usize = 0;
    while (i < expr_len) : (i += 1) expr[i] = text[i];
}

fn appendChar(ch: u8) void {
    if (expr_len >= expr.len) return;
    expr[expr_len] = ch;
    expr_len += 1;
}

fn appendText(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) appendChar(text[i]);
}

fn zoom(factor: f64) void {
    const cx = (x_min + x_max) * 0.5;
    const cy = (y_min + y_max) * 0.5;
    const hw = (x_max - x_min) * 0.5 * factor;
    const hh = (y_max - y_min) * 0.5 * factor;
    x_min = cx - hw;
    x_max = cx + hw;
    y_min = cy - hh;
    y_max = cy + hh;
}

const Parser = struct {
    input: []const u8,
    pos: usize,
    x: f64,
    failed: bool,

    fn parse(self: *Parser) f64 {
        const v = self.exprRule();
        self.skipSpaces();
        if (self.pos != self.input.len) self.failed = true;
        return v;
    }

    fn exprRule(self: *Parser) f64 {
        var v = self.term();
        while (true) {
            self.skipSpaces();
            if (self.match('+')) {
                v += self.term();
            } else if (self.match('-')) {
                v -= self.term();
            } else break;
        }
        return v;
    }

    fn term(self: *Parser) f64 {
        var v = self.power();
        while (true) {
            self.skipSpaces();
            if (self.match('*')) {
                v *= self.power();
            } else if (self.match('/')) {
                v /= self.power();
            } else break;
        }
        return v;
    }

    fn power(self: *Parser) f64 {
        var v = self.unary();
        self.skipSpaces();
        if (self.match('^')) v = std.math.pow(f64, v, self.power());
        return v;
    }

    fn unary(self: *Parser) f64 {
        self.skipSpaces();
        if (self.match('-')) return -self.unary();
        if (self.match('+')) return self.unary();
        return self.primary();
    }

    fn primary(self: *Parser) f64 {
        self.skipSpaces();
        if (self.match('x')) return self.x;
        if (self.match('(')) {
            const v = self.exprRule();
            if (!self.match(')')) self.failed = true;
            return v;
        }
        if (self.matchName("sin")) return std.math.sin(self.callArg());
        if (self.matchName("cos")) return std.math.cos(self.callArg());
        if (self.matchName("tan")) return std.math.tan(self.callArg());
        if (self.matchName("sqrt")) return std.math.sqrt(self.callArg());
        return self.number();
    }

    fn callArg(self: *Parser) f64 {
        if (!self.match('(')) {
            self.failed = true;
            return 0;
        }
        const v = self.exprRule();
        if (!self.match(')')) self.failed = true;
        return v;
    }

    fn number(self: *Parser) f64 {
        self.skipSpaces();
        const start = self.pos;
        while (self.pos < self.input.len and ((self.input[self.pos] >= '0' and self.input[self.pos] <= '9') or self.input[self.pos] == '.')) self.pos += 1;
        if (self.pos == start) {
            self.failed = true;
            return 0;
        }
        return parseFloat(self.input[start..self.pos]);
    }

    fn match(self: *Parser, ch: u8) bool {
        self.skipSpaces();
        if (self.pos < self.input.len and self.input[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn matchName(self: *Parser, name: []const u8) bool {
        self.skipSpaces();
        if (self.pos + name.len > self.input.len) return false;
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            if (self.input[self.pos + i] != name[i]) return false;
        }
        self.pos += name.len;
        return true;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] == ' ') self.pos += 1;
    }
};

fn evalAt(x: f64, failed: *bool) f64 {
    var p = Parser{ .input = expr[0..expr_len], .pos = 0, .x = x, .failed = false };
    const y = p.parse();
    if (p.failed or std.math.isNan(y) or !std.math.isFinite(y)) failed.* = true;
    return y;
}

fn parseFloat(s: []const u8) f64 {
    var value: f64 = 0;
    var frac: f64 = 0.1;
    var after_dot = false;
    for (s) |ch| {
        if (ch == '.') {
            after_dot = true;
        } else if (ch >= '0' and ch <= '9') {
            const d = @as(f64, @floatFromInt(ch - '0'));
            if (after_dot) {
                value += d * frac;
                frac *= 0.1;
            } else {
                value = value * 10 + d;
            }
        }
    }
    return value;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);
    fillRectI32(8, 8, 304, 204, C_PANEL);
    drawBorder(8, 8, 304, 204, C_FRAME);
    fillRectI32(14, 14, 292, 20, C_SCREEN);
    drawBorder(14, 14, 292, 20, C_FRAME);
    drawText(18, 21, "Y=", C_TEXT);
    drawText(34, 21, expr[0..expr_len], C_TEXT);
    drawGraph();
}

fn drawGraph() void {
    fillRectI32(GRAPH_X, GRAPH_Y, GRAPH_W, GRAPH_H, C_SCREEN);
    drawBorder(GRAPH_X, GRAPH_Y, GRAPH_W, GRAPH_H, C_FRAME);

    var i: i32 = 1;
    while (i < 10) : (i += 1) {
        const gx = GRAPH_X + @divTrunc(GRAPH_W * i, 10);
        const gy = GRAPH_Y + @divTrunc(GRAPH_H * i, 10);
        fillRectI32(gx, GRAPH_Y + 1, 1, GRAPH_H - 2, C_GRID);
        fillRectI32(GRAPH_X + 1, gy, GRAPH_W - 2, 1, C_GRID);
    }

    const ax = xToScreen(0);
    const ay = yToScreen(0);
    if (ax >= GRAPH_X and ax < GRAPH_X + GRAPH_W) fillRectI32(ax, GRAPH_Y, 1, GRAPH_H, C_AXIS);
    if (ay >= GRAPH_Y and ay < GRAPH_Y + GRAPH_H) fillRectI32(GRAPH_X, ay, GRAPH_W, 1, C_AXIS);

    var last_valid = false;
    var last_x: i32 = 0;
    var last_y: i32 = 0;
    var px: i32 = 0;
    var any_failed = false;
    while (px < GRAPH_W) : (px += 1) {
        const x = x_min + (@as(f64, @floatFromInt(px)) / @as(f64, @floatFromInt(GRAPH_W - 1))) * (x_max - x_min);
        var failed = false;
        const y = evalAt(x, &failed);
        if (failed) {
            any_failed = true;
            last_valid = false;
            continue;
        }
        const sy = yToScreen(y);
        const sx = GRAPH_X + px;
        if (sy >= GRAPH_Y - 20 and sy <= GRAPH_Y + GRAPH_H + 20) {
            if (last_valid and absI32(sy - last_y) < GRAPH_H) drawLine(sx, sy, last_x, last_y, C_PLOT);
            last_x = sx;
            last_y = sy;
            last_valid = true;
        } else {
            last_valid = false;
        }
    }
    if (any_failed) drawText(250, 202, "ERR", C_TEXT);
}

fn xToScreen(x: f64) i32 {
    return GRAPH_X + @as(i32, @intFromFloat((x - x_min) / (x_max - x_min) * @as(f64, @floatFromInt(GRAPH_W - 1))));
}

fn yToScreen(y: f64) i32 {
    return GRAPH_Y + GRAPH_H - 1 - @as(i32, @intFromFloat((y - y_min) / (y_max - y_min) * @as(f64, @floatFromInt(GRAPH_H - 1))));
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len and i < 36) : (i += 1) drawChar(x + @as(i32, @intCast(i * 7)), y, text[i], c);
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const rows = switch (ch) {
        '0' => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => [_]u8{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => [_]u8{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => [_]u8{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => [_]u8{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => [_]u8{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => [_]u8{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => [_]u8{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => [_]u8{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        'Y', 'y' => [_]u8{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'X', 'x' => [_]u8{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'E' => [_]u8{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'R' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        's' => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'i' => [_]u8{ 0b010, 0b000, 0b010, 0b010, 0b010 },
        'n' => [_]u8{ 0b000, 0b110, 0b101, 0b101, 0b101 },
        'c' => [_]u8{ 0b000, 0b111, 0b100, 0b100, 0b111 },
        'o' => [_]u8{ 0b000, 0b111, 0b101, 0b101, 0b111 },
        't' => [_]u8{ 0b010, 0b111, 0b010, 0b010, 0b011 },
        'a' => [_]u8{ 0b000, 0b111, 0b001, 0b111, 0b111 },
        'q' => [_]u8{ 0b000, 0b111, 0b101, 0b111, 0b001 },
        'r' => [_]u8{ 0b000, 0b101, 0b110, 0b100, 0b100 },
        '+', '=' => [_]u8{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => [_]u8{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => [_]u8{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '/' => [_]u8{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '^' => [_]u8{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '(' => [_]u8{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => [_]u8{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '.' => [_]u8{ 0b000, 0b000, 0b000, 0b000, 0b010 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };
    drawRows(x, y, rows, c);
}

fn drawRows(x0: i32, y0: i32, rows: [5]u8, c: Color) void {
    var y: usize = 0;
    while (y < 5) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            if ((rows[y] & (@as(u8, 1) << @as(u3, @intCast(2 - x)))) != 0) fillRectI32(x0 + @as(i32, @intCast(x * 2)), y0 + @as(i32, @intCast(y * 2)), 2, 2, c);
        }
    }
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

fn drawBorder(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x + w - 1, y, 1, h, c);
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
    const sx = @max(0, x0);
    const sy = @max(0, y0);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x0 + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y0 + h);
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

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

test "parser evaluates polynomial" {
    setExpr("x^2+2*x+1");
    var failed = false;
    const y = evalAt(2, &failed);
    try std.testing.expect(!failed);
    try std.testing.expect(y == 9);
}
