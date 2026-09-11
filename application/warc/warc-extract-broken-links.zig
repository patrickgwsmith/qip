// Extract response pages containing broken internal links and reduce their HTML to the offending tags.
const std = @import("std");
const warc = @import("lib/warc.zig");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 128 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";
const PATH_TABLE_CAP: usize = 65536;
const HTTP_PREFIX = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n";
const WARCINFO_BLOCK = "software: qip warc-extract-broken-links\r\nformat: WARC File Format 1.1\r\n";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const PathEntry = struct {
    used: bool = false,
    path: []const u8 = "",
    status: u16 = 0,
};

var path_table: [PATH_TABLE_CAP]PathEntry = [_]PathEntry{.{}} ** PATH_TABLE_CAP;

const WARCRecord = struct {
    next: usize,
    header_block: []const u8,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

const ResolveResult = union(enum) {
    ignore,
    invalid,
    ok: []const u8,
};

const Output = struct {
    len: usize = 0,
    overflow: bool = false,

    pub fn write(self: *Output, value: []const u8) void {
        if (self.overflow or value.len == 0) return;
        if (value.len > output_buf.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.len .. self.len + value.len], value);
        self.len += value.len;
    }

    pub fn writeSlice(self: *Output, value: []const u8) void {
        self.write(value);
    }

    pub fn writeUnsigned(self: *Output, value: usize) void {
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.write(formatted);
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

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn trimASCIIWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isTagNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '-' or c == ':';
}

fn isSchemeChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.';
}

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (start >= buf.len) return null;
    if (std.mem.indexOfPos(u8, buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (std.mem.indexOfPos(u8, buf, start, "\n\n")) |pos| return pos + 2;
    return null;
}

fn parseUnsigned10(value: []const u8) ?usize {
    if (value.len == 0) return null;
    var result: usize = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + @as(usize, c - '0');
    }
    return result;
}

fn parseStatusCode(line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    const value = parseUnsigned10(line[start..i]) orelse return null;
    if (value > std.math.maxInt(u16)) return null;
    return @intCast(value);
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const header_end = findHeaderEnd(input, start) orelse return null;
    const header = input[start..header_end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var content_length: ?usize = null;
    var line_start: usize = 0;
    var line_index: usize = 0;

    while (line_start < header.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header, line_start, "\n") orelse header.len;
        var line = header[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimASCIIWhitespace(line);
        line_start = if (nl < header.len) nl + 1 else header.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "WARC-Type")) warc_type = value;
        if (eqlIgnoreCase(key, "WARC-Target-URI")) target_uri = value;
        if (eqlIgnoreCase(key, "Content-Length")) content_length = parseUnsigned10(value);
    }

    const payload_len = content_length orelse return null;
    if (payload_len > input.len - header_end) return null;
    const payload = input[header_end .. header_end + payload_len];
    var next = header_end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}
    return .{ .next = next, .header_block = header, .warc_type = warc_type, .target_uri = target_uri, .payload = payload };
}

fn parseHTTPMeta(payload: []const u8) ?HTTPMeta {
    const header_end = findHeaderEnd(payload, 0) orelse return null;
    const header = payload[0..header_end];
    var status: ?u16 = null;
    var content_type: []const u8 = "";
    var line_start: usize = 0;
    var line_index: usize = 0;

    while (line_start < header.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header, line_start, "\n") orelse header.len;
        var line = header[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimASCIIWhitespace(line);
        line_start = if (nl < header.len) nl + 1 else header.len;
        if (line.len == 0) break;
        if (line_index == 0) {
            status = parseStatusCode(line);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (eqlIgnoreCase(trimASCIIWhitespace(line[0..colon]), "Content-Type")) {
            content_type = trimASCIIWhitespace(line[colon + 1 ..]);
        }
    }
    return .{ .status = status orelse return null, .content_type = content_type, .body = payload[header_end..] };
}

fn isHTMLContentType(raw: []const u8) bool {
    const trimmed = trimASCIIWhitespace(raw);
    const end = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
    const mime = trimASCIIWhitespace(trimmed[0..end]);
    return eqlIgnoreCase(mime, "text/html") or eqlIgnoreCase(mime, "application/xhtml+xml");
}

fn pathFromTargetURI(uri: []const u8) []const u8 {
    if (uri.len == 0) return "/";
    var path = uri;
    if (std.mem.indexOf(u8, uri, "://")) |scheme| {
        path = if (std.mem.indexOfPos(u8, uri, scheme + 3, "/")) |slash| uri[slash..] else "/";
    } else if (std.mem.startsWith(u8, uri, "//")) {
        path = if (std.mem.indexOfPos(u8, uri, 2, "/")) |slash| uri[slash..] else "/";
    } else if (uri[0] != '/') {
        path = if (std.mem.indexOfScalar(u8, uri, '/')) |slash| uri[slash..] else "/";
    }
    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, path, '#')) |pos| end = @min(end, pos);
    return if (end == 0 or path[0] != '/') "/" else path[0..end];
}

fn authorityFromTargetURI(uri: []const u8) []const u8 {
    var rest = uri;
    if (startsWithIgnoreCase(uri, "http://")) rest = uri["http://".len..] else if (startsWithIgnoreCase(uri, "https://")) rest = uri["https://".len..] else if (std.mem.startsWith(u8, uri, "//")) rest = uri[2..] else return "";
    var end = rest.len;
    if (std.mem.indexOfScalar(u8, rest, '/')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, rest, '?')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, rest, '#')) |pos| end = @min(end, pos);
    return rest[0..end];
}

fn schemeSeparatorIndex(raw: []const u8) ?usize {
    if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0])) return null;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == ':') return i;
        if (raw[i] == '/' or raw[i] == '?' or raw[i] == '#' or !isSchemeChar(raw[i])) return null;
    }
    return null;
}

fn canonicalizePath(raw: []const u8, out: []u8) ?[]const u8 {
    if (raw.len == 0 or raw[0] != '/' or out.len == 0) return null;
    out[0] = '/';
    var out_len: usize = 1;
    var i: usize = 1;
    while (true) {
        while (i < raw.len and raw[i] == '/') : (i += 1) {}
        if (i >= raw.len) break;
        const start = i;
        while (i < raw.len and raw[i] != '/') : (i += 1) {}
        const segment = raw[start..i];
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (out_len > 1) {
                out_len -= 1;
                while (out_len > 0 and out[out_len - 1] != '/') : (out_len -= 1) {}
            }
            continue;
        }
        if (out_len > 1 and out[out_len - 1] != '/') {
            if (out_len >= out.len) return null;
            out[out_len] = '/';
            out_len += 1;
        }
        if (segment.len > out.len - out_len) return null;
        @memcpy(out[out_len .. out_len + segment.len], segment);
        out_len += segment.len;
    }
    return out[0..out_len];
}

fn resolveInternalLink(source_path: []const u8, raw_link: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8) ResolveResult {
    const link = trimASCIIWhitespace(raw_link);
    if (link.len == 0 or link[0] == '#') return .ignore;
    var reference = link;
    var empty_path_base = source_path;

    if (std.mem.startsWith(u8, link, "//")) {
        if (internal_host.len == 0) return .invalid;
        const rest = link[2..];
        var host_end = rest.len;
        for ([_]u8{ '/', '?', '#' }) |delimiter| {
            if (std.mem.indexOfScalar(u8, rest, delimiter)) |pos| host_end = @min(host_end, pos);
        }
        if (host_end == 0) return .invalid;
        if (!eqlIgnoreCase(rest[0..host_end], internal_host)) return .ignore;
        reference = if (host_end == rest.len) "/" else rest[host_end..];
        empty_path_base = "/";
    } else if (schemeSeparatorIndex(link)) |separator| {
        const scheme = link[0..separator];
        if (!eqlIgnoreCase(scheme, "http") and !eqlIgnoreCase(scheme, "https")) return .ignore;
        const after_scheme = link[separator + 1 ..];
        if (!std.mem.startsWith(u8, after_scheme, "//") or internal_host.len == 0) return .invalid;
        const rest = after_scheme[2..];
        var host_end = rest.len;
        for ([_]u8{ '/', '?', '#' }) |delimiter| {
            if (std.mem.indexOfScalar(u8, rest, delimiter)) |pos| host_end = @min(host_end, pos);
        }
        if (host_end == 0) return .invalid;
        if (!eqlIgnoreCase(rest[0..host_end], internal_host)) return .ignore;
        reference = if (host_end == rest.len) "/" else rest[host_end..];
        empty_path_base = "/";
    }

    var end = reference.len;
    if (std.mem.indexOfScalar(u8, reference, '?')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, reference, '#')) |pos| end = @min(end, pos);
    var path = if (end == 0) empty_path_base else reference[0..end];
    if (path[0] != '/') {
        const slash = std.mem.lastIndexOfScalar(u8, source_path, '/') orelse 0;
        const base = if (slash == 0) "/" else source_path[0 .. slash + 1];
        if (path.len > join_buf.len - base.len) return .invalid;
        @memcpy(join_buf[0..base.len], base);
        @memcpy(join_buf[base.len .. base.len + path.len], path);
        path = join_buf[0 .. base.len + path.len];
    }
    return .{ .ok = canonicalizePath(path, canonical_buf) orelse return .invalid };
}

fn pathHash(path: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (path) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn clearPathTable() void {
    for (&path_table) |*entry| entry.* = .{};
}

fn pathTableInsert(path: []const u8, status: u16) bool {
    var index: usize = @intCast(pathHash(path) % PATH_TABLE_CAP);
    var probes: usize = 0;
    while (probes < PATH_TABLE_CAP) : (probes += 1) {
        const entry = &path_table[index];
        if (!entry.used or std.mem.eql(u8, entry.path, path)) {
            entry.* = .{ .used = true, .path = path, .status = status };
            return true;
        }
        index = (index + 1) % PATH_TABLE_CAP;
    }
    return false;
}

fn pathTableLookup(path: []const u8) ?u16 {
    var index: usize = @intCast(pathHash(path) % PATH_TABLE_CAP);
    var probes: usize = 0;
    while (probes < PATH_TABLE_CAP) : (probes += 1) {
        const entry = path_table[index];
        if (!entry.used) return null;
        if (std.mem.eql(u8, entry.path, path)) return entry.status;
        index = (index + 1) % PATH_TABLE_CAP;
    }
    return null;
}

fn isBrokenLink(source_path: []const u8, value: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8) bool {
    return switch (resolveInternalLink(source_path, value, internal_host, join_buf, canonical_buf)) {
        .ignore => false,
        .invalid => true,
        .ok => |target| if (pathTableLookup(target)) |status| status >= 400 else true,
    };
}

fn srcSetIsBroken(source_path: []const u8, value: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and (isSpace(value[i]) or value[i] == ',')) : (i += 1) {}
        const start = i;
        while (i < value.len and value[i] != ',' and !isSpace(value[i])) : (i += 1) {}
        if (i > start and isBrokenLink(source_path, value[start..i], internal_host, join_buf, canonical_buf)) return true;
        while (i < value.len and value[i] != ',') : (i += 1) {}
    }
    return false;
}

fn attributeCarriesLink(tag: []const u8, attribute: []const u8) bool {
    if (eqlIgnoreCase(attribute, "href")) return eqlIgnoreCase(tag, "a") or eqlIgnoreCase(tag, "area") or eqlIgnoreCase(tag, "link");
    if (eqlIgnoreCase(attribute, "src")) return eqlIgnoreCase(tag, "img") or eqlIgnoreCase(tag, "script") or eqlIgnoreCase(tag, "iframe") or eqlIgnoreCase(tag, "source") or eqlIgnoreCase(tag, "audio") or eqlIgnoreCase(tag, "video") or eqlIgnoreCase(tag, "track") or eqlIgnoreCase(tag, "embed");
    if (eqlIgnoreCase(attribute, "action")) return eqlIgnoreCase(tag, "form");
    if (eqlIgnoreCase(attribute, "data")) return eqlIgnoreCase(tag, "object");
    return eqlIgnoreCase(attribute, "srcset") and (eqlIgnoreCase(tag, "img") or eqlIgnoreCase(tag, "source"));
}

fn findCloseTag(html: []const u8, start: usize, tag: []const u8) ?usize {
    var i = start;
    while (i + tag.len + 2 <= html.len) : (i += 1) {
        if (html[i] == '<' and html[i + 1] == '/' and eqlIgnoreCase(html[i + 2 .. i + 2 + tag.len], tag)) {
            return std.mem.indexOfPos(u8, html, i + 2 + tag.len, ">");
        }
    }
    return null;
}

fn brokenTagBytes(html: []const u8, source_path: []const u8, internal_host: []const u8, output: ?*Output) usize {
    var total: usize = 0;
    var join_buf: [4096]u8 = undefined;
    var canonical_buf: [4096]u8 = undefined;
    var i: usize = 0;

    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |end| end + 3 else return total;
            continue;
        }
        var j = i + 1;
        if (j >= html.len) break;
        if (html[j] == '/' or html[j] == '!' or html[j] == '?') {
            i = if (std.mem.indexOfPos(u8, html, j, ">")) |end| end + 1 else break;
            continue;
        }
        const tag_start = j;
        while (j < html.len and isTagNameChar(html[j])) : (j += 1) {}
        if (j == tag_start) {
            i += 1;
            continue;
        }
        const tag = html[tag_start..j];
        const text_container = eqlIgnoreCase(tag, "script") or eqlIgnoreCase(tag, "style") or
            eqlIgnoreCase(tag, "textarea") or eqlIgnoreCase(tag, "title");
        var self_closing = false;
        var broken = false;

        while (j < html.len) {
            while (j < html.len and isSpace(html[j])) : (j += 1) {}
            if (j >= html.len) break;
            if (html[j] == '>') {
                j += 1;
                break;
            }
            if (html[j] == '/') {
                self_closing = true;
                j += 1;
                continue;
            }
            const attribute_start = j;
            while (j < html.len and isTagNameChar(html[j])) : (j += 1) {}
            if (j == attribute_start) {
                j += 1;
                continue;
            }
            const attribute = html[attribute_start..j];
            while (j < html.len and isSpace(html[j])) : (j += 1) {}
            var value: []const u8 = "";
            if (j < html.len and html[j] == '=') {
                j += 1;
                while (j < html.len and isSpace(html[j])) : (j += 1) {}
                if (j < html.len and (html[j] == '"' or html[j] == '\'')) {
                    const quote = html[j];
                    j += 1;
                    const value_start = j;
                    while (j < html.len and html[j] != quote) : (j += 1) {}
                    value = html[value_start..j];
                    if (j < html.len) j += 1;
                } else {
                    const value_start = j;
                    while (j < html.len and !isSpace(html[j]) and html[j] != '>') : (j += 1) {}
                    value = html[value_start..j];
                }
            }
            if (!broken and value.len > 0 and attributeCarriesLink(tag, attribute)) {
                broken = if (eqlIgnoreCase(attribute, "srcset"))
                    srcSetIsBroken(source_path, value, internal_host, &join_buf, &canonical_buf)
                else
                    isBrokenLink(source_path, value, internal_host, &join_buf, &canonical_buf);
            }
        }

        if (broken) {
            const tag_bytes = html[i..j];
            total += tag_bytes.len + 1;
            if (output) |writer| {
                writer.write(tag_bytes);
                writer.write("\n");
            }
        }
        i = j;
        if (text_container and !self_closing) {
            i = if (findCloseTag(html, i, tag)) |end| end + 1 else return total;
        }
    }
    return total;
}

fn writePage(output: *Output, record: WARCRecord, body: []const u8, source_path: []const u8, internal_host: []const u8, snippet_len: usize) void {
    const http_header_len = HTTP_PREFIX.len + "Content-Length: ".len + digits10(snippet_len) + 4;
    warc.writeRecordHeader(output, record.header_block, http_header_len + snippet_len, true);
    output.write(HTTP_PREFIX);
    output.write("Content-Length: ");
    output.writeUnsigned(snippet_len);
    output.write("\r\n\r\n");
    _ = brokenTagBytes(body, source_path, internal_host, output);
    output.write("\r\n\r\n");
}

fn listBrokenLinks(input: []const u8) ?usize {
    clearPathTable();
    var internal_host: []const u8 = "";
    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse return null;
        cursor = record.next;
        if (!eqlIgnoreCase(record.warc_type, "response")) continue;
        const http = parseHTTPMeta(record.payload) orelse continue;
        if (!pathTableInsert(pathFromTargetURI(record.target_uri), http.status)) return null;
        if (internal_host.len == 0) internal_host = authorityFromTargetURI(record.target_uri);
    }

    var output = Output{};
    output.write(
        "WARC/1.1\r\n" ++
            "WARC-Type: warcinfo\r\n" ++
            "WARC-Date: 2000-01-01T00:00:00Z\r\n" ++
            "WARC-Record-ID: <urn:uuid:27131921-2ca4-5d68-bda7-716ae5544b13>\r\n" ++
            "Content-Type: application/warc-fields\r\n" ++
            "Content-Length: ",
    );
    output.writeUnsigned(WARCINFO_BLOCK.len);
    output.write("\r\n\r\n");
    output.write(WARCINFO_BLOCK);
    output.write("\r\n\r\n");
    cursor = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse return null;
        cursor = record.next;
        if (!eqlIgnoreCase(record.warc_type, "response")) continue;
        const http = parseHTTPMeta(record.payload) orelse continue;
        if (http.status != 200 or !isHTMLContentType(http.content_type)) continue;
        var source_path_buf: [4096]u8 = undefined;
        const raw_path = pathFromTargetURI(record.target_uri);
        const source_path = canonicalizePath(raw_path, &source_path_buf) orelse raw_path;
        const snippet_len = brokenTagBytes(http.body, source_path, internal_host, null);
        if (snippet_len > 0) writePage(&output, record, http.body, source_path, internal_host, snippet_len);
    }
    return if (output.overflow) null else output.len;
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();
    const output_size = listBrokenLinks(input_buf[0..input_size]) orelse @trap();
    if (!warc.validateArchive(output_buf[0..output_size])) @trap();
    return @intCast(output_size);
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

fn digits10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) n /= 10;
    return digits;
}

fn appendWARCRecord(output: []u8, cursor: *usize, target_uri: []const u8, payload: []const u8) !void {
    const record = try std.fmt.bufPrint(
        output[cursor.*..],
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += record.len;
}

test "keeps only pages and tags with broken links" {
    var input: [4096]u8 = undefined;
    var input_len: usize = 0;
    try appendWARCRecord(&input, &input_len, "http://qip.local/", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>Home</p><a href=\"/ok\">OK</a><img alt=\"x\" src=\"/missing.png\"><a href=\"/missing\">Missing</a><textarea><a href=\"/ignored\">Example</a></textarea><title><a href=\"/also-ignored\">Title text</a></title>");
    try appendWARCRecord(&input, &input_len, "http://qip.local/ok", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>No broken links</p>");

    const output_len = listBrokenLinks(input[0..input_len]) orelse return error.UnexpectedNull;
    const result = output_buf[0..output_len];
    try std.testing.expect(std.mem.indexOf(u8, result, "WARC-Target-URI: http://qip.local/") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "WARC-Target-URI: http://qip.local/ok") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<img alt=\"x\" src=\"/missing.png\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<a href=\"/missing\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<a href=\"/ok\">") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/ignored") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/also-ignored") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<p>Home</p>") == null);
}

test "returns a valid warcinfo-only archive when every internal link resolves" {
    var input: [2048]u8 = undefined;
    var input_len: usize = 0;
    try appendWARCRecord(&input, &input_len, "http://qip.local/", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<a href=\"/ok\">OK</a>");
    try appendWARCRecord(&input, &input_len, "http://qip.local/ok", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>OK</p>");
    const output_len = listBrokenLinks(input[0..input_len]) orelse return error.UnexpectedNull;
    try std.testing.expect(warc.validateArchive(output_buf[0..output_len]));
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..output_len], "WARC-Type: warcinfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..output_len], "WARC-Type: response") == null);
}
