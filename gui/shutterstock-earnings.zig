const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const ui_font = @import("assets/dejavu_sans_mono_56_ascii_subset.zig");

const DISPLAY_W: usize = 760;
const DISPLAY_H: usize = 520;
const RETINA_SCALE: i32 = 2;
const RETINA_SCALE_USIZE: usize = 2;
const RENDER_W: usize = DISPLAY_W * RETINA_SCALE_USIZE;
const RENDER_H: usize = DISPLAY_H * RETINA_SCALE_USIZE;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const CHART_X: i32 = 64;
const CHART_Y: i32 = 112;
const CHART_W: i32 = 620;
const CHART_H: i32 = 292;
const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_RIGHT: i32 = 0xFF53;

const Color = [4]u8;
const C_BG: Color = .{ 0xF6, 0xF5, 0xF1, 0xFF };
const C_PANEL: Color = .{ 0xFF, 0xFE, 0xFA, 0xFF };
const C_CHART: Color = .{ 0xFB, 0xFA, 0xF6, 0xFF };
const C_INK: Color = .{ 0x18, 0x1B, 0x20, 0xFF };
const C_MUTED: Color = .{ 0x67, 0x68, 0x6C, 0xFF };
const C_GRID: Color = .{ 0xD7, 0xD0, 0xC4, 0xFF };
const C_ACTIVE: Color = .{ 0xF1, 0xCF, 0x58, 0xFF };
const C_REVENUE: Color = .{ 0x2E, 0x7D, 0x59, 0xFF };
const C_NET: Color = .{ 0xB1, 0x3B, 0x5D, 0xFF };
const C_EPS: Color = .{ 0xA7, 0x71, 0x18, 0xFF };
const C_NEG: Color = .{ 0xC7, 0x4E, 0x43, 0xFF };
const C_STOCK: Color = .{ 0x21, 0x6B, 0xB8, 0xFF };

const Metric = enum {
    revenue,
    net_income,
    eps,
};

const Range = struct {
    min: f64,
    max: f64,
};

const PointF = struct {
    x: f32,
    y: f32,
};

const Quarter = struct {
    short_label: []const u8,
    long_label: []const u8,
    price_date: []const u8,
    revenue_m: f64,
    net_income_m: f64,
    eps: f64,
    close: f64,
    q4_derived: bool,
};

// Financials: SEC companyfacts CIK 0001549346, pulled 2026-07-01.
// Q4 financials are derived from annual totals less Q1-Q3, because SEC frames
// publish annual values but not separate Q4 frames for 10-K filings.
// Prices: Nasdaq historical quote API, quarter-end close or previous trading day.
const QUARTERS = [_]Quarter{
    .{ .short_label = "23Q1", .long_label = "2023 Q1", .price_date = "2023-03-31", .revenue_m = 215.280, .net_income_m = 32.843, .eps = 0.90, .close = 72.60, .q4_derived = false },
    .{ .short_label = "23Q2", .long_label = "2023 Q2", .price_date = "2023-06-30", .revenue_m = 208.840, .net_income_m = 50.013, .eps = 1.37, .close = 48.67, .q4_derived = false },
    .{ .short_label = "23Q3", .long_label = "2023 Q3", .price_date = "2023-09-29", .revenue_m = 233.248, .net_income_m = 28.419, .eps = 0.79, .close = 38.05, .q4_derived = false },
    .{ .short_label = "23Q4", .long_label = "2023 Q4", .price_date = "2023-12-29", .revenue_m = 217.219, .net_income_m = -1.006, .eps = -0.02, .close = 48.28, .q4_derived = true },
    .{ .short_label = "24Q1", .long_label = "2024 Q1", .price_date = "2024-03-28", .revenue_m = 214.315, .net_income_m = 16.121, .eps = 0.45, .close = 45.81, .q4_derived = false },
    .{ .short_label = "24Q2", .long_label = "2024 Q2", .price_date = "2024-06-28", .revenue_m = 220.053, .net_income_m = 3.625, .eps = 0.10, .close = 38.70, .q4_derived = false },
    .{ .short_label = "24Q3", .long_label = "2024 Q3", .price_date = "2024-09-30", .revenue_m = 250.588, .net_income_m = 17.615, .eps = 0.50, .close = 35.37, .q4_derived = false },
    .{ .short_label = "24Q4", .long_label = "2024 Q4", .price_date = "2024-12-31", .revenue_m = 250.306, .net_income_m = -1.429, .eps = -0.04, .close = 30.35, .q4_derived = true },
    .{ .short_label = "25Q1", .long_label = "2025 Q1", .price_date = "2025-03-31", .revenue_m = 242.620, .net_income_m = 18.688, .eps = 0.53, .close = 18.63, .q4_derived = false },
    .{ .short_label = "25Q2", .long_label = "2025 Q2", .price_date = "2025-06-30", .revenue_m = 266.990, .net_income_m = 29.440, .eps = 0.82, .close = 18.96, .q4_derived = false },
    .{ .short_label = "25Q3", .long_label = "2025 Q3", .price_date = "2025-09-30", .revenue_m = 260.094, .net_income_m = 13.387, .eps = 0.37, .close = 20.85, .q4_derived = false },
    .{ .short_label = "25Q4", .long_label = "2025 Q4", .price_date = "2025-12-31", .revenue_m = 220.221, .net_income_m = -16.019, .eps = -0.47, .close = 19.10, .q4_derived = true },
    .{ .short_label = "26Q1", .long_label = "2026 Q1", .price_date = "2026-03-31", .revenue_m = 199.170, .net_income_m = -47.569, .eps = -1.34, .close = 16.61, .q4_derived = false },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var metric: Metric = .net_income;
var selected_idx: usize = QUARTERS.len - 1;
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
        XK_LEFT => selectAdjacent(-1),
        XK_RIGHT => selectAdjacent(1),
        '1', 'r', 'R' => setMetric(.revenue),
        '2', 'n', 'N' => setMetric(.net_income),
        '3', 'e', 'E' => setMetric(.eps),
        else => false,
    };
    return if (changed) 1 else 0;
}

export fn pointer_event(button_mask: i32, x: i32, y: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    const logical_x = @divTrunc(x, RETINA_SCALE);
    const logical_y = @divTrunc(y, RETINA_SCALE);
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    if (down and !primary_down) {
        if (hit(logical_x, logical_y, 20, 58, 82, 26)) changed = setMetric(.revenue);
        if (hit(logical_x, logical_y, 110, 58, 118, 26)) changed = setMetric(.net_income);
        if (hit(logical_x, logical_y, 236, 58, 54, 26)) changed = setMetric(.eps);
    }

    if (quarterAtPoint(logical_x, logical_y)) |idx| {
        if (idx != selected_idx) {
            selected_idx = idx;
            changed = true;
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

fn setMetric(next: Metric) bool {
    if (metric == next) return false;
    metric = next;
    return true;
}

fn selectAdjacent(delta: i32) bool {
    if (delta < 0) {
        if (selected_idx == 0) return false;
        selected_idx -= 1;
        return true;
    }
    if (selected_idx + 1 >= QUARTERS.len) return false;
    selected_idx += 1;
    return true;
}

fn drawFrame() void {
    fillRect(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), C_BG);
    drawText(20, 20, "SHUTTERSTOCK QUARTERLY EARNINGS + SSTK PRICE", C_INK);
    drawText(20, 40, "HOVER OR USE ARROWS.  1 REVENUE  2 NET INCOME  3 EPS", C_MUTED);

    button(20, 58, 82, "REVENUE", metric == .revenue);
    button(110, 58, 118, "NET INCOME", metric == .net_income);
    button(236, 58, 54, "EPS", metric == .eps);

    drawChart();
    drawLegend();
    drawDetail();
}

fn drawChart() void {
    fillRect(CHART_X, CHART_Y, CHART_W, CHART_H, C_CHART);
    drawBorder(CHART_X, CHART_Y, CHART_W, CHART_H, C_INK);

    var grid: i32 = 1;
    while (grid < 4) : (grid += 1) {
        const y = CHART_Y + @divTrunc(CHART_H * grid, 4);
        fillRect(CHART_X + 1, y, CHART_W - 2, 1, C_GRID);
    }

    var i: usize = 0;
    while (i < QUARTERS.len) : (i += 1) {
        const cx = quarterCenter(i);
        if ((i % 4) == 0 and i != 0) fillRect(cx - 1, CHART_Y + 1, 1, CHART_H - 2, C_GRID);
        drawBar(i, cx);
    }

    drawStockLine();
    drawAxesAndLabels();

    const sx = quarterCenter(selected_idx);
    fillRect(sx, CHART_Y + 1, 1, CHART_H - 2, C_ACTIVE);
}

fn drawBar(i: usize, cx: i32) void {
    const q = QUARTERS[i];
    const r = metricRange();
    const value = metricValue(q);
    const zero_y = valueToY(0, r);
    const value_y = valueToY(value, r);
    const bar_w: i32 = 20;
    const color = if (value < 0) C_NEG else metricColor();
    const x = cx - @divTrunc(bar_w, 2);
    const y = @min(value_y, zero_y);
    const h = @max(1, absI32(value_y - zero_y));

    fillRect(x, y, bar_w, h, color);
    if (i == selected_idx) drawBorder(x - 2, y - 2, bar_w + 4, h + 4, C_INK);
}

fn drawStockLine() void {
    var last_x: i32 = 0;
    var last_y: i32 = 0;
    var i: usize = 0;
    while (i < QUARTERS.len) : (i += 1) {
        const x = quarterCenter(i);
        const y = priceToY(QUARTERS[i].close);
        if (i > 0) {
            drawLineAA(last_x, last_y, x, y, C_STOCK, 1.6);
        }
        fillCircleAA(x, y, if (i == selected_idx) 4.4 else 2.6, C_STOCK);
        if (i == selected_idx) drawCircleAA(x, y, 6.8, 1.2, C_INK);
        last_x = x;
        last_y = y;
    }
}

fn drawAxesAndLabels() void {
    const r = metricRange();
    const top = r.max;
    const mid = (r.max + r.min) * 0.5;
    const bottom = r.min;
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;

    drawText(10, valueToY(top, r) - 5, formatAxis(&b1, top), C_MUTED);
    drawText(10, valueToY(mid, r) - 5, formatAxis(&b2, mid), C_MUTED);
    drawText(10, valueToY(bottom, r) - 5, formatAxis(&b3, bottom), C_MUTED);

    drawText(CHART_X + CHART_W + 10, priceToY(75) - 5, "$75", C_STOCK);
    drawText(CHART_X + CHART_W + 10, priceToY(45) - 5, "$45", C_STOCK);
    drawText(CHART_X + CHART_W + 10, priceToY(15) - 5, "$15", C_STOCK);

    var i: usize = 0;
    while (i < QUARTERS.len) : (i += 1) {
        drawText(quarterCenter(i) - 16, CHART_Y + CHART_H + 12, QUARTERS[i].short_label, if (i == selected_idx) C_INK else C_MUTED);
    }
}

fn drawLegend() void {
    fillRect(472, 58, 14, 10, metricColor());
    drawText(492, 58, metricLegend(), C_INK);
    fillRect(472, 76, 14, 4, C_STOCK);
    drawText(492, 72, "SSTK CLOSE", C_STOCK);
}

fn drawDetail() void {
    const q = QUARTERS[selected_idx];
    fillRect(20, 438, 720, 58, C_PANEL);
    drawBorder(20, 438, 720, 58, C_INK);

    var line: [144]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &line,
        "{s}  REV ${d:.1}M  NET {s}${d:.1}M  EPS {s}${d:.2}  SSTK ${d:.2}",
        .{ q.long_label, q.revenue_m, signPrefix(q.net_income_m), absF64(q.net_income_m), signPrefix(q.eps), absF64(q.eps), q.close },
    ) catch "";
    drawText(34, 452, detail, C_INK);

    var note: [128]u8 = undefined;
    const note_text = if (q.q4_derived)
        std.fmt.bufPrint(&note, "PRICE DATE {s}.  Q4 FINANCIALS DERIVED FROM FY LESS Q1-Q3.", .{q.price_date}) catch ""
    else
        std.fmt.bufPrint(&note, "PRICE DATE {s}.  FINANCIALS FROM SEC QUARTERLY FRAME.", .{q.price_date}) catch "";
    drawText(34, 474, note_text, C_MUTED);
}

fn metricValue(q: Quarter) f64 {
    return switch (metric) {
        .revenue => q.revenue_m,
        .net_income => q.net_income_m,
        .eps => q.eps,
    };
}

fn metricRange() Range {
    return switch (metric) {
        .revenue => .{ .min = 0, .max = 300 },
        .net_income => .{ .min = -55, .max = 55 },
        .eps => .{ .min = -1.5, .max = 1.5 },
    };
}

fn metricColor() Color {
    return switch (metric) {
        .revenue => C_REVENUE,
        .net_income => C_NET,
        .eps => C_EPS,
    };
}

fn metricLegend() []const u8 {
    return switch (metric) {
        .revenue => "REVENUE BARS",
        .net_income => "NET INCOME BARS",
        .eps => "DILUTED EPS BARS",
    };
}

fn formatAxis(buf: *[24]u8, value: f64) []const u8 {
    return switch (metric) {
        .revenue => std.fmt.bufPrint(buf, "${d:.0}M", .{value}) catch "",
        .net_income => std.fmt.bufPrint(buf, "{s}${d:.0}M", .{ signPrefix(value), absF64(value) }) catch "",
        .eps => std.fmt.bufPrint(buf, "{s}${d:.2}", .{ signPrefix(value), absF64(value) }) catch "",
    };
}

fn valueToY(value: f64, r: Range) i32 {
    const t = clampF64((value - r.min) / (r.max - r.min), 0, 1);
    return CHART_Y + CHART_H - @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(CHART_H)))));
}

fn priceToY(price: f64) i32 {
    const t = clampF64((price - 15.0) / (75.0 - 15.0), 0, 1);
    return CHART_Y + CHART_H - @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(CHART_H)))));
}

fn quarterCenter(i: usize) i32 {
    const numerator = CHART_W * @as(i32, @intCast(i * 2 + 1));
    const denominator = @as(i32, @intCast(QUARTERS.len * 2));
    return CHART_X + @divTrunc(numerator, denominator);
}

fn quarterAtPoint(x: i32, y: i32) ?usize {
    if (x < CHART_X or x >= CHART_X + CHART_W) return null;
    if (y < CHART_Y - 8 or y >= CHART_Y + CHART_H + 32) return null;

    const rel = x - CHART_X;
    var idx = @as(usize, @intCast(@divTrunc(rel * @as(i32, @intCast(QUARTERS.len)), CHART_W)));
    if (idx >= QUARTERS.len) idx = QUARTERS.len - 1;
    return idx;
}

fn button(x: i32, y: i32, w: i32, label: []const u8, active: bool) void {
    fillRect(x, y, w, 26, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, 26, C_INK);
    drawText(x + @divTrunc(w - textWidth(label), 2), y + 8, label, C_INK);
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn signPrefix(value: f64) []const u8 {
    return if (value < 0) "-" else "";
}

fn absF64(value: f64) f64 {
    return if (value < 0) -value else value;
}

fn absI32(value: i32) i32 {
    return if (value < 0) -value else value;
}

fn clampF64(value: f64, min: f64, max: f64) f64 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    const size_px: i32 = 12 * RETINA_SCALE;
    var cursor_x = x * RETINA_SCALE;
    const text_y = y * RETINA_SCALE;
    var i: usize = 0;
    while (i < text.len and i < 96) : (i += 1) {
        drawFontChar(cursor_x, text_y, text[i], c, size_px);
        cursor_x += fontAdvance(size_px);
    }
}

fn textWidth(text: []const u8) i32 {
    const advance = fontAdvance(12 * RETINA_SCALE);
    return @divTrunc(@as(i32, @intCast(text.len)) * advance + RETINA_SCALE - 1, RETINA_SCALE);
}

fn fontAdvance(size_px: i32) i32 {
    return @max(1, @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(ui_font.GLYPH_W)) * fontScale(size_px)))));
}

fn fontScale(size_px: i32) f32 {
    return @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(ui_font.GLYPH_H));
}

fn drawFontChar(x: i32, y: i32, ch: u8, c: Color, size_px: i32) void {
    const glyph_index = glyphIndexForByte(ch) orelse return;
    const scale = fontScale(size_px);
    const w = fontAdvance(size_px);
    const h = size_px;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            const coverage = fontCoverage(glyph_index, dx, dy, scale);
            if (coverage == 0) continue;
            var cc = c;
            cc[3] = @as(u8, @intCast(@divTrunc(@as(i32, c[3]) * coverage, 4)));
            blendPixelPhysical(x + dx, y + dy, cc);
        }
    }
}

fn glyphIndexForByte(ch: u8) ?usize {
    if (ch >= ui_font.ASCII_START and ch <= ui_font.ASCII_END) {
        return @as(usize, @intCast(ch - ui_font.ASCII_START));
    }
    return null;
}

fn fontCoverage(glyph_index: usize, dx: i32, dy: i32, scale: f32) i32 {
    const offsets = [_]PointF{
        .{ .x = 0.25, .y = 0.25 },
        .{ .x = 0.75, .y = 0.25 },
        .{ .x = 0.25, .y = 0.75 },
        .{ .x = 0.75, .y = 0.75 },
    };

    var covered: i32 = 0;
    for (offsets) |off| {
        const sx = @as(i32, @intFromFloat(@floor((@as(f32, @floatFromInt(dx)) + off.x) / scale)));
        const sy = @as(i32, @intFromFloat(@floor((@as(f32, @floatFromInt(dy)) + off.y) / scale)));
        if (fontBit(glyph_index, sx, sy)) covered += 1;
    }
    return covered;
}

fn fontBit(glyph_index: usize, sx: i32, sy: i32) bool {
    if (sx < 0 or sy < 0 or sx >= @as(i32, @intCast(ui_font.GLYPH_W)) or sy >= @as(i32, @intCast(ui_font.GLYPH_H))) return false;
    const row = ui_font.glyph_rows[glyph_index][@as(usize, @intCast(sy))];
    return ((row >> @as(u6, @intCast(sx))) & 1) != 0;
}

fn drawLineAA(x0: i32, y0: i32, x1: i32, y1: i32, c: Color, width_logical: f64) void {
    const ax = logicalCenterToPhysical(x0);
    const ay = logicalCenterToPhysical(y0);
    const bx = logicalCenterToPhysical(x1);
    const by = logicalCenterToPhysical(y1);
    const vx = bx - ax;
    const vy = by - ay;
    const len2 = vx * vx + vy * vy;
    if (len2 <= 0.0001) {
        fillCircleAA(x0, y0, width_logical * 0.5, c);
        return;
    }

    const radius = width_logical * @as(f64, @floatFromInt(RETINA_SCALE)) * 0.5;
    const pad = radius + 1.5;
    const min_x = @max(0, @as(i32, @intFromFloat(@floor(@min(ax, bx) - pad))));
    const max_x = @min(@as(i32, @intCast(RENDER_W)) - 1, @as(i32, @intFromFloat(@ceil(@max(ax, bx) + pad))));
    const min_y = @max(0, @as(i32, @intFromFloat(@floor(@min(ay, by) - pad))));
    const max_y = @min(@as(i32, @intCast(RENDER_H)) - 1, @as(i32, @intFromFloat(@ceil(@max(ay, by) + pad))));
    if (min_x > max_x or min_y > max_y) return;

    var py = min_y;
    while (py <= max_y) : (py += 1) {
        const fy = @as(f64, @floatFromInt(py)) + 0.5;
        var px = min_x;
        while (px <= max_x) : (px += 1) {
            const fx = @as(f64, @floatFromInt(px)) + 0.5;
            const wx = fx - ax;
            const wy = fy - ay;
            const t = clampF64((wx * vx + wy * vy) / len2, 0, 1);
            const cx = ax + vx * t;
            const cy = ay + vy * t;
            const dx = fx - cx;
            const dy = fy - cy;
            const dist = std.math.sqrt(dx * dx + dy * dy);
            const alpha = coverageAlpha(radius + 0.75 - dist);
            if (alpha != 0) blendPixelPhysical(px, py, withAlpha(c, alpha));
        }
    }
}

fn fillCircleAA(cx: i32, cy: i32, radius_logical: f64, c: Color) void {
    const pcx = logicalCenterToPhysical(cx);
    const pcy = logicalCenterToPhysical(cy);
    const radius = radius_logical * @as(f64, @floatFromInt(RETINA_SCALE));
    const pad = radius + 1.5;
    const min_x = @max(0, @as(i32, @intFromFloat(@floor(pcx - pad))));
    const max_x = @min(@as(i32, @intCast(RENDER_W)) - 1, @as(i32, @intFromFloat(@ceil(pcx + pad))));
    const min_y = @max(0, @as(i32, @intFromFloat(@floor(pcy - pad))));
    const max_y = @min(@as(i32, @intCast(RENDER_H)) - 1, @as(i32, @intFromFloat(@ceil(pcy + pad))));
    if (min_x > max_x or min_y > max_y) return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const fy = @as(f64, @floatFromInt(y)) + 0.5;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const fx = @as(f64, @floatFromInt(x)) + 0.5;
            const dx = fx - pcx;
            const dy = fy - pcy;
            const dist = std.math.sqrt(dx * dx + dy * dy);
            const alpha = coverageAlpha(radius + 0.75 - dist);
            if (alpha != 0) blendPixelPhysical(x, y, withAlpha(c, alpha));
        }
    }
}

fn drawCircleAA(cx: i32, cy: i32, radius_logical: f64, stroke_logical: f64, c: Color) void {
    const pcx = logicalCenterToPhysical(cx);
    const pcy = logicalCenterToPhysical(cy);
    const radius = radius_logical * @as(f64, @floatFromInt(RETINA_SCALE));
    const stroke_half = stroke_logical * @as(f64, @floatFromInt(RETINA_SCALE)) * 0.5;
    const pad = radius + stroke_half + 1.5;
    const min_x = @max(0, @as(i32, @intFromFloat(@floor(pcx - pad))));
    const max_x = @min(@as(i32, @intCast(RENDER_W)) - 1, @as(i32, @intFromFloat(@ceil(pcx + pad))));
    const min_y = @max(0, @as(i32, @intFromFloat(@floor(pcy - pad))));
    const max_y = @min(@as(i32, @intCast(RENDER_H)) - 1, @as(i32, @intFromFloat(@ceil(pcy + pad))));
    if (min_x > max_x or min_y > max_y) return;

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const fy = @as(f64, @floatFromInt(y)) + 0.5;
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const fx = @as(f64, @floatFromInt(x)) + 0.5;
            const dx = fx - pcx;
            const dy = fy - pcy;
            const dist = std.math.sqrt(dx * dx + dy * dy);
            const alpha = coverageAlpha(stroke_half + 0.75 - absF64(dist - radius));
            if (alpha != 0) blendPixelPhysical(x, y, withAlpha(c, alpha));
        }
    }
}

fn logicalCenterToPhysical(value: i32) f64 {
    return (@as(f64, @floatFromInt(value)) + 0.5) * @as(f64, @floatFromInt(RETINA_SCALE));
}

fn coverageAlpha(coverage: f64) u8 {
    const clamped = clampF64(coverage, 0, 1);
    return @as(u8, @intFromFloat(@round(clamped * 255.0)));
}

fn withAlpha(c: Color, alpha: u8) Color {
    return .{
        c[0],
        c[1],
        c[2],
        @as(u8, @intCast(@divTrunc(@as(i32, c[3]) * @as(i32, alpha) + 127, 255))),
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
    const sx = @max(0, x0 * RETINA_SCALE);
    const sy = @max(0, y0 * RETINA_SCALE);
    const ex = @min(@as(i32, @intCast(RENDER_W)), (x0 + w) * RETINA_SCALE);
    const ey = @min(@as(i32, @intCast(RENDER_H)), (y0 + h) * RETINA_SCALE);
    if (sx >= ex or sy >= ey) return;

    var y = sy;
    while (y < ey) : (y += 1) {
        var x = sx;
        while (x < ex) : (x += 1) {
            setPixelPhysical(x, y, c);
        }
    }
}

fn setPixel(x: i32, y: i32, c: Color) void {
    fillRect(x, y, 1, 1, c);
}

fn setPixelPhysical(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    pixel_buf[idx + 0] = c[0];
    pixel_buf[idx + 1] = c[1];
    pixel_buf[idx + 2] = c[2];
    pixel_buf[idx + 3] = c[3];
}

fn blendPixelPhysical(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    if (c[3] == 0xFF) {
        setPixelPhysical(x, y, c);
        return;
    }

    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const a = @as(i32, c[3]);
    const inv = 255 - a;
    pixel_buf[idx + 0] = @as(u8, @intCast(@divTrunc(@as(i32, c[0]) * a + @as(i32, pixel_buf[idx + 0]) * inv + 127, 255)));
    pixel_buf[idx + 1] = @as(u8, @intCast(@divTrunc(@as(i32, c[1]) * a + @as(i32, pixel_buf[idx + 1]) * inv + 127, 255)));
    pixel_buf[idx + 2] = @as(u8, @intCast(@divTrunc(@as(i32, c[2]) * a + @as(i32, pixel_buf[idx + 2]) * inv + 127, 255)));
    pixel_buf[idx + 3] = 0xFF;
}

test "Q4 revenue is annual less first three quarters" {
    try std.testing.expectApproxEqAbs(@as(f64, 217.219), QUARTERS[3].revenue_m, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 250.306), QUARTERS[7].revenue_m, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 220.221), QUARTERS[11].revenue_m, 0.001);
}

test "stock closes cover the same quarter count" {
    try std.testing.expectEqual(@as(usize, 13), QUARTERS.len);
    try std.testing.expect(QUARTERS[0].close > QUARTERS[QUARTERS.len - 1].close);
}
