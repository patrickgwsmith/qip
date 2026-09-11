const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const CONTENT_TYPE = "text/html";
const MAX_TARGETS: usize = 64 * 1024;
const MAX_REFERENCES: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var targets_buf: [MAX_TARGETS]Target = undefined;
var references_buf: [MAX_REFERENCES]Reference = undefined;

const ValidationError = error{
    MalformedHtml,
    MissingTarget,
    WrongTargetType,
    ResourceLimit,
};

const Range = struct {
    start: u32 = 0,
    len: u32 = 0,
    present: bool = false,

    fn slice(self: Range, input: []const u8) []const u8 {
        if (!self.present) return "";
        const start: usize = @intCast(self.start);
        const len: usize = @intCast(self.len);
        return input[start .. start + len];
    }
};

const Target = struct {
    id: Range,
    tag: Range,
    popover: bool,
    input_hidden: bool,
};

const TargetKind = enum(u8) {
    any,
    labelable,
    form,
    datalist,
    table_header,
    popover,
};

const Reference = struct {
    value: Range,
    kind: TargetKind,
    list: bool,
    fragment: bool = false,
};

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
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn equalIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn startsWith(input: []const u8, pos: usize, expected: []const u8) bool {
    if (pos > input.len or expected.len > input.len - pos) return false;
    return bytesEqual(input[pos .. pos + expected.len], expected);
}

fn isNameEnd(c: u8) bool {
    return isSpace(c) or c == '/' or c == '>' or c == '=';
}

fn skipSpaces(input: []const u8, index: *usize) void {
    while (index.* < input.len and isSpace(input[index.*])) : (index.* += 1) {}
}

fn scanToTagEnd(input: []const u8, start: usize) ValidationError!usize {
    var i = start;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        const byte = input[i];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            return i + 1;
        }
    }
    return error.MalformedHtml;
}

fn scanComment(input: []const u8, start: usize) ValidationError!usize {
    var i = start + 4;
    while (i + 2 < input.len) : (i += 1) {
        if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') return i + 3;
    }
    return error.MalformedHtml;
}

fn isRawTextTag(tag: []const u8) bool {
    return equalIgnoreCase(tag, "script") or
        equalIgnoreCase(tag, "style") or
        equalIgnoreCase(tag, "textarea") or
        equalIgnoreCase(tag, "title") or
        equalIgnoreCase(tag, "xmp") or
        equalIgnoreCase(tag, "iframe") or
        equalIgnoreCase(tag, "noembed") or
        equalIgnoreCase(tag, "noframes");
}

fn findRawTextEnd(input: []const u8, start: usize, tag: []const u8) usize {
    var i = start;
    while (i + tag.len + 2 <= input.len) : (i += 1) {
        if (input[i] != '<' or input[i + 1] != '/') continue;
        if (i + 2 + tag.len > input.len or !equalIgnoreCase(input[i + 2 .. i + 2 + tag.len], tag)) continue;
        const after = i + 2 + tag.len;
        if (after == input.len or isSpace(input[after]) or input[after] == '>') return i;
    }
    return input.len;
}

fn addReference(references_len: *usize, value: Range, kind: TargetKind, list: bool, fragment: bool) ValidationError!void {
    if (references_len.* >= MAX_REFERENCES) return error.ResourceLimit;
    references_buf[references_len.*] = .{ .value = value, .kind = kind, .list = list, .fragment = fragment };
    references_len.* += 1;
}

fn isAriaIdReference(name: []const u8) bool {
    return equalIgnoreCase(name, "aria-activedescendant") or
        equalIgnoreCase(name, "aria-details") or
        equalIgnoreCase(name, "aria-errormessage");
}

fn isAriaIdReferenceList(name: []const u8) bool {
    return equalIgnoreCase(name, "aria-controls") or
        equalIgnoreCase(name, "aria-describedby") or
        equalIgnoreCase(name, "aria-flowto") or
        equalIgnoreCase(name, "aria-labelledby") or
        equalIgnoreCase(name, "aria-owns");
}

fn isFormAssociatedTag(tag: []const u8) bool {
    return equalIgnoreCase(tag, "button") or
        equalIgnoreCase(tag, "fieldset") or
        equalIgnoreCase(tag, "input") or
        equalIgnoreCase(tag, "object") or
        equalIgnoreCase(tag, "output") or
        equalIgnoreCase(tag, "select") or
        equalIgnoreCase(tag, "textarea") or
        std.mem.indexOfScalar(u8, tag, '-') != null;
}

fn collectAttributeReference(tag: []const u8, name: []const u8, value: Range, references_len: *usize) ValidationError!void {
    if (isAriaIdReference(name)) return addReference(references_len, value, .any, false, false);
    if (isAriaIdReferenceList(name)) return addReference(references_len, value, .any, true, false);
    if (equalIgnoreCase(name, "itemref")) return addReference(references_len, value, .any, true, false);
    if (equalIgnoreCase(name, "for")) {
        if (equalIgnoreCase(tag, "label")) return addReference(references_len, value, .labelable, false, false);
        if (equalIgnoreCase(tag, "output")) return addReference(references_len, value, .any, true, false);
    }
    if (equalIgnoreCase(name, "headers") and (equalIgnoreCase(tag, "td") or equalIgnoreCase(tag, "th")))
        return addReference(references_len, value, .table_header, true, false);
    if (equalIgnoreCase(name, "form") and isFormAssociatedTag(tag)) return addReference(references_len, value, .form, false, false);
    if (equalIgnoreCase(name, "list") and equalIgnoreCase(tag, "input"))
        return addReference(references_len, value, .datalist, false, false);
    if (equalIgnoreCase(name, "popovertarget") and (equalIgnoreCase(tag, "button") or equalIgnoreCase(tag, "input"))) return addReference(references_len, value, .popover, false, false);
    if (equalIgnoreCase(name, "commandfor") and equalIgnoreCase(tag, "button")) return addReference(references_len, value, .any, false, false);
    if ((equalIgnoreCase(name, "href") or equalIgnoreCase(name, "xlink:href")) and
        (equalIgnoreCase(tag, "a") or equalIgnoreCase(tag, "area") or equalIgnoreCase(tag, "use")))
        return addReference(references_len, value, .any, false, true);
}

fn parseStartTag(input: []const u8, start: usize, targets_len: *usize, references_len: *usize) ValidationError!usize {
    var i = start + 1;
    const tag_start = i;
    while (i < input.len and !isNameEnd(input[i])) : (i += 1) {
        if (input[i] == '<' or input[i] == '\'' or input[i] == '"') return error.MalformedHtml;
    }
    if (i == tag_start) return error.MalformedHtml;
    const tag_range = Range{ .start = @intCast(tag_start), .len = @intCast(i - tag_start), .present = true };
    const tag = tag_range.slice(input);
    var id = Range{};
    var popover = false;
    var input_hidden = false;

    while (i < input.len) {
        skipSpaces(input, &i);
        if (i >= input.len) return error.MalformedHtml;
        if (input[i] == '>') {
            i += 1;
            break;
        }
        if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '>') {
            i += 2;
            break;
        }

        const name_start = i;
        while (i < input.len and !isNameEnd(input[i])) : (i += 1) {
            if (input[i] == '<' or input[i] == '\'' or input[i] == '"') return error.MalformedHtml;
        }
        if (i == name_start) return error.MalformedHtml;
        const name = input[name_start..i];
        skipSpaces(input, &i);

        var value = Range{ .start = @intCast(i), .len = 0, .present = true };
        if (i < input.len and input[i] == '=') {
            i += 1;
            skipSpaces(input, &i);
            if (i >= input.len) return error.MalformedHtml;
            if (input[i] == '\'' or input[i] == '"') {
                const quote = input[i];
                i += 1;
                const value_start = i;
                while (i < input.len and input[i] != quote) : (i += 1) {}
                if (i >= input.len) return error.MalformedHtml;
                value = .{ .start = @intCast(value_start), .len = @intCast(i - value_start), .present = true };
                i += 1;
            } else {
                const value_start = i;
                while (i < input.len and !isSpace(input[i]) and input[i] != '>') : (i += 1) {
                    if (input[i] == '<' or input[i] == '\'' or input[i] == '"' or input[i] == '=' or input[i] == '`') return error.MalformedHtml;
                }
                value = .{ .start = @intCast(value_start), .len = @intCast(i - value_start), .present = true };
            }
        }

        if (equalIgnoreCase(name, "id") and !id.present) id = value;
        if (equalIgnoreCase(name, "popover")) popover = true;
        if (equalIgnoreCase(tag, "input") and equalIgnoreCase(name, "type") and equalIgnoreCase(value.slice(input), "hidden")) input_hidden = true;
        try collectAttributeReference(tag, name, value, references_len);
    }

    if (id.present) {
        if (targets_len.* >= MAX_TARGETS) return error.ResourceLimit;
        targets_buf[targets_len.*] = .{ .id = id, .tag = tag_range, .popover = popover, .input_hidden = input_hidden };
        targets_len.* += 1;
    }
    return i;
}

fn targetMatchesKind(target: Target, kind: TargetKind, input: []const u8) bool {
    const tag = target.tag.slice(input);
    return switch (kind) {
        .any => true,
        .form => equalIgnoreCase(tag, "form"),
        .datalist => equalIgnoreCase(tag, "datalist"),
        .table_header => equalIgnoreCase(tag, "th"),
        .popover => target.popover,
        .labelable => equalIgnoreCase(tag, "button") or
            (equalIgnoreCase(tag, "input") and !target.input_hidden) or
            equalIgnoreCase(tag, "meter") or
            equalIgnoreCase(tag, "output") or
            equalIgnoreCase(tag, "progress") or
            equalIgnoreCase(tag, "select") or
            equalIgnoreCase(tag, "textarea") or
            std.mem.indexOfScalar(u8, tag, '-') != null,
    };
}

fn validateToken(token: []const u8, kind: TargetKind, input: []const u8, targets_len: usize) ValidationError!void {
    if (token.len == 0) return error.MissingTarget;
    var found_wrong_type = false;
    var i: usize = 0;
    while (i < targets_len) : (i += 1) {
        if (!bytesEqual(targets_buf[i].id.slice(input), token)) continue;
        if (targetMatchesKind(targets_buf[i], kind, input)) return;
        found_wrong_type = true;
    }
    if (found_wrong_type) return error.WrongTargetType;
    return error.MissingTarget;
}

fn validateReference(reference: Reference, input: []const u8, targets_len: usize) ValidationError!void {
    var value = reference.value.slice(input);
    if (reference.fragment) {
        if (value.len == 0 or value[0] != '#') return;
        value = value[1..];
        // An empty URL fragment addresses the document rather than an element.
        if (value.len == 0) return;
    }
    if (!reference.list) return validateToken(value, reference.kind, input, targets_len);

    var i: usize = 0;
    var token_count: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i == start) break;
        try validateToken(value[start..i], reference.kind, input, targets_len);
        token_count += 1;
    }
    if (token_count == 0) return error.MissingTarget;
}

fn validateIdReferences(input: []const u8) ValidationError!void {
    var targets_len: usize = 0;
    var references_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        if (startsWith(input, i, "<!--")) {
            i = try scanComment(input, i);
            continue;
        }
        if (i + 1 >= input.len) return error.MalformedHtml;
        if (input[i + 1] == '!' or input[i + 1] == '?' or input[i + 1] == '/') {
            i = try scanToTagEnd(input, i + 2);
            continue;
        }
        if (isSpace(input[i + 1]) or input[i + 1] == '<' or input[i + 1] == '>') {
            i += 1;
            continue;
        }
        const tag_start = i + 1;
        var tag_end = tag_start;
        while (tag_end < input.len and !isNameEnd(input[tag_end])) : (tag_end += 1) {}
        const tag = input[tag_start..tag_end];
        i = try parseStartTag(input, i, &targets_len, &references_len);
        if (equalIgnoreCase(tag, "plaintext")) break;
        if (isRawTextTag(tag)) i = findRawTextEnd(input, i, tag);
    }

    var reference_index: usize = 0;
    while (reference_index < references_len) : (reference_index += 1)
        try validateReference(references_buf[reference_index], input, targets_len);
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    validateIdReferences(input_buf[0..input_size]) catch @trap();
    return input_size_in;
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&input_buf)),
        .failed = 0,
    };
}

test "accepts resolved HTML and ARIA references" {
    try validateIdReferences(
        "<form id=f><label for=email>Email</label><input id=email form=f list=choices aria-describedby='hint extra'><datalist id=choices></datalist><p id=hint>Hint</p><p id=extra>Extra</p></form>" ++
            "<button popovertarget=menu commandfor=dialog>Open</button><div id=menu popover></div><dialog id=dialog></dialog><a href=#hint>Hint</a>",
    );
}

test "rejects missing references and wrong target types" {
    try std.testing.expectError(error.MissingTarget, validateIdReferences("<button aria-labelledby=missing>Save</button>"));
    try std.testing.expectError(error.WrongTargetType, validateIdReferences("<label for=not-control>Label</label><div id=not-control></div>"));
    try std.testing.expectError(error.WrongTargetType, validateIdReferences("<input list=choices><div id=choices></div>"));
    try std.testing.expectError(error.WrongTargetType, validateIdReferences("<button popovertarget=menu></button><div id=menu></div>"));
}

test "checks every token in ID reference lists" {
    try std.testing.expectError(error.MissingTarget, validateIdReferences("<p id=one></p><button aria-controls='one missing'></button>"));
    try std.testing.expectError(error.WrongTargetType, validateIdReferences("<table><th id=head></th><td headers='head body'></td><td id=body></td></table>"));
}

test "ignores external and empty-document fragments" {
    try validateIdReferences("<a href='other.html#missing'>Other</a><a href=#>Top</a><div href=#missing form=missing popovertarget=missing></div>");
}

test "ignores tag-looking text in comments and raw text elements" {
    try validateIdReferences("<!-- <button aria-controls=missing> --><script>const example = '<label for=missing>';</script><style>#missing { color: red }</style>");
}
