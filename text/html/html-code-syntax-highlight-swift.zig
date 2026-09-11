const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "actor", {} },
    .{ "any", {} },
    .{ "as", {} },
    .{ "associatedtype", {} },
    .{ "async", {} },
    .{ "attached", {} },
    .{ "autoclosure", {} },
    .{ "await", {} },
    .{ "borrow", {} },
    .{ "borrowing", {} },
    .{ "break", {} },
    .{ "case", {} },
    .{ "catch", {} },
    .{ "class", {} },
    .{ "consume", {} },
    .{ "consuming", {} },
    .{ "continue", {} },
    .{ "convenience", {} },
    .{ "copy", {} },
    .{ "default", {} },
    .{ "defer", {} },
    .{ "deinit", {} },
    .{ "didSet", {} },
    .{ "discard", {} },
    .{ "distributed", {} },
    .{ "do", {} },
    .{ "dynamic", {} },
    .{ "each", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "escaping", {} },
    .{ "extension", {} },
    .{ "fallthrough", {} },
    .{ "fileprivate", {} },
    .{ "final", {} },
    .{ "for", {} },
    .{ "forward", {} },
    .{ "func", {} },
    .{ "freestanding", {} },
    .{ "get", {} },
    .{ "guard", {} },
    .{ "if", {} },
    .{ "import", {} },
    .{ "indirect", {} },
    .{ "in", {} },
    .{ "infix", {} },
    .{ "init", {} },
    .{ "inout", {} },
    .{ "internal", {} },
    .{ "is", {} },
    .{ "isolated", {} },
    .{ "lazy", {} },
    .{ "let", {} },
    .{ "macro", {} },
    .{ "mutating", {} },
    .{ "nonisolated", {} },
    .{ "nonmutating", {} },
    .{ "nonsending", {} },
    .{ "open", {} },
    .{ "operator", {} },
    .{ "optional", {} },
    .{ "override", {} },
    .{ "package", {} },
    .{ "postfix", {} },
    .{ "precedencegroup", {} },
    .{ "preconcurrency", {} },
    .{ "prefix", {} },
    .{ "private", {} },
    .{ "protocol", {} },
    .{ "public", {} },
    .{ "repeat", {} },
    .{ "required", {} },
    .{ "reasync", {} },
    .{ "rethrows", {} },
    .{ "retroactive", {} },
    .{ "return", {} },
    .{ "safe", {} },
    .{ "self", {} },
    .{ "sending", {} },
    .{ "set", {} },
    .{ "some", {} },
    .{ "static", {} },
    .{ "struct", {} },
    .{ "subscript", {} },
    .{ "super", {} },
    .{ "switch", {} },
    .{ "throw", {} },
    .{ "throws", {} },
    .{ "try", {} },
    .{ "typealias", {} },
    .{ "unowned", {} },
    .{ "unsafe", {} },
    .{ "var", {} },
    .{ "weak", {} },
    .{ "where", {} },
    .{ "while", {} },
    .{ "willSet", {} },
    .{ "yield", {} },
    .{ "yielding", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "Any", {} },
    .{ "AnyObject", {} },
    .{ "Array", {} },
    .{ "Bool", {} },
    .{ "Bundle", {} },
    .{ "Character", {} },
    .{ "Data", {} },
    .{ "Double", {} },
    .{ "Engine", {} },
    .{ "Error", {} },
    .{ "Float", {} },
    .{ "Function", {} },
    .{ "Int", {} },
    .{ "Int8", {} },
    .{ "Int16", {} },
    .{ "Int32", {} },
    .{ "Int64", {} },
    .{ "Memory", {} },
    .{ "Never", {} },
    .{ "Optional", {} },
    .{ "Protocol", {} },
    .{ "Result", {} },
    .{ "Self", {} },
    .{ "Sendable", {} },
    .{ "Set", {} },
    .{ "Store", {} },
    .{ "String", {} },
    .{ "Substring", {} },
    .{ "UInt", {} },
    .{ "UInt8", {} },
    .{ "UInt16", {} },
    .{ "UInt32", {} },
    .{ "UInt64", {} },
    .{ "URL", {} },
    .{ "UTF8", {} },
    .{ "Value", {} },
    .{ "Void", {} },
    .{ "Type", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "nil", {} },
    .{ "true", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "assert", {} },
    .{ "fatalError", {} },
    .{ "max", {} },
    .{ "min", {} },
    .{ "precondition", {} },
    .{ "print", {} },
    .{ "readLine", {} },
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

const CodeOpenTag = struct {
    end: usize,
    is_swift: bool,
    has_hljs: bool,
};

const CodeCloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_swift: bool = false,
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

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isTagNameBoundary(byte: u8) bool {
    return byte == '>' or byte == '/' or isSpace(byte);
}

fn isAttrNameChar(byte: u8) bool {
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
    var cursor: usize = 0;
    while (cursor < value.len) {
        while (cursor < value.len and isSpace(value[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < value.len and !isSpace(value[cursor])) : (cursor += 1) {}
        if (start == cursor) continue;
        const token = value[start..cursor];
        if (eqlIgnoreCase(token, "language-swift")) result.is_swift = true;
        if (eqlIgnoreCase(token, "hljs")) result.has_hljs = true;
    }
    return result;
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var cursor = start;
    var quote: u8 = 0;
    while (cursor < input.len) : (cursor += 1) {
        const byte = input[cursor];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == '>') {
            return cursor;
        }
    }
    return null;
}

fn classValueRange(tag: []const u8) ?struct { start: usize, end: usize } {
    if (tag.len < 6) return null;
    var cursor: usize = 5;
    while (cursor < tag.len) {
        while (cursor < tag.len and isSpace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] == '>') break;
        if (tag[cursor] == '/') {
            cursor += 1;
            continue;
        }

        const name_start = cursor;
        while (cursor < tag.len and isAttrNameChar(tag[cursor])) : (cursor += 1) {}
        if (name_start == cursor) {
            cursor += 1;
            continue;
        }
        const name = tag[name_start..cursor];
        while (cursor < tag.len and isSpace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.len and isSpace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len) break;

        var value_start = cursor;
        var value_end = cursor;
        if (tag[cursor] == '"' or tag[cursor] == '\'') {
            const quote = tag[cursor];
            cursor += 1;
            value_start = cursor;
            while (cursor < tag.len and tag[cursor] != quote) : (cursor += 1) {}
            value_end = cursor;
            if (cursor < tag.len) cursor += 1;
        } else {
            value_start = cursor;
            while (cursor < tag.len and !isSpace(tag[cursor]) and tag[cursor] != '>' and tag[cursor] != '/') : (cursor += 1) {}
            value_end = cursor;
        }
        if (eqlIgnoreCase(name, "class")) return .{ .start = value_start, .end = value_end };
    }
    return null;
}

fn parseCodeOpenTag(input: []const u8, start: usize) ?CodeOpenTag {
    if (start + 5 > input.len or input[start] != '<') return null;
    if (!eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isTagNameBoundary(input[start + 5])) return null;
    const end = findTagEnd(input, start + 5) orelse return null;
    const tag = input[start .. end + 1];
    const range = classValueRange(tag) orelse return .{ .end = end, .is_swift = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_swift = info.is_swift, .has_hljs = info.has_hljs };
}

fn findCodeCloseTag(input: []const u8, start: usize) ?CodeCloseTag {
    var cursor = start;
    while (cursor + 7 <= input.len) : (cursor += 1) {
        if (input[cursor] != '<' or input[cursor + 1] != '/') continue;
        if (!eqlIgnoreCase(input[cursor + 2 .. cursor + 6], "code")) continue;
        var end = cursor + 6;
        if (end < input.len and !isTagNameBoundary(input[end])) continue;
        while (end < input.len and isSpace(input[end])) : (end += 1) {}
        if (end < input.len and input[end] == '>') return .{ .start = cursor, .end = end };
    }
    return null;
}

fn writeOpenTagWithHljs(tag: []const u8, writer: *Writer) void {
    const range = classValueRange(tag) orelse {
        writer.writeSlice(tag);
        return;
    };
    const info = classInfo(tag[range.start..range.end]);
    if (info.has_hljs) {
        writer.writeSlice(tag);
        return;
    }
    writer.writeSlice(tag[0..range.end]);
    if (range.start != range.end) writer.writeByte(' ');
    writer.writeSlice("hljs");
    writer.writeSlice(tag[range.end..]);
}

fn blockCommentEnd(code: []const u8, start: usize) usize {
    var cursor = start + 2;
    var depth: usize = 1;
    while (cursor < code.len) {
        if (cursor + 1 < code.len and code[cursor] == '/' and code[cursor + 1] == '*') {
            depth += 1;
            cursor += 2;
        } else if (cursor + 1 < code.len and code[cursor] == '*' and code[cursor + 1] == '/') {
            depth -= 1;
            cursor += 2;
            if (depth == 0) return cursor;
        } else {
            cursor += 1;
        }
    }
    return code.len;
}

const StringStart = struct {
    quote: usize,
    quote_len: usize,
    hashes: usize,
};

fn quoteLenAt(code: []const u8, start: usize) ?usize {
    if (start < code.len and code[start] == '"') return 1;
    if (start + 6 <= code.len and std.mem.eql(u8, code[start .. start + 6], "&quot;")) return 6;
    return null;
}

fn stringStart(code: []const u8, start: usize) ?StringStart {
    var cursor = start;
    while (cursor < code.len and code[cursor] == '#') : (cursor += 1) {}
    const quote_len = quoteLenAt(code, cursor) orelse return null;
    return .{ .quote = cursor, .quote_len = quote_len, .hashes = cursor - start };
}

fn hasHashes(code: []const u8, start: usize, count: usize) bool {
    if (start + count > code.len) return false;
    for (code[start .. start + count]) |byte| {
        if (byte != '#') return false;
    }
    return true;
}

fn hasQuotes(code: []const u8, start: usize, quote_len: usize, count: usize) bool {
    var cursor = start;
    for (0..count) |_| {
        if (quoteLenAt(code, cursor) != quote_len) return false;
        cursor += quote_len;
    }
    return true;
}

fn stringEnd(code: []const u8, quote_start: usize, quote_len: usize, hashes: usize) usize {
    const triple = hasQuotes(code, quote_start, quote_len, 3);
    const quote_bytes = quote_len * (if (triple) @as(usize, 3) else 1);
    var cursor = quote_start + quote_bytes;
    while (cursor < code.len) {
        if (hashes == 0 and code[cursor] == '\\') {
            cursor += @min(@as(usize, 2), code.len - cursor);
            continue;
        }
        if (hasQuotes(code, cursor, quote_len, if (triple) 3 else 1) and hasHashes(code, cursor + quote_bytes, hashes)) {
            return cursor + quote_bytes + hashes;
        }
        cursor += 1;
    }
    return code.len;
}

fn interpolationStart(code: []const u8, cursor: usize, hashes: usize) ?usize {
    if (cursor >= code.len or code[cursor] != '\\') return null;
    if (!hasHashes(code, cursor + 1, hashes)) return null;
    const paren = cursor + 1 + hashes;
    if (paren >= code.len or code[paren] != '(') return null;
    return paren;
}

fn interpolationEnd(code: []const u8, open_paren: usize) usize {
    var cursor = open_paren + 1;
    var depth: usize = 1;
    while (cursor < code.len) {
        if (cursor + 1 < code.len and code[cursor] == '/' and code[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < code.len and code[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        if (cursor + 1 < code.len and code[cursor] == '/' and code[cursor + 1] == '*') {
            cursor = blockCommentEnd(code, cursor);
            continue;
        }
        if (stringStart(code, cursor)) |nested| {
            cursor = stringEnd(code, nested.quote, nested.quote_len, nested.hashes);
            continue;
        }
        if (code[cursor] == '(') {
            depth += 1;
        } else if (code[cursor] == ')') {
            depth -= 1;
            if (depth == 0) return cursor;
        }
        cursor += 1;
    }
    return code.len;
}

fn numberEnd(code: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < code.len) {
        const byte = code[cursor];
        if (isIdentContinue(byte) or byte == '.' or byte == '_') {
            cursor += 1;
        } else if ((byte == '+' or byte == '-') and cursor > start and
            (code[cursor - 1] == 'e' or code[cursor - 1] == 'E' or code[cursor - 1] == 'p' or code[cursor - 1] == 'P'))
        {
            cursor += 1;
        } else {
            break;
        }
    }
    return cursor;
}

fn writeString(code: []const u8, start: usize, string: StringStart, writer: *Writer) usize {
    const triple = hasQuotes(code, string.quote, string.quote_len, 3);
    const quote_bytes = string.quote_len * (if (triple) @as(usize, 3) else 1);
    const end = stringEnd(code, string.quote, string.quote_len, string.hashes);
    const content_start = string.quote + quote_bytes;
    const closing_len = quote_bytes + string.hashes;
    const has_closing = end >= closing_len and
        hasQuotes(code, end - closing_len, string.quote_len, if (triple) 3 else 1) and
        hasHashes(code, end - string.hashes, string.hashes);
    const content_end = if (has_closing) end - closing_len else end;

    writer.openSpan("hljs-string");
    writer.writeSlice(code[start..content_start]);
    var segment_start = content_start;
    var cursor = content_start;
    while (cursor < content_end) {
        const open_paren = interpolationStart(code, cursor, string.hashes) orelse {
            if (string.hashes == 0 and code[cursor] == '\\' and cursor + 1 < content_end) {
                cursor += 2;
            } else {
                cursor += 1;
            }
            continue;
        };
        const close_paren = interpolationEnd(code[0..content_end], open_paren);
        if (close_paren >= content_end) {
            cursor += 1;
            continue;
        }

        writer.writeSlice(code[segment_start..cursor]);
        writer.openSpan("hljs-subst");
        writer.writeSlice(code[cursor .. open_paren + 1]);
        writeHighlightedSwift(code[open_paren + 1 .. close_paren], writer);
        writer.writeByte(')');
        writer.closeSpan();
        cursor = close_paren + 1;
        segment_start = cursor;
    }
    writer.writeSlice(code[segment_start..end]);
    writer.closeSpan();
    return end;
}

fn swiftParameterEnd(code: []const u8, start: usize) usize {
    var cursor = start + 1;
    var depth: usize = 1;
    while (cursor < code.len) {
        if (stringStart(code, cursor)) |string| {
            cursor = stringEnd(code, string.quote, string.quote_len, string.hashes);
            continue;
        }
        if (cursor + 1 < code.len and code[cursor] == '/' and code[cursor + 1] == '*') {
            cursor = blockCommentEnd(code, cursor);
            continue;
        }
        if (code[cursor] == '(') depth += 1;
        if (code[cursor] == ')') {
            depth -= 1;
            if (depth == 0) return cursor;
        }
        cursor += 1;
    }
    return code.len;
}

fn isOperatorByte(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "=+-*/%<>!&|^~?", byte) != null;
}

fn writeHighlightedSwift(code: []const u8, writer: *Writer) void {
    writeHighlightedSwiftInternal(code, writer, false);
}

fn writeHighlightedSwiftInternal(code: []const u8, writer: *Writer, in_parameters: bool) void {
    var cursor: usize = 0;
    var at_line_start = true;
    var expect_type_title = false;
    var expect_function_title = false;
    var after_function_title = false;
    var after_type_title = false;
    var in_inheritance = false;
    while (cursor < code.len) {
        if (code[cursor] == '\n') {
            writer.writeByte('\n');
            cursor += 1;
            at_line_start = true;
            expect_type_title = false;
            expect_function_title = false;
            after_function_title = false;
            after_type_title = false;
            in_inheritance = false;
            continue;
        }
        if (at_line_start and (code[cursor] == ' ' or code[cursor] == '\t')) {
            writer.writeByte(code[cursor]);
            cursor += 1;
            continue;
        }
        if (at_line_start and code[cursor] == '#' and cursor + 1 < code.len and isIdentStart(code[cursor + 1])) {
            var end = cursor + 1;
            while (end < code.len and code[end] != '\n') : (end += 1) {}
            writer.writeSpan("hljs-meta", code[cursor..end]);
            cursor = end;
            at_line_start = false;
            continue;
        }
        at_line_start = false;

        if (after_function_title and code[cursor] == '(') {
            const end = swiftParameterEnd(code, cursor);
            writer.writeByte('(');
            writeHighlightedSwiftInternal(code[cursor + 1 .. end], writer, true);
            if (end < code.len) writer.writeByte(')');
            cursor = @min(end + 1, code.len);
            after_function_title = false;
            continue;
        }

        if (cursor + 1 < code.len and code[cursor] == '/' and code[cursor + 1] == '/') {
            var end = cursor + 2;
            while (end < code.len and code[end] != '\n') : (end += 1) {}
            writer.writeSpan("hljs-comment", code[cursor..end]);
            cursor = end;
            continue;
        }
        if (cursor + 1 < code.len and code[cursor] == '/' and code[cursor + 1] == '*') {
            const end = blockCommentEnd(code, cursor);
            writer.writeSpan("hljs-comment", code[cursor..end]);
            cursor = end;
            continue;
        }
        if (stringStart(code, cursor)) |string| {
            cursor = writeString(code, cursor, string, writer);
            continue;
        }
        if (code[cursor] == '@' and cursor + 1 < code.len and isIdentStart(code[cursor + 1])) {
            var end = cursor + 2;
            while (end < code.len and (isIdentContinue(code[end]) or code[end] == '.')) : (end += 1) {}
            writer.writeSpan("hljs-keyword", code[cursor..end]);
            cursor = end;
            continue;
        }
        if (std.mem.startsWith(u8, code[cursor..], "-&gt;")) {
            writer.writeSlice("-&gt;");
            cursor += 5;
            continue;
        }
        if (isOperatorByte(code[cursor])) {
            var end = cursor + 1;
            while (end < code.len and isOperatorByte(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-operator", code[cursor..end]);
            cursor = end;
            continue;
        }
        if (std.ascii.isDigit(code[cursor])) {
            const end = numberEnd(code, cursor);
            writer.writeSpan("hljs-number", code[cursor..end]);
            cursor = end;
            continue;
        }
        if (isIdentStart(code[cursor])) {
            var end = cursor + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const identifier = code[cursor..end];
            const is_member = cursor > 0 and code[cursor - 1] == '.';
            var next = end;
            while (next < code.len and (code[next] == ' ' or code[next] == '\t')) : (next += 1) {}
            if (expect_type_title) {
                writer.writeSpan("hljs-title class_", identifier);
                expect_type_title = false;
                after_type_title = true;
            } else if (expect_function_title) {
                writer.writeSpan("hljs-title function_", identifier);
                expect_function_title = false;
                after_function_title = true;
            } else if (in_inheritance and (std.ascii.isUpper(identifier[0]) or TypeSet.get(identifier) != null)) {
                writer.writeSpan("hljs-title class_ inherited__", identifier);
            } else if (in_parameters and std.mem.eql(u8, identifier, "_")) {
                writer.writeSpan("hljs-keyword", identifier);
            } else if (in_parameters and next < code.len and code[next] == ':') {
                writer.writeSpan("hljs-params", identifier);
            } else if (KeywordSet.get(identifier) != null and (!is_member or std.mem.eql(u8, identifier, "self"))) {
                writer.writeSpan("hljs-keyword", identifier);
                if (std.mem.eql(u8, identifier, "struct") or
                    std.mem.eql(u8, identifier, "protocol") or
                    std.mem.eql(u8, identifier, "class") or
                    std.mem.eql(u8, identifier, "extension") or
                    std.mem.eql(u8, identifier, "enum") or
                    std.mem.eql(u8, identifier, "actor"))
                {
                    expect_type_title = true;
                }
                if (std.mem.eql(u8, identifier, "func") or std.mem.eql(u8, identifier, "macro")) {
                    expect_function_title = true;
                }
            } else if (TypeSet.get(identifier) != null) {
                writer.writeSpan("hljs-type", identifier);
            } else if (LiteralSet.get(identifier) != null) {
                writer.writeSpan("hljs-literal", identifier);
            } else if (BuiltinSet.get(identifier) != null) {
                writer.writeSpan("hljs-built_in", identifier);
            } else {
                writer.writeSlice(identifier);
            }
            cursor = end;
            continue;
        }
        if (after_type_title and code[cursor] == ':') {
            in_inheritance = true;
            after_type_title = false;
        }
        if (code[cursor] == '{') {
            in_inheritance = false;
            after_type_title = false;
        }
        writer.writeByte(code[cursor]);
        cursor += 1;
    }
}

fn transformHTML(input: []const u8, writer: *Writer) void {
    var copied_until: usize = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        if (input[cursor] != '<') {
            cursor += 1;
            continue;
        }
        const open = parseCodeOpenTag(input, cursor) orelse {
            cursor += 1;
            continue;
        };
        writer.writeSlice(input[copied_until..cursor]);
        const close = findCodeCloseTag(input, open.end + 1) orelse {
            writer.writeSlice(input[cursor..]);
            return;
        };
        if (!open.is_swift or open.has_hljs) {
            writer.writeSlice(input[cursor .. close.end + 1]);
        } else {
            writeOpenTagWithHljs(input[cursor .. open.end + 1], writer);
            writeHighlightedSwift(input[open.end + 1 .. close.start], writer);
            writer.writeSlice(input[close.start .. close.end + 1]);
        }
        copied_until = close.end + 1;
        cursor = copied_until;
    }
    writer.writeSlice(input[copied_until..]);
}

fn renderImpl(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();
    var writer = Writer{};
    transformHTML(input_buf[0..input_len], &writer);
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

test "highlights Swift declarations strings and literals" {
    const input = "<pre><code class=\"language-swift\">final class App { let name: String = \"QIP\"; let ready = true }</code></pre>";
    const expected = "<pre><code class=\"language-swift hljs\"><span class=\"hljs-keyword\">final</span> <span class=\"hljs-keyword\">class</span> <span class=\"hljs-title class_\">App</span> { <span class=\"hljs-keyword\">let</span> name: <span class=\"hljs-type\">String</span> <span class=\"hljs-operator\">=</span> <span class=\"hljs-string\">\"QIP\"</span>; <span class=\"hljs-keyword\">let</span> ready <span class=\"hljs-operator\">=</span> <span class=\"hljs-literal\">true</span> }</code></pre>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights Swift attributes nested comments and numbers" {
    const input = "<code class=\"language-swift\">@main struct App { static func main() { print(42) } } /* a /* b */ c */</code>";
    const expected = "<code class=\"language-swift hljs\"><span class=\"hljs-keyword\">@main</span> <span class=\"hljs-keyword\">struct</span> <span class=\"hljs-title class_\">App</span> { <span class=\"hljs-keyword\">static</span> <span class=\"hljs-keyword\">func</span> <span class=\"hljs-title function_\">main</span>() { <span class=\"hljs-built_in\">print</span>(<span class=\"hljs-number\">42</span>) } } <span class=\"hljs-comment\">/* a /* b */ c */</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights interpolation inside multiline and extended strings" {
    const input = "<code class=\"language-swift\">let message = \"\"\"value: \\(count + 1)\"\"\"\nlet raw = #\"value: \\#(count)\"#</code>";
    const expected = "<code class=\"language-swift hljs\"><span class=\"hljs-keyword\">let</span> message <span class=\"hljs-operator\">=</span> <span class=\"hljs-string\">\"\"\"value: <span class=\"hljs-subst\">\\(count <span class=\"hljs-operator\">+</span> <span class=\"hljs-number\">1</span>)</span>\"\"\"</span>\n<span class=\"hljs-keyword\">let</span> raw <span class=\"hljs-operator\">=</span> <span class=\"hljs-string\">#\"value: <span class=\"hljs-subst\">\\#(count)</span>\"#</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights HTML-encoded strings and interpolation" {
    const input = "<code class=\"language-swift\">let message = &quot;value: \\(count)&quot;\nlet block = &quot;&quot;&quot;\\#(raw)&quot;&quot;&quot;</code>";
    const expected = "<code class=\"language-swift hljs\"><span class=\"hljs-keyword\">let</span> message <span class=\"hljs-operator\">=</span> <span class=\"hljs-string\">&quot;value: <span class=\"hljs-subst\">\\(count)</span>&quot;</span>\n<span class=\"hljs-keyword\">let</span> block <span class=\"hljs-operator\">=</span> <span class=\"hljs-string\">&quot;&quot;&quot;\\#(raw)&quot;&quot;&quot;</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted and non-Swift blocks" {
    const highlighted = "<code class=\"language-swift hljs\"><span class=\"hljs-keyword\">let</span></code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const java = "<code class=\"language-java\">class App {}</code>";
    try std.testing.expectEqualStrings(java, runForTest(java));
}
