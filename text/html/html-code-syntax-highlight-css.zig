const std = @import("std");
const css = @import("lib/syntax-highlight-css.zig");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    pub fn writeByte(self: *Writer, byte: u8) void {
        if (self.overflow) return;
        if (self.idx == output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = byte;
        self.idx += 1;
    }

    pub fn writeSlice(self: *Writer, value: []const u8) void {
        if (self.overflow or value.len == 0) return;
        if (value.len > output_buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + value.len], value);
        self.idx += value.len;
    }

    pub fn writeSpan(self: *Writer, class_name: []const u8, value: []const u8) void {
        self.openSpan(class_name);
        self.writeSlice(value);
        self.closeSpan();
    }

    pub fn openSpan(self: *Writer, class_name: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
    }

    pub fn closeSpan(self: *Writer) void {
        self.writeSlice("</span>");
    }
};

const CodeInfo = struct { end: usize, is_css: bool, has_hljs: bool };
const ClassRange = struct { start: usize, end: usize };
const CloseTag = struct { start: usize, end: usize };

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
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

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9');
}

fn tokenInClass(value: []const u8, wanted: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i > start and eqlIgnoreCase(value[start..i], wanted)) return true;
    }
    return false;
}

fn isCssClass(value: []const u8) bool {
    return tokenInClass(value, "language-css");
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (quote != 0) {
            if (input[i] == quote) quote = 0;
        } else if (input[i] == '"' or input[i] == '\'') {
            quote = input[i];
        } else if (input[i] == '>') {
            return i;
        }
    }
    return null;
}

fn findClassRange(tag: []const u8) ?ClassRange {
    var i: usize = 5;
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        const name_start = i;
        while (i < tag.len and (isNameContinue(tag[i]) or tag[i] == ':')) : (i += 1) {}
        if (i == name_start) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len) break;

        var start = i;
        var end = i;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            start = i + 1;
            i += 1;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            end = i;
            if (i < tag.len) i += 1;
        } else {
            start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>') : (i += 1) {}
            end = i;
        }
        if (eqlIgnoreCase(name, "class")) return .{ .start = start, .end = end };
    }
    return null;
}

fn parseCodeOpen(input: []const u8, start: usize) ?CodeInfo {
    if (start + 5 > input.len or input[start] != '<' or !eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isSpace(input[start + 5]) and input[start + 5] != '>') return null;
    const end = findTagEnd(input, start + 5) orelse return null;
    const range = findClassRange(input[start .. end + 1]) orelse return .{ .end = end, .is_css = false, .has_hljs = false };
    const value = input[start + range.start .. start + range.end];
    return .{ .end = end, .is_css = isCssClass(value), .has_hljs = tokenInClass(value, "hljs") };
}

fn findClose(input: []const u8, start: usize) ?CloseTag {
    var i = start;
    while (i + 7 <= input.len) : (i += 1) {
        if (input[i] == '<' and input[i + 1] == '/' and eqlIgnoreCase(input[i + 2 .. i + 6], "code")) {
            var end = i + 6;
            while (end < input.len and isSpace(input[end])) : (end += 1) {}
            if (end < input.len and input[end] == '>') return .{ .start = i, .end = end };
        }
    }
    return null;
}

fn writeOpenWithHljs(tag: []const u8, w: *Writer) void {
    const range = findClassRange(tag) orelse {
        w.writeSlice(tag);
        return;
    };
    w.writeSlice(tag[0..range.end]);
    w.writeSlice(" hljs");
    w.writeSlice(tag[range.end..]);
}

fn writeHighlightedCSS(code: []const u8, w: *Writer) void {
    css.write(code, w);
}

fn transform(input: []const u8, w: *Writer) void {
    var cursor: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        const open = parseCodeOpen(input, i) orelse {
            i += 1;
            continue;
        };
        const close = findClose(input, open.end + 1) orelse {
            w.writeSlice(input[cursor..]);
            return;
        };
        w.writeSlice(input[cursor..i]);
        if (!open.is_css or open.has_hljs or std.mem.indexOf(u8, input[open.end + 1 .. close.start], "<span class=\"hljs-") != null) {
            w.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenWithHljs(input[i .. open.end + 1], w);
            writeHighlightedCSS(input[open.end + 1 .. close.start], w);
            w.writeSlice(input[close.start .. close.end + 1]);
        }
        cursor = close.end + 1;
        i = cursor;
    }
    w.writeSlice(input[cursor..]);
}

fn renderImpl(input_size: u32) u32 {
    const len: usize = @intCast(input_size);
    if (len > input_buf.len) @trap();
    var writer = Writer{};
    transform(input_buf[0..len], &writer);
    if (writer.overflow) @trap();
    return @intCast(writer.idx);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn runForTest(input: []const u8) []const u8 {
    @memcpy(input_buf[0..input.len], input);
    return output_buf[0..renderImpl(@intCast(input.len))];
}

test "highlights selectors properties values strings and comments" {
    const input = "<code class=\"language-css\">.card:hover { color: #fff; transform: translateY(-0.125rem); content: \"class color\"; /* display */ }</code>";
    const expected = "<code class=\"language-css hljs\"><span class=\"hljs-selector-class\">.card</span><span class=\"hljs-selector-pseudo\">:hover</span> { <span class=\"hljs-attribute\">color</span>: <span class=\"hljs-number\">#fff</span>; <span class=\"hljs-attribute\">transform</span>: <span class=\"hljs-built_in\">translateY</span>(-<span class=\"hljs-number\">0.125rem</span>); <span class=\"hljs-attribute\">content</span>: <span class=\"hljs-string\">\"class color\"</span>; <span class=\"hljs-comment\">/* display */</span> }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips other languages" {
    const input = "<code class=\"language-js\">const color = 1;</code>";
    try std.testing.expectEqualStrings(input, runForTest(input));
}
