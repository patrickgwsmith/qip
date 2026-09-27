const std = @import("std");
const warc = @import("lib/warc.zig");
const html_anchor = @import("html_anchor");

const CAP: usize = 256 * 1024 * 1024;
const HTML_CAP: usize = 8 * 1024 * 1024;
const CONTENT_TYPE = "application/warc";

var input_buf: [CAP]u8 = undefined;
var output_buf: [CAP]u8 = undefined;
var html_buf: [HTML_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return CAP;
}

export fn output_bytes_cap() u32 {
    return CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

const Writer = struct {
    index: usize = 0,
    overflow: bool = false,

    pub fn writeSlice(self: *Writer, bytes: []const u8) void {
        if (self.overflow or bytes.len > output_buf.len - self.index) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.index..][0..bytes.len], bytes);
        self.index += bytes.len;
    }

    pub fn writeUnsigned(self: *Writer, value: usize) void {
        var buffer: [32]u8 = undefined;
        self.writeSlice(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
    }
};

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    while (line_start < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, line_start, "\r\n") orelse return null;
        const line = headers[line_start..line_end];
        line_start = line_end + 2;
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (warc.eqlIgnoreCase(line[0..colon], name)) return warc.trimASCIIWhitespace(line[colon + 1 ..]);
    }
    return null;
}

fn htmlContentType(headers: []const u8) bool {
    const content_type = headerValue(headers, "Content-Type") orelse return false;
    const end = std.mem.indexOfAny(u8, content_type, "; \t") orelse content_type.len;
    return warc.eqlIgnoreCase(content_type[0..end], "text/html");
}

fn transformArchive(input: []const u8) ?usize {
    var writer = Writer{};
    var cursor: usize = 0;
    while (cursor < input.len) {
        const header_end = (std.mem.indexOfPos(u8, input, cursor, "\r\n\r\n") orelse return null) + 4;
        const headers = input[cursor..header_end];
        const length_text = headerValue(headers, "Content-Length") orelse return null;
        const payload_length = std.fmt.parseUnsigned(usize, length_text, 10) catch return null;
        const payload_end = std.math.add(usize, header_end, payload_length) catch return null;
        if (payload_end > input.len or input.len - payload_end < 4 or
            !std.mem.eql(u8, input[payload_end .. payload_end + 4], "\r\n\r\n")) return null;
        const next = payload_end + 4;

        const kind = headerValue(headers, "WARC-Type") orelse return null;
        if (!warc.eqlIgnoreCase(kind, "response")) {
            writer.writeSlice(input[cursor..next]);
            cursor = next;
            continue;
        }
        const payload = input[header_end..payload_end];
        const http_header_end = (std.mem.indexOf(u8, payload, "\r\n\r\n") orelse return null) + 4;
        const http_headers = payload[0..http_header_end];
        if (!htmlContentType(http_headers)) {
            writer.writeSlice(input[cursor..next]);
            cursor = next;
            continue;
        }
        const body = payload[http_header_end..];
        const html_length = html_anchor.addWasmAnchorTypes(body, &html_buf) orelse return null;
        if (html_length == body.len) {
            writer.writeSlice(input[cursor..next]);
            cursor = next;
            continue;
        }
        const status_end = std.mem.indexOf(u8, http_headers, "\r\n") orelse return null;
        const status_line = http_headers[0..status_end];
        const new_payload_length = warc.httpHeaderRewriteLen(http_headers, status_line, html_length) + html_length;
        warc.writeRecordHeader(&writer, headers, new_payload_length, true);
        warc.writeRewrittenHTTPHeaders(&writer, http_headers, status_line, html_length);
        writer.writeSlice(html_buf[0..html_length]);
        writer.writeSlice("\r\n\r\n");
        cursor = next;
    }
    return if (writer.overflow) null else writer.index;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const size = transformArchive(input_buf[0..input_size]) orelse return .{
        .output_size = 0,
        .output_ptr = 0,
        .failed = 1,
    };
    return .{
        .output_size = @intCast(size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "rewrites HTML response lengths and preserves non-HTML records" {
    const html = "<p><a href=/component.wasm>component</a></p>";
    const http = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ html.len, html },
    );
    const response = std.fmt.comptimePrint(
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Date: 2026-09-27T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:one>\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ http.len, http },
    );
    const binary_http = "HTTP/1.1 200 OK\r\nContent-Type: application/wasm\r\nContent-Length: 4\r\n\r\n\x00asm";
    const binary_response = std.fmt.comptimePrint(
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Date: 2026-09-27T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:two>\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ binary_http.len, binary_http },
    );
    const written = transformArchive(response ++ binary_response) orelse unreachable;
    const result = output_buf[0..written];
    try std.testing.expect(warc.validateArchive(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "<a href=/component.wasm type=\"application/wasm\">") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, binary_response));
}
