//! Render plain UTF-8 text as wrapped JetBrains Mono 2.304 paths on a
//! transparent, intrinsically sized SVG canvas.
//!
//! This first version uses the official NL faces, which contain no ligatures.

const builtin = @import("builtin");

pub const plain_text_input = !builtin.is_test;
pub const regular_font = if (builtin.is_test)
    @import("lib/inter_display_latin_paths.zig")
else
    @import("lib/jetbrains_mono_2_304_regular_latin_paths.zig");
pub const bold_font = if (builtin.is_test)
    @import("lib/inter_display_bold_latin_paths.zig")
else
    @import("lib/jetbrains_mono_2_304_bold_latin_paths.zig");
pub const font_family = if (builtin.is_test) "Inter Display" else "JetBrains Mono NL";

comptime {
    _ = @import("text-to-og-image-svg-inter.zig");
}
