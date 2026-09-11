const std = @import("std");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 128 * 1024 * 1024;
const TAR_BLOCK: usize = 512;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/x-tar";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

const WARCRecord = struct {
    next: usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPResponse = struct {
    status: u16,
    location: []const u8,
    body: []const u8,
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

    fn writeZeros(self: *Output, count: usize) void {
        if (self.overflow or count == 0) return;
        if (self.remaining() < count) {
            self.overflow = true;
            return;
        }
        @memset(output_buf[self.index .. self.index + count], 0);
        self.index += count;
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

fn parseHTTPResponse(payload: []const u8) ?HTTPResponse {
    const head = findHeaderEnd(payload, 0) orelse return null;
    const headers = payload[0..head.end];
    const first_nl = std.mem.indexOfScalar(u8, headers, '\n') orelse headers.len;
    var status_line = headers[0..first_nl];
    if (status_line.len > 0 and status_line[status_line.len - 1] == '\r') {
        status_line = status_line[0 .. status_line.len - 1];
    }
    const status = parseStatusCode(status_line) orelse return null;
    var location: []const u8 = "";

    var line_start = first_nl + 1;
    while (line_start < headers.len) {
        const nl_rel = std.mem.indexOfPos(u8, headers, line_start, "\n") orelse headers.len;
        var line = headers[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < headers.len) nl_rel + 1 else headers.len;
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "Location")) {
            location = value;
        }
    }

    return .{
        .status = status,
        .location = location,
        .body = payload[head.end..],
    };
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
    } else if (uri[0] != '/') {
        if (std.mem.indexOfScalar(u8, uri, '/')) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    }

    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, path, '#')) |pos| end = @min(end, pos);
    path = path[0..end];
    if (path.len == 0) return "/";
    if (path[0] != '/') return "/";
    return path;
}

fn hasExtension(rel: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
    const base = if (slash) |idx| rel[idx + 1 ..] else rel;
    return std.mem.lastIndexOfScalar(u8, base, '.') != null;
}

fn isSafeRelativePath(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    if (std.mem.startsWith(u8, rel, "../") or std.mem.eql(u8, rel, "..")) return false;
    if (std.mem.indexOf(u8, rel, "/../") != null) return false;
    if (std.mem.endsWith(u8, rel, "/..")) return false;
    if (std.mem.indexOf(u8, rel, "/./") != null) return false;
    if (std.mem.startsWith(u8, rel, "./") or std.mem.eql(u8, rel, ".")) return false;
    if (std.mem.endsWith(u8, rel, "/.")) return false;
    if (std.mem.indexOf(u8, rel, "//") != null) return false;
    return true;
}

fn isRedirectStatus(status: u16) bool {
    return status >= 300 and status <= 399;
}

fn hasRedirectsWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') return true;
    }
    return false;
}

fn appendStatus(out: *Output, status: u16) void {
    var tmp: [5]u8 = undefined;
    var value = status;
    var i = tmp.len;
    while (true) {
        i -= 1;
        tmp[i] = @as(u8, @intCast('0' + (value % 10)));
        value /= 10;
        if (value == 0) break;
    }
    out.writeSlice(tmp[i..]);
}

fn isRedirectsPath(request_path: []const u8) bool {
    return std.mem.eql(u8, request_path, "/_redirects");
}

fn mapPathNoTrailingSlash(request_path: []const u8, buf: []u8) ?[]const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return null;

    if (isRedirectsPath(request_path)) {
        if (buf.len < "_redirects".len) return null;
        @memcpy(buf[0.."_redirects".len], "_redirects");
        return buf[0.."_redirects".len];
    }

    if (std.mem.eql(u8, request_path, "/")) {
        if (buf.len < "index.html".len) return null;
        @memcpy(buf[0.."index.html".len], "index.html");
        return buf[0.."index.html".len];
    }

    var rel = request_path[1..];
    while (rel.len > 0 and rel[rel.len - 1] == '/') {
        rel = rel[0 .. rel.len - 1];
    }
    if (rel.len == 0) {
        if (buf.len < "index.html".len) return null;
        @memcpy(buf[0.."index.html".len], "index.html");
        return buf[0.."index.html".len];
    }

    if (!isSafeRelativePath(rel)) return null;

    if (hasExtension(rel)) {
        if (buf.len < rel.len) return null;
        @memcpy(buf[0..rel.len], rel);
        return buf[0..rel.len];
    }

    const suffix = ".html";
    if (buf.len < rel.len + suffix.len) return null;
    @memcpy(buf[0..rel.len], rel);
    @memcpy(buf[rel.len .. rel.len + suffix.len], suffix);
    return buf[0 .. rel.len + suffix.len];
}

fn writeOctal(field: []u8, value: u64) bool {
    if (field.len < 2) return false;
    @memset(field, '0');
    field[field.len - 1] = 0;
    var v = value;
    var i: usize = field.len - 2;
    while (true) {
        field[i] = @as(u8, @intCast('0' + (v & 7)));
        v >>= 3;
        if (v == 0) break;
        if (i == 0) return false;
        i -= 1;
    }
    return true;
}

fn writeChecksum(field: []u8, checksum: u64) bool {
    if (field.len < 8) return false;
    @memset(field, 0);
    var tmp: [6]u8 = undefined;
    if (!writeOctal(tmp[0..], checksum)) return false;
    @memcpy(field[0..6], tmp[0..6]);
    field[6] = 0;
    field[7] = ' ';
    return true;
}

fn buildTarHeader(path: []const u8, size: usize, out: *[TAR_BLOCK]u8) bool {
    if (path.len == 0 or path.len > 100) return false;
    @memset(out[0..], 0);

    @memcpy(out[0..path.len], path);
    if (!writeOctal(out[100..108], 0o644)) return false;
    if (!writeOctal(out[108..116], 0)) return false;
    if (!writeOctal(out[116..124], 0)) return false;
    if (!writeOctal(out[124..136], @intCast(size))) return false;
    if (!writeOctal(out[136..148], 0)) return false;

    @memset(out[148..156], ' ');
    out[156] = '0';

    @memcpy(out[257..263], "ustar\x00");
    @memcpy(out[263..265], "00");

    var sum: u64 = 0;
    for (out[0..]) |b| {
        sum += b;
    }
    if (!writeChecksum(out[148..156], sum)) return false;
    return true;
}

fn writeTarEntry(out: *Output, path: []const u8, body: []const u8) void {
    var header: [TAR_BLOCK]u8 = undefined;
    if (!buildTarHeader(path, body.len, &header)) {
        out.overflow = true;
        return;
    }
    out.writeSlice(header[0..]);
    out.writeSlice(body);
    const rem = body.len % TAR_BLOCK;
    if (rem != 0) {
        out.writeZeros(TAR_BLOCK - rem);
    }
}

fn writeRedirectsBody(out: *Output, input: []const u8) void {
    var cursor: usize = 0;

    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;

        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        if (rec.target_uri.len == 0) continue;

        const http = parseHTTPResponse(rec.payload) orelse continue;
        const req_path = pathFromTargetURI(rec.target_uri);

        if (!isRedirectStatus(http.status) or http.location.len == 0) continue;
        if (hasRedirectsWhitespace(req_path) or hasRedirectsWhitespace(http.location)) continue;
        out.writeSlice(req_path);
        out.writeByte(' ');
        out.writeSlice(http.location);
        out.writeByte(' ');
        appendStatus(out, http.status);
        out.writeByte('\n');
    }
}

fn writeRedirectsTarEntry(out: *Output, input: []const u8) void {
    const header_index = out.index;
    out.writeZeros(TAR_BLOCK);
    const body_start = out.index;
    writeRedirectsBody(out, input);
    if (out.overflow) return;

    const body_len = out.index - body_start;
    if (body_len == 0) {
        out.index = header_index;
        return;
    }

    var header: [TAR_BLOCK]u8 = undefined;
    if (!buildTarHeader("_redirects", body_len, &header)) {
        out.overflow = true;
        return;
    }
    @memcpy(output_buf[header_index .. header_index + TAR_BLOCK], header[0..]);

    const rem = body_len % TAR_BLOCK;
    if (rem != 0) out.writeZeros(TAR_BLOCK - rem);
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    const input = input_buf[0..input_size];
    var out = Output{};
    var cursor: usize = 0;
    var path_buf: [512]u8 = undefined;

    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;

        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        if (rec.target_uri.len == 0) continue;

        const http = parseHTTPResponse(rec.payload) orelse continue;
        if (http.status != 200) continue;

        const req_path = pathFromTargetURI(rec.target_uri);
        if (isRedirectsPath(req_path)) continue;
        const archive_path = mapPathNoTrailingSlash(req_path, path_buf[0..]) orelse continue;
        writeTarEntry(&out, archive_path, http.body);
        if (out.overflow) @trap();
    }

    writeRedirectsTarEntry(&out, input);
    if (out.overflow) @trap();

    out.writeZeros(TAR_BLOCK * 2);
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

test "path mapping no trailing slash" {
    var tmp: [128]u8 = undefined;
    try std.testing.expectEqualStrings("index.html", mapPathNoTrailingSlash("/", tmp[0..]).?);
    try std.testing.expectEqualStrings("about.html", mapPathNoTrailingSlash("/about", tmp[0..]).?);
    try std.testing.expectEqualStrings("img/logo.png", mapPathNoTrailingSlash("/img/logo.png", tmp[0..]).?);
    try std.testing.expectEqualStrings("_redirects", mapPathNoTrailingSlash("/_redirects", tmp[0..]).?);
}

test "redirects body includes WARC redirects only" {
    const warc =
        "WARC/1.1\r\n" ++
        "WARC-Type: response\r\n" ++
        "WARC-Target-URI: http://example.test/_redirects\r\n" ++
        "Content-Length: 39\r\n" ++
        "\r\n" ++
        "HTTP/1.1 200 OK\r\n\r\n" ++
        "/old-docs /docs 301\n" ++
        "\r\n\r\n" ++
        "WARC/1.1\r\n" ++
        "WARC-Type: response\r\n" ++
        "WARC-Target-URI: http://example.test/start\r\n" ++
        "Content-Length: 39\r\n" ++
        "\r\n" ++
        "HTTP/1.1 302 Found\r\n" ++
        "Location: /docs\r\n" ++
        "\r\n" ++
        "\r\n\r\n";

    var out = Output{};
    writeRedirectsBody(&out, warc);
    try std.testing.expectEqualStrings("/start /docs 302\n", output_buf[0..out.index]);
}

test "render writes redirects tar entry" {
    const warc =
        "WARC/1.1\r\n" ++
        "WARC-Type: response\r\n" ++
        "WARC-Target-URI: http://example.test/index.html\r\n" ++
        "Content-Length: 27\r\n" ++
        "\r\n" ++
        "HTTP/1.1 200 OK\r\n\r\n" ++
        "home" ++
        "\r\n\r\n" ++
        "WARC/1.1\r\n" ++
        "WARC-Type: response\r\n" ++
        "WARC-Target-URI: http://example.test/start\r\n" ++
        "Content-Length: 39\r\n" ++
        "\r\n" ++
        "HTTP/1.1 302 Found\r\n" ++
        "Location: /docs\r\n" ++
        "\r\n" ++
        "\r\n\r\n";

    @memcpy(input_buf[0..warc.len], warc);
    const size = renderImpl(@intCast(warc.len));
    const tar = output_buf[0..size];
    try std.testing.expect(std.mem.indexOf(u8, tar, "index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar, "_redirects") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar, "/start /docs 302\n") != null);
}
