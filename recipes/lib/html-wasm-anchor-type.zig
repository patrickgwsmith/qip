const std = @import("std");

const TYPE_ATTRIBUTE = " type=\"application/wasm\"";

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn equalIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (lower(left) != lower(right)) return false;
    }
    return true;
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

fn tagBoundary(byte: u8) bool {
    return space(byte) or byte == '>' or byte == '/';
}

fn startsTag(input: []const u8, start: usize, name: []const u8, closing: bool) bool {
    const prefix = if (closing) start + 2 else start + 1;
    if (prefix + name.len >= input.len) return false;
    if (input[start] != '<' or (closing and input[start + 1] != '/')) return false;
    return equalIgnoreCase(input[prefix .. prefix + name.len], name) and tagBoundary(input[prefix + name.len]);
}

fn tagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    for (start..input.len) |index| {
        const byte = input[index];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == '>') {
            return index;
        }
    }
    return null;
}

fn wasmHref(value: []const u8) bool {
    const path_end = std.mem.indexOfAny(u8, value, "?#") orelse value.len;
    const path = value[0..path_end];
    return path.len >= 5 and equalIgnoreCase(path[path.len - 5 ..], ".wasm");
}

fn anchorNeedsType(tag: []const u8) bool {
    var i: usize = 2;
    var href_is_wasm = false;
    var has_type = false;
    while (i < tag.len - 1) {
        while (i < tag.len - 1 and (space(tag[i]) or tag[i] == '/')) : (i += 1) {}
        const name_start = i;
        while (i < tag.len - 1 and !space(tag[i]) and tag[i] != '=' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}
        if (i == name_start) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];
        while (i < tag.len - 1 and space(tag[i])) : (i += 1) {}
        var value: []const u8 = "";
        if (i < tag.len - 1 and tag[i] == '=') {
            i += 1;
            while (i < tag.len - 1 and space(tag[i])) : (i += 1) {}
            if (i < tag.len - 1 and (tag[i] == '"' or tag[i] == '\'')) {
                const quote = tag[i];
                i += 1;
                const value_start = i;
                while (i < tag.len - 1 and tag[i] != quote) : (i += 1) {}
                value = tag[value_start..i];
                if (i < tag.len - 1) i += 1;
            } else {
                const value_start = i;
                while (i < tag.len - 1 and !space(tag[i]) and tag[i] != '>') : (i += 1) {}
                value = tag[value_start..i];
            }
        }
        if (equalIgnoreCase(name, "href")) href_is_wasm = wasmHref(value);
        if (equalIgnoreCase(name, "type")) has_type = true;
    }
    return href_is_wasm and !has_type;
}

const Writer = struct {
    output: []u8,
    count: usize = 0,

    fn append(self: *Writer, bytes: []const u8) bool {
        if (bytes.len > self.output.len - self.count) return false;
        @memcpy(self.output[self.count..][0..bytes.len], bytes);
        self.count += bytes.len;
        return true;
    }
};

pub fn addWasmAnchorTypes(input: []const u8, output: []u8) ?usize {
    var writer = Writer{ .output = output };
    var i: usize = 0;
    var raw_tag: ?[]const u8 = null;
    while (i < input.len) {
        if (input[i] != '<') {
            if (!writer.append(input[i .. i + 1])) return null;
            i += 1;
            continue;
        }
        if (raw_tag) |name| {
            if (!startsTag(input, i, name, true)) {
                if (!writer.append(input[i .. i + 1])) return null;
                i += 1;
                continue;
            }
            raw_tag = null;
        }
        if (std.mem.startsWith(u8, input[i..], "<!--")) {
            const end = if (std.mem.indexOf(u8, input[i + 4 ..], "-->")) |offset|
                i + 4 + offset + 3
            else
                input.len;
            if (!writer.append(input[i..end])) return null;
            i = end;
            continue;
        }
        const end = tagEnd(input, i) orelse input.len - 1;
        const tag = input[i .. end + 1];
        if (startsTag(input, i, "a", false) and anchorNeedsType(tag)) {
            const insert_at = if (tag.len >= 2 and tag[tag.len - 2] == '/') tag.len - 2 else tag.len - 1;
            if (!writer.append(tag[0..insert_at]) or !writer.append(TYPE_ATTRIBUTE) or !writer.append(tag[insert_at..])) return null;
        } else if (!writer.append(tag)) return null;
        if (startsTag(input, i, "script", false)) raw_tag = "script";
        if (startsTag(input, i, "style", false)) raw_tag = "style";
        i = end + 1;
    }
    return writer.count;
}

test "adds type to Wasm anchors while preserving other markup" {
    const input =
        "<p><a href=\"/a.wasm\"><code>a.wasm</code></a>" ++
        " <A HREF='/b.WASM?download=1#top' download>b</A>" ++
        " <a href=/c.txt>c</a><source src=/d.wasm></p>";
    const expected =
        "<p><a href=\"/a.wasm\" type=\"application/wasm\"><code>a.wasm</code></a>" ++
        " <A HREF='/b.WASM?download=1#top' download type=\"application/wasm\">b</A>" ++
        " <a href=/c.txt>c</a><source src=/d.wasm></p>";
    var output: [1024]u8 = undefined;
    const size = addWasmAnchorTypes(input, &output) orelse unreachable;
    try std.testing.expectEqualStrings(expected, output[0..size]);
}

test "leaves typed anchors and raw script or comment text alone" {
    const input =
        "<!-- <a href=/comment.wasm> -->" ++
        "<script>const s = '<a href=/script.wasm>';</script>" ++
        "<style>a::before { content: '<a href=/style.wasm>'; }</style>" ++
        "<a href=/done.wasm type='application/wasm'>done</a>";
    var output: [1024]u8 = undefined;
    const size = addWasmAnchorTypes(input, &output) orelse unreachable;
    try std.testing.expectEqualStrings(input, output[0..size]);
}

test "rejects output that cannot fit inserted attributes" {
    var output: [12]u8 = undefined;
    try std.testing.expect(addWasmAnchorTypes("<a href=/a.wasm>", &output) == null);
}
