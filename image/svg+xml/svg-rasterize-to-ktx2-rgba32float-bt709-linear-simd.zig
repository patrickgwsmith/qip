//! SIMD supersampling SVG rasterizer with linear BT.709 RGBA32F KTX2 output.
//!
//! The shared implementation keeps the established SVG subset and enables
//! coverage-aware source-over compositing, viewBox sizing, and float output.

pub const SVG_RASTERIZE_RGBA32FLOAT = true;

comptime {
    _ = @import("svg-rasterize-to-ktx2-r8g8b8a8-srgb.zig");
}
