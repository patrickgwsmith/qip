//! SVG rasterizer with B8G8R8A8 sRGB BMP output.
//!
//! This root shares the center-sampled KTX2 rasterizer's SVG subset; only the
//! container, row order, and channel order differ.

pub const SVG_RASTERIZE_BMP = true;

comptime {
    _ = @import("svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig");
}
