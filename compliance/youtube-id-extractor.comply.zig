// Content Compliance oracle for extracting YouTube video IDs from text.
//
// The fixtures define the supported URL forms and the exact 11-character ID
// boundary. Invalid and unrelated URLs produce an empty result. The oracle
// does not share parsing code with the implementation.
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
    .{ .input = "No video URL here.", .expected = "" },

    // Supported hosts and routes.
    .{ .input = "https://www.youtube.com/watch?v=dQw4w9WgXcQ", .expected = "dQw4w9WgXcQ" },
    .{ .input = "http://youtu.be/9bZkp7q19f0", .expected = "9bZkp7q19f0" },
    .{ .input = "youtube.com/embed/3JZ_D3ELwOQ", .expected = "3JZ_D3ELwOQ" },
    .{ .input = "m.youtube.com/shorts/L_jWHffIx5E", .expected = "L_jWHffIx5E" },
    .{ .input = "youtube.com/v/kJQP7kiw5Fk", .expected = "kJQP7kiw5Fk" },
    .{ .input = "music.youtube.com/live/Zi_XLOBDo_Y", .expected = "Zi_XLOBDo_Y" },
    .{ .input = "youtube-nocookie.com/embed/fJ9rUzIMcZQ", .expected = "fJ9rUzIMcZQ" },
    .{ .input = "WWW.YOUTUBE.COM/WATCH?V=C0DPdy98e4c", .expected = "C0DPdy98e4c" },

    // Query strings, fragments, ports, surrounding text, and multiple URLs.
    .{ .input = "youtube.com/watch?list=PL1&v=aqz-KE-bpKQ&index=2", .expected = "aqz-KE-bpKQ" },
    .{ .input = "youtube.com/watch?v=M7lc1UVf-VE#chapter", .expected = "M7lc1UVf-VE" },
    .{ .input = "https://youtube.com:65535/watch?v=jNQXAC9IVRw", .expected = "jNQXAC9IVRw" },
    .{ .input = "See (https://youtu.be/dQw4w9WgXcQ), then [youtube.com/watch?v=9bZkp7q19f0].", .expected = "dQw4w9WgXcQ\n9bZkp7q19f0" },

    // A video ID is exactly 11 ASCII letters, digits, hyphens, or underscores.
    .{ .input = "youtu.be/Az09_-Az09_", .expected = "Az09_-Az09_" },
    .{ .input = "youtu.be/too-short1", .expected = "" },
    .{ .input = "youtu.be/dQw4w9WgXcQx", .expected = "" },
    .{ .input = "youtu.be/dQw4w9WgXcQ.jpg", .expected = "" },
    .{ .input = "youtube.com/watch?v=dQw4w9WgXcQ%20junk", .expected = "" },

    // Reject lookalike hosts, unsupported routes, and invalid ports.
    .{ .input = "youtube.com.example/watch?v=dQw4w9WgXcQ", .expected = "" },
    .{ .input = "notyoutube.com/watch?v=dQw4w9WgXcQ", .expected = "" },
    .{ .input = "youtube.com/channel/dQw4w9WgXcQ", .expected = "" },
    .{ .input = "youtube.com/watch?video=dQw4w9WgXcQ", .expected = "" },
    .{ .input = "youtube.com:/watch?v=dQw4w9WgXcQ", .expected = "" },
    .{ .input = "youtube.com:not-a-port/watch?v=dQw4w9WgXcQ", .expected = "" },
    .{ .input = "youtube.com:65536/watch?v=dQw4w9WgXcQ", .expected = "" },
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
