const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;

const WINDOW_SIZE: usize = 32 * 1024;
const HASH_BITS = 15;
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_MASK: usize = HASH_SIZE - 1;

const MIN_MATCH: usize = 3;
const MAX_MATCH: usize = 258;
const MAX_CHAIN: usize = 64;

const LIT_CODE_COUNT: usize = 286;
const DIST_CODE_COUNT: usize = 30;
const CL_CODE_COUNT: usize = 19;
const MAX_CODELEN_RLE: usize = (LIT_CODE_COUNT + DIST_CODE_COUNT) * 2 + 32;

// A literal costs at most 15 bits. A match costs at most 48 bits and consumes
// at least 3 input bytes. Matches have the higher cost per input byte, so the
// maximum uses as many three-byte matches as possible and charges any remainder
// as literals.
// Each code-length RLE entry costs at most a 7-bit code plus 7 extra bits.
const MAX_LITERAL_BITS: usize = 15;
const MAX_MATCH_BITS: usize = 48;
const MAX_TOKEN_BITS: usize =
    (INPUT_CAP / MIN_MATCH) * MAX_MATCH_BITS + (INPUT_CAP % MIN_MATCH) * MAX_LITERAL_BITS;
const DYNAMIC_BLOCK_OVERHEAD_BITS: usize =
    3 + 5 + 5 + 4 + CL_CODE_COUNT * 3 + MAX_CODELEN_RLE * (7 + 7) + 15;
const ZLIB_WRAPPER_BYTES: usize = 2 + 4;
const OUTPUT_CAP: usize = ZLIB_WRAPPER_BYTES +
    (MAX_TOKEN_BITS + DYNAMIC_BLOCK_OVERHEAD_BITS + 7) / 8;

const CL_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var head: [HASH_SIZE]i32 = undefined;
var prev: [WINDOW_SIZE]i32 = undefined;
var token_buf: [INPUT_CAP]u32 = undefined;

const TOKEN_MATCH_FLAG: u32 = 0x8000_0000;
const TOKEN_LEN_MASK: u32 = 0x1ff;
const TOKEN_DIST_SHIFT: u5 = 9;

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

const Match = struct {
    len: usize,
    dist: usize,
};

const LengthEncoding = struct {
    symbol: u16,
    extra_bits: u8,
    extra_value: u16,
};

const DistanceEncoding = struct {
    symbol: u16,
    extra_bits: u8,
    extra_value: u16,
};

const RleEntry = struct {
    symbol: u8,
    extra_bits: u8,
    extra_value: u16,
};

const BitWriter = struct {
    out_i: usize,
    bitbuf: u64,
    bitcount: u8,

    fn init(start: usize) BitWriter {
        return .{ .out_i = start, .bitbuf = 0, .bitcount = 0 };
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

const Node = struct {
    freq: u64,
    left: i16,
    right: i16,
    symbol: i16,
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

fn reverseBits(code: u16, len: u8) u16 {
    var in_bits = code;
    var out_bits: u16 = 0;
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        out_bits = (out_bits << 1) | (in_bits & 1);
        in_bits >>= 1;
    }
    return out_bits;
}

fn hash3(input: []const u8, pos: usize) usize {
    const v = (@as(u32, input[pos]) << 16) |
        (@as(u32, input[pos + 1]) << 8) |
        (@as(u32, input[pos + 2]));
    return @as(usize, @intCast((v *% 2654435761) >> (32 - HASH_BITS))) & HASH_MASK;
}

fn initMatcher() void {
    @memset(head[0..], -1);
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

fn encodeLength(length: usize) LengthEncoding {
    // Symbol 284 covers lengths 227-257 per RFC 1951 even though its 5 extra
    // bits could reach 258; length 258 is exactly symbol 285.
    if (length == MAX_MATCH) {
        return .{ .symbol = 285, .extra_bits = 0, .extra_value = 0 };
    }

    var i: usize = 0;
    while (i < LENGTH_BASE.len) : (i += 1) {
        const base = LENGTH_BASE[i];
        const extra = LENGTH_EXTRA[i];
        const max_len: u16 = if (extra == 0) base else base + ((@as(u16, 1) << @intCast(extra)) - 1);
        if (length <= max_len) {
            return .{
                .symbol = @as(u16, @intCast(257 + i)),
                .extra_bits = extra,
                .extra_value = @as(u16, @intCast(length)) - base,
            };
        }
    }

    return .{ .symbol = 285, .extra_bits = 0, .extra_value = 0 };
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
                .extra_bits = extra,
                .extra_value = @as(u16, @intCast(distance)) - base,
            };
        }
    }

    return .{ .symbol = 29, .extra_bits = 13, .extra_value = @as(u16, @intCast(distance - 24577)) };
}

fn popMinNode(nodes: []const Node, pq: []i16, pq_len: *usize) i16 {
    var best: usize = 0;
    var i: usize = 1;
    while (i < pq_len.*) : (i += 1) {
        const a = nodes[@intCast(pq[i])];
        const b = nodes[@intCast(pq[best])];
        if (a.freq < b.freq or (a.freq == b.freq and pq[i] < pq[best])) {
            best = i;
        }
    }

    const out = pq[best];
    pq_len.* -= 1;
    pq[best] = pq[pq_len.*];
    return out;
}

fn buildCodeLengths(comptime N: usize, freq: *const [N]u32, lengths: *[N]u8, max_bits: u8) bool {
    @memset(lengths[0..], 0);

    var active: [N]u16 = undefined;
    var active_len: usize = 0;
    for (freq, 0..) |f, sym| {
        if (f != 0) {
            active[active_len] = @intCast(sym);
            active_len += 1;
        }
    }

    if (active_len == 0) return false;
    if (active_len == 1) {
        lengths[active[0]] = 1;
        return true;
    }

    var nodes: [2 * N]Node = undefined;
    var parent: [2 * N]i16 = [_]i16{-1} ** (2 * N);
    var pq: [2 * N]i16 = undefined;

    var node_len: usize = 0;
    var pq_len: usize = 0;
    var i: usize = 0;
    while (i < active_len) : (i += 1) {
        const sym = active[i];
        nodes[node_len] = .{
            .freq = freq[sym],
            .left = -1,
            .right = -1,
            .symbol = @intCast(sym),
        };
        pq[pq_len] = @intCast(node_len);
        node_len += 1;
        pq_len += 1;
    }

    while (pq_len > 1) {
        const a = popMinNode(nodes[0..node_len], pq[0..], &pq_len);
        const b = popMinNode(nodes[0..node_len], pq[0..], &pq_len);

        nodes[node_len] = .{
            .freq = nodes[@intCast(a)].freq + nodes[@intCast(b)].freq,
            .left = a,
            .right = b,
            .symbol = -1,
        };
        parent[@intCast(a)] = @intCast(node_len);
        parent[@intCast(b)] = @intCast(node_len);
        pq[pq_len] = @intCast(node_len);
        node_len += 1;
        pq_len += 1;
    }

    var bl_count: [2 * N]u16 = [_]u16{0} ** (2 * N);

    i = 0;
    while (i < active_len) : (i += 1) {
        var depth: u16 = 0;
        var cur: i16 = @intCast(i);
        while (parent[@intCast(cur)] >= 0) {
            depth += 1;
            cur = parent[@intCast(cur)];
        }
        if (depth == 0) depth = 1;

        const used_depth: u16 = if (depth > max_bits) max_bits else depth;
        bl_count[used_depth] += 1;
    }

    while (true) {
        var left: i32 = 1;
        var bits: u8 = 1;
        while (bits <= max_bits) : (bits += 1) {
            left = (left << 1) - @as(i32, bl_count[bits]);
        }
        if (left >= 0) break;

        var fix_bits: i32 = @as(i32, max_bits) - 1;
        while (fix_bits > 0 and bl_count[@intCast(fix_bits)] == 0) : (fix_bits -= 1) {}
        if (fix_bits <= 0) return false;

        bl_count[@intCast(fix_bits)] -= 1;
        bl_count[@intCast(fix_bits + 1)] += 2;
        if (bl_count[max_bits] == 0) return false;
        bl_count[max_bits] -= 1;
    }
    var by_freq: [N]u16 = undefined;
    i = 0;
    while (i < active_len) : (i += 1) {
        by_freq[i] = active[i];
    }

    i = 1;
    while (i < active_len) : (i += 1) {
        const key = by_freq[i];
        const key_freq = freq[key];
        var j: usize = i;
        while (j > 0) {
            const prev_sym = by_freq[j - 1];
            const prev_freq = freq[prev_sym];
            if (prev_freq > key_freq or (prev_freq == key_freq and prev_sym < key)) break;
            by_freq[j] = by_freq[j - 1];
            j -= 1;
        }
        by_freq[j] = key;
    }

    var out_i: usize = 0;
    var bit_len: u8 = 1;
    while (bit_len <= max_bits) : (bit_len += 1) {
        var count: u16 = bl_count[bit_len];
        while (count > 0) : (count -= 1) {
            if (out_i >= active_len) return false;
            lengths[by_freq[out_i]] = bit_len;
            out_i += 1;
        }
    }

    if (out_i != active_len) return false;
    return true;
}
fn buildCanonicalCodes(comptime N: usize, lengths: *const [N]u8, codes: *[N]u16, max_bits: u8) bool {
    @memset(codes[0..], 0);

    var count: [16]u16 = [_]u16{0} ** 16;

    for (lengths) |len| {
        if (len == 0) continue;
        if (len > max_bits) return false;
        count[len] += 1;
    }

    var next: [16]u16 = [_]u16{0} ** 16;
    var code: u32 = 0;

    var bits: u8 = 1;
    while (bits <= max_bits) : (bits += 1) {
        code = (code + count[bits - 1]) << 1;
        next[bits] = @intCast(code);
    }

    for (lengths, 0..) |len, sym| {
        if (len == 0) continue;
        const c = next[len];
        next[len] += 1;
        codes[sym] = reverseBits(c, len);
    }

    return true;
}

fn encodeLiteralToken(byte: u8) u32 {
    return @as(u32, byte);
}

fn encodeMatchToken(length: usize, distance: usize) u32 {
    return TOKEN_MATCH_FLAG |
        (@as(u32, @intCast(distance - 1)) << TOKEN_DIST_SHIFT) |
        @as(u32, @intCast(length));
}

fn tokenIsMatch(token: u32) bool {
    return (token & TOKEN_MATCH_FLAG) != 0;
}

fn tokenLiteral(token: u32) u8 {
    return @as(u8, @intCast(token & 0xff));
}

fn tokenLength(token: u32) usize {
    return @as(usize, @intCast(token & TOKEN_LEN_MASK));
}

fn tokenDistance(token: u32) usize {
    return @as(usize, @intCast((token >> TOKEN_DIST_SHIFT) & 0x7fff)) + 1;
}

fn tokenizeAndCount(
    input: []const u8,
    tokens: *[INPUT_CAP]u32,
    token_len: *usize,
    lit_freq: *[LIT_CODE_COUNT]u32,
    dist_freq: *[DIST_CODE_COUNT]u32,
) bool {
    token_len.* = 0;
    @memset(lit_freq[0..], 0);
    @memset(dist_freq[0..], 0);

    initMatcher();

    var pos: usize = 0;
    while (pos < input.len) {
        const m = findMatch(input, pos);
        if (m.len >= MIN_MATCH) {
            if (token_len.* >= INPUT_CAP) return false;
            tokens[token_len.*] = encodeMatchToken(m.len, m.dist);
            token_len.* += 1;

            const len_enc = encodeLength(m.len);
            const dist_enc = encodeDistance(m.dist);
            lit_freq[len_enc.symbol] += 1;
            dist_freq[dist_enc.symbol] += 1;

            var p = pos;
            const end = pos + m.len;
            while (p < end) : (p += 1) {
                insertPosition(input, p);
            }
            pos = end;
        } else {
            if (token_len.* >= INPUT_CAP) return false;
            const b = input[pos];
            tokens[token_len.*] = encodeLiteralToken(b);
            token_len.* += 1;

            lit_freq[b] += 1;
            insertPosition(input, pos);
            pos += 1;
        }
    }

    // End-of-block marker.
    lit_freq[256] += 1;

    var has_dist = false;
    for (dist_freq) |f| {
        if (f != 0) {
            has_dist = true;
            break;
        }
    }
    if (!has_dist) {
        // Dynamic Huffman requires at least one distance code.
        dist_freq[0] = 1;
    }

    return true;
}

fn getCodeLen(lit_len: *const [LIT_CODE_COUNT]u8, num_lit: usize, dist_len: *const [DIST_CODE_COUNT]u8, idx: usize) u8 {
    if (idx < num_lit) return lit_len[idx];
    return dist_len[idx - num_lit];
}

fn emitRle(entries: *[MAX_CODELEN_RLE]RleEntry, len: *usize, cl_freq: *[CL_CODE_COUNT]u32, symbol: u8, extra_bits: u8, extra_value: u16) bool {
    if (len.* >= entries.len) return false;
    entries[len.*] = .{ .symbol = symbol, .extra_bits = extra_bits, .extra_value = extra_value };
    len.* += 1;
    cl_freq[symbol] += 1;
    return true;
}

fn encodeCodeLengthRle(
    lit_len: *const [LIT_CODE_COUNT]u8,
    num_lit: usize,
    dist_len: *const [DIST_CODE_COUNT]u8,
    num_dist: usize,
    entries: *[MAX_CODELEN_RLE]RleEntry,
    entry_len: *usize,
    cl_freq: *[CL_CODE_COUNT]u32,
) bool {
    entry_len.* = 0;
    @memset(cl_freq[0..], 0);

    const total = num_lit + num_dist;
    var i: usize = 0;

    while (i < total) {
        const cur = getCodeLen(lit_len, num_lit, dist_len, i);
        var repeat_count: usize = 1;
        while (i + repeat_count < total and getCodeLen(lit_len, num_lit, dist_len, i + repeat_count) == cur and repeat_count < 138) : (repeat_count += 1) {}

        if (cur == 0) {
            var rem = repeat_count;
            while (rem > 0) {
                if (rem >= 11) {
                    const n = @min(rem, 138);
                    if (!emitRle(entries, entry_len, cl_freq, 18, 7, @intCast(n - 11))) return false;
                    rem -= n;
                } else if (rem >= 3) {
                    const n = @min(rem, 10);
                    if (!emitRle(entries, entry_len, cl_freq, 17, 3, @intCast(n - 3))) return false;
                    rem -= n;
                } else {
                    if (!emitRle(entries, entry_len, cl_freq, 0, 0, 0)) return false;
                    rem -= 1;
                }
            }
        } else {
            if (!emitRle(entries, entry_len, cl_freq, cur, 0, 0)) return false;

            var rem = repeat_count - 1;
            while (rem > 0) {
                if (rem >= 3) {
                    const n = @min(rem, 6);
                    if (!emitRle(entries, entry_len, cl_freq, 16, 2, @intCast(n - 3))) return false;
                    rem -= n;
                } else {
                    if (!emitRle(entries, entry_len, cl_freq, cur, 0, 0)) return false;
                    rem -= 1;
                }
            }
        }

        i += repeat_count;
    }

    return true;
}

fn emitTokenBuffer(
    tokens: []const u32,
    writer: *BitWriter,
    lit_len: *const [LIT_CODE_COUNT]u8,
    lit_code: *const [LIT_CODE_COUNT]u16,
    dist_len: *const [DIST_CODE_COUNT]u8,
    dist_code: *const [DIST_CODE_COUNT]u16,
) bool {
    for (tokens) |token| {
        if (tokenIsMatch(token)) {
            const m_len = tokenLength(token);
            const m_dist = tokenDistance(token);

            const len_enc = encodeLength(m_len);
            const dist_enc = encodeDistance(m_dist);

            if (!writer.writeBits(lit_code[len_enc.symbol], lit_len[len_enc.symbol])) return false;
            if (!writer.writeBits(len_enc.extra_value, len_enc.extra_bits)) return false;
            if (!writer.writeBits(dist_code[dist_enc.symbol], dist_len[dist_enc.symbol])) return false;
            if (!writer.writeBits(dist_enc.extra_value, dist_enc.extra_bits)) return false;
        } else {
            const b = tokenLiteral(token);
            if (!writer.writeBits(lit_code[b], lit_len[b])) return false;
        }
    }

    if (!writer.writeBits(lit_code[256], lit_len[256])) return false;
    return true;
}
/// Writes zlib stream with one final dynamic-Huffman DEFLATE block.
fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    var lit_freq: [LIT_CODE_COUNT]u32 = undefined;
    var dist_freq: [DIST_CODE_COUNT]u32 = undefined;
    var token_count: usize = 0;
    if (!tokenizeAndCount(input, &token_buf, &token_count, &lit_freq, &dist_freq)) @trap();

    var lit_len: [LIT_CODE_COUNT]u8 = undefined;
    var dist_len: [DIST_CODE_COUNT]u8 = undefined;

    if (!buildCodeLengths(LIT_CODE_COUNT, &lit_freq, &lit_len, 15)) @trap();
    if (!buildCodeLengths(DIST_CODE_COUNT, &dist_freq, &dist_len, 15)) @trap();

    var lit_code: [LIT_CODE_COUNT]u16 = undefined;
    var dist_code: [DIST_CODE_COUNT]u16 = undefined;

    if (!buildCanonicalCodes(LIT_CODE_COUNT, &lit_len, &lit_code, 15)) @trap();
    if (!buildCanonicalCodes(DIST_CODE_COUNT, &dist_len, &dist_code, 15)) @trap();

    var num_lit: usize = LIT_CODE_COUNT;
    while (num_lit > 257 and lit_len[num_lit - 1] == 0) : (num_lit -= 1) {}

    var num_dist: usize = DIST_CODE_COUNT;
    while (num_dist > 1 and dist_len[num_dist - 1] == 0) : (num_dist -= 1) {}

    var rle_entries: [MAX_CODELEN_RLE]RleEntry = undefined;
    var rle_len: usize = 0;
    var cl_freq: [CL_CODE_COUNT]u32 = undefined;

    if (!encodeCodeLengthRle(&lit_len, num_lit, &dist_len, num_dist, &rle_entries, &rle_len, &cl_freq)) @trap();

    var cl_len: [CL_CODE_COUNT]u8 = undefined;
    if (!buildCodeLengths(CL_CODE_COUNT, &cl_freq, &cl_len, 7)) @trap();

    var cl_code: [CL_CODE_COUNT]u16 = undefined;
    if (!buildCanonicalCodes(CL_CODE_COUNT, &cl_len, &cl_code, 7)) @trap();

    var num_cl: usize = CL_CODE_COUNT;
    while (num_cl > 4 and cl_len[CL_ORDER[num_cl - 1]] == 0) : (num_cl -= 1) {}

    // zlib header.
    output_buf[0] = 0x78;
    output_buf[1] = 0x01;

    var writer = BitWriter.init(2);

    // Final block, dynamic Huffman: BFINAL=1, BTYPE=10.
    if (!writer.writeBits(0b101, 3)) @trap();

    if (!writer.writeBits(@intCast(num_lit - 257), 5)) @trap();
    if (!writer.writeBits(@intCast(num_dist - 1), 5)) @trap();
    if (!writer.writeBits(@intCast(num_cl - 4), 4)) @trap();

    var i: usize = 0;
    while (i < num_cl) : (i += 1) {
        if (!writer.writeBits(cl_len[CL_ORDER[i]], 3)) @trap();
    }

    i = 0;
    while (i < rle_len) : (i += 1) {
        const e = rle_entries[i];
        const sym = e.symbol;
        const clen = cl_len[sym];
        if (clen == 0) @trap();
        if (!writer.writeBits(cl_code[sym], clen)) @trap();
        if (!writer.writeBits(e.extra_value, e.extra_bits)) @trap();
    }

    if (!emitTokenBuffer(token_buf[0..token_count], &writer, &lit_len, &lit_code, &dist_len, &dist_code)) @trap();
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
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var out_writer: std.Io.Writer = .fixed(out);

    const n = try decompress.reader.streamRemaining(&out_writer);

    var trailing: [1]u8 = undefined;
    if (try in.readSliceShort(&trailing) != 0) return error.TrailingBytes;
    return n;
}

test "round trips short text" {
    const plain = "dynamic huffman in qip";
    @memcpy(input_buf[0..plain.len], plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    // Verify dynamic block type: lower 3 bits should be BFINAL=1,BTYPE=10 => 0b101.
    try std.testing.expectEqual(@as(u8, 0b101), output_buf[2] & 0x07);

    var out: [128]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualStrings(plain, out[0..n]);
}

test "round trips empty input" {
    const written = renderImpl(0);
    try std.testing.expect(written > 0);

    var out: [1]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "round trips repetitive data" {
    var plain: [65536]u8 = undefined;
    for (&plain, 0..) |*b, i| {
        b.* = if ((i % 64) < 48) 'a' else 'b';
    }
    @memcpy(input_buf[0..plain.len], &plain);

    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [65536]u8 = undefined;
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

test "dynamic code limits obey the output bound" {
    var max_length_extra: usize = 0;
    for (LENGTH_EXTRA) |extra| max_length_extra = @max(max_length_extra, extra);

    var max_distance_extra: usize = 0;
    for (DIST_EXTRA) |extra| max_distance_extra = @max(max_distance_extra, extra);

    const max_match_bits = 15 + max_length_extra + 15 + max_distance_extra;
    try std.testing.expect(15 <= MAX_LITERAL_BITS);
    try std.testing.expect(max_match_bits <= MAX_MATCH_BITS);
    try std.testing.expect(MAX_CODELEN_RLE >= (LIT_CODE_COUNT + DIST_CODE_COUNT) * 2);
}
