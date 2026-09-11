//! SIMD supersampling SVG rasterizer with sRGB RGBA8 KTX2 output.
//!
//! This comparison component uses the same float working pixels, 4 by 4
//! coverage grid, and linear-light compositing as the RGBA32F component. It
//! quantizes once, after rasterization, so benchmarks isolate output encoding
//! and size from coverage quality.

pub const SVG_RASTERIZE_ANTIALIAS = true;

comptime {
    _ = @import("svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig");
}
