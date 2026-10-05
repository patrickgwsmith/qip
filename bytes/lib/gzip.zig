//! Internal gzip (RFC 1952) and BGZF framing shared by the gzip and bgzf
//! components. This is a private API: callers inside this repository only.
//!
//! Strict by construction, matching gzip's member rules:
//! - ID1/ID2 and CM=8 are required; reserved FLG bits reject.
//! - FEXTRA, FNAME, FCOMMENT and FHCRC are parsed, and FHCRC is verified.
//! - The CRC-32 and ISIZE trailer of every member is verified.
//!
//! BGZF (SAM/BAM specification section 4.1) is a series of gzip members whose
//! FEXTRA field holds a "BC" subfield with the member size. Every member holds
//! at most 64 KiB of compressed and uncompressed data.

const std = @import("std");
const inflate = @import("inflate.zig");

pub const CONTENT_TYPE = "application/gzip";

pub const HEADER_SIZE: usize = 10;
pub const TRAILER_SIZE: usize = 8;

const ID1: u8 = 0x1f;
const ID2: u8 = 0x8b;
const CM_DEFLATE: u8 = 8;
const FLG_FHCRC: u8 = 0x02;
const FLG_FEXTRA: u8 = 0x04;
const FLG_FNAME: u8 = 0x08;
const FLG_FCOMMENT: u8 = 0x10;
const FLG_RESERVED: u8 = 0xe0;
/// OS byte 255 means "unknown"; it keeps output the same on every host.
const OS_UNKNOWN: u8 = 0xff;

/// The largest uncompressed payload per BGZF block. htslib uses 0xff00, not
/// 0x10000, so that a stored DEFLATE fallback plus the BGZF header and
/// trailer always fits in the 64 KiB block limit.
pub const BGZF_BLOCK_DATA_MAX: usize = 0xff00;
pub const BGZF_BLOCK_SIZE_MAX: usize = 0x10000;
pub const BGZF_HEADER_SIZE: usize = 18;
pub const BGZF_BLOCK_OVERHEAD: usize = BGZF_HEADER_SIZE + TRAILER_SIZE;

/// The empty BGZF block that marks the end of a complete BGZF file.
pub const BGZF_EOF = [28]u8{
    0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xff, 0x06, 0x00, 0x42, 0x43, 0x02, 0x00,
    0x1b, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

/// Writes a 10-byte gzip header with no optional fields and MTIME 0.
pub fn writeHeader(out: []u8) void {
    out[0..HEADER_SIZE].* = .{ ID1, ID2, CM_DEFLATE, 0, 0, 0, 0, 0, 0, OS_UNKNOWN };
}

/// Writes an 18-byte BGZF header. `block_size` is the total member size,
/// including this header and the trailer.
pub fn writeBgzfHeader(out: []u8, block_size: usize) void {
    std.debug.assert(block_size <= BGZF_BLOCK_SIZE_MAX);
    out[0..12].* = .{ ID1, ID2, CM_DEFLATE, FLG_FEXTRA, 0, 0, 0, 0, 0, OS_UNKNOWN, 6, 0 };
    out[12..16].* = .{ 'B', 'C', 2, 0 };
    std.mem.writeInt(u16, out[16..18], @intCast(block_size - 1), .little);
}

/// Writes the CRC-32 and ISIZE trailer for `data`.
pub fn writeTrailer(out: []u8, data: []const u8) void {
    std.mem.writeInt(u32, out[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, out[4..8], @truncate(data.len), .little);
}

pub const Header = struct {
    data_start: usize,
    extra: ?[]const u8,
};

fn skipZeroTerminated(input: []const u8, start: usize) ?usize {
    const end = std.mem.indexOfScalarPos(u8, input, start, 0) orelse return null;
    return end + 1;
}

/// Parses the gzip member header at the start of `input`.
pub fn parseHeader(input: []const u8) ?Header {
    if (input.len < HEADER_SIZE) return null;
    if (input[0] != ID1 or input[1] != ID2 or input[2] != CM_DEFLATE) return null;
    const flags = input[3];
    if (flags & FLG_RESERVED != 0) return null;

    var pos: usize = HEADER_SIZE;
    var extra: ?[]const u8 = null;
    if (flags & FLG_FEXTRA != 0) {
        if (pos + 2 > input.len) return null;
        const xlen: usize = std.mem.readInt(u16, input[pos..][0..2], .little);
        pos += 2;
        if (pos + xlen > input.len) return null;
        extra = input[pos..][0..xlen];
        pos += xlen;
    }
    if (flags & FLG_FNAME != 0) pos = skipZeroTerminated(input, pos) orelse return null;
    if (flags & FLG_FCOMMENT != 0) pos = skipZeroTerminated(input, pos) orelse return null;
    if (flags & FLG_FHCRC != 0) {
        if (pos + 2 > input.len) return null;
        const stored = std.mem.readInt(u16, input[pos..][0..2], .little);
        if (@as(u16, @truncate(std.hash.Crc32.hash(input[0..pos]))) != stored) return null;
        pos += 2;
    }
    return .{ .data_start = pos, .extra = extra };
}

pub const Member = struct {
    /// Compressed bytes used by this member, from ID1 through ISIZE.
    consumed: usize,
    /// Decompressed bytes written to the start of `output`.
    length: usize,
    extra: ?[]const u8,
};

/// Decompresses the gzip member at the start of `input` into `output`.
/// Bytes after the member are ignored, so callers can read concatenated
/// members. Returns null when the member is malformed, truncated, too long
/// for `output`, or fails its CRC-32 or ISIZE check.
pub fn inflateMember(input: []const u8, output: []u8) ?Member {
    const header = parseHeader(input) orelse return null;
    const raw = inflate.inflateRawPrefix(input[header.data_start..], output) orelse return null;
    const trailer = header.data_start + raw.consumed;
    if (trailer + TRAILER_SIZE > input.len) return null;

    const crc = std.mem.readInt(u32, input[trailer..][0..4], .little);
    const stored_size = std.mem.readInt(u32, input[trailer + 4 ..][0..4], .little);
    if (std.hash.Crc32.hash(output[0..raw.length]) != crc) return null;
    if (@as(u32, @truncate(raw.length)) != stored_size) return null;

    return .{ .consumed = trailer + TRAILER_SIZE, .length = raw.length, .extra = header.extra };
}

/// Returns the total member size recorded in a BGZF extra field, or null
/// when the field does not hold exactly one well-formed "BC" subfield.
/// Other subfields are allowed, as in htslib.
pub fn bgzfBlockSize(extra: []const u8) ?usize {
    var block_size: ?usize = null;
    var pos: usize = 0;
    while (pos < extra.len) {
        if (pos + 4 > extra.len) return null;
        const len: usize = std.mem.readInt(u16, extra[pos + 2 ..][0..2], .little);
        const data_start = pos + 4;
        if (data_start + len > extra.len) return null;
        if (extra[pos] == 'B' and extra[pos + 1] == 'C') {
            if (len != 2 or block_size != null) return null;
            block_size = @as(usize, std.mem.readInt(u16, extra[data_start..][0..2], .little)) + 1;
        }
        pos = data_start + len;
    }
    return block_size;
}

test "parses optional header fields and verifies FHCRC" {
    var member = [_]u8{
        0x1f, 0x8b, 0x08, 0x1e, 0, 0, 0, 0, 0, 3,
        2, 0, 'x', 'y', // FEXTRA
        'a', 0, // FNAME
        'c', 0, // FCOMMENT
        0, 0, // FHCRC, set below
    };
    const crc: u16 = @truncate(std.hash.Crc32.hash(member[0 .. member.len - 2]));
    std.mem.writeInt(u16, member[member.len - 2 ..][0..2], crc, .little);

    const header = parseHeader(&member) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(member.len, header.data_start);
    try std.testing.expectEqualStrings("xy", header.extra.?);

    member[member.len - 1] ^= 1;
    try std.testing.expectEqual(@as(?Header, null), parseHeader(&member));
}

test "rejects reserved flags and wrong method" {
    try std.testing.expectEqual(@as(?Header, null), parseHeader(&.{ 0x1f, 0x8b, 0x08, 0x20, 0, 0, 0, 0, 0, 3 }));
    try std.testing.expectEqual(@as(?Header, null), parseHeader(&.{ 0x1f, 0x8b, 0x07, 0x00, 0, 0, 0, 0, 0, 3 }));
}

test "BGZF EOF block is a valid empty member" {
    var out: [1]u8 = undefined;
    const member = inflateMember(&BGZF_EOF, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(BGZF_EOF.len, member.consumed);
    try std.testing.expectEqual(@as(usize, 0), member.length);
    try std.testing.expectEqual(@as(?usize, BGZF_EOF.len), bgzfBlockSize(member.extra.?));
}

test "BGZF header encodes BSIZE as block size minus one" {
    var header: [BGZF_HEADER_SIZE]u8 = undefined;
    writeBgzfHeader(&header, BGZF_EOF.len);
    try std.testing.expectEqualSlices(u8, BGZF_EOF[0..BGZF_HEADER_SIZE], &header);
}

test "BGZF extra field rejects duplicate or malformed BC subfields" {
    try std.testing.expectEqual(@as(?usize, 0x1c), bgzfBlockSize(&.{ 'Z', 'Z', 1, 0, 9, 'B', 'C', 2, 0, 0x1b, 0 }));
    try std.testing.expectEqual(@as(?usize, null), bgzfBlockSize(&.{ 'B', 'C', 2, 0, 1, 0, 'B', 'C', 2, 0, 1, 0 }));
    try std.testing.expectEqual(@as(?usize, null), bgzfBlockSize(&.{ 'B', 'C', 3, 0, 1, 0, 0 }));
    try std.testing.expectEqual(@as(?usize, null), bgzfBlockSize(&.{ 'B', 'C', 2 }));
    try std.testing.expectEqual(@as(?usize, null), bgzfBlockSize(&.{}));
}
