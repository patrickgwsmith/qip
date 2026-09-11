const std = @import("std");
const warc = @import("lib/warc.zig");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";

const META_OG_IMAGE_PREFIX = "<meta property=\"og:image\" content=\"";
const META_OG_IMAGE_SUFFIX = "\" />\n";
const META_TWITTER_CARD = "<meta name=\"twitter:card\" content=\"summary_large_image\" />\n";
const META_TWITTER_IMAGE_PREFIX = "<meta name=\"twitter:image\" content=\"";
const META_TWITTER_IMAGE_SUFFIX = "\" />\n";

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

const BodyInjection = struct {
    should_inject: bool,
    insert_at: usize,
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

    return .{
        .next = next,
        .header_block = header_slice,
        .warc_type = warc_type,
        .target_uri = target_uri,
        .payload = payload,
    };
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
        if (std.mem.indexOfPos(u8, uri, after_scheme, "/")) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (startsWithIgnoreCase(uri, "//")) {
        if (std.mem.indexOfPos(u8, uri, 2, "/")) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (uri[0] != '/') {
        if (std.mem.indexOfScalar(u8, uri, '/')) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    }

    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, path, '#')) |idx| end = @min(end, idx);
    path = path[0..end];
    if (path.len == 0 or path[0] != '/') return "/";
    return path;
}

fn hasExtension(path_rel: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path_rel, '/');
    const base = if (slash) |idx| path_rel[idx + 1 ..] else path_rel;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    return dot != null;
}

fn stripLastExtension(path_rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path_rel, '/');
    const base = if (slash) |idx| path_rel[idx + 1 ..] else path_rel;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return path_rel;
    if (dot == 0) return path_rel;
    if (slash) |idx| {
        return path_rel[0 .. idx + 1 + dot];
    }
    return path_rel[0..dot];
}

fn ogImagePathForRequestPath(request_path: []const u8, out_buf: []u8) ?[]const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return null;

    var rel = request_path[1..];
    while (rel.len > 0 and rel[rel.len - 1] == '/') rel = rel[0 .. rel.len - 1];
    if (rel.len == 0) rel = "index";

    if (hasExtension(rel)) {
        rel = stripLastExtension(rel);
    }

    if (std.mem.endsWith(u8, rel, "/index")) {
        rel = rel[0 .. rel.len - "/index".len];
        while (rel.len > 0 and rel[rel.len - 1] == '/') rel = rel[0 .. rel.len - 1];
    } else if (std.mem.eql(u8, rel, "index")) {
        rel = "";
    }

    if (rel.len == 0) rel = "index";

    const needed = "/_og/".len + rel.len + ".png".len;
    if (needed > out_buf.len) return null;
    var i: usize = 0;
    @memcpy(out_buf[i .. i + "/_og/".len], "/_og/");
    i += "/_og/".len;
    @memcpy(out_buf[i .. i + rel.len], rel);
    i += rel.len;
    @memcpy(out_buf[i .. i + ".png".len], ".png");
    i += ".png".len;
    return out_buf[0..i];
}

fn isTagBoundary(c: u8) bool {
    return c == '>' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

const IMAGE_META_MARKERS = [_][]const u8{
    "property=\"og:image\"",
    "property='og:image'",
    "name=\"twitter:image\"",
    "name='twitter:image'",
};

fn startsWithIgnoreCaseAt(input: []const u8, start: usize, needle: []const u8) bool {
    return start <= input.len and needle.len <= input.len - start and
        eqlIgnoreCase(input[start .. start + needle.len], needle);
}

fn findTagEndAfter(body: []const u8, start: usize) ?usize {
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
        if (c == '>') return i + 1;
    }
    return null;
}

fn metaSnippetLen(og_path: []const u8) usize {
    return META_OG_IMAGE_PREFIX.len + og_path.len + META_OG_IMAGE_SUFFIX.len +
        META_TWITTER_CARD.len +
        META_TWITTER_IMAGE_PREFIX.len + og_path.len + META_TWITTER_IMAGE_SUFFIX.len;
}

fn writeMetaSnippet(out: *Output, og_path: []const u8) void {
    out.writeSlice(META_OG_IMAGE_PREFIX);
    out.writeSlice(og_path);
    out.writeSlice(META_OG_IMAGE_SUFFIX);
    out.writeSlice(META_TWITTER_CARD);
    out.writeSlice(META_TWITTER_IMAGE_PREFIX);
    out.writeSlice(og_path);
    out.writeSlice(META_TWITTER_IMAGE_SUFFIX);
}

fn computeHeaderRewriteLen(http: HTTPPayload, body_len: usize) usize {
    return warc.httpHeaderRewriteLen(http.header_block, http.status_line, body_len);
}

fn digits10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) n /= 10;
    return digits;
}

fn writeWARCRecordHeader(out: *Output, record: WARCRecord, payload_len: usize, changed: bool) void {
    warc.writeRecordHeader(out, record.header_block, payload_len, changed);
}

fn writeHTTPPayload(out: *Output, http: HTTPPayload, body_injection: BodyInjection, og_path: []const u8) void {
    const injected_body_len = if (body_injection.should_inject) http.body.len + metaSnippetLen(og_path) else http.body.len;
    warc.writeRewrittenHTTPHeaders(out, http.header_block, http.status_line, injected_body_len);

    if (!body_injection.should_inject) {
        out.writeSlice(http.body);
        return;
    }

    out.writeSlice(http.body[0..body_injection.insert_at]);
    writeMetaSnippet(out, og_path);
    out.writeSlice(http.body[body_injection.insert_at..]);
}

fn computeBodyInjection(body: []const u8) BodyInjection {
    var head_open_end: ?usize = null;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '<') {
            if (startsWithIgnoreCaseAt(body, i + 1, "/head")) {
                const boundary = i + 1 + "/head".len;
                if (boundary >= body.len or isTagBoundary(body[boundary])) {
                    return .{ .should_inject = true, .insert_at = i };
                }
            } else if (head_open_end == null and startsWithIgnoreCaseAt(body, i + 1, "head")) {
                const boundary = i + 1 + "head".len;
                if (boundary >= body.len or isTagBoundary(body[boundary])) {
                    head_open_end = findTagEndAfter(body, boundary);
                }
            }
        } else if (body[i] == 'p' or body[i] == 'P' or body[i] == 'n' or body[i] == 'N') {
            for (IMAGE_META_MARKERS) |marker| {
                if (startsWithIgnoreCaseAt(body, i, marker)) {
                    return .{ .should_inject = false, .insert_at = 0 };
                }
            }
        }
    }
    if (head_open_end) |insert_at| {
        return .{ .should_inject = true, .insert_at = insert_at };
    }
    return .{ .should_inject = false, .insert_at = 0 };
}

fn processWARC(input: []const u8, out: *Output) void {
    var cursor: usize = 0;
    var og_path_buf: [4096]u8 = undefined;

    while (cursor < input.len and !out.overflow) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;

        var payload_to_write: ?HTTPPayload = null;
        var injection = BodyInjection{ .should_inject = false, .insert_at = 0 };
        var og_path: []const u8 = "";
        var payload_len = record.payload.len;

        if (eqlIgnoreCase(record.warc_type, "response")) {
            if (parseHTTPPayload(record.payload)) |http| {
                if (http.status == 200 and isHTMLContentType(http.content_type)) {
                    const request_path = pathFromTargetURI(record.target_uri);
                    if (ogImagePathForRequestPath(request_path, og_path_buf[0..])) |path_value| {
                        injection = computeBodyInjection(http.body);
                        if (injection.should_inject) {
                            og_path = path_value;
                            const body_len = http.body.len + metaSnippetLen(og_path);
                            payload_len = computeHeaderRewriteLen(http, body_len) + body_len;
                            payload_to_write = http;
                        }
                    }
                }
            }
        }

        if (payload_to_write) |http| {
            writeWARCRecordHeader(out, record, payload_len, true);
            writeHTTPPayload(out, http, injection, og_path);
        } else {
            writeWARCRecordHeader(out, record, record.payload.len, false);
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

test "injects og image tags for html response" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/how-it-works",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html><head><title>x</title></head><body>ok</body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "property=\"og:image\" content=\"/_og/how-it-works.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "name=\"twitter:image\" content=\"/_og/how-it-works.png\"") != null);
}

test "maps docs index route to docs og image path" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/docs",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head></head><body>docs</body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "property=\"og:image\" content=\"/_og/docs.png\"") != null);
}

test "keeps existing og tags unchanged" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><meta property=\"og:image\" content=\"/existing.png\" /></head><body>x</body></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "content=\"/existing.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "twitter:image") == null);
}

test "injects when head is not explicitly closed" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/forms",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<!doctype html><html><head><meta charset=\"utf-8\"><style>h1{color:red}</style><main>hello</main></html>",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "property=\"og:image\" content=\"/_og/forms.png\"") != null);
}
