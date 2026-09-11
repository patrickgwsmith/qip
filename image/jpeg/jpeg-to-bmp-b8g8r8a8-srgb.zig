//! Converts baseline JPEG (SOF0/SOF1 sequential Huffman, 8-bit, grayscale or
//! YCbCr, sampling factors 1-2, restart markers) to BMP (BITMAPINFOHEADER,
//! 32-bit BGRA, bottom-up) so JPEGs can flow into every bmp-consuming
//! component.
//!
//! Dequantization, the integer IDCT, chroma upsampling, and the fixed-point
//! YCbCr conversion follow libjpeg's "islow" / "fancy upsampling" arithmetic
//! exactly, so output matches djpeg's default (smoothed) decode bit-for-bit.
//! Progressive, arithmetic-coded, 12-bit, 16-bit-quantizer, and CMYK streams
//! are rejected.

const std = @import("std");
const root = @import("root");

const OUTPUT_KTX2 = @hasDecl(root, "JPEG_OUTPUT_KTX2") and root.JPEG_OUTPUT_KTX2;
const ktx2 = if (OUTPUT_KTX2) @import("ktx2_rgba8_srgb") else struct {};

const MAX_PIXELS: usize = 25_000_000;
const MAX_DIMENSION: usize = 8192;
const INPUT_CAP: usize = 64 * 1024 * 1024;
const OUTPUT_HEADER_SIZE: usize = if (OUTPUT_KTX2) 224 else 54;
const OUTPUT_CAP: usize = MAX_PIXELS * 4 + OUTPUT_HEADER_SIZE;
// JPEG MCU padding can add up to 15 samples on both axes for 4:2:0.
const PLANE_CAP: usize = MAX_PIXELS + MAX_DIMENSION * 32 + 256;
const MAX_COMPONENTS: usize = 3;
const INPUT_CONTENT_TYPE = "image/jpeg";
const OUTPUT_CONTENT_TYPE = if (OUTPUT_KTX2) "image/ktx2" else "image/bmp";

var input_buf: [INPUT_CAP]u8 = undefined;
var plane_bufs: [MAX_COMPONENTS][PLANE_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

const JpegError = error{InvalidJpeg};

// Natural-order position for each zigzag index (jpeg_natural_order).
const ZIGZAG = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const HuffTable = struct {
    defined: bool = false,
    // Indexed by code length 1..16. max_code is -1 for unused lengths.
    max_code: [17]i32 = @splat(-1),
    // vals index = code + delta[len] for a matched code.
    delta: [17]i32 = @splat(0),
    vals: [256]u8 = @splat(0),
};

const Component = struct {
    id: u8 = 0,
    h: usize = 1,
    v: usize = 1,
    tq: usize = 0,
    dc_tbl: usize = 0,
    ac_tbl: usize = 0,
    plane_stride: usize = 0,
    dc_pred: i32 = 0,
    // Upsampling factors relative to the frame's max sampling factors, and
    // the real (non-block-padded) plane extent, i.e. libjpeg's
    // downsampled_width / downsampled_height. Set once per frame in decode().
    hs: usize = 1,
    vs: usize = 1,
    dw: usize = 0,
    dh: usize = 0,
};

// Module-level decode state, fully reset at the top of decode() so a trapped
// or failed render leaves nothing behind for the next call on the same
// instance.
var quant_tables: [4][64]u16 = undefined;
var quant_defined: [4]bool = undefined;
var dc_tables: [4]HuffTable = undefined;
var ac_tables: [4]HuffTable = undefined;
var components: [MAX_COMPONENTS]Component = undefined;

const BitReader = struct {
    data: []const u8,
    pos: usize,
    buf: u8 = 0,
    count: u4 = 0,

    fn bit(self: *BitReader) JpegError!u1 {
        if (self.count == 0) {
            if (self.pos >= self.data.len) return error.InvalidJpeg;
            const b = self.data[self.pos];
            if (b == 0xFF) {
                // 0xFF00 is a stuffed data byte; any other pair is a marker,
                // which must not appear inside an entropy-coded unit.
                if (self.pos + 1 >= self.data.len or self.data[self.pos + 1] != 0x00) {
                    return error.InvalidJpeg;
                }
                self.pos += 2;
            } else {
                self.pos += 1;
            }
            self.buf = b;
            self.count = 8;
        }
        self.count -= 1;
        return @intCast((self.buf >> @as(u3, @intCast(self.count))) & 1);
    }

    fn receive(self: *BitReader, s: u5) JpegError!i32 {
        var v: i32 = 0;
        var i: u5 = 0;
        while (i < s) : (i += 1) {
            v = (v << 1) | @as(i32, try self.bit());
        }
        return v;
    }

    // Byte-align and consume an expected restart marker.
    fn restart(self: *BitReader, expected: u8) JpegError!void {
        self.count = 0;
        var p = self.pos;
        // Skip fill bytes: any run of 0xFF before the marker code.
        while (p + 1 < self.data.len and self.data[p] == 0xFF and self.data[p + 1] == 0xFF) {
            p += 1;
        }
        if (p + 2 > self.data.len) return error.InvalidJpeg;
        if (self.data[p] != 0xFF or self.data[p + 1] != expected) return error.InvalidJpeg;
        self.pos = p + 2;
    }
};

fn extend(v: i32, s: u5) i32 {
    if (s == 0) return 0;
    const half = @as(i32, 1) << @intCast(s - 1);
    if (v < half) return v - (half << 1) + 1;
    return v;
}

fn buildHuffTable(table: *HuffTable, bits: *const [16]u8, vals: []const u8) JpegError!void {
    table.max_code = @splat(-1);
    table.delta = @splat(0);
    var code: i32 = 0;
    var k: usize = 0;
    var l: usize = 1;
    while (l <= 16) : (l += 1) {
        const n: usize = bits[l - 1];
        if (n > 0) {
            table.delta[l] = @as(i32, @intCast(k)) - code;
            code += @intCast(n);
            k += n;
            if (code > (@as(i32, 1) << @intCast(l))) return error.InvalidJpeg;
            table.max_code[l] = code - 1;
        }
        code <<= 1;
    }
    if (k != vals.len or k > 256) return error.InvalidJpeg;
    @memcpy(table.vals[0..k], vals);
    table.defined = true;
}

fn huffDecode(br: *BitReader, table: *const HuffTable) JpegError!u8 {
    var code: i32 = 0;
    var l: usize = 1;
    while (l <= 16) : (l += 1) {
        code = (code << 1) | @as(i32, try br.bit());
        if (code <= table.max_code[l]) {
            const idx = table.delta[l] + code;
            if (idx < 0 or idx > 255) return error.InvalidJpeg;
            return table.vals[@intCast(idx)];
        }
    }
    return error.InvalidJpeg;
}

// libjpeg jidctint.c "islow" constants: CONST_BITS = 13, PASS1_BITS = 2.
const FIX_0_298631336: i64 = 2446;
const FIX_0_390180644: i64 = 3196;
const FIX_0_541196100: i64 = 4433;
const FIX_0_765366865: i64 = 6270;
const FIX_0_899976223: i64 = 7373;
const FIX_1_175875602: i64 = 9633;
const FIX_1_501321110: i64 = 12299;
const FIX_1_847759065: i64 = 15137;
const FIX_1_961570560: i64 = 16069;
const FIX_2_053119869: i64 = 16819;
const FIX_2_562915447: i64 = 20995;
const FIX_3_072711026: i64 = 25172;

fn descale(x: i64, comptime n: u6) i64 {
    return (x + (@as(i64, 1) << (n - 1))) >> n;
}

fn clampSample(x: i64) u8 {
    const v = x + 128;
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

const IdctHalf = struct {
    tmp10: i64,
    tmp11: i64,
    tmp12: i64,
    tmp13: i64,
    tmp0: i64,
    tmp1: i64,
    tmp2: i64,
    tmp3: i64,
};

// One shared 1-D pass over (in0..in7); identical math to jidctint.c for both
// the column and row passes, which differ only in scaling of the results.
fn idct1d(in0: i64, in1: i64, in2: i64, in3: i64, in4: i64, in5: i64, in6: i64, in7: i64) IdctHalf {
    // Even part.
    var z1 = (in2 + in6) * FIX_0_541196100;
    const etmp2 = z1 + in6 * (-FIX_1_847759065);
    const etmp3 = z1 + in2 * FIX_0_765366865;
    const etmp0 = (in0 + in4) << 13;
    const etmp1 = (in0 - in4) << 13;
    const tmp10 = etmp0 + etmp3;
    const tmp13 = etmp0 - etmp3;
    const tmp11 = etmp1 + etmp2;
    const tmp12 = etmp1 - etmp2;

    // Odd part.
    var tmp0 = in7;
    var tmp1 = in5;
    var tmp2 = in3;
    var tmp3 = in1;
    z1 = tmp0 + tmp3;
    var z2 = tmp1 + tmp2;
    var z3 = tmp0 + tmp2;
    var z4 = tmp1 + tmp3;
    const z5 = (z3 + z4) * FIX_1_175875602;
    tmp0 *= FIX_0_298631336;
    tmp1 *= FIX_2_053119869;
    tmp2 *= FIX_3_072711026;
    tmp3 *= FIX_1_501321110;
    z1 *= -FIX_0_899976223;
    z2 *= -FIX_2_562915447;
    z3 = z3 * (-FIX_1_961570560) + z5;
    z4 = z4 * (-FIX_0_390180644) + z5;
    tmp0 += z1 + z3;
    tmp1 += z2 + z4;
    tmp2 += z2 + z3;
    tmp3 += z1 + z4;

    return .{
        .tmp10 = tmp10,
        .tmp11 = tmp11,
        .tmp12 = tmp12,
        .tmp13 = tmp13,
        .tmp0 = tmp0,
        .tmp1 = tmp1,
        .tmp2 = tmp2,
        .tmp3 = tmp3,
    };
}

// Inverse DCT of one dequantized block (natural order) into an 8x8 region of
// a sample plane. Matches libjpeg jpeg_idct_islow rounding bit-for-bit for
// in-range data.
fn idctBlock(coef: *const [64]i64, plane: []u8, offset: usize, stride: usize) void {
    var ws: [64]i64 = undefined;

    var col: usize = 0;
    while (col < 8) : (col += 1) {
        if (coef[col + 8] == 0 and coef[col + 16] == 0 and coef[col + 24] == 0 and
            coef[col + 32] == 0 and coef[col + 40] == 0 and coef[col + 48] == 0 and
            coef[col + 56] == 0)
        {
            const dcval = coef[col] << 2;
            var i: usize = 0;
            while (i < 8) : (i += 1) ws[col + i * 8] = dcval;
            continue;
        }
        const h = idct1d(
            coef[col],
            coef[col + 8],
            coef[col + 16],
            coef[col + 24],
            coef[col + 32],
            coef[col + 40],
            coef[col + 48],
            coef[col + 56],
        );
        ws[col] = descale(h.tmp10 + h.tmp3, 11);
        ws[col + 56] = descale(h.tmp10 - h.tmp3, 11);
        ws[col + 8] = descale(h.tmp11 + h.tmp2, 11);
        ws[col + 48] = descale(h.tmp11 - h.tmp2, 11);
        ws[col + 16] = descale(h.tmp12 + h.tmp1, 11);
        ws[col + 40] = descale(h.tmp12 - h.tmp1, 11);
        ws[col + 24] = descale(h.tmp13 + h.tmp0, 11);
        ws[col + 32] = descale(h.tmp13 - h.tmp0, 11);
    }

    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const r = ws[row * 8 ..][0..8];
        const dst = plane[offset + row * stride ..][0..8];
        if (r[1] == 0 and r[2] == 0 and r[3] == 0 and r[4] == 0 and
            r[5] == 0 and r[6] == 0 and r[7] == 0)
        {
            const dcval = clampSample(descale(r[0], 5));
            for (dst) |*d| d.* = dcval;
            continue;
        }
        const h = idct1d(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
        dst[0] = clampSample(descale(h.tmp10 + h.tmp3, 18));
        dst[7] = clampSample(descale(h.tmp10 - h.tmp3, 18));
        dst[1] = clampSample(descale(h.tmp11 + h.tmp2, 18));
        dst[6] = clampSample(descale(h.tmp11 - h.tmp2, 18));
        dst[2] = clampSample(descale(h.tmp12 + h.tmp1, 18));
        dst[5] = clampSample(descale(h.tmp12 - h.tmp1, 18));
        dst[3] = clampSample(descale(h.tmp13 + h.tmp0, 18));
        dst[4] = clampSample(descale(h.tmp13 - h.tmp0, 18));
    }
}

fn decodeBlock(
    br: *BitReader,
    comp: *Component,
    plane: []u8,
    offset: usize,
    stride: usize,
) JpegError!void {
    const dc_table = &dc_tables[comp.dc_tbl];
    const ac_table = &ac_tables[comp.ac_tbl];
    const qt = &quant_tables[comp.tq];

    var coef = [_]i64{0} ** 64;

    const t = try huffDecode(br, dc_table);
    if (t > 11) return error.InvalidJpeg; // Baseline 8-bit DC categories are 0..11.
    comp.dc_pred += extend(try br.receive(@intCast(t)), @intCast(t));
    coef[0] = @as(i64, comp.dc_pred) * qt[0];

    var k: usize = 1;
    while (k < 64) {
        const rs = try huffDecode(br, ac_table);
        const r: usize = rs >> 4;
        const s: u5 = @intCast(rs & 15);
        if (s == 0) {
            if (r == 15) {
                k += 16; // ZRL: sixteen zero coefficients.
                continue;
            }
            break; // EOB
        }
        if (s > 10) return error.InvalidJpeg; // Baseline 8-bit AC categories are 1..10.
        k += r;
        if (k > 63) return error.InvalidJpeg;
        coef[ZIGZAG[k]] = @as(i64, extend(try br.receive(s), s)) * qt[k];
        k += 1;
    }

    idctBlock(&coef, plane, offset, stride);
}

fn readU16BE(data: []const u8, pos: usize) JpegError!u16 {
    if (pos + 2 > data.len) return error.InvalidJpeg;
    return (@as(u16, data[pos]) << 8) | data[pos + 1];
}

// libjpeg jdsample.c "fancy" (triangle-filter) upsampling, generalized to a
// single per-pixel lookup instead of per-row output buffers.
//
// libjpeg's h2v1/h1v2/h2v2 routines special-case the first and last sample
// in each upsampled dimension (no neighbor to blend with at the edge). Each
// special case is algebraically identical to the general 3:1 blend with the
// out-of-range neighbor index clamped to the nearest in-range sample, so
// clamping the neighbor index at the plane edge reproduces libjpeg's output,
// edges included, with no separate edge branch.
fn clampPrev(k: usize) usize {
    return if (k == 0) 0 else k - 1;
}

fn clampNext(k: usize, bound: usize) usize {
    return if (k + 1 >= bound) bound - 1 else k + 1;
}

fn sampleAt(comp: *const Component, plane: []const u8, x: usize, y: usize) i32 {
    return plane[y * comp.plane_stride + @min(x, comp.dw - 1)];
}

// One dimension of triangle-filter upsampling by a factor of 2: `cur` is the
// source sample at the output position's own source index, `near` is the
// neighbor in the direction this output sample leans toward (clamped at the
// plane edge), and `first_half` selects libjpeg's two rounding constants (1
// for the sample closer to `cur`'s own position, 2 for the one closer to
// `near`).
fn blend2x(cur: i32, near: i32, first_half: bool) i32 {
    return if (first_half) @divFloor(cur * 3 + near + 1, 4) else @divFloor(cur * 3 + near + 2, 4);
}

fn upsampledSample(comp: *const Component, plane: []const u8, px: usize, py: usize) u8 {
    if (comp.hs == 1 and comp.vs == 1) {
        return @intCast(sampleAt(comp, plane, px, py));
    }
    const kx = px / comp.hs;
    const ky = py / comp.vs;
    if (comp.vs == 1) {
        // h2v1: horizontal-only triangle filter.
        const near_x = if (px % 2 == 0) clampPrev(kx) else clampNext(kx, comp.dw);
        return @intCast(blend2x(sampleAt(comp, plane, kx, ky), sampleAt(comp, plane, near_x, ky), px % 2 == 0));
    }
    if (comp.hs == 1) {
        // h1v2: vertical-only triangle filter.
        const near_y = if (py % 2 == 0) clampPrev(ky) else clampNext(ky, comp.dh);
        return @intCast(blend2x(sampleAt(comp, plane, kx, ky), sampleAt(comp, plane, kx, near_y), py % 2 == 0));
    }
    // h2v2: vertical triangle filter first (producing a column sum weighted
    // 3:1 toward the nearer row), then a horizontal triangle filter over
    // that column sum, combining to libjpeg's 9:3:3:1 corner weights.
    const near_y = if (py % 2 == 0) clampPrev(ky) else clampNext(ky, comp.dh);
    const colsum = struct {
        fn at(c: *const Component, pl: []const u8, k: usize, y0: usize, y1: usize) i32 {
            return sampleAt(c, pl, k, y0) * 3 + sampleAt(c, pl, k, y1);
        }
    }.at;
    const this_sum = colsum(comp, plane, kx, ky, near_y);
    const near_x = if (px % 2 == 0) clampPrev(kx) else clampNext(kx, comp.dw);
    const near_sum = colsum(comp, plane, near_x, ky, near_y);
    const total = if (px % 2 == 0) this_sum * 3 + near_sum + 8 else this_sum * 3 + near_sum + 7;
    return @intCast(total >> 4);
}

// libjpeg jdcolor.c fixed-point YCbCr -> RGB: SCALEBITS = 16.
fn yccToBgra(y: i32, cb: i32, cr: i32, dst: *[4]u8) void {
    const cx = cb - 128;
    const cw = cr - 128;
    const r = y + ((91881 * cw + 32768) >> 16);
    const g = y + ((-22554 * cx - 46802 * cw + 32768) >> 16);
    const b = y + ((116130 * cx + 32768) >> 16);
    dst[0] = @intCast(std.math.clamp(b, 0, 255));
    dst[1] = @intCast(std.math.clamp(g, 0, 255));
    dst[2] = @intCast(std.math.clamp(r, 0, 255));
    dst[3] = 255;
}

fn decode(input: []const u8) JpegError!usize {
    quant_defined = @splat(false);
    for (&dc_tables) |*table| table.defined = false;
    for (&ac_tables) |*table| table.defined = false;
    for (&components) |*comp| comp.* = .{};

    if (input.len < 4 or input[0] != 0xFF or input[1] != 0xD8) return error.InvalidJpeg;

    var width: usize = 0;
    var height: usize = 0;
    var ncomp: usize = 0;
    var restart_interval: usize = 0;
    var seen_sof = false;
    var scan_start: usize = 0;

    var pos: usize = 2;
    while (pos < input.len) {
        if (input[pos] != 0xFF) return error.InvalidJpeg;
        // Skip fill bytes.
        while (pos < input.len and input[pos] == 0xFF) pos += 1;
        if (pos >= input.len) return error.InvalidJpeg;
        const marker = input[pos];
        pos += 1;

        switch (marker) {
            0xC0, 0xC1 => { // SOF0 baseline / SOF1 extended sequential Huffman.
                if (seen_sof) return error.InvalidJpeg;
                const len = try readU16BE(input, pos);
                if (len < 8 or pos + len > input.len) return error.InvalidJpeg;
                const seg = input[pos + 2 .. pos + len];
                if (seg.len < 6) return error.InvalidJpeg;
                if (seg[0] != 8) return error.InvalidJpeg; // 8-bit precision only.
                height = (@as(usize, seg[1]) << 8) | seg[2];
                width = (@as(usize, seg[3]) << 8) | seg[4];
                ncomp = seg[5];
                if (width == 0 or height == 0) return error.InvalidJpeg;
                if (width > MAX_DIMENSION or height > MAX_DIMENSION or
                    width * height > MAX_PIXELS) return error.InvalidJpeg;
                if (ncomp != 1 and ncomp != 3) return error.InvalidJpeg;
                if (seg.len != 6 + ncomp * 3) return error.InvalidJpeg;
                var c: usize = 0;
                while (c < ncomp) : (c += 1) {
                    const id = seg[6 + c * 3];
                    const hv = seg[7 + c * 3];
                    const tq = seg[8 + c * 3];
                    const h: usize = hv >> 4;
                    const v: usize = hv & 15;
                    if (h < 1 or h > 2 or v < 1 or v > 2) return error.InvalidJpeg;
                    if (tq > 3) return error.InvalidJpeg;
                    components[c] = .{ .id = id, .h = h, .v = v, .tq = tq };
                }
                if (ncomp == 1) {
                    // A single-component scan is non-interleaved: data is
                    // coded as plain 8x8 blocks regardless of declared
                    // sampling factors.
                    components[0].h = 1;
                    components[0].v = 1;
                }
                seen_sof = true;
                pos += len;
            },
            0xC4 => { // DHT
                const len = try readU16BE(input, pos);
                if (len < 2 or pos + len > input.len) return error.InvalidJpeg;
                const seg = input[pos + 2 .. pos + len];
                var off: usize = 0;
                while (off < seg.len) {
                    if (off + 17 > seg.len) return error.InvalidJpeg;
                    const tc = seg[off] >> 4;
                    const th = seg[off] & 15;
                    if (tc > 1 or th > 3) return error.InvalidJpeg;
                    const bits = seg[off + 1 ..][0..16];
                    var total: usize = 0;
                    for (bits) |n| total += n;
                    if (total == 0 or total > 256) return error.InvalidJpeg;
                    if (off + 17 + total > seg.len) return error.InvalidJpeg;
                    const vals = seg[off + 17 ..][0..total];
                    const table = if (tc == 0) &dc_tables[th] else &ac_tables[th];
                    try buildHuffTable(table, bits, vals);
                    off += 17 + total;
                }
                pos += len;
            },
            0xDB => { // DQT
                const len = try readU16BE(input, pos);
                if (len < 2 or pos + len > input.len) return error.InvalidJpeg;
                const seg = input[pos + 2 .. pos + len];
                var off: usize = 0;
                while (off < seg.len) {
                    const pq = seg[off] >> 4;
                    const tq = seg[off] & 15;
                    if (pq != 0 or tq > 3) return error.InvalidJpeg; // 8-bit tables only.
                    if (off + 65 > seg.len) return error.InvalidJpeg;
                    var i: usize = 0;
                    while (i < 64) : (i += 1) {
                        const q = seg[off + 1 + i];
                        if (q == 0) return error.InvalidJpeg;
                        quant_tables[tq][i] = q; // Kept in zigzag order.
                    }
                    quant_defined[tq] = true;
                    off += 65;
                }
                pos += len;
            },
            0xDD => { // DRI
                const len = try readU16BE(input, pos);
                if (len != 4 or pos + len > input.len) return error.InvalidJpeg;
                restart_interval = try readU16BE(input, pos + 2);
                pos += len;
            },
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidJpeg;
                const len = try readU16BE(input, pos);
                if (len < 2 or pos + len > input.len) return error.InvalidJpeg;
                const seg = input[pos + 2 .. pos + len];
                if (seg.len < 1) return error.InvalidJpeg;
                const ns: usize = seg[0];
                if (ns != ncomp) return error.InvalidJpeg; // Single-scan files only.
                if (seg.len != 1 + ns * 2 + 3) return error.InvalidJpeg;
                var s: usize = 0;
                while (s < ns) : (s += 1) {
                    const cs = seg[1 + s * 2];
                    const tables = seg[2 + s * 2];
                    const comp = &components[s];
                    if (comp.id != cs) return error.InvalidJpeg; // Frame order required.
                    comp.dc_tbl = tables >> 4;
                    comp.ac_tbl = tables & 15;
                    if (comp.dc_tbl > 3 or comp.ac_tbl > 3) return error.InvalidJpeg;
                    if (!dc_tables[comp.dc_tbl].defined) return error.InvalidJpeg;
                    if (!ac_tables[comp.ac_tbl].defined) return error.InvalidJpeg;
                    if (!quant_defined[comp.tq]) return error.InvalidJpeg;
                }
                // Baseline spectral selection 0..63, no successive approximation.
                if (seg[1 + ns * 2] != 0 or seg[2 + ns * 2] != 63 or seg[3 + ns * 2] != 0) {
                    return error.InvalidJpeg;
                }
                scan_start = pos + len;
                pos += len;
            },
            0xD9 => return error.InvalidJpeg, // EOI before any scan data.
            0xE0...0xEF, 0xFE => { // APPn / COM
                const len = try readU16BE(input, pos);
                if (len < 2 or pos + len > input.len) return error.InvalidJpeg;
                pos += len;
            },
            else => return error.InvalidJpeg, // Progressive, arithmetic, DNL, hierarchical, stray RST.
        }
        if (scan_start != 0) break;
    }
    if (scan_start == 0) return error.InvalidJpeg;

    var h_max: usize = 1;
    var v_max: usize = 1;
    var c: usize = 0;
    while (c < ncomp) : (c += 1) {
        h_max = @max(h_max, components[c].h);
        v_max = @max(v_max, components[c].v);
    }
    const mcus_x = (width + h_max * 8 - 1) / (h_max * 8);
    const mcus_y = (height + v_max * 8 - 1) / (v_max * 8);

    const out_stride = width * 4;
    const out_total = OUTPUT_HEADER_SIZE + out_stride * height;
    if (out_total > OUTPUT_CAP) return error.InvalidJpeg;

    c = 0;
    while (c < ncomp) : (c += 1) {
        const comp = &components[c];
        comp.plane_stride = mcus_x * comp.h * 8;
        const plane_rows = mcus_y * comp.v * 8;
        if (comp.plane_stride * plane_rows > PLANE_CAP) return error.InvalidJpeg;
        // h_max and v_max are exact multiples of every h/v (both are in
        // {1, 2}), so these ratios and ceiling divisions are exact.
        comp.hs = h_max / comp.h;
        comp.vs = v_max / comp.v;
        comp.dw = (width * comp.h + h_max - 1) / h_max;
        comp.dh = (height * comp.v + v_max - 1) / v_max;
    }

    var br = BitReader{ .data = input, .pos = scan_start };
    var restarts: usize = 0;
    var mcu: usize = 0;
    const mcu_count = mcus_x * mcus_y;
    while (mcu < mcu_count) : (mcu += 1) {
        if (restart_interval != 0 and mcu != 0 and mcu % restart_interval == 0) {
            try br.restart(0xD0 + @as(u8, @intCast(restarts & 7)));
            restarts += 1;
            c = 0;
            while (c < ncomp) : (c += 1) components[c].dc_pred = 0;
        }
        const mcu_x = mcu % mcus_x;
        const mcu_y = mcu / mcus_x;
        c = 0;
        while (c < ncomp) : (c += 1) {
            const comp = &components[c];
            var by: usize = 0;
            while (by < comp.v) : (by += 1) {
                var bx: usize = 0;
                while (bx < comp.h) : (bx += 1) {
                    const px = (mcu_x * comp.h + bx) * 8;
                    const py = (mcu_y * comp.v + by) * 8;
                    try decodeBlock(&br, comp, &plane_bufs[c], py * comp.plane_stride + px, comp.plane_stride);
                }
            }
        }
    }

    // The compressed data must be followed (after discarded pad bits and
    // optional fill bytes) by EOI, ending the input.
    var tail = br.pos;
    while (tail + 2 < input.len and input[tail] == 0xFF and input[tail + 1] == 0xFF) tail += 1;
    if (tail + 2 != input.len) return error.InvalidJpeg;
    if (input[tail] != 0xFF or input[tail + 1] != 0xD9) return error.InvalidJpeg;

    if (OUTPUT_KTX2) {
        _ = ktx2.writeHeader(&output_buf, width, height) orelse return error.InvalidJpeg;
    } else {
        // BMP header: BITMAPINFOHEADER, 32-bit BGRA, bottom-up.
        @memset(output_buf[0..54], 0);
        output_buf[0] = 'B';
        output_buf[1] = 'M';
        std.mem.writeInt(u32, output_buf[2..6], @intCast(out_total), .little);
        std.mem.writeInt(u32, output_buf[10..14], 54, .little);
        std.mem.writeInt(u32, output_buf[14..18], 40, .little);
        std.mem.writeInt(i32, output_buf[18..22], @intCast(width), .little);
        std.mem.writeInt(i32, output_buf[22..26], @intCast(height), .little);
        std.mem.writeInt(u16, output_buf[26..28], 1, .little);
        std.mem.writeInt(u16, output_buf[28..30], 32, .little);
        std.mem.writeInt(u32, output_buf[34..38], @intCast(out_stride * height), .little);
        std.mem.writeInt(u32, output_buf[38..42], 2835, .little);
        std.mem.writeInt(u32, output_buf[42..46], 2835, .little);
    }

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const dst_y = if (OUTPUT_KTX2) y else height - 1 - y;
        const dst_row = OUTPUT_HEADER_SIZE + dst_y * out_stride;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const dst = output_buf[dst_row + x * 4 ..][0..4];
            const luma = upsampledSample(&components[0], &plane_bufs[0], x, y);
            if (ncomp == 1) {
                dst[0] = luma;
                dst[1] = luma;
                dst[2] = luma;
                dst[3] = 255;
            } else {
                const cb = upsampledSample(&components[1], &plane_bufs[1], x, y);
                const cr = upsampledSample(&components[2], &plane_bufs[2], x, y);
                yccToBgra(luma, cb, cr, dst);
                if (OUTPUT_KTX2) std.mem.swap(u8, &dst[0], &dst[2]);
            }
        }
    }

    return out_total;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const out_size = decode(input_buf[0..input_size]) catch return 0;
    return @as(u32, @intCast(out_size));
}

const RenderResult = packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
};

export fn render(input_size_in: u32) RenderResult {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "extend maps received bits to signed coefficients" {
    try std.testing.expectEqual(@as(i32, 0), extend(0, 0));
    try std.testing.expectEqual(@as(i32, -1), extend(0, 1));
    try std.testing.expectEqual(@as(i32, 1), extend(1, 1));
    try std.testing.expectEqual(@as(i32, -7), extend(0, 3));
    try std.testing.expectEqual(@as(i32, -4), extend(3, 3));
    try std.testing.expectEqual(@as(i32, 5), extend(5, 3));
}

test "huffman decode follows canonical code assignment" {
    var table = HuffTable{};
    // Symbols: 'a' has code 0 (1 bit), 'b' -> 10, 'c' -> 110.
    const bits = [16]u8{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try buildHuffTable(&table, &bits, &[_]u8{ 'a', 'b', 'c' });
    var br = BitReader{ .data = &[_]u8{0b0101_1000}, .pos = 0 };
    try std.testing.expectEqual(@as(u8, 'a'), try huffDecode(&br, &table));
    try std.testing.expectEqual(@as(u8, 'b'), try huffDecode(&br, &table));
    try std.testing.expectEqual(@as(u8, 'c'), try huffDecode(&br, &table));
}

test "idct of a dc-only block is uniform" {
    var coef = [_]i64{0} ** 64;
    coef[0] = 8 * 16; // Quantized DC 16 at quantizer 8 -> sample 16 + 128.
    var plane = [_]u8{0} ** 64;
    idctBlock(&coef, &plane, 0, 8);
    for (plane) |sample| {
        try std.testing.expectEqual(@as(u8, 144), sample);
    }
}

test "declares the standard 25 MP image capacities" {
    try std.testing.expectEqual(@as(u32, 64 * 1024 * 1024), input_bytes_cap());
    try std.testing.expectEqual(@as(u32, MAX_PIXELS * 4 + OUTPUT_HEADER_SIZE), output_bytes_cap());
}

test "ycc conversion matches libjpeg fixed point rounding" {
    var px: [4]u8 = undefined;
    yccToBgra(128, 128, 128, &px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 128, 128, 128, 255 }, &px);
    yccToBgra(255, 0, 0, &px);
    // Cb = Cr = -128: r = 255 - 179, g = 255 + 44 + 91, b = 255 - 227.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 28, 255, 76, 255 }, &px);
}

test "bit reader unstuffs 0xFF00 and rejects markers" {
    var br = BitReader{ .data = &[_]u8{ 0xFF, 0x00, 0xFF, 0xD9 }, .pos = 0 };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectEqual(@as(u1, 1), try br.bit());
    }
    try std.testing.expectError(error.InvalidJpeg, br.bit());
}
