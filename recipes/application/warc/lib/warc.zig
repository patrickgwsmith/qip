const std = @import("std");

pub fn trimASCIIWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and isWhitespace(s[start])) : (start += 1) {}
    while (end > start and isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// Same result as std.mem.indexOfPos, but finds candidates with indexOfScalarPos,
// which SIMD builds run 16 bytes per loop iteration. Hosts that interrupt wasm
// (wazero's WithCloseOnContextDone) pay for a check on every loop iteration, so
// fewer iterations is much faster there.
pub fn indexOfPos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    var i = start;
    // Each candidate moves i forward by at least one, so haystack.len - start
    // steps cover the whole search. The budget makes that bound provable to
    // wasm-bounded-loops, which can't see that pos + 1 > i.
    var steps = haystack.len -| start;
    while (steps > 0) : (steps -= 1) {
        const pos = std.mem.indexOfScalarPos(u8, haystack, i, needle[0]) orelse return null;
        if (haystack.len - pos < needle.len) return null;
        if (std.mem.eql(u8, haystack[pos..][0..needle.len], needle)) return pos;
        i = pos + 1;
    }
    return null;
}

// First index at or after start whose byte is in set, testing 16 bytes per loop
// iteration. std.mem.indexOfAnyPos tests one byte at a time.
pub fn indexOfAnyPos(haystack: []const u8, start: usize, comptime set: []const u8) ?usize {
    const V = @Vector(16, u8);
    var i = start;
    for (0..(haystack.len -| start) / 16) |_| {
        const block: V = haystack[i..][0..16].*;
        var hits: u16 = 0;
        inline for (set) |c| hits |= @bitCast(block == @as(V, @splat(c)));
        if (hits != 0) return i + @ctz(hits);
        i += 16;
    }
    while (i < haystack.len) : (i += 1) {
        inline for (set) |c| if (haystack[i] == c) return i;
    }
    return null;
}

// ASCII case-insensitive search. Anchors on the needle's first non-letter byte
// (e.g. '<' in "<main") so candidates come from indexOfScalarPos.
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len or haystack.len - start < needle.len) return null;
    const anchor = for (needle, 0..) |c, k| {
        if (!std.ascii.isAlphabetic(c)) break k;
    } else null;
    if (anchor) |k| {
        var i = start + k;
        // Step budget as in indexOfPos.
        var steps = haystack.len - i;
        while (steps > 0) : (steps -= 1) {
            const pos = std.mem.indexOfScalarPos(u8, haystack, i, needle[k]) orelse return null;
            const candidate = pos - k;
            if (haystack.len - candidate < needle.len) return null;
            if (eqlIgnoreCase(haystack[candidate..][0..needle.len], needle)) return candidate;
            i = pos + 1;
        }
        return null;
    }
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn lineName(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return trimASCIIWhitespace(line[0..colon]);
}

fn isInvalidatedWARCField(name: []const u8) bool {
    return eqlIgnoreCase(name, "WARC-Block-Digest") or
        eqlIgnoreCase(name, "WARC-Payload-Digest");
}

fn isInvalidatedHTTPField(name: []const u8) bool {
    return eqlIgnoreCase(name, "ETag") or
        eqlIgnoreCase(name, "Content-MD5") or
        eqlIgnoreCase(name, "Digest");
}

pub fn writeRecordHeader(
    out: anytype,
    header_block: []const u8,
    payload_len: usize,
    content_changed: bool,
) void {
    const version_end = std.mem.indexOfScalar(u8, header_block, '\n') orelse @trap();
    var version = header_block[0..version_end];
    if (version.len > 0 and version[version.len - 1] == '\r') version = version[0 .. version.len - 1];
    if (!std.mem.eql(u8, version, "WARC/1.0") and !std.mem.eql(u8, version, "WARC/1.1")) @trap();
    out.writeSlice("WARC/1.1\r\n");
    var have_type = false;
    var have_date = false;
    var have_id = false;
    var skip_continuation = false;
    var line_start: usize = 0;
    var line_index: usize = 0;
    // Each line moves line_start forward by at least one byte, so this step
    // budget never runs out; it makes the bound provable to wasm-bounded-loops.
    var steps = header_block.len;
    while (steps > 0 and line_start < header_block.len) : ({
        line_index += 1;
        steps -= 1;
    }) {
        const nl = std.mem.indexOfScalarPos(u8, header_block, line_start, '\n') orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line_index == 0) continue;
        if (line.len == 0) break;
        if (line[0] == ' ' or line[0] == '\t') {
            if (!skip_continuation) {
                out.writeSlice(line);
                out.writeSlice("\r\n");
            }
            continue;
        }
        const name = lineName(line) orelse @trap();
        skip_continuation = eqlIgnoreCase(name, "Content-Length") or
            (content_changed and isInvalidatedWARCField(name));
        if (skip_continuation) continue;
        have_type = have_type or eqlIgnoreCase(name, "WARC-Type");
        have_date = have_date or eqlIgnoreCase(name, "WARC-Date");
        have_id = have_id or eqlIgnoreCase(name, "WARC-Record-ID");
        out.writeSlice(line);
        out.writeSlice("\r\n");
    }
    if (!have_type or !have_date or !have_id) @trap();
    out.writeSlice("Content-Length: ");
    out.writeUnsigned(payload_len);
    out.writeSlice("\r\n\r\n");
}

pub fn httpHeaderRewriteLen(
    header_block: []const u8,
    status_line: []const u8,
    body_len: usize,
) usize {
    var len = status_line.len + 2;
    var line_start: usize = 0;
    var line_index: usize = 0;
    var skip_continuation = false;
    // Step budget as in writeRecordHeader.
    var steps = header_block.len;
    while (steps > 0 and line_start < header_block.len) : ({
        line_index += 1;
        steps -= 1;
    }) {
        const nl = std.mem.indexOfScalarPos(u8, header_block, line_start, '\n') orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (!skip_continuation) len += line.len + 2;
            continue;
        }
        const name = lineName(line) orelse @trap();
        skip_continuation = eqlIgnoreCase(name, "Content-Length") or
            isInvalidatedHTTPField(name);
        if (!skip_continuation) len += line.len + 2;
    }
    return len + "Content-Length: ".len + digits10(body_len) + 4;
}

pub fn writeRewrittenHTTPHeaders(
    out: anytype,
    header_block: []const u8,
    status_line: []const u8,
    body_len: usize,
) void {
    out.writeSlice(status_line);
    out.writeSlice("\r\n");
    var line_start: usize = 0;
    var line_index: usize = 0;
    var skip_continuation = false;
    // Step budget as in writeRecordHeader.
    var steps = header_block.len;
    while (steps > 0 and line_start < header_block.len) : ({
        line_index += 1;
        steps -= 1;
    }) {
        const nl = std.mem.indexOfScalarPos(u8, header_block, line_start, '\n') orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (!skip_continuation) {
                out.writeSlice(line);
                out.writeSlice("\r\n");
            }
            continue;
        }
        const name = lineName(line) orelse @trap();
        skip_continuation = eqlIgnoreCase(name, "Content-Length") or
            isInvalidatedHTTPField(name);
        if (skip_continuation) continue;
        out.writeSlice(line);
        out.writeSlice("\r\n");
    }
    out.writeSlice("Content-Length: ");
    out.writeUnsigned(body_len);
    out.writeSlice("\r\n\r\n");
}

pub fn validateArchive(archive: []const u8) bool {
    if (archive.len == 0) return false;
    var cursor: usize = 0;
    // Each record moves cursor forward, so these step budgets never run out;
    // they make the bounds provable to wasm-bounded-loops.
    var records = archive.len;
    while (records > 0 and cursor < archive.len) : (records -= 1) {
        const header_marker = indexOfPos(archive, cursor, "\r\n\r\n") orelse return false;
        const header_block = archive[cursor..header_marker];
        if (!std.mem.startsWith(u8, header_block, "WARC/1.1\r\n")) return false;
        var have_type = false;
        var have_date = false;
        var have_id = false;
        var content_length: ?usize = null;
        var line_start: usize = "WARC/1.1\r\n".len;
        var steps = header_block.len;
        while (steps > 0 and line_start < header_block.len) : (steps -= 1) {
            const nl = indexOfPos(header_block, line_start, "\r\n") orelse header_block.len;
            const line = header_block[line_start..nl];
            line_start = if (nl < header_block.len) nl + 2 else header_block.len;
            if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
            const name = lineName(line) orelse return false;
            const colon = std.mem.indexOfScalar(u8, line, ':').?;
            const value = trimASCIIWhitespace(line[colon + 1 ..]);
            if (eqlIgnoreCase(name, "WARC-Type")) have_type = true;
            if (eqlIgnoreCase(name, "WARC-Date")) have_date = true;
            if (eqlIgnoreCase(name, "WARC-Record-ID")) have_id = true;
            if (eqlIgnoreCase(name, "Content-Length")) {
                if (content_length != null) return false;
                content_length = parseUnsigned10(value) orelse return false;
            }
        }
        if (!have_type or !have_date or !have_id or content_length == null) return false;
        const block_start = header_marker + 4;
        const block_end = std.math.add(usize, block_start, content_length.?) catch return false;
        if (block_end + 4 > archive.len) return false;
        if (!std.mem.eql(u8, archive[block_end .. block_end + 4], "\r\n\r\n")) return false;
        cursor = block_end + 4;
    }
    return cursor == archive.len;
}

fn parseUnsigned10(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var value: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = std.math.mul(usize, value, 10) catch return null;
        value = std.math.add(usize, value, c - '0') catch return null;
    }
    return value;
}

fn digits10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) n /= 10;
    return digits;
}

test "indexOfPos and indexOfIgnoreCase match a plain scan" {
    const haystack = "WARC/1.1\r\nA: b\r\n\r\n<HTML><Main x>\n\n<!-- --><main>--> docs-SIDEBAR <a<a";
    const needles = [_][]const u8{ "", "\r\n\r\n", "\r\n", "\n\n", "-->", "<main", "</main>", "docs-sidebar", "<a", "a<a", "html", "missing", "<a<a<" };
    for (needles) |needle| {
        for (0..haystack.len + 2) |start| {
            if (start <= haystack.len) try std.testing.expectEqual(std.mem.indexOfPos(u8, haystack, start, needle), indexOfPos(haystack, start, needle));
            var expected: ?usize = if (needle.len == 0) start else null;
            if (needle.len > 0) {
                var i = start;
                while (i + needle.len <= haystack.len) : (i += 1) {
                    if (eqlIgnoreCase(haystack[i..][0..needle.len], needle)) {
                        expected = i;
                        break;
                    }
                }
            }
            try std.testing.expectEqual(expected, indexOfIgnoreCase(haystack, needle, start));
        }
    }
}

test "indexOfAnyPos matches a plain scan" {
    const haystack = "<html lang=\"en\"><head><meta property='og:image' content=x></head><body>a:b</body>";
    for (0..haystack.len + 2) |start| {
        try std.testing.expectEqual(if (start <= haystack.len) std.mem.indexOfAnyPos(u8, haystack, start, "\"'>") else null, indexOfAnyPos(haystack, start, "\"'>"));
        try std.testing.expectEqual(if (start <= haystack.len) std.mem.indexOfAnyPos(u8, haystack, start, "<:") else null, indexOfAnyPos(haystack, start, "<:"));
    }
}
