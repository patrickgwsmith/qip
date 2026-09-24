const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 420;
const RENDER_H: usize = 300;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const INPUT_CAP: usize = 64;

const XK_LEFT: i32 = 0xFF51;
const XK_RIGHT: i32 = 0xFF53;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const Color = [4]u8;
const COLOR_BG: Color = .{ 0x06, 0x0C, 0x16, 0xFF };
const COLOR_STAR: Color = .{ 0xD6, 0xE7, 0xFF, 0xFF };
const COLOR_MOON_LIGHT: Color = .{ 0xF1, 0xF3, 0xEE, 0xFF };
const COLOR_MOON_DARK: Color = .{ 0x3A, 0x40, 0x4A, 0xFF };
const COLOR_MOON_RIM: Color = .{ 0xC2, 0xC9, 0xD0, 0xFF };
const COLOR_BANNER: Color = .{ 0x0E, 0x1A, 0x2E, 0xFF };
const COLOR_TEXT: Color = .{ 0xE7, 0xEE, 0xFF, 0xFF };
const COLOR_PHASE_BAR: Color = .{ 0x2A, 0x3E, 0x5F, 0xFF };
const COLOR_PHASE_MARK: Color = .{ 0xF2, 0xC8, 0x54, 0xFF };

const SurfacePatch = struct {
    x: f64,
    y: f64,
    r: f64,
    delta: f64,
};

const ALBEDO_FEATURES = [_]SurfacePatch{
    // Major maria-style albedo regions.
    .{ .x = -0.54, .y = 0.02, .r = 0.52, .delta = -0.18 }, // Oceanus Procellarum
    .{ .x = -0.34, .y = -0.16, .r = 0.28, .delta = -0.12 }, // Mare Imbrium-ish
    .{ .x = -0.02, .y = 0.22, .r = 0.34, .delta = -0.10 }, // Mare Nubium-ish
    .{ .x = 0.28, .y = -0.22, .r = 0.26, .delta = -0.08 }, // Mare Serenitatis-ish
    .{ .x = 0.34, .y = 0.12, .r = 0.24, .delta = -0.07 }, // Mare Fecunditatis-ish
};

const Crater = struct {
    x: f64,
    y: f64,
    r: f64,
    bowl: f64,
    rim: f64,
};

const NAMED_CRATERS = [_]Crater{
    // Tycho: 43.31S, 11.36W
    .{ .x = -0.143, .y = -0.686, .r = 0.090, .bowl = 0.08, .rim = 0.09 },
    // Copernicus: 9.62N, 20.08W
    .{ .x = -0.338, .y = 0.167, .r = 0.072, .bowl = 0.07, .rim = 0.07 },
    // Clavius: 58.4S, 14.4W
    .{ .x = -0.132, .y = -0.851, .r = 0.105, .bowl = 0.07, .rim = 0.06 },
    // Aristarchus: 23.7N, 47.4W
    .{ .x = -0.676, .y = 0.402, .r = 0.050, .bowl = 0.08, .rim = 0.11 },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var input_buf: [INPUT_CAP]u8 = [_]u8{0} ** INPUT_CAP;

var needs_redraw: bool = true;

var base_days: i64 = daysFromCivil(2026, 5, 31);
var day_offset: i32 = 0;
var input_sig: u32 = 0;

const Phase = enum { initializing, ready, updating };

var transaction_phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf[0])));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn begin_update_at(now_ms: i64) void {
    if (transaction_phase != .ready) @trap();
    if (now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;

    switch (x11_key) {
        XK_LEFT => day_offset -= 1,
        XK_RIGHT => day_offset += 1,
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
    if (input_size > INPUT_CAP) @trap();
    if (transaction_phase == .initializing) {
        refreshInputDate(input_buf[0..input_size]);
    } else {
        if (transaction_phase != .ready or input_size != 0) @trap();
    }
    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawScene();
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

fn refreshInputDate(input: []const u8) void {
    const sig = hashInput(input);
    if (sig == input_sig) return;
    input_sig = sig;
    if (parseDateDays(input)) |days| {
        base_days = days;
        day_offset = 0;
        needs_redraw = true;
    }
}

fn hashInput(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |b| {
        h = (h ^ b) *% 16777619;
    }
    return h;
}

fn drawScene() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawStars();

    const day = base_days + @as(i64, day_offset);
    const phase = phaseForDay(day);
    drawMoon(phase);
    drawBanner(day, phase);
}

fn drawStars() void {
    var i: usize = 0;
    while (i < 56) : (i += 1) {
        const x = (i * 73 + 29) % RENDER_W;
        const y = (i * 41 + 17) % (RENDER_H - 70);
        const size: usize = if ((i % 7) == 0) 2 else 1;
        fillRect(x, y, size, size, COLOR_STAR);
    }
}

fn drawMoon(phase: f64) void {
    const cx: i32 = @intCast(@divFloor(RENDER_W, 2));
    const cy: i32 = @intCast(@divFloor(RENDER_H, 2) + 10);
    const r: i32 = 92;

    const angle = phase * std.math.tau;
    const sun_x = std.math.sin(angle);
    const sun_y = -0.20;
    const sun_z = -std.math.cos(angle);

    var y: i32 = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x: i32 = cx - r;
        while (x <= cx + r) : (x += 1) {
            const nx = @as(f64, @floatFromInt(x - cx)) / @as(f64, @floatFromInt(r));
            const ny = @as(f64, @floatFromInt(y - cy)) / @as(f64, @floatFromInt(r));
            const d2 = nx * nx + ny * ny;
            if (d2 > 1.0) continue;

            const nz = std.math.sqrt(1.0 - d2);
            setPixelI32(x, y, moonSurfaceColor(nx, ny, nz, sun_x, sun_y, sun_z));
        }
    }

    // Rim.
    var t: i32 = 0;
    while (t < 360) : (t += 1) {
        const a = @as(f64, @floatFromInt(t)) * std.math.tau / 360.0;
        const rx = cx + @as(i32, @intFromFloat(@as(f64, @floatFromInt(r)) * std.math.cos(a)));
        const ry = cy + @as(i32, @intFromFloat(@as(f64, @floatFromInt(r)) * std.math.sin(a)));
        setPixelI32(rx, ry, COLOR_MOON_RIM);
    }
}

fn moonSurfaceColor(nx: f64, ny: f64, nz: f64, sun_x: f64, sun_y: f64, sun_z: f64) Color {
    const sun_dot = nx * sun_x + ny * sun_y + nz * sun_z;

    // Soft phase transition + faint earthshine on the dark side.
    const direct = clamp01(sun_dot * 2.5 + 0.18);
    const earthshine = clamp01(-sun_dot * 0.55) * 0.18;
    const light_mix = clamp01(direct + earthshine);

    // Base albedo with broad maria.
    var albedo: f64 = 0.95;
    for (ALBEDO_FEATURES) |feature| {
        const dx = nx - feature.x;
        const dy = ny - feature.y;
        const d = std.math.sqrt(dx * dx + dy * dy) / feature.r;
        if (d < 1.65) {
            const w = 1.0 - d / 1.65;
            albedo += feature.delta * w * w;
        }
    }

    // Named crater relief: subtle bowls and rims (no harsh rays).
    var crater_relief: f64 = 0.0;
    for (NAMED_CRATERS) |cr| {
        const dx = nx - cr.x;
        const dy = ny - cr.y;
        const dist = std.math.sqrt(dx * dx + dy * dy);
        const d = dist / cr.r;
        if (d >= 1.6) continue;

        if (d < 1.0) {
            crater_relief -= 0.05 * (1.0 - d * d);
        }
        const rim = 1.0 - @abs(d - 1.0) / 0.42;
        if (rim > 0.0 and dist > 0.0001) {
            const ux = dx / dist;
            const uy = dy / dist;
            crater_relief += 0.06 * rim * (0.75 + 0.25 * (ux * sun_x + uy * sun_y));
        }
    }
    albedo = clamp01(albedo + crater_relief);

    // Limb darkening for spherical look.
    const limb = 0.74 + 0.26 * nz;
    const tonal = clamp01(albedo * limb);

    return blendColor(COLOR_MOON_DARK, COLOR_MOON_LIGHT, light_mix, tonal);
}

fn blendColor(dark: Color, light: Color, mixv: f64, tone: f64) Color {
    const m = clamp01(mixv);
    return .{
        blendU8(dark[0], light[0], m, tone),
        blendU8(dark[1], light[1], m, tone),
        blendU8(dark[2], light[2], m, tone),
        255,
    };
}

fn blendU8(a: u8, b: u8, m: f64, tone: f64) u8 {
    const af = @as(f64, @floatFromInt(a));
    const bf = @as(f64, @floatFromInt(b));
    const v = (af * (1.0 - m) + bf * m) * clamp01(tone);
    if (v <= 0.0) return 0;
    if (v >= 255.0) return 255;
    return @as(u8, @intFromFloat(v));
}

fn scaleColor(c: Color, tone: f64) Color {
    return .{
        scaleU8(c[0], tone),
        scaleU8(c[1], tone),
        scaleU8(c[2], tone),
        c[3],
    };
}

fn scaleU8(v: u8, tone: f64) u8 {
    const f = @as(f64, @floatFromInt(v)) * clamp01(tone);
    if (f <= 0.0) return 0;
    if (f >= 255.0) return 255;
    return @as(u8, @intFromFloat(f));
}

fn clamp01(v: f64) f64 {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

fn drawBanner(day: i64, phase: f64) void {
    fillRect(0, RENDER_H - 58, RENDER_W, 58, COLOR_BANNER);

    const ymd = civilFromDays(day);
    var date_buf: [10]u8 = undefined;
    encodeDate(ymd.year, ymd.month, ymd.day, &date_buf);
    drawText3x5(14, RENDER_H - 47, date_buf[0..], COLOR_TEXT, 3);

    const label = phaseLabel(phase);
    drawText3x5(150, RENDER_H - 43, label, COLOR_TEXT, 2);

    const bar_x: usize = 14;
    const bar_y: usize = RENDER_H - 18;
    const bar_w: usize = RENDER_W - 28;
    fillRect(bar_x, bar_y, bar_w, 8, COLOR_PHASE_BAR);

    const mark_x = bar_x + @as(usize, @intFromFloat(phase * @as(f64, @floatFromInt(bar_w - 1))));
    fillRect(mark_x, bar_y - 3, 3, 14, COLOR_PHASE_MARK);
}

fn phaseLabel(phase: f64) []const u8 {
    const idx_i32: i32 = @intFromFloat(phase * 8.0 + 0.5);
    const idx: usize = @intCast(@mod(idx_i32, 8));
    return switch (idx) {
        0 => "NEW",
        1 => "WAXING CRESCENT",
        2 => "FIRST QUARTER",
        3 => "WAXING GIBBOUS",
        4 => "FULL",
        5 => "WANING GIBBOUS",
        6 => "LAST QUARTER",
        else => "WANING CRESCENT",
    };
}

fn phaseForDay(day: i64) f64 {
    // New moon reference: 2000-01-06 18:14 UTC.
    const ref_day = @as(f64, @floatFromInt(daysFromCivil(2000, 1, 6))) + 0.7597;
    const synodic = 29.530588853;
    const d = @as(f64, @floatFromInt(day)) + 0.5;
    const age = positiveMod(d - ref_day, synodic);
    return age / synodic;
}

fn positiveMod(x: f64, m: f64) f64 {
    const q = std.math.floor(x / m);
    return x - q * m;
}

fn parseDateDays(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    const head = s[0..10];
    if (head[4] != '-' or head[7] != '-') return null;

    const year = parseN(head[0..4]) orelse return null;
    const month = parseN(head[5..7]) orelse return null;
    const day = parseN(head[8..10]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    return daysFromCivil(year, @intCast(month), @intCast(day));
}

fn parseN(s: []const u8) ?i32 {
    var v: i32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + @as(i32, c - '0');
    }
    return v;
}

fn isLeapYear(y: i32) bool {
    if (@mod(y, 400) == 0) return true;
    if (@mod(y, 100) == 0) return false;
    return @mod(y, 4) == 0;
}

fn daysInMonth(year: i32, month: i32) i32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeapYear(year)) 29 else 28,
    };
}

fn daysFromCivil(y0: i32, m0: u32, d0: u32) i64 {
    var y: i64 = y0;
    var m: i64 = m0;
    const d: i64 = d0;

    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    m = m + if (m > 2) @as(i64, -3) else @as(i64, 9); // Mar=0..Feb=11
    const doy = @divFloor(153 * m + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

const YMD = struct { year: i32, month: u32, day: u32 };

fn civilFromDays(z0: i64) YMD {
    const z = z0 + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0,146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0,399]
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0,365]
    const mp = @divFloor(5 * doy + 2, 153); // [0,11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1,31]
    const m = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9); // [1,12]
    y += if (m <= 2) 1 else 0;

    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

fn encodeDate(year: i32, month: u32, day: u32, out: *[10]u8) void {
    out[0] = @intCast('0' + @mod(@divFloor(year, 1000), 10));
    out[1] = @intCast('0' + @mod(@divFloor(year, 100), 10));
    out[2] = @intCast('0' + @mod(@divFloor(year, 10), 10));
    out[3] = @intCast('0' + @mod(year, 10));
    out[4] = '-';
    out[5] = @intCast('0' + @mod(@divFloor(month, 10), 10));
    out[6] = @intCast('0' + @mod(month, 10));
    out[7] = '-';
    out[8] = @intCast('0' + @mod(@divFloor(day, 10), 10));
    out[9] = @intCast('0' + @mod(day, 10));
}

fn drawText3x5(x0: usize, y0: usize, s: []const u8, color: Color, scale: usize) void {
    var x = x0;
    for (s) |ch| {
        drawGlyph3x5(x, y0, ch, color, scale);
        x += 4 * scale;
    }
}

fn drawGlyph3x5(x0: usize, y0: usize, ch: u8, color: Color, scale: usize) void {
    const rows = glyphRows(ch);
    var y: usize = 0;
    while (y < 5) : (y += 1) {
        const bits = rows[y];
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            const mask: u8 = @as(u8, 1) << @intCast(2 - x);
            if ((bits & mask) != 0) {
                fillRect(x0 + x * scale, y0 + y * scale, scale, scale, color);
            }
        }
    }
}

fn glyphRows(ch: u8) [5]u8 {
    return switch (ch) {
        '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        ' ' => .{ 0b000, 0b000, 0b000, 0b000, 0b000 },
        'A' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C' => .{ 0b011, 0b100, 0b100, 0b100, 0b011 },
        'D' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G' => .{ 0b011, 0b100, 0b101, 0b101, 0b011 },
        'H' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'L' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'O' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'Q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S' => .{ 0b011, 0b100, 0b111, 0b001, 0b110 },
        'T' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'W' => .{ 0b101, 0b101, 0b101, 0b111, 0b101 },
        'X' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'N' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn setPixelI32(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= RENDER_W or uy >= RENDER_H) return;
    setPixel(ux, uy, color);
}

fn setPixel(x: usize, y: usize, color: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    pixel_buf[idx + 0] = color[0];
    pixel_buf[idx + 1] = color[1];
    pixel_buf[idx + 2] = color[2];
    pixel_buf[idx + 3] = color[3];
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            setPixel(x, y, color);
        }
    }
}
