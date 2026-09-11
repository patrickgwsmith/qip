//! SIMD fork of png-to-bmp-b8g8r8a8-srgb.
//!
//! The decoder and its fixed batching policy stay shared with the scalar
//! component. This root-level switch selects wasm simd128 row operations.

pub const PNG_TO_BMP_SIMD = true;

comptime {
    _ = @import("png-to-bmp-b8g8r8a8-srgb.zig");
}
