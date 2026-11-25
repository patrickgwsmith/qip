// A four-function calculator in the style of the 1984 Macintosh desk accessory:
// a black-and-white window on a grey desktop, drawn as one-bit pixels and
// scaled up 4x.
//
// Arithmetic uses f64 and the display rounds to ten significant digits, so
// 0.1 + 0.2 shows 0.3. Results switch to scientific notation outside the range
// the display can show, and division by zero or overflow shows Error.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

// The component draws on a 120x180 one-bit canvas and outputs it at 4x.
const SCALE: usize = 4;
const LW: usize = 120;
const LH: usize = 180;
const RENDER_W: usize = LW * SCALE;
const RENDER_H: usize = LH * SCALE;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_RETURN: i32 = 0xFF0D;
const XK_KP_ENTER: i32 = 0xFF8D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_KP_0: i32 = 0xFFB0;
const XK_KP_9: i32 = 0xFFB9;
const XK_KP_MULTIPLY: i32 = 0xFFAA;
const XK_KP_ADD: i32 = 0xFFAB;
const XK_KP_SUBTRACT: i32 = 0xFFAD;
const XK_KP_DECIMAL: i32 = 0xFFAE;
const XK_KP_DIVIDE: i32 = 0xFFAF;

// ---- Layout (canvas pixels) ------------------------------------------------------

const WIN: Rect = .{ .x = 3, .y = 3, .w = 114, .h = 174 };
const TITLE_LINE_Y: i32 = WIN.y + 19;
const DISPLAY: Rect = .{ .x = 8, .y = 28, .w = 104, .h = 23 };
const KEYS_X: i32 = 8;
const KEYS_Y: i32 = 56;
const KEY_W: i32 = 22; // Including the one-pixel shadow.
const KEY_H: i32 = 20;
const PITCH_X: i32 = 27;
const PITCH_Y: i32 = 24;

// ---- Keys ----------------------------------------------------------------------

const Op = enum(u8) { none, add, sub, mul, div };
const KeyKind = enum(u8) { digit, dot, clear, clear_entry, op, equals };

const KeyDef = struct {
    kind: KeyKind,
    value: u8 = 0,
    op: Op = .none,
    row: u8,
    col: u8,
    cols: u8 = 1,
    rows: u8 = 1,
    label: []const u8,
};

// The desk accessory's layout: C clears everything, E clears the entry, = sits
// on the top row, + is two rows tall and 0 is two columns wide.
const keys = [_]KeyDef{
    .{ .kind = .clear, .row = 0, .col = 0, .label = "C" },
    .{ .kind = .clear_entry, .row = 0, .col = 1, .label = "E" },
    .{ .kind = .equals, .row = 0, .col = 2, .label = "=" },
    .{ .kind = .op, .op = .mul, .row = 0, .col = 3, .label = "*" },
    .{ .kind = .digit, .value = 7, .row = 1, .col = 0, .label = "7" },
    .{ .kind = .digit, .value = 8, .row = 1, .col = 1, .label = "8" },
    .{ .kind = .digit, .value = 9, .row = 1, .col = 2, .label = "9" },
    .{ .kind = .op, .op = .div, .row = 1, .col = 3, .label = "/" },
    .{ .kind = .digit, .value = 4, .row = 2, .col = 0, .label = "4" },
    .{ .kind = .digit, .value = 5, .row = 2, .col = 1, .label = "5" },
    .{ .kind = .digit, .value = 6, .row = 2, .col = 2, .label = "6" },
    .{ .kind = .op, .op = .sub, .row = 2, .col = 3, .label = "-" },
    .{ .kind = .digit, .value = 1, .row = 3, .col = 0, .label = "1" },
    .{ .kind = .digit, .value = 2, .row = 3, .col = 1, .label = "2" },
    .{ .kind = .digit, .value = 3, .row = 3, .col = 2, .label = "3" },
    .{ .kind = .op, .op = .add, .row = 3, .col = 3, .rows = 2, .label = "+" },
    .{ .kind = .digit, .value = 0, .row = 4, .col = 0, .cols = 2, .label = "0" },
    .{ .kind = .dot, .row = 4, .col = 2, .label = "." },
};

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

fn keyRect(k: KeyDef) Rect {
    const cols: i32 = k.cols;
    const rows: i32 = k.rows;
    return .{
        .x = KEYS_X + @as(i32, k.col) * PITCH_X,
        .y = KEYS_Y + @as(i32, k.row) * PITCH_Y,
        .w = KEY_W + (cols - 1) * PITCH_X,
        .h = KEY_H + (rows - 1) * PITCH_Y,
    };
}

// ---- State ---------------------------------------------------------------------

const MAX_DIGITS: usize = 10;
const NO_KEY: u8 = 0xFF;

const State = struct {
    // The number being typed, without sign or grouping, e.g. "12.50".
    entry: [MAX_DIGITS + 1]u8 = undefined,
    entry_len: u8 = 0,
    entry_negative: bool = false,
    entering: bool = false,

    acc: f64 = 0,
    pending: Op = .none,
    repeat_op: Op = .none,
    repeat_operand: f64 = 0,
    has_error: bool = false,

    pressed: u8 = NO_KEY,
    primary_down: bool = false,
};

const Phase = enum { initializing, ready, updating };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
// One byte per canvas pixel: 1 is black.
var canvas: [LW * LH]u8 = undefined;
var state: State = .{};
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

// ---- QIP exports ---------------------------------------------------------------

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_BYTES);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready) @trap();
    if (now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireEventPhase();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    const handled: ?bool = switch (x11_key) {
        '0'...'9' => pressDigit(@intCast(x11_key - '0')),
        XK_KP_0...XK_KP_9 => pressDigit(@intCast(x11_key - XK_KP_0)),
        '.', ',', XK_KP_DECIMAL => pressDot(),
        '+', XK_KP_ADD => pressOp(.add),
        '-', XK_KP_SUBTRACT => pressOp(.sub),
        '*', 'x', 'X', XK_KP_MULTIPLY => pressOp(.mul),
        '/', XK_KP_DIVIDE => pressOp(.div),
        '=', XK_RETURN, XK_KP_ENTER => pressEquals(),
        'c', 'C', XK_DELETE => pressClear(),
        'e', 'E' => clearEntry(),
        XK_ESCAPE => allClear(),
        XK_BACKSPACE => backspace(),
        'n', 'N', '_' => negate(),
        else => null,
    };
    return if (handled orelse false) 1 else 0;
}

// A key stays inverted while the button is held, like the original.
export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireEventPhase();
    const down = (button_mask & BTN_PRIMARY) != 0;
    if (down and !state.primary_down) {
        state.primary_down = true;
        const over = keyIndexAt(x_px, y_px);
        if (over == NO_KEY) return 0;
        state.pressed = over;
        _ = pressKey(keys[over]);
        return 1;
    }
    if (!down and state.primary_down) {
        state.primary_down = false;
        if (state.pressed == NO_KEY) return 0;
        state.pressed = NO_KEY;
        return 1;
    }
    return 0;
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
    committed_at_ms = begun_at_ms;
    phase = .ready;
    return begun_at_ms;
}

fn requireEventPhase() void {
    if (phase != .updating) @trap();
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    present();
    phase = .ready;
    return @intCast(OUTPUT_BYTES);
}

// Takes output pixel coordinates.
fn keyIndexAt(x_px: i32, y_px: i32) u8 {
    if (x_px < 0 or y_px < 0) return NO_KEY;
    const x = @divFloor(x_px, @as(i32, SCALE));
    const y = @divFloor(y_px, @as(i32, SCALE));
    for (keys, 0..) |k, i| {
        const r = keyRect(k);
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return @intCast(i);
    }
    return NO_KEY;
}

// ---- Calculator logic ------------------------------------------------------------
// Each action returns whether anything visible changed.

fn pressKey(k: KeyDef) bool {
    return switch (k.kind) {
        .digit => pressDigit(k.value),
        .dot => pressDot(),
        .clear => allClear(),
        .clear_entry => clearEntry(),
        .op => pressOp(k.op),
        .equals => pressEquals(),
    };
}

fn entrySlice() []const u8 {
    return state.entry[0..state.entry_len];
}

fn entryDigitCount() usize {
    var n: usize = 0;
    for (entrySlice()) |ch| {
        if (ch != '.') n += 1;
    }
    return n;
}

fn entryValue() f64 {
    const magnitude = std.fmt.parseFloat(f64, entrySlice()) catch 0;
    return if (state.entry_negative) -magnitude else magnitude;
}

fn entryIsZero() bool {
    for (entrySlice()) |ch| {
        if (ch != '0' and ch != '.') return false;
    }
    return true;
}

// Starts typing a new number. After "=", a new number also starts a new expression.
fn startEntry() void {
    if (state.has_error) allClearState();
    if (state.pending == .none) state.repeat_op = .none;
    state.entry[0] = '0';
    state.entry_len = 1;
    state.entry_negative = false;
    state.entering = true;
}

fn pressDigit(digit: u8) bool {
    const fresh = !state.entering;
    if (fresh) startEntry();
    if (entryDigitCount() >= MAX_DIGITS) return false;
    const ch = '0' + digit;
    if (state.entry_len == 1 and state.entry[0] == '0') {
        if (digit == 0) return fresh; // "0" stays "0".
        state.entry[0] = ch;
        return true;
    }
    state.entry[state.entry_len] = ch;
    state.entry_len += 1;
    return true;
}

fn pressDot() bool {
    if (!state.entering) startEntry();
    if (std.mem.indexOfScalar(u8, entrySlice(), '.') != null) return false;
    if (entryDigitCount() >= MAX_DIGITS) return false;
    state.entry[state.entry_len] = '.';
    state.entry_len += 1;
    return true;
}

fn pressOp(next: Op) bool {
    if (state.has_error) return false;
    if (state.entering) {
        const operand = entryValue();
        state.acc = if (state.pending != .none) apply(state.pending, state.acc, operand) else operand;
        state.entering = false;
        if (state.has_error) return true;
    }
    state.pending = next;
    state.repeat_op = .none;
    return true;
}

fn pressEquals() bool {
    if (state.has_error) return false;
    var op = state.pending;
    var operand: f64 = undefined;
    if (op != .none) {
        operand = if (state.entering) entryValue() else state.acc;
    } else if (state.repeat_op != .none and !state.entering) {
        op = state.repeat_op;
        operand = state.repeat_operand;
    } else if (state.entering) {
        state.acc = entryValue();
        state.entering = false;
        return true;
    } else {
        return false;
    }
    const left = state.acc;
    state.acc = apply(op, left, operand);
    state.entering = false;
    state.pending = .none;
    state.repeat_op = op;
    state.repeat_operand = operand;
    return true;
}

fn apply(op: Op, a: f64, b: f64) f64 {
    const result: f64 = switch (op) {
        .none => b,
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => if (b == 0) std.math.nan(f64) else a / b,
    };
    if (!std.math.isFinite(result) or @abs(result) >= 1e100) {
        state.has_error = true;
        state.pending = .none;
        state.repeat_op = .none;
        return 0;
    }
    // Results too small for the display become zero rather than 1e-300.
    return if (@abs(result) < 1e-99) 0 else result;
}

fn clearShowsC() bool {
    return state.entering and !entryIsZero();
}

// C clears the number being typed; AC clears everything.
fn pressClear() bool {
    if (clearShowsC()) {
        state.entry[0] = '0';
        state.entry_len = 1;
        state.entry_negative = false;
        return true;
    }
    return allClear();
}

// The E key: clears the number being typed and keeps the pending operation.
fn clearEntry() bool {
    if (state.has_error) return allClear();
    if (state.entering) {
        if (entryIsZero() and state.entry_len == 1 and !state.entry_negative) return false;
    } else if (state.acc == 0 and state.pending == .none) {
        return false;
    }
    startEntry();
    return true;
}

// Clears the calculation but keeps the pointer's pressed state.
fn clearedState() State {
    var fresh: State = .{};
    fresh.pressed = state.pressed;
    fresh.primary_down = state.primary_down;
    return fresh;
}

fn allClearState() void {
    state = clearedState();
}

fn allClear() bool {
    const fresh = clearedState();
    if (std.meta.eql(stateLogic(state), stateLogic(fresh))) return false;
    state = fresh;
    return true;
}

// The calculator part of the state, for comparing whether a clear changes anything.
fn stateLogic(s: State) struct { u8, bool, bool, f64, Op, Op, bool } {
    return .{ s.entry_len, s.entry_negative, s.entering, s.acc, s.pending, s.repeat_op, s.has_error };
}

fn negate() bool {
    if (state.has_error) return false;
    if (!state.entering and state.pending != .none) {
        startEntry();
        state.entry_negative = true;
        return true;
    }
    if (state.entering) {
        state.entry_negative = !state.entry_negative;
        return true;
    }
    state.acc = -state.acc;
    state.repeat_op = .none;
    return true;
}

fn backspace() bool {
    if (state.has_error) return allClear();
    if (!state.entering) return false;
    if (state.entry_len <= 1) {
        if (state.entry[0] == '0' and !state.entry_negative) return false;
        state.entry[0] = '0';
        state.entry_len = 1;
        state.entry_negative = false;
        return true;
    }
    state.entry_len -= 1;
    return true;
}

// ---- Number formatting -------------------------------------------------------------

const TextBuf = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,

    fn add(self: *TextBuf, s: []const u8) void {
        const n = @min(s.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn addByte(self: *TextBuf, b: u8) void {
        if (self.len < self.bytes.len) {
            self.bytes[self.len] = b;
            self.len += 1;
        }
    }

    fn slice(self: *const TextBuf) []const u8 {
        return self.bytes[0..self.len];
    }
};

const MINUS = "-";

// Adds digits with a comma between each group of three.
fn addGrouped(out: *TextBuf, int_digits: []const u8) void {
    for (int_digits, 0..) |ch, i| {
        if (i > 0 and (int_digits.len - i) % 3 == 0) out.addByte(',');
        out.addByte(ch);
    }
}

fn formatEntry(out: *TextBuf) void {
    const text = entrySlice();
    if (state.entry_negative) out.add(MINUS);
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    addGrouped(out, text[0..dot]);
    out.add(text[dot..]);
}

const Scientific = struct { negative: bool, digits: [MAX_DIGITS]u8, count: usize, exp: i32 };

// Rounds |v| to `sig` significant digits (1...10), dropping trailing zeros.
fn toScientific(v: f64, sig: usize) Scientific {
    var buf: [40]u8 = undefined;
    const text = switch (sig) {
        inline 1...MAX_DIGITS => |n| std.fmt.bufPrint(&buf, std.fmt.comptimePrint("{{e:.{d}}}", .{n - 1}), .{v}) catch unreachable,
        else => unreachable,
    };
    var result: Scientific = .{ .negative = false, .digits = undefined, .count = 0, .exp = 0 };
    var i: usize = 0;
    if (text[0] == '-') {
        result.negative = true;
        i = 1;
    }
    while (i < text.len and text[i] != 'e') : (i += 1) {
        if (text[i] == '.') continue;
        if (result.count < MAX_DIGITS) {
            result.digits[result.count] = text[i];
            result.count += 1;
        }
    }
    result.exp = std.fmt.parseInt(i32, text[i + 1 ..], 10) catch 0;
    while (result.count > 1 and result.digits[result.count - 1] == '0') result.count -= 1;
    return result;
}

fn formatNumber(out: *TextBuf, v: f64) void {
    if (v == 0) return out.add("0");
    var s = toScientific(v, MAX_DIGITS);
    if (s.exp < 0 and s.exp >= -6) {
        // 0.000123 spends digits on leading zeros, so it keeps fewer significant ones.
        s = toScientific(v, @intCast(@as(i32, MAX_DIGITS) + s.exp));
    }
    if (s.negative) out.add(MINUS);
    const digits = s.digits[0..s.count];
    if (s.exp >= @as(i32, MAX_DIGITS) or s.exp < -6) {
        out.addByte(digits[0]);
        if (digits.len > 1) {
            out.addByte('.');
            out.add(digits[1..]);
        }
        out.addByte('e');
        if (s.exp < 0) out.add(MINUS);
        var exp_buf: [8]u8 = undefined;
        out.add(std.fmt.bufPrint(&exp_buf, "{d}", .{@abs(s.exp)}) catch unreachable);
    } else if (s.exp >= 0) {
        const int_len: usize = @intCast(s.exp + 1);
        var int_digits: [MAX_DIGITS]u8 = undefined;
        for (0..int_len) |i| int_digits[i] = if (i < digits.len) digits[i] else '0';
        addGrouped(out, int_digits[0..int_len]);
        if (digits.len > int_len) {
            out.addByte('.');
            out.add(digits[int_len..]);
        }
    } else {
        out.add("0.");
        var zeros: i32 = -s.exp - 1;
        while (zeros > 0) : (zeros -= 1) out.addByte('0');
        out.add(digits);
    }
}

// ---- Bitmap font -------------------------------------------------------------------
// A 5x7 pixel font. Each row's bits start at bit 4 for the leftmost pixel.

const Glyph = struct { width: i32, rows: [7]u8 };

fn glyph(ch: u8) Glyph {
    const rows: [7]u8 = switch (ch) {
        '0' => .{ 14, 17, 17, 17, 17, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        'C' => .{ 15, 16, 16, 16, 16, 16, 15 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'a' => .{ 0, 0, 14, 1, 15, 17, 15 },
        'c' => .{ 0, 0, 15, 16, 16, 16, 15 },
        'e' => .{ 0, 0, 14, 17, 31, 16, 15 },
        'l' => .{ 12, 4, 4, 4, 4, 4, 14 },
        'o' => .{ 0, 0, 14, 17, 17, 17, 14 },
        'r' => .{ 0, 0, 22, 25, 16, 16, 16 },
        't' => .{ 8, 8, 28, 8, 8, 9, 6 },
        'u' => .{ 0, 0, 17, 17, 17, 19, 13 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '*' => .{ 0, 4, 21, 14, 21, 4, 0 },
        '/' => .{ 1, 1, 2, 4, 8, 16, 16 },
        '=' => .{ 0, 0, 31, 0, 31, 0, 0 },
        '.' => return .{ .width = 2, .rows = .{ 0, 0, 0, 0, 0, 24, 24 } },
        ',' => return .{ .width = 2, .rows = .{ 0, 0, 0, 0, 24, 8, 16 } },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
    return .{ .width = 5, .rows = rows };
}

const GLYPH_H: i32 = 7;

// Bold text smears each glyph one pixel to the right, as QuickDraw did.
fn textWidth(text: []const u8, scale: i32, bold: bool) i32 {
    var w: i32 = 0;
    for (text) |ch| w += (glyph(ch).width + 1 + @intFromBool(bold)) * scale;
    return if (w > 0) w - scale else 0;
}

fn drawText(text: []const u8, x0: i32, y: i32, scale: i32, bold: bool, ink: u8) void {
    var x = x0;
    for (text) |ch| {
        const g = glyph(ch);
        for (g.rows, 0..) |row, ry| {
            var rx: i32 = 0;
            while (rx < g.width) : (rx += 1) {
                if ((row >> @intCast(4 - rx)) & 1 == 0) continue;
                const px = x + rx * scale;
                const py = y + @as(i32, @intCast(ry)) * scale;
                fillRect(.{ .x = px, .y = py, .w = scale * (1 + @as(i32, @intFromBool(bold))), .h = scale }, ink);
            }
        }
        x += (g.width + 1 + @intFromBool(bold)) * scale;
    }
}

// ---- Drawing -----------------------------------------------------------------------

const WHITE: u8 = 0;
const BLACK: u8 = 1;

fn drawFrame() void {
    // The grey desktop is a checkerboard of black and white pixels.
    for (0..LH) |y| {
        for (0..LW) |x| canvas[y * LW + x] = @intCast((x + y) & 1);
    }
    drawWindow();
    drawDisplay();
    for (keys, 0..) |k, i| drawKey(k, state.pressed == i);
}

fn drawWindow() void {
    const w = WIN;
    fillRect(.{ .x = w.x + 1, .y = w.y + 1, .w = w.w, .h = w.h }, BLACK); // Drop shadow.
    fillRect(w, WHITE);
    frameRect(w);
    hline(w.x, w.x + w.w - 1, TITLE_LINE_Y);

    // Six title-bar stripes, broken by the close box and the title.
    var y = w.y + 4;
    while (y < TITLE_LINE_Y - 3) : (y += 2) hline(w.x + 2, w.x + w.w - 3, y);
    const close: Rect = .{ .x = w.x + 8, .y = w.y + 4, .w = 11, .h = 11 };
    fillRect(.{ .x = close.x - 1, .y = close.y - 1, .w = close.w + 2, .h = close.h + 2 }, WHITE);
    frameRect(close);

    const title = "Calculator";
    const tw = textWidth(title, 1, false);
    const tx = w.x + @divFloor(w.w - tw, 2);
    fillRect(.{ .x = tx - 4, .y = w.y + 3, .w = tw + 8, .h = 13 }, WHITE);
    drawText(title, tx, w.y + 6, 1, false, BLACK);
}

fn drawDisplay() void {
    fillRect(DISPLAY, WHITE);
    frameRect(DISPLAY);
    var text: TextBuf = .{};
    if (state.has_error) {
        text.add("Error");
    } else if (state.entering) {
        formatEntry(&text);
    } else {
        formatNumber(&text, state.acc);
    }
    // Double-size digits when they fit, otherwise the normal size.
    const room = DISPLAY.w - 8;
    const scale: i32 = if (textWidth(text.slice(), 2, false) <= room) 2 else 1;
    const tw = textWidth(text.slice(), scale, false);
    const y = DISPLAY.y + @divFloor(DISPLAY.h - GLYPH_H * scale, 2);
    drawText(text.slice(), DISPLAY.x + DISPLAY.w - 4 - tw, y, scale, false, BLACK);
}

// A key is a white face with a black outline and rounded corners, and a
// one-pixel shadow along its right and bottom edges. Pressed keys invert.
fn drawKey(k: KeyDef, pressed: bool) void {
    const r = keyRect(k);
    const face: Rect = .{ .x = r.x, .y = r.y, .w = r.w - 1, .h = r.h - 1 };
    fillRect(face, if (pressed) BLACK else WHITE);
    frameRect(face);
    hline(face.x + 1, face.x + face.w, face.y + face.h);
    vline(face.x + face.w, face.y + 1, face.y + face.h);
    // Round the outer corners.
    setPixel(face.x, face.y, WHITE);
    setPixel(face.x + face.w - 1, face.y, WHITE);
    setPixel(face.x, face.y + face.h - 1, WHITE);
    setPixel(face.x + face.w, face.y + face.h, WHITE);
    setPixel(face.x + 1, face.y + 1, BLACK);
    setPixel(face.x + face.w - 2, face.y + 1, BLACK);
    setPixel(face.x + 1, face.y + face.h - 2, BLACK);

    const tw = textWidth(k.label, 1, true);
    const lx = face.x + @divFloor(face.w - tw + 1, 2);
    const ly = face.y + @divFloor(face.h - GLYPH_H, 2);
    drawText(k.label, lx, ly, 1, true, if (pressed) WHITE else BLACK);
}

fn setPixel(x: i32, y: i32, ink: u8) void {
    if (x < 0 or y < 0 or x >= LW or y >= LH) return;
    canvas[@as(usize, @intCast(y)) * LW + @as(usize, @intCast(x))] = ink;
}

fn fillRect(r: Rect, ink: u8) void {
    const x0: usize = @intCast(std.math.clamp(r.x, 0, LW));
    const x1: usize = @intCast(std.math.clamp(r.x + r.w, 0, LW));
    const y0: usize = @intCast(std.math.clamp(r.y, 0, LH));
    const y1: usize = @intCast(std.math.clamp(r.y + r.h, 0, LH));
    if (x0 >= x1) return;
    for (y0..y1) |y| @memset(canvas[y * LW + x0 .. y * LW + x1], ink);
}

// Inclusive ends.
fn hline(x0: i32, x1: i32, y: i32) void {
    fillRect(.{ .x = x0, .y = y, .w = x1 - x0 + 1, .h = 1 }, BLACK);
}

fn vline(x: i32, y0: i32, y1: i32) void {
    fillRect(.{ .x = x, .y = y0, .w = 1, .h = y1 - y0 + 1 }, BLACK);
}

fn frameRect(r: Rect) void {
    hline(r.x, r.x + r.w - 1, r.y);
    hline(r.x, r.x + r.w - 1, r.y + r.h - 1);
    vline(r.x, r.y, r.y + r.h - 1);
    vline(r.x + r.w - 1, r.y, r.y + r.h - 1);
}

// Scales the canvas up into the KTX2 output: each canvas row becomes one
// expanded output row, copied SCALE times.
fn present() void {
    const row_bytes = RENDER_W * 4;
    for (0..LH) |y| {
        const first = ktx.HEADER_SIZE + y * SCALE * row_bytes;
        const row = output_buf[first..][0..row_bytes];
        for (0..LW) |x| {
            const v: u8 = if (canvas[y * LW + x] == BLACK) 0x00 else 0xFF;
            const px = row[x * SCALE * 4 ..][0 .. SCALE * 4];
            for (0..SCALE) |i| px[i * 4 ..][0..4].* = .{ v, v, v, 0xFF };
        }
        for (1..SCALE) |i| @memcpy(output_buf[first + i * row_bytes ..][0..row_bytes], row);
    }
}

// ---- Tests ---------------------------------------------------------------------------

fn resetForTest() void {
    state = .{};
    phase = .initializing;
    begun_at_ms = 0;
    committed_at_ms = 0;
}

fn typeKeys(text: []const u8) void {
    for (text) |ch| {
        const key: i32 = switch (ch) {
            '\n' => XK_RETURN,
            '<' => XK_BACKSPACE,
            '~' => 'n',
            else => ch,
        };
        _ = key_event(key, FLAG_KEY_DOWN);
    }
}

fn displayText() TextBuf {
    var out: TextBuf = .{};
    if (state.has_error) {
        out.add("Error");
    } else if (state.entering) {
        formatEntry(&out);
    } else {
        formatNumber(&out, state.acc);
    }
    return out;
}

fn expectDisplay(keys_typed: []const u8, expected: []const u8) !void {
    resetForTest();
    _ = renderImpl(0);
    begin_update_at(1);
    typeKeys(keys_typed);
    _ = finish_update();
    const shown = displayText();
    try std.testing.expectEqualStrings(expected, shown.slice());
}

test "arithmetic" {
    try expectDisplay("2+3=", "5");
    try expectDisplay("12*3=", "36");
    try expectDisplay("7-10=", "-3");
    try expectDisplay("1/4=", "0.25");
    try expectDisplay("2+3*4=", "20"); // Immediate execution, like a desk calculator.
}

test "decimals round for display" {
    try expectDisplay(".1+.2=", "0.3");
    try expectDisplay("1/3=", "0.333333333");
    try expectDisplay("2/3=", "0.666666667");
    try expectDisplay("1.50", "1.50");
    try expectDisplay("3..2", "3.2");
}

test "grouping and scientific notation" {
    try expectDisplay("1234567", "1,234,567");
    try expectDisplay("1234567.5", "1,234,567.5");
    try expectDisplay("99999*99999=", "9,999,800,001");
    try expectDisplay("9999999999*1000=", "9.999999999e12");
    try expectDisplay("1/3000000=", "3.333333333e-7");
    try expectDisplay("1/400000=", "0.0000025");
}

test "repeat equals, operator changes, sign and backspace" {
    try expectDisplay("2+3==", "8");
    try expectDisplay("5+=", "10");
    try expectDisplay("5+-3=", "2");
    try expectDisplay("123<", "12");
    try expectDisplay("1<", "0");
    try expectDisplay("5~", "-5");
    try expectDisplay("5+~3=", "2");
    try expectDisplay("2+3=~", "-5");
}

test "clear clears the entry, then everything" {
    try expectDisplay("12+34C5=", "17");
    try expectDisplay("12+34CC5=", "5");
}

test "E clears the entry and keeps the pending operation" {
    try expectDisplay("12+34E5=", "17");
    try expectDisplay("12+E", "0");
    try expectDisplay("12+E3=", "15");
}

test "on-screen keys follow the desk accessory layout" {
    try std.testing.expectEqual(@as(u8, 4), keyIndexAt(18 * SCALE, 99 * SCALE)); // 7
    try std.testing.expectEqual(@as(u8, 16), keyIndexAt(48 * SCALE, 162 * SCALE)); // wide 0
    try std.testing.expectEqual(@as(u8, 15), keyIndexAt(102 * SCALE, 162 * SCALE)); // tall +
    try std.testing.expectEqual(NO_KEY, keyIndexAt(0, 0));
    for (keys) |k| {
        const r = keyRect(k);
        try std.testing.expect(r.x > WIN.x and r.x + r.w < WIN.x + WIN.w);
        try std.testing.expect(r.y > DISPLAY.y + DISPLAY.h and r.y + r.h < WIN.y + WIN.h);
    }
}

test "the canvas is one-bit and scaled up exactly" {
    resetForTest();
    _ = renderImpl(0);
    const pixels = output_buf[ktx.HEADER_SIZE..];
    for (0..RENDER_H) |y| {
        for (0..RENDER_W) |x| {
            const i = (y * RENDER_W + x) * 4;
            const v = pixels[i];
            try std.testing.expect(v == 0 or v == 0xFF);
            try std.testing.expectEqual(v, pixels[((y / SCALE * SCALE) * RENDER_W + x / SCALE * SCALE) * 4]);
        }
    }
}

test "errors" {
    try expectDisplay("5/0=", "Error");
    try expectDisplay("5/0=7", "7");
    try expectDisplay("5/0=<", "0");
}

test "ignored keys report no change" {
    resetForTest();
    _ = renderImpl(0);
    begin_update_at(1);
    try std.testing.expectEqual(@as(i32, 0), key_event('q', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), key_event(XK_BACKSPACE, FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), key_event('C', FLAG_KEY_DOWN));
    try std.testing.expectEqual(@as(i32, 0), pointer_event(0, -1, -1));
    try std.testing.expectEqual(@as(i32, 1), key_event('1', FLAG_KEY_DOWN));
    _ = finish_update();
}

test "pointer presses keys by position and highlights them until release" {
    resetForTest();
    _ = renderImpl(0);
    begin_update_at(1);
    const seven = keyRect(keys[4]);
    const x: i32 = (seven.x + @divFloor(seven.w, 2)) * @as(i32, SCALE);
    const y: i32 = (seven.y + @divFloor(seven.h, 2)) * @as(i32, SCALE);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(BTN_PRIMARY, x, y));
    try std.testing.expectEqual(@as(u8, 4), state.pressed);
    try std.testing.expectEqual(@as(i32, 1), pointer_event(0, x, y));
    try std.testing.expectEqual(NO_KEY, state.pressed);
    _ = finish_update();
    try std.testing.expectEqualStrings("7", displayText().slice());
}

test "calculator updates state separately from presentation" {
    resetForTest();
    const size = renderImpl(0);
    try std.testing.expectEqual(@as(u32, OUTPUT_BYTES), size);
    const initial_hash = std.hash.Wyhash.hash(0, &output_buf);

    begin_update_at(1);
    typeKeys("2+3=");
    try std.testing.expectEqual(@as(i64, 1), finish_update());
    try std.testing.expectEqual(initial_hash, std.hash.Wyhash.hash(0, &output_buf));

    try std.testing.expectEqual(size, renderImpl(0));
    const result_hash = std.hash.Wyhash.hash(0, &output_buf);
    try std.testing.expect(initial_hash != result_hash);
    try std.testing.expectEqual(size, renderImpl(0));
    try std.testing.expectEqual(result_hash, std.hash.Wyhash.hash(0, &output_buf));
}
