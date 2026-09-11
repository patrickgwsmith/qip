const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/json";
const OUTPUT_CONTENT_TYPE = "application/json";
const MAX_DEPTH: usize = 512;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const JsonError = error{ InvalidJson, OutputOverflow };

const Writer = struct {
    buf: []u8,
    idx: usize = 0,

    fn writeByte(self: *Writer, b: u8) JsonError!void {
        if (self.idx >= self.buf.len) return error.OutputOverflow;
        self.buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) JsonError!void {
        if (self.idx + s.len > self.buf.len) return error.OutputOverflow;
        @memcpy(self.buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }

    fn writeIndent(self: *Writer, depth: usize) JsonError!void {
        var i: usize = 0;
        while (i < depth * 2) : (i += 1) try self.writeByte(' ');
    }
};

const Container = enum(u8) { object, array };

const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    out: Writer,
    // The recursion in value -> object/array -> value is unrolled into this
    // explicit stack so the call graph stays acyclic for the strict profile.
    // MAX_DEPTH bounds it exactly as it bounded the recursion depth before.
    stack: [MAX_DEPTH]Container = undefined,
    depth: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\n', '\r', '\t' => {},
                else => return,
            }
        }
    }

    fn parse(self: *Parser) JsonError!usize {
        self.skipWs();
        try self.value();
        self.skipWs();
        if (self.pos != self.input.len) return error.InvalidJson;
        return self.out.idx;
    }

    // Parses one complete value, container nesting included, iteratively.
    fn value(self: *Parser) JsonError!void {
        var want_value = true;
        while (true) {
            if (want_value) {
                if (self.pos >= self.input.len) return error.InvalidJson;
                want_value = switch (self.input[self.pos]) {
                    '{' => try self.open(.object),
                    '[' => try self.open(.array),
                    '"' => blk: {
                        try self.string();
                        break :blk false;
                    },
                    't' => blk: {
                        try self.literal("true");
                        break :blk false;
                    },
                    'f' => blk: {
                        try self.literal("false");
                        break :blk false;
                    },
                    'n' => blk: {
                        try self.literal("null");
                        break :blk false;
                    },
                    '-', '0'...'9' => blk: {
                        try self.number();
                        break :blk false;
                    },
                    else => return error.InvalidJson,
                };
                continue;
            }

            // A value just completed: close containers or continue them.
            self.skipWs();
            if (self.depth == 0) return;
            if (self.pos >= self.input.len) return error.InvalidJson;
            const top = self.stack[self.depth - 1];
            const c = self.input[self.pos];
            if ((c == '}' and top == .object) or (c == ']' and top == .array)) {
                self.pos += 1;
                self.depth -= 1;
                try self.out.writeByte('\n');
                try self.out.writeIndent(self.depth);
                try self.out.writeByte(c);
                continue;
            }
            if (c != ',') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeByte(',');
            try self.out.writeByte('\n');
            try self.out.writeIndent(self.depth);
            self.skipWs();
            if (top == .object) try self.keyColon();
            want_value = true;
        }
    }

    // Consumes an opening bracket. An empty container is written inline and
    // completes (returns false); a non-empty one is pushed and, for objects,
    // its first key is consumed, leaving a member value pending (returns
    // true).
    fn open(self: *Parser, kind: Container) JsonError!bool {
        const open_byte: u8 = if (kind == .object) '{' else '[';
        const close_byte: u8 = if (kind == .object) '}' else ']';
        self.pos += 1;
        try self.out.writeByte(open_byte);
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == close_byte) {
            self.pos += 1;
            try self.out.writeByte(close_byte);
            return false;
        }
        if (self.depth >= MAX_DEPTH) return error.InvalidJson;
        self.stack[self.depth] = kind;
        self.depth += 1;
        try self.out.writeByte('\n');
        try self.out.writeIndent(self.depth);
        self.skipWs();
        if (kind == .object) try self.keyColon();
        return true;
    }

    // Consumes a "key": pair opener inside an object, leaving pos at the
    // start of the member value.
    fn keyColon(self: *Parser) JsonError!void {
        if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
        try self.string();
        self.skipWs();
        if (self.pos >= self.input.len or self.input[self.pos] != ':') return error.InvalidJson;
        self.pos += 1;
        try self.out.writeSlice(": ");
        self.skipWs();
    }

    fn literal(self: *Parser, text: []const u8) JsonError!void {
        if (self.pos + text.len > self.input.len) return error.InvalidJson;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + text.len], text)) return error.InvalidJson;
        try self.out.writeSlice(text);
        self.pos += text.len;
    }

    fn string(self: *Parser) JsonError!void {
        try self.out.writeByte('"');
        self.pos += 1;
        while (self.pos < self.input.len) {
            const b = self.input[self.pos];
            if (b < 0x20) return error.InvalidJson;
            try self.out.writeByte(b);
            self.pos += 1;
            if (b == '"') return;
            if (b == '\\') {
                if (self.pos >= self.input.len) return error.InvalidJson;
                const esc = self.input[self.pos];
                switch (esc) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        try self.out.writeByte(esc);
                        self.pos += 1;
                    },
                    'u' => {
                        try self.out.writeByte('u');
                        self.pos += 1;
                        var i: usize = 0;
                        while (i < 4) : (i += 1) {
                            if (self.pos >= self.input.len or !std.ascii.isHex(self.input[self.pos])) return error.InvalidJson;
                            try self.out.writeByte(self.input[self.pos]);
                            self.pos += 1;
                        }
                    },
                    else => return error.InvalidJson,
                }
            }
        }
        return error.InvalidJson;
    }

    fn number(self: *Parser) JsonError!void {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.input.len) return error.InvalidJson;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (isDigit1to9(self.input[self.pos])) {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        } else return error.InvalidJson;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            if (self.pos >= self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidJson;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            if (self.pos >= self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidJson;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        try self.out.writeSlice(self.input[start..self.pos]);
    }

    fn object(self: *Parser, depth: usize) JsonError!void {
        self.pos += 1;
        try self.out.writeByte('{');
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            try self.out.writeByte('}');
            return;
        }
        while (true) {
            try self.out.writeByte('\n');
            try self.out.writeIndent(depth + 1);
            self.skipWs();
            if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
            try self.string();
            self.skipWs();
            if (self.pos >= self.input.len or self.input[self.pos] != ':') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeSlice(": ");
            self.skipWs();
            try self.value(depth + 1);
            self.skipWs();
            if (self.pos >= self.input.len) return error.InvalidJson;
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                try self.out.writeByte('\n');
                try self.out.writeIndent(depth);
                try self.out.writeByte('}');
                return;
            }
            if (self.input[self.pos] != ',') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeByte(',');
        }
    }

    fn array(self: *Parser, depth: usize) JsonError!void {
        self.pos += 1;
        try self.out.writeByte('[');
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == ']') {
            self.pos += 1;
            try self.out.writeByte(']');
            return;
        }
        while (true) {
            try self.out.writeByte('\n');
            try self.out.writeIndent(depth + 1);
            self.skipWs();
            try self.value(depth + 1);
            self.skipWs();
            if (self.pos >= self.input.len) return error.InvalidJson;
            if (self.input[self.pos] == ']') {
                self.pos += 1;
                try self.out.writeByte('\n');
                try self.out.writeIndent(depth);
                try self.out.writeByte(']');
                return;
            }
            if (self.input[self.pos] != ',') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeByte(',');
        }
    }
};

fn isDigit1to9(b: u8) bool {
    return b >= '1' and b <= '9';
}

fn prettifyJson(input: []const u8, output: []u8) JsonError!usize {
    var parser = Parser{ .input = input, .out = .{ .buf = output } };
    return parser.parse();
}

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const output_size = prettifyJson(input_buf[0..input_size], output_buf[0..]) catch @trap();
    return @as(u32, @intCast(output_size));
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "prettifies object" {
    var out: [256]u8 = undefined;
    const len = try prettifyJson("{\"b\":[1,true,null],\"a\":{\"x\":\"y\"}}", out[0..]);
    try std.testing.expectEqualStrings(
        "{\n  \"b\": [\n    1,\n    true,\n    null\n  ],\n  \"a\": {\n    \"x\": \"y\"\n  }\n}",
        out[0..len],
    );
}

test "rejects trailing input" {
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidJson, prettifyJson("{}x", out[0..]));
}

fn nestedArrays(comptime n: usize) []const u8 {
    return "[" ** n ++ "]" ** n;
}

test "accepts nesting at the depth limit" {
    var out: [1024 * 1024]u8 = undefined;
    _ = try prettifyJson(nestedArrays(MAX_DEPTH + 1), out[0..]);
}

test "rejects nesting past the depth limit" {
    var out: [1024 * 1024]u8 = undefined;
    try std.testing.expectError(error.InvalidJson, prettifyJson(nestedArrays(MAX_DEPTH + 2), out[0..]));
}
