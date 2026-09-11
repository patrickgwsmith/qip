const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "break", {} },     .{ "default", {} },     .{ "func", {} },
    .{ "interface", {} }, .{ "select", {} },      .{ "case", {} },
    .{ "defer", {} },     .{ "go", {} },          .{ "map", {} },
    .{ "struct", {} },    .{ "chan", {} },        .{ "else", {} },
    .{ "goto", {} },      .{ "package", {} },     .{ "switch", {} },
    .{ "const", {} },     .{ "fallthrough", {} }, .{ "if", {} },
    .{ "range", {} },     .{ "type", {} },        .{ "continue", {} },
    .{ "for", {} },       .{ "import", {} },      .{ "return", {} },
    .{ "var", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "any", {} },        .{ "bool", {} },      .{ "byte", {} },
    .{ "comparable", {} }, .{ "complex64", {} }, .{ "complex128", {} },
    .{ "error", {} },      .{ "float32", {} },   .{ "float64", {} },
    .{ "int", {} },        .{ "int8", {} },      .{ "int16", {} },
    .{ "int32", {} },      .{ "int64", {} },     .{ "rune", {} },
    .{ "string", {} },     .{ "uint", {} },      .{ "uint8", {} },
    .{ "uint16", {} },     .{ "uint32", {} },    .{ "uint64", {} },
    .{ "uintptr", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "iota", {} },
    .{ "nil", {} },
    .{ "true", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "append", {} },  .{ "cap", {} },     .{ "clear", {} },
    .{ "close", {} },   .{ "complex", {} }, .{ "copy", {} },
    .{ "delete", {} },  .{ "imag", {} },    .{ "len", {} },
    .{ "make", {} },    .{ "max", {} },     .{ "min", {} },
    .{ "new", {} },     .{ "panic", {} },   .{ "print", {} },
    .{ "println", {} }, .{ "real", {} },    .{ "recover", {} },
});

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Writer, byte: u8) void {
        if (self.overflow) return;
        if (self.idx == output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = byte;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, bytes: []const u8) void {
        if (self.overflow or bytes.len == 0) return;
        if (bytes.len > output_buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + bytes.len], bytes);
        self.idx += bytes.len;
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

const CodeTag = struct {
    end: usize,
    is_go: bool,
    has_hljs: bool,
};

const CloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_go: bool = false,
    has_hljs: bool = false,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_utf8_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (lower(left) != lower(right)) return false;
    }
    return true;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isNameBoundary(byte: u8) bool {
    return byte == '>' or byte == '/' or isSpace(byte);
}

fn isAttrChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':';
}

fn isIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentContinue(byte: u8) bool {
    return isIdentStart(byte) or std.ascii.isDigit(byte);
}

fn classInfo(value: []const u8) ClassInfo {
    var result = ClassInfo{};
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (start == i) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-go") or eqlIgnoreCase(token, "language-golang")) result.is_go = true;
        if (eqlIgnoreCase(token, "hljs")) result.has_hljs = true;
    }
    return result;
}

fn tagEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        if (quote != 0) {
            if (input[i] == quote) quote = 0;
        } else if (input[i] == '"' or input[i] == '\'') {
            quote = input[i];
        } else if (input[i] == '>') {
            return i;
        }
    }
    return null;
}

fn classRange(tag: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 5;
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }
        const name_start = i;
        while (i < tag.len and isAttrChar(tag[i])) : (i += 1) {}
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
        var start = i;
        var end = i;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            i += 1;
            start = i;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            end = i;
            if (i < tag.len) i += 1;
        } else {
            start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
            end = i;
        }
        if (eqlIgnoreCase(name, "class")) return .{ .start = start, .end = end };
    }
    return null;
}

fn parseOpenTag(input: []const u8, start: usize) ?CodeTag {
    if (start + 5 > input.len or input[start] != '<') return null;
    if (!eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isNameBoundary(input[start + 5])) return null;
    const end = tagEnd(input, start + 5) orelse return null;
    const tag = input[start .. end + 1];
    const range = classRange(tag) orelse return .{ .end = end, .is_go = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_go = info.is_go, .has_hljs = info.has_hljs };
}

fn closeTag(input: []const u8, start: usize) ?CloseTag {
    var i = start;
    while (i + 7 <= input.len) : (i += 1) {
        if (input[i] != '<' or input[i + 1] != '/') continue;
        if (!eqlIgnoreCase(input[i + 2 .. i + 6], "code")) continue;
        var end = i + 6;
        if (end < input.len and !isNameBoundary(input[end])) continue;
        while (end < input.len and isSpace(input[end])) : (end += 1) {}
        if (end < input.len and input[end] == '>') return .{ .start = i, .end = end };
    }
    return null;
}

fn containsSpanTag(code: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= code.len) : (i += 1) {
        if (code[i] != '<') continue;
        if (!eqlIgnoreCase(code[i + 1 .. i + 5], "span")) continue;
        if (i + 5 == code.len or isNameBoundary(code[i + 5])) return true;
    }
    return false;
}

fn writeOpenTag(tag: []const u8, writer: *Writer) void {
    const range = classRange(tag) orelse {
        writer.writeSlice(tag);
        return;
    };
    writer.writeSlice(tag[0..range.end]);
    if (range.start != range.end) writer.writeByte(' ');
    writer.writeSlice("hljs");
    writer.writeSlice(tag[range.end..]);
}

const Quote = struct {
    byte: u8,
    len: usize,
};

fn quoteAt(code: []const u8, start: usize) ?Quote {
    if (start >= code.len) return null;
    if (code[start] == '"' or code[start] == '\'' or code[start] == '`') {
        return .{ .byte = code[start], .len = 1 };
    }
    if (start + 6 <= code.len and std.mem.eql(u8, code[start .. start + 6], "&quot;")) {
        return .{ .byte = '"', .len = 6 };
    }
    if (start + 5 <= code.len and std.mem.eql(u8, code[start .. start + 5], "&#39;")) {
        return .{ .byte = '\'', .len = 5 };
    }
    if (start + 5 <= code.len and std.mem.eql(u8, code[start .. start + 5], "&#34;")) {
        return .{ .byte = '"', .len = 5 };
    }
    return null;
}

fn stringEnd(code: []const u8, start: usize, quote: Quote) usize {
    var i = start + quote.len;
    while (i < code.len) {
        if (quote.byte != '`' and code[i] == '\\') {
            i += @min(@as(usize, 2), code.len - i);
            continue;
        }
        if (quoteAt(code, i)) |candidate| {
            if (candidate.byte == quote.byte) return i + candidate.len;
        }
        i += 1;
    }
    return code.len;
}

fn isNumberContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.';
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < code.len) {
        if (isNumberContinue(code[i])) {
            i += 1;
            continue;
        }
        if ((code[i] == '+' or code[i] == '-') and i > start) {
            const previous = code[i - 1];
            if (previous == 'e' or previous == 'E' or previous == 'p' or previous == 'P') {
                i += 1;
                continue;
            }
        }
        break;
    }
    return i;
}

fn matchingDelimiter(code: []const u8, start: usize, open: u8, close: u8) ?usize {
    if (start >= code.len or code[start] != open) return null;
    var depth: usize = 1;
    var i = start + 1;
    while (i < code.len) {
        if (quoteAt(code, i)) |quote| {
            i = stringEnd(code, i, quote);
            continue;
        }
        if (code[i] == open) depth += 1;
        if (code[i] == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn skipHorizontalSpace(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len and (code[i] == ' ' or code[i] == '\t')) : (i += 1) {}
    return i;
}

fn writeFunctionDeclaration(code: []const u8, start: usize, keyword_end: usize, writer: *Writer) ?usize {
    var i = skipHorizontalSpace(code, keyword_end);
    writer.openSpan("hljs-function");
    writer.writeSpan("hljs-keyword", code[start..keyword_end]);
    writer.writeSlice(code[keyword_end..i]);

    if (i < code.len and code[i] == '(') {
        const receiver_end = matchingDelimiter(code, i, '(', ')') orelse {
            writer.closeSpan();
            return null;
        };
        writer.openSpan("hljs-params");
        writer.writeByte('(');
        writeGoTokens(code[i + 1 .. receiver_end], writer, false);
        writer.writeByte(')');
        writer.closeSpan();
        const after_receiver = skipHorizontalSpace(code, receiver_end + 1);
        writer.writeSlice(code[receiver_end + 1 .. after_receiver]);
        i = after_receiver;
    }

    if (i >= code.len or !isIdentStart(code[i])) {
        writer.closeSpan();
        return null;
    }
    var name_end = i + 1;
    while (name_end < code.len and isIdentContinue(code[name_end])) : (name_end += 1) {}
    writer.writeSpan("hljs-title", code[i..name_end]);
    i = name_end;

    if (i < code.len and code[i] == '[') {
        const generics_end = matchingDelimiter(code, i, '[', ']') orelse {
            writer.closeSpan();
            return null;
        };
        writer.writeByte('[');
        writeGoTokens(code[i + 1 .. generics_end], writer, false);
        writer.writeByte(']');
        i = generics_end + 1;
    }

    const params_start = skipHorizontalSpace(code, i);
    writer.writeSlice(code[i..params_start]);
    if (params_start >= code.len or code[params_start] != '(') {
        writer.closeSpan();
        return null;
    }
    const params_end = matchingDelimiter(code, params_start, '(', ')') orelse {
        writer.closeSpan();
        return null;
    };
    writer.openSpan("hljs-params");
    writer.writeByte('(');
    writeGoTokens(code[params_start + 1 .. params_end], writer, false);
    writer.writeByte(')');
    writer.closeSpan();
    writer.closeSpan();
    return params_end + 1;
}

fn writeGoTokens(code: []const u8, writer: *Writer, allow_function_declaration: bool) void {
    var i: usize = 0;
    while (i < code.len) {
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '/') {
            var end = i + 2;
            while (end < code.len and code[end] != '\n') : (end += 1) {}
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            var end = i + 2;
            while (end + 1 < code.len and !(code[end] == '*' and code[end + 1] == '/')) : (end += 1) {}
            end = if (end + 1 < code.len) end + 2 else code.len;
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            const end = stringEnd(code, i, quote);
            writer.writeSpan("hljs-string", code[i..end]);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(code[i]) or (code[i] == '.' and i + 1 < code.len and std.ascii.isDigit(code[i + 1]))) {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (isIdentStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const identifier = code[i..end];
            if (allow_function_declaration and std.mem.eql(u8, identifier, "func")) {
                if (writeFunctionDeclaration(code, i, end, writer)) |function_end| {
                    i = function_end;
                    continue;
                }
            }
            if (KeywordSet.get(identifier) != null) {
                writer.writeSpan("hljs-keyword", identifier);
            } else if (TypeSet.get(identifier) != null) {
                writer.writeSpan("hljs-type", identifier);
            } else if (LiteralSet.get(identifier) != null) {
                writer.writeSpan("hljs-literal", identifier);
            } else if (BuiltinSet.get(identifier) != null) {
                writer.writeSpan("hljs-built_in", identifier);
            } else {
                writer.writeSlice(identifier);
            }
            i = end;
            continue;
        }
        writer.writeByte(code[i]);
        i += 1;
    }
}

fn writeGo(code: []const u8, writer: *Writer) void {
    writeGoTokens(code, writer, true);
}

fn transform(input: []const u8, writer: *Writer) void {
    var copied: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        const open = parseOpenTag(input, i) orelse {
            i += 1;
            continue;
        };
        writer.writeSlice(input[copied..i]);
        const close = closeTag(input, open.end + 1) orelse {
            writer.writeSlice(input[i..]);
            return;
        };
        const code = input[open.end + 1 .. close.start];
        if (!open.is_go or open.has_hljs or containsSpanTag(code)) {
            writer.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenTag(input[i .. open.end + 1], writer);
            writeGo(code, writer);
            writer.writeSlice(input[close.start .. close.end + 1]);
        }
        copied = close.end + 1;
        i = copied;
    }
    writer.writeSlice(input[copied..]);
}

fn renderImpl(input_size: u32) u32 {
    const len: usize = @intCast(input_size);
    if (len > INPUT_CAP) @trap();
    var writer = Writer{};
    transform(input_buf[0..len], &writer);
    if (writer.overflow) @trap();
    return @intCast(writer.idx);
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
    @memcpy(input_buf[0..input.len], input);
    return output_buf[0..renderImpl(@intCast(input.len))];
}

test "highlights Go declarations types builtins and literals" {
    const input = "<code class=\"language-go\">package main\nfunc Map[T any](in []byte) error { if in == nil { return nil }; return make(error) }</code>";
    const expected = "<code class=\"language-go hljs\"><span class=\"hljs-keyword\">package</span> main\n<span class=\"hljs-function\"><span class=\"hljs-keyword\">func</span> <span class=\"hljs-title\">Map</span>[T <span class=\"hljs-type\">any</span>]<span class=\"hljs-params\">(in []<span class=\"hljs-type\">byte</span>)</span></span> <span class=\"hljs-type\">error</span> { <span class=\"hljs-keyword\">if</span> in == <span class=\"hljs-literal\">nil</span> { <span class=\"hljs-keyword\">return</span> <span class=\"hljs-literal\">nil</span> }; <span class=\"hljs-keyword\">return</span> <span class=\"hljs-built_in\">make</span>(<span class=\"hljs-type\">error</span>) }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights comments strings runes raw strings and numbers" {
    const input = "<code class=\"language-golang\">// return\nvar values = []any{&quot;x&quot;, &#39;λ&#39;, `raw\ntext`, 0x_FF, 1.2e3i}</code>";
    const expected = "<code class=\"language-golang hljs\"><span class=\"hljs-comment\">// return</span>\n<span class=\"hljs-keyword\">var</span> values = []<span class=\"hljs-type\">any</span>{<span class=\"hljs-string\">&quot;x&quot;</span>, <span class=\"hljs-string\">&#39;λ&#39;</span>, <span class=\"hljs-string\">`raw\ntext`</span>, <span class=\"hljs-number\">0x_FF</span>, <span class=\"hljs-number\">1.2e3i</span>}</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted blocks and other languages" {
    const highlighted = "<code class=\"language-go\"><span class=\"hljs-keyword\">package</span> main</code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const ruby = "<code class=\"language-ruby\">def go; end</code>";
    try std.testing.expectEqualStrings(ruby, runForTest(ruby));
}
