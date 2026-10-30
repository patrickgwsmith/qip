const std = @import("std");

// Subresource Integrity value, such as integrity="sha384-…".
const Hash = std.crypto.hash.sha2.Sha384;
const PREFIX = "sha384-";
// Only the encoder: std.base64.standard also carries the decoder's lookup tables.
const base64 = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=');

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = PREFIX.len + base64.calcSize(Hash.digest_length);

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn integrity(input: []const u8, out: *[OUTPUT_CAP]u8) void {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(input, &digest, .{});
    @memcpy(out[0..PREFIX.len], PREFIX);
    _ = base64.encode(out[PREFIX.len..], &digest);
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    integrity(input_buf[0..input_size], &output_buf);
    return OUTPUT_CAP;
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "output is 71 bytes" {
    try std.testing.expectEqual(@as(usize, 71), OUTPUT_CAP);
}

test "matches openssl for abc" {
    var out: [OUTPUT_CAP]u8 = undefined;
    integrity("abc", &out);
    try std.testing.expectEqualStrings("sha384-ywB1P0WjXou1oD1pmsZQBycsMqsO3tFjGotgWkP/W+2AhgcroefMI1i67KE0yCWn", &out);
}

test "matches openssl for empty input" {
    var out: [OUTPUT_CAP]u8 = undefined;
    integrity("", &out);
    try std.testing.expectEqualStrings("sha384-OLBgp1GsljhM2TJ+sbHjaiH9txEUvgdDTAzHv2P24donTt6/529l+9Ua0vFImLlb", &out);
}
