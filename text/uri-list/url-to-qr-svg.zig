const std = @import("std");

// QR encoding logic adapted from Project Nayuki's QR Code generator (MIT License):
// https://www.nayuki.io/page/qr-code-generator-library

const INPUT_CAP: usize = 256;
const OUTPUT_CAP: usize = 512 * 1024;
const INPUT_CONTENT_TYPE = "text/uri-list";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const MIN_VERSION: usize = 1;
const MAX_VERSION: usize = 40;
const ECL_MEDIUM: usize = 1;
const BYTE_MODE_INDICATOR: u32 = 0x4;
const BORDER_MODULES: usize = 4;
const TARGET_SVG_PIXELS: usize = 360;
const MIN_SCALE_PX: usize = 3;
const MAX_SCALE_PX: usize = 12;

const MAX_QR_SIZE: usize = MAX_VERSION * 4 + 17; // 177
const MAX_MODULES: usize = MAX_QR_SIZE * MAX_QR_SIZE;
const MAX_RAW_CODEWORDS: usize = 29648 / 8; // version 40 max data modules / 8
const MAX_RS_DEGREE: usize = 30;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var modules: [MAX_MODULES]u8 = [_]u8{0} ** MAX_MODULES;
var function_modules: [MAX_MODULES]u8 = [_]u8{0} ** MAX_MODULES;

// scratch for bitstream + ECC/interleave
var data_buf: [MAX_RAW_CODEWORDS]u8 = [_]u8{0} ** MAX_RAW_CODEWORDS;
var interleaved_buf: [MAX_RAW_CODEWORDS]u8 = [_]u8{0} ** MAX_RAW_CODEWORDS;
var function_tmp: [MAX_MODULES]u8 = [_]u8{0} ** MAX_MODULES;

const ECC_CODEWORDS_PER_BLOCK = [4][41]i16{
    .{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

const NUM_ERROR_CORRECTION_BLOCKS = [4][41]i16{
    .{ -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
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

const Writer = struct {
    idx: usize = 0,

    fn appendByte(self: *Writer, b: u8) !void {
        if (self.idx >= OUTPUT_CAP) return error.OutputOverflow;
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn appendSlice(self: *Writer, s: []const u8) !void {
        if (self.idx + s.len > OUTPUT_CAP) return error.OutputOverflow;
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn appendUsize(self: *Writer, v: usize) !void {
        var buf: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        try self.appendSlice(s);
    }
};

fn trimAsciiWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        const c = s[start];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            start += 1;
            continue;
        }
        break;
    }
    while (end > start) {
        const c = s[end - 1];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            end -= 1;
            continue;
        }
        break;
    }
    return s[start..end];
}

fn hasControlBytes(s: []const u8) bool {
    for (s) |b| {
        if (b < 0x20 or b == 0x7F) return true;
    }
    return false;
}

fn extractSingleUri(input: []const u8) ![]const u8 {
    var i: usize = 0;
    var found: ?[]const u8 = null;

    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') : (i += 1) {}
        var line = input[line_start..i];
        if (i < input.len and input[i] == '\n') i += 1;

        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        const trimmed = trimAsciiWhitespace(line);
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        if (found != null) return error.MultipleUris;
        found = trimmed;
    }

    return found orelse error.Empty;
}

fn moduleIndex(size: usize, x: usize, y: usize) usize {
    return y * size + x;
}

fn getModule(mat: []const u8, size: usize, x: usize, y: usize) bool {
    return mat[moduleIndex(size, x, y)] != 0;
}

fn setModule(mat: []u8, size: usize, x: usize, y: usize, dark: bool) void {
    mat[moduleIndex(size, x, y)] = if (dark) 1 else 0;
}

fn setModuleIfInBounds(mat: []u8, size: usize, x: isize, y: isize, dark: bool) void {
    if (x < 0 or y < 0) return;
    const ux = @as(usize, @intCast(x));
    const uy = @as(usize, @intCast(y));
    if (ux >= size or uy >= size) return;
    setModule(mat, size, ux, uy, dark);
}

fn fillRect(mat: []u8, size: usize, left: usize, top: usize, width: usize, height: usize, dark: bool) void {
    var dy: usize = 0;
    while (dy < height) : (dy += 1) {
        var dx: usize = 0;
        while (dx < width) : (dx += 1) {
            setModule(mat, size, left + dx, top + dy, dark);
        }
    }
}

fn getNumRawDataModules(version: usize) usize {
    var result = (16 * version + 128) * version + 64;
    if (version >= 2) {
        const num_align = version / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

fn getNumDataCodewords(version: usize, ecl: usize) usize {
    return getNumRawDataModules(version) / 8 -
        @as(usize, @intCast(ECC_CODEWORDS_PER_BLOCK[ecl][version])) *
            @as(usize, @intCast(NUM_ERROR_CORRECTION_BLOCKS[ecl][version]));
}

fn selectVersion(byte_len: usize) !usize {
    var version: usize = MIN_VERSION;
    while (version <= MAX_VERSION) : (version += 1) {
        const char_count_bits: usize = if (version <= 9) 8 else 16;
        const used_bits = 4 + char_count_bits + byte_len * 8;
        const cap_bits = getNumDataCodewords(version, ECL_MEDIUM) * 8;
        if (used_bits <= cap_bits) return version;
    }
    return error.DataTooLong;
}

fn appendBitsToData(value: u32, bit_count: usize, bit_len: *usize) void {
    var i: usize = 0;
    while (i < bit_count) : (i += 1) {
        const shift = bit_count - 1 - i;
        const bit = (value >> @as(u5, @intCast(shift))) & 1;
        const dst_bit = bit_len.*;
        if (bit != 0) {
            data_buf[dst_bit >> 3] |= @as(u8, 1) << @as(u3, @intCast(7 - (dst_bit & 7)));
        }
        bit_len.* += 1;
    }
}

fn reedSolomonMultiply(x_in: u8, y_in: u8) u8 {
    var z: u8 = 0;
    var i: isize = 7;
    while (i >= 0) : (i -= 1) {
        const carry: u16 = @as(u16, z >> 7);
        z = @as(u8, @truncate((@as(u16, z) << 1) ^ (carry * 0x11D)));
        z ^= ((y_in >> @as(u3, @intCast(i))) & 1) * x_in;
    }
    return z;
}

fn reedSolomonComputeDivisor(degree: usize, result: []u8) void {
    @memset(result[0..degree], 0);
    result[degree - 1] = 1;

    var root: u8 = 1;
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var j: usize = 0;
        while (j < degree) : (j += 1) {
            result[j] = reedSolomonMultiply(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j + 1];
        }
        root = reedSolomonMultiply(root, 0x02);
    }
}

fn reedSolomonComputeRemainder(data: []const u8, generator: []const u8, result: []u8) void {
    const degree = generator.len;
    @memset(result[0..degree], 0);

    for (data) |b| {
        const factor = b ^ result[0];

        if (degree > 1) {
            var i: usize = 0;
            while (i + 1 < degree) : (i += 1) {
                result[i] = result[i + 1];
            }
        }
        result[degree - 1] = 0;

        var j: usize = 0;
        while (j < degree) : (j += 1) {
            result[j] ^= reedSolomonMultiply(generator[j], factor);
        }
    }
}

fn addEccAndInterleave(version: usize, ecl: usize, data_len: usize, raw_codewords: usize) void {
    const num_blocks = @as(usize, @intCast(NUM_ERROR_CORRECTION_BLOCKS[ecl][version]));
    const block_ecc_len = @as(usize, @intCast(ECC_CODEWORDS_PER_BLOCK[ecl][version]));
    const num_short_blocks = num_blocks - raw_codewords % num_blocks;
    const short_block_data_len = raw_codewords / num_blocks - block_ecc_len;

    var rs_div: [MAX_RS_DEGREE]u8 = [_]u8{0} ** MAX_RS_DEGREE;
    reedSolomonComputeDivisor(block_ecc_len, rs_div[0..block_ecc_len]);

    var dat_index: usize = 0;
    var block: usize = 0;
    while (block < num_blocks) : (block += 1) {
        const dat_len = short_block_data_len + (if (block < num_short_blocks) @as(usize, 0) else @as(usize, 1));
        var ecc: [MAX_RS_DEGREE]u8 = [_]u8{0} ** MAX_RS_DEGREE;
        reedSolomonComputeRemainder(data_buf[dat_index .. dat_index + dat_len], rs_div[0..block_ecc_len], ecc[0..block_ecc_len]);

        var j: usize = 0;
        var k: usize = block;
        while (j < dat_len) : (j += 1) {
            if (j == short_block_data_len) k -= num_short_blocks;
            interleaved_buf[k] = data_buf[dat_index + j];
            k += num_blocks;
        }

        j = 0;
        k = data_len + block;
        while (j < block_ecc_len) : (j += 1) {
            interleaved_buf[k] = ecc[j];
            k += num_blocks;
        }

        dat_index += dat_len;
    }
}

fn getAlignmentPatternPositions(version: usize, out: *[7]u8) usize {
    if (version == 1) return 0;

    const num_align = version / 7 + 2;
    const step = ((version * 8 + num_align * 3 + 5) / (num_align * 4 - 4)) * 2;

    var i: isize = @as(isize, @intCast(num_align - 1));
    var pos: isize = @as(isize, @intCast(version * 4 + 10));
    while (i >= 1) : (i -= 1) {
        out[@as(usize, @intCast(i))] = @as(u8, @intCast(pos));
        pos -= @as(isize, @intCast(step));
    }
    out[0] = 6;
    return num_align;
}

fn initializeFunctionModules(version: usize, size: usize, dst: []u8) void {
    @memset(dst[0 .. size * size], 0);

    fillRect(dst, size, 6, 0, 1, size, true);
    fillRect(dst, size, 0, 6, size, 1, true);

    fillRect(dst, size, 0, 0, 9, 9, true);
    fillRect(dst, size, size - 8, 0, 8, 9, true);
    fillRect(dst, size, 0, size - 8, 9, 8, true);

    var align_pos: [7]u8 = [_]u8{0} ** 7;
    const num_align = getAlignmentPatternPositions(version, &align_pos);

    var i: usize = 0;
    while (i < num_align) : (i += 1) {
        var j: usize = 0;
        while (j < num_align) : (j += 1) {
            if ((i == 0 and j == 0) or (i == 0 and j == num_align - 1) or (i == num_align - 1 and j == 0)) continue;
            const x = @as(usize, align_pos[i]) - 2;
            const y = @as(usize, align_pos[j]) - 2;
            fillRect(dst, size, x, y, 5, 5, true);
        }
    }

    if (version >= 7) {
        fillRect(dst, size, size - 11, 0, 3, 6, true);
        fillRect(dst, size, 0, size - 11, 6, 3, true);
    }
}

fn drawLightFunctionModules(version: usize, size: usize, dst: []u8) void {
    var i: usize = 7;
    while (i < size - 7) : (i += 2) {
        setModule(dst, size, 6, i, false);
        setModule(dst, size, i, 6, false);
    }

    var dy: isize = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: isize = -4;
        while (dx <= 4) : (dx += 1) {
            const adx = if (dx < 0) -dx else dx;
            const ady = if (dy < 0) -dy else dy;
            const dist = if (adx > ady) adx else ady;
            if (dist == 2 or dist == 4) {
                setModuleIfInBounds(dst, size, 3 + dx, 3 + dy, false);
                setModuleIfInBounds(dst, size, @as(isize, @intCast(size - 4)) + dx, 3 + dy, false);
                setModuleIfInBounds(dst, size, 3 + dx, @as(isize, @intCast(size - 4)) + dy, false);
            }
        }
    }

    var align_pos: [7]u8 = [_]u8{0} ** 7;
    const num_align = getAlignmentPatternPositions(version, &align_pos);

    var a: usize = 0;
    while (a < num_align) : (a += 1) {
        var b: usize = 0;
        while (b < num_align) : (b += 1) {
            if ((a == 0 and b == 0) or (a == 0 and b == num_align - 1) or (a == num_align - 1 and b == 0)) continue;

            var ddy: isize = -1;
            while (ddy <= 1) : (ddy += 1) {
                var ddx: isize = -1;
                while (ddx <= 1) : (ddx += 1) {
                    const dark = ddx == 0 and ddy == 0;
                    setModule(
                        dst,
                        size,
                        @as(usize, align_pos[a]) + @as(usize, @intCast(ddx + 1)) - 1,
                        @as(usize, align_pos[b]) + @as(usize, @intCast(ddy + 1)) - 1,
                        dark,
                    );
                }
            }
        }
    }

    if (version >= 7) {
        var rem: usize = version;
        var t: usize = 0;
        while (t < 12) : (t += 1) {
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        }
        var bits: usize = (version << 12) | rem;

        var r: usize = 0;
        while (r < 6) : (r += 1) {
            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const k = size - 11 + c;
                const dark = (bits & 1) != 0;
                setModule(dst, size, k, r, dark);
                setModule(dst, size, r, k, dark);
                bits >>= 1;
            }
        }
    }
}

fn getBit(x: usize, i: usize) bool {
    return ((x >> @as(std.math.Log2Int(usize), @intCast(i))) & 1) != 0;
}

fn drawFormatBits(mask: usize, size: usize, dst: []u8) void {
    const ecl_format_table = [_]usize{ 1, 0, 3, 2 };
    const data = (ecl_format_table[ECL_MEDIUM] << 3) | mask;

    var rem = data;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    const bits = ((data << 10) | rem) ^ 0x5412;

    i = 0;
    while (i <= 5) : (i += 1) setModule(dst, size, 8, i, getBit(bits, i));
    setModule(dst, size, 8, 7, getBit(bits, 6));
    setModule(dst, size, 8, 8, getBit(bits, 7));
    setModule(dst, size, 7, 8, getBit(bits, 8));
    i = 9;
    while (i < 15) : (i += 1) setModule(dst, size, 14 - i, 8, getBit(bits, i));

    i = 0;
    while (i < 8) : (i += 1) setModule(dst, size, size - 1 - i, 8, getBit(bits, i));
    i = 8;
    while (i < 15) : (i += 1) setModule(dst, size, 8, size - 15 + i, getBit(bits, i));
    setModule(dst, size, 8, size - 8, true);
}

fn drawCodewords(data: []const u8, size: usize, function_mask: []const u8, dst: []u8) void {
    var bit_i: usize = 0;

    var right: isize = @as(isize, @intCast(size - 1));
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;

        var vert: usize = 0;
        while (vert < size) : (vert += 1) {
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const x = @as(usize, @intCast(right - @as(isize, @intCast(j))));
                const upward = ((@as(usize, @intCast(right + 1)) & 2) == 0);
                const y = if (upward) size - 1 - vert else vert;

                if (!getModule(function_mask, size, x, y) and bit_i < data.len * 8) {
                    const dark = (((data[bit_i >> 3] >> @as(u3, @intCast(7 - (bit_i & 7)))) & 1) != 0);
                    setModule(dst, size, x, y, dark);
                    bit_i += 1;
                }
            }
        }
    }
}

fn applyMask(mask: usize, size: usize, function_mask: []const u8, dst: []u8) void {
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) : (x += 1) {
            if (getModule(function_mask, size, x, y)) continue;

            const invert = switch (mask) {
                0 => (x + y) % 2 == 0,
                1 => y % 2 == 0,
                2 => x % 3 == 0,
                3 => (x + y) % 3 == 0,
                4 => (x / 3 + y / 2) % 2 == 0,
                5 => ((x * y) % 2 + (x * y) % 3) == 0,
                6 => (((x * y) % 2 + (x * y) % 3) % 2) == 0,
                7 => (((x + y) % 2 + (x * y) % 3) % 2) == 0,
                else => false,
            };

            if (invert) {
                const current = getModule(dst, size, x, y);
                setModule(dst, size, x, y, !current);
            }
        }
    }
}

fn finderPenaltyAddHistory(run_len: usize, run_history: *[7]usize, size: usize) void {
    var curr = run_len;
    if (run_history[0] == 0) curr += size;

    var i: usize = 6;
    while (i > 0) : (i -= 1) {
        run_history[i] = run_history[i - 1];
    }
    run_history[0] = curr;
}

fn finderPenaltyCountPatterns(run_history: *const [7]usize, size: usize) usize {
    _ = size;
    const n = run_history[1];
    const core = n > 0 and run_history[2] == n and run_history[3] == n * 3 and run_history[4] == n and run_history[5] == n;
    const a: usize = if (core and run_history[0] >= n * 4 and run_history[6] >= n) 1 else 0;
    const b: usize = if (core and run_history[6] >= n * 4 and run_history[0] >= n) 1 else 0;
    return a + b;
}

fn finderPenaltyTerminateAndCount(current_dark: bool, current_run_len: usize, run_history: *[7]usize, size: usize) usize {
    var run_len = current_run_len;
    if (current_dark) {
        finderPenaltyAddHistory(run_len, run_history, size);
        run_len = 0;
    }
    run_len += size;
    finderPenaltyAddHistory(run_len, run_history, size);
    return finderPenaltyCountPatterns(run_history, size);
}

fn getPenaltyScore(size: usize, dst: []const u8) usize {
    var result: usize = 0;

    var y: usize = 0;
    while (y < size) : (y += 1) {
        var run_color = false;
        var run_x: usize = 0;
        var run_history: [7]usize = [_]usize{0} ** 7;

        var x: usize = 0;
        while (x < size) : (x += 1) {
            const dark = getModule(dst, size, x, y);
            if (dark == run_color) {
                run_x += 1;
                if (run_x == 5) result += 3 else if (run_x > 5) result += 1;
            } else {
                finderPenaltyAddHistory(run_x, &run_history, size);
                if (!run_color) result += finderPenaltyCountPatterns(&run_history, size) * 40;
                run_color = dark;
                run_x = 1;
            }
        }
        result += finderPenaltyTerminateAndCount(run_color, run_x, &run_history, size) * 40;
    }

    var x: usize = 0;
    while (x < size) : (x += 1) {
        var run_color = false;
        var run_y: usize = 0;
        var run_history: [7]usize = [_]usize{0} ** 7;

        y = 0;
        while (y < size) : (y += 1) {
            const dark = getModule(dst, size, x, y);
            if (dark == run_color) {
                run_y += 1;
                if (run_y == 5) result += 3 else if (run_y > 5) result += 1;
            } else {
                finderPenaltyAddHistory(run_y, &run_history, size);
                if (!run_color) result += finderPenaltyCountPatterns(&run_history, size) * 40;
                run_color = dark;
                run_y = 1;
            }
        }
        result += finderPenaltyTerminateAndCount(run_color, run_y, &run_history, size) * 40;
    }

    y = 0;
    while (y + 1 < size) : (y += 1) {
        x = 0;
        while (x + 1 < size) : (x += 1) {
            const c = getModule(dst, size, x, y);
            if (c == getModule(dst, size, x + 1, y) and c == getModule(dst, size, x, y + 1) and c == getModule(dst, size, x + 1, y + 1)) {
                result += 3;
            }
        }
    }

    var dark_count: usize = 0;
    y = 0;
    while (y < size) : (y += 1) {
        x = 0;
        while (x < size) : (x += 1) {
            if (getModule(dst, size, x, y)) dark_count += 1;
        }
    }

    const total = size * size;
    const diff: i64 = @as(i64, @intCast(dark_count * 20)) - @as(i64, @intCast(total * 10));
    const abs_diff: u64 = @abs(diff);
    const total_u64: u64 = @as(u64, @intCast(total));
    const k = (abs_diff + total_u64 - 1) / total_u64 - 1;
    result += @as(usize, @intCast(k)) * 10;

    return result;
}

fn chooseScale(size: usize) usize {
    const total_modules = size + BORDER_MODULES * 2;
    var scale = TARGET_SVG_PIXELS / total_modules;
    if (scale < MIN_SCALE_PX) scale = MIN_SCALE_PX;
    if (scale > MAX_SCALE_PX) scale = MAX_SCALE_PX;
    return scale;
}

fn renderSvg(size: usize) !usize {
    const scale = chooseScale(size);
    const full_modules = size + BORDER_MODULES * 2;
    const dim_px = full_modules * scale;

    var w = Writer{};
    try w.appendSlice("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ");
    try w.appendUsize(dim_px);
    try w.appendByte(' ');
    try w.appendUsize(dim_px);
    try w.appendSlice("\" width=\"");
    try w.appendUsize(dim_px);
    try w.appendSlice("\" height=\"");
    try w.appendUsize(dim_px);
    try w.appendSlice("\" shape-rendering=\"crispEdges\">\n");
    try w.appendSlice("<rect width=\"100%\" height=\"100%\" fill=\"#fff\"/>\n");

    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) {
            if (!getModule(modules[0 .. size * size], size, x, y)) {
                x += 1;
                continue;
            }

            const start = x;
            x += 1;
            while (x < size and getModule(modules[0 .. size * size], size, x, y)) : (x += 1) {}
            const run_width = x - start;

            try w.appendSlice("<rect x=\"");
            try w.appendUsize((start + BORDER_MODULES) * scale);
            try w.appendSlice("\" y=\"");
            try w.appendUsize((y + BORDER_MODULES) * scale);
            try w.appendSlice("\" width=\"");
            try w.appendUsize(run_width * scale);
            try w.appendSlice("\" height=\"");
            try w.appendUsize(scale);
            try w.appendSlice("\" fill=\"#000\"/>\n");
        }
    }

    try w.appendSlice("</svg>");
    return w.idx;
}

fn encodeQrByteMode(payload: []const u8) !usize {
    const version = try selectVersion(payload.len);
    const size = version * 4 + 17;

    const raw_codewords = getNumRawDataModules(version) / 8;
    const data_codewords = getNumDataCodewords(version, ECL_MEDIUM);
    const data_capacity_bits = data_codewords * 8;

    @memset(data_buf[0..raw_codewords], 0);

    var bit_len: usize = 0;
    appendBitsToData(BYTE_MODE_INDICATOR, 4, &bit_len);

    if (version <= 9) {
        appendBitsToData(@as(u32, @intCast(payload.len)), 8, &bit_len);
    } else {
        appendBitsToData(@as(u32, @intCast(payload.len)), 16, &bit_len);
    }

    for (payload) |b| appendBitsToData(@as(u32, b), 8, &bit_len);

    var terminator_bits = data_capacity_bits - bit_len;
    if (terminator_bits > 4) terminator_bits = 4;
    appendBitsToData(0, terminator_bits, &bit_len);

    const pad_to_byte = (8 - (bit_len % 8)) % 8;
    appendBitsToData(0, pad_to_byte, &bit_len);

    var pad_byte: u8 = 0xEC;
    while (bit_len < data_capacity_bits) {
        appendBitsToData(pad_byte, 8, &bit_len);
        pad_byte = if (pad_byte == 0xEC) 0x11 else 0xEC;
    }

    addEccAndInterleave(version, ECL_MEDIUM, data_codewords, raw_codewords);

    initializeFunctionModules(version, size, function_modules[0 .. size * size]);
    @memcpy(modules[0 .. size * size], function_modules[0 .. size * size]);

    drawCodewords(interleaved_buf[0..raw_codewords], size, function_modules[0 .. size * size], modules[0 .. size * size]);
    drawLightFunctionModules(version, size, modules[0 .. size * size]);

    initializeFunctionModules(version, size, function_tmp[0 .. size * size]);

    var best_mask: usize = 0;
    var best_penalty: usize = std.math.maxInt(usize);
    var mask: usize = 0;
    while (mask < 8) : (mask += 1) {
        applyMask(mask, size, function_tmp[0 .. size * size], modules[0 .. size * size]);
        drawFormatBits(mask, size, modules[0 .. size * size]);
        const penalty = getPenaltyScore(size, modules[0 .. size * size]);
        if (penalty < best_penalty) {
            best_penalty = penalty;
            best_mask = mask;
        }
        applyMask(mask, size, function_tmp[0 .. size * size], modules[0 .. size * size]);
    }

    applyMask(best_mask, size, function_tmp[0 .. size * size], modules[0 .. size * size]);
    drawFormatBits(best_mask, size, modules[0 .. size * size]);

    return size;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const input = input_buf[0..input_size];

    const uri = extractSingleUri(input) catch @trap();
    if (uri.len == 0 or uri.len > INPUT_CAP) @trap();
    if (hasControlBytes(uri)) @trap();

    const size = encodeQrByteMode(uri) catch @trap();
    const out_len = renderSvg(size) catch @trap();
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

test "selectVersion handles URL-size payloads" {
    try std.testing.expectEqual(@as(usize, 1), try selectVersion(1));
    try std.testing.expectEqual(@as(usize, 2), try selectVersion(20));
    try std.testing.expect((try selectVersion(256)) <= 40);
}

test "extractSingleUri ignores comments and enforces single value" {
    const one =
        \\# example
        \\https://example.com/a
    ;
    try std.testing.expectEqualStrings("https://example.com/a", try extractSingleUri(one));

    const two =
        \\https://a.example
        \\https://b.example
    ;
    try std.testing.expectError(error.MultipleUris, extractSingleUri(two));
}

test "alignment positions known versions" {
    var buf: [7]u8 = [_]u8{0} ** 7;
    try std.testing.expectEqual(@as(usize, 2), getAlignmentPatternPositions(2, &buf));
    try std.testing.expectEqual(@as(u8, 6), buf[0]);
    try std.testing.expectEqual(@as(u8, 18), buf[1]);

    try std.testing.expectEqual(@as(usize, 3), getAlignmentPatternPositions(7, &buf));
    try std.testing.expectEqual(@as(u8, 6), buf[0]);
    try std.testing.expectEqual(@as(u8, 22), buf[1]);
    try std.testing.expectEqual(@as(u8, 38), buf[2]);
}
