//! Extracts up to eight representative RGB colours from canonical RGBA8 sRGB
//! KTX2 and returns DTCG 2025.10 design tokens.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const INPUT_CAP = ktx.MAX_FILE_SIZE;
const OUTPUT_CAP: usize = 4096;
const BUCKETS: usize = 32 * 32 * 32;
const MAX_COLORS: usize = 8;
const INPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const OUTPUT_CONTENT_TYPE = "application/design-tokens+json";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var counts: [BUCKETS]u32 = undefined;
var sum_r: [BUCKETS]u32 = undefined;
var sum_g: [BUCKETS]u32 = undefined;
var sum_b: [BUCKETS]u32 = undefined;

const Color = struct { bucket: usize, count: u32 };

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn bucketIndex(r: u8, g: u8, b: u8) usize {
    return (@as(usize, r >> 3) << 10) | (@as(usize, g >> 3) << 5) | @as(usize, b >> 3);
}

fn append(out: *usize, bytes: []const u8) !void {
    if (out.* + bytes.len > OUTPUT_CAP) return error.OutputOverflow;
    @memcpy(output_buf[out.* .. out.* + bytes.len], bytes);
    out.* += bytes.len;
}

fn appendByte(out: *usize, byte: u8) !void {
    if (out.* == OUTPUT_CAP) return error.OutputOverflow;
    output_buf[out.*] = byte;
    out.* += 1;
}

fn appendUInt(out: *usize, value: u64) !void {
    var buf: [20]u8 = undefined;
    try append(out, try std.fmt.bufPrint(&buf, "{d}", .{value}));
}

fn appendPercent(out: *usize, count: u32, total: u64) !void {
    const hundredths = (@as(u64, count) * 10_000 + total / 2) / total;
    try appendUInt(out, hundredths / 100);
    try appendByte(out, '.');
    if (hundredths % 100 < 10) try appendByte(out, '0');
    try appendUInt(out, hundredths % 100);
}

fn appendSrgbComponent(out: *usize, value: u8) !void {
    if (value == 0) return appendByte(out, '0');
    if (value == 255) return appendByte(out, '1');

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
    try append(out, "0.");
    try append(out, digits[0..end]);
}

fn appendHexByte(out: *usize, value: u8) !void {
    const hex = "0123456789abcdef";
    try appendByte(out, hex[value >> 4]);
    try appendByte(out, hex[value & 0x0f]);
}

fn insertTop(top: []Color, candidate: Color) void {
    if (candidate.count == 0) return;
    var position: usize = 0;
    while (position < top.len and top[position].count >= candidate.count) : (position += 1) {}
    if (position == top.len) return;
    var index = top.len - 1;
    while (index > position) : (index -= 1) top[index] = top[index - 1];
    top[position] = candidate;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > INPUT_CAP) @trap();
    const image = ktx.parse(input_buf[0..input_size]) orelse @trap();

    @memset(&counts, 0);
    @memset(&sum_r, 0);
    @memset(&sum_g, 0);
    @memset(&sum_b, 0);
    for (image.pixels, 0..) |_, offset| {
        if (offset % 4 != 0) continue;
        const r = image.pixels[offset];
        const g = image.pixels[offset + 1];
        const b = image.pixels[offset + 2];
        const bucket = bucketIndex(r, g, b);
        counts[bucket] += 1;
        sum_r[bucket] += r;
        sum_g[bucket] += g;
        sum_b[bucket] += b;
    }

    var top = [_]Color{.{ .bucket = 0, .count = 0 }} ** MAX_COLORS;
    for (counts, 0..) |count, bucket| insertTop(top[0..], .{ .bucket = bucket, .count = count });

    const total: u64 = @intCast(image.width * image.height);
    var out: usize = 0;
    append(&out, "{\"palette\":{\"$description\":\"Representative opaque sRGB colors extracted from the image, ordered by pixel frequency.\",") catch @trap();
    var written: usize = 0;
    for (top) |color| {
        if (color.count == 0) break;
        if (written != 0) appendByte(&out, ',') catch @trap();
        const r: u8 = @intCast((sum_r[color.bucket] + color.count / 2) / color.count);
        const g: u8 = @intCast((sum_g[color.bucket] + color.count / 2) / color.count);
        const b: u8 = @intCast((sum_b[color.bucket] + color.count / 2) / color.count);
        append(&out, "\"dominant-") catch @trap();
        appendUInt(&out, written + 1) catch @trap();
        append(&out, "\":{\"$type\":\"color\",\"$value\":{\"colorSpace\":\"srgb\",\"components\":[") catch @trap();
        appendSrgbComponent(&out, r) catch @trap();
        appendByte(&out, ',') catch @trap();
        appendSrgbComponent(&out, g) catch @trap();
        appendByte(&out, ',') catch @trap();
        appendSrgbComponent(&out, b) catch @trap();
        append(&out, "],\"hex\":\"#") catch @trap();
        appendHexByte(&out, r) catch @trap();
        appendHexByte(&out, g) catch @trap();
        appendHexByte(&out, b) catch @trap();
        append(&out, "\"},\"$extensions\":{\"dev.qip.image-palette\":{\"rank\":") catch @trap();
        appendUInt(&out, written + 1) catch @trap();
        append(&out, ",\"count\":") catch @trap();
        appendUInt(&out, color.count) catch @trap();
        append(&out, ",\"percent\":") catch @trap();
        appendPercent(&out, color.count, total) catch @trap();
        append(&out, "}}}") catch @trap();
        written += 1;
    }
    append(&out, "}}") catch @trap();
    return @intCast(out);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{ .output_size = renderImpl(input_size_in), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "reports canonical KTX2 colours" {
    const size = ktx.writeHeader(input_buf[0..], 2, 1) orelse unreachable;
    @memcpy(input_buf[ktx.HEADER_SIZE..size], &[_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 });
    const written = renderImpl(@intCast(size));
    try std.testing.expectEqualStrings("application/design-tokens+json", OUTPUT_CONTENT_TYPE);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..written], "\"components\":[1,0,0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..written], "#ff0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output_buf[0..written], "#0000ff") != null);
}

test "writes normalized sRGB components deterministically" {
    var out: usize = 0;
    try appendSrgbComponent(&out, 128);
    try std.testing.expectEqualStrings("0.50196078", output_buf[0..out]);
}
