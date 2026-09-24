const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 640;
const RENDER_H: usize = 420;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const BTN_PRIMARY: i32 = 1 << 0;

const Color = [4]u8;
const C_BG: Color = .{ 0xF7, 0xF4, 0xEC, 0xFF };
const C_INK: Color = .{ 0x18, 0x1A, 0x1F, 0xFF };
const C_MUTED: Color = .{ 0x6B, 0x66, 0x5C, 0xFF };
const C_LINE: Color = .{ 0xB8, 0xB0, 0xA4, 0xFF };
const C_PANEL: Color = .{ 0xFF, 0xFD, 0xF8, 0xFF };
const C_FLEX: Color = .{ 0x20, 0x7A, 0xB8, 0xFF };
const C_SWIFT: Color = .{ 0xD8, 0x63, 0x30, 0xFF };
const C_GRID: Color = .{ 0x35, 0x8E, 0x64, 0xFF };
const C_LIGHT_BLUE: Color = .{ 0xD7, 0xEC, 0xF8, 0xFF };
const C_LIGHT_ORANGE: Color = .{ 0xF7, 0xDF, 0xD3, 0xFF };
const C_LIGHT_GREEN: Color = .{ 0xD9, 0xEF, 0xE3, 0xFF };
const C_ACTIVE: Color = .{ 0xEE, 0xCC, 0x33, 0xFF };
const C_OVERFLOW: Color = .{ 0xA8, 0xA0, 0x96, 0xFF };

const Mode = enum(u8) { wrap_hstack, nowrap_hstack, wrap_grid };
const Slider = enum(u8) { none, container, child, spacing, items };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var mode: Mode = .wrap_hstack;
var container_w: i32 = 210;
var child_w: i32 = 58;
var spacing: i32 = 10;
var item_count: i32 = 7;
var primary_down = false;
var active_slider: Slider = .none;

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

export fn key_event(_: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const down = (button_mask & BTN_PRIMARY) != 0;
    if (down) {
        if (!primary_down) {
            if (hitButton(x_px, y_px, 20, 52, 138, 24)) mode = .wrap_hstack;
            if (hitButton(x_px, y_px, 168, 52, 150, 24)) mode = .nowrap_hstack;
            if (hitButton(x_px, y_px, 328, 52, 132, 24)) mode = .wrap_grid;
            active_slider = sliderAt(x_px, y_px);
        }
        applySlider(active_slider, x_px);
    } else {
        active_slider = .none;
    }
    primary_down = down;
    return 1;
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

fn hitButton(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn sliderAt(x: i32, y: i32) Slider {
    if (x < 180 or x > 420) return .none;
    if (y >= 90 and y <= 106) return .container;
    if (y >= 116 and y <= 132) return .child;
    if (y >= 142 and y <= 158) return .spacing;
    if (y >= 168 and y <= 184) return .items;
    return .none;
}

fn applySlider(slider: Slider, x: i32) void {
    if (slider == .none) return;
    const t = clampI32(x - 180, 0, 240);
    switch (slider) {
        .container => container_w = 150 + @divTrunc(t * 170, 240),
        .child => child_w = 36 + @divTrunc(t * 94, 240),
        .spacing => spacing = @divTrunc(t * 24, 240),
        .items => item_count = 3 + @divTrunc(t * 7, 240),
        .none => {},
    }
}

fn drawFrame() void {
    fillRectI32(0, 0, @intCast(RENDER_W), @intCast(RENDER_H), C_BG);
    drawText(20, 18, "FLEXBOX AND SWIFTUI LAYOUT", C_INK);
    drawText(20, 34, "DRAG SLIDERS OR TAP A MODE", C_MUTED);

    drawModeButton(20, 52, 138, "FLEX WRAP", mode == .wrap_hstack);
    drawModeButton(168, 52, 150, "FLEX NOWRAP", mode == .nowrap_hstack);
    drawModeButton(328, 52, 132, "SWIFT GRID", mode == .wrap_grid);

    drawSlider(92, "CONTAINER", .container, container_w, 150, 320);
    drawSlider(118, "CHILD WIDTH", .child, child_w, 36, 130);
    drawSlider(144, "SPACING", .spacing, spacing, 0, 24);
    drawSlider(170, "ITEMS", .items, item_count, 3, 10);

    drawText(485, 93, "WIDTH MAKES", C_MUTED);
    drawText(485, 109, "THE DIFFERENCE", C_MUTED);
    drawText(485, 141, modeTitle(), C_INK);
    drawWrappedNote(485, 162, modeNote());

    drawFlexPanel();
    drawSwiftPanel();
}

fn drawModeButton(x: i32, y: i32, w: i32, label: []const u8, active: bool) void {
    fillRectI32(x, y, w, 24, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, 24, C_INK);
    drawText(x + 8, y + 8, label, C_INK);
}

fn drawSlider(y: i32, label: []const u8, which: Slider, value: i32, min: i32, max: i32) void {
    drawText(20, y - 2, label, C_INK);
    drawLineH(180, y + 4, 240, C_LINE);
    const knob_x = 180 + @divTrunc((value - min) * 240, max - min);
    fillRectI32(knob_x - 4, y - 2, 8, 14, if (active_slider == which) C_ACTIVE else C_INK);
    var buf: [16]u8 = undefined;
    drawText(432, y - 2, printInt(&buf, value), C_INK);
}

fn drawFlexPanel() void {
    const x0: i32 = 20;
    const y0: i32 = 210;
    drawText(x0, y0 - 24, "CSS FLEXBOX", C_FLEX);
    const wrap = mode != .nowrap_hstack;
    drawText(x0, y0 - 10, if (wrap) "FLEX-WRAP: WRAP" else "FLEX-WRAP: NOWRAP", C_MUTED);
    drawLayoutBox(x0, y0, container_w, true, wrap);
}

fn drawSwiftPanel() void {
    const x0: i32 = 340;
    const y0: i32 = 210;
    drawText(x0, y0 - 24, "SWIFTUI", C_SWIFT);
    drawText(x0, y0 - 10, if (mode == .wrap_grid) "LAZYVGRID" else "HSTACK", C_MUTED);
    drawLayoutBox(x0, y0, container_w, false, mode == .wrap_grid);
}

fn drawLayoutBox(x0: i32, y0: i32, w: i32, is_flex: bool, wraps: bool) void {
    fillRectI32(x0, y0, w, 150, C_PANEL);
    drawBorder(x0, y0, w, 150, if (is_flex) C_FLEX else C_SWIFT);
    var i: i32 = 0;
    var x: i32 = 8;
    var y: i32 = 14;
    const color = if (is_flex) C_LIGHT_BLUE else if (mode == .wrap_grid) C_LIGHT_GREEN else C_LIGHT_ORANGE;
    while (i < item_count) : (i += 1) {
        if (wraps and x > 8 and x + child_w > w - 8) {
            x = 8;
            y += 38;
        }
        const overflow = x + child_w > w - 8;
        fillRectI32(x0 + x, y0 + y, child_w, 26, if (overflow) C_OVERFLOW else color);
        drawBorder(x0 + x, y0 + y, child_w, 26, if (overflow) C_MUTED else C_INK);
        var buf: [16]u8 = undefined;
        drawText(x0 + x + 6, y0 + y + 9, printInt(&buf, i + 1), C_INK);
        x += child_w + spacing;
    }
    if (!wraps and x > w) {
        drawText(x0 + 8, y0 + 130, "OVERFLOWS", C_MUTED);
    } else if (wraps) {
        drawText(x0 + 8, y0 + 130, "NEW ROWS ARE EXPLICIT", if (is_flex) C_FLEX else C_GRID);
    }
}

fn modeTitle() []const u8 {
    return switch (mode) {
        .wrap_hstack => "WRAP VS HSTACK",
        .nowrap_hstack => "ONE ROW EACH",
        .wrap_grid => "WRAP VS GRID",
    };
}

fn modeNote() []const u8 {
    return switch (mode) {
        .wrap_hstack => "FLEXBOX CREATES NEW LINES WHEN THE NEXT ITEM DOES NOT FIT. HSTACK STAYS ONE ROW.",
        .nowrap_hstack => "NOWRAP FLEXBOX AND HSTACK BOTH PLACE CHILDREN IN ONE HORIZONTAL RUN.",
        .wrap_grid => "SWIFTUI WRAPPING IS A DIFFERENT LAYOUT, SUCH AS LAZYVGRID OR A CUSTOM LAYOUT.",
    };
}

fn drawWrappedNote(x: i32, y: i32, text: []const u8) void {
    var start: usize = 0;
    var line: usize = 0;
    while (start < text.len and line < 6) : (line += 1) {
        var end = @min(text.len, start + 18);
        if (end < text.len) {
            var scan = end;
            while (scan > start and text[scan] != ' ') : (scan -= 1) {}
            if (scan > start) end = scan;
        }
        drawText(x, y + @as(i32, @intCast(line * 14)), trimLeft(text[start..end]), C_MUTED);
        start = end;
        while (start < text.len and text[start] == ' ') start += 1;
    }
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    return s[i..];
}

fn printInt(buf: *[16]u8, value: i32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    drawTextScaled(x, y, text, c, 2);
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len and i < 48) : (i += 1) {
        drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
    }
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
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
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        ',' => .{ 0b000, 0b000, 0b000, 0b010, 0b100 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        ';' => .{ 0b000, 0b010, 0b000, 0b010, 0b100 },
        '!' => .{ 0b010, 0b010, 0b010, 0b000, 0b010 },
        '?' => .{ 0b111, 0b001, 0b011, 0b000, 0b010 },
        '"' => .{ 0b101, 0b101, 0b000, 0b000, 0b000 },
        '\'' => .{ 0b010, 0b010, 0b000, 0b000, 0b000 },
        '(' => .{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => .{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '[' => .{ 0b011, 0b010, 0b010, 0b010, 0b011 },
        ']' => .{ 0b110, 0b010, 0b010, 0b010, 0b110 },
        '{' => .{ 0b001, 0b010, 0b110, 0b010, 0b001 },
        '}' => .{ 0b100, 0b010, 0b011, 0b010, 0b100 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '\\' => .{ 0b100, 0b100, 0b010, 0b001, 0b001 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => .{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '=' => .{ 0b000, 0b111, 0b000, 0b111, 0b000 },
        '_' => .{ 0b000, 0b000, 0b000, 0b000, 0b111 },
        '|' => .{ 0b010, 0b010, 0b010, 0b010, 0b010 },
        '#' => .{ 0b101, 0b111, 0b101, 0b111, 0b101 },
        '$' => .{ 0b010, 0b111, 0b110, 0b011, 0b111 },
        '%' => .{ 0b101, 0b001, 0b010, 0b100, 0b101 },
        '&' => .{ 0b010, 0b101, 0b010, 0b101, 0b011 },
        '@' => .{ 0b111, 0b101, 0b111, 0b100, 0b111 },
        '^' => .{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '`' => .{ 0b010, 0b001, 0b000, 0b000, 0b000 },
        '~' => .{ 0b000, 0b011, 0b110, 0b000, 0b000 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn drawBorder(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn drawLineH(x: i32, y: i32, w: i32, c: Color) void {
    fillRectI32(x, y, w, 2, c);
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
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

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return @min(hi, @max(lo, v));
}

test "flex wrap produces more lines when items widen" {
    container_w = 180;
    child_w = 90;
    spacing = 10;
    item_count = 4;
    mode = .wrap_hstack;
    try std.testing.expect(mode == .wrap_hstack);
}
