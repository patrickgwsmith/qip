const std = @import("std");

// Ports Highlight.js 11's Rust grammar (lib/languages/rust.js) rule for
// rule, including its quirks, so output matches byte for byte. Rules are
// matched against the decoded source; output copies the original escaped
// HTML so entities pass through unchanged.

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
// Decoded code block, and each decoded byte's offset in the escaped HTML.
var raw_buf: [INPUT_CAP]u8 = undefined;
var offset_buf: [INPUT_CAP + 1]u32 = undefined;

// Stands in for entities other than the five the escaper produces.
const OPAQUE_ENTITY: u8 = 0x1a;

const Class = enum { keyword, literal, built_in, type };

// Highlight.js assigns type, keyword, literal, then built_in, so `true` and
// `false` end up as literals. Its `drop ` built-in has a trailing space and
// never matches.
const TopKeywords = std.StaticStringMap(Class).initComptime(.{
    .{ "i8", .type },                    .{ "i16", .type },                  .{ "i32", .type },
    .{ "i64", .type },                   .{ "i128", .type },                 .{ "isize", .type },
    .{ "u8", .type },                    .{ "u16", .type },                  .{ "u32", .type },
    .{ "u64", .type },                   .{ "u128", .type },                 .{ "usize", .type },
    .{ "f16", .type },                   .{ "f32", .type },                  .{ "f64", .type },
    .{ "f128", .type },                  .{ "str", .type },                  .{ "char", .type },
    .{ "bool", .type },                  .{ "Box", .type },                  .{ "Option", .type },
    .{ "Result", .type },                .{ "String", .type },               .{ "Vec", .type },
    .{ "abstract", .keyword },           .{ "as", .keyword },                .{ "async", .keyword },
    .{ "await", .keyword },              .{ "become", .keyword },            .{ "box", .keyword },
    .{ "break", .keyword },              .{ "const", .keyword },             .{ "continue", .keyword },
    .{ "crate", .keyword },              .{ "do", .keyword },                .{ "dyn", .keyword },
    .{ "else", .keyword },               .{ "enum", .keyword },              .{ "extern", .keyword },
    .{ "final", .keyword },              .{ "fn", .keyword },                .{ "for", .keyword },
    .{ "if", .keyword },                 .{ "impl", .keyword },              .{ "in", .keyword },
    .{ "let", .keyword },                .{ "loop", .keyword },              .{ "macro", .keyword },
    .{ "match", .keyword },              .{ "mod", .keyword },               .{ "move", .keyword },
    .{ "mut", .keyword },                .{ "override", .keyword },          .{ "priv", .keyword },
    .{ "pub", .keyword },                .{ "raw", .keyword },               .{ "ref", .keyword },
    .{ "return", .keyword },             .{ "self", .keyword },              .{ "Self", .keyword },
    .{ "static", .keyword },             .{ "struct", .keyword },            .{ "super", .keyword },
    .{ "trait", .keyword },              .{ "try", .keyword },               .{ "type", .keyword },
    .{ "typeof", .keyword },             .{ "union", .keyword },             .{ "unsafe", .keyword },
    .{ "unsized", .keyword },            .{ "use", .keyword },               .{ "virtual", .keyword },
    .{ "where", .keyword },              .{ "while", .keyword },             .{ "yield", .keyword },
    .{ "true", .literal },               .{ "false", .literal },             .{ "Some", .literal },
    .{ "None", .literal },               .{ "Ok", .literal },                .{ "Err", .literal },
    .{ "Copy", .built_in },              .{ "Send", .built_in },             .{ "Sized", .built_in },
    .{ "Sync", .built_in },              .{ "Drop", .built_in },             .{ "Fn", .built_in },
    .{ "FnMut", .built_in },             .{ "FnOnce", .built_in },           .{ "ToOwned", .built_in },
    .{ "Clone", .built_in },             .{ "Debug", .built_in },            .{ "PartialEq", .built_in },
    .{ "PartialOrd", .built_in },        .{ "Eq", .built_in },               .{ "Ord", .built_in },
    .{ "AsRef", .built_in },             .{ "AsMut", .built_in },            .{ "Into", .built_in },
    .{ "From", .built_in },              .{ "Default", .built_in },          .{ "Iterator", .built_in },
    .{ "Extend", .built_in },            .{ "IntoIterator", .built_in },     .{ "DoubleEndedIterator", .built_in },
    .{ "ExactSizeIterator", .built_in }, .{ "SliceConcatExt", .built_in },   .{ "ToString", .built_in },
    .{ "assert!", .built_in },           .{ "assert_eq!", .built_in },       .{ "bitflags!", .built_in },
    .{ "bytes!", .built_in },            .{ "cfg!", .built_in },             .{ "col!", .built_in },
    .{ "concat!", .built_in },           .{ "concat_idents!", .built_in },   .{ "debug_assert!", .built_in },
    .{ "debug_assert_eq!", .built_in },  .{ "env!", .built_in },             .{ "eprintln!", .built_in },
    .{ "panic!", .built_in },            .{ "file!", .built_in },            .{ "format!", .built_in },
    .{ "format_args!", .built_in },      .{ "include_bytes!", .built_in },   .{ "include_str!", .built_in },
    .{ "line!", .built_in },             .{ "local_data_key!", .built_in },  .{ "module_path!", .built_in },
    .{ "option_env!", .built_in },       .{ "print!", .built_in },           .{ "println!", .built_in },
    .{ "select!", .built_in },           .{ "stringify!", .built_in },       .{ "try!", .built_in },
    .{ "unimplemented!", .built_in },    .{ "unreachable!", .built_in },     .{ "vec!", .built_in },
    .{ "write!", .built_in },            .{ "writeln!", .built_in },         .{ "macro_rules!", .built_in },
    .{ "assert_ne!", .built_in },        .{ "debug_assert_ne!", .built_in },
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
};

const CodeTag = struct {
    end: usize,
    is_rust: bool,
    has_hljs: bool,
};

const CloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_rust: bool = false,
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

fn classInfo(value: []const u8) ClassInfo {
    var result = ClassInfo{};
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (start == i) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-rust") or eqlIgnoreCase(token, "language-rs")) result.is_rust = true;
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
    const range = classRange(tag) orelse return .{ .end = end, .is_rust = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_rust = info.is_rust, .has_hljs = info.has_hljs };
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

const entities = [_]struct { text: []const u8, byte: u8 }{
    .{ .text = "&amp;", .byte = '&' },
    .{ .text = "&lt;", .byte = '<' },
    .{ .text = "&gt;", .byte = '>' },
    .{ .text = "&quot;", .byte = '"' },
    .{ .text = "&#39;", .byte = '\'' },
    .{ .text = "&#34;", .byte = '"' },
    .{ .text = "&#x27;", .byte = '\'' },
    .{ .text = "&apos;", .byte = '\'' },
};

fn otherEntityLen(code: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < code.len and i - start <= 32) : (i += 1) {
        if (code[i] == ';') return if (i > start + 1) i + 1 - start else null;
        if (!std.ascii.isAlphanumeric(code[i]) and code[i] != '#') return null;
    }
    return null;
}

// Decodes `code` into raw_buf and returns the decoded length.
fn decode(code: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    outer: while (i < code.len) {
        offset_buf[n] = @intCast(i);
        if (code[i] == '&') {
            for (entities) |entity| {
                if (std.mem.startsWith(u8, code[i..], entity.text)) {
                    raw_buf[n] = entity.byte;
                    n += 1;
                    i += entity.text.len;
                    continue :outer;
                }
            }
            if (otherEntityLen(code, i)) |len| {
                raw_buf[n] = OPAQUE_ENTITY;
                n += 1;
                i += len;
                continue;
            }
        }
        raw_buf[n] = code[i];
        n += 1;
        i += 1;
    }
    offset_buf[n] = @intCast(code.len);
    return n;
}

const Highlighter = struct {
    code: []const u8,
    raw: []const u8,
    writer: *Writer,

    fn emit(self: *Highlighter, start: usize, end: usize) void {
        self.writer.writeSlice(self.code[offset_buf[start]..offset_buf[end]]);
    }

    fn emitSpan(self: *Highlighter, class_name: []const u8, start: usize, end: usize) void {
        if (start == end) return;
        self.writer.openSpan(class_name);
        self.emit(start, end);
        self.writer.closeSpan();
    }

    fn at(self: *const Highlighter, i: usize) u8 {
        return if (i < self.raw.len) self.raw[i] else 0;
    }

    fn startsWith(self: *const Highlighter, i: usize, text: []const u8) bool {
        return i <= self.raw.len and std.mem.startsWith(u8, self.raw[i..], text);
    }

    fn isWordAt(self: *const Highlighter, i: usize) bool {
        return i < self.raw.len and isWord(self.raw[i]);
    }

    // JavaScript `\b` before position i.
    fn boundaryAt(self: *const Highlighter, i: usize) bool {
        const before = i > 0 and isWord(self.raw[i - 1]);
        return before != self.isWordAt(i);
    }

    // Length of the JavaScript `\s` character at i, or 0.
    fn spaceLen(self: *const Highlighter, i: usize) usize {
        if (i >= self.raw.len) return 0;
        const byte = self.raw[i];
        if (byte == ' ' or (byte >= '\t' and byte <= '\r')) return 1;
        const rest = self.raw[i..];
        if (std.mem.startsWith(u8, rest, "\u{a0}") or std.mem.startsWith(u8, rest, "\u{1680}")) return if (byte == 0xc2) 2 else 3;
        if (std.mem.startsWith(u8, rest, "\u{feff}") or std.mem.startsWith(u8, rest, "\u{202f}") or
            std.mem.startsWith(u8, rest, "\u{205f}") or std.mem.startsWith(u8, rest, "\u{3000}") or
            std.mem.startsWith(u8, rest, "\u{2028}") or std.mem.startsWith(u8, rest, "\u{2029}")) return 3;
        if (rest.len >= 3 and rest[0] == 0xe2 and rest[1] == 0x80 and rest[2] >= 0x80 and rest[2] <= 0x8a) return 3;
        return 0;
    }

    fn skipSpaces(self: *const Highlighter, start: usize) usize {
        var i = start;
        while (true) {
            const len = self.spaceLen(i);
            if (len == 0) return i;
            i += len;
        }
    }

    // A JavaScript line terminator, which `.` and multiline `$` stop at.
    fn isLineTerminator(self: *const Highlighter, i: usize) bool {
        const byte = self.raw[i];
        if (byte == '\n' or byte == '\r') return true;
        return self.startsWith(i, "\u{2028}") or self.startsWith(i, "\u{2029}");
    }

    fn wordEnd(self: *const Highlighter, start: usize) usize {
        var i = start;
        while (self.isWordAt(i)) : (i += 1) {}
        return i;
    }

    // `[a-zA-Z_]\w*`, optionally preceded by `r#`.
    fn underscoreIdentEnd(self: *const Highlighter, start: usize) ?usize {
        if (self.startsWith(start, "r#") and isUnderscoreIdentStart(self.at(start + 2))) return self.wordEnd(start + 3);
        if (!isUnderscoreIdentStart(self.at(start))) return null;
        return self.wordEnd(start + 1);
    }

    fn keywordAt(self: *const Highlighter, i: usize, word: []const u8) bool {
        return self.startsWith(i, word);
    }

    // Plain text between rule matches, scanned with `[a-zA-Z]\w*!?`.
    fn writeGap(self: *Highlighter, start: usize, end: usize) void {
        var plain = start;
        var i = start;
        while (i < end) {
            if (!std.ascii.isAlphabetic(self.raw[i])) {
                i += 1;
                continue;
            }
            var word_end = i + 1;
            while (word_end < end and isWord(self.raw[word_end])) : (word_end += 1) {}
            if (word_end < end and self.raw[word_end] == '!') word_end += 1;
            if (TopKeywords.get(self.raw[i..word_end])) |class| {
                self.emit(plain, i);
                self.emitSpan(className(class), i, word_end);
                plain = word_end;
            }
            i = word_end;
        }
        self.emit(plain, end);
    }

    // Comment body after its opening; returns where the comment ends.
    fn writeComment(self: *Highlighter, start: usize, nested: bool) usize {
        var plain = start;
        var i = start;
        while (i < self.raw.len) {
            if (nested and self.startsWith(i, "/*")) {
                self.emit(plain, i);
                i = self.writeBlockComment(i);
                plain = i;
                continue;
            }
            if (doctagLen(self.raw[i..])) |len| {
                self.emit(plain, i);
                self.emitSpan("hljs-doctag", i, i + len);
                i += len;
                plain = i;
                continue;
            }
            if (nested and self.startsWith(i, "*/")) {
                self.emit(plain, i + 2);
                return i + 2;
            }
            if (!nested and self.isLineTerminator(i)) break;
            i += 1;
        }
        self.emit(plain, i);
        return i;
    }

    fn writeBlockComment(self: *Highlighter, start: usize) usize {
        self.writer.openSpan("hljs-comment");
        self.emit(start, start + 2);
        const end = self.writeComment(start + 2, true);
        self.writer.closeSpan();
        return end;
    }

    // Double-quoted string body; `\` escapes any character.
    fn quotedEnd(self: *const Highlighter, start: usize) usize {
        var i = start;
        while (i < self.raw.len) {
            if (self.raw[i] == '\\') {
                i = @min(i + 2, self.raw.len);
                continue;
            }
            if (self.raw[i] == '"') return i + 1;
            i += 1;
        }
        return self.raw.len;
    }

    // `b?r(#*)"(.|\n)*?"\1(?!#)`
    fn rawStringEnd(self: *const Highlighter, start: usize) ?usize {
        var i = start;
        if (self.at(i) == 'b') i += 1;
        if (self.at(i) != 'r') return null;
        i += 1;
        const hashes_start = i;
        while (self.at(i) == '#') : (i += 1) {}
        const hashes = i - hashes_start;
        if (self.at(i) != '"') return null;
        i += 1;
        while (i < self.raw.len) {
            if (self.raw[i] == '"') {
                var j = i + 1;
                while (j < i + 1 + hashes and self.at(j) == '#') : (j += 1) {}
                if (j == i + 1 + hashes and self.at(j) != '#') return j;
            }
            if (self.raw[i] != '\n' and self.isLineTerminator(i)) return null;
            i += 1;
        }
        return null;
    }

    // `'[a-zA-Z_][a-zA-Z0-9_]*(?!')`
    fn symbolEnd(self: *const Highlighter, start: usize) ?usize {
        if (self.at(start) != '\'' or !isUnderscoreIdentStart(self.at(start + 1))) return null;
        const end = self.wordEnd(start + 2);
        if (self.at(end) != '\'') return end;
        // Backtracking drops the last character, if one can be dropped.
        return if (end > start + 2) end - 1 else null;
    }

    fn writeCharString(self: *Highlighter, start: usize, open_end: usize) usize {
        self.writer.openSpan("hljs-string");
        var plain = start;
        var i = open_end;
        while (i < self.raw.len) {
            if (self.raw[i] == '\'') {
                i += 1;
                break;
            }
            // `\\('|"|\\|\w|…)`: the `\w` branch shadows `x\w{2}` and the rest.
            if (self.raw[i] == '\\' and i + 1 < self.raw.len) {
                const next = self.raw[i + 1];
                if (next == '\'' or next == '"' or next == '\\' or isWord(next)) {
                    self.emit(plain, i);
                    self.emitSpan("hljs-char escape_", i, i + 2);
                    i += 2;
                    plain = i;
                    continue;
                }
            }
            i += 1;
        }
        self.emit(plain, i);
        self.writer.closeSpan();
        return i;
    }

    fn numberEnd(self: *const Highlighter, start: usize) ?usize {
        if (!self.boundaryAt(start) or !std.ascii.isDigit(self.at(start))) return null;
        if (self.at(start) == '0') {
            const prefixes = [_]struct { byte: u8, digits: *const fn (u8) bool }{
                .{ .byte = 'b', .digits = isBinaryDigit },
                .{ .byte = 'o', .digits = isOctalDigit },
                .{ .byte = 'x', .digits = isHexDigit },
            };
            for (prefixes) |prefix| {
                if (self.at(start + 1) != prefix.byte) continue;
                var i = start + 2;
                while (i < self.raw.len and prefix.digits(self.raw[i])) : (i += 1) {}
                if (i > start + 2) return self.suffixEnd(i);
            }
        }
        var i = start + 1;
        while (i < self.raw.len and (std.ascii.isDigit(self.raw[i]) or self.raw[i] == '_')) : (i += 1) {}
        if (self.at(i) == '.' and isDecimalDigit(self.at(i + 1))) {
            i += 2;
            while (i < self.raw.len and isDecimalDigit(self.raw[i])) : (i += 1) {}
        }
        if (self.at(i) == 'e' or self.at(i) == 'E') {
            var j = i + 1;
            if (self.at(j) == '+' or self.at(j) == '-') j += 1;
            if (isDecimalDigit(self.at(j))) {
                while (j < self.raw.len and isDecimalDigit(self.raw[j])) : (j += 1) {}
                i = j;
            }
        }
        return self.suffixEnd(i);
    }

    // `([ui](8|16|32|64|128|size)|f(16|32|64|128))?`
    fn suffixEnd(self: *const Highlighter, start: usize) usize {
        const byte = self.at(start);
        const widths: []const []const u8 = if (byte == 'u' or byte == 'i')
            &.{ "8", "16", "32", "64", "128", "size" }
        else if (byte == 'f')
            &.{ "16", "32", "64", "128" }
        else
            return start;
        for (widths) |width| {
            if (self.startsWith(start + 1, width)) return start + 1 + width.len;
        }
        return start;
    }

    // `#!?\[` up to the first `]`, with double-quoted strings inside.
    fn writeMeta(self: *Highlighter, start: usize, open_end: usize) usize {
        self.writer.openSpan("hljs-meta");
        var plain = start;
        var i = open_end;
        while (i < self.raw.len) {
            if (self.raw[i] == ']') {
                i += 1;
                break;
            }
            if (self.raw[i] == '"') {
                self.emit(plain, i);
                const end = self.quotedEnd(i + 1);
                self.emitSpan("hljs-string", i, end);
                i = end;
                plain = i;
                continue;
            }
            i += 1;
        }
        self.emit(plain, i);
        self.writer.closeSpan();
        return i;
    }

    // Tries each top-level rule at i, in grammar order. Returns the end of
    // the match after writing it, or null if no rule matches here.
    fn writeRuleAt(self: *Highlighter, i: usize) ?usize {
        const byte = self.raw[i];
        if (self.startsWith(i, "//")) {
            self.writer.openSpan("hljs-comment");
            self.emit(i, i + 2);
            const end = self.writeComment(i + 2, false);
            self.writer.closeSpan();
            return end;
        }
        if (self.startsWith(i, "/*")) return self.writeBlockComment(i);
        if (byte == '"' or self.startsWith(i, "b\"")) {
            const open_end = if (byte == 'b') i + 2 else i + 1;
            const end = self.quotedEnd(open_end);
            self.emitSpan("hljs-string", i, end);
            return end;
        }
        if (self.symbolEnd(i)) |end| {
            self.emitSpan("hljs-symbol", i, end);
            return end;
        }
        if (self.rawStringEnd(i)) |end| {
            self.emitSpan("hljs-string", i, end);
            return end;
        }
        if (byte == '\'') return self.writeCharString(i, i + 1);
        if (self.startsWith(i, "b'")) return self.writeCharString(i, i + 2);
        if (self.numberEnd(i)) |end| {
            self.emitSpan("hljs-number", i, end);
            return end;
        }
        if (self.boundaryAt(i) and self.startsWith(i, "safe")) {
            const spaces_end = self.skipSpaces(i + 4);
            if (spaces_end > i + 4 and self.startsWith(spaces_end, "extern")) {
                self.emitSpan("hljs-keyword", i, i + 4);
                self.emit(i + 4, spaces_end);
                self.emitSpan("hljs-keyword", spaces_end, spaces_end + 6);
                return spaces_end + 6;
            }
        }
        if (self.writeKeywordTitle(i, "fn", "hljs-title function_")) |end| return end;
        if (byte == '#') {
            if (self.startsWith(i, "#[")) return self.writeMeta(i, i + 2);
            if (self.startsWith(i, "#![")) return self.writeMeta(i, i + 3);
        }
        if (self.writeLet(i)) |end| return end;
        if (self.writeForIn(i)) |end| return end;
        if (self.writeKeywordTitle(i, "type", "hljs-title class_")) |end| return end;
        for ([_][]const u8{ "trait", "enum", "struct", "union", "impl", "for" }) |keyword| {
            if (self.writeKeywordTitle(i, keyword, "hljs-title class_")) |end| return end;
        }
        if (std.ascii.isAlphabetic(byte)) {
            const end = self.wordEnd(i + 1);
            if (self.startsWith(end, "::")) {
                // Only Self, the built-ins and the types are keywords here.
                const class = TopKeywords.get(self.raw[i..end]);
                if (class != null and class.? != .literal and (class.? != .keyword or std.mem.eql(u8, self.raw[i..end], "Self"))) {
                    self.emitSpan(className(class.?), i, end);
                } else {
                    self.emit(i, end);
                }
                self.emit(end, end + 2);
                return end + 2;
            }
        }
        if (self.startsWith(i, "->")) {
            self.emitSpan("hljs-punctuation", i, i + 2);
            return i + 2;
        }
        if (self.functionInvokeEnd(i)) |end| {
            self.emitSpan("hljs-title function_ invoke__", i, end);
            return end;
        }
        return null;
    }

    // `keyword\s+IDENT`, with the identifier given `title_class`.
    fn writeKeywordTitle(self: *Highlighter, i: usize, keyword: []const u8, title_class: []const u8) ?usize {
        if (!self.keywordAt(i, keyword)) return null;
        const spaces_end = self.skipSpaces(i + keyword.len);
        if (spaces_end == i + keyword.len) return null;
        const end = self.underscoreIdentEnd(spaces_end) orelse return null;
        self.emitSpan("hljs-keyword", i, i + keyword.len);
        self.emit(i + keyword.len, spaces_end);
        self.emitSpan(title_class, spaces_end, end);
        return end;
    }

    // `let\s+(?:mut\s+)?IDENT`
    fn writeLet(self: *Highlighter, i: usize) ?usize {
        if (!self.keywordAt(i, "let")) return null;
        const spaces_end = self.skipSpaces(i + 3);
        if (spaces_end == i + 3) return null;
        var mut_end = spaces_end;
        if (self.startsWith(spaces_end, "mut")) {
            const after_mut = self.skipSpaces(spaces_end + 3);
            if (after_mut > spaces_end + 3 and self.underscoreIdentEnd(after_mut) != null) mut_end = after_mut;
        }
        const end = self.underscoreIdentEnd(mut_end) orelse return null;
        self.emitSpan("hljs-keyword", i, i + 3);
        self.emit(i + 3, spaces_end);
        self.emitSpan("hljs-keyword", spaces_end, mut_end);
        self.emitSpan("hljs-variable", mut_end, end);
        return end;
    }

    // `for\s+IDENT\s+in`
    fn writeForIn(self: *Highlighter, i: usize) ?usize {
        if (!self.keywordAt(i, "for")) return null;
        const spaces_end = self.skipSpaces(i + 3);
        if (spaces_end == i + 3) return null;
        const name_end = self.underscoreIdentEnd(spaces_end) orelse return null;
        const in_start = self.skipSpaces(name_end);
        if (in_start == name_end or !self.startsWith(in_start, "in")) return null;
        self.emitSpan("hljs-keyword", i, i + 3);
        self.emit(i + 3, spaces_end);
        self.emitSpan("hljs-variable", spaces_end, name_end);
        self.emit(name_end, in_start);
        self.emitSpan("hljs-keyword", in_start, in_start + 2);
        return in_start + 2;
    }

    // `\b(?!(?:let|for|while|if|else|match)\b)(r#)?[a-zA-Z]\w*(?=\s*\()`
    fn functionInvokeEnd(self: *const Highlighter, i: usize) ?usize {
        if (!self.boundaryAt(i)) return null;
        const word = self.raw[i..self.wordEnd(i)];
        for ([_][]const u8{ "let", "for", "while", "if", "else", "match" }) |excluded| {
            if (std.mem.eql(u8, word, excluded)) return null;
        }
        var end: ?usize = null;
        if (self.startsWith(i, "r#") and std.ascii.isAlphabetic(self.at(i + 2))) end = self.wordEnd(i + 3);
        if (end == null or self.at(self.skipSpaces(end.?)) != '(') {
            if (!std.ascii.isAlphabetic(self.at(i))) return null;
            end = self.wordEnd(i + 1);
        }
        if (self.at(self.skipSpaces(end.?)) != '(') return null;
        return end;
    }

    fn run(self: *Highlighter) void {
        var gap = @as(usize, 0);
        var i = @as(usize, 0);
        while (i < self.raw.len) {
            // The grammar's `</` illegal rule consumes both characters as text.
            if (self.startsWith(i, "</")) {
                i += 2;
                continue;
            }
            if (self.ruleMatches(i)) {
                self.writeGap(gap, i);
                i = self.writeRuleAt(i).?;
                gap = i;
                continue;
            }
            i += 1;
        }
        self.writeGap(gap, self.raw.len);
    }

    // Whether writeRuleAt would match at i, checked by writing nowhere, so
    // the gap before the match can be written first.
    fn ruleMatches(self: *Highlighter, i: usize) bool {
        const writer = self.writer;
        defer self.writer = writer;
        var discard = Writer{ .idx = output_buf.len, .overflow = true };
        self.writer = &discard;
        return self.writeRuleAt(i) != null;
    }
};

fn className(class: Class) []const u8 {
    return switch (class) {
        .keyword => "hljs-keyword",
        .literal => "hljs-literal",
        .built_in => "hljs-built_in",
        .type => "hljs-type",
    };
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isUnderscoreIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isDecimalDigit(byte: u8) bool {
    return std.ascii.isDigit(byte) or byte == '_';
}

fn isBinaryDigit(byte: u8) bool {
    return byte == '0' or byte == '1' or byte == '_';
}

fn isOctalDigit(byte: u8) bool {
    return (byte >= '0' and byte <= '7') or byte == '_';
}

fn isHexDigit(byte: u8) bool {
    return std.ascii.isHex(byte) or byte == '_';
}

// `(TODO|FIXME|NOTE|BUG|OPTIMIZE|HACK|XXX):` inside comments.
fn doctagLen(text: []const u8) ?usize {
    for ([_][]const u8{ "TODO", "FIXME", "NOTE", "BUG", "OPTIMIZE", "HACK", "XXX" }) |tag| {
        if (text.len > tag.len and std.mem.startsWith(u8, text, tag) and text[tag.len] == ':') return tag.len + 1;
    }
    return null;
}

fn writeRust(code: []const u8, writer: *Writer) void {
    const len = decode(code);
    var highlighter = Highlighter{ .code = code, .raw = raw_buf[0..len], .writer = writer };
    highlighter.run();
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
        if (!open.is_rust or open.has_hljs or containsSpanTag(code)) {
            writer.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenTag(input[i .. open.end + 1], writer);
            writeRust(code, writer);
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

test "highlights Rust declarations, bindings and calls" {
    const input = "<code class=\"language-rust\">fn main() -&gt; u8 { let mut n = Vec::new(); n.push(1u8); }</code>";
    const expected = "<code class=\"language-rust hljs\"><span class=\"hljs-keyword\">fn</span> <span class=\"hljs-title function_\">main</span>() <span class=\"hljs-punctuation\">-&gt;</span> <span class=\"hljs-type\">u8</span> { <span class=\"hljs-keyword\">let</span> <span class=\"hljs-keyword\">mut </span><span class=\"hljs-variable\">n</span> = <span class=\"hljs-type\">Vec</span>::<span class=\"hljs-title function_ invoke__\">new</span>(); n.<span class=\"hljs-title function_ invoke__\">push</span>(<span class=\"hljs-number\">1u8</span>); }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights lifetimes, chars, raw strings and doctags" {
    const input = "<code class=\"language-rs\">&amp;&#39;a str; &#39;\\n&#39;; r#&quot;x&quot;#; // TODO: y</code>";
    const expected = "<code class=\"language-rs hljs\">&amp;<span class=\"hljs-symbol\">&#39;a</span> <span class=\"hljs-type\">str</span>; <span class=\"hljs-string\">&#39;<span class=\"hljs-char escape_\">\\n</span>&#39;</span>; <span class=\"hljs-string\">r#&quot;x&quot;#</span>; <span class=\"hljs-comment\">// <span class=\"hljs-doctag\">TODO:</span> y</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted blocks and other languages" {
    const highlighted = "<code class=\"language-rust\"><span class=\"hljs-keyword\">fn</span> main</code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const go = "<code class=\"language-go\">fn main() {}</code>";
    try std.testing.expectEqualStrings(go, runForTest(go));
}
