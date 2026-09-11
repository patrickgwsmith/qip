//! Reduces canonical RGBA8 sRGB KTX2 with a separable three-lobe Lanczos
//! filter. Filtering is linear-light and alpha-premultiplied.

const resize = @import("lib/resize-rgba8-srgb.zig");

export fn input_ptr() u32 {
    return resize.inputPtr();
}
export fn input_bytes_cap() u32 {
    return resize.inputBytesCap();
}
export fn output_bytes_cap() u32 {
    return resize.outputBytesCap();
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(resize.CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return resize.CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(resize.CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return resize.CONTENT_TYPE.len;
}
export fn failure_modes_per_input_offset() u32 {
    return 0;
}
export fn uniform_set_width(value: u32) u32 {
    return resize.setWidth(value);
}
export fn uniform_set_height(value: u32) u32 {
    return resize.setHeight(value);
}
export fn render(input_size: u32) resize.RenderResult {
    return resize.render(input_size, .lanczos3_down);
}
