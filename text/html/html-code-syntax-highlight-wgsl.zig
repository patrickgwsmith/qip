const std = @import("std");

// Highlights WGSL code blocks in Highlight.js's markup. Highlight.js 11 has
// no WGSL grammar, so this follows a small grammar of its own: comments
// (block comments nest), `@` attributes, numbers, `fn`/`struct`/`alias`
// names, `->`, calls, and keywords, types and built-in functions in the
// gaps between. Rules are matched against the decoded source; output copies
// the original escaped HTML so entities pass through unchanged.

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

// Keywords, address spaces and access modes; types, including the
// predeclared aliases like `vec4f`; and the built-in functions.
const Keywords = std.StaticStringMap(Class).initComptime(.{
    .{ "alias", .keyword }, .{ "break", .keyword }, .{ "case", .keyword }, .{ "const", .keyword },
    .{ "const_assert", .keyword }, .{ "continue", .keyword }, .{ "continuing", .keyword }, .{ "default", .keyword },
    .{ "diagnostic", .keyword }, .{ "discard", .keyword }, .{ "else", .keyword }, .{ "enable", .keyword },
    .{ "fn", .keyword }, .{ "for", .keyword }, .{ "if", .keyword }, .{ "let", .keyword },
    .{ "loop", .keyword }, .{ "override", .keyword }, .{ "requires", .keyword }, .{ "return", .keyword },
    .{ "struct", .keyword }, .{ "switch", .keyword }, .{ "var", .keyword }, .{ "while", .keyword },
    .{ "function", .keyword }, .{ "private", .keyword }, .{ "workgroup", .keyword }, .{ "uniform", .keyword },
    .{ "storage", .keyword }, .{ "read", .keyword }, .{ "write", .keyword }, .{ "read_write", .keyword },
    .{ "true", .literal }, .{ "false", .literal }, .{ "bool", .type }, .{ "f16", .type },
    .{ "f32", .type }, .{ "i32", .type }, .{ "u32", .type }, .{ "vec2", .type },
    .{ "vec3", .type }, .{ "vec4", .type }, .{ "mat2x2", .type }, .{ "mat2x3", .type },
    .{ "mat2x4", .type }, .{ "mat3x2", .type }, .{ "mat3x3", .type }, .{ "mat3x4", .type },
    .{ "mat4x2", .type }, .{ "mat4x3", .type }, .{ "mat4x4", .type }, .{ "array", .type },
    .{ "atomic", .type }, .{ "ptr", .type }, .{ "sampler", .type }, .{ "sampler_comparison", .type },
    .{ "texture_1d", .type }, .{ "texture_2d", .type }, .{ "texture_2d_array", .type }, .{ "texture_3d", .type },
    .{ "texture_cube", .type }, .{ "texture_cube_array", .type }, .{ "texture_multisampled_2d", .type }, .{ "texture_depth_multisampled_2d", .type },
    .{ "texture_external", .type }, .{ "texture_storage_1d", .type }, .{ "texture_storage_2d", .type }, .{ "texture_storage_2d_array", .type },
    .{ "texture_storage_3d", .type }, .{ "texture_depth_2d", .type }, .{ "texture_depth_2d_array", .type }, .{ "texture_depth_cube", .type },
    .{ "texture_depth_cube_array", .type }, .{ "vec2i", .type }, .{ "vec2u", .type }, .{ "vec2f", .type },
    .{ "vec2h", .type }, .{ "vec3i", .type }, .{ "vec3u", .type }, .{ "vec3f", .type },
    .{ "vec3h", .type }, .{ "vec4i", .type }, .{ "vec4u", .type }, .{ "vec4f", .type },
    .{ "vec4h", .type }, .{ "mat2x2f", .type }, .{ "mat2x2h", .type }, .{ "mat2x3f", .type },
    .{ "mat2x3h", .type }, .{ "mat2x4f", .type }, .{ "mat2x4h", .type }, .{ "mat3x2f", .type },
    .{ "mat3x2h", .type }, .{ "mat3x3f", .type }, .{ "mat3x3h", .type }, .{ "mat3x4f", .type },
    .{ "mat3x4h", .type }, .{ "mat4x2f", .type }, .{ "mat4x2h", .type }, .{ "mat4x3f", .type },
    .{ "mat4x3h", .type }, .{ "mat4x4f", .type }, .{ "mat4x4h", .type }, .{ "bitcast", .built_in },
    .{ "all", .built_in }, .{ "any", .built_in }, .{ "select", .built_in }, .{ "arrayLength", .built_in },
    .{ "abs", .built_in }, .{ "acos", .built_in }, .{ "acosh", .built_in }, .{ "asin", .built_in },
    .{ "asinh", .built_in }, .{ "atan", .built_in }, .{ "atanh", .built_in }, .{ "atan2", .built_in },
    .{ "ceil", .built_in }, .{ "clamp", .built_in }, .{ "cos", .built_in }, .{ "cosh", .built_in },
    .{ "countLeadingZeros", .built_in }, .{ "countOneBits", .built_in }, .{ "countTrailingZeros", .built_in }, .{ "cross", .built_in },
    .{ "degrees", .built_in }, .{ "determinant", .built_in }, .{ "distance", .built_in }, .{ "dot", .built_in },
    .{ "dot4U8Packed", .built_in }, .{ "dot4I8Packed", .built_in }, .{ "exp", .built_in }, .{ "exp2", .built_in },
    .{ "extractBits", .built_in }, .{ "faceForward", .built_in }, .{ "firstLeadingBit", .built_in }, .{ "firstTrailingBit", .built_in },
    .{ "floor", .built_in }, .{ "fma", .built_in }, .{ "fract", .built_in }, .{ "frexp", .built_in },
    .{ "insertBits", .built_in }, .{ "inverseSqrt", .built_in }, .{ "ldexp", .built_in }, .{ "length", .built_in },
    .{ "log", .built_in }, .{ "log2", .built_in }, .{ "max", .built_in }, .{ "min", .built_in },
    .{ "mix", .built_in }, .{ "modf", .built_in }, .{ "normalize", .built_in }, .{ "pow", .built_in },
    .{ "quantizeToF16", .built_in }, .{ "radians", .built_in }, .{ "reflect", .built_in }, .{ "refract", .built_in },
    .{ "reverseBits", .built_in }, .{ "round", .built_in }, .{ "saturate", .built_in }, .{ "sign", .built_in },
    .{ "sin", .built_in }, .{ "sinh", .built_in }, .{ "smoothstep", .built_in }, .{ "sqrt", .built_in },
    .{ "step", .built_in }, .{ "tan", .built_in }, .{ "tanh", .built_in }, .{ "transpose", .built_in },
    .{ "trunc", .built_in }, .{ "dpdx", .built_in }, .{ "dpdxCoarse", .built_in }, .{ "dpdxFine", .built_in },
    .{ "dpdy", .built_in }, .{ "dpdyCoarse", .built_in }, .{ "dpdyFine", .built_in }, .{ "fwidth", .built_in },
    .{ "fwidthCoarse", .built_in }, .{ "fwidthFine", .built_in }, .{ "textureDimensions", .built_in }, .{ "textureGather", .built_in },
    .{ "textureGatherCompare", .built_in }, .{ "textureLoad", .built_in }, .{ "textureNumLayers", .built_in }, .{ "textureNumLevels", .built_in },
    .{ "textureNumSamples", .built_in }, .{ "textureSample", .built_in }, .{ "textureSampleBias", .built_in }, .{ "textureSampleCompare", .built_in },
    .{ "textureSampleCompareLevel", .built_in }, .{ "textureSampleGrad", .built_in }, .{ "textureSampleLevel", .built_in }, .{ "textureSampleBaseClampToEdge", .built_in },
    .{ "textureStore", .built_in }, .{ "atomicLoad", .built_in }, .{ "atomicStore", .built_in }, .{ "atomicAdd", .built_in },
    .{ "atomicSub", .built_in }, .{ "atomicMax", .built_in }, .{ "atomicMin", .built_in }, .{ "atomicAnd", .built_in },
    .{ "atomicOr", .built_in }, .{ "atomicXor", .built_in }, .{ "atomicExchange", .built_in }, .{ "atomicCompareExchangeWeak", .built_in },
    .{ "pack4x8snorm", .built_in }, .{ "pack4x8unorm", .built_in }, .{ "pack4xI8", .built_in }, .{ "pack4xU8", .built_in },
    .{ "pack4xI8Clamp", .built_in }, .{ "pack4xU8Clamp", .built_in }, .{ "pack2x16snorm", .built_in }, .{ "pack2x16unorm", .built_in },
    .{ "pack2x16float", .built_in }, .{ "unpack4x8snorm", .built_in }, .{ "unpack4x8unorm", .built_in }, .{ "unpack4xI8", .built_in },
    .{ "unpack4xU8", .built_in }, .{ "unpack2x16snorm", .built_in }, .{ "unpack2x16unorm", .built_in }, .{ "unpack2x16float", .built_in },
    .{ "storageBarrier", .built_in }, .{ "textureBarrier", .built_in }, .{ "workgroupBarrier", .built_in }, .{ "workgroupUniformLoad", .built_in },
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
    is_wgsl: bool,
    has_hljs: bool,
};

const CloseTag = struct {
    start: usize,
    end: usize,
};

const ClassInfo = struct {
    is_wgsl: bool = false,
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
        if (eqlIgnoreCase(token, "language-wgsl")) result.is_wgsl = true;
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
    const range = classRange(tag) orelse return .{ .end = end, .is_wgsl = false, .has_hljs = false };
    const info = classInfo(tag[range.start..range.end]);
    return .{ .end = end, .is_wgsl = info.is_wgsl, .has_hljs = info.has_hljs };
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

    // A JavaScript line terminator, which multiline `$` stops at.
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

    // `[a-zA-Z_]\w*`
    fn identEnd(self: *const Highlighter, start: usize) ?usize {
        if (!isIdentStart(self.at(start))) return null;
        return self.wordEnd(start + 1);
    }

    // Plain text between rule matches, scanned with `\w+`.
    fn writeGap(self: *Highlighter, start: usize, end: usize) void {
        var plain = start;
        var i = start;
        while (i < end) {
            if (!isWord(self.raw[i])) {
                i += 1;
                continue;
            }
            var word_end = i + 1;
            while (word_end < end and isWord(self.raw[word_end])) : (word_end += 1) {}
            if (Keywords.get(self.raw[i..word_end])) |class| {
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

    fn digitsEnd(self: *const Highlighter, start: usize, digits: *const fn (u8) bool) usize {
        var i = start;
        while (i < self.raw.len and digits(self.raw[i])) : (i += 1) {}
        return i;
    }

    // `[eE][+-]?\d+` for decimals, `[pP][+-]?\d+` for hex, if present.
    fn exponentEnd(self: *const Highlighter, start: usize, marker: u8) usize {
        if (lower(self.at(start)) != marker) return start;
        var i = start + 1;
        if (self.at(i) == '+' or self.at(i) == '-') i += 1;
        const end = self.digitsEnd(i, isDigit);
        return if (end > i) end else start;
    }

    fn suffixEnd(self: *const Highlighter, start: usize, suffixes: []const u8) usize {
        return if (std.mem.indexOfScalar(u8, suffixes, self.at(start)) != null) start + 1 else start;
    }

    fn numberEnd(self: *const Highlighter, start: usize) ?usize {
        const byte = self.at(start);
        if (byte == '.') {
            // `\B\.\d+(?:[eE][+-]?\d+)?[fh]?`
            if (self.boundaryAt(start) or !isDigit(self.at(start + 1))) return null;
            const i = self.exponentEnd(self.digitsEnd(start + 1, isDigit), 'e');
            return self.suffixEnd(i, "fh");
        }
        if (!self.boundaryAt(start) or !isDigit(byte)) return null;
        if (byte == '0' and (self.at(start + 1) == 'x' or self.at(start + 1) == 'X')) {
            // `0[xX](?:H+(?:\.H*)?|\.H+)(?:[pP][+-]?\d+[fh]?)?[iu]?`
            var i = self.digitsEnd(start + 2, std.ascii.isHex);
            if (i > start + 2) {
                if (self.at(i) == '.') i = self.digitsEnd(i + 1, std.ascii.isHex);
            } else if (self.at(i) == '.' and std.ascii.isHex(self.at(i + 1))) {
                i = self.digitsEnd(i + 1, std.ascii.isHex);
            }
            if (i > start + 2) {
                const exponent_end = self.exponentEnd(i, 'p');
                if (exponent_end > i) i = self.suffixEnd(exponent_end, "fh");
                return self.suffixEnd(i, "iu");
            }
        }
        // `\d+(?:\.\d*)?(?:[eE][+-]?\d+)?[iufh]?`
        var i = self.digitsEnd(start + 1, isDigit);
        if (self.at(i) == '.') i = self.digitsEnd(i + 1, isDigit);
        return self.suffixEnd(self.exponentEnd(i, 'e'), "iufh");
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
        if (byte == '@') {
            if (self.identEnd(i + 1)) |end| {
                self.emitSpan("hljs-meta", i, end);
                return end;
            }
        }
        if (self.numberEnd(i)) |end| {
            self.emitSpan("hljs-number", i, end);
            return end;
        }
        if (self.writeKeywordTitle(i, "fn", "hljs-title function_")) |end| return end;
        if (self.writeKeywordTitle(i, "struct", "hljs-title class_")) |end| return end;
        if (self.writeKeywordTitle(i, "alias", "hljs-title class_")) |end| return end;
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

    // `\bkeyword\s+IDENT`, with the identifier given `title_class`.
    fn writeKeywordTitle(self: *Highlighter, i: usize, keyword: []const u8, title_class: []const u8) ?usize {
        if (!self.boundaryAt(i) or !self.startsWith(i, keyword)) return null;
        const spaces_end = self.skipSpaces(i + keyword.len);
        if (spaces_end == i + keyword.len) return null;
        const end = self.identEnd(spaces_end) orelse return null;
        self.emitSpan("hljs-keyword", i, i + keyword.len);
        self.emit(i + keyword.len, spaces_end);
        self.emitSpan(title_class, spaces_end, end);
        return end;
    }

    // `\b(?!KEYWORD\b)[a-zA-Z_]\w*(?=\s*\()`: keywords, types and built-ins
    // are left for the gap scan.
    fn functionInvokeEnd(self: *const Highlighter, i: usize) ?usize {
        if (!self.boundaryAt(i)) return null;
        const end = self.identEnd(i) orelse return null;
        if (Keywords.has(self.raw[i..end])) return null;
        if (self.at(self.skipSpaces(end)) != '(') return null;
        return end;
    }

    fn run(self: *Highlighter) void {
        var gap = @as(usize, 0);
        var i = @as(usize, 0);
        while (i < self.raw.len) {
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

fn isIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isDigit(byte: u8) bool {
    return std.ascii.isDigit(byte);
}

// `(TODO|FIXME|NOTE|BUG|OPTIMIZE|HACK|XXX):` inside comments.
fn doctagLen(text: []const u8) ?usize {
    for ([_][]const u8{ "TODO", "FIXME", "NOTE", "BUG", "OPTIMIZE", "HACK", "XXX" }) |tag| {
        if (text.len > tag.len and std.mem.startsWith(u8, text, tag) and text[tag.len] == ':') return tag.len + 1;
    }
    return null;
}

fn writeWgsl(code: []const u8, writer: *Writer) void {
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
        if (!open.is_wgsl or open.has_hljs or containsSpanTag(code)) {
            writer.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenTag(input[i .. open.end + 1], writer);
            writeWgsl(code, writer);
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

test "highlights WGSL entry points, types and calls" {
    const input = "<code class=\"language-wgsl\">@fragment fn main(@location(0) uv: vec2f) -&gt; @location(0) vec4f { return vec4(shade(uv), 1.0, textureLoad(t, 0u, 0)); }</code>";
    const expected = "<code class=\"language-wgsl hljs\"><span class=\"hljs-meta\">@fragment</span> <span class=\"hljs-keyword\">fn</span> <span class=\"hljs-title function_\">main</span>(<span class=\"hljs-meta\">@location</span>(<span class=\"hljs-number\">0</span>) uv: <span class=\"hljs-type\">vec2f</span>) <span class=\"hljs-punctuation\">-&gt;</span> <span class=\"hljs-meta\">@location</span>(<span class=\"hljs-number\">0</span>) <span class=\"hljs-type\">vec4f</span> { <span class=\"hljs-keyword\">return</span> <span class=\"hljs-type\">vec4</span>(<span class=\"hljs-title function_ invoke__\">shade</span>(uv), <span class=\"hljs-number\">1.0</span>, <span class=\"hljs-built_in\">textureLoad</span>(t, <span class=\"hljs-number\">0u</span>, <span class=\"hljs-number\">0</span>)); }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "highlights numbers, structs and nested comments" {
    const input = "<code class=\"language-wgsl\">struct P { a: f32 } const k = .5e-1f + 0x1.8p2 * 3i; /* a /* TODO: b */ c */</code>";
    const expected = "<code class=\"language-wgsl hljs\"><span class=\"hljs-keyword\">struct</span> <span class=\"hljs-title class_\">P</span> { a: <span class=\"hljs-type\">f32</span> } <span class=\"hljs-keyword\">const</span> k = <span class=\"hljs-number\">.5e-1f</span> + <span class=\"hljs-number\">0x1.8p2</span> * <span class=\"hljs-number\">3i</span>; <span class=\"hljs-comment\">/* a <span class=\"hljs-comment\">/* <span class=\"hljs-doctag\">TODO:</span> b */</span> c */</span></code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips highlighted blocks and other languages" {
    const highlighted = "<code class=\"language-wgsl\"><span class=\"hljs-keyword\">fn</span> main</code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const rust = "<code class=\"language-rust\">fn main() {}</code>";
    try std.testing.expectEqualStrings(rust, runForTest(rust));
}
