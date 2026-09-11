//! Internal zlib/DEFLATE compression engine shared by the zlib-compress
//! components and image encoders that embed a zlib stream (such as PNG).
//! This is a private API: callers inside this repository only.
//!
//! Supports zlib-wrapped and raw streams, including bounded multi-block raw
//! compression. Callers provide the output and token scratch buffers; the
//! 32 KB-window hash chains live in this module.

const std = @import("std");

const WINDOW_SIZE: usize = 32 * 1024;
const HASH_BITS = 15;
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_MASK: usize = HASH_SIZE - 1;

const MIN_MATCH: usize = 3;
pub const MAX_MATCH: usize = 258;
const DEFAULT_MAX_CHAIN: usize = 256;
const LAZY_MATCH_BONUS: usize = 1;

const LIT_CODE_COUNT: usize = 286;
const DIST_CODE_COUNT: usize = 30;
const CL_CODE_COUNT: usize = 19;
const MAX_CODELEN_RLE: usize = (LIT_CODE_COUNT + DIST_CODE_COUNT) * 2 + 32;

const CL_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

var head: [HASH_SIZE]i32 = undefined;
var prev: [WINDOW_SIZE]i32 = undefined;

pub const CompressionOptions = struct {
    /// Maximum number of hash-chain candidates examined for each match.
    /// Shallower searches trade compression ratio for throughput.
    max_chain: usize = DEFAULT_MAX_CHAIN,
};

const TOKEN_MATCH_FLAG: u32 = 0x8000_0000;
const TOKEN_LEN_MASK: u32 = 0x1ff;
const TOKEN_DIST_SHIFT: u5 = 9;

pub const LENGTH_BASE = [_]u16{
    3,   4,   5,   6,   7,   8,  9,  10,
    11,  13,  15,  17,  19,  23, 27, 31,
    35,  43,  51,  59,  67,  83, 99, 115,
    131, 163, 195, 227, 258,
};

pub const LENGTH_EXTRA = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0,
};

pub const DIST_BASE = [_]u16{
    1,    2,    3,    4,     5,     7,     9,    13,
    17,   25,   33,   49,    65,    97,    129,  193,
    257,  385,  513,  769,   1025,  1537,  2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577,
};

pub const DIST_EXTRA = [_]u8{
    0,  0,  0,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  5,  6,  6,
    7,  7,  8,  8,  9,  9,  10, 10,
    11, 11, 12, 12, 13, 13,
};

// Length symbol index (0-28 for symbols 257-285) by match length 3-258.
// Symbol 284 covers lengths 227-257 per RFC 1951; length 258 is exactly
// symbol 285 and must not be emitted as 284 + 31.
const LENGTH_SYMBOL = blk: {
    var t: [MAX_MATCH + 1]u8 = undefined;
    for (LENGTH_BASE, LENGTH_EXTRA, 0..) |base, extra, i| {
        const top = if (i == 28) MAX_MATCH else @min(base + (@as(usize, 1) << extra) - 1, 257);
        var len: usize = base;
        while (len <= top) : (len += 1) t[len] = @intCast(i);
    }
    break :blk t;
};

fn distSymbolScan(dist: usize) u8 {
    for (DIST_BASE, DIST_EXTRA, 0..) |base, extra, i| {
        if (dist <= base + (@as(usize, 1) << extra) - 1) return @intCast(i);
    }
    unreachable;
}

// Distance symbol index by distance, split like zlib's dist_code: indexed by
// dist - 1 for distances 1-256, and by (dist - 1) >> 7 for 257-32768. Every
// 128-wide bucket above 256 falls inside a single symbol's range.
const DIST_SYMBOL_LOW = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, i| e.* = distSymbolScan(i + 1);
    break :blk t;
};

const DIST_SYMBOL_HIGH = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u8 = [_]u8{0} ** 256;
    var b: usize = 2;
    while (b < 256) : (b += 1) t[b] = distSymbolScan(b * 128 + 1);
    break :blk t;
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

const FixedCode = struct {
    bits: u16,
    len: u8,
};

const RleEntry = struct {
    symbol: u8,
    extra_bits: u8,
    extra_value: u16,
};

const BitWriter = struct {
    out: []u8,
    out_i: usize,
    bitbuf: u64,
    bitcount: u8,

    fn init(out: []u8, start: usize) BitWriter {
        return .{ .out = out, .out_i = start, .bitbuf = 0, .bitcount = 0 };
    }

    fn writeBits(self: *BitWriter, value: u32, nbits: u8) bool {
        if (nbits == 0) return true;

        self.bitbuf |= (@as(u64, value) << @intCast(self.bitcount));
        self.bitcount += nbits;

        if (self.bitcount >= 32) {
            if (self.out_i + 4 > self.out.len) return false;
            std.mem.writeInt(u32, self.out[self.out_i..][0..4], @truncate(self.bitbuf), .little);
            self.out_i += 4;
            self.bitbuf >>= 32;
            self.bitcount -= 32;
        }

        return true;
    }

    fn flush(self: *BitWriter) bool {
        while (self.bitcount > 0) {
            if (self.out_i >= self.out.len) return false;
            self.out[self.out_i] = @intCast(self.bitbuf & 0xff);
            self.out_i += 1;
            self.bitbuf >>= 8;
            self.bitcount -= @min(self.bitcount, 8);
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

fn fixedLiteralCode(symbol: u16) FixedCode {
    if (symbol <= 143) {
        return .{ .bits = reverseBits(@as(u16, 0x30) + symbol, 8), .len = 8 };
    }
    if (symbol <= 255) {
        return .{ .bits = reverseBits(@as(u16, 0x190) + symbol - 144, 9), .len = 9 };
    }
    if (symbol <= 279) {
        return .{ .bits = reverseBits(symbol - 256, 7), .len = 7 };
    }
    return .{ .bits = reverseBits(@as(u16, 0xc0) + symbol - 280, 8), .len = 8 };
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

fn matchLen(input: []const u8, a: usize, b: usize, max: usize) usize {
    var len: usize = 0;
    while (len + 8 <= max) {
        const x = std.mem.readInt(u64, input[a + len ..][0..8], .little);
        const y = std.mem.readInt(u64, input[b + len ..][0..8], .little);
        const diff = x ^ y;
        if (diff != 0) return len + (@as(usize, @ctz(diff)) >> 3);
        len += 8;
    }
    while (len < max and input[a + len] == input[b + len]) : (len += 1) {}
    return len;
}

fn findMatch(input: []const u8, pos: usize, max_chain: usize) Match {
    if (pos + MIN_MATCH > input.len) {
        return .{ .len = 0, .dist = 0 };
    }

    const h = hash3(input, pos);
    var cand = head[h];
    var best_len: usize = 0;
    var best_dist: usize = 0;
    const max_len = @min(MAX_MATCH, input.len - pos);

    var steps: usize = 0;
    while (cand >= 0 and steps < max_chain) : (steps += 1) {
        const cand_pos: usize = @intCast(cand);
        const dist = pos - cand_pos;
        if (dist == 0 or dist > WINDOW_SIZE) break;

        // A longer match than best_len must agree at its last byte; probing
        // it first skips most non-improving candidates without a full scan.
        if (best_len == 0 or input[cand_pos + best_len] == input[pos + best_len]) {
            const len = matchLen(input, cand_pos, pos, max_len);
            if (len >= MIN_MATCH and len > best_len) {
                best_len = len;
                best_dist = dist;
                if (len == max_len) break;
            }
        }

        cand = prev[cand_pos & (WINDOW_SIZE - 1)];
    }

    return .{ .len = best_len, .dist = best_dist };
}

pub fn encodeLength(length: usize) LengthEncoding {
    const i = LENGTH_SYMBOL[length];
    return .{
        .symbol = @as(u16, 257) + i,
        .extra_bits = LENGTH_EXTRA[i],
        .extra_value = @as(u16, @intCast(length)) - LENGTH_BASE[i],
    };
}

pub fn encodeDistance(distance: usize) DistanceEncoding {
    const i = if (distance <= 256) DIST_SYMBOL_LOW[distance - 1] else DIST_SYMBOL_HIGH[(distance - 1) >> 7];
    return .{
        .symbol = i,
        .extra_bits = DIST_EXTRA[i],
        .extra_value = @as(u16, @intCast(distance)) - DIST_BASE[i],
    };
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
    tokens: []u32,
    token_len: *usize,
    lit_freq: *[LIT_CODE_COUNT]u32,
    dist_freq: *[DIST_CODE_COUNT]u32,
    options: CompressionOptions,
) bool {
    token_len.* = 0;
    @memset(lit_freq[0..], 0);
    @memset(dist_freq[0..], 0);

    initMatcher();

    var pos: usize = 0;
    var carried = Match{ .len = 0, .dist = 0 };
    var carried_valid = false;
    while (pos < input.len) {
        const m = if (carried_valid) carried else findMatch(input, pos, options.max_chain);
        carried_valid = false;

        var used_lookahead = false;
        if (m.len >= MIN_MATCH and m.len < MAX_MATCH and pos + 1 < input.len) {
            used_lookahead = true;
            insertPosition(input, pos);
            const next = findMatch(input, pos + 1, options.max_chain);
            if (next.len > m.len + LAZY_MATCH_BONUS) {
                // The deferred match is exactly what the next iteration's
                // findMatch would return; carry it instead of recomputing.
                carried = next;
                carried_valid = true;
                if (token_len.* >= tokens.len) return false;
                const b = input[pos];
                tokens[token_len.*] = encodeLiteralToken(b);
                token_len.* += 1;
                lit_freq[b] += 1;
                pos += 1;
                continue;
            }
        }

        if (m.len >= MIN_MATCH) {
            if (token_len.* >= tokens.len) return false;
            tokens[token_len.*] = encodeMatchToken(m.len, m.dist);
            token_len.* += 1;

            const len_enc = encodeLength(m.len);
            const dist_enc = encodeDistance(m.dist);
            lit_freq[len_enc.symbol] += 1;
            dist_freq[dist_enc.symbol] += 1;

            var p: usize = if (used_lookahead) pos + 1 else pos;
            const end = pos + m.len;
            while (p < end) : (p += 1) {
                insertPosition(input, p);
            }
            pos = end;
        } else {
            if (token_len.* >= tokens.len) return false;
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

fn emitFixedTokenBuffer(tokens: []const u32, writer: *BitWriter) bool {
    for (tokens) |token| {
        if (tokenIsMatch(token)) {
            const length = encodeLength(tokenLength(token));
            const length_code = fixedLiteralCode(length.symbol);
            if (!writer.writeBits(length_code.bits, length_code.len)) return false;
            if (!writer.writeBits(length.extra_value, length.extra_bits)) return false;

            const distance = encodeDistance(tokenDistance(token));
            if (!writer.writeBits(reverseBits(distance.symbol, 5), 5)) return false;
            if (!writer.writeBits(distance.extra_value, distance.extra_bits)) return false;
        } else {
            const literal = fixedLiteralCode(tokenLiteral(token));
            if (!writer.writeBits(literal.bits, literal.len)) return false;
        }
    }

    const eob = fixedLiteralCode(256);
    return writer.writeBits(eob.bits, eob.len);
}

fn fixedTokenBitCost(tokens: []const u32) u64 {
    var bits: u64 = 3 + fixedLiteralCode(256).len;
    for (tokens) |token| {
        if (tokenIsMatch(token)) {
            const length = encodeLength(tokenLength(token));
            const distance = encodeDistance(tokenDistance(token));
            bits += fixedLiteralCode(length.symbol).len + length.extra_bits +
                5 + distance.extra_bits;
        } else {
            bits += fixedLiteralCode(tokenLiteral(token)).len;
        }
    }
    return bits;
}

fn dynamicTokenBitCost(
    tokens: []const u32,
    lit_len: *const [LIT_CODE_COUNT]u8,
    dist_len: *const [DIST_CODE_COUNT]u8,
) u64 {
    var bits: u64 = lit_len[256];
    for (tokens) |token| {
        if (tokenIsMatch(token)) {
            const length = encodeLength(tokenLength(token));
            const distance = encodeDistance(tokenDistance(token));
            bits += lit_len[length.symbol] + length.extra_bits +
                dist_len[distance.symbol] + distance.extra_bits;
        } else {
            bits += lit_len[tokenLiteral(token)];
        }
    }
    return bits;
}

fn writeU32BE(out: []u8, off: usize, value: u32) void {
    out[off] = @intCast((value >> 24) & 0xff);
    out[off + 1] = @intCast((value >> 16) & 0xff);
    out[off + 2] = @intCast((value >> 8) & 0xff);
    out[off + 3] = @intCast(value & 0xff);
}

fn emitDynamicBlock(
    input: []const u8,
    tokens: []u32,
    options: CompressionOptions,
    writer_ptr: *BitWriter,
    is_final: bool,
    choose_fixed: bool,
) ?void {
    var lit_freq: [LIT_CODE_COUNT]u32 = undefined;
    var dist_freq: [DIST_CODE_COUNT]u32 = undefined;
    var token_count: usize = 0;
    if (!tokenizeAndCount(input, tokens, &token_count, &lit_freq, &dist_freq, options)) return null;

    var lit_len: [LIT_CODE_COUNT]u8 = undefined;
    var dist_len: [DIST_CODE_COUNT]u8 = undefined;

    if (!buildCodeLengths(LIT_CODE_COUNT, &lit_freq, &lit_len, 15)) return null;
    if (!buildCodeLengths(DIST_CODE_COUNT, &dist_freq, &dist_len, 15)) return null;

    var lit_code: [LIT_CODE_COUNT]u16 = undefined;
    var dist_code: [DIST_CODE_COUNT]u16 = undefined;

    if (!buildCanonicalCodes(LIT_CODE_COUNT, &lit_len, &lit_code, 15)) return null;
    if (!buildCanonicalCodes(DIST_CODE_COUNT, &dist_len, &dist_code, 15)) return null;

    var num_lit: usize = LIT_CODE_COUNT;
    while (num_lit > 257 and lit_len[num_lit - 1] == 0) : (num_lit -= 1) {}

    var num_dist: usize = DIST_CODE_COUNT;
    while (num_dist > 1 and dist_len[num_dist - 1] == 0) : (num_dist -= 1) {}

    var rle_entries: [MAX_CODELEN_RLE]RleEntry = undefined;
    var rle_len: usize = 0;
    var cl_freq: [CL_CODE_COUNT]u32 = undefined;

    if (!encodeCodeLengthRle(&lit_len, num_lit, &dist_len, num_dist, &rle_entries, &rle_len, &cl_freq)) return null;

    var cl_len: [CL_CODE_COUNT]u8 = undefined;
    if (!buildCodeLengths(CL_CODE_COUNT, &cl_freq, &cl_len, 7)) return null;

    var cl_code: [CL_CODE_COUNT]u16 = undefined;
    if (!buildCanonicalCodes(CL_CODE_COUNT, &cl_len, &cl_code, 7)) return null;

    var num_cl: usize = CL_CODE_COUNT;
    while (num_cl > 4 and cl_len[CL_ORDER[num_cl - 1]] == 0) : (num_cl -= 1) {}

    var writer = writer_ptr.*;
    defer writer_ptr.* = writer;

    var dynamic_bits: u64 = 3 + 5 + 5 + 4 + num_cl * 3;
    for (rle_entries[0..rle_len]) |entry| {
        dynamic_bits += cl_len[entry.symbol] + entry.extra_bits;
    }
    dynamic_bits += dynamicTokenBitCost(tokens[0..token_count], &lit_len, &dist_len);

    if (choose_fixed and fixedTokenBitCost(tokens[0..token_count]) <= dynamic_bits) {
        if (!writer.writeBits(0b010 | @as(u3, @intFromBool(is_final)), 3)) return null;
        if (!emitFixedTokenBuffer(tokens[0..token_count], &writer)) return null;
        return;
    }

    // Dynamic Huffman: BTYPE=10, with BFINAL controlled by the caller.
    if (!writer.writeBits(0b100 | @as(u3, @intFromBool(is_final)), 3)) return null;

    if (!writer.writeBits(@intCast(num_lit - 257), 5)) return null;
    if (!writer.writeBits(@intCast(num_dist - 1), 5)) return null;
    if (!writer.writeBits(@intCast(num_cl - 4), 4)) return null;

    var i: usize = 0;
    while (i < num_cl) : (i += 1) {
        if (!writer.writeBits(cl_len[CL_ORDER[i]], 3)) return null;
    }

    i = 0;
    while (i < rle_len) : (i += 1) {
        const e = rle_entries[i];
        const sym = e.symbol;
        const clen = cl_len[sym];
        if (clen == 0) return null;
        if (!writer.writeBits(cl_code[sym], clen)) return null;
        if (!writer.writeBits(e.extra_value, e.extra_bits)) return null;
    }

    if (!emitTokenBuffer(tokens[0..token_count], &writer, &lit_len, &lit_code, &dist_len, &dist_code)) return null;
}

fn compressDynamic(
    input: []const u8,
    output: []u8,
    tokens: []u32,
    options: CompressionOptions,
    output_start: usize,
) ?usize {
    var writer = BitWriter.init(output, output_start);
    emitDynamicBlock(input, tokens, options, &writer, true, false) orelse return null;
    if (!writer.flush()) return null;
    return writer.out_i;
}

/// Compresses `input` as a zlib stream with one final dynamic-Huffman
/// DEFLATE block, written into `output`. `tokens` must hold at least
/// `input.len` entries. Returns the number of bytes written, or null when
/// the output or token buffer is too small (or a Huffman tree could not be
/// built, which does not happen for well-formed inputs).
pub fn compressZlib(input: []const u8, output: []u8, tokens: []u32) ?usize {
    return compressZlibWithOptions(input, output, tokens, .{});
}

pub fn compressZlibWithOptions(input: []const u8, output: []u8, tokens: []u32, options: CompressionOptions) ?usize {
    if (output.len < 2) return null;
    output[0] = 0x78;
    output[1] = 0x01;

    const deflate_end = compressDynamic(input, output, tokens, options, 2) orelse return null;
    if (deflate_end + 4 > output.len) return null;
    writeU32BE(output, deflate_end, std.hash.Adler32.hash(input));
    return deflate_end + 4;
}

/// Compresses `input` as a raw RFC 1951 DEFLATE stream. This is the payload
/// shape used by containers such as ZIP; unlike `compressZlib`, it has no
/// RFC 1950 header or Adler-32 trailer.
pub fn compressRaw(input: []const u8, output: []u8, tokens: []u32) ?usize {
    return compressRawWithOptions(input, output, tokens, .{});
}

pub fn compressRawWithOptions(input: []const u8, output: []u8, tokens: []u32, options: CompressionOptions) ?usize {
    return compressDynamic(input, output, tokens, options, 0);
}

const INCOMPRESSIBLE_SAMPLE_SIZE: usize = 8 * 1024;
const INCOMPRESSIBLE_MATCH_PERCENT: usize = 2;

fn likelyIncompressible(input: []const u8, options: CompressionOptions) bool {
    if (input.len < INCOMPRESSIBLE_SAMPLE_SIZE) return false;

    const sample = input[0..INCOMPRESSIBLE_SAMPLE_SIZE];
    const sample_chain = @min(options.max_chain, 8);
    initMatcher();

    var matched_bytes: usize = 0;
    var pos: usize = 0;
    while (pos < sample.len) {
        const match = findMatch(sample, pos, sample_chain);
        if (match.len >= MIN_MATCH) {
            matched_bytes += match.len;
            const end = pos + match.len;
            while (pos < end) : (pos += 1) insertPosition(sample, pos);
        } else {
            insertPosition(sample, pos);
            pos += 1;
        }
    }

    return matched_bytes * 100 < sample.len * INCOMPRESSIBLE_MATCH_PERCENT;
}

fn emitStoredBlocks(input: []const u8, writer: *BitWriter, is_final: bool) bool {
    var input_offset: usize = 0;
    while (input_offset < input.len) {
        const block_len = @min(input.len - input_offset, std.math.maxInt(u16));
        const block_end = input_offset + block_len;
        const block_is_final = is_final and block_end == input.len;

        if (!writer.writeBits(@intFromBool(block_is_final), 3)) return false;
        if (!writer.flush()) return false;
        if (writer.out_i + 4 + block_len > writer.out.len) return false;

        const len: u16 = @intCast(block_len);
        std.mem.writeInt(u16, writer.out[writer.out_i..][0..2], len, .little);
        std.mem.writeInt(u16, writer.out[writer.out_i + 2 ..][0..2], ~len, .little);
        writer.out_i += 4;
        @memcpy(writer.out[writer.out_i .. writer.out_i + block_len], input[input_offset..block_end]);
        writer.out_i += block_len;
        input_offset = block_end;
    }
    return true;
}

fn emitBestBlock(
    input: []const u8,
    tokens: []u32,
    options: CompressionOptions,
    writer: *BitWriter,
    is_final: bool,
) ?void {
    if (likelyIncompressible(input, options)) {
        if (!emitStoredBlocks(input, writer, is_final)) return null;
        return;
    }
    return emitDynamicBlock(input, tokens, options, writer, is_final, true);
}

/// Compresses a raw DEFLATE stream in bounded stored, fixed-Huffman, or
/// dynamic-Huffman blocks. Match history is reset at each batch boundary.
/// `tokens.len` controls both the maximum batch size and scratch memory use.
pub fn compressRawBlocksWithOptions(
    input: []const u8,
    output: []u8,
    tokens: []u32,
    options: CompressionOptions,
) ?usize {
    if (tokens.len == 0) return null;

    var writer = BitWriter.init(output, 0);
    if (input.len == 0) {
        emitBestBlock(input, tokens, options, &writer, true) orelse return null;
    } else {
        var input_offset: usize = 0;
        while (input_offset < input.len) {
            const block_len = @min(tokens.len, input.len - input_offset);
            const block_end = input_offset + block_len;
            emitBestBlock(
                input[input_offset..block_end],
                tokens[0..block_len],
                options,
                &writer,
                block_end == input.len,
            ) orelse return null;
            input_offset = block_end;
        }
    }

    if (!writer.flush()) return null;
    return writer.out_i;
}

fn emitFixedBlock(
    input: []const u8,
    options: CompressionOptions,
    writer_ptr: *BitWriter,
    is_final: bool,
) ?void {
    initMatcher();
    var writer = writer_ptr.*;
    defer writer_ptr.* = writer;
    if (!writer.writeBits(0b010 | @as(u3, @intFromBool(is_final)), 3)) return null;

    var pos: usize = 0;
    while (pos < input.len) {
        const match = findMatch(input, pos, options.max_chain);
        if (match.len >= MIN_MATCH) {
            const length = encodeLength(match.len);
            const length_code = fixedLiteralCode(length.symbol);
            if (!writer.writeBits(length_code.bits, length_code.len)) return null;
            if (!writer.writeBits(length.extra_value, length.extra_bits)) return null;

            const distance = encodeDistance(match.dist);
            if (!writer.writeBits(reverseBits(distance.symbol, 5), 5)) return null;
            if (!writer.writeBits(distance.extra_value, distance.extra_bits)) return null;

            const end = pos + match.len;
            while (pos < end) : (pos += 1) insertPosition(input, pos);
        } else {
            const literal = fixedLiteralCode(input[pos]);
            if (!writer.writeBits(literal.bits, literal.len)) return null;
            insertPosition(input, pos);
            pos += 1;
        }
    }

    const eob = fixedLiteralCode(256);
    if (!writer.writeBits(eob.bits, eob.len)) return null;
}

fn compressFixed(input: []const u8, output: []u8, options: CompressionOptions, output_start: usize) ?usize {
    var writer = BitWriter.init(output, output_start);
    emitFixedBlock(input, options, &writer, true) orelse return null;
    if (!writer.flush()) return null;
    return writer.out_i;
}

/// Compresses `input` as a zlib stream with one fixed-Huffman DEFLATE block.
/// This path needs no token buffer, so image encoders can accept large pixel
/// streams without reserving four scratch bytes for every input byte.
pub fn compressZlibFixed(input: []const u8, output: []u8) ?usize {
    return compressZlibFixedWithOptions(input, output, .{});
}

pub fn compressZlibFixedWithOptions(input: []const u8, output: []u8, options: CompressionOptions) ?usize {
    if (output.len < 2) return null;
    output[0] = 0x78;
    output[1] = 0x01;

    const deflate_end = compressFixed(input, output, options, 2) orelse return null;
    if (deflate_end + 4 > output.len) return null;
    writeU32BE(output, deflate_end, std.hash.Adler32.hash(input));
    return deflate_end + 4;
}

/// Compresses `input` as a raw RFC 1951 fixed-Huffman DEFLATE stream without
/// allocating a token buffer.
pub fn compressRawFixed(input: []const u8, output: []u8) ?usize {
    return compressRawFixedWithOptions(input, output, .{});
}

pub fn compressRawFixedWithOptions(input: []const u8, output: []u8, options: CompressionOptions) ?usize {
    return compressFixed(input, output, options, 0);
}
