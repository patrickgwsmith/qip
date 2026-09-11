const std = @import("std");

const INPUT_CAP: usize = 512 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const OUTPUT_CONTENT_TYPE = "text/html";

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

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

fn escapedByteLen(b: u8) usize {
    return switch (b) {
        '&' => "&amp;".len,
        '<' => "&lt;".len,
        '>' => "&gt;".len,
        '"' => "&quot;".len,
        '\'' => "&#39;".len,
        else => 1,
    };
}

fn escapedLen(input: []const u8) usize {
    var len: usize = 0;
    for (input) |b| {
        len += escapedByteLen(b);
    }
    return len;
}

fn writeEscapedByte(out: []u8, index: *usize, b: u8) void {
    const escaped = switch (b) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
        else => {
            out[index.*] = b;
            index.* += 1;
            return;
        },
    };
    @memcpy(out[index.* .. index.* + escaped.len], escaped);
    index.* += escaped.len;
}

fn escapeHtml(input: []const u8, out: []u8) usize {
    const needed = escapedLen(input);
    if (needed > out.len) @trap();

    var index: usize = 0;
    for (input) |b| {
        writeEscapedByte(out, &index, b);
    }
    return index;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    return @as(u32, @intCast(escapeHtml(input_buf[0..input_size], output_buf[0..])));
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

pub const native_output_capacity: usize = OUTPUT_CAP;

pub fn nativeRender(input: []const u8, output: []u8) u32 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const output_size = renderImpl(@intCast(input.len));
    if (output_size > output.len) @trap();
    @memcpy(output[0..output_size], output_buf[0..output_size]);
    return output_size;
}

test "escapes text node and quoted attribute characters" {
    var out: [128]u8 = undefined;
    const len = escapeHtml("<input value=\"Tom & 'QIP'\">", out[0..]);
    try std.testing.expectEqualStrings("&lt;input value=&quot;Tom &amp; &#39;QIP&#39;&quot;&gt;", out[0..len]);
}

test "leaves ordinary text unchanged" {
    var out: [128]u8 = undefined;
    const len = escapeHtml("plain UTF-8 text", out[0..]);
    try std.testing.expectEqualStrings("plain UTF-8 text", out[0..len]);
}

test "counts escaped output size before writing" {
    try std.testing.expectEqual(@as(usize, 4), escapedLen("<"));
    try std.testing.expectEqual(@as(usize, 6), escapedLen("\""));
    try std.testing.expectEqual(@as(usize, 5), escapedLen("'"));
}
