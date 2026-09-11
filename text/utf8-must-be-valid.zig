// Accepts valid UTF-8 input unchanged and rejects malformed byte sequences.

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

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn failure_modes_per_input_offset() u32 {
    return 1;
}

fn isContinuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn isEightAscii(start: u32) bool {
    const index: usize = @intCast(start);
    const ptr: *align(1) const u64 = @ptrCast(&input_buf[index]);
    return (ptr.* & 0x8080_8080_8080_8080) == 0;
}

fn reject(offset: u32) RenderOutcome {
    return .{ .output_size_or_failure = offset, .output_ptr = 0, .failed = 1 };
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size: u32) RenderOutcome {
    if (input_size > INPUT_CAP) @trap();

    var i: u32 = 0;
    while (i < input_size) {
        const b = input_buf[i];
        if (b <= 0x7f) {
            if (i + 8 <= input_size and isEightAscii(i)) i += 8 else i += 1;
            continue;
        }

        if (b >= 0xc2 and b <= 0xdf) {
            if (i + 1 >= input_size) return reject(input_size);
            if (!isContinuation(input_buf[i + 1])) return reject(i + 1);
            i += 2;
            continue;
        }

        if (b >= 0xe0 and b <= 0xef) {
            if (i + 2 >= input_size) return reject(input_size);
            const b2 = input_buf[i + 1];
            const b3 = input_buf[i + 2];
            if (!isContinuation(b2)) return reject(i + 1);
            if (!isContinuation(b3)) return reject(i + 2);
            if (b == 0xe0 and b2 < 0xa0) return reject(i);
            if (b == 0xed and b2 >= 0xa0) return reject(i);
            i += 3;
            continue;
        }

        if (b >= 0xf0 and b <= 0xf4) {
            if (i + 3 >= input_size) return reject(input_size);
            const b2 = input_buf[i + 1];
            const b3 = input_buf[i + 2];
            const b4 = input_buf[i + 3];
            if (!isContinuation(b2)) return reject(i + 1);
            if (!isContinuation(b3)) return reject(i + 2);
            if (!isContinuation(b4)) return reject(i + 3);
            if (b == 0xf0 and b2 < 0x90) return reject(i);
            if (b == 0xf4 and b2 >= 0x90) return reject(i);
            i += 4;
            continue;
        }

        return reject(i);
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

test "accepts UTF-8 in place" {
    const input = "Hello, \xe4\xb8\x96\xe7\x95\x8c";
    @memcpy(input_buf[0..input.len], input);
    const result = renderOutcome(input.len);
    try std.testing.expectEqual(@as(u1, 0), result.failed);
    try std.testing.expectEqual(@as(u32, input.len), result.output_size_or_failure);
    try std.testing.expectEqualStrings("Hello, \xe4\xb8\x96\xe7\x95\x8c", input_buf[0..input.len]);
}

test "rejects with an offset and accepts the next render" {
    const invalid = [_]u8{ 'A', 0xc3, '(' };
    @memcpy(input_buf[0..invalid.len], &invalid);
    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, 2), rejected.output_size_or_failure);

    input_buf[0] = 'A';
    const accepted = renderOutcome(1);
    try std.testing.expectEqual(@as(u1, 0), accepted.failed);
    try std.testing.expectEqual(@as(u32, 1), accepted.output_size_or_failure);
    try std.testing.expectEqualStrings("A", input_buf[0..1]);
}

test "reports truncated input at the end" {
    const invalid = [_]u8{ 0xe2, 0x82 };
    @memcpy(input_buf[0..invalid.len], &invalid);
    const rejected = renderOutcome(invalid.len);
    try std.testing.expectEqual(@as(u1, 1), rejected.failed);
    try std.testing.expectEqual(@as(u32, invalid.len), rejected.output_size_or_failure);
}

const std = @import("std");
