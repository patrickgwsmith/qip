//! Applies the Display P3 transfer function to linear Display P3 RGBA32F KTX2.
//! RGB remains float32 so extended values above one retain HDR headroom.

const linear = @import("ktx2_rgba32float_display_p3_linear");
const encoded = @import("ktx2_rgba32float_display_p3");

const CAP: usize = linear.MAX_FILE_SIZE;
const CONTENT_TYPE = "image/ktx2";

var buffer: [CAP]u8 align(16) = undefined;

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
    const bytes = buffer[0..input_size];
    const image = linear.parse(bytes) orelse @trap();

    var pixel: usize = 0;
    while (pixel < image.width * image.height) : (pixel += 1) {
        const channel = pixel * 4;
        image.pixels[channel] = encoded.linearToDisplayP3(image.pixels[channel]);
        image.pixels[channel + 1] = encoded.linearToDisplayP3(image.pixels[channel + 1]);
        image.pixels[channel + 2] = encoded.linearToDisplayP3(image.pixels[channel + 2]);
    }
    return @intCast(encoded.writeHeader(buffer[0..], image.width, image.height) orelse @trap());
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
