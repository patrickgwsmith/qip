const std = @import("std");
const ui_font = @import("assets/inter_display_chart_ascii.zig");

const DISPLAY_W: usize = 820;
const DISPLAY_H: usize = 540;
const PAGE_MARGIN: i32 = 24;
// The saved Inter advances were measured at 28 px; this SVG uses 14 px.
const FONT_METRIC_SCALE: i32 = 2;
const OUTPUT_CAP: usize = 65536;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

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
// Place the browser-rendered Inter text within the 30 px button.
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

var output_buf: [OUTPUT_CAP]u8 = undefined;
var selected_series: Series = .anthropic;
var selected_idx: usize = ANTHROPIC_POINTS.len - 1;
var hovered_point: ?HitPoint = null;
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

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
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
    const down = (button_mask & BTN_PRIMARY) != 0;
    var changed = false;

    if (down and !primary_down) {
        if (hit(x, y, OPENAI_BUTTON_X, BUTTON_Y, OPENAI_BUTTON_W, BUTTON_H)) changed = selectLatest(.openai);
        if (hit(x, y, ANTHROPIC_BUTTON_X, BUTTON_Y, ANTHROPIC_BUTTON_W, BUTTON_H)) changed = selectLatest(.anthropic);
        if (hit(x, y, LINEAR_BUTTON_X, BUTTON_Y, LINEAR_BUTTON_W, BUTTON_H)) changed = setScaleMode(.linear);
        if (hit(x, y, LOG_BUTTON_X, BUTTON_Y, LOG_BUTTON_W, BUTTON_H)) changed = setScaleMode(.log);
    }

    const nearest = nearestPoint(x, y);
    if (nearest) |hit_point| {
        if (selected_series != hit_point.series or selected_idx != hit_point.index) {
            selected_series = hit_point.series;
            selected_idx = hit_point.index;
            changed = true;
        }
    }
    if (!std.meta.eql(hovered_point, nearest)) {
        hovered_point = nearest;
        changed = true;
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
    var writer = Writer{};
    drawFrame(&writer) catch @trap();
    transaction_phase = .ready;
    return @intCast(writer.n);
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

const Writer = struct {
    n: usize = 0,

    fn bytes(w: *Writer, s: []const u8) !void {
        if (s.len > OUTPUT_CAP - w.n) return error.Full;
        @memcpy(output_buf[w.n..][0..s.len], s);
        w.n += s.len;
    }

    fn fmt(w: *Writer, comptime format: []const u8, args: anytype) !void {
        const printed = std.fmt.bufPrint(output_buf[w.n..], format, args) catch return error.Full;
        w.n += printed.len;
    }

    fn escaped(w: *Writer, s: []const u8) !void {
        for (s) |byte| {
            switch (byte) {
                '&' => try w.bytes("&amp;"),
                '<' => try w.bytes("&lt;"),
                '>' => try w.bytes("&gt;"),
                '"' => try w.bytes("&quot;"),
                else => try w.bytes(&.{byte}),
            }
        }
    }
};

fn color(w: *Writer, c: Color) !void {
    try w.fmt("#{X:0>2}{X:0>2}{X:0>2}", .{ c[0], c[1], c[2] });
}

fn rect(w: *Writer, x: i32, y: i32, width: i32, height: i32, fill: Color) !void {
    try w.fmt("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"", .{ x, y, width, height });
    try color(w, fill);
    try w.bytes("\"/>");
}

fn outline(w: *Writer, x: i32, y: i32, width: i32, height: i32, stroke: Color) !void {
    try w.fmt("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d}\" height=\"{d}\" fill=\"none\" stroke=\"", .{ @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5, width - 1, height - 1 });
    try color(w, stroke);
    try w.bytes("\" stroke-width=\"1\"/>");
}

fn line(w: *Writer, x1: i32, y1: i32, x2: i32, y2: i32, stroke: Color, opacity: f64) !void {
    try w.fmt("<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\" stroke=\"", .{ x1, y1, x2, y2 });
    try color(w, stroke);
    try w.fmt("\" stroke-opacity=\"{d:.3}\" stroke-width=\"1\"/>", .{opacity});
}

fn circle(w: *Writer, x: i32, y: i32, radius: f64, fill: Color) !void {
    try w.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d:.1}\" fill=\"", .{ x, y, radius });
    try color(w, fill);
    try w.bytes("\"/>");
}

fn textAt(w: *Writer, x: i32, top: i32, label: []const u8, fill: Color, opacity: f64) !void {
    try w.fmt("<text x=\"{d}\" y=\"{d}\" fill=\"", .{ x, top + 16 });
    try color(w, fill);
    try w.fmt("\" fill-opacity=\"{d:.3}\">", .{opacity});
    try w.escaped(label);
    try w.bytes("</text>");
}

fn drawFrame(w: *Writer) !void {
    // The page's universal CSS overrides SVG presentation attributes. The
    // spacing also tracks the rounded 28 px glyph advances in the raster fork.
    try w.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" style=\"font-size:14px;letter-spacing:0.25px\" role=\"img\" aria-label=\"OpenAI and Anthropic annualized revenue milestones\">", .{ DISPLAY_W, DISPLAY_H, DISPLAY_W, DISPLAY_H });
    try w.bytes("<g font-family=\"QIP Chart Inter, Inter, sans-serif\" font-size=\"14\" font-weight=\"700\">");
    try rect(w, 0, 0, @intCast(DISPLAY_W), @intCast(DISPLAY_H), C_BG);
    try textAt(w, PAGE_MARGIN, 20, "OpenAI vs Anthropic revenue run rate", C_INK, 1);
    try textAt(w, PAGE_MARGIN, 40, "Reported milestones in USD billions. Hover or use arrows to explore. Press L to change the scale.", C_MUTED, 1);

    try button(w, OPENAI_BUTTON_X, BUTTON_Y, OPENAI_BUTTON_W, "OpenAI", C_OPENAI, selected_series == .openai, "series-openai");
    try button(w, ANTHROPIC_BUTTON_X, BUTTON_Y, ANTHROPIC_BUTTON_W, "Anthropic", C_ANTHROPIC, selected_series == .anthropic, "series-anthropic");
    try scaleButton(w, LINEAR_BUTTON_X, BUTTON_Y, LINEAR_BUTTON_W, "Linear", scale_mode == .linear, "scale-linear");
    try scaleButton(w, LOG_BUTTON_X, BUTTON_Y, LOG_BUTTON_W, "Log", scale_mode == .log, "scale-log");

    try drawChart(w);
    try drawHoverTooltip(w);
    try drawDetail(w);
    try w.bytes("</g></svg>");
}

fn button(w: *Writer, x: i32, y: i32, width: i32, label: []const u8, accent: Color, active: bool, role: []const u8) !void {
    try w.fmt("<g data-qip-chart-control=\"{s}\">", .{role});
    try rect(w, x, y, width, BUTTON_H, if (active) C_ACTIVE else C_PANEL);
    try outline(w, x, y, width, BUTTON_H, if (active) C_ACTIVE_EDGE else C_INK);
    try rect(w, x + 1, y + 1, 6, BUTTON_H - 2, accent);
    const label_x = x + LEGEND_ACCENT_SPACE + BUTTON_PAD_X;
    try textAt(w, label_x, y + BUTTON_LABEL_Y_OFFSET, label, C_INK, 1);
    try underline(w, label_x, y, label);
    try w.bytes("</g>");
}

fn scaleButton(w: *Writer, x: i32, y: i32, width: i32, label: []const u8, active: bool, role: []const u8) !void {
    try w.fmt("<g data-qip-chart-control=\"{s}\">", .{role});
    try rect(w, x, y, width, BUTTON_H, if (active) C_ACTIVE else C_PANEL);
    try outline(w, x, y, width, BUTTON_H, if (active) C_ACTIVE_EDGE else C_INK);
    const label_x = x + BUTTON_PAD_X;
    try textAt(w, label_x, y + BUTTON_LABEL_Y_OFFSET, label, C_INK, 1);
    try underline(w, label_x, y, label);
    try w.bytes("</g>");
}

fn underline(w: *Writer, label_x: i32, button_y: i32, label: []const u8) !void {
    if (label.len == 0) return;
    const width = @divTrunc(glyphAdvance(label[0]) + FONT_METRIC_SCALE - 1, FONT_METRIC_SCALE);
    try rect(w, label_x, button_y + @divTrunc(BUTTON_H - FONT_SIZE_LOGICAL, 2) + FONT_SIZE_LOGICAL + 1, @max(1, width - 2), 1, C_INK);
}

fn drawChart(w: *Writer) !void {
    try rect(w, CHART_X, CHART_Y, CHART_W, CHART_H, C_CHART);
    try outline(w, CHART_X, CHART_Y, CHART_W, CHART_H, C_INK);
    const years = [_]struct { month: i32, label: []const u8 }{
        .{ .month = 1, .label = "2024" },
        .{ .month = 13, .label = "2025" },
        .{ .month = 25, .label = "2026" },
    };
    for (years) |year| {
        const x = monthToX(year.month);
        try line(w, x, CHART_Y + 1, x, CHART_Y + CHART_H - 1, C_GRID, 1);
        try textAt(w, x - 18, CHART_Y + CHART_H + 6, year.label, C_MUTED, 1);
    }
    try drawYAxis(w);
    try drawSeries(w, OPENAI_POINTS[0..], .openai, C_OPENAI);
    try drawSeries(w, ANTHROPIC_POINTS[0..], .anthropic, C_ANTHROPIC);
}

fn drawYAxis(w: *Writer) !void {
    const linear_ticks = [_]f64{ 0, 10, 20, 30, 40, 50, 60, 70 };
    const log_ticks = [_]f64{ 0.01, 0.1, 1, 10, 100 };
    try drawYAxisTicks(w, linear_ticks[0..], .linear, clampF64((0.5 - scale_mix) * 2, 0, 1));
    try drawYAxisTicks(w, log_ticks[0..], .log, clampF64((scale_mix - 0.5) * 2, 0, 1));
}

fn drawYAxisTicks(w: *Writer, ticks: []const f64, mode: ScaleMode, opacity: f64) !void {
    if (opacity <= 0.001) return;
    var buf: [24]u8 = undefined;
    for (ticks) |value| {
        const y = arrToYForMode(value, mode);
        if (y > CHART_Y + 1 and y < CHART_Y + CHART_H - 1) try line(w, CHART_X + 1, y, CHART_X + CHART_W - 1, y, C_GRID, opacity);
        const label = if (value == 0)
            std.fmt.bufPrint(&buf, "${d:.0}B", .{value}) catch ""
        else if (value < 0.1)
            std.fmt.bufPrint(&buf, "${d:.0}M", .{value * 1000}) catch ""
        else if (value < 1)
            std.fmt.bufPrint(&buf, "${d:.1}B", .{value}) catch ""
        else
            std.fmt.bufPrint(&buf, "${d:.0}B", .{value}) catch "";
        try textAt(w, 24, y - 6, label, C_MUTED, opacity);
    }
}

fn drawSeries(w: *Writer, points: []const ARRPoint, series: Series, stroke: Color) !void {
    try w.bytes("<path d=\"");
    for (points, 0..) |point, index| {
        try w.fmt("{s}{d} {d}", .{ if (index == 0) "M" else " L", monthToX(point.month), arrToY(point.arr_b) });
    }
    try w.bytes("\" fill=\"none\" stroke=\"");
    try color(w, stroke);
    try w.bytes("\" stroke-width=\"1.9\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>");
    for (points, 0..) |point, index| {
        const x = monthToX(point.month);
        const y = arrToY(point.arr_b);
        const selected = selected_series == series and selected_idx == index;
        try circle(w, x, y, if (selected) 4.8 else 3, stroke);
        if (selected) {
            try w.fmt("<circle cx=\"{d}\" cy=\"{d}\" r=\"7\" fill=\"none\" stroke=\"", .{ x, y });
            try color(w, C_INK);
            try w.bytes("\" stroke-width=\"1.25\"/>");
        }
    }
}

fn drawHoverTooltip(w: *Writer) !void {
    const point_hit = hovered_point orelse return;
    const point = pointForHit(point_hit);
    const name: []const u8 = switch (point_hit.series) {
        .openai => "OpenAI",
        .anthropic => "Anthropic",
    };
    const accent = switch (point_hit.series) {
        .openai => C_OPENAI,
        .anthropic => C_ANTHROPIC,
    };
    var title_buf: [48]u8 = undefined;
    const title = if (point.arr_b < 1)
        std.fmt.bufPrint(&title_buf, "{s}  ${d:.0}M", .{ name, point.arr_b * 1000 }) catch return
    else
        std.fmt.bufPrint(&title_buf, "{s}  ${d:.1}B", .{ name, point.arr_b }) catch return;
    const width = @max(textWidth(title), textWidth(point.label)) + 28;
    const height: i32 = 48;
    const px = monthToX(point.month);
    const py = arrToY(point.arr_b);
    const x = if (px + 12 + width <= DETAIL_X + DETAIL_W) px + 12 else px - width - 12;
    const y = if (py - height - 12 >= CHART_Y) py - height - 12 else py + 12;
    try w.bytes("<g data-qip-chart-tooltip=\"true\" pointer-events=\"none\">");
    try rect(w, x, y, width, height, C_PANEL);
    try outline(w, x, y, width, height, C_ACTIVE_EDGE);
    try rect(w, x + 1, y + 1, 4, height - 2, accent);
    try textAt(w, x + 14, y + 4, title, C_INK, 1);
    try textAt(w, x + 14, y + 24, point.label, C_MUTED, 1);
    try w.bytes("</g>");
}

fn drawDetail(w: *Writer) !void {
    const point = selectedPoint();
    const name: []const u8 = switch (selected_series) {
        .openai => "OpenAI",
        .anthropic => "Anthropic",
    };
    const accent = switch (selected_series) {
        .openai => C_OPENAI,
        .anthropic => C_ANTHROPIC,
    };
    try rect(w, DETAIL_X, DETAIL_Y, DETAIL_W, DETAIL_H, C_PANEL);
    try outline(w, DETAIL_X, DETAIL_Y, DETAIL_W, DETAIL_H, C_INK);
    try rect(w, DETAIL_X + 14, DETAIL_Y + 17, 18, 4, accent);
    var line_buf: [128]u8 = undefined;
    const detail = if (point.arr_b < 1)
        std.fmt.bufPrint(&line_buf, "{s}  {s}  ARR ${d:.0}M", .{ name, point.label, point.arr_b * 1000 }) catch ""
    else
        std.fmt.bufPrint(&line_buf, "{s}  {s}  ARR ${d:.1}B", .{ name, point.label, point.arr_b }) catch "";
    try textAt(w, DETAIL_X + 42, DETAIL_Y + 12, detail, C_INK, 1);
    try textAt(w, DETAIL_X + 42, DETAIL_Y + 36, point.note, C_MUTED, 1);
}

fn selectedPoint() ARRPoint {
    return switch (selected_series) {
        .openai => OPENAI_POINTS[selected_idx],
        .anthropic => ANTHROPIC_POINTS[selected_idx],
    };
}

fn pointForHit(point_hit: HitPoint) ARRPoint {
    return switch (point_hit.series) {
        .openai => OPENAI_POINTS[point_hit.index],
        .anthropic => ANTHROPIC_POINTS[point_hit.index],
    };
}

const HitPoint = struct { series: Series, index: usize };

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
    for (points, 0..) |point, index| {
        const dx = @as(i64, monthToX(point.month) - x);
        const dy = @as(i64, arrToY(point.arr_b) - y);
        const dist = dx * dx + dy * dy;
        if (dist < best_dist.*) {
            best.* = .{ .series = series, .index = index };
            best_dist.* = dist;
        }
    }
}

fn monthToX(month: i32) i32 {
    const span = MAX_MONTH - MIN_MONTH;
    return CHART_X + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(month - MIN_MONTH)) / @as(f64, @floatFromInt(span)) * @as(f64, @floatFromInt(CHART_W)))));
}

fn arrToY(value: f64) i32 {
    const linear = arrToYForMode(value, .linear);
    const logarithmic = arrToYForMode(value, .log);
    return @intFromFloat(@round(lerpF64(@floatFromInt(linear), @floatFromInt(logarithmic), scale_mix)));
}

fn arrToYForMode(value: f64, mode: ScaleMode) i32 {
    const t = switch (mode) {
        .linear => clampF64(value / ARR_LINEAR_MAX_B, 0, 1),
        .log => logScaleT(value),
    };
    return CHART_Y + CHART_H - @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(CHART_H)))));
}

fn logScaleT(value: f64) f64 {
    const clamped = clampF64(value, ARR_LOG_MIN_B, ARR_LOG_MAX_B);
    return clampF64((std.math.log10(clamped) - std.math.log10(ARR_LOG_MIN_B)) / (std.math.log10(ARR_LOG_MAX_B) - std.math.log10(ARR_LOG_MIN_B)), 0, 1);
}

fn textWidth(label: []const u8) i32 {
    var width: i32 = 0;
    for (label) |byte| width += glyphAdvance(byte);
    return @divTrunc(width + FONT_METRIC_SCALE - 1, FONT_METRIC_SCALE);
}

fn glyphAdvance(byte: u8) i32 {
    if (byte < ui_font.ASCII_START or byte > ui_font.ASCII_END) return 0;
    return ui_font.advances[@as(usize, byte - ui_font.ASCII_START)];
}

fn hit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and x < bx + bw and y >= by and y < by + bh;
}

fn clampF64(value: f64, min: f64, max: f64) f64 {
    return @max(min, @min(max, value));
}

fn absF64(value: f64) f64 {
    return @abs(value);
}
fn lerpF64(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * clampF64(t, 0, 1);
}
fn smoothstep(value: f64) f64 {
    const t = clampF64(value, 0, 1);
    return t * t * (3 - 2 * t);
}
