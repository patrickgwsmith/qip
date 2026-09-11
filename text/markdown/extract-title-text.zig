const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "text/markdown";
const OUTPUT_CONTENT_TYPE = "text/plain";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Candidate = struct {
    start: usize,
    text: []const u8,
};

const Line = struct {
    start: usize,
    end: usize,
    next_start: usize,
};

const Bracket = struct {
    content: []const u8,
    next: usize,
};

const Entity = struct {
    bytes: [4]u8,
    len: usize,
    next: usize,
};

const Writer = struct {
    buf: []u8,
    idx: usize = 0,
    prev_space: bool = true,

    fn writeSpace(self: *Writer) void {
        if (self.idx == 0 or self.prev_space) {
            self.prev_space = true;
            return;
        }
        if (self.idx >= self.buf.len) @trap();
        self.buf[self.idx] = ' ';
        self.idx += 1;
        self.prev_space = true;
    }

    fn writeByte(self: *Writer, b: u8) void {
        if (isAsciiSpace(b)) {
            self.writeSpace();
            return;
        }
        if (self.idx >= self.buf.len) @trap();
        self.buf[self.idx] = b;
        self.idx += 1;
        self.prev_space = false;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        for (s) |b| self.writeByte(b);
    }

    fn finish(self: *Writer) u32 {
        if (self.idx > 0 and self.buf[self.idx - 1] == ' ') self.idx -= 1;
        return @as(u32, @intCast(self.idx));
    }
};

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

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isInlineSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isTagNameBoundary(c: u8) bool {
    return c == '>' or c == '/' or isAsciiSpace(c);
}

fn isBlankLine(s: []const u8) bool {
    for (s) |b| {
        if (!isInlineSpace(b)) return false;
    }
    return true;
}

fn trimInlineSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isInlineSpace(s[start])) start += 1;
    while (end > start and isInlineSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn nextLine(input: []const u8, start: usize) Line {
    var end = start;
    while (end < input.len and input[end] != '\n') : (end += 1) {}
    var line_end = end;
    if (line_end > start and input[line_end - 1] == '\r') line_end -= 1;
    const next_start = if (end < input.len) end + 1 else input.len;
    return .{ .start = start, .end = line_end, .next_start = next_start };
}

fn trimAtxContent(line: []const u8) []const u8 {
    var s = trimInlineSpace(line);
    if (s.len == 0) return s;

    var end = s.len;
    while (end > 0 and s[end - 1] == '#') end -= 1;
    if (end < s.len) {
        var k = end;
        while (k > 0 and isInlineSpace(s[k - 1])) k -= 1;
        if (k < end) s = s[0..k];
    }
    return trimInlineSpace(s);
}

fn isSetextH1Underline(line: []const u8) bool {
    const s = trimInlineSpace(line);
    if (s.len == 0) return false;
    for (s) |b| {
        if (b != '=') return false;
    }
    return true;
}

fn findTagEnd(s: []const u8, from: usize) ?usize {
    var i = from;
    var quote: u8 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return i + 1;
    }
    return null;
}

fn findH1CloseStart(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 4 < s.len) : (i += 1) {
        if (s[i] != '<' or s[i + 1] != '/') continue;
        if (asciiLower(s[i + 2]) != 'h' or s[i + 3] != '1') continue;
        if (!isTagNameBoundary(s[i + 4])) continue;
        return i;
    }
    return null;
}

fn findTitleCloseStart(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 7 < s.len) : (i += 1) {
        if (s[i] != '<' or s[i + 1] != '/') continue;
        if (asciiLower(s[i + 2]) != 't') continue;
        if (asciiLower(s[i + 3]) != 'i') continue;
        if (asciiLower(s[i + 4]) != 't') continue;
        if (asciiLower(s[i + 5]) != 'l') continue;
        if (asciiLower(s[i + 6]) != 'e') continue;
        if (!isTagNameBoundary(s[i + 7])) continue;
        return i;
    }
    return null;
}

fn findFirstHtmlTitle(input: []const u8) ?Candidate {
    var i: usize = 0;
    while (i + 6 < input.len) : (i += 1) {
        if (input[i] != '<') continue;
        if (asciiLower(input[i + 1]) != 't') continue;
        if (asciiLower(input[i + 2]) != 'i') continue;
        if (asciiLower(input[i + 3]) != 't') continue;
        if (asciiLower(input[i + 4]) != 'l') continue;
        if (asciiLower(input[i + 5]) != 'e') continue;
        if (!isTagNameBoundary(input[i + 6])) continue;

        const open_end = findTagEnd(input, i + 6) orelse continue;
        const close_start = findTitleCloseStart(input, open_end) orelse input.len;
        return .{
            .start = i,
            .text = input[open_end..close_start],
        };
    }
    return null;
}

fn findFirstHtmlH1(input: []const u8) ?Candidate {
    var i: usize = 0;
    while (i + 3 < input.len) : (i += 1) {
        if (input[i] != '<') continue;
        if (asciiLower(input[i + 1]) != 'h' or input[i + 2] != '1') continue;
        if (!isTagNameBoundary(input[i + 3])) continue;

        const open_end = findTagEnd(input, i + 3) orelse continue;
        const close_start = findH1CloseStart(input, open_end) orelse input.len;
        return .{
            .start = i,
            .text = input[open_end..close_start],
        };
    }
    return null;
}

fn findFirstAtxH1(input: []const u8) ?Candidate {
    var pos: usize = 0;
    while (pos < input.len) {
        const line = nextLine(input, pos);
        const slice = input[line.start..line.end];

        var i: usize = 0;
        var spaces: usize = 0;
        while (i < slice.len and spaces < 3 and slice[i] == ' ') : ({
            i += 1;
            spaces += 1;
        }) {}

        if (i < slice.len and slice[i] == '#') {
            if (i + 1 >= slice.len or slice[i + 1] != '#') {
                var j = i + 1;
                if (j == slice.len or isInlineSpace(slice[j])) {
                    while (j < slice.len and isInlineSpace(slice[j])) : (j += 1) {}
                    if (j < slice.len) {
                        const content = trimAtxContent(slice[j..]);
                        if (content.len > 0) {
                            return .{
                                .start = line.start + i,
                                .text = content,
                            };
                        }
                    }
                }
            }
        }

        pos = line.next_start;
    }
    return null;
}

fn findFirstSetextH1(input: []const u8) ?Candidate {
    var pos: usize = 0;
    var prev: ?Line = null;

    while (pos < input.len) {
        const line = nextLine(input, pos);
        if (prev) |p| {
            const prev_slice = input[p.start..p.end];
            const cur_slice = input[line.start..line.end];
            if (!isBlankLine(prev_slice) and isSetextH1Underline(cur_slice)) {
                const content = trimInlineSpace(prev_slice);
                if (content.len > 0) {
                    return .{
                        .start = p.start,
                        .text = content,
                    };
                }
            }
        }
        prev = line;
        pos = line.next_start;
    }

    return null;
}

fn earlier(a: ?Candidate, b: Candidate) Candidate {
    if (a) |x| {
        if (x.start <= b.start) return x;
    }
    return b;
}

fn findTitleSlice(input: []const u8) ?[]const u8 {
    if (findFirstHtmlTitle(input)) |c| return c.text;
    return findHeadingTitleSlice(input);
}

fn findHeadingTitleSlice(input: []const u8) ?[]const u8 {
    var best: ?Candidate = null;
    if (findFirstHtmlH1(input)) |c| best = c;
    if (findFirstAtxH1(input)) |c| best = earlier(best, c);
    if (findFirstSetextH1(input)) |c| best = earlier(best, c);
    if (best) |c| return c.text;
    return null;
}

fn parseBracket(s: []const u8, at: usize) ?Bracket {
    if (at >= s.len or s[at] != '[') return null;
    var depth: usize = 1;
    var i = at + 1;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == '[') {
            depth += 1;
            i += 1;
            continue;
        }
        if (s[i] == ']') {
            depth -= 1;
            if (depth == 0) {
                return .{
                    .content = s[at + 1 .. i],
                    .next = i + 1,
                };
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return null;
}

fn skipBalanced(s: []const u8, at: usize, open: u8, close: u8) usize {
    if (at >= s.len or s[at] != open) return at;
    var depth: usize = 0;
    var i = at;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == open) {
            depth += 1;
            i += 1;
            continue;
        }
        if (s[i] == close) {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return s.len;
}

fn skipLinkTail(s: []const u8, at: usize) usize {
    if (at >= s.len) return at;
    if (s[at] == '(') return skipBalanced(s, at, '(', ')');
    if (s[at] == '[') return skipBalanced(s, at, '[', ']');
    return at;
}

fn countRun(s: []const u8, at: usize, b: u8) usize {
    var i = at;
    while (i < s.len and s[i] == b) : (i += 1) {}
    return i - at;
}

fn findBacktickClose(s: []const u8, from: usize, tick_count: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] != '`') {
            i += 1;
            continue;
        }
        const n = countRun(s, i, '`');
        if (n == tick_count) return i;
        i += n;
    }
    return null;
}

fn decodeEntityAt(s: []const u8, at: usize) ?Entity {
    if (at >= s.len or s[at] != '&') return null;

    var semi = at + 1;
    while (semi < s.len and semi - at <= 16 and s[semi] != ';') : (semi += 1) {}
    if (semi >= s.len or s[semi] != ';') return null;

    const body = s[at + 1 .. semi];
    if (body.len == 0) return null;

    var out: Entity = .{
        .bytes = undefined,
        .len = 0,
        .next = semi + 1,
    };

    if (std.mem.eql(u8, body, "nbsp")) {
        out.bytes[0] = ' ';
        out.len = 1;
        return out;
    }
    if (std.mem.eql(u8, body, "amp")) {
        out.bytes[0] = '&';
        out.len = 1;
        return out;
    }
    if (std.mem.eql(u8, body, "lt")) {
        out.bytes[0] = '<';
        out.len = 1;
        return out;
    }
    if (std.mem.eql(u8, body, "gt")) {
        out.bytes[0] = '>';
        out.len = 1;
        return out;
    }
    if (std.mem.eql(u8, body, "quot")) {
        out.bytes[0] = '"';
        out.len = 1;
        return out;
    }
    if (std.mem.eql(u8, body, "#39")) {
        out.bytes[0] = '\'';
        out.len = 1;
        return out;
    }

    if (body[0] == '#') {
        var cp: u32 = 0;
        if (body.len >= 2 and (body[1] == 'x' or body[1] == 'X')) {
            if (body.len == 2) return null;
            var i: usize = 2;
            while (i < body.len) : (i += 1) {
                const b = body[i];
                var d: u32 = 0;
                if (b >= '0' and b <= '9') {
                    d = b - '0';
                } else if (b >= 'a' and b <= 'f') {
                    d = 10 + (b - 'a');
                } else if (b >= 'A' and b <= 'F') {
                    d = 10 + (b - 'A');
                } else {
                    return null;
                }
                cp = cp * 16 + d;
            }
        } else {
            if (body.len == 1) return null;
            var i: usize = 1;
            while (i < body.len) : (i += 1) {
                const b = body[i];
                if (b < '0' or b > '9') return null;
                cp = cp * 10 + (b - '0');
            }
        }
        if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
            cp = 0xFFFD;
        }
        const n = std.unicode.utf8Encode(@as(u21, @intCast(cp)), &out.bytes) catch return null;
        out.len = n;
        return out;
    }

    return null;
}

fn skipHtmlTag(s: []const u8, at: usize) ?usize {
    if (at >= s.len or s[at] != '<' or at + 1 >= s.len) return null;
    const next = s[at + 1];
    if (!(isAlpha(next) or next == '/' or next == '!' or next == '?')) return null;
    return findTagEnd(s, at + 1);
}

fn appendPlainInline(w: *Writer, s: []const u8, depth: u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<') {
            if (skipHtmlTag(s, i)) |next| {
                w.writeSpace();
                i = next;
                continue;
            }
        }

        if (s[i] == '&') {
            if (decodeEntityAt(s, i)) |ent| {
                w.writeSlice(ent.bytes[0..ent.len]);
                i = ent.next;
                continue;
            }
        }

        if (s[i] == '\\' and i + 1 < s.len) {
            w.writeByte(s[i + 1]);
            i += 2;
            continue;
        }

        if (s[i] == '`') {
            const tick_count = countRun(s, i, '`');
            const after_open = i + tick_count;
            if (findBacktickClose(s, after_open, tick_count)) |close_at| {
                w.writeSlice(s[after_open..close_at]);
                i = close_at + tick_count;
                continue;
            }
            i += tick_count;
            continue;
        }

        if (depth < 8 and s[i] == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (parseBracket(s, i + 1)) |br| {
                appendPlainInline(w, br.content, depth + 1);
                i = skipLinkTail(s, br.next);
                continue;
            }
        }

        if (depth < 8 and s[i] == '[') {
            if (parseBracket(s, i)) |br| {
                appendPlainInline(w, br.content, depth + 1);
                i = skipLinkTail(s, br.next);
                continue;
            }
        }

        if (s[i] == '*' or s[i] == '_' or s[i] == '~') {
            i += 1;
            continue;
        }

        w.writeByte(s[i]);
        i += 1;
    }
}

fn extractTitleToOutput(input: []const u8, out: []u8) u32 {
    if (findTitleSlice(input)) |title| {
        var writer = Writer{ .buf = out };
        appendPlainInline(&writer, title, 0);
        const n = writer.finish();
        if (n > 0) return n;
    }

    const fallback = findHeadingTitleSlice(input) orelse return 0;
    var writer = Writer{ .buf = out };
    appendPlainInline(&writer, fallback, 0);
    return writer.finish();
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    return extractTitleToOutput(input_buf[0..input_size], output_buf[0..]);
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

test "extracts markdown h1 and strips emphasis" {
    var out: [128]u8 = undefined;
    const n = extractTitleToOutput("# Hello *World*", out[0..]);
    try std.testing.expectEqualStrings("Hello World", out[0..n]);
}

test "extracts html h1 and strips tags/entities" {
    var out: [128]u8 = undefined;
    const n = extractTitleToOutput("<h1>Hello&nbsp;<code>World</code></h1>", out[0..]);
    try std.testing.expectEqualStrings("Hello World", out[0..n]);
}

test "extracts html title and strips tags/entities" {
    var out: [128]u8 = undefined;
    const n = extractTitleToOutput("<title>Hello&nbsp;<em>World</em> &amp; Co</title><h1>Ignored</h1>", out[0..]);
    try std.testing.expectEqualStrings("Hello World & Co", out[0..n]);
}

test "falls back to heading if html title is empty" {
    var out: [128]u8 = undefined;
    const n = extractTitleToOutput("<title>   </title>\n# Hello World", out[0..]);
    try std.testing.expectEqualStrings("Hello World", out[0..n]);
}

test "extracts first heading in document order" {
    var out: [128]u8 = undefined;
    const input =
        \\before
        \\# First
        \\<h1>Second</h1>
    ;
    const n = extractTitleToOutput(input, out[0..]);
    try std.testing.expectEqualStrings("First", out[0..n]);
}

test "supports setext h1" {
    var out: [128]u8 = undefined;
    const input =
        \\Hello _World_
        \\===
    ;
    const n = extractTitleToOutput(input, out[0..]);
    try std.testing.expectEqualStrings("Hello World", out[0..n]);
}

test "keeps link label text only" {
    var out: [128]u8 = undefined;
    const n = extractTitleToOutput("# [Hello *World*](https://example.com)", out[0..]);
    try std.testing.expectEqualStrings("Hello World", out[0..n]);
}

test "maximum-size plain heading fits the output capacity" {
    input_buf[0] = '#';
    input_buf[1] = ' ';
    @memset(input_buf[2..], 'x');

    const n = renderImpl(INPUT_CAP);
    try std.testing.expectEqual(@as(u32, INPUT_CAP - 2), n);
    try std.testing.expectEqualSlices(u8, input_buf[2..], output_buf[0..n]);
}
