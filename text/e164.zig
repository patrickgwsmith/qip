const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP + 1;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();

    // Emit '+' then append only digits.
    output_buf[0] = '+';
    var out: usize = 1;

    var i: usize = 0;
    while (i < input_size) : (i += 1) {
        const c = input_buf[i];
        if (!isDigit(c)) continue;

        output_buf[out] = c;
        out += 1;
    }

    // Inputs without digits normalize to empty output.
    if (out == 1) return 0;

    return @as(u32, @intCast(out));
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "maximum input fits after adding the plus prefix" {
    @memset(input_buf[0..], '9');

    try std.testing.expectEqual(@as(u32, OUTPUT_CAP), renderImpl(INPUT_CAP));
    try std.testing.expectEqual(@as(u8, '+'), output_buf[0]);
    try std.testing.expectEqualSlices(u8, input_buf[0..], output_buf[1..]);
}

test "input without digits produces successful empty output" {
    @memcpy(input_buf[0..3], "abc");
    try std.testing.expectEqual(@as(u32, 0), renderImpl(3));
}

const std = @import("std");
