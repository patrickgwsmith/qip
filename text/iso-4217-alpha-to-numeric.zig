// Convert an ISO 4217 three-letter alphabetic code to its three-digit ASCII
// numeric code. The table is the SIX Group List One published 2026-01-01.
// Input is strict uppercase ASCII; unknown or malformed codes trap.
const table = @import("lib/iso-4217-alpha-numeric-table.zig");

const INPUT_CAP: usize = 16;
const OUTPUT_CAP: usize = 3;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn findNumeric(alpha: u32) ?u16 {
    var lo: usize = 0;
    var hi: usize = table.entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (table.entries[mid].alpha < alpha) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= table.entries.len or table.entries[lo].alpha != alpha) return null;
    return table.entries[lo].numeric;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 3) @trap();
    const alpha = (@as(u32, input_buf[0]) << 16) |
        (@as(u32, input_buf[1]) << 8) |
        @as(u32, input_buf[2]);
    const numeric = findNumeric(alpha) orelse @trap();
    output_buf[0] = '0' + @as(u8, @intCast(numeric / 100));
    output_buf[1] = '0' + @as(u8, @intCast((numeric / 10) % 10));
    output_buf[2] = '0' + @as(u8, @intCast(numeric % 10));
    return OUTPUT_CAP;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}
