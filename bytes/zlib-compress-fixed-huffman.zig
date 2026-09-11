const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
// A fixed-Huffman literal costs at most 9 bits. A match costs at most 31 bits
// and consumes at least 3 input bytes. Matches have the higher cost per input
// byte, so the maximum uses as many three-byte matches as possible and charges
// any remainder as literals.
const MAX_LITERAL_BITS: usize = 9;
const MAX_MATCH_BITS: usize = 31;
const MAX_TOKEN_BITS: usize =
    (INPUT_CAP / MIN_MATCH) * MAX_MATCH_BITS + (INPUT_CAP % MIN_MATCH) * MAX_LITERAL_BITS;
const BLOCK_OVERHEAD_BITS: usize = 3 + 7;
const ZLIB_WRAPPER_BYTES: usize = 2 + 4;
const OUTPUT_CAP: usize = ZLIB_WRAPPER_BYTES +
    (MAX_TOKEN_BITS + BLOCK_OVERHEAD_BITS + 7) / 8;

const WINDOW_SIZE: usize = 32 * 1024;
const HASH_BITS = 15;
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_MASK: usize = HASH_SIZE - 1;

const MIN_MATCH: usize = 3;
const MAX_MATCH: usize = 258;
const MAX_CHAIN: usize = 64;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

// Hash chain tables for LZ77 (32 KiB sliding window).
var head: [HASH_SIZE]i32 = undefined;
var prev: [WINDOW_SIZE]i32 = undefined;

const LENGTH_BASE = [_]u16{
    3,   4,   5,   6,   7,   8,  9,  10,
    11,  13,  15,  17,  19,  23, 27, 31,
    35,  43,  51,  59,  67,  83, 99, 115,
    131, 163, 195, 227, 258,
};

const LENGTH_EXTRA = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0,
};

const DIST_BASE = [_]u16{
    1,    2,    3,    4,     5,     7,     9,    13,
    17,   25,   33,   49,    65,    97,    129,  193,
    257,  385,  513,  769,   1025,  1537,  2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577,
};

const DIST_EXTRA = [_]u8{
    0,  0,  0,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  5,  6,  6,
    7,  7,  8,  8,  9,  9,  10, 10,
    11, 11, 12, 12, 13, 13,
};

const Code = struct {
    bits: u16,
    len: u5,
};

const LengthEncoding = struct {
    symbol: u16,
    extra_bits: u5,
    extra_value: u16,
};

const DistanceEncoding = struct {
    symbol: u16,
    extra_bits: u5,
    extra_value: u16,
};

const Match = struct {
    len: usize,
    dist: usize,
};

const BitWriter = struct {
    out_i: usize,
    bitbuf: u64,
    bitcount: u8,

    fn init(start: usize) BitWriter {
        return .{
            .out_i = start,
            .bitbuf = 0,
            .bitcount = 0,
        };
    }

    fn writeBits(self: *BitWriter, value: u32, nbits: u8) bool {
        if (nbits == 0) return true;

        self.bitbuf |= (@as(u64, value) << @intCast(self.bitcount));
        self.bitcount += nbits;

        while (self.bitcount >= 8) {
            if (self.out_i >= OUTPUT_CAP) return false;
            output_buf[self.out_i] = @intCast(self.bitbuf & 0xff);
            self.out_i += 1;
            self.bitbuf >>= 8;
            self.bitcount -= 8;
        }

        return true;
    }

    fn flush(self: *BitWriter) bool {
        if (self.bitcount > 0) {
            if (self.out_i >= OUTPUT_CAP) return false;
            output_buf[self.out_i] = @intCast(self.bitbuf & 0xff);
            self.out_i += 1;
            self.bitbuf = 0;
            self.bitcount = 0;
        }
        return true;
    }
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn writeU32BE(off: usize, value: u32) void {
    output_buf[off] = @intCast((value >> 24) & 0xff);
    output_buf[off + 1] = @intCast((value >> 16) & 0xff);
    output_buf[off + 2] = @intCast((value >> 8) & 0xff);
    output_buf[off + 3] = @intCast(value & 0xff);
}

fn reverseBits(code: u16, bit_len: u5) u16 {
    var in_bits = code;
    var out_bits: u16 = 0;
    var i: u5 = 0;
    while (i < bit_len) : (i += 1) {
        out_bits = (out_bits << 1) | (in_bits & 1);
        in_bits >>= 1;
    }
    return out_bits;
}

fn fixedLiteralCode(symbol: u16) Code {
    if (symbol <= 143) {
        const code = @as(u16, 0x30) + symbol;
        return .{ .bits = reverseBits(code, 8), .len = 8 };
    }
    if (symbol <= 255) {
        const code = @as(u16, 0x190) + (symbol - 144);
        return .{ .bits = reverseBits(code, 9), .len = 9 };
    }
    if (symbol <= 279) {
        const code = symbol - 256;
        return .{ .bits = reverseBits(code, 7), .len = 7 };
    }

    const code = @as(u16, 0xC0) + (symbol - 280);
    return .{ .bits = reverseBits(code, 8), .len = 8 };
}

fn fixedDistanceCode(symbol: u16) Code {
    return .{ .bits = reverseBits(symbol, 5), .len = 5 };
}

fn encodeLength(length: usize) LengthEncoding {
    var i: usize = 0;
    while (i < LENGTH_BASE.len) : (i += 1) {
        const base = LENGTH_BASE[i];
        const extra = LENGTH_EXTRA[i];
        const max_len: u16 = if (extra == 0) base else base + ((@as(u16, 1) << @intCast(extra)) - 1);
        if (length <= max_len) {
            return .{
                .symbol = @as(u16, @intCast(257 + i)),
                .extra_bits = @intCast(extra),
                .extra_value = @as(u16, @intCast(length)) - base,
            };
        }
    }

    return .{
        .symbol = 285,
        .extra_bits = 0,
        .extra_value = 0,
    };
}

fn encodeDistance(distance: usize) DistanceEncoding {
    var i: usize = 0;
    while (i < DIST_BASE.len) : (i += 1) {
        const base = DIST_BASE[i];
        const extra = DIST_EXTRA[i];
        const max_dist: u16 = if (extra == 0) base else base + ((@as(u16, 1) << @intCast(extra)) - 1);
        if (distance <= max_dist) {
            return .{
                .symbol = @as(u16, @intCast(i)),
                .extra_bits = @intCast(extra),
                .extra_value = @as(u16, @intCast(distance)) - base,
            };
        }
    }

    // Caller guarantees distance <= 32768.
    return .{
        .symbol = 29,
        .extra_bits = 13,
        .extra_value = @as(u16, @intCast(distance - 24577)),
    };
}

fn hash3(input: []const u8, pos: usize) usize {
    const v = (@as(u32, input[pos]) << 16) |
        (@as(u32, input[pos + 1]) << 8) |
        (@as(u32, input[pos + 2]));
    return @as(usize, @intCast((v *% 2654435761) >> (32 - HASH_BITS))) & HASH_MASK;
}

fn insertPosition(input: []const u8, pos: usize) void {
    if (pos + 2 >= input.len) return;

    const h = hash3(input, pos);
    const slot = pos & (WINDOW_SIZE - 1);
    prev[slot] = head[h];
    head[h] = @as(i32, @intCast(pos));
}

fn findMatch(input: []const u8, pos: usize) Match {
    if (pos + MIN_MATCH > input.len) {
        return .{ .len = 0, .dist = 0 };
    }

    const h = hash3(input, pos);
    var cand = head[h];
    var best_len: usize = 0;
    var best_dist: usize = 0;
    const max_len = @min(MAX_MATCH, input.len - pos);

    var steps: usize = 0;
    while (cand >= 0 and steps < MAX_CHAIN) : (steps += 1) {
        const cand_pos: usize = @intCast(cand);
        const dist = pos - cand_pos;

        if (dist == 0 or dist > WINDOW_SIZE) break;

        var len: usize = 0;
        while (len < max_len and input[cand_pos + len] == input[pos + len]) : (len += 1) {}

        if (len >= MIN_MATCH and len > best_len) {
            best_len = len;
            best_dist = dist;
            if (len == MAX_MATCH) break;
        }

        cand = prev[cand_pos & (WINDOW_SIZE - 1)];
    }

    return .{ .len = best_len, .dist = best_dist };
}

fn emitLiteral(writer: *BitWriter, byte: u8) bool {
    const code = fixedLiteralCode(byte);
    return writer.writeBits(code.bits, code.len);
}

fn emitMatch(writer: *BitWriter, length: usize, distance: usize) bool {
    const len_enc = encodeLength(length);
    const len_code = fixedLiteralCode(len_enc.symbol);
    if (!writer.writeBits(len_code.bits, len_code.len)) return false;
    if (!writer.writeBits(len_enc.extra_value, len_enc.extra_bits)) return false;

    const dist_enc = encodeDistance(distance);
    const dist_code = fixedDistanceCode(dist_enc.symbol);
    if (!writer.writeBits(dist_code.bits, dist_code.len)) return false;
    if (!writer.writeBits(dist_enc.extra_value, dist_enc.extra_bits)) return false;

    return true;
}

/// Writes zlib (RFC1950) with DEFLATE fixed-Huffman block(s) (RFC1951).
fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    @memset(head[0..], -1);

    // zlib header: CMF/FLG with 32KiB window and no dictionary.
    output_buf[0] = 0x78;
    output_buf[1] = 0x01;

    var writer = BitWriter.init(2);

    // Single final block using fixed Huffman codes: BFINAL=1, BTYPE=01.
    if (!writer.writeBits(0b011, 3)) @trap();

    var pos: usize = 0;
    while (pos < input_size) {
        const m = findMatch(input, pos);
        if (m.len >= MIN_MATCH) {
            if (!emitMatch(&writer, m.len, m.dist)) @trap();

            var p = pos;
            const end = pos + m.len;
            while (p < end) : (p += 1) {
                insertPosition(input, p);
            }

            pos = end;
        } else {
            if (!emitLiteral(&writer, input[pos])) @trap();
            insertPosition(input, pos);
            pos += 1;
        }
    }

    // End-of-block symbol.
    const eob = fixedLiteralCode(256);
    if (!writer.writeBits(eob.bits, eob.len)) @trap();

    if (!writer.flush()) @trap();

    if (writer.out_i + 4 > OUTPUT_CAP) @trap();
    writeU32BE(writer.out_i, std.hash.Adler32.hash(input));
    writer.out_i += 4;

    return @as(u32, @intCast(writer.out_i));
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

fn decompressZlib(compressed: []const u8, out: []u8) !usize {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    var out_writer: std.Io.Writer = .fixed(out);

    const n = try decompress.reader.streamRemaining(&out_writer);

    var trailing: [1]u8 = undefined;
    if (try in.readSliceShort(&trailing) != 0) return error.TrailingBytes;
    return n;
}

test "round trips empty input" {
    const written = renderImpl(0);
    try std.testing.expect(written > 0);

    var out: [1]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "round trips short text" {
    const plain = "qip + wasm";
    @memcpy(input_buf[0..plain.len], plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [64]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualStrings(plain, out[0..n]);
}

test "compresses repetitive data well" {
    var plain: [4096]u8 = undefined;
    for (&plain, 0..) |*b, i| {
        b.* = if ((i % 16) < 8) 'A' else 'B';
    }
    @memcpy(input_buf[0..plain.len], &plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);
    try std.testing.expect(written < plain.len / 2);

    var out: [4096]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualSlices(u8, &plain, out[0..n]);
}

test "maximum input stays within the derived output capacity" {
    @memset(input_buf[0..], 0);
    const written = renderImpl(@intCast(INPUT_CAP));
    try std.testing.expect(written > 0);
    try std.testing.expect(written <= OUTPUT_CAP);
}

test "literal and match tables obey the output bound" {
    var max_literal_bits: usize = 0;
    for (0..256) |symbol| {
        max_literal_bits = @max(max_literal_bits, fixedLiteralCode(@intCast(symbol)).len);
    }

    var max_length_bits: usize = 0;
    for (LENGTH_EXTRA, 0..) |extra, i| {
        const code = fixedLiteralCode(@intCast(257 + i));
        max_length_bits = @max(max_length_bits, @as(usize, code.len) + extra);
    }

    var max_distance_bits: usize = 0;
    for (DIST_EXTRA) |extra| {
        max_distance_bits = @max(max_distance_bits, 5 + @as(usize, extra));
    }

    try std.testing.expect(max_literal_bits <= MAX_LITERAL_BITS);
    try std.testing.expect(max_length_bits + max_distance_bits <= MAX_MATCH_BITS);
}
