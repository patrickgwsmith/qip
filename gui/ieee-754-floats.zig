const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 760;
const RENDER_H: usize = 560;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_RETURN: i32 = 0xFF0D;
const XK_ESCAPE: i32 = 0xFF1B;
const XK_SPACE: i32 = 0x20;
const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;

const Color = [4]u8;
const C_BG: Color = .{ 0xF7, 0xF4, 0xEC, 0xFF };
const C_PANEL: Color = .{ 0xFF, 0xFD, 0xF8, 0xFF };
const C_INK: Color = .{ 0x18, 0x1A, 0x1F, 0xFF };
const C_MUTED: Color = .{ 0x66, 0x63, 0x5C, 0xFF };
const C_LINE: Color = .{ 0xB8, 0xB0, 0xA4, 0xFF };
const C_SIGN: Color = .{ 0xD5, 0x5E, 0x00, 0xFF };
const C_EXP: Color = .{ 0x56, 0xB4, 0xE9, 0xFF };
const C_FRAC: Color = .{ 0x00, 0x9E, 0x73, 0xFF };
const C_ACTIVE: Color = .{ 0xF0, 0xE4, 0x42, 0xFF };
const C_WARN: Color = .{ 0xCC, 0x79, 0xA7, 0xFF };

const BitBox = struct { bit: u6, x: i32, y: i32, w: i32, h: i32 };
const Decode = struct {
    sign: u1,
    exponent_raw: u16,
    exponent_bits: u8,
    fraction_bits: u8,
    bias: i32,
    exponent: i32,
    fraction: u64,
    category: []const u8,
    hidden_bit: []const u8,
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var is_f64 = false;
var bits: u64 = 0x40490FDB; // f32 pi
var selected_bit: u6 = 31;
var primary_down = false;

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
    const changed = switch (x11_key) {
        'f', 'F' => setMode(!is_f64),
        '3' => setMode(false),
        '6' => setMode(true),
        's', 'S', 'n', 'N' => toggleSign(),
        'z', 'Z' => presetZero(),
        'o', 'O', '1' => presetOne(),
        'p', 'P' => presetPi(),
        'i', 'I' => presetInf(),
        'q', 'Q' => presetNaN(),
        'm', 'M' => presetMinNorm(),
        XK_LEFT => selectHorizontalBit(-1),
        XK_RIGHT => selectHorizontalBit(1),
        XK_UP => selectAdjacentBit(32),
        XK_DOWN => selectAdjacentBit(-32),
        XK_SPACE, XK_RETURN => toggleSelectedBit(),
        XK_ESCAPE => false,
        else => false,
    };
    return if (changed) 1 else 0;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;
    if (down and !primary_down) {
        if (hit(x, y, 20, 42, 58, 24)) changed = setMode(false);
        if (hit(x, y, 82, 42, 58, 24)) changed = setMode(true);
        if (hit(x, y, 158, 42, 84, 24)) changed = toggleSign();
        if (hit(x, y, 256, 42, 60, 24)) changed = presetZero();
        if (hit(x, y, 322, 42, 60, 24)) changed = presetOne();
        if (hit(x, y, 388, 42, 54, 24)) changed = presetPi();
        if (hit(x, y, 448, 42, 54, 24)) changed = presetInf();
        if (hit(x, y, 508, 42, 54, 24)) changed = presetNaN();
        if (hit(x, y, 568, 42, 92, 24)) changed = presetMinNorm();

        const maybe_bit = bitAtPoint(x, y);
        if (maybe_bit) |bit| {
            selected_bit = bit;
            changed = toggleBit(bit);
        }
    }
    primary_down = down;
    return if (changed) 1 else 0;
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

fn setMode(next_f64: bool) bool {
    if (is_f64 == next_f64) return false;
    if (next_f64) {
        const f: f32 = @bitCast(@as(u32, @intCast(bits & 0xFFFF_FFFF)));
        bits = @bitCast(@as(f64, @floatCast(f)));
    } else {
        const d: f64 = @bitCast(bits);
        bits = @as(u32, @bitCast(@as(f32, @floatCast(d))));
    }
    is_f64 = next_f64;
    clampSelectedBit();
    return true;
}

fn toggleSign() bool {
    return toggleBit(signBit());
}

fn presetZero() bool {
    bits = 0;
    clampSelectedBit();
    return true;
}

fn presetOne() bool {
    bits = if (is_f64) @as(u64, @bitCast(@as(f64, 1.0))) else @as(u32, @bitCast(@as(f32, 1.0)));
    clampSelectedBit();
    return true;
}

fn presetPi() bool {
    bits = if (is_f64) @as(u64, @bitCast(@as(f64, std.math.pi))) else @as(u32, @bitCast(@as(f32, std.math.pi)));
    clampSelectedBit();
    return true;
}

fn presetInf() bool {
    bits = if (is_f64) 0x7FF0_0000_0000_0000 else 0x7F80_0000;
    clampSelectedBit();
    return true;
}

fn presetNaN() bool {
    bits = if (is_f64) 0x7FF8_0000_0000_0001 else 0x7FC0_0001;
    clampSelectedBit();
    return true;
}

fn presetMinNorm() bool {
    bits = if (is_f64) 0x0010_0000_0000_0000 else 0x0080_0000;
    clampSelectedBit();
    return true;
}

fn toggleSelectedBit() bool {
    return toggleBit(selected_bit);
}

fn toggleBit(bit: u6) bool {
    bits ^= (@as(u64, 1) << bit);
    if (!is_f64) bits &= 0xFFFF_FFFF;
    return true;
}

fn selectAdjacentBit(delta: i32) bool {
    const max_bit = @as(i32, signBit());
    var next = @as(i32, selected_bit) + delta;
    if (next < 0) next = 0;
    if (next > max_bit) next = max_bit;
    const cast_next: u6 = @intCast(next);
    if (selected_bit == cast_next) return false;
    selected_bit = cast_next;
    return true;
}

fn selectHorizontalBit(column_delta: i32) bool {
    const total = @as(i32, totalBits());
    const index_from_left = total - 1 - @as(i32, selected_bit);
    const row_start = @divTrunc(index_from_left, 32) * 32;
    const next_index = std.math.clamp(index_from_left + column_delta, row_start, row_start + 31);
    const next_bit: u6 = @intCast(total - 1 - next_index);
    if (selected_bit == next_bit) return false;
    selected_bit = next_bit;
    return true;
}

fn clampSelectedBit() void {
    if (selected_bit > signBit()) selected_bit = signBit();
}

fn drawFrame() void {
    fillRect(0, 0, @intCast(RENDER_W), @intCast(RENDER_H), C_BG);
    drawText(20, 18, "IEEE 754 FLOATING POINT", C_INK);
    button(20, 42, 58, "F32", !is_f64);
    button(82, 42, 58, "F64", is_f64);
    button(158, 42, 84, "NEGATIVE", sign() == 1);
    button(256, 42, 60, "ZERO", false);
    button(322, 42, 60, "ONE", false);
    button(388, 42, 54, "PI", false);
    button(448, 42, 54, "INF", false);
    button(508, 42, 54, "NAN", false);
    button(568, 42, 92, "MIN NORM", false);

    legend(470, 18);
    bitGrid();
    decodedPanel();
    valuePanel();
    layoutPanel();
}

fn legend(x: i32, y: i32) void {
    legendItem(x, y, "SIGN", C_SIGN);
    legendItem(x + 72, y, "EXP", C_EXP);
    legendItem(x + 136, y, "FRACTION", C_FRAC);
}

fn legendItem(x: i32, y: i32, label: []const u8, c: Color) void {
    fillRect(x, y + 1, 12, 10, c);
    drawBorder(x, y + 1, 12, 10, C_INK);
    drawText(x + 16, y, label, C_MUTED);
}

fn bitGrid() void {
    drawText(20, 88, "CLICK BITS TO TOGGLE", C_MUTED);
    const total: u8 = totalBits();
    var i: u8 = 0;
    while (i < total) : (i += 1) {
        const bit: u6 = @intCast(total - 1 - i);
        const box = bitBox(bit);
        const one = ((bits >> bit) & 1) != 0;
        const c = bitColor(bit);
        fillRect(box.x, box.y, box.w, box.h, if (one) c else C_PANEL);
        drawBorder(box.x, box.y, box.w, box.h, c);
        if (bit == selected_bit) drawBorder(box.x + 2, box.y + 2, box.w - 4, box.h - 4, C_ACTIVE);
        drawText(box.x + 7, box.y + 7, if (one) "1" else "0", if (one) C_PANEL else C_INK);
        if (@mod(i, 4) == 0) {
            var buf: [8]u8 = undefined;
            drawText(box.x, box.y - 14, std.fmt.bufPrint(&buf, "{d}", .{bit}) catch "", C_MUTED);
        }
    }
    drawGroupLabels();
}

fn drawGroupLabels() void {
    const s = bitBox(signBit());
    drawText(s.x, s.y + 30, "SIGN", C_SIGN);
    const e0 = bitBox(signBit() - 1);
    drawText(e0.x, e0.y + 30, "EXPONENT", C_EXP);
    const f0 = bitBox(bitIndex(fractionBits() - 1));
    drawText(f0.x, f0.y + 30, "FRACTION / MANTISSA", C_FRAC);
}

fn decodedPanel() void {
    const d = decode();
    fillRect(20, 220, 350, 150, C_PANEL);
    drawBorder(20, 220, 350, 150, C_LINE);
    drawText(34, 236, "DECODED FIELDS", C_INK);

    var b1: [48]u8 = undefined;
    var b2: [48]u8 = undefined;
    var b3: [48]u8 = undefined;
    var b4: [64]u8 = undefined;
    var b5: [48]u8 = undefined;
    drawText(34, 260, std.fmt.bufPrint(&b1, "SIGN: {d}", .{d.sign}) catch "", C_INK);
    drawText(34, 280, std.fmt.bufPrint(&b2, "RAW EXP: {d}  BIAS: {d}", .{ d.exponent_raw, d.bias }) catch "", C_INK);
    drawText(34, 300, std.fmt.bufPrint(&b3, "UNBIASED EXP: {d}", .{d.exponent}) catch "", C_INK);
    drawText(34, 320, std.fmt.bufPrint(&b4, "FRACTION: 0X{X}", .{d.fraction}) catch "", C_INK);
    drawText(34, 340, std.fmt.bufPrint(&b5, "HIDDEN BIT: {s}", .{d.hidden_bit}) catch "", C_INK);
    drawText(214, 260, d.category, if (isSpecial(d)) C_WARN else C_FRAC);
}

fn valuePanel() void {
    fillRect(390, 220, 350, 150, C_PANEL);
    drawBorder(390, 220, 350, 150, C_LINE);
    drawText(404, 236, "FORMATTED VALUES", C_INK);

    var hex_buf: [48]u8 = undefined;
    var bytes_buf: [80]u8 = undefined;
    var dec_buf: [96]u8 = undefined;
    var sci_buf: [96]u8 = undefined;

    drawText(404, 260, hexString(&hex_buf), C_INK);
    drawText(404, 280, byteString(&bytes_buf), C_INK);
    drawText(404, 304, decimalString(&dec_buf), C_INK);
    drawText(404, 326, scientificString(&sci_buf), C_INK);
    drawText(404, 348, if (is_f64) "WASM TYPE: F64" else "WASM TYPE: F32", C_MUTED);
}

fn layoutPanel() void {
    fillRect(20, 392, 720, 132, C_PANEL);
    drawBorder(20, 392, 720, 132, C_LINE);
    drawText(34, 408, "WHAT TO NOTICE", C_INK);
    drawText(34, 432, "EXPONENT ALL 0 MAKES ZERO OR SUBNORMAL. THE HIDDEN BIT IS 0.", C_MUTED);
    drawText(34, 454, "EXPONENT ALL 1 MAKES INFINITY OR NAN, DEPENDING ON FRACTION.", C_MUTED);
    drawText(34, 476, "NORMAL VALUES USE (-1)^SIGN * 1.FRACTION * 2^EXPONENT.", C_MUTED);
    drawText(34, 498, "F32 HAS 1 SIGN, 8 EXPONENT, 23 FRACTION BITS. F64 HAS 1, 11, 52.", C_MUTED);
}

fn decode() Decode {
    const exp_bits = exponentBits();
    const frac_bits = fractionBits();
    const exp_mask = (@as(u64, 1) << shiftAmount64(exp_bits)) - 1;
    const frac_mask = (@as(u64, 1) << shiftAmount64(frac_bits)) - 1;
    const raw: u16 = @intCast((bits >> shiftAmount64(frac_bits)) & exp_mask);
    const frac = bits & frac_mask;
    const bias_value: i32 = if (is_f64) 1023 else 127;
    const all_exp = @as(u16, @intCast(exp_mask));
    const category: []const u8 = if (raw == 0)
        if (frac == 0) "ZERO" else "SUBNORMAL"
    else if (raw == all_exp)
        if (frac == 0) "INFINITY" else "NAN"
    else
        "NORMAL";
    return .{
        .sign = sign(),
        .exponent_raw = raw,
        .exponent_bits = exp_bits,
        .fraction_bits = frac_bits,
        .bias = bias_value,
        .exponent = if (raw == 0) 1 - bias_value else @as(i32, raw) - bias_value,
        .fraction = frac,
        .category = category,
        .hidden_bit = if (raw == 0) "0" else if (raw == all_exp) "N/A" else "1",
    };
}

fn isSpecial(d: Decode) bool {
    const all_exp = (@as(u16, 1) << shiftAmount16(d.exponent_bits)) - 1;
    return d.exponent_raw == 0 or d.exponent_raw == all_exp;
}

fn decimalString(buf: *[96]u8) []const u8 {
    if (is_f64) {
        const v: f64 = @bitCast(bits);
        return std.fmt.bufPrint(buf, "DECIMAL: {d}", .{v}) catch "";
    }
    const v: f32 = @bitCast(@as(u32, @intCast(bits & 0xFFFF_FFFF)));
    return std.fmt.bufPrint(buf, "DECIMAL: {d}", .{v}) catch "";
}

fn scientificString(buf: *[96]u8) []const u8 {
    if (is_f64) {
        const v: f64 = @bitCast(bits);
        return std.fmt.bufPrint(buf, "SCIENTIFIC: {e}", .{v}) catch "";
    }
    const v: f32 = @bitCast(@as(u32, @intCast(bits & 0xFFFF_FFFF)));
    return std.fmt.bufPrint(buf, "SCIENTIFIC: {e}", .{v}) catch "";
}

fn hexString(buf: *[48]u8) []const u8 {
    if (is_f64) return std.fmt.bufPrint(buf, "HEX BITS: 0X{X:0>16}", .{bits}) catch "";
    return std.fmt.bufPrint(buf, "HEX BITS: 0X{X:0>8}", .{@as(u32, @intCast(bits & 0xFFFF_FFFF))}) catch "";
}

fn byteString(buf: *[80]u8) []const u8 {
    if (is_f64) {
        return std.fmt.bufPrint(buf, "BYTES LE: {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
            @as(u8, @intCast((bits >> 0) & 0xFF)),
            @as(u8, @intCast((bits >> 8) & 0xFF)),
            @as(u8, @intCast((bits >> 16) & 0xFF)),
            @as(u8, @intCast((bits >> 24) & 0xFF)),
            @as(u8, @intCast((bits >> 32) & 0xFF)),
            @as(u8, @intCast((bits >> 40) & 0xFF)),
            @as(u8, @intCast((bits >> 48) & 0xFF)),
            @as(u8, @intCast((bits >> 56) & 0xFF)),
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "BYTES LE: {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
        @as(u8, @intCast((bits >> 0) & 0xFF)),
        @as(u8, @intCast((bits >> 8) & 0xFF)),
        @as(u8, @intCast((bits >> 16) & 0xFF)),
        @as(u8, @intCast((bits >> 24) & 0xFF)),
    }) catch "";
}

fn bitAtPoint(x: i32, y: i32) ?u6 {
    const total = totalBits();
    var i: u8 = 0;
    while (i < total) : (i += 1) {
        const bit: u6 = @intCast(total - 1 - i);
        const b = bitBox(bit);
        if (hit(x, y, b.x, b.y, b.w, b.h)) return bit;
    }
    return null;
}

fn bitBox(bit: u6) BitBox {
    const total = totalBits();
    const index_from_left: i32 = @as(i32, total - 1) - @as(i32, bit);
    const per_row: i32 = if (is_f64) 32 else 32;
    const cell_w: i32 = if (is_f64) 22 else 22;
    const cell_h: i32 = 24;
    const gap: i32 = 0;
    const row = @divTrunc(index_from_left, per_row);
    const col = @mod(index_from_left, per_row);
    return .{ .bit = bit, .x = 20 + col * (cell_w + gap), .y = 116 + row * 42, .w = cell_w, .h = cell_h };
}

fn bitColor(bit: u6) Color {
    if (bit == signBit()) return C_SIGN;
    if (bit >= fractionBits()) return C_EXP;
    return C_FRAC;
}

fn totalBits() u8 {
    return if (is_f64) 64 else 32;
}

fn signBit() u6 {
    return if (is_f64) 63 else 31;
}

fn exponentBits() u8 {
    return if (is_f64) 11 else 8;
}

fn fractionBits() u8 {
    return if (is_f64) 52 else 23;
}

fn bitIndex(bit: u8) u6 {
    return @intCast(bit);
}

fn shiftAmount64(bit_count: u8) u6 {
    return @intCast(bit_count);
}

fn shiftAmount16(bit_count: u8) u4 {
    return @intCast(bit_count);
}

fn sign() u1 {
    return @intCast((bits >> signBit()) & 1);
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn button(x: i32, y: i32, w: i32, label: []const u8, active: bool) void {
    fillRect(x, y, w, 24, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, 24, C_INK);
    drawText(x + 8, y + 8, label, C_INK);
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len and i < 96) : (i += 1) drawChar(x + @as(i32, @intCast(i)) * 8, y, text[i], c);
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const glyph_rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((glyph_rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) != 0) fillRect(x + @as(i32, @intCast(rx * 2)), y + @as(i32, @intCast(ry * 2)), 2, 2, c);
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
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        '^' => .{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '*' => .{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn drawBorder(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRect(x, y, w, 1, c);
    fillRect(x, y, 1, h, c);
    fillRect(x, y + h - 1, w, 1, c);
    fillRect(x + w - 1, y, 1, h, c);
}

fn fillRect(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = @max(0, x0);
    const sy = @max(0, y0);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x0 + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y0 + h);
    if (sx >= ex or sy >= ey) return;
    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) {
            const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
            pixel_buf[idx + 0] = c[0];
            pixel_buf[idx + 1] = c[1];
            pixel_buf[idx + 2] = c[2];
            pixel_buf[idx + 3] = c[3];
        }
    }
}

test "f32 one decodes as normal zero exponent" {
    is_f64 = false;
    bits = @as(u32, @bitCast(@as(f32, 1.0)));
    const d = decode();
    try std.testing.expectEqual(@as(u16, 127), d.exponent_raw);
    try std.testing.expectEqual(@as(i32, 0), d.exponent);
    try std.testing.expectEqualStrings("NORMAL", d.category);
}

test "f64 infinity is special" {
    is_f64 = true;
    bits = 0x7FF0_0000_0000_0000;
    const d = decode();
    try std.testing.expectEqualStrings("INFINITY", d.category);
}

test "horizontal selection follows visual bit order in f32" {
    is_f64 = false;
    selected_bit = 31;

    try std.testing.expect(!selectHorizontalBit(-1));
    try std.testing.expect(selectHorizontalBit(1));
    try std.testing.expectEqual(@as(u6, 30), selected_bit);
    try std.testing.expect(selectHorizontalBit(-1));
    try std.testing.expectEqual(@as(u6, 31), selected_bit);

    selected_bit = 0;
    try std.testing.expect(!selectHorizontalBit(1));
}

test "horizontal selection stays within each f64 row" {
    is_f64 = true;

    selected_bit = 32;
    try std.testing.expect(!selectHorizontalBit(1));
    try std.testing.expect(selectHorizontalBit(-1));
    try std.testing.expectEqual(@as(u6, 33), selected_bit);

    selected_bit = 31;
    try std.testing.expect(!selectHorizontalBit(-1));
    try std.testing.expect(selectHorizontalBit(1));
    try std.testing.expectEqual(@as(u6, 30), selected_bit);
}
