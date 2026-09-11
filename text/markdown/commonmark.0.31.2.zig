// CommonMark 0.31.2 renderer (no GFM extensions). Thin root: the shared
// implementation — and its TODO backlog — lives in lib/commonmark.zig, which
// also builds gfm-commonmark.0.31.2.zig via the comptime `enable_gfm` flag.
const impl = @import("lib/commonmark.zig").Make(.{ .gfm = false });

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&impl.input_buf)));
}

export fn input_utf8_cap() u32 {
    return impl.INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return impl.OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(impl.INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(impl.INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(impl.OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(impl.OUTPUT_CONTENT_TYPE.len));
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = impl.render(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&impl.output_buf)),
        .failed = 0,
    };
}

pub const native_output_capacity: usize = impl.OUTPUT_CAP;

pub fn nativeRender(input: []const u8, output: []u8) u32 {
    if (input.len > impl.INPUT_CAP) @trap();
    @memcpy(impl.input_buf[0..input.len], input);
    const output_size = impl.render(@intCast(input.len));
    if (output_size > output.len) @trap();
    @memcpy(output[0..output_size], impl.output_buf[0..output_size]);
    return output_size;
}

test "CommonMark variant leaves GFM constructs inert" {
    const input = "- [ ] foo\n\n| a |\n| - |\n| b |\n\n~~gone~~\n";
    var output: [1024]u8 = undefined;
    const size = impl.renderMarkdown(input, &output);
    try @import("std").testing.expectEqualStrings(
        "<ul>\n" ++
            "<li>[ ] foo</li>\n" ++
            "</ul>\n" ++
            "<p>| a |\n" ++
            "| - |\n" ++
            "| b |</p>\n" ++
            "<p>~~gone~~</p>\n",
        output[0..size],
    );
}
