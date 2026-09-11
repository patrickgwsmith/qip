const std = @import("std");

pub const Kind = enum { exponential_moving_average, rolling_mean };
pub const Error = error{ InvalidSVG, OutputOverflow, TooManyPoints };
const MAX_POINTS = 2048;

const Output = struct {
    bytes: []u8,
    pos: usize = 0,
    fn append(self: *Output, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.pos) return error.OutputOverflow;
        @memcpy(self.bytes[self.pos..][0..value.len], value);
        self.pos += value.len;
    }
    fn number(self: *Output, value: f64) Error!void {
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutputOverflow;
        try self.append(text);
    }
};

fn isNameBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '>' or byte == '/';
}
fn skipSpace(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t' or input[pos.*] == '\n' or input[pos.*] == '\r' or input[pos.*] == ',')) pos.* += 1;
}
fn number(input: []const u8, pos: *usize) ?f64 {
    skipSpace(input, pos);
    const start = pos.*;
    if (pos.* < input.len and (input[pos.*] == '-' or input[pos.*] == '+')) pos.* += 1;
    var digits: usize = 0;
    while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') : (pos.* += 1) digits += 1;
    if (pos.* < input.len and input[pos.*] == '.') {
        pos.* += 1;
        while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') : (pos.* += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (pos.* < input.len and (input[pos.*] == 'e' or input[pos.*] == 'E')) {
        pos.* += 1;
        if (pos.* < input.len and (input[pos.*] == '-' or input[pos.*] == '+')) pos.* += 1;
        const exponent_start = pos.*;
        while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') : (pos.* += 1) {}
        if (pos.* == exponent_start) return null;
    }
    return std.fmt.parseFloat(f64, input[start..pos.*]) catch null;
}

fn writePoints(out: *Output, points: []const u8, kind: Kind, window: usize) Error!void {
    var xs: [MAX_POINTS]f64 = undefined;
    var ys: [MAX_POINTS]f64 = undefined;
    var pos: usize = 0;
    var count: usize = 0;
    while (true) {
        skipSpace(points, &pos);
        if (pos == points.len) break;
        if (count == MAX_POINTS) return error.TooManyPoints;
        xs[count] = number(points, &pos) orelse return error.InvalidSVG;
        ys[count] = number(points, &pos) orelse return error.InvalidSVG;
        if (!std.math.isFinite(xs[count]) or !std.math.isFinite(ys[count])) return error.InvalidSVG;
        count += 1;
    }
    if (count < 2) return error.InvalidSVG;
    var ema: f64 = ys[0];
    const alpha = 2.0 / (@as(f64, @floatFromInt(window)) + 1.0);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const y = switch (kind) {
            .exponential_moving_average => blk: {
                if (i != 0) ema = alpha * ys[i] + (1.0 - alpha) * ema;
                break :blk ema;
            },
            .rolling_mean => blk: {
                const first = if (i + 1 > window) i + 1 - window else 0;
                var total: f64 = 0;
                var j = first;
                while (j <= i) : (j += 1) total += ys[j];
                break :blk total / @as(f64, @floatFromInt(i + 1 - first));
            },
        };
        if (i != 0) try out.append(" ");
        try out.number(xs[i]);
        try out.append(",");
        try out.number(y);
    }
}

fn quotedAttribute(tag: []const u8, name: []const u8) ?[]const u8 {
    const attribute = std.mem.indexOf(u8, tag, name) orelse return null;
    const value_start = attribute + name.len;
    if (value_start >= tag.len or (tag[value_start] != '"' and tag[value_start] != '\'')) return null;
    const quote = tag[value_start];
    const content_start = value_start + 1;
    const content_end = std.mem.indexOfScalarPos(u8, tag, content_start, quote) orelse return null;
    return tag[content_start..content_end];
}

fn writeMeanLine(out: *Output, points: []const u8, stroke: []const u8) Error!void {
    var pos: usize = 0;
    var first_x: f64 = undefined;
    var last_x: f64 = undefined;
    var total: f64 = 0;
    var count: usize = 0;
    while (true) {
        skipSpace(points, &pos);
        if (pos == points.len) break;
        if (count == MAX_POINTS) return error.TooManyPoints;
        const x = number(points, &pos) orelse return error.InvalidSVG;
        const y = number(points, &pos) orelse return error.InvalidSVG;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidSVG;
        if (count == 0) first_x = x;
        last_x = x;
        total += y;
        count += 1;
    }
    if (count < 2) return error.InvalidSVG;
    const mean = total / @as(f64, @floatFromInt(count));
    try out.append("<polyline points=\"");
    try out.number(first_x);
    try out.append(",");
    try out.number(mean);
    try out.append(" ");
    try out.number(last_x);
    try out.append(",");
    try out.number(mean);
    try out.append("\" fill=\"none\" stroke=\"");
    try out.append(stroke);
    try out.append("\" stroke-width=\"2\" stroke-dasharray=\"4 4\" vector-effect=\"non-scaling-stroke\"/>");
}

/// Rewrites every SVG polyline. The input is the strict chart SVG subset: each
/// data line is a polyline with a quoted points attribute. All other SVG bytes
/// remain unchanged.
pub fn smooth(input: []const u8, destination: []u8, kind: Kind, window: usize) Error!usize {
    if (window == 0) return error.InvalidSVG;
    var out = Output{ .bytes = destination };
    var pos: usize = 0;
    var found = false;
    while (pos < input.len) {
        const tag_start = std.mem.indexOfPos(u8, input, pos, "<polyline") orelse {
            try out.append(input[pos..]);
            break;
        };
        const after_name = tag_start + "<polyline".len;
        if (after_name >= input.len or !isNameBoundary(input[after_name])) {
            try out.append(input[pos..after_name]);
            pos = after_name;
            continue;
        }
        const tag_end = std.mem.indexOfScalarPos(u8, input, after_name, '>') orelse return error.InvalidSVG;
        const tag = input[tag_start .. tag_end + 1];
        const points_name = std.mem.indexOf(u8, tag, "points=") orelse return error.InvalidSVG;
        const quote_at = points_name + "points=".len;
        if (quote_at >= tag.len or (tag[quote_at] != '"' and tag[quote_at] != '\'')) return error.InvalidSVG;
        const quote = tag[quote_at];
        const points_start = quote_at + 1;
        const points_end = std.mem.indexOfScalarPos(u8, tag, points_start, quote) orelse return error.InvalidSVG;
        try out.append(input[pos .. tag_start + points_start]);
        try writePoints(&out, tag[points_start..points_end], kind, window);
        try out.append(tag[points_end..]);
        pos = tag_end + 1;
        found = true;
    }
    if (!found) return error.InvalidSVG;
    return out.pos;
}

/// Appends a horizontal dashed mean line after every SVG polyline. The input
/// is the strict chart SVG subset: each source line has quoted `points` and
/// `stroke` attributes. All existing SVG bytes remain unchanged.
pub fn addMeanLines(input: []const u8, destination: []u8) Error!usize {
    var out = Output{ .bytes = destination };
    var pos: usize = 0;
    var found = false;
    while (pos < input.len) {
        const tag_start = std.mem.indexOfPos(u8, input, pos, "<polyline") orelse {
            try out.append(input[pos..]);
            break;
        };
        const after_name = tag_start + "<polyline".len;
        if (after_name >= input.len or !isNameBoundary(input[after_name])) {
            try out.append(input[pos..after_name]);
            pos = after_name;
            continue;
        }
        const tag_end = std.mem.indexOfScalarPos(u8, input, after_name, '>') orelse return error.InvalidSVG;
        const tag = input[tag_start .. tag_end + 1];
        const points = quotedAttribute(tag, "points=") orelse return error.InvalidSVG;
        const stroke = quotedAttribute(tag, "stroke=") orelse return error.InvalidSVG;
        try out.append(input[pos .. tag_end + 1]);
        try writeMeanLine(&out, points, stroke);
        pos = tag_end + 1;
        found = true;
    }
    if (!found) return error.InvalidSVG;
    return out.pos;
}
