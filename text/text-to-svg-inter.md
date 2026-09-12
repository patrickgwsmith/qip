# Text To SVG With Inter

`text-to-svg-inter.wasm` renders plain UTF-8 text as wrapped Inter Display
paths on a transparent SVG canvas. `measure` sets the maximum line width and
the SVG width. The component derives the SVG height from the font metrics,
line count, and line height. It does not add padding, shrink text, truncate
text, or vertically center the result. The paths inherit `currentColor`.

```bash
printf '%s' 'A transparent text layer that wraps onto additional lines.' |
  qip run text/text-to-svg-inter.wasm \
    -u font_size=64 -u measure=1080 -u alignment=0.5 \
  > text.svg
```

The component accepts these uniforms:

- `font_weight`: values below 550 select Regular 400; other values select Bold
  700. The default is 400.
- `font_size`: the exact font size in SVG user units. The default is 64. Zero
  renders zero-size paths.
- `measure`: the maximum line width and SVG viewport width in user units. The
  default is 1080. Text that cannot place one glyph within the measure fails.
- `line_height_em`: baseline advance as a multiple of `font_size`. The default
  is the font's authored 1.21em line height. Zero places every line on the same
  baseline; negative values clamp to zero.
- `alignment`: positions each line within the measure. Zero aligns to the
  beginning of the writing direction, 0.5 centers, and one aligns to the end.
  Intermediate values support animation; values clamp to 0–1. This version
  supports left-to-right text.
- `inspect_layout_metrics`: nonzero values add an inspection group containing
  measure edges, line bounds, ascenders, baselines, and descenders. It does not
  change the SVG dimensions or layout calculations and resets to zero.

The SVG inspection group has `data-inspect="layout_metrics"`. Its lines use
`data-metric` values so a host can identify or remove them without relying on
their diagnostic colors.

To set an explicit color, follow this component with
`svg-recolor-current-color.wasm`:

```bash
printf '%s' 'A colored text layer.' |
  qip run \
    text/text-to-svg-inter.wasm \
    image/svg+xml/svg-recolor-current-color.wasm \
      -u color_rgba=0x2563ebff \
  > text.svg
```

Without `color_rgba`, the recoloring component resolves `currentColor` to
opaque black. QIP's native SVG rasterizers and ThorVG also resolve
`currentColor` to opaque black. Set a native rasterizer's
`current_color_rgba` uniform to override it without rewriting the SVG.

Each render resets the uniforms to these authored defaults. Explicit newlines,
including empty lines, are preserved. Repeated spaces collapse, tabs and
non-breaking spaces become spaces, and wrapping otherwise occurs at word
boundaries. Words break at character boundaries when needed.

The input capacity is 4 KiB. The renderer accepts up to 1,024 code points and
16 lines with the fixed Latin coverage in `lib/inter_display_latin_paths.zig`.
It rejects invalid UTF-8, unsupported codepoints, excess lines, and glyphs that
cannot fit within the measure. Use a renderer with a shaping engine for other
scripts, bidirectional text, or combining-mark positioning.
