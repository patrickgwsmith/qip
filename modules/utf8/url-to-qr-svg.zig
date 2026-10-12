const std = @import("std");

const INPUT_CAP: usize = 1024;
const OUTPUT_CAP: usize = 512 * 1024;
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const VERSION: usize = 1;
const SIZE: usize = VERSION * 4 + 17;
const DATA_CODEWORDS: usize = 19;
const ECC_CODEWORDS: usize = 7;
const TOTAL_CODEWORDS: usize = DATA_CODEWORDS + ECC_CODEWORDS;
const MAX_URL_BYTES: usize = 17;

const QUIET_ZONE_MODULES: usize = 4;
const MODULE_SIZE_PX: usize = 8;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

const Writer = struct {
    idx: usize = 0,

    fn writeByte(self: *Writer, out: []u8, b: u8) !void {
        if (self.idx >= out.len) return error.OutputOverflow;
        out[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, out: []u8, s: []const u8) !void {
        if (self.idx + s.len > out.len) return error.OutputOverflow;
        @memcpy(out[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn writeInt(self: *Writer, out: []u8, value: usize) !void {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.writeSlice(out, s);
    }
};

fn trimAsciiSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and std.ascii.isWhitespace(s[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn gfMul(a_in: u8, b_in: u8) u8 {
    var a = a_in;
    var b = b_in;
    var p: u16 = 0;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        if ((b & 1) != 0) p ^= a;
        const carry = (a & 0x80) != 0;
        a <<= 1;
        if (carry) a ^= 0x1D;
        b >>= 1;
    }
    return @as(u8, @intCast(p & 0xFF));
}

fn pushBits(bitbuf: []u8, bit_len: *usize, value: u32, count: usize) !void {
    if (count == 0) return;
    const end = bit_len.* + count;
    if (end > bitbuf.len) return error.DataOverflow;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const shift = count - 1 - i;
        bitbuf[bit_len.*] = @as(u8, @intCast((value >> @as(u5, @intCast(shift))) & 1));
        bit_len.* += 1;
    }
}

fn buildDataCodewords(url: []const u8, data: *[DATA_CODEWORDS]u8) !void {
    var bits: [DATA_CODEWORDS * 8]u8 = [_]u8{0} ** (DATA_CODEWORDS * 8);
    var bit_len: usize = 0;

    try pushBits(bits[0..], &bit_len, 0b0100, 4);
    try pushBits(bits[0..], &bit_len, @as(u32, @intCast(url.len)), 8);
    for (url) |b| try pushBits(bits[0..], &bit_len, b, 8);

    const capacity_bits = DATA_CODEWORDS * 8;
    const terminator_bits = @min(@as(usize, 4), capacity_bits - bit_len);
    try pushBits(bits[0..], &bit_len, 0, terminator_bits);

    const rem = bit_len % 8;
    if (rem != 0) try pushBits(bits[0..], &bit_len, 0, 8 - rem);

    @memset(data, 0);
    var i: usize = 0;
    while (i < bit_len) : (i += 1) {
        if (bits[i] == 1) {
            const byte_index = i / 8;
            const bit_index = 7 - (i % 8);
            data[byte_index] |= @as(u8, @intCast(@as(u16, 1) << @as(u4, @intCast(bit_index))));
        }
    }

    var used = bit_len / 8;
    var pad_toggle = false;
    while (used < DATA_CODEWORDS) : (used += 1) {
        data[used] = if (pad_toggle) 0x11 else 0xEC;
        pad_toggle = !pad_toggle;
    }
}

fn appendErrorCodewords(data: [DATA_CODEWORDS]u8, codewords: *[TOTAL_CODEWORDS]u8) void {
    const gen = [_]u8{ 87, 229, 146, 149, 238, 102, 21 };
    var ecc: [ECC_CODEWORDS]u8 = [_]u8{0} ** ECC_CODEWORDS;

    for (data) |d| {
        const factor = d ^ ecc[0];
        var i: usize = 0;
        while (i + 1 < ECC_CODEWORDS) : (i += 1) {
            ecc[i] = ecc[i + 1] ^ gfMul(factor, gen[i]);
        }
        ecc[ECC_CODEWORDS - 1] = gfMul(factor, gen[ECC_CODEWORDS - 1]);
    }

    @memcpy(codewords[0..DATA_CODEWORDS], data[0..]);
    @memcpy(codewords[DATA_CODEWORDS..TOTAL_CODEWORDS], ecc[0..]);
}

fn setFunction(mods: *[SIZE][SIZE]bool, is_function: *[SIZE][SIZE]bool, row: usize, col: usize, dark: bool) void {
    mods[row][col] = dark;
    is_function[row][col] = true;
}

fn drawFinder(mods: *[SIZE][SIZE]bool, is_function: *[SIZE][SIZE]bool, top: usize, left: usize) void {
    var dy: i32 = -1;
    while (dy <= 7) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 7) : (dx += 1) {
            const r_signed = @as(i32, @intCast(top)) + dy;
            const c_signed = @as(i32, @intCast(left)) + dx;
            if (r_signed < 0 or c_signed < 0 or r_signed >= SIZE or c_signed >= SIZE) continue;

            const r = @as(usize, @intCast(r_signed));
            const c = @as(usize, @intCast(c_signed));

            const adx = @abs(dx - 3);
            const ady = @abs(dy - 3);
            const dist = @max(adx, ady);
            const dark = dist == 3 or dist <= 1;
            setFunction(mods, is_function, r, c, dark);
        }
    }
}

fn reserveFormatAreas(mods: *[SIZE][SIZE]bool, is_function: *[SIZE][SIZE]bool) void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        setFunction(mods, is_function, 8, i, false);
        setFunction(mods, is_function, i, 8, false);
    }
    setFunction(mods, is_function, 8, 7, false);
    setFunction(mods, is_function, 8, 8, false);
    setFunction(mods, is_function, 7, 8, false);

    i = 0;
    while (i < 8) : (i += 1) setFunction(mods, is_function, 8, SIZE - 1 - i, false);
    i = 0;
    while (i < 7) : (i += 1) setFunction(mods, is_function, SIZE - 1 - i, 8, false);
}

fn drawFunctionPatterns(mods: *[SIZE][SIZE]bool, is_function: *[SIZE][SIZE]bool) void {
    drawFinder(mods, is_function, 0, 0);
    drawFinder(mods, is_function, 0, SIZE - 7);
    drawFinder(mods, is_function, SIZE - 7, 0);

    var i: usize = 8;
    while (i < SIZE - 8) : (i += 1) {
        const dark = (i % 2) == 0;
        setFunction(mods, is_function, 6, i, dark);
        setFunction(mods, is_function, i, 6, dark);
    }

    setFunction(mods, is_function, SIZE - 8, 8, true);
    reserveFormatAreas(mods, is_function);
}

fn placeDataBits(mods: *[SIZE][SIZE]bool, is_function: *[SIZE][SIZE]bool, codewords: [TOTAL_CODEWORDS]u8) void {
    var bit_index: usize = 0;
    var upward = true;
    var col: i32 = SIZE - 1;

    while (col > 0) : (col -= 2) {
        if (col == 6) col -= 1;

        if (upward) {
            var row: i32 = SIZE - 1;
            while (row >= 0) : (row -= 1) {
                var x: usize = 0;
                while (x < 2) : (x += 1) {
                    const c = @as(usize, @intCast(col - @as(i32, @intCast(x))));
                    const r = @as(usize, @intCast(row));
                    if (is_function[r][c]) continue;

                    var bit: u8 = 0;
                    if (bit_index < TOTAL_CODEWORDS * 8) {
                        const b = codewords[bit_index / 8];
                        bit = (b >> @as(u3, @intCast(7 - (bit_index % 8)))) & 1;
                        bit_index += 1;
                    }

                    if (((r + c) & 1) == 0) bit ^= 1;
                    mods[r][c] = bit == 1;
                }
            }
        } else {
            var row: usize = 0;
            while (row < SIZE) : (row += 1) {
                var x: usize = 0;
                while (x < 2) : (x += 1) {
                    const c = @as(usize, @intCast(col - @as(i32, @intCast(x))));
                    if (is_function[row][c]) continue;

                    var bit: u8 = 0;
                    if (bit_index < TOTAL_CODEWORDS * 8) {
                        const b = codewords[bit_index / 8];
                        bit = (b >> @as(u3, @intCast(7 - (bit_index % 8)))) & 1;
                        bit_index += 1;
                    }

                    if (((row + c) & 1) == 0) bit ^= 1;
                    mods[row][c] = bit == 1;
                }
            }
        }

        upward = !upward;
    }
}

fn getBit(bits: u16, i: usize) bool {
    return ((bits >> @as(u4, @intCast(i))) & 1) != 0;
}

fn formatBitsForMask0() u16 {
    const ecc_level_l: u16 = 1;
    const mask: u16 = 0;
    const data: u16 = (ecc_level_l << 3) | mask;

    var rem: u16 = data;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        rem <<= 1;
        if ((rem & 0x400) != 0) rem ^= 0x537;
    }

    return ((data << 10) | rem) ^ 0x5412;
}

fn drawFormatBits(mods: *[SIZE][SIZE]bool, is_function: *[SIZE][SIZE]bool) void {
    const bits = formatBitsForMask0();

    var i: usize = 0;
    while (i <= 5) : (i += 1) setFunction(mods, is_function, 8, i, getBit(bits, i));
    setFunction(mods, is_function, 8, 7, getBit(bits, 6));
    setFunction(mods, is_function, 8, 8, getBit(bits, 7));
    setFunction(mods, is_function, 7, 8, getBit(bits, 8));
    i = 9;
    while (i <= 14) : (i += 1) setFunction(mods, is_function, 14 - i, 8, getBit(bits, i));

    i = 0;
    while (i <= 7) : (i += 1) setFunction(mods, is_function, 8, SIZE - 1 - i, getBit(bits, i));
    i = 8;
    while (i <= 14) : (i += 1) setFunction(mods, is_function, SIZE - 15 + i, 8, getBit(bits, i));
}

fn renderSvg(mods: [SIZE][SIZE]bool, out: []u8) !u32 {
    const px_size = (SIZE + QUIET_ZONE_MODULES * 2) * MODULE_SIZE_PX;

    var w = Writer{};
    try w.writeSlice(out, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"");
    try w.writeInt(out, px_size);
    try w.writeSlice(out, "\" height=\"");
    try w.writeInt(out, px_size);
    try w.writeSlice(out, "\" viewBox=\"0 0 ");
    try w.writeInt(out, px_size);
    try w.writeByte(out, ' ');
    try w.writeInt(out, px_size);
    try w.writeSlice(out, "\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"#fff\"/><g fill=\"#000\">");

    var row: usize = 0;
    while (row < SIZE) : (row += 1) {
        var col: usize = 0;
        while (col < SIZE) : (col += 1) {
            if (!mods[row][col]) continue;

            const x = (col + QUIET_ZONE_MODULES) * MODULE_SIZE_PX;
            const y = (row + QUIET_ZONE_MODULES) * MODULE_SIZE_PX;

            try w.writeSlice(out, "<rect x=\"");
            try w.writeInt(out, x);
            try w.writeSlice(out, "\" y=\"");
            try w.writeInt(out, y);
            try w.writeSlice(out, "\" width=\"");
            try w.writeInt(out, MODULE_SIZE_PX);
            try w.writeSlice(out, "\" height=\"");
            try w.writeInt(out, MODULE_SIZE_PX);
            try w.writeSlice(out, "\"/>");
        }
    }

    try w.writeSlice(out, "</g></svg>");
    return @as(u32, @intCast(w.idx));
}

fn generateSvg(url_raw: []const u8, out: []u8) !u32 {
    const url = trimAsciiSpace(url_raw);
    if (url.len == 0) return error.EmptyInput;
    if (url.len > MAX_URL_BYTES) return error.InputTooLong;

    var data: [DATA_CODEWORDS]u8 = undefined;
    try buildDataCodewords(url, &data);

    var codewords: [TOTAL_CODEWORDS]u8 = undefined;
    appendErrorCodewords(data, &codewords);

    var mods: [SIZE][SIZE]bool = undefined;
    var is_function: [SIZE][SIZE]bool = undefined;

    var r: usize = 0;
    while (r < SIZE) : (r += 1) {
        @memset(mods[r][0..], false);
        @memset(is_function[r][0..], false);
    }

    drawFunctionPatterns(&mods, &is_function);
    placeDataBits(&mods, &is_function, codewords);
    drawFormatBits(&mods, &is_function);

    return renderSvg(mods, out);
}

export fn run(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    return generateSvg(input_buf[0..input_size], output_buf[0..]) catch 0;
}

test "generates svg qr for short URL" {
    const out_len = try generateSvg("https://qip.rs", output_buf[0..]);
    const out = output_buf[0..@as(usize, @intCast(out_len))];

    try std.testing.expect(out_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, out, "<svg "));
    try std.testing.expect(std.mem.indexOf(u8, out, "shape-rendering=\"crispEdges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<rect x=\"") != null);
}

test "rejects long url beyond version-1 byte capacity" {
    try std.testing.expectError(error.InputTooLong, generateSvg("https://a.co/12345", output_buf[0..]));
}
