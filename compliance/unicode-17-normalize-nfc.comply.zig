// Content Compliance oracle for Unicode 17.0.0 NFC normalization.
//
// The non-ASCII cases come from NormalizationTest-17.0.0.txt. They exercise
// canonical composition, canonical ordering, composition exclusions, Hangul,
// compatibility characters, and characters added in Unicode 17. The oracle
// contains only expected byte strings. It does not share normalization code or
// tables with the implementation.
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
    .{ .input = "ASCII text stays byte-for-byte identical.\n", .expected = "ASCII text stays byte-for-byte identical.\n" },
    .{ .input = "e\u{0301}", .expected = "\u{00E9}" },
    .{ .input = "\u{00E9}", .expected = "\u{00E9}" },

    // Specific cases from Part 0 of the Unicode normalization test suite.
    .{ .input = "\u{1E0A}\u{0323}", .expected = "\u{1E0C}\u{0307}" },
    .{ .input = "D\u{0307}\u{0323}", .expected = "\u{1E0C}\u{0307}" },
    .{ .input = "E\u{0304}\u{0300}", .expected = "\u{1E14}" },
    .{ .input = "E\u{0300}\u{0304}", .expected = "\u{00C8}\u{0304}" },
    .{
        .input = "\u{05B8}\u{05B9}\u{05B1}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}",
        .expected = "\u{05B1}\u{05B8}\u{05B9}\u{0591}\u{05C3}\u{05B0}\u{05AC}\u{059F}",
    },
    .{ .input = "\u{1100}\u{AC00}\u{11A8}", .expected = "\u{1100}\u{AC01}" },
    .{ .input = "\u{1100}\u{1161}\u{11A8}", .expected = "\u{AC01}" },
    .{ .input = "\u{1112}\u{1175}\u{11C2}", .expected = "\u{D7A3}" },

    // NFC preserves compatibility-only decompositions.
    .{ .input = "\u{00A0}", .expected = "\u{00A0}" },
    .{ .input = "\u{3304}\u{0334}", .expected = "\u{3304}\u{0334}" },
    .{ .input = "\u{FEF5}\u{0656}", .expected = "\u{FEF5}\u{0656}" },
    .{ .input = "\u{FB01}", .expected = "\u{FB01}" },

    // Canonical singleton mappings and composition exclusions.
    .{ .input = "\u{0344}", .expected = "\u{0308}\u{0301}" },
    .{ .input = "\u{2126}", .expected = "\u{03A9}" },
    .{ .input = "\u{212A}", .expected = "K" },
    .{ .input = "\u{212B}", .expected = "\u{00C5}" },
    .{ .input = "\u{1D15E}", .expected = "\u{1D157}\u{1D165}" },

    // Canonical compositions added in Unicode 17.0.0.
    .{ .input = "\u{105D2}\u{0307}", .expected = "\u{105C9}" },
    .{ .input = "\u{11382}\u{113C9}", .expected = "\u{11383}" },
    .{ .input = "\u{16D67}\u{16D67}", .expected = "\u{16D68}" },
};

export fn uniform_set_seed(_: i32) void {}

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
