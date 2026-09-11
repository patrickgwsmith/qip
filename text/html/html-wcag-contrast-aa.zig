const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

const MAX_RULES: usize = 512;
const MAX_STACK: usize = 128;
const MAX_NAME: usize = 64;
const MAX_SELECTOR_PARTS: usize = 8;
const MAX_SELECTOR_CLASSES: usize = 8;
const MAX_SELECTOR_ATTRS: usize = 8;
const MAX_ELEMENT_ATTRS: usize = 32;
const MAX_ATTR_VALUE: usize = 128;
const MAX_SELECTOR_SOURCE: usize = 2048;
const MAX_CSS_NESTING: usize = 8;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var rules_buf: [MAX_RULES]Rule = undefined;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const Style = struct {
    color: ?Color = null,
    background: ?Color = null,
    color_important: bool = false,
    background_important: bool = false,
    font_size_px: ?f64 = null,
    font_size_important: bool = false,
    bold: ?bool = null,
    bold_important: bool = false,
    unsupported: bool = false,
};

const AttrOperator = enum(u8) {
    present,
    equal,
    includes,
    dash,
    prefix,
    suffix,
    substring,
};

const SelectorAttr = struct {
    name: [MAX_NAME]u8 = undefined,
    name_len: u8 = 0,
    value: [MAX_ATTR_VALUE]u8 = undefined,
    value_len: u8 = 0,
    operator: AttrOperator = .present,
    case_insensitive: bool = false,
    force_sensitive: bool = false,
};

const CompoundSelector = struct {
    tag: [MAX_NAME]u8 = undefined,
    tag_len: u8 = 0,
    id: [MAX_NAME]u8 = undefined,
    id_len: u8 = 0,
    classes: [MAX_SELECTOR_CLASSES][MAX_NAME]u8 = undefined,
    class_lens: [MAX_SELECTOR_CLASSES]u8 = [_]u8{0} ** MAX_SELECTOR_CLASSES,
    class_count: u8 = 0,
    attrs: [MAX_SELECTOR_ATTRS]SelectorAttr = undefined,
    attr_count: u8 = 0,
    root: bool = false,
};

const Selector = struct {
    parts: [MAX_SELECTOR_PARTS]CompoundSelector = undefined,
    part_count: u8 = 0,
};

const Rule = struct {
    selector: Selector,
    style: Style,
    specificity: u16,
};

const Element = struct {
    tag: [MAX_NAME]u8 = undefined,
    tag_len: u8 = 0,
    id: [MAX_NAME]u8 = undefined,
    id_len: u8 = 0,
    class_attr: []const u8 = "",
    attrs: [MAX_ELEMENT_ATTRS]Attr = undefined,
    attr_count: u8 = 0,
    color: Color = Color{ .r = 0, .g = 0, .b = 0 },
    background: Color = Color{ .r = 255, .g = 255, .b = 255 },
    font_size_px: f64 = 16.0,
    bold: bool = false,
    suppress_text: bool = false,
    is_root: bool = false,
};

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

const Attrs = struct {
    id: []const u8 = "",
    class: []const u8 = "",
    style: []const u8 = "",
    items: [MAX_ELEMENT_ATTRS]Attr = undefined,
    count: u8 = 0,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
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
    var i: usize = 0;
    var steps: usize = 0;
    while (i < a.len and steps < INPUT_CAP * 2) : ({
        i += 1;
        steps += 1 + (i & 1);
    }) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return i == a.len;
}

fn startsWithIgnoreCase(a: []const u8, b: []const u8) bool {
    return a.len >= b.len and eqlIgnoreCase(a[0..b.len], b);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == ':';
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    var left_steps: usize = 0;
    while (start < end and isSpace(s[start])) {
        if (left_steps >= INPUT_CAP * 2) @trap();
        left_steps += 1 + (s[start] & 1);
        start += 1;
    }
    var right_steps: usize = 0;
    while (end > start and isSpace(s[end - 1])) {
        if (right_steps >= INPUT_CAP * 2) @trap();
        right_steps += 1 + (s[end - 1] & 1);
        end -= 1;
    }
    return s[start..end];
}

fn indexOfByte(s: []const u8, byte: u8) ?usize {
    var i: usize = 0;
    var fuel: usize = INPUT_CAP * 2;
    while (i < s.len and fuel > 0) : ({
        i += 1;
        fuel -= 1;
    }) {
        if (s[i] == byte) return i;
    }
    return null;
}

fn indexOfCommentEnd(s: []const u8) ?usize {
    var i: usize = 0;
    var fuel: usize = INPUT_CAP * 2;
    while (i + 2 < s.len and fuel > 0) : ({
        i += 1;
        fuel -= 1;
    }) {
        if (s[i] == '-' and s[i + 1] == '-' and s[i + 2] == '>') return i;
    }
    return null;
}

fn hasVisibleText(s: []const u8) bool {
    var i: usize = 0;
    var steps: usize = 0;
    while (i < s.len and steps < INPUT_CAP * 2) : ({
        i += 1;
        steps += 1 + (i & 1);
    }) {
        if (!isSpace(s[i])) return true;
    }
    return false;
}

fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHexColor(s_in: []const u8) ?Color {
    const s = trim(s_in);
    if (s.len == 4 and s[0] == '#') {
        const r = hexValue(s[1]) orelse return null;
        const g = hexValue(s[2]) orelse return null;
        const b = hexValue(s[3]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if (s.len == 7 and s[0] == '#') {
        const r1 = hexValue(s[1]) orelse return null;
        const r2 = hexValue(s[2]) orelse return null;
        const g1 = hexValue(s[3]) orelse return null;
        const g2 = hexValue(s[4]) orelse return null;
        const b1 = hexValue(s[5]) orelse return null;
        const b2 = hexValue(s[6]) orelse return null;
        return .{ .r = r1 * 16 + r2, .g = g1 * 16 + g2, .b = b1 * 16 + b2 };
    }
    return null;
}

fn parseU8Token(s: []const u8, index: *usize) ?u8 {
    var leading_steps: usize = 0;
    while (index.* < s.len and isSpace(s[index.*]) and leading_steps < INPUT_CAP * 2) {
        index.* += 1;
        leading_steps += 1 + (index.* & 1);
    }
    var value: u32 = 0;
    const start = index.*;
    var digit_steps: usize = 0;
    while (index.* < s.len and s[index.*] >= '0' and s[index.*] <= '9' and digit_steps < INPUT_CAP * 2) : ({
        index.* += 1;
        digit_steps += 1 + (index.* & 1);
    }) {
        value = value * 10 + (s[index.*] - '0');
        if (value > 255) return null;
    }
    if (index.* == start) return null;
    var trailing_steps: usize = 0;
    while (index.* < s.len and isSpace(s[index.*]) and trailing_steps < INPUT_CAP * 2) {
        index.* += 1;
        trailing_steps += 1 + (index.* & 1);
    }
    if (index.* < s.len and s[index.*] == '%') return null;
    return @as(u8, @intCast(value));
}

fn parseRgbColor(s_in: []const u8) ?Color {
    const s = trim(s_in);
    if (!startsWithIgnoreCase(s, "rgb(") or s.len < 6 or s[s.len - 1] != ')') return null;
    const inner = s[4 .. s.len - 1];
    var i: usize = 0;
    const r = parseU8Token(inner, &i) orelse return null;
    if (i >= inner.len or inner[i] != ',') return null;
    i += 1;
    const g = parseU8Token(inner, &i) orelse return null;
    if (i >= inner.len or inner[i] != ',') return null;
    i += 1;
    const b = parseU8Token(inner, &i) orelse return null;
    var steps: usize = 0;
    while (i < inner.len and isSpace(inner[i]) and steps < INPUT_CAP * 2) {
        i += 1;
        steps += 1 + (i & 1);
    }
    if (i != inner.len) return null;
    return .{ .r = r, .g = g, .b = b };
}

fn namedColor(s: []const u8) ?Color {
    if (eqlIgnoreCase(s, "black")) return .{ .r = 0, .g = 0, .b = 0 };
    if (eqlIgnoreCase(s, "white")) return .{ .r = 255, .g = 255, .b = 255 };
    if (eqlIgnoreCase(s, "red")) return .{ .r = 255, .g = 0, .b = 0 };
    if (eqlIgnoreCase(s, "green")) return .{ .r = 0, .g = 128, .b = 0 };
    if (eqlIgnoreCase(s, "blue")) return .{ .r = 0, .g = 0, .b = 255 };
    if (eqlIgnoreCase(s, "gray") or eqlIgnoreCase(s, "grey")) return .{ .r = 128, .g = 128, .b = 128 };
    if (eqlIgnoreCase(s, "darkgray") or eqlIgnoreCase(s, "darkgrey")) return .{ .r = 169, .g = 169, .b = 169 };
    if (eqlIgnoreCase(s, "lightgray") or eqlIgnoreCase(s, "lightgrey")) return .{ .r = 211, .g = 211, .b = 211 };
    if (eqlIgnoreCase(s, "yellow")) return .{ .r = 255, .g = 255, .b = 0 };
    if (eqlIgnoreCase(s, "orange")) return .{ .r = 255, .g = 165, .b = 0 };
    if (eqlIgnoreCase(s, "purple")) return .{ .r = 128, .g = 0, .b = 128 };
    return null;
}

fn parseColorValue(value_in: []const u8) ?Color {
    var value = trim(value_in);
    if (indexOfByte(value, '!')) |bang| value = trim(value[0..bang]);
    if (eqlIgnoreCase(value, "transparent") or eqlIgnoreCase(value, "currentcolor")) return null;
    if (parseHexColor(value)) |c| return c;
    if (parseRgbColor(value)) |c| return c;
    return namedColor(value);
}

fn stripImportant(value_in: []const u8, important: *bool) []const u8 {
    const value = trim(value_in);
    var i = value.len;
    var end_steps: usize = 0;
    while (i > 0 and isSpace(value[i - 1]) and end_steps < INPUT_CAP * 2) {
        i -= 1;
        end_steps += 1 + (i & 1);
    }
    const word = "important";
    if (i < word.len) return value;
    const word_start = i - word.len;
    if (!eqlIgnoreCase(value[word_start..i], word)) return value;
    var bang = word_start;
    var bang_steps: usize = 0;
    while (bang > 0 and isSpace(value[bang - 1]) and bang_steps < INPUT_CAP * 2) {
        bang -= 1;
        bang_steps += 1 + (bang & 1);
    }
    if (bang == 0 or value[bang - 1] != '!') return value;
    important.* = true;
    return trim(value[0 .. bang - 1]);
}

fn parseFontSize(value_in: []const u8) ?f64 {
    const value = trim(value_in);
    var i: usize = 0;
    var seen_digit = false;
    var seen_dot = false;
    var scan_steps: usize = 0;
    while (i < value.len and scan_steps < 64) : ({
        i += 1;
        scan_steps += 1;
    }) {
        const c = value[i];
        if (c >= '0' and c <= '9') {
            seen_digit = true;
            continue;
        }
        if (c == '.' and !seen_dot) {
            seen_dot = true;
            continue;
        }
        break;
    }
    if (!seen_digit) return null;
    var number: f64 = 0;
    var fraction_scale: f64 = 0;
    var number_index: usize = 0;
    while (number_index < i and number_index < 64) : (number_index += 1) {
        const c = value[number_index];
        if (c == '.') {
            fraction_scale = 0.1;
        } else if (fraction_scale == 0) {
            number = number * 10 + @as(f64, @floatFromInt(c - '0'));
        } else {
            number += @as(f64, @floatFromInt(c - '0')) * fraction_scale;
            fraction_scale *= 0.1;
        }
    }
    if (number < 0) return null;
    const unit = value[i..];
    if (eqlIgnoreCase(unit, "px")) return number;
    if (eqlIgnoreCase(unit, "pt")) return number * (4.0 / 3.0);
    return null;
}

fn parseBold(value: []const u8) ?bool {
    if (eqlIgnoreCase(value, "bold") or eqlIgnoreCase(value, "bolder")) return true;
    if (eqlIgnoreCase(value, "normal") or eqlIgnoreCase(value, "lighter")) return false;
    if (value.len == 0 or value.len > 4) return null;
    var weight: u16 = 0;
    var index: usize = 0;
    while (index < value.len and index < 4) : (index += 1) {
        const c = value[index];
        if (c < '0' or c > '9') return null;
        weight = weight * 10 + (c - '0');
    }
    if (weight < 1 or weight > 1000) return null;
    return weight >= 700;
}

fn parseStyleDecls(css: []const u8) Style {
    var style = Style{};
    var start: usize = 0;
    var declaration_steps: usize = 0;
    while (declaration_steps < INPUT_CAP) : (declaration_steps += 1) {
        if (start >= css.len) break;
        const end = if (indexOfByte(css[start..], ';')) |offset| start + offset else css.len;
        const decl = trim(css[start..end]);
        if (indexOfByte(decl, ':')) |colon| {
            const prop = trim(decl[0..colon]);
            const raw_value = trim(decl[colon + 1 ..]);
            if (eqlIgnoreCase(prop, "color")) {
                const value = stripImportant(raw_value, &style.color_important);
                if (parseColorValue(value)) |c| style.color = c else style.unsupported = true;
            } else if (eqlIgnoreCase(prop, "background-color") or eqlIgnoreCase(prop, "background")) {
                const value = stripImportant(raw_value, &style.background_important);
                if (parseColorValue(value)) |c| style.background = c else style.unsupported = true;
            } else if (eqlIgnoreCase(prop, "font-size")) {
                const value = stripImportant(raw_value, &style.font_size_important);
                style.font_size_px = parseFontSize(value);
            } else if (eqlIgnoreCase(prop, "font-weight")) {
                const value = stripImportant(raw_value, &style.bold_important);
                style.bold = parseBold(value);
            }
        }
        start = if (end < css.len) end + 1 else css.len;
    }
    return style;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len and i < INPUT_CAP) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return i == a.len;
}

fn copyExact(comptime N: usize, dst: *[N]u8, len: *u8, src: []const u8) bool {
    if (src.len == 0 or src.len > N) return false;
    var i: usize = 0;
    while (i < src.len and i < N) : (i += 1) dst[i] = src[i];
    len.* = @intCast(src.len);
    return true;
}

fn copyLower(dst: *[MAX_NAME]u8, len: *u8, src: []const u8) bool {
    if (src.len == 0 or src.len > MAX_NAME) return false;
    var i: usize = 0;
    while (i < src.len and i < MAX_NAME) : (i += 1) dst[i] = asciiLower(src[i]);
    len.* = @intCast(src.len);
    return true;
}

fn isCssNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c >= 0x80;
}

fn readCssIdent(s: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    const first = s[start];
    if (!((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z') or first == '-' or first == '_' or first >= 0x80)) return null;
    var end = start + 1;
    while (end < s.len and isCssNameChar(s[end]) and end - start < MAX_ATTR_VALUE) : (end += 1) {}
    return end;
}

fn parseAttributeSelector(compound: *CompoundSelector, s: []const u8, index: *usize) bool {
    if (compound.attr_count >= MAX_SELECTOR_ATTRS or s[index.*] != '[') return false;
    var i = index.* + 1;
    while (i < s.len and isSpace(s[i])) i += 1;
    const name_start = i;
    const name_end = readCssIdent(s, i) orelse return false;
    i = name_end;
    var attr = SelectorAttr{};
    if (!copyLower(&attr.name, &attr.name_len, s[name_start..name_end])) return false;
    while (i < s.len and isSpace(s[i])) i += 1;
    if (i < s.len and s[i] == ']') {
        i += 1;
    } else {
        if (i >= s.len) return false;
        if (i + 1 < s.len and s[i + 1] == '=') {
            attr.operator = switch (s[i]) {
                '~' => .includes,
                '|' => .dash,
                '^' => .prefix,
                '$' => .suffix,
                '*' => .substring,
                else => return false,
            };
            i += 2;
        } else if (s[i] == '=') {
            attr.operator = .equal;
            i += 1;
        } else return false;
        while (i < s.len and isSpace(s[i])) i += 1;
        const value_start = i;
        var value_end = i;
        if (i < s.len and (s[i] == '"' or s[i] == '\'')) {
            const quote = s[i];
            i += 1;
            const quoted_start = i;
            while (i < s.len and s[i] != quote) : (i += 1) {
                if (s[i] == '\\') return false;
            }
            if (i >= s.len) return false;
            value_end = i;
            if (!copyExact(MAX_ATTR_VALUE, &attr.value, &attr.value_len, s[quoted_start..value_end])) return false;
            i += 1;
        } else {
            value_end = readCssIdent(s, value_start) orelse return false;
            if (!copyExact(MAX_ATTR_VALUE, &attr.value, &attr.value_len, s[value_start..value_end])) return false;
            i = value_end;
        }
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i < s.len and (s[i] == 'i' or s[i] == 'I' or s[i] == 's' or s[i] == 'S')) {
            attr.case_insensitive = s[i] == 'i' or s[i] == 'I';
            attr.force_sensitive = s[i] == 's' or s[i] == 'S';
            i += 1;
            while (i < s.len and isSpace(s[i])) i += 1;
        }
        if (i >= s.len or s[i] != ']') return false;
        i += 1;
    }
    compound.attrs[compound.attr_count] = attr;
    compound.attr_count += 1;
    index.* = i;
    return true;
}

fn parseCompoundSelector(s: []const u8) ?CompoundSelector {
    var compound = CompoundSelector{};
    var i: usize = 0;
    if (s.len == 0) return null;
    if (s[i] == '*') {
        i += 1;
    } else if (readCssIdent(s, i)) |end| {
        if (!copyLower(&compound.tag, &compound.tag_len, s[i..end])) return null;
        i = end;
    }
    while (i < s.len) {
        if (s[i] == '#') {
            if (compound.id_len != 0) return null;
            const end = readCssIdent(s, i + 1) orelse return null;
            if (!copyExact(MAX_NAME, &compound.id, &compound.id_len, s[i + 1 .. end])) return null;
            i = end;
        } else if (s[i] == '.') {
            if (compound.class_count >= MAX_SELECTOR_CLASSES) return null;
            const end = readCssIdent(s, i + 1) orelse return null;
            const class_index = compound.class_count;
            if (!copyExact(MAX_NAME, &compound.classes[class_index], &compound.class_lens[class_index], s[i + 1 .. end])) return null;
            compound.class_count += 1;
            i = end;
        } else if (s[i] == '[') {
            if (!parseAttributeSelector(&compound, s, &i)) return null;
        } else if (i + 5 == s.len and s[i] == ':' and eqlIgnoreCase(s[i..], ":root")) {
            compound.root = true;
            i = s.len;
        } else return null;
    }
    if (compound.tag_len == 0 and compound.id_len == 0 and compound.class_count == 0 and compound.attr_count == 0 and !compound.root and s[0] != '*') return null;
    return compound;
}

fn parseSelector(selector_in: []const u8) ?Selector {
    const s = trim(selector_in);
    if (s.len == 0) return null;
    var selector = Selector{};
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i >= s.len or selector.part_count >= MAX_SELECTOR_PARTS) return null;
        const start = i;
        var bracket_depth: u8 = 0;
        var quote: u8 = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') quote = c else if (c == '[') bracket_depth += 1 else if (c == ']') {
                if (bracket_depth == 0) return null;
                bracket_depth -= 1;
            } else if (bracket_depth == 0 and isSpace(c)) break;
        }
        if (bracket_depth != 0 or quote != 0) return null;
        selector.parts[selector.part_count] = parseCompoundSelector(s[start..i]) orelse return null;
        selector.part_count += 1;
    }
    return if (selector.part_count > 0) selector else null;
}

fn selectorSpecificity(selector: *const Selector) u16 {
    var result: u16 = 0;
    var i: usize = 0;
    while (i < selector.part_count and i < MAX_SELECTOR_PARTS) : (i += 1) {
        const part = &selector.parts[i];
        if (part.tag_len > 0) result += 1;
        if (part.id_len > 0) result += 100;
        result += @as(u16, part.class_count + part.attr_count + @intFromBool(part.root)) * 10;
    }
    return result;
}

fn addRule(rules: []Rule, count: *usize, selector: []const u8, style: Style) void {
    if (style.color == null and style.background == null and style.font_size_px == null and style.bold == null and !style.unsupported) return;
    if (count.* >= rules.len) @trap();
    const parsed = parseSelector(selector) orelse @trap();
    const specificity = selectorSpecificity(&parsed);
    rules[count.*] = .{ .selector = parsed, .style = style, .specificity = specificity };
    count.* += 1;
}

fn mergeStyle(target: *Style, incoming: Style) void {
    if (incoming.color) |value| {
        target.color = value;
        target.color_important = incoming.color_important;
    }
    if (incoming.background) |value| {
        target.background = value;
        target.background_important = incoming.background_important;
    }
    if (incoming.font_size_px) |value| {
        target.font_size_px = value;
        target.font_size_important = incoming.font_size_important;
    }
    if (incoming.bold) |value| {
        target.bold = value;
        target.bold_important = incoming.bold_important;
    }
    target.unsupported = target.unsupported or incoming.unsupported;
}

fn nextSelectorItem(list: []const u8, start_in: usize, end_out: *usize) ?[]const u8 {
    var start = start_in;
    while (start < list.len and (isSpace(list[start]) or list[start] == ',')) start += 1;
    if (start >= list.len) return null;
    var i = start;
    var bracket_depth: u8 = 0;
    var quote: u8 = 0;
    while (i < list.len) : (i += 1) {
        const c = list[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') quote = c else if (c == '[') bracket_depth += 1 else if (c == ']') {
            if (bracket_depth == 0) return null;
            bracket_depth -= 1;
        } else if (c == ',' and bracket_depth == 0) break;
    }
    if (quote != 0 or bracket_depth != 0) return null;
    end_out.* = if (i < list.len) i + 1 else i;
    return trim(list[start..i]);
}

fn addRulesForList(rules: []Rule, count: *usize, selectors: []const u8, style: Style, forced_specificity: ?u16) void {
    if (style.color == null and style.background == null and style.font_size_px == null and style.bold == null and !style.unsupported) return;
    var cursor: usize = 0;
    var steps: usize = 0;
    while (cursor < selectors.len and steps < MAX_RULES) : (steps += 1) {
        var next: usize = cursor;
        const item = nextSelectorItem(selectors, cursor, &next) orelse @trap();
        const before = count.*;
        addRule(rules, count, item, style);
        if (forced_specificity) |specificity| rules[before].specificity = specificity;
        cursor = next;
    }
}

fn selectorListMaxSpecificity(selectors: []const u8) u16 {
    var result: u16 = 0;
    var cursor: usize = 0;
    var steps: usize = 0;
    while (cursor < selectors.len and steps < MAX_RULES) : (steps += 1) {
        var next: usize = cursor;
        const item = nextSelectorItem(selectors, cursor, &next) orelse @trap();
        const parsed = parseSelector(item) orelse @trap();
        result = @max(result, selectorSpecificity(&parsed));
        cursor = next;
    }
    return result;
}

fn findMatchingBrace(css: []const u8, open: usize) ?usize {
    var depth: usize = 1;
    var quote: u8 = 0;
    var i = open + 1;
    var steps: usize = 0;
    while (i < css.len and steps < INPUT_CAP) : ({
        i += 1;
        steps += 1;
    }) {
        const c = css[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') quote = c else if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn appendSlice(buffer: []u8, length: *usize, value: []const u8) bool {
    if (length.* + value.len > buffer.len) return false;
    @memcpy(buffer[length.* .. length.* + value.len], value);
    length.* += value.len;
    return true;
}

fn expandNestedSelector(buffer: []u8, length: *usize, parent: []const u8, child: []const u8) bool {
    var ampersands: usize = 0;
    var i: usize = 0;
    var quote: u8 = 0;
    var bracket_depth: u8 = 0;
    while (i < child.len) : (i += 1) {
        const c = child[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') quote = c else if (c == '[') bracket_depth += 1 else if (c == ']') bracket_depth -= 1 else if (c == '&' and bracket_depth == 0) ampersands += 1;
    }
    if (ampersands > 1) return false;
    if (ampersands == 0) {
        if (!appendSlice(buffer, length, parent) or !appendSlice(buffer, length, " ") or !appendSlice(buffer, length, child)) return false;
        return true;
    }
    i = 0;
    while (i < child.len) : (i += 1) {
        if (child[i] == '&') {
            if (!appendSlice(buffer, length, parent)) return false;
        } else if (!appendSlice(buffer, length, child[i .. i + 1])) return false;
    }
    return true;
}

fn buildNestedSelectorList(parent_list: []const u8, child: []const u8, buffer: []u8) ?usize {
    var length: usize = 0;
    var cursor: usize = 0;
    var steps: usize = 0;
    while (cursor < parent_list.len and steps < MAX_RULES) : (steps += 1) {
        var next: usize = cursor;
        const parent = nextSelectorItem(parent_list, cursor, &next) orelse return null;
        if (length > 0 and !appendSlice(buffer, &length, ",")) return null;
        if (!expandNestedSelector(buffer, &length, parent, child)) return null;
        cursor = next;
    }
    return length;
}

fn processRuleBody(css: []const u8, selectors: []const u8, inherited_specificity: ?u16, rules: []Rule, count: *usize, comptime depth: usize) void {
    var pending = Style{};
    var segment_start: usize = 0;
    var i: usize = 0;
    var quote: u8 = 0;
    var bracket_depth: u8 = 0;
    var paren_depth: u8 = 0;
    var steps: usize = 0;
    while (i <= css.len and steps < INPUT_CAP) : ({
        i += 1;
        steps += 1;
    }) {
        if (i == css.len) {
            const tail = trim(css[segment_start..i]);
            if (tail.len > 0) mergeStyle(&pending, parseStyleDecls(tail));
            addRulesForList(rules, count, selectors, pending, inherited_specificity);
            return;
        }
        const c = css[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '[') bracket_depth += 1 else if (c == ']') bracket_depth -= 1 else if (c == '(') paren_depth += 1 else if (c == ')') paren_depth -= 1;
        if (bracket_depth != 0 or paren_depth != 0) continue;
        if (c == ';') {
            mergeStyle(&pending, parseStyleDecls(css[segment_start..i]));
            segment_start = i + 1;
            continue;
        }
        if (c != '{') continue;
        addRulesForList(rules, count, selectors, pending, inherited_specificity);
        pending = Style{};
        const child_list = trim(css[segment_start..i]);
        if (child_list.len == 0 or child_list[0] == '@') @trap();
        const close = findMatchingBrace(css, i) orelse @trap();
        var child_cursor: usize = 0;
        var child_steps: usize = 0;
        while (child_cursor < child_list.len and child_steps < MAX_RULES) : (child_steps += 1) {
            var child_next: usize = child_cursor;
            const child = nextSelectorItem(child_list, child_cursor, &child_next) orelse @trap();
            var expanded: [MAX_SELECTOR_SOURCE]u8 = undefined;
            const expanded_len = buildNestedSelectorList(selectors, child, expanded[0..]) orelse @trap();
            const actual_parent_max = selectorListMaxSpecificity(selectors);
            const parent_delta = if (inherited_specificity) |forced| forced -| actual_parent_max else 0;
            const nested_specificity = selectorListMaxSpecificity(expanded[0..expanded_len]) + parent_delta;
            if (comptime depth >= MAX_CSS_NESTING) @trap() else processRuleBody(css[i + 1 .. close], expanded[0..expanded_len], nested_specificity, rules, count, depth + 1);
            child_cursor = child_next;
        }
        i = close;
        segment_start = close + 1;
    }
    @trap();
}

noinline fn parseStylesheet(css: []const u8, rules: []Rule, count: *usize) void {
    var i: usize = 0;
    var steps: usize = 0;
    while (i < css.len and steps < INPUT_CAP) : (steps += 1) {
        while (i < css.len and isSpace(css[i])) i += 1;
        if (i >= css.len) return;
        if (css[i] == '@') @trap();
        const selector_start = i;
        var quote: u8 = 0;
        var bracket_depth: u8 = 0;
        while (i < css.len) : (i += 1) {
            const c = css[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') quote = c else if (c == '[') bracket_depth += 1 else if (c == ']') bracket_depth -= 1 else if (c == '{' and bracket_depth == 0) break;
        }
        if (i >= css.len) @trap();
        const close = findMatchingBrace(css, i) orelse @trap();
        const selectors = trim(css[selector_start..i]);
        processRuleBody(css[i + 1 .. close], selectors, null, rules, count, 0);
        i = close + 1;
    }
}

noinline fn hasClass(class_attr: []const u8, name: []const u8) bool {
    var i: usize = 0;
    var class_steps: usize = 0;
    while (i < class_attr.len and class_steps < INPUT_CAP) : (class_steps += 1) {
        var space_steps: usize = 0;
        while (i < class_attr.len and isSpace(class_attr[i]) and space_steps < INPUT_CAP) {
            i += 1;
            space_steps += 1;
        }
        const start = i;
        var token_steps: usize = 0;
        while (i < class_attr.len and !isSpace(class_attr[i]) and token_steps < INPUT_CAP) {
            i += 1;
            token_steps += 1;
        }
        if (i > start and bytesEqual(class_attr[start..i], name)) return true;
    }
    return false;
}

fn valueEqual(a: []const u8, b: []const u8, insensitive: bool) bool {
    return if (insensitive) eqlIgnoreCase(a, b) else bytesEqual(a, b);
}

fn attrValueMatches(actual: []const u8, expected: []const u8, op: AttrOperator, insensitive: bool) bool {
    if (op == .equal) return valueEqual(actual, expected, insensitive);
    if (expected.len == 0) return false;
    if (op == .prefix) return actual.len >= expected.len and valueEqual(actual[0..expected.len], expected, insensitive);
    if (op == .suffix) return actual.len >= expected.len and valueEqual(actual[actual.len - expected.len ..], expected, insensitive);
    if (op == .dash) return valueEqual(actual, expected, insensitive) or
        (actual.len > expected.len and actual[expected.len] == '-' and valueEqual(actual[0..expected.len], expected, insensitive));
    var i: usize = 0;
    while (i + expected.len <= actual.len and i < INPUT_CAP) : (i += 1) {
        if (valueEqual(actual[i .. i + expected.len], expected, insensitive)) {
            if (op == .substring) return true;
            if (op == .includes and (i == 0 or isSpace(actual[i - 1])) and (i + expected.len == actual.len or isSpace(actual[i + expected.len]))) return true;
        }
    }
    return false;
}

fn findElementAttr(el: *const Element, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < el.attr_count and i < MAX_ELEMENT_ATTRS) : (i += 1) {
        if (eqlIgnoreCase(el.attrs[i].name, name)) return el.attrs[i].value;
    }
    return null;
}

fn htmlAttributeValueIsCaseInsensitive(name: []const u8) bool {
    const names = .{
        "accept", "accept-charset", "align", "alink", "axis", "bgcolor", "charset", "checked", "clear", "codetype", "color", "compact", "declare", "defer", "dir", "direction", "disabled", "enctype", "face", "frame", "hreflang", "http-equiv", "lang", "language", "link", "media", "method", "multiple", "nohref", "noresize", "noshade", "nowrap", "readonly", "rel", "rev", "rules", "scope", "scrolling", "selected", "shape", "target", "text", "type", "valign", "valuetype", "vlink",
    };
    inline for (names) |candidate| {
        if (eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn compoundMatches(part: *const CompoundSelector, el: *const Element) bool {
    if (part.tag_len > 0 and !eqlIgnoreCase(el.tag[0..el.tag_len], part.tag[0..part.tag_len])) return false;
    if (part.id_len > 0 and !bytesEqual(el.id[0..el.id_len], part.id[0..part.id_len])) return false;
    if (part.root and !el.is_root) return false;
    var i: usize = 0;
    while (i < part.class_count and i < MAX_SELECTOR_CLASSES) : (i += 1) {
        if (!hasClass(el.class_attr, part.classes[i][0..part.class_lens[i]])) return false;
    }
    i = 0;
    while (i < part.attr_count and i < MAX_SELECTOR_ATTRS) : (i += 1) {
        const wanted = &part.attrs[i];
        const actual = findElementAttr(el, wanted.name[0..wanted.name_len]) orelse return false;
        const insensitive = wanted.case_insensitive or (!wanted.force_sensitive and htmlAttributeValueIsCaseInsensitive(wanted.name[0..wanted.name_len]));
        if (wanted.operator != .present and !attrValueMatches(actual, wanted.value[0..wanted.value_len], wanted.operator, insensitive)) return false;
    }
    return true;
}

fn selectorMatches(sel: *const Selector, el: *const Element, ancestors: []const Element) bool {
    if (sel.part_count == 0) return false;
    var part_index: usize = sel.part_count - 1;
    if (!compoundMatches(&sel.parts[part_index], el)) return false;
    var ancestor_end = ancestors.len;
    while (part_index > 0) {
        part_index -= 1;
        var found = false;
        while (ancestor_end > 0) {
            ancestor_end -= 1;
            if (compoundMatches(&sel.parts[part_index], &ancestors[ancestor_end])) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

const channel_luminance: [256]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var values: [256]f64 = undefined;
    for (0..256) |i| {
        const s = @as(f64, @floatFromInt(i)) / 255.0;
        values[i] = if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
    }
    break :blk values;
};

fn luminanceChannel(v: u8) f64 {
    return channel_luminance[v];
}

fn luminance(c: Color) f64 {
    return 0.2126 * luminanceChannel(c.r) + 0.7152 * luminanceChannel(c.g) + 0.0722 * luminanceChannel(c.b);
}

fn contrastRatio(a: Color, b: Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const lighter = @max(la, lb);
    const darker = @min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
}

fn passesAA(fg: Color, bg: Color, font_size_px: f64, bold: bool) bool {
    const large = font_size_px >= 24.0 or (bold and font_size_px + 0.000001 >= (56.0 / 3.0));
    const threshold: f64 = if (large) 3.0 else 4.5;
    return contrastRatio(fg, bg) >= threshold;
}

fn findTagEnd(input: []const u8, start: usize) usize {
    var i = start;
    var quote: u8 = 0;
    var steps: usize = 0;
    while (i < input.len) : (i += 1) {
        if (steps >= INPUT_CAP * 2) @trap();
        steps += 1 + (input[i] & 1);
        const c = input[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i;
        }
    }
    return input.len;
}

noinline fn parseAttrs(tag_src: []const u8) Attrs {
    var attrs = Attrs{};
    var i: usize = 0;
    var tag_steps: usize = 0;
    while (i < tag_src.len and !isSpace(tag_src[i]) and tag_src[i] != '/' and tag_steps < INPUT_CAP) {
        i += 1;
        tag_steps += 1;
    }
    var attr_steps: usize = 0;
    while (i < tag_src.len and attr_steps < INPUT_CAP) : (attr_steps += 1) {
        var separator_steps: usize = 0;
        while (i < tag_src.len and (isSpace(tag_src[i]) or tag_src[i] == '/') and separator_steps < INPUT_CAP) {
            i += 1;
            separator_steps += 1;
        }
        const name_start = i;
        var name_steps: usize = 0;
        while (i < tag_src.len and isNameChar(tag_src[i]) and name_steps < INPUT_CAP) {
            i += 1;
            name_steps += 1;
        }
        if (i == name_start) break;
        const name = tag_src[name_start..i];
        var before_value_steps: usize = 0;
        while (i < tag_src.len and isSpace(tag_src[i]) and before_value_steps < INPUT_CAP) {
            i += 1;
            before_value_steps += 1;
        }
        var value: []const u8 = "";
        if (i < tag_src.len and tag_src[i] == '=') {
            i += 1;
            var after_equals_steps: usize = 0;
            while (i < tag_src.len and isSpace(tag_src[i]) and after_equals_steps < INPUT_CAP) {
                i += 1;
                after_equals_steps += 1;
            }
            if (i < tag_src.len and (tag_src[i] == '"' or tag_src[i] == '\'')) {
                const q = tag_src[i];
                i += 1;
                const value_start = i;
                var quoted_steps: usize = 0;
                while (i < tag_src.len and tag_src[i] != q and quoted_steps < INPUT_CAP) {
                    i += 1;
                    quoted_steps += 1;
                }
                value = tag_src[value_start..@min(i, tag_src.len)];
                if (i < tag_src.len) i += 1;
            } else {
                const value_start = i;
                var unquoted_steps: usize = 0;
                while (i < tag_src.len and !isSpace(tag_src[i]) and tag_src[i] != '/' and unquoted_steps < INPUT_CAP) {
                    i += 1;
                    unquoted_steps += 1;
                }
                value = tag_src[value_start..i];
            }
        }
        if (eqlIgnoreCase(name, "id")) attrs.id = value;
        if (eqlIgnoreCase(name, "class")) attrs.class = value;
        if (eqlIgnoreCase(name, "style")) attrs.style = value;
        if (attrs.count >= MAX_ELEMENT_ATTRS) @trap();
        attrs.items[attrs.count] = .{ .name = name, .value = value };
        attrs.count += 1;
    }
    return attrs;
}

noinline fn parseOpenElement(tag_src: []const u8, parent: Element, ancestors: []const Element, rules: []Rule) Element {
    var el = parent;
    el.class_attr = "";
    el.id_len = 0;
    el.attr_count = 0;
    el.is_root = ancestors.len == 1;
    const attrs = parseAttrs(tag_src);
    var tag_end: usize = 0;
    var tag_steps: usize = 0;
    while (tag_end < tag_src.len and !isSpace(tag_src[tag_end]) and tag_src[tag_end] != '/' and tag_steps < MAX_NAME) {
        tag_end += 1;
        tag_steps += 1;
    }
    if (!copyLower(&el.tag, &el.tag_len, tag_src[0..tag_end])) @trap();
    if (attrs.id.len > 0 and !copyExact(MAX_NAME, &el.id, &el.id_len, attrs.id)) @trap();
    el.class_attr = attrs.class;
    el.attr_count = attrs.count;
    var attr_index: usize = 0;
    while (attr_index < attrs.count and attr_index < MAX_ELEMENT_ATTRS) : (attr_index += 1) el.attrs[attr_index] = attrs.items[attr_index];
    el.suppress_text = eqlIgnoreCase(el.tag[0..el.tag_len], "script") or eqlIgnoreCase(el.tag[0..el.tag_len], "style");

    var color_specificity: i32 = -1;
    var background_specificity: i32 = -1;
    var color_important = false;
    var background_important = false;
    var font_size_specificity: i32 = -1;
    var bold_specificity: i32 = -1;
    var font_size_important = false;
    var bold_important = false;
    var rule_index: usize = 0;
    var rule_steps: usize = 0;
    while (rule_index < rules.len and rule_steps < MAX_RULES) : ({
        rule_index += 1;
        rule_steps += 1;
    }) {
        const rule = &rules[rule_index];
        if (!selectorMatches(&rule.selector, &el, ancestors)) continue;
        if (rule.style.unsupported) @trap();
        if (rule.style.color) |color| {
            if ((rule.style.color_important and !color_important) or
                (rule.style.color_important == color_important and @as(i32, rule.specificity) >= color_specificity))
            {
                el.color = color;
                color_important = rule.style.color_important;
                color_specificity = rule.specificity;
            }
        }
        if (rule.style.background) |background| {
            if ((rule.style.background_important and !background_important) or
                (rule.style.background_important == background_important and @as(i32, rule.specificity) >= background_specificity))
            {
                el.background = background;
                background_important = rule.style.background_important;
                background_specificity = rule.specificity;
            }
        }
        if (rule.style.font_size_px) |font_size_px| {
            if ((rule.style.font_size_important and !font_size_important) or
                (rule.style.font_size_important == font_size_important and @as(i32, rule.specificity) >= font_size_specificity))
            {
                el.font_size_px = font_size_px;
                font_size_important = rule.style.font_size_important;
                font_size_specificity = rule.specificity;
            }
        }
        if (rule.style.bold) |bold| {
            if ((rule.style.bold_important and !bold_important) or
                (rule.style.bold_important == bold_important and @as(i32, rule.specificity) >= bold_specificity))
            {
                el.bold = bold;
                bold_important = rule.style.bold_important;
                bold_specificity = rule.specificity;
            }
        }
    }
    const inline_style = parseStyleDecls(attrs.style);
    if (inline_style.unsupported) @trap();
    if (inline_style.color) |color| {
        if (inline_style.color_important or !color_important) el.color = color;
    }
    if (inline_style.background) |background| {
        if (inline_style.background_important or !background_important) el.background = background;
    }
    if (inline_style.font_size_px) |font_size_px| {
        if (inline_style.font_size_important or !font_size_important) el.font_size_px = font_size_px;
    }
    if (inline_style.bold) |bold| {
        if (inline_style.bold_important or !bold_important) el.bold = bold;
    }
    return el;
}

fn isVoidElement(tag: []const u8) bool {
    const names = .{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };
    inline for (names) |name| {
        if (eqlIgnoreCase(tag, name)) return true;
    }
    return false;
}

noinline fn closingTagOffset(input: []const u8, start: usize, name: []const u8) ?usize {
    var i = start;
    var steps: usize = 0;
    while (i + name.len + 3 <= input.len and steps < INPUT_CAP) : ({
        i += 1;
        steps += 1;
    }) {
        if (input[i] != '<' or input[i + 1] != '/') continue;
        if (!eqlIgnoreCase(input[i + 2 .. i + 2 + name.len], name)) continue;
        var p = i + 2 + name.len;
        var space_steps: usize = 0;
        while (p < input.len and isSpace(input[p]) and space_steps < INPUT_CAP) {
            p += 1;
            space_steps += 1;
        }
        if (p < input.len and input[p] == '>') return i;
    }
    return null;
}

noinline fn collectStylesheets(input: []const u8, rules: []Rule, count: *usize) void {
    var i: usize = 0;
    var steps: usize = 0;
    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        const tag_end = findTagEnd(input, i + 1);
        if (tag_end >= input.len) return;
        const tag_src = trim(input[i + 1 .. tag_end]);
        i = tag_end + 1;
        if (tag_src.len == 0 or tag_src[0] == '/' or tag_src[0] == '!' or tag_src[0] == '?') continue;
        var name_end: usize = 0;
        var name_steps: usize = 0;
        while (name_end < tag_src.len and isNameChar(tag_src[name_end]) and name_steps < MAX_NAME) {
            name_end += 1;
            name_steps += 1;
        }
        if (!eqlIgnoreCase(tag_src[0..name_end], "style")) continue;
        const close = closingTagOffset(input, i, "style") orelse @trap();
        parseStylesheet(input[i..close], rules, count);
        const close_end = findTagEnd(input, close + 2);
        if (close_end >= input.len) @trap();
        i = close_end + 1;
    }
}

noinline fn validateContrast(input: []const u8, rules: []Rule) void {
    var rule_count: usize = 0;
    collectStylesheets(input, rules, &rule_count);
    var stack: [MAX_STACK]Element = undefined;
    var depth: usize = 1;
    stack[0] = .{};

    var i: usize = 0;
    var document_steps: usize = 0;
    while (i < input.len and document_steps < INPUT_CAP) : (document_steps += 1) {
        if (input[i] != '<') {
            const start = i;
            var text_steps: usize = 0;
            while (i < input.len and input[i] != '<') {
                if (text_steps >= INPUT_CAP * 2) @trap();
                text_steps += 1 + (input[i] & 1);
                i += 1;
            }
            const current = stack[depth - 1];
            if (!current.suppress_text and hasVisibleText(input[start..i]) and !passesAA(current.color, current.background, current.font_size_px, current.bold)) @trap();
            continue;
        }

        if (i + 4 <= input.len and input[i] == '<' and input[i + 1] == '!' and input[i + 2] == '-' and input[i + 3] == '-') {
            if (indexOfCommentEnd(input[i + 4 ..])) |off| {
                i = i + 4 + off + 3;
            } else {
                break;
            }
            continue;
        }

        const tag_end = findTagEnd(input, i + 1);
        if (tag_end >= input.len) break;
        const tag_src = trim(input[i + 1 .. tag_end]);
        i = tag_end + 1;
        if (tag_src.len == 0 or tag_src[0] == '!' or tag_src[0] == '?') continue;

        if (tag_src[0] == '/') {
            const close_src = trim(tag_src[1..]);
            var close_len: usize = 0;
            var close_steps: usize = 0;
            while (close_len < close_src.len and isNameChar(close_src[close_len])) {
                if (close_steps >= MAX_NAME * 2) @trap();
                close_steps += 1 + (close_src[close_len] & 1);
                close_len += 1;
            }
            var search = depth;
            var stack_steps: usize = 0;
            while (stack_steps < MAX_STACK) : (stack_steps += 1) {
                if (search <= 1) break;
                search -= 1;
                if (eqlIgnoreCase(stack[search].tag[0..stack[search].tag_len], close_src[0..close_len])) {
                    depth = search;
                    break;
                }
            }
            continue;
        }

        const parent = stack[depth - 1];
        const el = parseOpenElement(tag_src, parent, stack[0..depth], rules[0..rule_count]);

        if (eqlIgnoreCase(el.tag[0..el.tag_len], "style")) {
            const close = closingTagOffset(input, i, "style") orelse @trap();
            const close_end = findTagEnd(input, close + 2);
            if (close_end >= input.len) @trap();
            i = close_end + 1;
            continue;
        }

        if (!isVoidElement(el.tag[0..el.tag_len])) {
            if (depth >= stack.len) @trap();
            stack[depth] = el;
            depth += 1;
        }
    }
}

fn renderChecked(input: []const u8, out: []u8) usize {
    if (input.len > out.len) @trap();
    validateContrast(input, rules_buf[0..]);
    @memcpy(out[0..input.len], input);
    return input.len;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    return @as(u32, @intCast(renderChecked(input_buf[0..input_size], output_buf[0..])));
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

test "passes inline AA contrast and returns input unchanged" {
    const html = "<p style=\"color:#111;background:#fff\">Readable</p>";
    var out: [128]u8 = undefined;
    const len = renderChecked(html, out[0..]);
    try std.testing.expectEqualStrings(html, out[0..len]);
}

test "passes stylesheet rule before content" {
    const html = "<style>.ok{color:#111;background:white}</style><p class=\"ok\">Readable</p>";
    var out: [128]u8 = undefined;
    const len = renderChecked(html, out[0..]);
    try std.testing.expectEqualStrings(html, out[0..len]);
}

test "stylesheet cascade applies regardless of style element position" {
    const html = "<p>Readable</p><style>p{color:#111;background:#fff}</style>";
    var out: [128]u8 = undefined;
    const len = renderChecked(html, out[0..]);
    try std.testing.expectEqualStrings(html, out[0..len]);
}
