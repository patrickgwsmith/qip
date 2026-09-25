//! Read-only tree viewer for XML and binary Apple property lists.
const std = @import("std");
const INFO_MODE = @hasDecl(@import("root"), "info_plist_mode");
const SCHEMA = if (INFO_MODE) @embedFile("lib/info-plist-schema.tsv") else "";

const INPUT_CAP = 8 * 1024 * 1024;
const POOL_CAP = 8 * 1024 * 1024;
const OUTPUT_CAP = 128 * 1024;
const MAX_NODES = 32 * 1024;
const MAX_DEPTH = 128;
const NONE = std.math.maxInt(u32);
const KEY_DOWN: i32 = 1;
const XK_LEFT: i32 = 0xff51;
const XK_UP: i32 = 0xff52;
const XK_RIGHT: i32 = 0xff53;
const XK_DOWN: i32 = 0xff54;
const XK_PAGE_UP: i32 = 0xff55;
const XK_PAGE_DOWN: i32 = 0xff56;
const XK_HOME: i32 = 0xff50;
const XK_END: i32 = 0xff57;
const XK_ENTER: i32 = 0xff0d;

const Kind = enum { dict, array, string, integer, real, boolean, date, data, uid, null, set };
const Node = struct {
    parent: u32 = NONE,
    first: u32 = NONE,
    last: u32 = NONE,
    next: u32 = NONE,
    kind: Kind,
    label: []const u8,
    display_label: []const u8 = "",
    schema_class: []const u8 = "",
    value: []const u8 = "",
    children: usize = 0,
    expanded: bool = false,
};
const Phase = enum { initial, ready, updating };
var phase: Phase = .initial;
var begun: i64 = 0;
var committed: i64 = 0;
var columns: usize = 80;
var lines: usize = 24;
var input: [INPUT_CAP]u8 = undefined;
var pool: [POOL_CAP]u8 = undefined;
var pool_len: usize = 0;
var nodes: [MAX_NODES]Node = undefined;
var node_count: usize = 0;
var visible: [MAX_NODES]u32 = undefined;
var depths: [MAX_NODES]u8 = undefined;
var visible_count: usize = 0;
var selected: usize = 0;
var top: usize = 0;
var output: [OUTPUT_CAP]u8 = undefined;
var output_len: usize = 0;
var format_name: []const u8 = "";
var load_error: []const u8 = "";
var object_stack: [MAX_DEPTH]u64 = undefined;

fn stored(value: []const u8) ![]const u8 {
    if (value.len > POOL_CAP - pool_len) return error.TooMuchText;
    const start = pool_len;
    @memcpy(pool[start..][0..value.len], value);
    pool_len += value.len;
    return pool[start..pool_len];
}

fn formatted(comptime pattern: []const u8, args: anytype) ![]const u8 {
    const result = std.fmt.bufPrint(pool[pool_len..], pattern, args) catch return error.TooMuchText;
    pool_len += result.len;
    return result;
}

fn add(parent: u32, kind: Kind, label: []const u8, value: []const u8) !u32 {
    if (node_count == MAX_NODES) return error.TooManyNodes;
    const id: u32 = @intCast(node_count);
    node_count += 1;
    nodes[id] = .{ .parent = parent, .kind = kind, .label = label, .value = value, .expanded = parent == NONE };
    if (INFO_MODE) {
        if (parent == NONE) {
            nodes[id].display_label = "Info.plist";
            nodes[id].schema_class = "_root_";
        } else if (nodes[parent].kind == .dict) {
            if (schemaKey(nodes[parent].schema_class, label)) |info| {
                nodes[id].display_label = info.label;
                nodes[id].schema_class = info.class;
            }
        } else if (nodes[parent].kind == .array) {
            nodes[id].schema_class = schemaArrayElement(nodes[parent].schema_class);
        }
    }
    if (parent != NONE) {
        const p = &nodes[parent];
        if (p.last == NONE) p.first = id else nodes[p.last].next = id;
        p.last = id;
        p.children += 1;
    }
    return id;
}

const KeyInfo = struct { label: []const u8, class: []const u8 };

fn schemaKey(parent_class: []const u8, key: []const u8) ?KeyInfo {
    var lines_it = std.mem.tokenizeScalar(u8, SCHEMA, '\n');
    while (lines_it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "K\t")) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        const parent = fields.next() orelse continue;
        const raw_key = fields.next() orelse continue;
        if (!std.mem.eql(u8, parent, parent_class) or !std.mem.eql(u8, raw_key, key)) continue;
        return .{ .label = fields.next() orelse "", .class = fields.next() orelse "" };
    }
    return null;
}

fn schemaDefinition(class: []const u8) ?struct { kind: []const u8, element: []const u8 } {
    var lines_it = std.mem.tokenizeScalar(u8, SCHEMA, '\n');
    while (lines_it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "D\t")) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        if (!std.mem.eql(u8, fields.next() orelse "", class)) continue;
        return .{ .kind = fields.next() orelse "", .element = fields.next() orelse "" };
    }
    return null;
}

fn schemaArrayElement(class: []const u8) []const u8 {
    if (schemaDefinition(class)) |definition| return definition.element;
    return "";
}

fn schemaMismatch(node: Node) bool {
    if (!INFO_MODE or node.schema_class.len == 0) return false;
    const expected = if (schemaDefinition(node.schema_class)) |definition| definition.kind else node.schema_class;
    if (std.mem.eql(u8, expected, "String")) return node.kind != .string;
    if (std.mem.eql(u8, expected, "Boolean")) return node.kind != .boolean;
    if (std.mem.eql(u8, expected, "Dictionary")) return node.kind != .dict;
    if (std.mem.eql(u8, expected, "Array")) return node.kind != .array;
    if (std.mem.eql(u8, expected, "Number")) return node.kind != .integer and node.kind != .real;
    return false;
}

const Xml = struct {
    data: []const u8,
    at: usize = 0,

    const Tag = struct { name: []const u8, closing: bool, empty: bool };

    fn skip(self: *Xml) !void {
        while (self.at < self.data.len) {
            if (std.ascii.isWhitespace(self.data[self.at])) {
                self.at += 1;
            } else if (std.mem.startsWith(u8, self.data[self.at..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.data, self.at + 4, "-->") orelse return error.InvalidXml;
                self.at = end + 3;
            } else if (std.mem.startsWith(u8, self.data[self.at..], "<?")) {
                const end = std.mem.indexOfPos(u8, self.data, self.at + 2, "?>") orelse return error.InvalidXml;
                self.at = end + 2;
            } else if (std.mem.startsWith(u8, self.data[self.at..], "<!DOCTYPE")) {
                var pos = self.at + 9;
                var quote: u8 = 0;
                var brackets: usize = 0;
                while (pos < self.data.len) : (pos += 1) {
                    const byte = self.data[pos];
                    if (quote != 0) {
                        if (byte == quote) quote = 0;
                    } else switch (byte) {
                        '\'', '"' => quote = byte,
                        '[' => brackets += 1,
                        ']' => brackets -|= 1,
                        '>' => if (brackets == 0) break,
                        else => {},
                    }
                }
                if (pos == self.data.len) return error.InvalidXml;
                self.at = pos + 1;
            } else break;
        }
    }

    fn tag(self: *Xml) !Tag {
        if (self.at >= self.data.len or self.data[self.at] != '<') return error.InvalidXml;
        const end = std.mem.indexOfScalarPos(u8, self.data, self.at + 1, '>') orelse return error.InvalidXml;
        var body = std.mem.trim(u8, self.data[self.at + 1 .. end], " \r\n\t");
        self.at = end + 1;
        if (body.len == 0) return error.InvalidXml;
        const is_closing = body[0] == '/';
        if (is_closing) body = body[1..];
        const empty = body.len > 0 and body[body.len - 1] == '/';
        if (empty) body = body[0 .. body.len - 1];
        const name_end = std.mem.indexOfAny(u8, body, " \r\n\t") orelse body.len;
        if (name_end == 0) return error.InvalidXml;
        return .{ .name = body[0..name_end], .closing = is_closing, .empty = empty };
    }

    fn closing(self: *Xml, name: []const u8) !void {
        const close = try self.tag();
        if (!close.closing or !std.mem.eql(u8, close.name, name)) return error.InvalidXml;
    }

    fn text(self: *Xml, name: []const u8) ![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.data, self.at, '<') orelse return error.InvalidXml;
        const raw = self.data[self.at..end];
        self.at = end;
        try self.closing(name);
        const start = pool_len;
        var pos: usize = 0;
        while (pos < raw.len) {
            if (raw[pos] != '&') {
                _ = try stored(raw[pos .. pos + 1]);
                pos += 1;
                continue;
            }
            const semicolon = std.mem.indexOfScalarPos(u8, raw, pos + 1, ';') orelse return error.InvalidXml;
            const entity = raw[pos + 1 .. semicolon];
            const scalar: u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else if (std.mem.startsWith(u8, entity, "#x")) std.fmt.parseInt(u21, entity[2..], 16) catch return error.InvalidXml else if (std.mem.startsWith(u8, entity, "#")) std.fmt.parseInt(u21, entity[1..], 10) catch return error.InvalidXml else return error.InvalidXml;
            if (scalar == 0 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) return error.InvalidXml;
            const count = std.unicode.utf8Encode(scalar, pool[pool_len..]) catch return error.TooMuchText;
            pool_len += count;
            pos = semicolon + 1;
        }
        return pool[start..pool_len];
    }

    fn value(self: *Xml, parent: u32, label: []const u8, depth: usize) anyerror!u32 {
        if (depth == MAX_DEPTH) return error.TooDeep;
        try self.skip();
        const open = try self.tag();
        if (open.closing) return error.InvalidXml;
        const kind: Kind = if (std.mem.eql(u8, open.name, "dict")) .dict else if (std.mem.eql(u8, open.name, "array")) .array else if (std.mem.eql(u8, open.name, "string")) .string else if (std.mem.eql(u8, open.name, "integer")) .integer else if (std.mem.eql(u8, open.name, "real")) .real else if (std.mem.eql(u8, open.name, "date")) .date else if (std.mem.eql(u8, open.name, "data")) .data else if (std.mem.eql(u8, open.name, "true") or std.mem.eql(u8, open.name, "false")) .boolean else return error.InvalidXml;
        const id = try add(parent, kind, label, "");
        if (kind == .boolean) {
            nodes[id].value = if (std.mem.eql(u8, open.name, "true")) "true" else "false";
            if (!open.empty) {
                try self.skip();
                try self.closing(open.name);
            }
        } else if (kind == .dict or kind == .array) {
            if (!open.empty) {
                while (true) {
                    try self.skip();
                    if (std.mem.startsWith(u8, self.data[self.at..], "</")) {
                        try self.closing(open.name);
                        break;
                    }
                    if (kind == .dict) {
                        const key = try self.tag();
                        if (key.closing or !std.mem.eql(u8, key.name, "key")) return error.InvalidXml;
                        const label_text = if (key.empty) "" else try self.text("key");
                        _ = try self.value(id, label_text, depth + 1);
                    } else {
                        const child_label = try formatted("[{d}]", .{nodes[id].children});
                        _ = try self.value(id, child_label, depth + 1);
                    }
                }
            }
        } else {
            const raw = if (open.empty) "" else try self.text(open.name);
            const trimmed = std.mem.trim(u8, raw, " \r\n\t");
            if (kind == .data) {
                var count: usize = 0;
                var padding: usize = 0;
                for (trimmed) |byte| {
                    if (std.ascii.isWhitespace(byte)) continue;
                    if (byte == '=') {
                        padding += 1;
                    } else {
                        if (padding != 0 or !std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '/') return error.InvalidXml;
                    }
                    count += 1;
                }
                if (count % 4 != 0 or padding > 2) return error.InvalidXml;
                nodes[id].value = try formatted("{d} bytes", .{count / 4 * 3 - padding});
            } else nodes[id].value = if (kind == .string) raw else trimmed;
        }
        return id;
    }
};

fn parseXml(data: []const u8) !void {
    const xml = if (std.mem.startsWith(u8, data, "\xef\xbb\xbf")) data[3..] else data;
    if (!std.unicode.utf8ValidateSlice(xml)) return error.InvalidXml;
    var parser = Xml{ .data = xml };
    try parser.skip();
    const open = try parser.tag();
    if (open.closing or open.empty or !std.mem.eql(u8, open.name, "plist")) return error.InvalidXml;
    _ = try parser.value(NONE, "root", 0);
    if (INFO_MODE and nodes[0].kind != .dict) return error.InvalidXml;
    try parser.skip();
    try parser.closing("plist");
    try parser.skip();
    if (parser.at != xml.len) return error.InvalidXml;
}

fn big(data: []const u8, at: usize, size: usize) !u64 {
    if (size == 0 or size > 8 or at > data.len or size > data.len - at) return error.InvalidBinary;
    var result: u64 = 0;
    for (data[at..][0..size]) |byte| result = (result << 8) | byte;
    return result;
}

fn dateText(value: f64) ![]const u8 {
    const unix = value + std.time.epoch.ios;
    if (!std.math.isFinite(unix) or unix < 0 or unix >= 253402300800) {
        return formatted("{d} seconds since 2001-01-01", .{value});
    }
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intFromFloat(@floor(unix)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return formatted("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

const Binary = struct {
    data: []const u8,
    offset_size: usize,
    ref_size: usize,
    count: u64,
    table: usize,

    fn offset(self: Binary, object_index: u64) !usize {
        if (object_index >= self.count or object_index > (self.data.len - self.table) / self.offset_size) return error.InvalidBinary;
        const at = self.table + @as(usize, @intCast(object_index)) * self.offset_size;
        const value = try big(self.data, at, self.offset_size);
        if (value < 8 or value >= self.table) return error.InvalidBinary;
        return @intCast(value);
    }

    fn length(self: Binary, nibble: u8, at: *usize) !usize {
        if (nibble < 15) return nibble;
        if (at.* >= self.table) return error.InvalidBinary;
        const marker = self.data[at.*];
        if (marker >> 4 != 1 or marker & 15 > 3) return error.InvalidBinary;
        const size: usize = @as(usize, 1) << @intCast(marker & 15);
        if (at.* + 1 > self.table or size > self.table - (at.* + 1)) return error.InvalidBinary;
        const result = try big(self.data, at.* + 1, size);
        at.* += 1 + size;
        if (result > INPUT_CAP) return error.InvalidBinary;
        return @intCast(result);
    }

    fn string(self: Binary, object_index: u64) ![]const u8 {
        const at = try self.offset(object_index);
        const marker = self.data[at];
        var pos = at + 1;
        const count = try self.length(marker & 15, &pos);
        if (marker >> 4 == 5) {
            if (pos > self.table or count > self.table - pos) return error.InvalidBinary;
            const value = self.data[pos .. pos + count];
            for (value) |byte| if (!std.ascii.isAscii(byte)) return error.InvalidBinary;
            return value;
        }
        if (marker >> 4 != 6 or count > (self.table -| pos) / 2) return error.InvalidBinary;
        const start = pool_len;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const unit = try big(self.data, pos + i * 2, 2);
            var scalar: u21 = @intCast(unit);
            if (unit >= 0xd800 and unit <= 0xdbff) {
                i += 1;
                if (i == count) return error.InvalidBinary;
                const low = try big(self.data, pos + i * 2, 2);
                if (low < 0xdc00 or low > 0xdfff) return error.InvalidBinary;
                scalar = @intCast(0x10000 + (unit - 0xd800) * 1024 + low - 0xdc00);
            } else if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidBinary;
            const written = std.unicode.utf8Encode(scalar, pool[pool_len..]) catch return error.TooMuchText;
            pool_len += written;
        }
        return pool[start..pool_len];
    }

    fn reference(self: Binary, at: usize) !u64 {
        const ref = try big(self.data, at, self.ref_size);
        if (ref >= self.count) return error.InvalidBinary;
        return ref;
    }

    fn object(self: Binary, object_ref: u64, parent: u32, label: []const u8, depth: usize) anyerror!u32 {
        if (depth == MAX_DEPTH) return error.TooDeep;
        for (object_stack[0..depth]) |seen| if (seen == object_ref) return error.InvalidBinary;
        object_stack[depth] = object_ref;
        const at = try self.offset(object_ref);
        const marker = self.data[at];
        const family = marker >> 4;
        const nibble = marker & 15;
        var pos = at + 1;
        const kind: Kind = switch (family) {
            0 => switch (nibble) {
                0 => .null,
                8, 9 => .boolean,
                else => return error.InvalidBinary,
            },
            1 => .integer,
            2 => .real,
            3 => if (nibble == 3) .date else return error.InvalidBinary,
            4 => .data,
            5, 6 => .string,
            8 => .uid,
            10 => .array,
            12 => .set,
            13 => .dict,
            else => return error.InvalidBinary,
        };
        const id = try add(parent, kind, label, "");
        switch (kind) {
            .null => nodes[id].value = "null",
            .boolean => nodes[id].value = if (nibble == 9) "true" else "false",
            .integer, .uid => {
                const size: usize = if (kind == .uid) @as(usize, nibble) + 1 else @as(usize, 1) << @intCast(nibble);
                if (size > 16 or pos > self.table or size > self.table - pos) return error.InvalidBinary;
                if (size == 16) {
                    const high = try big(self.data, pos, 8);
                    const low = try big(self.data, pos + 8, 8);
                    nodes[id].value = try formatted("0x{x:0>16}{x:0>16}", .{ high, low });
                } else {
                    const value = try big(self.data, pos, size);
                    nodes[id].value = if (kind == .integer and size == 8 and value >> 63 == 1)
                        try formatted("{d}", .{@as(i64, @bitCast(value))})
                    else
                        try formatted("{d}", .{value});
                }
            },
            .real, .date => {
                const size: usize = @as(usize, 1) << @intCast(nibble);
                if (pos > self.table or size > self.table - pos) return error.InvalidBinary;
                const number: f64 = if (size == 4) @as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @intCast(try big(self.data, pos, 4))))))) else if (size == 8) @as(f64, @bitCast(try big(self.data, pos, 8))) else return error.InvalidBinary;
                nodes[id].value = if (kind == .date) try dateText(number) else try formatted("{d}", .{number});
            },
            .string => nodes[id].value = try self.string(object_ref),
            .data => {
                const count = try self.length(nibble, &pos);
                if (pos > self.table or count > self.table - pos) return error.InvalidBinary;
                nodes[id].value = try formatted("{d} bytes", .{count});
            },
            .array, .set, .dict => {
                const count = try self.length(nibble, &pos);
                const fields: usize = if (kind == .dict) 2 else 1;
                if (pos > self.table or count > (self.table - pos) / self.ref_size / fields) return error.InvalidBinary;
                for (0..count) |index| {
                    const child_label = if (kind == .dict)
                        try self.string(try self.reference(pos + index * self.ref_size))
                    else
                        try formatted("[{d}]", .{index});
                    const value_at = pos + (if (kind == .dict) count + index else index) * self.ref_size;
                    _ = try self.object(try self.reference(value_at), id, child_label, depth + 1);
                }
            },
        }
        return id;
    }
};

fn parseBinary(data: []const u8) !void {
    if (data.len < 40 or !std.mem.startsWith(u8, data, "bplist00")) return error.InvalidBinary;
    const trailer = data.len - 32;
    const offset_size: usize = data[trailer + 6];
    const ref_size: usize = data[trailer + 7];
    const count = try big(data, trailer + 8, 8);
    const root = try big(data, trailer + 16, 8);
    const table_offset = try big(data, trailer + 24, 8);
    if (offset_size == 0 or offset_size > 8 or ref_size == 0 or ref_size > 8 or count == 0 or count > MAX_NODES or root >= count or table_offset < 8 or table_offset >= trailer) return error.InvalidBinary;
    const table: usize = @intCast(table_offset);
    if (count > (trailer - table) / offset_size) return error.InvalidBinary;
    const parser = Binary{ .data = data, .offset_size = offset_size, .ref_size = ref_size, .count = count, .table = table };
    _ = try parser.object(root, NONE, "root", 0);
    if (INFO_MODE and nodes[0].kind != .dict) return error.InvalidBinary;
}

fn collectVisible(id: u32, depth: usize) void {
    if (visible_count == MAX_NODES) return;
    visible[visible_count] = id;
    depths[visible_count] = @intCast(@min(depth, 255));
    visible_count += 1;
    if (!nodes[id].expanded) return;
    var child = nodes[id].first;
    while (child != NONE) : (child = nodes[child].next) collectVisible(child, depth + 1);
}

const Writer = struct {
    at: usize = 0,
    column: usize = 0,
    row: usize = 0,

    fn byte(self: *Writer, value: u8) void {
        if (self.at == OUTPUT_CAP) return;
        output[self.at] = value;
        self.at += 1;
    }

    fn text(self: *Writer, value: []const u8) void {
        var pos: usize = 0;
        while (pos < value.len and self.column < columns and self.row < lines) {
            const count = std.unicode.utf8ByteSequenceLength(value[pos]) catch 1;
            if (pos + count > value.len) break;
            const scalar = if (count == 1) @as(u21, value[pos]) else std.unicode.utf8Decode(value[pos .. pos + count]) catch 0xfffd;
            if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f) or (scalar >= 0x202a and scalar <= 0x202e) or (scalar >= 0x2066 and scalar <= 0x2069) or scalar == 0xfeff) {
                self.byte('?');
            } else for (value[pos .. pos + count]) |part| self.byte(part);
            self.column += 1;
            pos += count;
        }
    }

    fn newline(self: *Writer) void {
        if (self.row + 1 >= lines) return;
        self.byte('\n');
        self.row += 1;
        self.column = 0;
    }

    fn number(self: *Writer, value: usize) void {
        var digits: [20]u8 = undefined;
        const value_text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return;
        self.text(value_text);
    }
};

fn draw() void {
    var w = Writer{};
    w.text(if (INFO_MODE) "INFO.PLIST VIEWER  " else "PLIST VIEWER  ");
    w.text(format_name);
    if (load_error.len == 0) {
        w.text("  ");
        w.number(node_count);
        w.text(" values");
    }
    w.newline();
    if (load_error.len > 0) {
        w.text(load_error);
        w.newline();
        w.text("Open an XML or binary Apple property list.");
        output_len = w.at;
        return;
    }
    visible_count = 0;
    collectVisible(0, 0);
    selected = @min(selected, visible_count -| 1);
    const page = lines -| (if (INFO_MODE) @as(usize, 3) else 2);
    if (selected < top) top = selected;
    if (page > 0 and selected >= top + page) top = selected - page + 1;
    for (top..@min(top + page, visible_count)) |index| {
        const node = nodes[visible[index]];
        w.text(if (index == selected) "> " else "  ");
        for (0..@min(@as(usize, depths[index]) * 2, 48)) |_| w.text(" ");
        w.text(if (node.first == NONE) "  " else if (node.expanded) "- " else "+ ");
        if (INFO_MODE and node.display_label.len > 0) {
            w.text(node.display_label);
        } else w.text(node.label);
        w.text("  ");
        if (node.first != NONE or node.kind == .dict or node.kind == .array or node.kind == .set) {
            w.text(switch (node.kind) {
                .dict => "dict",
                .array => "array",
                .set => "set",
                else => "",
            });
            w.text(" (");
            w.number(node.children);
            w.text(")");
        } else {
            w.text(switch (node.kind) {
                .string => "string",
                .integer => "integer",
                .real => "real",
                .boolean => "bool",
                .date => "date",
                .data => "data",
                .uid => "UID",
                .null => "null",
                else => "",
            });
            w.text(": ");
            w.text(node.value);
        }
        if (schemaMismatch(node)) {
            w.text("  ! expected ");
            const expected = if (schemaDefinition(node.schema_class)) |definition| definition.kind else node.schema_class;
            w.text(expected);
        }
        w.newline();
    }
    if (INFO_MODE and lines > 2) {
        const node = nodes[visible[selected]];
        w.text("Key: ");
        w.text(node.label);
        if (node.schema_class.len > 0) {
            const expected = if (schemaDefinition(node.schema_class)) |definition| definition.kind else node.schema_class;
            w.text("  Expected: ");
            w.text(expected);
        }
        w.newline();
    }
    if (lines > 2) {
        w.text("Up/Down move  Left/Right fold  Enter toggle  a open all  PgUp/PgDn page");
    }
    output_len = w.at;
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input));
}
export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr("text/plain".ptr));
}
export fn output_content_type_size() u32 {
    return "text/plain".len;
}
export fn uniform_set_columns(value: u32) void {
    columns = @max(1, @min(value, 240));
}
export fn uniform_set_lines(value: u32) void {
    lines = @max(1, @min(value, 100));
}
export fn begin_update_at(now: i64) void {
    if (phase != .ready or now <= committed) @trap();
    begun = now;
    phase = .updating;
}
export fn key_event(key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if (flags & KEY_DOWN == 0 or load_error.len > 0) return 0;
    const old = selected;
    const old_count = visible_count;
    const page = @max(1, lines -| (if (INFO_MODE) @as(usize, 3) else 2));
    switch (key) {
        XK_UP, 'k' => selected -|= 1,
        XK_DOWN, 'j' => selected = @min(selected + 1, visible_count -| 1),
        XK_PAGE_UP => selected -|= page,
        XK_PAGE_DOWN => selected = @min(selected + page, visible_count -| 1),
        XK_HOME, 'g' => selected = 0,
        XK_END, 'G' => selected = visible_count -| 1,
        XK_LEFT => {
            const id = visible[selected];
            if (nodes[id].expanded and nodes[id].first != NONE) {
                nodes[id].expanded = false;
            } else if (nodes[id].parent != NONE) {
                for (visible[0..visible_count], 0..) |other, index| {
                    if (other == nodes[id].parent) {
                        selected = index;
                        break;
                    }
                }
            }
        },
        XK_RIGHT => {
            const id = visible[selected];
            if (nodes[id].first != NONE and !nodes[id].expanded) {
                nodes[id].expanded = true;
            } else if (nodes[id].first != NONE) selected += 1;
        },
        XK_ENTER, ' ' => {
            const id = visible[selected];
            if (nodes[id].first != NONE) nodes[id].expanded = !nodes[id].expanded;
        },
        'a' => {
            for (nodes[0..node_count]) |*node| {
                if (node.first != NONE) node.expanded = true;
            }
        },
        else => {},
    }
    if (key == XK_LEFT or key == XK_RIGHT or key == XK_ENTER or key == ' ' or key == 'a') {
        visible_count = 0;
        collectVisible(0, 0);
    }
    return if (selected != old or visible_count != old_count) 1 else 0;
}
export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed = begun;
    phase = .ready;
    return committed;
}
export fn render(size: u32) packed struct(u64) { output_size: u32, output_ptr: u31, failed: u1 } {
    if (phase == .updating or size > INPUT_CAP) @trap();
    if (phase == .initial) {
        pool_len = 0;
        node_count = 0;
        selected = 0;
        top = 0;
        const bytes = input[0..size];
        if (std.mem.startsWith(u8, bytes, "bplist00")) {
            format_name = "BINARY";
            parseBinary(bytes) catch {
                load_error = "Invalid or unsupported binary plist.";
            };
        } else {
            format_name = "XML";
            parseXml(bytes) catch {
                load_error = "Invalid or unsupported XML plist.";
            };
        }
        phase = .ready;
    } else if (size != 0) @trap();
    draw();
    return .{ .output_size = @intCast(output_len), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}
