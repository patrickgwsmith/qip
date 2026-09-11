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
    payload: []const u8,
};

const HTTPPayload = struct {
    header_block: []const u8,
    body: []const u8,
    content_type: []const u8,
};

const Output = struct {
    idx: usize = 0,
    overflow: bool = false,

    pub fn writeSlice(self: *Output, value: []const u8) void {
        if (self.overflow or value.len == 0) return;
        if (value.len > output_buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + value.len], value);
        self.idx += value.len;
    }

    pub fn writeUnsigned(self: *Output, value: usize) void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(text);
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn findHeaderEnd(input: []const u8, start: usize) ?usize {
    const at = std.mem.indexOfPos(u8, input, start, "\r\n\r\n") orelse return null;
    return at + 4;
}

fn parseUnsigned(value: []const u8) ?usize {
    if (value.len == 0) return null;
    var result: usize = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, byte - '0') catch return null;
    }
    return result;
}

fn headerValue(header_block: []const u8, wanted: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = warc.trimASCIIWhitespace(line[0..colon]);
        if (warc.eqlIgnoreCase(name, wanted)) {
            return warc.trimASCIIWhitespace(line[colon + 1 ..]);
        }
    }
    return null;
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const header_end = findHeaderEnd(input, start) orelse return null;
    const header_block = input[start..header_end];
    const content_length = parseUnsigned(headerValue(header_block, "Content-Length") orelse return null) orelse return null;
    const payload_end = std.math.add(usize, header_end, content_length) catch return null;
    if (payload_end > input.len) return null;
    var next = payload_end;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}
    return .{
        .next = next,
        .header_block = header_block,
        .warc_type = headerValue(header_block, "WARC-Type") orelse "",
        .payload = input[header_end..payload_end],
    };
}

fn mediaType(content_type: []const u8) []const u8 {
    const trimmed = warc.trimASCIIWhitespace(content_type);
    const end = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
    return warc.trimASCIIWhitespace(trimmed[0..end]);
}

fn parseHTTPPayload(payload: []const u8) ?HTTPPayload {
    const header_end = findHeaderEnd(payload, 0) orelse return null;
    const header_block = payload[0..header_end];
    return .{
        .header_block = header_block,
        .body = payload[header_end..],
        .content_type = headerValue(header_block, "Content-Type") orelse "",
    };
}

fn firstURIListTarget(body: []const u8) ?[]const u8 {
    var start: usize = 0;
    var first_line = true;
    while (start <= body.len) {
        const nl = std.mem.indexOfPos(u8, body, start, "\n") orelse body.len;
        var line = warc.trimASCIIWhitespace(body[start..nl]);
        if (first_line) {
            first_line = false;
            if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        }
        if (line.len != 0 and line[0] != '#') return line;
        if (nl == body.len) break;
        start = nl + 1;
    }
    return null;
}

fn headerName(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return warc.trimASCIIWhitespace(line[0..colon]);
}

fn omitRedirectHeader(name: []const u8) bool {
    return warc.eqlIgnoreCase(name, "Content-Length") or
        warc.eqlIgnoreCase(name, "Content-Type") or
        warc.eqlIgnoreCase(name, "Content-Encoding") or
        warc.eqlIgnoreCase(name, "Content-Range") or
        warc.eqlIgnoreCase(name, "Transfer-Encoding") or
        warc.eqlIgnoreCase(name, "Location") or
        warc.eqlIgnoreCase(name, "ETag") or
        warc.eqlIgnoreCase(name, "Content-MD5") or
        warc.eqlIgnoreCase(name, "Digest");
}

fn preservedHTTPHeadersLen(header_block: []const u8) usize {
    var result: usize = 0;
    var line_start: usize = 0;
    var line_index: usize = 0;
    var omit_continuation = false;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (!omit_continuation) result += line.len + 2;
            continue;
        }
        const name = headerName(line) orelse @trap();
        omit_continuation = omitRedirectHeader(name);
        if (!omit_continuation) result += line.len + 2;
    }
    return result;
}

fn redirectPayloadLen(http: HTTPPayload, target: []const u8) usize {
    return "HTTP/1.1 302 Found\r\n".len +
        preservedHTTPHeadersLen(http.header_block) +
        "Location: \r\nContent-Length: 0\r\n\r\n".len +
        target.len;
}

fn writePreservedHTTPHeaders(out: *Output, header_block: []const u8) void {
    var line_start: usize = 0;
    var line_index: usize = 0;
    var omit_continuation = false;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (!omit_continuation) {
                out.writeSlice(line);
                out.writeSlice("\r\n");
            }
            continue;
        }
        const name = headerName(line) orelse @trap();
        omit_continuation = omitRedirectHeader(name);
        if (!omit_continuation) {
            out.writeSlice(line);
            out.writeSlice("\r\n");
        }
    }
}

fn writeRedirectPayload(out: *Output, http: HTTPPayload, target: []const u8) void {
    out.writeSlice("HTTP/1.1 302 Found\r\n");
    writePreservedHTTPHeaders(out, http.header_block);
    out.writeSlice("Location: ");
    out.writeSlice(target);
    out.writeSlice("\r\nContent-Length: 0\r\n\r\n");
}

fn process(input: []const u8, out: *Output) void {
    var cursor: usize = 0;
    while (cursor < input.len and !out.overflow) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor == input.len) break;
        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;

        var redirect_http: ?HTTPPayload = null;
        var redirect_target: []const u8 = "";
        var payload_len = record.payload.len;
        if (warc.eqlIgnoreCase(record.warc_type, "response")) {
            if (parseHTTPPayload(record.payload)) |http| {
                if (warc.eqlIgnoreCase(mediaType(http.content_type), "text/uri-list")) {
                    redirect_target = firstURIListTarget(http.body) orelse @trap();
                    redirect_http = http;
                    payload_len = redirectPayloadLen(http, redirect_target);
                }
            }
        }

        warc.writeRecordHeader(out, record.header_block, payload_len, redirect_http != null);
        if (redirect_http) |http| {
            writeRedirectPayload(out, http, redirect_target);
        } else {
            out.writeSlice(record.payload);
        }
        out.writeSlice("\r\n\r\n");
    }
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = input_size_u32;
    if (input_size > input_buf.len) @trap();
    var out = Output{};
    process(input_buf[0..input_size], &out);
    if (out.overflow or !warc.validateArchive(output_buf[0..out.idx])) @trap();
    return @intCast(out.idx);
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

fn appendResponse(out: []u8, target_uri: []const u8, content_type: []const u8, body: []const u8) ![]const u8 {
    const http = try std.fmt.bufPrint(
        out,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nX-Test: kept\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ content_type, body.len, body },
    );
    const http_copy_len = http.len;
    std.mem.copyBackwards(u8, out[1024 .. 1024 + http_copy_len], http);
    return std.fmt.bufPrint(
        out[0..1024],
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000001>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ target_uri, http_copy_len, out[1024 .. 1024 + http_copy_len] },
    );
}

test "converts first URI-list target to a redirect" {
    var source: [4096]u8 = undefined;
    const input = try appendResponse(&source, "http://qip.local/old", "text/uri-list", "\xef\xbb\xbf# old\r\n \r\n /new \r\n/ignored");
    @memcpy(input_buf[0..input.len], input);
    const output_len = renderImpl(@intCast(input.len));
    const output = output_buf[0..output_len];
    try std.testing.expect(std.mem.indexOf(u8, output, "HTTP/1.1 302 Found\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Location: /new\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "X-Test: kept\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Content-Type: text/uri-list") == null);
}

test "leaves other response types unchanged" {
    var source: [4096]u8 = undefined;
    const input = try appendResponse(&source, "http://qip.local/plain", "text/plain", "/new");
    @memcpy(input_buf[0..input.len], input);
    const output_len = renderImpl(@intCast(input.len));
    try std.testing.expectEqualSlices(u8, input, output_buf[0..output_len]);
}

test "rejects a URI list without a target" {
    try std.testing.expect(firstURIListTarget("# old\n \n") == null);
}
