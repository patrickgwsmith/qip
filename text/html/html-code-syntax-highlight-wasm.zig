const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "module", {} },
    .{ "func", {} },
    .{ "import", {} },
    .{ "export", {} },
    .{ "memory", {} },
    .{ "table", {} },
    .{ "global", {} },
    .{ "local", {} },
    .{ "param", {} },
    .{ "result", {} },
    .{ "type", {} },
    .{ "elem", {} },
    .{ "data", {} },
    .{ "start", {} },
    .{ "mut", {} },
    .{ "offset", {} },
    .{ "block", {} },
    .{ "loop", {} },
    .{ "if", {} },
    .{ "then", {} },
    .{ "else", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "i32", {} },
    .{ "i64", {} },
    .{ "f32", {} },
    .{ "f64", {} },
    .{ "v128", {} },
});

const InstrSet = std.StaticStringMap(void).initComptime(.{
    .{ "unreachable", {} },
    .{ "nop", {} },
    .{ "drop", {} },
    .{ "select", {} },
    .{ "br", {} },
    .{ "br_if", {} },
    .{ "br_table", {} },
    .{ "return", {} },
    .{ "call", {} },
    .{ "call_indirect", {} },
    .{ "local.get", {} },
    .{ "local.set", {} },
    .{ "local.tee", {} },
    .{ "global.get", {} },
    .{ "global.set", {} },
    .{ "table.get", {} },
    .{ "table.set", {} },
    .{ "memory.size", {} },
    .{ "memory.grow", {} },
    .{ "ref.null", {} },
    .{ "ref.is_null", {} },
    .{ "ref.func", {} },
});

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Writer) usize {
        return output_buf.len - self.idx;
    }

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.remaining() < s.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn writeSpan(self: *Writer, class_name: []const u8, text: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
        self.writeSlice(text);
        self.writeSlice("</span>");
    }
};

const CodeOpenTag = struct {
    end: usize,
    has_language_wasm: bool,
    has_hljs: bool,
};

const CodeClassInfo = struct {
    has_language: bool,
    has_hljs: bool,
};

const CodeCloseTag = struct {
    start: usize,
    end: usize,
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

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isTagNameBoundary(c: u8) bool {
    return c == '>' or c == '/' or isSpace(c);
}

fn isAttrNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == ':';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isAtomBoundary(c: u8) bool {
    return isSpace(c) or c == '(' or c == ')' or c == '"' or c == '\'' or c == ';';
}

fn classContainsLanguageWasm(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-wasm") or eqlIgnoreCase(token, "language-wat")) return true;
    }
    return false;
}

fn classContainsHljs(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        if (eqlIgnoreCase(value[start..i], "hljs")) return true;
    }
    return false;
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '>') return i;
    }
    return null;
}

fn codeTagClassInfoWasm(tag: []const u8) CodeClassInfo {
    var out: CodeClassInfo = .{ .has_language = false, .has_hljs = false };
    if (tag.len < 6) return out;
    var i: usize = 5; // after "<code"
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }

        const name_start = i;
        while (i < tag.len and isAttrNameChar(tag[i])) : (i += 1) {}
        if (name_start == i) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];

        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        var value: []const u8 = "";
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
            if (i >= tag.len) break;
            if (tag[i] == '"' or tag[i] == '\'') {
                const quote = tag[i];
                i += 1;
                const value_start = i;
                while (i < tag.len and tag[i] != quote) : (i += 1) {}
                value = tag[value_start..@min(i, tag.len)];
                if (i < tag.len and tag[i] == quote) i += 1;
            } else {
                const value_start = i;
                while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
                value = tag[value_start..i];
            }
        }

        if (eqlIgnoreCase(name, "class")) {
            if (classContainsLanguageWasm(value)) out.has_language = true;
            if (classContainsHljs(value)) out.has_hljs = true;
        }
    }
    return out;
}

fn findClassValueRange(tag: []const u8) ?struct { value_start: usize, value_end: usize } {
    if (tag.len < 6) return null;
    var i: usize = 5; // after "<code"
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }

        const name_start = i;
        while (i < tag.len and isAttrNameChar(tag[i])) : (i += 1) {}
        if (name_start == i) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];

        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len) break;

        var value_start = i;
        var value_end = i;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            value_start = i + 1;
            i += 1;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            value_end = @min(i, tag.len);
            if (i < tag.len and tag[i] == quote) i += 1;
        } else {
            value_start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
            value_end = i;
        }

        if (eqlIgnoreCase(name, "class")) {
            return .{ .value_start = value_start, .value_end = value_end };
        }
    }
    return null;
}

fn writeCodeOpenTagWithHljs(tag: []const u8, w: *Writer) void {
    const class_range = findClassValueRange(tag) orelse {
        w.writeSlice(tag);
        return;
    };
    const class_value = tag[class_range.value_start..class_range.value_end];
    if (classContainsHljs(class_value)) {
        w.writeSlice(tag);
        return;
    }
    w.writeSlice(tag[0..class_range.value_end]);
    if (class_value.len > 0) w.writeByte(' ');
    w.writeSlice("hljs");
    w.writeSlice(tag[class_range.value_end..]);
}

fn parseCodeOpenTag(input: []const u8, start: usize) ?CodeOpenTag {
    if (start + 5 > input.len) return null;
    if (input[start] != '<') return null;
    if (!eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isTagNameBoundary(input[start + 5])) return null;

    const end = findTagEnd(input, start + 5) orelse return null;
    const info = codeTagClassInfoWasm(input[start .. end + 1]);
    return .{ .end = end, .has_language_wasm = info.has_language, .has_hljs = info.has_hljs };
}

fn findCodeCloseTag(input: []const u8, from: usize) ?CodeCloseTag {
    var i = from;
    while (i + 7 <= input.len) : (i += 1) {
        if (input[i] != '<') continue;
        if (i + 2 >= input.len or input[i + 1] != '/') continue;
        if (i + 6 > input.len) continue;
        if (!eqlIgnoreCase(input[i + 2 .. i + 6], "code")) continue;

        var j = i + 6;
        if (j < input.len and !isTagNameBoundary(input[j])) continue;
        while (j < input.len and isSpace(input[j])) : (j += 1) {}
        if (j < input.len and input[j] == '>') {
            return .{ .start = i, .end = j };
        }
    }
    return null;
}

fn stringEnd(code: []const u8, start: usize) usize {
    if (start >= code.len) return start;
    if (std.mem.startsWith(u8, code[start..], "&quot;")) {
        var i = start + 6;
        while (i < code.len) : (i += 1) {
            if (std.mem.startsWith(u8, code[i..], "&quot;")) return i + 6;
        }
        return code.len;
    }
    const quote = code[start];
    var i = start + 1;
    var escaped = false;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == quote) return i + 1;
    }
    return code.len;
}

fn blockCommentEnd(code: []const u8, start: usize) usize {
    if (start + 1 >= code.len) return code.len;
    var i: usize = start + 2;
    var depth: usize = 1;
    while (i + 1 < code.len) {
        if (code[i] == '(' and code[i + 1] == ';') {
            depth += 1;
            i += 2;
            continue;
        }
        if (code[i] == ';' and code[i + 1] == ')') {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return code.len;
}

fn isNumericAtom(atom: []const u8) bool {
    if (atom.len == 0) return false;
    if (std.mem.eql(u8, atom, "nan") or std.mem.eql(u8, atom, "+nan") or std.mem.eql(u8, atom, "-nan") or std.mem.eql(u8, atom, "inf") or std.mem.eql(u8, atom, "+inf") or std.mem.eql(u8, atom, "-inf")) return true;

    var i: usize = 0;
    if (atom[i] == '+' or atom[i] == '-') {
        i += 1;
        if (i >= atom.len) return false;
    }

    if (i + 2 <= atom.len and atom[i] == '0' and (atom[i + 1] == 'x' or atom[i + 1] == 'X')) {
        i += 2;
        var has_hex = false;
        while (i < atom.len) : (i += 1) {
            const c = atom[i];
            if (isHexDigit(c)) {
                has_hex = true;
                continue;
            }
            if (c == '_' or c == '.' or c == 'p' or c == 'P' or c == '+' or c == '-') continue;
            return false;
        }
        return has_hex;
    }

    var has_digit = false;
    while (i < atom.len) : (i += 1) {
        const c = atom[i];
        if (isDigit(c)) {
            has_digit = true;
            continue;
        }
        if (c == '_' or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') continue;
        return false;
    }
    return has_digit;
}

fn isOpcodeLike(atom: []const u8) bool {
    if (InstrSet.get(atom) != null) return true;
    if (std.mem.indexOfScalar(u8, atom, '.')) |dot| {
        const head = atom[0..dot];
        if (std.mem.eql(u8, head, "i32") or std.mem.eql(u8, head, "i64") or std.mem.eql(u8, head, "f32") or std.mem.eql(u8, head, "f64") or std.mem.eql(u8, head, "v128") or std.mem.eql(u8, head, "local") or std.mem.eql(u8, head, "global") or std.mem.eql(u8, head, "memory") or std.mem.eql(u8, head, "table") or std.mem.eql(u8, head, "ref")) {
            return true;
        }
    }
    return false;
}

fn writeHighlightedWasm(code: []const u8, w: *Writer) void {
    var i: usize = 0;
    var expect_function_title = false;

    while (i < code.len) {
        if (i + 1 < code.len and code[i] == ';' and code[i + 1] == ';') {
            var j = i + 2;
            while (j < code.len and code[j] != '\n') : (j += 1) {}
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            continue;
        }

        if (i + 1 < code.len and code[i] == '(' and code[i + 1] == ';') {
            const j = blockCommentEnd(code, i);
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            continue;
        }

        if (code[i] == '"' or code[i] == '\'' or std.mem.startsWith(u8, code[i..], "&quot;")) {
            const j = stringEnd(code, i);
            w.writeSpan("hljs-string", code[i..j]);
            i = j;
            continue;
        }

        if (code[i] == '(' or code[i] == ')') {
            var j = i + 1;
            while (j < code.len and (code[j] == '(' or code[j] == ')')) : (j += 1) {}
            w.writeSpan("hljs-punctuation", code[i..j]);
            i = j;
            continue;
        }

        if (isAtomBoundary(code[i])) {
            w.writeByte(code[i]);
            i += 1;
            continue;
        }

        var j = i;
        while (j < code.len and !isAtomBoundary(code[j])) : (j += 1) {}
        const atom = code[i..j];

        if (atom.len > 0 and atom[0] == '$') {
            if (expect_function_title) {
                w.writeSpan("hljs-title function_", atom);
            } else {
                w.writeSpan("hljs-variable", atom);
            }
            expect_function_title = false;
        } else if (KeywordSet.get(atom) != null) {
            w.writeSpan("hljs-keyword", atom);
            expect_function_title = std.mem.eql(u8, atom, "func");
        } else if (TypeSet.get(atom) != null) {
            w.writeSpan("hljs-type", atom);
            expect_function_title = false;
        } else if (isNumericAtom(atom)) {
            w.writeSpan("hljs-number", atom);
            expect_function_title = false;
        } else if (isOpcodeLike(atom)) {
            w.writeSpan("hljs-keyword", atom);
            expect_function_title = false;
        } else {
            w.writeSlice(atom);
            expect_function_title = false;
        }
        i = j;
    }
}

fn transformHTML(input: []const u8, w: *Writer) void {
    var cursor: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }

        const open = parseCodeOpenTag(input, i) orelse {
            i += 1;
            continue;
        };

        w.writeSlice(input[cursor..i]);
        const close = findCodeCloseTag(input, open.end + 1) orelse {
            w.writeSlice(input[i..]);
            return;
        };

        const inner = input[open.end + 1 .. close.start];
        const should_highlight = open.has_language_wasm and !open.has_hljs;
        if (!should_highlight) {
            w.writeSlice(input[i .. close.end + 1]);
            cursor = close.end + 1;
            i = cursor;
            continue;
        }

        writeCodeOpenTagWithHljs(input[i .. open.end + 1], w);
        writeHighlightedWasm(inner, w);
        w.writeSlice(input[close.start .. close.end + 1]);
        cursor = close.end + 1;
        i = cursor;
    }
    if (cursor < input.len) {
        w.writeSlice(input[cursor..]);
    }
}

fn renderImpl(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();
    const input = input_buf[0..input_len];

    var w = Writer{};
    transformHTML(input, &w);
    if (w.overflow) @trap();
    return @as(u32, @intCast(w.idx));
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn runForTest(input: []const u8) []const u8 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const out_len = renderImpl(@as(u32, @intCast(input.len)));
    return output_buf[0..@as(usize, @intCast(out_len))];
}

test "highlights plain text language-wasm code blocks" {
    const input = "<pre><code class=\"language-wasm\">(module (func $add (param $a i32) (param $b i32) (result i32) local.get $a local.get $b i32.add))</code></pre>";
    const got = runForTest(input);
    const expected = "<pre><code class=\"language-wasm hljs\"><span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">module</span> <span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">func</span> <span class=\"hljs-title function_\">$add</span> <span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">param</span> <span class=\"hljs-variable\">$a</span> <span class=\"hljs-type\">i32</span><span class=\"hljs-punctuation\">)</span> <span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">param</span> <span class=\"hljs-variable\">$b</span> <span class=\"hljs-type\">i32</span><span class=\"hljs-punctuation\">)</span> <span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">result</span> <span class=\"hljs-type\">i32</span><span class=\"hljs-punctuation\">)</span> <span class=\"hljs-keyword\">local.get</span> <span class=\"hljs-variable\">$a</span> <span class=\"hljs-keyword\">local.get</span> <span class=\"hljs-variable\">$b</span> <span class=\"hljs-keyword\">i32.add</span><span class=\"hljs-punctuation\">))</span></code></pre>";
    try std.testing.expectEqualStrings(expected, got);
}

test "skips code blocks that already contain spans" {
    const input = "<code class=\"language-wasm hljs\"><span class=\"hljs-keyword\">module</span></code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "skips non-wasm code blocks" {
    const input = "<code class=\"language-rust\">fn main() {}</code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "highlights comments strings and numbers" {
    const input = "<code class=\"language-wasm\">;; head\n(data (i32.const 0) \"hi\")</code>";
    const got = runForTest(input);
    const expected = "<code class=\"language-wasm hljs\"><span class=\"hljs-comment\">;; head</span>\n<span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">data</span> <span class=\"hljs-punctuation\">(</span><span class=\"hljs-keyword\">i32.const</span> <span class=\"hljs-number\">0</span><span class=\"hljs-punctuation\">)</span> <span class=\"hljs-string\">\"hi\"</span><span class=\"hljs-punctuation\">)</span></code>";
    try std.testing.expectEqualStrings(expected, got);
}
