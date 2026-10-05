//! BGZF compression, the blocked gzip format from the SAM/BAM specification
//! that bgzip, tabix, samtools, and htslib read. The input is cut into
//! 65,280-byte chunks (htslib's limit). Each chunk becomes one gzip member
//! of at most 64 KiB with a "BC" extra subfield, and the output ends with the
//! 28-byte BGZF EOF block. Any gunzip can read the result.
//!
//! Each member compresses on its own with the shared engine in
//! lib/deflate.zig, so a reader can start at any member. A member uses a
//! single stored block when DEFLATE would not make it smaller.

const std = @import("std");
const deflate = @import("lib/deflate.zig");
const gzip = @import("lib/gzip.zig");

const INPUT_CAP: usize = 16 * 1024 * 1024;
const BLOCK_DATA_MAX = gzip.BGZF_BLOCK_DATA_MAX;
const BLOCK_COUNT_MAX: usize = (INPUT_CAP + BLOCK_DATA_MAX - 1) / BLOCK_DATA_MAX;
// A stored DEFLATE block adds 5 bytes, and a member never exceeds its stored
// size, so a full member is at most 65,311 bytes.
const STORED_HEADER_SIZE: usize = 5;
const MEMBER_SIZE_MAX: usize = gzip.BGZF_BLOCK_OVERHEAD + STORED_HEADER_SIZE + BLOCK_DATA_MAX;
const OUTPUT_CAP: usize = BLOCK_COUNT_MAX * MEMBER_SIZE_MAX + gzip.BGZF_EOF.len;

comptime {
    std.debug.assert(MEMBER_SIZE_MAX <= gzip.BGZF_BLOCK_SIZE_MAX);
}

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var token_buf: [BLOCK_DATA_MAX]u32 = undefined;

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
    return @as(u32, @intCast(@intFromPtr(gzip.CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(gzip.CONTENT_TYPE.len));
}

fn writeStoredBlock(out: []u8, data: []const u8) usize {
    const len: u16 = @intCast(data.len);
    out[0] = 0x01; // BFINAL=1, BTYPE=00
    std.mem.writeInt(u16, out[1..3], len, .little);
    std.mem.writeInt(u16, out[3..5], ~len, .little);
    @memcpy(out[STORED_HEADER_SIZE..][0..data.len], data);
    return STORED_HEADER_SIZE + data.len;
}

/// Writes one BGZF member for `data` at `start` and returns its size.
fn writeMember(start: usize, data: []const u8) usize {
    const payload_start = start + gzip.BGZF_HEADER_SIZE;
    const payload_end = @min(
        start + gzip.BGZF_BLOCK_SIZE_MAX - gzip.TRAILER_SIZE,
        OUTPUT_CAP - gzip.BGZF_EOF.len - gzip.TRAILER_SIZE,
    );
    const payload = output_buf[payload_start..payload_end];
    const stored_size = STORED_HEADER_SIZE + data.len;

    var payload_size = stored_size;
    if (deflate.compressRawBlocksWithOptions(data, payload, token_buf[0..data.len], .{})) |raw_size| {
        payload_size = raw_size;
    }
    if (payload_size >= stored_size) payload_size = writeStoredBlock(payload, data);

    const member_size = gzip.BGZF_BLOCK_OVERHEAD + payload_size;
    gzip.writeBgzfHeader(output_buf[start..], member_size);
    gzip.writeTrailer(output_buf[payload_start + payload_size ..], data);
    return member_size;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    const input = input_buf[0..input_size];

    var out_i: usize = 0;
    var pos: usize = 0;
    while (pos < input.len) {
        const end = @min(pos + BLOCK_DATA_MAX, input.len);
        out_i += writeMember(out_i, input[pos..end]);
        pos = end;
    }
    @memcpy(output_buf[out_i..][0..gzip.BGZF_EOF.len], &gzip.BGZF_EOF);
    return @as(u32, @intCast(out_i + gzip.BGZF_EOF.len));
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

/// Walks the members by BSIZE alone, as an indexed BGZF reader does, and
/// checks that each one decompresses to the expected slice of `plain`.
fn expectBgzf(written: usize, plain: []const u8) !void {
    const out = try std.testing.allocator.alloc(u8, BLOCK_DATA_MAX);
    defer std.testing.allocator.free(out);

    var pos: usize = 0;
    var plain_pos: usize = 0;
    while (pos < written) {
        const header = gzip.parseHeader(output_buf[pos..written]) orelse return error.BadHeader;
        const block_size = gzip.bgzfBlockSize(header.extra orelse return error.NoExtra) orelse return error.NoBsize;
        try std.testing.expect(block_size <= gzip.BGZF_BLOCK_SIZE_MAX);
        const member = gzip.inflateMember(output_buf[pos..][0..block_size], out) orelse return error.BadMember;
        try std.testing.expectEqual(block_size, member.consumed);
        try std.testing.expectEqualSlices(u8, plain[plain_pos..][0..member.length], out[0..member.length]);
        plain_pos += member.length;
        pos += block_size;
    }
    try std.testing.expectEqual(plain.len, plain_pos);
    try std.testing.expectEqualSlices(u8, &gzip.BGZF_EOF, output_buf[written - gzip.BGZF_EOF.len .. written]);
}

test "empty input is only the EOF block" {
    const written = renderImpl(0);
    try std.testing.expectEqualSlices(u8, &gzip.BGZF_EOF, output_buf[0..written]);
}

test "round trips short text in one member" {
    const plain = "chr1\t100\t200\n";
    @memcpy(input_buf[0..plain.len], plain);
    const written = renderImpl(@intCast(plain.len));
    try std.testing.expect(gzip.bgzfBlockSize(output_buf[12..18]) != null);
    try expectBgzf(written, plain);
}

test "splits at 65,280 bytes and stores incompressible members" {
    const len = 3 * BLOCK_DATA_MAX + 1;
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(input_buf[0..len]);
    const written = renderImpl(len);
    try std.testing.expectEqual(@as(?usize, MEMBER_SIZE_MAX), gzip.bgzfBlockSize(output_buf[12..18]));
    try expectBgzf(written, input_buf[0..len]);
}

test "maximum compressible and incompressible inputs fit the output capacity" {
    @memset(input_buf[0..], 'a');
    try expectBgzf(renderImpl(@intCast(INPUT_CAP)), input_buf[0..INPUT_CAP]);

    var prng = std.Random.DefaultPrng.init(2);
    prng.random().bytes(input_buf[0..]);
    const written = renderImpl(@intCast(INPUT_CAP));
    try std.testing.expect(written <= OUTPUT_CAP);
    try expectBgzf(written, input_buf[0..INPUT_CAP]);
}
