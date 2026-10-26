// Accepts a well-formed BCP 47 (RFC 5646) language tag unchanged. It checks
// grammar only, so unregistered subtags such as "qq-ZZ" pass; use
// bcp47-must-be-valid.wasm to also check the IANA registry.
//
// Rejection reports the offset of the first subtag, or byte, that breaks the
// grammar. A tag that ends too early reports the input length.
const bcp47 = @import("lib/bcp47.zig");

const INPUT_CAP: usize = 1024;
var input_buf: [INPUT_CAP]u8 = undefined;
var parsed: bcp47.Parsed = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

// Accepted output is the input itself.
export fn output_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

// Returns the failure offset, or null when the tag is well-formed.
fn check(input_size: u32) ?u32 {
    if (input_size > INPUT_CAP) @trap();
    const err = bcp47.parse(input_buf[0..input_size], &parsed) orelse return null;
    return err.offset;
}

export fn render(input_size: u32) RenderResult {
    if (check(input_size)) |offset| {
        return .{ .output_size_or_failure = offset, .output_ptr = 0, .failed = 1 };
    }
    return .{ .output_size_or_failure = input_size, .output_ptr = @intCast(@intFromPtr(&input_buf)), .failed = 0 };
}

const std = @import("std");

test {
    _ = bcp47;
}

fn checkText(text: []const u8) ?u32 {
    @memcpy(input_buf[0..text.len], text);
    return check(@intCast(text.len));
}

test "accepts unregistered subtags and recovers after rejection" {
    try std.testing.expectEqual(@as(?u32, null), checkText("zh-Hant-TW"));
    try std.testing.expectEqual(@as(?u32, 6), checkText("en-US-"));
    try std.testing.expectEqual(@as(?u32, null), checkText("qq-ZZ"));
}

test "maximum input of private-use subtags fits the subtag table" {
    // "x" then 511 one-letter subtags uses 1023 bytes and 512 subtags.
    input_buf[0] = 'x';
    var i: usize = 1;
    while (i + 1 < INPUT_CAP) : (i += 2) {
        input_buf[i] = '-';
        input_buf[i + 1] = 'a';
    }
    try std.testing.expectEqual(@as(?u32, null), check(@intCast(i)));
}
