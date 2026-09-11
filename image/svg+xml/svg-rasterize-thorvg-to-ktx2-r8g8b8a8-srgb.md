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

This first wrapper includes only the CPU renderer and SVG loader. It does not
load files, external resources, embedded PNG/JPEG/WebP images, animation, GPU
engines, or fonts. SVG `<text>` is therefore out of scope.

TODO: add an explicit, bounded font input contract and ThorVG TTF/OTF loader.
The future design must say how a caller supplies font bytes and maps an SVG font
family to those bytes; it must not read host font files implicitly.

Do not use this component when 512 MiB of fixed Wasm memory is too costly, when
text or embedded raster images are required, or when output must be composited
in linear light. Use the RGBA32F SIMD rasterizer for linear-light pipelines.
