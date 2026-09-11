# Text To Open Graph SVG With Inter

`text-to-og-image-svg-inter.wasm` turns a title and subtitle into a 1200×630
Open Graph SVG. Its input is `application/x-www-form-urlencoded` with a required,
possibly empty `title` field and an optional `subtitle` field. It wraps both fields, aligns
them to a 96px left edge, centers the complete block vertically, and draws
glyphs as paths. The SVG has no external font dependency.

The component uses Inter Display because Open Graph titles are large. It embeds
Regular and Bold outlines, proportional advance widths, and pair kerning. The
default title uses Bold with dark text on a yellow background. The subtitle uses
Regular at 40% of the title size, with a 24px minimum. Auto-fit selects the
largest even title size from 112px down to 32px that fits inside 96px horizontal
and 72px vertical margins.

```bash
printf '%s' 'title=Inter+makes+Open+Graph+titles+clear&subtitle=Reusable+paths%2C+wrapping%2C+and+kerning.' |
  qip run -- \
    text/text-to-og-image-svg-inter.wasm \
    -u text_color_rgba=0xffffffff -u background_color_rgba=0x4b2e83ff -u font_weight=700 \
    image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm \
    image/bmp/bmp-to-png.wasm \
  > og-image.png
```

Form field names and values use standard percent encoding, and `+` decodes to a
space. Duplicate fields, unknown fields, malformed escapes, and a missing title
field cause a trap. An empty title is valid, including when the subtitle is also empty.

The component accepts these uniforms:

- `text_color_rgba`: packed `0xRRGGBBAA`; the default is `0x101010ff`.
- `background_color_rgba`: packed `0xRRGGBBAA`; the default is `0xeecc33ff`.
- `font_weight`: values below 550 select Regular 400 for the title; other values
  select Bold 700. The default is 700. The subtitle always uses Regular.
- `font_max_size`: `0` uses the default 112px auto-fit ceiling. Other values
  set a ceiling clamped to 32–160px; layout selects a smaller size when needed.

The reusable font data is in `lib/inter_display_latin_paths.zig` and
`lib/inter_display_bold_latin_paths.zig`. The tables contain outlines, advance
widths, and kerning pairs. `tools/generate-inter-display-zig.mjs` regenerates
them from the vendored Inter 4.1 TrueType files with QIP's TrueType parser and
`hb-shape`.

Coverage includes printable ASCII, U+00A0–U+00FF except soft hyphen U+00AD, and
common title punctuation: curly quotes, en and em dashes, bullet, ellipsis,
prime marks, angle quotes, euro, trademark, and the true minus sign. Tabs and
no-break spaces become ordinary spaces. Other codepoints cause a trap instead
of font fallback.

This bounded renderer applies proportional metrics and pair kerning. It does
not apply OpenType ligatures, contextual alternates, bidirectional layout,
combining-mark positioning, or general script shaping. Use a full shaping
engine for text outside this fixed Latin coverage.
