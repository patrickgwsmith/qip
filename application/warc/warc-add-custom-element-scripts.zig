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

const ElementEntry = struct {
    name: []const u8,
    request_path: []const u8,
};

const MAX_ELEMENT_ENTRIES: usize = 4096;
var element_entries: [MAX_ELEMENT_ENTRIES]ElementEntry = undefined;
var element_usage: [MAX_ELEMENT_ENTRIES]u8 = undefined;
var required_element_indices: [MAX_ELEMENT_ENTRIES]u16 = undefined;

const INDEXED_RECORD_IS_HTML: u8 = 1;
const MAX_WARC_RECORDS: usize = 65536;

const IndexedRecord = struct {
    header_start: u32,
    header_end: u32,
    payload_start: u32,
    payload_end: u32,
    flags: u8,
};

// Twenty bytes per entry keeps the complete 65,536-record index to 1.25 MiB.
comptime {
    if (@sizeOf(IndexedRecord) != 20) @compileError("IndexedRecord must remain compact");
}

const ArchiveIndex = struct {
    records: []const IndexedRecord,
    elements: []const ElementEntry,
};

var indexed_records: [MAX_WARC_RECORDS]IndexedRecord = undefined;

const ELEMENT_TAG_PRESENT: u8 = 1;
const ELEMENT_SCRIPT_PRESENT: u8 = 2;

const Output = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Output) usize {
        return output_buf.len - self.idx;
    }

    fn writeByte(self: *Output, b: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
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

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len or haystack.len - start < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

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

fn skipASCIIWhitespaceIn(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) : (i += 1) {}
    return i;
}

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (start >= buf.len) return null;
    if (std.mem.indexOfPos(u8, buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (std.mem.indexOfPos(u8, buf, start, "\n\n")) |pos| return pos + 2;
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

fn isTextHTMLContentType(content_type_raw: []const u8) bool {
    const token = mimeTypeToken(content_type_raw);
    return token.len > 0 and eqlIgnoreCase(token, "text/html");
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
    return c == '>' or c == '/' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
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

fn digits10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) n /= 10;
    return digits;
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

fn isCustomElementName(name: []const u8) bool {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '-') == null) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    if (name.len >= 3 and eqlIgnoreCase(name[0..3], "xml")) return false;
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

test "element entrypoint names must start with a lowercase letter" {
    try std.testing.expect(isCustomElementName("qip-play"));
    try std.testing.expect(!isCustomElementName("_qip-ktx2"));
}

fn elementEntryFromTargetURI(record: WARCRecord) ?ElementEntry {
    if (!eqlIgnoreCase(record.warc_type, "response")) return null;
    const request_path = pathFromTargetURI(record.target_uri);
    const prefix = "/elements/";
    if (!std.mem.startsWith(u8, request_path, prefix)) return null;
    const filename = request_path[prefix.len..];
    if (filename.len <= ".js".len or std.mem.indexOfScalar(u8, filename, '/') != null or !std.mem.endsWith(u8, filename, ".js")) return null;
    const name = filename[0 .. filename.len - ".js".len];
    if (!isCustomElementName(name)) return null;
    return .{ .name = name, .request_path = request_path };
}

fn findLastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i = haystack.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn tagAttributeValue(tag: []const u8, wanted_name: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < tag.len and !isTagBoundary(tag[i])) : (i += 1) {}
    while (i < tag.len) {
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len or tag[i] == '>' or tag[i] == '/') return null;
        const name_start = i;
        while (i < tag.len and tag[i] != '=' and !isTagBoundary(tag[i])) : (i += 1) {}
        const name = tag[name_start..i];
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len) return null;
        var value: []const u8 = "";
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            i += 1;
            const value_start = i;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            if (i >= tag.len) return null;
            value = tag[value_start..i];
            i += 1;
        } else {
            const value_start = i;
            while (i < tag.len and !isTagBoundary(tag[i])) : (i += 1) {}
            value = tag[value_start..i];
        }
        if (eqlIgnoreCase(name, wanted_name)) return value;
    }
    return null;
}

fn elementIndexByName(elements: []const ElementEntry, name: []const u8) ?usize {
    for (elements, 0..) |element, index| {
        if (eqlIgnoreCase(element.name, name)) return index;
    }
    return null;
}

fn elementIndexByRequestPath(elements: []const ElementEntry, request_path: []const u8) ?usize {
    for (elements, 0..) |element, index| {
        if (std.mem.eql(u8, element.request_path, request_path)) return index;
    }
    return null;
}

fn requiredElements(elements: []const ElementEntry, body: []const u8) []const u16 {
    @memset(element_usage[0..elements.len], 0);
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "<")) |start| {
        if (start + 4 <= body.len and std.mem.eql(u8, body[start .. start + 4], "<!--")) {
            cursor = if (std.mem.indexOfPos(u8, body, start + 4, "-->")) |end| end + 3 else body.len;
            continue;
        }
        const name_start = start + 1;
        if (name_start >= body.len) return required_element_indices[0..0];
        if (body[name_start] == '/' or body[name_start] == '!' or body[name_start] == '?') {
            cursor = start + 1;
            continue;
        }
        const tag_end = findTagEnd(body, start) orelse return required_element_indices[0..0];
        var name_end = name_start;
        while (name_end < body.len and !isTagBoundary(body[name_end])) : (name_end += 1) {}
        const name = body[name_start..name_end];

        if (elementIndexByName(elements, name)) |index| {
            element_usage[index] |= ELEMENT_TAG_PRESENT;
        }

        if (eqlIgnoreCase(name, "script")) {
            const tag = body[start .. tag_end + 1];
            if (tagAttributeValue(tag, "src")) |src| {
                if (elementIndexByRequestPath(elements, src)) |index| {
                    element_usage[index] |= ELEMENT_SCRIPT_PRESENT;
                }
            }
        }

        if (eqlIgnoreCase(name, "script") or eqlIgnoreCase(name, "style") or eqlIgnoreCase(name, "textarea") or eqlIgnoreCase(name, "title")) {
            var close_buf: [32]u8 = undefined;
            if (name.len + 2 <= close_buf.len) {
                close_buf[0] = '<';
                close_buf[1] = '/';
                @memcpy(close_buf[2 .. name.len + 2], name);
                cursor = if (indexOfIgnoreCase(body, close_buf[0 .. name.len + 2], tag_end + 1)) |close| close + name.len + 2 else body.len;
                continue;
            }
        }
        cursor = tag_end + 1;
    }

    var required_count: usize = 0;
    for (element_usage[0..elements.len], 0..) |usage, index| {
        if (usage & ELEMENT_TAG_PRESENT == 0 or usage & ELEMENT_SCRIPT_PRESENT != 0) continue;
        required_element_indices[required_count] = @as(u16, @intCast(index));
        required_count += 1;
    }
    return required_element_indices[0..required_count];
}

fn scriptTagLen(request_path: []const u8) usize {
    return "<script type=\"module\" src=\"".len + request_path.len + "\"></script>\n".len;
}

fn inputOffset(input: []const u8, slice: []const u8) u32 {
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(input.ptr);
    if (offset > std.math.maxInt(u32)) @trap();
    return @as(u32, @intCast(offset));
}

fn indexArchive(input: []const u8) ArchiveIndex {
    var record_count: usize = 0;
    var element_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;

        if (record_count >= indexed_records.len) @trap();
        var flags: u8 = 0;
        const element = elementEntryFromTargetURI(record);
        if (eqlIgnoreCase(record.warc_type, "response")) {
            const http = parseHTTPPayload(record.payload) orelse @trap();
            if (isTextHTMLContentType(http.content_type)) {
                flags |= INDEXED_RECORD_IS_HTML;
            }
            if (element) |entry| {
                if (http.status >= 200 and http.status < 300) {
                    if (element_count >= element_entries.len) @trap();
                    element_entries[element_count] = entry;
                    element_count += 1;
                }
            }
        }
        indexed_records[record_count] = .{
            .header_start = inputOffset(input, record.header_block),
            .header_end = inputOffset(input, record.header_block) + @as(u32, @intCast(record.header_block.len)),
            .payload_start = inputOffset(input, record.payload),
            .payload_end = inputOffset(input, record.payload) + @as(u32, @intCast(record.payload.len)),
            .flags = flags,
        };
        record_count += 1;
    }
    return .{
        .records = indexed_records[0..record_count],
        .elements = element_entries[0..element_count],
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

fn addedScriptsLen(elements: []const ElementEntry, required: []const u16) usize {
    var total: usize = 0;
    for (required) |index| {
        total += scriptTagLen(elements[index].request_path);
    }
    return total;
}

fn writeAddedScripts(elements: []const ElementEntry, required: []const u16, out: *Output) void {
    for (required) |index| {
        const element = elements[index];
        out.writeSlice("<script type=\"module\" src=\"");
        out.writeSlice(element.request_path);
        out.writeSlice("\"></script>\n");
    }
}

fn writeHTTPPayloadWithElementScripts(elements: []const ElementEntry, required: []const u16, out: *Output, http: HTTPPayload, added_len: usize) void {
    writeHTTPHeaders(out, http, http.body.len + added_len);
    const insert_at = findLastIndexOfIgnoreCase(http.body, "</body>") orelse http.body.len;
    out.writeSlice(http.body[0..insert_at]);
    writeAddedScripts(elements, required, out);
    out.writeSlice(http.body[insert_at..]);
}

fn processWARC(input: []const u8, out: *Output) void {
    const archive = indexArchive(input);
    for (archive.records) |indexed| {
        if (out.overflow) break;
        const record = indexedWARCRecord(input, indexed);

        var payload_to_write: ?HTTPPayload = null;
        var required: []const u16 = &.{};
        var scripts_len: usize = 0;
        var payload_len = record.payload.len;

        if (indexed.flags & INDEXED_RECORD_IS_HTML != 0) {
            if (parseHTTPPayload(record.payload)) |http| {
                required = requiredElements(archive.elements, http.body);
                scripts_len = addedScriptsLen(archive.elements, required);
                if (scripts_len > 0) {
                    const body_len = http.body.len + scripts_len;
                    payload_len = computeHeaderRewriteLen(http, body_len) + body_len;
                    payload_to_write = http;
                }
            }
        }

        writeWARCRecordHeader(out, record, payload_len, payload_to_write != null);
        if (payload_to_write) |http| {
            writeHTTPPayloadWithElementScripts(archive.elements, required, out, http, scripts_len);
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

test "adds scripts only for available custom elements used by the page" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/page",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html><body><copy-code></copy-code><unused-box></unused-box></body></html>",
    );
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/elements/copy-code.js", "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\ncustomElements.define('copy-code', class extends HTMLElement {});");
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/elements/other-box.js", "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport {};");

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<script type=\"module\" src=\"/elements/copy-code.js\"></script>\n</body>") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "/elements/other-box.js\"></script>") == null);
}

test "ignores examples and existing module scripts" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/page",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><!-- <copy-code></copy-code> --><textarea><copy-code></copy-code></textarea><script type=\"module\" src=\"/elements/live-box.js\"></script><live-box></live-box></body></html>",
    );
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/elements/copy-code.js", "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport {};");
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/elements/live-box.js", "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport {};");

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, transformed, "/elements/live-box.js\"></script>"));
    try std.testing.expect(std.mem.indexOf(u8, transformed, "/elements/copy-code.js\"></script>") == null);
}

test "nested modules are not custom element entrypoints" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/page",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><shared-helper></shared-helper></body></html>",
    );
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/elements/lib/shared-helper.js", "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport {};");

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "src=\"/elements/lib/shared-helper.js\"") == null);
}

test "scans each html page independently and ignores scripts in comments" {
    var warc_buf: [16384]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/first",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><!-- <script src=\"/elements/copy-code.js\"></script> --><copy-code></copy-code></body></html>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/second",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><p>No custom element here.</p></body></html>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/elements/copy-code.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport {};",
    );

    var out: [32768]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, transformed, "<script type=\"module\" src=\"/elements/copy-code.js\"></script>"),
    );
}

test "indexes ordinary html separately from custom element discovery" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/page",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><copy-code></copy-code></body></html>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/image.png",
        "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nPNG",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/elements/copy-code.js",
        "HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport {};",
    );

    @memcpy(input_buf[0..n], warc_buf[0..n]);
    const archive = indexArchive(input_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 3), archive.records.len);
    try std.testing.expect(archive.records[0].flags & INDEXED_RECORD_IS_HTML != 0);
    try std.testing.expectEqual(@as(u8, 0), archive.records[1].flags);
    try std.testing.expectEqual(@as(u8, 0), archive.records[2].flags);
    try std.testing.expectEqual(@as(usize, 1), archive.elements.len);
    try std.testing.expectEqualStrings("copy-code", archive.elements[0].name);
}
