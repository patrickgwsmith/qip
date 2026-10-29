//! Adds a rendered Open Graph image to every HTML page in a WARC.
//!
//! For each 200 text/html response whose head has no og:image or
//! twitter:image meta tag, the page title (the head's <title>, else the first
//! <h1>) is laid out in Inter Display and rasterized straight to pixels: no
//! SVG is produced or parsed. The component inserts og:image, twitter:card,
//! and twitter:image meta tags and writes a response record for the
//! `/_og/<path>.png` image directly after the page record. The image URL is
//! absolute when the page's WARC-Target-URI has an origin.
//!
//! When the archive already has a record for an image path, or an earlier
//! page mapped to the same path, the meta tags point at that image and
//! nothing is rendered. Titles that have no supported glyphs are skipped.
//!
//! An image meta tag whose URL is a /_og/ path with a query, such as
//! "/_og/index.png?primary=…&secondary=…", is a template: its query sets the
//! primary text, a smaller secondary line, and the uniforms for that page,
//! and the tag is replaced by the usual tags without the query.
//!
//! Layout matches text-to-og-image-svg-inter.wasm: a left-aligned title,
//! vertically centered in a 1200x630 card with 96px and 72px margins, sized
//! by auto-fit from 112px down to 32px. Coverage is the exact signed area of
//! each pixel under the glyph outlines. The PNG is 8-bit indexed: palette
//! entry N is the text color composited over the background at N/255
//! coverage in sRGB, so each pixel is one byte before compression.

const std = @import("std");
const warc = @import("lib/warc.zig");
const deflate = @import("deflate");
const regular = @import("inter_regular");
const bold = @import("inter_bold");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";

const META_OG_IMAGE_PREFIX = "<meta property=\"og:image\" content=\"";
const META_OG_IMAGE_SUFFIX = "\" />\n";
const META_TWITTER_CARD = "<meta name=\"twitter:card\" content=\"summary_large_image\" />\n";
const META_TWITTER_IMAGE_PREFIX = "<meta name=\"twitter:image\" content=\"";
const META_TWITTER_IMAGE_SUFFIX = "\" />\n";

const WIDTH: usize = 1200;
const HEIGHT: usize = 630;
const PADDING_X: f32 = 96;
const PADDING_Y: f32 = 72;
const AUTO_MAX_FONT_SIZE: u32 = 112;
const MIN_FONT_SIZE: u32 = 32;
const MAX_FONT_SIZE: u32 = 160;
const FONT_SIZE_STEP: u32 = 2;
const MAX_TITLE_CODEPOINTS: usize = 300;
const MAX_LINES: usize = 16;
// The secondary line is Regular, auto-fit from 44px down to 24px, below the
// primary text and at most a third of the drawable height.
const SECONDARY_MAX_FONT_SIZE: u32 = 44;
const SECONDARY_MIN_FONT_SIZE: u32 = 24;
const SECONDARY_GAP: f32 = 24;
const MAX_SECONDARY_LINES: usize = 4;
// Image meta tags with a query string that one page may carry.
const MAX_TEMPLATE_TAGS: usize = 4;
const TEMPLATE_QUERY_CAP: usize = 4096;
// Quadratic curves flatten into at most this many line segments.
const MAX_CURVE_SEGMENTS: usize = 64;

const DEFAULT_TEXT_COLOR_RGBA: u32 = 0x101010ff;
const DEFAULT_BACKGROUND_COLOR_RGBA: u32 = 0xeecc33ff;
const DEFAULT_FONT_WEIGHT: u32 = 700;
const DEFAULT_REQUESTED_MAX_FONT_SIZE: u32 = 0;

// Each scanline is one filter byte then one palette index per pixel.
const FILTERED_LEN: usize = (1 + WIDTH) * HEIGHT;
const PNG_CAP: usize = FILTERED_LEN + FILTERED_LEN / 8 + 4096;
// Distinct image paths the archive may already hold or this pass may add.
const MAX_IMAGE_PATHS: usize = 16 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
// Signed area accumulation. Rasterizing leaves it all zero again, so it is
// cleared only once, by wasm's zeroed memory.
var coverage: [WIDTH * HEIGHT]f32 = @splat(0);
// Cells that edges touched, as half-open ranges. Other cells are background.
var dirty_x0: usize = WIDTH;
var dirty_x1: usize = 0;
var dirty_y0: usize = HEIGHT;
var dirty_y1: usize = 0;
var filtered_buf: [FILTERED_LEN]u8 = undefined;
var token_buf: [FILTERED_LEN]u32 = undefined;
var png_buf: [PNG_CAP]u8 = undefined;
var title_codepoints: [MAX_TITLE_CODEPOINTS]u32 = undefined;
var title_lines: [MAX_LINES]Line = undefined;
var secondary_codepoints: [MAX_TITLE_CODEPOINTS]u32 = undefined;
var secondary_lines: [MAX_SECONDARY_LINES]Line = undefined;
var template_query_buf: [TEMPLATE_QUERY_CAP]u8 = undefined;
var image_paths: [MAX_IMAGE_PATHS][]const u8 = undefined;
var image_path_count: usize = 0;
// Paths this pass adds point into the output, which is not yet complete, so
// they are copied here.
var added_path_bytes: [4 * 1024 * 1024]u8 = undefined;
var added_path_len: usize = 0;

var text_color_rgba: u32 = DEFAULT_TEXT_COLOR_RGBA;
var background_color_rgba: u32 = DEFAULT_BACKGROUND_COLOR_RGBA;
var font_weight: u32 = DEFAULT_FONT_WEIGHT;
var requested_max_font_size: u32 = DEFAULT_REQUESTED_MAX_FONT_SIZE;

const WARCRecord = struct {
    next: usize,
    header_block: []const u8,
    warc_type: []const u8,
    target_uri: []const u8,
    warc_date: []const u8,
    payload: []const u8,
};

const HTTPPayload = struct {
    status: u16,
    status_line: []const u8,
    content_type: []const u8,
    header_block: []const u8,
    body: []const u8,
};

const Range = struct {
    start: usize,
    end: usize,
};

const HeadScan = struct {
    should_inject: bool,
    insert_at: usize,
    title: ?[]const u8,
    // Image meta tags whose URL is a /_og/ path with a query string. The
    // first one's content attribute is the template.
    templates: [MAX_TEMPLATE_TAGS]Range = undefined,
    template_count: usize = 0,
    template_url: []const u8 = "",
};

// A template's image path and its query, still HTML-escaped.
const TemplateURL = struct {
    path: []const u8,
    query: []const u8,
};

// Values from a template's query. Text is plain UTF-8, and numbers that are
// missing or don't parse leave the uniform as it is.
const TemplateOptions = struct {
    primary: ?[]const u8 = null,
    secondary: ?[]const u8 = null,
    text_color_rgba: ?u32 = null,
    background_color_rgba: ?u32 = null,
    font_weight: ?u32 = null,
    font_max_size: ?u32 = null,
};

const Line = struct {
    start: usize,
    end: usize,
};

const Layout = struct {
    font_size: u32,
    scale: f32,
    line_advance: f32,
    line_count: usize,
    block_height: f32,
};

const Card = struct {
    primary: Layout,
    primary_baseline: f32,
    secondary: ?Layout,
    secondary_baseline: f32,
};

const LayoutError = error{ TextDoesNotFit, TooManyLines };

const Output = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Output) usize {
        return output_buf.len - self.idx;
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

export fn uniform_set_text_color_rgba(value: u32) u32 {
    text_color_rgba = value;
    return text_color_rgba;
}

export fn uniform_set_background_color_rgba(value: u32) u32 {
    background_color_rgba = value;
    return background_color_rgba;
}

export fn uniform_set_font_weight(value: u32) u32 {
    font_weight = if (value < 550) 400 else 700;
    return font_weight;
}

export fn uniform_set_font_max_size(value: u32) u32 {
    requested_max_font_size = if (value == 0) 0 else std.math.clamp(value, MIN_FONT_SIZE, MAX_FONT_SIZE);
    return requested_max_font_size;
}

fn resetUniforms() void {
    text_color_rgba = DEFAULT_TEXT_COLOR_RGBA;
    background_color_rgba = DEFAULT_BACKGROUND_COLOR_RGBA;
    font_weight = DEFAULT_FONT_WEIGHT;
    requested_max_font_size = DEFAULT_REQUESTED_MAX_FONT_SIZE;
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
    return warc.trimASCIIWhitespace(s);
}

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (start >= buf.len) return null;
    if (warc.indexOfPos(buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (warc.indexOfPos(buf, start, "\n\n")) |pos| return pos + 2;
    return null;
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
    var warc_date: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl = std.mem.indexOfScalarPos(u8, header_slice, line_start, '\n') orelse header_slice.len;
        const line = trimASCIIWhitespace(header_slice[line_start..nl]);
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
        } else if (eqlIgnoreCase(key, "WARC-Date")) {
            warc_date = value;
        } else if (eqlIgnoreCase(key, "Content-Length")) {
            content_length = parseUnsigned10(value);
        }
    }

    const payload_len = content_length orelse return null;
    if (payload_len > input.len - header_end) return null;
    const payload = input[header_end .. header_end + payload_len];
    var next = header_end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{
        .next = next,
        .header_block = header_slice,
        .warc_type = warc_type,
        .target_uri = target_uri,
        .warc_date = warc_date,
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
        const nl = std.mem.indexOfScalarPos(u8, header_block, line_start, '\n') orelse header_block.len;
        const trimmed = trimASCIIWhitespace(header_block[line_start..nl]);
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;
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
    return eqlIgnoreCase(token, "text/html") or eqlIgnoreCase(token, "application/xhtml+xml");
}

// Scheme and authority, such as "https://qip.dev", or "" for a bare path.
fn originFromTargetURI(uri: []const u8) []const u8 {
    const scheme_sep = std.mem.indexOf(u8, uri, "://") orelse return "";
    const after_scheme = scheme_sep + 3;
    const end = std.mem.indexOfAnyPos(u8, uri, after_scheme, "/?#") orelse uri.len;
    return uri[0..end];
}

fn pathFromTargetURI(uri: []const u8) []const u8 {
    if (uri.len == 0) return "/";

    var path = uri;
    if (std.mem.indexOf(u8, uri, "://")) |scheme_sep| {
        const after_scheme = scheme_sep + 3;
        if (std.mem.indexOfScalarPos(u8, uri, after_scheme, '/')) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (startsWithIgnoreCase(uri, "//")) {
        if (std.mem.indexOfScalarPos(u8, uri, 2, '/')) |slash_pos| {
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

fn stripLastExtension(path_rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path_rel, '/');
    const base = if (slash) |idx| path_rel[idx + 1 ..] else path_rel;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return path_rel;
    if (dot == 0) return path_rel;
    if (slash) |idx| return path_rel[0 .. idx + 1 + dot];
    return path_rel[0..dot];
}

// Same mapping as warc-add-open-graph-image-meta.wasm: "/" and "/index.html"
// become "/_og/index.png", "/docs/" becomes "/_og/docs.png".
fn ogImagePathForRequestPath(request_path: []const u8, out_buf: []u8) ?[]const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return null;

    var rel = request_path[1..];
    while (rel.len > 0 and rel[rel.len - 1] == '/') rel = rel[0 .. rel.len - 1];
    if (rel.len == 0) rel = "index";
    rel = stripLastExtension(rel);

    if (std.mem.endsWith(u8, rel, "/index")) {
        rel = rel[0 .. rel.len - "/index".len];
        while (rel.len > 0 and rel[rel.len - 1] == '/') rel = rel[0 .. rel.len - 1];
    } else if (std.mem.eql(u8, rel, "index")) {
        rel = "";
    }
    if (rel.len == 0) rel = "index";

    const needed = "/_og/".len + rel.len + ".png".len;
    if (needed > out_buf.len) return null;
    @memcpy(out_buf[0.."/_og/".len], "/_og/");
    @memcpy(out_buf["/_og/".len..][0..rel.len], rel);
    @memcpy(out_buf["/_og/".len + rel.len ..][0..".png".len], ".png");
    return out_buf[0..needed];
}

// The URL goes into an HTML attribute and a WARC header line unescaped, so
// only plain URL characters are accepted.
fn isSafeURL(url: []const u8) bool {
    for (url) |c| {
        if (c <= ' ' or c >= 0x7f or c == '"' or c == '\'' or c == '<' or c == '>' or c == '&' or c == '\\') return false;
    }
    return true;
}

fn isTagBoundary(c: u8) bool {
    return c == '>' or c == '/' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
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

// Start tags the HTML parser keeps in <head> ("in head" insertion mode).
const HEAD_ELEMENTS = [_][]const u8{ "html", "head", "base", "link", "meta", "title" };

// Head elements whose contents are text rather than tags, so the scan jumps
// to their end tag.
const RAW_TEXT_HEAD_ELEMENTS = [_][]const u8{ "style", "script", "title", "noscript", "noframes", "template" };

fn tagNameAt(body: []const u8, start: usize) []const u8 {
    if (start >= body.len or !std.ascii.isAlphabetic(body[start])) return "";
    for (body[start..], 0..) |c, k| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return body[start..][0..k];
    }
    return body[start..];
}

fn hasImageMetaMarker(tag: []const u8) bool {
    inline for (IMAGE_META_MARKERS) |marker| {
        if (warc.indexOfIgnoreCase(tag, marker, 0) != null) return true;
    }
    return false;
}

fn isAttributeSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c;
}

// The raw value of a start tag's attribute, still HTML-escaped. The tag
// runs from '<' to just past '>'.
fn attributeValue(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var i = tagNameAt(tag, 1).len + 1;
    const end = tag.len - 1;
    // Each pass consumes at least one byte.
    var steps = tag.len;
    while (steps > 0 and i < end) : (steps -= 1) {
        if (isAttributeSpace(tag[i]) or tag[i] == '/') {
            i += 1;
            continue;
        }
        const name_start = i;
        while (i < end and !isAttributeSpace(tag[i]) and tag[i] != '=' and tag[i] != '/') i += 1;
        const name = tag[name_start..i];
        if (name.len == 0) i += 1;
        while (i < end and isAttributeSpace(tag[i])) i += 1;
        var value: []const u8 = "";
        if (i < end and tag[i] == '=') {
            i += 1;
            while (i < end and isAttributeSpace(tag[i])) i += 1;
            if (i < end and (tag[i] == '"' or tag[i] == '\'')) {
                const close = std.mem.indexOfScalarPos(u8, tag[0..end], i + 1, tag[i]) orelse end;
                value = tag[i + 1 .. close];
                i = close + 1;
            } else {
                const value_start = i;
                while (i < end and !isAttributeSpace(tag[i])) i += 1;
                value = tag[value_start..i];
            }
        }
        if (eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

// A content URL such as "/_og/index.png?primary=…", optionally with an
// origin, is a template: the component renders it rather than leaving the
// page alone.
fn templateURL(content: []const u8) ?TemplateURL {
    const query_mark = std.mem.indexOfScalar(u8, content, '?') orelse return null;
    const query_end = std.mem.indexOfScalarPos(u8, content, query_mark, '#') orelse content.len;
    const path = pathFromTargetURI(content[0..query_mark]);
    if (!std.mem.startsWith(u8, path, "/_og/") or !std.mem.endsWith(u8, path, ".png")) return null;
    if (path.len == "/_og/.png".len or !isSafeURL(path)) return null;
    return .{ .path = path, .query = content[query_mark + 1 .. query_end] };
}

// The head scan of warc-add-open-graph-image-meta.wasm, which also keeps the
// first <title>'s text and any template image tags. It stops at </head> or at
// the first start tag that isn't a head element, where the parser closes an
// omitted </head>.
fn scanHead(body: []const u8) HeadScan {
    var head_open_end: ?usize = null;
    var title: ?[]const u8 = null;
    var scan_result = HeadScan{ .should_inject = false, .insert_at = 0, .title = null };
    var cursor: usize = 0;
    // Each pass moves cursor forward by at least one; the budget makes that
    // bound provable to wasm-bounded-loops.
    var steps = body.len;
    scan: while (steps > 0) : (steps -= 1) {
        const lt = warc.indexOfAnyPos(body, cursor, "<") orelse break;
        cursor = lt + 1;
        if (startsWithIgnoreCaseAt(body, cursor, "!--")) {
            const close = warc.indexOfPos(body, cursor + "!--".len, "-->") orelse break;
            cursor = close + "-->".len;
            continue;
        }
        if (startsWithIgnoreCaseAt(body, cursor, "/head")) {
            const boundary = cursor + "/head".len;
            if (boundary >= body.len or isTagBoundary(body[boundary])) {
                scan_result.should_inject = true;
                scan_result.insert_at = lt;
                scan_result.title = title;
                return scan_result;
            }
        }
        const name = tagNameAt(body, cursor);
        // End tags, <!doctype>, and a stray '<' in text.
        if (name.len == 0) continue;
        const tag_end = findTagEndAfter(body, cursor + name.len) orelse break;
        cursor = tag_end;
        if (eqlIgnoreCase(name, "meta")) {
            const tag = body[lt..tag_end];
            if (hasImageMetaMarker(tag)) {
                // An image the page declares itself, or more template tags
                // than one page needs, leaves the page unchanged.
                const content = attributeValue(tag, "content") orelse "";
                if (templateURL(content) == null or scan_result.template_count == MAX_TEMPLATE_TAGS) {
                    return .{ .should_inject = false, .insert_at = 0, .title = null };
                }
                if (scan_result.template_count == 0) scan_result.template_url = content;
                scan_result.templates[scan_result.template_count] = .{ .start = lt, .end = tag_end };
                scan_result.template_count += 1;
            }
            continue;
        }
        if (eqlIgnoreCase(name, "head")) {
            if (head_open_end == null) head_open_end = tag_end;
            continue;
        }
        inline for (RAW_TEXT_HEAD_ELEMENTS) |raw| {
            if (eqlIgnoreCase(name, raw)) {
                cursor = warc.indexOfIgnoreCase(body, "</" ++ raw, tag_end) orelse break :scan;
                if (comptime std.mem.eql(u8, raw, "title")) {
                    if (title == null) title = body[tag_end..cursor];
                }
                continue :scan;
            }
        }
        inline for (HEAD_ELEMENTS) |head_element| {
            if (eqlIgnoreCase(name, head_element)) continue :scan;
        }
        break;
    }
    if (head_open_end) |insert_at| {
        scan_result.should_inject = true;
        scan_result.insert_at = insert_at;
        scan_result.title = title;
        return scan_result;
    }
    return .{ .should_inject = false, .insert_at = 0, .title = null };
}

// Contents of the first <h1> element, including any inline markup.
fn firstH1(body: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    // Each candidate moves cursor forward by at least one.
    var steps = body.len;
    while (steps > 0) : (steps -= 1) {
        const open = warc.indexOfIgnoreCase(body, "<h1", cursor) orelse return null;
        cursor = open + "<h1".len;
        if (cursor < body.len and !isTagBoundary(body[cursor])) continue;
        const tag_end = findTagEndAfter(body, cursor) orelse return null;
        const close = warc.indexOfIgnoreCase(body, "</h1", tag_end) orelse return null;
        return body[tag_end..close];
    }
    return null;
}

const NAMED_ENTITIES = [_]struct { name: []const u8, codepoint: u32 }{
    .{ .name = "amp", .codepoint = '&' },
    .{ .name = "lt", .codepoint = '<' },
    .{ .name = "gt", .codepoint = '>' },
    .{ .name = "quot", .codepoint = '"' },
    .{ .name = "apos", .codepoint = '\'' },
    .{ .name = "nbsp", .codepoint = 0x00a0 },
    .{ .name = "ndash", .codepoint = 0x2013 },
    .{ .name = "mdash", .codepoint = 0x2014 },
    .{ .name = "lsquo", .codepoint = 0x2018 },
    .{ .name = "rsquo", .codepoint = 0x2019 },
    .{ .name = "ldquo", .codepoint = 0x201c },
    .{ .name = "rdquo", .codepoint = 0x201d },
    .{ .name = "hellip", .codepoint = 0x2026 },
    .{ .name = "middot", .codepoint = 0x00b7 },
    .{ .name = "times", .codepoint = 0x00d7 },
    .{ .name = "copy", .codepoint = 0x00a9 },
    .{ .name = "trade", .codepoint = 0x2122 },
};

const Decoded = struct { codepoint: u32, len: usize };

// Decodes the character reference at text[start] ('&'). An unknown or
// malformed reference is a literal '&'.
fn decodeEntity(text: []const u8, start: usize) Decoded {
    const literal = Decoded{ .codepoint = '&', .len = 1 };
    const limit = @min(text.len, start + 12);
    const semicolon = std.mem.indexOfScalarPos(u8, text[0..limit], start + 1, ';') orelse return literal;
    const name = text[start + 1 .. semicolon];
    const len = semicolon + 1 - start;
    if (name.len >= 2 and name[0] == '#') {
        const hex = name[1] == 'x' or name[1] == 'X';
        const digits = if (hex) name[2..] else name[1..];
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return literal;
        if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return literal;
        return .{ .codepoint = value, .len = len };
    }
    for (NAMED_ENTITIES) |entity| {
        if (std.mem.eql(u8, name, entity.name)) return .{ .codepoint = entity.codepoint, .len = len };
    }
    return literal;
}

fn decodeUtf8(text: []const u8, start: usize) ?Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return null;
    if (len > text.len - start) return null;
    const codepoint = std.unicode.utf8Decode(text[start..][0..len]) catch return null;
    return .{ .codepoint = codepoint, .len = len };
}

fn isTextWhitespace(codepoint: u32) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or
        codepoint == 0x0c or codepoint == 0x00a0;
}

// Decodes HTML text to codepoints the font can draw. Tags are dropped,
// whitespace runs become one space, and characters without a glyph are
// skipped. A title longer than the cap ends with an ellipsis.
fn titleCodepoints(html_text: []const u8, output: []u32) usize {
    return textCodepoints(html_text, output, true);
}

// textCodepoints for plain UTF-8, where '<' and '&' are literal.
fn plainTextCodepoints(text: []const u8, output: []u32) usize {
    return textCodepoints(text, output, false);
}

fn textCodepoints(html_text: []const u8, output: []u32, comptime markup: bool) usize {
    var count: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < html_text.len) {
        const c = html_text[i];
        if (markup and c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html_text, i, '>') orelse break;
            i = close + 1;
            continue;
        }
        const decoded = if (markup and c == '&') decodeEntity(html_text, i) else decodeUtf8(html_text, i) orelse {
            i += 1;
            continue;
        };
        i += decoded.len;
        const codepoint = decoded.codepoint;
        if (isTextWhitespace(codepoint)) {
            pending_space = count > 0;
            continue;
        }
        if (codepoint == 0x00ad or regular.glyphIndex(codepoint) == null) continue;
        const needed: usize = if (pending_space) 2 else 1;
        if (output.len - count < needed + 1) {
            output[count] = 0x2026;
            return count + 1;
        }
        if (pending_space) {
            output[count] = ' ';
            count += 1;
            pending_space = false;
        }
        output[count] = codepoint;
        count += 1;
    }
    return count;
}

// Decodes the character references in an attribute value, so "&amp;"
// between query parameters becomes '&'.
fn decodeAttribute(raw: []const u8, out: []u8) ?[]u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            if (len == out.len) return null;
            out[len] = raw[i];
            len += 1;
            i += 1;
            continue;
        }
        const decoded = decodeEntity(raw, i);
        i += decoded.len;
        if (out.len - len < 4) return null;
        len += std.unicode.utf8Encode(@intCast(decoded.codepoint), out[len..][0..4]) catch return null;
    }
    return out[0..len];
}

fn hexDigit(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

// Percent-decodes a query component in place, with '+' as a space.
fn decodeQueryComponent(component: []u8) []u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < component.len) : (len += 1) {
        const c = component[i];
        if (c == '+') {
            component[len] = ' ';
            i += 1;
        } else if (c == '%' and i + 2 < component.len and hexDigit(component[i + 1]) != null and hexDigit(component[i + 2]) != null) {
            component[len] = hexDigit(component[i + 1]).? * 16 + hexDigit(component[i + 2]).?;
            i += 3;
        } else {
            component[len] = c;
            i += 1;
        }
    }
    return component[0..len];
}

// Unsigned decimal, or hex with a "0x" prefix as qip's -u flag takes.
fn parseQueryNumber(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, value, 0) catch null;
}

// Reads primary, secondary, and the uniforms by name. Other keys, such as a
// cache-busting version, are ignored. The text slices point into
// template_query_buf.
fn parseTemplateQuery(raw_query: []const u8) ?TemplateOptions {
    const query = decodeAttribute(raw_query, &template_query_buf) orelse return null;
    var options = TemplateOptions{};
    var start: usize = 0;
    while (start < query.len) {
        const end = std.mem.indexOfScalarPos(u8, query, start, '&') orelse query.len;
        const part = query[start..end];
        start = end + 1;
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const key = decodeQueryComponent(part[0..eq]);
        const value = if (eq < part.len) decodeQueryComponent(part[eq + 1 ..]) else part[part.len..];
        if (std.mem.eql(u8, key, "primary")) {
            options.primary = value;
        } else if (std.mem.eql(u8, key, "secondary")) {
            options.secondary = value;
        } else if (std.mem.eql(u8, key, "text_color_rgba")) {
            options.text_color_rgba = parseQueryNumber(value);
        } else if (std.mem.eql(u8, key, "background_color_rgba")) {
            options.background_color_rgba = parseQueryNumber(value);
        } else if (std.mem.eql(u8, key, "font_weight")) {
            options.font_weight = parseQueryNumber(value);
        } else if (std.mem.eql(u8, key, "font_max_size")) {
            options.font_max_size = parseQueryNumber(value);
        }
    }
    return options;
}

fn glyphAdvance(glyph_index: usize, use_bold: bool) i32 {
    return if (use_bold) bold.advances[glyph_index] else regular.advances[glyph_index];
}

fn glyphKerning(left: usize, right: usize, use_bold: bool) i32 {
    return if (use_bold) bold.kerning(left, right) else regular.kerning(left, right);
}

// titleCodepoints only keeps codepoints the font covers.
fn glyphIndex(codepoint: u32) usize {
    return regular.glyphIndex(codepoint).?;
}

const DRAWABLE_HEIGHT = @as(f32, @floatFromInt(HEIGHT)) - 2 * PADDING_Y;

// The largest even size from max_size down to min_size at which the
// wrapped text fits in available_height.
fn chooseLayout(text: []const u32, use_bold: bool, max_size: u32, min_size: u32, lines: []Line, available_height: f32) LayoutError!Layout {
    var font_size = max_size;
    while (font_size >= min_size) : (font_size -= FONT_SIZE_STEP) {
        if (layoutForSize(text, font_size, use_bold, lines, available_height)) |layout| return layout else |_| {}
        if (font_size < min_size + FONT_SIZE_STEP) break;
    }
    return error.TextDoesNotFit;
}

fn layoutForSize(text: []const u32, font_size: u32, use_bold: bool, lines: []Line, available_height: f32) LayoutError!Layout {
    const scale = @as(f32, @floatFromInt(font_size)) / regular.UNITS_PER_EM;
    const drawable_width = @as(f32, @floatFromInt(WIDTH)) - 2 * PADDING_X;
    const max_width_units: i32 = @intFromFloat(@floor(drawable_width / scale));
    const line_count = try wrapLines(text, max_width_units, lines, use_bold);
    const line_advance = (regular.ASCENDER - regular.DESCENDER + regular.LINE_GAP) * scale;
    const block_height = line_advance * @as(f32, @floatFromInt(line_count));
    if (block_height > available_height) return error.TextDoesNotFit;
    return .{
        .font_size = font_size,
        .scale = scale,
        .line_advance = line_advance,
        .line_count = line_count,
        .block_height = block_height,
    };
}

// Lays out the primary text, and the secondary text below it when there is
// any, as one block centered vertically. Without secondary text this is the
// layout of text-to-og-image-svg-inter.wasm.
fn layoutCard(primary: []const u32, secondary: []const u32, use_bold: bool) LayoutError!Card {
    var secondary_layout: ?Layout = null;
    var primary_height = DRAWABLE_HEIGHT;
    if (secondary.len > 0) {
        const layout = try chooseLayout(secondary, false, SECONDARY_MAX_FONT_SIZE, SECONDARY_MIN_FONT_SIZE, &secondary_lines, DRAWABLE_HEIGHT / 3);
        primary_height -= layout.block_height + SECONDARY_GAP;
        secondary_layout = layout;
    }
    const max_size = if (requested_max_font_size == 0) AUTO_MAX_FONT_SIZE else requested_max_font_size;
    const primary_layout = try chooseLayout(primary, use_bold, max_size, MIN_FONT_SIZE, &title_lines, primary_height);

    var block_height = primary_layout.block_height;
    if (secondary_layout) |layout| block_height += SECONDARY_GAP + layout.block_height;
    const block_top = (@as(f32, @floatFromInt(HEIGHT)) - block_height) / 2;
    const secondary_top = block_top + primary_layout.block_height + SECONDARY_GAP;
    return .{
        .primary = primary_layout,
        .primary_baseline = block_top + regular.ASCENDER * primary_layout.scale,
        .secondary = secondary_layout,
        .secondary_baseline = if (secondary_layout) |layout| secondary_top + regular.ASCENDER * layout.scale else 0,
    };
}

// Greedy wrapping at spaces, as in text-to-og-image-svg-inter.wasm. A word
// wider than the line does not fit.
fn wrapLines(text: []const u32, max_width_units: i32, line_output: []Line, use_bold: bool) LayoutError!usize {
    var line_count: usize = 0;
    var position: usize = 0;
    while (position < text.len) {
        while (position < text.len and text[position] == ' ') position += 1;
        if (position >= text.len) break;
        if (line_count >= line_output.len) return error.TooManyLines;

        const start = position;
        var end: usize = position;
        var last_space: ?usize = null;
        var width_units: i32 = 0;
        var previous_glyph: ?usize = null;
        while (position < text.len) {
            const glyph_index = glyphIndex(text[position]);
            var next_width = width_units + glyphAdvance(glyph_index, use_bold);
            if (previous_glyph) |previous| next_width += glyphKerning(previous, glyph_index, use_bold);
            if (next_width > max_width_units) {
                if (position == start) return error.TextDoesNotFit;
                if (last_space) |space| {
                    end = space;
                    position = space + 1;
                } else return error.TextDoesNotFit;
                break;
            }
            width_units = next_width;
            if (text[position] == ' ') last_space = position;
            previous_glyph = glyph_index;
            position += 1;
            end = position;
        }
        while (end > start and text[end - 1] == ' ') end -= 1;
        line_output[line_count] = .{ .start = start, .end = end };
        line_count += 1;
    }
    return line_count;
}

const Point = struct { x: f32, y: f32 };

// Keeps every cell an edge touches, plus the cell to its right, in the row.
fn clampX(x: f32) f32 {
    return std.math.clamp(x, 0, @as(f32, @floatFromInt(WIDTH - 2)));
}

// Adds the signed area a line contributes to each cell, in the manner of
// font-rs: a pixel's coverage is the running sum of its row up to it.
fn accumulateLine(a: Point, b: Point) void {
    if (a.y == b.y) return;
    const dir: f32 = if (a.y < b.y) 1 else -1;
    const p0 = if (a.y < b.y) a else b;
    const p1 = if (a.y < b.y) b else a;
    const height_f: f32 = @floatFromInt(HEIGHT);
    if (p1.y <= 0 or p0.y >= height_f) return;
    const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
    var x = p0.x;
    if (p0.y < 0) x -= p0.y * dxdy;
    const y_start: usize = @intFromFloat(@max(0, @floor(p0.y)));
    const y_end: usize = @intFromFloat(@min(height_f, @ceil(p1.y)));
    dirty_y0 = @min(dirty_y0, y_start);
    dirty_y1 = @max(dirty_y1, y_end);
    dirty_x0 = @min(dirty_x0, @as(usize, @intFromFloat(@floor(clampX(@min(p0.x, p1.x))))));
    // A line on a cell boundary also writes the cell to its right.
    dirty_x1 = @max(dirty_x1, @as(usize, @intFromFloat(@ceil(clampX(@max(p0.x, p1.x))))) + 2);
    for (y_start..y_end) |y| {
        const row = coverage[y * WIDTH ..][0..WIDTH];
        const y_f: f32 = @floatFromInt(y);
        const dy = @min(y_f + 1, p1.y) - @max(y_f, p0.y);
        const x_next = x + dxdy * dy;
        const d = dy * dir;
        const x0 = clampX(@min(x, x_next));
        const x1 = clampX(@max(x, x_next));
        const x0_floor = @floor(x0);
        const x0i: usize = @intFromFloat(x0_floor);
        const x1_ceil = @ceil(x1);
        const x1i: usize = @intFromFloat(x1_ceil);
        if (x1i <= x0i + 1) {
            const xmf = 0.5 * (x0 + x1) - x0_floor;
            row[x0i] += d - d * xmf;
            row[x0i + 1] += d * xmf;
        } else {
            const s = 1 / (x1 - x0);
            const x0f = x0 - x0_floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = x1 - x1_ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            row[x0i] += d * a0;
            if (x1i == x0i + 2) {
                row[x0i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                row[x0i + 1] += d * (a1 - a0);
                for (x0i + 2..x1i - 1) |xi| row[xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                row[x1i - 1] += d * (1 - a2 - am);
            }
            row[x1i] += d * am;
        }
        x = x_next;
    }
}

// Flattens a quadratic curve into lines no more than about a third of a
// pixel from it.
fn accumulateQuad(p0: Point, p1: Point, p2: Point) void {
    const ddx = p0.x - 2 * p1.x + p2.x;
    const ddy = p0.y - 2 * p1.y + p2.y;
    const deviation2 = ddx * ddx + ddy * ddy;
    if (deviation2 < 0.333) {
        accumulateLine(p0, p2);
        return;
    }
    const steps_f = @min(@floor(@sqrt(@sqrt(3 * deviation2))), @as(f32, MAX_CURVE_SEGMENTS - 1));
    const steps: usize = 1 + @as(usize, @intFromFloat(steps_f));
    const steps_inv = 1 / @as(f32, @floatFromInt(steps));
    var previous = p0;
    for (1..steps) |i| {
        const t = @as(f32, @floatFromInt(i)) * steps_inv;
        const mt = 1 - t;
        const point = Point{
            .x = mt * mt * p0.x + 2 * t * mt * p1.x + t * t * p2.x,
            .y = mt * mt * p0.y + 2 * t * mt * p1.y + t * t * p2.y,
        };
        accumulateLine(previous, point);
        previous = point;
    }
    accumulateLine(previous, p2);
}

// Packed glyph coordinates are half font units with y pointing down.
fn drawGlyph(comptime font: type, glyph_index: usize, origin_x: f32, baseline_y: f32, scale: f32) void {
    const commands = font.glyph_commands[font.glyph_command_offsets[glyph_index]..font.glyph_command_offsets[glyph_index + 1]];
    const coords = font.glyph_coords;
    var coord_index: usize = font.glyph_coord_offsets[glyph_index];
    const half_scale = scale * 0.5;
    const point = struct {
        fn at(c: []const i16, i: usize, ox: f32, oy: f32, s: f32) Point {
            return .{ .x = ox + @as(f32, @floatFromInt(c[i])) * s, .y = oy + @as(f32, @floatFromInt(c[i + 1])) * s };
        }
    }.at;
    var start = Point{ .x = origin_x, .y = baseline_y };
    var current = start;
    for (commands) |command| {
        switch (command) {
            'M' => {
                // A fill closes any open subpath.
                accumulateLine(current, start);
                start = point(&coords, coord_index, origin_x, baseline_y, half_scale);
                current = start;
                coord_index += 2;
            },
            'L' => {
                const next = point(&coords, coord_index, origin_x, baseline_y, half_scale);
                accumulateLine(current, next);
                current = next;
                coord_index += 2;
            },
            'Q' => {
                const control = point(&coords, coord_index, origin_x, baseline_y, half_scale);
                const next = point(&coords, coord_index + 2, origin_x, baseline_y, half_scale);
                accumulateQuad(current, control, next);
                current = next;
                coord_index += 4;
            },
            'Z' => {
                accumulateLine(current, start);
                current = start;
            },
            else => unreachable,
        }
    }
    accumulateLine(current, start);
}

fn drawCard(primary: []const u32, secondary: []const u32, card: Card, use_bold: bool) void {
    drawLines(primary, title_lines[0..card.primary.line_count], card.primary, card.primary_baseline, use_bold);
    if (card.secondary) |layout| {
        drawLines(secondary, secondary_lines[0..layout.line_count], layout, card.secondary_baseline, false);
    }
}

fn drawLines(text: []const u32, lines: []const Line, layout: Layout, first_baseline: f32, use_bold: bool) void {
    for (lines, 0..) |line, line_index| {
        const baseline_y = first_baseline + @as(f32, @floatFromInt(line_index)) * layout.line_advance;
        var cursor_units: i32 = 0;
        for (line.start..line.end) |index| {
            const glyph_index = glyphIndex(text[index]);
            const origin_x = PADDING_X + @as(f32, @floatFromInt(cursor_units)) * layout.scale;
            if (use_bold) {
                drawGlyph(bold, glyph_index, origin_x, baseline_y, layout.scale);
            } else {
                drawGlyph(regular, glyph_index, origin_x, baseline_y, layout.scale);
            }
            cursor_units += glyphAdvance(glyph_index, use_bold);
            if (index + 1 < line.end) cursor_units += glyphKerning(glyph_index, glyphIndex(text[index + 1]), use_bold);
        }
    }
}

// Rows [y0, y1) hold ink. Every other row is background: a zero filter byte
// then zero palette indexes.
const Band = struct { y0: usize, y1: usize };

// Turns accumulated area into palette indexes for the band's rows and clears
// the accumulator. Each closed outline adds zero to every row, so each row's
// sum starts at 0 and is 0 again right of the dirty cells.
fn resolveCoverage() Band {
    const band: Band = if (dirty_y0 < dirty_y1 and dirty_x0 < dirty_x1)
        .{ .y0 = dirty_y0, .y1 = dirty_y1 }
    else
        .{ .y0 = 0, .y1 = 0 };
    @memset(filtered_buf[band.y0 * (WIDTH + 1) .. band.y1 * (WIDTH + 1)], 0);
    for (band.y0..band.y1) |y| {
        const row = coverage[y * WIDTH ..][dirty_x0..dirty_x1];
        const out = filtered_buf[y * (WIDTH + 1) + 1 ..][dirty_x0..dirty_x1];
        var sum: f32 = 0;
        for (row, out) |*cell, *index| {
            sum += cell.*;
            cell.* = 0;
            index.* = @intFromFloat(@min(@abs(sum), 1) * 255 + 0.5);
        }
    }
    dirty_x0 = WIDTH;
    dirty_x1 = 0;
    dirty_y0 = HEIGHT;
    dirty_y1 = 0;
    return band;
}

// LSB-first bit output for the DEFLATE blocks this component writes itself.
const BitStream = struct {
    out: []u8,
    at: usize,
    bits: u64 = 0,
    count: u6 = 0,

    fn write(self: *BitStream, value: u32, n: u6) void {
        self.bits |= @as(u64, value) << self.count;
        self.count += n;
        while (self.count >= 8) {
            self.out[self.at] = @truncate(self.bits);
            self.at += 1;
            self.bits >>= 8;
            self.count -= 8;
        }
    }

    fn alignToByte(self: *BitStream) void {
        if (self.count == 0) return;
        self.out[self.at] = @truncate(self.bits);
        self.at += 1;
        self.bits = 0;
        self.count = 0;
    }

    // An empty stored block, as zlib's Z_SYNC_FLUSH writes, so the next
    // block starts on a byte boundary.
    fn syncFlush(self: *BitStream) void {
        self.write(0, 3);
        self.alignToByte();
        @memcpy(self.out[self.at..][0..4], &[4]u8{ 0x00, 0x00, 0xff, 0xff });
        self.at += 4;
    }
};

// Writes `len` zero bytes as one dynamic-Huffman block: a literal 0, then
// 258-byte matches at distance 1, then one shorter match or up to two more
// literals. The fixed code would spend 13 bits on each 258-byte match; these
// tables spend 2. Codes are canonical Huffman codes, bit-reversed for output:
//
//   literal/length: 285 "0", 0 "10", 256 "110", remainder length "111"
//   distance: 0 "0", 1 "1" (unused, so the code is complete)
//   code length: 17 "00", 18 "01", 0 "100", 1 "101", 2 "110", 3 "111"
fn writeZeroRunBlock(stream: *BitStream, len: usize, final: bool) void {
    const after_literal = len -| 1;
    const remainder = after_literal % deflate.MAX_MATCH;
    const remainder_symbol: u16 = if (remainder >= 3) deflate.encodeLength(remainder).symbol else 257;

    stream.write(0b100 | @as(u32, @intFromBool(final)), 3);
    stream.write(286 - 257, 5); // HLIT: literal/length codes 0-285
    stream.write(2 - 1, 5); // HDIST: distance codes 0-1
    // Code length code lengths in RFC 1951 order 16, 17, 18, 0, 8, 7, 9, 6,
    // 10, 5, 11, 4, 12, 3, 13, 2, 14, 1.
    const cl_lengths = [_]u3{ 0, 2, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 3, 0, 3 };
    stream.write(cl_lengths.len - 4, 4);
    for (cl_lengths) |cl_len| stream.write(cl_len, 3);

    const zeros = struct {
        // Runs of zero code lengths with CL symbols 18, 17, and 0.
        fn write(s: *BitStream, count: usize) void {
            var left = count;
            while (left >= 11) {
                const n = @min(left, 138);
                s.write(0b10, 2); // 18
                s.write(@intCast(n - 11), 7);
                left -= n;
            }
            if (left >= 3) {
                s.write(0b00, 2); // 17
                s.write(@intCast(left - 3), 3);
                left = 0;
            }
            for (0..left) |_| s.write(0b001, 3); // 0
        }
    }.write;
    const cl_one = 0b101;
    const cl_two = 0b011;
    const cl_three = 0b111;
    stream.write(cl_two, 3); // literal 0
    zeros(stream, 255);
    stream.write(cl_three, 3); // 256
    zeros(stream, remainder_symbol - 257);
    stream.write(cl_three, 3); // remainder length
    zeros(stream, 284 - remainder_symbol);
    stream.write(cl_one, 3); // 285
    stream.write(cl_one, 3); // distance 0
    stream.write(cl_one, 3); // distance 1

    if (len != 0) stream.write(0b01, 2); // literal 0
    for (0..after_literal / deflate.MAX_MATCH) |_| stream.write(0b00, 2); // 285, distance 1
    if (remainder >= 3) {
        const length = deflate.encodeLength(remainder);
        stream.write(0b111, 3);
        stream.write(length.extra_value, @intCast(length.extra_bits));
        stream.write(0, 1); // distance 1
    } else {
        for (0..remainder) |_| stream.write(0b01, 2); // literal 0
    }
    stream.write(0b011, 3); // end of block
}

const ADLER_MOD: u32 = 65521;

// Adler-32 of the filtered image. Each blank row adds zero bytes, which
// leave the first sum alone and add it to the second sum once per byte.
fn adler32(band: Band) u32 {
    var a: u64 = 1;
    var b: u64 = 0;
    const blank_before = band.y0 * (WIDTH + 1);
    b = (b + a * blank_before) % ADLER_MOD;
    var hasher = std.hash.Adler32{ .adler = @intCast((b << 16) | a) };
    hasher.update(filtered_buf[blank_before .. band.y1 * (WIDTH + 1)]);
    a = hasher.adler & 0xffff;
    b = hasher.adler >> 16;
    b = (b + a * ((HEIGHT - band.y1) * (WIDTH + 1))) % ADLER_MOD;
    return @intCast((b << 16) | a);
}

// Writes the zlib stream for the filtered image into `out`. Only the band
// goes through the general compressor; blank rows above and below it are
// zero-run blocks, which cost no per-byte work.
fn compressImage(band: Band, out: []u8) ?usize {
    if (out.len < 2 + 4) return null;
    out[0] = 0x78;
    out[1] = 0x01;
    var stream = BitStream{ .out = out, .at = 2 };
    if (band.y0 > 0) {
        writeZeroRunBlock(&stream, band.y0 * (WIDTH + 1), false);
        stream.syncFlush();
    }
    if (band.y1 > band.y0) {
        const band_bytes = filtered_buf[band.y0 * (WIDTH + 1) .. band.y1 * (WIDTH + 1)];
        // Band rows are mostly background too, so long matches turn up within
        // a few candidates. Searching 8 instead of the default 256 encoded
        // qip.dev's 153 cards 2.4 times faster and 1.1% smaller.
        const n = deflate.compressRawSyncFlushWithOptions(band_bytes, out[stream.at .. out.len - 4], &token_buf, .{ .max_chain = 8 }) orelse return null;
        stream.at += n;
    }
    writeZeroRunBlock(&stream, (HEIGHT - band.y1) * (WIDTH + 1), true);
    stream.alignToByte();
    std.mem.writeInt(u32, out[stream.at..][0..4], adler32(band), .big);
    return stream.at + 4;
}

fn channel(rgba: u32, shift: u5) f32 {
    return @as(f32, @floatFromInt((rgba >> shift) & 0xff)) / 255;
}

fn unorm8(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * 255 + 0.5);
}

fn writeChunk(buf: []u8, at: usize, kind: *const [4]u8, data_len: usize) usize {
    std.mem.writeInt(u32, buf[at..][0..4], @intCast(data_len), .big);
    @memcpy(buf[at + 4 ..][0..4], kind);
    const crc = std.hash.Crc32.hash(buf[at + 4 .. at + 8 + data_len]);
    std.mem.writeInt(u32, buf[at + 8 + data_len ..][0..4], crc, .big);
    return at + 12 + data_len;
}

// Writes the PNG for the current filtered_buf into png_buf. Palette entry N
// is the text color source-over the background at N/255 coverage, in sRGB
// as SVG compositing does.
fn encodePNG(band: Band) ?[]const u8 {
    const signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    @memcpy(png_buf[0..8], &signature);
    var at: usize = 8;

    const ihdr = png_buf[at + 8 ..][0..13];
    std.mem.writeInt(u32, ihdr[0..4], WIDTH, .big);
    std.mem.writeInt(u32, ihdr[4..8], HEIGHT, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 3; // indexed color
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    at = writeChunk(&png_buf, at, "IHDR", 13);

    const text_alpha = channel(text_color_rgba, 0);
    const background_alpha = channel(background_color_rgba, 0);
    const plte = png_buf[at + 8 ..][0 .. 256 * 3];
    var alphas: [256]u8 = undefined;
    for (0..256) |i| {
        const source_alpha = @as(f32, @floatFromInt(i)) / 255 * text_alpha;
        const destination_weight = background_alpha * (1 - source_alpha);
        const out_alpha = source_alpha + destination_weight;
        const shifts = [3]u5{ 24, 16, 8 };
        for (shifts, 0..) |shift, c| {
            const blended = channel(text_color_rgba, shift) * source_alpha + channel(background_color_rgba, shift) * destination_weight;
            plte[i * 3 + c] = if (out_alpha > 0) unorm8(blended / out_alpha) else 0;
        }
        alphas[i] = unorm8(out_alpha);
    }
    at = writeChunk(&png_buf, at, "PLTE", 256 * 3);

    if (background_alpha < 1) {
        @memcpy(png_buf[at + 8 ..][0..256], &alphas);
        at = writeChunk(&png_buf, at, "tRNS", 256);
    }

    const compressed_len = compressImage(band, png_buf[at + 8 .. png_buf.len - 24]) orelse return null;
    at = writeChunk(&png_buf, at, "IDAT", compressed_len);
    at = writeChunk(&png_buf, at, "IEND", 0);
    return png_buf[0..at];
}

fn renderCardPNG(primary: []const u32, secondary: []const u32) ?[]const u8 {
    const use_bold = font_weight == 700;
    const card = layoutCard(primary, secondary, use_bold) catch return null;
    drawCard(primary, secondary, card, use_bold);
    return encodePNG(resolveCoverage());
}

fn hasImagePath(path: []const u8) bool {
    for (image_paths[0..image_path_count]) |existing| {
        if (std.mem.eql(u8, existing, path)) return true;
    }
    return false;
}

fn addImagePath(path: []const u8) void {
    if (image_path_count >= image_paths.len) @trap();
    image_paths[image_path_count] = path;
    image_path_count += 1;
}

fn collectExistingImagePaths(input: []const u8) void {
    image_path_count = 0;
    added_path_len = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;
        if (!eqlIgnoreCase(record.warc_type, "response")) continue;
        const path = pathFromTargetURI(record.target_uri);
        if (std.mem.startsWith(u8, path, "/_og/") and !hasImagePath(path)) addImagePath(path);
    }
}

fn rememberAddedPath(path: []const u8) void {
    if (path.len > added_path_bytes.len - added_path_len) @trap();
    const copy = added_path_bytes[added_path_len..][0..path.len];
    @memcpy(copy, path);
    added_path_len += path.len;
    addImagePath(copy);
}

fn writeMetaSnippet(out: *Output, origin: []const u8, og_path: []const u8) void {
    out.writeSlice(META_OG_IMAGE_PREFIX);
    out.writeSlice(origin);
    out.writeSlice(og_path);
    out.writeSlice(META_OG_IMAGE_SUFFIX);
    out.writeSlice(META_TWITTER_CARD);
    out.writeSlice(META_TWITTER_IMAGE_PREFIX);
    out.writeSlice(origin);
    out.writeSlice(og_path);
    out.writeSlice(META_TWITTER_IMAGE_SUFFIX);
}

fn metaSnippetLen(url_len: usize) usize {
    return META_OG_IMAGE_PREFIX.len + url_len + META_OG_IMAGE_SUFFIX.len +
        META_TWITTER_CARD.len +
        META_TWITTER_IMAGE_PREFIX.len + url_len + META_TWITTER_IMAGE_SUFFIX.len;
}

fn hexLower(byte: u8) [2]u8 {
    const digits = "0123456789abcdef";
    return .{ digits[byte >> 4], digits[byte & 0x0f] };
}

// A stable record ID from the image's target URI, so rebuilding the same
// site gives the same archive.
fn writeRecordID(out: *Output, origin: []const u8, og_path: []const u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("warc-add-open-graph-image-inter-png:");
    hasher.update(origin);
    hasher.update(og_path);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    out.writeSlice("WARC-Record-ID: <urn:uuid:");
    for (digest[0..16], 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) out.writeSlice("-");
        out.writeSlice(&hexLower(byte));
    }
    out.writeSlice(">\r\n");
}

fn writeImageRecord(out: *Output, origin: []const u8, og_path: []const u8, warc_date: []const u8, png: []const u8) void {
    const http_head_len = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ".len +
        std.fmt.count("{d}", .{png.len}) + 4;
    out.writeSlice("WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: ");
    out.writeSlice(origin);
    out.writeSlice(og_path);
    out.writeSlice("\r\nWARC-Date: ");
    out.writeSlice(warc_date);
    out.writeSlice("\r\n");
    writeRecordID(out, origin, og_path);
    out.writeSlice("Content-Type: application/http; msgtype=response\r\nContent-Length: ");
    out.writeUnsigned(http_head_len + png.len);
    out.writeSlice("\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ");
    out.writeUnsigned(png.len);
    out.writeSlice("\r\n\r\n");
    out.writeSlice(png);
    out.writeSlice("\r\n\r\n");
}

// Renders the template's primary text, else the head's <title>, else the
// first <h1>, using the first that has something the font can draw. The
// template's secondary text and uniforms apply to this page only.
fn renderPage(head_title: ?[]const u8, body: []const u8, options: TemplateOptions) ?[]const u8 {
    var count: usize = if (options.primary) |primary| plainTextCodepoints(primary, &title_codepoints) else 0;
    if (count == 0) {
        if (head_title) |title| count = titleCodepoints(title, &title_codepoints);
    }
    if (count == 0) {
        const h1 = firstH1(body) orelse return null;
        count = titleCodepoints(h1, &title_codepoints);
    }
    if (count == 0) return null;
    const secondary_count = if (options.secondary) |secondary| plainTextCodepoints(secondary, &secondary_codepoints) else 0;

    const saved = .{ text_color_rgba, background_color_rgba, font_weight, requested_max_font_size };
    defer {
        text_color_rgba = saved[0];
        background_color_rgba = saved[1];
        font_weight = saved[2];
        requested_max_font_size = saved[3];
    }
    if (options.text_color_rgba) |value| _ = uniform_set_text_color_rgba(value);
    if (options.background_color_rgba) |value| _ = uniform_set_background_color_rgba(value);
    if (options.font_weight) |value| _ = uniform_set_font_weight(value);
    if (options.font_max_size) |value| _ = uniform_set_font_max_size(value);
    return renderCardPNG(title_codepoints[0..count], secondary_codepoints[0..secondary_count]);
}

// The body with the meta snippet in place of the first template tag and
// the other template tags removed, or inserted at insert_at without any.
fn writePageBody(out: *Output, body: []const u8, head: HeadScan, origin: []const u8, og_path: []const u8) void {
    if (head.template_count == 0) {
        out.writeSlice(body[0..head.insert_at]);
        writeMetaSnippet(out, origin, og_path);
        out.writeSlice(body[head.insert_at..]);
        return;
    }
    var cursor: usize = 0;
    for (head.templates[0..head.template_count], 0..) |tag, i| {
        out.writeSlice(body[cursor..tag.start]);
        if (i == 0) writeMetaSnippet(out, origin, og_path);
        cursor = tag.end;
    }
    out.writeSlice(body[cursor..]);
}

fn pageBodyLen(body: []const u8, head: HeadScan, url_len: usize) usize {
    var len = body.len + metaSnippetLen(url_len);
    for (head.templates[0..head.template_count]) |tag| len -= tag.end - tag.start;
    return len;
}

fn processWARC(input: []const u8, out: *Output) void {
    collectExistingImagePaths(input);
    var cursor: usize = 0;
    var og_path_buf: [4096]u8 = undefined;

    while (cursor < input.len and !out.overflow) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;

        const page = blk: {
            if (!eqlIgnoreCase(record.warc_type, "response")) break :blk null;
            const http = parseHTTPPayload(record.payload) orelse break :blk null;
            if (http.status != 200 or !isHTMLContentType(http.content_type)) break :blk null;
            const origin = originFromTargetURI(record.target_uri);
            const head = scanHead(http.body);
            if (!head.should_inject) break :blk null;
            var options = TemplateOptions{};
            var og_path: []const u8 = undefined;
            if (head.template_count > 0) {
                // scanHead only keeps tags whose URL is a template.
                const template = templateURL(head.template_url).?;
                options = parseTemplateQuery(template.query) orelse break :blk null;
                og_path = template.path;
            } else {
                og_path = ogImagePathForRequestPath(pathFromTargetURI(record.target_uri), &og_path_buf) orelse break :blk null;
            }
            if (!isSafeURL(origin) or !isSafeURL(og_path)) break :blk null;
            break :blk .{ .http = http, .head = head, .og_path = og_path, .origin = origin, .options = options };
        };

        var png: ?[]const u8 = null;
        var has_image = false;
        if (page) |p| {
            has_image = hasImagePath(p.og_path);
            if (!has_image) {
                png = renderPage(p.head.title, p.http.body, p.options);
                has_image = png != null;
            }
        }

        if (page != null and has_image) {
            const p = page.?;
            const body_len = pageBodyLen(p.http.body, p.head, p.origin.len + p.og_path.len);
            const payload_len = warc.httpHeaderRewriteLen(p.http.header_block, p.http.status_line, body_len) + body_len;
            warc.writeRecordHeader(out, record.header_block, payload_len, true);
            warc.writeRewrittenHTTPHeaders(out, p.http.header_block, p.http.status_line, body_len);
            writePageBody(out, p.http.body, p.head, p.origin, p.og_path);
            out.writeSlice("\r\n\r\n");
            if (png) |png_bytes| {
                writeImageRecord(out, p.origin, p.og_path, record.warc_date, png_bytes);
                rememberAddedPath(p.og_path);
            }
        } else {
            warc.writeRecordHeader(out, record.header_block, record.payload.len, false);
            out.writeSlice(record.payload);
            out.writeSlice("\r\n\r\n");
        }
    }
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    var out = Output{};
    processWARC(input_buf[0..input_size], &out);
    resetUniforms();
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

fn appendWARCRecord(out_buf: []u8, cursor: *usize, target_uri: []const u8, payload: []const u8) !void {
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.1\r\nWARC-Type: response\r\nWARC-Target-URI: {s}\r\nWARC-Date: 2000-01-01T00:00:00Z\r\nWARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-{d:0>12}>\r\nContent-Type: application/http; msgtype=response\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ target_uri, cursor.*, payload.len, payload },
    );
    cursor.* += rec.len;
}

fn runTransform(input: []const u8) []const u8 {
    @memcpy(input_buf[0..input.len], input);
    const n = renderImpl(@as(u32, @intCast(input.len)));
    return output_buf[0..n];
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

const PNG_SIGNATURE = "\x89PNG\r\n\x1a\n";

test "adds absolute og image tags and a PNG record after the page" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/docs/formats", "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<!doctype html><html><head><title>Formats &amp; Encodings</title></head><body><h1>Other</h1></body></html>");

    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta property=\"og:image\" content=\"https://qip.dev/_og/docs/formats.png\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta name=\"twitter:image\" content=\"https://qip.dev/_og/docs/formats.png\" />") != null);
    const image_record = std.mem.indexOf(u8, out, "WARC-Target-URI: https://qip.dev/_og/docs/formats.png\r\n").?;
    try std.testing.expect(image_record > std.mem.indexOf(u8, out, "</html>").?);
    try std.testing.expect(std.mem.indexOf(u8, out[image_record..], "Content-Type: image/png\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[image_record..], PNG_SIGNATURE ++ "\x00\x00\x00\x0dIHDR\x00\x00\x04\xb0\x00\x00\x02\x76\x08\x03") != null);
}

test "renders the decoded title in Inter" {
    const count = titleCodepoints("Formats &amp; <em>Encodings</em>&#x2014;caf\xc3\xa9", &title_codepoints);
    const expected = [_]u32{ 'F', 'o', 'r', 'm', 'a', 't', 's', ' ', '&', ' ', 'E', 'n', 'c', 'o', 'd', 'i', 'n', 'g', 's', 0x2014, 'c', 'a', 'f', 0xe9 };
    try std.testing.expectEqualSlices(u32, &expected, title_codepoints[0..count]);

    const card = try layoutCard(title_codepoints[0..1], &.{}, true);
    try std.testing.expectEqual(AUTO_MAX_FONT_SIZE, card.primary.font_size);
    drawCard(title_codepoints[0..1], &.{}, card, true);
    const band = resolveCoverage();
    try std.testing.expect(band.y0 > 0 and band.y1 < HEIGHT);
    // The F's stem is solid ink just right of the left margin; the margin is
    // background.
    const stem_y: usize = @intFromFloat(card.primary_baseline - 20);
    try std.testing.expectEqual(@as(u8, 255), filtered_buf[stem_y * (WIDTH + 1) + 1 + 110]);
    try std.testing.expectEqual(@as(u8, 0), filtered_buf[stem_y * (WIDTH + 1) + 1 + 10]);
    for (coverage) |cell| try std.testing.expectEqual(@as(f32, 0), cell);
}

// Inflates the PNG's IDAT data and checks it is the band's rows with blank
// rows around them.
fn expectImageDataDecodes(png: []const u8, band: Band) !void {
    const Inflated = struct {
        var bytes: [FILTERED_LEN + 1]u8 = undefined;
    };
    const idat = std.mem.indexOf(u8, png, "IDAT").?;
    const idat_len = std.mem.readInt(u32, png[idat - 4 ..][0..4], .big);
    var reader: std.Io.Reader = .fixed(png[idat + 4 ..][0..idat_len]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    var writer: std.Io.Writer = .fixed(&Inflated.bytes);
    const n = try decompress.reader.streamRemaining(&writer);
    try std.testing.expectEqual(FILTERED_LEN, n);
    const band_start = band.y0 * (WIDTH + 1);
    const band_end = band.y1 * (WIDTH + 1);
    for (Inflated.bytes[0..band_start]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqualSlices(u8, filtered_buf[band_start..band_end], Inflated.bytes[band_start..band_end]);
    for (Inflated.bytes[band_end..FILTERED_LEN]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "image data inflates to the band between blank rows" {
    const count = titleCodepoints("A title long enough to wrap onto more than one line of the card", &title_codepoints);
    const card = try layoutCard(title_codepoints[0..count], &.{}, true);
    try std.testing.expect(card.primary.line_count > 1);
    drawCard(title_codepoints[0..count], &.{}, card, true);
    const band = resolveCoverage();
    try expectImageDataDecodes(encodePNG(band).?, band);
}

test "zero-run blocks cover every remainder length" {
    // Blank image: one final zero-run block.
    try expectImageDataDecodes(encodePNG(.{ .y0 = 0, .y1 = 0 }).?, .{ .y0 = 0, .y1 = 0 });
    // Bands touching the top and bottom edges skip one zero-run block.
    @memset(filtered_buf[0 .. 3 * (WIDTH + 1)], 7);
    try expectImageDataDecodes(encodePNG(.{ .y0 = 0, .y1 = 3 }).?, .{ .y0 = 0, .y1 = 3 });
    @memset(filtered_buf[(HEIGHT - 2) * (WIDTH + 1) ..], 7);
    try expectImageDataDecodes(encodePNG(.{ .y0 = HEIGHT - 2, .y1 = HEIGHT }).?, .{ .y0 = HEIGHT - 2, .y1 = HEIGHT });
    // Each remainder after the 258-byte matches, from none to 257.
    var out: [4096]u8 = undefined;
    var zeros: [2048]u8 = @splat(0);
    for (0..deflate.MAX_MATCH + 2) |extra| {
        const len = 1 + deflate.MAX_MATCH * 3 + extra;
        var stream = BitStream{ .out = &out, .at = 0 };
        writeZeroRunBlock(&stream, len, true);
        stream.alignToByte();
        var reader: std.Io.Reader = .fixed(out[0..stream.at]);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&reader, .raw, &window);
        var decoded: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&decoded);
        try std.testing.expectEqual(len, try decompress.reader.streamRemaining(&writer));
        try std.testing.expectEqualSlices(u8, zeros[0..len], decoded[0..len]);
    }
}

test "falls back to the first h1 and skips characters without glyphs" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><meta charset=\"utf-8\"></head><body><svg><title>Icon</title></svg><h1 class=\"x\">Hello \xce\xa9 <code>world</code></h1></body></html>");
    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expect(std.mem.indexOf(u8, out, "content=\"https://qip.dev/_og/index.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "WARC-Target-URI: https://qip.dev/_og/index.png\r\n") != null);

    const h1 = firstH1("<h10>no</h10><H1>Yes</H1>").?;
    try std.testing.expectEqualStrings("Yes", h1);
    const count = titleCodepoints("Hello \xce\xa9 <code>world</code>", &title_codepoints);
    try std.testing.expectEqualSlices(u32, &.{ 'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd' }, title_codepoints[0..count]);
}

test "keeps pages that already declare an image unchanged" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title>x</title><meta property=\"og:image\" content=\"/existing.png\" /></head><body>x</body></html>");
    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expectEqualStrings(warc_bytes[0..n], out);
}

test "points at an image the archive already has instead of rendering" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/forms", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title>Forms</title></head><body>x</body></html>");
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/forms.html", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title>Forms</title></head><body>x</body></html>");
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/_og/blog.png", "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nPNG");
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/blog/", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title>Blog</title></head><body>x</body></html>");
    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "WARC-Target-URI: https://qip.dev/_og/forms.png\r\n"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(out, "property=\"og:image\" content=\"https://qip.dev/_og/forms.png\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "WARC-Target-URI: https://qip.dev/_og/blog.png\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "property=\"og:image\" content=\"https://qip.dev/_og/blog.png\"") != null);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, PNG_SIGNATURE));
}

test "uses a root-relative image path when the target URI has no origin" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "/how-it-works", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title>How it works</title></head><body>x</body></html>");
    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expect(std.mem.indexOf(u8, out, "property=\"og:image\" content=\"/_og/how-it-works.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "WARC-Target-URI: /_og/how-it-works.png\r\n") != null);
}

test "pages without title text get no image" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/empty", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title> </title></head><body><p>No heading</p></body></html>");
    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expectEqualStrings(warc_bytes[0..n], out);
}

test "transparent backgrounds add a tRNS chunk" {
    _ = uniform_set_background_color_rgba(0x00000000);
    const text = [_]u32{'A'};
    const png = renderCardPNG(&text, &.{}).?;
    try std.testing.expect(std.mem.indexOf(u8, png, "tRNS") != null);
    resetUniforms();
    const opaque_png = renderCardPNG(&text, &.{}).?;
    try std.testing.expect(std.mem.indexOf(u8, opaque_png, "tRNS") == null);
}

fn pageBody(out: []const u8, target_uri: []const u8) []const u8 {
    const record = std.mem.indexOf(u8, out, target_uri).?;
    const start = std.mem.indexOfPos(u8, out, record, "\r\n\r\n<").? + 4;
    const end = std.mem.indexOfPos(u8, out, start, "</html>").? + "</html>".len;
    return out[start..end];
}

test "a template og:image URL renders its query and drops the query from the tags" {
    var warc_bytes: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><head><title>QIP</title><meta property=\"og:image\" content=\"/_og/home.png?primary=A+new+way+to+render&amp;secondary=qip.dev%20%E2%80%94%20WebAssembly&amp;background_color_rgba=0x4b2e83ff&amp;v=2\"><meta name=\"twitter:image\" content=\"/_og/home.png?primary=ignored\"></head><body>x</body></html>");
    const out = runTransform(warc_bytes[0..n]);
    try std.testing.expectEqualStrings(
        "<html><head><title>QIP</title><meta property=\"og:image\" content=\"https://qip.dev/_og/home.png\" />\n" ++
            "<meta name=\"twitter:card\" content=\"summary_large_image\" />\n" ++
            "<meta name=\"twitter:image\" content=\"https://qip.dev/_og/home.png\" />\n" ++
            "</head><body>x</body></html>",
        pageBody(out, "WARC-Target-URI: https://qip.dev/\r\n"),
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "WARC-Target-URI: https://qip.dev/_og/home.png\r\n"));
    try std.testing.expect(warc.validateArchive(out));
    // The page's uniforms don't outlast it.
    try std.testing.expectEqual(DEFAULT_BACKGROUND_COLOR_RGBA, background_color_rgba);

    const options = parseTemplateQuery("primary=A+new+way&amp;secondary=qip.dev%20%E2%80%94%20Wasm&amp;font_weight=400&amp;font_max_size=bad&amp;v=2").?;
    try std.testing.expectEqualStrings("A new way", options.primary.?);
    try std.testing.expectEqualStrings("qip.dev \xe2\x80\x94 Wasm", options.secondary.?);
    try std.testing.expectEqual(@as(?u32, 400), options.font_weight);
    try std.testing.expectEqual(@as(?u32, null), options.font_max_size);
}

test "secondary text sits below the primary text in Regular" {
    const primary_count = plainTextCodepoints("A new way to render", &title_codepoints);
    const secondary_count = plainTextCodepoints("qip.dev WebAssembly everywhere", &secondary_codepoints);
    const card = try layoutCard(title_codepoints[0..primary_count], secondary_codepoints[0..secondary_count], true);
    const secondary = card.secondary.?;
    try std.testing.expect(secondary.font_size < card.primary.font_size);
    try std.testing.expect(card.secondary_baseline > card.primary_baseline + card.primary.block_height - card.primary.line_advance);
    // The block stays centered: equal space above the first line and below
    // the last.
    const top = card.primary_baseline - regular.ASCENDER * card.primary.scale;
    const bottom = card.secondary_baseline - regular.ASCENDER * secondary.scale + secondary.block_height;
    try std.testing.expectApproxEqAbs(top, @as(f32, @floatFromInt(HEIGHT)) - bottom, 0.01);

    drawCard(title_codepoints[0..primary_count], secondary_codepoints[0..secondary_count], card, true);
    const band = resolveCoverage();
    try expectImageDataDecodes(encodePNG(band).?, band);
}

test "template tags with no query or outside /_og/ leave the page unchanged" {
    const pages = [_][]const u8{
        "<html><head><title>x</title><meta property=\"og:image\" content=\"/_og/x.png\"></head><body>x</body></html>",
        "<html><head><title>x</title><meta property=\"og:image\" content=\"/images/x.png?primary=y\"></head><body>x</body></html>",
        "<html><head><title>x</title><meta property=\"og:image\" content=\"/_og/x.png?primary=y\"><meta name=\"twitter:image\" content=\"/other.png\"></head><body>x</body></html>",
    };
    for (pages) |page| {
        var warc_bytes: [8192]u8 = undefined;
        var n: usize = 0;
        var payload_buf: [1024]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n{s}", .{page});
        try appendWARCRecord(&warc_bytes, &n, "https://qip.dev/x", payload);
        try std.testing.expectEqualStrings(warc_bytes[0..n], runTransform(warc_bytes[0..n]));
    }
}

test "attributeValue reads quoted, unquoted, and mixed-case attributes" {
    try std.testing.expectEqualStrings("/a?b", attributeValue("<meta property=\"og:image\" CONTENT='/a?b'>", "content").?);
    try std.testing.expectEqualStrings("/a", attributeValue("<meta data-x=\"content=/no\" content=/a />", "content").?);
    try std.testing.expectEqual(@as(?[]const u8, null), attributeValue("<meta name=\"content\">", "content"));
}
