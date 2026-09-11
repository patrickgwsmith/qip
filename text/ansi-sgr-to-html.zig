//! Convert the supported ANSI SGR subset into an escaped HTML `<pre>` document.

const ansi = @import("lib/ansi-sgr.zig");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/plain";
const OUTPUT_CONTENT_TYPE = "text/html";

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

const Writer = struct {
    index: usize = 0,

    fn bytes(self: *Writer, text: []const u8) !void {
        if (text.len > output_buf.len - self.index) return error.OutputOverflow;
        @memcpy(output_buf[self.index .. self.index + text.len], text);
        self.index += text.len;
    }

    fn byte(self: *Writer, value: u8) !void {
        if (self.index >= output_buf.len) return error.OutputOverflow;
        output_buf[self.index] = value;
        self.index += 1;
    }
};

const Context = struct {
    out: Writer,

    fn emit(self: *@This(), text: []const u8, style: ansi.Style) !void {
        if (style.bold) try self.out.bytes("<b>");
        if (style.foreground != null or style.background != null or style.dim) {
            try self.out.bytes("<span style=\"");
            if (style.foreground) |color| {
                try self.out.bytes("color:");
                try self.out.bytes(ansi.colorHex(color));
                try self.out.byte(';');
            }
            if (style.background) |color| {
                try self.out.bytes("background-color:");
                try self.out.bytes(ansi.colorHex(color));
                try self.out.byte(';');
            }
            if (style.dim) try self.out.bytes("opacity:.65;");
            try self.out.bytes("\">");
        }
        if (style.underline) try self.out.bytes("<u>");
        for (text) |byte| switch (byte) {
            '&' => try self.out.bytes("&amp;"),
            '<' => try self.out.bytes("&lt;"),
            '>' => try self.out.bytes("&gt;"),
            else => try self.out.byte(byte),
        };
        if (style.underline) try self.out.bytes("</u>");
        if (style.foreground != null or style.background != null or style.dim) try self.out.bytes("</span>");
        if (style.bold) try self.out.bytes("</b>");
    }
};

fn renderImpl(input: []const u8) u32 {
    var context = Context{ .out = .{} };
    context.out.bytes("<!doctype html><meta charset=\"utf-8\"><pre>") catch @trap();
    ansi.parse(input, Context, &context, Context.emit) catch @trap();
    context.out.bytes("</pre>") catch @trap();
    return @intCast(context.out.index);
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

test "uses semantic tags and escapes text" {
    const input = "<\x1b[1;94mblue & bold\x1b[0m>";
    const output_len = renderImpl(input);
    const output = output_buf[0..output_len];
    try @import("std").testing.expect(@import("std").mem.indexOf(u8, output, "<b><span style=\"color:#3b8eea;\">blue &amp; bold</span></b>") != null);
    try @import("std").testing.expect(@import("std").mem.indexOf(u8, output, "&lt;") != null);
}
