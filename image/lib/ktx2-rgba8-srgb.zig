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
};

const IDENTIFIER = [_]u8{ 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };
const DFD = [_]u8{
    // Khronos basic descriptor for VK_FORMAT_R8G8B8A8_SRGB.
    0x5C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x58, 0x00, 0x01, 0x01, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    // R at byte 0.
    0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
    // G at byte 1.
    0x08, 0x00, 0x07, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
    // B at byte 2.
    0x10, 0x00, 0x07, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00,
    // Straight alpha at byte 3. Alpha remains a linear UNORM value.
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

pub fn fileSize(width: usize, height: usize) ?usize {
    const pixel_bytes = checkedPixelBytes(width, height) orelse return null;
    return std.math.add(usize, HEADER_SIZE, pixel_bytes) catch return null;
}

pub fn writeHeader(output: []u8, width: usize, height: usize) ?usize {
    const total_size = fileSize(width, height) orelse return null;
    if (output.len < total_size) return null;
    @memset(output[0..HEADER_SIZE], 0);
    @memcpy(output[0..IDENTIFIER.len], &IDENTIFIER);
    writeU32(output, 12, 43); // VK_FORMAT_R8G8B8A8_SRGB
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

pub fn parse(data: []u8) ?Image {
    if (data.len < HEADER_SIZE or !std.mem.eql(u8, data[0..IDENTIFIER.len], &IDENTIFIER)) return null;
    if (readU32(data, 12) != 43 or readU32(data, 16) != 1) return null;
    const width: usize = readU32(data, 20);
    const height: usize = readU32(data, 24);
    if (readU32(data, 28) != 0 or readU32(data, 32) != 0 or readU32(data, 36) != 1) return null;
    if (readU32(data, 40) != 1 or readU32(data, 44) != 0) return null;
    if (readU32(data, 48) != 104 or readU32(data, 52) != DFD.len) return null;
    if (readU32(data, 56) != 196 or readU32(data, 60) != KVD.len) return null;
    if (readU64(data, 64) != 0 or readU64(data, 72) != 0) return null;
    if (!std.mem.eql(u8, data[104 .. 104 + DFD.len], &DFD)) return null;
    if (!std.mem.eql(u8, data[196 .. 196 + KVD.len], &KVD)) return null;

    const expected_size = fileSize(width, height) orelse return null;
    const pixel_bytes = expected_size - HEADER_SIZE;
    if (data.len != expected_size) return null;
    if (readU64(data, 80) != HEADER_SIZE or readU64(data, 88) != pixel_bytes or readU64(data, 96) != pixel_bytes) return null;
    return .{ .width = width, .height = height, .pixels = data[HEADER_SIZE..expected_size] };
}
