const std = @import("std");
const warc = @import("lib/warc.zig");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const SITEMAP_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP + SITEMAP_CAP + 4096;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";
const SITEMAP_PATH = "/sitemap.xml";

var input_buf: [INPUT_CAP]u8 = undefined;
var sitemap_buf: [SITEMAP_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const WARCRecord = struct {
    next: usize,
    header_block: []const u8,
    warc_type: []const u8,
    target_uri: []const u8,
    warc_date: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
};

const BuildError = error{
    InvalidWARC,
    InvalidHTTP,
    MissingOrigin,
    MixedOrigins,
    ExistingSitemap,
    SitemapTooLarge,
    OutputTooLarge,
};

const Writer = struct {
    buf: []u8,
    idx: usize = 0,

    fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    fn writeByte(self: *Writer, value: u8) BuildError!void {
        if (self.idx >= self.buf.len) return error.OutputTooLarge;
        self.buf[self.idx] = value;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, value: []const u8) BuildError!void {
        if (value.len > self.buf.len - self.idx) return error.OutputTooLarge;
        @memcpy(self.buf[self.idx .. self.idx + value.len], value);
        self.idx += value.len;
    }

    fn writeUnsigned(self: *Writer, value: usize) BuildError!void {
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.writeSlice(formatted);
    }

    fn writeHex64(self: *Writer, value: u64) BuildError!void {
        const digits = "0123456789abcdef";
        var shift: u6 = 60;
        while (true) {
            try self.writeByte(digits[@as(usize, @intCast((value >> shift) & 0xf))]);
            if (shift == 0) break;
            shift -= 4;
        }
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

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (start >= buf.len) return null;
    if (warc.indexOfPos(buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (warc.indexOfPos(buf, start, "\n\n")) |pos| return pos + 2;
    return null;
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
    const header_block = input[start..header_end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var warc_date: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = warc.trimASCIIWhitespace(line);
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0) {
            if (!std.mem.eql(u8, line, "WARC/1.0") and !std.mem.eql(u8, line, "WARC/1.1")) return null;
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = warc.trimASCIIWhitespace(line[0..colon]);
        const value = warc.trimASCIIWhitespace(line[colon + 1 ..]);
        if (warc.eqlIgnoreCase(key, "WARC-Type")) {
            warc_type = value;
        } else if (warc.eqlIgnoreCase(key, "WARC-Target-URI")) {
            target_uri = value;
        } else if (warc.eqlIgnoreCase(key, "WARC-Date")) {
            warc_date = value;
        } else if (warc.eqlIgnoreCase(key, "Content-Length")) {
            if (content_length != null) return null;
            content_length = parseUnsigned10(value);
        }
    }

    const payload_len = content_length orelse return null;
    if (header_end > input.len or payload_len > input.len - header_end) return null;
    const payload = input[header_end .. header_end + payload_len];
    var next = header_end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{
        .next = next,
        .header_block = header_block,
        .warc_type = warc_type,
        .target_uri = target_uri,
        .warc_date = warc_date,
        .payload = payload,
    };
}

fn parseHTTPMeta(payload: []const u8) ?HTTPMeta {
    const header_end = findHeaderEnd(payload, 0) orelse return null;
    const header_block = payload[0..header_end];
    var status: ?u16 = null;
    var content_type: []const u8 = "";

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = warc.trimASCIIWhitespace(line);
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0) {
            status = parseStatusCode(line);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = warc.trimASCIIWhitespace(line[0..colon]);
        const value = warc.trimASCIIWhitespace(line[colon + 1 ..]);
        if (warc.eqlIgnoreCase(key, "Content-Type")) content_type = value;
    }

    return .{ .status = status orelse return null, .content_type = content_type };
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = warc.trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return warc.trimASCIIWhitespace(content_type[0..end]);
}

fn isHTML(content_type_raw: []const u8) bool {
    const content_type = mimeTypeToken(content_type_raw);
    return warc.eqlIgnoreCase(content_type, "text/html") or
        warc.eqlIgnoreCase(content_type, "application/xhtml+xml");
}

fn uriWithoutFragment(uri_raw: []const u8) []const u8 {
    const uri = warc.trimASCIIWhitespace(uri_raw);
    const hash = std.mem.indexOfScalar(u8, uri, '#') orelse uri.len;
    return uri[0..hash];
}

fn absoluteURIOrigin(uri_raw: []const u8) ?[]const u8 {
    const uri = uriWithoutFragment(uri_raw);
    const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return null;
    const scheme = uri[0..scheme_end];
    if (!warc.eqlIgnoreCase(scheme, "http") and !warc.eqlIgnoreCase(scheme, "https")) return null;
    const authority_start = scheme_end + 3;
    if (authority_start >= uri.len) return null;
    var authority_end = authority_start;
    while (authority_end < uri.len and uri[authority_end] != '/' and uri[authority_end] != '?') : (authority_end += 1) {}
    if (authority_end == authority_start) return null;
    return uri[0..authority_end];
}

fn absoluteURIPath(uri_raw: []const u8) ?[]const u8 {
    const uri = uriWithoutFragment(uri_raw);
    const origin = absoluteURIOrigin(uri) orelse return null;
    if (origin.len == uri.len) return "/";
    if (uri[origin.len] == '?') return "/";
    const query = std.mem.indexOfScalarPos(u8, uri, origin.len, '?') orelse uri.len;
    return uri[origin.len..query];
}

fn writeXMLEscaped(out: *Writer, value: []const u8) BuildError!void {
    for (value) |c| {
        switch (c) {
            '&' => try out.writeSlice("&amp;"),
            '<' => try out.writeSlice("&lt;"),
            '>' => try out.writeSlice("&gt;"),
            '"' => try out.writeSlice("&quot;"),
            '\'' => try out.writeSlice("&apos;"),
            else => try out.writeByte(c),
        }
    }
}

fn fnv1a64(value: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (value) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn appendSitemapRecord(
    out: *Writer,
    origin: []const u8,
    warc_date: []const u8,
    sitemap: []const u8,
) BuildError!void {
    const http_prefix = "HTTP/1.1 200 OK\r\nContent-Type: application/xml; charset=utf-8\r\nContent-Length: ";
    const http_suffix = "\r\n\r\n";
    var content_length_buf: [32]u8 = undefined;
    const xml_len = std.fmt.bufPrint(&content_length_buf, "{d}", .{sitemap.len}) catch unreachable;
    const http_payload_len = http_prefix.len + xml_len.len + http_suffix.len + sitemap.len;

    try out.writeSlice("WARC/1.1\r\n");
    try out.writeSlice("WARC-Type: response\r\n");
    try out.writeSlice("WARC-Target-URI: ");
    try out.writeSlice(origin);
    try out.writeSlice(SITEMAP_PATH);
    try out.writeSlice("\r\n");
    try out.writeSlice("WARC-Date: ");
    try out.writeSlice(warc_date);
    try out.writeSlice("\r\n");
    try out.writeSlice("WARC-Record-ID: <urn:qip:sitemap:");
    try out.writeHex64(fnv1a64(sitemap));
    try out.writeSlice(">\r\n");
    try out.writeSlice("Content-Type: application/http; msgtype=response\r\n");
    try out.writeSlice("Content-Length: ");
    try out.writeUnsigned(http_payload_len);
    try out.writeSlice("\r\n\r\n");
    try out.writeSlice(http_prefix);
    try out.writeSlice(xml_len);
    try out.writeSlice(http_suffix);
    try out.writeSlice(sitemap);
    try out.writeSlice("\r\n\r\n");
}

fn addSitemap(input: []const u8, output: []u8, sitemap_storage: []u8) BuildError!usize {
    if (!warc.validateArchive(input)) return error.InvalidWARC;

    var sitemap = Writer.init(sitemap_storage);
    try sitemap.writeSlice("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try sitemap.writeSlice("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    var cursor: usize = 0;
    var origin: ?[]const u8 = null;
    var archive_date: ?[]const u8 = null;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse return error.InvalidWARC;
        cursor = record.next;
        if (archive_date == null and record.warc_date.len > 0) archive_date = record.warc_date;
        if (!warc.eqlIgnoreCase(record.warc_type, "response")) continue;

        const record_origin = absoluteURIOrigin(record.target_uri) orelse continue;
        if (absoluteURIPath(record.target_uri)) |path| {
            if (std.mem.eql(u8, path, SITEMAP_PATH)) return error.ExistingSitemap;
        }

        const http = parseHTTPMeta(record.payload) orelse return error.InvalidHTTP;
        if (http.status != 200 or !isHTML(http.content_type)) continue;
        if (origin) |expected_origin| {
            if (!warc.eqlIgnoreCase(expected_origin, record_origin)) return error.MixedOrigins;
        } else {
            origin = record_origin;
        }

        try sitemap.writeSlice("  <url><loc>");
        try writeXMLEscaped(&sitemap, uriWithoutFragment(record.target_uri));
        try sitemap.writeSlice("</loc></url>\n");
    }
    try sitemap.writeSlice("</urlset>\n");

    const site_origin = origin orelse return error.MissingOrigin;
    const record_date = archive_date orelse return error.InvalidWARC;
    var out = Writer.init(output);
    try out.writeSlice(input);
    if (!std.mem.endsWith(u8, input, "\r\n\r\n")) try out.writeSlice("\r\n\r\n");
    appendSitemapRecord(&out, site_origin, record_date, sitemap_storage[0..sitemap.idx]) catch |err| {
        return if (err == error.OutputTooLarge) error.SitemapTooLarge else err;
    };
    if (!warc.validateArchive(output[0..out.idx])) return error.InvalidWARC;
    return out.idx;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    const written = addSitemap(input_buf[0..input_size], output_buf[0..], sitemap_buf[0..]) catch @trap();
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

fn appendTestRecord(
    out: []u8,
    cursor: *usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
) !void {
    const record = try std.fmt.bufPrint(
        out[cursor.*..],
        "WARC/1.1\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2026-07-24T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ warc_type, target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += record.len;
}

test "appends sitemap response while preserving the input archive" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/docs?a=1&b=2#contract",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html></html>",
    );
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/styles.css",
        "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\n\r\nbody{}",
    );
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/missing",
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\nmissing",
    );

    var output: [8192]u8 = undefined;
    var sitemap_storage: [4096]u8 = undefined;
    const written = try addSitemap(input[0..input_len], &output, &sitemap_storage);
    const result = output[0..written];

    try std.testing.expectEqualSlices(u8, input[0..input_len], result[0..input_len]);
    try std.testing.expect(warc.validateArchive(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "WARC-Target-URI: https://qip.dev/sitemap.xml") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loc>https://qip.dev/docs?a=1&amp;b=2</loc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loc>https://qip.dev/styles.css</loc>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loc>https://qip.dev/missing</loc>") == null);
}

test "rejects HTML pages from multiple origins" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nhome",
    );
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://docs.qip.dev/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\ndocs",
    );

    var output: [8192]u8 = undefined;
    var sitemap_storage: [4096]u8 = undefined;
    try std.testing.expectError(
        error.MixedOrigins,
        addSitemap(input[0..input_len], &output, &sitemap_storage),
    );
}

test "rejects an existing sitemap route" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nhome",
    );
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/sitemap.xml",
        "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\n\r\n<urlset/>",
    );

    var output: [8192]u8 = undefined;
    var sitemap_storage: [4096]u8 = undefined;
    try std.testing.expectError(
        error.ExistingSitemap,
        addSitemap(input[0..input_len], &output, &sitemap_storage),
    );
}
