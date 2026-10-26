// RFC 5646 (BCP 47) language tag parser shared by the bcp47-must-be-*
// components. It checks the ABNF in RFC 5646 section 2.1, case-insensitively,
// and records each subtag's role so a caller can check registry validity.
//
// The grammar has no length limit; callers bound input with their buffer size.

pub const max_subtags = 512;

pub const Kind = enum(u8) {
    language,
    extlang,
    script,
    region,
    variant,
    singleton,
    extension,
    privateuse_singleton,
    privateuse,
};

pub const Subtag = struct {
    start: u32,
    len: u8,
    kind: Kind,
};

pub const Parsed = struct {
    // Irregular and regular grandfathered tags match as whole tags. Regular
    // ones also parse as langtag, and their subtags are still recorded.
    grandfathered: bool,
    count: u32,
    subtags: [max_subtags]Subtag,
};

pub const Error = struct {
    offset: u32,
};

// RFC 5646 section 2.2.8. The list is closed: no new grandfathered tags can
// be registered.
pub const irregular = [_][]const u8{
    "en-gb-oed", "i-ami", "i-bnn",     "i-default", "i-enochian", "i-hak",
    "i-klingon", "i-lux", "i-mingo",   "i-navajo",  "i-pwn",      "i-tao",
    "i-tay",     "i-tsu", "sgn-be-fr", "sgn-be-nl", "sgn-ch-de",
};

pub const regular = [_][]const u8{
    "art-lojban", "cel-gaulish", "no-bok",     "no-nyn",   "zh-guoyu",
    "zh-hakka",   "zh-min",      "zh-min-nan", "zh-xiang",
};

pub fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c | 0x20 else c;
}

fn isAlpha(c: u8) bool {
    const l = lower(c);
    return l >= 'a' and l <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

fn allAlpha(s: []const u8) bool {
    for (s) |c| if (!isAlpha(c)) return false;
    return true;
}

fn allDigit(s: []const u8) bool {
    for (s) |c| if (!isDigit(c)) return false;
    return true;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn matchesAny(tag: []const u8, list: []const []const u8) bool {
    for (list) |entry| if (eqlIgnoreCase(tag, entry)) return true;
    return false;
}

const Cursor = struct {
    input: []const u8,
    pos: usize,

    // Returns the next subtag without consuming it, or null at the end.
    fn peek(self: *const Cursor) ?[]const u8 {
        if (self.pos >= self.input.len) return null;
        var end = self.pos;
        while (end < self.input.len and self.input[end] != '-') end += 1;
        return self.input[self.pos..end];
    }

    fn advance(self: *Cursor, len: usize) void {
        self.pos += len;
        // Step over the separator. Split guarantees it is not trailing.
        if (self.pos < self.input.len) self.pos += 1;
    }
};

// Checks bytes and subtag lengths before the grammar runs, so the grammar
// only sees non-empty 1*8alphanum subtags.
fn checkShape(input: []const u8) ?Error {
    if (input.len == 0) return .{ .offset = 0 };
    var start: usize = 0;
    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        if (i == input.len or input[i] == '-') {
            const len = i - start;
            if (len == 0 or len > 8) return .{ .offset = @intCast(start) };
            start = i + 1;
            continue;
        }
        if (!isAlnum(input[i])) return .{ .offset = @intCast(i) };
    }
    return null;
}

fn isVariant(s: []const u8) bool {
    if (s.len >= 5) return true; // 5*8alphanum; shape is already checked.
    return s.len == 4 and isDigit(s[0]);
}

fn isSingleton(s: []const u8) bool {
    return s.len == 1 and lower(s[0]) != 'x';
}

pub fn parse(input: []const u8, out: *Parsed) ?Error {
    out.count = 0;
    out.grandfathered = false;
    if (checkShape(input)) |err| return err;

    if (matchesAny(input, &irregular)) {
        out.grandfathered = true;
        return null;
    }
    out.grandfathered = matchesAny(input, &regular);

    var c = Cursor{ .input = input, .pos = 0 };
    const first = c.peek().?;

    if (first.len == 1 and lower(first[0]) == 'x') return parsePrivateuse(&c, out);

    // language = 2*3ALPHA ["-" extlang] / 4ALPHA / 5*8ALPHA
    if (first.len < 2 or !allAlpha(first)) return .{ .offset = 0 };
    push(out, &c, first, .language) orelse return .{ .offset = 0 };

    if (first.len <= 3) {
        // extlang = 3ALPHA *2("-" 3ALPHA)
        var n: usize = 0;
        while (n < 3) : (n += 1) {
            const s = c.peek() orelse return null;
            if (s.len != 3 or !allAlpha(s)) break;
            push(out, &c, s, .extlang) orelse return .{ .offset = @intCast(c.pos) };
        }
    }

    if (c.peek()) |s| {
        if (s.len == 4 and allAlpha(s)) push(out, &c, s, .script) orelse return .{ .offset = @intCast(c.pos) };
    }
    if (c.peek()) |s| {
        if ((s.len == 2 and allAlpha(s)) or (s.len == 3 and allDigit(s))) {
            push(out, &c, s, .region) orelse return .{ .offset = @intCast(c.pos) };
        }
    }
    while (c.peek()) |s| {
        if (!isVariant(s)) break;
        push(out, &c, s, .variant) orelse return .{ .offset = @intCast(c.pos) };
    }

    // extension = singleton 1*("-" (2*8alphanum))
    while (c.peek()) |s| {
        if (!isSingleton(s)) break;
        push(out, &c, s, .singleton) orelse return .{ .offset = @intCast(c.pos) };
        var n: usize = 0;
        while (c.peek()) |e| {
            if (e.len < 2) break;
            push(out, &c, e, .extension) orelse return .{ .offset = @intCast(c.pos) };
            n += 1;
        }
        if (n == 0) return .{ .offset = @intCast(c.pos) };
    }

    const rest = c.peek() orelse return null;
    if (rest.len == 1 and lower(rest[0]) == 'x') return parsePrivateuse(&c, out);
    return .{ .offset = @intCast(c.pos) };
}

// privateuse = "x" 1*("-" (1*8alphanum))
fn parsePrivateuse(c: *Cursor, out: *Parsed) ?Error {
    const x = c.peek().?;
    push(out, c, x, .privateuse_singleton) orelse return .{ .offset = @intCast(c.pos) };
    if (c.peek() == null) return .{ .offset = @intCast(c.input.len) };
    while (c.peek()) |s| {
        push(out, c, s, .privateuse) orelse return .{ .offset = @intCast(c.pos) };
    }
    return null;
}

// Records a subtag and consumes it. Returns null when the subtag table is
// full; the caller reports that subtag as the failure position.
fn push(out: *Parsed, c: *Cursor, s: []const u8, kind: Kind) ?void {
    if (out.count >= max_subtags) return null;
    out.subtags[out.count] = .{ .start = @intCast(c.pos), .len = @intCast(s.len), .kind = kind };
    out.count += 1;
    c.advance(s.len);
}

const std = @import("std");

var test_parsed: Parsed = undefined;

fn expectWellFormed(tag: []const u8) !void {
    if (parse(tag, &test_parsed)) |err| {
        std.debug.print("expected well-formed: {s} (offset {d})\n", .{ tag, err.offset });
        return error.TestUnexpectedResult;
    }
}

fn expectMalformedAt(tag: []const u8, offset: u32) !void {
    const err = parse(tag, &test_parsed) orelse {
        std.debug.print("expected malformed: {s}\n", .{tag});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(offset, err.offset);
}

test "RFC 5646 appendix A examples are well-formed" {
    for ([_][]const u8{
        "de",                    "fr",                   "ja",                     "i-enochian",
        "zh-Hant",               "zh-Hans",              "sr-Cyrl",                "sr-Latn",
        "zh-cmn-Hans-CN",        "cmn-Hans-CN",          "zh-yue-HK",              "yue-HK",
        "zh-Hans-CN",            "sr-Latn-RS",           "sl-rozaj",               "sl-rozaj-biske",
        "sl-nedis",              "de-CH-1901",           "sl-IT-nedis",            "hy-Latn-IT-arevela",
        "de-DE",                 "en-US",                "es-419",                 "de-CH-x-phonebk",
        "az-Arab-x-AZE-derbend", "x-whatever",           "qaa-Qaaa-QM-x-southern", "de-Qaaa",
        "sr-Latn-QM",            "sr-Qaaa-RS",           "en-US-u-islamcal",       "zh-CN-a-myext-x-private",
        "en-a-myext-b-another",  "ar-a-aaa-b-bbb-a-ccc", "EN-gb-OED",              "zh-min-nan",
    }) |tag| try expectWellFormed(tag);
}

test "malformed tags report the failing subtag" {
    try expectMalformedAt("", 0);
    try expectMalformedAt("-en", 0);
    try expectMalformedAt("en-", 3);
    try expectMalformedAt("en--US", 3);
    try expectMalformedAt("en_US", 2);
    try expectMalformedAt("e", 0);
    try expectMalformedAt("1en", 0);
    try expectMalformedAt("toolongtag", 0);
    try expectMalformedAt("en-a", 4);
    try expectMalformedAt("en-a-b", 5);
    try expectMalformedAt("en-x", 4);
    try expectMalformedAt("x", 1);
    try expectMalformedAt("en-US-Latn", 6);
    try expectMalformedAt("en-GB-oed-x", 6);
    try expectMalformedAt("de-419-DE", 7);
    try expectMalformedAt("a-DE", 0);
    try expectMalformedAt("abcd-efg", 5);
    try expectMalformedAt("en-a-x", 5);
}

test "subtags are classified for registry checks" {
    try std.testing.expectEqual(@as(?Error, null), parse("zh-yue-Hant-HK-1901-u-co-x-a", &test_parsed));
    const kinds = [_]Kind{ .language, .extlang, .script, .region, .variant, .singleton, .extension, .privateuse_singleton, .privateuse };
    try std.testing.expectEqual(@as(u32, kinds.len), test_parsed.count);
    for (kinds, test_parsed.subtags[0..kinds.len]) |kind, subtag| try std.testing.expectEqual(kind, subtag.kind);
}
