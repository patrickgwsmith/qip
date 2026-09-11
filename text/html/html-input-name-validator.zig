const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;

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

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn utf8Length(bytes: []const u8, i: usize) ?usize {
    const first = bytes[i];
    if (first <= 0x7f) return 1;
    if (first >= 0xc2 and first <= 0xdf and i + 1 < bytes.len and continuation(bytes[i + 1])) return 2;
    if (first == 0xe0 and i + 2 < bytes.len and bytes[i + 1] >= 0xa0 and bytes[i + 1] <= 0xbf and continuation(bytes[i + 2])) return 3;
    if (first >= 0xe1 and first <= 0xec and i + 2 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2])) return 3;
    if (first == 0xed and i + 2 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9f and continuation(bytes[i + 2])) return 3;
    if (first >= 0xee and first <= 0xef and i + 2 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2])) return 3;
    if (first == 0xf0 and i + 3 < bytes.len and bytes[i + 1] >= 0x90 and bytes[i + 1] <= 0xbf and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    if (first >= 0xf1 and first <= 0xf3 and i + 3 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    if (first == 0xf4 and i + 3 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x8f and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    return null;
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size: u32) RenderOutcome {
    const size: usize = @intCast(input_size);
    if (size > INPUT_CAP) @trap();
    const input = input_buf[0..size];

    if (size == 0) return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };

    var i: usize = 0;
    var steps: usize = 0;
    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        if (input[i] == 0) {
            return .{ .output_size_or_failure = @intCast(i), .output_ptr = 0, .failed = 1 };
        }
        i += utf8Length(input, i) orelse @trap();
    }
    if (i != input.len) @trap();
    return .{ .output_size_or_failure = @intCast(size), .output_ptr = @intFromPtr(&input_buf), .failed = 0 };
}

export fn render(input_size: u32) RenderResult {
    const result = renderOutcome(input_size);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}

test "accepted names remain in the input buffer" {
    const value = "items[0].名前 😀";
    @memcpy(input_buf[0..value.len], value);

    const accepted = renderOutcome(value.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(value.len, accepted.output_size_or_failure);
    try std.testing.expectEqualStrings(value, input_buf[0..value.len]);
}

test "NUL rejects with an offset and the instance recovers" {
    const invalid = "item\x00name";
    @memcpy(input_buf[0..invalid.len], invalid);

    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, 4), rejected.output_size_or_failure);

    const valid = "email";
    @memcpy(input_buf[0..valid.len], valid);
    const recovered = renderOutcome(valid.len);
    try std.testing.expectEqual(@as(u1, 0), recovered.failed);
    try std.testing.expectEqual(valid.len, recovered.output_size_or_failure);
    try std.testing.expectEqualStrings(valid, input_buf[0..valid.len]);
}
