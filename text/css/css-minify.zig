const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/css";
const OUTPUT_CONTENT_TYPE = "text/css";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const MinifyError = error{ OutputOverflow, UnterminatedString, UnterminatedComment };

fn isWhitespace(b: u8) bool {
    return b == ' ' or b == '\n' or b == '\r' or b == '\t' or b == 0x0c;
}

fn isIdentChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-';
}

fn isPunct(b: u8) bool {
    return switch (b) {
        '{', '}', ':', ';', ',', '>', '~', '(', ')', '[', ']', '=' => true,
        else => false,
    };
}

fn needsSpace(left: u8, right: u8, in_function: bool) bool {
    return (isIdentChar(left) and isIdentChar(right)) or
        (in_function and (left == '+' or left == '-' or right == '+' or right == '-'));
}

fn writeByte(output: []u8, out_idx: *usize, b: u8) MinifyError!void {
    if (out_idx.* >= output.len) return error.OutputOverflow;
    output[out_idx.*] = b;
    out_idx.* += 1;
}

fn minifyCss(input: []const u8, output: []u8) MinifyError!usize {
    var i: usize = 0;
    var out: usize = 0;
    var pending_space = false;
    var last: u8 = 0;
    var paren_depth: usize = 0;
    var steps: usize = 0;

    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        const b = input[i];
        if (b == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) i += 1;
            if (i + 1 >= input.len) return error.UnterminatedComment;
            i += 2;
            pending_space = out > 0;
            continue;
        }
        if (isWhitespace(b)) {
            pending_space = out > 0;
            i += 1;
            continue;
        }
        if (b == '"' or b == '\'') {
            if (pending_space and out > 0 and needsSpace(last, b, paren_depth > 0)) try writeByte(output, &out, ' ');
            pending_space = false;
            const quote = b;
            try writeByte(output, &out, b);
            last = b;
            i += 1;
            var string_steps: usize = 0;
            while (i < input.len and string_steps < INPUT_CAP) : (string_steps += 1) {
                const c = input[i];
                try writeByte(output, &out, c);
                last = c;
                i += 1;
                if (c == quote) break;
                if (c == '\\') {
                    if (i >= input.len) return error.UnterminatedString;
                    try writeByte(output, &out, input[i]);
                    last = input[i];
                    i += 1;
                }
            } else return error.UnterminatedString;
            continue;
        }
        if (pending_space and out > 0 and needsSpace(last, b, paren_depth > 0)) {
            try writeByte(output, &out, ' ');
            last = ' ';
        }
        pending_space = false;
        if (isPunct(b) and out > 0 and output[out - 1] == ' ') out -= 1;
        if (b == ';') {
            var j = i + 1;
            while (j < input.len and isWhitespace(input[j])) j += 1;
            if (j < input.len and input[j] == '}') {
                i += 1;
                continue;
            }
        }
        try writeByte(output, &out, b);
        if (b == '(') paren_depth += 1;
        if (b == ')' and paren_depth > 0) paren_depth -= 1;
        last = b;
        i += 1;
    }
    return out;
}

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

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const output_size = minifyCss(input_buf[0..input_size], output_buf[0..]) catch @trap();
    return @as(u32, @intCast(output_size));
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

test "minifies rules" {
    var out: [256]u8 = undefined;
    const len = try minifyCss("/* x */ .card > a { color: red; margin: 0 ; }\n", out[0..]);
    try std.testing.expectEqualStrings(".card>a{color:red;margin:0}", out[0..len]);
}

test "preserves strings" {
    var out: [256]u8 = undefined;
    const len = try minifyCss(".x{content:\"a  b /* not comment */\"}", out[0..]);
    try std.testing.expectEqualStrings(".x{content:\"a  b /* not comment */\"}", out[0..len]);
}

test "preserves required calc operator whitespace" {
    var out: [256]u8 = undefined;
    const len = try minifyCss(".x { width: calc(100% - 1rem); height: calc(1px + 2px); }", out[0..]);
    try std.testing.expectEqualStrings(".x{width:calc(100% - 1rem);height:calc(1px + 2px)}", out[0..len]);
}
