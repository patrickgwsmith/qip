//! BGZF decompression with the structure checks that htslib readers rely
//! on. gzip-decompress also decodes BGZF content; use this component when
//! the input must be valid BGZF, for example before tabix or samtools sees
//! it. Every member must:
//! - carry exactly one "BC" extra subfield whose BSIZE matches the member's
//!   real compressed size, at most 64 KiB;
//! - decompress to at most 64 KiB and pass its CRC-32 and ISIZE checks.
//! The input must end with the 28-byte BGZF EOF block, so a truncated file
//! rejects.

const std = @import("std");
const gzip = @import("lib/gzip.zig");

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
const BLOCK_SIZE_MAX = gzip.BGZF_BLOCK_SIZE_MAX;
// TODO: Distinguish malformed input from output exhaustion and report useful
// input progress when the inflater exposes it.

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const RenderResult = packed struct(u64) {
    output_size_or_failure: u32,
    output_ptr: u31,
    failed: u1,
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

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(gzip.CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(gzip.CONTENT_TYPE.len));
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

fn inflateBgzf(input: []const u8, output: []u8) ?usize {
    if (!std.mem.endsWith(u8, input, &gzip.BGZF_EOF)) return null;

    var in_pos: usize = 0;
    var out_len: usize = 0;
    while (in_pos < input.len) {
        const rest = input[in_pos..];
        const header = gzip.parseHeader(rest) orelse return null;
        const block_size = gzip.bgzfBlockSize(header.extra orelse return null) orelse return null;
        if (block_size > rest.len) return null;

        const out_room = @min(BLOCK_SIZE_MAX, output.len - out_len);
        const member = gzip.inflateMember(rest[0..block_size], output[out_len..][0..out_room]) orelse return null;
        if (member.consumed != block_size) return null;
        in_pos += block_size;
        out_len += member.length;
    }
    return out_len;
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size_in: u32) RenderOutcome {
    if (input_size_in > INPUT_CAP) @trap();
    const input_size: usize = @intCast(input_size_in);
    const out_len = inflateBgzf(input_buf[0..input_size], &output_buf) orelse {
        return .{ .output_size_or_failure = 0, .output_ptr = 0, .failed = 1 };
    };
    return .{ .output_size_or_failure = @intCast(out_len), .output_ptr = @intFromPtr(&output_buf), .failed = 0 };
}

export fn render(input_size_in: u32) RenderResult {
    const result = renderOutcome(input_size_in);
    return .{
        .output_size_or_failure = result.output_size_or_failure,
        .output_ptr = if (result.failed == 1) 0 else @intCast(result.output_ptr),
        .failed = result.failed,
    };
}

// One BGZF member holding "Hello world\n": the DEFLATE payload from
// `printf 'Hello world\n' | gzip -n` in an 18-byte BGZF header with BSIZE 39.
const HELLO_MEMBER = [_]u8{
    0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    0x06, 0x00, 0x42, 0x43, 0x02, 0x00, 0x27, 0x00, 0xf3, 0x48,
    0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1,
    0x02, 0x00, 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
};
const HELLO_BGZF = HELLO_MEMBER ++ gzip.BGZF_EOF;

fn expectDecodes(input: []const u8, expected: []const u8) !void {
    @memcpy(input_buf[0..input.len], input);
    const result = renderOutcome(@intCast(input.len));
    try std.testing.expectEqual(@as(u1, 0), result.failed);
    try std.testing.expectEqualStrings(expected, output_buf[0..result.output_size_or_failure]);
}

fn expectRejects(input: []const u8) !void {
    @memcpy(input_buf[0..input.len], input);
    try std.testing.expectEqual(@as(u1, 1), renderOutcome(@intCast(input.len)).failed);
}

test "decodes members followed by the EOF block" {
    try expectDecodes(&HELLO_BGZF, "Hello world\n");
    try expectDecodes(&(HELLO_MEMBER ++ HELLO_MEMBER ++ gzip.BGZF_EOF), "Hello world\nHello world\n");
    try expectDecodes(&gzip.BGZF_EOF, "");
}

test "rejects a missing EOF block" {
    try expectRejects(&HELLO_MEMBER);
    try expectRejects("");
}

test "rejects a BSIZE that does not match the member" {
    var bad = HELLO_BGZF;
    bad[16] += 1;
    try expectRejects(&bad);
}

test "rejects plain gzip members without a BC subfield" {
    const plain_gzip = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca,
        0x49, 0xe1, 0x02, 0x00, 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00,
        0x00, 0x00,
    };
    try expectRejects(&(plain_gzip ++ gzip.BGZF_EOF));
}

test "rejects a member that decompresses to more than 64 KiB" {
    // A fixed-Huffman block with one literal 'a' and then 255 matches of
    // 258 bytes at distance 1 decompresses to 65,791 bytes.
    const plain_len: usize = 1 + 258 * 255;
    try std.testing.expect(plain_len > BLOCK_SIZE_MAX);

    var bgzf: [512]u8 = undefined;
    var bits: u64 = 0;
    var nbits: u6 = 0;
    var out_i: usize = gzip.BGZF_HEADER_SIZE;
    const Writer = struct {
        out: []u8,
        out_i: *usize,
        bits: *u64,
        nbits: *u6,

        // Huffman codes are sent most significant bit first.
        fn code(self: @This(), value: u16, len: u4) void {
            self.put(@bitReverse(value) >> @intCast(16 - @as(u5, len)), len);
        }

        fn put(self: @This(), value: u32, len: u6) void {
            self.bits.* |= @as(u64, value) << self.nbits.*;
            self.nbits.* += len;
            while (self.nbits.* >= 8) {
                self.out[self.out_i.*] = @truncate(self.bits.*);
                self.out_i.* += 1;
                self.bits.* >>= 8;
                self.nbits.* -= 8;
            }
        }
    };
    const w = Writer{ .out = &bgzf, .out_i = &out_i, .bits = &bits, .nbits = &nbits };
    w.put(0b011, 3); // BFINAL=1, BTYPE=01
    w.code(0x30 + 'a', 8);
    var k: usize = 0;
    while (k < 255) : (k += 1) {
        w.code(0xc0 + (285 - 280), 8); // length 258
        w.code(0, 5); // distance 1
    }
    w.code(0, 7); // end of block
    w.put(0, 7); // pad to a byte boundary

    var plain: [plain_len]u8 = undefined;
    @memset(&plain, 'a');
    gzip.writeTrailer(bgzf[out_i..], &plain);
    out_i += gzip.TRAILER_SIZE;
    gzip.writeBgzfHeader(&bgzf, out_i);
    @memcpy(bgzf[out_i..][0..gzip.BGZF_EOF.len], &gzip.BGZF_EOF);
    out_i += gzip.BGZF_EOF.len;

    try expectRejects(bgzf[0..out_i]);

    // The same member decodes through plain gzip, which has no size limit.
    var out: [plain_len]u8 = undefined;
    const member = gzip.inflateMember(bgzf[0..out_i], &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(plain_len, member.length);
}
