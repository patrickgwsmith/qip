//! Doubles canonical RGBA8 sRGB KTX2 dimensions with exact nearest-neighbour
//! pixel replication. This is distinct from the Mitchell reconstruction scaler.

const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const MAX_INPUT_PIXELS = ktx.MAX_PIXELS / 4;
const INPUT_CAP = ktx.HEADER_SIZE + MAX_INPUT_PIXELS * 4;
const OUTPUT_CAP = ktx.MAX_FILE_SIZE;
const INPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 { return @intCast(@intFromPtr(&input_buf)); }
export fn input_bytes_cap() u32 { return INPUT_CAP; }
export fn output_bytes_cap() u32 { return OUTPUT_CAP; }
export fn input_content_type_ptr() u32 { return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)); }
export fn input_content_type_size() u32 { return INPUT_CONTENT_TYPE.len; }
export fn output_content_type_ptr() u32 { return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)); }
export fn output_content_type_size() u32 { return INPUT_CONTENT_TYPE.len; }

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > INPUT_CAP) @trap();
    const image = ktx.parse(input_buf[0..input_size]) orelse @trap();
    const width = std.math.mul(usize, image.width, 2) catch @trap();
    const height = std.math.mul(usize, image.height, 2) catch @trap();
    const output_size = ktx.writeHeader(output_buf[0..], width, height) orelse @trap();

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const source = (y * image.width + x) * 4;
            const first = ((y * 2) * width + x * 2) * 4;
            const pixel = image.pixels[source .. source + 4];
            @memcpy(output_buf[ktx.HEADER_SIZE + first .. ktx.HEADER_SIZE + first + 4], pixel);
            @memcpy(output_buf[ktx.HEADER_SIZE + first + 4 .. ktx.HEADER_SIZE + first + 8], pixel);
            @memcpy(output_buf[ktx.HEADER_SIZE + first + width * 4 .. ktx.HEADER_SIZE + first + width * 4 + 4], pixel);
            @memcpy(output_buf[ktx.HEADER_SIZE + first + width * 4 + 4 .. ktx.HEADER_SIZE + first + width * 4 + 8], pixel);
        }
    }
    return @intCast(output_size);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32, output_ptr: u31, failed: u1,
} {
    return .{ .output_size = renderImpl(input_size_in), .output_ptr = @intCast(@intFromPtr(&output_buf)), .failed = 0 };
}

test "replicates every RGBA pixel into a two by two block" {
    const size = ktx.writeHeader(input_buf[0..], 2, 1) orelse unreachable;
    @memcpy(input_buf[ktx.HEADER_SIZE..size], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const written = renderImpl(@intCast(size));
    try std.testing.expectEqual(@as(usize, 224 + 4 * 2 * 4), written);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8, 5, 6, 7, 8,
        1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8, 5, 6, 7, 8,
    }, output_buf[ktx.HEADER_SIZE..written]);
}
