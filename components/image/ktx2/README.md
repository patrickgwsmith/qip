# KTX2 image components

KTX2 is the container. Names such as `VK_FORMAT_B8G8R8A8_SRGB` and
`VK_FORMAT_R32G32B32A32_SFLOAT` describe the pixel payload inside that
container. They are not complete interchange formats by themselves. See
[Image container names and pixel format names](../../../docs/formats.md#image-container-names-and-pixel-format-names)
for diagrams of the BMP and KTX2 layers and the repository's naming rules.

QIP uses `VK_FORMAT_R8G8B8A8_SRGB` as its canonical general-purpose 8-bit
Content image. Its top-down RGBA payload matches Canvas `ImageData` channel
order and maps directly to the common WebGL and OpenGL ES RGBA texture path.
Presentation code still queries the platform's preferred canvas format; it can
render this texture into either an RGBA or BGRA surface without a CPU swizzle.

The linear RGBA32F Content components use KTX2 as an intermediate image buffer.
Pixels are four little-endian IEEE 754 `f32` values in linear-light RGBA order.
This gives image transforms a file-shaped boundary without converting working
pixels back to 8-bit sRGB after every component.

The Display P3 RGBA32F profiles use the same float payload and narrow KTX2
shape. Their DFD declares Display P3 primaries and either a linear or sRGB
transfer function. Values above one retain HDR headroom. The transfer-encoded
profile remains float32; it is not a packed binary16 payload.

The original linear working profile is intentionally narrow:

- MIME type: `image/ktx2`
- `vkFormat`: `VK_FORMAT_R32G32B32A32_SFLOAT` (109)
- one 2D image, one mip level, one face, and no array layers
- no supercompression
- BT.709 primaries, linear transfer, and straight alpha in the DFD
- top-to-bottom, left-to-right (`KTXorientation=rd`)
- one tightly packed level at byte offset 224
- at most 25,000,000 pixels and 8192 pixels on either axis

The two Display P3 float profiles keep the same limits, Vulkan format, payload
offset, orientation, and straight alpha. Their DFD uses Display P3 primaries.
The `-linear` profile declares a linear transfer function; the presentation
profile declares the sRGB transfer function used by Display P3.

The strict profile keeps parsing small and makes the pixel payload directly
addressable in Wasm memory. It is not a general KTX2 decoder. Files with mip
chains, arrays, cubemaps, compressed texture data, a different data format
descriptor, or different metadata are rejected.

The canonical 8-bit profile has `vkFormat = VK_FORMAT_R8G8B8A8_SRGB` (43), one
2D level, straight alpha, and no supercompression. Its RGB bytes retain sRGB
encoding; alpha remains a linear UNORM byte. The repository retains the
`VK_FORMAT_B8G8R8A8_SRGB` components as an explicit alternate for boundaries
that require BGRA payload bytes. It is not the canonical Content profile.

The canonical KTX2 writers emit `KTXorientation=rd`: rows run from the logical top to
the bottom and pixels run left to right. The KTX specification recommends this
upper-left origin as the preferred default where possible and assumes `rd`
when the key is absent. Canonical profile readers require the explicit `rd`
metadata written by QIP. This keeps in-place RGBA8-to-RGBA32F expansion and
RGBA32F-to-RGBA8 compaction independent of row-order scratch memory.

## Components

`ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm` reduces canonical RGBA8 sRGB
KTX2 with a separable three-lobe Lanczos filter. `width` and `height` select
the output dimensions. Omit one dimension to preserve the input aspect ratio,
or omit both to reduce each axis by one half. The component rejects an output
that enlarges either axis. Direction mismatch is a recoverable rejection, so a
host can try another component on the same input without treating the module as
broken.

`ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm` enlarges the same profile with
the balanced Mitchell-Netravali bicubic filter (`B = C = 1/3`). It uses the
same dimension uniforms, doubles both axes by default, and rejects an output
that reduces either axis. This direction mismatch is also recoverable. An axis
whose size does not change passes through an identity filter instead of
receiving unnecessary bicubic softening.

Both resizers decode sRGB values to linear light before filtering. They
premultiply RGB by alpha, extend edge pixels across the filter support, and
return straight-alpha RGBA8 sRGB. This prevents hidden RGB in transparent
pixels from bleeding into visible edges. The output remains the canonical
KTX2 profile, so either component can sit between a decoder and an encoder:

```sh
./qip run -i input.ktx2 -o thumbnail.ktx2 \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm \
  -u width=1200 -u height=800

./qip run -i input.ktx2 -o enlarged.ktx2 \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm \
  -u width=2400
```

The resizers use center-convention coordinates and a separable float32
intermediate, one channel at a time. Their fixed 287.4 MiB memory holds the
25-megapixel input and output capacities plus one 25-megapixel float channel.
Use a simpler fixed-ratio or nearest-neighbor component when that fixed memory
cost is larger than the quality requirement permits.

The float32 equivalents name their complete colour profile:

- `ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm`
- `ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm`
- `ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.wasm`
- `ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm`

They use the same uniforms, defaults, kernels, and direction rejection. They
filter the already-linear values, preserve negative and HDR RGB values, and
clamp alpha to 0 through 1 after kernel overshoot. Each component accepts only
the profile named in its filename and writes the same profile. Transfer-encoded
Display P3 is not accepted. The 25-megapixel input, output, and single-channel
intermediate require 859.6 MiB of fixed Wasm memory.

`solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm` is an inputless
solid-colour generator. Set `width`, `height`, `lightness`, `chroma`,
`hue_degrees`, and `alpha`; all colour uniforms are `f32`. Lightness and alpha
are clamped to 0 through 1, chroma to 0 through 0.5, and hue wraps to 0
through 360 degrees. The output is straight-alpha linear Display P3 RGBA
`f32`. If the requested OKLCH colour is outside Display P3, the component
retains its lightness and hue and reduces its chroma to fit. It does not
generate HDR RGB values; use a direct linear-P3 generator when values outside
0 through 1 are required.

Each resizer also has a `-simd.wasm` variant. It processes four adjacent
destination pixels in the vertical pass with Wasm `f32x4` operations, then
uses the scalar path for the final one to three pixels of a row. The horizontal
pass remains scalar because its source positions are indirect and its RGBA
channels are interleaved. SIMD and scalar variants produce identical bytes.
Use the scalar component as a fallback for a host that cannot compile Wasm
SIMD. The image-resize worker tries the SIMD RGBA8 component first and compiles
the scalar component if that fails.

`ktx2-rgba32float-bt709-linear-resize-up-mitchell-odin-simd.wasm` is a measured
Odin prototype of the BT.709 float32 enlargement component. It has exact
output tests and a repeatable benchmark, but it is not yet the default and does
not replace the complete Zig resize family. Run a reused-instance V8 comparison
with any representative KTX2 input:

```sh
node --expose-gc tools/bench-ktx2-resize-simd.mjs \
  input.ktx2 2400 1600 \
  components/image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm \
  components/image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-simd.wasm \
  components/image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-odin-simd.wasm
```

`../bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm` decodes 32-bit uncompressed BMP
BGRA pixels. It converts sRGB colour channels to linear `f32`; alpha remains a
straight normalized value.

`ktx2-rgba32float-look-warm-fade.wasm` applies an authored 17x17x17 LUT with
trilinear interpolation. The look uses a restrained contrast curve, slightly
muted colour, cool shadows, and warm highlights. Its `strength` uniform accepts
0 through 1 and defaults to 1. The component changes the KTX2 pixel payload in
place, preserves alpha and container bytes, and retains excursions outside the
LUT's 0 through 1 domain. The LUT is source code in this repository and is
covered by the repository's Apache-2.0 license.

`ktx2-rgba32float-display-p3-linear-to-ktx2-rgba32float-display-p3.wasm`
applies the Display P3 transfer function to RGB in place. It preserves alpha
and extended float values. Use it at a presentation boundary which accepts
transfer-encoded P3. Keep the linear profile between filters that operate in
linear light.

`ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm` converts linear colour to 8-bit sRGB and
writes an uncompressed, bottom-up BGRA BMP. Converting through both adapters
without an intervening transform reproduces every input channel byte.

`../bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm` accepts positive-height
bottom-up and negative-height top-down BMPs. It reverses rows when needed and
swaps BGRA to the canonical top-down RGBA payload.

`ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm` performs the inverse row and
channel conversion and writes a bottom-up BMP.

`ktx2-r8g8b8a8-srgb-to-favicon.wasm` writes a single BMP-backed ICO image for
a canonical KTX2 no larger than 256×256. It reverses KTX2's top-down rows and
swaps RGBA to BGRA for the ICO bitmap. Use `bmp-to-ico.wasm` when the source is
already BMP; neither component resizes an image.

`ktx2-r8g8b8a8-srgb-color-palette.wasm` returns up to eight representative
opaque sRGB colours as DTCG 2025.10 design tokens with the
`application/design-tokens+json` content type. The `dev.qip.image-palette`
extension records each colour's rank, pixel count, and percentage. The
component ignores alpha when counting colours.

`ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm` converts a canonical KTX2 of at
most eight million pixels into grid-aligned SVG paths. It reduces retained pixels
to up to eight representative RGB colours, joins 4-connected regions, and
traces their pixel edges. `colors` accepts 1 through 8 and defaults to 8;
`alpha_threshold` accepts 1 through 255 and defaults to 128. Pixels below the
threshold are transparent, and retained alpha is made opaque. Use it for flat
icons, logos, diagrams, and pixel art. Do not use it for photos, gradients, or
anti-aliased artwork: those inputs can create too many paths and are rejected.

`ktx2-r8g8b8a8-srgb-double.wasm` replicates each pixel into an exact 2×2
block. It does not use the linear-light Mitchell reconstruction used by the
general KTX2 enlargement component. Its output is limited to 25 MP, so its
input is limited to 6.25 MP.

`ktx2-r8g8b8a8-srgb-rotate-and-flip.wasm` and
`ktx2-rgba32float-rotate-and-flip.wasm` apply lossless right-angle geometry.
The first accepts the canonical RGBA8 sRGB profile. The float32 component
preserves linear BT.709, linear Display P3, and transfer-encoded Display P3
metadata. `rotation_degrees` accepts `0`, `90`, `180`, or `270` clockwise;
`flip_horizontal` and `flip_vertical` accept zero or nonzero. Rotation runs
first, then the flips apply in the rotated image's coordinates. The components
remain separate because RGBA8 and RGBA32F use incompatible payload widths.

`ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm` converts sRGB colour to linear
`f32`. `ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm` converts back to sRGB bytes.
Both conversions preserve straight alpha and operate in place because their
KTX2 payloads start at the same byte offset. An RGBA8-to-float-to-RGBA8 round
trip reproduces every channel byte.

`../webp/webp-to-ktx2-r8g8b8a8-srgb.wasm` decodes static WebP directly into
the canonical RGBA payload. It rejects animated WebP and applies the standard
image limits.

`../png/png-to-ktx2-r8g8b8a8-srgb.wasm` decodes supported 8-bit,
non-interlaced PNGs directly into the canonical top-down RGBA payload. It
shares the strict parser and bounded inflater with the PNG-to-BMP component.

`../jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm` decodes sequential and progressive
Huffman JPEG directly into the canonical payload.
`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm`
accepts either strict 8-bit sRGB component order, composites straight alpha
against its configurable background, and encodes JPEG without a BMP boundary.

`../avif/avif-to-ktx2-r8g8b8a8-srgb.wasm` decodes one still AVIF directly
into canonical RGBA. The AVIF encoders record BT.709 primaries, the sRGB
transfer characteristic, and BT.601 matrix coefficients in CICP metadata.

`../svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm` renders SVG directly
into canonical top-down RGBA. It shares the parser and rasterizer with the BMP
component but writes pixels in their final KTX2 order.

`../svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm` uses SIMD
scanline path coverage with a 4 by 4 sample grid and composites premultiplied
paint in linear light. It returns straight-alpha linear BT.709 RGBA32F. The
matched-quality `../svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm`
quantizes the final image once and is useful when a downstream stage requires
canonical RGBA8.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm` accepts either exact sRGB
component order and writes an 8-bit RGBA PNG. RGBA rows pass directly into PNG
filtering; BGRA rows swap red and blue in the encoder's bounded row buffer.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm` passes either payload
order directly to libavif. It preserves alpha and exposes quality, alpha
quality, speed, and chroma-subsampling uniforms.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm` accepts either exact
sRGB component order with explicit `rd` orientation. It swaps R and B in a
disposable `VK_FORMAT_R8G8B8A8_SRGB` payload; a
`VK_FORMAT_B8G8R8A8_SRGB` payload already has the ARGB word representation
expected by libwebp on little-endian wasm32 and passes through unchanged. The
lossless encoder preserves RGB beneath transparent pixels.

`ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm` accepts only the canonical RGBA8
profile and uses the same in-place swap. Both encoders avoid an image-sized
libwebp import allocation and do not use a BMP component boundary.

`../bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm` accepts both positive-height
bottom-up BMP and negative-height top-down BMP. It copies BGRA channel bytes to
a canonical top-down KTX2 payload.

`ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm` copies the sRGB BGRA bytes back to a
bottom-up BMP. It accepts the common top-down KTX orientation, bottom-up `ru`,
and the specification's implicit top-down orientation. It rejects
`VK_FORMAT_B8G8R8A8_UNORM` because those bytes claim to contain linear colour.

For example:

```sh
./qip run \
  components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm \
  components/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm \
  '?strength=0.8' \
  components/image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm \
  -i input.bmp -o output.bmp
```

To apply the look and write WebP without a BMP intermediate:

```sh
./qip run \
  components/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm \
  components/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm \
  components/image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm \
  -i input.webp -o output.webp
```

The KTX2 payload costs 16 bytes per pixel. The converters reserve about 512
MiB to hold worst-case input and output buffers. Do not use this profile when
compact storage, network transfer, mipmaps, or direct support from ordinary
image viewers is the main requirement. Use BMP, PNG, JPEG, or WebP at those
boundaries.

The RGBA8 sRGB payload costs 4 bytes per pixel. Use it for general 8-bit image
content and GPU upload, but not between operations that need linear light or
more than 8-bit precision. The RGBA8/float converters share their input and
output buffer and reserve 512 MiB for the 25 MP RGBA32F limit.
