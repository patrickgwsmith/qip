const std = @import("std");
const warc = @import("lib/warc.zig");

// Applies <qip-main-layout> declarations. A 200 HTML page whose <main>
// contains a <qip-main-layout> with at least one <slot> declares a layout for
// its own path and every path below it. Each page in that scope gets a copy of
// the layout as the content of its <main>: the page's direct <main> children
// with a slot="name" attribute fill the matching <slot name="name">, and the
// rest of <main> fills the unnamed <slot>. Nested layouts compose, outermost
// first, with each inner layout placed in the unnamed slot of the one around
// it. A slot that a page does not fill shows the slot's own content.
//
// Layout mistakes reject the archive at the offending element's input offset
// with one of these modes:
const FAILURE_DUPLICATE_LAYOUT: u32 = 0; // two pages declare a layout for one path
const FAILURE_DUPLICATE_SLOT: u32 = 1; // a layout repeats a slot name, or has two unnamed slots
const FAILURE_MALFORMED_LAYOUT: u32 = 2; // unclosed or nested <qip-main-layout> or <slot>
const FAILURE_OUTER_WITHOUT_UNNAMED_SLOT: u32 = 3; // an outer layout has nowhere to put the inner one
const FAILURE_UNKNOWN_SLOT: u32 = 4; // a page fills a slot that no layout in its chain defines
const FAILURE_UNPLACED_CONTENT: u32 = 5; // a page has content outside slot="…" elements but no unnamed slot
const FAILURE_LIMIT: u32 = 6; // too many layouts, slots, links, or slot-filling elements
const FAILURE_MODES: u32 = 7;

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const LAYOUT_OPEN = "<qip-main-layout";
const LAYOUT_CLOSE = "</qip-main-layout";
const ARIA_CURRENT_PAGE = " aria-current=\"page\"";

const MAX_WARC_RECORDS: usize = 65536;
const MAX_LAYOUTS: usize = 256;
const MAX_CHAIN: usize = 8;
const MAX_SLOTS: usize = 4096;
const MAX_LINKS: usize = 16384;
const TEMPLATE_CAP: usize = 4 * 1024 * 1024;
const MAX_PAGE_PARTS: usize = 2048;

const WARCRecord = struct {
    next: usize,
    header_block: []const u8,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPPayload = struct {
    status: u16,
    status_line: []const u8,
    content_type: []const u8,
    header_block: []const u8,
    body: []const u8,
};

const Range = struct {
    start: usize,
    end: usize,
};

const MainRange = struct {
    open_end: usize,
    close_start: usize,
};

const INDEXED_RECORD_IS_HTML_PAGE: u8 = 1;
const INDEXED_RECORD_HAS_APPLIED_LAYOUT: u8 = 2;

// Offsets are into the input. A page that declares a layout records the
// <qip-main-layout> element so the page's own content can skip it.
const IndexedRecord = struct {
    header_start: u32,
    header_end: u32,
    payload_start: u32,
    payload_end: u32,
    path_start: u32,
    path_end: u32,
    layout_start: u32,
    layout_end: u32,
    flags: u8,
};

comptime {
    if (@sizeOf(IndexedRecord) != 36) @compileError("IndexedRecord must remain compact");
}

const Link = struct {
    href: ?[]const u8,
    // Offset of the anchor's closing '>' in Layout.html.
    insert_at: usize,
};

const Slot = struct {
    // Empty for the unnamed slot.
    name: []const u8,
    // The whole <slot>…</slot> element, and its content, in Layout.html.
    start: usize,
    end: usize,
    fallback_start: usize,
    fallback_end: usize,
};

// Every page in a layout's scope gets the same markup apart from which link is
// aria-current, so the layout is copied once with aria-current removed and
// each page splices ARIA_CURRENT_PAGE in before the matching link's '>'.
const Layout = struct {
    prefix: []const u8,
    input_offset: u32,
    html: []const u8,
    links: []const Link,
    slots: []const Slot,
    has_unnamed_slot: bool,
};

// A run of <main> content. `close` names an element that HTML closed without
// an end tag at `end`; writing "</close>" after the run keeps it closed there
// when the run moves.
const PagePart = struct {
    start: usize,
    end: usize,
    close: []const u8 = "",
};

const PageFill = struct {
    name: []const u8,
    part: PagePart,
};

// A page's <main> content split into slot-filling elements and everything else.
const PageContent = struct {
    body: []const u8,
    loose: []const PagePart,
    fills: []const PageFill,
};

var indexed_records: [MAX_WARC_RECORDS]IndexedRecord = undefined;
var layouts: [MAX_LAYOUTS]Layout = undefined;
var layout_count: usize = 0;
var template_buf: [TEMPLATE_CAP]u8 = undefined;
var template_len: usize = 0;
var link_buf: [MAX_LINKS]Link = undefined;
var link_len: usize = 0;
var slot_buf: [MAX_SLOTS]Slot = undefined;
var slot_len: usize = 0;
var loose_buf: [MAX_PAGE_PARTS]PagePart = undefined;
var fill_buf: [MAX_PAGE_PARTS]PageFill = undefined;

const Rejection = struct {
    input_offset: u32,
    mode: u32,
};

var rejection: Rejection = .{ .input_offset = 0, .mode = 0 };

fn reject(input_offset: u32, mode: u32) error{Rejected} {
    rejection = .{ .input_offset = input_offset, .mode = mode };
    return error.Rejected;
}

const Output = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Output) usize {
        return output_buf.len - self.idx;
    }

    pub fn writeSlice(self: *Output, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.remaining() < s.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    pub fn writeUnsigned(self: *Output, value: usize) void {
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(formatted);
    }
};

// Measures what the same calls would write to an Output, so a rewritten body
// has one writer instead of separate length and write functions.
const Counter = struct {
    len: usize = 0,

    pub fn writeSlice(self: *Counter, s: []const u8) void {
        self.len += s.len;
    }
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
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

export fn failure_modes_per_input_offset() u32 {
    return FAILURE_MODES;
}

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

const eqlIgnoreCase = warc.eqlIgnoreCase;
const indexOfIgnoreCase = warc.indexOfIgnoreCase;
const trimASCIIWhitespace = warc.trimASCIIWhitespace;

fn startsWithIgnoreCase(a: []const u8, prefix: []const u8) bool {
    if (a.len < prefix.len) return false;
    return eqlIgnoreCase(a[0..prefix.len], prefix);
}

fn isASCIIWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0c';
}

fn skipASCIIWhitespaceIn(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and isASCIIWhitespace(s[i])) : (i += 1) {}
    return i;
}

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (start >= buf.len) return null;
    if (warc.indexOfPos(buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (warc.indexOfPos(buf, start, "\n\n")) |pos| return pos + 2;
    return null;
}

fn parseUnsigned10(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var value: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn parseStatusCode(status_line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < status_line.len and status_line[i] != ' ') : (i += 1) {}
    if (i >= status_line.len) return null;
    while (i < status_line.len and status_line[i] == ' ') : (i += 1) {}
    const code_start = i;
    while (i < status_line.len and status_line[i] >= '0' and status_line[i] <= '9') : (i += 1) {}
    if (i == code_start) return null;
    const code = parseUnsigned10(status_line[code_start..i]) orelse return null;
    if (code > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(code));
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const header_end = findHeaderEnd(input, start) orelse return null;
    const header_slice = input[start..header_end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimASCIIWhitespace(line);
        line_start = if (nl < header_slice.len) nl + 1 else header_slice.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "WARC-Type")) {
            warc_type = value;
        } else if (eqlIgnoreCase(key, "WARC-Target-URI")) {
            target_uri = value;
        } else if (eqlIgnoreCase(key, "Content-Length")) {
            content_length = parseUnsigned10(value);
        }
    }

    const payload_len = content_length orelse return null;
    if (header_end + payload_len > input.len) return null;
    const payload = input[header_end .. header_end + payload_len];
    var next = header_end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{ .next = next, .header_block = header_slice, .warc_type = warc_type, .target_uri = target_uri, .payload = payload };
}

fn parseHTTPPayload(payload: []const u8) ?HTTPPayload {
    const header_end = findHeaderEnd(payload, 0) orelse return null;
    const header_block = payload[0..header_end];
    var status_line: []const u8 = "";
    var status: ?u16 = null;
    var content_type: []const u8 = "";

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;

        const trimmed = trimASCIIWhitespace(line);
        if (trimmed.len == 0) break;
        if (line_index == 0) {
            status_line = trimmed;
            status = parseStatusCode(trimmed);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = trimASCIIWhitespace(trimmed[0..colon]);
        const value = trimASCIIWhitespace(trimmed[colon + 1 ..]);
        if (eqlIgnoreCase(key, "Content-Type")) {
            content_type = value;
        }
    }

    return .{
        .status = status orelse return null,
        .status_line = status_line,
        .content_type = content_type,
        .header_block = header_block,
        .body = payload[header_end..],
    };
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return trimASCIIWhitespace(content_type[0..end]);
}

fn isHTMLContentType(content_type_raw: []const u8) bool {
    const token = mimeTypeToken(content_type_raw);
    if (token.len == 0) return false;
    return eqlIgnoreCase(token, "text/html") or eqlIgnoreCase(token, "application/xhtml+xml");
}

fn pathFromTargetURI(uri: []const u8) []const u8 {
    if (uri.len == 0) return "/";
    var path = uri;
    if (std.mem.indexOf(u8, uri, "://")) |scheme_sep| {
        const after_scheme = scheme_sep + 3;
        path = if (std.mem.indexOfPos(u8, uri, after_scheme, "/")) |slash_pos| uri[slash_pos..] else "/";
    } else if (startsWithIgnoreCase(uri, "//")) {
        path = if (std.mem.indexOfPos(u8, uri, 2, "/")) |slash_pos| uri[slash_pos..] else "/";
    } else if (uri[0] != '/') {
        path = if (std.mem.indexOfScalar(u8, uri, '/')) |slash_pos| uri[slash_pos..] else "/";
    }
    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, path, '#')) |idx| end = @min(end, idx);
    path = path[0..end];
    if (path.len == 0 or path[0] != '/') return "/";
    return path;
}

// "/docs/" declares the same scope as "/docs".
fn layoutPrefix(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

fn prefixCovers(prefix: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn isTagBoundary(c: u8) bool {
    return c == '>' or c == '/' or isASCIIWhitespace(c);
}

fn findTagEnd(body: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return i;
    }
    return null;
}

// Finds `open` (such as "<slot") followed by a tag boundary, so "<slots" does
// not match.
fn findOpenTag(body: []const u8, open: []const u8, start: usize, end: usize) ?usize {
    var cursor = start;
    while (indexOfIgnoreCase(body, open, cursor)) |idx| {
        if (idx >= end) return null;
        const boundary = idx + open.len;
        if (boundary >= body.len or isTagBoundary(body[boundary])) return idx;
        cursor = boundary;
    }
    return null;
}

const Attribute = struct {
    start: usize,
    end: usize,
    value: []const u8,
};

// Parses the attributes of one open tag, skipping the tag name, so a value or
// a tag named like the attribute does not match.
fn findAttribute(tag: []const u8, attr_name: []const u8) ?Attribute {
    var i: usize = 1;
    while (i < tag.len and !isTagBoundary(tag[i])) : (i += 1) {}
    while (i < tag.len) {
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len or tag[i] == '>') return null;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }
        const attr_start = i;
        while (i < tag.len and tag[i] != '=' and !isTagBoundary(tag[i])) : (i += 1) {}
        const name = tag[attr_start..i];
        var end = i;
        var value: []const u8 = "";
        const eq = skipASCIIWhitespaceIn(tag, i);
        if (eq < tag.len and tag[eq] == '=') {
            var j = skipASCIIWhitespaceIn(tag, eq + 1);
            if (j < tag.len and (tag[j] == '"' or tag[j] == '\'')) {
                const quote = tag[j];
                const value_start = j + 1;
                j = value_start;
                while (j < tag.len and tag[j] != quote) : (j += 1) {}
                value = tag[value_start..j];
                if (j < tag.len) j += 1;
            } else {
                const value_start = j;
                while (j < tag.len and tag[j] != '>' and !isASCIIWhitespace(tag[j])) : (j += 1) {}
                value = tag[value_start..j];
            }
            end = j;
        }
        if (name.len > 0 and eqlIgnoreCase(name, attr_name)) return .{ .start = attr_start, .end = end, .value = value };
        i = if (end > attr_start) end else attr_start + 1;
    }
    return null;
}

fn findMainRange(body: []const u8) ?MainRange {
    const start = findOpenTag(body, "<main", 0, body.len) orelse return null;
    const open_end = findTagEnd(body, start) orelse return null;
    var close_start: ?usize = null;
    var scan = open_end + 1;
    while (indexOfIgnoreCase(body, "</main>", scan)) |idx| {
        close_start = idx;
        scan = idx + 1;
    }
    const close = close_start orelse return null;
    return .{ .open_end = open_end + 1, .close_start = close };
}

fn inputOffset(input: []const u8, slice: []const u8) u32 {
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(input.ptr);
    if (offset > std.math.maxInt(u32)) @trap();
    return @as(u32, @intCast(offset));
}

fn inputOffsetAt(slice: []const u8, index: usize) u32 {
    return inputOffset(&input_buf, slice[index..]);
}

const TemplateBuilder = struct {
    start: usize,

    fn append(self: *TemplateBuilder, s: []const u8, offset: u32) !void {
        _ = self;
        if (s.len > template_buf.len - template_len) return reject(offset, FAILURE_LIMIT);
        @memcpy(template_buf[template_len .. template_len + s.len], s);
        template_len += s.len;
    }

    fn len(self: *const TemplateBuilder) usize {
        return template_len - self.start;
    }
};

// Copies one <qip-main-layout>…</qip-main-layout> element into template_buf
// without aria-current, recording each link and slot.
fn prepareLayout(prefix: []const u8, element: []const u8) !Layout {
    const offset = inputOffsetAt(element, 0);
    if (findOpenTag(element, LAYOUT_OPEN, 1, element.len) != null) return reject(offset, FAILURE_MALFORMED_LAYOUT);

    var builder = TemplateBuilder{ .start = template_len };
    const links_start = link_len;
    var written: usize = 0;
    var cursor: usize = 0;
    while (findOpenTag(element, "<a", cursor, element.len)) |a_start| {
        const open_end = findTagEnd(element, a_start) orelse break;
        const tag = element[a_start .. open_end + 1];
        try builder.append(element[written..a_start], offset);
        if (findAttribute(tag, "aria-current")) |attr| {
            const skip_start = if (attr.start > 0 and isASCIIWhitespace(tag[attr.start - 1])) attr.start - 1 else attr.start;
            try builder.append(tag[0..skip_start], offset);
            try builder.append(tag[attr.end .. tag.len - 1], offset);
        } else {
            try builder.append(tag[0 .. tag.len - 1], offset);
        }
        if (link_len >= link_buf.len) return reject(offset, FAILURE_LIMIT);
        link_buf[link_len] = .{ .href = if (findAttribute(tag, "href")) |attr| attr.value else null, .insert_at = builder.len() };
        link_len += 1;
        try builder.append(">", offset);
        written = open_end + 1;
        cursor = written;
    }
    try builder.append(element[written..], offset);
    const html = template_buf[builder.start..template_len];

    const slots_start = slot_len;
    var has_unnamed_slot = false;
    cursor = 0;
    while (findOpenTag(html, "<slot", cursor, html.len)) |start| {
        const open_end = findTagEnd(html, start) orelse return reject(offset, FAILURE_MALFORMED_LAYOUT);
        const tag = html[start .. open_end + 1];
        const name = if (findAttribute(tag, "name")) |attr| trimASCIIWhitespace(attr.value) else "";
        var slot = Slot{ .name = name, .start = start, .end = open_end + 1, .fallback_start = open_end + 1, .fallback_end = open_end + 1 };
        if (tag[tag.len - 2] != '/') {
            const close = indexOfIgnoreCase(html, "</slot", open_end + 1) orelse return reject(offset, FAILURE_MALFORMED_LAYOUT);
            if (findOpenTag(html, "<slot", open_end + 1, close) != null) return reject(offset, FAILURE_MALFORMED_LAYOUT);
            const close_end = findTagEnd(html, close) orelse return reject(offset, FAILURE_MALFORMED_LAYOUT);
            slot.end = close_end + 1;
            slot.fallback_end = close;
        }
        for (slot_buf[slots_start..slot_len]) |other| {
            if (std.mem.eql(u8, other.name, name)) return reject(offset, FAILURE_DUPLICATE_SLOT);
        }
        if (slot_len >= slot_buf.len) return reject(offset, FAILURE_LIMIT);
        slot_buf[slot_len] = slot;
        slot_len += 1;
        if (name.len == 0) has_unnamed_slot = true;
        cursor = slot.end;
    }

    return .{
        .prefix = prefix,
        .input_offset = offset,
        .html = html,
        .links = link_buf[links_start..link_len],
        .slots = slot_buf[slots_start..slot_len],
        .has_unnamed_slot = has_unnamed_slot,
    };
}

const LayoutElement = struct {
    range: Range,
    declares: bool,
};

// Finds a <qip-main-layout> inside <main>. It declares a layout while it
// still has a <slot>; once applied, its slots are gone.
fn findLayoutElement(body: []const u8, main: MainRange) !?LayoutElement {
    const start = findOpenTag(body, LAYOUT_OPEN, main.open_end, main.close_start) orelse return null;
    const close = indexOfIgnoreCase(body, LAYOUT_CLOSE, start) orelse return reject(inputOffsetAt(body, start), FAILURE_MALFORMED_LAYOUT);
    const close_end = findTagEnd(body, close) orelse return reject(inputOffsetAt(body, start), FAILURE_MALFORMED_LAYOUT);
    if (close_end >= main.close_start) return reject(inputOffsetAt(body, start), FAILURE_MALFORMED_LAYOUT);
    return .{
        .range = .{ .start = start, .end = close_end + 1 },
        .declares = findOpenTag(body, "<slot", start, close) != null,
    };
}

fn isVoidElement(name: []const u8) bool {
    const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
    for (void_elements) |v| {
        if (eqlIgnoreCase(name, v)) return true;
    }
    return false;
}

fn isRawTextElement(name: []const u8) bool {
    return eqlIgnoreCase(name, "script") or eqlIgnoreCase(name, "style") or
        eqlIgnoreCase(name, "textarea") or eqlIgnoreCase(name, "title");
}

fn isOneOf(name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |n| {
        if (eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

// Start tags that close an open <p>.
fn closesP(name: []const u8) bool {
    return isOneOf(name, &.{
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li", "listing", "main", "menu", "nav", "ol",
        "p", "pre", "search", "section", "summary", "table", "ul", "xmp",
    });
}

// Elements that stop the search for an open <p> to close.
fn pScopeBoundary(name: []const u8) bool {
    return isOneOf(name, &.{ "applet", "button", "caption", "marquee", "object", "table", "td", "template", "th" });
}

// Elements that stop the search for an open <li> to close. HTML stops at any
// special element except address, div, and p.
fn liScopeBoundary(name: []const u8) bool {
    return isOneOf(name, &.{
        "article", "aside", "blockquote", "button", "caption", "center", "dd", "details", "dialog", "dir", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "main", "menu", "nav", "ol",
        "pre", "search", "section", "select", "summary", "table", "td", "template", "th", "tr", "ul",
    });
}

fn tagName(tag: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < tag.len and !isTagBoundary(tag[end])) : (end += 1) {}
    return tag[start..end];
}

const MAX_OPEN_ELEMENTS: usize = 512;

const OpenElement = struct {
    name: []const u8,
    // In SVG or MathML, where "/>" closes an element.
    foreign: bool,
};

var open_buf: [MAX_OPEN_ELEMENTS]OpenElement = undefined;

// Splits the content of <main> into direct children with a slot attribute and
// everything else, leaving out the page's own layout declaration.
//
// A stack of open element names finds the direct children. It follows the
// HTML rules that close elements without an end tag where Markdown and
// hand-written pages rely on them: a block start tag closes an open <p>, an
// <li> closes the previous <li>, an end tag closes the elements open inside
// its element, and "/>" closes an element inside <svg> or <math>. An end tag
// with no matching open element is ignored.
const PageScanner = struct {
    body: []const u8,
    open_len: usize = 0,
    loose_len: usize = 0,
    fill_len: usize = 0,
    loose_start: usize,
    fill: ?PageFill = null,

    fn addLoose(self: *PageScanner, start: usize, end: usize, close: []const u8) !void {
        if (end <= start and close.len == 0) return;
        if (self.loose_len >= loose_buf.len) return reject(inputOffsetAt(self.body, start), FAILURE_LIMIT);
        loose_buf[self.loose_len] = .{ .start = start, .end = end, .close = close };
        self.loose_len += 1;
    }

    fn addFill(self: *PageScanner, fill: PageFill) !void {
        if (self.fill_len >= fill_buf.len) return reject(inputOffsetAt(self.body, fill.part.start), FAILURE_LIMIT);
        fill_buf[self.fill_len] = fill;
        self.fill_len += 1;
    }

    // Records the end of a direct child of <main>. An implicit end is where
    // the token that closed it starts.
    fn endDirectChild(self: *PageScanner, name: []const u8, end: usize, implicit: bool) !void {
        const close = if (implicit) name else "";
        if (self.fill) |f| {
            try self.addFill(.{ .name = f.name, .part = .{ .start = f.part.start, .end = end, .close = close } });
            self.fill = null;
            self.loose_start = end;
        } else if (implicit) {
            try self.addLoose(self.loose_start, end, close);
            self.loose_start = end;
        }
    }

    // Pops open elements down to `len`. The element at index `len` closes with
    // its own end tag when `explicit_end` is set.
    fn popTo(self: *PageScanner, len: usize, token_start: usize, explicit_end: ?usize) !void {
        while (self.open_len > len) {
            self.open_len -= 1;
            if (self.open_len != 0) continue;
            const own = self.open_len == len and explicit_end != null;
            try self.endDirectChild(open_buf[0].name, if (own) explicit_end.? else token_start, !own);
        }
    }

    fn push(self: *PageScanner, name: []const u8, foreign: bool, lt: usize) !void {
        if (self.open_len >= open_buf.len) return reject(inputOffsetAt(self.body, lt), FAILURE_LIMIT);
        open_buf[self.open_len] = .{ .name = name, .foreign = foreign };
        self.open_len += 1;
    }

    fn inForeign(self: *const PageScanner) bool {
        return self.open_len > 0 and open_buf[self.open_len - 1].foreign;
    }

    fn findOpen(self: *const PageScanner, name: []const u8, comptime boundary: ?fn ([]const u8) bool) ?usize {
        var i = self.open_len;
        while (i > 0) {
            i -= 1;
            const e = open_buf[i];
            if (e.foreign) return null;
            if (eqlIgnoreCase(e.name, name)) return i;
            if (boundary) |b| {
                if (b(e.name)) return null;
            }
        }
        return null;
    }

    fn startTag(self: *PageScanner, name: []const u8, tag: []const u8, lt: usize) !void {
        const self_closing = tag.len >= 2 and tag[tag.len - 2] == '/';
        if (self.inForeign()) {
            if (!self_closing) try self.push(name, true, lt);
            return;
        }
        if (closesP(name)) {
            if (self.findOpen("p", pScopeBoundary)) |index| try self.popTo(index, lt, null);
        }
        if (eqlIgnoreCase(name, "li")) {
            if (self.findOpen("li", liScopeBoundary)) |index| try self.popTo(index, lt, null);
        }
        if (self.open_len == 0 and self.fill == null) {
            if (findAttribute(tag, "slot")) |attr| {
                try self.addLoose(self.loose_start, lt, "");
                self.fill = .{ .name = trimASCIIWhitespace(attr.value), .part = .{ .start = lt, .end = lt } };
            }
        }
        if (eqlIgnoreCase(name, "svg") or eqlIgnoreCase(name, "math")) {
            if (!self_closing) try self.push(name, true, lt);
        } else if (!isVoidElement(name)) {
            try self.push(name, false, lt);
        }
    }

    fn endTag(self: *PageScanner, name: []const u8, lt: usize, end: usize) !void {
        var i = self.open_len;
        while (i > 0) {
            i -= 1;
            if (eqlIgnoreCase(open_buf[i].name, name)) return self.popTo(i, lt, end);
        }
    }
};

fn scanPage(body: []const u8, main: MainRange, skip: ?Range) !PageContent {
    const content = body[0..main.close_start];
    var scanner = PageScanner{ .body = body, .loose_start = main.open_end };
    var skipped = skip == null;
    var i = main.open_end;
    while (std.mem.indexOfScalarPos(u8, content, i, '<')) |lt| {
        if (skip) |s| {
            if (lt == s.start) {
                // The declaration must be a direct child of <main>.
                if (scanner.open_len != 0 or scanner.fill != null) return reject(inputOffsetAt(body, s.start), FAILURE_MALFORMED_LAYOUT);
                try scanner.addLoose(scanner.loose_start, s.start, "");
                i = s.end;
                scanner.loose_start = i;
                skipped = true;
                continue;
            }
        }
        if (std.mem.startsWith(u8, content[lt..], "<!--")) {
            i = if (warc.indexOfPos(content, lt + 4, "-->")) |close| close + 3 else content.len;
            continue;
        }
        if (lt + 1 >= content.len) break;
        const next = content[lt + 1];
        if (next != '/' and next != '!' and next != '?' and !std.ascii.isAlphabetic(next)) {
            i = lt + 1;
            continue;
        }
        const tag_end = findTagEnd(content, lt) orelse break;
        const tag = content[lt .. tag_end + 1];
        i = tag_end + 1;
        if (next == '!' or next == '?') continue;
        if (next == '/') {
            try scanner.endTag(tagName(tag, 2), lt, i);
            continue;
        }
        const name = tagName(tag, 1);
        try scanner.startTag(name, tag, lt);
        if (isRawTextElement(name) and !scanner.inForeign()) {
            var close_open: [16]u8 = undefined;
            close_open[0] = '<';
            close_open[1] = '/';
            @memcpy(close_open[2 .. 2 + name.len], name);
            const close = indexOfIgnoreCase(content, close_open[0 .. 2 + name.len], i) orelse content.len;
            const end = if (findTagEnd(content, close)) |e| e + 1 else content.len;
            i = end;
            try scanner.endTag(name, close, end);
        } else if (scanner.open_len == 0) {
            // A void or self-closing direct child ends with its start tag.
            if (scanner.fill) |f| {
                try scanner.addFill(.{ .name = f.name, .part = .{ .start = f.part.start, .end = i } });
                scanner.fill = null;
                scanner.loose_start = i;
            }
        }
    }
    if (!skipped) return reject(inputOffsetAt(body, skip.?.start), FAILURE_MALFORMED_LAYOUT);
    try scanner.popTo(0, main.close_start, null);
    try scanner.addLoose(scanner.loose_start, main.close_start, "");
    return .{
        .body = body,
        .loose = loose_buf[0..scanner.loose_len],
        .fills = fill_buf[0..scanner.fill_len],
    };
}

// True when the range holds only whitespace and comments.
fn isBlankHTML(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (isASCIIWhitespace(s[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, s[i..], "<!--")) {
            const close = warc.indexOfPos(s, i + 4, "-->") orelse return true;
            i = close + 3;
        } else {
            return false;
        }
    }
    return true;
}

// The level of the innermost layout in the chain that defines a slot name.
fn slotOwner(chain: []const *const Layout, name: []const u8) ?usize {
    var level = chain.len;
    while (level > 0) {
        level -= 1;
        for (chain[level].slots) |slot| {
            if (std.mem.eql(u8, slot.name, name)) return level;
        }
    }
    return null;
}

fn layoutChain(path: []const u8, buf: *[MAX_CHAIN]*const Layout) []const *const Layout {
    var len: usize = 0;
    for (layouts[0..layout_count]) |*layout| {
        if (!prefixCovers(layout.prefix, path)) continue;
        if (len >= buf.len) @trap();
        // Insertion sort by prefix length puts the outermost layout first.
        var at = len;
        while (at > 0 and buf[at - 1].prefix.len > layout.prefix.len) : (at -= 1) buf[at] = buf[at - 1];
        buf[at] = layout;
        len += 1;
    }
    return buf[0..len];
}

fn validatePage(chain: []const *const Layout, page: PageContent) !void {
    for (chain[0 .. chain.len - 1]) |layout| {
        if (!layout.has_unnamed_slot) return reject(layout.input_offset, FAILURE_OUTER_WITHOUT_UNNAMED_SLOT);
    }
    for (page.fills) |fill| {
        if (slotOwner(chain, fill.name) == null) return reject(inputOffsetAt(page.body, fill.part.start), FAILURE_UNKNOWN_SLOT);
    }
    if (!chain[chain.len - 1].has_unnamed_slot) {
        for (page.loose) |part| {
            if (part.close.len > 0 or !isBlankHTML(page.body[part.start..part.end])) return reject(inputOffsetAt(page.body, part.start), FAILURE_UNPLACED_CONTENT);
        }
    }
}

fn isCurrentLink(link: Link, current_path: []const u8) bool {
    const href = link.href orelse return false;
    return std.mem.eql(u8, href, current_path);
}

fn writeTemplateRange(w: anytype, layout: *const Layout, start: usize, end: usize, current_path: []const u8) void {
    var cursor = start;
    for (layout.links) |link| {
        if (link.insert_at < start or link.insert_at >= end) continue;
        if (!isCurrentLink(link, current_path)) continue;
        w.writeSlice(layout.html[cursor..link.insert_at]);
        w.writeSlice(ARIA_CURRENT_PAGE);
        cursor = link.insert_at;
    }
    w.writeSlice(layout.html[cursor..end]);
}

fn writePart(w: anytype, body: []const u8, part: PagePart) void {
    w.writeSlice(body[part.start..part.end]);
    if (part.close.len == 0) return;
    w.writeSlice("</");
    w.writeSlice(part.close);
    w.writeSlice(">");
}

fn writeLayout(w: anytype, chain: []const *const Layout, level: usize, page: PageContent, current_path: []const u8) void {
    const layout = chain[level];
    var cursor: usize = 0;
    for (layout.slots) |slot| {
        writeTemplateRange(w, layout, cursor, slot.start, current_path);
        cursor = slot.end;
        if (slot.name.len == 0) {
            if (level + 1 < chain.len) {
                writeLayout(w, chain, level + 1, page, current_path);
            } else {
                for (page.loose) |part| writePart(w, page.body, part);
            }
            continue;
        }
        var filled = false;
        if (slotOwner(chain, slot.name) == level) {
            for (page.fills) |fill| {
                if (!std.mem.eql(u8, fill.name, slot.name)) continue;
                writePart(w, page.body, fill.part);
                filled = true;
            }
        }
        if (!filled) writeTemplateRange(w, layout, slot.fallback_start, slot.fallback_end, current_path);
    }
    writeTemplateRange(w, layout, cursor, layout.html.len, current_path);
}

fn writeBody(w: anytype, body: []const u8, main: MainRange, chain: []const *const Layout, page: PageContent, current_path: []const u8) void {
    w.writeSlice(body[0..main.open_end]);
    writeLayout(w, chain, 0, page, current_path);
    w.writeSlice(body[main.close_start..]);
}

const ArchiveIndex = struct {
    records: []const IndexedRecord,
};

fn indexArchive(input: []const u8) !ArchiveIndex {
    layout_count = 0;
    template_len = 0;
    link_len = 0;
    slot_len = 0;
    var record_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;
        if (record_count >= indexed_records.len) @trap();

        var entry = IndexedRecord{
            .header_start = inputOffset(input, record.header_block),
            .header_end = inputOffset(input, record.header_block) + @as(u32, @intCast(record.header_block.len)),
            .payload_start = inputOffset(input, record.payload),
            .payload_end = inputOffset(input, record.payload) + @as(u32, @intCast(record.payload.len)),
            .path_start = 0,
            .path_end = 0,
            .layout_start = 0,
            .layout_end = 0,
            .flags = 0,
        };
        if (eqlIgnoreCase(record.warc_type, "response")) html: {
            const http = parseHTTPPayload(record.payload) orelse break :html;
            if (http.status != 200 or !isHTMLContentType(http.content_type)) break :html;
            const main = findMainRange(http.body) orelse break :html;
            const path = pathFromTargetURI(record.target_uri);
            entry.flags |= INDEXED_RECORD_IS_HTML_PAGE;
            entry.path_start = inputOffset(input, path);
            entry.path_end = entry.path_start + @as(u32, @intCast(path.len));

            const element = try findLayoutElement(http.body, main) orelse break :html;
            if (!element.declares) {
                entry.flags |= INDEXED_RECORD_HAS_APPLIED_LAYOUT;
                break :html;
            }
            const element_html = http.body[element.range.start..element.range.end];
            entry.layout_start = inputOffset(input, element_html);
            entry.layout_end = entry.layout_start + @as(u32, @intCast(element_html.len));
            const prefix = layoutPrefix(path);
            for (layouts[0..layout_count]) |other| {
                if (std.mem.eql(u8, other.prefix, prefix)) return reject(entry.layout_start, FAILURE_DUPLICATE_LAYOUT);
            }
            if (layout_count >= layouts.len) return reject(entry.layout_start, FAILURE_LIMIT);
            layouts[layout_count] = try prepareLayout(prefix, element_html);
            layout_count += 1;
        }
        indexed_records[record_count] = entry;
        record_count += 1;
    }
    for (layouts[0..layout_count]) |layout| {
        var depth: usize = 0;
        for (layouts[0..layout_count]) |other| {
            if (prefixCovers(other.prefix, layout.prefix)) depth += 1;
        }
        if (depth > MAX_CHAIN) return reject(layout.input_offset, FAILURE_LIMIT);
    }
    return .{ .records = indexed_records[0..record_count] };
}

fn indexedWARCRecord(input: []const u8, indexed: IndexedRecord) WARCRecord {
    return .{
        .next = 0,
        .header_block = input[indexed.header_start..indexed.header_end],
        .warc_type = "",
        .target_uri = "",
        .payload = input[indexed.payload_start..indexed.payload_end],
    };
}

fn processWARC(input: []const u8, out: *Output) !void {
    const archive = try indexArchive(input);
    for (archive.records) |indexed| {
        if (out.overflow) break;
        const record = indexedWARCRecord(input, indexed);
        var chain_buf: [MAX_CHAIN]*const Layout = undefined;
        const chain: []const *const Layout = if (layout_count > 0 and
            indexed.flags & INDEXED_RECORD_IS_HTML_PAGE != 0 and
            indexed.flags & INDEXED_RECORD_HAS_APPLIED_LAYOUT == 0)
            layoutChain(input[indexed.path_start..indexed.path_end], &chain_buf)
        else
            &.{};

        if (chain.len == 0) {
            warc.writeRecordHeader(out, record.header_block, record.payload.len, false);
            out.writeSlice(record.payload);
            out.writeSlice("\r\n\r\n");
            continue;
        }

        const current_path = input[indexed.path_start..indexed.path_end];
        const http = parseHTTPPayload(record.payload) orelse @trap();
        const main = findMainRange(http.body) orelse @trap();
        const skip: ?Range = if (indexed.layout_end > indexed.layout_start) .{
            .start = indexed.layout_start - inputOffset(input, http.body),
            .end = indexed.layout_end - inputOffset(input, http.body),
        } else null;
        const page = try scanPage(http.body, main, skip);
        try validatePage(chain, page);

        var counter = Counter{};
        writeBody(&counter, http.body, main, chain, page, current_path);
        const payload_len = warc.httpHeaderRewriteLen(http.header_block, http.status_line, counter.len) + counter.len;
        warc.writeRecordHeader(out, record.header_block, payload_len, true);
        warc.writeRewrittenHTTPHeaders(out, http.header_block, http.status_line, counter.len);
        writeBody(out, http.body, main, chain, page, current_path);
        out.writeSlice("\r\n\r\n");
    }
}

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

const RenderOutcome = struct {
    output_size_or_failure: u32,
    failed: u1,
};

fn renderImpl(input_size_u32: u32) RenderOutcome {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    var out = Output{};
    processWARC(input_buf[0..input_size], &out) catch {
        return .{ .output_size_or_failure = rejection.input_offset * FAILURE_MODES + rejection.mode, .failed = 1 };
    };
    if (out.overflow) @trap();
    if (!warc.validateArchive(output_buf[0..out.idx])) @trap();
    return .{ .output_size_or_failure = @as(u32, @intCast(out.idx)), .failed = 0 };
}

export fn render(input_size_u32: u32) RenderResult {
    const outcome = renderImpl(input_size_u32);
    return .{
        .output_size_or_failure = outcome.output_size_or_failure,
        .output_ptr = if (outcome.failed == 1) 0 else @intCast(@intFromPtr(&output_buf)),
        .failed = outcome.failed,
    };
}

fn appendResponse(out_buf: []u8, cursor: *usize, path: []const u8, html: []const u8) !void {
    var payload_buf: [8192]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n{s}", .{html});
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: http://qip.local{s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ path, cursor.*, payload.len, payload },
    );
    cursor.* += rec.len;
}

fn runTransform(input: []const u8) RenderOutcome {
    @memcpy(input_buf[0..input.len], input);
    return renderImpl(@as(u32, @intCast(input.len)));
}

fn transformed(input: []const u8) ![]const u8 {
    const result = runTransform(input);
    if (result.failed == 1) return error.Rejected;
    return output_buf[0..result.output_size_or_failure];
}

fn expectRejection(input: []const u8, mode: u32) !void {
    const result = runTransform(input);
    try std.testing.expectEqual(@as(u1, 1), result.failed);
    try std.testing.expectEqual(mode, result.output_size_or_failure % FAILURE_MODES);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing: {s}\n", .{needle});
        return error.TestExpectedContains;
    }
}

const DOCS_LAYOUT = "<qip-main-layout><nav class=\"docs-sidebar\"><a href=\"/docs\" aria-current=\"page\">Docs</a> <a href=\"/docs/router\">Router</a></nav><article class=\"docs-content\"><slot></slot></article></qip-main-layout>";

test "applies a layout to the declaring page and the pages below it" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/docs", "<main><h1>Docs</h1>" ++ DOCS_LAYOUT ++ "</main>");
    try appendResponse(&warc_buf, &n, "/docs/router", "<main><h1>Router</h1></main>");
    try appendResponse(&warc_buf, &n, "/docsearch", "<main><h1>Elsewhere</h1></main>");

    const out = try transformed(warc_buf[0..n]);
    try expectContains(out, "<main><qip-main-layout><nav class=\"docs-sidebar\"><a href=\"/docs\" aria-current=\"page\">Docs</a> <a href=\"/docs/router\">Router</a></nav><article class=\"docs-content\"><h1>Docs</h1></article></qip-main-layout></main>");
    try expectContains(out, "<main><qip-main-layout><nav class=\"docs-sidebar\"><a href=\"/docs\">Docs</a> <a href=\"/docs/router\" aria-current=\"page\">Router</a></nav><article class=\"docs-content\"><h1>Router</h1></article></qip-main-layout></main>");
    try expectContains(out, "<main><h1>Elsewhere</h1></main>");
}

test "running the recipe again leaves applied layouts unchanged" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/docs", "<main><h1>Docs</h1>" ++ DOCS_LAYOUT ++ "</main>");
    try appendResponse(&warc_buf, &n, "/docs/router", "<main><h1>Router</h1></main>");

    var first: [16384]u8 = undefined;
    const once = try transformed(warc_buf[0..n]);
    @memcpy(first[0..once.len], once);
    const twice = try transformed(first[0..once.len]);
    try std.testing.expectEqualStrings(first[0..once.len], twice);
}

test "fills named slots from direct children and falls back to slot content" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/guide", "<main><qip-main-layout><article><slot></slot></article><aside><slot name=\"aside\"><p>Ask on Discord.</p></slot></aside></qip-main-layout><p>Intro</p></main>");
    try appendResponse(&warc_buf, &n, "/guide/abi", "<main><h1>ABI</h1><section slot=\"aside\"><p>Version <b>2</b>.</p></section><div><span slot=\"aside\">inline</span></div></main>");

    const out = try transformed(warc_buf[0..n]);
    try expectContains(out, "<main><qip-main-layout><article><p>Intro</p></article><aside><p>Ask on Discord.</p></aside></qip-main-layout></main>");
    try expectContains(out, "<main><qip-main-layout><article><h1>ABI</h1><div><span slot=\"aside\">inline</span></div></article><aside><section slot=\"aside\"><p>Version <b>2</b>.</p></section></aside></qip-main-layout></main>");
}

test "nested layouts compose with the inner layout in the outer unnamed slot" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/docs", "<main>" ++ "<qip-main-layout><nav>outer</nav><slot></slot><footer><slot name=\"note\">none</slot></footer></qip-main-layout>" ++ "<p>Docs</p></main>");
    try appendResponse(&warc_buf, &n, "/docs/spec", "<main><qip-main-layout class=\"spec\"><nav>inner</nav><slot></slot></qip-main-layout><p>Spec</p></main>");
    try appendResponse(&warc_buf, &n, "/docs/spec/abi", "<main><p>ABI</p><p slot=\"note\">v2</p></main>");

    const out = try transformed(warc_buf[0..n]);
    try expectContains(out, "<main><qip-main-layout><nav>outer</nav><qip-main-layout class=\"spec\"><nav>inner</nav><p>Spec</p></qip-main-layout><footer>none</footer></qip-main-layout></main>");
    try expectContains(out, "<main><qip-main-layout><nav>outer</nav><qip-main-layout class=\"spec\"><nav>inner</nav><p>ABI</p></qip-main-layout><footer><p slot=\"note\">v2</p></footer></qip-main-layout></main>");
}

test "a layout with only named slots accepts pages without loose content" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/cards", "<main>\n<qip-main-layout><h1><slot name=\"title\"></slot></h1></qip-main-layout>\n<!-- index --></main>");
    try appendResponse(&warc_buf, &n, "/cards/one", "<main>\n<span slot=\"title\">One</span>\n</main>");

    const out = try transformed(warc_buf[0..n]);
    try expectContains(out, "<main><qip-main-layout><h1><span slot=\"title\">One</span></h1></qip-main-layout></main>");
}

test "rejects layout mistakes" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main>" ++ DOCS_LAYOUT ++ "</main>");
    try appendResponse(&warc_buf, &n, "/a/", "<main>" ++ DOCS_LAYOUT ++ "</main>");
    try expectRejection(warc_buf[0..n], FAILURE_DUPLICATE_LAYOUT);

    n = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><qip-main-layout><slot></slot><slot></slot></qip-main-layout></main>");
    try expectRejection(warc_buf[0..n], FAILURE_DUPLICATE_SLOT);

    n = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><qip-main-layout><slot></qip-main-layout></main>");
    try expectRejection(warc_buf[0..n], FAILURE_MALFORMED_LAYOUT);

    n = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><div><qip-main-layout><slot></slot></qip-main-layout></div></main>");
    try expectRejection(warc_buf[0..n], FAILURE_MALFORMED_LAYOUT);

    n = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><qip-main-layout><slot name=\"x\"></slot></qip-main-layout></main>");
    try appendResponse(&warc_buf, &n, "/a/b", "<main><qip-main-layout><slot></slot></qip-main-layout></main>");
    try expectRejection(warc_buf[0..n], FAILURE_OUTER_WITHOUT_UNNAMED_SLOT);

    n = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main>" ++ DOCS_LAYOUT ++ "</main>");
    try appendResponse(&warc_buf, &n, "/a/b", "<main><p slot=\"asdie\">typo</p></main>");
    try expectRejection(warc_buf[0..n], FAILURE_UNKNOWN_SLOT);

    n = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><qip-main-layout><slot name=\"x\"></slot></qip-main-layout></main>");
    try appendResponse(&warc_buf, &n, "/a/b", "<main><p>dropped</p></main>");
    try expectRejection(warc_buf[0..n], FAILURE_UNPLACED_CONTENT);
}

test "reports the offending element's input offset" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main>" ++ DOCS_LAYOUT ++ "</main>");
    try appendResponse(&warc_buf, &n, "/a/b", "<main><p slot=\"asdie\">typo</p></main>");
    const result = runTransform(warc_buf[0..n]);
    const offset = result.output_size_or_failure / FAILURE_MODES;
    try std.testing.expect(std.mem.startsWith(u8, warc_buf[offset..n], "<p slot=\"asdie\">"));
}

test "closes <p> and <li> where HTML does and appends the end tag when they move" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><qip-main-layout><article><slot></slot></article><aside><slot name=\"note\"></slot></aside></qip-main-layout></main>");
    try appendResponse(&warc_buf, &n, "/a/b", "<main><p>Intro<p slot=\"note\">Moved<div>Body</div>tail<ul><li>one<li>two</ul></main>");

    const out = try transformed(warc_buf[0..n]);
    try expectContains(out, "<article><p>Intro</p><div>Body</div>tail<ul><li>one<li>two</ul></article><aside><p slot=\"note\">Moved</p></aside>");
}

test "treats self-closing SVG tags as closed" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendResponse(&warc_buf, &n, "/a", "<main><qip-main-layout><article><slot></slot></article><aside><slot name=\"note\"></slot></aside></qip-main-layout></main>");
    try appendResponse(&warc_buf, &n, "/a/b", "<main><p><svg viewBox=\"0 0 1 1\"><path d=\"M0 0\"/><circle r=\"1\" /></svg></p><svg/><aside slot=\"note\">Note</aside><p>End</p></main>");

    const out = try transformed(warc_buf[0..n]);
    try expectContains(out, "<article><p><svg viewBox=\"0 0 1 1\"><path d=\"M0 0\"/><circle r=\"1\" /></svg></p><svg/><p>End</p></article><aside><aside slot=\"note\">Note</aside></aside>");
}
