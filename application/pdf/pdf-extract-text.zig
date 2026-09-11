//! Extract readable UTF-8 text from born-digital PDFs.
//!
//! This first implementation targets ordinary, unencrypted PDFs whose page,
//! font, and content-stream objects are not packed into object streams. It
//! decodes unfiltered, Flate, ASCII85+Flate, and ASCIIHex+Flate content,
//! understands the common PDF text-positioning operators, applies simple
//! WinAnsi and ToUnicode mappings, suppresses overlapping duplicate glyphs,
//! and reconstructs words and visual lines from page coordinates.
//!
//! It deliberately does not perform OCR, table recognition, or semantic
//! heading detection. Pages are separated with form feed (U+000C).

const std = @import("std");
const inflate = @import("inflate");

const INPUT_CAP: usize = 64 * 1024 * 1024;
const OUTPUT_CAP: usize = 32 * 1024 * 1024;
const STREAM_CAP: usize = 64 * 1024 * 1024;
const MAX_OBJECTS: usize = 16_384;
const MAX_PAGES: usize = 4_096;
const MAX_REFS: usize = 32_768;
const MAX_FONTS: usize = 2_048;
const MAX_RESOURCE_FONTS: usize = 8_192;
const MAX_CMAP_ENTRIES: usize = 65_536;
const MAX_GLYPHS_PER_PAGE: usize = 500_000;
const INPUT_CONTENT_TYPE = "application/pdf";
const OUTPUT_CONTENT_TYPE = "text/plain";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var stream_buf_a: [STREAM_CAP]u8 = undefined;
var stream_buf_b: [STREAM_CAP]u8 = undefined;
var objects: [MAX_OBJECTS]PdfObject = undefined;
var pages: [MAX_PAGES]Page = undefined;
var refs: [MAX_REFS]u32 = undefined;
var fonts: [MAX_FONTS]Font = undefined;
var resource_fonts: [MAX_RESOURCE_FONTS]ResourceFont = undefined;
var cmap_entries: [MAX_CMAP_ENTRIES]CMapEntry = undefined;
var glyphs: [MAX_GLYPHS_PER_PAGE]Glyph = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
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

const ExtractError = error{
    InvalidPdf,
    EncryptedPdf,
    TooManyObjects,
    TooManyPages,
    TooManyReferences,
    TooManyFonts,
    TooManyResourceFonts,
    TooManyCMapEntries,
    TooManyGlyphs,
    UnsupportedStreamFilter,
    InvalidStream,
    OutputOverflow,
};

const Output = struct {
    index: usize = 0,

    fn write(self: *Output, bytes: []const u8) ExtractError!void {
        if (bytes.len > output_buf.len - self.index) return error.OutputOverflow;
        @memcpy(output_buf[self.index .. self.index + bytes.len], bytes);
        self.index += bytes.len;
    }

    fn byte(self: *Output, value: u8) ExtractError!void {
        if (self.index >= output_buf.len) return error.OutputOverflow;
        output_buf[self.index] = value;
        self.index += 1;
    }

    fn codepoint(self: *Output, value: u21) ExtractError!void {
        var encoded: [4]u8 = undefined;
        const size = std.unicode.utf8Encode(value, &encoded) catch return error.InvalidPdf;
        try self.write(encoded[0..size]);
    }

    fn trimSpaces(self: *Output) void {
        while (self.index > 0 and output_buf[self.index - 1] == ' ') self.index -= 1;
    }
};

fn isWhite(byte: u8) bool {
    return byte == 0 or byte == '\t' or byte == '\n' or byte == '\x0c' or byte == '\r' or byte == ' ';
}

fn isDelimiter(byte: u8) bool {
    return isWhite(byte) or byte == '(' or byte == ')' or byte == '<' or byte == '>' or
        byte == '[' or byte == ']' or byte == '{' or byte == '}' or byte == '/' or byte == '%';
}

fn hexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return null;
}

const TokenKind = enum {
    number,
    name,
    word,
    string,
    hex_string,
    dict_open,
    dict_close,
    array_open,
    array_close,
};

const Token = struct {
    kind: TokenKind,
    bytes: []const u8,
    start: usize,
    end: usize,
    number: f32 = 0,
    integer: ?i64 = null,
};

const Lexer = struct {
    input: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.input.len) {
            if (isWhite(self.input[self.pos])) {
                self.pos += 1;
                continue;
            }
            if (self.input[self.pos] == '%') {
                while (self.pos < self.input.len and self.input[self.pos] != '\r' and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }

    fn next(self: *Lexer) ?Token {
        self.skipSpace();
        if (self.pos >= self.input.len) return null;
        const start = self.pos;
        const first = self.input[self.pos];

        if (first == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '<') {
            self.pos += 2;
            return .{ .kind = .dict_open, .bytes = self.input[start..self.pos], .start = start, .end = self.pos };
        }
        if (first == '>' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
            self.pos += 2;
            return .{ .kind = .dict_close, .bytes = self.input[start..self.pos], .start = start, .end = self.pos };
        }
        if (first == '[' or first == ']') {
            self.pos += 1;
            return .{
                .kind = if (first == '[') .array_open else .array_close,
                .bytes = self.input[start..self.pos],
                .start = start,
                .end = self.pos,
            };
        }
        if (first == '/') {
            self.pos += 1;
            const name_start = self.pos;
            while (self.pos < self.input.len and !isDelimiter(self.input[self.pos])) self.pos += 1;
            return .{ .kind = .name, .bytes = self.input[name_start..self.pos], .start = start, .end = self.pos };
        }
        if (first == '(') {
            self.pos += 1;
            var depth: usize = 1;
            while (self.pos < self.input.len and depth != 0) {
                const byte = self.input[self.pos];
                self.pos += 1;
                if (byte == '\\') {
                    if (self.pos < self.input.len) {
                        if (self.input[self.pos] == '\r') {
                            self.pos += 1;
                            if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                        } else {
                            self.pos += 1;
                        }
                    }
                } else if (byte == '(') {
                    depth += 1;
                } else if (byte == ')') {
                    depth -= 1;
                }
            }
            if (depth != 0) return null;
            return .{ .kind = .string, .bytes = self.input[start..self.pos], .start = start, .end = self.pos };
        }
        if (first == '<') {
            self.pos += 1;
            while (self.pos < self.input.len and self.input[self.pos] != '>') self.pos += 1;
            if (self.pos >= self.input.len) return null;
            self.pos += 1;
            return .{ .kind = .hex_string, .bytes = self.input[start..self.pos], .start = start, .end = self.pos };
        }
        if (first == '>' or first == '{' or first == '}') {
            self.pos += 1;
            return .{ .kind = .word, .bytes = self.input[start..self.pos], .start = start, .end = self.pos };
        }

        while (self.pos < self.input.len and !isDelimiter(self.input[self.pos])) self.pos += 1;
        if (self.pos == start) return null;
        const bytes = self.input[start..self.pos];
        if (std.fmt.parseFloat(f32, bytes)) |number| {
            const integer = std.fmt.parseInt(i64, bytes, 10) catch null;
            return .{ .kind = .number, .bytes = bytes, .start = start, .end = self.pos, .number = number, .integer = integer };
        } else |_| {}
        return .{ .kind = .word, .bytes = bytes, .start = start, .end = self.pos };
    }
};

const Value = struct {
    first: Token,
    bytes: []const u8,
    reference: ?u32 = null,
};

fn captureValue(lexer: *Lexer, first: Token) ?Value {
    var end = first.end;
    if (first.kind == .dict_open or first.kind == .array_open) {
        var dict_depth: usize = if (first.kind == .dict_open) 1 else 0;
        var array_depth: usize = if (first.kind == .array_open) 1 else 0;
        while (lexer.next()) |token| {
            switch (token.kind) {
                .dict_open => dict_depth += 1,
                .dict_close => {
                    if (dict_depth == 0) return null;
                    dict_depth -= 1;
                },
                .array_open => array_depth += 1,
                .array_close => {
                    if (array_depth == 0) return null;
                    array_depth -= 1;
                },
                else => {},
            }
            end = token.end;
            if (dict_depth == 0 and array_depth == 0) break;
        }
        if (dict_depth != 0 or array_depth != 0) return null;
        return .{ .first = first, .bytes = lexer.input[first.start..end] };
    }
    if (first.kind == .number and first.integer != null and first.integer.? >= 0) {
        const saved = lexer.pos;
        const generation = lexer.next();
        const marker = lexer.next();
        if (generation != null and generation.?.kind == .number and generation.?.integer != null and
            generation.?.integer.? >= 0 and marker != null and marker.?.kind == .word and
            std.mem.eql(u8, marker.?.bytes, "R") and first.integer.? <= std.math.maxInt(u32))
        {
            return .{ .first = first, .bytes = lexer.input[first.start..marker.?.end], .reference = @intCast(first.integer.?) };
        }
        lexer.pos = saved;
    }
    return .{ .first = first, .bytes = lexer.input[first.start..first.end] };
}

fn findValue(dict: []const u8, key: []const u8) ?Value {
    var lexer = Lexer{ .input = dict };
    const opening = lexer.next() orelse return null;
    if (opening.kind != .dict_open) return null;
    var dict_depth: usize = 1;
    var array_depth: usize = 0;
    while (lexer.next()) |token| {
        switch (token.kind) {
            .dict_open => dict_depth += 1,
            .dict_close => {
                if (dict_depth == 0) return null;
                dict_depth -= 1;
                if (dict_depth == 0) return null;
            },
            .array_open => array_depth += 1,
            .array_close => if (array_depth > 0) {
                array_depth -= 1;
            },
            .name => if (dict_depth == 1 and array_depth == 0 and std.mem.eql(u8, token.bytes, key)) {
                const first = lexer.next() orelse return null;
                return captureValue(&lexer, first);
            },
            else => {},
        }
    }
    return null;
}

fn valueName(value: ?Value) ?[]const u8 {
    const actual = value orelse return null;
    if (actual.first.kind != .name) return null;
    return actual.first.bytes;
}

fn tokenBoundary(input: []const u8, start: usize, len: usize) bool {
    return (start == 0 or isDelimiter(input[start - 1])) and
        (start + len == input.len or isDelimiter(input[start + len]));
}

fn findKeyword(input: []const u8, start: usize, keyword: []const u8) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, input, cursor, keyword)) |at| {
        if (tokenBoundary(input, at, keyword.len)) return at;
        cursor = at + keyword.len;
    }
    return null;
}

const PdfObject = struct {
    number: u32,
    dictionary: []const u8,
    stream: ?[]const u8,
};

fn scanObjects(input: []const u8) ExtractError!usize {
    var count: usize = 0;
    var lexer = Lexer{ .input = input };
    var prior2: ?Token = null;
    var prior1: ?Token = null;
    while (lexer.next()) |token| {
        if (token.kind == .word and std.mem.eql(u8, token.bytes, "obj") and
            prior2 != null and prior2.?.kind == .number and prior2.?.integer != null and prior2.?.integer.? >= 0 and
            prior1 != null and prior1.?.kind == .number and prior1.?.integer != null and prior1.?.integer.? >= 0 and
            prior2.?.integer.? <= std.math.maxInt(u32))
        {
            const object_number: u32 = @intCast(prior2.?.integer.?);
            const first = lexer.next() orelse return error.InvalidPdf;
            if (first.kind != .dict_open) {
                const endobj = findKeyword(input, first.end, "endobj") orelse return error.InvalidPdf;
                lexer.pos = endobj + "endobj".len;
                prior2 = null;
                prior1 = null;
                continue;
            }
            const value = captureValue(&lexer, first) orelse return error.InvalidPdf;
            const dictionary = value.bytes;
            var stream: ?[]const u8 = null;
            const after_dict = lexer.pos;
            const next = lexer.next();
            if (next != null and next.?.kind == .word and std.mem.eql(u8, next.?.bytes, "stream")) {
                var stream_start = next.?.end;
                if (stream_start < input.len and input[stream_start] == '\r') {
                    stream_start += 1;
                    if (stream_start < input.len and input[stream_start] == '\n') stream_start += 1;
                } else if (stream_start < input.len and input[stream_start] == '\n') {
                    stream_start += 1;
                } else return error.InvalidStream;

                var stream_end: ?usize = null;
                if (findValue(dictionary, "Length")) |length_value| {
                    if (length_value.first.kind == .number and length_value.first.integer != null and length_value.first.integer.? >= 0) {
                        const length: usize = @intCast(length_value.first.integer.?);
                        if (length <= input.len - stream_start) stream_end = stream_start + length;
                    }
                }
                if (stream_end == null) stream_end = findKeyword(input, stream_start, "endstream") orelse return error.InvalidStream;
                var trimmed_end = stream_end.?;
                while (trimmed_end > stream_start and (input[trimmed_end - 1] == '\r' or input[trimmed_end - 1] == '\n')) trimmed_end -= 1;
                stream = input[stream_start..trimmed_end];
                const endstream = findKeyword(input, stream_end.?, "endstream") orelse return error.InvalidStream;
                const endobj = findKeyword(input, endstream + "endstream".len, "endobj") orelse return error.InvalidPdf;
                lexer.pos = endobj + "endobj".len;
            } else {
                lexer.pos = after_dict;
                const endobj = findKeyword(input, lexer.pos, "endobj") orelse return error.InvalidPdf;
                lexer.pos = endobj + "endobj".len;
            }
            if (count >= objects.len) return error.TooManyObjects;
            objects[count] = .{ .number = object_number, .dictionary = dictionary, .stream = stream };
            count += 1;
            prior2 = null;
            prior1 = null;
            continue;
        }
        prior2 = prior1;
        prior1 = token;
    }
    return count;
}

fn findObject(object_count: usize, number: u32) ?*const PdfObject {
    var index: usize = 0;
    while (index < object_count) : (index += 1) {
        if (objects[index].number == number) return &objects[index];
    }
    return null;
}

const Filter = enum { none, flate, ascii85, ascii_hex, ascii85_flate, ascii_hex_flate, unsupported };

fn filterFor(dictionary: []const u8) Filter {
    const value = findValue(dictionary, "Filter") orelse return .none;
    if (value.first.kind == .name) {
        if (std.mem.eql(u8, value.first.bytes, "FlateDecode") or std.mem.eql(u8, value.first.bytes, "Fl")) return .flate;
        if (std.mem.eql(u8, value.first.bytes, "ASCII85Decode") or std.mem.eql(u8, value.first.bytes, "A85")) return .ascii85;
        if (std.mem.eql(u8, value.first.bytes, "ASCIIHexDecode") or std.mem.eql(u8, value.first.bytes, "AHx")) return .ascii_hex;
        return .unsupported;
    }
    if (value.first.kind != .array_open) return .unsupported;
    var lexer = Lexer{ .input = value.bytes };
    _ = lexer.next();
    var names: [3][]const u8 = undefined;
    var count: usize = 0;
    while (lexer.next()) |token| {
        if (token.kind == .array_close) break;
        if (token.kind == .name) {
            if (count >= names.len) return .unsupported;
            names[count] = token.bytes;
            count += 1;
        }
    }
    if (count == 2 and (std.mem.eql(u8, names[1], "FlateDecode") or std.mem.eql(u8, names[1], "Fl"))) {
        if (std.mem.eql(u8, names[0], "ASCII85Decode") or std.mem.eql(u8, names[0], "A85")) return .ascii85_flate;
        if (std.mem.eql(u8, names[0], "ASCIIHexDecode") or std.mem.eql(u8, names[0], "AHx")) return .ascii_hex_flate;
    }
    return .unsupported;
}

fn decodeAsciiHex(input: []const u8, output: []u8) ?usize {
    var high: ?u8 = null;
    var target: usize = 0;
    for (input) |byte| {
        if (isWhite(byte)) continue;
        if (byte == '>') break;
        const nibble = hexNibble(byte) orelse return null;
        if (high) |value| {
            if (target >= output.len) return null;
            output[target] = (value << 4) | nibble;
            target += 1;
            high = null;
        } else high = nibble;
    }
    if (high) |value| {
        if (target >= output.len) return null;
        output[target] = value << 4;
        target += 1;
    }
    return target;
}

fn decodeAscii85(input: []const u8, output: []u8) ?usize {
    var source: usize = 0;
    var target: usize = 0;
    var group: [5]u8 = undefined;
    var count: usize = 0;
    while (source < input.len) : (source += 1) {
        const byte = input[source];
        if (isWhite(byte)) continue;
        if (byte == '<' and source + 1 < input.len and input[source + 1] == '~') {
            source += 1;
            continue;
        }
        if (byte == '~') {
            if (source + 1 >= input.len or input[source + 1] != '>') return null;
            break;
        }
        if (byte == 'z') {
            if (count != 0 or target + 4 > output.len) return null;
            @memset(output[target .. target + 4], 0);
            target += 4;
            continue;
        }
        if (byte < '!' or byte > 'u') return null;
        group[count] = byte - '!';
        count += 1;
        if (count == 5) {
            var value: u64 = 0;
            for (group) |digit| value = value * 85 + digit;
            if (value > std.math.maxInt(u32) or target + 4 > output.len) return null;
            std.mem.writeInt(u32, output[target..][0..4], @intCast(value), .big);
            target += 4;
            count = 0;
        }
    }
    if (count == 1) return null;
    if (count > 1) {
        const output_count = count - 1;
        while (count < 5) : (count += 1) group[count] = 84;
        var value: u64 = 0;
        for (group) |digit| value = value * 85 + digit;
        if (value > std.math.maxInt(u32) or target + output_count > output.len) return null;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(value), .big);
        @memcpy(output[target .. target + output_count], bytes[0..output_count]);
        target += output_count;
    }
    return target;
}

fn decodeStream(object: *const PdfObject) ExtractError![]const u8 {
    const stream = object.stream orelse return error.InvalidStream;
    return switch (filterFor(object.dictionary)) {
        .none => stream,
        .flate => stream_buf_b[0 .. inflate.inflateZlib(stream, &stream_buf_b) orelse return error.InvalidStream],
        .ascii85 => stream_buf_a[0 .. decodeAscii85(stream, &stream_buf_a) orelse return error.InvalidStream],
        .ascii_hex => stream_buf_a[0 .. decodeAsciiHex(stream, &stream_buf_a) orelse return error.InvalidStream],
        .ascii85_flate => blk: {
            const outer = stream_buf_a[0 .. decodeAscii85(stream, &stream_buf_a) orelse return error.InvalidStream];
            break :blk stream_buf_b[0 .. inflate.inflateZlib(outer, &stream_buf_b) orelse return error.InvalidStream];
        },
        .ascii_hex_flate => blk: {
            const outer = stream_buf_a[0 .. decodeAsciiHex(stream, &stream_buf_a) orelse return error.InvalidStream];
            break :blk stream_buf_b[0 .. inflate.inflateZlib(outer, &stream_buf_b) orelse return error.InvalidStream];
        },
        .unsupported => error.UnsupportedStreamFilter,
    };
}

const Page = struct { object_number: u32, ref_start: usize, ref_count: usize };

fn appendRefs(value: Value, ref_count: *usize) ExtractError!void {
    if (value.reference) |reference| {
        if (ref_count.* >= refs.len) return error.TooManyReferences;
        refs[ref_count.*] = reference;
        ref_count.* += 1;
        return;
    }
    var lexer = Lexer{ .input = value.bytes };
    var prior2: ?Token = null;
    var prior1: ?Token = null;
    while (lexer.next()) |token| {
        if (token.kind == .word and std.mem.eql(u8, token.bytes, "R") and
            prior2 != null and prior2.?.kind == .number and prior2.?.integer != null and
            prior2.?.integer.? >= 0 and prior2.?.integer.? <= std.math.maxInt(u32) and
            prior1 != null and prior1.?.kind == .number)
        {
            if (ref_count.* >= refs.len) return error.TooManyReferences;
            refs[ref_count.*] = @intCast(prior2.?.integer.?);
            ref_count.* += 1;
        }
        prior2 = prior1;
        prior1 = token;
    }
}

fn collectPages(object_count: usize) ExtractError!struct { page_count: usize, ref_count: usize } {
    var page_count: usize = 0;
    var ref_count: usize = 0;
    var index: usize = 0;
    while (index < object_count) : (index += 1) {
        const object = &objects[index];
        const kind = valueName(findValue(object.dictionary, "Type")) orelse continue;
        if (!std.mem.eql(u8, kind, "Page")) continue;
        if (page_count >= pages.len) return error.TooManyPages;
        const start = ref_count;
        if (findValue(object.dictionary, "Contents")) |contents| try appendRefs(contents, &ref_count);
        pages[page_count] = .{ .object_number = object.number, .ref_start = start, .ref_count = ref_count - start };
        page_count += 1;
    }
    return .{ .page_count = page_count, .ref_count = ref_count };
}

const Font = struct {
    object_number: u32,
    to_unicode: ?u32 = null,
    identity: bool = false,
    cmap_start: usize = 0,
    cmap_count: usize = 0,
};

const ResourceFont = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8,
    object_number: u32,
};

fn addFont(object: *const PdfObject, font_count: *usize) ExtractError!void {
    if (font_count.* >= fonts.len) return error.TooManyFonts;
    const encoding = valueName(findValue(object.dictionary, "Encoding"));
    fonts[font_count.*] = .{
        .object_number = object.number,
        .to_unicode = if (findValue(object.dictionary, "ToUnicode")) |value| value.reference else null,
        .identity = if (encoding) |name| std.mem.eql(u8, name, "Identity-H") or std.mem.eql(u8, name, "Identity-V") else false,
    };
    font_count.* += 1;
}

fn collectResourceFontDictionary(bytes: []const u8, resource_count: *usize) ExtractError!void {
    var lexer = Lexer{ .input = bytes };
    const opening = lexer.next() orelse return;
    if (opening.kind != .dict_open) return;
    while (lexer.next()) |name| {
        if (name.kind == .dict_close) break;
        if (name.kind != .name) continue;
        const first = lexer.next() orelse break;
        const value = captureValue(&lexer, first) orelse break;
        const object_number = value.reference orelse continue;
        if (name.bytes.len == 0 or name.bytes.len > 32) continue;
        if (resource_count.* >= resource_fonts.len) return error.TooManyResourceFonts;
        var mapping = ResourceFont{ .name_len = @intCast(name.bytes.len), .object_number = object_number };
        @memcpy(mapping.name[0..name.bytes.len], name.bytes);
        resource_fonts[resource_count.*] = mapping;
        resource_count.* += 1;
    }
}

fn collectFontValue(object_count: usize, value: Value, resource_count: *usize) ExtractError!void {
    if (value.reference) |reference| {
        if (findObject(object_count, reference)) |font_dict| try collectResourceFontDictionary(font_dict.dictionary, resource_count);
    } else if (value.first.kind == .dict_open) {
        try collectResourceFontDictionary(value.bytes, resource_count);
    }
}

fn collectResources(object_count: usize, resources: Value, resource_count: *usize) ExtractError!void {
    const dictionary = if (resources.reference) |reference|
        if (findObject(object_count, reference)) |object| object.dictionary else return
    else if (resources.first.kind == .dict_open)
        resources.bytes
    else
        return;
    if (findValue(dictionary, "Font")) |font_value| try collectFontValue(object_count, font_value, resource_count);
}

fn collectFonts(object_count: usize) ExtractError!struct { font_count: usize, resource_count: usize } {
    var font_count: usize = 0;
    var resource_count: usize = 0;
    var index: usize = 0;
    while (index < object_count) : (index += 1) {
        const object = &objects[index];
        const kind = valueName(findValue(object.dictionary, "Type"));
        if (kind != null and std.mem.eql(u8, kind.?, "Font")) try addFont(object, &font_count);
    }
    index = 0;
    while (index < object_count) : (index += 1) {
        if (findValue(objects[index].dictionary, "Font")) |font_value| try collectFontValue(object_count, font_value, &resource_count);
        if (findValue(objects[index].dictionary, "Resources")) |resources| try collectResources(object_count, resources, &resource_count);
    }
    return .{ .font_count = font_count, .resource_count = resource_count };
}

fn findFont(font_count: usize, object_number: u32) ?*Font {
    var index: usize = 0;
    while (index < font_count) : (index += 1) {
        if (fonts[index].object_number == object_number) return &fonts[index];
    }
    return null;
}

fn fontForResource(font_count: usize, resource_count: usize, name: []const u8) ?*Font {
    var index = resource_count;
    while (index > 0) {
        index -= 1;
        const mapping = &resource_fonts[index];
        if (mapping.name_len == name.len and std.mem.eql(u8, mapping.name[0..mapping.name_len], name)) {
            return findFont(font_count, mapping.object_number);
        }
    }
    return null;
}

const CMapEntry = struct {
    font_object: u32,
    source: u32,
    source_len: u8,
    utf8: [16]u8 = [_]u8{0} ** 16,
    utf8_len: u8,
};

fn decodeHexBytes(token: []const u8, output: []u8) ?usize {
    if (token.len < 2 or token[0] != '<' or token[token.len - 1] != '>') return null;
    return decodeAsciiHex(token[1 .. token.len - 1], output);
}

const SourceCode = struct { value: u32, len: u8 };

fn sourceCode(token: []const u8) ?SourceCode {
    var bytes: [4]u8 = undefined;
    const count = decodeHexBytes(token, &bytes) orelse return null;
    if (count == 0 or count > 4) return null;
    var value: u32 = 0;
    for (bytes[0..count]) |byte| value = (value << 8) | byte;
    return .{ .value = value, .len = @intCast(count) };
}

fn utf16HexToUtf8(token: []const u8, output: []u8) ?usize {
    var bytes: [32]u8 = undefined;
    const count = decodeHexBytes(token, &bytes) orelse return null;
    if (count == 0 or count % 2 != 0) return null;
    var source: usize = 0;
    var target: usize = 0;
    while (source < count) {
        var codepoint: u21 = std.mem.readInt(u16, bytes[source..][0..2], .big);
        source += 2;
        if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
            if (source + 2 > count) return null;
            const low = std.mem.readInt(u16, bytes[source..][0..2], .big);
            if (low < 0xdc00 or low > 0xdfff) return null;
            source += 2;
            codepoint = @intCast(0x10000 + ((@as(u32, codepoint) - 0xd800) << 10) + (@as(u32, low) - 0xdc00));
        } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) return null;
        var encoded: [4]u8 = undefined;
        const size = std.unicode.utf8Encode(codepoint, &encoded) catch return null;
        if (size > output.len - target) return null;
        @memcpy(output[target .. target + size], encoded[0..size]);
        target += size;
    }
    return target;
}

fn addCMapEntry(font_object: u32, source: SourceCode, destination: []const u8, cmap_count: *usize) ExtractError!void {
    if (cmap_count.* >= cmap_entries.len) return error.TooManyCMapEntries;
    var entry = CMapEntry{ .font_object = font_object, .source = source.value, .source_len = source.len, .utf8_len = 0 };
    const size = utf16HexToUtf8(destination, &entry.utf8) orelse return;
    entry.utf8_len = @intCast(size);
    cmap_entries[cmap_count.*] = entry;
    cmap_count.* += 1;
}

fn parseCMap(font: *Font, bytes: []const u8, cmap_count: *usize) ExtractError!void {
    font.cmap_start = cmap_count.*;
    var lexer = Lexer{ .input = bytes };
    var mode: enum { none, bfchar, bfrange } = .none;
    var pending: [3]Token = undefined;
    var pending_count: usize = 0;
    while (lexer.next()) |token| {
        if (token.kind == .word) {
            if (std.mem.eql(u8, token.bytes, "beginbfchar")) {
                mode = .bfchar;
                pending_count = 0;
                continue;
            }
            if (std.mem.eql(u8, token.bytes, "endbfchar")) {
                mode = .none;
                pending_count = 0;
                continue;
            }
            if (std.mem.eql(u8, token.bytes, "beginbfrange")) {
                mode = .bfrange;
                pending_count = 0;
                continue;
            }
            if (std.mem.eql(u8, token.bytes, "endbfrange")) {
                mode = .none;
                pending_count = 0;
                continue;
            }
        }
        if (token.kind != .hex_string or mode == .none) continue;
        pending[pending_count] = token;
        pending_count += 1;
        if (mode == .bfchar and pending_count == 2) {
            if (sourceCode(pending[0].bytes)) |source| try addCMapEntry(font.object_number, source, pending[1].bytes, cmap_count);
            pending_count = 0;
        } else if (mode == .bfrange and pending_count == 3) {
            const start = sourceCode(pending[0].bytes);
            const end = sourceCode(pending[1].bytes);
            if (start != null and end != null and start.?.len == end.?.len and end.?.value >= start.?.value and
                end.?.value - start.?.value <= 4096)
            {
                var destination_bytes: [8]u8 = undefined;
                const destination_len = decodeHexBytes(pending[2].bytes, &destination_bytes) orelse 0;
                if (destination_len == 2) {
                    const destination_start = std.mem.readInt(u16, destination_bytes[0..2], .big);
                    var source_value = start.?.value;
                    while (source_value <= end.?.value) : (source_value += 1) {
                        const destination_value = @as(u32, destination_start) + source_value - start.?.value;
                        if (destination_value <= 0xffff) {
                            var destination_token: [6]u8 = undefined;
                            destination_token[0] = '<';
                            const digits = "0123456789ABCDEF";
                            destination_token[1] = digits[(destination_value >> 12) & 0xf];
                            destination_token[2] = digits[(destination_value >> 8) & 0xf];
                            destination_token[3] = digits[(destination_value >> 4) & 0xf];
                            destination_token[4] = digits[destination_value & 0xf];
                            destination_token[5] = '>';
                            try addCMapEntry(font.object_number, .{ .value = source_value, .len = start.?.len }, &destination_token, cmap_count);
                        }
                    }
                }
            }
            pending_count = 0;
        }
    }
    font.cmap_count = cmap_count.* - font.cmap_start;
}

fn buildCMaps(object_count: usize, font_count: usize) ExtractError!usize {
    var cmap_count: usize = 0;
    var index: usize = 0;
    while (index < font_count) : (index += 1) {
        const reference = fonts[index].to_unicode orelse continue;
        const object = findObject(object_count, reference) orelse continue;
        const decoded = decodeStream(object) catch continue;
        try parseCMap(&fonts[index], decoded, &cmap_count);
    }
    return cmap_count;
}

fn winAnsi(byte: u8) u21 {
    const special = [_]u21{
        0x20ac, 0xfffd, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
        0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0xfffd, 0x017d, 0xfffd,
        0xfffd, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
        0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0xfffd, 0x017e, 0x0178,
    };
    if (byte >= 0x80 and byte <= 0x9f) return special[byte - 0x80];
    return byte;
}

const Matrix = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    fn point(self: Matrix, x: f32, y: f32) struct { x: f32, y: f32 } {
        return .{ .x = self.a * x + self.c * y + self.e, .y = self.b * x + self.d * y + self.f };
    }
};

fn multiply(left: Matrix, right: Matrix) Matrix {
    return .{
        .a = left.a * right.a + left.c * right.b,
        .b = left.b * right.a + left.d * right.b,
        .c = left.a * right.c + left.c * right.d,
        .d = left.b * right.c + left.d * right.d,
        .e = left.a * right.e + left.c * right.f + left.e,
        .f = left.b * right.e + left.d * right.f + left.f,
    };
}

const Glyph = struct {
    codepoint: u21,
    x: f32,
    y: f32,
    width: f32,
    size: f32,
    source_order: u32,
    run_id: u32,
};

const TextState = struct {
    matrix: Matrix = .{},
    line_matrix: Matrix = .{},
    font: ?*Font = null,
    font_size: f32 = 12,
    leading: f32 = 0,
    char_spacing: f32 = 0,
    word_spacing: f32 = 0,
    horizontal_scale: f32 = 1,
    rise: f32 = 0,
};

fn estimateAdvance(codepoint: u21, state: TextState) f32 {
    const factor: f32 = if (codepoint == ' ') 0.28 else if (codepoint >= 0x2e80) 1 else 0.52;
    return (state.font_size * factor + state.char_spacing + if (codepoint == ' ') state.word_spacing else 0) * state.horizontal_scale;
}

fn appendGlyph(codepoint: u21, ctm: Matrix, state: TextState, glyph_count: *usize, source_order: *u32, run_id: u32) ExtractError!void {
    if (codepoint == 0 or codepoint == '\r' or codepoint == '\n') return;
    const text_point = state.matrix.point(0, state.rise);
    const page_point = ctm.point(text_point.x, text_point.y);
    const width = @abs(estimateAdvance(codepoint, state));
    const lookback = @min(glyph_count.*, 12);
    var prior = glyph_count.*;
    var checked: usize = 0;
    while (checked < lookback) : (checked += 1) {
        prior -= 1;
        const glyph = glyphs[prior];
        if (glyph.codepoint == codepoint and @abs(glyph.x - page_point.x) < 0.15 and @abs(glyph.y - page_point.y) < 0.15) return;
    }
    if (glyph_count.* >= glyphs.len) return error.TooManyGlyphs;
    glyphs[glyph_count.*] = .{
        .codepoint = codepoint,
        .x = page_point.x,
        .y = page_point.y,
        .width = width,
        .size = @max(1, @abs(state.font_size)),
        .source_order = source_order.*,
        .run_id = run_id,
    };
    glyph_count.* += 1;
    source_order.* += 1;
}

fn translateText(state: *TextState, distance: f32) void {
    state.matrix.e += state.matrix.a * distance;
    state.matrix.f += state.matrix.b * distance;
}

fn cmapMatch(font: *const Font, raw: []const u8, offset: usize) ?struct { bytes: []const u8, consumed: usize } {
    var length: usize = 1;
    while (length <= 4 and offset + length <= raw.len) : (length += 1) {
        var source: u32 = 0;
        for (raw[offset .. offset + length]) |byte| source = (source << 8) | byte;
        var index = font.cmap_start;
        while (index < font.cmap_start + font.cmap_count) : (index += 1) {
            const entry = &cmap_entries[index];
            if (entry.source_len == length and entry.source == source) return .{
                .bytes = entry.utf8[0..entry.utf8_len],
                .consumed = length,
            };
        }
    }
    return null;
}

fn decodePdfString(token: Token, output: []u8) ?usize {
    if (token.kind == .hex_string) return decodeHexBytes(token.bytes, output);
    if (token.kind != .string or token.bytes.len < 2) return null;
    var source: usize = 1;
    var target: usize = 0;
    const end = token.bytes.len - 1;
    while (source < end) {
        var byte = token.bytes[source];
        source += 1;
        if (byte == '\\') {
            if (source >= end) break;
            byte = token.bytes[source];
            source += 1;
            switch (byte) {
                'n' => byte = '\n',
                'r' => byte = '\r',
                't' => byte = '\t',
                'b' => byte = 0x08,
                'f' => byte = 0x0c,
                '\r' => {
                    if (source < end and token.bytes[source] == '\n') source += 1;
                    continue;
                },
                '\n' => continue,
                '0'...'7' => {
                    var value: u16 = byte - '0';
                    var digits: usize = 1;
                    while (digits < 3 and source < end and token.bytes[source] >= '0' and token.bytes[source] <= '7') {
                        value = value * 8 + token.bytes[source] - '0';
                        source += 1;
                        digits += 1;
                    }
                    byte = @truncate(value);
                },
                else => {},
            }
        }
        if (target >= output.len) return null;
        output[target] = byte;
        target += 1;
    }
    return target;
}

fn showString(token: Token, ctm: Matrix, state: *TextState, glyph_count: *usize, source_order: *u32, run_id: u32) ExtractError!void {
    var raw_buffer: [8192]u8 = undefined;
    const raw_len = decodePdfString(token, &raw_buffer) orelse return error.InvalidPdf;
    const raw = raw_buffer[0..raw_len];
    var offset: usize = 0;
    while (offset < raw.len) {
        if (state.font) |font| {
            if (font.cmap_count > 0) {
                if (cmapMatch(font, raw, offset)) |mapping| {
                    var view = std.unicode.Utf8View.init(mapping.bytes) catch return error.InvalidPdf;
                    var iterator = view.iterator();
                    while (iterator.nextCodepoint()) |codepoint| {
                        try appendGlyph(codepoint, ctm, state.*, glyph_count, source_order, run_id);
                        translateText(state, estimateAdvance(codepoint, state.*));
                    }
                    offset += mapping.consumed;
                    continue;
                }
            }
            if (font.identity and offset + 2 <= raw.len) {
                try appendGlyph(0xfffd, ctm, state.*, glyph_count, source_order, run_id);
                translateText(state, estimateAdvance(0xfffd, state.*));
                offset += 2;
                continue;
            }
        }
        const codepoint = winAnsi(raw[offset]);
        try appendGlyph(codepoint, ctm, state.*, glyph_count, source_order, run_id);
        translateText(state, estimateAdvance(codepoint, state.*));
        offset += 1;
    }
}

fn numberAt(stack: []const Token, index: usize) ?f32 {
    if (index >= stack.len or stack[index].kind != .number) return null;
    return stack[index].number;
}

fn matrixAt(stack: []const Token, start: usize) ?Matrix {
    if (start + 6 > stack.len) return null;
    const a = numberAt(stack, start) orelse return null;
    const b = numberAt(stack, start + 1) orelse return null;
    const c = numberAt(stack, start + 2) orelse return null;
    const d = numberAt(stack, start + 3) orelse return null;
    const e = numberAt(stack, start + 4) orelse return null;
    const f = numberAt(stack, start + 5) orelse return null;
    return .{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f };
}

fn nextLine(state: *TextState) void {
    state.line_matrix.e -= state.line_matrix.c * state.leading;
    state.line_matrix.f -= state.line_matrix.d * state.leading;
    state.matrix = state.line_matrix;
}

fn processContent(bytes: []const u8, font_count: usize, resource_count: usize, glyph_count: *usize, source_order: *u32) ExtractError!void {
    var lexer = Lexer{ .input = bytes };
    var stack: [256]Token = undefined;
    var stack_count: usize = 0;
    var array_depth: usize = 0;
    var ctm = Matrix{};
    var graphics_stack: [32]Matrix = undefined;
    var graphics_depth: usize = 0;
    var state = TextState{};
    var run_id: u32 = 0;

    while (lexer.next()) |token| {
        if (token.kind == .array_open) {
            array_depth += 1;
            if (stack_count >= stack.len) return error.InvalidPdf;
            stack[stack_count] = token;
            stack_count += 1;
            continue;
        }
        if (token.kind == .array_close) {
            if (array_depth == 0) return error.InvalidPdf;
            array_depth -= 1;
            if (stack_count >= stack.len) return error.InvalidPdf;
            stack[stack_count] = token;
            stack_count += 1;
            continue;
        }
        if (token.kind != .word or array_depth > 0) {
            if (stack_count >= stack.len) return error.InvalidPdf;
            stack[stack_count] = token;
            stack_count += 1;
            continue;
        }

        const operator = token.bytes;
        if (std.mem.eql(u8, operator, "q")) {
            if (graphics_depth >= graphics_stack.len) return error.InvalidPdf;
            graphics_stack[graphics_depth] = ctm;
            graphics_depth += 1;
        } else if (std.mem.eql(u8, operator, "Q")) {
            if (graphics_depth == 0) return error.InvalidPdf;
            graphics_depth -= 1;
            ctm = graphics_stack[graphics_depth];
        } else if (std.mem.eql(u8, operator, "cm") and stack_count >= 6) {
            const start = stack_count - 6;
            if (matrixAt(stack[0..stack_count], start)) |matrix| ctm = multiply(ctm, matrix);
        } else if (std.mem.eql(u8, operator, "BT")) {
            state.matrix = .{};
            state.line_matrix = .{};
        } else if (std.mem.eql(u8, operator, "Tf") and stack_count >= 2) {
            const name = stack[stack_count - 2];
            const size = stack[stack_count - 1];
            if (name.kind == .name and size.kind == .number) {
                state.font = fontForResource(font_count, resource_count, name.bytes);
                state.font_size = size.number;
            }
        } else if (std.mem.eql(u8, operator, "Tm") and stack_count >= 6) {
            const start = stack_count - 6;
            if (matrixAt(stack[0..stack_count], start)) |matrix| {
                state.matrix = matrix;
                state.line_matrix = state.matrix;
            }
        } else if ((std.mem.eql(u8, operator, "Td") or std.mem.eql(u8, operator, "TD")) and stack_count >= 2) {
            const tx = numberAt(stack[0..stack_count], stack_count - 2);
            const ty = numberAt(stack[0..stack_count], stack_count - 1);
            if (tx != null and ty != null) {
                state.line_matrix.e += state.line_matrix.a * tx.? + state.line_matrix.c * ty.?;
                state.line_matrix.f += state.line_matrix.b * tx.? + state.line_matrix.d * ty.?;
                state.matrix = state.line_matrix;
                if (std.mem.eql(u8, operator, "TD")) state.leading = -ty.?;
            }
        } else if (std.mem.eql(u8, operator, "T*")) {
            nextLine(&state);
        } else if (std.mem.eql(u8, operator, "TL") and stack_count >= 1) {
            if (numberAt(stack[0..stack_count], stack_count - 1)) |value| state.leading = value;
        } else if (std.mem.eql(u8, operator, "Tc") and stack_count >= 1) {
            if (numberAt(stack[0..stack_count], stack_count - 1)) |value| state.char_spacing = value;
        } else if (std.mem.eql(u8, operator, "Tw") and stack_count >= 1) {
            if (numberAt(stack[0..stack_count], stack_count - 1)) |value| state.word_spacing = value;
        } else if (std.mem.eql(u8, operator, "Tz") and stack_count >= 1) {
            if (numberAt(stack[0..stack_count], stack_count - 1)) |value| state.horizontal_scale = value / 100;
        } else if (std.mem.eql(u8, operator, "Ts") and stack_count >= 1) {
            if (numberAt(stack[0..stack_count], stack_count - 1)) |value| state.rise = value;
        } else if (std.mem.eql(u8, operator, "Tj") and stack_count >= 1) {
            const string = stack[stack_count - 1];
            if (string.kind == .string or string.kind == .hex_string) {
                try showString(string, ctm, &state, glyph_count, source_order, run_id);
                run_id +%= 1;
            }
        } else if (std.mem.eql(u8, operator, "TJ")) {
            var index: usize = 0;
            while (index < stack_count) : (index += 1) {
                const item = stack[index];
                if (item.kind == .string or item.kind == .hex_string) {
                    try showString(item, ctm, &state, glyph_count, source_order, run_id);
                } else if (item.kind == .number) {
                    if (item.number < -180) try appendGlyph(' ', ctm, state, glyph_count, source_order, run_id);
                    translateText(&state, -item.number / 1000 * state.font_size * state.horizontal_scale);
                }
            }
            run_id +%= 1;
        } else if (std.mem.eql(u8, operator, "'") and stack_count >= 1) {
            nextLine(&state);
            const string = stack[stack_count - 1];
            if (string.kind == .string or string.kind == .hex_string) {
                try showString(string, ctm, &state, glyph_count, source_order, run_id);
                run_id +%= 1;
            }
        } else if (std.mem.eql(u8, operator, "\"") and stack_count >= 3) {
            if (numberAt(stack[0..stack_count], stack_count - 3)) |value| state.word_spacing = value;
            if (numberAt(stack[0..stack_count], stack_count - 2)) |value| state.char_spacing = value;
            nextLine(&state);
            const string = stack[stack_count - 1];
            if (string.kind == .string or string.kind == .hex_string) {
                try showString(string, ctm, &state, glyph_count, source_order, run_id);
                run_id +%= 1;
            }
        }
        stack_count = 0;
    }
}

fn glyphLess(_: void, left: Glyph, right: Glyph) bool {
    if (@abs(left.y - right.y) > 0.25) return left.y > right.y;
    return left.source_order < right.source_order;
}

fn isTextSpace(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == 0x00a0;
}

fn writePage(out: *Output, glyph_count: usize) ExtractError!void {
    if (glyph_count == 0) return;
    std.sort.block(Glyph, glyphs[0..glyph_count], {}, glyphLess);
    var index: usize = 0;
    var line_y = glyphs[0].y;
    var line_size = glyphs[0].size;
    var prior_x_end = glyphs[0].x;
    var prior_run = glyphs[0].run_id;
    var prior_was_space = true;
    var previous_line_y: ?f32 = null;
    var line_has_text = false;
    while (index < glyph_count) : (index += 1) {
        const glyph = glyphs[index];
        const tolerance = @max(1.0, @max(line_size, glyph.size) * 0.35);
        if (@abs(glyph.y - line_y) > tolerance) {
            if (line_has_text) {
                out.trimSpaces();
                try out.byte('\n');
                if (previous_line_y) |previous| {
                    if (@abs(previous - line_y) > line_size * 1.8) try out.byte('\n');
                }
                previous_line_y = line_y;
            }
            line_y = glyph.y;
            line_size = glyph.size;
            prior_x_end = glyph.x;
            prior_run = glyph.run_id;
            prior_was_space = true;
            line_has_text = false;
        }
        if (glyph.size > line_size) line_size = glyph.size;
        const gap = glyph.x - prior_x_end;
        if (!prior_was_space and !isTextSpace(glyph.codepoint) and glyph.run_id != prior_run and gap > glyph.size * 0.45) try out.byte(' ');
        if (isTextSpace(glyph.codepoint)) {
            if (!prior_was_space) try out.byte(' ');
            prior_was_space = true;
        } else {
            try out.codepoint(glyph.codepoint);
            prior_was_space = false;
            line_has_text = true;
        }
        prior_x_end = @max(prior_x_end, glyph.x + glyph.width);
        prior_run = glyph.run_id;
    }
    if (line_has_text) {
        out.trimSpaces();
        try out.byte('\n');
    }
}

fn extract(input: []const u8) ExtractError!usize {
    if (input.len < 8 or !std.mem.startsWith(u8, input, "%PDF-")) return error.InvalidPdf;
    if (std.mem.indexOf(u8, input, "/Encrypt") != null) return error.EncryptedPdf;
    const object_count = try scanObjects(input);
    if (object_count == 0) return error.InvalidPdf;
    const page_info = try collectPages(object_count);
    const font_info = try collectFonts(object_count);
    _ = try buildCMaps(object_count, font_info.font_count);

    var out = Output{};
    var page_index: usize = 0;
    while (page_index < page_info.page_count) : (page_index += 1) {
        if (page_index > 0) try out.byte(0x0c);
        var glyph_count: usize = 0;
        var source_order: u32 = 0;
        const page = pages[page_index];
        var content_index: usize = 0;
        while (content_index < page.ref_count) : (content_index += 1) {
            const reference = refs[page.ref_start + content_index];
            const content_object = findObject(object_count, reference) orelse continue;
            const content = decodeStream(content_object) catch |err| switch (err) {
                error.UnsupportedStreamFilter => continue,
                else => return err,
            };
            try processContent(content, font_info.font_count, font_info.resource_count, &glyph_count, &source_order);
        }
        try writePage(&out, glyph_count);
    }
    return out.index;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    const size = extract(input_buf[0..input_size]) catch @trap();
    if (size > OUTPUT_CAP) @trap();
    return @intCast(size);
}

export fn render(input_size_u32: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_u32),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "literal strings decode escapes and octal bytes" {
    const source = "(Hello\\nPDF\\040text)";
    const token = Token{ .kind = .string, .bytes = source, .start = 0, .end = source.len };
    var decoded: [64]u8 = undefined;
    const size = decodePdfString(token, &decoded) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Hello\nPDF text", decoded[0..size]);
}

test "WinAnsi maps punctuation and Latin-1" {
    try std.testing.expectEqual(@as(u21, 0x20ac), winAnsi(0x80));
    try std.testing.expectEqual(@as(u21, 0x201c), winAnsi(0x93));
    try std.testing.expectEqual(@as(u21, 0x00e9), winAnsi(0xe9));
}
