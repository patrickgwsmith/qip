//! Strict RGBA8 or BGRA8 sRGB KTX2 encoder to 8-bit RGBA PNG.

pub const PNG_INPUT_KTX2 = true;

comptime {
    _ = @import("png_encoder_impl");
}
