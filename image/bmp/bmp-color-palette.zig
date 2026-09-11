//! Extracts up to eight representative opaque colors from an uncompressed BMP.
//! The component treats RGB channel values as sRGB and returns DTCG 2025.10
//! design tokens. It does not process BMP color profiles.

const std = @import("std");

const INPUT_CAP: usize = 24 * 1024 * 1024;
const OUTPUT_CAP: usize = 4096;
const BUCKETS: usize = 32 * 32 * 32;
const MAX_COLORS: usize = 8;
const INPUT_CONTENT_TYPE = "image/bmp";
const OUTPUT_CONTENT_TYPE = "application/design-tokens+json";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var counts: [BUCKETS]u32 = undefined;
var sum_r: [BUCKETS]u32 = undefined;
var sum_g: [BUCKETS]u32 = undefined;
var sum_b: [BUCKETS]u32 = undefined;

const BmpError = error{ InvalidBmp, OutputOverflow };

const Color = struct {
    bucket: usize,
    count: u32,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

fn readU16LE(input: []const u8, off: usize) BmpError!u16 {
    if (off + 2 > input.len) return error.InvalidBmp;
    return @as(u16, input[off]) | (@as(u16, input[off + 1]) << 8);
}

fn readU32LE(input: []const u8, off: usize) BmpError!u32 {
    if (off + 4 > input.len) return error.InvalidBmp;
    return @as(u32, input[off]) |
        (@as(u32, input[off + 1]) << 8) |
        (@as(u32, input[off + 2]) << 16) |
        (@as(u32, input[off + 3]) << 24);
}

fn readI32LE(input: []const u8, off: usize) BmpError!i32 {
    return @as(i32, @bitCast(try readU32LE(input, off)));
}

fn rowStrideBytes(width: u32, bits_per_pixel: u32) ?u32 {
    const bits_per_row: u64 = @as(u64, width) * @as(u64, bits_per_pixel);
    const dwords_per_row: u64 = (bits_per_row + 31) / 32;
    const bytes_per_row: u64 = dwords_per_row * 4;
    if (bytes_per_row > std.math.maxInt(u32)) return null;
    return @intCast(bytes_per_row);
}

fn bucketIndex(r: u8, g: u8, b: u8) usize {
    return (@as(usize, r >> 3) << 10) | (@as(usize, g >> 3) << 5) | @as(usize, b >> 3);
}

fn writeByte(out: *usize, b: u8) BmpError!void {
    if (out.* >= OUTPUT_CAP) return error.OutputOverflow;
    output_buf[out.*] = b;
    out.* += 1;
}

fn writeAll(out: *usize, s: []const u8) BmpError!void {
    if (out.* + s.len > OUTPUT_CAP) return error.OutputOverflow;
    @memcpy(output_buf[out.* .. out.* + s.len], s);
    out.* += s.len;
}

fn writeUInt(out: *usize, n: u64) BmpError!void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    try writeAll(out, s);
}

fn writePercent(out: *usize, count: u32, total: u64) BmpError!void {
    const hundredths = (@as(u64, count) * 10000 + total / 2) / total;
    try writeUInt(out, hundredths / 100);
    try writeByte(out, '.');
    const frac = hundredths % 100;
    if (frac < 10) try writeByte(out, '0');
    try writeUInt(out, frac);
}

fn writeSrgbComponent(out: *usize, value: u8) BmpError!void {
    if (value == 0) return writeByte(out, '0');
    if (value == 255) return writeByte(out, '1');

    // Eight decimal places reproduce every 8-bit channel when rounded back to
    // a byte. Do the conversion with integers so output is deterministic.
    const scale: u64 = 100_000_000;
    var fraction = (@as(u64, value) * scale + 127) / 255;
    var digits: [8]u8 = undefined;
    var i: usize = digits.len;
    while (i > 0) {
        i -= 1;
        digits[i] = @intCast('0' + fraction % 10);
        fraction /= 10;
    }
    var end = digits.len;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    try writeAll(out, "0.");
    try writeAll(out, digits[0..end]);
}

fn hexNibble(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}

fn writeHexByte(out: *usize, value: u8) BmpError!void {
    try writeByte(out, hexNibble(value >> 4));
    try writeByte(out, hexNibble(value & 0x0f));
}

fn insertTop(top: []Color, candidate: Color) void {
    if (candidate.count == 0) return;
    var pos: usize = 0;
    while (pos < top.len and top[pos].count >= candidate.count) : (pos += 1) {}
    if (pos >= top.len) return;
    var i = top.len - 1;
    while (i > pos) : (i -= 1) {
        top[i] = top[i - 1];
    }
    top[pos] = candidate;
}

fn paletteJSON(input: []const u8) BmpError!usize {
    if (input.len < 54 or input[0] != 'B' or input[1] != 'M') return error.InvalidBmp;

    const pixel_offset = try readU32LE(input, 10);
    const dib_size = try readU32LE(input, 14);
    if (dib_size < 40) return error.InvalidBmp;
    const width_i32 = try readI32LE(input, 18);
    const height_i32 = try readI32LE(input, 22);
    const planes = try readU16LE(input, 26);
    const bpp = try readU16LE(input, 28);
    const compression = try readU32LE(input, 30);

    if (planes != 1 or compression != 0) return error.InvalidBmp;
    if (!(bpp == 24 or bpp == 32)) return error.InvalidBmp;
    if (width_i32 <= 0 or height_i32 == 0 or height_i32 == std.math.minInt(i32)) return error.InvalidBmp;

    const width: u32 = @intCast(width_i32);
    const top_down = height_i32 < 0;
    const height: u32 = if (top_down) @intCast(-height_i32) else @intCast(height_i32);
    const stride = rowStrideBytes(width, bpp) orelse return error.InvalidBmp;
    const bytes_needed = @as(u64, pixel_offset) + @as(u64, stride) * @as(u64, height);
    if (bytes_needed > input.len) return error.InvalidBmp;

    @memset(&counts, 0);
    @memset(&sum_r, 0);
    @memset(&sum_g, 0);
    @memset(&sum_b, 0);

    const bytes_per_pixel: u32 = bpp / 8;
    var total: u64 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (top_down) y else height - 1 - y;
        const row_off = pixel_offset + src_y * stride;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const px = row_off + x * bytes_per_pixel;
            const b = input[@intCast(px)];
            const g = input[@intCast(px + 1)];
            const r = input[@intCast(px + 2)];
            const idx = bucketIndex(r, g, b);
            counts[idx] += 1;
            sum_r[idx] += r;
            sum_g[idx] += g;
            sum_b[idx] += b;
            total += 1;
        }
    }
    if (total == 0) return error.InvalidBmp;

    var top = [_]Color{.{ .bucket = 0, .count = 0 }} ** MAX_COLORS;
    for (counts, 0..) |count, idx| {
        insertTop(top[0..], .{ .bucket = idx, .count = count });
    }

    var out: usize = 0;
    try writeAll(&out, "{\"palette\":{\"$description\":\"Representative opaque sRGB colors extracted from the image, ordered by pixel frequency.\",");
    var written: usize = 0;
    for (top) |color| {
        if (color.count == 0) break;
        if (written > 0) try writeByte(&out, ',');
        const r: u8 = @intCast((sum_r[color.bucket] + color.count / 2) / color.count);
        const g: u8 = @intCast((sum_g[color.bucket] + color.count / 2) / color.count);
        const b: u8 = @intCast((sum_b[color.bucket] + color.count / 2) / color.count);
        try writeAll(&out, "\"dominant-");
        try writeUInt(&out, written + 1);
        try writeAll(&out, "\":{\"$type\":\"color\",\"$value\":{\"colorSpace\":\"srgb\",\"components\":[");
        try writeSrgbComponent(&out, r);
        try writeByte(&out, ',');
        try writeSrgbComponent(&out, g);
        try writeByte(&out, ',');
        try writeSrgbComponent(&out, b);
        try writeAll(&out, "],\"hex\":\"#");
        try writeHexByte(&out, r);
        try writeHexByte(&out, g);
        try writeHexByte(&out, b);
        try writeAll(&out, "\"},\"$extensions\":{\"dev.qip.image-palette\":{\"rank\":");
        try writeUInt(&out, written + 1);
        try writeAll(&out, ",\"count\":");
        try writeUInt(&out, color.count);
        try writeAll(&out, ",\"percent\":");
        try writePercent(&out, color.count, total);
        try writeAll(&out, "}}}");
        written += 1;
    }
    try writeAll(&out, "}}");
    return out;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    return @as(u32, @intCast(paletteJSON(input_buf[0..input_size]) catch @trap()));
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

test "extracts dominant colors from a tiny bmp" {
    const bmp = [_]u8{
        'B', 'M', 70, 0,   0, 0, 0,   0, 0, 0,   54, 0, 0, 0,
        40,  0,   0,  0,   2, 0, 0,   0, 2, 0,   0,  0, 1, 0,
        24,  0,   0,  0,   0, 0, 16,  0, 0, 0,   0,  0, 0, 0,
        0,   0,   0,  0,   0, 0, 0,   0, 0, 0,   0,  0, 0, 0,
        255, 0,   0,  255, 0, 0, 255, 0, 0, 255, 0,  0, 0, 0,
    };
    const len = try paletteJSON(bmp[0..]);
    try std.testing.expectEqualStrings("application/design-tokens+json", OUTPUT_CONTENT_TYPE);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..len], "\"$type\":\"color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..len], "\"colorSpace\":\"srgb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..len], "\"components\":[1,0,0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..len], "#ff0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..len], "#0000ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..len], "\"dev.qip.image-palette\"") != null);
}

test "writes normalized sRGB components deterministically" {
    var out: usize = 0;
    try writeSrgbComponent(&out, 128);
    try std.testing.expectEqualStrings("0.50196078", output_buf[0..out]);
}
