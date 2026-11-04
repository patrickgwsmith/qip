//! Shared reader and writer for the bar-chart SVG subset emitted by
//! `text/csv/fiscal-quarter-csv-to-svg-bars.wasm`.
//!
//! Contract read by the SVG passes:
//! - The root `<svg>` carries `data-plot-left`, `data-plot-top`,
//!   `data-plot-right` and `data-plot-bottom` (pixels), `data-value-min` and
//!   `data-value-max` (the value domain mapped onto the plot's bottom and top
//!   edges), `data-value-step` (the round step both edges are multiples of),
//!   and literal `data-label-prefix` and `data-label-suffix` strings.
//! - The bars live in one `<g data-layer="bars">` group. Each bar is a
//!   self-closing `<rect>` with pixel `x`, `width`, a `data-value` number and a
//!   `data-fiscal-quarter` of the form `FY2026Q4`.
//! Passes insert content before that group (behind the bars) or before the
//! closing `</svg>` (in front of the bars) and copy every other byte.
const std = @import("std");

pub const Error = error{ InvalidSVG, OutputOverflow, TooManyBars };
pub const MAX_BARS = 256;
pub const BARS_GROUP = "<g data-layer=\"bars\"";

pub const Output = struct {
    bytes: []u8,
    pos: usize = 0,
    pub fn append(self: *Output, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.pos) return error.OutputOverflow;
        @memcpy(self.bytes[self.pos..][0..value.len], value);
        self.pos += value.len;
    }
    pub fn number(self: *Output, value: f64) Error!void {
        var buf: [48]u8 = undefined;
        // Pixel coordinates only need two decimal places.
        const rounded = @round(value * 100.0) / 100.0;
        const text = std.fmt.bufPrint(&buf, "{d}", .{if (rounded == 0) 0 else rounded}) catch return error.OutputOverflow;
        try self.append(text);
    }
    /// Writes a packed `0xRRGGBBAA` colour uniform as CSS hex: `#rrggbb` when
    /// opaque, otherwise `#rrggbbaa`.
    pub fn color(self: *Output, rgba: u32) Error!void {
        const digits = "0123456789abcdef";
        var buf: [9]u8 = undefined;
        buf[0] = '#';
        for (0..8) |i| buf[1 + i] = digits[(rgba >> @intCast(28 - 4 * i)) & 0xF];
        try self.append(if (rgba & 0xFF == 0xFF) buf[0..7] else buf[0..9]);
    }
};

pub const Root = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
    value_min: f64,
    value_max: f64,
    value_step: f64,
    label_prefix: []const u8,
    label_suffix: []const u8,

    /// Maps a value onto the plot's vertical pixel axis.
    pub fn y(self: Root, value: f64) f64 {
        return self.bottom - (value - self.value_min) / (self.value_max - self.value_min) * (self.bottom - self.top);
    }
};

pub const Bar = struct {
    x: f64,
    width: f64,
    value: f64,
    /// Fiscal year, for example 2026 for `FY2026Q4`.
    fiscal_year: u16,
    /// Quarter 1 to 4.
    quarter: u8,
};

/// Returns the value of `name="..."` inside `tag`, matching only whole
/// attribute names.
pub fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, name)) |at| {
        from = at + 1;
        if (at == 0 or (tag[at - 1] != ' ' and tag[at - 1] != '\t' and tag[at - 1] != '\n' and tag[at - 1] != '\r')) continue;
        const eq = at + name.len;
        if (eq + 1 >= tag.len or tag[eq] != '=' or tag[eq + 1] != '"') continue;
        const start = eq + 2;
        const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
        return tag[start..end];
    }
    return null;
}

fn numberAttribute(tag: []const u8, name: []const u8) Error!f64 {
    const text = attribute(tag, name) orelse return error.InvalidSVG;
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidSVG;
    if (!std.math.isFinite(value)) return error.InvalidSVG;
    return value;
}

/// Returns the byte range of the root `<svg ...>` start tag.
fn rootTag(input: []const u8) Error![]const u8 {
    const start = std.mem.indexOf(u8, input, "<svg ") orelse return error.InvalidSVG;
    const end = std.mem.indexOfScalarPos(u8, input, start, '>') orelse return error.InvalidSVG;
    return input[start .. end + 1];
}

pub fn readRoot(input: []const u8) Error!Root {
    const tag = try rootTag(input);
    const root = Root{
        .left = try numberAttribute(tag, "data-plot-left"),
        .top = try numberAttribute(tag, "data-plot-top"),
        .right = try numberAttribute(tag, "data-plot-right"),
        .bottom = try numberAttribute(tag, "data-plot-bottom"),
        .value_min = try numberAttribute(tag, "data-value-min"),
        .value_max = try numberAttribute(tag, "data-value-max"),
        .value_step = try numberAttribute(tag, "data-value-step"),
        .label_prefix = attribute(tag, "data-label-prefix") orelse "",
        .label_suffix = attribute(tag, "data-label-suffix") orelse "",
    };
    if (root.right <= root.left or root.bottom <= root.top or root.value_max <= root.value_min or root.value_step <= 0) return error.InvalidSVG;
    return root;
}

pub fn parseFiscalQuarter(text: []const u8) ?struct { year: u16, quarter: u8 } {
    if (text.len != 8 or text[0] != 'F' or text[1] != 'Y' or text[6] != 'Q') return null;
    const year = std.fmt.parseInt(u16, text[2..6], 10) catch return null;
    if (text[7] < '1' or text[7] > '4') return null;
    return .{ .year = year, .quarter = text[7] - '0' };
}

/// Reads every bar rect, in document order, into `bars`.
pub fn readBars(input: []const u8, bars: *[MAX_BARS]Bar) Error![]Bar {
    const group = std.mem.indexOf(u8, input, BARS_GROUP) orelse return error.InvalidSVG;
    const group_end = std.mem.indexOfPos(u8, input, group, "</g>") orelse return error.InvalidSVG;
    var pos = group;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, input[0..group_end], pos, "<rect ")) |start| {
        const end = std.mem.indexOfScalarPos(u8, input, start, '>') orelse return error.InvalidSVG;
        const tag = input[start .. end + 1];
        pos = end + 1;
        const quarter_text = attribute(tag, "data-fiscal-quarter") orelse continue;
        const quarter = parseFiscalQuarter(quarter_text) orelse return error.InvalidSVG;
        if (count == MAX_BARS) return error.TooManyBars;
        bars[count] = .{
            .x = try numberAttribute(tag, "x"),
            .width = try numberAttribute(tag, "width"),
            .value = try numberAttribute(tag, "data-value"),
            .fiscal_year = quarter.year,
            .quarter = quarter.quarter,
        };
        count += 1;
    }
    if (count == 0) return error.InvalidSVG;
    return bars[0..count];
}

/// Returns the offset at which content painted behind the bars is inserted.
pub fn behindBarsOffset(input: []const u8) Error!usize {
    return std.mem.indexOf(u8, input, BARS_GROUP) orelse error.InvalidSVG;
}

/// Returns the offset at which content painted in front of the bars is
/// inserted.
pub fn frontOffset(input: []const u8) Error!usize {
    return std.mem.lastIndexOf(u8, input, "</svg>") orelse error.InvalidSVG;
}

/// Picks a round step (1, 2, 2.5 or 5 times a power of ten) that divides
/// `span` into roughly `intervals` parts.
pub fn niceStep(span: f64, intervals: u32) f64 {
    const raw = span / @as(f64, @floatFromInt(@max(intervals, 1)));
    const magnitude = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const fraction = raw / magnitude;
    const nice: f64 = if (fraction <= 1) 1 else if (fraction <= 2) 2 else if (fraction <= 2.5) 2.5 else if (fraction <= 5) 5 else 10;
    return nice * magnitude;
}

/// Number of decimal places needed to print every multiple of `step` exactly.
pub fn stepDecimals(step: f64) u8 {
    var decimals: u8 = 0;
    var scaled = step;
    while (decimals < 6 and @abs(scaled - @round(scaled)) > 1e-9 * @max(1.0, @abs(scaled))) : (decimals += 1) scaled *= 10;
    return decimals;
}

/// Writes `value` with a fixed number of decimals, avoiding binary floating
/// point noise such as `0.30000000000000004`.
pub fn fixed(out: *Output, value: f64, decimals: u8) Error!void {
    const scale = std.math.pow(f64, 10, @floatFromInt(decimals));
    const scaled: i64 = @intFromFloat(@round(@abs(value) * scale));
    if (value < 0 and scaled != 0) try out.append("-");
    const whole = @divTrunc(scaled, @as(i64, @intFromFloat(scale)));
    var buf: [32]u8 = undefined;
    try out.append(std.fmt.bufPrint(&buf, "{d}", .{whole}) catch return error.OutputOverflow);
    if (decimals == 0) return;
    try out.append(".");
    const frac = @mod(scaled, @as(i64, @intFromFloat(scale)));
    const text = std.fmt.bufPrint(&buf, "{d}", .{frac}) catch return error.OutputOverflow;
    var pad = decimals - @as(u8, @intCast(text.len));
    while (pad > 0) : (pad -= 1) try out.append("0");
    try out.append(text);
}

/// Writes `prefix value suffix`, with a leading minus sign before the prefix
/// for negative values (`-$3B`).
pub fn label(out: *Output, root: Root, value: f64, decimals: u8) Error!void {
    if (value < 0) try out.append("-");
    try out.append(root.label_prefix);
    try fixed(out, @abs(value), decimals);
    try out.append(root.label_suffix);
}

test "attribute matches whole names only" {
    const tag = "<rect data-x=\"1\" x=\"2\" width=\"3\"/>";
    try std.testing.expectEqualStrings("2", attribute(tag, "x").?);
}

test "nice steps" {
    try std.testing.expectEqual(@as(f64, 20), niceStep(100, 5));
    try std.testing.expectEqual(@as(f64, 25), niceStep(100, 4));
    try std.testing.expectEqual(@as(f64, 20), niceStep(90, 5));
    try std.testing.expectEqual(@as(f64, 0.5), niceStep(2.2, 5));
}

test "fixed avoids float noise" {
    var buf: [32]u8 = undefined;
    var out = Output{ .bytes = &buf };
    try fixed(&out, 0.1 + 0.2, stepDecimals(0.1));
    try std.testing.expectEqualStrings("0.3", buf[0..out.pos]);
}

test "colour uniforms print as CSS hex" {
    var buf: [32]u8 = undefined;
    var out = Output{ .bytes = &buf };
    try out.color(0x4e79a7ff);
    try out.append(" ");
    try out.color(0x0000ff80);
    try std.testing.expectEqualStrings("#4e79a7 #0000ff80", buf[0..out.pos]);
}
