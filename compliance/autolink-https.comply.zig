// Content Compliance oracle for adding links to HTTPS URLs in HTML text.
//
// The component links visible text only. It preserves URLs in markup,
// comments, anchors, literal elements, scripts, and styles. The oracle does
// not share HTML scanning or URL-boundary code with the implementation.
extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

const Case = struct {
    input: []const u8,
    expected: []const u8,
};

const cases = [_]Case{
    .{ .input = "", .expected = "" },
    .{ .input = "No link here.", .expected = "No link here." },
    .{ .input = "http://example.com", .expected = "http://example.com" },
    .{ .input = "https://example.com", .expected = "<a href=\"https://example.com\">https://example.com</a>" },
    .{ .input = "HTTPS://example.com/path", .expected = "<a href=\"HTTPS://example.com/path\">HTTPS://example.com/path</a>" },
    .{
        .input = "<p>See https://example.com/path).</p>",
        .expected = "<p>See <a href=\"https://example.com/path\">https://example.com/path</a>).</p>",
    },
    .{
        .input = "https://example.com/a_(b).",
        .expected = "<a href=\"https://example.com/a_(b)\">https://example.com/a_(b)</a>.",
    },
    .{
        .input = "[https://example.com/a_[b]]",
        .expected = "[<a href=\"https://example.com/a_[b]\">https://example.com/a_[b]</a>]",
    },
    .{
        .input = "https://example.com/search?a=1&b=2",
        .expected = "<a href=\"https://example.com/search?a=1&b=2\">https://example.com/search?a=1&b=2</a>",
    },
    .{
        .input = "https://example.com/search?a=1&amp;b=2",
        .expected = "<a href=\"https://example.com/search?a=1&amp;b=2\">https://example.com/search?a=1&amp;b=2</a>",
    },
    .{
        .input = "First https://one.example, then https://two.example!",
        .expected = "First <a href=\"https://one.example\">https://one.example</a>, then <a href=\"https://two.example\">https://two.example</a>!",
    },
    .{ .input = "https://", .expected = "https://" },
    .{ .input = "prefixhttps://example.com", .expected = "prefixhttps://example.com" },

    // Markup and literal contexts remain byte-for-byte unchanged.
    .{
        .input = "<a href=\"https://example.com\">https://example.com</a>",
        .expected = "<a href=\"https://example.com\">https://example.com</a>",
    },
    .{
        .input = "<img alt='https://alt.example' src=\"https://src.example\">",
        .expected = "<img alt='https://alt.example' src=\"https://src.example\">",
    },
    .{
        .input = "<code>https://code.example</code><pre>https://pre.example</pre><textarea>https://text.example</textarea>",
        .expected = "<code>https://code.example</code><pre>https://pre.example</pre><textarea>https://text.example</textarea>",
    },
    .{
        .input = "<title>https://title.example</title><p>https://visible.example</p>",
        .expected = "<title>https://title.example</title><p><a href=\"https://visible.example\">https://visible.example</a></p>",
    },
    .{
        .input = "<script>const url = 'https://script.example';</script><style>/* https://style.example */</style>",
        .expected = "<script>const url = 'https://script.example';</script><style>/* https://style.example */</style>",
    },
    .{
        .input = "<!-- before > https://comment.example --><p>https://visible.example</p>",
        .expected = "<!-- before > https://comment.example --><p><a href=\"https://visible.example\">https://visible.example</a></p>",
    },
    .{
        .input = "<script>if (a < b) use('https://script.example');</script><p>https://visible.example</p>",
        .expected = "<script>if (a < b) use('https://script.example');</script><p><a href=\"https://visible.example\">https://visible.example</a></p>",
    },
    .{
        .input = "<p title=\"1 > 0 https://attribute.example\">https://visible.example</p>",
        .expected = "<p title=\"1 > 0 https://attribute.example\"><a href=\"https://visible.example\">https://visible.example</a></p>",
    },
};

export fn comply() i32 {
    inline for (cases, 0..) |case, ordinal| {
        _ = must_render_exactly(
            ordinal,
            @intCast(@intFromPtr(case.input.ptr)),
            @intCast(case.input.len),
            @intCast(@intFromPtr(case.expected.ptr)),
            @intCast(case.expected.len),
        );
    }
    return cases.len;
}
