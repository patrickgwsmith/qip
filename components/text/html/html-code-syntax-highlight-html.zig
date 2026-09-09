const std = @import("std");
const css = @import("lib/syntax-highlight-css.zig");
const javascript = @import("lib/syntax-highlight-javascript.zig");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Writer) usize {
        return output_buf.len - self.idx;
    }

    pub fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    pub fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.remaining() < s.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    pub fn writeSpan(self: *Writer, class_name: []const u8, text: []const u8) void {
        self.openSpan(class_name);
        self.writeSlice(text);
        self.closeSpan();
    }

    pub fn writeOperator(self: *Writer, text: []const u8) void {
        self.writeSlice(text);
    }

    pub fn writeParameterType(self: *Writer, text: []const u8) void {
        self.writeSpan("hljs-title class_", text);
    }

    pub fn openSpan(self: *Writer, class_name: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
    }

    pub fn closeSpan(self: *Writer) void {
        self.writeSlice("</span>");
    }
};

const CodeOpenTag = struct {
    end: usize,
    has_language_html: bool,
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

fn classContainsLanguageHTML(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i > start) {
            const token = value[start..i];
            if (eqlIgnoreCase(token, "language-html") or
                eqlIgnoreCase(token, "language-xml") or
                eqlIgnoreCase(token, "language-markup"))
            {
                return true;
            }
        }
    }
    return false;
}

fn classContainsHljs(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i > start and eqlIgnoreCase(value[start..i], "hljs")) return true;
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

fn codeTagClassInfoHTML(tag: []const u8) CodeClassInfo {
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
            if (classContainsLanguageHTML(value)) out.has_language = true;
            if (classContainsHljs(value)) out.has_hljs = true;
        }
    }
    return out;
}

fn findClassValueRange(tag: []const u8) ?struct { value_start: usize, value_end: usize } {
    if (tag.len < 6) return null;
    var i: usize = 5;
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
            if (i < tag.len) i += 1;
        } else {
            value_start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
            value_end = i;
        }
        if (eqlIgnoreCase(name, "class")) return .{ .value_start = value_start, .value_end = value_end };
    }
    return null;
}

fn writeCodeOpenTagWithHljs(tag: []const u8, w: *Writer) void {
    const range = findClassValueRange(tag) orelse {
        w.writeSlice(tag);
        return;
    };
    if (classContainsHljs(tag[range.value_start..range.value_end])) {
        w.writeSlice(tag);
        return;
    }
    w.writeSlice(tag[0..range.value_end]);
    if (range.value_end > range.value_start) w.writeByte(' ');
    w.writeSlice("hljs");
    w.writeSlice(tag[range.value_end..]);
}

fn parseCodeOpenTag(input: []const u8, start: usize) ?CodeOpenTag {
    if (start + 5 > input.len) return null;
    if (input[start] != '<') return null;
    if (!eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isTagNameBoundary(input[start + 5])) return null;

    const end = findTagEnd(input, start + 5) orelse return null;
    const info = codeTagClassInfoHTML(input[start .. end + 1]);
    return .{
        .end = end,
        .has_language_html = info.has_language,
        .has_hljs = info.has_hljs,
    };
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

fn startsWithAt(s: []const u8, i: usize, needle: []const u8) bool {
    return i + needle.len <= s.len and std.mem.eql(u8, s[i .. i + needle.len], needle);
}

fn isEscapedTagStart(code: []const u8, i: usize) bool {
    return startsWithAt(code, i, "&lt;");
}

fn isEscapedTagEnd(code: []const u8, i: usize) bool {
    return startsWithAt(code, i, "&gt;");
}

fn isEscapedQuote(code: []const u8, i: usize) ?usize {
    if (startsWithAt(code, i, "&quot;")) return 6;
    if (startsWithAt(code, i, "&#34;")) return 5;
    if (startsWithAt(code, i, "&#x22;") or startsWithAt(code, i, "&#X22;")) return 6;
    if (startsWithAt(code, i, "&#39;")) return 5;
    if (startsWithAt(code, i, "&#x27;") or startsWithAt(code, i, "&#X27;")) return 6;
    return null;
}

fn isRawQuote(c: u8) bool {
    return c == '"' or c == '\'';
}

fn isHTMLNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == ':' or c == '_' or c == '!' or c == '?';
}

fn isHTMLNameContinue(c: u8) bool {
    return isHTMLNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

fn skipSpaces(code: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < code.len and isSpace(code[i])) : (i += 1) {}
    return i;
}

fn writeEntity(w: *Writer, class_name: []const u8, code: []const u8, start: usize, end: usize) void {
    if (end > start) w.writeSpan(class_name, code[start..end]);
}

fn writeAttributeValue(code: []const u8, w: *Writer, start: usize) usize {
    if (start >= code.len) return start;

    if (isEscapedQuote(code, start)) |quote_len| {
        const quote = code[start .. start + quote_len];
        var i = start + quote_len;
        while (i < code.len) {
            if (startsWithAt(code, i, quote)) {
                i += quote_len;
                break;
            }
            if (isEscapedTagEnd(code, i)) break;
            i += 1;
        }
        w.writeSpan("hljs-string", code[start..i]);
        return i;
    }

    if (isRawQuote(code[start])) {
        const quote = code[start];
        var i = start + 1;
        while (i < code.len and code[i] != quote) : (i += 1) {}
        if (i < code.len) i += 1;
        w.writeSpan("hljs-string", code[start..i]);
        return i;
    }

    var i = start;
    while (i < code.len and !isSpace(code[i]) and !isEscapedTagEnd(code, i)) : (i += 1) {}
    w.writeSpan("hljs-string", code[start..i]);
    return i;
}

fn findEscapedCommentEnd(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len) : (i += 1) {
        if (startsWithAt(code, i, "--&gt;")) return i + "--&gt;".len;
    }
    return code.len;
}

fn startsWithIgnoreCaseAt(code: []const u8, start: usize, needle: []const u8) bool {
    if (start + needle.len > code.len) return false;
    return eqlIgnoreCase(code[start .. start + needle.len], needle);
}

fn writeDoctype(code: []const u8, w: *Writer, start: usize) ?usize {
    if (!startsWithIgnoreCaseAt(code, start, "&lt;!doctype")) return null;
    var end = start + "&lt;!doctype".len;
    while (end < code.len and !isEscapedTagEnd(code, end)) : (end += 1) {}
    if (end < code.len) end += "&gt;".len;

    w.openSpan("hljs-meta");
    var keyword_start = start + "&lt;!doctype".len;
    while (keyword_start < end and isSpace(code[keyword_start])) : (keyword_start += 1) {}
    w.writeSlice(code[start..keyword_start]);
    var keyword_end = keyword_start;
    while (keyword_end < end and isHTMLNameContinue(code[keyword_end])) : (keyword_end += 1) {}
    if (keyword_end > keyword_start) w.writeSpan("hljs-keyword", code[keyword_start..keyword_end]);
    w.writeSlice(code[keyword_end..end]);
    w.closeSpan();
    return end;
}

fn writeHighlightedEscapedTag(code: []const u8, w: *Writer, start: usize) usize {
    if (startsWithAt(code, start, "&lt;!--")) {
        const end = findEscapedCommentEnd(code, start + "&lt;!--".len);
        w.writeSpan("hljs-comment", code[start..end]);
        return end;
    }
    if (writeDoctype(code, w, start)) |end| return end;

    var i = start;
    w.openSpan("hljs-tag");
    w.writeSlice(code[i .. i + "&lt;".len]);
    i += "&lt;".len;

    i = skipSpaces(code, i);
    if (i < code.len and code[i] == '/') {
        w.writeByte('/');
        i += 1;
        i = skipSpaces(code, i);
    }

    if (i < code.len and isHTMLNameStart(code[i])) {
        const name_start = i;
        i += 1;
        while (i < code.len and isHTMLNameContinue(code[i])) : (i += 1) {}
        w.writeSpan("hljs-name", code[name_start..i]);
    }

    while (i < code.len) {
        if (isEscapedTagEnd(code, i)) {
            w.writeSlice(code[i .. i + "&gt;".len]);
            w.closeSpan();
            return i + "&gt;".len;
        }

        if (isSpace(code[i])) {
            w.writeByte(code[i]);
            i += 1;
            continue;
        }

        if (code[i] == '/') {
            w.writeByte('/');
            i += 1;
            continue;
        }

        if (isHTMLNameStart(code[i])) {
            const attr_start = i;
            i += 1;
            while (i < code.len and isHTMLNameContinue(code[i])) : (i += 1) {}
            w.writeSpan("hljs-attr", code[attr_start..i]);
            const before_spaces = i;
            i = skipSpaces(code, i);
            if (i > before_spaces) w.writeSlice(code[before_spaces..i]);
            if (i < code.len and code[i] == '=') {
                w.writeByte('=');
                i += 1;
                const value_spaces = i;
                i = skipSpaces(code, i);
                if (i > value_spaces) w.writeSlice(code[value_spaces..i]);
                i = writeAttributeValue(code, w, i);
            }
            continue;
        }

        w.writeByte(code[i]);
        i += 1;
    }

    w.closeSpan();
    return i;
}

const EmbeddedLanguage = enum { css, javascript };

fn embeddedLanguageAt(code: []const u8, start: usize) ?EmbeddedLanguage {
    if (!startsWithAt(code, start, "&lt;")) return null;
    var i = skipSpaces(code, start + "&lt;".len);
    if (i >= code.len or code[i] == '/') return null;
    const name_start = i;
    while (i < code.len and isHTMLNameContinue(code[i])) : (i += 1) {}
    const name = code[name_start..i];
    if (eqlIgnoreCase(name, "style")) return .css;
    if (eqlIgnoreCase(name, "script")) return .javascript;
    return null;
}

fn findEmbeddedClose(code: []const u8, start: usize, language: EmbeddedLanguage) ?usize {
    const name = switch (language) {
        .css => "style",
        .javascript => "script",
    };
    var i = start;
    while (i + "&lt;/".len + name.len <= code.len) : (i += 1) {
        if (!startsWithAt(code, i, "&lt;/")) continue;
        var cursor = skipSpaces(code, i + "&lt;/".len);
        if (cursor + name.len > code.len or !eqlIgnoreCase(code[cursor .. cursor + name.len], name)) continue;
        cursor += name.len;
        cursor = skipSpaces(code, cursor);
        if (isEscapedTagEnd(code, cursor)) return i;
    }
    return null;
}

fn writeHighlightedHTML(code: []const u8, w: *Writer) void {
    var i: usize = 0;
    while (i < code.len) {
        if (isEscapedTagStart(code, i)) {
            const embedded = embeddedLanguageAt(code, i);
            i = writeHighlightedEscapedTag(code, w, i);
            if (embedded) |language| {
                const close = findEmbeddedClose(code, i, language) orelse code.len;
                switch (language) {
                    .css => css.write(code[i..close], w),
                    .javascript => javascript.write(code[i..close], w),
                }
                i = close;
            }
            continue;
        }

        if (code[i] == '<') {
            var j = i + 1;
            while (j < code.len and code[j] != '>') : (j += 1) {}
            if (j < code.len) j += 1;
            writeEntity(w, "hljs-tag", code, i, j);
            i = j;
            continue;
        }

        if (startsWithAt(code, i, "&amp;")) {
            var j = i + "&amp;".len;
            while (j < code.len and code[j] != ';' and !isSpace(code[j])) : (j += 1) {}
            if (j < code.len and code[j] == ';') j += 1;
            w.writeSpan("hljs-symbol", code[i..j]);
            i = j;
            continue;
        }

        w.writeByte(code[i]);
        i += 1;
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
        if (!open.has_language_html or open.has_hljs or std.mem.indexOf(u8, inner, "<span class=\"hljs-") != null) {
            w.writeSlice(input[i .. close.end + 1]);
            cursor = close.end + 1;
            i = cursor;
            continue;
        }

        writeCodeOpenTagWithHljs(input[i .. open.end + 1], w);
        writeHighlightedHTML(inner, w);
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

test "highlights escaped html code blocks" {
    const input = "<pre><code class=\"language-html\">&lt;div class=&quot;card&quot;&gt;Hello&lt;/div&gt;</code></pre>";
    const got = runForTest(input);
    const expected = "<pre><code class=\"language-html hljs\"><span class=\"hljs-tag\">&lt;<span class=\"hljs-name\">div</span> <span class=\"hljs-attr\">class</span>=<span class=\"hljs-string\">&quot;card&quot;</span>&gt;</span>Hello<span class=\"hljs-tag\">&lt;/<span class=\"hljs-name\">div</span>&gt;</span></code></pre>";
    try std.testing.expectEqualStrings(expected, got);
}

test "highlights escaped html comments" {
    const input = "<code class=\"language-html\">&lt;!-- note --&gt;</code>";
    const got = runForTest(input);
    const expected = "<code class=\"language-html hljs\"><span class=\"hljs-comment\">&lt;!-- note --&gt;</span></code>";
    try std.testing.expectEqualStrings(expected, got);
}

test "skips code blocks that already contain spans" {
    const input = "<code class=\"language-html\"><span class=\"hljs-name\">div</span></code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "skips non-html code blocks" {
    const input = "<code class=\"language-js\">const x = 1;</code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "highlights CSS and JavaScript inside escaped style and script elements" {
    const input = "<code class=\"language-html\">&lt;style&gt;.card { color: #fff; content: \"return\"; }&lt;/style&gt;\n&lt;script&gt;const message = \"return class\"; console.log(message);&lt;/script&gt;</code>";
    const expected = "<code class=\"language-html hljs\"><span class=\"hljs-tag\">&lt;<span class=\"hljs-name\">style</span>&gt;</span><span class=\"hljs-selector-class\">.card</span> { <span class=\"hljs-attribute\">color</span>: <span class=\"hljs-number\">#fff</span>; <span class=\"hljs-attribute\">content</span>: <span class=\"hljs-string\">\"return\"</span>; }<span class=\"hljs-tag\">&lt;/<span class=\"hljs-name\">style</span>&gt;</span>\n<span class=\"hljs-tag\">&lt;<span class=\"hljs-name\">script</span>&gt;</span><span class=\"hljs-keyword\">const</span> message = <span class=\"hljs-string\">\"return class\"</span>; <span class=\"hljs-variable language_\">console</span>.<span class=\"hljs-title function_\">log</span>(message);<span class=\"hljs-tag\">&lt;/<span class=\"hljs-name\">script</span>&gt;</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}
