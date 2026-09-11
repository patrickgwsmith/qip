const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

const PathAndQuery = struct {
    path: []const u8,
    query: []const u8,
};

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
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

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn isTokenSeparator(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '"' or ch == '\'' or ch == '<' or ch == '>' or ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}';
}

fn trimTrailingPunctuation(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) : (end -= 1) {
        const ch = s[end - 1];
        if (ch == '.' or ch == ',' or ch == ';' or ch == ':' or ch == '!' or ch == '?') continue;
        break;
    }
    return s[0..end];
}

fn findDelimiter(s: []const u8) usize {
    for (s, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#' or ch == '&') return i;
    }
    return s.len;
}

fn isVideoIdChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
}

fn parseVideoIdPrefix(s: []const u8) ?[]const u8 {
    if (s.len < 11) return null;
    for (s[0..11]) |ch| {
        if (!isVideoIdChar(ch)) return null;
    }
    if (s.len > 11 and isVideoIdChar(s[11])) return null;
    return s[0..11];
}

fn parseIdFromPathSegment(s: []const u8) ?[]const u8 {
    const end = findDelimiter(s);
    return parseVideoIdPrefix(s[0..end]);
}

fn parsePathAndQuery(rest: []const u8) PathAndQuery {
    if (rest.len == 0) return .{ .path = "", .query = "" };

    var path = rest;
    var query: []const u8 = "";

    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        path = rest[0..q];
        query = rest[q + 1 ..];
    }

    if (std.mem.indexOfScalar(u8, path, '#')) |h| {
        path = path[0..h];
    }

    if (query.len > 0) {
        if (std.mem.indexOfScalar(u8, query, '#')) |h| {
            query = query[0..h];
        }
    }

    return .{ .path = path, .query = query };
}

fn parseQueryForVideoId(query: []const u8) ?[]const u8 {
    if (query.len == 0) return null;
    var pos: usize = 0;
    while (pos <= query.len) {
        const next_amp = std.mem.indexOfPos(u8, query, pos, "&") orelse query.len;
        const pair = query[pos..next_amp];
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (eqlIgnoreCase(key, "v")) {
                if (parseVideoIdPrefix(value)) |id| return id;
            }
        }
        if (next_amp == query.len) break;
        pos = next_amp + 1;
    }
    return null;
}

fn hostIsYoutuBe(host: []const u8) bool {
    return eqlIgnoreCase(host, "youtu.be");
}

fn hostIsYouTube(host: []const u8) bool {
    if (eqlIgnoreCase(host, "youtube.com")) return true;
    if (endsWithIgnoreCase(host, ".youtube.com")) return true;
    if (eqlIgnoreCase(host, "youtube-nocookie.com")) return true;
    if (endsWithIgnoreCase(host, ".youtube-nocookie.com")) return true;
    return false;
}

fn extractFromYouTubeHost(rest: []const u8) ?[]const u8 {
    const pq = parsePathAndQuery(rest);

    if (startsWithIgnoreCase(pq.path, "/embed/")) {
        return parseIdFromPathSegment(pq.path[7..]);
    }
    if (startsWithIgnoreCase(pq.path, "/shorts/")) {
        return parseIdFromPathSegment(pq.path[8..]);
    }
    if (startsWithIgnoreCase(pq.path, "/v/")) {
        return parseIdFromPathSegment(pq.path[3..]);
    }
    if (startsWithIgnoreCase(pq.path, "/live/")) {
        return parseIdFromPathSegment(pq.path[6..]);
    }
    if (eqlIgnoreCase(pq.path, "/watch") or pq.path.len == 0) {
        return parseQueryForVideoId(pq.query);
    }

    return null;
}

fn extractVideoIdFromToken(token: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (startsWithIgnoreCase(token, "https://")) {
        pos = 8;
    } else if (startsWithIgnoreCase(token, "http://")) {
        pos = 7;
    }
    if (startsWithIgnoreCase(token[pos..], "www.")) {
        pos += 4;
    }

    var host_end = pos;
    while (host_end < token.len and token[host_end] != '/' and token[host_end] != '?' and token[host_end] != '#') : (host_end += 1) {}
    if (host_end == pos) return null;

    var host = token[pos..host_end];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        host = host[0..colon];
    }
    const rest = token[host_end..];

    if (hostIsYoutuBe(host)) {
        if (rest.len == 0 or rest[0] != '/') return null;
        return parseIdFromPathSegment(rest[1..]);
    }
    if (hostIsYouTube(host)) {
        return extractFromYouTubeHost(rest);
    }
    return null;
}

fn extractAll(input: []const u8, output: []u8) u32 {
    var i: usize = 0;
    var out: usize = 0;
    var found: usize = 0;

    while (i < input.len) {
        while (i < input.len and isTokenSeparator(input[i])) : (i += 1) {}
        if (i >= input.len) break;

        const start = i;
        while (i < input.len and !isTokenSeparator(input[i])) : (i += 1) {}
        const token = trimTrailingPunctuation(input[start..i]);
        if (token.len == 0) continue;

        if (extractVideoIdFromToken(token)) |id| {
            if (found > 0) {
                // Each newline replaces at least one input token separator.
                if (out >= output.len) @trap();
                output[out] = '\n';
                out += 1;
            }
            // The ID is an 11-byte slice of its longer source token, so the
            // complete output cannot be larger than the input.
            if (out + id.len > output.len) @trap();
            @memcpy(output[out..][0..id.len], id);
            out += id.len;
            found += 1;
        }
    }

    if (found == 0) return 0;
    return @as(u32, @intCast(out));
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    return extractAll(input_buf[0..input_size], output_buf[0..]);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "extracts watch URL id" {
    const input = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
    const out_len = extractAll(input, output_buf[0..]);
    try std.testing.expectEqual(@as(u32, 11), out_len);
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", output_buf[0..11]);
}

test "extracts short and embed URLs" {
    const input = "https://youtu.be/9bZkp7q19f0 and https://www.youtube.com/embed/3JZ_D3ELwOQ";
    const out_len = extractAll(input, output_buf[0..]);
    try std.testing.expectEqual(@as(u32, 23), out_len);
    try std.testing.expectEqualStrings("9bZkp7q19f0\n3JZ_D3ELwOQ", output_buf[0..23]);
}

test "ignores non-youtube hosts" {
    const input = "https://example.com/watch?v=dQw4w9WgXcQ";
    const out_len = extractAll(input, output_buf[0..]);
    try std.testing.expectEqual(@as(u32, 0), out_len);
}

test "many IDs stay within the input-size output bound" {
    const token = "youtu.be/12345678901 ";
    var input_len: usize = 0;
    while (input_len + token.len <= input_buf.len) : (input_len += token.len) {
        @memcpy(input_buf[input_len..][0..token.len], token);
    }

    const out_len = extractAll(input_buf[0..input_len], output_buf[0..]);
    try std.testing.expect(out_len > 0);
    try std.testing.expect(out_len <= input_len);
}
