const std = @import("std");

const INPUT_CAP: usize = 4 * 1024 * 1024;
const OUTPUT_CAP: usize = 128;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Counts = struct {
    lines: u64,
    words: u64,
    bytes: u64,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn isWhitespaceByte(b: u8) bool {
    return b == ' ' or (b >= 0x09 and b <= 0x0D);
}

fn countWc(input: []const u8) Counts {
    var lines: u64 = 0;
    var words: u64 = 0;
    var in_word = false;

    for (input) |b| {
        if (b == '\n') lines += 1;

        if (isWhitespaceByte(b)) {
            in_word = false;
        } else if (!in_word) {
            words += 1;
            in_word = true;
        }
    }

    return .{
        .lines = lines,
        .words = words,
        .bytes = @as(u64, @intCast(input.len)),
    };
}

fn appendByte(out: []u8, index: *usize, b: u8) void {
    if (index.* >= out.len) @trap();
    out[index.*] = b;
    index.* += 1;
}

fn appendRightAlignedU64(out: []u8, index: *usize, value: u64, width: usize) void {
    var digits_rev: [20]u8 = undefined;
    var digits_len: usize = 0;
    var n = value;

    if (n == 0) {
        digits_rev[0] = '0';
        digits_len = 1;
    } else {
        while (n > 0) {
            const d: u8 = @intCast(n % 10);
            digits_rev[digits_len] = '0' + d;
            digits_len += 1;
            n /= 10;
        }
    }

    const pad = if (digits_len < width) width - digits_len else 0;
    for (0..pad) |_| appendByte(out, index, ' ');

    var i = digits_len;
    while (i > 0) {
        i -= 1;
        appendByte(out, index, digits_rev[i]);
    }
}

fn formatCounts(counts: Counts, out: []u8) usize {
    var index: usize = 0;
    appendRightAlignedU64(out, &index, counts.lines, 8);
    appendRightAlignedU64(out, &index, counts.words, 8);
    appendRightAlignedU64(out, &index, counts.bytes, 8);
    return index;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const counts = countWc(input_buf[0..input_size]);
    const out_len = formatCounts(counts, output_buf[0..]);
    return @as(u32, @intCast(out_len));
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

test "counts lines words bytes" {
    const counts = countWc("a b\n");
    try std.testing.expectEqual(@as(u64, 1), counts.lines);
    try std.testing.expectEqual(@as(u64, 2), counts.words);
    try std.testing.expectEqual(@as(u64, 4), counts.bytes);
}

test "formats wc output without filename" {
    const counts = Counts{ .lines = 1, .words = 2, .bytes = 4 };
    var out: [64]u8 = undefined;
    const len = formatCounts(counts, out[0..]);
    try std.testing.expectEqualStrings("       1       2       4", out[0..len]);
}

test "counts empty input" {
    const counts = countWc("");
    try std.testing.expectEqual(@as(u64, 0), counts.lines);
    try std.testing.expectEqual(@as(u64, 0), counts.words);
    try std.testing.expectEqual(@as(u64, 0), counts.bytes);
}
