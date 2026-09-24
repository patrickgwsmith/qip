const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const ui_font = @import("assets/inter_display_chart_ascii.zig");

const DISPLAY_W: usize = 820;
const DISPLAY_H: usize = 540;
const PAGE_MARGIN: i32 = 24;
const RETINA_SCALE: i32 = 2;
const RETINA_SCALE_USIZE: usize = 2;
const RENDER_W: usize = DISPLAY_W * RETINA_SCALE_USIZE;
const RENDER_H: usize = DISPLAY_H * RETINA_SCALE_USIZE;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const CHART_X: i32 = 74;
const CHART_Y: i32 = 116;
const CHART_W: i32 = 680;
const CHART_H: i32 = 304;
const DETAIL_X: i32 = PAGE_MARGIN;
const DETAIL_Y: i32 = 450;
const DETAIL_W: i32 = @as(i32, @intCast(DISPLAY_W)) - PAGE_MARGIN * 2;
const DETAIL_H: i32 = 66;
const BUTTON_Y: i32 = 64;
const BUTTON_H: i32 = 30;
const BUTTON_PAD_X: i32 = 16;
const BUTTON_GAP: i32 = 10;
// One border pixel plus the six-pixel series stripe.
const LEGEND_ACCENT_SPACE: i32 = 7;
const OPENAI_BUTTON_W: i32 = textWidth("OpenAI") + LEGEND_ACCENT_SPACE + BUTTON_PAD_X * 2;
const ANTHROPIC_BUTTON_W: i32 = textWidth("Anthropic") + LEGEND_ACCENT_SPACE + BUTTON_PAD_X * 2;
const LINEAR_BUTTON_W: i32 = textWidth("Linear") + BUTTON_PAD_X * 2;
const LOG_BUTTON_W: i32 = textWidth("Log") + BUTTON_PAD_X * 2;
const OPENAI_BUTTON_X: i32 = PAGE_MARGIN;
const ANTHROPIC_BUTTON_X: i32 = OPENAI_BUTTON_X + OPENAI_BUTTON_W + BUTTON_GAP;
const LOG_BUTTON_X: i32 = DETAIL_X + DETAIL_W - LOG_BUTTON_W;
const LINEAR_BUTTON_X: i32 = LOG_BUTTON_X - BUTTON_GAP - LINEAR_BUTTON_W;
const FONT_SIZE_LOGICAL: i32 = 14;
// The Inter glyph bitmap has top padding; this centers its visible ink in a button.
const BUTTON_LABEL_Y_OFFSET: i32 = 5;
const SCALE_TWEEN_DURATION_MS: i64 = 300;
const SCALE_TWEEN_FRAME_MS: i64 = 16;
const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;
const XK_LEFT: i32 = 0xFF51;
const XK_RIGHT: i32 = 0xFF53;

const Color = [4]u8;
const C_BG: Color = .{ 0x08, 0x0A, 0x12, 0xFF };
const C_PANEL: Color = .{ 0x10, 0x14, 0x22, 0xFF };
const C_CHART: Color = .{ 0x0B, 0x0E, 0x18, 0xFF };
const C_INK: Color = .{ 0xF4, 0xF7, 0xFB, 0xFF };
const C_MUTED: Color = .{ 0xA4, 0xAE, 0xC0, 0xFF };
const C_GRID: Color = .{ 0x32, 0x3A, 0x4C, 0xFF };
const C_ACTIVE: Color = .{ 0x2B, 0x42, 0x78, 0xFF };
const C_ACTIVE_EDGE: Color = .{ 0x8F, 0xB4, 0xFF, 0xFF };
const C_OPENAI: Color = .{ 0x31, 0xD7, 0xB7, 0xFF };
const C_ANTHROPIC: Color = .{ 0xFF, 0x8B, 0x52, 0xFF };

const MIN_MONTH: i32 = 0; // 2023-12
const MAX_MONTH: i32 = 33; // 2026-09, leaving space after the latest point
const ARR_LINEAR_MAX_B: f64 = 70.0;
const ARR_LOG_MIN_B: f64 = 0.01;
const ARR_LOG_MAX_B: f64 = 100.0;

const Series = enum {
    openai,
    anthropic,
};

const ScaleMode = enum {
    linear,
    log,
};

const PointF = struct {
    x: f32,
    y: f32,
};

const ARRPoint = struct {
    month: i32,
    label: []const u8,
    arr_b: f64,
    note: []const u8,
};

// Reported annualized revenue / ARR milestones. These are private-company
// run-rate figures from public reporting, not audited revenue statements.
const OPENAI_POINTS = [_]ARRPoint{
    .{ .month = 0, .label = "2023", .arr_b = 2.0, .note = "OpenAI's CFO reported $2B ARR in 2023." },
    // https://www.bloomberg.com/news/articles/2024-06-12/openai-doubles-annualized-revenue-to-3-4-billion-information
    .{ .month = 6, .label = "Jun 2024", .arr_b = 3.4, .note = "Bloomberg: Altman reported a $3.4B annual pace." },
    // https://www.investing.com/news/stock-market-news/openais-annualized-revenue-hits-10-billion-up-from-55-billion-in-december-2024-4087508
    .{ .month = 12, .label = "2024", .arr_b = 5.5, .note = "OpenAI told Reuters its year-end run rate was $5.5B." },
    .{ .month = 18, .label = "Jun 2025", .arr_b = 10.0, .note = "FT: OpenAI's run rate nearly doubled to $10B." },
    .{ .month = 19, .label = "Jul 2025", .arr_b = 12.0, .note = "Reuters and The Information reported a $12B run rate." },
    // https://www.axios.com/newsletters/axios-ai-plus-efcf11cf-d66b-453c-9d1f-d50774376983
    .{ .month = 20, .label = "Aug 2025", .arr_b = 13.0, .note = "Axios: OpenAI's run rate reached $13B." },
    // https://www.theinformation.com/articles/openai-discussed-raising-tens-billions-valuation-around-750-billion
    .{ .month = 23, .label = "Nov 2025", .arr_b = 19.0, .note = "The Information: Run rate topped $19B in November." },
    // https://www.investing.com/news/stock-market-news/openai-tops-25-billion-in-annualized-revenue-last-month-the-information-reports-4542796
    .{ .month = 24, .label = "2025", .arr_b = 21.4, .note = "The Information and Reuters: $21.4B at year-end." },
    .{ .month = 26, .label = "Feb 2026", .arr_b = 25.0, .note = "The Information and Reuters: Run rate topped $25B." },
    .{ .month = 32, .label = "Aug 2026", .arr_b = 40.0, .note = "Bloomberg, Aug 13: Annualized revenue topped $40B." },
};

const ANTHROPIC_POINTS = [_]ARRPoint{
    // https://www.anthropic.com/news/anthropic-expands-global-leadership-in-enterprise-ai-naming-chris-ciauri-as-managing-director-of
    .{ .month = 1, .label = "Jan 2024", .arr_b = 0.087, .note = "Anthropic: Run rate was $87M at the start of 2024." },
    .{ .month = 13, .label = "Jan 2025", .arr_b = 1.0, .note = "Anthropic: Run rate was about $1B at the start of 2025." },
    .{ .month = 14, .label = "Feb 2025", .arr_b = 1.2, .note = "WSJ: Annualized revenue was about $1.2B." },
    // https://www.investing.com/news/stock-market-news/exclusiveanthropic-hits-3-billion-in-annualized-revenue-on-business-demand-for-ai-4073600
    .{ .month = 15, .label = "Mar 2025", .arr_b = 2.0, .note = "Reuters: Run rate crossed $2B by the end of March." },
    .{ .month = 17, .label = "May 2025", .arr_b = 3.0, .note = "FT: Anthropic's run rate reached $3B by May." },
    // https://www.theinformation.com/articles/investors-float-deal-valuing-anthropic-100-billion
    .{ .month = 18, .label = "Jun 2025", .arr_b = 4.0, .note = "The Information: Annualized revenue topped $4B." },
    // https://www.anthropic.com/news/anthropic-raises-series-f-at-usd183b-post-money-valuation
    .{ .month = 20, .label = "Aug 2025", .arr_b = 5.0, .note = "Anthropic: Run-rate revenue topped $5B." },
    // https://reutersbest.com/anthropic-aims-to-nearly-triple-annualized-revenue-in-2026/
    .{ .month = 22, .label = "Oct 2025", .arr_b = 7.0, .note = "Anthropic told Reuters its run rate approached $7B." },
    .{ .month = 24, .label = "2025", .arr_b = 9.0, .note = "Anthropic: Run rate was about $9B at year-end." },
    .{ .month = 26, .label = "Feb 2026", .arr_b = 14.0, .note = "The Guardian: Annualized revenue reached $14B." },
    .{ .month = 27, .label = "Mar 2026", .arr_b = 19.0, .note = "Axios: Run rate reached $19B in early March." },
    .{ .month = 28, .label = "Apr 2026", .arr_b = 30.0, .note = "Anthropic: Run-rate revenue surpassed $30B." },
    .{ .month = 29, .label = "May 2026", .arr_b = 47.0, .note = "FT and MarketWatch: Run rate crossed $47B." },
    .{ .month = 31, .label = "Jul 2026", .arr_b = 65.0, .note = "Bloomberg, Aug 18: Run rate hit $65B at July's end." },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var pixel_buf: [PIXEL_BYTES]u8 = undefined;
var selected_series: Series = .anthropic;
var selected_idx: usize = ANTHROPIC_POINTS.len - 1;
var scale_mode: ScaleMode = .log;
var scale_mix: f64 = 1.0;
var scale_tween_from: f64 = 1.0;
var scale_tween_to: f64 = 1.0;
var scale_tween_started_at_ms: i64 = 0;
var scale_tween_duration_ms: i64 = 0;
var scale_tween_active = false;
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
    advanceScaleTween(now_ms);
    transaction_phase = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    if (!eventPhaseIsValid()) return 0;
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    const changed = switch (x11_key) {
        XK_LEFT => selectAdjacent(-1),
        XK_RIGHT => selectAdjacent(1),
        'o', 'O', '1' => selectLatest(.openai),
        'a', 'A', '2' => selectLatest(.anthropic),
        'l', 'L' => toggleScaleMode(),
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
        if (hit(logical_x, logical_y, OPENAI_BUTTON_X, BUTTON_Y, OPENAI_BUTTON_W, BUTTON_H)) changed = selectLatest(.openai);
        if (hit(logical_x, logical_y, ANTHROPIC_BUTTON_X, BUTTON_Y, ANTHROPIC_BUTTON_W, BUTTON_H)) changed = selectLatest(.anthropic);
        if (hit(logical_x, logical_y, LINEAR_BUTTON_X, BUTTON_Y, LINEAR_BUTTON_W, BUTTON_H)) changed = setScaleMode(.linear);
        if (hit(logical_x, logical_y, LOG_BUTTON_X, BUTTON_Y, LOG_BUTTON_W, BUTTON_H)) changed = setScaleMode(.log);
    }

    if (nearestPoint(logical_x, logical_y)) |hit_point| {
        if (selected_series != hit_point.series or selected_idx != hit_point.index) {
            selected_series = hit_point.series;
            selected_idx = hit_point.index;
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
    return scaleTweenNextWake();
}

fn selectLatest(series: Series) bool {
    selected_series = series;
    selected_idx = switch (series) {
        .openai => OPENAI_POINTS.len - 1,
        .anthropic => ANTHROPIC_POINTS.len - 1,
    };
    return true;
}

fn setScaleMode(mode: ScaleMode) bool {
    if (scale_mode == mode) return false;
    scale_mode = mode;
    startScaleTween(if (mode == .log) 1.0 else 0.0);
    return true;
}

fn toggleScaleMode() bool {
    return setScaleMode(switch (scale_mode) {
        .linear => .log,
        .log => .linear,
    });
}

fn startScaleTween(target: f64) void {
    scale_tween_from = scale_mix;
    scale_tween_to = target;
    scale_tween_started_at_ms = begun_at_ms;
    const distance = absF64(target - scale_mix);
    scale_tween_duration_ms = @max(1, @as(i64, @intFromFloat(@round(distance * @as(f64, @floatFromInt(SCALE_TWEEN_DURATION_MS))))));
    scale_tween_active = distance > 0.000_001;
    if (!scale_tween_active) scale_mix = target;
}

fn advanceScaleTween(now_ms: i64) void {
    if (!scale_tween_active) return;
    const elapsed = @max(0, now_ms - scale_tween_started_at_ms);
    if (elapsed >= scale_tween_duration_ms) {
        scale_mix = scale_tween_to;
        scale_tween_active = false;
        return;
    }
    const t = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(scale_tween_duration_ms));
    scale_mix = lerpF64(scale_tween_from, scale_tween_to, smoothstep(t));
}

fn scaleTweenNextWake() i64 {
    if (!scale_tween_active) return begun_at_ms;
    const end_at = scale_tween_started_at_ms +| scale_tween_duration_ms;
    const frame_at = begun_at_ms +| SCALE_TWEEN_FRAME_MS;
    return @min(end_at, frame_at);
}

fn selectAdjacent(delta: i32) bool {
    const len = selectedLen();
    if (delta < 0) {
        if (selected_idx == 0) return false;
        selected_idx -= 1;
        return true;
    }
    if (selected_idx + 1 >= len) return false;
    selected_idx += 1;
    return true;
}

fn selectedLen() usize {
    return switch (selected_series) {
        .openai => OPENAI_POINTS.len,
        .anthropic => ANTHROPIC_POINTS.len,
    };
}

fn drawFrame() void {
    fillRect(0, 0, @as(i32, @intCast(DISPLAY_W)), @as(i32, @intCast(DISPLAY_H)), C_BG);
    drawText(PAGE_MARGIN, 20, "OpenAI vs Anthropic revenue run rate", C_INK);
    drawText(PAGE_MARGIN, 40, "Reported milestones in USD billions. Hover or use arrows to explore. Press L to change the scale.", C_MUTED);

    button(OPENAI_BUTTON_X, BUTTON_Y, OPENAI_BUTTON_W, "OpenAI", C_OPENAI, selected_series == .openai, 0);
    button(ANTHROPIC_BUTTON_X, BUTTON_Y, ANTHROPIC_BUTTON_W, "Anthropic", C_ANTHROPIC, selected_series == .anthropic, 0);
    scaleButton(LINEAR_BUTTON_X, BUTTON_Y, LINEAR_BUTTON_W, "Linear", scale_mode == .linear, 0);
    scaleButton(LOG_BUTTON_X, BUTTON_Y, LOG_BUTTON_W, "Log", scale_mode == .log, 0);

    drawChart();
    drawDetail();
}

fn drawChart() void {
    fillRect(CHART_X, CHART_Y, CHART_W, CHART_H, C_CHART);
    drawBorder(CHART_X, CHART_Y, CHART_W, CHART_H, C_INK);

    const year_ticks = [_]struct { month: i32, label: []const u8 }{
        .{ .month = 1, .label = "2024" },
        .{ .month = 13, .label = "2025" },
        .{ .month = 25, .label = "2026" },
    };
    for (year_ticks) |tick_mark| {
        const x = monthToX(tick_mark.month);
        fillRect(x, CHART_Y + 1, 1, CHART_H - 2, C_GRID);
        drawText(x - 18, CHART_Y + CHART_H + 6, tick_mark.label, C_MUTED);
    }

    drawYAxis();
    drawSeries(OPENAI_POINTS[0..], .openai, C_OPENAI);
    drawSeries(ANTHROPIC_POINTS[0..], .anthropic, C_ANTHROPIC);
}

fn drawYAxis() void {
    const linear_ticks = [_]f64{ 0, 10, 20, 30, 40, 50, 60, 70 };
    const log_ticks = [_]f64{ 0.01, 0.1, 1, 10, 100 };
    // Fade one axis out before the other appears so unlike tick values never
    // overlap while the data geometry moves between the two scales.
    drawYAxisTicks(linear_ticks[0..], .linear, clampF64((0.5 - scale_mix) * 2.0, 0, 1));
    drawYAxisTicks(log_ticks[0..], .log, clampF64((scale_mix - 0.5) * 2.0, 0, 1));
}

fn drawYAxisTicks(ticks: []const f64, mode: ScaleMode, opacity: f64) void {
    if (opacity <= 0.001) return;
    var buf: [24]u8 = undefined;
    const alpha = @as(u8, @intFromFloat(@round(clampF64(opacity, 0, 1) * 255.0)));
    const grid_color = lerpColor(C_CHART, C_GRID, opacity);
    for (ticks) |value| {
        const y = arrToYForMode(value, mode);
        if (y > CHART_Y + 1 and y < CHART_Y + CHART_H - 1) fillRect(CHART_X + 1, y, CHART_W - 2, 1, grid_color);
        const label = if (value == 0)
            std.fmt.bufPrint(&buf, "${d:.0}B", .{value}) catch ""
        else if (value < 0.1)
            std.fmt.bufPrint(&buf, "${d:.0}M", .{value * 1000.0}) catch ""
        else if (value < 1)
            std.fmt.bufPrint(&buf, "${d:.1}B", .{value}) catch ""
        else
            std.fmt.bufPrint(&buf, "${d:.0}B", .{value}) catch "";
        drawText(24, y - 6, label, withAlpha(C_MUTED, alpha));
    }
}

fn drawSeries(points: []const ARRPoint, series: Series, color: Color) void {
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const x = monthToX(points[i].month);
        const y = arrToY(points[i].arr_b);
        if (i > 0) {
            drawLineAA(monthToX(points[i - 1].month), arrToY(points[i - 1].arr_b), x, y, color, 1.9);
        }
        const selected = selected_series == series and selected_idx == i;
        fillCircleAA(x, y, if (selected) 4.8 else 3.0, color);
        if (selected) drawCircleAA(x, y, 7.0, 1.25, C_INK);
    }
}

fn drawDetail() void {
    const p = selectedPoint();
    const series_name = switch (selected_series) {
        .openai => "OpenAI",
        .anthropic => "Anthropic",
    };
    const color = switch (selected_series) {
        .openai => C_OPENAI,
        .anthropic => C_ANTHROPIC,
    };

    fillRect(DETAIL_X, DETAIL_Y, DETAIL_W, DETAIL_H, C_PANEL);
    drawBorder(DETAIL_X, DETAIL_Y, DETAIL_W, DETAIL_H, C_INK);
    fillRect(DETAIL_X + 14, DETAIL_Y + 17, 18, 4, color);

    var line: [128]u8 = undefined;
    const detail = if (p.arr_b < 1)
        std.fmt.bufPrint(&line, "{s}  {s}  ARR ${d:.0}M", .{ series_name, p.label, p.arr_b * 1000.0 }) catch ""
    else
        std.fmt.bufPrint(&line, "{s}  {s}  ARR ${d:.1}B", .{ series_name, p.label, p.arr_b }) catch "";
    drawText(DETAIL_X + 42, DETAIL_Y + 12, detail, C_INK);
    drawText(DETAIL_X + 42, DETAIL_Y + 36, p.note, C_MUTED);
}

fn selectedPoint() ARRPoint {
    return switch (selected_series) {
        .openai => OPENAI_POINTS[selected_idx],
        .anthropic => ANTHROPIC_POINTS[selected_idx],
    };
}

const HitPoint = struct {
    series: Series,
    index: usize,
};

fn nearestPoint(x: i32, y: i32) ?HitPoint {
    if (x < CHART_X - 12 or x > CHART_X + CHART_W + 12 or y < CHART_Y - 12 or y > CHART_Y + CHART_H + 12) return null;

    var best = HitPoint{ .series = selected_series, .index = selected_idx };
    var best_dist: i64 = 1 << 60;
    scanNearest(OPENAI_POINTS[0..], .openai, x, y, &best, &best_dist);
    scanNearest(ANTHROPIC_POINTS[0..], .anthropic, x, y, &best, &best_dist);
    if (best_dist > 38 * 38) return null;
    return best;
}

fn scanNearest(points: []const ARRPoint, series: Series, x: i32, y: i32, best: *HitPoint, best_dist: *i64) void {
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const dx = @as(i64, monthToX(points[i].month) - x);
        const dy = @as(i64, arrToY(points[i].arr_b) - y);
        const dist = dx * dx + dy * dy;
        if (dist < best_dist.*) {
            best.* = .{ .series = series, .index = i };
            best_dist.* = dist;
        }
    }
}

fn monthToX(month: i32) i32 {
    const span = MAX_MONTH - MIN_MONTH;
    return CHART_X + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(month - MIN_MONTH)) / @as(f64, @floatFromInt(span)) * @as(f64, @floatFromInt(CHART_W)))));
}

fn arrToY(arr_b: f64) i32 {
    const linear_y = arrToYForMode(arr_b, .linear);
    const log_y = arrToYForMode(arr_b, .log);
    return @as(i32, @intFromFloat(@round(lerpF64(
        @as(f64, @floatFromInt(linear_y)),
        @as(f64, @floatFromInt(log_y)),
        scale_mix,
    ))));
}

fn arrToYForMode(arr_b: f64, mode: ScaleMode) i32 {
    const t = switch (mode) {
        .linear => clampF64(arr_b / ARR_LINEAR_MAX_B, 0, 1),
        .log => logScaleT(arr_b),
    };
    return CHART_Y + CHART_H - @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(CHART_H)))));
}

fn logScaleT(arr_b: f64) f64 {
    const value = clampF64(arr_b, ARR_LOG_MIN_B, ARR_LOG_MAX_B);
    const min_log = std.math.log10(ARR_LOG_MIN_B);
    const max_log = std.math.log10(ARR_LOG_MAX_B);
    return clampF64((std.math.log10(value) - min_log) / (max_log - min_log), 0, 1);
}

fn button(x: i32, y: i32, w: i32, label: []const u8, accent: Color, active: bool, underline_idx: usize) void {
    fillRect(x, y, w, BUTTON_H, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, BUTTON_H, if (active) C_ACTIVE_EDGE else C_INK);
    fillRect(x + 1, y + 1, 6, BUTTON_H - 2, accent);

    drawButtonLabel(x + LEGEND_ACCENT_SPACE + BUTTON_PAD_X, y, label, underline_idx);
}

fn scaleButton(x: i32, y: i32, w: i32, label: []const u8, active: bool, underline_idx: usize) void {
    fillRect(x, y, w, BUTTON_H, if (active) C_ACTIVE else C_PANEL);
    drawBorder(x, y, w, BUTTON_H, if (active) C_ACTIVE_EDGE else C_INK);
    drawButtonLabel(x + BUTTON_PAD_X, y, label, underline_idx);
}

fn drawButtonLabel(x: i32, button_y: i32, label: []const u8, underline_idx: usize) void {
    drawText(x, button_y + BUTTON_LABEL_Y_OFFSET, label, C_INK);
    drawAcceleratorUnderline(x, button_y, label, underline_idx);
}

fn drawAcceleratorUnderline(label_x: i32, button_y: i32, label: []const u8, underline_idx: usize) void {
    if (underline_idx >= label.len) return;
    const x = label_x + textWidth(label[0..underline_idx]);
    const advance = @divTrunc(glyphAdvance(label[underline_idx]) + RETINA_SCALE - 1, RETINA_SCALE);
    fillRect(x, button_y + @divTrunc(BUTTON_H - FONT_SIZE_LOGICAL, 2) + FONT_SIZE_LOGICAL + 1, @max(1, advance - 2), 1, C_INK);
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn clampF64(value: f64, min: f64, max: f64) f64 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn absF64(value: f64) f64 {
    return if (value < 0) -value else value;
}

fn lerpF64(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * clampF64(t, 0, 1);
}

fn smoothstep(t_in: f64) f64 {
    const t = clampF64(t_in, 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

fn lerpColor(a: Color, b: Color, t: f64) Color {
    const clamped = clampF64(t, 0, 1);
    return .{
        @as(u8, @intFromFloat(@round(lerpF64(@as(f64, @floatFromInt(a[0])), @as(f64, @floatFromInt(b[0])), clamped)))),
        @as(u8, @intFromFloat(@round(lerpF64(@as(f64, @floatFromInt(a[1])), @as(f64, @floatFromInt(b[1])), clamped)))),
        @as(u8, @intFromFloat(@round(lerpF64(@as(f64, @floatFromInt(a[2])), @as(f64, @floatFromInt(b[2])), clamped)))),
        0xFF,
    };
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var cursor_x = x * RETINA_SCALE;
    const text_y = y * RETINA_SCALE;
    var i: usize = 0;
    while (i < text.len and i < 110) : (i += 1) {
        drawFontChar(cursor_x, text_y, text[i], c);
        cursor_x += glyphAdvance(text[i]);
    }
}

fn textWidth(text: []const u8) i32 {
    var width: i32 = 0;
    for (text) |ch| width += glyphAdvance(ch);
    return @divTrunc(width + RETINA_SCALE - 1, RETINA_SCALE);
}

fn glyphAdvance(ch: u8) i32 {
    const index = glyphIndexForByte(ch) orelse return 0;
    return ui_font.advances[index];
}

fn drawFontChar(x: i32, y: i32, ch: u8, c: Color) void {
    const glyph_index = glyphIndexForByte(ch) orelse return;
    var dy: i32 = 0;
    while (dy < @as(i32, @intCast(ui_font.GLYPH_H))) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < @as(i32, @intCast(ui_font.GLYPH_W))) : (dx += 1) {
            const alpha4 = glyphAlpha4(glyph_index, dx, dy);
            if (alpha4 == 0) continue;
            var cc = c;
            cc[3] = @intCast(@divTrunc(@as(u16, c[3]) * alpha4, 15));
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

fn glyphAlpha4(glyph_index: usize, x: i32, y: i32) u8 {
    const pixel_index: usize = @as(usize, @intCast(y)) * ui_font.GLYPH_W + @as(usize, @intCast(x));
    const byte = ui_font.glyph_alpha4[glyph_index][pixel_index / 2];
    return if (pixel_index % 2 == 0) byte >> 4 else byte & 0x0F;
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

test "latest Anthropic ARR is above latest OpenAI run-rate milestone" {
    try std.testing.expect(ANTHROPIC_POINTS[ANTHROPIC_POINTS.len - 1].arr_b > OPENAI_POINTS[OPENAI_POINTS.len - 1].arr_b);
}

test "latest milestones cite Bloomberg in hover detail" {
    const openai = OPENAI_POINTS[OPENAI_POINTS.len - 1];
    const anthropic = ANTHROPIC_POINTS[ANTHROPIC_POINTS.len - 1];
    try std.testing.expectEqual(@as(f64, 40.0), openai.arr_b);
    try std.testing.expectEqual(@as(f64, 65.0), anthropic.arr_b);
    try std.testing.expect(std.mem.indexOf(u8, openai.note, "Bloomberg") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic.note, "Bloomberg") != null);
}

test "scale tween interpolates for 300 milliseconds" {
    scale_mode = .log;
    scale_mix = 1.0;
    scale_tween_active = false;
    begun_at_ms = 100;

    try std.testing.expect(setScaleMode(.linear));
    try std.testing.expect(scale_tween_active);
    try std.testing.expectEqual(@as(i64, SCALE_TWEEN_DURATION_MS), scale_tween_duration_ms);
    const log_y = arrToYForMode(10.0, .log);
    const linear_y = arrToYForMode(10.0, .linear);

    advanceScaleTween(250);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), scale_mix, 0.000_001);
    const middle_y = arrToY(10.0);
    try std.testing.expect(middle_y > @min(log_y, linear_y));
    try std.testing.expect(middle_y < @max(log_y, linear_y));

    advanceScaleTween(400);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), scale_mix, 0.000_001);
    try std.testing.expect(!scale_tween_active);
}

test "reversing scale tween starts from its current position" {
    scale_mode = .log;
    scale_mix = 1.0;
    scale_tween_active = false;
    begun_at_ms = 100;
    _ = setScaleMode(.linear);
    advanceScaleTween(250);
    const before_reverse = scale_mix;

    begun_at_ms = 250;
    try std.testing.expect(setScaleMode(.log));
    try std.testing.expectApproxEqAbs(before_reverse, scale_tween_from, 0.000_001);
    try std.testing.expectEqual(@as(i64, 150), scale_tween_duration_ms);
    advanceScaleTween(400);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), scale_mix, 0.000_001);
    try std.testing.expect(!scale_tween_active);
}
