// Content Compliance oracle for extracting HTML links and accessible names.
//
// The expected output has one link per line. Each line contains the decoded
// href, then its simplified accessible name when one exists. These cases are
// independent of the component parser.
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
    .{ .input = "No links here.", .expected = "" },
    .{ .input = "<a href=\"https://example.com/docs\">Docs</a>", .expected = "https://example.com/docs Docs\n" },
    .{ .input = "<a href=/one>One</a><a href='/two'>Two</a>", .expected = "/one One\n/two Two\n" },
    .{ .input = "<a href>Boolean</a><a href=\"\">Empty</a><a>No href</a>", .expected = "Boolean\nEmpty\n" },
    .{ .input = "<A HREF='/x'>  One\n <b>bold</b>\tword </A>", .expected = "/x One bold word\n" },
    .{ .input = "<a href='/?a=1&amp;b=2'>A &lt; B&nbsp; now</a>", .expected = "/?a=1&b=2 A < B now\n" },
    .{ .input = "<a href=/x>Image <img alt='small icon'> after<br>break</a>", .expected = "/x Image small icon after break\n" },
    .{ .input = "<a href=/x aria-label='Short &amp; clear'>Ignored text</a>", .expected = "/x Short & clear\n" },
    .{
        .input = "<span id=first>First <b>label</b></span><span id=second>Second</span><a href=/x aria-label='Fallback' aria-labelledby='second first'>Ignored</a>",
        .expected = "/x Second First label\n",
    },
    .{
        .input = "<a href=/x aria-labelledby='later'>Ignored</a><p id=later>Forward label</p>",
        .expected = "/x Forward label\n",
    },
    .{
        .input = "<img id=logo alt='QIP logo'><a href=/x aria-labelledby=logo>Ignored</a>",
        .expected = "/x QIP logo\n",
    },
    .{
        .input = "<span id=known>Known</span><a href=/x aria-labelledby='missing known absent'>Ignored</a>",
        .expected = "/x Known\n",
    },
    .{
        .input = "<span id=Name>Exact</span><span id=name>Lower</span><a href=/x aria-labelledby='name Name'>Ignored</a>",
        .expected = "/x Lower Exact\n",
    },
    .{
        .input = "<span id=dup>First</span><span id=dup>Second</span><a href=/x aria-labelledby=dup>Ignored</a>",
        .expected = "/x First\n",
    },
    .{
        .input = "<span id=nested>Outer <span>inner</span> end</span><a href=/x aria-labelledby=nested>Ignored</a>",
        .expected = "/x Outer inner end\n",
    },
    .{
        .input = "<a href=/x>Shown<script>hidden < tag</script><style>also hidden</style> end</a>",
        .expected = "/x Shown end\n",
    },
    .{
        .input = "<a href=/x>Before<!-- hidden > text -->after</a>",
        .expected = "/x Beforeafter\n",
    },
    .{ .input = "<a href=/x aria-label=Label />", .expected = "/x Label\n" },
    .{ .input = "<a href=/x>Unclosed", .expected = "/x Unclosed\n" },
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
