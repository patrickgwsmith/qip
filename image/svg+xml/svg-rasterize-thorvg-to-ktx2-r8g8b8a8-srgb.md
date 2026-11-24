# SVG to sRGB RGBA8 KTX2 with ThorVG

`svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm` parses SVG with ThorVG 1.1.1
and renders it with ThorVG's CPU scan converter. It writes straight-alpha RGBA8
sRGB pixels directly into a canonical KTX2 level.

The component is an alternative to QIP's smaller native SVG rasterizers. It
supports a broader SVG paint model and produces antialiased path edges, but it
uses more code and memory. The Wasm module has a fixed 512 MiB memory. Its
reclaiming arena makes 384 MiB available to ThorVG and reports allocation
telemetry through the standard `arena_*` exports.

Set `width` and `height` to choose the output size. An omitted dimension uses
the SVG intrinsic size. ThorVG preserves the drawing aspect ratio inside the
requested viewport. `background_color_rgba` accepts `0xRRGGBBAA` and defaults
to transparent. Uniforms reset after each invocation.

ThorVG resolves `currentColor` through the SVG `color` property and its
inheritance, with opaque black as the initial value. This wrapper does not
expose `current_color_rgba`; declare `color` in the SVG or run
`svg-recolor-current-color.wasm` when an external value must be baked into the
document.

The wrapper includes the CPU renderer, the SVG loader, and ThorVG's built-in
PNG (lodepng) and JPEG (jpgd) decoders. It does not load files, external
resources, WebP or GIF images, animation, GPU engines, or fonts. SVG `<text>`
is therefore out of scope.

## Embedded images

`<image>` draws PNG and JPEG bitmaps embedded as base64 `data:` URIs:

```svg
<image x="16" y="16" width="48" height="48"
       preserveAspectRatio="xMidYMid slice" clip-path="url(#round)"
       href="data:image/jpeg;base64,/9j/4AAQ…"/>
```

`href` and `xlink:href` both work. `preserveAspectRatio` follows SVG: the
default `xMidYMid meet` fits the bitmap inside `width` and `height`, `slice`
fills them and clips the overflow, and `none` stretches. A missing `width` or
`height` follows the bitmap's own size, keeping its aspect ratio when only one
is given. `clip-path`, `mask`, `opacity` and `transform` apply as they do to
other elements. Embedded SVG data URIs are also accepted, as ThorVG allows.

The component never resolves any other `href`. An `http:`, `file:` or relative
reference, an unsupported type such as GIF or WebP, and bad base64 or image
data are each skipped, and the rest of the SVG still draws. Only decoding that
runs out of the 384 MiB arena fails the whole render, so a small PNG that
declares a huge size cannot exhaust memory. Base64 makes images about a third
larger, so the 8 MiB input holds roughly 6 MiB of image bytes.

`<image>` sizing and `preserveAspectRatio` are QIP patches to ThorVG 1.1.1,
which stretches every bitmap to `width` and `height`. A further patch releases
an image that fails to load instead of leaking it.

TODO: add an explicit, bounded font input contract and ThorVG TTF/OTF loader.
The future design must say how a caller supplies font bytes and maps an SVG font
family to those bytes; it must not read host font files implicitly.

Do not use this component when 512 MiB of fixed Wasm memory is too costly, when
text is required, or when floating-point
linear-light output is required. Use the RGBA32F SIMD rasterizer for
linear-light pipelines.
