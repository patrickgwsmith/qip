const std = @import("std");
const warc = @import("lib/warc.zig");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

const MainRange = struct {
    open_end: usize,
    close_start: usize,
};

const NavRange = struct {
    start: usize,
    end: usize,
};

const AttributeRange = struct {
    start: usize,
    end: usize,
};

const INDEXED_RECORD_IS_DOCS_RESPONSE: u8 = 1;
const MAX_WARC_RECORDS: usize = 65536;

const IndexedRecord = struct {
    header_start: u32,
    header_end: u32,
    payload_start: u32,
    payload_end: u32,
    path_start: u32,
    path_end: u32,
    flags: u8,
};

const NAV_CAP: usize = 1024 * 1024;
const MAX_NAV_LINKS: usize = 4096;
const ARIA_CURRENT_PAGE = " aria-current=\"page\"";

const NavLink = struct {
    href: ?[]const u8,
    // Offset of the anchor's closing '>' in PreparedNav.html.
    insert_at: usize,
};

// Every docs page gets the same nav apart from which link is aria-current, so
// the nav is parsed once with aria-current removed and each page splices
// ARIA_CURRENT_PAGE in before the matching link's '>'.
const PreparedNav = struct {
    html: []const u8,
    links: []const NavLink,
};

const ArchiveIndex = struct {
    records: []const IndexedRecord,
    nav: ?PreparedNav,
};

// Twenty-eight bytes per record keeps the full index below 1.75 MiB.
comptime {
    if (@sizeOf(IndexedRecord) != 28) @compileError("IndexedRecord must remain compact");
}

var indexed_records: [MAX_WARC_RECORDS]IndexedRecord = undefined;
var nav_html_buf: [NAV_CAP]u8 = undefined;
var nav_links: [MAX_NAV_LINKS]NavLink = undefined;

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
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(a: []const u8, prefix: []const u8) bool {
    if (a.len < prefix.len) return false;
    return eqlIgnoreCase(a[0..prefix.len], prefix);
}

const indexOfIgnoreCase = warc.indexOfIgnoreCase;

fn trimASCIIWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) : (start += 1) {
        const c = s[start];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    while (end > start) : (end -= 1) {
        const c = s[end - 1];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    return s[start..end];
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

fn isTagBoundary(c: u8) bool {
    return c == '>' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
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

fn hrefFromOpenATag(tag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) : (i += 1) {
        if (asciiLower(tag[i]) != 'h') continue;
        if (i + 4 > tag.len or !eqlIgnoreCase(tag[i .. i + 4], "href")) continue;
        if (i > 0 and !isTagBoundary(tag[i - 1])) continue;
        var j = i + 4;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t' or tag[j] == '\r' or tag[j] == '\n')) : (j += 1) {}
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t' or tag[j] == '\r' or tag[j] == '\n')) : (j += 1) {}
        if (j >= tag.len) return null;
        const quote = tag[j];
        if (quote == '"' or quote == '\'') {
            j += 1;
            const value_start = j;
            while (j < tag.len and tag[j] != quote) : (j += 1) {}
            if (j <= tag.len) return tag[value_start..j];
            return null;
        }
        const value_start = j;
        while (j < tag.len and !isTagBoundary(tag[j])) : (j += 1) {}
        return tag[value_start..j];
    }
    return null;
}

fn findMainRange(body: []const u8) ?MainRange {
    var cursor: usize = 0;
    while (indexOfIgnoreCase(body, "<main", cursor)) |start| {
        const boundary = start + "<main".len;
        if (boundary < body.len and !isTagBoundary(body[boundary])) {
            cursor = boundary;
            continue;
        }
        const open_end = findTagEnd(body, start) orelse return null;
        var close_start: ?usize = null;
        var scan = open_end + 1;
        while (indexOfIgnoreCase(body, "</main>", scan)) |idx| {
            close_start = idx;
            scan = idx + 1;
        }
        if (close_start) |close| return .{ .open_end = open_end + 1, .close_start = close };
        return null;
    }
    return null;
}

fn findDocsNavRange(body: []const u8, main_range: MainRange) ?NavRange {
    var cursor = main_range.open_end;
    while (cursor < main_range.close_start) {
        const start = indexOfIgnoreCase(body, "<nav", cursor) orelse return null;
        const boundary = start + "<nav".len;
        if (boundary < body.len and !isTagBoundary(body[boundary])) {
            cursor = boundary;
            continue;
        }
        const open_end = findTagEnd(body, start) orelse return null;
        if (open_end >= main_range.close_start) return null;
        const close_start = indexOfIgnoreCase(body, "</nav>", open_end + 1) orelse return null;
        const close_end = close_start + "</nav>".len;
        if (close_end > main_range.close_start) return null;
        return .{ .start = start, .end = close_end };
    }
    return null;
}

fn mainStartsWithDocsSidebar(body: []const u8, main_range: MainRange) bool {
    const start = skipASCIIWhitespaceIn(body, main_range.open_end);
    if (start >= main_range.close_start or !startsWithIgnoreCase(body[start..], "<nav")) return false;
    const open_end = findTagEnd(body, start) orelse return false;
    if (open_end >= main_range.close_start) return false;
    const tag = body[start .. open_end + 1];
    return indexOfIgnoreCase(tag, "docs-sidebar", 0) != null;
}

fn skipASCIIWhitespaceIn(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) : (i += 1) {}
    return i;
}

fn findAttributeRange(tag: []const u8, attr_name: []const u8) ?AttributeRange {
    if (tag.len < 2) return null;
    var i: usize = 1;
    while (i + attr_name.len <= tag.len) {
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len or tag[i] == '>') return null;
        const attr_start = i;
        while (i < tag.len and tag[i] != '=' and !isTagBoundary(tag[i])) : (i += 1) {}
        const name = tag[attr_start..i];
        var j = skipASCIIWhitespaceIn(tag, i);
        if (j < tag.len and tag[j] == '=') {
            j += 1;
            j = skipASCIIWhitespaceIn(tag, j);
            if (j < tag.len and (tag[j] == '"' or tag[j] == '\'')) {
                const quote = tag[j];
                j += 1;
                while (j < tag.len and tag[j] != quote) : (j += 1) {}
                if (j < tag.len) j += 1;
            } else {
                while (j < tag.len and !isTagBoundary(tag[j])) : (j += 1) {}
            }
        }
        if (eqlIgnoreCase(name, attr_name)) return .{ .start = attr_start, .end = j };
        i = j;
    }
    return null;
}

const NavBuilder = struct {
    len: usize = 0,

    fn append(self: *NavBuilder, s: []const u8) void {
        if (s.len > nav_html_buf.len - self.len) @trap();
        @memcpy(nav_html_buf[self.len .. self.len + s.len], s);
        self.len += s.len;
    }
};

fn prepareNav(nav: []const u8) PreparedNav {
    var builder = NavBuilder{};
    var link_count: usize = 0;
    var written: usize = 0;
    var cursor: usize = 0;
    while (indexOfIgnoreCase(nav, "<a", cursor)) |a_start| {
        if (a_start + 2 < nav.len and !isTagBoundary(nav[a_start + 2])) {
            cursor = a_start + 2;
            continue;
        }
        const open_end = findTagEnd(nav, a_start) orelse break;
        const tag = nav[a_start .. open_end + 1];
        builder.append(nav[written..a_start]);
        if (findAttributeRange(tag, "aria-current")) |range| {
            const skip_start = if (range.start > 0 and (tag[range.start - 1] == ' ' or tag[range.start - 1] == '\t')) range.start - 1 else range.start;
            builder.append(tag[0..skip_start]);
            builder.append(tag[range.end .. tag.len - 1]);
        } else {
            builder.append(tag[0 .. tag.len - 1]);
        }
        if (link_count >= nav_links.len) @trap();
        nav_links[link_count] = .{ .href = hrefFromOpenATag(tag), .insert_at = builder.len };
        link_count += 1;
        builder.append(">");
        written = open_end + 1;
        cursor = written;
    }
    builder.append(nav[written..]);
    return .{ .html = nav_html_buf[0..builder.len], .links = nav_links[0..link_count] };
}

fn isCurrentNavLink(link: NavLink, current_path: []const u8) bool {
    const href = link.href orelse return false;
    return std.mem.eql(u8, href, current_path);
}

fn adjustedNavLen(nav: PreparedNav, current_path: []const u8) usize {
    var len = nav.html.len;
    for (nav.links) |link| {
        if (isCurrentNavLink(link, current_path)) len += ARIA_CURRENT_PAGE.len;
    }
    return len;
}

fn digits10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) n /= 10;
    return digits;
}

fn injectedBodyLen(body: []const u8, nav: PreparedNav, current_path: []const u8) usize {
    return body.len + adjustedNavLen(nav, current_path) + "<article class=\"docs-content\">".len + "</article>".len;
}

fn injectedRootDocsBodyLen(body: []const u8, nav: PreparedNav, current_path: []const u8, nav_range: NavRange) usize {
    return body.len - (nav_range.end - nav_range.start) + adjustedNavLen(nav, current_path) + "<article class=\"docs-content\">".len + "</article>".len;
}

fn docsPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/docs") or std.mem.startsWith(u8, path, "/docs/");
}

fn childDocsPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/docs/");
}

fn computeHeaderRewriteLen(http: HTTPPayload, body_len: usize) usize {
    return warc.httpHeaderRewriteLen(http.header_block, http.status_line, body_len);
}

fn writeWARCRecordHeader(out: *Output, record: WARCRecord, payload_len: usize, changed: bool) void {
    warc.writeRecordHeader(out, record.header_block, payload_len, changed);
}

fn writeHTTPHeaders(out: *Output, http: HTTPPayload, body_len: usize) void {
    warc.writeRewrittenHTTPHeaders(out, http.header_block, http.status_line, body_len);
}

fn writeAdjustedNav(out: *Output, nav: PreparedNav, current_path: []const u8) void {
    var cursor: usize = 0;
    for (nav.links) |link| {
        if (!isCurrentNavLink(link, current_path)) continue;
        out.writeSlice(nav.html[cursor..link.insert_at]);
        out.writeSlice(ARIA_CURRENT_PAGE);
        cursor = link.insert_at;
    }
    out.writeSlice(nav.html[cursor..]);
}

fn writeHTTPPayloadWithSidebar(out: *Output, http: HTTPPayload, nav: PreparedNav, current_path: []const u8, main_range: MainRange, body_len: usize) void {
    writeHTTPHeaders(out, http, body_len);
    out.writeSlice(http.body[0..main_range.open_end]);
    writeAdjustedNav(out, nav, current_path);
    out.writeSlice("<article class=\"docs-content\">");
    out.writeSlice(http.body[main_range.open_end..main_range.close_start]);
    out.writeSlice("</article>");
    out.writeSlice(http.body[main_range.close_start..]);
}

fn writeRootDocsHTTPPayloadWithSidebar(out: *Output, http: HTTPPayload, nav: PreparedNav, current_path: []const u8, main_range: MainRange, nav_range: NavRange, body_len: usize) void {
    writeHTTPHeaders(out, http, body_len);
    out.writeSlice(http.body[0..main_range.open_end]);
    writeAdjustedNav(out, nav, current_path);
    out.writeSlice("<article class=\"docs-content\">");
    out.writeSlice(http.body[main_range.open_end..nav_range.start]);
    out.writeSlice(http.body[nav_range.end..main_range.close_start]);
    out.writeSlice("</article>");
    out.writeSlice(http.body[main_range.close_start..]);
}

fn inputOffset(input: []const u8, slice: []const u8) u32 {
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(input.ptr);
    if (offset > std.math.maxInt(u32)) @trap();
    return @as(u32, @intCast(offset));
}

fn indexArchive(input: []const u8) ArchiveIndex {
    var record_count: usize = 0;
    var nav: ?PreparedNav = null;
    var docs_page_decided = false;
    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;
        if (record_count >= indexed_records.len) @trap();

        var path: []const u8 = "";
        var flags: u8 = 0;
        if (eqlIgnoreCase(record.warc_type, "response")) {
            path = pathFromTargetURI(record.target_uri);
            if (docsPath(path)) flags |= INDEXED_RECORD_IS_DOCS_RESPONSE;

            if (!docs_page_decided and std.mem.eql(u8, path, "/docs")) {
                if (parseHTTPPayload(record.payload)) |http| {
                    if (http.status == 200 and isHTMLContentType(http.content_type)) {
                        docs_page_decided = true;
                        if (findMainRange(http.body)) |range| {
                            if (findDocsNavRange(http.body, range)) |nav_range| {
                                nav = prepareNav(http.body[nav_range.start..nav_range.end]);
                            }
                        }
                    }
                }
            }
        }

        indexed_records[record_count] = .{
            .header_start = inputOffset(input, record.header_block),
            .header_end = inputOffset(input, record.header_block) + @as(u32, @intCast(record.header_block.len)),
            .payload_start = inputOffset(input, record.payload),
            .payload_end = inputOffset(input, record.payload) + @as(u32, @intCast(record.payload.len)),
            .path_start = if (flags & INDEXED_RECORD_IS_DOCS_RESPONSE != 0) inputOffset(input, path) else 0,
            .path_end = if (flags & INDEXED_RECORD_IS_DOCS_RESPONSE != 0)
                inputOffset(input, path) + @as(u32, @intCast(path.len))
            else
                0,
            .flags = flags,
        };
        record_count += 1;
    }
    return .{
        .records = indexed_records[0..record_count],
        .nav = nav,
    };
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

fn processWARC(input: []const u8, out: *Output) void {
    const archive = indexArchive(input);
    for (archive.records) |indexed| {
        if (out.overflow) break;
        const record = indexedWARCRecord(input, indexed);
        var payload_to_write: ?HTTPPayload = null;
        var main_range: ?MainRange = null;
        var nav_range: ?NavRange = null;
        var rewritten_body_len: usize = 0;
        var payload_len = record.payload.len;
        const request_path = input[indexed.path_start..indexed.path_end];

        if (archive.nav != null and indexed.flags & INDEXED_RECORD_IS_DOCS_RESPONSE != 0) {
            if (parseHTTPPayload(record.payload)) |http| {
                if (http.status == 200 and isHTMLContentType(http.content_type) and std.mem.eql(u8, request_path, "/docs")) {
                    if (findMainRange(http.body)) |range| {
                        if (!mainStartsWithDocsSidebar(http.body, range)) {
                            if (findDocsNavRange(http.body, range)) |docs_nav_range| {
                                const body_len = injectedRootDocsBodyLen(http.body, archive.nav.?, request_path, docs_nav_range);
                                payload_len = computeHeaderRewriteLen(http, body_len) + body_len;
                                payload_to_write = http;
                                main_range = range;
                                nav_range = docs_nav_range;
                                rewritten_body_len = body_len;
                            }
                        }
                    }
                } else if (http.status == 200 and isHTMLContentType(http.content_type) and childDocsPath(request_path)) {
                    if (findMainRange(http.body)) |range| {
                        // The sidebar only ever goes first in <main>, so that is
                        // the only place to look for one already there.
                        if (!mainStartsWithDocsSidebar(http.body, range)) {
                            const body_len = injectedBodyLen(http.body, archive.nav.?, request_path);
                            payload_len = computeHeaderRewriteLen(http, body_len) + body_len;
                            payload_to_write = http;
                            main_range = range;
                            rewritten_body_len = body_len;
                        }
                    }
                }
            }
        }

        writeWARCRecordHeader(out, record, payload_len, payload_to_write != null);
        if (payload_to_write) |http| {
            if (std.mem.eql(u8, request_path, "/docs")) {
                writeRootDocsHTTPPayloadWithSidebar(out, http, archive.nav.?, request_path, main_range.?, nav_range.?, rewritten_body_len);
            } else {
                writeHTTPPayloadWithSidebar(out, http, archive.nav.?, request_path, main_range.?, rewritten_body_len);
            }
        } else {
            out.writeSlice(record.payload);
        }
        out.writeSlice("\r\n\r\n");
    }
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    var out = Output{};
    processWARC(input_buf[0..input_size], &out);
    if (out.overflow) @trap();
    if (!warc.validateArchive(output_buf[0..out.idx])) @trap();
    return @as(u32, @intCast(out.idx));
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

fn appendWARCRecord(out_buf: []u8, cursor: *usize, warc_type: []const u8, target_uri: []const u8, payload: []const u8) !void {
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.1\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ warc_type, target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += rec.len;
}

fn runTransform(input: []const u8, out: []u8) ![]const u8 {
    @memset(out, 0);
    @memcpy(input_buf[0..input.len], input);
    const n = renderImpl(@as(u32, @intCast(input.len)));
    if (n > out.len) return error.OutputTooSmall;
    @memcpy(out[0..n], output_buf[0..n]);
    return out[0..n];
}

test "injects docs sidebar from docs index into docs child page" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html><body><main><h1>Docs</h1><p>Start here.</p><nav class=\"docs-sidebar\" aria-label=\"Docs\"><ol><li><a href=\"/docs/security-model\">Security Model</a></li><li><a href=\"/docs/router\">Router</a></li></ol></nav></main></body></html>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs/security-model",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html><body><main><h1>Security Model</h1></main></body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "class=\"docs-sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "href=\"/docs/security-model\" aria-current=\"page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "href=\"/docs/router\" aria-current=\"page\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<article class=\"docs-content\"><h1>Security Model</h1></article>") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<main><nav class=\"docs-sidebar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<article class=\"docs-content\"><h1>Docs</h1><p>Start here.</p></article>") != null);
}

test "moves aria-current to the page's link and leaves pages that already have a sidebar" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html><body><main><h1>Docs</h1><nav class=\"docs-sidebar\"><abbr>API</abbr><a href=\"/docs\" aria-current=\"page\">Docs</a> <a href=\"/docs/router\">Router</a></nav></main></body></html>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs/router",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<main><h1>Router</h1></main>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs/done",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<main>\n<nav class=\"docs-sidebar\"></nav><h1>Done</h1></main>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<main><nav class=\"docs-sidebar\"><abbr>API</abbr><a href=\"/docs\" aria-current=\"page\">Docs</a> <a href=\"/docs/router\">Router</a></nav><article class=\"docs-content\"><h1>Docs</h1></article></main>") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<main><nav class=\"docs-sidebar\"><abbr>API</abbr><a href=\"/docs\">Docs</a> <a href=\"/docs/router\" aria-current=\"page\">Router</a></nav><article class=\"docs-content\"><h1>Router</h1></article></main>") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<main>\n<nav class=\"docs-sidebar\"></nav><h1>Done</h1></main>") != null);
}
