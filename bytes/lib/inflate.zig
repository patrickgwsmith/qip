//! Internal zlib/DEFLATE decompression engine shared by zlib-decompress and
//! image decoders that embed a zlib stream (such as PNG). This is a private
//! API: callers inside this repository only.
//!
//! Strict by construction, matching zlib's inflate semantics:
//! - zlib header CM/CINFO/FCHECK validated, FDICT rejected.
//! - Over-subscribed Huffman trees rejected; incomplete trees allowed only
//!   for the single-code case in literal/length and distance trees.
//! - Repeats before any code, missing end-of-block codes, invalid block
//!   types, stored-block NLEN mismatches, and out-of-window distances all
//!   reject the stream.
//! - The Adler-32 trailer is verified and the stream must span the entire
//!   input: trailing bytes reject.

const std = @import("std");
const deflate = @import("deflate.zig");

const WINDOW_SIZE: usize = 32 * 1024;
const MAX_BITS: u5 = 15;
const TABLE_SIZE: usize = 1 << MAX_BITS;
const CL_BITS: u5 = 7;
const CL_TABLE_SIZE: usize = 1 << CL_BITS;

const CL_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// Decode table entries: (code length << 12) | symbol. Length 0 marks an
// invalid entry. One table per tree, rebuilt per dynamic block.
var litlen_table: [TABLE_SIZE]u16 = undefined;
var dist_table: [TABLE_SIZE]u16 = undefined;
var cl_table: [CL_TABLE_SIZE]u16 = undefined;

const FIXED_LIT_LENGTHS = blk: {
    var lens: [288]u8 = undefined;
    for (&lens, 0..) |*l, sym| {
        l.* = if (sym < 144) 8 else if (sym < 256) 9 else if (sym < 280) 7 else 8;
    }
    break :blk lens;
};

const FIXED_DIST_LENGTHS = [_]u8{5} ** 32;

const BitReader = struct {
    input: []const u8,
    pos: usize,
    bitbuf: u64,
    bitcnt: u6,

    fn init(input: []const u8, start: usize) BitReader {
        return .{ .input = input, .pos = start, .bitbuf = 0, .bitcnt = 0 };
    }

    fn refill(self: *BitReader) void {
        while (self.bitcnt < 56 and self.pos < self.input.len) {
            self.bitbuf |= @as(u64, self.input[self.pos]) << self.bitcnt;
            self.pos += 1;
            self.bitcnt += 8;
        }
    }

    fn getBits(self: *BitReader, nbits: u6) ?u32 {
        if (self.bitcnt < nbits) self.refill();
        if (self.bitcnt < nbits) return null;
        const mask = (@as(u64, 1) << nbits) - 1;
        const v: u32 = @intCast(self.bitbuf & mask);
        self.bitbuf >>= nbits;
        self.bitcnt -= nbits;
        return v;
    }

    fn decode(self: *BitReader, table: []const u16, mask: u16) ?u16 {
        if (self.bitcnt < MAX_BITS) self.refill();
        const e = table[@as(usize, @intCast(self.bitbuf)) & mask];
        const n: u6 = @intCast(e >> 12);
        if (n == 0 or n > self.bitcnt) return null;
        self.bitbuf >>= @intCast(n);
        self.bitcnt -= n;
        return e & 0xfff;
    }

    /// Discards partial bits and returns the byte offset of the next unread
    /// byte, for stored blocks and the trailer.
    fn alignToByte(self: *BitReader) usize {
        self.bitbuf >>= @intCast(self.bitcnt & 7);
        self.bitcnt -= self.bitcnt & 7;
        const buffered_bytes: usize = self.bitcnt / 8;
        self.bitbuf = 0;
        self.bitcnt = 0;
        return self.pos - buffered_bytes;
    }

    fn seekTo(self: *BitReader, byte_pos: usize) void {
        self.pos = byte_pos;
        self.bitbuf = 0;
        self.bitcnt = 0;
    }
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

/// Builds an LSB-first lookup table for a canonical Huffman code. Rejects
/// over-subscribed sets; incomplete sets are allowed only when
/// `allow_incomplete_single` and the set is a single length-1 code, mirroring
/// zlib's rule for literal/length and distance trees.
fn buildTable(lens: []const u8, table: []u16, table_bits: u5, allow_incomplete_single: bool) bool {
    @memset(table, 0);

    var count: [MAX_BITS + 1]u16 = [_]u16{0} ** (MAX_BITS + 1);
    var max_len: u8 = 0;
    for (lens) |l| {
        if (l > table_bits) return false;
        count[l] += 1;
        if (l > max_len) max_len = l;
    }
    // An empty tree is valid for distance trees in blocks that use no
    // matches (zlib accepts these); decoding through it errors on use.
    if (max_len == 0) return allow_incomplete_single;

    var left: i32 = 1;
    var bits: u8 = 1;
    while (bits <= MAX_BITS) : (bits += 1) {
        left = (left << 1) - @as(i32, count[bits]);
        if (left < 0) return false;
    }
    if (left > 0 and (!allow_incomplete_single or max_len != 1)) return false;

    var next: [MAX_BITS + 1]u16 = [_]u16{0} ** (MAX_BITS + 1);
    var code: u32 = 0;
    bits = 1;
    while (bits <= MAX_BITS) : (bits += 1) {
        code = (code + count[bits - 1]) << 1;
        next[bits] = @intCast(code);
    }

    for (lens, 0..) |l, sym| {
        if (l == 0) continue;
        const c = next[l];
        next[l] += 1;
        const entry: u16 = (@as(u16, l) << 12) | @as(u16, @intCast(sym));
        var idx: usize = reverseBits(c, l);
        const step = @as(usize, 1) << @intCast(l);
        while (idx < (@as(usize, 1) << table_bits)) : (idx += step) {
            table[idx] = entry;
        }
    }

    return true;
}

fn inflateBlocks(br: *BitReader, writer: anytype) bool {
    while (true) {
        const bfinal = br.getBits(1) orelse return false;
        const btype = br.getBits(2) orelse return false;

        switch (btype) {
            0 => {
                var pos = br.alignToByte();
                if (pos + 4 > br.input.len) return false;
                const len: usize = @as(usize, br.input[pos]) | (@as(usize, br.input[pos + 1]) << 8);
                const nlen: usize = @as(usize, br.input[pos + 2]) | (@as(usize, br.input[pos + 3]) << 8);
                if (len != (~nlen & 0xffff)) return false;
                pos += 4;
                if (pos + len > br.input.len) return false;
                if (!writer.writeStored(br.input[pos..][0..len])) return false;
                br.seekTo(pos + len);
            },
            1, 2 => {
                if (btype == 1) {
                    if (!buildTable(&FIXED_LIT_LENGTHS, &litlen_table, MAX_BITS, false)) return false;
                    if (!buildTable(&FIXED_DIST_LENGTHS, &dist_table, MAX_BITS, false)) return false;
                } else {
                    if (!readDynamicTables(br)) return false;
                }
                if (!inflateHuffmanBlock(br, writer)) return false;
            },
            else => return false,
        }

        if (bfinal == 1) return true;
    }
}

fn readDynamicTables(br: *BitReader) bool {
    const hlit: usize = @as(usize, br.getBits(5) orelse return false) + 257;
    const hdist: usize = @as(usize, br.getBits(5) orelse return false) + 1;
    const hclen: usize = @as(usize, br.getBits(4) orelse return false) + 4;
    if (hlit > 286 or hdist > 30) return false;

    var cl_lens: [19]u8 = [_]u8{0} ** 19;
    var i: usize = 0;
    while (i < hclen) : (i += 1) {
        cl_lens[CL_ORDER[i]] = @intCast(br.getBits(3) orelse return false);
    }
    if (!buildTable(&cl_lens, &cl_table, CL_BITS, false)) return false;

    var lens: [286 + 30]u8 = undefined;
    const total = hlit + hdist;
    i = 0;
    while (i < total) {
        const sym = br.decode(&cl_table, CL_TABLE_SIZE - 1) orelse return false;
        if (sym < 16) {
            lens[i] = @intCast(sym);
            i += 1;
            continue;
        }
        var repeat: usize = 0;
        var value: u8 = 0;
        if (sym == 16) {
            if (i == 0) return false;
            value = lens[i - 1];
            repeat = 3 + @as(usize, br.getBits(2) orelse return false);
        } else if (sym == 17) {
            repeat = 3 + @as(usize, br.getBits(3) orelse return false);
        } else {
            repeat = 11 + @as(usize, br.getBits(7) orelse return false);
        }
        if (i + repeat > total) return false;
        @memset(lens[i..][0..repeat], value);
        i += repeat;
    }

    // A literal/length tree without an end-of-block code can never terminate.
    if (lens[256] == 0) return false;

    if (!buildTable(lens[0..hlit], &litlen_table, MAX_BITS, true)) return false;
    if (!buildTable(lens[hlit..total], &dist_table, MAX_BITS, true)) return false;
    return true;
}

fn inflateHuffmanBlock(br: *BitReader, writer: anytype) bool {
    while (true) {
        const sym = br.decode(&litlen_table, TABLE_SIZE - 1) orelse return false;

        if (sym < 256) {
            if (!writer.writeLiteral(@intCast(sym))) return false;
            continue;
        }
        if (sym == 256) return true;
        if (sym > 285) return false;

        const len_idx = sym - 257;
        const length: usize = @as(usize, deflate.LENGTH_BASE[len_idx]) +
            @as(usize, br.getBits(@intCast(deflate.LENGTH_EXTRA[len_idx])) orelse return false);

        const dist_sym = br.decode(&dist_table, TABLE_SIZE - 1) orelse return false;
        if (dist_sym > 29) return false;
        const distance: usize = @as(usize, deflate.DIST_BASE[dist_sym]) +
            @as(usize, br.getBits(@intCast(deflate.DIST_EXTRA[dist_sym])) orelse return false);
        if (!writer.writeMatch(length, distance)) return false;
    }
}

const ContiguousWriter = struct {
    output: []u8,
    out_i: usize = 0,

    fn writeStored(self: *ContiguousWriter, bytes: []const u8) bool {
        if (self.out_i + bytes.len > self.output.len) return false;
        @memcpy(self.output[self.out_i..][0..bytes.len], bytes);
        self.out_i += bytes.len;
        return true;
    }

    fn writeLiteral(self: *ContiguousWriter, byte: u8) bool {
        if (self.out_i >= self.output.len) return false;
        self.output[self.out_i] = byte;
        self.out_i += 1;
        return true;
    }

    fn writeMatch(self: *ContiguousWriter, length: usize, distance: usize) bool {
        if (distance > self.out_i or self.out_i + length > self.output.len) return false;
        const src_start = self.out_i - distance;
        if (distance >= length) {
            @memcpy(self.output[self.out_i..][0..length], self.output[src_start..][0..length]);
            self.out_i += length;
        } else {
            var k: usize = 0;
            while (k < length) : (k += 1) {
                self.output[self.out_i] = self.output[src_start + k];
                self.out_i += 1;
            }
        }
        return true;
    }
};

fn BatchWriter(comptime Context: type, comptime consume: fn (*Context, []u8) bool) type {
    return struct {
        const Self = @This();

        work: []u8,
        history_scratch: []u8,
        history_len: usize = 0,
        out_i: usize = 0,
        total: usize = 0,
        batch_bytes: usize,
        adler: std.hash.Adler32 = .{},
        context: *Context,

        fn newBytes(self: *const Self) usize {
            return self.out_i - self.history_len;
        }

        fn flush(self: *Self) bool {
            const batch = self.work[self.history_len..self.out_i];
            if (batch.len == 0) return true;
            self.adler.update(batch);

            const keep = @min(self.out_i, WINDOW_SIZE);
            const keep_start = self.out_i - keep;
            @memcpy(self.history_scratch[0..keep], self.work[keep_start..self.out_i]);

            if (!consume(self.context, batch)) return false;

            @memcpy(self.work[0..keep], self.history_scratch[0..keep]);
            self.history_len = keep;
            self.out_i = keep;
            return true;
        }

        fn writeStored(self: *Self, bytes: []const u8) bool {
            const initial_room = self.batch_bytes - self.newBytes();
            if (bytes.len <= initial_room) {
                @memcpy(self.work[self.out_i..][0..bytes.len], bytes);
                self.out_i += bytes.len;
                self.total += bytes.len;
                return self.newBytes() != self.batch_bytes or self.flush();
            }

            var pos: usize = 0;
            while (pos < bytes.len) {
                const room = self.batch_bytes - self.newBytes();
                const count = @min(room, bytes.len - pos);
                @memcpy(self.work[self.out_i..][0..count], bytes[pos..][0..count]);
                self.out_i += count;
                self.total += count;
                pos += count;
                if (self.newBytes() == self.batch_bytes and !self.flush()) return false;
            }
            return true;
        }

        fn writeLiteral(self: *Self, byte: u8) bool {
            if (self.out_i >= self.work.len) return false;
            self.work[self.out_i] = byte;
            self.out_i += 1;
            self.total += 1;
            return self.newBytes() != self.batch_bytes or self.flush();
        }

        fn writeMatch(self: *Self, length: usize, distance: usize) bool {
            if (distance == 0 or distance > self.total or distance > WINDOW_SIZE) return false;
            const initial_room = self.batch_bytes - self.newBytes();
            if (length <= initial_room) {
                if (distance > self.out_i or self.out_i + length > self.work.len) return false;
                const src_start = self.out_i - distance;
                if (distance >= length) {
                    @memcpy(self.work[self.out_i..][0..length], self.work[src_start..][0..length]);
                    self.out_i += length;
                } else {
                    var k: usize = 0;
                    while (k < length) : (k += 1) {
                        self.work[self.out_i] = self.work[src_start + k];
                        self.out_i += 1;
                    }
                }
                self.total += length;
                return self.newBytes() != self.batch_bytes or self.flush();
            }

            var remaining = length;
            while (remaining != 0) {
                const room = self.batch_bytes - self.newBytes();
                const count = @min(room, remaining);
                if (distance > self.out_i or self.out_i + count > self.work.len) return false;
                const src_start = self.out_i - distance;
                if (distance >= count) {
                    @memcpy(self.work[self.out_i..][0..count], self.work[src_start..][0..count]);
                    self.out_i += count;
                } else {
                    var k: usize = 0;
                    while (k < count) : (k += 1) {
                        self.work[self.out_i] = self.work[src_start + k];
                        self.out_i += 1;
                    }
                }
                self.total += count;
                remaining -= count;
                if (self.newBytes() == self.batch_bytes and !self.flush()) return false;
            }
            return true;
        }
    };
}

/// Decompresses a zlib stream that spans exactly the whole of `input`,
/// writing into `output`. Returns the number of bytes written, or null when
/// the stream is malformed, over-long for `output`, has trailing bytes, or
/// fails its Adler-32 check.
pub fn inflateZlib(input: []const u8, output: []u8) ?usize {
    if (input.len < 6) return null;

    // CM must be deflate with a window <= 32 KB; the FCHECK mod-31 header
    // checksum must hold; FDICT preset dictionaries are not supported.
    if (input[0] & 0x0f != 8 or input[0] >> 4 > 7) return null;
    if ((@as(u32, input[0]) * 256 + input[1]) % 31 != 0) return null;
    if (input[1] & 0x20 != 0) return null;

    var br = BitReader.init(input, 2);
    var writer = ContiguousWriter{ .output = output };
    if (!inflateBlocks(&br, &writer)) return null;
    const out_len = writer.out_i;

    const trailer = br.alignToByte();
    if (trailer + 4 != input.len) return null;
    const stored = std.mem.readInt(u32, input[trailer..][0..4], .big);
    if (std.hash.Adler32.hash(output[0..out_len]) != stored) return null;

    return out_len;
}

pub const RawResult = struct {
    length: usize,
    crc32: u32,
};

/// Decompresses one raw DEFLATE stream that spans exactly `input`.
/// The result includes the decompressed length and ZIP-compatible CRC-32.
/// A stream that leaves compressed bytes unread, exceeds `output`, or is
/// malformed returns null.
pub fn inflateRawExact(input: []const u8, output: []u8) ?RawResult {
    var br = BitReader.init(input, 0);
    var writer = ContiguousWriter{ .output = output };
    if (!inflateBlocks(&br, &writer)) return null;
    if (br.alignToByte() != input.len) return null;
    return .{
        .length = writer.out_i,
        .crc32 = std.hash.Crc32.hash(output[0..writer.out_i]),
    };
}

/// Inflates one complete zlib stream through fixed-size synchronous batches.
/// `batch_bytes` is chosen by the caller and must fit in `work` after the
/// retained 32 KiB DEFLATE history. The callback runs inside this function;
/// there is no externally resumable decoder state.
pub fn inflateZlibBatches(
    comptime Context: type,
    input: []const u8,
    work: []u8,
    history_scratch: []u8,
    batch_bytes: usize,
    context: *Context,
    comptime consume: fn (*Context, []u8) bool,
) ?usize {
    if (input.len < 6 or batch_bytes == 0) return null;
    if (work.len < WINDOW_SIZE + batch_bytes or history_scratch.len < WINDOW_SIZE) return null;
    if (input[0] & 0x0f != 8 or input[0] >> 4 > 7) return null;
    if ((@as(u32, input[0]) * 256 + input[1]) % 31 != 0) return null;
    if (input[1] & 0x20 != 0) return null;

    const Writer = BatchWriter(Context, consume);
    var writer = Writer{
        .work = work,
        .history_scratch = history_scratch,
        .batch_bytes = batch_bytes,
        .context = context,
    };
    var br = BitReader.init(input, 2);
    if (!inflateBlocks(&br, &writer)) return null;
    if (!writer.flush()) return null;

    const trailer = br.alignToByte();
    if (trailer + 4 != input.len) return null;
    const stored = std.mem.readInt(u32, input[trailer..][0..4], .big);
    if (writer.adler.adler != stored) return null;
    return writer.total;
}
