// Shared JSON Schema 2020-12 machinery: the JSON parser, exact decimal
// numbers, URI resolution, the ECMA-262 regex subset and its Pike VM, and the
// schema index that resolves $id, $anchor, $dynamicAnchor and $ref.
//
// json-schema-2020-12-must-be-valid.zig evaluates schemas directly with it.
// json-schema-to-wasm.zig uses the same index to resolve a schema ahead of
// time, and lib/json-schema-runtime.zig reuses the number and regex code.
const std = @import("std");
pub const unicode_letter = @import("json-schema-unicode-letter.zig");

pub const MAX_DEPTH: usize = 512;
pub const MAX_REGEX_INSTS: usize = 20_000;
pub const DEFAULT_BASE = "https://json-schema.invalid/schema.json";
pub const DIALECT_2020_12 = "https://json-schema.org/draft/2020-12/schema";

pub const Error = error{
    OutOfMemory,
    InvalidEnvelope,
    InvalidJson,
    MissingKey,
    BadSchema,
    Unsupported,
    TooDeep,
};

// ---------------------------------------------------------------------------
// Built-in meta-schemas

pub const Embedded = struct { uri: []const u8, json: []const u8 };

// The files stay as published; whitespace outside strings is dropped at
// compile time, which keeps about 3 KB out of the Wasm.
pub fn embedMinified(comptime path: []const u8) []const u8 {
    comptime {
        const src = @embedFile(path);
        @setEvalBranchQuota(src.len * 20);
        var out: [src.len]u8 = undefined;
        var n: usize = 0;
        var in_string = false;
        var escaped = false;
        for (src) |c| {
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
            } else if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                continue;
            } else if (c == '"') {
                in_string = true;
            }
            out[n] = c;
            n += 1;
        }
        const final = out[0..n].*;
        return &final;
    }
}

pub const embedded_schemas = [_]Embedded{
    .{ .uri = "https://json-schema.org/draft/2020-12/schema", .json = embedMinified("json-schema-2020-12/schema.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/core", .json = embedMinified("json-schema-2020-12/meta-core.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/applicator", .json = embedMinified("json-schema-2020-12/meta-applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/unevaluated", .json = embedMinified("json-schema-2020-12/meta-unevaluated.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/validation", .json = embedMinified("json-schema-2020-12/meta-validation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/meta-data", .json = embedMinified("json-schema-2020-12/meta-meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-annotation", .json = embedMinified("json-schema-2020-12/meta-format-annotation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/content", .json = embedMinified("json-schema-2020-12/meta-content.json") },
};

// ---------------------------------------------------------------------------
// JSON values

pub const Number = struct { text: []const u8 };

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: Number,
    string: []const u8,
    array: []Value,
    object: []Member,
};

pub const Member = struct { key: []const u8, value: Value };

pub fn get(object: []const Member, key: []const u8) ?*const Value {
    for (object) |*member| {
        if (std.mem.eql(u8, member.key, key)) return &member.value;
    }
    return null;
}

// Every array and object is allocated once, at its final size, so a bump
// allocator holds nothing but the tree: no slices abandoned while a list grew.
// The tree takes at most 6 bytes of arena per input byte. An array item is a
// 12-byte Value for at least 2 input bytes ("0,"), a member a 20-byte Member
// for at least 5 ('"":0,'), and a decoded string is never longer than its
// source. Children wait on a stack in scratch until their container closes
// and are then copied out. A pending value takes at least 2 input bytes too,
// so the stack needs at most another 6 bytes per input byte, in scratch.
pub const JsonParser = struct {
    src: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    // Children of the open containers, innermost last. An object's members
    // wait as key and value pairs.
    stack: []Value = &.{},
    top: usize = 0,

    pub fn parseDocument(alloc: std.mem.Allocator, scratch: std.mem.Allocator, src: []const u8) Error!Value {
        var parser = JsonParser{ .src = src, .alloc = alloc, .scratch = scratch };
        const value = try parser.parseTree();
        parser.skipWs();
        if (parser.pos != src.len) return error.InvalidJson;
        return value;
    }

    // Parses one value starting at pos. The stack is reserved in scratch for
    // the most children the rest of the input could hold, but only the part
    // used is touched, and it is given back once the value parses.
    pub fn parseTree(p: *JsonParser) Error!Value {
        p.stack = try p.scratch.alloc(Value, (p.src.len - p.pos) / 2 + 1);
        defer {
            p.scratch.free(p.stack);
            p.stack = &.{};
        }
        p.top = 0;
        return p.parseValue();
    }

    fn push(p: *JsonParser, value: Value) Error!void {
        if (p.top == p.stack.len) return error.OutOfMemory;
        p.stack[p.top] = value;
        p.top += 1;
    }

    pub fn skipWs(p: *JsonParser) void {
        while (p.pos < p.src.len) : (p.pos += 1) {
            switch (p.src[p.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    pub fn literal(p: *JsonParser, word: []const u8) Error!void {
        if (!std.mem.startsWith(u8, p.src[p.pos..], word)) return error.InvalidJson;
        p.pos += word.len;
    }

    pub fn parseValue(p: *JsonParser) Error!Value {
        p.skipWs();
        if (p.pos >= p.src.len) return error.InvalidJson;
        switch (p.src[p.pos]) {
            '{' => return p.parseObject(),
            '[' => return p.parseArray(),
            '"' => return .{ .string = try p.parseString() },
            't' => {
                try p.literal("true");
                return .{ .boolean = true };
            },
            'f' => {
                try p.literal("false");
                return .{ .boolean = false };
            },
            'n' => {
                try p.literal("null");
                return .null;
            },
            '-', '0'...'9' => return p.parseNumber(),
            else => return error.InvalidJson,
        }
    }

    pub fn enter(p: *JsonParser) Error!void {
        p.depth += 1;
        if (p.depth > MAX_DEPTH) return error.TooDeep;
    }

    pub fn parseObject(p: *JsonParser) Error!Value {
        try p.enter();
        defer p.depth -= 1;
        p.pos += 1;
        p.skipWs();
        if (p.pos < p.src.len and p.src[p.pos] == '}') {
            p.pos += 1;
            return .{ .object = &.{} };
        }
        const base = p.top;
        while (true) {
            p.skipWs();
            if (p.pos >= p.src.len or p.src[p.pos] != '"') return error.InvalidJson;
            const key = try p.parseString();
            p.skipWs();
            if (p.pos >= p.src.len or p.src[p.pos] != ':') return error.InvalidJson;
            p.pos += 1;
            const value = try p.parseValue();
            try p.push(.{ .string = key });
            try p.push(value);
            p.skipWs();
            if (p.pos >= p.src.len) return error.InvalidJson;
            if (p.src[p.pos] == ',') {
                p.pos += 1;
                continue;
            }
            if (p.src[p.pos] == '}') {
                p.pos += 1;
                break;
            }
            return error.InvalidJson;
        }
        const pending = p.stack[base..p.top];
        p.top = base;
        const members = try p.alloc.alloc(Member, pending.len / 2);
        for (members, 0..) |*m, i| m.* = .{ .key = pending[2 * i].string, .value = pending[2 * i + 1] };
        return .{ .object = members };
    }

    pub fn parseArray(p: *JsonParser) Error!Value {
        try p.enter();
        defer p.depth -= 1;
        p.pos += 1;
        p.skipWs();
        if (p.pos < p.src.len and p.src[p.pos] == ']') {
            p.pos += 1;
            return .{ .array = &.{} };
        }
        const base = p.top;
        while (true) {
            try p.push(try p.parseValue());
            p.skipWs();
            if (p.pos >= p.src.len) return error.InvalidJson;
            if (p.src[p.pos] == ',') {
                p.pos += 1;
                continue;
            }
            if (p.src[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            return error.InvalidJson;
        }
        const items = try p.alloc.dupe(Value, p.stack[base..p.top]);
        p.top = base;
        return .{ .array = items };
    }

    pub fn hex4(p: *JsonParser) Error!u21 {
        if (p.pos + 4 > p.src.len) return error.InvalidJson;
        var value: u21 = 0;
        for (p.src[p.pos..][0..4]) |c| {
            const digit: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidJson,
            };
            value = value * 16 + digit;
        }
        p.pos += 4;
        return value;
    }

    pub fn parseString(p: *JsonParser) Error![]const u8 {
        p.pos += 1;
        const start = p.pos;
        var escaped = false;
        while (true) {
            if (p.pos >= p.src.len) return error.InvalidJson;
            const c = p.src[p.pos];
            if (c == '"') break;
            if (c < 0x20) return error.InvalidJson;
            if (c == '\\') {
                escaped = true;
                p.pos += 2;
                continue;
            }
            p.pos += 1;
        }
        const raw = p.src[start..p.pos];
        p.pos += 1;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidJson;
        if (!escaped) return raw;

        // Decoded text is never longer than its escaped form.
        const out = try p.alloc.alloc(u8, raw.len);
        var o: usize = 0;
        var i: usize = 0;
        const saved = p.pos;
        defer p.pos = saved;
        while (i < raw.len) {
            const c = raw[i];
            if (c != '\\') {
                out[o] = c;
                o += 1;
                i += 1;
                continue;
            }
            if (i + 1 >= raw.len) return error.InvalidJson;
            const e = raw[i + 1];
            i += 2;
            const simple: ?u8 = switch (e) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => null,
                else => return error.InvalidJson,
            };
            if (simple) |byte| {
                out[o] = byte;
                o += 1;
                continue;
            }
            p.pos = start + i;
            var cp = try p.hex4();
            i += 4;
            if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 <= raw.len and raw[i] == '\\' and raw[i + 1] == 'u') {
                p.pos = start + i + 2;
                const low = try p.hex4();
                if (low >= 0xDC00 and low <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    i += 6;
                }
            }
            o += encodeWtf8(cp, out[o..]);
        }
        // Gives back the bytes the escapes saved when out is still the
        // arena's last allocation.
        _ = p.alloc.resize(out, o);
        return out[0..o];
    }

    pub fn parseNumber(p: *JsonParser) Error!Value {
        const start = p.pos;
        if (p.src[p.pos] == '-') p.pos += 1;
        if (p.pos >= p.src.len) return error.InvalidJson;
        if (p.src[p.pos] == '0') {
            p.pos += 1;
        } else if (p.src[p.pos] >= '1' and p.src[p.pos] <= '9') {
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        } else return error.InvalidJson;
        if (p.pos < p.src.len and p.src[p.pos] == '.') {
            p.pos += 1;
            const digits = p.pos;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            if (p.pos == digits) return error.InvalidJson;
        }
        if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
            p.pos += 1;
            if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) p.pos += 1;
            const digits = p.pos;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            if (p.pos == digits) return error.InvalidJson;
        }
        return .{ .number = .{ .text = p.src[start..p.pos] } };
    }
};

// Lone surrogates from \u escapes keep their 3-byte form (WTF-8), so they
// still count as one code point and compare equal to themselves.
pub fn encodeWtf8(cp: u21, out: []u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

pub const Decoded = struct { cp: u21, len: usize };

pub fn decodeAt(text: []const u8, i: usize) Decoded {
    const b = text[i];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const len: usize = if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
    if (len == 1 or i + len > text.len) return .{ .cp = b, .len = 1 };
    var cp: u21 = switch (len) {
        2 => b & 0x1F,
        3 => b & 0x0F,
        else => b & 0x07,
    };
    for (text[i + 1 .. i + len]) |c| cp = (cp << 6) | (c & 0x3F);
    return .{ .cp = cp, .len = len };
}

pub fn codePointCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |b| {
        if ((b & 0xC0) != 0x80) count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Exact decimal view of a JSON number: value = digits * 10^exp, where digits
// has no leading or trailing zeros (empty means zero).

pub const Decimal = struct {
    int: []const u8,
    frac: []const u8,
    lead: usize,
    end: usize,
    exp: i64,

    pub fn digit(d: Decimal, index: usize) u8 {
        return if (index < d.int.len) d.int[index] - '0' else d.frac[index - d.int.len] - '0';
    }

    pub fn isZero(d: Decimal) bool {
        return d.lead >= d.end;
    }

    pub fn digitCount(d: Decimal) usize {
        return d.end - d.lead;
    }
};

pub fn decimal(text: []const u8) Decimal {
    var i: usize = 0;
    if (text[0] == '-') i = 1;
    const int_start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    const int = text[int_start..i];
    var frac: []const u8 = "";
    if (i < text.len and text[i] == '.') {
        const frac_start = i + 1;
        i = frac_start;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        frac = text[frac_start..i];
    }
    var exp: i64 = 0;
    if (i < text.len) {
        i += 1;
        var negative = false;
        if (text[i] == '+' or text[i] == '-') {
            negative = text[i] == '-';
            i += 1;
        }
        while (i < text.len) : (i += 1) {
            if (exp < 1_000_000_000) exp = exp * 10 + (text[i] - '0');
        }
        if (negative) exp = -exp;
    }
    var d = Decimal{ .int = int, .frac = frac, .lead = 0, .end = int.len + frac.len, .exp = exp - @as(i64, @intCast(frac.len)) };
    while (d.lead < d.end and d.digit(d.lead) == 0) d.lead += 1;
    while (d.end > d.lead and d.digit(d.end - 1) == 0) {
        d.end -= 1;
        d.exp += 1;
    }
    return d;
}

pub fn isIntegral(n: Number) bool {
    if (std.mem.indexOfAny(u8, n.text, ".eE") == null) return true;
    const d = decimal(n.text);
    return d.isZero() or d.exp >= 0;
}

// a * b mod m for a, b < m < 2^127. Small moduli multiply directly; larger
// ones double and add so nothing overflows.
pub fn mulMod(a: u128, b: u128, m: u128) u128 {
    if (m <= std.math.maxInt(u64)) return (a * b) % m;
    var result: u128 = 0;
    var x = a;
    var y = b;
    while (y > 0) : (y >>= 1) {
        if ((y & 1) != 0) result = (result + x) % m;
        x = (x + x) % m;
    }
    return result;
}

pub fn powMod(base: u128, exponent: u64, modulus: u128) u128 {
    var result: u128 = 1 % modulus;
    var b = base % modulus;
    var e = exponent;
    while (e > 0) : (e >>= 1) {
        if ((e & 1) != 0) result = mulMod(result, b, modulus);
        b = mulMod(b, b, modulus);
    }
    return result;
}

// Orders two JSON numbers by exact value. -0 equals 0.
pub fn compareNumbers(a: []const u8, b: []const u8) std.math.Order {
    if (smallNumber(a)) |x| if (smallNumber(b)) |y| {
        // Scale both to the same number of decimal places, unless that
        // overflows.
        const places = @max(x.places, y.places);
        const sx = @mulWithOverflow(x.value, pow10[places - x.places]);
        const sy = @mulWithOverflow(y.value, pow10[places - y.places]);
        if (sx[1] == 0 and sy[1] == 0) return std.math.order(sx[0], sy[0]);
    };
    return compareDecimals(a, b);
}

pub fn compareDecimals(a: []const u8, b: []const u8) std.math.Order {
    const da = decimal(a);
    const db = decimal(b);
    const sa: i2 = if (da.isZero()) 0 else if (a[0] == '-') -1 else 1;
    const sb: i2 = if (db.isZero()) 0 else if (b[0] == '-') -1 else 1;
    if (sa != sb) return std.math.order(sa, sb);
    if (sa == 0) return .eq;
    const magnitude = compareMagnitude(da, db);
    return if (sa < 0) magnitude.invert() else magnitude;
}

pub const SmallNumber = struct { value: i64, places: u8 };

pub const pow10 = blk: {
    var t: [19]i64 = undefined;
    t[0] = 1;
    for (1..t.len) |i| t[i] = t[i - 1] * 10;
    break :blk t;
};

// The common case: no exponent and at most 18 digits, read as an integer
// count of 10^-places. Anything else takes the Decimal path.
pub fn smallNumber(text: []const u8) ?SmallNumber {
    var i: usize = 0;
    const negative = text[0] == '-';
    if (negative) i = 1;
    var value: i64 = 0;
    var digits: usize = 0;
    var places: u8 = 0;
    var after_point = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '.') {
            after_point = true;
            continue;
        }
        if (c < '0' or c > '9') return null;
        digits += 1;
        if (digits > 18) return null;
        value = value * 10 + (c - '0');
        if (after_point) places += 1;
    }
    return .{ .value = if (negative) -value else value, .places = places };
}

pub fn compareMagnitude(a: Decimal, b: Decimal) std.math.Order {
    // The leading digit's place value decides first, then digit by digit.
    const pa = a.exp + @as(i64, @intCast(a.digitCount()));
    const pb = b.exp + @as(i64, @intCast(b.digitCount()));
    if (pa != pb) return std.math.order(pa, pb);
    const n = @max(a.digitCount(), b.digitCount());
    for (0..n) |i| {
        const x: u8 = if (i < a.digitCount()) a.digit(a.lead + i) else 0;
        const y: u8 = if (i < b.digitCount()) b.digit(b.lead + i) else 0;
        if (x != y) return std.math.order(x, y);
    }
    return .eq;
}

// Orders a count (string length, item count) against a schema number.
pub fn compareCount(count: usize, v: *const Value) Error!std.math.Order {
    if (v.* != .number) return error.BadSchema;
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var c = count;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(c % 10));
        c /= 10;
        if (c == 0) break;
    }
    return compareNumbers(buf[i..], v.number.text);
}

pub fn isMultipleOf(x: Number, m: Number) Error!bool {
    const dx = decimal(x.text);
    const dm = decimal(m.text);
    if (dm.isZero()) return false;
    if (dx.isZero()) return true;
    // Below 10^37 the running remainder times 10 still fits in a u128.
    if (dm.digitCount() > 37) return error.Unsupported;
    var modulus: u128 = 0;
    for (dm.lead..dm.end) |index| modulus = modulus * 10 + dm.digit(index);
    // x / m = (dx.digits / dm.digits) * 10^(dx.exp - dm.exp). When the
    // exponent difference is negative the quotient would need dx.digits to be
    // a multiple of 10, which trailing-zero stripping rules out.
    const shift = dx.exp - dm.exp;
    if (shift < 0) return false;
    var r: u128 = 0;
    for (dx.lead..dx.end) |index| r = (r * 10 + dx.digit(index)) % modulus;
    r = mulMod(r, powMod(10, @intCast(shift), modulus), modulus);
    return r == 0;
}

pub fn jsonEqual(a: *const Value, b: *const Value) bool {
    switch (a.*) {
        .null => return b.* == .null,
        .boolean => |x| return b.* == .boolean and b.boolean == x,
        .number => |x| return b.* == .number and compareNumbers(x.text, b.number.text) == .eq,
        .string => |x| return b.* == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b.* != .array or b.array.len != x.len) return false;
            for (x, b.array) |*l, *r| {
                if (!jsonEqual(l, r)) return false;
            }
            return true;
        },
        .object => |x| {
            if (b.* != .object or b.object.len != x.len) return false;
            for (x) |*member| {
                const other = get(b.object, member.key) orelse return false;
                if (!jsonEqual(&member.value, other)) return false;
            }
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Envelope input

pub const Envelope = struct {
    schema: ?*const Value = null,
    instance: ?*const Value = null,
    instance_bytes: []const u8 = "",
    schemas: []const Member = &.{},
};

// Parses the envelope object. Each member value is parsed at depth 0, so
// MAX_DEPTH means the same as it does for a standalone document.
pub fn parseEnvelope(alloc: std.mem.Allocator, scratch: std.mem.Allocator, src: []const u8) Error!Envelope {
    var p = JsonParser{ .src = src, .alloc = alloc, .scratch = scratch };
    var env = Envelope{};
    var seen_schemas = false;
    p.skipWs();
    if (p.pos >= src.len or src[p.pos] != '{') return error.InvalidEnvelope;
    p.pos += 1;
    p.skipWs();
    if (p.pos < src.len and src[p.pos] == '}') return error.MissingKey;
    while (true) {
        p.skipWs();
        if (p.pos >= src.len or src[p.pos] != '"') return error.InvalidJson;
        const key = try p.parseString();
        p.skipWs();
        if (p.pos >= src.len or src[p.pos] != ':') return error.InvalidJson;
        p.pos += 1;
        p.skipWs();
        const start = p.pos;
        const value = try alloc.create(Value);
        value.* = try p.parseTree();
        if (std.mem.eql(u8, key, "schema")) {
            if (env.schema != null) return error.InvalidEnvelope;
            env.schema = value;
        } else if (std.mem.eql(u8, key, "instance")) {
            if (env.instance != null) return error.InvalidEnvelope;
            env.instance = value;
            env.instance_bytes = src[start..p.pos];
        } else if (std.mem.eql(u8, key, "schemas")) {
            if (seen_schemas or value.* != .object) return error.InvalidEnvelope;
            seen_schemas = true;
            env.schemas = value.object;
        } else return error.InvalidEnvelope;
        p.skipWs();
        if (p.pos >= src.len) return error.InvalidJson;
        if (src[p.pos] == ',') {
            p.pos += 1;
            continue;
        }
        if (src[p.pos] == '}') {
            p.pos += 1;
            break;
        }
        return error.InvalidJson;
    }
    p.skipWs();
    if (p.pos != src.len) return error.InvalidJson;
    return env;
}

// ---------------------------------------------------------------------------
// URI references (RFC 3986 section 5)

pub const Uri = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

pub fn parseUri(s: []const u8) Uri {
    var u = Uri{};
    var rest = s;
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
        u.fragment = rest[hash + 1 ..];
        rest = rest[0..hash];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        u.query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    if (rest.len > 0 and std.ascii.isAlphabetic(rest[0])) {
        var i: usize = 1;
        while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '+' or rest[i] == '-' or rest[i] == '.')) i += 1;
        if (i < rest.len and rest[i] == ':') {
            u.scheme = rest[0..i];
            rest = rest[i + 1 ..];
        }
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        const end = std.mem.indexOfScalarPos(u8, rest, 2, '/') orelse rest.len;
        u.authority = rest[2..end];
        rest = rest[end..];
    }
    u.path = rest;
    return u;
}

pub fn removeDotSegments(alloc: std.mem.Allocator, path: []const u8) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var input = path;
    while (input.len > 0) {
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        } else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..];
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        } else if (std.mem.startsWith(u8, input, "/../") or std.mem.eql(u8, input, "/..")) {
            input = if (input.len == 3) "/" else input[3..];
            const cut = std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0;
            out.shrinkRetainingCapacity(cut);
        } else if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) {
            input = "";
        } else {
            const start: usize = if (input[0] == '/') 1 else 0;
            const end = std.mem.indexOfScalarPos(u8, input, start, '/') orelse input.len;
            try out.appendSlice(alloc, input[0..end]);
            input = input[end..];
        }
    }
    return out.items;
}

pub fn resolveUri(alloc: std.mem.Allocator, base_text: []const u8, ref_text: []const u8) Error![]const u8 {
    const r = parseUri(ref_text);
    const base = parseUri(base_text);
    var t = Uri{};
    if (r.scheme != null) {
        t = r;
        t.path = try removeDotSegments(alloc, r.path);
    } else {
        t.scheme = base.scheme;
        if (r.authority != null) {
            t.authority = r.authority;
            t.path = try removeDotSegments(alloc, r.path);
            t.query = r.query;
        } else {
            t.authority = base.authority;
            if (r.path.len == 0) {
                t.path = base.path;
                t.query = r.query orelse base.query;
            } else {
                if (r.path[0] == '/') {
                    t.path = try removeDotSegments(alloc, r.path);
                } else {
                    const merged = if (base.authority != null and base.path.len == 0)
                        try std.mem.concat(alloc, u8, &.{ "/", r.path })
                    else
                        try std.mem.concat(alloc, u8, &.{ base.path[0 .. if (std.mem.lastIndexOfScalar(u8, base.path, '/')) |slash| slash + 1 else 0], r.path });
                    t.path = try removeDotSegments(alloc, merged);
                }
                t.query = r.query;
            }
        }
        t.fragment = r.fragment;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (t.scheme) |s| {
        try out.appendSlice(alloc, s);
        try out.append(alloc, ':');
    }
    if (t.authority) |a| {
        try out.appendSlice(alloc, "//");
        try out.appendSlice(alloc, a);
    }
    try out.appendSlice(alloc, t.path);
    if (t.query) |q| {
        try out.append(alloc, '?');
        try out.appendSlice(alloc, q);
    }
    if (t.fragment) |f| {
        if (f.len > 0) {
            try out.append(alloc, '#');
            try out.appendSlice(alloc, f);
        }
    }
    return out.items;
}

pub fn splitFragment(uri: []const u8) struct { base: []const u8, fragment: []const u8 } {
    if (std.mem.indexOfScalar(u8, uri, '#')) |hash| return .{ .base = uri[0..hash], .fragment = uri[hash + 1 ..] };
    return .{ .base = uri, .fragment = "" };
}

pub fn percentDecode(alloc: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    const out = try alloc.alloc(u8, text.len);
    var o: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (o += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.BadSchema;
            out[o] = byte;
            i += 3;
        } else {
            out[o] = text[i];
            i += 1;
        }
    }
    return out[0..o];
}

// ---------------------------------------------------------------------------
// Regular expressions: ECMA-262 subset compiled for a Pike VM.

pub const Class = struct {
    negated: bool = false,
    letter: bool = false,
    not_letter: bool = false,
    ranges: []const [2]u21 = &.{},

    pub fn matches(c: Class, cp: u21) bool {
        var hit = false;
        for (c.ranges) |r| {
            if (cp >= r[0] and cp <= r[1]) {
                hit = true;
                break;
            }
        }
        if (!hit and c.letter and unicode_letter.isLetter(cp)) hit = true;
        if (!hit and c.not_letter and !unicode_letter.isLetter(cp)) hit = true;
        return hit != c.negated;
    }
};

pub const Inst = union(enum) {
    char: u21,
    any,
    class: Class,
    split: [2]u32,
    jmp: u32,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    match,
};

pub const RNode = union(enum) {
    empty,
    char: u21,
    any,
    class: Class,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    cat: []RNode,
    alt: []RNode,
    rep: struct { child: *RNode, min: u32, max: ?u32 },
};

// anchored: the pattern starts with ^ outside any group, so a match can only
// begin at offset 0.
pub const Regex = struct { insts: []Inst, anchored: bool };

pub const digit_ranges = [_][2]u21{.{ '0', '9' }};
pub const word_ranges = [_][2]u21{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };
pub const space_ranges = [_][2]u21{
    .{ 0x09, 0x0D }, .{ 0x20, 0x20 },     .{ 0xA0, 0xA0 },     .{ 0x1680, 0x1680 },
    .{ 0x2000, 0x200A }, .{ 0x2028, 0x2029 }, .{ 0x202F, 0x202F }, .{ 0x205F, 0x205F },
    .{ 0x3000, 0x3000 }, .{ 0xFEFF, 0xFEFF },
};

pub fn complement(alloc: std.mem.Allocator, ranges: []const [2]u21) Error![]const [2]u21 {
    var out: std.ArrayListUnmanaged([2]u21) = .empty;
    var next: u21 = 0;
    for (ranges) |r| {
        if (r[0] > next) try out.append(alloc, .{ next, r[0] - 1 });
        next = r[1] + 1;
    }
    if (next <= 0x10FFFF) try out.append(alloc, .{ next, 0x10FFFF });
    return out.items;
}

pub fn isWordChar(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
}

pub const RegexParser = struct {
    pat: []const u21,
    pos: usize = 0,
    depth: usize = 0,
    alloc: std.mem.Allocator,

    pub fn peek(p: *RegexParser) ?u21 {
        return if (p.pos < p.pat.len) p.pat[p.pos] else null;
    }

    pub fn eat(p: *RegexParser, c: u21) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    pub fn parseAlt(p: *RegexParser) Error!RNode {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 64) return error.Unsupported;
        var branches: std.ArrayListUnmanaged(RNode) = .empty;
        try branches.append(p.alloc, try p.parseCat());
        while (p.eat('|')) try branches.append(p.alloc, try p.parseCat());
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    pub fn parseCat(p: *RegexParser) Error!RNode {
        var items: std.ArrayListUnmanaged(RNode) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(p.alloc, try p.parseRepeat());
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .cat = items.items };
    }

    pub fn parseInt(p: *RegexParser) ?u32 {
        const start = p.pos;
        var value: u32 = 0;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            value = std.math.mul(u32, value, 10) catch return null;
            value += @intCast(c - '0');
            p.pos += 1;
        }
        return if (p.pos == start) null else value;
    }

    pub fn parseRepeat(p: *RegexParser) Error!RNode {
        var atom = try p.parseAtom();
        while (p.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => p.pos += 1,
                '+' => {
                    p.pos += 1;
                    min = 1;
                },
                '?' => {
                    p.pos += 1;
                    max = 1;
                },
                '{' => {
                    p.pos += 1;
                    min = p.parseInt() orelse return error.Unsupported;
                    max = min;
                    if (p.eat(',')) max = p.parseInt();
                    if (!p.eat('}')) return error.Unsupported;
                    if (max) |m| if (m < min) return error.BadSchema;
                },
                else => break,
            }
            // Laziness changes which match is found, not whether one exists.
            _ = p.eat('?');
            const child = try p.alloc.create(RNode);
            child.* = atom;
            atom = .{ .rep = .{ .child = child, .min = min, .max = max } };
        }
        return atom;
    }

    pub fn hexValue(p: *RegexParser, count: usize) Error!u21 {
        var value: u21 = 0;
        for (0..count) |_| {
            const c = p.peek() orelse return error.Unsupported;
            const digit: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.Unsupported,
            };
            value = value * 16 + digit;
            p.pos += 1;
        }
        return value;
    }

    const Escape = union(enum) { char: u21, class: Class, word_boundary, not_word_boundary };

    pub fn parseEscape(p: *RegexParser, in_class: bool) Error!Escape {
        const c = p.peek() orelse return error.Unsupported;
        p.pos += 1;
        switch (c) {
            'd' => return .{ .class = .{ .ranges = &digit_ranges } },
            'D' => return .{ .class = .{ .ranges = try complement(p.alloc, &digit_ranges) } },
            'w' => return .{ .class = .{ .ranges = &word_ranges } },
            'W' => return .{ .class = .{ .ranges = try complement(p.alloc, &word_ranges) } },
            's' => return .{ .class = .{ .ranges = &space_ranges } },
            'S' => return .{ .class = .{ .ranges = try complement(p.alloc, &space_ranges) } },
            'b' => return if (in_class) .{ .char = 0x08 } else .word_boundary,
            'B' => {
                if (in_class) return error.Unsupported;
                return .not_word_boundary;
            },
            'p', 'P' => {
                if (!p.eat('{')) return error.Unsupported;
                const start = p.pos;
                while (p.peek()) |n| {
                    if (n == '}') break;
                    p.pos += 1;
                }
                const name = p.pat[start..p.pos];
                if (!p.eat('}')) return error.Unsupported;
                const is_letter = (name.len == 1 and name[0] == 'L') or
                    (name.len == 6 and std.mem.eql(u21, name, &[_]u21{ 'L', 'e', 't', 't', 'e', 'r' }));
                if (!is_letter) return error.Unsupported;
                return .{ .class = if (c == 'p') .{ .letter = true } else .{ .not_letter = true } };
            },
            't' => return .{ .char = '\t' },
            'n' => return .{ .char = '\n' },
            'r' => return .{ .char = '\r' },
            'v' => return .{ .char = 0x0B },
            'f' => return .{ .char = 0x0C },
            '0' => {
                if (p.peek()) |n| if (n >= '0' and n <= '9') return error.Unsupported;
                return .{ .char = 0 };
            },
            'x' => return .{ .char = try p.hexValue(2) },
            'u' => {
                if (p.eat('{')) {
                    var value: u21 = 0;
                    var digits: usize = 0;
                    while (!p.eat('}')) {
                        if (digits >= 6) return error.Unsupported;
                        value = value * 16 + try p.hexValue(1);
                        digits += 1;
                    }
                    if (digits == 0 or value > 0x10FFFF) return error.Unsupported;
                    return .{ .char = value };
                }
                var value = try p.hexValue(4);
                if (value >= 0xD800 and value <= 0xDBFF and p.pos + 6 <= p.pat.len and p.pat[p.pos] == '\\' and p.pat[p.pos + 1] == 'u') {
                    const saved = p.pos;
                    p.pos += 2;
                    const low = try p.hexValue(4);
                    if (low >= 0xDC00 and low <= 0xDFFF) {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00);
                    } else p.pos = saved;
                }
                return .{ .char = value };
            },
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => return .{ .char = c },
            '-' => {
                if (!in_class) return error.Unsupported;
                return .{ .char = '-' };
            },
            else => return error.Unsupported,
        }
    }

    pub fn parseClass(p: *RegexParser) Error!Class {
        var class = Class{ .negated = p.eat('^') };
        var ranges: std.ArrayListUnmanaged([2]u21) = .empty;
        while (true) {
            const c = p.peek() orelse return error.Unsupported;
            if (c == ']') {
                p.pos += 1;
                break;
            }
            var lo: u21 = undefined;
            p.pos += 1;
            if (c == '\\') {
                switch (try p.parseEscape(true)) {
                    .char => |ch| lo = ch,
                    .class => |set| {
                        try ranges.appendSlice(p.alloc, set.ranges);
                        if (set.letter) class.letter = true;
                        if (set.not_letter) class.not_letter = true;
                        continue;
                    },
                    else => return error.Unsupported,
                }
            } else lo = c;
            if (p.peek() == '-' and p.pos + 1 < p.pat.len and p.pat[p.pos + 1] != ']') {
                p.pos += 1;
                const h = p.peek() orelse return error.Unsupported;
                p.pos += 1;
                var hi: u21 = h;
                if (h == '\\') {
                    switch (try p.parseEscape(true)) {
                        .char => |ch| hi = ch,
                        else => return error.Unsupported,
                    }
                }
                if (hi < lo) return error.BadSchema;
                try ranges.append(p.alloc, .{ lo, hi });
            } else try ranges.append(p.alloc, .{ lo, lo });
        }
        class.ranges = ranges.items;
        return class;
    }

    pub fn parseAtom(p: *RegexParser) Error!RNode {
        const c = p.peek() orelse return error.Unsupported;
        p.pos += 1;
        switch (c) {
            '(' => {
                if (p.eat('?')) {
                    if (p.eat(':')) {} else if (p.eat('<')) {
                        const n = p.peek() orelse return error.Unsupported;
                        if (n == '=' or n == '!') return error.Unsupported;
                        while (!p.eat('>')) {
                            if (p.peek() == null) return error.Unsupported;
                            p.pos += 1;
                        }
                    } else return error.Unsupported;
                }
                const inner = try p.parseAlt();
                if (!p.eat(')')) return error.Unsupported;
                return inner;
            },
            '[' => return .{ .class = try p.parseClass() },
            '.' => return .any,
            '^' => return .bol,
            '$' => return .eol,
            '\\' => return switch (try p.parseEscape(false)) {
                .char => |ch| .{ .char = ch },
                .class => |set| .{ .class = set },
                .word_boundary => .word_boundary,
                .not_word_boundary => .not_word_boundary,
            },
            '*', '+', '?', '{', '}', ']', ')' => return error.Unsupported,
            else => return .{ .char = c },
        }
    }
};

pub const RegexCompiler = struct {
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    alloc: std.mem.Allocator,

    pub fn emit(c: *RegexCompiler, inst: Inst) Error!u32 {
        if (c.insts.items.len >= MAX_REGEX_INSTS) return error.Unsupported;
        try c.insts.append(c.alloc, inst);
        return @intCast(c.insts.items.len - 1);
    }

    pub fn here(c: *RegexCompiler) u32 {
        return @intCast(c.insts.items.len);
    }

    pub fn compile(c: *RegexCompiler, node: RNode) Error!void {
        switch (node) {
            .empty => {},
            .char => |ch| _ = try c.emit(.{ .char = ch }),
            .any => _ = try c.emit(.any),
            .class => |cl| _ = try c.emit(.{ .class = cl }),
            .bol => _ = try c.emit(.bol),
            .eol => _ = try c.emit(.eol),
            .word_boundary => _ = try c.emit(.word_boundary),
            .not_word_boundary => _ = try c.emit(.not_word_boundary),
            .cat => |items| for (items) |item| try c.compile(item),
            .alt => |branches| {
                var jumps: std.ArrayListUnmanaged(u32) = .empty;
                for (branches, 0..) |branch, index| {
                    if (index + 1 < branches.len) {
                        const split = try c.emit(.{ .split = .{ 0, 0 } });
                        c.insts.items[split].split[0] = c.here();
                        try c.compile(branch);
                        try jumps.append(c.alloc, try c.emit(.{ .jmp = 0 }));
                        c.insts.items[split].split[1] = c.here();
                    } else try c.compile(branch);
                }
                for (jumps.items) |j| c.insts.items[j].jmp = c.here();
            },
            .rep => |r| {
                for (0..r.min) |_| try c.compile(r.child.*);
                if (r.max) |max| {
                    var exits: std.ArrayListUnmanaged(u32) = .empty;
                    for (r.min..max) |_| {
                        const split = try c.emit(.{ .split = .{ 0, 0 } });
                        c.insts.items[split].split[0] = c.here();
                        try exits.append(c.alloc, split);
                        try c.compile(r.child.*);
                    }
                    for (exits.items) |s| c.insts.items[s].split[1] = c.here();
                } else {
                    const split = try c.emit(.{ .split = .{ 0, 0 } });
                    c.insts.items[split].split[0] = c.here();
                    try c.compile(r.child.*);
                    _ = try c.emit(.{ .jmp = split });
                    c.insts.items[split].split[1] = c.here();
                }
            },
        }
    }
};

pub fn compileRegex(alloc: std.mem.Allocator, pattern: []const u8) Error!Regex {
    var cps: std.ArrayListUnmanaged(u21) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        const d = decodeAt(pattern, i);
        try cps.append(alloc, d.cp);
        i += d.len;
    }
    var parser = RegexParser{ .pat = cps.items, .alloc = alloc };
    const tree = try parser.parseAlt();
    if (parser.pos != cps.items.len) return error.Unsupported;
    var compiler = RegexCompiler{ .alloc = alloc };
    try compiler.compile(tree);
    _ = try compiler.emit(.match);
    const anchored = switch (tree) {
        .bol => true,
        .cat => |items| items[0] == .bol,
        else => false,
    };
    return .{ .insts = compiler.insts.items, .anchored = anchored };
}

pub const PikeVm = struct {
    insts: []const Inst,
    text: []const u8,
    marks: []u32,
    stack: []u32,
    gen: u32 = 0,

    pub fn prevCp(vm: *PikeVm, pos: usize) ?u21 {
        if (pos == 0) return null;
        var start = pos - 1;
        while (start > 0 and (vm.text[start] & 0xC0) == 0x80) start -= 1;
        return decodeAt(vm.text, start).cp;
    }

    pub fn atWordBoundary(vm: *PikeVm, pos: usize) bool {
        const before = if (vm.prevCp(pos)) |cp| isWordChar(cp) else false;
        const after = if (pos < vm.text.len) isWordChar(decodeAt(vm.text, pos).cp) else false;
        return before != after;
    }

    // Follows jumps and zero-width assertions from pc, adding consuming
    // instructions to list. Returns true if the closure reaches match.
    pub fn add(vm: *PikeVm, list: []u32, count: *usize, pc0: u32, pos: usize) bool {
        var top: usize = 0;
        vm.stack[top] = pc0;
        top += 1;
        while (top > 0) {
            top -= 1;
            const pc = vm.stack[top];
            if (vm.marks[pc] == vm.gen) continue;
            vm.marks[pc] = vm.gen;
            switch (vm.insts[pc]) {
                .match => return true,
                .jmp => |target| {
                    vm.stack[top] = target;
                    top += 1;
                },
                .split => |targets| {
                    vm.stack[top] = targets[1];
                    vm.stack[top + 1] = targets[0];
                    top += 2;
                },
                .bol => if (pos == 0) {
                    vm.stack[top] = pc + 1;
                    top += 1;
                },
                .eol => if (pos == vm.text.len) {
                    vm.stack[top] = pc + 1;
                    top += 1;
                },
                .word_boundary => if (vm.atWordBoundary(pos)) {
                    vm.stack[top] = pc + 1;
                    top += 1;
                },
                .not_word_boundary => if (!vm.atWordBoundary(pos)) {
                    vm.stack[top] = pc + 1;
                    top += 1;
                },
                else => {
                    list[count.*] = pc;
                    count.* += 1;
                },
            }
        }
        return false;
    }
};

// Unanchored search: does the pattern match anywhere in text?
pub fn regexSearch(scratch: std.mem.Allocator, regex: Regex, text: []const u8) Error!bool {
    const n = regex.insts.len;
    const buffers = try scratch.alloc(u32, n * 5);
    var vm = PikeVm{
        .insts = regex.insts,
        .text = text,
        .marks = buffers[0..n],
        .stack = buffers[n .. 3 * n],
    };
    @memset(vm.marks, 0);
    var clist = buffers[3 * n .. 4 * n];
    var nlist = buffers[4 * n .. 5 * n];
    var ccount: usize = 0;
    var pos: usize = 0;
    vm.gen = 1;
    while (true) {
        if (pos == 0 or !regex.anchored) {
            if (vm.add(clist, &ccount, 0, pos)) return true;
        } else if (ccount == 0) return false;
        if (pos >= text.len) return false;
        const d = decodeAt(text, pos);
        vm.gen += 1;
        var ncount: usize = 0;
        for (clist[0..ccount]) |pc| {
            const hit = switch (vm.insts[pc]) {
                .char => |ch| ch == d.cp,
                .any => d.cp != '\n' and d.cp != '\r' and d.cp != 0x2028 and d.cp != 0x2029,
                .class => |cl| cl.matches(d.cp),
                else => false,
            };
            if (hit and vm.add(nlist, &ncount, pc + 1, pos + d.len)) return true;
        }
        std.mem.swap([]u32, &clist, &nlist);
        ccount = ncount;
        pos += d.len;
    }
}

// ---------------------------------------------------------------------------
// Schema index

pub const Vocab = packed struct {
    applicator: bool = true,
    validation: bool = true,
    unevaluated: bool = true,
};

// Every keyword the evaluator reads, looked up once per schema object when
// it is indexed rather than by scanning its members on every visit.
pub const Keywords = struct {
    @"$ref": ?*const Value = null,
    @"$dynamicRef": ?*const Value = null,
    allOf: ?*const Value = null,
    anyOf: ?*const Value = null,
    oneOf: ?*const Value = null,
    not: ?*const Value = null,
    @"if": ?*const Value = null,
    then: ?*const Value = null,
    @"else": ?*const Value = null,
    prefixItems: ?*const Value = null,
    items: ?*const Value = null,
    contains: ?*const Value = null,
    minContains: ?*const Value = null,
    maxContains: ?*const Value = null,
    properties: ?*const Value = null,
    patternProperties: ?*const Value = null,
    additionalProperties: ?*const Value = null,
    dependentSchemas: ?*const Value = null,
    propertyNames: ?*const Value = null,
    unevaluatedItems: ?*const Value = null,
    unevaluatedProperties: ?*const Value = null,
    type: ?*const Value = null,
    @"const": ?*const Value = null,
    @"enum": ?*const Value = null,
    multipleOf: ?*const Value = null,
    maximum: ?*const Value = null,
    exclusiveMaximum: ?*const Value = null,
    minimum: ?*const Value = null,
    exclusiveMinimum: ?*const Value = null,
    maxLength: ?*const Value = null,
    minLength: ?*const Value = null,
    pattern: ?*const Value = null,
    maxItems: ?*const Value = null,
    minItems: ?*const Value = null,
    uniqueItems: ?*const Value = null,
    maxProperties: ?*const Value = null,
    minProperties: ?*const Value = null,
    required: ?*const Value = null,
    dependentRequired: ?*const Value = null,

    const fields = std.meta.fields(Keywords);
    const names = std.StaticStringMap(u8).initComptime(blk: {
        var kvs: [fields.len]struct { []const u8, u8 } = undefined;
        for (fields, 0..) |field, i| kvs[i] = .{ field.name, i };
        break :blk kvs;
    });

    pub fn of(alloc: std.mem.Allocator, obj: []const Member) Error!*const Keywords {
        const kw = try alloc.create(Keywords);
        kw.* = .{};
        for (obj) |*member| {
            const index = names.get(member.key) orelse continue;
            inline for (fields, 0..) |field, i| {
                if (i == index) @field(kw, field.name) = &member.value;
            }
        }
        return kw;
    }
};

pub const Info = struct { base: []const u8, vocab: Vocab, kw: ?*const Keywords = null };

pub const InfoSlot = struct { key: usize = 0, info: Info = undefined };

// Maps a nonzero address to a nonzero word with open addressing. One
// non-generic table serves every pointer-keyed lookup (schema info, resolved
// $ref targets, compiled regexes); values that are not already pointers are
// stored as pointers into the arena. std.HashMap would instantiate its insert
// and probe code once per key/value type.
pub const PtrTable = struct {
    keys: []usize = &.{},
    vals: []usize = &.{},
    len: usize = 0,

    pub fn slot(t: *const PtrTable, key: usize) usize {
        const mask = t.keys.len - 1;
        var i = ((key >> 2) *% 0x9E3779B1) & mask;
        while (t.keys[i] != 0 and t.keys[i] != key) i = (i + 1) & mask;
        return i;
    }

    pub fn get(t: *const PtrTable, key: usize) ?usize {
        if (t.keys.len == 0) return null;
        const i = t.slot(key);
        return if (t.keys[i] == key) t.vals[i] else null;
    }

    pub fn put(t: *PtrTable, alloc: std.mem.Allocator, key: usize, val: usize) Error!void {
        if (t.len * 2 >= t.keys.len) {
            const old_keys = t.keys;
            const old_vals = t.vals;
            const cap = @max(64, old_keys.len * 2);
            t.keys = try alloc.alloc(usize, cap);
            t.vals = try alloc.alloc(usize, cap);
            @memset(t.keys, 0);
            for (old_keys, old_vals) |k, v| {
                if (k != 0) {
                    const i = t.slot(k);
                    t.keys[i] = k;
                    t.vals[i] = v;
                }
            }
        }
        const i = t.slot(key);
        if (t.keys[i] == 0) t.len += 1;
        t.keys[i] = key;
        t.vals[i] = val;
    }
};

// A string-keyed list searched linearly. Schema resources and anchors number
// in the tens, and the URIs are resolved once per $ref and then cached.
pub const StrList = struct {
    items: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct { key: []const u8, val: *const Value };

    pub fn get(l: *const StrList, key: []const u8) ?*const Value {
        for (l.items.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.val;
        }
        return null;
    }

    // Later definitions replace earlier ones, as HashMap.put did.
    pub fn put(l: *StrList, alloc: std.mem.Allocator, key: []const u8, val: *const Value) Error!void {
        for (l.items.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.val = val;
                return;
            }
        }
        try l.items.append(alloc, .{ .key = key, .val = val });
    }
};

pub const State = struct {
    alloc: std.mem.Allocator,
    scratch: *std.heap.FixedBufferAllocator,
    infos: PtrTable = .{}, // *const Value -> *Info
    refs: PtrTable = .{}, // $ref string node -> *const Value target
    regexes: PtrTable = .{}, // pattern slice -> *Regex
    resources: StrList = .{},
    anchors: StrList = .{},
    dynamic_anchors: StrList = .{},
    info_cache: [256]InfoSlot = [_]InfoSlot{.{}} ** 256,
    scope: [MAX_DEPTH][]const u8 = undefined,
    scope_len: usize = 0,
    depth: usize = 0,

    // Indexes an envelope's documents and returns its root schema. Supplied
    // documents come first so a document is also found by the $id it
    // declares, not only by its key. A URI an earlier document already
    // claimed through its $id is not loaded again.
    pub fn loadEnvelope(st: *State, env: Envelope) Error!*const Value {
        const root = env.schema orelse return error.MissingKey;
        for (env.schemas) |*member| {
            if (st.resources.get(member.key) != null) continue;
            try st.resources.put(st.alloc, member.key, &member.value);
            try st.index(&member.value, member.key, .{}, true);
        }
        try st.resources.put(st.alloc, DEFAULT_BASE, root);
        try st.index(root, DEFAULT_BASE, .{}, true);
        return root;
    }

    pub fn loadDocument(st: *State, uri: []const u8, json: []const u8) Error!*const Value {
        const root = try st.alloc.create(Value);
        root.* = try JsonParser.parseDocument(st.alloc, st.scratch.allocator(), json);
        try st.resources.put(st.alloc, uri, root);
        try st.index(root, uri, .{}, true);
        return root;
    }

    // Finds the schema resource for an absolute URI without a fragment,
    // parsing a built-in document the first time it is needed.
    pub fn resource(st: *State, uri: []const u8) Error!?*const Value {
        if (st.resources.get(uri)) |root| return root;
        for (embedded_schemas) |e| {
            if (std.mem.eql(u8, e.uri, uri)) {
                _ = try st.loadDocument(e.uri, e.json);
                return st.resources.get(uri);
            }
        }
        return null;
    }

    pub fn vocabFor(st: *State, meta_uri: []const u8) Error!Vocab {
        if (std.mem.eql(u8, meta_uri, DIALECT_2020_12)) return .{};
        const meta = (try st.resource(meta_uri)) orelse return error.Unsupported;
        if (meta.* != .object) return error.BadSchema;
        const vocabulary = get(meta.object, "$vocabulary") orelse return .{};
        if (vocabulary.* != .object) return error.BadSchema;
        var vocab = Vocab{ .applicator = false, .validation = false, .unevaluated = false };
        const prefix = "https://json-schema.org/draft/2020-12/vocab/";
        for (vocabulary.object) |member| {
            const required = member.value == .boolean and member.value.boolean;
            const name = if (std.mem.startsWith(u8, member.key, prefix)) member.key[prefix.len..] else "";
            if (std.mem.eql(u8, name, "applicator")) {
                vocab.applicator = true;
            } else if (std.mem.eql(u8, name, "validation")) {
                vocab.validation = true;
            } else if (std.mem.eql(u8, name, "unevaluated")) {
                vocab.unevaluated = true;
            } else if (std.mem.eql(u8, name, "core") or std.mem.eql(u8, name, "meta-data") or
                std.mem.eql(u8, name, "format-annotation") or std.mem.eql(u8, name, "content"))
            {} else if (required) return error.Unsupported;
        }
        return vocab;
    }

    // Records the base URI and vocabularies of every subschema, and registers
    // $id, $anchor and $dynamicAnchor. Only keywords whose values are schemas
    // are followed, so an "$id" inside enum or an unknown keyword is ignored.
    pub fn index(st: *State, node: *const Value, base_in: []const u8, vocab_in: Vocab, register: bool) Error!void {
        st.depth += 1;
        defer st.depth -= 1;
        if (st.depth > MAX_DEPTH) return error.TooDeep;
        var base = base_in;
        var vocab = vocab_in;
        switch (node.*) {
            .boolean => {
                try st.putInfo(node, .{ .base = base, .vocab = vocab });
                return;
            },
            .object => {},
            else => return,
        }
        const obj = node.object;
        if (get(obj, "$id")) |id| {
            if (id.* == .string) {
                base = splitFragment(try resolveUri(st.alloc, base, id.string)).base;
                if (register) try st.resources.put(st.alloc, base, node);
            }
        }
        if (get(obj, "$schema")) |dialect| {
            if (dialect.* == .string) vocab = try st.vocabFor(splitFragment(try resolveUri(st.alloc, base, dialect.string)).base);
        }
        if (register) {
            if (get(obj, "$anchor")) |anchor| {
                if (anchor.* == .string) try st.anchors.put(st.alloc, try std.mem.concat(st.alloc, u8, &.{ base, "#", anchor.string }), node);
            }
            if (get(obj, "$dynamicAnchor")) |anchor| {
                if (anchor.* == .string) {
                    const key = try std.mem.concat(st.alloc, u8, &.{ base, "#", anchor.string });
                    try st.anchors.put(st.alloc, key, node);
                    try st.dynamic_anchors.put(st.alloc, key, node);
                }
            }
        }
        try st.putInfo(node, .{ .base = base, .vocab = vocab, .kw = try Keywords.of(st.alloc, obj) });
        for (obj) |*member| {
            const k = member.key;
            const v = &member.value;
            if (isOneOf(k, &.{ "additionalProperties", "propertyNames", "unevaluatedItems", "unevaluatedProperties", "items", "contains", "not", "if", "then", "else" })) {
                try st.index(v, base, vocab, register);
            } else if (isOneOf(k, &.{ "properties", "patternProperties", "$defs", "dependentSchemas" })) {
                if (v.* == .object) for (v.object) |*sub| try st.index(&sub.value, base, vocab, register);
            } else if (isOneOf(k, &.{ "prefixItems", "allOf", "anyOf", "oneOf" })) {
                if (v.* == .array) for (v.array) |*sub| try st.index(sub, base, vocab, register);
            }
        }
    }

    pub fn putInfo(st: *State, node: *const Value, info: Info) Error!void {
        const slot = try st.alloc.create(Info);
        slot.* = info;
        try st.infos.put(st.alloc, @intFromPtr(node), @intFromPtr(slot));
    }

    pub fn findInfo(st: *const State, key: usize) ?*const Info {
        return @ptrFromInt(st.infos.get(key) orelse return null);
    }

    pub fn infoOf(st: *State, node: *const Value) Error!Info {
        // A few schemas ($defs entries, items) are visited once per instance
        // node, so a small direct-mapped cache saves most hash lookups.
        const key = @intFromPtr(node);
        const slot = &st.info_cache[(key >> 3) % st.info_cache.len];
        if (slot.key == key) return slot.info;
        const info = (st.findInfo(key) orelse return error.BadSchema).*;
        slot.* = .{ .key = key, .info = info };
        return info;
    }

    pub fn resolvePointer(st: *State, root: *const Value, pointer: []const u8) Error!*const Value {
        var node = root;
        var info = try st.infoOf(root);
        var rest = pointer;
        while (rest.len > 0) {
            if (rest[0] != '/') return error.BadSchema;
            rest = rest[1..];
            const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const raw = rest[0..end];
            rest = rest[end..];
            var token: std.ArrayListUnmanaged(u8) = .empty;
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == '~' and i + 1 < raw.len and (raw[i + 1] == '0' or raw[i + 1] == '1')) {
                    try token.append(st.alloc, if (raw[i + 1] == '0') '~' else '/');
                    i += 1;
                } else try token.append(st.alloc, raw[i]);
            }
            switch (node.*) {
                .object => |obj| node = get(obj, token.items) orelse return error.BadSchema,
                .array => |arr| {
                    const at = std.fmt.parseInt(usize, token.items, 10) catch return error.BadSchema;
                    if (at >= arr.len) return error.BadSchema;
                    node = &arr[at];
                },
                else => return error.BadSchema,
            }
            if (st.findInfo(@intFromPtr(node))) |found| info = found.*;
        }
        if (st.findInfo(@intFromPtr(node)) == null) try st.index(node, info.base, info.vocab, false);
        return node;
    }

    pub fn resolveRef(st: *State, ref_node: *const Value, base: []const u8) Error!*const Value {
        if (st.refs.get(@intFromPtr(ref_node))) |cached| return @ptrFromInt(cached);
        if (ref_node.* != .string) return error.BadSchema;
        const uri = try resolveUri(st.alloc, base, ref_node.string);
        const parts = splitFragment(uri);
        const fragment = try percentDecode(st.alloc, parts.fragment);
        const root = (try st.resource(parts.base)) orelse return error.BadSchema;
        const target = if (fragment.len == 0)
            root
        else if (fragment[0] == '/')
            try st.resolvePointer(root, fragment)
        else
            st.anchors.get(try std.mem.concat(st.alloc, u8, &.{ parts.base, "#", fragment })) orelse return error.BadSchema;
        try st.refs.put(st.alloc, @intFromPtr(ref_node), @intFromPtr(target));
        return target;
    }

    pub fn resolveDynamicRef(st: *State, ref_node: *const Value, base: []const u8) Error!*const Value {
        const initial = try st.resolveRef(ref_node, base);
        const uri = try resolveUri(st.alloc, base, ref_node.string);
        const parts = splitFragment(uri);
        if (parts.fragment.len == 0 or parts.fragment[0] == '/') return initial;
        // Dynamic resolution applies only when the static target is itself a
        // $dynamicAnchor with this name. Then the outermost resource in the
        // dynamic scope that declares the same dynamic anchor wins.
        const static_key = try std.mem.concat(st.alloc, u8, &.{ parts.base, "#", parts.fragment });
        if (st.dynamic_anchors.get(static_key) == null) return initial;
        for (st.scope[0..st.scope_len]) |scope_base| {
            const key = try std.mem.concat(st.alloc, u8, &.{ scope_base, "#", parts.fragment });
            if (st.dynamic_anchors.get(key)) |target| return target;
        }
        return initial;
    }

    pub fn regexFor(st: *State, pattern: []const u8) Error!Regex {
        const key = @intFromPtr(pattern.ptr) ^ (pattern.len << 20);
        if (key == 0) return compileRegex(st.alloc, pattern);
        if (st.regexes.get(key)) |r| return @as(*const Regex, @ptrFromInt(r)).*;
        const r = try st.alloc.create(Regex);
        r.* = try compileRegex(st.alloc, pattern);
        try st.regexes.put(st.alloc, key, @intFromPtr(r));
        return r.*;
    }

    pub fn matches(st: *State, pattern: []const u8, text: []const u8) Error!bool {
        const regex = try st.regexFor(pattern);
        const mark = st.scratch.end_index;
        defer st.scratch.end_index = mark;
        return regexSearch(st.scratch.allocator(), regex, text);
    }

    // -----------------------------------------------------------------------
    // Evaluation
    //
    // ann, when present, collects which object members or array items this
    // schema evaluated successfully, for unevaluatedProperties and
    // unevaluatedItems in an enclosing schema. A schema writes into ann only
    // on success paths that its caller keeps; callers isolate branches that
    // may fail without failing the whole schema (anyOf, oneOf, if, not).

    pub fn newBits(st: *State, len: usize) Error![]u64 {
        const bits = try st.scratch.allocator().alloc(u64, (len + 63) / 64);
        @memset(bits, 0);
        return bits;
    }

    pub fn validate(st: *State, schema: *const Value, inst: *const Value, ann: ?[]u64) Error!bool {
        switch (schema.*) {
            .boolean => |b| return b,
            .object => {},
            else => return error.BadSchema,
        }
        st.depth += 1;
        defer st.depth -= 1;
        if (st.depth > MAX_DEPTH) return error.TooDeep;

        const info = try st.infoOf(schema);
        const pushed = st.scope_len == 0 or !sameText(st.scope[st.scope_len - 1], info.base);
        if (pushed) {
            if (st.scope_len >= MAX_DEPTH) return error.TooDeep;
            st.scope[st.scope_len] = info.base;
            st.scope_len += 1;
        }
        defer if (pushed) {
            st.scope_len -= 1;
        };

        const kw = info.kw orelse return error.BadSchema;
        const vocab = info.vocab;
        const uneval_props = if (vocab.unevaluated and inst.* == .object) kw.@"unevaluatedProperties" else null;
        const uneval_items = if (vocab.unevaluated and inst.* == .array) kw.@"unevaluatedItems" else null;
        const mark = st.scratch.end_index;
        defer st.scratch.end_index = mark;

        const len: usize = switch (inst.*) {
            .object => |o| o.len,
            .array => |a| a.len,
            else => 0,
        };
        const own_bits = uneval_props != null or uneval_items != null;
        const local: ?[]u64 = if (own_bits) try st.newBits(len) else if (inst.* == .object or inst.* == .array) ann else null;

        if (kw.@"$ref") |ref| {
            if (!try st.validate(try st.resolveRef(ref, info.base), inst, local)) return false;
        }
        if (kw.@"$dynamicRef") |ref| {
            if (!try st.validate(try st.resolveDynamicRef(ref, info.base), inst, local)) return false;
        }
        if (vocab.applicator and !try st.applicators(kw, inst, local, vocab)) return false;
        if (vocab.validation and !try st.assertions(kw, inst)) return false;

        if (uneval_items) |sub| {
            const bits = local.?;
            for (inst.array, 0..) |*item, i| {
                if (bitSet(bits, i)) continue;
                if (!try st.validate(sub, item, null)) return false;
                setBit(bits, i);
            }
        }
        if (uneval_props) |sub| {
            const bits = local.?;
            for (inst.object, 0..) |*member, i| {
                if (bitSet(bits, i)) continue;
                if (!try st.validate(sub, &member.value, null)) return false;
                setBit(bits, i);
            }
        }
        if (own_bits) {
            if (ann) |out| orBits(out, local.?);
        }
        return true;
    }

    // Runs a subschema whose failure does not fail the parent, keeping its
    // annotations only when it passes.
    pub fn tryBranch(st: *State, sub: *const Value, inst: *const Value, local: ?[]u64) Error!bool {
        if (local) |bits| {
            const mark = st.scratch.end_index;
            defer st.scratch.end_index = mark;
            const tmp = try st.newBits(bits.len * 64);
            if (!try st.validate(sub, inst, tmp)) return false;
            orBits(bits, tmp);
            return true;
        }
        return st.validate(sub, inst, null);
    }

    pub fn applicators(st: *State, kw: *const Keywords, inst: *const Value, local: ?[]u64, vocab: Vocab) Error!bool {
        if (kw.@"allOf") |list| {
            if (list.* != .array) return error.BadSchema;
            for (list.array) |*sub| {
                if (!try st.validate(sub, inst, local)) return false;
            }
        }
        if (kw.@"anyOf") |list| {
            if (list.* != .array) return error.BadSchema;
            var any = false;
            for (list.array) |*sub| {
                if (try st.tryBranch(sub, inst, local)) {
                    any = true;
                    if (local == null) break;
                }
            }
            if (!any) return false;
        }
        if (kw.@"oneOf") |list| {
            if (list.* != .array) return error.BadSchema;
            var passed: usize = 0;
            for (list.array) |*sub| {
                if (try st.tryBranch(sub, inst, local)) passed += 1;
            }
            if (passed != 1) return false;
        }
        if (kw.@"not") |sub| {
            if (try st.validate(sub, inst, null)) return false;
        }
        if (kw.@"if") |cond| {
            if (try st.tryBranch(cond, inst, local)) {
                if (kw.@"then") |then| {
                    if (!try st.validate(then, inst, local)) return false;
                }
            } else if (kw.@"else") |otherwise| {
                if (!try st.validate(otherwise, inst, local)) return false;
            }
        }
        switch (inst.*) {
            .array => |items| {
                var prefix_len: usize = 0;
                if (kw.@"prefixItems") |list| {
                    if (list.* != .array) return error.BadSchema;
                    prefix_len = list.array.len;
                    for (items[0..@min(items.len, prefix_len)], 0..) |*item, i| {
                        if (!try st.validate(&list.array[i], item, null)) return false;
                        if (local) |bits| setBit(bits, i);
                    }
                }
                if (kw.@"items") |sub| {
                    if (items.len > prefix_len) {
                        for (items[prefix_len..], prefix_len..) |*item, i| {
                            if (!try st.validate(sub, item, null)) return false;
                            if (local) |bits| setBit(bits, i);
                        }
                    }
                }
                if (kw.@"contains") |sub| {
                    var found: usize = 0;
                    for (items, 0..) |*item, i| {
                        if (try st.validate(sub, item, null)) {
                            found += 1;
                            if (local) |bits| setBit(bits, i);
                        }
                    }
                    // minContains and maxContains belong to the validation
                    // vocabulary; without it contains needs one match.
                    var min: ?*const Value = null;
                    var max: ?*const Value = null;
                    if (vocab.validation) {
                        min = kw.@"minContains";
                        max = kw.@"maxContains";
                    }
                    if (min) |m| {
                        if (try compareCount(found, m) == .lt) return false;
                    } else if (found < 1) return false;
                    if (max) |m| if (try compareCount(found, m) == .gt) return false;
                }
            },
            .object => |members| {
                const properties = kw.@"properties";
                const pattern_properties = kw.@"patternProperties";
                const additional = kw.@"additionalProperties";
                if (properties) |p| if (p.* != .object) return error.BadSchema;
                if (pattern_properties) |p| if (p.* != .object) return error.BadSchema;
                if (properties != null or pattern_properties != null or additional != null) {
                    for (members, 0..) |*member, i| {
                        var matched = false;
                        if (properties) |p| {
                            if (get(p.object, member.key)) |sub| {
                                matched = true;
                                if (!try st.validate(sub, &member.value, null)) return false;
                            }
                        }
                        if (pattern_properties) |p| {
                            for (p.object) |*entry| {
                                if (try st.matches(entry.key, member.key)) {
                                    matched = true;
                                    if (!try st.validate(&entry.value, &member.value, null)) return false;
                                }
                            }
                        }
                        if (!matched) {
                            if (additional) |sub| {
                                if (!try st.validate(sub, &member.value, null)) return false;
                                matched = true;
                            }
                        }
                        if (matched) if (local) |bits| setBit(bits, i);
                    }
                }
                if (kw.@"dependentSchemas") |deps| {
                    if (deps.* != .object) return error.BadSchema;
                    for (deps.object) |*dep| {
                        if (get(members, dep.key) != null) {
                            if (!try st.validate(&dep.value, inst, local)) return false;
                        }
                    }
                }
                if (kw.@"propertyNames") |sub| {
                    for (members) |member| {
                        const name = Value{ .string = member.key };
                        if (!try st.validate(sub, &name, null)) return false;
                    }
                }
            },
            else => {},
        }
        return true;
    }

    pub fn assertions(st: *State, kw: *const Keywords, inst: *const Value) Error!bool {
        if (kw.@"type") |t| {
            switch (t.*) {
                .string => |name| if (!typeMatches(name, inst)) return false,
                .array => |names| {
                    var any = false;
                    for (names) |name| {
                        if (name != .string) return error.BadSchema;
                        if (typeMatches(name.string, inst)) any = true;
                    }
                    if (!any) return false;
                },
                else => return error.BadSchema,
            }
        }
        if (kw.@"const") |c| {
            if (!jsonEqual(c, inst)) return false;
        }
        if (kw.@"enum") |e| {
            if (e.* != .array) return error.BadSchema;
            var any = false;
            for (e.array) |*option| {
                if (jsonEqual(option, inst)) {
                    any = true;
                    break;
                }
            }
            if (!any) return false;
        }
        switch (inst.*) {
            .number => |n| {
                if (kw.@"multipleOf") |m| {
                    if (m.* != .number) return error.BadSchema;
                    if (!try isMultipleOf(n, m.number)) return false;
                }
                if (kw.@"maximum") |v| if (try compareTo(n, v) == .gt) return false;
                if (kw.@"exclusiveMaximum") |v| if (try compareTo(n, v) != .lt) return false;
                if (kw.@"minimum") |v| if (try compareTo(n, v) == .lt) return false;
                if (kw.@"exclusiveMinimum") |v| if (try compareTo(n, v) != .gt) return false;
            },
            .string => |s| {
                const needs_length = kw.@"maxLength" != null or kw.@"minLength" != null;
                if (needs_length) {
                    const count = codePointCount(s);
                    if (kw.@"maxLength") |v| if (try compareCount(count, v) == .gt) return false;
                    if (kw.@"minLength") |v| if (try compareCount(count, v) == .lt) return false;
                }
                if (kw.@"pattern") |pattern| {
                    if (pattern.* != .string) return error.BadSchema;
                    if (!try st.matches(pattern.string, s)) return false;
                }
            },
            .array => |items| {
                if (kw.@"maxItems") |v| if (try compareCount(items.len, v) == .gt) return false;
                if (kw.@"minItems") |v| if (try compareCount(items.len, v) == .lt) return false;
                if (kw.@"uniqueItems") |u| {
                    if (u.* == .boolean and u.boolean) {
                        for (items, 0..) |*a, i| {
                            for (items[i + 1 ..]) |*b| {
                                if (jsonEqual(a, b)) return false;
                            }
                        }
                    }
                }
            },
            .object => |members| {
                if (kw.@"maxProperties") |v| if (try compareCount(members.len, v) == .gt) return false;
                if (kw.@"minProperties") |v| if (try compareCount(members.len, v) == .lt) return false;
                if (kw.@"required") |r| {
                    if (r.* != .array) return error.BadSchema;
                    for (r.array) |name| {
                        if (name != .string) return error.BadSchema;
                        if (get(members, name.string) == null) return false;
                    }
                }
                if (kw.@"dependentRequired") |deps| {
                    if (deps.* != .object) return error.BadSchema;
                    for (deps.object) |dep| {
                        if (get(members, dep.key) == null) continue;
                        if (dep.value != .array) return error.BadSchema;
                        for (dep.value.array) |name| {
                            if (name != .string) return error.BadSchema;
                            if (get(members, name.string) == null) return false;
                        }
                    }
                }
            },
            else => {},
        }
        return true;
    }
};

pub fn sameText(a: []const u8, b: []const u8) bool {
    return (a.ptr == b.ptr and a.len == b.len) or std.mem.eql(u8, a, b);
}

pub fn isOneOf(key: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

pub fn compareTo(n: Number, v: *const Value) Error!std.math.Order {
    if (v.* != .number) return error.BadSchema;
    return compareNumbers(n.text, v.number.text);
}

pub fn typeMatches(name: []const u8, inst: *const Value) bool {
    return switch (inst.*) {
        .null => std.mem.eql(u8, name, "null"),
        .boolean => std.mem.eql(u8, name, "boolean"),
        .string => std.mem.eql(u8, name, "string"),
        .array => std.mem.eql(u8, name, "array"),
        .object => std.mem.eql(u8, name, "object"),
        .number => |n| std.mem.eql(u8, name, "number") or (std.mem.eql(u8, name, "integer") and isIntegral(n)),
    };
}

pub fn bitSet(bits: []const u64, i: usize) bool {
    return (bits[i / 64] >> @intCast(i % 64)) & 1 != 0;
}

pub fn setBit(bits: []u64, i: usize) void {
    bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
}

pub fn orBits(dst: []u64, src: []const u64) void {
    for (dst, src) |*d, s| d.* |= s;
}


pub fn testSearch(pattern: []const u8, text: []const u8) !bool {
    var buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const regex = try compileRegex(fba.allocator(), pattern);
    return regexSearch(fba.allocator(), regex, text);
}

test {
    // Runs the letter table's packed-lookup test with this file's tests.
    _ = unicode_letter;
}

test "embedded meta-schemas are minified and still parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (embedded_schemas) |e| {
        try std.testing.expect(std.mem.indexOfScalar(u8, e.json, '\n') == null);
        _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), e.json, .{});
    }
}

fn testParse(arena: *std.heap.FixedBufferAllocator, scratch: *std.heap.FixedBufferAllocator, src: []const u8) Error!Value {
    arena.reset();
    scratch.reset();
    defer std.debug.assert(scratch.end_index == 0);
    return JsonParser.parseDocument(arena.allocator(), scratch.allocator(), src);
}

test "the parser allocates each container once, at its final size" {
    const arena_buf = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(arena_buf);
    const scratch_buf = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(scratch_buf);
    var arena = std.heap.FixedBufferAllocator.init(arena_buf);
    var scratch = std.heap.FixedBufferAllocator.init(scratch_buf);

    // [[0],[0],...] grew the outer list behind every inner one, abandoning
    // its old slices. Now the arena holds exactly the 2n values.
    const n = 10_000;
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.append(std.testing.allocator, '[');
    for (0..n) |i| try src.appendSlice(std.testing.allocator, if (i == 0) "[0]" else ",[0]");
    try src.append(std.testing.allocator, ']');
    const v = try testParse(&arena, &scratch, src.items);
    try std.testing.expectEqual(@as(usize, n), v.array.len);
    try std.testing.expectEqual(2 * n * @sizeOf(Value), arena.end_index);

    // The densest shapes stay inside the documented bound: 6 bytes per input
    // byte on wasm32, which scales with Value and Member on this target.
    const per_byte = @max(@sizeOf(Value) / 2, @sizeOf(Member) / 5);
    const shapes = [_][]const u8{ "0,", "[0],", "{\"\":0},", "\"\\n\"," };
    for (shapes) |unit| {
        src.clearRetainingCapacity();
        try src.append(std.testing.allocator, '[');
        for (0..n) |_| try src.appendSlice(std.testing.allocator, unit);
        src.items[src.items.len - 1] = ']';
        _ = try testParse(&arena, &scratch, src.items);
        try std.testing.expect(arena.end_index <= per_byte * src.items.len);
    }
    src.clearRetainingCapacity();
    try src.append(std.testing.allocator, '{');
    for (0..n) |i| try src.print(std.testing.allocator, "\"{d}\":0,", .{i});
    src.items[src.items.len - 1] = '}';
    const obj = try testParse(&arena, &scratch, src.items);
    try std.testing.expectEqual(@as(usize, n), obj.object.len);
    try std.testing.expectEqualStrings("9999", obj.object[n - 1].key);
}

test "the parser accepts exactly what std.json accepts" {
    var arena_buf: [1 << 16]u8 = undefined;
    var scratch_buf: [1 << 14]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_buf);
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const inputs = [_][]const u8{
        "[]",        "{}",            "[1,2,3]",      "{\"a\":[1,{\"b\":[]}],\"c\":\"]}\"}",
        "[\"\\\"]\"]", "[1,]",          "[,1]",         "[1 2]",
        "{\"a\" 1}",  "{\"a\":1,}",     "{,}",          "[[1],[2,3]",
        "[1]]",      "{\"a\":1}}",     "\"x",          "[\"x",
        "[\"\\",     "[1,[2,[3]],4]", "{\"a\":{\"a\":{}}}", "  [ 1 , [ ] , { } ]  ",
        "1",         "[0]x",          "[{]",          "[}",
        "{\"a\":1 \"b\":2}", "[[],[[]],[[],[]]]", "{\"\\u0041\":\"\\ud83d\\ude00\"}", "",
    };
    for (inputs) |src| {
        const ours = if (testParse(&arena, &scratch, src)) |_| true else |_| false;
        const std_ok = try std.json.validate(std.testing.allocator, src);
        std.testing.expectEqual(std_ok, ours) catch |err| {
            std.debug.print("input: {s}\n", .{src});
            return err;
        };
    }
    const deep_ok = "[" ** MAX_DEPTH ++ "]" ** MAX_DEPTH;
    _ = try testParse(&arena, &scratch, deep_ok);
    const deep = "[" ** (MAX_DEPTH + 1) ++ "]" ** (MAX_DEPTH + 1);
    try std.testing.expectError(error.TooDeep, testParse(&arena, &scratch, deep));
    try std.testing.expectError(error.TooDeep, testParse(&arena, &scratch, "[" ** (MAX_DEPTH + 1) ++ "1"));
}

test "regex search" {
    try std.testing.expect(try testSearch("^a*$", "aaa"));
    try std.testing.expect(!try testSearch("^a*$", "abc"));
    try std.testing.expect(try testSearch("f.*o", "xxfoo"));
    try std.testing.expect(!try testSearch("^\\p{Letter}+$", "123"));
    try std.testing.expect(try testSearch("^\\p{Letter}+$", "π"));
    try std.testing.expect(try testSearch("[0-9]{2,}", "a12"));
    try std.testing.expect(!try testSearch("[0-9]{2,}", "a1b2"));
    try std.testing.expect(try testSearch("^(cat|dog)s?\\b", "dogs!"));
    try std.testing.expect(!try testSearch("^[^#]*#?$", "a#b"));
}

pub fn testNumber(text: []const u8) Number {
    return .{ .text = text };
}

test "integers and multipleOf use exact decimals" {
    try std.testing.expect(isIntegral(testNumber("1.0")));
    try std.testing.expect(isIntegral(testNumber("1e308")));
    try std.testing.expect(isIntegral(testNumber("-0.0")));
    try std.testing.expect(!isIntegral(testNumber("1.5")));
    try std.testing.expect(!isIntegral(testNumber("1.0000000000000000001")));
    try std.testing.expect(try isMultipleOf(testNumber("0.0075"), testNumber("0.0001")));
    try std.testing.expect(!try isMultipleOf(testNumber("0.00751"), testNumber("0.0001")));
    try std.testing.expect(try isMultipleOf(testNumber("19.99"), testNumber("0.01")));
    try std.testing.expect(try isMultipleOf(testNumber("4.5"), testNumber("1.5")));
    try std.testing.expect(!try isMultipleOf(testNumber("1e308"), testNumber("0.123456789")));
    try std.testing.expect(try isMultipleOf(testNumber("12391239123"), testNumber("1e-8")));
    try std.testing.expect(try isMultipleOf(testNumber("0"), testNumber("7")));
    // Divisors past 2^64 take the double-and-add path.
    try std.testing.expect(try isMultipleOf(testNumber("246913578024691357802469135780"), testNumber("123456789012345678901234567890")));
    try std.testing.expect(!try isMultipleOf(testNumber("246913578024691357802469135781"), testNumber("123456789012345678901234567890")));
    try std.testing.expect(try isMultipleOf(testNumber("1.23456789012345678901234567890e40"), testNumber("123456789012345678901234567890")));
    try std.testing.expectError(error.Unsupported, isMultipleOf(testNumber("1"), testNumber("1.0000000000000000000000000000000000001")));
}

test "numbers compare exactly" {
    const O = std.math.Order;
    try std.testing.expectEqual(O.eq, compareNumbers("1", "1.0"));
    try std.testing.expectEqual(O.eq, compareNumbers("-0", "0.0e5"));
    try std.testing.expectEqual(O.eq, compareNumbers("100", "1e2"));
    try std.testing.expectEqual(O.eq, compareNumbers("0.5", "5E-1"));
    try std.testing.expectEqual(O.lt, compareNumbers("1", "1.0000000000000000001"));
    try std.testing.expectEqual(O.gt, compareNumbers("1e400", "1e308"));
    try std.testing.expectEqual(O.lt, compareNumbers("-1e400", "-1e308"));
    try std.testing.expectEqual(O.lt, compareNumbers("-2", "1"));
    try std.testing.expectEqual(O.gt, compareNumbers("0.1", "-0.2"));
    try std.testing.expectEqual(O.lt, compareNumbers("-0.25", "0"));
    try std.testing.expectEqual(O.lt, compareNumbers("9.99", "10"));
    try std.testing.expectEqual(O.gt, compareNumbers("12", "11.999"));
    try std.testing.expectEqual(O.lt, compareNumbers("-12", "-11.999"));
    var v = Value{ .number = .{ .text = "2.0" } };
    try std.testing.expectEqual(O.eq, try compareCount(2, &v));
    try std.testing.expectEqual(O.lt, try compareCount(1, &v));
    try std.testing.expectEqual(O.gt, try compareCount(10, &v));
    v = .{ .number = .{ .text = "0" } };
    try std.testing.expectEqual(O.eq, try compareCount(0, &v));
    try std.testing.expectEqual(O.gt, compareNumbers("123456789012345678901", "123456789012345678900"));
    try std.testing.expectEqual(O.gt, compareNumbers("0.1000000000000000000001", "0.1"));
    // The small-number fast path agrees with the exact Decimal path.
    const samples = [_][]const u8{ "0", "-0", "0.0", "1", "-1", "1.0", "1.5", "-1.5", "10", "9.99", "0.01", "0.001", "-0.001", "100", "99.990", "123456789012345678", "-123456789012345678", "0.123456789012345678", "17.25", "17.250000", "-17.25", "1000", "999.999999999999999" };
    for (samples) |x| for (samples) |y| {
        try std.testing.expectEqual(compareDecimals(x, y), compareNumbers(x, y));
    };
}

test "envelope keys come in any order and the instance keeps its bytes" {
    var buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    const env = try parseEnvelope(a, a, " {\"instance\" : [1.50, 2] ,\"schemas\":{\"urn:x\":true},\"schema\":{}} ");
    try std.testing.expectEqualStrings("[1.50, 2]", env.instance_bytes);
    try std.testing.expect(env.schema != null);
    try std.testing.expectEqual(@as(usize, 1), env.schemas.len);
    try std.testing.expectEqualStrings("urn:x", env.schemas[0].key);
    try std.testing.expectError(error.InvalidEnvelope, parseEnvelope(a, a, "{\"schema\":{},\"schema\":{}}"));
    try std.testing.expectError(error.InvalidEnvelope, parseEnvelope(a, a, "{\"schema\":{},\"other\":1}"));
    try std.testing.expectError(error.InvalidEnvelope, parseEnvelope(a, a, "{\"schemas\":[]}"));
    try std.testing.expectError(error.InvalidEnvelope, parseEnvelope(a, a, "[]"));
    try std.testing.expectError(error.MissingKey, parseEnvelope(a, a, "{}"));
    try std.testing.expectError(error.InvalidJson, parseEnvelope(a, a, "{\"schema\":{}} x"));
}

test "URI references resolve per RFC 3986" {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    const base = "http://a/b/c/d;p?q";
    const cases = [_][2][]const u8{
        .{ "g", "http://a/b/c/g" },
        .{ "./g", "http://a/b/c/g" },
        .{ "g/", "http://a/b/c/g/" },
        .{ "/g", "http://a/g" },
        .{ "//g", "http://g" },
        .{ "?y", "http://a/b/c/d;p?y" },
        .{ "#s", "http://a/b/c/d;p?q#s" },
        .{ "..", "http://a/b/" },
        .{ "../g", "http://a/b/g" },
        .{ "../../../g", "http://a/g" },
        .{ "g;x=1/../y", "http://a/b/c/y" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try resolveUri(a, base, c[0]));
    try std.testing.expectEqualStrings("urn:uuid:deadbeef#foo", try resolveUri(a, "urn:uuid:deadbeef", "#foo"));
}
