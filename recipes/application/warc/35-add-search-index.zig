const std = @import("std");
const warc = @import("lib/warc.zig");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 304 * 1024 * 1024;
const TARGETS_CAP: usize = 2 * 1024 * 1024;
const SHARD_CAP: usize = 8 * 1024 * 1024;
const MAX_POSTINGS: usize = 300_000;
const TERM_CAP: usize = 40;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";
const SEARCH_ROOT = "/search/v1/";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var targets_buf: [TARGETS_CAP]u8 = undefined;
var shard_buf: [SHARD_CAP]u8 = undefined;
var postings: [MAX_POSTINGS]Posting = undefined;
var posting_count: usize = 0;
var page_body_terms: [std.math.maxInt(u16) + 1]u32 = undefined;
var page_code_terms: [std.math.maxInt(u16) + 1]u32 = undefined;

const Field = enum(u8) {
    body,
    title,
    heading,
    code,
    code_identifier,
    code_params,
    code_title,
    ignored,
};

const FIELD_COUNT = @typeInfo(Field).@"enum".fields.len;

const Posting = struct {
    term: [TERM_CAP]u8,
    term_len: u8,
    page: u16,
    section: u16,
    field: Field,

    fn termSlice(self: *const Posting) []const u8 {
        return self.term[0..self.term_len];
    }
};

const WARCRecord = struct {
    next: usize,
    warc_type: []const u8,
    target_uri: []const u8,
    warc_date: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

const Range = struct {
    start: usize,
    end: usize,
};

const IndexError = error{
    InvalidWARC,
    InvalidHTTP,
    MissingOrigin,
    MixedOrigins,
    ExistingSearchIndex,
    TooManyPages,
    TooManySections,
    TooManyPostings,
    TargetsTooLarge,
    ShardTooLarge,
    OutputTooLarge,
};

const Writer = struct {
    buf: []u8,
    idx: usize = 0,
    overflow: bool = false,

    fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    fn writeByte(self: *Writer, value: u8) void {
        if (self.overflow) return;
        if (self.idx >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.idx] = value;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, value: []const u8) void {
        if (self.overflow or value.len == 0) return;
        if (value.len > self.buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.idx .. self.idx + value.len], value);
        self.idx += value.len;
    }

    fn writeUnsigned(self: *Writer, value: usize) void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(text);
    }

    fn written(self: *const Writer, comptime err: IndexError) IndexError![]const u8 {
        if (self.overflow) return err;
        return self.buf[0..self.idx];
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

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and eqlIgnoreCase(value[0..prefix.len], prefix);
}

const indexOfIgnoreCase = warc.indexOfIgnoreCase;

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn trimWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isWhitespace(value[start])) : (start += 1) {}
    while (end > start and isWhitespace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn parseUnsigned10(value: []const u8) ?usize {
    if (value.len == 0) return null;
    var result: usize = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, c - '0') catch return null;
    }
    return result;
}

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (warc.indexOfPos(buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (warc.indexOfPos(buf, start, "\n\n")) |pos| return pos + 2;
    return null;
}

fn parseStatusCode(status_line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < status_line.len and status_line[i] != ' ') : (i += 1) {}
    while (i < status_line.len and status_line[i] == ' ') : (i += 1) {}
    const start = i;
    while (i < status_line.len and status_line[i] >= '0' and status_line[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    const value = parseUnsigned10(status_line[start..i]) orelse return null;
    if (value > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(value));
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const header_end = findHeaderEnd(input, start) orelse return null;
    const header = input[start..header_end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var warc_date: []const u8 = "";
    var content_length: ?usize = null;
    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header, line_start, "\n") orelse header.len;
        var line = header[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header.len) nl + 1 else header.len;
        if (line_index == 0) continue;
        line = trimWhitespace(line);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const key = trimWhitespace(line[0..colon]);
        const value = trimWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "WARC-Type")) warc_type = value;
        if (eqlIgnoreCase(key, "WARC-Target-URI")) target_uri = value;
        if (eqlIgnoreCase(key, "WARC-Date")) warc_date = value;
        if (eqlIgnoreCase(key, "Content-Length")) content_length = parseUnsigned10(value);
    }
    const payload_len = content_length orelse return null;
    if (header_end > input.len or payload_len > input.len - header_end) return null;
    const payload_end = header_end + payload_len;
    if (payload_end + 4 > input.len or !std.mem.eql(u8, input[payload_end .. payload_end + 4], "\r\n\r\n")) return null;
    return .{
        .next = payload_end + 4,
        .warc_type = warc_type,
        .target_uri = target_uri,
        .warc_date = warc_date,
        .payload = input[header_end..payload_end],
    };
}

fn parseHTTPMeta(payload: []const u8) ?HTTPMeta {
    const header_end = findHeaderEnd(payload, 0) orelse return null;
    const header = payload[0..header_end];
    var status: ?u16 = null;
    var content_type: []const u8 = "";
    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header, line_start, "\n") orelse header.len;
        var line = header[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header.len) nl + 1 else header.len;
        line = trimWhitespace(line);
        if (line.len == 0) break;
        if (line_index == 0) {
            status = parseStatusCode(line);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (eqlIgnoreCase(trimWhitespace(line[0..colon]), "Content-Type")) {
            content_type = trimWhitespace(line[colon + 1 ..]);
        }
    }
    return .{ .status = status orelse return null, .content_type = content_type, .body = payload[header_end..] };
}

fn mimeTypeToken(raw: []const u8) []const u8 {
    const value = trimWhitespace(raw);
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return trimWhitespace(value[0..semicolon]);
}

fn isHTML(content_type: []const u8) bool {
    const mime = mimeTypeToken(content_type);
    return eqlIgnoreCase(mime, "text/html") or eqlIgnoreCase(mime, "application/xhtml+xml");
}

fn uriOrigin(uri: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, uri, "://") orelse return null;
    const authority_start = scheme + 3;
    if (authority_start >= uri.len) return null;
    const path = std.mem.indexOfPos(u8, uri, authority_start, "/") orelse uri.len;
    const query = std.mem.indexOfPos(u8, uri, authority_start, "?") orelse uri.len;
    const fragment = std.mem.indexOfPos(u8, uri, authority_start, "#") orelse uri.len;
    return uri[0..@min(path, @min(query, fragment))];
}

fn uriPath(uri: []const u8) ?[]const u8 {
    const origin = uriOrigin(uri) orelse return null;
    const end = std.mem.indexOfScalar(u8, uri, '#') orelse uri.len;
    if (end < origin.len) return null;
    if (end == origin.len) return "/";
    const path = uri[origin.len..end];
    if (path.len == 0) return "/";
    return path;
}

fn isSearchPath(uri: []const u8) bool {
    const path = uriPath(uri) orelse return false;
    return startsWithIgnoreCase(path, SEARCH_ROOT);
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i;
        }
    }
    return null;
}

fn tagName(tag: []const u8) []const u8 {
    if (tag.len < 3 or tag[0] != '<') return "";
    var i: usize = 1;
    if (tag[i] == '/') i += 1;
    while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}
    const start = i;
    while (i < tag.len and ((tag[i] >= 'a' and tag[i] <= 'z') or (tag[i] >= 'A' and tag[i] <= 'Z') or (tag[i] >= '0' and tag[i] <= '9'))) : (i += 1) {}
    return tag[start..i];
}

fn isClosingTag(tag: []const u8) bool {
    var i: usize = 1;
    while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}
    return i < tag.len and tag[i] == '/';
}

fn attributeValue(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var i: usize = 1;
    if (i < tag.len and tag[i] == '/') i += 1;
    while (i < tag.len and !isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
    while (i < tag.len) {
        while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>' or tag[i] == '/') return null;
        const name_start = i;
        while (i < tag.len and !isWhitespace(tag[i]) and tag[i] != '=' and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
        const name = tag[name_start..i];
        while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') {
            while (i < tag.len and !isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
            continue;
        }
        i += 1;
        while (i < tag.len and isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len) return null;
        var value: []const u8 = "";
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            i += 1;
            const value_start = i;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            value = tag[value_start..i];
            if (i < tag.len) i += 1;
        } else {
            const value_start = i;
            while (i < tag.len and !isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {}
            value = tag[value_start..i];
        }
        if (eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

fn findElementContent(input: []const u8, name: []const u8, start: usize) ?Range {
    var cursor = start;
    while (indexOfIgnoreCase(input, "<", cursor)) |open| {
        const open_end = findTagEnd(input, open) orelse return null;
        const tag = input[open .. open_end + 1];
        if (!isClosingTag(tag) and eqlIgnoreCase(tagName(tag), name)) {
            var close_buf: [32]u8 = undefined;
            const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch return null;
            const close_start = indexOfIgnoreCase(input, close, open_end + 1) orelse return null;
            return .{ .start = open_end + 1, .end = close_start };
        }
        cursor = open_end + 1;
    }
    return null;
}

fn hasClass(tag: []const u8, wanted: []const u8) bool {
    const classes = attributeValue(tag, "class") orelse return false;
    var cursor: usize = 0;
    while (cursor < classes.len) {
        while (cursor < classes.len and isWhitespace(classes[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < classes.len and !isWhitespace(classes[cursor])) : (cursor += 1) {}
        if (eqlIgnoreCase(classes[start..cursor], wanted)) return true;
    }
    return false;
}

fn findIndexableContent(input: []const u8) Range {
    var cursor: usize = 0;
    while (indexOfIgnoreCase(input, "<article", cursor)) |open| {
        const open_end = findTagEnd(input, open) orelse break;
        const tag = input[open .. open_end + 1];
        if (hasClass(tag, "docs-content")) {
            const close = indexOfIgnoreCase(input, "</article", open_end + 1) orelse break;
            return .{ .start = open_end + 1, .end = close };
        }
        cursor = open_end + 1;
    }
    return findElementContent(input, "main", 0) orelse .{ .start = 0, .end = input.len };
}

fn appendEntityText(out: *Writer, entity: []const u8) void {
    if (eqlIgnoreCase(entity, "amp")) return out.writeByte('&');
    if (eqlIgnoreCase(entity, "lt")) return out.writeByte('<');
    if (eqlIgnoreCase(entity, "gt")) return out.writeByte('>');
    if (eqlIgnoreCase(entity, "quot")) return out.writeByte('"');
    if (eqlIgnoreCase(entity, "apos") or std.mem.eql(u8, entity, "#39")) return out.writeByte('\'');
    if (eqlIgnoreCase(entity, "nbsp")) return out.writeByte(' ');
    out.writeByte(' ');
}

fn plainText(html: []const u8, storage: []u8) []const u8 {
    var out = Writer.init(storage);
    var pending_space = false;
    var i: usize = 0;
    while (i < html.len and !out.overflow) {
        if (html[i] == '<') {
            const end = findTagEnd(html, i) orelse break;
            i = end + 1;
            pending_space = out.idx > 0;
            continue;
        }
        if (html[i] == '&') {
            const semicolon = std.mem.indexOfScalarPos(u8, html, i + 1, ';');
            if (semicolon) |end| {
                if (pending_space and out.idx > 0 and out.buf[out.idx - 1] != ' ') out.writeByte(' ');
                pending_space = false;
                appendEntityText(&out, html[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }
        const c = html[i];
        if (isWhitespace(c)) {
            pending_space = out.idx > 0;
        } else {
            if (pending_space and out.idx > 0 and out.buf[out.idx - 1] != ' ') out.writeByte(' ');
            pending_space = false;
            out.writeByte(c);
        }
        i += 1;
    }
    var text = trimWhitespace(storage[0..out.idx]);
    if (text.len > 0 and text[text.len - 1] == '#') text = trimWhitespace(text[0 .. text.len - 1]);
    return text;
}

fn safeFragment(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) return false;
    }
    return true;
}

fn addPosting(term: []const u8, page: u16, section: u16, field: Field) IndexError!void {
    if (term.len == 0) return;
    if (posting_count >= MAX_POSTINGS) return error.TooManyPostings;
    var posting = &postings[posting_count];
    const len = @min(term.len, TERM_CAP);
    @memset(&posting.term, 0);
    for (term[0..len], 0..) |c, i| posting.term[i] = asciiLower(c);
    posting.term_len = @as(u8, @intCast(len));
    posting.page = page;
    posting.section = section;
    posting.field = field;
    posting_count += 1;
}

fn recordTerm(term: []const u8, page: u16, section: u16, field: Field) IndexError!void {
    if (field == .ignored) return;
    if (field == .body) page_body_terms[page] += 1;
    if (field == .code or field == .code_identifier or field == .code_params or field == .code_title) {
        page_code_terms[page] += 1;
    }
    try addPosting(term, page, section, field);
}

fn addTerms(text: []const u8, page: u16, section: u16, field: Field) IndexError!void {
    var term: [TERM_CAP]u8 = undefined;
    var term_len: usize = 0;
    var in_long_term = false;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const c: u8 = if (i < text.len) text[i] else ' ';
        const is_term = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (is_term) {
            if (term_len < TERM_CAP) {
                term[term_len] = asciiLower(c);
                term_len += 1;
            } else {
                in_long_term = true;
            }
        } else if (term_len > 0) {
            if (!in_long_term) try recordTerm(term[0..term_len], page, section, field);
            term_len = 0;
            in_long_term = false;
        }
    }
}

fn addHTMLTerms(html: []const u8, page: u16, section: u16, field: Field) IndexError!void {
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = findTagEnd(html, i) orelse break;
            i = end + 1;
            continue;
        }
        if (html[i] == '&') {
            i = (std.mem.indexOfScalarPos(u8, html, i + 1, ';') orelse i) + 1;
            continue;
        }
        const start = i;
        i = warc.indexOfAnyPos(html, i, "<&") orelse html.len;
        try addTerms(html[start..i], page, section, field);
    }
}

fn isCodeField(field: Field) bool {
    return field == .code or field == .code_identifier or field == .code_params or field == .code_title or field == .ignored;
}

fn highlightedCodeField(tag: []const u8, parent: Field) Field {
    if (parent == .ignored or
        hasClass(tag, "hljs-keyword") or
        hasClass(tag, "hljs-punctuation") or
        hasClass(tag, "hljs-operator") or
        hasClass(tag, "hljs-number"))
    {
        return .ignored;
    }
    if (hasClass(tag, "hljs-title") or parent == .code_title) return .code_title;
    if (hasClass(tag, "hljs-params") or parent == .code_params) return .code_params;
    if (hasClass(tag, "hljs-type") or
        hasClass(tag, "hljs-variable") or
        hasClass(tag, "hljs-attr") or
        hasClass(tag, "hljs-attribute") or
        hasClass(tag, "hljs-name") or
        hasClass(tag, "hljs-symbol") or
        hasClass(tag, "hljs-built_in"))
    {
        return .code_identifier;
    }
    return parent;
}

fn addCodeLanguageTerm(tag: []const u8, page: u16, section: u16) IndexError!void {
    const classes = attributeValue(tag, "class") orelse return;
    var cursor: usize = 0;
    while (cursor < classes.len) {
        while (cursor < classes.len and isWhitespace(classes[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < classes.len and !isWhitespace(classes[cursor])) : (cursor += 1) {}
        const class_name = classes[start..cursor];
        const prefix = "language-";
        if (std.mem.startsWith(u8, class_name, prefix) and class_name.len > prefix.len) {
            try addTerms(class_name[prefix.len..], page, section, .code_title);
            return;
        }
    }
}

const CodeFrame = struct {
    tag_name: []const u8,
    previous_field: Field,
};

fn writeCSVField(out: *Writer, value: []const u8) void {
    var quote = false;
    for (value) |c| {
        if (c == ',' or c == '"' or c == '\r' or c == '\n') {
            quote = true;
            break;
        }
    }
    if (!quote) return out.writeSlice(value);
    out.writeByte('"');
    for (value) |c| {
        if (c == '"') out.writeByte('"');
        out.writeByte(c);
    }
    out.writeByte('"');
}

fn writeTarget(
    out: *Writer,
    page: u16,
    section: u16,
    url: []const u8,
    fragment: ?[]const u8,
    page_title: []const u8,
    heading: ?[]const u8,
) void {
    out.writeUnsigned(page);
    out.writeByte('-');
    out.writeUnsigned(section);
    out.writeByte(',');
    writeCSVField(out, url);
    if (fragment) |id| {
        out.writeByte('#');
        out.writeSlice(id);
    }
    out.writeByte(',');
    if (heading) |text| {
        var label_buf: [2048]u8 = undefined;
        var label = Writer.init(&label_buf);
        label.writeSlice(page_title);
        label.writeSlice(" — ");
        label.writeSlice(text);
        writeCSVField(out, label_buf[0..label.idx]);
    } else {
        writeCSVField(out, page_title);
    }
    out.writeByte('\n');
}

fn indexPage(body: []const u8, url: []const u8, page: u16, targets: *Writer) IndexError!void {
    page_body_terms[page] = 0;
    page_code_terms[page] = 0;
    var title_buf: [1024]u8 = undefined;
    const title_range = findElementContent(body, "title", 0);
    const title = if (title_range) |range| plainText(body[range.start..range.end], &title_buf) else "Untitled";
    writeTarget(targets, page, 0, url, null, title, null);
    try addTerms(title, page, 0, .title);

    const content_range = findIndexableContent(body);
    const content = body[content_range.start..content_range.end];
    var section: u16 = 0;
    var cursor: usize = 0;
    var text_start: usize = 0;
    var code_frames: [64]CodeFrame = undefined;
    var code_depth: usize = 0;
    var current_field: Field = .body;
    while (cursor < content.len) {
        if (content[cursor] != '<') {
            cursor = std.mem.indexOfScalarPos(u8, content, cursor, '<') orelse content.len;
            continue;
        }
        if (cursor > text_start) try addHTMLTerms(content[text_start..cursor], page, section, current_field);
        const open_end = findTagEnd(content, cursor) orelse break;
        const tag = content[cursor .. open_end + 1];
        const name = tagName(tag);

        if (!isClosingTag(tag) and
            (eqlIgnoreCase(name, "script") or eqlIgnoreCase(name, "style") or eqlIgnoreCase(name, "svg") or eqlIgnoreCase(name, "nav")))
        {
            var close_buf: [32]u8 = undefined;
            const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch return error.InvalidHTTP;
            const close_start = indexOfIgnoreCase(content, close, open_end + 1) orelse content.len;
            const close_end = if (close_start < content.len) findTagEnd(content, close_start) orelse close_start else close_start;
            cursor = if (close_start < content.len) close_end + 1 else content.len;
            text_start = cursor;
            continue;
        }

        const is_heading = !isClosingTag(tag) and name.len == 2 and asciiLower(name[0]) == 'h' and name[1] >= '2' and name[1] <= '6';
        if (is_heading) {
            const id = attributeValue(tag, "id");
            if (id != null and safeFragment(id.?)) {
                var close_buf: [16]u8 = undefined;
                const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch return error.InvalidHTTP;
                const close_start = indexOfIgnoreCase(content, close, open_end + 1) orelse return error.InvalidHTTP;
                const close_end = findTagEnd(content, close_start) orelse return error.InvalidHTTP;
                if (section == std.math.maxInt(u16)) return error.TooManySections;
                section += 1;
                var heading_buf: [1024]u8 = undefined;
                const heading = plainText(content[open_end + 1 .. close_start], &heading_buf);
                writeTarget(targets, page, section, url, id, title, heading);
                try addTerms(heading, page, section, .heading);
                cursor = close_end + 1;
                text_start = cursor;
                continue;
            }
        }

        if (isClosingTag(tag)) {
            if (code_depth > 0 and eqlIgnoreCase(code_frames[code_depth - 1].tag_name, name)) {
                code_depth -= 1;
                current_field = code_frames[code_depth].previous_field;
            }
        } else if (eqlIgnoreCase(name, "code")) {
            if (code_depth >= code_frames.len) return error.InvalidHTTP;
            code_frames[code_depth] = .{ .tag_name = name, .previous_field = current_field };
            code_depth += 1;
            current_field = .code;
            try addCodeLanguageTerm(tag, page, section);
        } else if (eqlIgnoreCase(name, "span") and isCodeField(current_field)) {
            if (code_depth >= code_frames.len) return error.InvalidHTTP;
            code_frames[code_depth] = .{ .tag_name = name, .previous_field = current_field };
            code_depth += 1;
            current_field = highlightedCodeField(tag, current_field);
        }
        cursor = open_end + 1;
        text_start = cursor;
    }
    if (text_start < content.len) try addHTMLTerms(content[text_start..], page, section, current_field);
}

fn postingLessThan(_: void, a: Posting, b: Posting) bool {
    const order = std.mem.order(u8, a.termSlice(), b.termSlice());
    if (order != .eq) return order == .lt;
    if (a.page != b.page) return a.page < b.page;
    return a.section < b.section;
}

fn sameTerm(a: *const Posting, b: *const Posting) bool {
    return std.mem.eql(u8, a.termSlice(), b.termSlice());
}

fn shardForTerm(term: []const u8) u8 {
    const first = if (term.len > 0) term[0] else '_';
    if (first >= 'a' and first <= 'z') return first;
    if (first >= '0' and first <= '9') return '0';
    return '_';
}

const SHARDS = "0_abcdefghijklmnopqrstuvwxyz";

const PostingRange = struct {
    start: usize = 0,
    end: usize = 0,
};

fn shardIndex(shard: u8) usize {
    if (shard == '0') return 0;
    if (shard == '_') return 1;
    if (shard >= 'a' and shard <= 'z') return 2 + shard - 'a';
    unreachable;
}

fn postingRangesByShard() [SHARDS.len]PostingRange {
    var ranges = [_]PostingRange{.{}} ** SHARDS.len;
    var seen = [_]bool{false} ** SHARDS.len;
    for (postings[0..posting_count], 0..) |*posting, index| {
        const range_index = shardIndex(shardForTerm(posting.termSlice()));
        if (!seen[range_index]) {
            ranges[range_index].start = index;
            seen[range_index] = true;
        }
        ranges[range_index].end = index + 1;
    }
    return ranges;
}

const FieldCounts = [FIELD_COUNT]u16;

fn addFieldCount(counts: *FieldCounts, field: Field) void {
    const index = @intFromEnum(field);
    counts[index] +|= 1;
}

fn countFor(counts: FieldCounts, field: Field) u32 {
    return counts[@intFromEnum(field)];
}

fn normalizedRepeatedScore(count: u32, page_len: u32, average_len: u32, unit: u32) u32 {
    if (count == 0) return 0;
    const saturated = @min(count, 3) * unit;
    if (average_len == 0) return saturated;
    return @max(1, saturated * 2 * average_len / (average_len + page_len));
}

fn fieldScore(counts: FieldCounts, page: u16, average_body_len: u32, average_code_len: u32) u32 {
    const title: u32 = if (countFor(counts, .title) > 0) 40 else 0;
    const heading_count = countFor(counts, .heading);
    const heading: u32 = if (heading_count > 0) @as(u32, 24) + @min(heading_count - 1, @as(u32, 2)) * 2 else 0;
    const code_title_count = countFor(counts, .code_title);
    const code_title: u32 = if (code_title_count > 0) @as(u32, 18) + @min(code_title_count - 1, @as(u32, 2)) * 2 else 0;
    const code_params_count = countFor(counts, .code_params);
    const code_params: u32 = if (code_params_count > 0) @as(u32, 10) + @min(code_params_count - 1, @as(u32, 2)) * 2 else 0;
    const code_identifier_count = countFor(counts, .code_identifier);
    const code_identifier: u32 = if (code_identifier_count > 0) @as(u32, 6) + @min(code_identifier_count - 1, @as(u32, 2)) else 0;
    const code = normalizedRepeatedScore(countFor(counts, .code), page_code_terms[page], average_code_len, 2);
    const body = normalizedRepeatedScore(countFor(counts, .body), page_body_terms[page], average_body_len, 2);
    return title + heading + code_title + code_params + code_identifier + code + body;
}

fn buildShard(
    posting_range: PostingRange,
    page_count: usize,
    average_body_len: u32,
    average_code_len: u32,
    out: *Writer,
) void {
    out.writeSlice("term,target,weight\n");
    var i = posting_range.start;
    while (i < posting_range.end) {
        const term_first = &postings[i];
        var term_end = i + 1;
        while (term_end < posting_range.end and sameTerm(term_first, &postings[term_end])) : (term_end += 1) {}

        var document_frequency: usize = 0;
        var frequency_cursor = i;
        while (frequency_cursor < term_end) {
            document_frequency += 1;
            const page = postings[frequency_cursor].page;
            while (frequency_cursor < term_end and postings[frequency_cursor].page == page) : (frequency_cursor += 1) {}
        }
        const rarity = @min(@as(usize, 16), @max(@as(usize, 1), page_count / document_frequency));

        var page_cursor = i;
        while (page_cursor < term_end) {
            const page = postings[page_cursor].page;
            var page_end = page_cursor + 1;
            while (page_end < term_end and postings[page_end].page == page) : (page_end += 1) {}

            var page_counts = [_]u16{0} ** FIELD_COUNT;
            var best_section: u16 = 0;
            var best_section_score: u32 = 0;
            var section_cursor = page_cursor;
            while (section_cursor < page_end) {
                const section = postings[section_cursor].section;
                var section_counts = [_]u16{0} ** FIELD_COUNT;
                while (section_cursor < page_end and postings[section_cursor].section == section) : (section_cursor += 1) {
                    addFieldCount(&page_counts, postings[section_cursor].field);
                    addFieldCount(&section_counts, postings[section_cursor].field);
                }
                const section_score = fieldScore(section_counts, page, average_body_len, average_code_len);
                if (section_score > best_section_score) {
                    best_section = section;
                    best_section_score = section_score;
                }
            }

            const score = @min(
                @as(usize, std.math.maxInt(u16)),
                @as(usize, fieldScore(page_counts, page, average_body_len, average_code_len)) * rarity,
            );
            out.writeSlice(term_first.termSlice());
            out.writeByte(',');
            out.writeUnsigned(page);
            out.writeByte('-');
            out.writeUnsigned(best_section);
            out.writeByte(',');
            out.writeUnsigned(score);
            out.writeByte('\n');
            page_cursor = page_end;
        }
        i = term_end;
    }
}

fn fnv64(parts: []const []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (parts) |part| {
        for (part) |c| {
            hash ^= c;
            hash *%= 1099511628211;
        }
    }
    return hash;
}

fn writeHex64(out: *Writer, value: u64) void {
    const digits = "0123456789abcdef";
    var shift: u6 = 60;
    while (true) {
        out.writeByte(digits[@as(usize, @intCast((value >> shift) & 0xf))]);
        if (shift == 0) break;
        shift -= 4;
    }
}

fn appendResponse(
    out: *Writer,
    origin: []const u8,
    date: []const u8,
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    const http_header_len = "HTTP/1.1 200 OK\r\nContent-Type: \r\nContent-Length: \r\n\r\n".len +
        content_type.len + std.fmt.count("{d}", .{body.len});
    const payload_len = http_header_len + body.len;
    out.writeSlice("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: ");
    out.writeSlice(origin);
    out.writeSlice(path);
    out.writeSlice("\r\nWARC-Date: ");
    out.writeSlice(date);
    out.writeSlice("\r\nWARC-Record-ID: <urn:qip:search:");
    writeHex64(out, fnv64(&.{ path, body }));
    out.writeSlice(">\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: ");
    out.writeUnsigned(payload_len);
    out.writeSlice("\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: ");
    out.writeSlice(content_type);
    out.writeSlice("\r\nContent-Length: ");
    out.writeUnsigned(body.len);
    out.writeSlice("\r\n\r\n");
    out.writeSlice(body);
    out.writeSlice("\r\n\r\n");
}

fn addSearchIndex(input: []const u8, output: []u8, targets_storage: []u8, shard_storage: []u8) IndexError!usize {
    if (!warc.validateArchive(input)) return error.InvalidWARC;
    posting_count = 0;
    var targets = Writer.init(targets_storage);
    targets.writeSlice("target,url,label\n");
    var cursor: usize = 0;
    var origin: ?[]const u8 = null;
    var archive_date: ?[]const u8 = null;
    var page_count: usize = 0;
    while (cursor < input.len) {
        const record = parseWARCRecord(input, cursor) orelse return error.InvalidWARC;
        cursor = record.next;
        if (archive_date == null and record.warc_date.len > 0) archive_date = record.warc_date;
        if (isSearchPath(record.target_uri)) return error.ExistingSearchIndex;
        if (!eqlIgnoreCase(record.warc_type, "response")) continue;
        const http = parseHTTPMeta(record.payload) orelse return error.InvalidHTTP;
        if (http.status != 200 or !isHTML(http.content_type)) continue;
        const record_origin = uriOrigin(record.target_uri) orelse return error.InvalidWARC;
        if (origin) |expected| {
            if (!eqlIgnoreCase(expected, record_origin)) return error.MixedOrigins;
        } else {
            origin = record_origin;
        }
        const path = uriPath(record.target_uri) orelse return error.InvalidWARC;
        if (startsWithIgnoreCase(path, "/view-source")) continue;
        if (page_count >= std.math.maxInt(u16)) return error.TooManyPages;
        page_count += 1;
        try indexPage(http.body, path, @as(u16, @intCast(page_count)), &targets);
        if (targets.overflow) return error.TargetsTooLarge;
    }
    const site_origin = origin orelse return error.MissingOrigin;
    const date = archive_date orelse return error.InvalidWARC;
    const targets_csv = try targets.written(error.TargetsTooLarge);

    std.sort.block(Posting, postings[0..posting_count], {}, postingLessThan);
    const posting_ranges = postingRangesByShard();
    var total_body_terms: u64 = 0;
    var total_code_terms: u64 = 0;
    var page_index: usize = 1;
    while (page_index <= page_count) : (page_index += 1) {
        total_body_terms += page_body_terms[page_index];
        total_code_terms += page_code_terms[page_index];
    }
    const average_body_len = @as(u32, @intCast(@max(@as(u64, 1), total_body_terms / page_count)));
    const average_code_len = @as(u32, @intCast(@max(@as(u64, 1), total_code_terms / page_count)));

    var out = Writer.init(output);
    out.writeSlice(input);
    if (!std.mem.endsWith(u8, input, "\r\n\r\n")) out.writeSlice("\r\n\r\n");
    appendResponse(&out, site_origin, date, SEARCH_ROOT ++ "targets.csv", "text/csv; charset=utf-8; header=present", targets_csv);

    for (SHARDS, 0..) |shard, range_index| {
        var shard_writer = Writer.init(shard_storage);
        buildShard(posting_ranges[range_index], page_count, average_body_len, average_code_len, &shard_writer);
        const shard_csv = try shard_writer.written(error.ShardTooLarge);
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, SEARCH_ROOT ++ "index/{c}.csv", .{shard}) catch return error.OutputTooLarge;
        appendResponse(&out, site_origin, date, path, "text/csv; charset=utf-8; header=present", shard_csv);
    }
    if (out.overflow) return error.OutputTooLarge;
    if (!warc.validateArchive(output[0..out.idx])) return error.InvalidWARC;
    return out.idx;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    const written = addSearchIndex(input_buf[0..input_size], &output_buf, &targets_buf, &shard_buf) catch @trap();
    return @as(u32, @intCast(written));
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

fn appendTestRecord(out: []u8, cursor: *usize, target_uri: []const u8, payload: []const u8) !void {
    const record = try std.fmt.bufPrint(
        out[cursor.*..],
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2026-07-24T00:00:00Z\r\nWARC-Record-ID: <urn:test:{d}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += record.len;
}

test "appends flat page and section CSV search routes" {
    var input: [8192]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "https://qip.dev/docs/abc",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><title>ABC Docs</title><main><p>Portable C overview.</p><h2 id=\"portable\">Portable <a class=\"heading-anchor\" href=\"#portable\">#</a></h2><p>Portable WebAssembly component.</p><h2 id=\"components\">Components</h2><p>Component pipelines.</p><pre><code class=\"language-zig hljs\"><span class=\"hljs-keyword\">fn</span> <span class=\"hljs-title function_\">render</span>(<span class=\"hljs-params\">input_size</span>)</code></pre></main>",
    );
    var output: [64 * 1024]u8 = undefined;
    var targets_storage: [8192]u8 = undefined;
    var shard_storage: [8192]u8 = undefined;
    const written = try addSearchIndex(input[0..input_len], &output, &targets_storage, &shard_storage);
    const result = output[0..written];
    try std.testing.expect(warc.validateArchive(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "WARC-Target-URI: https://qip.dev/search/v1/targets.csv") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1-0,/docs/abc,ABC Docs\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1-1,/docs/abc#portable,ABC Docs — Portable\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "portable,1-1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "component,1-1,") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "\ncomponent,1-"));
    try std.testing.expect(std.mem.indexOf(u8, result, "\nc,1-0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\nrender,1-2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\ninput_size,1-2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\nzig,1-2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\nfn,1-") == null);
}

test "repetition saturates and long pages do not win by volume" {
    page_body_terms[1] = 100;
    page_body_terms[2] = 1000;
    page_code_terms[1] = 0;
    page_code_terms[2] = 0;

    var once = [_]u16{0} ** FIELD_COUNT;
    once[@intFromEnum(Field.body)] = 1;
    var repeated = [_]u16{0} ** FIELD_COUNT;
    repeated[@intFromEnum(Field.body)] = 16;
    var saturated = [_]u16{0} ** FIELD_COUNT;
    saturated[@intFromEnum(Field.body)] = 3;
    var title = [_]u16{0} ** FIELD_COUNT;
    title[@intFromEnum(Field.title)] = 1;

    const average_body_len = 100;
    const once_score = fieldScore(once, 1, average_body_len, 1);
    const repeated_score = fieldScore(repeated, 1, average_body_len, 1);
    try std.testing.expectEqual(fieldScore(saturated, 1, average_body_len, 1), repeated_score);
    try std.testing.expect(repeated_score <= once_score * 3);
    try std.testing.expect(fieldScore(repeated, 2, average_body_len, 1) < repeated_score);
    try std.testing.expect(fieldScore(title, 1, average_body_len, 1) > repeated_score);
}

test "rejects an existing search route" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "https://qip.dev/search/v1/targets.csv",
        "HTTP/1.1 200 OK\r\nContent-Type: text/csv\r\n\r\ntarget,url,label\n",
    );
    var output: [8192]u8 = undefined;
    var targets_storage: [1024]u8 = undefined;
    var shard_storage: [1024]u8 = undefined;
    try std.testing.expectError(
        error.ExistingSearchIndex,
        addSearchIndex(input[0..input_len], &output, &targets_storage, &shard_storage),
    );
}
