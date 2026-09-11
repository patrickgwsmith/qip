//! Remove the supported ANSI SGR presentation controls from UTF-8 text.

const ansi = @import("lib/ansi-sgr.zig");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const CONTENT_TYPE = "text/plain";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

const Context = struct {
    output_len: usize = 0,

    fn emit(self: *@This(), text: []const u8, _: ansi.Style) !void {
        if (text.len > output_buf.len - self.output_len) return error.OutputOverflow;
        @memcpy(output_buf[self.output_len .. self.output_len + text.len], text);
        self.output_len += text.len;
    }
};

fn renderImpl(input: []const u8) u32 {
    var context = Context{};
    ansi.parse(input, Context, &context, Context.emit) catch @trap();
    return @intCast(context.output_len);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const size: usize = input_size;
    if (size > INPUT_CAP) @trap();
    return .{ .output_size = renderImpl(input_buf[0..size]), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "strips supported SGR while retaining UTF-8 and newlines" {
    const input = "normal \x1b[1;94mbold blue\x1b[0m\n\x1b[2mdim é\x1b[22m";
    const output_len = renderImpl(input);
    try @import("std").testing.expectEqualStrings("normal bold blue\ndim é", output_buf[0..output_len]);
}
