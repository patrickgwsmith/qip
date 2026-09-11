//! PNG decoder with canonical top-down RGBA8 sRGB KTX2 output.

pub const PNG_OUTPUT_KTX2 = true;

comptime {
    _ = @import("png-to-bmp-b8g8r8a8-srgb.zig");
}
