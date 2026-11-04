//! Adds fiscal-quarter labels under the bars in the bar-chart SVG subset
//! emitted by `text/csv/fiscal-quarter-csv-to-svg-bars.wasm`.
//!
//! Input and output are `image/svg+xml`. Each bar's `data-fiscal-quarter`
//! (`FY2026Q4`) becomes a `Q4` label centred under the bar, or just `4` when
//! bars are closer than `MIN_PREFIXED_PITCH` apart so long ranges (ten years
//! of quarters) stay legible. A second row
//! labels the fiscal year as `’26` under each first quarter and under the
//! first bar (unless the next year label would be closer than
//! `MIN_YEAR_GAP`). Fiscal years are whatever the CSV says, so Apple's `FY2026Q4`
//! ends in September and NVIDIA's ends in January. `label_color_rgba` (packed
//! `0xRRGGBBAA`, default `0x374151ff`) sets the text colour. Labels are inserted before
//! the closing `</svg>`; every other byte is copied unchanged.
const std = @import("std");
const bars_svg = @import("svg_bars");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 320 * 1024;
const CONTENT_TYPE = "image/svg+xml";
const DEFAULT_LABEL_COLOR_RGBA: u32 = 0x374151ff;

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var bars: [bars_svg.MAX_BARS]bars_svg.Bar = undefined;
var label_color_rgba: u32 = DEFAULT_LABEL_COLOR_RGBA;

/// Narrowest bar-to-bar distance, in SVG units, that fits an 11px `Q4` label.
const MIN_PREFIXED_PITCH: f64 = 20;
/// Narrowest distance between the centres of two bold 12px `’26` labels.
const MIN_YEAR_GAP: f64 = 28;

fn addQuarterXAxis(source: []const u8, destination: []u8, label_color: u32) bars_svg.Error!usize {
    const root = try bars_svg.readRoot(source);
    const found = try bars_svg.readBars(source, &bars);
    const at = try bars_svg.frontOffset(source);
    var out = bars_svg.Output{ .bytes = destination };
    try out.append(source[0..at]);
    try out.append("<g data-layer=\"quarter-x-axis\" fill=\"");
    try out.color(label_color);
    try out.append("\" text-anchor=\"middle\">");
    const prefixed = found.len < 2 or found[1].x - found[0].x >= MIN_PREFIXED_PITCH;
    for (found, 0..) |bar, i| {
        const x = bar.x + bar.width / 2;
        try out.append("<text x=\"");
        try out.number(x);
        try out.append("\" y=\"");
        try out.number(root.bottom + 16);
        try out.append("\" font-size=\"11\">");
        if (prefixed) try out.append("Q");
        try out.append(&.{'0' + bar.quarter});
        try out.append("</text>");
        if (bar.quarter != 1 and i != 0) continue;
        if (bar.quarter != 1) {
            const next_first: usize = 5 - @as(usize, bar.quarter);
            if (next_first < found.len and found[next_first].x - bar.x < MIN_YEAR_GAP) continue;
        }
        try out.append("<text x=\"");
        try out.number(x);
        try out.append("\" y=\"");
        try out.number(root.bottom + 32);
        try out.append("\" font-size=\"12\" font-weight=\"bold\">\u{2019}");
        const two_digits = bar.fiscal_year % 100;
        try out.append(&.{ '0' + @as(u8, @intCast(two_digits / 10)), '0' + @as(u8, @intCast(two_digits % 10)) });
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
export fn uniform_set_label_color_rgba(value: u32) u32 {
    label_color_rgba = value;
    return value;
}
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const label_color = label_color_rgba;
    label_color_rgba = DEFAULT_LABEL_COLOR_RGBA;
    const out_n = addQuarterXAxis(input[0..n], &output, label_color) catch return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}

test "labels quarters and fiscal years" {
    const sample =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" data-plot-left=\"64\" data-plot-top=\"24\" data-plot-right=\"624\" data-plot-bottom=\"344\" data-value-min=\"0\" data-value-max=\"10\" data-value-step=\"2\">" ++
        "<g data-layer=\"bars\">" ++
        "<rect x=\"70\" y=\"0\" width=\"20\" height=\"1\" data-fiscal-quarter=\"FY2025Q4\" data-value=\"1\"><title>FY2025Q4: 1</title></rect>" ++
        "<rect x=\"100\" y=\"0\" width=\"20\" height=\"1\" data-fiscal-quarter=\"FY2026Q1\" data-value=\"2\"/>" ++
        "<rect x=\"130\" y=\"0\" width=\"20\" height=\"1\" data-fiscal-quarter=\"FY2026Q2\" data-value=\"3\"/>" ++
        "</g></svg>\n";
    var buf: [8192]u8 = undefined;
    const n = try addQuarterXAxis(sample, &buf, DEFAULT_LABEL_COLOR_RGBA);
    const svg = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, svg, "<g data-layer=\"quarter-x-axis\" fill=\"#374151\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "x=\"80\" y=\"360\" font-size=\"11\">Q4</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">\u{2019}25</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "x=\"110\" y=\"376\" font-size=\"12\" font-weight=\"bold\">\u{2019}26</text>") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, svg, "\u{2019}"));
    try std.testing.expect(std.mem.endsWith(u8, svg, "</text></g></svg>\n"));
}

test "drops the Q prefix when bars are too close together" {
    const sample =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" data-plot-left=\"64\" data-plot-top=\"24\" data-plot-right=\"624\" data-plot-bottom=\"344\" data-value-min=\"0\" data-value-max=\"10\" data-value-step=\"2\">" ++
        "<g data-layer=\"bars\">" ++
        "<rect x=\"70\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2025Q4\" data-value=\"1\"/>" ++
        "<rect x=\"84\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2026Q1\" data-value=\"2\"/>" ++
        "</g></svg>\n";
    var buf: [8192]u8 = undefined;
    const n = try addQuarterXAxis(sample, &buf, DEFAULT_LABEL_COLOR_RGBA);
    const svg = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, svg, "x=\"75\" y=\"360\" font-size=\"11\">4</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">Q") == null);
}

test "skips the first-bar year when the next year label is too close" {
    const sample =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" data-plot-left=\"64\" data-plot-top=\"24\" data-plot-right=\"624\" data-plot-bottom=\"344\" data-value-min=\"0\" data-value-max=\"10\" data-value-step=\"2\">" ++
        "<g data-layer=\"bars\">" ++
        "<rect x=\"70\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2016Q4\" data-value=\"1\"/>" ++
        "<rect x=\"84\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2017Q1\" data-value=\"2\"/>" ++
        "</g></svg>\n";
    var buf: [8192]u8 = undefined;
    const n = try addQuarterXAxis(sample, &buf, DEFAULT_LABEL_COLOR_RGBA);
    const svg = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, svg, ">\u{2019}16</text>") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">\u{2019}17</text>") != null);
}
