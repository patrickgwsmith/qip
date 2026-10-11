const std = @import("std");
const warc = @import("lib/warc.zig");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";
const DATA_PATH_ATTR = "data-path";

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

const TagRange = struct {
    start: usize,
    end: usize,
};

const AttributeRange = struct {
    start: usize,
    end: usize,
};

const BodyRewrite = struct {
    html_tag: TagRange,
    data_path_attr: ?AttributeRange,
    path: []const u8,
};

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

fn findOpenHTMLTag(body: []const u8) ?TagRange {
    var cursor: usize = 0;
    while (cursor + "<html".len <= body.len) {
        const start = std.mem.indexOfPos(u8, body, cursor, "<") orelse return null;
        if (start + "<html".len > body.len) return null;
        if (!eqlIgnoreCase(body[start + 1 .. start + 5], "html")) {
            cursor = start + 1;
            continue;
        }
        const boundary = start + "<html".len;
        if (boundary < body.len and !isTagBoundary(body[boundary])) {
            cursor = boundary;
            continue;
        }
        const open_end = findTagEnd(body, start) orelse return null;
        return .{ .start = start, .end = open_end + 1 };
    }
    return null;
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

fn escapedAttributeValueLen(s: []const u8) usize {
    var len: usize = 0;
    for (s) |c| {
        len += switch (c) {
            '&' => "&amp;".len,
            '<' => "&lt;".len,
            '>' => "&gt;".len,
            '"' => "&quot;".len,
            else => 1,
        };
    }
    return len;
}

fn dataPathAssignmentLen(path: []const u8) usize {
    return DATA_PATH_ATTR.len + "=\"".len + escapedAttributeValueLen(path) + "\"".len;
}

fn bodyLenWithDataPath(body: []const u8, rewrite: BodyRewrite) usize {
    const attr_len = dataPathAssignmentLen(rewrite.path);
    if (rewrite.data_path_attr) |range| {
        return body.len - (range.end - range.start) + attr_len;
    }
    return body.len + " ".len + attr_len;
}

fn writeEscapedAttributeValue(out: *Output, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '&' => out.writeSlice("&amp;"),
            '<' => out.writeSlice("&lt;"),
            '>' => out.writeSlice("&gt;"),
            '"' => out.writeSlice("&quot;"),
            else => out.writeByte(c),
        }
    }
}

fn writeDataPathAssignment(out: *Output, path: []const u8) void {
    out.writeSlice(DATA_PATH_ATTR);
    out.writeSlice("=\"");
    writeEscapedAttributeValue(out, path);
    out.writeByte('"');
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

fn writeBodyWithDataPath(out: *Output, body: []const u8, rewrite: BodyRewrite) void {
    if (rewrite.data_path_attr) |range| {
        out.writeSlice(body[0 .. rewrite.html_tag.start + range.start]);
        writeDataPathAssignment(out, rewrite.path);
        out.writeSlice(body[rewrite.html_tag.start + range.end ..]);
        return;
    }

    const insert_at = rewrite.html_tag.end - 1;
    out.writeSlice(body[0..insert_at]);
    out.writeByte(' ');
    writeDataPathAssignment(out, rewrite.path);
    out.writeSlice(body[insert_at..]);
}

fn writeHTTPPayloadWithDataPath(out: *Output, http: HTTPPayload, rewrite: BodyRewrite) void {
    const body_len = bodyLenWithDataPath(http.body, rewrite);
    writeHTTPHeaders(out, http, body_len);
    writeBodyWithDataPath(out, http.body, rewrite);
}

fn computeBodyRewrite(body: []const u8, path: []const u8) ?BodyRewrite {
    const html_tag = findOpenHTMLTag(body) orelse return null;
    const tag = body[html_tag.start..html_tag.end];
    return .{
        .html_tag = html_tag,
        .data_path_attr = findAttributeRange(tag, DATA_PATH_ATTR),
        .path = path,
    };
}

fn processWARC(input: []const u8, out: *Output) void {
    var cursor: usize = 0;
    while (cursor < input.len and !out.overflow) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;

        var payload_to_write: ?HTTPPayload = null;
        var rewrite: ?BodyRewrite = null;
        var payload_len = record.payload.len;

        if (eqlIgnoreCase(record.warc_type, "response")) {
            if (parseHTTPPayload(record.payload)) |http| {
                if (isTextHTMLContentType(http.content_type)) {
                    const request_path = pathFromTargetURI(record.target_uri);
                    if (computeBodyRewrite(http.body, request_path)) |body_rewrite| {
                        const body_len = bodyLenWithDataPath(http.body, body_rewrite);
                        payload_len = computeHeaderRewriteLen(http, body_len) + body_len;
                        payload_to_write = http;
                        rewrite = body_rewrite;
                    }
                }
            }
        }

        writeWARCRecordHeader(out, record, payload_len, payload_to_write != null);
        if (payload_to_write) |http| {
            writeHTTPPayloadWithDataPath(out, http, rewrite.?);
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

test "adds data path to html response" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs/router?from=test#section",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html lang=\"en\"><head><title>x</title></head><body>ok</body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<html lang=\"en\" data-path=\"/docs/router\">") != null);
}

test "replaces existing data path and escapes attribute value" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs/a&b\"c",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html data-path=\"/old\" class=\"page\"><body>ok</body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "<html data-path=\"/docs/a&amp;b&quot;c\" class=\"page\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "data-path=\"/old\"") == null);
}

test "leaves non text html responses unchanged" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/feed.xml",
        "HTTP/1.1 200 OK\r\nContent-Type: application/xhtml+xml\r\n\r\n<html><body>xml</body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "data-path=") == null);
}
