//! Reflowable, text-only EPUB reader. The archive, package and spine are read
//! inside Wasm; the host supplies only the EPUB bytes and terminal dimensions.
const std = @import("std");
const zip = @import("zip");

const INPUT_CAP = 24 * 1024 * 1024;
const FILE_CAP = 2 * 1024 * 1024;
const TEXT_CAP = 8 * 1024 * 1024;
const OUTPUT_CAP = 512 * 1024;
const MAX_LINES = 400_000;
const MAX_CHAPTERS = 512;
const MAX_STYLE_RULES = 1024;
const FLAG_DOWN: i32 = 1;
const XK_HOME: i32 = 0xff50;
const XK_LEFT: i32 = 0xff51;
const XK_UP: i32 = 0xff52;
const XK_RIGHT: i32 = 0xff53;
const XK_DOWN: i32 = 0xff54;
const XK_PAGE_UP: i32 = 0xff55;
const XK_PAGE_DOWN: i32 = 0xff56;
const XK_END: i32 = 0xff57;

const Phase = enum { initial, ready, updating };
var phase: Phase = .initial;
var begun: i64 = 0;
var committed: i64 = 0;
var columns: usize = 80;
var rows: usize = 24;
var input: [INPUT_CAP]u8 = undefined;
var file: [FILE_CAP]u8 = undefined;
var text: [TEXT_CAP]u8 = undefined;
var centered_bits: [TEXT_CAP / 8]u8 = [_]u8{0} ** (TEXT_CAP / 8);
var bold_bits: [TEXT_CAP / 8]u8 = [_]u8{0} ** (TEXT_CAP / 8);
var quote_bits: [TEXT_CAP / 8]u8 = [_]u8{0} ** (TEXT_CAP / 8);
var text_len: usize = 0;
var centered: bool = false;
var bold: bool = false;
var quoted: bool = false;
var output: [OUTPUT_CAP]u8 = undefined;
var output_len: usize = 0;
var starts: [MAX_LINES]u32 = undefined;
var line_count: usize = 0;
var top_line: usize = 0;
var wrapped_width: usize = 0;
var chapter_starts: [MAX_CHAPTERS]u32 = undefined;
var chapter_count: usize = 0;
var title: [160]u8 = undefined;
var title_len: usize = 0;
var message: []const u8 = "";
const StyleRule = struct { selector: [96]u8, len: u8, centered: ?bool, bold: ?bool, large: bool, specificity: u8 };
var style_rules: [MAX_STYLE_RULES]StyleRule = undefined;
var style_rule_count: usize = 0;

const Tag = struct { name: []const u8, attrs: []const u8, closing: bool, self_closing: bool };

fn localName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |at| return name[at + 1 ..];
    return name;
}

fn nextTag(xml: []const u8, position: *usize) ?Tag {
    while (std.mem.indexOfScalarPos(u8, xml, position.*, '<')) |open| {
        var end = open + 1;
        var quote: u8 = 0;
        while (end < xml.len) : (end += 1) {
            const byte = xml[end];
            if (quote != 0) {
                if (byte == quote) quote = 0;
            } else if (byte == '"' or byte == '\'') {
                quote = byte;
            } else if (byte == '>') break;
        }
        if (end == xml.len) {
            position.* = xml.len;
            return null;
        }
        position.* = end + 1;
        var body = std.mem.trim(u8, xml[open + 1 .. end], " \r\n\t");
        if (body.len == 0 or body[0] == '!' or body[0] == '?') continue;
        const closing = body[0] == '/';
        if (closing) body = body[1..];
        var name_end: usize = 0;
        while (name_end < body.len and body[name_end] != ' ' and body[name_end] != '\r' and body[name_end] != '\n' and body[name_end] != '\t' and body[name_end] != '/') : (name_end += 1) {}
        if (name_end == 0) continue;
        return .{ .name = localName(body[0..name_end]), .attrs = body[name_end..], .closing = closing, .self_closing = body[body.len - 1] == '/' };
    }
    position.* = xml.len;
    return null;
}

fn attribute(attrs: []const u8, wanted: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < attrs.len) {
        while (pos < attrs.len and (std.ascii.isWhitespace(attrs[pos]) or attrs[pos] == '/')) : (pos += 1) {}
        const start = pos;
        while (pos < attrs.len and !std.ascii.isWhitespace(attrs[pos]) and attrs[pos] != '=' and attrs[pos] != '/') : (pos += 1) {}
        if (pos == start) break;
        const name = localName(attrs[start..pos]);
        while (pos < attrs.len and std.ascii.isWhitespace(attrs[pos])) : (pos += 1) {}
        if (pos >= attrs.len or attrs[pos] != '=') continue;
        pos += 1;
        while (pos < attrs.len and std.ascii.isWhitespace(attrs[pos])) : (pos += 1) {}
        if (pos >= attrs.len or (attrs[pos] != '"' and attrs[pos] != '\'')) break;
        const quote = attrs[pos];
        pos += 1;
        const value_start = pos;
        while (pos < attrs.len and attrs[pos] != quote) : (pos += 1) {}
        if (pos == attrs.len) break;
        const value = attrs[value_start..pos];
        pos += 1;
        if (std.mem.eql(u8, name, wanted)) return value;
    }
    return null;
}

fn entryFor(archive: []const u8, path: []const u8) !?zip.Entry {
    var reader = try zip.Reader.init(archive);
    var found: ?zip.Entry = null;
    while (try reader.next()) |entry| {
        if (entry.kind == .regular and std.mem.eql(u8, entry.path, path)) found = entry;
    }
    try reader.finish();
    return found;
}

fn extract(archive: []const u8, path: []const u8) ![]const u8 {
    const entry = (try entryFor(archive, path)) orelse return error.MissingFile;
    if (entry.uncompressed_size > FILE_CAP) return error.FileTooLarge;
    const body = file[0..entry.uncompressed_size];
    try zip.extractBody(archive, entry, body);
    return body;
}

fn decodePath(href: []const u8, out: []u8) ![]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < href.len and href[i] != '#' and href[i] != '?') : (i += 1) {
        var byte = href[i];
        if (byte == '&') {
            const end = std.mem.indexOfScalarPos(u8, href, i + 1, ';') orelse return error.BadPath;
            if (end - i > 16) return error.BadPath;
            const scalar = entity(href[i + 1 .. end]) orelse return error.BadPath;
            const count = std.unicode.utf8Encode(scalar, out[len..]) catch return error.BadPath;
            len += count;
            i = end;
            continue;
        }
        if (byte == '%') {
            if (i + 2 >= href.len) return error.BadPath;
            const hi = std.fmt.charToDigit(href[i + 1], 16) catch return error.BadPath;
            const lo = std.fmt.charToDigit(href[i + 2], 16) catch return error.BadPath;
            byte = hi * 16 + lo;
            i += 2;
        }
        if (byte == 0 or byte == '\\' or len == out.len) return error.BadPath;
        out[len] = byte;
        len += 1;
    }
    return out[0..len];
}

fn resolve(base: []const u8, href: []const u8, out: []u8) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, base, '/');
    const prefix = if (slash) |at| base[0 .. at + 1] else "";
    if (prefix.len >= out.len) return error.BadPath;
    @memcpy(out[0..prefix.len], prefix);
    const decoded = try decodePath(href, out[prefix.len..]);
    const joined = out[0 .. prefix.len + decoded.len];
    var normalized: [1024]u8 = undefined;
    var len: usize = 0;
    var parts = std.mem.splitScalar(u8, joined, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (len == 0) return error.BadPath;
            len -= 1;
            while (len > 0 and normalized[len - 1] != '/') : (len -= 1) {}
            continue;
        }
        if (len + part.len + 1 > normalized.len or len + part.len + 1 > out.len) return error.BadPath;
        if (len != 0) {
            normalized[len] = '/';
            len += 1;
        }
        @memcpy(normalized[len..][0..part.len], part);
        len += part.len;
    }
    if (len == 0) return error.BadPath;
    @memcpy(out[0..len], normalized[0..len]);
    return out[0..len];
}

fn append(bytes: []const u8) void {
    if (bytes.len > TEXT_CAP - text_len) return;
    @memcpy(text[text_len..][0..bytes.len], bytes);
    if (centered) {
        for (text_len..text_len + bytes.len) |index| centered_bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
    if (bold) {
        for (text_len..text_len + bytes.len) |index| bold_bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
    if (quoted) {
        for (text_len..text_len + bytes.len) |index| quote_bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
    text_len += bytes.len;
}

fn newline() void {
    if (text_len == 0 or text[text_len - 1] == '\n') return;
    append("\n");
}

fn blankLine() void {
    if (text_len == 0) return;
    if (text[text_len - 1] != '\n') append("\n");
    if (text_len < 2 or text[text_len - 2] != '\n') append("\n");
}

fn isCenteredAt(index: usize) bool {
    return index < text_len and (centered_bits[index / 8] & (@as(u8, 1) << @intCast(index % 8))) != 0;
}

fn isBoldAt(index: usize) bool {
    return index < text_len and (bold_bits[index / 8] & (@as(u8, 1) << @intCast(index % 8))) != 0;
}

fn isQuotedAt(index: usize) bool {
    return index < text_len and (quote_bits[index / 8] & (@as(u8, 1) << @intCast(index % 8))) != 0;
}

fn entity(bytes: []const u8) ?u21 {
    if (std.mem.eql(u8, bytes, "amp")) return '&';
    if (std.mem.eql(u8, bytes, "lt")) return '<';
    if (std.mem.eql(u8, bytes, "gt")) return '>';
    if (std.mem.eql(u8, bytes, "quot")) return '"';
    if (std.mem.eql(u8, bytes, "apos")) return '\'';
    if (std.mem.eql(u8, bytes, "nbsp")) return ' ';
    if (std.mem.eql(u8, bytes, "mdash")) return 0x2014;
    if (std.mem.eql(u8, bytes, "ndash")) return 0x2013;
    if (std.mem.eql(u8, bytes, "hellip")) return 0x2026;
    if (bytes.len > 1 and bytes[0] == '#') {
        const hex = bytes.len > 2 and (bytes[1] == 'x' or bytes[1] == 'X');
        const digits = bytes[if (hex) 2 else 1..];
        const scalar = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
        if (scalar == 0 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) return null;
        return scalar;
    }
    return null;
}

fn appendPlain(source: []const u8) void {
    var i: usize = 0;
    while (i < source.len and text_len + 4 < TEXT_CAP) {
        const byte = source[i];
        if (byte == '&') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, ';')) |end| {
                if (end - i <= 16) {
                    if (entity(source[i + 1 .. end])) |scalar| {
                        var encoded: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(scalar, &encoded) catch 0;
                        append(encoded[0..n]);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        if (std.ascii.isWhitespace(byte) or byte == 0xc2 and i + 1 < source.len and source[i + 1] == 0xa0) {
            if (text_len > 0 and text[text_len - 1] != ' ' and text[text_len - 1] != '\n') append(" ");
            i += if (byte == 0xc2) 2 else 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            i += 1;
            continue;
        }
        const width = std.unicode.utf8ByteSequenceLength(byte) catch {
            i += 1;
            continue;
        };
        if (i + width > source.len or !std.unicode.utf8ValidateSlice(source[i..][0..width])) {
            i += 1;
            continue;
        }
        const scalar = std.unicode.utf8Decode(source[i..][0..width]) catch {
            i += 1;
            continue;
        };
        if (scalar >= 0x80 and scalar <= 0x9f) {
            i += width;
            continue;
        }
        append(source[i..][0..width]);
        i += width;
    }
}

fn isParagraph(name: []const u8) bool {
    for ([_][]const u8{ "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote" }) |block| {
        if (std.mem.eql(u8, name, block)) return true;
    }
    return false;
}

fn isBoldElement(name: []const u8) bool {
    if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) return true;
    return name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6';
}

fn isBlock(name: []const u8) bool {
    for ([_][]const u8{ "div", "section", "article", "li", "tr" }) |block| {
        if (std.mem.eql(u8, name, block)) return true;
    }
    return false;
}

fn alignmentValue(value: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "center")) return true;
    for ([_][]const u8{ "left", "right", "start", "end", "justify" }) |other| {
        if (std.ascii.eqlIgnoreCase(trimmed, other)) return false;
    }
    return null;
}

fn declarationAlignment(style: []const u8) ?bool {
    var result: ?bool = null;
    var declarations = std.mem.splitScalar(u8, style, ';');
    while (declarations.next()) |declaration| {
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(property, "text-align")) continue;
        const raw = declaration[colon + 1 ..];
        const bang = std.mem.indexOfScalar(u8, raw, '!') orelse raw.len;
        if (alignmentValue(raw[0..bang])) |value| result = value;
    }
    return result;
}

fn declarationBold(style: []const u8) ?bool {
    var result: ?bool = null;
    var declarations = std.mem.splitScalar(u8, style, ';');
    while (declarations.next()) |declaration| {
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(property, "font-weight")) continue;
        const raw = declaration[colon + 1 ..];
        const bang = std.mem.indexOfScalar(u8, raw, '!') orelse raw.len;
        const value = std.mem.trim(u8, raw[0..bang], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "bold") or std.ascii.eqlIgnoreCase(value, "bolder")) {
            result = true;
        } else if (std.ascii.eqlIgnoreCase(value, "normal") or std.ascii.eqlIgnoreCase(value, "lighter")) {
            result = false;
        } else if (std.fmt.parseInt(u16, value, 10)) |weight| {
            result = weight >= 600;
        } else |_| {}
    }
    return result;
}

fn declarationLarge(style: []const u8) bool {
    var declarations = std.mem.splitScalar(u8, style, ';');
    while (declarations.next()) |declaration| {
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(property, "font-size")) continue;
        const raw = std.mem.trim(u8, declaration[colon + 1 ..], " \t\r\n");
        if (!std.mem.endsWith(u8, raw, "em")) continue;
        const size = std.fmt.parseFloat(f32, raw[0 .. raw.len - 2]) catch continue;
        if (size > 1.05) return true;
    }
    return false;
}

fn addStyleRule(selector: []const u8, center: ?bool, weight: ?bool, large: bool) void {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 96 or style_rule_count == MAX_STYLE_RULES) return;
    const specificity: u8 = if (std.mem.indexOfScalar(u8, trimmed, '#') != null) 3 else if (std.mem.indexOfScalar(u8, trimmed, '.') != null) 2 else 1;
    var rule = &style_rules[style_rule_count];
    @memcpy(rule.selector[0..trimmed.len], trimmed);
    rule.len = @intCast(trimmed.len);
    rule.centered = center;
    rule.bold = weight;
    rule.large = large;
    rule.specificity = specificity;
    style_rule_count += 1;
}

fn parseStyleCss(css: []const u8) void {
    var pos: usize = 0;
    while (pos < css.len) {
        while (pos < css.len and std.ascii.isWhitespace(css[pos])) : (pos += 1) {}
        if (pos + 2 <= css.len and std.mem.eql(u8, css[pos..][0..2], "/*")) {
            const end = std.mem.indexOfPos(u8, css, pos + 2, "*/") orelse break;
            pos = end + 2;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, css, pos, '{') orelse break;
        if (std.mem.indexOfScalarPos(u8, css, pos, ';')) |semicolon| {
            if (semicolon < open) {
                pos = semicolon + 1;
                continue;
            }
        }
        const close = std.mem.indexOfScalarPos(u8, css, open + 1, '}') orelse break;
        const selector = std.mem.trim(u8, css[pos..open], " \t\r\n");
        const declarations = css[open + 1 .. close];
        const center = declarationAlignment(declarations);
        const weight = declarationBold(declarations);
        const large = declarationLarge(declarations);
        if (center != null or weight != null or large) {
            var selectors = std.mem.splitScalar(u8, selector, ',');
            while (selectors.next()) |part| addStyleRule(part, center, weight, large);
        }
        pos = close + 1;
    }
}

fn classContains(classes: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, classes, " \t\r\n");
    while (tokens.next()) |token| if (std.mem.eql(u8, token, wanted)) return true;
    return false;
}

fn ruleMatches(selector: []const u8, tag: Tag) bool {
    if (std.mem.indexOfAny(u8, selector, " >+~:[") != null) return false;
    if (selector[0] == '#') return std.mem.eql(u8, attribute(tag.attrs, "id") orelse "", selector[1..]);
    if (selector[0] == '.') return classContains(attribute(tag.attrs, "class") orelse "", selector[1..]);
    if (std.mem.indexOfScalar(u8, selector, '.')) |dot| {
        return std.mem.eql(u8, tag.name, selector[0..dot]) and classContains(attribute(tag.attrs, "class") orelse "", selector[dot + 1 ..]);
    }
    return std.mem.eql(u8, tag.name, selector);
}

fn alignmentOverride(tag: Tag) ?bool {
    var result: ?bool = null;
    var best: u8 = 0;
    for (style_rules[0..style_rule_count]) |rule| {
        if (rule.centered == null or rule.specificity < best or !ruleMatches(rule.selector[0..rule.len], tag)) continue;
        result = rule.centered;
        best = rule.specificity;
    }
    if (attribute(tag.attrs, "align")) |value| {
        if (alignmentValue(value)) |parsed| result = parsed;
    }
    if (attribute(tag.attrs, "style")) |style| {
        if (declarationAlignment(style)) |parsed| result = parsed;
    }
    if (std.mem.eql(u8, tag.name, "center")) result = true;
    return result;
}

fn boldOverride(tag: Tag) ?bool {
    var result: ?bool = null;
    var best: u8 = 0;
    for (style_rules[0..style_rule_count]) |rule| {
        if (rule.bold == null or rule.specificity < best or !ruleMatches(rule.selector[0..rule.len], tag)) continue;
        result = rule.bold;
        best = rule.specificity;
    }
    if (attribute(tag.attrs, "style")) |style| {
        if (declarationBold(style)) |parsed| result = parsed;
    }
    return result;
}

fn isLargeText(tag: Tag) bool {
    if (!isParagraph(tag.name)) return false;
    var large = false;
    var best: u8 = 0;
    for (style_rules[0..style_rule_count]) |rule| {
        if (!rule.large or rule.specificity < best or !ruleMatches(rule.selector[0..rule.len], tag)) continue;
        large = true;
        best = rule.specificity;
    }
    if (attribute(tag.attrs, "style")) |style| {
        if (declarationLarge(style)) large = true;
    }
    return large;
}

fn appendXhtml(html: []const u8) void {
    const Style = struct { name: []const u8, previous_centered: bool, previous_bold: bool, previous_quoted: bool };
    var stack: [64]Style = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    var ignored: ?[]const u8 = null;
    var in_body = false;
    var saw_body = false;
    centered = false;
    bold = false;
    quoted = false;
    while (pos < html.len) {
        const open = std.mem.indexOfScalarPos(u8, html, pos, '<') orelse html.len;
        if (in_body and ignored == null) appendPlain(html[pos..open]);
        pos = open;
        if (open == html.len) break;
        const tag = nextTag(html, &pos) orelse break;
        if (!tag.closing and std.mem.eql(u8, tag.name, "style")) {
            const close = std.mem.indexOfPos(u8, html, pos, "</style>") orelse break;
            parseStyleCss(html[pos..close]);
            pos = close + "</style>".len;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "body")) {
            if (!tag.closing) {
                in_body = true;
                saw_body = true;
                centered = alignmentOverride(tag) orelse false;
                bold = boldOverride(tag) orelse false;
            } else {
                in_body = false;
                centered = false;
                bold = false;
                quoted = false;
            }
            continue;
        }
        if (!in_body) continue;
        if (ignored) |name| {
            if (tag.closing and std.mem.eql(u8, tag.name, name)) ignored = null;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "script") or std.mem.eql(u8, tag.name, "style") or std.mem.eql(u8, tag.name, "svg")) {
            ignored = tag.name;
            continue;
        }
        if (tag.closing) {
            if (isParagraph(tag.name) or isBlock(tag.name)) newline();
            var index = depth;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, stack[index].name, tag.name)) {
                    centered = stack[index].previous_centered;
                    bold = stack[index].previous_bold;
                    quoted = stack[index].previous_quoted;
                    depth = index;
                    break;
                }
            }
            continue;
        }
        if (isParagraph(tag.name)) blankLine() else if (isBlock(tag.name) or std.mem.eql(u8, tag.name, "br")) newline();
        if (!tag.self_closing and !std.mem.eql(u8, tag.name, "br") and depth < stack.len) {
            stack[depth] = .{ .name = tag.name, .previous_centered = centered, .previous_bold = bold, .previous_quoted = quoted };
            depth += 1;
            centered = alignmentOverride(tag) orelse centered;
            bold = (boldOverride(tag) orelse (bold or isBoldElement(tag.name))) or isLargeText(tag);
            quoted = quoted or std.mem.eql(u8, tag.name, "blockquote");
        }
    }
    if (!saw_body) appendPlain("");
    newline();
}

fn packagePath(container: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (nextTag(container, &pos)) |tag| {
        if (!tag.closing and std.mem.eql(u8, tag.name, "rootfile")) return attribute(tag.attrs, "full-path");
    }
    return null;
}

fn manifestHref(opf: []const u8, id: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (nextTag(opf, &pos)) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, "item")) continue;
        if (attribute(tag.attrs, "id")) |candidate| {
            if (std.mem.eql(u8, candidate, id)) {
                const media = attribute(tag.attrs, "media-type") orelse return null;
                if (!std.mem.eql(u8, media, "application/xhtml+xml")) return null;
                return attribute(tag.attrs, "href");
            }
        }
    }
    return null;
}

fn bookTitle(opf: []const u8) void {
    var pos: usize = 0;
    while (nextTag(opf, &pos)) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, "title")) continue;
        const end = std.mem.indexOfScalarPos(u8, opf, pos, '<') orelse break;
        const value = std.mem.trim(u8, opf[pos..end], " \r\n\t");
        var i: usize = 0;
        while (i < value.len and title_len + 4 <= title.len) {
            var scalar: u21 = undefined;
            if (value[i] == '&') {
                if (std.mem.indexOfScalarPos(u8, value, i + 1, ';')) |entity_end| {
                    if (entity_end - i <= 16) {
                        if (entity(value[i + 1 .. entity_end])) |decoded| {
                            scalar = decoded;
                            i = entity_end + 1;
                        } else {
                            scalar = '&';
                            i += 1;
                        }
                    } else {
                        scalar = '&';
                        i += 1;
                    }
                } else {
                    scalar = '&';
                    i += 1;
                }
            } else {
                const count = std.unicode.utf8ByteSequenceLength(value[i]) catch {
                    i += 1;
                    continue;
                };
                if (i + count > value.len) break;
                scalar = std.unicode.utf8Decode(value[i..][0..count]) catch {
                    i += 1;
                    continue;
                };
                i += count;
            }
            if (scalar < 0x20 or scalar == 0x7f or (scalar >= 0x80 and scalar <= 0x9f)) {
                if (scalar == '\n' or scalar == '\r' or scalar == '\t') scalar = ' ' else continue;
            }
            const count = std.unicode.utf8Encode(scalar, title[title_len..]) catch continue;
            title_len += count;
        }
        return;
    }
}

fn loadBook(archive: []const u8) !void {
    text_len = 0;
    @memset(&centered_bits, 0);
    @memset(&bold_bits, 0);
    @memset(&quote_bits, 0);
    chapter_count = 0;
    title_len = 0;
    const mime = try extract(archive, "mimetype");
    if (!std.mem.eql(u8, mime, "application/epub+zip")) return error.NotEpub;
    const container = try extract(archive, "META-INF/container.xml");
    const raw_opf_path = packagePath(container) orelse return error.NoPackage;
    var opf_path_buf: [1024]u8 = undefined;
    const opf_path = try resolve("", raw_opf_path, &opf_path_buf);
    const opf = try extract(archive, opf_path);
    // Keep the package document while the shared extraction buffer is reused.
    const opf_copy = std.heap.page_allocator.alloc(u8, opf.len) catch return error.PackageTooLarge;
    defer std.heap.page_allocator.free(opf_copy);
    @memcpy(opf_copy, opf);
    bookTitle(opf_copy);
    style_rule_count = 0;
    var css_pos: usize = 0;
    var css_path_buf: [1024]u8 = undefined;
    while (nextTag(opf_copy, &css_pos)) |tag| {
        if (tag.closing or !std.mem.eql(u8, tag.name, "item")) continue;
        if (!std.mem.eql(u8, attribute(tag.attrs, "media-type") orelse "", "text/css")) continue;
        const href = attribute(tag.attrs, "href") orelse continue;
        const path = resolve(opf_path, href, &css_path_buf) catch continue;
        const css = extract(archive, path) catch continue;
        parseStyleCss(css);
    }
    const external_rule_count = style_rule_count;
    var pos: usize = 0;
    var in_spine = false;
    var path_buf: [1024]u8 = undefined;
    while (nextTag(opf_copy, &pos)) |tag| {
        if (std.mem.eql(u8, tag.name, "spine")) {
            in_spine = !tag.closing;
            continue;
        }
        if (!in_spine or tag.closing or !std.mem.eql(u8, tag.name, "itemref")) continue;
        if (std.mem.eql(u8, attribute(tag.attrs, "linear") orelse "yes", "no")) continue;
        const id = attribute(tag.attrs, "idref") orelse continue;
        const href = manifestHref(opf_copy, id) orelse continue;
        const path = try resolve(opf_path, href, &path_buf);
        const chapter = try extract(archive, path);
        if (chapter_count == MAX_CHAPTERS or text_len + chapter.len + 2 > TEXT_CAP) return error.BookTooLarge;
        if (chapter_count > 0) {
            blankLine();
        }
        chapter_starts[chapter_count] = @intCast(text_len);
        chapter_count += 1;
        style_rule_count = external_rule_count;
        appendXhtml(chapter);
    }
    if (chapter_count == 0 or text_len == 0) return error.NoReadableChapters;
}

fn lineEnd(start: usize, width: usize) struct { end: usize, next: usize } {
    const available = if (isQuotedAt(start) and width > 2) width - 2 else width;
    var pos = start;
    var cells: usize = 0;
    var last_space: ?usize = null;
    while (pos < text_len) {
        if (text[pos] == '\n') return .{ .end = pos, .next = pos + 1 };
        if (text[pos] == ' ') last_space = pos;
        const n = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        if (cells >= available) break;
        pos += @min(n, text_len - pos);
        cells += 1;
    }
    if (pos == text_len) return .{ .end = pos, .next = pos };
    if (text[pos] == ' ') {
        var next = pos + 1;
        while (next < text_len and text[next] == ' ') : (next += 1) {}
        return .{ .end = pos, .next = next };
    }
    if (last_space) |space| {
        if (space > start and space < pos) {
            var next = space + 1;
            while (next < text_len and text[next] == ' ') : (next += 1) {}
            return .{ .end = space, .next = next };
        }
    }
    return .{ .end = pos, .next = pos };
}

fn reflow() void {
    const width = @max(1, @min(columns, 240) -| 1);
    if (width == wrapped_width) return;
    const anchor: usize = if (line_count > 0) starts[@min(top_line, line_count - 1)] else 0;
    wrapped_width = width;
    line_count = 0;
    top_line = 0;
    var pos: usize = 0;
    while (pos < text_len and line_count < MAX_LINES) {
        starts[line_count] = @intCast(pos);
        if (pos <= anchor) top_line = line_count;
        line_count += 1;
        const ending = lineEnd(pos, width);
        if (ending.next <= pos) break;
        pos = ending.next;
    }
}

fn write(bytes: []const u8) void {
    if (bytes.len > OUTPUT_CAP - output_len) return;
    @memcpy(output[output_len..][0..bytes.len], bytes);
    output_len += bytes.len;
}

fn writeNumber(value: usize) void {
    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    write(digits);
}

fn writeStyled(start: usize, end: usize) void {
    var segment = start;
    var pos = start;
    var active = false;
    while (pos < end) {
        const wanted = isBoldAt(pos);
        if (wanted != active) {
            write(text[segment..pos]);
            write(if (wanted) "\x1b[1m" else "\x1b[22m");
            active = wanted;
            segment = pos;
        }
        const count = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        pos += @min(count, end - pos);
    }
    write(text[segment..end]);
    if (active) write("\x1b[22m");
}

fn currentChapter() usize {
    if (chapter_count == 0 or line_count == 0) return 0;
    const offset = starts[@min(top_line, line_count - 1)];
    var index: usize = 0;
    while (index + 1 < chapter_count and chapter_starts[index + 1] <= offset) : (index += 1) {}
    return index;
}

fn draw() void {
    output_len = 0;
    const width = @min(columns, 240);
    const height = @min(rows, 100);
    if (height == 0 or width == 0) return;
    if (width < 6) write("EPUB"[0..@min(width, 4)]) else write("EPUB  ");
    if (width >= 6 and title_len > 0) {
        var pos: usize = 0;
        var cells: usize = 6;
        while (pos < title_len and cells < width) {
            const count = std.unicode.utf8ByteSequenceLength(title[pos]) catch break;
            if (pos + count > title_len) break;
            write(title[pos..][0..count]);
            pos += count;
            cells += 1;
        }
    } else if (width >= 12) write("Reader");
    if (height == 1) return;
    write("\n");
    if (message.len > 0) {
        write(message[0..@min(message.len, width)]);
        return;
    }
    reflow();
    const body_rows = height -| 2;
    for (0..body_rows) |row| {
        const line = top_line + row;
        if (line < line_count) {
            const start = starts[line];
            const ending = lineEnd(start, wrapped_width);
            if (width > 1) {
                var padding: usize = 1;
                const quote_indent: usize = if (isQuotedAt(start) and width > 3) 2 else 0;
                if (isCenteredAt(start) and ending.end > start) {
                    const cells = std.unicode.utf8CountCodepoints(text[start..ending.end]) catch 0;
                    padding += (wrapped_width -| quote_indent -| cells) / 2;
                }
                for (0..padding) |_| write(" ");
                if (quote_indent != 0) write("│ ");
            }
            writeStyled(start, ending.end);
        }
        write("\n");
    }
    if (width >= 74) write("Up/Down scroll  PgUp/PgDn page  Left/Right chapter  Home/End  ") else if (width >= 48) write("Up/Down scroll  Left/Right chapter  ") else if (width >= 28) write("↑↓ scroll  ←→ chapter  ") else if (width >= 10) write("↑↓  ←→  ");
    if (width < 3) return;
    writeNumber(currentChapter() + 1);
    write("/");
    writeNumber(chapter_count);
}

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input));
}
export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr("application/epub+zip".ptr));
}
export fn input_content_type_size() u32 {
    return "application/epub+zip".len;
}
export fn uniform_set_columns(value: u32) void {
    columns = @max(1, @min(value, 240));
}
export fn uniform_set_lines(value: u32) void {
    rows = @max(1, @min(value, 100));
}

export fn begin_update_at(now: i64) void {
    if (phase != .ready or now <= committed) @trap();
    begun = now;
    phase = .updating;
}

export fn key_event(key: i32, flags: i32) i32 {
    if (phase != .updating) @trap();
    if ((flags & FLAG_DOWN) == 0 or message.len > 0) return 0;
    const old = top_line;
    const page = @max(1, @min(rows, 100) -| 2);
    switch (key) {
        XK_UP, 'k' => top_line -|= 1,
        XK_DOWN, 'j' => top_line = @min(top_line + 1, line_count -| 1),
        XK_PAGE_UP, 'b' => top_line -|= page,
        XK_PAGE_DOWN, ' ' => top_line = @min(top_line + page, line_count -| 1),
        XK_HOME, 'g' => top_line = 0,
        XK_END, 'G' => top_line = line_count -| page,
        XK_LEFT, 'p' => {
            const current = currentChapter();
            const target = if (current > 0) current - 1 else 0;
            top_line = lineForOffset(chapter_starts[target]);
        },
        XK_RIGHT, 'n' => {
            const current = currentChapter();
            if (current + 1 < chapter_count) top_line = lineForOffset(chapter_starts[current + 1]);
        },
        else => {},
    }
    return if (top_line != old) 1 else 0;
}

fn lineForOffset(offset: u32) usize {
    var low: usize = 0;
    var high = line_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (starts[middle] < offset) low = middle + 1 else high = middle;
    }
    return @min(low, line_count -| 1);
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    committed = begun;
    phase = .ready;
    return committed;
}

export fn render(size: u32) packed struct(u64) { output_size: u32, output_ptr: u31, failed: u1 } {
    if (phase == .updating or size > INPUT_CAP) @trap();
    if (phase == .initial) {
        message = "";
        loadBook(input[0..size]) catch |err| {
            message = switch (err) {
                error.NotEpub => "This file is not an EPUB (invalid mimetype).",
                error.MissingFile => "EPUB is missing a required file.",
                error.NoPackage => "EPUB has no package document.",
                error.NoReadableChapters => "EPUB has no readable XHTML chapters.",
                error.FileTooLarge => "An EPUB chapter or package exceeds 2 MiB.",
                error.BookTooLarge => "Book text exceeds 8 MiB or 512 chapters.",
                error.BadPath => "EPUB has an invalid chapter path.",
                else => "Could not read this EPUB.",
            };
        };
        phase = .ready;
    } else if (size != 0) @trap();
    draw();
    return .{ .output_size = @intCast(output_len), .output_ptr = @intCast(@intFromPtr(&output)), .failed = 0 };
}

test "extracts text and reflows for terminal width" {
    text_len = 0;
    @memset(&centered_bits, 0);
    @memset(&bold_bits, 0);
    @memset(&quote_bits, 0);
    wrapped_width = 0;
    top_line = 0;
    chapter_count = 1;
    chapter_starts[0] = 0;
    appendXhtml("<html><head><title>skip</title></head><body><h1>Hello &amp; world</h1><p>First paragraph with words.</p><script>skip</script><p>Last line.</p></body></html>");
    try std.testing.expect(std.mem.indexOf(u8, text[0..text_len], "Hello & world") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[0..text_len], "skip") == null);
    columns = 20;
    rows = 6;
    message = "";
    title_len = 0;
    draw();
    const narrow = line_count;
    columns = 60;
    draw();
    try std.testing.expect(line_count < narrow);
    try std.testing.expect(std.mem.indexOf(u8, output[0..output_len], "Hello & world") != null);
}
