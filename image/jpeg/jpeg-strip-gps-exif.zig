const std = @import("std");

const INPUT_CAP: usize = 24 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "image/jpeg";
const OUTPUT_CONTENT_TYPE = "image/jpeg";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const JpegError = error{ InvalidJpeg, OutputOverflow };

fn readU16BE(input: []const u8, pos: usize) JpegError!u16 {
    if (pos + 2 > input.len) return error.InvalidJpeg;
    return (@as(u16, input[pos]) << 8) | input[pos + 1];
}

fn readU16Endian(input: []const u8, pos: usize, little: bool) JpegError!u16 {
    if (pos + 2 > input.len) return error.InvalidJpeg;
    if (little) return @as(u16, input[pos]) | (@as(u16, input[pos + 1]) << 8);
    return (@as(u16, input[pos]) << 8) | input[pos + 1];
}

fn readU32Endian(input: []const u8, pos: usize, little: bool) JpegError!u32 {
    if (pos + 4 > input.len) return error.InvalidJpeg;
    if (little) {
        return @as(u32, input[pos]) |
            (@as(u32, input[pos + 1]) << 8) |
            (@as(u32, input[pos + 2]) << 16) |
            (@as(u32, input[pos + 3]) << 24);
    }
    return (@as(u32, input[pos]) << 24) |
        (@as(u32, input[pos + 1]) << 16) |
        (@as(u32, input[pos + 2]) << 8) |
        input[pos + 3];
}

fn writeSlice(output: []u8, out: *usize, s: []const u8) JpegError!void {
    if (out.* + s.len > output.len) return error.OutputOverflow;
    @memcpy(output[out.* .. out.* + s.len], s);
    out.* += s.len;
}

fn exifHasGps(segment_payload: []const u8) JpegError!bool {
    if (segment_payload.len < 14) return false;
    if (!std.mem.eql(u8, segment_payload[0..6], "Exif\x00\x00")) return false;
    const tiff = segment_payload[6..];
    const little = if (std.mem.eql(u8, tiff[0..2], "II"))
        true
    else if (std.mem.eql(u8, tiff[0..2], "MM"))
        false
    else
        return false;
    if (try readU16Endian(tiff, 2, little) != 42) return false;
    const ifd0_offset = try readU32Endian(tiff, 4, little);
    if (ifd0_offset > tiff.len or ifd0_offset + 2 > tiff.len) return error.InvalidJpeg;
    const ifd0 = @as(usize, @intCast(ifd0_offset));
    const count = try readU16Endian(tiff, ifd0, little);
    var entry = ifd0 + 2;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (entry + 12 > tiff.len) return error.InvalidJpeg;
        const tag = try readU16Endian(tiff, entry, little);
        if (tag == 0x8825) return true;
        entry += 12;
    }
    return false;
}

fn stripGpsExif(input: []const u8, output: []u8) JpegError!usize {
    if (input.len < 4 or input[0] != 0xff or input[1] != 0xd8) return error.InvalidJpeg;
    var pos: usize = 2;
    var out: usize = 0;
    var removed = false;
    try writeSlice(output, &out, input[0..2]);

    while (pos < input.len) {
        if (input[pos] != 0xff) return error.InvalidJpeg;
        var marker_pos = pos;
        while (marker_pos < input.len and input[marker_pos] == 0xff) marker_pos += 1;
        if (marker_pos >= input.len) return error.InvalidJpeg;
        const marker = input[marker_pos];
        pos = marker_pos + 1;

        if (marker == 0xd9) {
            try writeSlice(output, &out, input[marker_pos - 1 .. pos]);
            if (pos < input.len) try writeSlice(output, &out, input[pos..]);
            return if (removed) out else 0;
        }

        if (marker == 0xda) {
            try writeSlice(output, &out, input[marker_pos - 1 ..]);
            return if (removed) out else 0;
        }

        if ((marker >= 0xd0 and marker <= 0xd7) or marker == 0x01) {
            try writeSlice(output, &out, input[marker_pos - 1 .. pos]);
            continue;
        }

        const len = try readU16BE(input, pos);
        if (len < 2) return error.InvalidJpeg;
        const segment_end = pos + @as(usize, len);
        if (segment_end > input.len) return error.InvalidJpeg;
        const segment_start = marker_pos - 1;
        const segment = input[segment_start..segment_end];
        const payload = input[pos + 2 .. segment_end];
        if (marker == 0xe1 and try exifHasGps(payload)) {
            removed = true;
        } else {
            try writeSlice(output, &out, segment);
        }
        pos = segment_end;
    }

    return if (removed) out else 0;
}

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
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

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const stripped_size = stripGpsExif(input_buf[0..input_size], output_buf[0..]) catch @trap();
    if (stripped_size == 0) {
        return .{
            .output_size = @intCast(input_size),
            .output_ptr = @intCast(@intFromPtr(&input_buf)),
            .failed = 0,
        };
    }
    return .{
        .output_size = @intCast(stripped_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn tinyJpegWithExifGps() []const u8 {
    return &[_]u8{
        0xff, 0xd8,
        0xff, 0xe1,
        0x00, 0x22,
        'E',  'x',
        'i',  'f',
        0x00, 0x00,
        'M',  'M',
        0x00, 0x2a,
        0x00, 0x00,
        0x00, 0x08,
        0x00, 0x01,
        0x88, 0x25,
        0x00, 0x04,
        0x00, 0x00,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x1a,
        0x00, 0x00,
        0x00, 0x00,
        0xff, 0xda,
        0x00, 0x02,
        0x11, 0x22,
        0xff, 0xd9,
    };
}

test "removes exif segment with gps ifd pointer" {
    var out: [128]u8 = undefined;
    const len = try stripGpsExif(tinyJpegWithExifGps(), out[0..]);
    try std.testing.expect(len > 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xd8, 0xff, 0xda, 0x00, 0x02, 0x11, 0x22, 0xff, 0xd9 }, out[0..len]);
}

test "returns zero when unchanged" {
    var out: [128]u8 = undefined;
    const input = &[_]u8{ 0xff, 0xd8, 0xff, 0xda, 0x00, 0x02, 0xaa, 0xbb, 0xff, 0xd9 };
    try std.testing.expectEqual(@as(usize, 0), try stripGpsExif(input, out[0..]));
}
