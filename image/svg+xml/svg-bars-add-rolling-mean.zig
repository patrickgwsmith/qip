//! Overlays a trailing rolling-mean line on the bar-chart SVG subset emitted
//! by `text/csv/fiscal-quarter-csv-to-svg-bars.wasm`.
//!
//! Input and output are `image/svg+xml`. `window_size` (default 4, so a
//! four-quarter average) is a positive count of bars. The line starts at the
//! first bar with a full window behind it, so there is no partial average,
//! and passes through each bar's top-centre position for the mean of that bar
//! and the previous `window_size - 1` bars, using the root `data-plot-*` and
//! `data-value-min/max` mapping. With fewer bars than the window, no line is
//! added. The line is inserted before the closing `</svg>`, in front of the
//! bars; every other byte is copied unchanged.
const std = @import("std");
const bars_svg = @import("svg_bars");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 320 * 1024;
const CONTENT_TYPE = "image/svg+xml";
const DEFAULT_WINDOW_SIZE: u32 = 4;

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var bars: [bars_svg.MAX_BARS]bars_svg.Bar = undefined;
var window_size: u32 = DEFAULT_WINDOW_SIZE;

fn addRollingMean(source: []const u8, destination: []u8, window: u32) bars_svg.Error!usize {
    if (window == 0) return error.InvalidSVG;
    const root = try bars_svg.readRoot(source);
    const found = try bars_svg.readBars(source, &bars);
    const at = try bars_svg.frontOffset(source);
    var out = bars_svg.Output{ .bytes = destination };
    try out.append(source[0..at]);
    if (found.len >= window) {
        try out.append("<polyline data-layer=\"rolling-mean\" data-window-size=\"");
        var buf: [16]u8 = undefined;
        try out.append(std.fmt.bufPrint(&buf, "{d}", .{window}) catch return error.OutputOverflow);
        try out.append("\" points=\"");
        var total: f64 = 0;
        for (found, 0..) |bar, i| {
            total += bar.value;
            if (i >= window) total -= found[i - window].value;
            if (i + 1 < window) continue;
            if (i + 1 > window) try out.append(" ");
            try out.number(bar.x + bar.width / 2);
            try out.append(",");
            try out.number(root.y(total / @as(f64, @floatFromInt(window))));
        }
        try out.append("\" fill=\"none\" stroke=\"#f97316\" stroke-width=\"2.5\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>");
    }
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
export fn uniform_set_window_size(value: u32) u32 {
    window_size = value;
    return value;
}
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const window = window_size;
    window_size = DEFAULT_WINDOW_SIZE;
    const out_n = addRollingMean(input[0..n], &output, window) catch return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}

const SAMPLE =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" data-plot-left=\"0\" data-plot-top=\"0\" data-plot-right=\"100\" data-plot-bottom=\"100\" data-value-min=\"0\" data-value-max=\"10\" data-value-step=\"2\">" ++
    "<g data-layer=\"bars\">" ++
    "<rect x=\"0\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2026Q1\" data-value=\"2\"/>" ++
    "<rect x=\"20\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2026Q2\" data-value=\"4\"/>" ++
    "<rect x=\"40\" y=\"0\" width=\"10\" height=\"1\" data-fiscal-quarter=\"FY2026Q3\" data-value=\"6\"/>" ++
    "</g></svg>\n";

test "trailing mean starts at the first full window" {
    var buf: [8192]u8 = undefined;
    const n = try addRollingMean(SAMPLE, &buf, 2);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "points=\"25,70 45,50\"") != null);
}

test "no line when the window is longer than the series" {
    var buf: [8192]u8 = undefined;
    const n = try addRollingMean(SAMPLE, &buf, 4);
    try std.testing.expectEqualStrings(SAMPLE, buf[0..n]);
    try std.testing.expectError(error.InvalidSVG, addRollingMean(SAMPLE, &buf, 0));
}
