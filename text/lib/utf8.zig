// Shared strict UTF-8 decode/encode for the unicode-17 case components.
pub const Decoded = struct {
    cp: u32,
    size: usize,
    valid: bool,
};

// Strict UTF-8 decode with Go utf8.DecodeRune acceptance: rejects overlong
// forms, surrogates, and values above U+10FFFF; an invalid sequence consumes
// exactly one byte.
pub fn decode(bytes: []const u8) Decoded {
    const b0 = bytes[0];
    if (b0 < 0x80) return .{ .cp = b0, .size = 1, .valid = true };
    if (b0 < 0xC2) return .{ .cp = 0, .size = 1, .valid = false };

    if (b0 < 0xE0) {
        if (bytes.len < 2) return .{ .cp = 0, .size = 1, .valid = false };
        const b1 = bytes[1];
        if (b1 < 0x80 or b1 > 0xBF) return .{ .cp = 0, .size = 1, .valid = false };
        return .{ .cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, b1 & 0x3F), .size = 2, .valid = true };
    }

    if (b0 < 0xF0) {
        if (bytes.len < 3) return .{ .cp = 0, .size = 1, .valid = false };
        const b1 = bytes[1];
        const lo: u8 = if (b0 == 0xE0) 0xA0 else 0x80;
        const hi: u8 = if (b0 == 0xED) 0x9F else 0xBF;
        if (b1 < lo or b1 > hi) return .{ .cp = 0, .size = 1, .valid = false };
        const b2 = bytes[2];
        if (b2 < 0x80 or b2 > 0xBF) return .{ .cp = 0, .size = 1, .valid = false };
        const cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, b1 & 0x3F) << 6) | @as(u32, b2 & 0x3F);
        return .{ .cp = cp, .size = 3, .valid = true };
    }

    if (b0 < 0xF5) {
        if (bytes.len < 4) return .{ .cp = 0, .size = 1, .valid = false };
        const b1 = bytes[1];
        const lo: u8 = if (b0 == 0xF0) 0x90 else 0x80;
        const hi: u8 = if (b0 == 0xF4) 0x8F else 0xBF;
        if (b1 < lo or b1 > hi) return .{ .cp = 0, .size = 1, .valid = false };
        const b2 = bytes[2];
        if (b2 < 0x80 or b2 > 0xBF) return .{ .cp = 0, .size = 1, .valid = false };
        const b3 = bytes[3];
        if (b3 < 0x80 or b3 > 0xBF) return .{ .cp = 0, .size = 1, .valid = false };
        const cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, b1 & 0x3F) << 12) |
            (@as(u32, b2 & 0x3F) << 6) | @as(u32, b3 & 0x3F);
        return .{ .cp = cp, .size = 4, .valid = true };
    }

    return .{ .cp = 0, .size = 1, .valid = false };
}

pub fn encode(cp: u32, out: []u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}
