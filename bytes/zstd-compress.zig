//! Zstandard (RFC 8878) compression: one frame with the content size and
//! an XXH64 content checksum, so the same input always gives the same bytes
//! and `zstd -d`, browsers, and Node can read it. No dictionary is used.
//!
//! Matches come from a greedy hash-chain search over the previous 1 MiB.
//! Literals are stored raw and sequences use the predefined FSE tables from
//! RFC 8878 section 3.1.1.3.2.2, so no table descriptions or Huffman trees
//! are written. A block that would not shrink is stored raw.

const std = @import("std");
const zstd = std.compress.zstd;

const CONTENT_TYPE = "application/zstd";
const MAGIC: u32 = 0xFD2FB528;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const BLOCK_MAX: usize = zstd.block_size_max;
const BLOCK_COUNT: usize = (INPUT_CAP + BLOCK_MAX - 1) / BLOCK_MAX;
// Magic, descriptor, and an 8-byte content size, then a raw block header per
// block (at least one, for empty input) and the 4-byte checksum.
const FRAME_OVERHEAD: usize = 4 + 1 + 8 + 4;
const OUTPUT_CAP: usize = FRAME_OVERHEAD + 3 * @as(usize, @max(BLOCK_COUNT, 1)) + INPUT_CAP;

const MIN_MATCH: usize = 4;
const WINDOW_LOG = 20;
const WINDOW: usize = 1 << WINDOW_LOG;
const HASH_LOG = 16;
const CHAIN_DEPTH = 32;

// A sequence covers at least MIN_MATCH bytes. Each costs at most 6 + 6 + 5
// state bits plus 16 + 16 + 28 extra bits, which fits in 10 bytes.
const SEQUENCE_CAP: usize = BLOCK_MAX / MIN_MATCH;
const SCRATCH_CAP: usize = 3 + BLOCK_MAX + 4 + SEQUENCE_CAP * 10 + 8;

const Sequence = struct {
    literal_length: u32,
    match_length: u32,
    offset: u32,
};

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var scratch_buf: [SCRATCH_CAP]u8 = undefined;
var sequences: [SEQUENCE_CAP]Sequence = undefined;
var hash_head: [1 << HASH_LOG]u32 = undefined;
var hash_prev: [WINDOW]u32 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(CONTENT_TYPE.len));
}

// FSE encoding tables built from a normalized distribution, following the
// layout zstd's FSE_buildCTable uses.
fn FseTable(comptime log: u4, comptime symbol_count: usize) type {
    const size = 1 << log;
    return struct {
        states: [size]u16,
        delta_bits: [symbol_count]u32,
        delta_state: [symbol_count]i32,

        const Self = @This();

        fn build(comptime distribution: [symbol_count]i16) Self {
            @setEvalBranchQuota(100_000);
            var self: Self = undefined;
            var symbols: [size]u8 = undefined;
            var cumulative: [symbol_count + 1]u32 = undefined;

            // Symbols with probability -1 ("less than 1") take the last cells.
            var high: usize = size - 1;
            cumulative[0] = 0;
            for (distribution, 0..) |count, s| {
                if (count == -1) {
                    symbols[high] = @intCast(s);
                    high -= 1;
                    cumulative[s + 1] = cumulative[s] + 1;
                } else {
                    cumulative[s + 1] = cumulative[s] + @as(u32, @intCast(count));
                }
            }

            const step = (size >> 1) + (size >> 3) + 3;
            var position: usize = 0;
            for (distribution, 0..) |count, s| {
                if (count <= 0) continue;
                for (0..@intCast(count)) |_| {
                    symbols[position] = @intCast(s);
                    position = (position + step) & (size - 1);
                    while (position > high) position = (position + step) & (size - 1);
                }
            }

            var next = cumulative;
            for (symbols, 0..) |s, u| {
                self.states[next[s]] = @intCast(size + u);
                next[s] += 1;
            }

            var total: i32 = 0;
            for (distribution, 0..) |count, s| {
                switch (count) {
                    0 => {
                        self.delta_bits[s] = 0;
                        self.delta_state[s] = 0;
                    },
                    -1, 1 => {
                        self.delta_bits[s] = (@as(u32, log) << 16) - size;
                        self.delta_state[s] = total - 1;
                        total += 1;
                    },
                    else => {
                        const c: u32 = @intCast(count);
                        const max_bits_out: u32 = log - std.math.log2_int(u32, c - 1);
                        self.delta_bits[s] = (max_bits_out << 16) -% (c << @intCast(max_bits_out));
                        self.delta_state[s] = total - @as(i32, @intCast(c));
                        total += @intCast(c);
                    },
                }
            }
            return self;
        }

        fn init(self: *const Self, symbol: u8) u32 {
            const bits = (self.delta_bits[symbol] +% (1 << 15)) >> 16;
            const value = (bits << 16) -% self.delta_bits[symbol];
            return self.states[@intCast(@as(i32, @intCast(value >> @intCast(bits))) + self.delta_state[symbol])];
        }

        fn encode(self: *const Self, bits: *BitWriter, state: *u32, symbol: u8) void {
            const n = (state.* +% self.delta_bits[symbol]) >> 16;
            bits.add(state.*, n);
            state.* = self.states[@intCast(@as(i32, @intCast(state.* >> @intCast(n))) + self.delta_state[symbol])];
        }

        fn flush(bits: *BitWriter, state: u32) void {
            bits.add(state, log);
        }
    };
}

const LiteralTable = FseTable(zstd.default_accuracy_log.literal, zstd.literals_length_default_distribution.len);
const MatchTable = FseTable(zstd.default_accuracy_log.match, zstd.match_lengths_default_distribution.len);
const OffsetTable = FseTable(zstd.default_accuracy_log.offset, zstd.offset_codes_default_distribution.len);

const literal_table = LiteralTable.build(zstd.literals_length_default_distribution);
const match_table = MatchTable.build(zstd.match_lengths_default_distribution);
const offset_table = OffsetTable.build(zstd.offset_codes_default_distribution);

/// Little-endian bit writer; the decoder reads the stream backwards.
const BitWriter = struct {
    out: []u8,
    pos: usize = 0,
    acc: u64 = 0,
    count: u6 = 0,

    fn add(self: *BitWriter, value: u32, n: u32) void {
        if (n == 0) return;
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        self.acc |= (@as(u64, value) & mask) << self.count;
        self.count += @intCast(n);
        while (self.count >= 8) {
            self.out[self.pos] = @truncate(self.acc);
            self.pos += 1;
            self.acc >>= 8;
            self.count -= 8;
        }
    }

    /// Writes the end mark and pads to a byte boundary.
    fn finish(self: *BitWriter) usize {
        self.add(1, 1);
        if (self.count > 0) {
            self.out[self.pos] = @truncate(self.acc);
            self.pos += 1;
        }
        return self.pos;
    }
};

/// Returns the code whose baseline range holds `value`.
fn lengthCode(comptime table: anytype, value: u32) struct { code: u8, extra: u32, bits: u32 } {
    var code: usize = table.len - 1;
    while (table[code][0] > value) code -= 1;
    return .{ .code = @intCast(code), .extra = value - table[code][0], .bits = table[code][1] };
}

fn hash4(bytes: []const u8, pos: usize) usize {
    const v = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    return @intCast((v *% 2654435761) >> (32 - HASH_LOG));
}

fn insert(input: []const u8, pos: usize) void {
    if (pos + MIN_MATCH > input.len) return;
    const h = hash4(input, pos);
    hash_prev[pos & (WINDOW - 1)] = hash_head[h];
    hash_head[h] = @intCast(pos + 1);
}

/// Finds the longest earlier match for `pos` that ends by `limit`.
fn longestMatch(input: []const u8, pos: usize, limit: usize) struct { length: usize, offset: usize } {
    var best_len: usize = 0;
    var best_off: usize = 0;
    if (pos + MIN_MATCH > limit) return .{ .length = 0, .offset = 0 };
    var candidate: usize = hash_head[hash4(input, pos)];
    var depth: usize = CHAIN_DEPTH;
    while (candidate != 0 and depth > 0) : (depth -= 1) {
        const c = candidate - 1;
        if (pos - c >= WINDOW) break;
        if (input[c + best_len] == input[pos + best_len]) {
            var n: usize = 0;
            while (pos + n < limit and input[c + n] == input[pos + n]) n += 1;
            if (n > best_len) {
                best_len = n;
                best_off = pos - c;
                if (pos + n == limit) break;
            }
        }
        const next: usize = hash_prev[c & (WINDOW - 1)];
        if (next >= candidate) break;
        candidate = next;
    }
    if (best_len < MIN_MATCH) return .{ .length = 0, .offset = 0 };
    return .{ .length = best_len, .offset = best_off };
}

/// Writes a compressed block body for `input[start..end]` into scratch_buf.
/// Returns null when it would not be smaller than a raw block.
fn compressBlock(input: []const u8, start: usize, end: usize) ?[]const u8 {
    var count: usize = 0;
    var literal_start = start;
    var literal_total: usize = 0;
    var pos = start;
    while (pos < end) {
        const match = longestMatch(input, pos, end);
        if (match.length == 0) {
            insert(input, pos);
            pos += 1;
            continue;
        }
        sequences[count] = .{
            .literal_length = @intCast(pos - literal_start),
            .match_length = @intCast(match.length),
            .offset = @intCast(match.offset),
        };
        count += 1;
        literal_total += pos - literal_start;
        for (pos..pos + match.length) |p| insert(input, p);
        pos += match.length;
        literal_start = pos;
    }
    literal_total += end - literal_start;
    if (count == 0) return null;

    // Literals section: raw, with a 1, 2, or 3 byte header.
    var out = scratch_buf[0..];
    var n: usize = 0;
    if (literal_total < 32) {
        out[0] = @intCast(literal_total << 3);
        n = 1;
    } else if (literal_total < 4096) {
        std.mem.writeInt(u16, out[0..2], @intCast((literal_total << 4) | 0b0100), .little);
        n = 2;
    } else {
        std.mem.writeInt(u24, out[0..3], @intCast((literal_total << 4) | 0b1100), .little);
        n = 3;
    }
    {
        var from = start;
        for (sequences[0..count]) |seq| {
            @memcpy(out[n..][0..seq.literal_length], input[from..][0..seq.literal_length]);
            n += seq.literal_length;
            from += seq.literal_length + seq.match_length;
        }
        @memcpy(out[n..][0 .. end - from], input[from..end]);
        n += end - from;
    }

    // Sequences section header, then predefined modes for all three codes.
    if (count < 128) {
        out[n] = @intCast(count);
        n += 1;
    } else if (count < 0x7F00) {
        out[n] = @intCast((count >> 8) + 0x80);
        out[n + 1] = @truncate(count);
        n += 2;
    } else {
        out[n] = 0xFF;
        std.mem.writeInt(u16, out[n + 1 ..][0..2], @intCast(count - 0x7F00), .little);
        n += 3;
    }
    out[n] = 0;
    n += 1;

    // Sequences are written last to first, so the decoder reads them in order.
    var bits: BitWriter = .{ .out = out[n..] };
    const Codes = struct { ll: @TypeOf(lengthCode(zstd.literals_length_code_table, 0)), ml: @TypeOf(lengthCode(zstd.match_length_code_table, 0)), of: u8, of_value: u32 };
    const codes = struct {
        fn of(seq: Sequence) Codes {
            const value = seq.offset + 3;
            return .{
                .ll = lengthCode(zstd.literals_length_code_table, seq.literal_length),
                .ml = lengthCode(zstd.match_length_code_table, seq.match_length),
                .of = std.math.log2_int(u32, value),
                .of_value = value,
            };
        }
    };
    const last = codes.of(sequences[count - 1]);
    var ml_state = match_table.init(last.ml.code);
    var of_state = offset_table.init(last.of);
    var ll_state = literal_table.init(last.ll.code);
    bits.add(last.ll.extra, last.ll.bits);
    bits.add(last.ml.extra, last.ml.bits);
    bits.add(last.of_value, last.of);
    var i = count - 1;
    while (i > 0) {
        i -= 1;
        const c = codes.of(sequences[i]);
        offset_table.encode(&bits, &of_state, c.of);
        match_table.encode(&bits, &ml_state, c.ml.code);
        literal_table.encode(&bits, &ll_state, c.ll.code);
        bits.add(c.ll.extra, c.ll.bits);
        bits.add(c.ml.extra, c.ml.bits);
        bits.add(c.of_value, c.of);
    }
    MatchTable.flush(&bits, ml_state);
    OffsetTable.flush(&bits, of_state);
    LiteralTable.flush(&bits, ll_state);
    n += bits.finish();

    if (n >= end - start) return null;
    return out[0..n];
}

fn writeBlockHeader(out: []u8, last: bool, block_type: u2, size: usize) void {
    const value: u24 = @intCast(@as(usize, @intFromBool(last)) | (@as(usize, block_type) << 1) | (size << 3));
    std.mem.writeInt(u24, out[0..3], value, .little);
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];
    @memset(&hash_head, 0);

    // Single-segment frame: the window is the whole content, so the content
    // size field is required. Checksum flag set; no dictionary ID.
    std.mem.writeInt(u32, output_buf[0..4], MAGIC, .little);
    var n: usize = 5;
    const size_flag: u8 = if (input_size < 256) 0 else if (input_size < 65536 + 256) 1 else 2;
    output_buf[4] = (size_flag << 6) | 0x20 | 0x04;
    switch (size_flag) {
        0 => {
            output_buf[n] = @intCast(input_size);
            n += 1;
        },
        1 => {
            std.mem.writeInt(u16, output_buf[n..][0..2], @intCast(input_size - 256), .little);
            n += 2;
        },
        else => {
            std.mem.writeInt(u32, output_buf[n..][0..4], @intCast(input_size), .little);
            n += 4;
        },
    }

    var start: usize = 0;
    while (true) {
        const end = @min(start + BLOCK_MAX, input_size);
        const last = end == input_size;
        if (compressBlock(input, start, end)) |body| {
            writeBlockHeader(output_buf[n..], last, 2, body.len);
            @memcpy(output_buf[n + 3 ..][0..body.len], body);
            n += 3 + body.len;
        } else {
            writeBlockHeader(output_buf[n..], last, 0, end - start);
            @memcpy(output_buf[n + 3 ..][0 .. end - start], input[start..end]);
            n += 3 + end - start;
        }
        start = end;
        if (last) break;
    }

    std.mem.writeInt(u32, output_buf[n..][0..4], @truncate(std.hash.XxHash64.hash(0, input)), .little);
    return @intCast(n + 4);
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

fn decompressZstd(compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decompress: zstd.Decompress = .init(&in, &.{}, .{});
    _ = try decompress.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn expectRoundTrip(len: usize) !usize {
    const written = renderImpl(@intCast(len));
    const plain = try decompressZstd(output_buf[0..written]);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualSlices(u8, input_buf[0..len], plain);
    return written;
}

test "empty input is a frame with one empty raw block" {
    const written = renderImpl(0);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x00, 0x01, 0x00, 0x00 },
        output_buf[0..9],
    );
    try std.testing.expectEqual(@as(usize, 13), written);
    _ = try expectRoundTrip(0);
}

test "round trips repetitive text smaller than the input" {
    const line = "qip + zstd, qip + zstd, qip + wasm\n";
    for (0..200) |i| @memcpy(input_buf[i * line.len ..][0..line.len], line);
    const len = 200 * line.len;
    try std.testing.expect(try expectRoundTrip(len) < len / 10);
}

test "round trips across blocks with matches into earlier blocks" {
    const len = 3 * BLOCK_MAX + 1234;
    for (input_buf[0..len], 0..) |*b, i| b.* = @truncate((i * 7) ^ (i >> 9));
    _ = try expectRoundTrip(len);
}

test "round trips each content size field width" {
    for ([_]usize{ 1, 255, 256, 65791, 65792 }) |len| {
        for (input_buf[0..len], 0..) |*b, i| b.* = @truncate(i % 251);
        _ = try expectRoundTrip(len);
    }
}

test "maximum input stays within the derived output capacity" {
    var state: u32 = 1;
    for (input_buf[0..]) |*b| {
        state = state *% 1103515245 +% 12345;
        b.* = @truncate(state >> 16);
    }
    const written = try expectRoundTrip(INPUT_CAP);
    try std.testing.expect(written <= OUTPUT_CAP);
}
