const std = @import("std");
const warc = @import("lib/warc.zig");
// Only the encoder: std.base64.url_safe_no_pad also carries the decoder's lookup tables.
const ni_base64 = std.base64.Base64Encoder.init(std.base64.url_safe_alphabet_chars, null);

const INPUT_CAP: usize = 256 * 1024 * 1024;
const FEED_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP + FEED_CAP + 4096;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";
const FEED_PATH = "/components.atom";
const FEED_TITLE = "qip components";
const QIP_NAMESPACE = "https://qip.dev/ns/components";

var input_buf: [INPUT_CAP]u8 = undefined;
var feed_buf: [FEED_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const WARCRecord = struct {
    next: usize,
    header_block: []const u8,
    warc_type: []const u8,
    target_uri: []const u8,
    warc_date: []const u8,
    payload_digest: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

const BuildError = error{
    InvalidWARC,
    InvalidHTTP,
    MissingOrigin,
    MixedOrigins,
    ExistingFeed,
    FeedTooLarge,
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
    var payload_digest: []const u8 = "";
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
        } else if (warc.eqlIgnoreCase(key, "WARC-Payload-Digest")) {
            payload_digest = value;
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
        .payload_digest = payload_digest,
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

    return .{
        .status = status orelse return null,
        .content_type = content_type,
        .body = payload[header_end..],
    };
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = warc.trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return warc.trimASCIIWhitespace(content_type[0..end]);
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

fn readLEB128U32(bytes: []const u8, idx: *usize) ?u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (idx.* < bytes.len) {
        const byte = bytes[idx.*];
        idx.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift == 28) return null;
        shift += 7;
    }
    return null;
}

/// A QIP component exports either a Tile entry point, or a Content `render`
/// function with an output capacity. Other wasm served by the site (comply
/// oracles, font data, third-party modules) does not.
fn isQIPComponent(wasm: []const u8) bool {
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..8], "\x00asm\x01\x00\x00\x00")) return false;
    var idx: usize = 8;
    while (idx < wasm.len) {
        const section_id = wasm[idx];
        idx += 1;
        const size: usize = readLEB128U32(wasm, &idx) orelse return false;
        if (size > wasm.len - idx) return false;
        const section = wasm[idx .. idx + size];
        idx += size;
        if (section_id != 7) continue;

        var cursor: usize = 0;
        const count = readLEB128U32(section, &cursor) orelse return false;
        var has_render = false;
        var has_output_cap = false;
        var has_tile = false;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const name_len: usize = readLEB128U32(section, &cursor) orelse return false;
            if (name_len > section.len - cursor) return false;
            const name = section[cursor .. cursor + name_len];
            cursor += name_len;
            if (cursor >= section.len) return false;
            const kind = section[cursor];
            cursor += 1;
            _ = readLEB128U32(section, &cursor) orelse return false;
            if (kind != 0) continue;
            if (std.mem.eql(u8, name, "render")) has_render = true;
            if (std.mem.eql(u8, name, "tile_rgba32float_64x64")) has_tile = true;
            if (std.mem.eql(u8, name, "output_utf8_cap") or std.mem.eql(u8, name, "output_bytes_cap")) has_output_cap = true;
        }
        return has_tile or (has_render and has_output_cap);
    }
    return false;
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

/// Reads a hex `sha256:` WARC-Payload-Digest. qip routers add one to every
/// response and verify it after each recipe, so hashing in wasm is only a
/// fallback for archives from elsewhere.
fn parseSHA256PayloadDigest(value: []const u8, digest: *[32]u8) bool {
    const prefix = "sha256:";
    if (value.len != prefix.len + 64 or !warc.eqlIgnoreCase(value[0..prefix.len], prefix)) return false;
    _ = std.fmt.hexToBytes(digest, value[prefix.len..]) catch return false;
    return true;
}

fn writeFeedEntry(feed: *Writer, uri: []const u8, path: []const u8, updated: []const u8, wasm: []const u8, payload_digest: []const u8) BuildError!void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (!parseSHA256PayloadDigest(payload_digest, &digest)) {
        std.crypto.hash.sha2.Sha256.hash(wasm, &digest, .{});
    }
    const hex = std.fmt.bytesToHex(digest, .lower);
    var ni_buf: [ni_base64.calcSize(digest.len)]u8 = undefined;
    const ni = ni_base64.encode(&ni_buf, &digest);

    try feed.writeSlice("  <entry>\n");
    // RFC 6920 named-information URI: the entry id changes whenever the bytes do.
    try feed.writeSlice("    <id>ni:///sha-256;");
    try feed.writeSlice(ni);
    try feed.writeSlice("</id>\n    <title>");
    try writeXMLEscaped(feed, std.mem.trimLeft(u8, path, "/"));
    try feed.writeSlice("</title>\n    <updated>");
    try writeXMLEscaped(feed, updated);
    try feed.writeSlice("</updated>\n    <link rel=\"enclosure\" type=\"application/wasm\" length=\"");
    try feed.writeUnsigned(wasm.len);
    try feed.writeSlice("\" href=\"");
    try writeXMLEscaped(feed, uri);
    try feed.writeSlice("\"/>\n    <content type=\"application/wasm\" src=\"");
    try writeXMLEscaped(feed, uri);
    try feed.writeSlice("\"/>\n    <summary>sha256 ");
    try feed.writeSlice(&hex);
    try feed.writeSlice("</summary>\n    <qip:sha256>");
    try feed.writeSlice(&hex);
    try feed.writeSlice("</qip:sha256>\n  </entry>\n");
}

fn appendFeedRecord(
    out: *Writer,
    origin: []const u8,
    warc_date: []const u8,
    feed: []const u8,
) BuildError!void {
    const http_prefix = "HTTP/1.1 200 OK\r\nContent-Type: application/atom+xml; charset=utf-8\r\nContent-Length: ";
    const http_suffix = "\r\n\r\n";
    var content_length_buf: [32]u8 = undefined;
    const xml_len = std.fmt.bufPrint(&content_length_buf, "{d}", .{feed.len}) catch unreachable;
    const http_payload_len = http_prefix.len + xml_len.len + http_suffix.len + feed.len;

    try out.writeSlice("WARC/1.1\r\n");
    try out.writeSlice("WARC-Type: response\r\n");
    try out.writeSlice("WARC-Target-URI: ");
    try out.writeSlice(origin);
    try out.writeSlice(FEED_PATH);
    try out.writeSlice("\r\n");
    try out.writeSlice("WARC-Date: ");
    try out.writeSlice(warc_date);
    try out.writeSlice("\r\n");
    try out.writeSlice("WARC-Record-ID: <urn:qip:components-atom:");
    try out.writeHex64(fnv1a64(feed));
    try out.writeSlice(">\r\n");
    try out.writeSlice("Content-Type: application/http; msgtype=response\r\n");
    try out.writeSlice("Content-Length: ");
    try out.writeUnsigned(http_payload_len);
    try out.writeSlice("\r\n\r\n");
    try out.writeSlice(http_prefix);
    try out.writeSlice(xml_len);
    try out.writeSlice(http_suffix);
    try out.writeSlice(feed);
    try out.writeSlice("\r\n\r\n");
}

fn writeFeedHead(feed: *Writer, origin: []const u8, updated: []const u8) BuildError!void {
    try feed.writeSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try feed.writeSlice("<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:qip=\"" ++ QIP_NAMESPACE ++ "\">\n");
    try feed.writeSlice("  <id>");
    try writeXMLEscaped(feed, origin);
    try feed.writeSlice(FEED_PATH ++ "</id>\n");
    try feed.writeSlice("  <title>" ++ FEED_TITLE ++ "</title>\n");
    try feed.writeSlice("  <updated>");
    try writeXMLEscaped(feed, updated);
    try feed.writeSlice("</updated>\n");
    try feed.writeSlice("  <author><name>qip</name></author>\n");
    try feed.writeSlice("  <link rel=\"self\" type=\"application/atom+xml\" href=\"");
    try writeXMLEscaped(feed, origin);
    try feed.writeSlice(FEED_PATH ++ "\"/>\n");
    try feed.writeSlice("  <link rel=\"alternate\" type=\"text/html\" href=\"");
    try writeXMLEscaped(feed, origin);
    try feed.writeSlice("/\"/>\n");
}

fn addComponentsFeed(input: []const u8, output: []u8, feed_storage: []u8) BuildError!usize {
    if (!warc.validateArchive(input)) return error.InvalidWARC;

    // The feed head needs the origin and date, which are only known once the
    // first record is read, so entries are written first and the head is
    // spliced in front of them afterwards.
    var entries = Writer.init(feed_storage);

    var cursor: usize = 0;
    var origin: ?[]const u8 = null;
    // Archives without components (such as qip-router's single-page route
    // probe) still get an empty feed, using the first response's origin.
    var first_origin: ?[]const u8 = null;
    var archive_date: ?[]const u8 = null;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse return error.InvalidWARC;
        cursor = record.next;
        if (archive_date == null and record.warc_date.len > 0) archive_date = record.warc_date;
        if (!warc.eqlIgnoreCase(record.warc_type, "response")) continue;

        const record_origin = absoluteURIOrigin(record.target_uri) orelse continue;
        const path = absoluteURIPath(record.target_uri) orelse continue;
        if (std.mem.eql(u8, path, FEED_PATH)) return error.ExistingFeed;
        if (first_origin == null) first_origin = record_origin;

        const http = parseHTTPMeta(record.payload) orelse return error.InvalidHTTP;
        if (http.status != 200 or !warc.eqlIgnoreCase(mimeTypeToken(http.content_type), "application/wasm")) continue;
        if (!isQIPComponent(http.body)) continue;
        if (origin) |expected_origin| {
            if (!warc.eqlIgnoreCase(expected_origin, record_origin)) return error.MixedOrigins;
        } else {
            origin = record_origin;
        }

        writeFeedEntry(&entries, uriWithoutFragment(record.target_uri), path, archive_date.?, http.body, record.payload_digest) catch |err| {
            return if (err == error.OutputTooLarge) error.FeedTooLarge else err;
        };
    }

    const site_origin = origin orelse first_origin orelse return error.MissingOrigin;
    const record_date = archive_date orelse return error.InvalidWARC;

    var head_buf: [4096]u8 = undefined;
    var head = Writer.init(&head_buf);
    try writeFeedHead(&head, site_origin, record_date);
    const tail = "</feed>\n";
    const entries_len = entries.idx;
    const feed_len = head.idx + entries_len + tail.len;
    if (feed_len > feed_storage.len) return error.FeedTooLarge;
    std.mem.copyBackwards(u8, feed_storage[head.idx .. head.idx + entries_len], feed_storage[0..entries_len]);
    @memcpy(feed_storage[0..head.idx], head_buf[0..head.idx]);
    @memcpy(feed_storage[head.idx + entries_len .. feed_len], tail);

    var out = Writer.init(output);
    try out.writeSlice(input);
    if (!std.mem.endsWith(u8, input, "\r\n\r\n")) try out.writeSlice("\r\n\r\n");
    try appendFeedRecord(&out, site_origin, record_date, feed_storage[0..feed_len]);
    if (!warc.validateArchive(output[0..out.idx])) return error.InvalidWARC;
    return out.idx;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    const written = addComponentsFeed(input_buf[0..input_size], output_buf[0..], feed_buf[0..]) catch @trap();
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

// Module exporting functions "render" and "output_utf8_cap" (bodies omitted;
// only the export section is inspected).
const test_component_wasm = "\x00asm\x01\x00\x00\x00" ++
    "\x07\x1c\x02" ++
    "\x06render\x00\x00" ++
    "\x0foutput_utf8_cap\x00\x01";

// Module exporting "tile_rgba32float_64x64", like rgba filters.
const test_tile_wasm = "\x00asm\x01\x00\x00\x00" ++
    "\x07\x1a\x01" ++
    "\x16tile_rgba32float_64x64\x00\x00";

// Module exporting only "comply", like the site's oracles.
const test_oracle_wasm = "\x00asm\x01\x00\x00\x00" ++
    "\x07\x0a\x01" ++
    "\x06comply\x00\x00";

test "appends components feed with sha256 of each component" {
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
        "https://qip.dev/image/svg+xml/a&b.wasm",
        "HTTP/1.1 200 OK\r\nContent-Type: application/wasm\r\n\r\n" ++ test_component_wasm,
    );
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/oracles/luhn.comply.wasm",
        "HTTP/1.1 200 OK\r\nContent-Type: application/wasm\r\n\r\n" ++ test_oracle_wasm,
    );
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/interactive/aces-up.wasm",
        "HTTP/1.1 302 Found\r\nLocation: /gui/aces-up.wasm\r\nContent-Length: 0\r\n\r\n",
    );

    var output: [16384]u8 = undefined;
    var feed_storage: [8192]u8 = undefined;
    const written = try addComponentsFeed(input[0..input_len], &output, &feed_storage);
    const result = output[0..written];

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(test_component_wasm, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var expected_hash_buf: [128]u8 = undefined;
    const expected_hash = try std.fmt.bufPrint(&expected_hash_buf, "<qip:sha256>{s}</qip:sha256>", .{hex});

    try std.testing.expectEqualSlices(u8, input[0..input_len], result[0..input_len]);
    try std.testing.expect(warc.validateArchive(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "WARC-Target-URI: https://qip.dev/components.atom") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Type: application/atom+xml; charset=utf-8") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<id>https://qip.dev/components.atom</id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<title>image/svg+xml/a&amp;b.wasm</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"https://qip.dev/image/svg+xml/a&amp;b.wasm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, expected_hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, result[input_len..], "luhn.comply.wasm") == null);
    try std.testing.expect(std.mem.indexOf(u8, result[input_len..], "aces-up.wasm") == null);
    try std.testing.expect(std.mem.endsWith(u8, result, "</entry>\n</feed>\n\r\n\r\n"));
}

test "appends an empty feed when the archive has no components" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nhome",
    );

    var output: [16384]u8 = undefined;
    var feed_storage: [8192]u8 = undefined;
    const written = try addComponentsFeed(input[0..input_len], &output, &feed_storage);
    const result = output[0..written];

    try std.testing.expect(warc.validateArchive(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "WARC-Target-URI: http://qip.local/components.atom") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<entry>") == null);
    try std.testing.expect(std.mem.endsWith(u8, result, "</feed>\n\r\n\r\n"));
}

test "uses the WARC-Payload-Digest instead of rehashing" {
    var digest: [32]u8 = undefined;
    try std.testing.expect(parseSHA256PayloadDigest("sha256:" ++ "ab" ** 32, &digest));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xab} ** 32), &digest);
    try std.testing.expect(!parseSHA256PayloadDigest("sha1:" ++ "ab" ** 20, &digest));
    try std.testing.expect(!parseSHA256PayloadDigest("sha256:FTZE3OS7WCRQ4JXIHMVMLOPCTYNRMHS4D6TUEXTTAQZWFE4LTASA", &digest));

    var input: [4096]u8 = undefined;
    const payload = "HTTP/1.1 200 OK\r\nContent-Type: application/wasm\r\n\r\n" ++ test_component_wasm;
    const record = try std.fmt.bufPrint(
        &input,
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: https://qip.dev/a.wasm\r\nWARC-Date: 2026-07-24T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000000>\r\nWARC-Payload-Digest: sha256:{s}\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ "cd" ** 32, payload.len, payload },
    );
    var output: [16384]u8 = undefined;
    var feed_storage: [8192]u8 = undefined;
    const written = try addComponentsFeed(record, &output, &feed_storage);
    try std.testing.expect(std.mem.indexOf(u8, output[0..written], "<qip:sha256>" ++ "cd" ** 32 ++ "</qip:sha256>") != null);
}

test "recognizes QIP components by their exports" {
    try std.testing.expect(isQIPComponent(test_component_wasm));
    try std.testing.expect(isQIPComponent(test_tile_wasm));
    try std.testing.expect(!isQIPComponent(test_oracle_wasm));
    try std.testing.expect(!isQIPComponent("not wasm"));
    try std.testing.expect(!isQIPComponent("\x00asm\x01\x00\x00\x00\x07\x7f"));
}

test "rejects an existing components feed route" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendTestRecord(
        &input,
        &input_len,
        "response",
        "https://qip.dev/components.atom",
        "HTTP/1.1 200 OK\r\nContent-Type: application/atom+xml\r\n\r\n<feed/>",
    );

    var output: [8192]u8 = undefined;
    var feed_storage: [4096]u8 = undefined;
    try std.testing.expectError(
        error.ExistingFeed,
        addComponentsFeed(input[0..input_len], &output, &feed_storage),
    );
}
