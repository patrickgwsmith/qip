//! Renders a strict time-series CSV table as vector SVG polylines.
//!
//! Input is UTF-8 `text/csv` with a `date` first column (`YYYY-MM-DD`) or a
//! `timestamp` first column (an RFC 3339 UTC instant), followed by one or more
//! named numeric series columns. Rows must be chronological and complete.
//! Output is `image/svg+xml`: one raw-value-space `polyline` per series in a
//! transformed `g`; axes use `path`, never `polyline`. Each data stroke uses
//! `vector-effect="non-scaling-stroke"` so conforming SVG renderers keep it at
//! two pixels. The y domain includes zero by default and labels its endpoints.
//! `x_axis_tick_year_interval=N` adds a tick and year label at the first sample
//! in every Nth calendar year; zero disables x-axis ticks. SVG polyline
//! transforms can therefore operate on raw y values.
const std = @import("std");
const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 256 * 1024;
const MAX_ROWS: usize = 512;
const MAX_SERIES: usize = 8;
const INPUT_CONTENT_TYPE = "text/csv";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";
var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var dates: [MAX_ROWS]f64 = undefined;
var years: [MAX_ROWS]i64 = undefined;
var values: [MAX_SERIES][MAX_ROWS]f64 = undefined;
var x_axis_tick_year_interval: u32 = 0;
const Error = error{ InvalidCSV, OutputOverflow, TooManyRows, TooManySeries };
const Writer = struct {
    bytes: []u8,
    pos: usize = 0,
    fn append(self: *Writer, text: []const u8) Error!void {
        if (text.len > self.bytes.len - self.pos) return error.OutputOverflow;
        @memcpy(self.bytes[self.pos..][0..text.len], text);
        self.pos += text.len;
    }
    fn number(self: *Writer, value: f64) Error!void {
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutputOverflow;
        try self.append(text);
    }
};
fn lineAt(bytes: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* == bytes.len) return null;
    const start = pos.*;
    while (pos.* < bytes.len and bytes[pos.*] != '\n') pos.* += 1;
    const line = bytes[start..pos.*];
    if (pos.* < bytes.len) pos.* += 1;
    return line;
}
fn fields(line: []const u8, result: *[MAX_SERIES + 1][]const u8) Error!usize {
    var start: usize = 0;
    var n: usize = 0;
    while (true) {
        if (n == result.len) return error.TooManySeries;
        const comma = std.mem.indexOfScalarPos(u8, line, start, ',');
        result[n] = line[start .. comma orelse line.len];
        n += 1;
        if (comma) |at| {
            start = at + 1;
        } else break;
    }
    return n;
}
fn parseDate(value: []const u8) ?f64 {
    if (value.len < 10 or value[4] != '-' or value[7] != '-') return null;
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, value[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, value[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    const adjusted_year = year - (if (month <= 2) @as(i64, 1) else @as(i64, 0));
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const day_of_year = @divFloor(153 * (month + (if (month > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    const whole_days: f64 = @floatFromInt(era * 146097 + day_of_era - 719468);
    if (value.len == 10) return whole_days;
    if (value.len != 20 or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return null;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    if (hour > 23 or minute > 59 or second > 59) return null;
    return whole_days + (@as(f64, @floatFromInt(hour)) * 3600.0 + @as(f64, @floatFromInt(minute)) * 60.0 + @as(f64, @floatFromInt(second))) / 86400.0;
}
fn parse(input_bytes: []const u8) Error!struct { rows: usize, series: usize } {
    var pos: usize = 0;
    const header = lineAt(input_bytes, &pos) orelse return error.InvalidCSV;
    var cells: [MAX_SERIES + 1][]const u8 = undefined;
    const series_plus_date = try fields(header, &cells);
    if (series_plus_date < 2 or (!std.mem.eql(u8, cells[0], "date") and !std.mem.eql(u8, cells[0], "timestamp"))) return error.InvalidCSV;
    const series = series_plus_date - 1;
    var rows: usize = 0;
    var previous_date: f64 = -std.math.inf(f64);
    while (lineAt(input_bytes, &pos)) |line| {
        if (line.len == 0) continue;
        if (rows == MAX_ROWS) return error.TooManyRows;
        var row_cells: [MAX_SERIES + 1][]const u8 = undefined;
        if (try fields(line, &row_cells) != series_plus_date) return error.InvalidCSV;
        const date = parseDate(row_cells[0]) orelse return error.InvalidCSV;
        if (date <= previous_date) return error.InvalidCSV;
        previous_date = date;
        dates[rows] = date;
        years[rows] = std.fmt.parseInt(i64, row_cells[0][0..4], 10) catch return error.InvalidCSV;
        var column: usize = 0;
        while (column < series) : (column += 1) {
            const value = std.fmt.parseFloat(f64, row_cells[column + 1]) catch return error.InvalidCSV;
            if (!std.math.isFinite(value)) return error.InvalidCSV;
            values[column][rows] = value;
        }
        rows += 1;
    }
    if (rows < 2) return error.InvalidCSV;
    return .{ .rows = rows, .series = series };
}
fn renderSVG(input_bytes: []const u8) Error!usize {
    const parsed = try parse(input_bytes);
    var min_y: f64 = 0;
    var max_y: f64 = 0;
    var s: usize = 0;
    while (s < parsed.series) : (s += 1) {
        var r: usize = 0;
        while (r < parsed.rows) : (r += 1) {
            min_y = @min(min_y, values[s][r]);
            max_y = @max(max_y, values[s][r]);
        }
    }
    if (min_y == max_y) {
        if (min_y == 0) {
            max_y = 1;
        } else if (min_y > 0) {
            min_y = 0;
        } else {
            max_y = 0;
        }
    }
    const x_span = dates[parsed.rows - 1] - dates[0];
    if (x_span <= 0) return error.InvalidCSV;
    const scale_x = 560.0 / x_span;
    const scale_y = 320.0 / (max_y - min_y);
    const colors = [_][]const u8{ "#2563eb", "#dc2626", "#16a34a", "#9333ea", "#ea580c", "#0891b2", "#be123c", "#4f46e5" };
    var out = Writer{ .bytes = &output };
    try out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"640\" height=\"400\" viewBox=\"0 0 640 400\" font-family=\"sans-serif\"><rect width=\"640\" height=\"400\" fill=\"white\"/><path d=\"M 56 24 V 360 H 616 M 52 24 H 56 M 52 360 H 56\" fill=\"none\" stroke=\"#475569\" stroke-width=\"1\"/><text x=\"48\" y=\"29\" text-anchor=\"end\" font-size=\"12\" fill=\"#475569\">");
    try out.number(max_y);
    try out.append("</text><text x=\"48\" y=\"364\" text-anchor=\"end\" font-size=\"12\" fill=\"#475569\">");
    try out.number(min_y);
    try out.append("</text>");
    if (x_axis_tick_year_interval != 0) {
        var previous_year: ?i64 = null;
        var r: usize = 0;
        while (r < parsed.rows) : (r += 1) {
            if (previous_year != null and previous_year.? == years[r]) continue;
            previous_year = years[r];
            const years_since_first = years[r] - years[0];
            if (@mod(years_since_first, @as(i64, @intCast(x_axis_tick_year_interval))) != 0) continue;
            const x = 56.0 + scale_x * (dates[r] - dates[0]);
            try out.append("<path d=\"M ");
            try out.number(x);
            try out.append(" 360 V 364\" fill=\"none\" stroke=\"#475569\" stroke-width=\"1\"/><text x=\"");
            try out.number(x);
            try out.append("\" y=\"378\" text-anchor=\"middle\" font-size=\"12\" fill=\"#475569\">");
            try out.number(@floatFromInt(years[r]));
            try out.append("</text>");
        }
    }
    try out.append("<g transform=\"translate(56 ");
    try out.number(360.0 + scale_y * min_y);
    try out.append(") scale(");
    try out.number(scale_x);
    try out.append(" -");
    try out.number(scale_y);
    try out.append(")\">");
    s = 0;
    while (s < parsed.series) : (s += 1) {
        try out.append("<polyline points=\"");
        var r: usize = 0;
        while (r < parsed.rows) : (r += 1) {
            if (r != 0) try out.append(" ");
            try out.number(dates[r] - dates[0]);
            try out.append(",");
            try out.number(values[s][r]);
        }
        try out.append("\" fill=\"none\" stroke=\"");
        try out.append(colors[s]);
        try out.append("\" stroke-width=\"");
        try out.append("2");
        try out.append("\" vector-effect=\"non-scaling-stroke\"/>");
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
export fn uniform_set_x_axis_tick_year_interval(value: u32) u32 {
    x_axis_tick_year_interval = value;
    return x_axis_tick_year_interval;
}
export fn render(size: u32) packed struct(u64) { output_size_or_failure: u32, output_ptr: u31, failed: u1 } {
    const n: usize = size;
    if (n > INPUT_CAP) @trap();
    const out_n = renderSVG(input[0..n]) catch {
        x_axis_tick_year_interval = 0;
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    x_axis_tick_year_interval = 0;
    return .{ .output_size_or_failure = @intCast(out_n), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
test "renders two series in one value-space group" {
    const svg_len = try renderSVG("date,one,two\n2026-01-01,2,4\n2026-01-03,4,2\n");
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], "<polyline") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], "font-family=\"sans-serif\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], "vector-effect=\"non-scaling-stroke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], ">0</text>") != null);
}

test "keeps RFC 3339 UTC timestamps on the time scale" {
    const svg_len = try renderSVG("timestamp,value\n2026-01-01T00:00:00Z,2\n2026-01-01T12:00:00Z,4\n");
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], "0,2 0.5,4") != null);
}

test "year ticks label the first sample at the configured interval" {
    x_axis_tick_year_interval = 2;
    defer x_axis_tick_year_interval = 0;
    const svg_len = try renderSVG("date,value\n2025-06-30,2\n2026-02-01,4\n2027-06-30,6\n");
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], ">2025</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], ">2026</text>") == null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..svg_len], ">2027</text>") != null);
}
