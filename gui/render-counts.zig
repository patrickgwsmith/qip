const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const WAKE_INTERVAL_MS: i64 = 16;

const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const Color = [4]u8;
const C_BG: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_TEXT: Color = .{ 0x0B, 0x13, 0x0B, 0xFF };
const C_YELLOW: Color = .{ 0xDD, 0xBB, 0x02, 0xFF };
const C_BLUE: Color = .{ 0x10, 0x88, 0xFF, 0xFF };
const C_PURPLE: Color = .{ 0xAA, 0x22, 0xFF, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;

const State = struct {
    total_begin_count: u64 = 0,
    total_finish_count: u64 = 0,
    total_render_count: u64 = 0,
    total_key_count: u64 = 0,
    total_pointer_count: u64 = 0,
    transaction_ms: i64 = 0,
    last_key_ms: i64 = 0,
    last_key_char: u8 = 0,
    last_pointer_ms: i64 = 0,
};

const Phase = enum { initializing, ready, updating };

var state: State = .{};
var phase: Phase = .initializing;
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
    if (phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    state.total_begin_count +%= 1;
    state.transaction_ms = now_ms;
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (x11_key) {
        '0'...'9', 'a'...'z' => state.last_key_char = @as(u8, @intCast(x11_key)),
        'A'...'Z' => state.last_key_char = @as(u8, @intCast(x11_key + ('a' - 'A'))),
        else => return 0,
    }
    state.total_key_count +%= 1;
    state.last_key_ms = begun_at_ms;
    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    state.total_pointer_count +%= 1;
    state.last_pointer_ms = begun_at_ms;
    return 1;
}

fn eventPhaseIsValid() bool {
    if (phase != .updating) @trap();
    return true;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0) @trap();
    if (phase != .initializing and phase != .ready) @trap();
    state.total_render_count +%= 1;
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawFrame();
    @memcpy(output_buf[ktx.HEADER_SIZE..], pixel_buf[0..]);
    phase = .ready;
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
    if (phase != .updating) @trap();
    state.total_finish_count +%= 1;
    committed_at_ms = begun_at_ms;
    const wake = if (begun_at_ms <= std.math.maxInt(i64) - WAKE_INTERVAL_MS)
        begun_at_ms + WAKE_INTERVAL_MS
    else
        begun_at_ms;
    phase = .ready;
    return wake;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);

    var print_buf: [48]u8 = undefined;

    drawText(20, 20, printUnsigned(&print_buf, state.total_begin_count, "updates begun"), C_PURPLE);
    drawText(150, 20, printSigned(&print_buf, state.transaction_ms, "ms update"), C_PURPLE);
    drawText(20, 45, printUnsigned(&print_buf, state.total_finish_count, "updates finished"), C_BLUE);
    drawText(20, 70, printUnsigned(&print_buf, state.total_render_count, "renders including frame"), C_BLUE);
    drawText(20, 105, printUnsigned(&print_buf, state.total_key_count, "keys"), C_YELLOW);
    drawText(150, 105, printSigned(&print_buf, state.last_key_ms, "ms key"), C_YELLOW);
    drawText(285, 105, &[1]u8{state.last_key_char}, C_YELLOW);
    drawText(20, 130, printUnsigned(&print_buf, state.total_pointer_count, "pointers"), C_YELLOW);
    drawText(150, 130, printSigned(&print_buf, state.last_pointer_ms, "ms pointer"), C_YELLOW);
    drawText(20, 175, "render follows finished update", C_TEXT);
}

fn printSigned(buf: *[48]u8, number: i64, item: []const u8) []const u8 {
    if (number >= 0) return printUnsigned(buf, @intCast(number), item);
    buf[0] = '-';
    var tail: [47]u8 = undefined;
    const magnitude = @as(u64, @intCast(-(number + 1))) + 1;
    const rendered = printUnsignedInto(tail[0..], magnitude, item);
    @memcpy(buf[1 .. 1 + rendered.len], rendered);
    return buf[0 .. 1 + rendered.len];
}

fn printUnsigned(buf: *[48]u8, number: u64, item: []const u8) []const u8 {
    return printUnsignedInto(buf[0..], number, item);
}

fn printUnsignedInto(buf: []u8, number: u64, item: []const u8) []const u8 {
    var value = number;
    var digits_rev: [20]u8 = undefined;
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
    buf[out] = ' ';
    out += 1;

    const copy_len = @min(item.len, buf.len - out);
    std.mem.copyForwards(u8, buf[out .. out + copy_len], item[0..copy_len]);
    return buf[0 .. out + copy_len];
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len and i < 42) : (i += 1) drawChar(x + @as(i32, @intCast(i * 7)), y, text[i], c);
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
        'b' => [_]u8{ 0b100, 0b100, 0b110, 0b101, 0b110 },
        'd' => [_]u8{ 0b001, 0b001, 0b011, 0b101, 0b011 },
        'e' => [_]u8{ 0b000, 0b111, 0b111, 0b100, 0b111 },
        'f' => [_]u8{ 0b011, 0b010, 0b111, 0b010, 0b010 },
        'g' => [_]u8{ 0b000, 0b011, 0b101, 0b011, 0b001 },
        'h' => [_]u8{ 0b100, 0b100, 0b110, 0b101, 0b101 },
        'j' => [_]u8{ 0b001, 0b000, 0b001, 0b101, 0b111 },
        'k' => [_]u8{ 0b100, 0b101, 0b110, 0b101, 0b101 },
        'l' => [_]u8{ 0b110, 0b010, 0b010, 0b010, 0b111 },
        'm' => [_]u8{ 0b000, 0b110, 0b111, 0b101, 0b101 },
        'p' => [_]u8{ 0b000, 0b110, 0b101, 0b110, 0b100 },
        'u' => [_]u8{ 0b000, 0b101, 0b101, 0b101, 0b111 },
        'v' => [_]u8{ 0b000, 0b101, 0b101, 0b101, 0b010 },
        'w' => [_]u8{ 0b000, 0b101, 0b101, 0b111, 0b111 },
        'z' => [_]u8{ 0b000, 0b111, 0b001, 0b010, 0b111 },
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
