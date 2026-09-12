// Content Compliance oracle for GitHub-style emoji shortcode replacement.
//
// These fixtures cover parsing and representative names across the lookup
// table. Unknown or malformed shortcodes remain unchanged. The oracle does not
// import the component's emoji table or lookup code.
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
    .{ .input = "Plain text stays plain.", .expected = "Plain text stays plain." },
    .{ .input = "Ship :rocket: code :sparkles:", .expected = "Ship 🚀 code ✨" },
    .{ .input = ":smile::rocket:", .expected = "😄🚀" },
    .{ .input = "::a:", .expected = ":🅰️" },
    .{ .input = ":unknown_shortcode:", .expected = ":unknown_shortcode:" },
    .{ .input = ":octocat:", .expected = ":octocat:" },
    .{ .input = ":SMILE:", .expected = ":SMILE:" },
    .{ .input = ":not.real: :two words: :unterminated", .expected = ":not.real: :two words: :unterminated" },
    .{ .input = "Unicode café :coffee:", .expected = "Unicode café ☕" },

    // Cover every first-character range in the lookup table.
    .{ .input = ":+1:", .expected = "👍" },
    .{ .input = ":-1:", .expected = "👎" },
    .{ .input = ":100:", .expected = "💯" },
    .{ .input = ":1234:", .expected = "🔢" },
    .{ .input = ":8ball:", .expected = "🎱" },
    .{ .input = ":a:", .expected = "🅰️" },
    .{ .input = ":b:", .expected = "🅱️" },
    .{ .input = ":cd:", .expected = "💿" },
    .{ .input = ":de:", .expected = "🇩🇪" },
    .{ .input = ":es:", .expected = "🇪🇸" },
    .{ .input = ":fr:", .expected = "🇫🇷" },
    .{ .input = ":gb:", .expected = "🇬🇧" },
    .{ .input = ":hand:", .expected = "✋" },
    .{ .input = ":id:", .expected = "🆔" },
    .{ .input = ":jp:", .expected = "🇯🇵" },
    .{ .input = ":kr:", .expected = "🇰🇷" },
    .{ .input = ":leo:", .expected = "♌" },
    .{ .input = ":m:", .expected = "Ⓜ️" },
    .{ .input = ":ng:", .expected = "🆖" },
    .{ .input = ":o:", .expected = "⭕" },
    .{ .input = ":pig:", .expected = "🐷" },
    .{ .input = ":question:", .expected = "❓" },
    .{ .input = ":ru:", .expected = "🇷🇺" },
    .{ .input = ":sa:", .expected = "🈂️" },
    .{ .input = ":tm:", .expected = "™️" },
    .{ .input = ":uk:", .expected = "🇬🇧" },
    .{ .input = ":v:", .expected = "✌️" },
    .{ .input = ":wc:", .expected = "🚾" },
    .{ .input = ":x:", .expected = "❌" },
    .{ .input = ":yen:", .expected = "💴" },
    .{ .input = ":zap:", .expected = "⚡" },
    .{ .input = ":zero:", .expected = "0️⃣" },
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
