// Accepts ASCII input unchanged and rejects the first byte above 0x7f.

const INPUT_CAP: usize = 1024 * 1024;
var input_buf: [INPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

// Accepted output is the input itself. The host can keep using the bytes it
// wrote instead of copying them to a second component buffer.
export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
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
    if (input_size > INPUT_CAP) @trap();

    for (input_buf[0..input_size], 0..) |byte, offset| {
        if (byte > 0x7f) {
            return .{ .output_size_or_failure = @intCast(offset), .output_ptr = 0, .failed = 1 };
        }
    }

    return .{ .output_size_or_failure = input_size, .output_ptr = @intFromPtr(&input_buf), .failed = 0 };
}

export fn render(input_size: u32) RenderResult {
    const result = renderOutcome(input_size);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}

test "accepts ASCII in place" {
    const input = "QIP 123\n";
    @memcpy(input_buf[0..input.len], input);
    const result = renderOutcome(input.len);
    try std.testing.expectEqual(@as(u1, 0), result.failed);
    try std.testing.expectEqual(@as(u32, input.len), result.output_size_or_failure);
    try std.testing.expectEqualStrings("QIP 123\n", input_buf[0..input.len]);
}

test "rejects at the first non-ASCII byte and recovers" {
    const invalid = "A\xc3\xa9";
    @memcpy(input_buf[0..invalid.len], invalid);
    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, 1), rejected.output_size_or_failure);

    input_buf[0] = 'A';
    const accepted = renderOutcome(1);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, 1), accepted.output_size_or_failure);
    try std.testing.expectEqualStrings("A", input_buf[0..1]);
}

const std = @import("std");
