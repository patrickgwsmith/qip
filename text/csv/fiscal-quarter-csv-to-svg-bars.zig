//! Renders one value per fiscal quarter as vertical SVG bars.
//!
//! Input is UTF-8 `text/csv` with exactly two columns. The header's first
//! column is `fiscal_quarter`; the second names the series. Each row has a
//! quarter such as `FY2026Q4` and a value such as `102.5`, `$102.5B` or
//! `-$3.2B`. Rows must be consecutive fiscal quarters in order. Any literal
//! text before and after the number is the label format: every row must use
//! the same prefix and suffix, and the SVG records them verbatim in
//! `data-label-prefix` and `data-label-suffix` so axis passes can print
//! `$25B` without unit codes.
//!
//! Output is `image/svg+xml` with only the bars. The root records the plot
//! area (`data-plot-left/top/right/bottom`) and value domain
//! (`data-value-min/max`, rounded out to multiples of a round
//! `data-value-step` and always including zero). Bars are `<rect>` elements in one `<g data-layer="bars">` with
//! `data-fiscal-quarter` and `data-value` attributes; the last bar has its own
//! `fill` so the latest quarter reads as the headline figure.
//!
//! Colour uniforms are packed `0xRRGGBBAA`: `bar_color_rgba` (default
//! `0xa0cbe8ff`) fills every bar and `latest_bar_color_rgba` (default
//! `0x4e79a7ff`) fills the last one. Add axes and overlays with
//! `svg-bars-add-y-axis.wasm`, `svg-bars-add-quarter-x-axis.wasm` and
//! `svg-bars-add-rolling-mean.wasm`.
const std = @import("std");
const bars_svg = @import("svg_bars");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 256 * 1024;
const MAX_ROWS: usize = bars_svg.MAX_BARS;
const MAX_AFFIX: usize = 16;
const INPUT_CONTENT_TYPE = "text/csv";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const PLOT_LEFT = 64;
const PLOT_TOP = 24;
const PLOT_RIGHT = 624;
const PLOT_BOTTOM = 344;
/// Target number of value intervals used to round out the domain.
const DOMAIN_INTERVALS = 5;
const DEFAULT_BAR_COLOR_RGBA: u32 = 0xa0cbe8ff;
const DEFAULT_LATEST_BAR_COLOR_RGBA: u32 = 0x4e79a7ff;

const Colors = struct {
    bar: u32 = DEFAULT_BAR_COLOR_RGBA,
    latest_bar: u32 = DEFAULT_LATEST_BAR_COLOR_RGBA,
};
var colors: Colors = .{};

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;

const Error = error{ InvalidCSV, OutputOverflow, TooManyRows };

const Row = struct {
    quarter: []const u8,
    cell: []const u8,
    value: f64,
};
var rows: [MAX_ROWS]Row = undefined;

const Value = struct { value: f64, prefix: []const u8, suffix: []const u8 };

fn validAffix(text: []const u8) bool {
    if (text.len > MAX_AFFIX) return false;
    for (text) |byte| {
        if (byte < 0x20 or byte == '<' or byte == '>' or byte == '&' or byte == '"' or byte == '\'') return false;
    }
    return true;
}

/// Splits `-$102.5B` into sign and number (`-102.5`), prefix (`$`) and suffix
/// (`B`).
fn parseValue(cell: []const u8) ?Value {
    var pos: usize = 0;
    const negative = cell.len > 0 and cell[0] == '-';
    if (negative) pos = 1;
    const prefix_start = pos;
    while (pos < cell.len and !std.ascii.isDigit(cell[pos]) and cell[pos] != '.') pos += 1;
    const prefix = cell[prefix_start..pos];
    const number_start = pos;
    var digits: usize = 0;
    while (pos < cell.len and std.ascii.isDigit(cell[pos])) : (pos += 1) digits += 1;
    if (pos < cell.len and cell[pos] == '.') {
        pos += 1;
        while (pos < cell.len and std.ascii.isDigit(cell[pos])) : (pos += 1) digits += 1;
    }
    if (digits == 0) return null;
    const magnitude = std.fmt.parseFloat(f64, cell[number_start..pos]) catch return null;
    const suffix = cell[pos..];
    if (suffix.len > 0 and (std.ascii.isDigit(suffix[0]) or suffix[0] == '.')) return null;
    if (!validAffix(prefix) or !validAffix(suffix)) return null;
    return .{ .value = if (negative) -magnitude else magnitude, .prefix = prefix, .suffix = suffix };
}

fn nextLine(bytes: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= bytes.len) return null;
    const start = pos.*;
    while (pos.* < bytes.len and bytes[pos.*] != '\n') pos.* += 1;
    var line = bytes[start..pos.*];
    if (pos.* < bytes.len) pos.* += 1;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

fn split(line: []const u8) ?[2][]const u8 {
    const comma = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    if (std.mem.indexOfScalarPos(u8, line, comma + 1, ',') != null) return null;
    return .{ line[0..comma], line[comma + 1 ..] };
}

const Parsed = struct { count: usize, prefix: []const u8, suffix: []const u8 };

fn parse(bytes: []const u8) Error!Parsed {
    var pos: usize = 0;
    const header = split(nextLine(bytes, &pos) orelse return error.InvalidCSV) orelse return error.InvalidCSV;
    if (!std.mem.eql(u8, header[0], "fiscal_quarter") or header[1].len == 0) return error.InvalidCSV;
    var count: usize = 0;
    var prefix: []const u8 = "";
    var suffix: []const u8 = "";
    var previous: ?u32 = null;
    while (nextLine(bytes, &pos)) |line| {
        if (line.len == 0) continue;
        if (count == MAX_ROWS) return error.TooManyRows;
        const cells = split(line) orelse return error.InvalidCSV;
        const quarter = bars_svg.parseFiscalQuarter(cells[0]) orelse return error.InvalidCSV;
        const ordinal = @as(u32, quarter.year) * 4 + quarter.quarter - 1;
        if (previous) |p| if (ordinal != p + 1) return error.InvalidCSV;
        previous = ordinal;
        const value = parseValue(cells[1]) orelse return error.InvalidCSV;
        if (count == 0) {
            prefix = value.prefix;
            suffix = value.suffix;
        } else if (!std.mem.eql(u8, prefix, value.prefix) or !std.mem.eql(u8, suffix, value.suffix)) {
            return error.InvalidCSV;
        }
        rows[count] = .{ .quarter = cells[0], .cell = cells[1], .value = value.value };
        count += 1;
    }
    if (count == 0) return error.InvalidCSV;
    return .{ .count = count, .prefix = prefix, .suffix = suffix };
}

fn renderSVG(bytes: []const u8, palette: Colors) !usize {
    const parsed = try parse(bytes);
    var min_value: f64 = 0;
    var max_value: f64 = 0;
    for (rows[0..parsed.count]) |row| {
        min_value = @min(min_value, row.value);
        max_value = @max(max_value, row.value);
    }
    if (min_value == max_value) max_value = 1;
    const step = bars_svg.niceStep(max_value - min_value, DOMAIN_INTERVALS);
    max_value = @ceil(max_value / step - 1e-9) * step;
    min_value = @floor(min_value / step + 1e-9) * step;

    const root = bars_svg.Root{
        .left = PLOT_LEFT,
        .top = PLOT_TOP,
        .right = PLOT_RIGHT,
        .bottom = PLOT_BOTTOM,
        .value_min = min_value,
        .value_max = max_value,
        .value_step = step,
        .label_prefix = parsed.prefix,
        .label_suffix = parsed.suffix,
    };
    const decimals = bars_svg.stepDecimals(step);
    var out = bars_svg.Output{ .bytes = &output };
    try out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"640\" height=\"400\" viewBox=\"0 0 640 400\" font-family=\"system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif\" font-variant-numeric=\"tabular-nums\" data-plot-left=\"");
    try out.number(PLOT_LEFT);
    try out.append("\" data-plot-top=\"");
    try out.number(PLOT_TOP);
    try out.append("\" data-plot-right=\"");
    try out.number(PLOT_RIGHT);
    try out.append("\" data-plot-bottom=\"");
    try out.number(PLOT_BOTTOM);
    try out.append("\" data-value-min=\"");
    try bars_svg.fixed(&out, min_value, decimals);
    try out.append("\" data-value-max=\"");
    try bars_svg.fixed(&out, max_value, decimals);
    try out.append("\" data-value-step=\"");
    try bars_svg.fixed(&out, step, decimals);
    try out.append("\" data-label-prefix=\"");
    try out.append(parsed.prefix);
    try out.append("\" data-label-suffix=\"");
    try out.append(parsed.suffix);
    try out.append("\"><rect width=\"640\" height=\"400\" fill=\"white\"/><g data-layer=\"bars\" fill=\"");
    try out.color(palette.bar);
    try out.append("\">");

    const slot = @as(f64, PLOT_RIGHT - PLOT_LEFT) / @as(f64, @floatFromInt(parsed.count));
    const zero_y = root.y(0);
    for (rows[0..parsed.count], 0..) |row, i| {
        const value_y = root.y(row.value);
        try out.append("<rect x=\"");
        try out.number(PLOT_LEFT + slot * @as(f64, @floatFromInt(i)) + slot * 0.15);
        try out.append("\" y=\"");
        try out.number(@min(value_y, zero_y));
        try out.append("\" width=\"");
        try out.number(slot * 0.7);
        try out.append("\" height=\"");
        try out.number(@abs(zero_y - value_y));
        try out.append("\" data-fiscal-quarter=\"");
        try out.append(row.quarter);
        if (i + 1 == parsed.count) {
            try out.append("\" fill=\"");
            try out.color(palette.latest_bar);
        }
        try out.append("\" data-value=\"");
        var buf: [48]u8 = undefined;
        try out.append(std.fmt.bufPrint(&buf, "{d}", .{row.value}) catch return error.OutputOverflow);
        try out.append("\"><title>");
        try out.append(row.quarter);
        try out.append(": ");
        try out.append(row.cell);
        try out.append("</title></rect>");
    }
    try out.append("</g></svg>\n");
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
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}
export fn uniform_set_bar_color_rgba(value: u32) u32 {
    colors.bar = value;
    return value;
}
export fn uniform_set_latest_bar_color_rgba(value: u32) u32 {
    colors.latest_bar = value;
    return value;
}
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const palette = colors;
    colors = .{};
    const out_n = renderSVG(input[0..n], palette) catch return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}

fn rendered(csv: []const u8) ![]const u8 {
    const n = try renderSVG(csv, .{});
    return output[0..n];
}

test "renders bars with label format and rounded domain" {
    const svg = try rendered("fiscal_quarter,revenue\nFY2026Q3,$94B\nFY2026Q4,$102.5B\nFY2027Q1,$90B\n");
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-label-prefix=\"$\" data-label-suffix=\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-value-min=\"0\" data-value-max=\"125\" data-value-step=\"25\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-fiscal-quarter=\"FY2026Q4\" data-value=\"102.5\"") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, svg, "<rect x="));
    try std.testing.expect(std.mem.indexOf(u8, svg, "<g data-layer=\"bars\" fill=\"#a0cbe8\">") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, "fill=\"#4e79a7\""));
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-fiscal-quarter=\"FY2027Q1\" fill=\"#4e79a7\"") != null);
}

test "colour uniforms replace the default palette" {
    const n = try renderSVG("fiscal_quarter,v\nFY2026Q1,1\nFY2026Q2,2\n", .{ .bar = 0xccccccff, .latest_bar = 0x11223380 });
    const svg = output[0..n];
    try std.testing.expect(std.mem.indexOf(u8, svg, "<g data-layer=\"bars\" fill=\"#cccccc\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-fiscal-quarter=\"FY2026Q2\" fill=\"#11223380\"") != null);
}

test "plain numbers and negative values" {
    const svg = try rendered("fiscal_quarter,income\r\nFY2026Q1,-3\r\nFY2026Q2,7\r\n");
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-label-prefix=\"\" data-label-suffix=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-value-min=\"-4\" data-value-max=\"8\" data-value-step=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "data-value=\"-3\"") != null);
}

test "rejects gaps, mixed formats and markup in affixes" {
    try std.testing.expectError(error.InvalidCSV, renderSVG("fiscal_quarter,v\nFY2026Q1,1\nFY2026Q3,2\n", .{}));
    try std.testing.expectError(error.InvalidCSV, renderSVG("fiscal_quarter,v\nFY2026Q1,$1B\nFY2026Q2,$2M\n", .{}));
    try std.testing.expectError(error.InvalidCSV, renderSVG("fiscal_quarter,v\nFY2026Q1,<b>1\n", .{}));
    try std.testing.expectError(error.InvalidCSV, renderSVG("date,v\nFY2026Q1,1\n", .{}));
}
