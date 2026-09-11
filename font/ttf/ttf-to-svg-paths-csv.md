# TrueType To SVG Paths CSV

`ttf-to-svg-paths-csv.wasm` extracts Unicode-mapped glyph outlines and font
metrics from a TrueType font. It emits one CSV row per mapped codepoint. The
`path_d` field contains SVG path data, so another component can generate Zig
font data, an SVG document, or a bitmap atlas without parsing TrueType again.

```bash
qip run \
  -i fixtures/dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf \
  -o dejavu-sans-paths.csv \
  -- font/ttf/ttf-to-svg-paths-csv.wasm
```

The default range is U+0020 through U+00FF. Select another inclusive range
with numeric uniforms:

```bash
qip run \
  -i font.ttf \
  -o basic-latin.csv \
  -- font/ttf/ttf-to-svg-paths-csv.wasm \
  -u first_codepoint=32 -u last_codepoint=126
```

The range may contain at most 4,096 codepoints. Unmapped codepoints do not
produce rows. Different codepoints that map to the same glyph produce separate
rows because the codepoint is the stable downstream key.

## Output

The component emits `text/csv` with these columns:

- `codepoint`, `hex`, and `glyph_id` identify the mapping.
- `advance_x` and `left_side_bearing` describe horizontal placement.
- `svg_x_min`, `svg_y_min`, `svg_x_max`, and `svg_y_max` bound the path.
- `units_per_em`, `svg_ascender_y`, `svg_descender_y`, and `line_gap` describe
  the font coordinate system.
- `path_d` contains absolute `M`, `L`, `Q`, and `Z` commands.

Coordinates remain in font units. The baseline is zero and Y is inverted from
the TrueType coordinate system for direct use in SVG. As a consequence,
`svg_ascender_y` is normally negative and `svg_descender_y` is normally
positive. Empty glyphs such as space have an empty `path_d` field.

## Supported TrueType Data

The parser reads Unicode `cmap` formats 4 and 12, horizontal metrics, simple
quadratic outlines, and compound glyphs positioned with XY offsets. It accepts
variable TTF files but emits only their default `glyf` outlines; it does not
apply variation-axis deltas.

The component does not parse CFF outlines from OTF files, font collections,
WOFF or WOFF2 compression, point-attached compound glyphs, hinting programs,
kerning, substitutions, positioning, bidirectional text, or shaping. Those
features are not required to extract independent glyph paths. Use a shaping
engine when output depends on adjacent characters or language.

Input is capped at 16 MiB and output at 32 MiB. The parser uses fixed scratch
space for 8,192 points, 1,024 contours, 128 pending components, and 16 compound
levels. It traps on malformed data, unsupported structures, limit violations,
or output overflow.
