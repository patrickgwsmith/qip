// Content Compliance oracle for decimal RGB text to lowercase hexadecimal.
//
// The fixtures are independent of the WebAssembly-text implementation. They
// cover channel boundaries, both accepted syntaxes, whitespace and casing,
// and malformed inputs. This component represents invalid input as a
// successful empty output rather than a rejected result.
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
    // Accepted forms.
    .{ .input = "0,0,0", .expected = "#000000" },
    .{ .input = "255,255,255", .expected = "#ffffff" },
    .{ .input = "255,0,170", .expected = "#ff00aa" },
    .{ .input = "rgb(101, 79, 240)", .expected = "#654ff0" },
    .{ .input = " RGB ( 1 , 2 , 3 ) ", .expected = "#010203" },
    .{ .input = "\t12,\n34,\r56\x0c", .expected = "#0c2238" },
    .{ .input = "000,015,255", .expected = "#000fff" },
    .{ .input = " 255 , 128 , 0 ", .expected = "#ff8000" },
    .{ .input = "rgb(255,0,170)", .expected = "#ff00aa" },
    .{ .input = "rGb(16, 32, 64)", .expected = "#102040" },

    // Invalid forms render an empty result.
    .{ .input = "", .expected = "" },
    .{ .input = "   ", .expected = "" },
    .{ .input = "1 2,3", .expected = "" },
    .{ .input = "1,2", .expected = "" },
    .{ .input = "1,2,3,4", .expected = "" },
    .{ .input = "1,,2,3", .expected = "" },
    .{ .input = "1,2,,3", .expected = "" },
    .{ .input = "256,0,0", .expected = "" },
    .{ .input = "4294967296,0,0", .expected = "" },
    .{ .input = "-1,0,0", .expected = "" },
    .{ .input = "rgb(1,2,3", .expected = "" },
    .{ .input = "rgba(1,2,3)", .expected = "" },
    .{ .input = "1,2,3x", .expected = "" },
    .{ .input = "rgb 1,2,3", .expected = "" },
    .{ .input = ",1,2", .expected = "" },
    .{ .input = "1,,2", .expected = "" },
    .{ .input = "1,2,", .expected = "" },
};

export fn comply() i32 {
    for (cases, 0..) |case, ordinal| {
        _ = must_render_exactly(
            @intCast(ordinal),
            @intCast(@intFromPtr(case.input.ptr)),
            @intCast(case.input.len),
            @intCast(@intFromPtr(case.expected.ptr)),
            @intCast(case.expected.len),
        );
    }
    return @intCast(cases.len);
}
