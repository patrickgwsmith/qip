// The qip.dev site's Open Graph images: warc-add-open-graph-image-inter-png
// with "qip.dev" as the secondary line on every page, in the site's dark
// palette from recipes/text/markdown/styles.css. A page's og:image template
// can still set its own secondary text and colors.
pub const og_image_default_secondary: []const u8 = "qip.dev";
// --bg-dark, oklch(19.18% 0.0102 52.85).
pub const og_image_default_background_color_rgba: u32 = 0x181310ff;
// --link-dark, oklch(73% 0.18 50).
pub const og_image_default_text_color_rgba: u32 = 0xfe7f25ff;
// --link-hover-dark, oklch(82% 0.1 50).
pub const og_image_default_secondary_color_rgba: u32 = 0xf9b189ff;

comptime {
    _ = @import("og_image");
}
