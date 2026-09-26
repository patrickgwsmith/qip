//! Renders categorical, grouped horizontal bars from `name,group,value` CSV.
//!
//! Each row is one bar. Names and groups appear in first-seen order. Values
//! must be finite and nonnegative; duplicate name/group pairs are rejected.
//! Quoted fields may contain commas and escaped quotes. The SVG uses a zero
//! baseline and leaves the unit and chart title to the embedding document.
const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 128 * 1024;
const MAX_NAMES: usize = 32;
const MAX_GROUPS: usize = 8;
const MAX_ROWS: usize = MAX_NAMES * MAX_GROUPS;
const MAX_FIELD: usize = 64;
const INPUT_TYPE = "text/csv";
const OUTPUT_TYPE = "image/svg+xml";
const Error = error{ InvalidCSV, TooManyRows, TooManyNames, TooManyGroups, OutputOverflow };

const Label = struct {
    bytes: [MAX_FIELD]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *Label, bytes: []const u8) void {
        @memcpy(self.bytes[0..bytes.len], bytes);
        self.len = @intCast(bytes.len);
    }
};

const Cell = struct {
    present: bool = false,
    value: f64 = 0,
    text: Label = .{},
};

const Table = struct {
    names: [MAX_NAMES]Label = undefined,
    groups: [MAX_GROUPS]Label = undefined,
    cells: [MAX_NAMES][MAX_GROUPS]Cell = undefined,
    name_count: usize = 0,
    group_count: usize = 0,
    row_count: usize = 0,
    max_value: f64 = 0,
    max_text: Label = .{},

    fn init(self: *Table) void {
        self.name_count = 0;
        self.group_count = 0;
        self.row_count = 0;
        self.max_value = 0;
        self.max_text = .{};
        for (&self.cells) |*row| {
            for (row) |*cell| cell.present = false;
        }
    }

    fn indexOf(labels: []const Label, value: []const u8) ?usize {
        for (labels, 0..) |label, i| {
            if (std.mem.eql(u8, label.slice(), value)) return i;
        }
        return null;
    }

    fn addName(self: *Table, value: []const u8) Error!usize {
        if (indexOf(self.names[0..self.name_count], value)) |i| return i;
        if (self.name_count == MAX_NAMES) return error.TooManyNames;
        const i = self.name_count;
        self.names[i].set(value);
        self.name_count += 1;
        return i;
    }

    fn addGroup(self: *Table, value: []const u8) Error!usize {
        if (indexOf(self.groups[0..self.group_count], value)) |i| return i;
        if (self.group_count == MAX_GROUPS) return error.TooManyGroups;
        const i = self.group_count;
        self.groups[i].set(value);
        self.group_count += 1;
        return i;
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(self: *Reader, fields: *[3]Label) Error!bool {
        if (self.pos == self.bytes.len) return false;
        for (fields, 0..) |*field, col| {
            field.len = 0;
            if (self.pos < self.bytes.len and self.bytes[self.pos] == '"') {
                self.pos += 1;
                var closed = false;
                while (self.pos < self.bytes.len) {
                    const byte = self.bytes[self.pos];
                    if (byte == '"') {
                        self.pos += 1;
                        if (self.pos < self.bytes.len and self.bytes[self.pos] == '"') {
                            try push(field, '"');
                            self.pos += 1;
                        } else {
                            closed = true;
                            break;
                        }
                    } else {
                        if (byte < 0x20 or byte == 0x7f) return error.InvalidCSV;
                        try push(field, byte);
                        self.pos += 1;
                    }
                }
                if (!closed) return error.InvalidCSV;
            } else {
                while (self.pos < self.bytes.len) {
                    const byte = self.bytes[self.pos];
                    if (byte == ',' or byte == '\r' or byte == '\n') break;
                    if (byte == '"' or byte < 0x20 or byte == 0x7f) return error.InvalidCSV;
                    try push(field, byte);
                    self.pos += 1;
                }
            }
            if (col < 2) {
                if (self.pos == self.bytes.len or self.bytes[self.pos] != ',') return error.InvalidCSV;
                self.pos += 1;
            } else if (self.pos < self.bytes.len) {
                if (self.bytes[self.pos] == '\r') {
                    self.pos += 1;
                    if (self.pos == self.bytes.len or self.bytes[self.pos] != '\n') return error.InvalidCSV;
                } else if (self.bytes[self.pos] != '\n') return error.InvalidCSV;
                self.pos += 1;
            }
        }
        return true;
    }

    fn push(field: *Label, byte: u8) Error!void {
        if (field.len == MAX_FIELD) return error.InvalidCSV;
        field.bytes[field.len] = byte;
        field.len += 1;
    }
};

const Writer = struct {
    bytes: []u8,
    pos: usize = 0,

    fn append(self: *Writer, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.pos) return error.OutputOverflow;
        @memcpy(self.bytes[self.pos..][0..value.len], value);
        self.pos += value.len;
    }

    fn number(self: *Writer, value: usize) Error!void {
        var buffer: [24]u8 = undefined;
        const value_text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutputOverflow;
        try self.append(value_text);
    }

    fn xml(self: *Writer, value: []const u8) Error!void {
        for (value) |byte| {
            switch (byte) {
                '&' => try self.append("&amp;"),
                '<' => try self.append("&lt;"),
                '>' => try self.append("&gt;"),
                '"' => try self.append("&quot;"),
                '\'' => try self.append("&apos;"),
                else => try self.append(&.{byte}),
            }
        }
    }
};

var input: [INPUT_CAP]u8 = undefined;
var output: [OUTPUT_CAP]u8 = undefined;
var table: Table = undefined;

fn parse(csv: []const u8, result: *Table) Error!void {
    result.init();
    var reader = Reader{ .bytes = csv };
    var fields: [3]Label = .{ .{}, .{}, .{} };
    if (!try reader.next(&fields)) return error.InvalidCSV;
    var name_col: ?usize = null;
    var group_col: ?usize = null;
    var value_col: ?usize = null;
    for (&fields, 0..) |*field, i| {
        const header = field.slice();
        if (std.mem.eql(u8, header, "name")) {
            if (name_col != null) return error.InvalidCSV;
            name_col = i;
        } else if (std.mem.eql(u8, header, "group")) {
            if (group_col != null) return error.InvalidCSV;
            group_col = i;
        } else if (std.mem.eql(u8, header, "value")) {
            if (value_col != null) return error.InvalidCSV;
            value_col = i;
        } else return error.InvalidCSV;
    }
    const nc = name_col orelse return error.InvalidCSV;
    const gc = group_col orelse return error.InvalidCSV;
    const vc = value_col orelse return error.InvalidCSV;
    while (try reader.next(&fields)) {
        if (result.row_count == MAX_ROWS) return error.TooManyRows;
        const name = fields[nc].slice();
        const group = fields[gc].slice();
        const number_text = fields[vc].slice();
        if (name.len == 0 or group.len == 0 or number_text.len == 0) return error.InvalidCSV;
        const value = std.fmt.parseFloat(f64, number_text) catch return error.InvalidCSV;
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCSV;
        const ni = try result.addName(name);
        const gi = try result.addGroup(group);
        const cell = &result.cells[ni][gi];
        if (cell.present) return error.InvalidCSV;
        cell.present = true;
        cell.value = value;
        cell.text.set(number_text);
        if (result.row_count == 0 or value > result.max_value) {
            result.max_value = value;
            result.max_text.set(number_text);
        }
        result.row_count += 1;
    }
    if (result.row_count == 0) return error.InvalidCSV;
}

fn renderSVG(csv: []const u8, svg: []u8) Error!usize {
    try parse(csv, &table);
    const colors = [_][]const u8{ "#2563eb", "#dc2626", "#16a34a", "#9333ea", "#ea580c", "#0891b2", "#be123c", "#4f46e5" };
    const x0: usize = 300;
    const chart_width: usize = 700;
    const top: usize = 48 + 24 * table.group_count;
    const category_height: usize = 16 + 22 * table.group_count;
    const height: usize = top + category_height * table.name_count + 40;
    var out = Writer{ .bytes = svg };
    try out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"");
    try out.number(height);
    try out.append("\" viewBox=\"0 0 1200 ");
    try out.number(height);
    try out.append("\" role=\"img\"><title>Grouped bar chart</title><rect width=\"1200\" height=\"");
    try out.number(height);
    try out.append("\" fill=\"white\"/>");

    for (0..table.group_count) |gi| {
        try out.append("<rect x=\"300\" y=\"");
        try out.number(12 + 24 * gi);
        try out.append("\" width=\"12\" height=\"12\" fill=\"");
        try out.append(colors[gi]);
        try out.append("\"/><text x=\"320\" y=\"");
        try out.number(23 + 24 * gi);
        try out.append("\" font-size=\"13\" font-family=\"sans-serif\" fill=\"#111827\">");
        try out.xml(table.groups[gi].slice());
        try out.append("</text>");
    }

    try out.append("<path d=\"M 300 ");
    try out.number(top - 8);
    try out.append(" V ");
    try out.number(height - 25);
    try out.append(" H 1000\" fill=\"none\" stroke=\"#64748b\"/><text x=\"300\" y=\"");
    try out.number(height - 7);
    try out.append("\" text-anchor=\"middle\" font-size=\"12\" font-family=\"sans-serif\">0</text><text x=\"1000\" y=\"");
    try out.number(height - 7);
    try out.append("\" text-anchor=\"middle\" font-size=\"12\" font-family=\"sans-serif\">");
    try out.xml(table.max_text.slice());
    try out.append("</text>");

    for (0..table.name_count) |ni| {
        const row_top = top + ni * category_height;
        try out.append("<text x=\"282\" y=\"");
        try out.number(row_top + table.group_count * 11);
        try out.append("\" text-anchor=\"end\" font-size=\"13\" font-family=\"sans-serif\" fill=\"#111827\">");
        try out.xml(table.names[ni].slice());
        try out.append("</text>");
        for (0..table.group_count) |gi| {
            const cell = &table.cells[ni][gi];
            if (!cell.present) continue;
            const y = row_top + gi * 22;
            const bar_width: usize = if (table.max_value == 0) 0 else @intFromFloat(@round(cell.value / table.max_value * @as(f64, @floatFromInt(chart_width))));
            try out.append("<rect x=\"300\" y=\"");
            try out.number(y);
            try out.append("\" width=\"");
            try out.number(bar_width);
            try out.append("\" height=\"16\" fill=\"");
            try out.append(colors[gi]);
            try out.append("\"/><text x=\"");
            try out.number(x0 + bar_width + 6);
            try out.append("\" y=\"");
            try out.number(y + 13);
            try out.append("\" font-size=\"12\" font-family=\"sans-serif\" fill=\"#334155\">");
            try out.xml(cell.text.slice());
            try out.append("</text>");
        }
    }
    try out.append("</svg>\n");
    return out.pos;
}

export fn input_ptr() u32 { return @intCast(@intFromPtr(&input)); }
export fn input_utf8_cap() u32 { return INPUT_CAP; }
export fn output_utf8_cap() u32 { return OUTPUT_CAP; }
export fn failure_modes_per_input_offset() u32 { return 0; }
export fn input_content_type_ptr() u32 { return @intCast(@intFromPtr(INPUT_TYPE.ptr)); }
export fn input_content_type_size() u32 { return INPUT_TYPE.len; }
export fn output_content_type_ptr() u32 { return @intCast(@intFromPtr(OUTPUT_TYPE.ptr)); }
export fn output_content_type_size() u32 { return OUTPUT_TYPE.len; }

export fn render(size: u32) packed struct(u64) { length_or_failure: u32, output_ptr: u31, failed: u1 } {
    if (size > INPUT_CAP) @trap();
    const length = renderSVG(input[0..size], &output) catch {
        return .{ .length_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{ .length_or_failure = @intCast(length), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}

test "renders grouped bars and escapes quoted CSV labels" {
    var svg: [8192]u8 = undefined;
    const csv = "value,group,name\r\n132.4,Scalar,\"WAT & <C>\"\r\n16.7,SIMD,\"WAT & <C>\"\r\n22,\"SIMD, fast\",Zig\r\n";
    const length = try renderSVG(csv, &svg);
    const result = svg[0..length];
    try std.testing.expect(std.mem.indexOf(u8, result, "WAT &amp; &lt;C&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "SIMD, fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<rect x=\"300\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ">132.4</text>") != null);
}

test "rejects duplicate pairs, invalid values, and malformed CSV" {
    var svg: [8192]u8 = undefined;
    try std.testing.expectError(error.InvalidCSV, renderSVG("name,group,value\nWAT,Scalar,1\nWAT,Scalar,2\n", &svg));
    try std.testing.expectError(error.InvalidCSV, renderSVG("name,group,value\nWAT,Scalar,nan\n", &svg));
    try std.testing.expectError(error.InvalidCSV, renderSVG("name,group,value\nWAT,Scalar,-1\n", &svg));
    try std.testing.expectError(error.InvalidCSV, renderSVG("name,group,value\n\"WAT,Scalar,1\n", &svg));
}
