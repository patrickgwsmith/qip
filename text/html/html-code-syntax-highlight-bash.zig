const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "if", {} },
    .{ "then", {} },
    .{ "elif", {} },
    .{ "else", {} },
    .{ "fi", {} },
    .{ "for", {} },
    .{ "while", {} },
    .{ "until", {} },
    .{ "in", {} },
    .{ "do", {} },
    .{ "done", {} },
    .{ "case", {} },
    .{ "esac", {} },
    .{ "function", {} },
    .{ "select", {} },
    .{ "time", {} },
    .{ "coproc", {} },
    .{ "break", {} },
    .{ "continue", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "echo", {} },
    .{ "printf", {} },
    .{ "cat", {} },
    .{ "read", {} },
    .{ "cd", {} },
    .{ "pwd", {} },
    .{ "export", {} },
    .{ "unset", {} },
    .{ "local", {} },
    .{ "declare", {} },
    .{ "typeset", {} },
    .{ "alias", {} },
    .{ "unalias", {} },
    .{ "eval", {} },
    .{ "exec", {} },
    .{ "exit", {} },
    .{ "return", {} },
    .{ "set", {} },
    .{ "shift", {} },
    .{ "source", {} },
    .{ ".", {} },
    .{ "trap", {} },
    .{ "test", {} },
    .{ "true", {} },
    .{ "false", {} },
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
        self.openSpan(class_name);
        self.writeSlice(text);
        self.closeSpan();
    }

    fn openSpan(self: *Writer, class_name: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
    }

    fn closeSpan(self: *Writer) void {
        self.writeSlice("</span>");
    }
};

const CodeOpenTag = struct {
    end: usize,
    has_language_bash: bool,
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

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return isLetter(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isVarSpecial(c: u8) bool {
    return c == '@' or c == '*' or c == '#' or c == '?' or c == '!' or c == '-' or c == '$';
}

fn isCommentPrefixBoundary(c: u8) bool {
    return isSpace(c) or c == ';' or c == '(' or c == ')' or c == '{' or c == '}' or c == '|' or c == '&';
}

fn classContainsLanguageBash(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-bash") or eqlIgnoreCase(token, "language-sh") or eqlIgnoreCase(token, "language-shell")) return true;
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

fn codeTagClassInfoBash(tag: []const u8) CodeClassInfo {
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
            if (classContainsLanguageBash(value)) out.has_language = true;
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
    const info = codeTagClassInfoBash(input[start .. end + 1]);
    return .{ .end = end, .has_language_bash = info.has_language, .has_hljs = info.has_hljs };
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

const Quote = struct {
    byte: u8,
    len: usize,
};

fn quoteAt(code: []const u8, start: usize) ?Quote {
    if (start >= code.len) return null;
    if (code[start] == '"' or code[start] == '\'') return .{ .byte = code[start], .len = 1 };
    if (std.mem.startsWith(u8, code[start..], "&quot;")) return .{ .byte = '"', .len = 6 };
    if (std.mem.startsWith(u8, code[start..], "&#39;")) return .{ .byte = '\'', .len = 5 };
    return null;
}

fn matchingQuoteAt(code: []const u8, start: usize, quote: Quote) bool {
    const candidate = quoteAt(code, start) orelse return false;
    return candidate.byte == quote.byte and candidate.len == quote.len;
}

fn plainStringEnd(code: []const u8, start: usize, quote: Quote) usize {
    var i = start + quote.len;
    var escaped = false;
    while (i < code.len) {
        if (escaped) {
            escaped = false;
            i += 1;
            continue;
        }
        if (quote.byte == '"' and code[i] == '\\') {
            escaped = true;
            i += 1;
            continue;
        }
        if (matchingQuoteAt(code, i, quote)) return i + quote.len;
        i += 1;
    }
    return code.len;
}

fn commandSubstitutionEnd(code: []const u8, start: usize) usize {
    var i = start + 2;
    var depth: usize = 1;
    while (i < code.len) {
        if (quoteAt(code, i)) |quote| {
            i = plainStringEnd(code, i, quote);
            continue;
        }
        if (i + 1 < code.len and code[i] == '$' and code[i + 1] == '(') {
            depth += 1;
            i += 2;
            continue;
        }
        if (code[i] == ')') {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return code.len;
}

fn variableEnd(code: []const u8, start: usize) usize {
    if (start + 1 >= code.len or code[start] != '$') return start + 1;

    if (code[start + 1] == '{') {
        var i = start + 2;
        while (i < code.len and code[i] != '}') : (i += 1) {}
        if (i < code.len and code[i] == '}') return i + 1;
        return code.len;
    }

    if (isIdentStart(code[start + 1])) {
        var i = start + 2;
        while (i < code.len and isIdentContinue(code[i])) : (i += 1) {}
        return i;
    }

    if (isDigit(code[start + 1]) or isVarSpecial(code[start + 1])) {
        return start + 2;
    }

    return start + 1;
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    if (i < code.len and (code[i] == '+' or code[i] == '-')) i += 1;
    if (i + 2 <= code.len and code[i] == '0' and (code[i + 1] == 'x' or code[i + 1] == 'X')) {
        i += 2;
        while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or (code[i] >= 'a' and code[i] <= 'f') or (code[i] >= 'A' and code[i] <= 'F') or code[i] == '_')) : (i += 1) {}
        return i;
    }
    while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or code[i] == '_')) : (i += 1) {}
    return i;
}

fn writeBashString(code: []const u8, start: usize, quote: Quote, w: *Writer) usize {
    w.openSpan("hljs-string");
    w.writeSlice(code[start .. start + quote.len]);

    var i = start + quote.len;
    if (quote.byte == '\'') {
        const end = plainStringEnd(code, start, quote);
        w.writeSlice(code[i..end]);
        w.closeSpan();
        return end;
    }

    while (i < code.len) {
        if (matchingQuoteAt(code, i, quote)) {
            w.writeSlice(code[i .. i + quote.len]);
            i += quote.len;
            w.closeSpan();
            return i;
        }
        if (i + 1 < code.len and code[i] == '$' and code[i + 1] == '(') {
            const end = commandSubstitutionEnd(code, i);
            w.openSpan("hljs-subst");
            w.writeSlice("$(");
            if (end >= i + 3) writeHighlightedBash(code[i + 2 .. end - 1], w);
            if (end > i + 2 and code[end - 1] == ')') w.writeByte(')');
            w.closeSpan();
            i = end;
            continue;
        }
        if (code[i] == '$') {
            const end = variableEnd(code, i);
            w.writeSpan("hljs-variable", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '\\' and i + 1 < code.len) {
            w.writeSlice(code[i .. i + 2]);
            i += 2;
            continue;
        }
        w.writeByte(code[i]);
        i += 1;
    }

    w.closeSpan();
    return i;
}

fn heredocEnd(code: []const u8, start: usize) ?struct { operator_end: usize, marker_start: usize, end: usize } {
    var operator_end: usize = undefined;
    if (std.mem.startsWith(u8, code[start..], "&lt;&lt;")) {
        operator_end = start + 8;
    } else if (std.mem.startsWith(u8, code[start..], "<<")) {
        operator_end = start + 2;
    } else {
        return null;
    }

    var marker_start = operator_end;
    if (marker_start < code.len and code[marker_start] == '-') marker_start += 1;
    while (marker_start < code.len and (code[marker_start] == ' ' or code[marker_start] == '\t')) : (marker_start += 1) {}
    const marker_end = blk: {
        var j = marker_start;
        while (j < code.len and isIdentContinue(code[j])) : (j += 1) {}
        break :blk j;
    };
    if (marker_end == marker_start or marker_end >= code.len or code[marker_end] != '\n') return null;
    const marker = code[marker_start..marker_end];

    var line_start = marker_end + 1;
    while (line_start <= code.len) {
        var line_end = line_start;
        while (line_end < code.len and code[line_end] != '\n') : (line_end += 1) {}
        if (std.mem.eql(u8, code[line_start..line_end], marker)) {
            return .{ .operator_end = operator_end, .marker_start = marker_start, .end = line_end };
        }
        if (line_end == code.len) break;
        line_start = line_end + 1;
    }
    return null;
}

fn writeHighlightedBash(code: []const u8, w: *Writer) void {
    var i: usize = 0;
    var at_line_start = true;

    while (i < code.len) {
        if (code[i] == '\n') {
            w.writeByte('\n');
            i += 1;
            at_line_start = true;
            continue;
        }

        if (at_line_start and code[i] == '#' and i + 1 < code.len and code[i + 1] == '!') {
            var j = i + 2;
            while (j < code.len and code[j] != '\n') : (j += 1) {}
            w.writeSpan("hljs-meta", code[i..j]);
            i = j;
            at_line_start = false;
            continue;
        }

        if (code[i] == '#' and (i == 0 or isCommentPrefixBoundary(code[i - 1]))) {
            var j = i + 1;
            while (j < code.len and code[j] != '\n') : (j += 1) {}
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            at_line_start = false;
            continue;
        }

        if (heredocEnd(code, i)) |heredoc| {
            w.writeSlice(code[i..heredoc.operator_end]);
            w.writeSlice(code[heredoc.operator_end..heredoc.marker_start]);
            w.writeSpan("hljs-string", code[heredoc.marker_start..heredoc.end]);
            i = heredoc.end;
            at_line_start = false;
            continue;
        }

        if (quoteAt(code, i)) |quote| {
            i = writeBashString(code, i, quote, w);
            at_line_start = false;
            continue;
        }

        if (code[i] == '$') {
            const j = variableEnd(code, i);
            w.writeSpan("hljs-variable", code[i..j]);
            i = j;
            at_line_start = false;
            continue;
        }

        if (isDigit(code[i]) or ((code[i] == '+' or code[i] == '-') and i + 1 < code.len and isDigit(code[i + 1]))) {
            const j = numberEnd(code, i);
            if (j > i) {
                w.writeSpan("hljs-number", code[i..j]);
                i = j;
                at_line_start = false;
                continue;
            }
        }

        if (isIdentStart(code[i]) or code[i] == '.') {
            var j = i + 1;
            while (j < code.len and (isIdentContinue(code[j]) or code[j] == '-')) : (j += 1) {}
            const ident = code[i..j];
            var after = j;
            while (after < code.len and (code[after] == ' ' or code[after] == '\t')) : (after += 1) {}
            const is_function = after + 1 < code.len and code[after] == '(' and code[after + 1] == ')';
            if (is_function) {
                w.openSpan("hljs-function");
                w.writeSpan("hljs-title", ident);
                w.closeSpan();
            } else if (KeywordSet.get(ident) != null) {
                w.writeSpan("hljs-keyword", ident);
            } else if (BuiltinSet.get(ident) != null) {
                w.writeSpan("hljs-built_in", ident);
            } else {
                w.writeSlice(ident);
            }
            i = j;
            at_line_start = false;
            continue;
        }

        if (!isSpace(code[i])) at_line_start = false;
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
        const should_highlight = open.has_language_bash and !open.has_hljs;
        if (!should_highlight) {
            w.writeSlice(input[i .. close.end + 1]);
            cursor = close.end + 1;
            i = cursor;
            continue;
        }

        writeCodeOpenTagWithHljs(input[i .. open.end + 1], w);
        writeHighlightedBash(inner, w);
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

test "highlights plain text language-bash code blocks" {
    const input = "<pre><code class=\"language-bash\">if [ -n \"$HOME\" ]; then echo $HOME; fi</code></pre>";
    const got = runForTest(input);
    const expected = "<pre><code class=\"language-bash hljs\"><span class=\"hljs-keyword\">if</span> [ -n <span class=\"hljs-string\">\"<span class=\"hljs-variable\">$HOME</span>\"</span> ]; <span class=\"hljs-keyword\">then</span> <span class=\"hljs-built_in\">echo</span> <span class=\"hljs-variable\">$HOME</span>; <span class=\"hljs-keyword\">fi</span></code></pre>";
    try std.testing.expectEqualStrings(expected, got);
}

test "skips code blocks that already contain spans" {
    const input = "<code class=\"language-bash hljs\"><span class=\"hljs-keyword\">if</span> true; then echo ok; fi</code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "skips non-bash code blocks" {
    const input = "<code class=\"language-python\">print(1)</code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "highlights shebang comments variables and numbers" {
    const input = "<code class=\"language-bash\">#!/usr/bin/env bash\n# set answer\nx=${USER:-guest}\necho $x 42</code>";
    const got = runForTest(input);
    const expected = "<code class=\"language-bash hljs\"><span class=\"hljs-meta\">#!/usr/bin/env bash</span>\n<span class=\"hljs-comment\"># set answer</span>\nx=<span class=\"hljs-variable\">${USER:-guest}</span>\n<span class=\"hljs-built_in\">echo</span> <span class=\"hljs-variable\">$x</span> <span class=\"hljs-number\">42</span></code>";
    try std.testing.expectEqualStrings(expected, got);
}
