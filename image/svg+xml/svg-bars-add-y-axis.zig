//! Adds labelled horizontal gridlines to the bar-chart SVG subset emitted by
//! `text/csv/fiscal-quarter-csv-to-svg-bars.wasm`.
//!
//! Input and output are `image/svg+xml`. The pass reads the root
//! `data-plot-*`, `data-value-min/max` and `data-value-step` attributes and
//! draws a gridline at every multiple of the step inside the domain. Setting
//! `tick_count` to a positive number instead picks a round step (1, 2, 2.5 or
//! 5 times a power of ten) that splits the domain into roughly that many
//! intervals; the default 0 keeps the step recorded in the SVG. Labels print the root's literal `data-label-prefix` and
//! `data-label-suffix` around the number (`$25B`); negative values put the
//! minus sign first (`-$5B`). Colour uniforms are packed `0xRRGGBBAA`:
//! `label_color_rgba` (default `0x6b7280ff`), `gridline_color_rgba` (default
//! `0xe5e7ebff`) and `zero_line_color_rgba` (default `0x374151ff`). The gridlines are inserted before the bars group
//! so the bars paint over them. Every other byte is copied unchanged.
const std = @import("std");
const bars_svg = @import("svg_bars");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 320 * 1024;
const CONTENT_TYPE = "image/svg+xml";
const DEFAULT_TICK_COUNT: u32 = 0;
const MAX_TICKS = 64;

const Colors = struct {
    label: u32 = 0x6b7280ff,
    gridline: u32 = 0xe5e7ebff,
    zero_line: u32 = 0x374151ff,
};
var colors: Colors = .{};

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var tick_count: u32 = DEFAULT_TICK_COUNT;

fn addYAxis(source: []const u8, destination: []u8, intervals: u32, palette: Colors) bars_svg.Error!usize {
    const root = try bars_svg.readRoot(source);
    const at = try bars_svg.behindBarsOffset(source);
    var out = bars_svg.Output{ .bytes = destination };
    try out.append(source[0..at]);

    const step = if (intervals == 0) root.value_step else bars_svg.niceStep(root.value_max - root.value_min, intervals);
    const decimals = bars_svg.stepDecimals(step);
    const first: i64 = @intFromFloat(@ceil(root.value_min / step - 1e-9));
    const last: i64 = @intFromFloat(@floor(root.value_max / step + 1e-9));
    if (last - first > MAX_TICKS) return error.InvalidSVG;

    try out.append("<g data-layer=\"y-axis\" font-size=\"12\" fill=\"");
    try out.color(palette.label);
    try out.append("\" text-anchor=\"end\">");
    var k = first;
    while (k <= last) : (k += 1) {
        const value = @as(f64, @floatFromInt(k)) * step;
        const y = root.y(value);
        try out.append("<path d=\"M ");
        try out.number(root.left);
        try out.append(" ");
        try out.number(y);
        try out.append(" H ");
        try out.number(root.right);
        try out.append("\" fill=\"none\" stroke=\"");
        try out.color(if (k == 0) palette.zero_line else palette.gridline);
        try out.append("\" stroke-width=\"1\"/>");
        try out.append("<text x=\"");
        try out.number(root.left - 8);
        try out.append("\" y=\"");
        try out.number(y + 4);
        try out.append("\">");
        try bars_svg.label(&out, root, value, decimals);
        try out.append("</text>");
    }
    try out.append("</g>");
    try out.append(source[at..]);
    return out.pos;
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn failure_modes_per_input_offset() u32 {
    return 0;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}
export fn uniform_set_tick_count(value: u32) u32 {
    tick_count = value;
    return value;
}
export fn uniform_set_label_color_rgba(value: u32) u32 {
    colors.label = value;
    return value;
}
export fn uniform_set_gridline_color_rgba(value: u32) u32 {
    colors.gridline = value;
    return value;
}
export fn uniform_set_zero_line_color_rgba(value: u32) u32 {
    colors.zero_line = value;
    return value;
}
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const intervals = tick_count;
    const palette = colors;
    tick_count = DEFAULT_TICK_COUNT;
    colors = .{};
    const out_n = addYAxis(input[0..n], &output, intervals, palette) catch return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}

const SAMPLE =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" data-plot-left=\"64\" data-plot-top=\"24\" data-plot-right=\"624\" data-plot-bottom=\"344\" data-value-min=\"-50\" data-value-max=\"150\" data-value-step=\"50\" data-label-prefix=\"$\" data-label-suffix=\"B\">" ++
    "<rect width=\"640\" height=\"400\" fill=\"white\"/><g data-layer=\"bars\"><rect x=\"80\" y=\"100\" width=\"20\" height=\"50\" data-fiscal-quarter=\"FY2026Q4\" data-value=\"102.5\"/></g></svg>\n";

test "inserts prefixed gridlines before the bars" {
    var buf: [8192]u8 = undefined;
    const n = try addYAxis(SAMPLE, &buf, 0, .{});
    const svg = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, svg, "fill=\"#6b7280\" text-anchor") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, "stroke=\"#374151\""));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, svg, "stroke=\"#e5e7eb\""));
    const axis = std.mem.indexOf(u8, svg, "data-layer=\"y-axis\"").?;
    try std.testing.expect(axis < std.mem.indexOf(u8, svg, bars_svg.BARS_GROUP).?);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">-$50B</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">$0B</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">$150B</text>") != null);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, svg, "</text>"));
}

test "tick_count picks its own round step" {
    var buf: [8192]u8 = undefined;
    const n = try addYAxis(SAMPLE, &buf, 8, .{});
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], ">$25B</text>") != null);
    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, buf[0..n], "</text>"));
}
