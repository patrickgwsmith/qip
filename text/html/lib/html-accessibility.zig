const std = @import("std");

pub const INPUT_CAP: usize = 256 * 1024;
pub const OUTPUT_CAP: usize = 1024 * 1024;
pub const INPUT_CONTENT_TYPE = "text/html";
pub const OUTPUT_CONTENT_TYPE = "text/markdown";

const MAX_ELEMENTS: usize = 2048;
const MAX_CONTENT: usize = 8192;
const MAX_FRAMES: usize = 2048;
const MAX_NODES: usize = 1024;
const MAX_NAME_LEN: usize = 192;
const MAX_ROLE_LEN: usize = 31;
const MAX_LABEL_REFS: usize = 32;

pub var input_buf: [INPUT_CAP]u8 = undefined;
pub var output_buf: [OUTPUT_CAP]u8 = undefined;
var elements_buf: [MAX_ELEMENTS]Element = undefined;
var content_buf: [MAX_CONTENT]Content = undefined;
var frames_buf: [MAX_FRAMES]i32 = undefined;
var nodes_buf: [MAX_NODES]Node = undefined;
var element_node_buf: [MAX_ELEMENTS]i32 = undefined;
var work_buf: [MAX_CONTENT]i32 = undefined;

const Range = struct {
    start: u32 = 0,
    len: u32 = 0,
    present: bool = false,

    fn slice(self: Range, input: []const u8) []const u8 {
        if (!self.present) return "";
        const start: usize = @intCast(self.start);
        const len: usize = @intCast(self.len);
        if (start > input.len or len > input.len - start) return "";
        return input[start .. start + len];
    }
};

const Element = struct {
    parent: i32 = -1,
    parent_content: i32 = -1,
    first_content: i32 = -1,
    last_content: i32 = -1,
    tag: Range = .{},
    id: Range = .{},
    role: Range = .{},
    aria_label: Range = .{},
    aria_labelledby: Range = .{},
    aria_hidden: Range = .{},
    input_type: Range = .{},
    alt: Range = .{},
    value: Range = .{},
    title: Range = .{},
    placeholder: Range = .{},
    aria_placeholder: Range = .{},
    label_for: Range = .{},
    href_present: bool = false,
    hidden_present: bool = false,
};

const ContentKind = enum(u8) { text, element };

const Content = struct {
    kind: ContentKind = .text,
    owner: i32 = -1,
    next: i32 = -1,
    element: i32 = -1,
    text: Range = .{},
};

const RoleKind = enum(u8) {
    standard,
    custom,
};

const Node = struct {
    depth: u16 = 0,
    role_kind: RoleKind = .standard,
    role: [MAX_ROLE_LEN]u8 = undefined,
    role_len: u8 = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: u16 = 0,
};

const RoleInfo = struct {
    present: bool = false,
    suppressed: bool = false,
    label: [MAX_ROLE_LEN]u8 = undefined,
    label_len: u8 = 0,
    name_from_content: bool = false,
    name_prohibited: bool = false,
};

const NameBuffer = struct {
    bytes: [MAX_NAME_LEN]u8 = undefined,
    len: usize = 0,
    needs_space: bool = false,

    fn appendSpace(self: *NameBuffer) void {
        if (self.len > 0) self.needs_space = true;
    }

    fn prepare(self: *NameBuffer, byte_len: usize) bool {
        const separator: usize = if (self.needs_space and self.len > 0) 1 else 0;
        if (byte_len > MAX_NAME_LEN - self.len - separator) return false;
        if (separator == 1) {
            self.bytes[self.len] = ' ';
            self.len += 1;
        }
        self.needs_space = false;
        return true;
    }

    fn appendCodepoint(self: *NameBuffer, cp: u21) void {
        if (isSpaceCodepoint(cp)) {
            self.appendSpace();
            return;
        }
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &encoded) catch return;
        if (!self.prepare(n)) return;
        @memcpy(self.bytes[self.len .. self.len + n], encoded[0..n]);
        self.len += n;
    }

    noinline fn appendUtf8(self: *NameBuffer, bytes: []const u8) void {
        var i: usize = 0;
        var steps: usize = 0;
        while (i < bytes.len and steps < INPUT_CAP + 1) : (steps += 1) {
            if (bytes[i] == '&') {
                var consumed: usize = 0;
                var cp: u21 = 0;
                if (decodeEntity(bytes, i, &consumed, &cp)) {
                    self.appendCodepoint(cp);
                    i += consumed;
                    continue;
                }
            }

            const b = bytes[i];
            if (isSpace(b)) {
                self.appendSpace();
                i += 1;
                continue;
            }

            const sequence_len = utf8SequenceLen(b);
            if (sequence_len > 1 and i + sequence_len <= bytes.len and validUtf8Continuation(bytes[i + 1 .. i + sequence_len])) {
                if (self.prepare(sequence_len)) {
                    @memcpy(self.bytes[self.len .. self.len + sequence_len], bytes[i .. i + sequence_len]);
                    self.len += sequence_len;
                }
                i += sequence_len;
                continue;
            }

            if (self.prepare(1)) {
                self.bytes[self.len] = b;
                self.len += 1;
            }
            i += 1;
        }
        if (i < bytes.len) @trap();
    }
};

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.idx >= output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, bytes: []const u8) void {
        if (self.overflow) return;
        if (bytes.len > output_buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + bytes.len], bytes);
        self.idx += bytes.len;
    }
};

pub fn input_ptr() callconv(.c) u32 {
    return @intCast(@intFromPtr(&input_buf));
}

pub fn input_utf8_cap() callconv(.c) u32 {
    return INPUT_CAP;
}

pub fn output_ptr() callconv(.c) u32 {
    return @intCast(@intFromPtr(&output_buf));
}

pub fn output_utf8_cap() callconv(.c) u32 {
    return OUTPUT_CAP;
}

pub fn input_content_type_ptr() callconv(.c) u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

pub fn input_content_type_size() callconv(.c) u32 {
    return INPUT_CONTENT_TYPE.len;
}

pub fn output_content_type_ptr() callconv(.c) u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

pub fn output_content_type_size() callconv(.c) u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

noinline fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

noinline fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c;
}

fn isSpaceCodepoint(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\r' or cp == '\n' or cp == 0x0c or cp == 0xa0;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == ':';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexValue(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

fn utf8SequenceLen(first: u8) usize {
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

noinline fn validUtf8Continuation(bytes: []const u8) bool {
    var i: usize = 0;
    var fuel: usize = 4;
    while (i < bytes.len and fuel > 0) : ({
        i += 1;
        fuel -= 1;
    }) {
        if ((bytes[i] & 0xc0) != 0x80) return false;
    }
    if (i < bytes.len) @trap();
    return true;
}

noinline fn decodeEntity(input: []const u8, pos: usize, consumed: *usize, cp: *u21) bool {
    if (pos >= input.len or input[pos] != '&') return false;
    var i = pos + 1;
    if (i >= input.len) return false;

    if (input[i] == '#') {
        i += 1;
        var base: u32 = 10;
        if (i < input.len and (input[i] == 'x' or input[i] == 'X')) {
            base = 16;
            i += 1;
        }
        const digit_start = i;
        var value: u32 = 0;
        while (i < input.len and input[i] != ';') : (i += 1) {
            const c = input[i];
            const digit: u32 = if (base == 16)
                (if (isHexDigit(c)) hexValue(c) else return false)
            else
                (if (c >= '0' and c <= '9') c - '0' else return false);
            if (value > (0x10ffff - digit) / base) return false;
            value = value * base + digit;
        }
        if (i >= input.len or input[i] != ';' or i == digit_start) return false;
        if (value == 0 or (value >= 0xd800 and value <= 0xdfff) or value > 0x10ffff) return false;
        consumed.* = i - pos + 1;
        cp.* = @intCast(value);
        return true;
    }

    const named = input[i..];
    const entities = [_]struct { name: []const u8, value: u21 }{
        .{ .name = "amp;", .value = '&' },
        .{ .name = "lt;", .value = '<' },
        .{ .name = "gt;", .value = '>' },
        .{ .name = "quot;", .value = '"' },
        .{ .name = "apos;", .value = '\'' },
        .{ .name = "nbsp;", .value = 0xa0 },
    };
    inline for (entities) |entity| {
        if (std.mem.startsWith(u8, named, entity.name)) {
            consumed.* = entity.name.len + 1;
            cp.* = entity.value;
            return true;
        }
    }
    return false;
}

noinline fn trimStart(bytes: []const u8) usize {
    var i: usize = 0;
    var steps: usize = 0;
    while (i < bytes.len and isSpace(bytes[i])) : (i += 1) {
        if (steps >= INPUT_CAP * 2) @trap();
        steps += 1 + @as(usize, bytes[i] & 1);
    }
    return i;
}

noinline fn trimEnd(bytes: []const u8, start: usize) usize {
    var end = bytes.len;
    var steps: usize = 0;
    while (end > start and isSpace(bytes[end - 1])) : ({
        end -= 1;
        steps += 1;
    }) {
        if (steps >= INPUT_CAP) @trap();
    }
    return end;
}

noinline fn trimmed(bytes: []const u8) []const u8 {
    const start = trimStart(bytes);
    const end = trimEnd(bytes, start);
    return bytes[start..end];
}

fn isTagBytes(name: []const u8, tag: []const u8) bool {
    return eqlIgnoreCase(name, tag);
}

fn elementTag(element_index: usize, input: []const u8) []const u8 {
    return elements_buf[element_index].tag.slice(input);
}

fn elementIs(element_index: usize, input: []const u8, tag: []const u8) bool {
    return isTagBytes(elementTag(element_index, input), tag);
}

fn isVoidElement(tag: []const u8) bool {
    return isTagBytes(tag, "area") or
        isTagBytes(tag, "base") or
        isTagBytes(tag, "br") or
        isTagBytes(tag, "col") or
        isTagBytes(tag, "embed") or
        isTagBytes(tag, "hr") or
        isTagBytes(tag, "img") or
        isTagBytes(tag, "input") or
        isTagBytes(tag, "link") or
        isTagBytes(tag, "meta") or
        isTagBytes(tag, "param") or
        isTagBytes(tag, "source") or
        isTagBytes(tag, "track") or
        isTagBytes(tag, "wbr");
}

fn isRawTextElement(tag: []const u8) bool {
    return isTagBytes(tag, "script") or isTagBytes(tag, "style") or isTagBytes(tag, "textarea") or isTagBytes(tag, "title");
}

fn appendContent(owner: usize, item: Content, content_count: *usize) bool {
    if (content_count.* >= MAX_CONTENT) return false;
    const index = content_count.*;
    content_count.* += 1;
    content_buf[index] = item;
    content_buf[index].owner = @intCast(owner);
    if (elements_buf[owner].last_content >= 0) {
        const last: usize = @intCast(elements_buf[owner].last_content);
        content_buf[last].next = @intCast(index);
    } else {
        elements_buf[owner].first_content = @intCast(index);
    }
    elements_buf[owner].last_content = @intCast(index);
    return true;
}

noinline fn popThroughTag(tag: []const u8, input: []const u8, frame_len: *usize) bool {
    var i = frame_len.*;
    while (i > 0) {
        i -= 1;
        const element_index: usize = @intCast(frames_buf[i]);
        if (!isTagBytes(elementTag(element_index, input), tag)) continue;
        frame_len.* = i;
        return true;
    }
    return false;
}

noinline fn popListItemInScope(input: []const u8, frame_len: *usize) void {
    var i = frame_len.*;
    while (i > 0) {
        i -= 1;
        const open_index: usize = @intCast(frames_buf[i]);
        const open_tag = elementTag(open_index, input);
        if (isTagBytes(open_tag, "ul") or isTagBytes(open_tag, "ol") or isTagBytes(open_tag, "menu")) return;
        if (isTagBytes(open_tag, "li")) {
            frame_len.* = i;
            return;
        }
    }
}

noinline fn popDefinitionItemInScope(input: []const u8, frame_len: *usize) void {
    const limit = frame_len.*;
    var offset: usize = 0;
    var proof: usize = 0;
    while (offset < limit) : (offset += 1) {
        const i = limit - offset - 1;
        const open_index: usize = @intCast(frames_buf[i]);
        if (proof >= MAX_FRAMES * 2) @trap();
        proof += 1 + (open_index & 1);
        const open_tag = elementTag(open_index, input);
        if (isTagBytes(open_tag, "dl")) return;
        if (isTagBytes(open_tag, "dt") or isTagBytes(open_tag, "dd")) {
            frame_len.* = i;
            return;
        }
    }
}

noinline fn popTableCellInScope(input: []const u8, frame_len: *usize) void {
    const limit = frame_len.*;
    var offset: usize = 0;
    var proof: usize = 0;
    while (offset < limit) : (offset += 1) {
        const i = limit - offset - 1;
        const open_index: usize = @intCast(frames_buf[i]);
        if (proof >= MAX_FRAMES * 2) @trap();
        proof += 1 + (open_index & 1);
        const open_tag = elementTag(open_index, input);
        if (isTagBytes(open_tag, "tr") or isTagBytes(open_tag, "table")) return;
        if (isTagBytes(open_tag, "td") or isTagBytes(open_tag, "th")) {
            frame_len.* = i;
            return;
        }
    }
}

noinline fn popTableRowInScope(input: []const u8, frame_len: *usize) void {
    var i = frame_len.*;
    while (i > 0) {
        i -= 1;
        const open_index: usize = @intCast(frames_buf[i]);
        const open_tag = elementTag(open_index, input);
        if (isTagBytes(open_tag, "table") or isTagBytes(open_tag, "tbody") or isTagBytes(open_tag, "thead") or isTagBytes(open_tag, "tfoot")) return;
        if (isTagBytes(open_tag, "tr")) {
            frame_len.* = i;
            return;
        }
    }
}

fn isPClosingStart(tag: []const u8) bool {
    return isTagBytes(tag, "address") or isTagBytes(tag, "article") or isTagBytes(tag, "aside") or
        isTagBytes(tag, "blockquote") or isTagBytes(tag, "div") or isTagBytes(tag, "dl") or
        isTagBytes(tag, "fieldset") or isTagBytes(tag, "footer") or isTagBytes(tag, "form") or
        isTagBytes(tag, "h1") or isTagBytes(tag, "h2") or isTagBytes(tag, "h3") or
        isTagBytes(tag, "h4") or isTagBytes(tag, "h5") or isTagBytes(tag, "h6") or
        isTagBytes(tag, "header") or isTagBytes(tag, "hgroup") or isTagBytes(tag, "hr") or
        isTagBytes(tag, "main") or isTagBytes(tag, "menu") or isTagBytes(tag, "nav") or
        isTagBytes(tag, "ol") or isTagBytes(tag, "p") or isTagBytes(tag, "pre") or
        isTagBytes(tag, "section") or isTagBytes(tag, "table") or isTagBytes(tag, "ul");
}

noinline fn autoCloseForStart(tag: []const u8, input: []const u8, frame_len: *usize) void {
    if (isTagBytes(tag, "li")) {
        popListItemInScope(input, frame_len);
    } else if (isTagBytes(tag, "dt") or isTagBytes(tag, "dd")) {
        popDefinitionItemInScope(input, frame_len);
    } else if (isTagBytes(tag, "option")) {
        _ = popThroughTag("option", input, frame_len);
    } else if (isTagBytes(tag, "optgroup")) {
        _ = popThroughTag("option", input, frame_len);
        _ = popThroughTag("optgroup", input, frame_len);
    } else if (isTagBytes(tag, "tr")) {
        popTableRowInScope(input, frame_len);
    } else if (isTagBytes(tag, "td") or isTagBytes(tag, "th")) {
        popTableCellInScope(input, frame_len);
    }
    if (isPClosingStart(tag)) _ = popThroughTag("p", input, frame_len);
}

fn setAttribute(element: *Element, name: []const u8, value: Range) void {
    if (eqlIgnoreCase(name, "id")) element.id = value else if (eqlIgnoreCase(name, "role")) element.role = value else if (eqlIgnoreCase(name, "aria-label")) element.aria_label = value else if (eqlIgnoreCase(name, "aria-labelledby")) element.aria_labelledby = value else if (eqlIgnoreCase(name, "aria-hidden")) element.aria_hidden = value else if (eqlIgnoreCase(name, "aria-placeholder")) element.aria_placeholder = value else if (eqlIgnoreCase(name, "type")) element.input_type = value else if (eqlIgnoreCase(name, "alt")) element.alt = value else if (eqlIgnoreCase(name, "value")) element.value = value else if (eqlIgnoreCase(name, "title")) element.title = value else if (eqlIgnoreCase(name, "placeholder")) element.placeholder = value else if (eqlIgnoreCase(name, "for")) element.label_for = value else if (eqlIgnoreCase(name, "href")) element.href_present = true else if (eqlIgnoreCase(name, "hidden")) element.hidden_present = true;
}

noinline fn skipSpaces(input: []const u8, start: usize) usize {
    var i = start;
    var fuel: usize = INPUT_CAP + 1;
    while (fuel > 0) : (fuel -= 1) {
        if (i >= input.len or !isSpace(input[i])) return i;
        i += 1;
    }
    @trap();
}

noinline fn scanName(input: []const u8, start: usize) usize {
    var i = start;
    var fuel: usize = INPUT_CAP + 1;
    while (fuel > 0) : (fuel -= 1) {
        if (i >= input.len or !isNameChar(input[i])) return i;
        i += 1;
    }
    @trap();
}

noinline fn scanTokenEnd(input: []const u8, start: usize) usize {
    var i = start;
    var fuel: usize = INPUT_CAP + 1;
    while (fuel > 0) : (fuel -= 1) {
        if (i >= input.len or isSpace(input[i])) return i;
        i += 1;
    }
    @trap();
}

noinline fn scanUnquotedAttributeEnd(input: []const u8, start: usize) usize {
    var i = start;
    var fuel: usize = INPUT_CAP + 1;
    while (fuel > 0) : (fuel -= 1) {
        if (i >= input.len or isSpace(input[i]) or input[i] == '>') return i;
        i += 1;
    }
    @trap();
}

noinline fn scanUntilByte(input: []const u8, start: usize, byte: u8) usize {
    var i = start;
    while (i < input.len and input[i] != byte) : (i += 1) {}
    return i;
}

noinline fn scanTextEnd(input: []const u8, start: usize) usize {
    return scanUntilByte(input, start, '<');
}

noinline fn scanCommentEnd(input: []const u8, start: usize) usize {
    var i = start;
    while (i + 2 < input.len) : (i += 1) {
        if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') return i;
    }
    return input.len;
}

noinline fn findRawClose(input: []const u8, start: usize, tag: []const u8) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (i + 2 + tag.len > input.len) continue;
        if (input[i] != '<' or input[i + 1] != '/') continue;
        if (eqlIgnoreCase(input[i + 2 .. i + 2 + tag.len], tag)) return i;
    }
    return input.len;
}

noinline fn parseStartTagAttributes(input: []const u8, start: usize, element: *Element) ?usize {
    var j = start;
    var fuel = input.len - start + 1;
    while (j < input.len and fuel > 0) : (fuel -= 1) {
        j = skipSpaces(input, j);
        if (j >= input.len) return input.len;
        if (input[j] == '>') return j + 1;
        if (input[j] == '/') {
            j += 1;
            continue;
        }
        const name_start = j;
        j = scanName(input, j);
        if (j == name_start) {
            j += 1;
            continue;
        }
        const name = input[name_start..j];
        j = skipSpaces(input, j);
        var value = Range{ .start = @intCast(j), .len = 0, .present = true };
        if (j < input.len and input[j] == '=') {
            j = skipSpaces(input, j + 1);
            if (j < input.len and (input[j] == '"' or input[j] == '\'')) {
                const quote = input[j];
                const value_start = j + 1;
                j = scanUntilByte(input, value_start, quote);
                value = .{ .start = @intCast(value_start), .len = @intCast(j - value_start), .present = true };
                if (j < input.len) j += 1;
            } else {
                const value_start = j;
                j = scanUnquotedAttributeEnd(input, j);
                value = .{ .start = @intCast(value_start), .len = @intCast(j - value_start), .present = true };
            }
        }
        setAttribute(element, name, value);
    }
    if (j < input.len) @trap();
    return input.len;
}

noinline fn parseDocument(input: []const u8, element_count: *usize, content_count: *usize) bool {
    element_count.* = 0;
    content_count.* = 0;
    var frame_len: usize = 0;
    var i: usize = 0;
    var fuel = input.len + 1;

    while (i < input.len and fuel > 0) : (fuel -= 1) {
        if (frame_len > 0) {
            const top_index: usize = @intCast(frames_buf[frame_len - 1]);
            const top_tag = elementTag(top_index, input);
            if (isRawTextElement(top_tag) and input[i] == '<') {
                const close_pos = findRawClose(input, i, top_tag);
                if (close_pos > i) {
                    if (!elementIs(top_index, input, "script") and !elementIs(top_index, input, "style")) {
                        if (!appendContent(top_index, .{ .kind = .text, .text = .{ .start = @intCast(i), .len = @intCast(close_pos - i), .present = true } }, content_count)) return false;
                    }
                    i = close_pos;
                    continue;
                }
            }
        }

        if (input[i] != '<') {
            const start = i;
            i = scanTextEnd(input, i);
            if (frame_len > 0 and i > start) {
                const owner: usize = @intCast(frames_buf[frame_len - 1]);
                if (!elementIs(owner, input, "script") and !elementIs(owner, input, "style")) {
                    if (!appendContent(owner, .{ .kind = .text, .text = .{ .start = @intCast(start), .len = @intCast(i - start), .present = true } }, content_count)) return false;
                }
            }
            continue;
        }

        if (i + 3 < input.len and input[i + 1] == '!' and input[i + 2] == '-' and input[i + 3] == '-') {
            const j = scanCommentEnd(input, i + 4);
            i = if (j + 2 < input.len) j + 3 else input.len;
            continue;
        }
        if (i + 1 < input.len and (input[i + 1] == '!' or input[i + 1] == '?')) {
            const j = scanUntilByte(input, i + 2, '>');
            i = if (j < input.len) j + 1 else input.len;
            continue;
        }

        var j = i + 1;
        var is_close = false;
        if (j < input.len and input[j] == '/') {
            is_close = true;
            j += 1;
        }
        j = skipSpaces(input, j);
        const tag_start = j;
        j = scanName(input, j);
        if (j == tag_start) {
            i += 1;
            continue;
        }
        const tag = input[tag_start..j];

        if (is_close) {
            j = scanUntilByte(input, j, '>');
            i = if (j < input.len) j + 1 else input.len;
            if (!isVoidElement(tag)) _ = popThroughTag(tag, input, &frame_len);
            continue;
        }

        if (element_count.* >= MAX_ELEMENTS) return false;
        const element_index = element_count.*;
        element_count.* += 1;
        elements_buf[element_index] = .{ .tag = .{ .start = @intCast(tag_start), .len = @intCast(tag.len), .present = true } };
        j = parseStartTagAttributes(input, j, &elements_buf[element_index]) orelse return false;

        autoCloseForStart(tag, input, &frame_len);
        if (frame_len > 0) {
            const parent: usize = @intCast(frames_buf[frame_len - 1]);
            elements_buf[element_index].parent = @intCast(parent);
            const content_index = content_count.*;
            if (!appendContent(parent, .{ .kind = .element, .element = @intCast(element_index) }, content_count)) return false;
            elements_buf[element_index].parent_content = @intCast(content_index);
        }
        if (!isVoidElement(tag)) {
            if (frame_len >= MAX_FRAMES) return false;
            frames_buf[frame_len] = @intCast(element_index);
            frame_len += 1;
        }
        i = j;
    }
    if (i < input.len) return false;
    return true;
}

noinline fn copyRole(info: *RoleInfo, role: []const u8) void {
    const n = @min(role.len, MAX_ROLE_LEN);
    var i: usize = 0;
    while (i < n) : (i += 1) info.label[i] = asciiLower(role[i]);
    info.label_len = @intCast(n);
    info.present = n > 0;
}

fn roleNameFromContent(role: []const u8) bool {
    return eqlIgnoreCase(role, "button") or eqlIgnoreCase(role, "cell") or eqlIgnoreCase(role, "checkbox") or
        eqlIgnoreCase(role, "columnheader") or eqlIgnoreCase(role, "gridcell") or eqlIgnoreCase(role, "heading") or
        eqlIgnoreCase(role, "link") or eqlIgnoreCase(role, "menuitem") or eqlIgnoreCase(role, "menuitemcheckbox") or
        eqlIgnoreCase(role, "menuitemradio") or eqlIgnoreCase(role, "option") or eqlIgnoreCase(role, "radio") or
        eqlIgnoreCase(role, "row") or eqlIgnoreCase(role, "rowheader") or eqlIgnoreCase(role, "switch") or
        eqlIgnoreCase(role, "tab") or eqlIgnoreCase(role, "tooltip") or eqlIgnoreCase(role, "treeitem");
}

fn roleNameProhibited(role: []const u8) bool {
    return eqlIgnoreCase(role, "caption") or eqlIgnoreCase(role, "code") or eqlIgnoreCase(role, "deletion") or
        eqlIgnoreCase(role, "emphasis") or eqlIgnoreCase(role, "generic") or eqlIgnoreCase(role, "insertion") or
        eqlIgnoreCase(role, "mark") or eqlIgnoreCase(role, "paragraph") or eqlIgnoreCase(role, "presentation") or
        eqlIgnoreCase(role, "strong") or eqlIgnoreCase(role, "subscript") or eqlIgnoreCase(role, "suggestion") or
        eqlIgnoreCase(role, "superscript") or eqlIgnoreCase(role, "term") or eqlIgnoreCase(role, "time");
}

fn isRecognizedAriaRole(role: []const u8) bool {
    const roles = [_][]const u8{
        "alert",      "alertdialog", "application", "article",          "banner",        "blockquote",    "button",      "caption",
        "cell",       "checkbox",    "code",        "columnheader",     "combobox",      "complementary", "contentinfo", "definition",
        "deletion",   "dialog",      "directory",   "document",         "emphasis",      "feed",          "figure",      "form",
        "generic",    "grid",        "gridcell",    "group",            "heading",       "img",           "insertion",   "link",
        "list",       "listbox",     "listitem",    "log",              "main",          "mark",          "marquee",     "math",
        "menu",       "menubar",     "menuitem",    "menuitemcheckbox", "menuitemradio", "meter",         "navigation",  "none",
        "note",       "option",      "paragraph",   "presentation",     "progressbar",   "radio",         "radiogroup",  "region",
        "row",        "rowgroup",    "rowheader",   "scrollbar",        "search",        "searchbox",     "separator",   "slider",
        "spinbutton", "status",      "strong",      "subscript",        "suggestion",    "superscript",   "switch",      "tab",
        "table",      "tablist",     "tabpanel",    "term",             "textbox",       "time",          "timer",       "toolbar",
        "tooltip",    "tree",        "treegrid",    "treeitem",
    };
    inline for (roles) |known| {
        if (eqlIgnoreCase(role, known)) return true;
    }
    return false;
}

fn isFocusable(element_index: usize, input: []const u8) bool {
    const tag = elementTag(element_index, input);
    if (isTagBytes(tag, "button") or isTagBytes(tag, "select") or isTagBytes(tag, "textarea")) return true;
    if (isTagBytes(tag, "a") or isTagBytes(tag, "area")) return elements_buf[element_index].href_present;
    if (isTagBytes(tag, "input")) return !eqlIgnoreCase(trimmed(elements_buf[element_index].input_type.slice(input)), "hidden");
    return false;
}

noinline fn explicitRole(element_index: usize, input: []const u8) RoleInfo {
    const raw = elements_buf[element_index].role.slice(input);
    var i: usize = 0;
    var steps: usize = 0;
    while (i < raw.len and steps < INPUT_CAP + 1) : (steps += 1) {
        i = skipSpaces(raw, i);
        const start = i;
        i = scanTokenEnd(raw, i);
        if (i == start) break;
        const token = raw[start..i];
        if (!isRecognizedAriaRole(token)) continue;
        if (eqlIgnoreCase(token, "none") or eqlIgnoreCase(token, "presentation")) {
            if (isFocusable(element_index, input)) return .{};
            return .{ .present = true, .suppressed = true };
        }
        var info = RoleInfo{};
        copyRole(&info, token);
        info.name_from_content = roleNameFromContent(token);
        info.name_prohibited = roleNameProhibited(token);
        return info;
    }
    return .{};
}

noinline fn hasSectioningAncestor(element_index: usize, input: []const u8) bool {
    var parent = elements_buf[element_index].parent;
    var steps: usize = 0;
    while (true) {
        if (steps >= MAX_ELEMENTS * 2) @trap();
        if (parent < 0) return false;
        const p: usize = @intCast(parent);
        const tag = elementTag(p, input);
        if (isTagBytes(tag, "article") or isTagBytes(tag, "aside") or isTagBytes(tag, "main") or isTagBytes(tag, "nav") or isTagBytes(tag, "section")) return true;
        parent = elements_buf[p].parent;
        steps += 1 + (p & 1);
    }
}

fn hasDirectAuthorName(element_index: usize, input: []const u8) bool {
    const element = elements_buf[element_index];
    return trimmed(element.aria_labelledby.slice(input)).len > 0 or
        trimmed(element.aria_label.slice(input)).len > 0 or
        trimmed(element.title.slice(input)).len > 0;
}

fn implicitRole(element_index: usize, input: []const u8) RoleInfo {
    const element = elements_buf[element_index];
    const tag = element.tag.slice(input);
    var label: []const u8 = "";
    if ((isTagBytes(tag, "a") or isTagBytes(tag, "area")) and element.href_present) label = "link" else if (isTagBytes(tag, "button") or isTagBytes(tag, "summary")) label = "button" else if (isTagBytes(tag, "textarea")) label = "textbox" else if (isTagBytes(tag, "select")) label = "combobox" else if (isTagBytes(tag, "option")) label = "option" else if (isTagBytes(tag, "optgroup") or isTagBytes(tag, "address")) label = "group" else if (isTagBytes(tag, "ul") or isTagBytes(tag, "ol") or isTagBytes(tag, "menu")) label = "list" else if (isTagBytes(tag, "li")) label = "listitem" else if (isTagBytes(tag, "main")) label = "main" else if (isTagBytes(tag, "nav")) label = "navigation" else if (isTagBytes(tag, "search")) label = "search" else if (isTagBytes(tag, "header") and !hasSectioningAncestor(element_index, input)) label = "banner" else if (isTagBytes(tag, "footer") and !hasSectioningAncestor(element_index, input)) label = "contentinfo" else if (isTagBytes(tag, "section") and hasDirectAuthorName(element_index, input)) label = "region" else if (isTagBytes(tag, "article")) label = "article" else if (isTagBytes(tag, "aside")) label = "complementary" else if (isTagBytes(tag, "form") and hasDirectAuthorName(element_index, input)) label = "form" else if (isTagBytes(tag, "fieldset")) label = "group" else if (isTagBytes(tag, "figure")) label = "figure" else if (isTagBytes(tag, "table")) label = "table" else if (isTagBytes(tag, "tbody") or isTagBytes(tag, "thead") or isTagBytes(tag, "tfoot")) label = "rowgroup" else if (isTagBytes(tag, "tr")) label = "row" else if (isTagBytes(tag, "th")) label = "columnheader" else if (isTagBytes(tag, "td")) label = "cell" else if (isTagBytes(tag, "dialog")) label = "dialog" else if (isTagBytes(tag, "output")) label = "status" else if (isTagBytes(tag, "meter")) label = "meter" else if (isTagBytes(tag, "progress")) label = "progressbar" else if (isTagBytes(tag, "p")) label = "paragraph" else if (isTagBytes(tag, "h1") or isTagBytes(tag, "h2") or isTagBytes(tag, "h3") or isTagBytes(tag, "h4") or isTagBytes(tag, "h5") or isTagBytes(tag, "h6")) label = "heading" else if (isTagBytes(tag, "img")) {
        const alt = trimmed(element.alt.slice(input));
        const has_override = trimmed(element.aria_label.slice(input)).len > 0 or trimmed(element.aria_labelledby.slice(input)).len > 0;
        if (!element.alt.present or alt.len > 0 or has_override) label = "img";
    } else if (isTagBytes(tag, "input")) {
        const input_type = trimmed(element.input_type.slice(input));
        if (input_type.len == 0 or eqlIgnoreCase(input_type, "text") or eqlIgnoreCase(input_type, "email") or eqlIgnoreCase(input_type, "search") or eqlIgnoreCase(input_type, "tel") or eqlIgnoreCase(input_type, "url") or eqlIgnoreCase(input_type, "password") or eqlIgnoreCase(input_type, "number")) label = "textbox" else if (eqlIgnoreCase(input_type, "checkbox")) label = "checkbox" else if (eqlIgnoreCase(input_type, "radio")) label = "radio" else if (eqlIgnoreCase(input_type, "range")) label = "slider" else if (eqlIgnoreCase(input_type, "button") or eqlIgnoreCase(input_type, "submit") or eqlIgnoreCase(input_type, "reset") or eqlIgnoreCase(input_type, "image")) label = "button";
    }
    var info = RoleInfo{};
    if (label.len > 0) {
        copyRole(&info, label);
        info.name_from_content = roleNameFromContent(label);
        info.name_prohibited = roleNameProhibited(label);
    }
    return info;
}

fn resolveRole(element_index: usize, input: []const u8) RoleInfo {
    if (elements_buf[element_index].role.present) {
        const explicit = explicitRole(element_index, input);
        if (explicit.present) return explicit;
    }
    return implicitRole(element_index, input);
}

fn ariaHiddenTrue(element_index: usize, input: []const u8) bool {
    const value = trimmed(elements_buf[element_index].aria_hidden.slice(input));
    return value.len > 0 and eqlIgnoreCase(value, "true");
}

noinline fn isHidden(element_index: usize, input: []const u8) bool {
    var current: i32 = @intCast(element_index);
    var steps: usize = 0;
    while (true) {
        if (steps >= MAX_ELEMENTS) @trap();
        if (current < 0) return false;
        const index: usize = @intCast(current);
        const tag = elementTag(index, input);
        if (elements_buf[index].hidden_present or ariaHiddenTrue(index, input) or isTagBytes(tag, "script") or isTagBytes(tag, "style")) return true;
        current = elements_buf[index].parent;
        steps += 1;
    }
}

noinline fn findElementById(id: []const u8, input: []const u8, element_count: usize) ?usize {
    var i: usize = 0;
    while (i < element_count) : (i += 1) {
        const candidate = elements_buf[i].id.slice(input);
        if (candidate.len > 0 and bytesEqual(candidate, id)) return i;
    }
    return null;
}

noinline fn isAncestor(ancestor: usize, descendant: usize) bool {
    var current = elements_buf[descendant].parent;
    var steps: usize = 0;
    while (true) {
        if (steps >= MAX_ELEMENTS * 2) @trap();
        if (current < 0) return false;
        if (current == @as(i32, @intCast(ancestor))) return true;
        const index: usize = @intCast(current);
        current = elements_buf[index].parent;
        steps += 1 + (index & 1);
    }
}

noinline fn directChildByTag(element_index: usize, tag: []const u8, input: []const u8) ?usize {
    var content_index = elements_buf[element_index].first_content;
    var steps: usize = 0;
    while (content_index >= 0 and steps < MAX_CONTENT) : (steps += 1) {
        const content = content_buf[@intCast(content_index)];
        if (content.kind == .element) {
            const child: usize = @intCast(content.element);
            if (elementIs(child, input, tag)) return child;
        }
        content_index = content.next;
    }
    return null;
}

fn appendRange(out: *NameBuffer, range: Range, input: []const u8) void {
    out.appendUtf8(range.slice(input));
}

fn appendDirectAlternative(element_index: usize, out: *NameBuffer, input: []const u8) bool {
    const element = elements_buf[element_index];
    if (trimmed(element.aria_label.slice(input)).len > 0) {
        appendRange(out, element.aria_label, input);
        return true;
    }
    const tag = element.tag.slice(input);
    if (isTagBytes(tag, "img") or isTagBytes(tag, "area")) {
        if (element.alt.present) {
            appendRange(out, element.alt, input);
            return true;
        }
    }
    if (isTagBytes(tag, "input")) {
        const input_type = trimmed(element.input_type.slice(input));
        if (eqlIgnoreCase(input_type, "image") and element.alt.present) {
            appendRange(out, element.alt, input);
            return true;
        }
        if (eqlIgnoreCase(input_type, "button") or eqlIgnoreCase(input_type, "submit") or eqlIgnoreCase(input_type, "reset") or input_type.len == 0 or eqlIgnoreCase(input_type, "text")) {
            if (element.value.present and trimmed(element.value.slice(input)).len > 0) {
                appendRange(out, element.value, input);
                return true;
            }
        }
    }
    if (element.title.present and trimmed(element.title.slice(input)).len > 0) {
        appendRange(out, element.title, input);
        return true;
    }
    return false;
}

noinline fn appendSubtreeText(root: usize, skip_element: ?usize, include_hidden: bool, out: *NameBuffer, input: []const u8) void {
    var sp: usize = 0;
    if (elements_buf[root].first_content >= 0) {
        work_buf[sp] = elements_buf[root].first_content;
        sp += 1;
    }
    var steps: usize = 0;
    while (sp > 0 and steps < MAX_CONTENT * 2) : (steps += 1) {
        sp -= 1;
        const content_index: usize = @intCast(work_buf[sp]);
        const content = content_buf[content_index];
        if (content.next >= 0 and sp < MAX_CONTENT) {
            work_buf[sp] = content.next;
            sp += 1;
        }
        if (content.kind == .text) {
            appendRange(out, content.text, input);
            continue;
        }
        const child: usize = @intCast(content.element);
        if (skip_element != null and child == skip_element.?) continue;
        if (!include_hidden and isHidden(child, input)) continue;
        if (elementIs(child, input, "br")) {
            out.appendSpace();
            continue;
        }
        if (appendDirectAlternative(child, out, input)) continue;
        if (elements_buf[child].first_content >= 0 and sp < MAX_CONTENT) {
            work_buf[sp] = elements_buf[child].first_content;
            sp += 1;
        }
    }
}

fn appendReferencedName(element_index: usize, out: *NameBuffer, input: []const u8) void {
    if (appendDirectAlternative(element_index, out, input)) return;
    appendSubtreeText(element_index, null, true, out, input);
}

noinline fn appendLabelledby(element_index: usize, out: *NameBuffer, input: []const u8, element_count: usize) bool {
    const raw = elements_buf[element_index].aria_labelledby.slice(input);
    if (trimmed(raw).len == 0) return false;
    var seen: [MAX_LABEL_REFS]i32 = undefined;
    var seen_len: usize = 0;
    var found_reference = false;
    var reference_count: usize = 0;
    var i: usize = 0;
    var steps: usize = 0;
    while (i < raw.len and steps < INPUT_CAP + 1) : (steps += 1) {
        i = skipSpaces(raw, i);
        const start = i;
        i = scanTokenEnd(raw, i);
        if (i == start) break;
        const referenced = findElementById(raw[start..i], input, element_count) orelse continue;
        var duplicate = false;
        var s: usize = 0;
        while (s < seen_len) : (s += 1) {
            if (seen[s] == @as(i32, @intCast(referenced))) duplicate = true;
        }
        if (duplicate) continue;
        found_reference = true;
        if (seen_len < MAX_LABEL_REFS) {
            seen[seen_len] = @intCast(referenced);
            seen_len += 1;
        }
        if (reference_count > 0) out.appendSpace();
        appendReferencedName(referenced, out, input);
        reference_count += 1;
    }
    return found_reference;
}

noinline fn appendAssociatedLabels(element_index: usize, out: *NameBuffer, input: []const u8, element_count: usize) bool {
    const target_id = elements_buf[element_index].id.slice(input);
    var appended = false;
    var i: usize = 0;
    while (i < element_count) : (i += 1) {
        if (!elementIs(i, input, "label")) continue;
        const label_for = elements_buf[i].label_for.slice(input);
        const explicit = elements_buf[i].label_for.present and target_id.len > 0 and bytesEqual(label_for, target_id);
        const wrapping = !elements_buf[i].label_for.present and isAncestor(i, element_index);
        if (!explicit and !wrapping) continue;
        const before = out.len;
        appendSubtreeText(i, element_index, false, out, input);
        if (out.len > before) appended = true;
    }
    return appended;
}

noinline fn computeName(element_index: usize, role: RoleInfo, out: *NameBuffer, input: []const u8, element_count: usize) void {
    out.* = .{};
    const element = elements_buf[element_index];
    const tag = element.tag.slice(input);

    if (!role.name_prohibited) {
        if (appendLabelledby(element_index, out, input, element_count)) return;
        if (trimmed(element.aria_label.slice(input)).len > 0) {
            appendRange(out, element.aria_label, input);
            return;
        }
    }

    const is_input = isTagBytes(tag, "input");
    const is_form_control = is_input or isTagBytes(tag, "textarea") or isTagBytes(tag, "select") or isTagBytes(tag, "button") or isTagBytes(tag, "output") or isTagBytes(tag, "meter") or isTagBytes(tag, "progress");
    if (is_form_control and appendAssociatedLabels(element_index, out, input, element_count)) return;

    if (is_input) {
        const input_type = trimmed(element.input_type.slice(input));
        if (eqlIgnoreCase(input_type, "button") or eqlIgnoreCase(input_type, "submit") or eqlIgnoreCase(input_type, "reset")) {
            if (element.value.present and trimmed(element.value.slice(input)).len > 0) {
                appendRange(out, element.value, input);
                return;
            }
            if (eqlIgnoreCase(input_type, "submit")) {
                out.appendUtf8("Submit");
                return;
            }
            if (eqlIgnoreCase(input_type, "reset")) {
                out.appendUtf8("Reset");
                return;
            }
        } else if (eqlIgnoreCase(input_type, "image")) {
            if (element.alt.present and trimmed(element.alt.slice(input)).len > 0) {
                appendRange(out, element.alt, input);
                return;
            }
            if (element.title.present and trimmed(element.title.slice(input)).len > 0) {
                appendRange(out, element.title, input);
                return;
            }
            out.appendUtf8("Submit");
            return;
        }
        if (element.title.present and trimmed(element.title.slice(input)).len > 0) {
            appendRange(out, element.title, input);
            return;
        }
        if ((input_type.len == 0 or eqlIgnoreCase(input_type, "text") or eqlIgnoreCase(input_type, "email") or eqlIgnoreCase(input_type, "search") or eqlIgnoreCase(input_type, "tel") or eqlIgnoreCase(input_type, "url") or eqlIgnoreCase(input_type, "password") or eqlIgnoreCase(input_type, "number")) and element.placeholder.present) {
            appendRange(out, element.placeholder, input);
            return;
        }
        if ((input_type.len == 0 or eqlIgnoreCase(input_type, "text") or eqlIgnoreCase(input_type, "email") or eqlIgnoreCase(input_type, "search") or eqlIgnoreCase(input_type, "tel") or eqlIgnoreCase(input_type, "url") or eqlIgnoreCase(input_type, "password") or eqlIgnoreCase(input_type, "number")) and element.aria_placeholder.present) {
            appendRange(out, element.aria_placeholder, input);
            return;
        }
    } else if (isTagBytes(tag, "textarea") or isTagBytes(tag, "select")) {
        if (element.title.present and trimmed(element.title.slice(input)).len > 0) {
            appendRange(out, element.title, input);
            return;
        }
        if (isTagBytes(tag, "textarea") and element.placeholder.present) {
            appendRange(out, element.placeholder, input);
            return;
        }
        if (isTagBytes(tag, "textarea") and element.aria_placeholder.present) {
            appendRange(out, element.aria_placeholder, input);
            return;
        }
    } else if (isTagBytes(tag, "img")) {
        if (element.alt.present) {
            appendRange(out, element.alt, input);
            return;
        }
        if (element.title.present) {
            appendRange(out, element.title, input);
            return;
        }
    } else if (isTagBytes(tag, "area")) {
        if (element.alt.present and trimmed(element.alt.slice(input)).len > 0) {
            appendRange(out, element.alt, input);
            return;
        }
    } else if (isTagBytes(tag, "fieldset")) {
        if (directChildByTag(element_index, "legend", input)) |legend| {
            appendSubtreeText(legend, null, false, out, input);
            if (out.len > 0) return;
        }
    } else if (isTagBytes(tag, "table")) {
        if (directChildByTag(element_index, "caption", input)) |caption| {
            appendSubtreeText(caption, null, false, out, input);
            if (out.len > 0) return;
        }
    }

    if (role.name_from_content) {
        appendSubtreeText(element_index, null, false, out, input);
        if (out.len > 0) return;
    }
    if (!role.name_prohibited and element.title.present and trimmed(element.title.slice(input)).len > 0) appendRange(out, element.title, input);
}

noinline fn buildNodes(input: []const u8, element_count: usize) usize {
    @memset(&element_node_buf, -1);
    var node_count: usize = 0;
    var i: usize = 0;
    while (i < element_count) : (i += 1) {
        if (isHidden(i, input)) continue;
        const role = resolveRole(i, input);
        if (!role.present or role.suppressed or node_count >= MAX_NODES) continue;

        const node_index = node_count;
        node_count += 1;
        nodes_buf[node_index] = .{};
        nodes_buf[node_index].role_len = role.label_len;
        @memcpy(nodes_buf[node_index].role[0..role.label_len], role.label[0..role.label_len]);

        var parent = elements_buf[i].parent;
        var parent_steps: usize = 0;
        while (parent >= 0 and parent_steps < MAX_ELEMENTS) : (parent_steps += 1) {
            const parent_index: usize = @intCast(parent);
            const parent_node = element_node_buf[parent_index];
            if (parent_node >= 0) {
                nodes_buf[node_index].depth = nodes_buf[@intCast(parent_node)].depth + 1;
                break;
            }
            parent = elements_buf[parent_index].parent;
        }

        var name = NameBuffer{};
        computeName(i, role, &name, input, element_count);
        // Paragraph and list-item roles do not derive an accessible name from
        // content. Preserve their readable text in this human-facing tree
        // without feeding it back into the accessible-name algorithm.
        if (name.len == 0 and (elementIs(i, input, "p") or elementIs(i, input, "li"))) {
            appendSubtreeText(i, null, false, &name, input);
        }
        nodes_buf[node_index].name_len = @intCast(name.len);
        if (name.len > 0) @memcpy(nodes_buf[node_index].name[0..name.len], name.bytes[0..name.len]);
        element_node_buf[i] = @intCast(node_index);
    }
    return node_count;
}

fn roleRequiresUniqueAccessibleName(role: RoleInfo) bool {
    const name = role.label[0..role.label_len];
    return bytesEqual(name, "button") or bytesEqual(name, "checkbox") or bytesEqual(name, "combobox") or
        bytesEqual(name, "listbox") or bytesEqual(name, "menu") or bytesEqual(name, "menubar") or
        bytesEqual(name, "menuitem") or bytesEqual(name, "menuitemcheckbox") or bytesEqual(name, "menuitemradio") or
        bytesEqual(name, "option") or bytesEqual(name, "radio") or bytesEqual(name, "scrollbar") or
        bytesEqual(name, "searchbox") or bytesEqual(name, "slider") or bytesEqual(name, "spinbutton") or
        bytesEqual(name, "switch") or bytesEqual(name, "tab") or bytesEqual(name, "textbox") or
        bytesEqual(name, "treeitem");
}

fn nearestNavigationAncestor(element_index: usize, input: []const u8) ?usize {
    var current = elements_buf[element_index].parent;
    var steps: usize = 0;
    while (current >= 0 and steps < MAX_ELEMENTS) : (steps += 1) {
        const index: usize = @intCast(current);
        const role = resolveRole(index, input);
        if (role.present and !role.suppressed and bytesEqual(role.label[0..role.label_len], "navigation")) return index;
        current = elements_buf[index].parent;
    }
    return null;
}

/// Uses the same HTML tree construction and accessible-name calculation as
/// this renderer, but checks only non-empty names on exposed interactive
/// controls, page-level h2 headings, plus links within the same navigation
/// landmark. Name uniqueness is a repository policy, not an ARIA conformance
/// requirement.
pub noinline fn accessibleNamesAreUnique(input: []const u8) bool {
    if (input.len > INPUT_CAP) return false;
    var element_count: usize = 0;
    var content_count: usize = 0;
    if (!parseDocument(input, &element_count, &content_count)) return false;

    var named_count: usize = 0;
    var i: usize = 0;
    while (i < element_count) : (i += 1) {
        if (isHidden(i, input)) continue;
        const role = resolveRole(i, input);
        if (!role.present or role.suppressed) continue;
        const role_name = role.label[0..role.label_len];
        const scope: i32 = if (roleRequiresUniqueAccessibleName(role))
            -1
        else if (elementIs(i, input, "h2"))
            -2
        else if (bytesEqual(role_name, "link"))
            @intCast(nearestNavigationAncestor(i, input) orelse continue)
        else
            continue;

        var name = NameBuffer{};
        computeName(i, role, &name, input, element_count);
        if (name.len == 0) continue;
        if (named_count >= MAX_NODES) return false;

        var previous: usize = 0;
        while (previous < named_count) : (previous += 1) {
            if (work_buf[previous] != scope) continue;
            const previous_len: usize = @intCast(nodes_buf[previous].name_len);
            if (previous_len != name.len) continue;
            if (bytesEqual(nodes_buf[previous].name[0..previous_len], name.bytes[0..name.len])) return false;
        }
        nodes_buf[named_count].name_len = @intCast(name.len);
        @memcpy(nodes_buf[named_count].name[0..name.len], name.bytes[0..name.len]);
        work_buf[named_count] = scope;
        named_count += 1;
    }
    return true;
}

fn markdownEscapable(b: u8) bool {
    return b == '\\' or b == '`' or b == '*' or b == '_' or b == '{' or b == '}' or b == '[' or b == ']' or b == '<' or b == '>' or b == '(' or b == ')' or b == '#' or b == '+' or b == '-' or b == '.' or b == '!' or b == '|';
}

noinline fn writeIndent(writer: *Writer, requested_depth: usize) void {
    var depth: usize = 0;
    while (depth < requested_depth) : (depth += 1) writer.writeSlice("  ");
}

noinline fn writeMarkdownName(writer: *Writer, name: []const u8) void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const b = name[i];
        if (markdownEscapable(b)) writer.writeByte('\\');
        writer.writeByte(b);
    }
}

noinline fn renderNode(writer: *Writer, index: usize) void {
    writeIndent(writer, nodes_buf[index].depth);
    writer.writeSlice("- `");
    writer.writeSlice(nodes_buf[index].role[0..nodes_buf[index].role_len]);
    writer.writeByte('`');
    if (nodes_buf[index].name_len > 0) {
        writer.writeSlice(" **");
        writeMarkdownName(writer, nodes_buf[index].name[0..nodes_buf[index].name_len]);
        writer.writeSlice("**");
    }
    writer.writeByte('\n');
}

noinline fn renderNodes(count: usize) u32 {
    var writer = Writer{};
    var i: usize = 0;
    while (i < MAX_NODES) : (i += 1) {
        if (i >= count) break;
        renderNode(&writer, i);
    }
    if (writer.overflow) return 0;
    return @intCast(writer.idx);
}

pub fn render(input_size: u32) callconv(.c) u32 {
    const size: usize = @intCast(input_size);
    if (size > INPUT_CAP) return 0;
    const input = input_buf[0..size];
    var element_count: usize = 0;
    var content_count: usize = 0;
    if (!parseDocument(input, &element_count, &content_count)) return 0;
    return renderNodes(buildNodes(input, element_count));
}

fn expectRender(input: []const u8, expected: []const u8) !void {
    @memcpy(input_buf[0..input.len], input);
    const output_len = render(@intCast(input.len));
    try std.testing.expectEqualStrings(expected, output_buf[0..output_len]);
}

test "void elements, optional end tags, and unmatched end tags preserve tree structure" {
    try expectRender(
        "<main><img alt=Logo><input aria-label=Name><button>After</button></main>",
        "- `main`\n  - `img` **Logo**\n  - `textbox` **Name**\n  - `button` **After**\n",
    );
    try expectRender(
        "<ul><li>One<li>Two</ul>",
        "- `list`\n  - `listitem` **One**\n  - `listitem` **Two**\n",
    );
    try expectRender(
        "<main><section aria-label=Section></span><button>Inside</button></section></main>",
        "- `main`\n  - `region` **Section**\n    - `button` **Inside**\n",
    );
}

test "accessible names follow ARIA and HTML precedence" {
    try expectRender(
        "<span id=visible>Visible label</span><main><button aria-labelledby=visible aria-label=Override>Text</button><label for=email>Email address</label><input id=email placeholder=Fallback><input type=button value=Save><img alt=Logo></main>",
        "- `main`\n  - `button` **Visible label**\n  - `textbox` **Email address**\n  - `button` **Save**\n  - `img` **Logo**\n",
    );
    try expectRender(
        "<main><button aria-label=Save>Visible label</button><button alt=Wrong>Right</button></main>",
        "- `main`\n  - `button` **Save**\n  - `button` **Right**\n",
    );
}

test "ARIA tokens, aria-hidden, contextual landmarks, and markdown escaping" {
    try expectRender(
        "<header>Top</header><main><header><h2>Nested</h2></header><div role='bogus button'>Save *now*</div><div aria-hidden><button>Visible</button></div><div aria-hidden=1><button>Also visible</button></div></main>",
        "- `banner`\n- `main`\n  - `heading` **Nested**\n  - `button` **Save \\*now\\***\n  - `button` **Visible**\n  - `button` **Also visible**\n",
    );
}

test "accessible-name uniqueness uses computed names and ignores empty names" {
    try std.testing.expect(accessibleNamesAreUnique("<main><p>Unnamed paragraph</p><button>Save</button><button>Cancel</button></main>"));
    try std.testing.expect(!accessibleNamesAreUnique("<main><button>Save</button><button aria-label='Save'>Icon</button></main>"));
    try std.testing.expect(accessibleNamesAreUnique("<h2>Open</h2><table><tr><td>Open</td><td>Open</td></tr></table><a href=#>Open</a><a href=/other>Open</a>"));
    try std.testing.expect(!accessibleNamesAreUnique("<nav><a href=/one>Docs</a><a href=/two aria-label=Docs>Other</a></nav>"));
    try std.testing.expect(accessibleNamesAreUnique("<nav aria-label=Primary><a href=/one>Docs</a></nav><nav aria-label=Footer><a href=/two>Docs</a></nav>"));
    try std.testing.expect(!accessibleNamesAreUnique("<h2>API</h2><h2 aria-label=API>Reference</h2>"));
    try std.testing.expect(accessibleNamesAreUnique("<h2>Save</h2><h3>Save</h3><button>Save</button>"));
}

test "current HTML-AAM native roles and labelable elements contribute names" {
    try expectRender(
        "<search aria-label=Products></search><label for=m>Usage</label><meter id=m></meter><label for=p>Loading</label><progress id=p></progress><label for=o>Total</label><output id=o></output>",
        "- `search` **Products**\n- `meter` **Usage**\n- `progressbar` **Loading**\n- `status` **Total**\n",
    );
    try std.testing.expect(accessibleNamesAreUnique("<label for=m>Status</label><meter id=m></meter><output aria-label=Status></output>"));
}
