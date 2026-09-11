const std = @import("std");
const builtin = @import("builtin");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

// A one MiB document cannot contain this many distinct id values: even the
// shortest start tag with an id attribute needs more than eight bytes once the
// finite set of one-byte values has been used. Keeping the table fixed makes
// the component's memory use independent of the input.
const ID_TABLE_CAP: usize = 128 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var id_offsets: [ID_TABLE_CAP]u32 = [_]u32{0} ** ID_TABLE_CAP;
var id_lengths: [ID_TABLE_CAP]u32 = undefined;

const ValidationError = error{
    DuplicateId,
    MalformedHtml,
    IdTableFull,
};

const Range = struct {
    start: usize,
    end: usize,

    fn slice(self: Range, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isTagNameEnd(c: u8) bool {
    return isSpace(c) or c == '/' or c == '>';
}

fn isAttributeNameEnd(c: u8) bool {
    return isSpace(c) or c == '/' or c == '>' or c == '=';
}

fn equalIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn startsWith(input: []const u8, pos: usize, expected: []const u8) bool {
    if (pos > input.len or expected.len > input.len - pos) return false;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (input[pos + i] != expected[i]) return false;
    }
    return true;
}

fn startsWithIgnoreCase(input: []const u8, pos: usize, expected: []const u8) bool {
    if (pos > input.len or expected.len > input.len - pos) return false;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (asciiLower(input[pos + i]) != asciiLower(expected[i])) return false;
    }
    return true;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn digitValue(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

fn decodeUtf8(input: []const u8, index: *usize) ?u21 {
    const i = index.*;
    const first = input[i];
    if (first <= 0x7f) {
        index.* += 1;
        return first;
    }
    const count: usize = if (first >= 0xc2 and first <= 0xdf)
        2
    else if (first >= 0xe0 and first <= 0xef)
        3
    else if (first >= 0xf0 and first <= 0xf4)
        4
    else
        return null;
    if (count > input.len - i) return null;

    var value: u32 = first & (if (count == 2) @as(u8, 0x1f) else if (count == 3) @as(u8, 0x0f) else @as(u8, 0x07));
    var j: usize = 1;
    while (j < count) : (j += 1) {
        const byte = input[i + j];
        if ((byte & 0xc0) != 0x80) return null;
        value = (value << 6) | (byte & 0x3f);
    }
    if ((count == 2 and value < 0x80) or
        (count == 3 and value < 0x800) or
        (count == 4 and value < 0x10000) or
        value > 0x10ffff or
        (value >= 0xd800 and value <= 0xdfff)) return null;
    index.* += count;
    return @intCast(value);
}

fn decodeReference(value: []const u8, index: *usize) ?u21 {
    const start = index.*;
    if (value[start] != '&' or start + 1 >= value.len) return null;
    var i = start + 1;

    if (value[i] == '#') {
        i += 1;
        var base: u32 = 10;
        if (i < value.len and (value[i] == 'x' or value[i] == 'X')) {
            base = 16;
            i += 1;
        }
        const digit_start = i;
        var scalar: u32 = 0;
        while (i < value.len) : (i += 1) {
            const byte = value[i];
            if ((base == 16 and !isHexDigit(byte)) or
                (base == 10 and (byte < '0' or byte > '9'))) break;
            const digit = digitValue(byte);
            if (scalar > (0x10ffff - digit) / base) return null;
            scalar = scalar * base + digit;
        }
        if (i == digit_start) return null;
        if (i < value.len and value[i] == ';') i += 1;
        if (scalar == 0 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) scalar = 0xfffd;
        index.* = i;
        return @intCast(scalar);
    }

    const entities = [_]struct { name: []const u8, scalar: u21 }{
        .{ .name = "amp;", .scalar = '&' },
        .{ .name = "apos;", .scalar = '\'' },
        .{ .name = "gt;", .scalar = '>' },
        .{ .name = "lt;", .scalar = '<' },
        .{ .name = "nbsp;", .scalar = 0x00a0 },
        .{ .name = "quot;", .scalar = '"' },
    };
    inline for (entities) |entity| {
        if (startsWith(value, i, entity.name)) {
            index.* = i + entity.name.len;
            return entity.scalar;
        }
    }
    return null;
}

fn nextIdScalar(value: []const u8, index: *usize) ?u21 {
    if (value[index.*] == '&') {
        const saved = index.*;
        if (decodeReference(value, index)) |scalar| return scalar;
        index.* = saved;
    }
    return decodeUtf8(value, index);
}

fn hashId(value: []const u8) ValidationError!u64 {
    var hash: u64 = 14695981039346656037;
    var i: usize = 0;
    while (i < value.len) {
        const scalar = nextIdScalar(value, &i) orelse return error.MalformedHtml;
        hash ^= scalar;
        hash *%= 1099511628211;
    }
    return hash;
}

fn idsEqual(a: []const u8, b: []const u8) ValidationError!bool {
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (a_index < a.len and b_index < b.len) {
        const a_scalar = nextIdScalar(a, &a_index) orelse return error.MalformedHtml;
        const b_scalar = nextIdScalar(b, &b_index) orelse return error.MalformedHtml;
        if (a_scalar != b_scalar) return false;
    }
    return a_index == a.len and b_index == b.len;
}

fn rememberId(input: []const u8, value_range: Range) ValidationError!void {
    const value = value_range.slice(input);
    const hash = try hashId(value);
    var slot: usize = @intCast(hash & (ID_TABLE_CAP - 1));
    var probes: usize = 0;
    while (probes < ID_TABLE_CAP) : (probes += 1) {
        const offset_plus_one = id_offsets[slot];
        if (offset_plus_one == 0) {
            id_offsets[slot] = @intCast(value_range.start + 1);
            id_lengths[slot] = @intCast(value.len);
            return;
        }
        const old_start: usize = @as(usize, offset_plus_one) - 1;
        const old_len: usize = @intCast(id_lengths[slot]);
        if (try idsEqual(input[old_start .. old_start + old_len], value)) return error.DuplicateId;
        slot = (slot + 1) & (ID_TABLE_CAP - 1);
    }
    return error.IdTableFull;
}

fn clearIdTable() void {
    var i: usize = 0;
    while (i < ID_TABLE_CAP) : (i += 1) id_offsets[i] = 0;
}

fn skipSpaces(input: []const u8, index: *usize) void {
    while (index.* < input.len and isSpace(input[index.*])) : (index.* += 1) {}
}

fn skipComment(input: []const u8, start: usize) ValidationError!usize {
    var i = start + 4;
    while (i + 2 < input.len) : (i += 1) {
        if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') return i + 3;
    }
    return error.MalformedHtml;
}

fn skipMarkupDeclaration(input: []const u8, start: usize) ValidationError!usize {
    var i = start + 2;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        const byte = input[i];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            return i + 1;
        }
    }
    return error.MalformedHtml;
}

fn isRawTextTag(tag: []const u8) bool {
    return equalIgnoreCase(tag, "script") or
        equalIgnoreCase(tag, "style") or
        equalIgnoreCase(tag, "textarea") or
        equalIgnoreCase(tag, "title") or
        equalIgnoreCase(tag, "xmp") or
        equalIgnoreCase(tag, "iframe") or
        equalIgnoreCase(tag, "noembed") or
        equalIgnoreCase(tag, "noframes");
}

fn findRawTextEnd(input: []const u8, start: usize, tag: []const u8) usize {
    var i = start;
    while (i + tag.len + 2 <= input.len) : (i += 1) {
        if (input[i] != '<' or input[i + 1] != '/') continue;
        if (!startsWithIgnoreCase(input, i + 2, tag)) continue;
        const after = i + 2 + tag.len;
        if (after == input.len or isTagNameEnd(input[after])) return i;
    }
    return input.len;
}

fn parseStartTag(input: []const u8, start: usize) ValidationError!struct { end: usize, raw_text: bool, plaintext: bool } {
    var i = start + 1;
    const tag_start = i;
    while (i < input.len and !isTagNameEnd(input[i])) : (i += 1) {
        if (input[i] == '<' or input[i] == '\'' or input[i] == '"' or input[i] == '=') return error.MalformedHtml;
    }
    if (i == tag_start) return error.MalformedHtml;
    const tag = input[tag_start..i];

    var saw_id = false;
    while (i < input.len) {
        skipSpaces(input, &i);
        if (i >= input.len) return error.MalformedHtml;
        if (input[i] == '>') {
            return .{ .end = i + 1, .raw_text = isRawTextTag(tag), .plaintext = equalIgnoreCase(tag, "plaintext") };
        }
        if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '>') {
            return .{ .end = i + 2, .raw_text = false, .plaintext = false };
        }

        const name_start = i;
        while (i < input.len and !isAttributeNameEnd(input[i])) : (i += 1) {
            if (input[i] == '<' or input[i] == '\'' or input[i] == '"') return error.MalformedHtml;
        }
        if (i == name_start) return error.MalformedHtml;
        const name = input[name_start..i];
        skipSpaces(input, &i);

        var value = Range{ .start = i, .end = i };
        if (i < input.len and input[i] == '=') {
            i += 1;
            skipSpaces(input, &i);
            if (i >= input.len) return error.MalformedHtml;
            if (input[i] == '\'' or input[i] == '"') {
                const quote = input[i];
                i += 1;
                value.start = i;
                while (i < input.len and input[i] != quote) : (i += 1) {}
                if (i >= input.len) return error.MalformedHtml;
                value.end = i;
                i += 1;
            } else {
                value.start = i;
                while (i < input.len and !isSpace(input[i]) and input[i] != '>') : (i += 1) {
                    if (input[i] == '<' or input[i] == '\'' or input[i] == '"' or input[i] == '=' or input[i] == '`') return error.MalformedHtml;
                }
                value.end = i;
            }
        }

        if (equalIgnoreCase(name, "id")) {
            if (saw_id) return error.DuplicateId;
            saw_id = true;
            try rememberId(input, value);
        }
    }
    return error.MalformedHtml;
}

noinline fn validateUniqueIds(input: []const u8) ValidationError!void {
    clearIdTable();
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        if (startsWith(input, i, "<!--")) {
            i = try skipComment(input, i);
            continue;
        }
        if (i + 1 >= input.len) return error.MalformedHtml;
        if (input[i + 1] == '!' or input[i + 1] == '?') {
            i = try skipMarkupDeclaration(input, i);
            continue;
        }
        if (input[i + 1] == '/') {
            i = try skipMarkupDeclaration(input, i);
            continue;
        }
        if (isSpace(input[i + 1]) or input[i + 1] == '<' or input[i + 1] == '>') {
            i += 1;
            continue;
        }

        const parsed = try parseStartTag(input, i);
        if (parsed.plaintext) return;
        if (parsed.raw_text) {
            const tag_start = i + 1;
            var tag_end = tag_start;
            while (tag_end < input.len and !isTagNameEnd(input[tag_end])) : (tag_end += 1) {}
            i = findRawTextEnd(input, parsed.end, input[tag_start..tag_end]);
        } else {
            i = parsed.end;
        }
    }
}

noinline fn checkedInputSize(input_size: u32) usize {
    if (input_size > INPUT_CAP) @trap();
    return @intCast(input_size);
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = checkedInputSize(input_size_in);
    validateUniqueIds(input_buf[0..input_size]) catch @trap();
    const output_size = input_size_in;
    if (output_size > OUTPUT_CAP) @trap();
    return output_size;
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&input_buf)),
        .failed = 0,
    };
}

test "successful output aliases the unchanged input buffer" {
    if (builtin.target.cpu.arch != .wasm32) return error.SkipZigTest;
    try std.testing.expectEqual(input_ptr(), @intFromPtr(&input_buf));
    try std.testing.expectEqual(input_utf8_cap(), output_utf8_cap());
}

test "accepts unique quoted, unquoted, empty, and case-sensitive id values" {
    try validateUniqueIds("<!doctype html><main ID=one><p id='Two'></p><i id=two><b id></b></main>");
}

test "rejects duplicate ids across elements and on one element" {
    try std.testing.expectError(error.DuplicateId, validateUniqueIds("<main id=content><p id=content></p></main>"));
    try std.testing.expectError(error.DuplicateId, validateUniqueIds("<p id=first ID=second></p>"));
    try std.testing.expectError(error.DuplicateId, validateUniqueIds("<p id><i id=''></i>"));
}

test "compares decoded character references" {
    try std.testing.expectError(error.DuplicateId, validateUniqueIds("<p id='a&amp;b'><i id='a&#38;b'></i>"));
    try std.testing.expectError(error.DuplicateId, validateUniqueIds("<p id='caf&#xE9;'><i id='café'></i>"));
}

test "ignores tag-looking text in comments and raw text elements" {
    try validateUniqueIds("<!-- <p id=x> --><script>const example = '<i id=x>';</script><style>#x { color: red }</style><p id=x></p>");
    try validateUniqueIds("<textarea><p id=x></textarea><p id=x>");
}

test "clears remembered ids between documents" {
    try validateUniqueIds("<p id=reused></p>");
    try validateUniqueIds("<p id=reused></p>");
}

test "rejects unterminated constructs instead of overlooking ids" {
    try std.testing.expectError(error.MalformedHtml, validateUniqueIds("<p id='unterminated>"));
    try std.testing.expectError(error.MalformedHtml, validateUniqueIds("<!-- <p id=x>"));
}
