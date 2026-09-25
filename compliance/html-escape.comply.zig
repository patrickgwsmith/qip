// Exact HTML text escaping cases. Expected bytes are independent of the
// implementation's escape table and cover both unchanged runs and boundaries.
extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

const Case = struct { input: []const u8, expected: []const u8 };

const cases = [_]Case{
    .{ .input = "", .expected = "" },
    .{ .input = "plain UTF-8 café 😀", .expected = "plain UTF-8 café 😀" },
    .{ .input = "&", .expected = "&amp;" },
    .{ .input = "<", .expected = "&lt;" },
    .{ .input = ">", .expected = "&gt;" },
    .{ .input = "\"", .expected = "&quot;" },
    .{ .input = "'", .expected = "&#39;" },
    .{ .input = "<&>\"'", .expected = "&lt;&amp;&gt;&quot;&#39;" },
    .{ .input = "before <tag> after", .expected = "before &lt;tag&gt; after" },
    .{ .input = "Tom & \"QIP\"", .expected = "Tom &amp; &quot;QIP&quot;" },
    .{ .input = "&amp;", .expected = "&amp;amp;" },
    .{ .input = "a\x00b\n\tc", .expected = "a\x00b\n\tc" },
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
