<title>Image content components</title>

# Image content components

These components accept an `image/*` MIME type. Common web and camera formats come first. Download a `.wasm` file and run it with [`qipx run`](/docs/qipx), or use the [recipe finder](/recipes) to connect compatible decoders, transforms, and encoders.

## JPEG (`image/jpeg`)

- [`jpeg-strip-gps-exif.wasm`](/image/jpeg/jpeg-strip-gps-exif.wasm) removes GPS coordinates from EXIF metadata without decoding the image.
- [`jpeg-to-bmp-b8g8r8a8-srgb.wasm`](/image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm) decodes JPEG to an 8-bit sRGB BMP image.
- [`jpeg-to-ktx2-r8g8b8a8-srgb.wasm`](/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm) decodes JPEG to an 8-bit sRGB KTX2 image.

Related tool: [JPEG location stripper](/jpeg-location-stripper).

## PNG (`image/png`)

- [`png-to-bmp-b8g8r8a8-srgb.wasm`](/image/png/png-to-bmp-b8g8r8a8-srgb.wasm) decodes PNG to an 8-bit sRGB BMP image.
- [`png-to-bmp-b8g8r8a8-srgb-simd.wasm`](/image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm) provides the SIMD PNG-to-BMP decoder.
- [`png-to-ktx2-r8g8b8a8-srgb.wasm`](/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm) decodes PNG to an 8-bit sRGB KTX2 image.

Related tools: [favicon generator](/favicon) and [image compressor](/image-compress).

## WebP (`image/webp`)

- [`webp-to-bmp-b8g8r8a8-srgb.wasm`](/image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm) decodes static WebP to an 8-bit sRGB BMP image.
- [`webp-to-ktx2-r8g8b8a8-srgb.wasm`](/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm) decodes static WebP to an 8-bit sRGB KTX2 image.

Related tool: [WebP to PNG or BMP](/webp-to-png).

## SVG (`image/svg+xml`)

- [`svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm`](/image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm) uses ThorVG's CPU renderer for broader SVG paint support and antialiased RGBA8 sRGB KTX2 output. This build does not include fonts or embedded raster-image decoders.
- [`svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm`](/image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm) uses SIMD scanline path coverage with a 4 by 4 sample grid and linear-light compositing, then writes linear BT.709 RGBA32F KTX2.
- [`svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm`](/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm) uses the same antialiasing path, then quantizes the completed image to canonical RGBA8 sRGB KTX2.
- [`svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm`](/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm) provides the faster center-sampled baseline in canonical RGBA8 sRGB KTX2.
- [`svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm`](/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm) provides BMP output for stages that still require it.
- [`svg-recolor-current-color.wasm`](/image/svg+xml/svg-recolor-current-color.wasm) replaces supported `currentColor` uses with a supplied color.
- [`svg-to-pdf-inter-font.wasm`](/image/svg+xml/svg-to-pdf-inter-font.wasm) converts a strict SVG vector subset to single-page PDF/A-2b with complete embedded Inter Regular, Bold, Italic, and Bold Italic text. It preserves paths, groups, affine transforms, supported native gradients, and element/group opacity; unsupported SVG rejects rather than rasterizing.
- [`svg-to-data-uri.wasm`](/image/svg+xml/svg-to-data-uri.wasm) percent-encodes SVG bytes as a data URI.

Related tools: [SVG data URI](/svg-data-uri), [QR code maker](/qr), and [Open Graph image maker](/og-image).

## GIF (`image/gif`)

- [`gifsicle-optimize.wasm`](/image/gif/gifsicle-optimize.wasm) optimizes a GIF while preserving its image data and animation.

## AVIF (`image/avif`)

- [`avif-to-ktx2-r8g8b8a8-srgb.wasm`](/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm) decodes AVIF to an 8-bit sRGB KTX2 image.

Related tool: [image compressor](/image-compress).

## BMP (`image/bmp`)

### Color and size

- [`bmp-b8g8r8a8-icc-to-srgb.wasm`](/image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm) converts supported embedded ICC color profiles to sRGB.
- [`bmp-color-palette.wasm`](/image/bmp/bmp-color-palette.wasm) returns a representative color palette as Design Tokens JSON.
- [`bmp-double.wasm`](/image/bmp/bmp-double.wasm) doubles the image dimensions with the C scaler.
- [`bmp-double2.wasm`](/image/bmp/bmp-double2.wasm) doubles the image dimensions with the Zig scaler.
- [`bmp-double-simd.wasm`](/image/bmp/bmp-double-simd.wasm) doubles the image dimensions with the SIMD scaler.

### Encode

- [`bmp-b8g8r8a8-srgb-to-avif-lossy.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm) encodes lossy AVIF.
- [`bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm) encodes lossy JPEG.
- [`bmp-b8g8r8a8-srgb-to-webp-lossless.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm) encodes exact lossless WebP.
- [`bmp-b8g8r8a8-srgb-to-webp-lossy.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm) encodes lossy WebP with alpha.
- [`bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm) encodes lossy WebP without alpha.
- [`bmp-to-ico.wasm`](/image/bmp/bmp-to-ico.wasm) creates an ICO favicon.
- [`bmp-to-png.wasm`](/image/bmp/bmp-to-png.wasm) encodes PNG.

### Convert to KTX2

- [`bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm) stores 8-bit BGRA sRGB pixels.
- [`bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm) stores 8-bit RGBA sRGB pixels.
- [`bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm`](/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm) stores 32-bit floating-point RGBA pixels.

Related tools: [image color palette](/image-color-palette), [favicon generator](/favicon), [BMP to WebP](/webp), and [image compressor](/image-compress).

## KTX2 (`image/ktx2`)

### Generate

- [`solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm`](/image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm) generates a straight-alpha linear Display P3 float32 KTX2 surface from `width`, `height`, `lightness`, `chroma`, `hue_degrees`, and `alpha` uniforms. It reduces out-of-gamut OKLCH chroma while preserving lightness and hue.

### Resize

- [`ktx2-r8g8b8a8-srgb-double.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-double.wasm) doubles canonical RGBA8 sRGB KTX2 with exact nearest-neighbor pixel replication.
- [`ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm) reduces canonical RGBA8 sRGB KTX2 with a three-lobe Lanczos filter.
- [`ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm) enlarges canonical RGBA8 sRGB KTX2 with balanced Mitchell-Netravali bicubic reconstruction.
- [`ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm`](/image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm) reduces linear BT.709 float32 KTX2.
- [`ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm`](/image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm) enlarges linear BT.709 float32 KTX2.
- [`ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.wasm`](/image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.wasm) reduces linear Display P3 float32 KTX2 and preserves HDR RGB values.
- [`ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm`](/image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm) enlarges linear Display P3 float32 KTX2 and preserves HDR RGB values.

The components filter in linear light with premultiplied alpha. They expose
`width` and `height` uniforms, preserve aspect ratio when one dimension is
omitted, and recoverably reject the opposite scaling direction.

### Rotate and flip

- [`ktx2-r8g8b8a8-srgb-rotate-and-flip.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-rotate-and-flip.wasm) rotates canonical RGBA8 sRGB KTX2 by right angles and flips it horizontally or vertically without changing channel values.
- [`ktx2-rgba32float-rotate-and-flip.wasm`](/image/ktx2/ktx2-rgba32float-rotate-and-flip.wasm) provides the same operation for linear BT.709, linear Display P3, and transfer-encoded Display P3 RGBA32F KTX2, preserving each profile's metadata.

Both components accept `rotation_degrees=0|90|180|270`, `flip_horizontal=0|1`,
and `flip_vertical=0|1`. Rotation is clockwise and happens before either flip.

Related tool: [high-quality image resizer](/image-resize).

### Decode and encode

- [`ktx2-r8g8b8a8-srgb-color-palette.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-color-palette.wasm) returns up to eight representative colors as JSON.
- [`ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm) traces flat RGBA8 sRGB KTX2 artwork into reduced-color, grid-aligned SVG paths.
- [`ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm`](/image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm) converts 8-bit BGRA sRGB KTX2 to BMP.
- [`ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm) converts 8-bit RGBA sRGB KTX2 to BMP.
- [`ktx2-r8g8b8a8-srgb-to-favicon.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-to-favicon.wasm) creates a single-image ICO favicon from canonical RGBA8 sRGB KTX2 up to 256×256.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm`](/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm) encodes lossy AVIF.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm`](/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm) encodes lossy JPEG.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm`](/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm) encodes PNG.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm`](/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm) encodes exact lossless WebP.
- [`ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm) encodes lossy WebP.

Related tool: [image vectorizer](/image/vectorize).

### Floating-point pipeline

- [`ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm`](/image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm) converts 8-bit sRGB pixels to 32-bit floating-point RGBA pixels.
- [`ktx2-rgba32float-look-warm-fade.wasm`](/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm) applies the warm-fade color look.
- [`ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm`](/image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm) converts floating-point RGBA pixels to an 8-bit sRGB BMP image.
- [`ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm`](/image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm) converts floating-point RGBA pixels to 8-bit sRGB KTX2.

## JPEG 2000 (`image/jp2`)

- [`jp2-to-bmp-b8g8r8a8-srgb.wasm`](/image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm) decodes JPEG 2000 to an 8-bit sRGB BMP image.

Looking for source formats and markup instead? See the [text content components](/text).
