const std = @import("std");

pub const MAX_PIXELS: usize = 25_000_000;
pub const MAX_DIMENSION: usize = 8192;
pub const HEADER_SIZE: usize = 224;
pub const MAX_FILE_SIZE: usize = HEADER_SIZE + MAX_PIXELS * 4;
pub const CONTENT_TYPE = "image/ktx2";

pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    top_down: bool,
};

const IDENTIFIER = [_]u8{ 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };
const DFD = [_]u8{
    // Khronos basic descriptor for VK_FORMAT_B8G8R8A8_SRGB. This matches
    // createDFDUnpacked(0, 4, 1, 1, s_SRGB) in Khronos' dfdutils.
    0x5C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x58, 0x00, 0x01, 0x01, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    // B at byte 0.
    0x00, 0x00, 0x07, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
    // G at byte 1.
    0x08, 0x00, 0x07, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
    // R at byte 2.
    0x10, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
    // Straight alpha at byte 3. The linear qualifier is required because the
    // RGB transfer function is sRGB but alpha remains a linear UNORM value.
    0x18, 0x00, 0x07, 0x1F,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
};
const KVD = [_]u8{
    0x12, 0x00, 0x00, 0x00,
    'K',  'T',  'X',  'o',
    'r',  'i',  'e',  'n',
    't',  'a',  't',  'i',
    'o',  'n',  0x00, 'r',
    'd',  0x00, 0x00, 0x00,
};
const ORIENTATION_KEY = "KTXorientation";
const ByteRange = struct { offset: usize, end: usize };

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, data[offset..][0..8], .little);
}

fn writeU32(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .little);
}

fn writeU64(data: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, data[offset..][0..8], value, .little);
}

fn checkedPixelBytes(width: usize, height: usize) ?usize {
    if (width == 0 or height == 0 or width > MAX_DIMENSION or height > MAX_DIMENSION) return null;
    const count = std.math.mul(usize, width, height) catch return null;
    if (count > MAX_PIXELS) return null;
    return std.math.mul(usize, count, 4) catch return null;
}

fn checkedRange(data_len: usize, offset_u64: u64, length_u64: u64) ?ByteRange {
    const offset = std.math.cast(usize, offset_u64) orelse return null;
    const length = std.math.cast(usize, length_u64) orelse return null;
    const end = std.math.add(usize, offset, length) catch return null;
    if (end > data_len) return null;
    return .{ .offset = offset, .end = end };
}

pub fn fileSize(width: usize, height: usize) ?usize {
    const pixel_bytes = checkedPixelBytes(width, height) orelse return null;
    return std.math.add(usize, HEADER_SIZE, pixel_bytes) catch return null;
}

pub fn writeHeader(output: []u8, width: usize, height: usize) ?usize {
    const total_size = fileSize(width, height) orelse return null;
    if (output.len < total_size) return null;
    @memset(output[0..HEADER_SIZE], 0);
    @memcpy(output[0..IDENTIFIER.len], &IDENTIFIER);
    writeU32(output, 12, 50); // VK_FORMAT_B8G8R8A8_SRGB
    writeU32(output, 16, 1);
    writeU32(output, 20, @intCast(width));
    writeU32(output, 24, @intCast(height));
    writeU32(output, 36, 1);
    writeU32(output, 40, 1);
    writeU32(output, 48, 104);
    writeU32(output, 52, DFD.len);
    writeU32(output, 56, 196);
    writeU32(output, 60, KVD.len);

    const pixel_bytes = total_size - HEADER_SIZE;
    writeU64(output, 80, HEADER_SIZE);
    writeU64(output, 88, pixel_bytes);
    writeU64(output, 96, pixel_bytes);
    @memcpy(output[104 .. 104 + DFD.len], &DFD);
    @memcpy(output[196 .. 196 + KVD.len], &KVD);
    return total_size;
}

fn parseOrientation(kvd: []const u8) ?bool {
    var top_down = true; // The KTX2 specification assumes rd when absent.
    var found = false;
    var cursor: usize = 0;
    while (cursor < kvd.len) {
        if (kvd.len - cursor < 4) return null;
        const pair_size: usize = readU32(kvd, cursor);
        cursor += 4;
        if (pair_size == 0 or pair_size > kvd.len - cursor) return null;
        const pair = kvd[cursor .. cursor + pair_size];
        const key_end = std.mem.indexOfScalar(u8, pair, 0) orelse return null;
        if (std.mem.eql(u8, pair[0..key_end], ORIENTATION_KEY)) {
            if (found) return null;
            const value = pair[key_end + 1 ..];
            if (std.mem.eql(u8, value, "rd\x00")) {
                top_down = true;
            } else if (std.mem.eql(u8, value, "ru\x00")) {
                top_down = false;
            } else {
                return null;
            }
            found = true;
        }
        const padded_size = std.mem.alignForward(usize, pair_size, 4);
        if (padded_size > kvd.len - cursor) return null;
        cursor += padded_size;
    }
    return top_down;
}

pub fn parse(data: []u8) ?Image {
    if (data.len < 104 or !std.mem.eql(u8, data[0..IDENTIFIER.len], &IDENTIFIER)) return null;
    if (readU32(data, 12) != 50 or readU32(data, 16) != 1) return null;
    const width: usize = readU32(data, 20);
    const height: usize = readU32(data, 24);
    const pixel_bytes = checkedPixelBytes(width, height) orelse return null;
    if (readU32(data, 28) != 0 or readU32(data, 32) != 0 or readU32(data, 36) != 1) return null;
    if (readU32(data, 40) != 1 or readU32(data, 44) != 0) return null;
    if (readU64(data, 64) != 0 or readU64(data, 72) != 0) return null;

    const dfd_offset = readU32(data, 48);
    if (dfd_offset < 104 or dfd_offset % 4 != 0) return null;
    const dfd = checkedRange(data.len, dfd_offset, readU32(data, 52)) orelse return null;
    if (!std.mem.eql(u8, data[dfd.offset..dfd.end], &DFD)) return null;

    const kvd_offset = readU32(data, 56);
    const kvd_length = readU32(data, 60);
    var kvd_range: ?ByteRange = null;
    const top_down = if (kvd_offset == 0 and kvd_length == 0)
        true
    else blk: {
        if (kvd_offset < 104 or kvd_offset % 4 != 0 or kvd_length == 0) return null;
        const kvd = checkedRange(data.len, kvd_offset, kvd_length) orelse return null;
        if (kvd.offset < dfd.end and dfd.offset < kvd.end) return null;
        kvd_range = kvd;
        break :blk parseOrientation(data[kvd.offset..kvd.end]) orelse return null;
    };

    const level_offset = readU64(data, 80);
    if (level_offset < 104 or level_offset % 4 != 0) return null;
    if (readU64(data, 88) != pixel_bytes or readU64(data, 96) != pixel_bytes) return null;
    const level = checkedRange(data.len, level_offset, pixel_bytes) orelse return null;
    if (level.offset < dfd.end and dfd.offset < level.end) return null;
    if (kvd_range) |kvd| {
        if (level.offset < kvd.end and kvd.offset < level.end) return null;
    }
    return .{
        .width = width,
        .height = height,
        .pixels = data[level.offset..level.end],
        .top_down = top_down,
    };
}
