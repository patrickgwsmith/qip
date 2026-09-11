//! Converts canonical linear RGBA32F KTX2 pixels to canonical sRGB RGBA8 KTX2.
//! The payload compacts forward in the shared input/output buffer.

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
    const image = rgba32f.parse(buffer[0..input_size]) orelse @trap();
    const width = image.width;
    const height = image.height;
    const pixel_count = width * height;

    var pixel: usize = 0;
    while (pixel < pixel_count) : (pixel += 1) {
        const source = pixel * 4;
        const target = rgba8.HEADER_SIZE + pixel * 4;
        buffer[target] = rgba32f.linearToSrgb8(image.pixels[source]);
        buffer[target + 1] = rgba32f.linearToSrgb8(image.pixels[source + 1]);
        buffer[target + 2] = rgba32f.linearToSrgb8(image.pixels[source + 2]);
        buffer[target + 3] = rgba32f.linearToUnorm8(image.pixels[source + 3]);
    }
    return @intCast(rgba8.writeHeader(&buffer, width, height) orelse @trap());
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
