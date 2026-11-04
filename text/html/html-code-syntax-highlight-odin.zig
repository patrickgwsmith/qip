const std = @import("std");

// Highlights `<code class="language-odin">` blocks with Highlight.js class
// names. Odin has no grammar in Highlight.js core, so classes follow the Go
// highlighter: `name :: proc` gets `hljs-title function_`, `name :: struct`
// (enum, union, bit_set, bit_field) gets `hljs-title class_`, procedure
// parameters are wrapped in `hljs-params`, and `#directive` and `@(attribute)`
// are `hljs-meta`. Block comments nest as they do in Odin.

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "asm", {} },         .{ "auto_cast", {} },   .{ "bit_field", {} },
    .{ "bit_set", {} },     .{ "break", {} },       .{ "case", {} },
    .{ "cast", {} },        .{ "context", {} },     .{ "continue", {} },
    .{ "defer", {} },       .{ "distinct", {} },    .{ "do", {} },
    .{ "dynamic", {} },     .{ "else", {} },        .{ "enum", {} },
    .{ "fallthrough", {} }, .{ "for", {} },         .{ "foreign", {} },
    .{ "if", {} },          .{ "import", {} },      .{ "in", {} },
    .{ "map", {} },         .{ "matrix", {} },      .{ "not_in", {} },
    .{ "or_break", {} },    .{ "or_continue", {} }, .{ "or_else", {} },
    .{ "or_return", {} },   .{ "package", {} },     .{ "proc", {} },
    .{ "return", {} },      .{ "struct", {} },      .{ "switch", {} },
    .{ "transmute", {} },   .{ "union", {} },       .{ "using", {} },
    .{ "when", {} },        .{ "where", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "any", {} },           .{ "b8", {} },           .{ "b16", {} },
    .{ "b32", {} },           .{ "b64", {} },          .{ "bool", {} },
    .{ "byte", {} },          .{ "complex32", {} },    .{ "complex64", {} },
    .{ "complex128", {} },    .{ "cstring", {} },      .{ "f16", {} },
    .{ "f16be", {} },         .{ "f16le", {} },        .{ "f32", {} },
    .{ "f32be", {} },         .{ "f32le", {} },        .{ "f64", {} },
    .{ "f64be", {} },         .{ "f64le", {} },        .{ "i8", {} },
    .{ "i16", {} },           .{ "i16be", {} },        .{ "i16le", {} },
    .{ "i32", {} },           .{ "i32be", {} },        .{ "i32le", {} },
    .{ "i64", {} },           .{ "i64be", {} },        .{ "i64le", {} },
    .{ "i128", {} },          .{ "i128be", {} },       .{ "i128le", {} },
    .{ "int", {} },           .{ "quaternion64", {} }, .{ "quaternion128", {} },
    .{ "quaternion256", {} }, .{ "rawptr", {} },       .{ "rune", {} },
    .{ "string", {} },        .{ "typeid", {} },       .{ "u8", {} },
    .{ "u16", {} },           .{ "u16be", {} },        .{ "u16le", {} },
    .{ "u32", {} },           .{ "u32be", {} },        .{ "u32le", {} },
    .{ "u64", {} },           .{ "u64be", {} },        .{ "u64le", {} },
    .{ "u128", {} },          .{ "u128be", {} },       .{ "u128le", {} },
    .{ "uint", {} },          .{ "uintptr", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "nil", {} },
    .{ "true", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "abs", {} },              .{ "align_of", {} },       .{ "append", {} },
    .{ "assert", {} },           .{ "cap", {} },            .{ "clamp", {} },
    .{ "clear", {} },            .{ "complex", {} },        .{ "conj", {} },
    .{ "copy", {} },             .{ "delete", {} },         .{ "expand_values", {} },
    .{ "free", {} },             .{ "imag", {} },           .{ "inject_at", {} },
    .{ "jmag", {} },             .{ "kmag", {} },           .{ "len", {} },
    .{ "make", {} },             .{ "max", {} },            .{ "min", {} },
    .{ "new", {} },              .{ "offset_of", {} },      .{ "panic", {} },
    .{ "quaternion", {} },       .{ "raw_data", {} },       .{ "real", {} },
    .{ "reserve", {} },          .{ "resize", {} },         .{ "size_of", {} },
    .{ "soa_unzip", {} },        .{ "soa_zip", {} },        .{ "swizzle", {} },
    .{ "type_info_of", {} },     .{ "type_of", {} },        .{ "typeid_of", {} },
    .{ "unordered_remove", {} }, .{ "ordered_remove", {} },
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
    is_odin: bool,
    has_hljs: bool,
};

const CloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_odin: bool = false,
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
        if (eqlIgnoreCase(token, "language-odin")) result.is_odin = true;
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
    const range = classRange(tag) orelse return .{ .end = end, .is_odin = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_odin = info.is_odin, .has_hljs = info.has_hljs };
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

// Returns the end of an HTML character reference such as `&lt;` or `&#x3C;`,
// so its letters are never read as identifiers or directives.
fn entityEnd(code: []const u8, start: usize) ?usize {
    if (start >= code.len or code[start] != '&') return null;
    var i = start + 1;
    if (i < code.len and code[i] == '#') i += 1;
    const name_start = i;
    while (i < code.len and i - start <= 32 and std.ascii.isAlphanumeric(code[i])) : (i += 1) {}
    if (i == name_start or i >= code.len or code[i] != ';') return null;
    return i + 1;
}

fn isNumberContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.';
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < code.len) {
        // `0..<10` and `0..=9` are ranges, not a number followed by a dot.
        if (code[i] == '.' and i + 1 < code.len and code[i + 1] == '.') break;
        if (isNumberContinue(code[i])) {
            i += 1;
            continue;
        }
        if ((code[i] == '+' or code[i] == '-') and i > start) {
            const previous = code[i - 1];
            const is_hex = start + 1 < code.len and code[start] == '0' and (code[start + 1] == 'x' or code[start + 1] == 'X' or code[start + 1] == 'h');
            if (!is_hex and (previous == 'e' or previous == 'E')) {
                i += 1;
                continue;
            }
        }
        break;
    }
    return i;
}

fn blockCommentEnd(code: []const u8, start: usize) usize {
    var depth: usize = 1;
    var i = start + 2;
    while (i + 1 < code.len) {
        if (code[i] == '/' and code[i + 1] == '*') {
            depth += 1;
            i += 2;
            continue;
        }
        if (code[i] == '*' and code[i + 1] == '/') {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return code.len;
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
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '/') {
            while (i < code.len and code[i] != '\n') : (i += 1) {}
            continue;
        }
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            i = blockCommentEnd(code, i);
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

fn identifierEnd(code: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
    return end;
}

// For `name :: proc`, `name :: #force_inline proc` and `name :: struct`,
// returns the title class to give `name`.
fn declarationTitle(code: []const u8, name_end: usize) ?[]const u8 {
    var i = skipHorizontalSpace(code, name_end);
    if (i + 2 > code.len or code[i] != ':' or code[i + 1] != ':') return null;
    i = skipHorizontalSpace(code, i + 2);
    while (i < code.len and code[i] == '#') {
        if (i + 1 >= code.len or !isIdentStart(code[i + 1])) return null;
        i = skipHorizontalSpace(code, identifierEnd(code, i + 1));
    }
    if (i >= code.len or !isIdentStart(code[i])) return null;
    const keyword = code[i..identifierEnd(code, i)];
    if (std.mem.eql(u8, keyword, "proc")) return "hljs-title function_";
    if (std.mem.eql(u8, keyword, "struct") or std.mem.eql(u8, keyword, "enum") or
        std.mem.eql(u8, keyword, "union") or std.mem.eql(u8, keyword, "bit_set") or
        std.mem.eql(u8, keyword, "bit_field")) return "hljs-title class_";
    return null;
}

// Writes `proc`, an optional calling convention string, and the parameter
// list wrapped in `hljs-params`. Returns null when no parameter list follows.
fn writeProc(code: []const u8, start: usize, keyword_end: usize, writer: *Writer) ?usize {
    var i = skipHorizontalSpace(code, keyword_end);
    var convention_end = i;
    if (quoteAt(code, i)) |quote| {
        convention_end = stringEnd(code, i, quote);
        i = skipHorizontalSpace(code, convention_end);
    }
    if (i >= code.len or code[i] != '(') return null;
    const params_end = matchingDelimiter(code, i, '(', ')') orelse return null;
    writer.writeSpan("hljs-keyword", code[start..keyword_end]);
    const convention_start = skipHorizontalSpace(code, keyword_end);
    writer.writeSlice(code[keyword_end..convention_start]);
    if (convention_end > convention_start) {
        writer.writeSpan("hljs-string", code[convention_start..convention_end]);
    }
    writer.writeSlice(code[convention_end..i]);
    writer.openSpan("hljs-params");
    writer.writeByte('(');
    writeOdinTokens(code[i + 1 .. params_end], writer);
    writer.writeByte(')');
    writer.closeSpan();
    return params_end + 1;
}

fn writeOdinTokens(code: []const u8, writer: *Writer) void {
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
            const end = blockCommentEnd(code, i);
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
        if (entityEnd(code, i)) |end| {
            writer.writeSlice(code[i..end]);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(code[i]) or (code[i] == '.' and i + 1 < code.len and std.ascii.isDigit(code[i + 1]) and (i == 0 or code[i - 1] != '.'))) {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '#' and i + 1 < code.len and isIdentStart(code[i + 1])) {
            const end = identifierEnd(code, i + 1);
            writer.writeSpan("hljs-meta", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '@' and i + 1 < code.len) {
            if (code[i + 1] == '(') {
                if (matchingDelimiter(code, i + 1, '(', ')')) |close| {
                    writer.writeSpan("hljs-meta", code[i .. close + 1]);
                    i = close + 1;
                    continue;
                }
            } else if (isIdentStart(code[i + 1])) {
                const end = identifierEnd(code, i + 1);
                writer.writeSpan("hljs-meta", code[i..end]);
                i = end;
                continue;
            }
        }
        if (code[i] == '$' and i + 1 < code.len and isIdentStart(code[i + 1])) {
            const end = identifierEnd(code, i + 1);
            writer.writeSpan("hljs-type", code[i..end]);
            i = end;
            continue;
        }
        if (isIdentStart(code[i])) {
            const end = identifierEnd(code, i);
            const identifier = code[i..end];
            if (std.mem.eql(u8, identifier, "proc")) {
                if (writeProc(code, i, end, writer)) |proc_end| {
                    i = proc_end;
                    continue;
                }
            }
            if (KeywordSet.get(identifier) != null) {
                writer.writeSpan("hljs-keyword", identifier);
            } else if (TypeSet.get(identifier) != null) {
                writer.writeSpan("hljs-type", identifier);
            } else if (LiteralSet.get(identifier) != null) {
                writer.writeSpan("hljs-literal", identifier);
            } else if (declarationTitle(code, end)) |title| {
                writer.writeSpan(title, identifier);
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

fn writeOdin(code: []const u8, writer: *Writer) void {
    writeOdinTokens(code, writer);
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
        if (!open.is_odin or open.has_hljs or containsSpanTag(code)) {
            writer.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenTag(input[i .. open.end + 1], writer);
            writeOdin(code, writer);
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

test "highlights Odin procedures types builtins and literals" {
    const input = "<code class=\"language-odin\">package main\nmain :: proc(args: []string) -&gt; bool { if len(args) == 0 { return false }; return true }</code>";
    const expected = "<code class=\"language-odin hljs\"><span class=\"hljs-keyword\">package</span> main\n<span class=\"hljs-title function_\">main</span> :: <span class=\"hljs-keyword\">proc</span><span class=\"hljs-params\">(args: []<span class=\"hljs-type\">string</span>)</span> -&gt; <span class=\"hljs-type\">bool</span> { <span class=\"hljs-keyword\">if</span> <span class=\"hljs-built_in\">len</span>(args) == <span class=\"hljs-number\">0</span> { <span class=\"hljs-keyword\">return</span> <span class=\"hljs-literal\">false</span> }; <span class=\"hljs-keyword\">return</span> <span class=\"hljs-literal\">true</span> }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights directives attributes polymorphic types and struct titles" {
    const input = "<code class=\"language-odin\">@(private)\nPair :: struct($T: typeid) { a, b: T }\nadd :: #force_inline proc \"contextless\" (x: $T) -&gt; T { #partial switch x { } return x }</code>";
    const expected = "<code class=\"language-odin hljs\"><span class=\"hljs-meta\">@(private)</span>\n<span class=\"hljs-title class_\">Pair</span> :: <span class=\"hljs-keyword\">struct</span>(<span class=\"hljs-type\">$T</span>: <span class=\"hljs-type\">typeid</span>) { a, b: T }\n<span class=\"hljs-title function_\">add</span> :: <span class=\"hljs-meta\">#force_inline</span> <span class=\"hljs-keyword\">proc</span> <span class=\"hljs-string\">\"contextless\"</span> <span class=\"hljs-params\">(x: <span class=\"hljs-type\">$T</span>)</span> -&gt; T { <span class=\"hljs-meta\">#partial</span> <span class=\"hljs-keyword\">switch</span> x { } <span class=\"hljs-keyword\">return</span> x }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights nested comments strings runes raw strings numbers and ranges" {
    const input = "<code class=\"language-odin\">/* outer /* proc */ return */\n// for\ns := []any{&quot;x&quot;, &#39;λ&#39;, `raw\ntext`, 0x_FF, 1.5e-3, 2i}\nfor i in 0..&lt;10 {}</code>";
    const expected = "<code class=\"language-odin hljs\"><span class=\"hljs-comment\">/* outer /* proc */ return */</span>\n<span class=\"hljs-comment\">// for</span>\ns := []<span class=\"hljs-type\">any</span>{<span class=\"hljs-string\">&quot;x&quot;</span>, <span class=\"hljs-string\">&#39;λ&#39;</span>, <span class=\"hljs-string\">`raw\ntext`</span>, <span class=\"hljs-number\">0x_FF</span>, <span class=\"hljs-number\">1.5e-3</span>, <span class=\"hljs-number\">2i</span>}\n<span class=\"hljs-keyword\">for</span> i <span class=\"hljs-keyword\">in</span> <span class=\"hljs-number\">0</span>..&lt;<span class=\"hljs-number\">10</span> {}</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "leaves HTML character references alone" {
    const input = "<code class=\"language-odin\">x := &amp;y; z := &#x3C;</code>";
    const expected = "<code class=\"language-odin hljs\">x := &amp;y; z := &#x3C;</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted blocks and other languages" {
    const highlighted = "<code class=\"language-odin\"><span class=\"hljs-keyword\">package</span> main</code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const go = "<code class=\"language-go\">func proc() {}</code>";
    try std.testing.expectEqualStrings(go, runForTest(go));
}
