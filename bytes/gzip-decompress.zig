//! gzip (RFC 1952) decompression using the shared engines in lib/gzip.zig
//! and lib/inflate.zig. Concatenated members decode to the concatenation of
//! their contents, as with gunzip, so BGZF files also decode here. Every
//! member's header flags, FHCRC, CRC-32, and ISIZE are verified. Bytes after
//! the last member reject, including the zero padding that gunzip ignores
//! with a warning.

const std = @import("std");
const gzip = @import("lib/gzip.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
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

/// Decompresses one or more concatenated members that span all of `input`.
fn inflateMembers(input: []const u8, output: []u8) ?usize {
    if (input.len == 0) return null;
    var in_pos: usize = 0;
    var out_len: usize = 0;
    while (in_pos < input.len) {
        const member = gzip.inflateMember(input[in_pos..], output[out_len..]) orelse return null;
        in_pos += member.consumed;
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
    const out_len = inflateMembers(input_buf[0..input_size], &output_buf) orelse {
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

// `printf 'Hello world\n' | gzip -n`
const HELLO_GZ = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca,
    0x49, 0xe1, 0x02, 0x00, 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00,
    0x00, 0x00,
};

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

test "decompresses a gzip member" {
    try expectDecodes(&HELLO_GZ, "Hello world\n");
}

test "concatenated members decode in order" {
    try expectDecodes(&(HELLO_GZ ++ HELLO_GZ), "Hello world\nHello world\n");
}

test "decodes a BGZF EOF block as empty output" {
    try expectDecodes(&gzip.BGZF_EOF, "");
}

test "rejects empty input, trailing bytes, and truncation" {
    try expectRejects("");
    try expectRejects(&(HELLO_GZ ++ [_]u8{0}));
    try expectRejects(HELLO_GZ[0 .. HELLO_GZ.len - 1]);
}

test "rejects corrupted CRC-32 and ISIZE" {
    var bad_crc = HELLO_GZ;
    bad_crc[HELLO_GZ.len - 8] ^= 1;
    try expectRejects(&bad_crc);

    var bad_size = HELLO_GZ;
    bad_size[HELLO_GZ.len - 4] ^= 1;
    try expectRejects(&bad_size);
}

test "rejects zlib input and recovers" {
    try expectRejects(&.{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 });
    try expectDecodes(&HELLO_GZ, "Hello world\n");
}
