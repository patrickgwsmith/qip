//! Converts canonical sRGB RGBA8 KTX2 pixels to canonical linear RGBA32F KTX2.
//! The payload expands backward in the shared input/output buffer.

const rgba8 = @import("ktx2_rgba8_srgb");
const rgba32f = @import("ktx2_rgba32float");

const CAP: usize = rgba32f.MAX_FILE_SIZE;
const CONTENT_TYPE = "image/ktx2";

var buffer: [CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&buffer));
}
export fn input_bytes_cap() u32 {
    return CAP;
}

export fn output_bytes_cap() u32 {
    return CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

fn renderImpl(input_size_in: u32) u32 {
    const input_size: usize = input_size_in;
    if (input_size > CAP) @trap();
    const image = rgba8.parse(buffer[0..input_size]) orelse @trap();
    const width = image.width;
    const height = image.height;
    const pixel_count = width * height;
    const output_size = rgba32f.fileSize(width, height) orelse @trap();

    var remaining = pixel_count;
    while (remaining > 0) {
        remaining -= 1;
        const source = rgba8.HEADER_SIZE + remaining * 4;
        const target = rgba32f.HEADER_SIZE + remaining * 16;
        const red = rgba32f.SRGB8_TO_LINEAR[buffer[source]];
        const green = rgba32f.SRGB8_TO_LINEAR[buffer[source + 1]];
        const blue = rgba32f.SRGB8_TO_LINEAR[buffer[source + 2]];
        const alpha = @as(f32, @floatFromInt(buffer[source + 3])) / 255.0;
        @as(*align(1) f32, @ptrCast(&buffer[target])).* = red;
        @as(*align(1) f32, @ptrCast(&buffer[target + 4])).* = green;
        @as(*align(1) f32, @ptrCast(&buffer[target + 8])).* = blue;
        @as(*align(1) f32, @ptrCast(&buffer[target + 12])).* = alpha;
    }
    _ = rgba32f.writeHeader(&buffer, width, height) orelse @trap();
    return @intCast(output_size);
}

export fn render(input_size_in: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size_in),
        .output_ptr = @intCast(@intFromPtr(&buffer)),
        .failed = 0,
    };
}
