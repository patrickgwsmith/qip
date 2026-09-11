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

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c;
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

    if (size == 0) return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };

    var i: usize = 0;
    while (i < size) : (i += 1) {
        if (isAsciiWhitespace(input_buf[i])) {
            return .{ .output_size_or_failure = @intCast(i), .output_ptr = 0, .failed = 1 };
        }
    }
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

test "accepted IDs remain in the input buffer" {
    const value = "main-content";
    @memcpy(input_buf[0..value.len], value);

    const accepted = renderOutcome(value.len);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(value.len, accepted.output_size_or_failure);
    try std.testing.expectEqualStrings(value, input_buf[0..value.len]);
}

test "rejection reports the whitespace offset and the instance recovers" {
    const invalid = "main content";
    @memcpy(input_buf[0..invalid.len], invalid);

    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, 4), rejected.output_size_or_failure);

    const valid = "main:content";
    @memcpy(input_buf[0..valid.len], valid);
    const recovered = renderOutcome(valid.len);
    try std.testing.expectEqual(@as(u1, 0), recovered.failed);
    try std.testing.expectEqual(valid.len, recovered.output_size_or_failure);
    try std.testing.expectEqualStrings(valid, input_buf[0..valid.len]);
}
