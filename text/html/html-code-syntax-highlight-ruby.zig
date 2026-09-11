const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "BEGIN", {} },    .{ "END", {} },     .{ "alias", {} },
    .{ "and", {} },      .{ "begin", {} },   .{ "break", {} },
    .{ "case", {} },     .{ "class", {} },   .{ "def", {} },
    .{ "defined?", {} }, .{ "do", {} },      .{ "else", {} },
    .{ "elsif", {} },    .{ "end", {} },     .{ "ensure", {} },
    .{ "extend", {} },   .{ "for", {} },     .{ "if", {} },
    .{ "in", {} },       .{ "include", {} }, .{ "module", {} },
    .{ "next", {} },     .{ "not", {} },     .{ "or", {} },
    .{ "prepend", {} },  .{ "private", {} }, .{ "protected", {} },
    .{ "public", {} },   .{ "raise", {} },   .{ "redo", {} },
    .{ "require", {} },  .{ "rescue", {} },  .{ "retry", {} },
    .{ "return", {} },   .{ "then", {} },    .{ "throw", {} },
    .{ "undef", {} },    .{ "unless", {} },  .{ "until", {} },
    .{ "when", {} },     .{ "while", {} },   .{ "yield", {} },
});

const ConstantVariableSet = std.StaticStringMap(void).initComptime(.{
    .{ "__ENCODING__", {} },
    .{ "__FILE__", {} },
    .{ "__LINE__", {} },
});

const LanguageVariableSet = std.StaticStringMap(void).initComptime(.{
    .{ "self", {} },
    .{ "super", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "nil", {} },
    .{ "true", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "attr_accessor", {} },    .{ "attr_reader", {} }, .{ "attr_writer", {} },
    .{ "define_method", {} },    .{ "lambda", {} },      .{ "module_function", {} },
    .{ "private_constant", {} }, .{ "proc", {} },
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

    fn openSpan(self: *Writer, class_name: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
    }

    fn closeSpan(self: *Writer) void {
        self.writeSlice("</span>");
    }

    fn writeSpan(self: *Writer, class_name: []const u8, text: []const u8) void {
        self.openSpan(class_name);
        self.writeSlice(text);
        self.closeSpan();
    }
};

const CodeTag = struct {
    end: usize,
    is_ruby: bool,
    has_hljs: bool,
};

const CloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_ruby: bool = false,
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
    for (a, b) |left, right| if (lower(left) != lower(right)) return false;
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
        if (eqlIgnoreCase(token, "language-ruby") or eqlIgnoreCase(token, "language-rb")) result.is_ruby = true;
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
        } else if (input[i] == '>') return i;
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
    const range = classRange(tag) orelse return .{ .end = end, .is_ruby = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_ruby = info.is_ruby, .has_hljs = info.has_hljs };
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
    if (code[start] == '"' or code[start] == '\'' or code[start] == '`') return .{ .byte = code[start], .len = 1 };
    if (start + 6 <= code.len and std.mem.eql(u8, code[start .. start + 6], "&quot;")) return .{ .byte = '"', .len = 6 };
    if (start + 5 <= code.len and std.mem.eql(u8, code[start .. start + 5], "&#39;")) return .{ .byte = '\'', .len = 5 };
    return null;
}

fn findQuoteEnd(code: []const u8, start: usize, quote: Quote) usize {
    var i = start + quote.len;
    while (i < code.len) {
        if (code[i] == '\\') {
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

fn interpolationEnd(code: []const u8, open: usize) usize {
    var i = open + 2;
    var depth: usize = 1;
    while (i < code.len) {
        if (code[i] == '#') {
            while (i < code.len and code[i] != '\n') : (i += 1) {}
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            i = findQuoteEnd(code, i, quote);
            continue;
        }
        if (code[i] == '{') depth += 1;
        if (code[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return code.len;
}

fn writeInterpolated(code: []const u8, start: usize, end: usize, class_name: []const u8, writer: *Writer) void {
    writer.openSpan(class_name);
    var segment = start;
    var i = start;
    while (i + 1 < end) {
        if (code[i] == '\\') {
            i += @min(@as(usize, 2), end - i);
            continue;
        }
        if (code[i] != '#' or code[i + 1] != '{') {
            i += 1;
            continue;
        }
        const close = interpolationEnd(code[0..end], i);
        if (close >= end) break;
        writer.writeSlice(code[segment..i]);
        writer.openSpan("hljs-subst");
        writer.writeSlice("#{");
        writeRuby(code[i + 2 .. close], writer);
        writer.writeByte('}');
        writer.closeSpan();
        i = close + 1;
        segment = i;
    }
    writer.writeSlice(code[segment..end]);
    writer.closeSpan();
}

fn delimiterClose(open: u8) u8 {
    return switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        else => open,
    };
}

fn percentEnd(code: []const u8, delimiter_at: usize) usize {
    const open = code[delimiter_at];
    const close = delimiterClose(open);
    const paired = open != close;
    var depth: usize = 1;
    var i = delimiter_at + 1;
    while (i < code.len) {
        if (code[i] == '\\') {
            i += @min(@as(usize, 2), code.len - i);
            continue;
        }
        if (paired and code[i] == open) depth += 1;
        if (code[i] == close) {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                while (i < code.len and std.ascii.isAlphabetic(code[i])) : (i += 1) {}
                return i;
            }
        }
        i += 1;
    }
    return code.len;
}

fn percentLiteral(code: []const u8, start: usize) ?struct { end: usize, interpolates: bool, class_name: []const u8 } {
    if (code[start] != '%' or start + 1 >= code.len) return null;
    var delimiter_at = start + 1;
    var kind: u8 = 'Q';
    if (std.ascii.isAlphabetic(code[delimiter_at])) {
        kind = code[delimiter_at];
        delimiter_at += 1;
    }
    if (delimiter_at >= code.len or std.ascii.isAlphanumeric(code[delimiter_at]) or isSpace(code[delimiter_at])) return null;
    const class_name: []const u8 = if (kind == 'r') "hljs-regexp" else if (kind == 's' or kind == 'i' or kind == 'I') "hljs-symbol" else "hljs-string";
    const interpolates = kind == 'Q' or kind == 'W' or kind == 'I' or kind == 'r' or kind == 'x';
    return .{ .end = percentEnd(code, delimiter_at), .interpolates = interpolates, .class_name = class_name };
}

fn heredocEnd(code: []const u8, start: usize) ?struct { end: usize, interpolates: bool } {
    const marker_len: usize = if (std.mem.startsWith(u8, code[start..], "&lt;&lt;")) 8 else if (std.mem.startsWith(u8, code[start..], "<<")) 2 else return null;
    var i = start + marker_len;
    var indented = false;
    if (i < code.len and (code[i] == '-' or code[i] == '~')) {
        indented = true;
        i += 1;
    }
    var interpolates = true;
    var terminator: []const u8 = undefined;
    if (quoteAt(code, i)) |quote| {
        interpolates = quote.byte != '\'';
        const value_start = i + quote.len;
        const value_end = findQuoteEnd(code, i, quote);
        if (value_end <= value_start or value_end > code.len) return null;
        terminator = code[value_start .. value_end - quote.len];
        i = value_end;
    } else {
        const value_start = i;
        while (i < code.len and isIdentContinue(code[i])) : (i += 1) {}
        if (i == value_start) return null;
        terminator = code[value_start..i];
    }
    const first_newline = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse return .{ .end = code.len, .interpolates = interpolates };
    var line_start = first_newline + 1;
    while (line_start <= code.len) {
        const line_end = std.mem.indexOfScalarPos(u8, code, line_start, '\n') orelse code.len;
        var candidate = line_start;
        if (indented) {
            while (candidate < line_end and (code[candidate] == ' ' or code[candidate] == '\t')) : (candidate += 1) {}
        }
        if (std.mem.eql(u8, code[candidate..line_end], terminator)) return .{ .end = line_end, .interpolates = interpolates };
        if (line_end == code.len) break;
        line_start = line_end + 1;
    }
    return .{ .end = code.len, .interpolates = interpolates };
}

fn regexAllowed(code: []const u8, start: usize) bool {
    var i = start;
    while (i > 0) {
        i -= 1;
        if (isSpace(code[i])) continue;
        return std.mem.indexOfScalar(u8, "=([{,:;!?", code[i]) != null;
    }
    return true;
}

fn regexEnd(code: []const u8, start: usize) usize {
    var i = start + 1;
    var in_class = false;
    while (i < code.len) {
        if (code[i] == '\\') {
            i += @min(@as(usize, 2), code.len - i);
            continue;
        }
        if (code[i] == '[') in_class = true;
        if (code[i] == ']') in_class = false;
        if (code[i] == '/' and !in_class) {
            i += 1;
            while (i < code.len and std.ascii.isAlphabetic(code[i])) : (i += 1) {}
            return i;
        }
        i += 1;
    }
    return code.len;
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len and (isIdentContinue(code[i]) or code[i] == '.' or code[i] == '_')) : (i += 1) {}
    return i;
}

fn isUpperConstant(identifier: []const u8) bool {
    if (identifier.len == 0 or !std.ascii.isUpper(identifier[0])) return false;
    for (identifier) |byte| {
        if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte) and byte != '_') return false;
    }
    return true;
}

fn parameterEnd(code: []const u8, start: usize) usize {
    var i = start + 1;
    var depth: usize = 1;
    while (i < code.len) {
        if (code[i] == '#') {
            while (i < code.len and code[i] != '\n') : (i += 1) {}
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            i = findQuoteEnd(code, i, quote);
            continue;
        }
        if (code[i] == '(') depth += 1;
        if (code[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return code.len;
}

fn writeRuby(code: []const u8, writer: *Writer) void {
    var i: usize = 0;
    var line_start = true;
    var expect_class_name = false;
    var expect_method_name = false;
    var after_method_name = false;
    while (i < code.len) {
        if (code[i] == '\n') {
            writer.writeByte('\n');
            i += 1;
            line_start = true;
            expect_class_name = false;
            expect_method_name = false;
            after_method_name = false;
            continue;
        }
        if (line_start and (code[i] == ' ' or code[i] == '\t')) {
            writer.writeByte(code[i]);
            i += 1;
            continue;
        }
        if (line_start and std.mem.startsWith(u8, code[i..], "=begin") and (i + 6 == code.len or isSpace(code[i + 6]))) {
            const end_marker = std.mem.indexOfPos(u8, code, i + 6, "\n=end") orelse code.len;
            const end = if (end_marker == code.len) code.len else (std.mem.indexOfScalarPos(u8, code, end_marker + 1, '\n') orelse code.len);
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            line_start = false;
            continue;
        }
        if (line_start and std.mem.startsWith(u8, code[i..], "__END__")) {
            writer.writeSpan("hljs-comment", code[i..]);
            return;
        }
        line_start = false;

        if (after_method_name and code[i] == '(') {
            const end = parameterEnd(code, i);
            writer.writeByte('(');
            writer.openSpan("hljs-params");
            writeRuby(code[i + 1 .. end], writer);
            writer.closeSpan();
            if (end < code.len) writer.writeByte(')');
            i = @min(end + 1, code.len);
            after_method_name = false;
            continue;
        }

        if (code[i] == '#') {
            var end = i + 1;
            while (end < code.len and code[end] != '\n') : (end += 1) {}
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (heredocEnd(code, i)) |heredoc| {
            if (heredoc.interpolates) writeInterpolated(code, i, heredoc.end, "hljs-string", writer) else writer.writeSpan("hljs-string", code[i..heredoc.end]);
            i = heredoc.end;
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            const end = findQuoteEnd(code, i, quote);
            if (quote.byte == '"' or quote.byte == '`') writeInterpolated(code, i, end, "hljs-string", writer) else writer.writeSpan("hljs-string", code[i..end]);
            i = end;
            continue;
        }
        if (percentLiteral(code, i)) |literal| {
            if (literal.interpolates) writeInterpolated(code, i, literal.end, literal.class_name, writer) else writer.writeSpan(literal.class_name, code[i..literal.end]);
            i = literal.end;
            continue;
        }
        if (code[i] == '/' and regexAllowed(code, i)) {
            const end = regexEnd(code, i);
            writeInterpolated(code, i, end, "hljs-regexp", writer);
            i = end;
            continue;
        }
        if (code[i] == '@' or code[i] == '$') {
            var end = i + 1;
            if (code[i] == '@' and end < code.len and code[end] == '@') end += 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-variable", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == ':' and (i == 0 or code[i - 1] != ':') and i + 1 < code.len and code[i + 1] != ':' and isIdentStart(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            if (end < code.len and (code[end] == '?' or code[end] == '!' or code[end] == '=')) end += 1;
            writer.writeSpan("hljs-symbol", code[i..end]);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(code[i])) {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (isIdentStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            if (end < code.len and (code[end] == '?' or code[end] == '!')) end += 1;
            const identifier = code[i..end];
            if (end < code.len and code[end] == ':' and (end + 1 == code.len or code[end + 1] != ':')) {
                writer.writeSpan("hljs-symbol", code[i .. end + 1]);
                i = end + 1;
            } else if (expect_method_name) {
                writer.writeSpan("hljs-title function_", identifier);
                expect_method_name = false;
                after_method_name = true;
                i = end;
            } else if (expect_class_name) {
                writer.writeSpan("hljs-title class_", identifier);
                expect_class_name = false;
                i = end;
            } else if (KeywordSet.get(identifier) != null) {
                writer.writeSpan("hljs-keyword", identifier);
                if (std.mem.eql(u8, identifier, "class") or
                    std.mem.eql(u8, identifier, "module") or
                    std.mem.eql(u8, identifier, "include") or
                    std.mem.eql(u8, identifier, "extend") or
                    std.mem.eql(u8, identifier, "prepend"))
                {
                    expect_class_name = true;
                }
                if (std.mem.eql(u8, identifier, "def")) expect_method_name = true;
                i = end;
            } else if (ConstantVariableSet.get(identifier) != null or isUpperConstant(identifier)) {
                writer.writeSpan("hljs-variable constant_", identifier);
                i = end;
            } else if (LanguageVariableSet.get(identifier) != null) {
                writer.writeSpan("hljs-variable language_", identifier);
                i = end;
            } else if (LiteralSet.get(identifier) != null) {
                writer.writeSpan("hljs-literal", identifier);
                i = end;
            } else if (BuiltinSet.get(identifier) != null) {
                writer.writeSpan("hljs-built_in", identifier);
                i = end;
            } else if (std.ascii.isUpper(identifier[0])) {
                writer.writeSpan("hljs-title class_", identifier);
                i = end;
            } else {
                writer.writeSlice(identifier);
                i = end;
            }
            continue;
        }
        writer.writeByte(code[i]);
        i += 1;
    }
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
        if (!open.is_ruby or open.has_hljs) {
            writer.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenTag(input[i .. open.end + 1], writer);
            writeRuby(input[open.end + 1 .. close.start], writer);
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

test "highlights Ruby declarations variables symbols and interpolation" {
    const input = "<code class=\"language-ruby\">class App; def call(name:); puts \"#{@name}: #{name}\"; end; end</code>";
    const expected = "<code class=\"language-ruby hljs\"><span class=\"hljs-keyword\">class</span> <span class=\"hljs-title class_\">App</span>; <span class=\"hljs-keyword\">def</span> <span class=\"hljs-title function_\">call</span>(<span class=\"hljs-params\"><span class=\"hljs-symbol\">name:</span></span>); puts <span class=\"hljs-string\">\"<span class=\"hljs-subst\">#{<span class=\"hljs-variable\">@name</span>}</span>: <span class=\"hljs-subst\">#{name}</span>\"</span>; <span class=\"hljs-keyword\">end</span>; <span class=\"hljs-keyword\">end</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights Ruby percent literals regexps and heredocs" {
    const input = "<code class=\"language-rb\">items = %W[one #{2}]\npattern = /x+/i\ntext = &lt;&lt;~TXT\n#{items}\nTXT</code>";
    const expected = "<code class=\"language-rb hljs\">items = <span class=\"hljs-string\">%W[one <span class=\"hljs-subst\">#{<span class=\"hljs-number\">2</span>}</span>]</span>\npattern = <span class=\"hljs-regexp\">/x+/i</span>\ntext = <span class=\"hljs-string\">&lt;&lt;~TXT\n<span class=\"hljs-subst\">#{items}</span>\nTXT</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "distinguishes namespaces from symbols" {
    const input = "<code class=\"language-ruby\">rescue JSON::ParserError\nvalue = :ready</code>";
    const expected = "<code class=\"language-ruby hljs\"><span class=\"hljs-keyword\">rescue</span> <span class=\"hljs-variable constant_\">JSON</span>::<span class=\"hljs-title class_\">ParserError</span>\nvalue = <span class=\"hljs-symbol\">:ready</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted and non-Ruby blocks" {
    const highlighted = "<code class=\"language-ruby hljs\"><span class=\"hljs-keyword\">def</span></code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const python = "<code class=\"language-python\">def ready(): pass</code>";
    try std.testing.expectEqualStrings(python, runForTest(python));
}
