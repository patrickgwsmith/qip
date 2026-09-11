//! Render plain UTF-8 text as wrapped Inter Display paths on a transparent,
//! intrinsically sized SVG canvas.
//!
//! The component reuses the Open Graph renderer's font metrics and layout.
//! `font_size`, `font_weight`, `measure`, `line_height_em`, `alignment`, and
//! `inspect_layout_metrics` configure one render.

const builtin = @import("builtin");

// Imported by text-to-og-image-svg-inter.zig at compile time. Zig tests use
// that source's form-input tests; the built component enables this variant.
pub const plain_text_input = !builtin.is_test;

comptime {
    _ = @import("text-to-og-image-svg-inter.zig");
}
