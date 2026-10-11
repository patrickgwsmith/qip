//! Zstandard (RFC 8878) decompression using std.compress.zstd. Concatenated
//! frames decode to the concatenation of their contents, and skippable
//! frames are ignored, as with `zstd -d`. Content checksums are verified
//! here because std does not verify them yet. Frames that need a dictionary
//! or a window over 8 MiB reject, matching what browsers accept.

const std = @import("std");
const zstd = std.compress.zstd;

const CONTENT_TYPE = "application/zstd";
const MAGIC: u32 = 0xFD2FB528;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
// The std decoder reserves room for a whole block before decoding one, so
// output that ends near the cap needs one block of slack.
const OUTPUT_BUF_LEN: usize = OUTPUT_CAP + zstd.block_size_max;
// TODO: Report useful input progress when the decoder exposes it.

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_BUF_LEN]u8 = undefined;

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
    return @as(u32, @intCast(@intFromPtr(CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(CONTENT_TYPE.len));
}

export fn failure_modes_per_input_offset() u32 {
    return 0;
}

/// Decompresses every frame in `input`, one block per step, so each frame's
/// output range is known when its checksum is read.
fn decompressFrames(input: []const u8, output: []u8) ?usize {
    if (input.len == 0) return null;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer = .fixed(output);
    var decompress: zstd.Decompress = .init(&in, &.{}, .{});

    var frame_start: usize = 0;
    var checksummed = false;
    while (true) {
        if (decompress.state == .new_frame) {
            const rest = input[in.seek..];
            if (rest.len == 0) break;
            frame_start = out.end;
            // Byte 4 is a Zstandard frame's descriptor; bit 2 is the checksum flag.
            checksummed = rest.len > 4 and std.mem.readInt(u32, rest[0..4], .little) == MAGIC and rest[4] & 0x04 != 0;
        }
        _ = decompress.reader.stream(&out, .unlimited) catch return null;
        if (decompress.state == .new_frame and checksummed) {
            const expected = std.mem.readInt(u32, input[in.seek - 4 ..][0..4], .little);
            const actual: u32 = @truncate(std.hash.XxHash64.hash(0, output[frame_start..out.end]));
            if (expected != actual) return null;
            checksummed = false;
        }
    }
    if (out.end > OUTPUT_CAP) return null;
    return out.end;
}

const RenderOutcome = struct {
    output_size_or_failure: u32,
    output_ptr: usize,
    failed: u1,
};

fn renderOutcome(input_size_in: u32) RenderOutcome {
    if (input_size_in > INPUT_CAP) @trap();
    const input_size: usize = @intCast(input_size_in);
    const out_len = decompressFrames(input_buf[0..input_size], &output_buf) orelse {
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

// `printf 'Hello world\n' | zstd -c`
const HELLO_ZST = [_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x61, 0x00, 0x00, 0x48,
    0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64,
    0x0a, 0x8c, 0xa0, 0x38, 0x9a,
};

// A skippable frame with four bytes of user data.
const SKIPPABLE = [_]u8{ 0x50, 0x2a, 0x4d, 0x18, 0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4 };

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

test "decompresses a zstd frame" {
    try expectDecodes(&HELLO_ZST, "Hello world\n");
}

test "concatenated and skippable frames decode in order" {
    try expectDecodes(&(HELLO_ZST ++ SKIPPABLE ++ HELLO_ZST), "Hello world\nHello world\n");
    try expectDecodes(&SKIPPABLE, "");
}

test "rejects empty input, trailing bytes, and truncation" {
    try expectRejects("");
    try expectRejects(&(HELLO_ZST ++ [_]u8{0}));
    try expectRejects(HELLO_ZST[0 .. HELLO_ZST.len - 1]);
}

test "rejects a corrupted checksum and recovers" {
    var bad = HELLO_ZST;
    bad[HELLO_ZST.len - 1] ^= 1;
    try expectRejects(&bad);
    try expectDecodes(&HELLO_ZST, "Hello world\n");
}
