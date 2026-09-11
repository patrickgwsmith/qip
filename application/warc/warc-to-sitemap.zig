const std = @import("std");

const INPUT_CAP: usize = 32 * 1024 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/xml";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
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

const WARCRecord = struct {
    next: usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
};

const Output = struct {
    index: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Output) usize {
        return output_buf.len - self.index;
    }

    fn writeByte(self: *Output, b: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.index] = b;
        self.index += 1;
    }

    fn writeSlice(self: *Output, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.remaining() < s.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.index .. self.index + s.len], s);
        self.index += s.len;
    }
};

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

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eqlIgnoreCase(s[0..prefix.len], prefix);
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

fn findHeaderEnd(buf: []const u8, start: usize) ?struct { end: usize, delim_len: usize } {
    if (start >= buf.len) return null;

    if (std.mem.indexOfPos(u8, buf, start, "\r\n\r\n")) |pos| {
        return .{ .end = pos + 4, .delim_len = 4 };
    }
    if (std.mem.indexOfPos(u8, buf, start, "\n\n")) |pos| {
        return .{ .end = pos + 2, .delim_len = 2 };
    }
    return null;
}

fn parseUnsigned10(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var value: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit = @as(usize, c - '0');
        value = value * 10 + digit;
    }
    return value;
}

fn parseStatusCode(line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    if (i >= line.len) return null;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const code_start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == code_start) return null;
    const code_slice = line[code_start..i];
    const code = parseUnsigned10(code_slice) orelse return null;
    if (code > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(code));
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const head = findHeaderEnd(input, start) orelse return null;
    const header_slice = input[start..head.end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl_rel = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < header_slice.len) nl_rel + 1 else header_slice.len;
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
    if (head.end + payload_len > input.len) return null;
    const payload = input[head.end .. head.end + payload_len];

    var next = head.end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{
        .next = next,
        .warc_type = warc_type,
        .target_uri = target_uri,
        .payload = payload,
    };
}

fn parseHTTPMeta(payload: []const u8) ?HTTPMeta {
    const head = findHeaderEnd(payload, 0) orelse return null;
    const header_slice = payload[0..head.end];
    var status: ?u16 = null;
    var content_type: []const u8 = "";

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl_rel = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < header_slice.len) nl_rel + 1 else header_slice.len;
        if (line.len == 0) break;

        if (line_index == 0) {
            status = parseStatusCode(line);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "Content-Type")) {
            content_type = value;
        }
    }

    return .{
        .status = status orelse return null,
        .content_type = content_type,
    };
}

fn canonicalSitemapURI(uri_raw: []const u8) ?[]const u8 {
    var uri = trimASCIIWhitespace(uri_raw);
    if (uri.len == 0) return null;

    if (!startsWithIgnoreCase(uri, "http://") and !startsWithIgnoreCase(uri, "https://")) {
        return null;
    }

    if (std.mem.indexOfScalar(u8, uri, '#')) |idx| {
        uri = uri[0..idx];
    }
    if (uri.len == 0) return null;
    return uri;
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return trimASCIIWhitespace(content_type[0..end]);
}

fn isSitemapPageContentType(content_type_raw: []const u8) bool {
    const content_type = mimeTypeToken(content_type_raw);
    if (content_type.len == 0) return false;
    return eqlIgnoreCase(content_type, "text/html") or eqlIgnoreCase(content_type, "application/xhtml+xml");
}

fn writeXMLEscaped(out: *Output, value: []const u8) void {
    for (value) |c| {
        switch (c) {
            '&' => out.writeSlice("&amp;"),
            '<' => out.writeSlice("&lt;"),
            '>' => out.writeSlice("&gt;"),
            '"' => out.writeSlice("&quot;"),
            '\'' => out.writeSlice("&apos;"),
            else => out.writeByte(c),
        }
    }
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    const input = input_buf[0..input_size];
    var out = Output{};
    var cursor: usize = 0;

    out.writeSlice("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.writeSlice("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;

        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        const uri = canonicalSitemapURI(rec.target_uri) orelse continue;

        const http = parseHTTPMeta(rec.payload) orelse continue;
        if (http.status != 200) continue;
        if (!isSitemapPageContentType(http.content_type)) continue;

        out.writeSlice("  <url><loc>");
        writeXMLEscaped(&out, uri);
        out.writeSlice("</loc></url>\n");
        if (out.overflow) @trap();
    }

    out.writeSlice("</urlset>\n");
    if (out.overflow) @trap();
    return @as(u32, @intCast(out.index));
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

fn appendWARCRecord(
    out_buf: []u8,
    cursor: *usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
) !void {
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.1\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ warc_type, target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += rec.len;
}

test "run emits sitemap entries for successful html responses" {
    var build_buf: [4096]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\nhome",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/style.css",
        "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\n\r\nbody{}",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/missing",
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\nmissing",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "https://example.com/about?a=1&b=2#frag",
        "HTTP/1.1 200 OK\r\nContent-Type: Application/XHTML+XML\r\n\r\nok",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "metadata",
        "https://example.com/ignored",
        "ignored",
    );

    @memcpy(input_buf[0..n], build_buf[0..n]);
    const out_len = renderImpl(@as(u32, @intCast(n)));
    const got = output_buf[0..out_len];

    const expected =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n" ++
        "  <url><loc>http://qip.local/</loc></url>\n" ++
        "  <url><loc>https://example.com/about?a=1&amp;b=2</loc></url>\n" ++
        "</urlset>\n";
    try std.testing.expectEqualStrings(expected, got);
}
