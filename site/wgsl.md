<title>WGSL shaders: WebGPU vs WebAssembly</title>

# WGSL shaders: WebGPU vs WebAssembly

Pick an effect, or edit the shader. The page runs the same WGSL on your GPU
with WebGPU, and as WebAssembly that it compiles in your browser with
[`wgsl-to-wasm.wasm`](/text/wgsl/wgsl-to-wasm.wasm). Then it
compares the two outputs float for float. Nothing is uploaded.

<style>
/* Wider than the text measure, so the panel and a 2×2 grid of 512 px images fit.
   The input image sits at the bottom of the panel, below the uniforms, so the grid
   holds the outputs and their difference. */
.wgsl {
  --wgsl-width: min(90em, 100vw - 2em);
  box-sizing: border-box;
  width: var(--wgsl-width);
  margin-inline: calc((100% - var(--wgsl-width)) / 2);
  display: grid;
  grid-template-columns: minmax(18em, 24em) minmax(0, 1fr);
  grid-template-areas: "panel view" "source source";
  gap: 1.5rem 2rem;
  align-items: start;
}
.wgsl-panel {
  grid-area: panel;
  display: grid;
  gap: 1rem;
}
.wgsl-view {
  grid-area: view;
  display: grid;
  gap: 1rem;
}
/* One row per control: name, input, value. Subgrid aligns them across rows. */
.wgsl-controls {
  display: grid;
  grid-template-columns: max-content minmax(0, 1fr) 4.5em;
  gap: 0.6rem 0.75rem;
  align-items: center;
}
.wgsl-controls:empty {
  display: none;
}
#wgsl-uniforms,
.wgsl-image {
  padding-top: 1rem;
  border-top: 1px solid color-mix(in srgb, currentColor 25%, transparent);
}
.wgsl-controls > label {
  grid-column: 1 / -1;
  display: grid;
  grid-template-columns: subgrid;
  row-gap: 0.15rem;
  align-items: center;
}
.wgsl-controls > label > span {
  grid-column: 1;
}
.wgsl-controls > label > :is(input, select) {
  grid-column: 2 / -1;
  box-sizing: border-box;
  width: 100%;
  min-width: 0;
  margin: 0;
  font: inherit;
}
.wgsl-controls > label > input[type="range"] {
  grid-column: 2;
}
.wgsl-controls > label > input[type="color"] {
  width: 3.5em;
  height: 1.75em;
  padding: 0;
}
.wgsl-controls > label > output {
  --invert: 0;
  grid-column: 3;
  padding: 0;
  color: inherit;
  text-align: right;
  font-variant-numeric: tabular-nums;
  overflow: hidden;
  text-overflow: ellipsis;
}
.wgsl-controls > label > small {
  grid-column: 2 / -1;
  font-size: 0.8em;
  line-height: 1.3;
  opacity: 0.8;
}
.wgsl-controls > button {
  grid-column: 2 / -1;
  justify-self: start;
  font: inherit;
}
.wgsl-controls > label.wgsl-check {
  display: flex;
  gap: 0.5rem;
}
.wgsl-controls > label.wgsl-check > input {
  width: auto;
}
.wgsl-outputs {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}
.wgsl figure {
  margin: 0;
}
.wgsl figure canvas {
  display: block;
  width: 100%;
  height: auto;
  image-rendering: pixelated;
  border-radius: 0.35rem;
  background: repeating-conic-gradient(#8884 0 25%, transparent 0 50%) 0 0 / 16px 16px;
}
.wgsl figure figcaption {
  margin-top: 0.35rem;
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}
.wgsl-error {
  color: #c33;
}
.wgsl-summary {
  min-height: 1.5rem;
  margin: 0;
  font-variant-numeric: tabular-nums;
}
.wgsl-source {
  grid-area: source;
  box-sizing: border-box;
  width: 100%;
  min-height: 24rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
  tab-size: 2;
}
@media (max-width: 60em) {
  .wgsl {
    grid-template-columns: minmax(0, 1fr);
    grid-template-areas: "panel" "view" "source";
  }
}
@media (max-width: 30em) {
  .wgsl-outputs {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>

<div class="wgsl">
  <div class="wgsl-panel">
    <div class="wgsl-controls">
      <label><span>Effect</span><select id="wgsl-shader"></select></label>
      <label class="wgsl-check"><input id="wgsl-vectorize" type="checkbox">Vectorize Wasm invocations</label>
    </div>
    <div id="wgsl-uniforms" class="wgsl-controls"></div>
    <div class="wgsl-controls wgsl-image">
      <label><span>Image</span><input id="wgsl-file" type="file" accept="image/*"></label>
      <button id="wgsl-camera" type="button">Use camera</button>
    </div>
    <figure><canvas id="wgsl-input"></canvas><figcaption id="wgsl-input-caption">Input</figcaption></figure>
  </div>
  <div class="wgsl-view">
    <div class="wgsl-outputs">
      <figure><canvas id="wgsl-gpu"></canvas><figcaption id="wgsl-gpu-caption">WebGPU</figcaption></figure>
      <figure><canvas id="wgsl-wasm"></canvas><figcaption id="wgsl-wasm-caption">WebAssembly</figcaption></figure>
      <figure><canvas id="wgsl-diff" tabindex="0" aria-label="Difference image. Hover or focus to magnify small differences."></canvas><figcaption><span id="wgsl-diff-caption">Absolute difference ×65,536: black → red → yellow</span>. Hover or focus to magnify.</figcaption></figure>
    </div>
    <p id="wgsl-summary" class="wgsl-summary" aria-live="polite">Loading…</p>
  </div>
  <textarea id="wgsl-source" class="wgsl-source" spellcheck="false" aria-label="WGSL source"></textarea>
</div>

## Why the outputs can differ

Wasm `f32` arithmetic is IEEE 754 with correct rounding, so the Wasm output is
the same on every machine. WGSL lets GPUs compute `sqrt` and division less
precisely, and shader compilers can reorder or fuse floating-point operations.
Wasm has no `sin`, `cos`, `tan`, `asin`, `atan`, `tanh`, `exp`, `log` or `pow`
instructions, so the compiler inlines its own polynomial approximations. They
are accurate to about 3 ULP
(`pow` loses more as its result grows, and `atan2` is accurate to 2.4e-7
absolute, which is many ULP when its result is near zero), while GPUs may trade accuracy for speed:
WGSL allows `sin` an absolute error of 2⁻¹¹ in [−π, π] and does not bound it
outside that range. Small differences can be a few ULP (units in the last place). The heatmap scales
brightness by the largest absolute channel difference times the gain:
zero is black, and a difference of 1/gain or more is yellow. The gain is
65,536. Hover over the difference image or focus it with the keyboard to raise
the gain to 1,048,576 and inspect tiny errors. The
summary still counts every float mismatch. The ULP count
looks large near zero, where adjacent floats are closest
together: 7e-7 can be hundreds of ULP. **Comic book**, **Bulge**,
**Halftone dots** and **Fluted glass** compare floats or turn them into pixel indexes, so a one-ULP
change could move an outline or a sampled pixel; whether it does depends on the
GPU and the image. With the zigzag or pattern flutes, a few pixels on flute
boundaries often sample a different flute. **Voronoi** hashes each cell with
`fract` of products near 400, so GPU rounding moves cell centres slightly and
pixels on cell edges can differ by a few 8-bit levels. **Image dithering**'s
random type uses the same kind of hash, so a few pixels can switch color; its
Bayer types use exact thresholds.
**Mirror** and **Pop art** index with integers, so they should match bit for
bit.

## How it works

Each shader reads one `array<vec4f>` of RGBA32F pixels (16 bytes each),
up to 512×512. Most shaders write one `vec4f` per invocation; Atkinson dither
writes an 8×8 block. Pixel values are the image's sRGB values divided by 255,
without conversion to linear light.

- **WebGPU:** the page creates a compute pipeline with `layout: "auto"`, passes
  each `override` as a pipeline constant, dispatches one invocation per pixel,
  and copies the output buffer back.
- **WebAssembly:** `wgsl-to-wasm.wasm` compiles the source to a QIP
  content component. Each `override` becomes a `uniform_set_<name>` export, and
  `render` runs the entry point once per element with SIMD for `vec4f`.

**Chromatic aberration** is a fragment shader instead. Its
`@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f` runs
once per pixel and returns that pixel's color. It reads the image from a
`texture_2d<f32>` with `textureLoad` and `textureDimensions`.

- **WebGPU:** the page draws one triangle over an rgba32float texture cleared
  to transparent black, with the image in a second rgba32float texture.
- **WebAssembly:** `render` calls the entry point for each pixel in row order,
  with `pos` set to `(x + 0.5, y + 0.5, 0, 1)` as on the GPU. The module has
  its own `width` uniform for the rows, so the shader cannot declare one.
  `discard` leaves the pixel transparent black, the same as the GPU's cleared
  texture. A `textureLoad` outside the image is limited as Chrome's Dawn
  does, to `min(u32(c), size - 1)`, so a negative coordinate reads the last
  column or row. WGSL allows any pixel or zero, so the example clamps its
  coordinates itself.
  `vec2i` and `vec2u` support constructors, conversions, `.x`, `.y` and
  swizzles, and `+ - *`.

**Rings** uses `fwidth` to antialias its edges. GPUs compute `dpdx`, `dpdy` and
`fwidth` from the 2×2 square of pixels that each pixel belongs to, so the Wasm
render runs each 2×2 square together. It runs the shader for all four pixels,
including pixels past an odd right or bottom edge, whose output it drops as the
GPU does. Each derivative call records its argument, and the derivative is the
difference between neighbours in the same row or column of the square. Chrome
on a Mac computes the `Coarse` forms per row and column too, which WGSL
allows, so the Wasm render does the same. A pixel that `discard`s inside an
`if` keeps running, so its neighbours still get its values. The shader runs at
least twice per pixel, plus once more for each derivative of a derivative.

The page sets `width` to the image width. A trailing `// min..max` comment on an
`override` gives it a slider. The compiler accepts a subset of WGSL. Helper
functions compile to Wasm functions; they must come before the entry point and
call only helpers above them. Loops must be
`for (var i = start; i < N; i++)`, where the bound and step are integer
literals or `const`s, the comparison runs the way the step does, and the body
doesn't assign `i`. They may use `break` and `continue`; `while` and `loop`
are unsupported. A module-scope `const` array of literals, such as
`const BAYER4 = array<f32, 16>(…)`, becomes a data segment, and an index past
the end reads the last element, as Chrome does. Shaders with loops, helper
calls or constant-array reads keep the scalar path when vectorized. Run it on the command line with `qip`:

```bash
qip run -i edges.wgsl -o edges.wasm text/wgsl/wgsl-to-wasm.wasm
qip run -i photo.rgba32f -o edges.rgba32f edges.wasm -u width=256 -u threshold=0.3
```

Enable **Vectorize Wasm invocations** to compile eligible shaders in groups of
four invocations with SIMD. The caption reports when a shader keeps the scalar
path. The option is off by default: generated modules are larger and simple
shaders can be slower. To use it from the CLI, pass
`-u vectorize_invocations=1` to `wgsl-to-wasm.wasm` when compiling.

To add an effect, add a `<script type="text/wgsl" data-name="…">` block to
this page.

**Atkinson dither** converts luma to black and white in independent 8×8 blocks.
Each pixel sends one eighth of its rounding error to six later neighbours.
Error resets at block edges, so the pattern can repeat every eight pixels.
The page generates unrolled WGSL, written before the compiler supported
loops. Adjust `threshold` to change the balance of black and white.

**Perlin noise** generates a two-color field from 3D gradient noise with
quintic interpolation and up to eight octaves. Like the
[Paper Perlin noise example](https://shaders.paper.design/perlin-noise), it has
controls for color balance, edge softness, persistence, and lacunarity.
Move `time` to explore the third dimension. It ignores the input image except
for its dimensions. This implementation uses an integer lattice hash, so its
patterns differ from [Paper's GLSL shader](https://github.com/paper-design/shaders/blob/main/packages/shaders/src/shaders/perlin-noise.ts).

**Halftone dots** is a port of the classic dot style from
[Paper's Halftone Dots](https://shaders.paper.design/halftone-dots)
([GLSL source](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/halftone-dots.ts)).
Each dot's size follows the luma at its centre. Set `grid` to 1 for
hex rows or 0 for a square grid. `spacing` is the distance between dots in
pixels. Paper Shaders is licensed under the
[Apache License 2.0](/licenses/paper-shaders-LICENSE.txt)
(NOTICE: “Powered by Paper Shaders: https://shaders.paper.design”). We changed the shader to fit what the compiler
supported when it was ported:

- The four overlapping dot samples are unrolled, in place of loops and helper
  functions.
- An algebraic sigmoid, `0.5 + 0.5·s / √(1 + s²)`, replaces Paper's logistic
  contrast curve. It has the same slope at mid-grey.
- A fixed one-pixel edge replaces `fwidth` antialiasing.
- The image is sampled nearest-neighbour.
- Dot spacing is set in pixels, in place of Paper's `size`.
- Only the classic dots are included. The gooey, holes and soft styles, original
  colors, and grain are left out.

**Fluted glass**, **Waves**, **Spiral** and **Swirl** are ports of
[Paper's Fluted Glass](https://shaders.paper.design/fluted-glass),
[Waves](https://shaders.paper.design/waves),
[Spiral](https://shaders.paper.design/spiral) and
[Swirl](https://shaders.paper.design/swirl), from the GLSL at the same commit
([fluted glass](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/fluted-glass.ts),
[waves](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/waves.ts),
[spiral](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/spiral.ts),
[swirl](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/swirl.ts)),
under the same licence. Fluted glass refracts the image through vertical flutes:
`shape` picks lines, irregular lines, wave, zigzag or pattern flutes, and
`distortion_shape` picks prism, lens, contour, cascade or flat glass. The other
three draw patterns and ignore the input image except for its dimensions. The
defaults follow Paper's default presets, with `time` at 0. We changed them to
fit what the compiler supported when they were ported:

- Each `fwidth(f)` becomes `|f(x + 1, y) − f(x, y)| + |f(x, y + 1) − f(x, y)|`,
  so the page generates the code that computes `f` three times. Fluted glass
  uses the undistorted pixel size at the image's edges.
- Helper functions, including simplex noise, are inlined, and Swirl's color
  loop is unrolled to three bands.
- Pixels are measured in image pixels, with a device pixel ratio of 1. Fluted
  glass defaults to `size` 0.77 so that flutes on a 512-pixel image are about as
  wide as Paper's default on a full-size canvas.
- Waves, Spiral and Swirl output opaque colors. Fluted glass keeps Paper's
  transparent background but outputs straight rather than premultiplied alpha.
- Fluted glass leaves out the margins, blur and grain, and it samples the image
  bilinearly in the shader.
- `pow` is kept defined: the contour glass takes `abs` before its even power,
  and Swirl clamps noise below 0. Swirl keeps its `smoothstep` edges apart,
  including when twist or softness is 0.
- The color-banding dither is left out, because it scales `sin` by 43,758 and
  would turn GPU rounding into visible noise.

**Mesh gradient**, **Neuro noise**, **Dot grid** and **Voronoi** are ports of
[Paper's Mesh Gradient](https://shaders.paper.design/mesh-gradient),
[Neuro Noise](https://shaders.paper.design/neuro-noise),
[Dot Grid](https://shaders.paper.design/dot-grid) and
[Voronoi](https://shaders.paper.design/voronoi), from the GLSL at the same commit
([mesh gradient](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/mesh-gradient.ts),
[neuro noise](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/neuro-noise.ts),
[dot grid](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/dot-grid.ts),
[Voronoi](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/voronoi.ts)),
under the same licence. All four draw patterns, ignore the input image except
for its dimensions, and output opaque colors. The defaults follow Paper's
default presets, with `time` at 0. We changed them to fit what the compiler supported when they were ported:

- Mesh gradient now uses a WGSL loop for its two distortion passes. Its color
  spots, neuro noise's 15 layers, and Voronoi's 3×3 and 5×5 cell searches remain
  unrolled. Mesh gradient has up to four colors and Voronoi up to three, in place of Paper's
  ten and five.
- Mesh gradient leaves out both grain effects.
- Voronoi uses Paper's `hash22` in place of its noise texture, so its cells
  differ from Paper's.
- Dot grid's `fwidth` follows the Fluted glass approach, but it measures the
  neighbours from this pixel's cell so cell boundaries don't show.
- Dot sizes and gaps are in image pixels, with a device pixel ratio of 1.
- Colors are clamped to [0, 1], as Paper's framebuffer does: neuro noise
  reaches 1.4, Voronoi's glow can overshoot, and dot grid's opacity randomizer
  can exceed 1.
- `pow` is kept defined: mesh gradient floors its distance before raising it
  to 3.5, and Voronoi writes `pow(glow, 1.5)` as `glow · √glow`. Dot grid keeps
  its `smoothstep` edges apart where the distance is flat.

**Image dithering**, **Simplex noise**, **Static mesh gradient** and **Static
radial gradient** are ports of
[Paper's Image Dithering](https://shaders.paper.design/image-dithering),
[Simplex Noise](https://shaders.paper.design/simplex-noise),
[Static Mesh Gradient](https://shaders.paper.design/static-mesh-gradient) and
[Static Radial Gradient](https://shaders.paper.design/static-radial-gradient),
from the GLSL at the same commit
([image dithering](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/image-dithering.ts),
[simplex noise](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/simplex-noise.ts),
[static mesh gradient](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/static-mesh-gradient.ts),
[static radial gradient](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/static-radial-gradient.ts)),
under the same licence. Image dithering reduces the input image to a palette
with random or 2×2, 4×4 or 8×8 Bayer dithering; set `original_colors` to 1 to
keep the image's hues. The other three draw patterns and ignore the input image
except for its dimensions. All four output opaque colors, apart from image
dithering's `original_colors` mode, which keeps Paper's alpha. The defaults
follow Paper's default presets, with `time` at 0. We changed them to fit what the
compiler supported when they were ported:

- The Bayer matrices are built from the interleaved bits of `x ^ y` and `y`,
  in place of constant arrays. They give the same thresholds as Paper's tables.
- Image dithering fills the frame with the image, as Paper's `cover` fit does
  when the image and canvas match, samples it nearest-neighbour, and leaves out
  the frame fade, which is always 1 here.
- Loops are unrolled: simplex noise has up to five colors, the static mesh
  gradient up to four and the static radial gradient up to three, matching
  their default presets in place of Paper's ten.
- Simplex noise and the static radial gradient emulate `fwidth` like Fluted
  glass, and keep their `smoothstep` edges and divisions apart where it is 0.
- Both static gradients leave out grain, and simplex noise leaves out the
  color-banding dither, as Swirl does.
- `pow` is kept defined at 0 by flooring or selecting around its base.

**Liquid Metal (shapes)** ports the built-in circle, daisy, diamond and
metaballs from [Paper's Liquid Metal](https://shaders.paper.design/liquid-metal)
([pinned GLSL source](https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/liquid-metal.ts))
under the same licence. It draws a moving stripe pattern and uses the shape
edge to bend it. The input image supplies only the canvas size. Choose the
shape beside the control; adjust repetition, angle, contour, softness and
color dispersion to see how the edge changes the stripes.

This port covers Paper's built-in shapes, including its five-step metaball
loop. It omits uploaded-image masks, which Paper prepares with a Poisson
solver before the shader runs. The background is opaque, and a simple
procedural ripple replaces Paper's simplex noise and color-banding dither.
The shape edge and stripe antialiasing use fragment `fwidth` directly.

**Color ring (vgpu)** is the `main.wgsl` and `color.wgsl` example from the
[vgpu](https://vgpu.sh/) home page, a glowing ring tinted by a cosine palette.
vgpu is © 2025 Vercel, Inc. and licensed under the
[MIT License](/licenses/vgpu-LICENSE.txt). The palette is inlined in place of
vgpu's WGSL `import`, and the size comes from the input texture in place of a
`resolution` uniform, so the input image supplies only the canvas size.
Colors are clamped to [0, 1], as vgpu's framebuffer does.

<script type="text/wgsl" data-name="Edges">
// Sobel edge detection on luma. A threshold of 0 shows the gradient strength.
override width: u32 = 256;
override threshold: f32 = 0.0; // 0..1
override gain: f32 = 1.0; // 0..4

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  // Clamp neighbours to the edge of the image.
  let l = max(x, 1u) - 1u;
  let r = min(x + 1u, width - 1u);
  let u = (max(y, 1u) - 1u) * width;
  let m = y * width;
  let d = min(y + 1u, height - 1u) * width;
  let k = vec3f(0.2126, 0.7152, 0.0722);
  let tl = dot(src[u + l].rgb, k);
  let tm = dot(src[u + x].rgb, k);
  let tr = dot(src[u + r].rgb, k);
  let ml = dot(src[m + l].rgb, k);
  let mr = dot(src[m + r].rgb, k);
  let bl = dot(src[d + l].rgb, k);
  let bm = dot(src[d + x].rgb, k);
  let br = dot(src[d + r].rgb, k);
  let gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
  let gy = (bl + 2.0 * bm + br) - (tl + 2.0 * tm + tr);
  let g = sqrt(gx * gx + gy * gy) * gain;
  var e = min(g, 1.0);
  if threshold > 0.0 { e = select(0.0, 1.0, g > threshold); }
  dst[id.x] = vec4f(e, e, e, 1.0);
}
</script>

<script type="text/wgsl" data-name="Comic book">
// Three flat tones with black Sobel outlines.
override width: u32 = 256;
override outline: f32 = 0.35; // 0..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  let l = max(x, 1u) - 1u;
  let r = min(x + 1u, width - 1u);
  let u = (max(y, 1u) - 1u) * width;
  let m = y * width;
  let d = min(y + 1u, height - 1u) * width;
  let k = vec3f(0.2126, 0.7152, 0.0722);
  let tl = dot(src[u + l].rgb, k);
  let tm = dot(src[u + x].rgb, k);
  let tr = dot(src[u + r].rgb, k);
  let ml = dot(src[m + l].rgb, k);
  let mr = dot(src[m + r].rgb, k);
  let bl = dot(src[d + l].rgb, k);
  let bm = dot(src[d + x].rgb, k);
  let br = dot(src[d + r].rgb, k);
  let gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
  let gy = (bl + 2.0 * bm + br) - (tl + 2.0 * tm + tr);
  let c = src[id.x];
  let tone = floor(clamp(dot(c.rgb, k), 0.0, 0.999) * 3.0) / 2.0;
  var ink = mix(vec3f(0.15, 0.1, 0.35), vec3f(1.0, 0.95, 0.8), tone);
  if gx * gx + gy * gy > outline * outline { ink = vec3f(0.0); }
  dst[id.x] = vec4f(ink, 1.0);
}
</script>

<script type="text/wgsl" data-name="Thermal camera">
// Brightness mapped to a black-body style palette.
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let c = src[id.x];
  let t = clamp(dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722)), 0.0, 1.0) * 4.0;
  var h = mix(vec3f(0.0, 0.0, 0.25), vec3f(0.45, 0.0, 0.75), clamp(t, 0.0, 1.0));
  h = mix(h, vec3f(1.0, 0.0, 0.25), clamp(t - 1.0, 0.0, 1.0));
  h = mix(h, vec3f(1.0, 0.8, 0.0), clamp(t - 2.0, 0.0, 1.0));
  h = mix(h, vec3f(1.0), clamp(t - 3.0, 0.0, 1.0));
  dst[id.x] = vec4f(h, c.a);
}
</script>

<script type="text/wgsl" data-name="X-ray">
// Inverted brightness with a cold blue tint.
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let c = src[id.x];
  let l = 1.0 - dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
  dst[id.x] = vec4f(l * vec3f(0.8, 0.9, 1.0), c.a);
}
</script>

<script type="text/wgsl" data-name="Pop art">
// Four two-color copies of the image, one per quadrant.
override width: u32 = 256;
override threshold: f32 = 0.45; // 0..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  let tile = select(0u, 1u, x * 2u >= width) + select(0u, 2u, y * 2u >= height);
  let sx = min(x * 2u % width, width - 1u);
  let sy = min(y * 2u % height, height - 1u);
  let c = src[sy * width + sx];
  let light = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722)) > threshold;
  var ink = vec3f(0.9, 0.1, 0.5);
  var paper = vec3f(1.0, 0.9, 0.1);
  if tile == 1u {
    ink = vec3f(0.1, 0.2, 0.7);
    paper = vec3f(1.0, 0.5, 0.6);
  } else if tile == 2u {
    ink = vec3f(0.0, 0.5, 0.3);
    paper = vec3f(0.6, 0.9, 1.0);
  } else if tile == 3u {
    ink = vec3f(0.4, 0.1, 0.6);
    paper = vec3f(1.0, 0.6, 0.2);
  }
  dst[id.x] = vec4f(select(ink, paper, light), 1.0);
}
</script>

<script type="text/wgsl" data-name="Sepia">
// Sepia tone, blended with the original by amount.
override amount: f32 = 1.0; // 0..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let c = src[id.x];
  let s = vec3f(
    dot(c.rgb, vec3f(0.393, 0.769, 0.189)),
    dot(c.rgb, vec3f(0.349, 0.686, 0.168)),
    dot(c.rgb, vec3f(0.272, 0.534, 0.131))
  );
  dst[id.x] = vec4f(mix(c.rgb, min(s, vec3f(1.0)), amount), c.a);
}
</script>

<script type="text/wgsl" data-name="Bulge">
// Bulge (strength > 0) or dent (strength < 0) around the centre, sampled
// nearest-neighbour.
override width: u32 = 256;
override strength: f32 = 0.6; // -1..1
override radius: f32 = 0.8; // 0.1..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let dx = f32(id.x % width) + 0.5 - cx;
  let dy = f32(id.x / width) + 0.5 - cy;
  let r = sqrt(dx * dx + dy * dy) / (radius * min(cx, cy));
  var s = 1.0;
  if r < 1.0 { s = mix(1.0, r, strength); }
  let sx = u32(clamp(cx + dx * s, 0.0, f32(width - 1u)));
  let sy = u32(clamp(cy + dy * s, 0.0, f32(height - 1u)));
  dst[id.x] = src[sy * width + sx];
}
</script>

<script type="text/wgsl" data-name="Mirror">
// The left half reflected onto the right. Integer indexing only, so WebGPU
// and Wasm should match exactly.
override width: u32 = 256;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let x = id.x % width;
  let y = id.x / width;
  let mx = select(x, width - 1u - x, x >= width / 2u);
  dst[id.x] = src[y * width + mx];
}
</script>

<script type="text/wgsl" data-name="Chromatic aberration (fragment)">
// A fragment shader: red and blue are read further from and nearer to the
// centre than green, like a cheap lens.
override strength: f32 = 6.0; // 0..24

@group(0) @binding(0) var src: texture_2d<f32>;

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(src));
  let offset = (pos.xy - size * 0.5) / (size * 0.5) * strength;
  // Clamp in floats: an out-of-range textureLoad is indeterminate in WGSL.
  let edge = size - 1.0;
  let r = textureLoad(src, vec2i(clamp(pos.xy + offset, vec2f(0.0), edge)), 0).r;
  let c = textureLoad(src, vec2i(pos.xy), 0);
  let b = textureLoad(src, vec2i(clamp(pos.xy - offset, vec2f(0.0), edge)), 0).b;
  return vec4f(r, c.g, b, c.a);
}
</script>

<script type="text/wgsl" data-name="Rings (fragment, fwidth)">
// A fragment shader: rings around the centre, tinted by the image, with
// edges antialiased by fwidth over each 2x2 quad of pixels.
override spacing: f32 = 24.0; // 4..64
override thickness: f32 = 0.3; // 0.05..0.95

@group(0) @binding(0) var src: texture_2d<f32>;

fn rings(p: vec2f, size: vec2f) -> f32 {
  return length(p - size * 0.5) / spacing;
}

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(src));
  let d = rings(pos.xy, size);
  let aa = fwidth(d);
  // Distance from the middle of the nearest ring, in rings.
  let edge = abs(fract(d) - 0.5) - thickness * 0.5;
  let ink = 1.0 - smoothstep(-aa, aa, edge);
  let c = textureLoad(src, vec2i(pos.xy), 0);
  return vec4f(mix(c.rgb * 0.35, c.rgb, ink), c.a);
}
</script>

<script type="text/wgsl" data-name="Atkinson dither" data-generated="atkinson">
// Generated below: Atkinson error diffusion in independent 8x8 blocks.
</script>

<script type="text/wgsl" data-name="Perlin noise" data-generated="perlin">
// Generated below: 3D gradient noise with eight unrolled octaves.
</script>

<script type="text/wgsl" data-name="Halftone dots" data-generated="halftone">
// Generated below: Paper's classic halftone dots with four unrolled samples.
</script>

<script type="text/wgsl" data-name="Fluted glass" data-generated="fluted-glass">
// Generated below: Paper's fluted glass, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Waves" data-generated="waves">
// Generated below: Paper's waves, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Spiral" data-generated="spiral">
// Generated below: Paper's spiral, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Swirl" data-generated="swirl">
// Generated below: Paper's swirl, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Mesh gradient" data-generated="mesh-gradient">
// Generated below: Paper's mesh gradient with four unrolled color spots.
</script>

<script type="text/wgsl" data-name="Neuro noise" data-generated="neuro-noise">
// Generated below: Paper's neuro noise with 15 unrolled layers.
</script>

<script type="text/wgsl" data-name="Dot grid" data-generated="dot-grid">
// Generated below: Paper's dot grid, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Voronoi" data-generated="voronoi">
// Generated below: Paper's Voronoi with both cell searches unrolled.
</script>

<script type="text/wgsl" data-name="Image dithering" data-generated="image-dithering">
// Generated below: Paper's image dithering with bit-built Bayer matrices.
</script>

<script type="text/wgsl" data-name="Simplex noise" data-generated="simplex-noise">
// Generated below: Paper's simplex noise, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Static mesh gradient" data-generated="static-mesh-gradient">
// Generated below: Paper's static mesh gradient with four unrolled colors.
</script>

<script type="text/wgsl" data-name="Static radial gradient" data-generated="static-radial-gradient">
// Generated below: Paper's static radial gradient, with neighbour samples for fwidth.
</script>

<script type="text/wgsl" data-name="Liquid metal (shapes)">
// Built-in shapes and stripes ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders/blob/1923e9f536ea079e2a95d23291cbfacfd69d37f6/packages/shaders/src/shaders/liquid-metal.ts
// Changes are listed on qip.dev/wgsl. Input colors are unused.
override shape: u32 = 1; // 0..4
override time: f32 = 0.0; // 0..10
override repetition: f32 = 4.0; // 1..10
override softness: f32 = 0.25; // 0..1
override contour: f32 = 0.5; // 0..1
override distortion: f32 = 0.25; // 0..1
override angle: f32 = 0.0; // 0..360
override shift_red: f32 = 0.3; // -1..1
override shift_blue: f32 = 0.3; // -1..1
override back_r: f32 = 0.08;
override back_g: f32 = 0.08;
override back_b: f32 = 0.1;

const PI: f32 = 3.14159265358979323846;
@group(0) @binding(0) var src: texture_2d<f32>;

fn edgeAt(uv: vec2f, t: f32) -> f32 {
  let p = uv - vec2f(0.5);
  if shape == 0u {
    let m = min(uv, vec2f(1.0) - uv);
    return 1.0 - pow(smoothstep(0.0, 0.14, m.x) * smoothstep(0.0, 0.14, m.y), 0.25);
  }
  if shape == 1u {
    return pow(clamp(2.01 * length(p), 0.0, 1.0), 18.0);
  }
  if shape == 2u {
    let q = p * 1.68;
    let a = atan2(q.y, q.x) + 0.2;
    let r = length(q) * 2.0 * (1.0 + 0.05 * sin(3.0 * a + 2.0 * t));
    let e = smoothstep(abs(cos(3.0 * a)), abs(cos(3.0 * a)) + 0.7, r);
    return e * e;
  }
  if shape == 3u {
    let q = vec2f(p.x - p.y, p.x + p.y) * 1.0041 + vec2f(0.5);
    let m = min(q, vec2f(1.0) - q);
    return 1.0 - pow(smoothstep(0.0, 0.15, m.x) * smoothstep(0.0, 0.15, m.y), 0.25);
  }
  var sum = 0.0;
  for (var i = 0; i < 5; i++) {
    let fi = f32(i);
    let speed = 1.5 + (2.0 / 3.0) * sin(fi * 12.345);
    let a = -fi * 1.5;
    let d1 = vec2f(cos(a), sin(a));
    let d2 = vec2f(cos(a + 1.57), sin(a + 1.0));
    let traj = 0.4 * (d1 * sin(t * speed + fi * 1.23) +
      d2 * cos(t * speed * 0.7 + fi * 2.17));
    sum += pow(1.0 - clamp(length(p * 1.3 + traj), 0.0, 1.0), 4.0);
  }
  return pow(1.0 - smoothstep(0.65, 0.9, sum), 4.0);
}

fn stripeChannel(c1: f32, c2: f32, phase: f32, blur: f32) -> f32 {
  let thin1 = 0.12;
  let thin2 = 0.07;
  var c = mix(c2, c1, smoothstep(0.0, 2.0 * blur, phase));
  c = mix(c, c2, smoothstep(thin1, thin1 + 2.0 * blur, phase));
  c = mix(c, c1, smoothstep(thin1 + 0.18, thin1 + 0.18 + 2.0 * blur, phase));
  c = mix(c, c2, smoothstep(thin1 + thin2 + 0.22, thin1 + thin2 + 0.22 + 2.0 * blur, phase));
  let gradient = mix(c1, c2, smoothstep(0.0, 1.0, (phase - thin1 - thin2) / 0.81));
  return mix(c, gradient, smoothstep(thin1 + thin2, thin1 + thin2 + blur, phase));
}

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(src));
  let uv = pos.xy / size;
  let t = 0.3 * (time + 2.8);
  let raw_edge = edgeAt(uv, t);
  let edge_aa = max(fwidth(raw_edge), 0.00001);
  let edge = mix(1.0 - smoothstep(0.9 - 2.0 * edge_aa, 0.9, raw_edge),
    raw_edge, smoothstep(0.0, 0.4, contour));
  let opacity = 1.0 - smoothstep(0.9 - 2.0 * edge_aa, 0.9, raw_edge);
  let a = (70.0 - angle) * PI / 180.0;
  let p = uv - vec2f(0.5);
  let rotated = vec2f(p.x * cos(a) - p.y * sin(a),
    p.x * sin(a) + p.y * cos(a)) + vec2f(0.5);
  let diagonal = rotated.x - rotated.y;
  let noise = sin(uv.x * 31.0 + t) * cos(uv.y * 27.0 - t) * 0.5;
  let distance = length(p + vec2f(0.0, 0.2 * diagonal));
  let bump = (1.0 - pow(max(1.8 * distance, 0.00001), 1.2)) *
    pow(max(uv.y, 0.00001), 0.3);
  let bend = smoothstep(0.0, 1.0, edge);
  var direction = p.x * cos(0.25 * PI - 0.2 * diagonal) -
    p.y * sin(0.25 * PI - 0.2 * diagonal) + diagonal;
  direction -= 2.0 * noise * diagonal * bend * (1.0 - bend);
  direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, contour));
  direction -= 1.7 * edge * smoothstep(0.5, 1.0, contour);
  direction *= (0.1 + (1.1 - edge) * bump) * repetition;
  direction += distortion * noise;
  direction -= t;
  let red_phase = fract(direction + shift_red * (1.0 - bump) / 20.0);
  let green_phase = fract(direction);
  let blue_phase = fract(direction - shift_blue * (1.0 - bump) / 20.0);
  let blur = softness / 15.0;
  let red = stripeChannel(0.98, 0.1, red_phase, max(blur + fwidth(red_phase), 0.00001));
  let green = stripeChannel(0.98, 0.1, green_phase, max(blur + fwidth(green_phase), 0.00001));
  let blue = stripeChannel(1.0, 0.1, blue_phase, max(blur + fwidth(blue_phase), 0.00001));
  let color = vec3f(red, green, blue) * opacity +
    vec3f(back_r, back_g, back_b) * (1.0 - opacity);
  return vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0);
}
</script>

<script type="text/wgsl" data-name="Color ring (vgpu)">
// The main.wgsl and color.wgsl example from https://vgpu.sh/
// Copyright (c) 2025 Vercel, Inc. MIT License: qip.dev/licenses/vgpu-LICENSE.txt
// The palette is inlined and the size comes from the texture. Input colors are unused.
@group(0) @binding(0) var src: texture_2d<f32>;

fn palette(t: f32) -> vec3f {
  let phase = vec3f(0.0, 0.33, 0.67);
  return 0.55 + 0.45 * cos(6.28318 * (t + phase));
}

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let resolution = vec2f(textureDimensions(src));
  let uv = pos.xy / resolution;
  let shortest = min(resolution.x, resolution.y);
  let aspect = resolution / shortest;
  let p = (uv - 0.5) * aspect;
  let radius = length(p);
  let angle = atan2(p.y, p.x) / 6.28318 + 0.5;
  let ring = exp(-95.0 * pow(abs(radius - 0.31), 2.0));
  let halo = exp(-18.0 * pow(abs(radius - 0.31), 2.0));
  let bands = 0.82 + 0.18 * sin(angle * 25.13272 + radius * 42.0);
  let color = palette(angle + radius * 0.65);
  // The ring reaches about 2.2, so clamp like vgpu's framebuffer.
  return vec4f(clamp(color * (ring * bands * 2.0 + halo * 0.22), vec3f(0.0), vec3f(1.0)), 1.0);
}
</script>

<script type="module">

const MAX_SIDE = 512;
const COMPILE_FAILURES = ["syntax error", "unsupported WGSL", "type error", "unknown or duplicate name"];
const shaderSelect = document.getElementById("wgsl-shader");
const fileInput = document.getElementById("wgsl-file");
const cameraButton = document.getElementById("wgsl-camera");
const vectorizeInput = document.getElementById("wgsl-vectorize");
const uniformsBox = document.getElementById("wgsl-uniforms");
const sourceInput = document.getElementById("wgsl-source");
const summary = document.getElementById("wgsl-summary");
const inputCanvas = document.getElementById("wgsl-input");
const inputCaption = document.getElementById("wgsl-input-caption");
const gpuCanvas = document.getElementById("wgsl-gpu");
const gpuCaption = document.getElementById("wgsl-gpu-caption");
const wasmCanvas = document.getElementById("wgsl-wasm");
const wasmCaption = document.getElementById("wgsl-wasm-caption");
const diffCanvas = document.getElementById("wgsl-diff");
const diffCaption = document.getElementById("wgsl-diff-caption");
let comparisonOutputs = null;

const shaders = [...document.querySelectorAll('script[type="text/wgsl"]')];
for (const [index, script] of shaders.entries()) {
  if (script.dataset.generated === "atkinson") script.textContent = atkinsonShader();
  if (script.dataset.generated === "perlin") script.textContent = perlinNoiseShader();
  if (script.dataset.generated === "halftone") script.textContent = halftoneDotsShader();
  if (script.dataset.generated === "fluted-glass") script.textContent = flutedGlassShader();
  if (script.dataset.generated === "waves") script.textContent = wavesShader();
  if (script.dataset.generated === "spiral") script.textContent = spiralShader();
  if (script.dataset.generated === "swirl") script.textContent = swirlShader();
  if (script.dataset.generated === "mesh-gradient") script.textContent = meshGradientShader();
  if (script.dataset.generated === "neuro-noise") script.textContent = neuroNoiseShader();
  if (script.dataset.generated === "dot-grid") script.textContent = dotGridShader();
  if (script.dataset.generated === "voronoi") script.textContent = voronoiShader();
  if (script.dataset.generated === "image-dithering") script.textContent = imageDitheringShader();
  if (script.dataset.generated === "simplex-noise") script.textContent = simplexNoiseShader();
  if (script.dataset.generated === "static-mesh-gradient") script.textContent = staticMeshGradientShader();
  if (script.dataset.generated === "static-radial-gradient") script.textContent = staticRadialGradientShader();
  shaderSelect.add(new Option(script.dataset.name, String(index)));
}

// Each invocation owns one block. Keep all errors local, and unroll the
// raster scan because the WGSL-to-Wasm compiler does not accept shader loops.
function atkinsonShader() {
  const lines = [`// Atkinson dither: monochrome, independent 8x8 blocks.
// Errors stop at block edges. Each invocation writes a different block.
override width: u32 = 256;
override threshold: f32 = 0.5; // 0.1..0.9

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let height = arrayLength(&src) / width;
  let columns = (width + 7u) / 8u;
  if id.x >= columns * ((height + 7u) / 8u) { return; }
  let ox = (id.x % columns) * 8u;
  let oy = (id.x / columns) * 8u;
  let k = vec3f(0.2126, 0.7152, 0.0722);`];
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const i = y * 8 + x;
      // Incoming edges reverse Atkinson's outgoing diffusion stencil.
      const previous = [[x - 1, y], [x - 2, y], [x - 1, y - 1],
        [x, y - 1], [x + 1, y - 1], [x, y - 2]]
        .filter(([px, py]) => px >= 0 && px < 8 && py >= 0)
        .map(([px, py]) => "e" + (py * 8 + px));
      const incoming = previous.map((name) => " + " + name).join("");
      lines.push(`  var e${i} = 0.0;
  {
    let x = ox + ${x}u;
    let y = oy + ${y}u;
    if x < width && y < height {
      let c = src[y * width + x];
      let v = dot(c.rgb, k)${incoming};
      let q = select(0.0, 1.0, v >= threshold);
      e${i} = (v - q) * 0.125;
      dst[y * width + x] = vec4f(vec3f(q), c.a);
    }
  }`);
    }
  }
  lines.push("}");
  return lines.join("\n");
}

// Independent gradient-noise implementation: hash lattice corners, project
// their gradients, then interpolate with the quintic fade curve. Unroll the
// eight corners and eight octaves, as written before the compiler had loops.
function perlinNoiseShader() {
  const lines = [`// 3D Perlin gradient noise, with an integer lattice hash.
// Move time to explore a continuous third dimension. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override seed: u32 = 0; // 0..100
override time: f32 = 0.0; // 0..20
override octave_count: u32 = 1; // 1..8
override persistence: f32 = 0.5; // 0.3..1
override lacunarity: f32 = 1.5; // 1.5..4
override proportion: f32 = 0.35; // 0..1
override softness: f32 = 0.1; // 0..1
override back_r: f32 = 0.3882353;
override back_g: f32 = 0.1647059;
override back_b: f32 = 0.8352941;
override front_r: f32 = 0.9882353;
override front_g: f32 = 0.8117647;
override front_b: f32 = 0.9686275;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let height = arrayLength(&src) / width;
  let size = f32(max(min(width, height), 1u));
  let px = (f32(id.x % width) + 0.5 - f32(width) * 0.5) / size;
  let py = (f32(id.x / width) + 0.5 - f32(height) * 0.5) / size;
  var frequency = 5.0 / max(scale, 0.01);
  var amplitude = 1.0;
  var total = 0.0;
  var weight = 0.0;
  var hash: u32 = 0u;
  var gradient: u32 = 0u;
  var a = 0.0;
  var b = 0.0;`];
  for (let octave = 0; octave < 8; octave++) {
    lines.push(`  if octave_count > ${octave}u {
    let p = vec3f(px * frequency + 17.25, py * frequency + 43.5, time * 0.2 * frequency + 11.75);
    let cell = floor(p);
    let f = p - cell;
    let fade = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);`);
    for (let z = 0; z < 2; z++) {
      for (let y = 0; y < 2; y++) {
        for (let x = 0; x < 2; x++) {
          lines.push(`    hash = (u32(i32(cell.x) + ${x}) * 0x8da6b343u) ^ (u32(i32(cell.y) + ${y}) * 0xd8163841u) ^ (u32(i32(cell.z) + ${z}) * 0xcb1ab31fu) ^ seed ^ ${octave * 1013}u;
    hash = (hash ^ (hash >> 16u)) * 0x7feb352du;
    hash = (hash ^ (hash >> 15u)) * 0x846ca68bu;
    gradient = (hash ^ (hash >> 16u)) % 12u;
    a = f.x - ${x}.0;
    b = f.y - ${y}.0;
    if gradient >= 4u { b = f.z - ${z}.0; }
    if gradient >= 8u { a = f.y - ${y}.0; }
    let v${x}${y}${z} = select(a, -a, (gradient & 1u) != 0u) + select(b, -b, (gradient & 2u) != 0u);`);
        }
      }
    }
    lines.push(`    let row0 = mix(v000, v100, fade.x);
    let row1 = mix(v010, v110, fade.x);
    let row2 = mix(v001, v101, fade.x);
    let row3 = mix(v011, v111, fade.x);
    let noise = mix(mix(row0, row1, fade.y), mix(row2, row3, fade.y), fade.z);
    total += noise * amplitude;
    weight += amplitude;
    amplitude *= persistence;
    frequency *= lacunarity;
  }`);
  }
  lines.push(`  let value = clamp(total / max(weight, 0.0001) * 0.5 + proportion, 0.0, 1.0);
  // A minimum one-pixel transition replaces fragment-only fwidth.
  let half_width = max(softness * 0.5, 0.5 / size);
  let t = clamp((value - (0.5 - half_width)) / (2.0 * half_width), 0.0, 1.0);
  let blend = t * t * (3.0 - 2.0 * t);
  let back = vec3f(back_r, back_g, back_b);
  let front = vec3f(front_r, front_g, front_b);
  dst[id.x] = vec4f(mix(back, front, blend), 1.0);
  }`);
  return lines.join("\n");
}

// Port of Paper's classic halftone dots (Apache-2.0). Classic dots use a grid
// at half-cell steps, so each pixel sums the dots of four overlapping cells.
// Unroll those four samples to fit the compiler's loop-free subset.
function halftoneDotsShader() {
  const lines = [`// Classic halftone dots, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
override width: u32 = 256;
override spacing: f32 = 6.0; // 2..16
override radius: f32 = 1.25; // 0..2
override contrast: f32 = 0.4; // 0..1
override grid: u32 = 1; // 0..1
override inverted: u32 = 0; // 0..1
override back_r: f32 = 0.9490196;
override back_g: f32 = 0.9450980;
override back_b: f32 = 0.9098039;
override front_r: f32 = 0.1686275;
override front_g: f32 = 0.1686275;
override front_b: f32 = 0.1686275;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let w = f32(width);
  let h = f32(height);
  let cx = w * 0.5;
  let cy = h * 0.5;
  // Paper offsets a second grid by half a cell, so dots are half a cell apart.
  let cell = spacing * 2.0;
  let ux = (f32(id.x % width) + 0.5 - cx) / cell;
  let uy = (f32(id.x / width) + 0.5 - cy) / cell;
  // Paper maps contrast through pow(contrast, 1.5) into a logistic curve.
  let steepness = 15.0 * contrast * sqrt(contrast);
  // One pixel of antialiasing, in place of fwidth.
  let aa = 1.0 / cell;
  let margin = cell * 0.5;
  let k = vec3f(0.2126, 0.7152, 0.0722);
  var shape = 0.0;`];
  for (const oy of [-0.5, 0]) {
    for (const ox of [-0.5, 0]) {
      // On the hex grid, every second row of the half-step grid shifts right.
      const shift = oy === 0 ? " + 0.25 * f32(min(grid, 1u))" : "";
      lines.push(`  {
    let ox = ${ox.toFixed(1)}${shift};
    let oy = ${oy.toFixed(1)};
    let qx = ux + ox;
    let qy = uy + oy;
    let ix = floor(qx);
    let iy = floor(qy);
    let fx = qx - ix - 0.5;
    let fy = qy - iy - 0.5;
    // Sample the image at the dot's centre, nearest-neighbour.
    let sx = (ix + 0.5 - ox) * cell + cx;
    let sy = (iy + 0.5 - oy) * cell + cy;
    let inside = sx >= -margin && sx <= w + margin && sy >= -margin && sy <= h + margin;
    let c = src[u32(clamp(sy, 0.0, h - 1.0)) * width + u32(clamp(sx, 0.0, w - 1.0))];
    // An algebraic sigmoid with the logistic curve's slope at 0.5.
    let s = (c.rgb - vec3f(0.5)) * (steepness * 0.5);
    let toned = vec3f(0.5) + s * 0.5 / sqrt(vec3f(1.0) + s * s);
    let lum = mix(1.0, dot(toned, k), c.a);
    let r = 0.25 * radius * (1.0 - select(lum, 1.0 - lum, inverted != 0u));
    let t = clamp((sqrt(fx * fx + fy * fy) - r + aa) / (2.0 * aa), 0.0, 1.0);
    shape += select(0.0, 1.0 - t * t * (3.0 - 2.0 * t), inside);
  }`);
    }
  }
  lines.push(`  let back = vec3f(back_r, back_g, back_b);
  let front = vec3f(front_r, front_g, front_b);
  dst[id.x] = vec4f(mix(back, front, min(shape, 1.0)), 1.0);
}`);
  return lines.join("\n");
}

// The Paper ports below emulate fragment-only fwidth(f) as
// |f(x + 1, y) - f(x, y)| + |f(x, y + 1) - f(x, y)|, so their generators emit
// the code that computes f once per pixel offset, with these name suffixes.
// A function, because the shader list is generated before constants initialise.
function paperNeighbours() {
  return [["", 0, 0], ["_x", 1, 0], ["_y", 0, 1]];
}

// Paper's 2D simplex noise (Ashima Arts) as statements that assign `out`.
// GLSL's mod(x, 289.0) floors, unlike WGSL's %, so it is written out.
function simplexNoiseWgsl(out, v, prefix) {
  return `    let ${prefix}v = ${v};
    let ${prefix}k = vec4f(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    let ${prefix}i0 = floor(${prefix}v + dot(${prefix}v, ${prefix}k.yy));
    let ${prefix}x0 = ${prefix}v - ${prefix}i0 + dot(${prefix}i0, ${prefix}k.xx);
    let ${prefix}i1 = select(vec2f(0.0, 1.0), vec2f(1.0, 0.0), ${prefix}x0.x > ${prefix}x0.y);
    let ${prefix}x12 = ${prefix}x0.xyxy + ${prefix}k.xxzz - vec4f(${prefix}i1, 0.0, 0.0);
    let ${prefix}i = ${prefix}i0 - 289.0 * floor(${prefix}i0 / 289.0);
    let ${prefix}a = ${prefix}i.y + vec3f(0.0, ${prefix}i1.y, 1.0);
    let ${prefix}b = (${prefix}a * 34.0 + 1.0) * ${prefix}a;
    let ${prefix}c = ${prefix}b - 289.0 * floor(${prefix}b / 289.0) + ${prefix}i.x + vec3f(0.0, ${prefix}i1.x, 1.0);
    let ${prefix}d = (${prefix}c * 34.0 + 1.0) * ${prefix}c;
    let ${prefix}p = ${prefix}d - 289.0 * floor(${prefix}d / 289.0);
    var ${prefix}m = max(vec3f(0.5) - vec3f(dot(${prefix}x0, ${prefix}x0), dot(${prefix}x12.xy, ${prefix}x12.xy), dot(${prefix}x12.zw, ${prefix}x12.zw)), vec3f(0.0));
    ${prefix}m = ${prefix}m * ${prefix}m;
    ${prefix}m = ${prefix}m * ${prefix}m;
    let ${prefix}x = 2.0 * fract(${prefix}p * ${prefix}k.www) - 1.0;
    let ${prefix}h = abs(${prefix}x) - 0.5;
    let ${prefix}a0 = ${prefix}x - floor(${prefix}x + 0.5);
    ${prefix}m = ${prefix}m * (1.79284291400159 - 0.85373472095314 * (${prefix}a0 * ${prefix}a0 + ${prefix}h * ${prefix}h));
    ${out} = 130.0 * dot(${prefix}m, vec3f(${prefix}a0.x * ${prefix}x0.x + ${prefix}h.x * ${prefix}x0.y,
      ${prefix}a0.y * ${prefix}x12.x + ${prefix}h.y * ${prefix}x12.y, ${prefix}a0.z * ${prefix}x12.z + ${prefix}h.z * ${prefix}x12.w));`;
}

// Port of Paper's fluted glass (Apache-2.0) without margins, blur or grain.
// The pattern is computed at the right and lower neighbours for fwidth.
function flutedGlassShader() {
  const lines = [`// Fluted glass, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// shape: 1 lines, 2 irregular lines, 3 wave, 4 zigzag, 5 pattern.
// distortion_shape: 1 prism, 2 lens, 3 contour, 4 cascade, 5 flat.
override width: u32 = 256;
override size: f32 = 0.77; // 0..1
override angle: f32 = 0.0; // 0..180
override shape: u32 = 1; // 1..5
override distortion_shape: u32 = 1; // 1..5
override distortion: f32 = 0.5; // 0..1
override shift: f32 = 0.0; // -1..1
override highlights: f32 = 0.1; // 0..1
override shadows: f32 = 0.25; // 0..1
override edges: f32 = 0.25; // 0..1
override stretch: f32 = 0.0; // 0..1
override shadow_r: f32 = 0.0;
override shadow_g: f32 = 0.0;
override shadow_b: f32 = 0.0;
override highlight_r: f32 = 1.0;
override highlight_g: f32 = 1.0;
override highlight_b: f32 = 1.0;

const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let w = f32(width);
  let h = f32(height);
  let aspect = w / h;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  let rot = -angle * PI / 180.0;
  let rc = cos(rot);
  let rs = sin(rot);
  let pattern_size = mix(200.0, 5.0, size);`];
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  // Flute coordinates${s ? ` one pixel ${s === "_x" ? "right" : "down"}, for fwidth` : ""}.
  let ax${s} = ((x + ${dx}.0) / w - 0.5) * pattern_size * aspect;
  let ay${s} = ((y + ${dy}.0) / h - 0.5) * pattern_size;
  let ux${s} = (rc * ax${s} - rs * ay${s}) / aspect;
  let uy${s} = rs * ax${s} + rc * ay${s};
  let py${s} = uy${s} / aspect;
  var curve${s} = 0.0;
  if shape == 5u {
    curve${s} = 0.5 + 0.5 * sin(0.5 * PI * ux${s}) * cos(0.5 * PI * py${s});
  } else if shape == 4u {
    curve${s} = 10.0 * abs(fract(0.1 * py${s}) - 0.5);
  } else if shape == 3u {
    curve${s} = 4.0 * sin(0.23 * py${s});
  } else if shape == 2u {
    curve${s} = 0.5 + 0.5 * sin(0.5 * ux${s}) * sin(1.7 * ux${s});
  }
  let tf${s} = ux${s} + curve${s};
  let fr${s} = fract(tf${s});`);
  }
  lines.push(`  let fw = abs(tf_x - tf) + abs(tf_y - tf);
  // Paper's smoothFract: fold the sawtooth back over the last pixel.
  let fold = max(fw, 0.000001);
  var xs = mix(fr, 1.0 - fr, smoothstep(-fold, fold, abs(fr - 0.5) - 0.5));
  let xn = fr + 0.0001;
  let hw = 2.0 * max(0.001, fw);
  let hl = clamp((1.0 - smoothstep(0.0, hw, xn) * smoothstep(1.0, 1.0 - hw, xn)) * highlights, 0.0, 1.0);
  var shade = pow(xs, 1.3);
  var bend = 0.0;
  var fade_x = 1.0;
  var frame_fade = 0.0;
  var aa = max(max(abs(fr_x - fr) + abs(fr_y - fr), abs(ux_x - ux) + abs(ux_y - ux)), max(fw, 0.0001));
  if distortion_shape == 1u {
    bend = 0.5 - shift - pow(1.5 * xs, 3.0);
    frame_fade = pow(1.5 * xs, 3.0);
    aa = max(0.2, aa) + mix(0.2, 0.0, size);
    fade_x = smoothstep(0.0, aa, xn) * smoothstep(1.0, 1.0 - aa, xn);
    bend = mix(0.5, bend, fade_x);
  } else if distortion_shape == 2u {
    bend = 2.0 * pow(xs, 2.0) - (0.5 + shift);
    frame_fade = pow(abs(xs - 0.5), 4.0);
    aa = max(0.2, aa) + mix(0.2, 0.0, size);
    fade_x = smoothstep(0.0, aa, xn) * smoothstep(1.0, 1.0 - aa, xn);
    bend = mix(0.5, bend, fade_x);
    frame_fade = mix(1.0, frame_fade, 0.5 * fade_x);
  } else if distortion_shape == 3u {
    // Paper raises a negative base to the 6th power; abs keeps pow defined.
    bend = pow(abs(2.0 * (xn - 0.5)), 6.0) - 0.25 - shift;
    frame_fade = 1.0 - 2.0 * pow(abs(xs - 0.4), 2.0);
    aa = 0.15 + mix(0.1, 0.0, size);
    fade_x = smoothstep(0.0, aa, xn) * smoothstep(1.0, 1.0 - aa, xn);
    frame_fade = mix(1.0, frame_fade, fade_x);
  } else if distortion_shape == 4u {
    xs = xn;
    bend = sin((xs + 0.25) * TWO_PI);
    shade = 0.5 + 0.5 * asin(clamp(bend, -1.0, 1.0)) / (0.5 * PI);
    bend = 0.5 * bend - shift;
    frame_fade = 0.5 + 0.5 * sin(xs * TWO_PI);
  } else if distortion_shape == 5u {
    bend = (0.33 - pow(xs, 0.2) * xs - 3.0 * shift) * 0.33;
    frame_fade = 0.3 * smoothstep(0.0, 1.0, xs);
    shade = pow(xs, 2.5);
    aa = max(0.1, aa) + mix(0.1, 0.0, size);
    fade_x = smoothstep(0.0, aa, xn) * smoothstep(1.0, 1.0 - aa, xn);
    bend *= fade_x;
  }
  shade = clamp(min(shade, 1.0) * shadows * shadows, 0.0, 1.0);
  bend *= 3.0 * distortion;
  frame_fade *= distortion;
  // Shift within each flute, then rotate back into image coordinates.
  let gx = (floor(ux) + fract(ux) + bend) * aspect;
  let gy = floor(uy) + fract(uy);
  let u = (rc * gx + rs * gy) / aspect / pattern_size + 0.5;
  var v = (rc * gy - rs * gx) / pattern_size + 0.5;
  // Paper's getUvFrame, with the undistorted pixel size in place of fwidth.
  let aax = 2.0 / w;
  let aay = 2.0 / h;
  let soft = mix(0.0, 0.04, edges) + 0.06 * frame_fade * edges;
  let frame = smoothstep(0.0, aax + soft, u) * (1.0 - smoothstep(1.0 - soft - aax, 1.0, u)) *
    smoothstep(0.0, aay + soft, v) * (1.0 - smoothstep(1.0 - soft - aay, 1.0, v));
  let soft2 = 0.1 + 0.05 * frame_fade;
  let frame2 = smoothstep(0.0, aax + soft2, u) * (1.0 - smoothstep(1.0 - soft2 - aax, 1.0, u)) *
    smoothstep(0.0, aay + soft2, v) * (1.0 - smoothstep(1.0 - soft2 - aay, 1.0, v));
  let pull = 1.0 - smoothstep(0.0, 0.5, xn) * smoothstep(1.0, 0.5, xn);
  v = mix(v, 0.5, stretch * pull * pull * frame2);
  // Bilinear sample, clamped to the edge like Paper's texture.
  let tx = u * w - 0.5;
  let ty = v * h - 0.5;
  let x0 = floor(tx);
  let y0 = floor(ty);
  let i0 = u32(clamp(x0, 0.0, w - 1.0));
  let i1 = u32(clamp(x0 + 1.0, 0.0, w - 1.0));
  let j0 = u32(clamp(y0, 0.0, h - 1.0)) * width;
  let j1 = u32(clamp(y0 + 1.0, 0.0, h - 1.0)) * width;
  let c = mix(mix(src[j0 + i0], src[j0 + i1], tx - x0), mix(src[j1 + i0], src[j1 + i1], tx - x0), ty - y0);
  let shadow = vec3f(shadow_r, shadow_g, shadow_b);
  let highlight = vec3f(highlight_r, highlight_g, highlight_b);
  let sh = mix(shade, 0.0, hl);
  var color = clamp(mix(highlight * hl, shadow, 0.5 * sh) + 0.5 * sqrt(sh) * shadow, vec3f(0.0), vec3f(1.0));
  var opacity = clamp(hl + sh, 0.0, 1.0);
  color += c.rgb * c.a * ((1.0 - opacity) * frame);
  opacity = clamp(opacity + c.a * (1.0 - opacity) * frame, 0.0, 1.0);
  // The background is transparent. Un-premultiply for the page's canvases.
  dst[id.x] = vec4f(select(color / opacity, vec3f(0.0), opacity <= 0.0), opacity);
}`);
  return lines.join("\n");
}

// Port of Paper's waves (Apache-2.0).
function wavesShader() {
  const lines = [`// Waves, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// shape: 0 zigzag, 1 sine, 2 and 3 irregular; fractions morph between them.
// Input colors are unused.
override width: u32 = 256;
override scale: f32 = 0.6; // 0.1..4
override rotation: f32 = 0.0; // 0..360
override shape: f32 = 0.0; // 0..3
override frequency: f32 = 0.5; // 0..2
override amplitude: f32 = 0.5; // 0..1
override spacing: f32 = 1.2; // 0..2
override proportion: f32 = 0.1; // 0..1
override softness: f32 = 0.0; // 0..1
override back_r: f32 = 0.0;
override back_g: f32 = 0.0;
override back_b: f32 = 0.0;
override front_r: f32 = 1.0;
override front_g: f32 = 0.7333333;
override front_b: f32 = 0.0;

const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  let r = rotation * PI / 180.0;
  let rc = cos(r);
  let rs = sin(r);
  // Paper's pattern units are 100 pixels, and waves scale them by 4.
  let k = 0.04 / scale;`];
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  let px${s} = x + ${dx}.0 - cx;
  let py${s} = cy - (y + ${dy}.0);
  let ux${s} = (rc * px${s} - rs * py${s}) * k;
  let uy${s} = (rs * px${s} + rc * py${s}) * k;
  let fx${s} = ux${s} * frequency;
  var offset${s} = mix(2.0 * abs(fract(fx${s}) - 0.5), 0.5 * cos(fx${s} * TWO_PI), smoothstep(0.0, 1.0, shape));
  offset${s} = mix(offset${s}, sin(fx${s} * 0.25 * TWO_PI) * cos(fx${s} * TWO_PI), smoothstep(1.0, 2.0, shape));
  offset${s} = mix(offset${s}, 0.75 * (sin(fx${s} * TWO_PI) + 0.5 * cos(fx${s} * 0.5 * TWO_PI)), smoothstep(2.0, 3.0, shape));
  let line${s} = 0.5 + 0.5 * sin((uy${s} + offset${s} * (2.0 * amplitude)) * PI / (0.001 + spacing));`);
  }
  lines.push(`  let aa = 0.0001 + abs(line_x - line) + abs(line_y - line);
  let dc = 1.0 - clamp(proportion, 0.0, 1.0);
  let e0 = dc - softness - aa;
  let e1 = dc + softness + aa;
  let res = smoothstep(min(e0, e1), max(e0, e1), line);
  let back = vec3f(back_r, back_g, back_b);
  let front = vec3f(front_r, front_g, front_b);
  dst[id.x] = vec4f(mix(back, front, res), 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's spiral (Apache-2.0), with simplex noise inlined.
function spiralShader() {
  const lines = [`// Spiral, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move time to turn the spiral. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override time: f32 = 0.0; // 0..20
override density: f32 = 1.0; // 0..1
override distortion: f32 = 0.0; // 0..1
override stroke_width: f32 = 0.5; // 0..1
override stroke_taper: f32 = 0.0; // 0..1
override stroke_cap: f32 = 0.0; // 0..1
override noise: f32 = 0.0; // 0..1
override noise_frequency: f32 = 0.0; // 0..1
override softness: f32 = 0.0; // 0..1
override back_r: f32 = 0.0;
override back_g: f32 = 0.0784314;
override back_b: f32 = 0.1607843;
override front_r: f32 = 0.4745098;
override front_g: f32 = 0.8196078;
override front_b: f32 = 1.0;

const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's pattern units are 100 pixels, and the spiral doubles them.
  let k = 0.02 / scale;`];
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  let ux${s} = (x + ${dx}.0 - cx) * k;
  let uy${s} = (cy - (y + ${dy}.0)) * k;
  let l${s} = pow(max(length(vec2f(ux${s}, uy${s})), 0.000001), clamp(density, 0.0, 1.0));
  var turn${s} = (atan2(uy${s}, ux${s}) - time) / TWO_PI;
  if noise > 0.0 {
    var nz${s} = 0.0;
${simplexNoiseWgsl(`nz${s}`, `vec2f(ux${s}, uy${s}) * (16.0 * pow(noise_frequency, 3.0))`, `sn${s}_`)}
    turn${s} += 0.125 * noise * nz${s};
  }
  let offset${s} = l${s} + turn${s} - distortion * (sin(4.0 * l${s} - 0.5 * time) * cos(PI + l${s} + 0.5 * time));
  let stripe${s} = fract(offset${s});
  let band${s} = 2.0 * abs(stripe${s} - 0.5);`);
  }
  lines.push(`  var w = 1.0 - clamp(stroke_width, 0.005 * stroke_taper, 1.0);
  let cap = mix(w, (1.0 - stripe) * (1.0 - step(0.5, stripe)), 1.0 - clamp(l, 0.0, 1.0));
  w = mix(w, cap, stroke_cap) * (1.0 - clamp(stroke_taper, 0.0, 1.0) * l);
  let fw = abs(offset_x - offset) + abs(offset_y - offset);
  let fw_mult = 4.0 - 3.0 * (smoothstep(0.05, 0.4, 2.0 * stroke_width) * smoothstep(0.05, 0.4, 2.0 * (1.0 - stroke_width)));
  var pixel = mix(fw_mult * fw, abs(band_x - band) + abs(band_y - band), clamp(fw, 0.0, 1.0));
  pixel = mix(pixel, 0.002, stroke_cap * (1.0 - clamp(l, 0.0, 1.0)));
  let res = smoothstep(w - pixel - softness, w + pixel + softness, band);
  let back = vec3f(back_r, back_g, back_b);
  let front = vec3f(front_r, front_g, front_b);
  dst[id.x] = vec4f(mix(back, front, res), 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's swirl (Apache-2.0) with three band colors, unrolled.
function swirlShader() {
  const lines = [`// Swirl, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move time to turn the swirl. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override time: f32 = 0.0; // 0..20
override band_count: u32 = 4; // 0..15
override twist: f32 = 0.1; // 0..1
override center: f32 = 0.2; // 0..1
override proportion: f32 = 0.5; // 0..1
override softness: f32 = 0.0; // 0..1
override noise: f32 = 0.2; // 0..1
override noise_frequency: f32 = 0.4; // 0..1
override back_r: f32 = 0.2;
override back_g: f32 = 0.0;
override back_b: f32 = 0.0;
override band1_r: f32 = 1.0;
override band1_g: f32 = 0.8196078;
override band1_b: f32 = 0.8196078;
override band2_r: f32 = 1.0;
override band2_g: f32 = 0.5411765;
override band2_b: f32 = 0.5411765;
override band3_r: f32 = 0.4;
override band3_g: f32 = 0.0;
override band3_b: f32 = 0.0;

const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's object units span the shorter side.
  let k = 1.0 / (f32(max(min(width, height), 1u)) * scale);
  let tw = 3.0 * clamp(twist, 0.0, 1.0);
  let p = clamp(proportion, 0.0, 1.0);
  let exponent = mix(mix(0.25, 1.0, p * 2.0), 10.0, max(0.0, p * 2.0 - 1.0));
  // WebGPU rejects equal smoothstep edges made from overrides.
  let mid_edge = 0.2 + max(0.8 * center, 0.000001);`];
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  let ux${s} = (x + ${dx}.0 - cx) * k;
  let uy${s} = (cy - (y + ${dy}.0)) * k;
  let l${s} = max(0.0001, length(vec2f(ux${s}, uy${s})));
  let inner${s} = pow(l${s}, -tw);
  var shape${s} = fract(inner${s} + (f32(band_count) * atan2(uy${s}, ux${s}) + time) / TWO_PI);
  shape${s} = 1.0 - abs(2.0 * shape${s} - 1.0);
  if noise > 0.0 {
    var nz${s} = 0.0;
${simplexNoiseWgsl(`nz${s}`, `vec2f(ux${s}, uy${s}) * (15.0 * pow(noise_frequency, 2.0))`, `sn${s}_`)}
    shape${s} += noise * nz${s};
  }
  shape${s} = mix(0.0, shape${s}, smoothstep(0.2, mid_edge, pow(l${s}, tw)));
  // Noise can push the shape below 0, where Paper's pow is undefined.
  let mixer${s} = pow(max(shape${s}, 0.0), exponent) * 3.0;
  let m1${s} = clamp(mixer${s}, 0.0, 1.0);
  let m2${s} = clamp(mixer${s} - 1.0, 0.0, 1.0);
  let m3${s} = clamp(mixer${s} - 2.0, 0.0, 1.0);`);
  }
  lines.push(`  let lo = 0.5 - 0.5 * softness;
  let hi = 0.5 + 0.5 * softness;
  let aa1 = max(abs(m1_x - m1) + abs(m1_y - m1), 0.000001);
  let aa2 = max(abs(m2_x - m2) + abs(m2_y - m2), 0.000001);
  let aa3 = max(abs(m3_x - m3) + abs(m3_y - m3), 0.000001);
  let b1 = smoothstep(lo - aa1, hi + aa1, m1);
  let band1 = vec3f(band1_r, band1_g, band1_b);
  let band2 = vec3f(band2_r, band2_g, band2_b);
  let band3 = vec3f(band3_r, band3_g, band3_b);
  let gradient = mix(mix(band1, band2, smoothstep(lo - aa2, hi + aa2, m2)), band3, smoothstep(lo - aa3, hi + aa3, m3));
  let mid_aa = max(0.1 * (abs(inner_x - inner) + abs(inner_y - inner)), 0.000001);
  let outer = mix(0.0, b1, smoothstep(0.2, 0.2 + mid_aa, pow(l, tw)));
  let back = vec3f(back_r, back_g, back_b);
  dst[id.x] = vec4f(mix(back, gradient, outer), 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's mesh gradient (Apache-2.0) with four color spots.
function meshGradientShader() {
  const lines = [`// Mesh gradient, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move time to move the color spots. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override time: f32 = 0.0; // 0..20
override color_count: u32 = 4; // 1..4
override distortion: f32 = 0.8; // 0..1
override swirl: f32 = 0.1; // 0..1
override color1_r: f32 = 0.8784314;
override color1_g: f32 = 0.9176471;
override color1_b: f32 = 1.0;
override color2_r: f32 = 0.1411765;
override color2_g: f32 = 0.1137255;
override color2_b: f32 = 0.6039216;
override color3_r: f32 = 0.9686275;
override color3_g: f32 = 0.3137255;
override color3_b: f32 = 0.5725490;
override color4_r: f32 = 0.6235294;
override color4_g: f32 = 0.3137255;
override color4_b: f32 = 0.8274510;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's object units span the shorter side.
  let k = 1.0 / (f32(max(min(width, height), 1u)) * scale);
  var ux = (x - cx) * k + 0.5;
  var uy = (cy - y) * k + 0.5;
  // Paper starts its first frame at time 41.5.
  let t = 0.5 * (time + 41.5);
  let radius = smoothstep(0.0, 1.0, length(vec2f(ux - 0.5, uy - 0.5)));
  let center = 1.0 - radius;
  for (var i = 1; i <= 2; i++) {
    let f = f32(i);
    ux += distortion * center / f * sin(t + f * 0.4 * smoothstep(0.0, 1.0, uy)) * cos(0.2 * t + f * 2.4 * smoothstep(0.0, 1.0, uy));
    uy += distortion * center / f * cos(t + f * 2.0 * smoothstep(0.0, 1.0, ux));
  }
  let angle = -3.0 * swirl * radius;
  let ra = cos(angle);
  let rb = sin(angle);
  let rx = ra * (ux - 0.5) - rb * (uy - 0.5) + 0.5;
  let ry = rb * (ux - 0.5) + ra * (uy - 0.5) + 0.5;
  var color = vec3f(0.0);
  var total = 0.0;`];
  for (let i = 0; i < 4; i++) {
    lines.push(`  if color_count > ${i}u {
    let px = 0.5 + 0.5 * sin(t * (0.6 + fract(${i}.0 / 3.0) * 0.9) + ${i}.0 * 0.37);
    let py = 0.5 + 0.5 * cos(t * (0.8 + fract(${i + 1}.0 / 4.0)) + ${i}.0 * 0.37 * 1.5);
    // Paper raises a distance that can be 0; the floor keeps pow defined.
    let d = pow(max(length(vec2f(rx - px, ry - py)), 0.000001), 3.5);
    let weight = 1.0 / (d + 0.001);
    color += vec3f(color${i + 1}_r, color${i + 1}_g, color${i + 1}_b) * weight;
    total += weight;
  }`);
  }
  lines.push(`  dst[id.x] = vec4f(color / max(0.0001, total), 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's neuro noise (Apache-2.0) with its 15 layers unrolled.
function neuroNoiseShader() {
  const lines = [`// Neuro noise, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move time to animate the web. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override time: f32 = 0.0; // 0..20
override brightness: f32 = 0.05; // 0..1
override contrast: f32 = 0.3; // 0..1
override front_r: f32 = 1.0;
override front_g: f32 = 1.0;
override front_b: f32 = 1.0;
override mid_r: f32 = 0.2784314;
override mid_g: f32 = 0.6509804;
override mid_b: f32 = 1.0;
override back_r: f32 = 0.0;
override back_g: f32 = 0.0;
override back_b: f32 = 0.0;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's pattern units are 100 pixels, and neuro noise scales them by 0.13.
  let k = 0.0013 / scale;
  var ux = (x - cx) * k;
  var uy = (cy - y) * k;
  let t = 0.5 * time;
  let rc = cos(1.0);
  let rs = sin(1.0);
  var ax = 0.0;
  var ay = 0.0;
  var tmp = 0.0;
  var res = vec2f(0.0);
  var layer_scale = 8.0;`];
  for (let j = 0; j < 15; j++) {
    lines.push(`  // Layer ${j}: rotate the position and the sine accumulator by 1 radian.
  tmp = rc * ux - rs * uy;
  uy = rs * ux + rc * uy;
  ux = tmp;
  tmp = rc * ax - rs * ay;
  ay = rs * ax + rc * ay;
  ax = tmp;
  {
    let layer = vec2f(ux, uy) * layer_scale + ${j}.0 + vec2f(ax, ay) - t;
    let sl = sin(layer);
    ax += sl.x;
    ay += sl.y;
    res += (0.5 + 0.5 * cos(layer)) / layer_scale;
    layer_scale *= 1.2;
  }`);
  }
  lines.push(`  var noise = res.x + res.y;
  noise = (1.0 + brightness) * noise * noise;
  noise = min(1.4, pow(max(noise, 0.000001), 0.7 + 6.0 * contrast));
  let blend = smoothstep(0.7, 1.4, noise);
  let front = vec3f(front_r, front_g, front_b);
  let mid = vec3f(mid_r, mid_g, mid_b);
  let back = vec3f(back_r, back_g, back_b);
  let opacity = clamp(noise, 0.0, 1.0);
  // Noise reaches 1.4, so clamp like Paper's framebuffer.
  let color = mix(mid, front, blend) * noise + back * (1.0 - opacity);
  dst[id.x] = vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0);
}`);
  return lines.join("\n");
}

// Paper's polygon distance as a statement that assigns `out`.
function polygonWgsl(out, px, py, sides, rotation) {
  return `{
      let pa = atan2(${px}, ${py}) + ${rotation};
      let pr = TWO_PI / ${sides};
      ${out} = cos(floor(0.5 + pa / pr) * pr - pa) * length(vec2f(${px}, ${py}));
    }`;
}

// Port of Paper's dot grid (Apache-2.0). fwidth comes from the right and lower
// neighbours, measured within this pixel's cell so cell seams stay smooth.
function dotGridShader() {
  const lines = [`// Dot grid, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// shape: 0 circle, 1 diamond, 2 square, 3 triangle. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override shape: u32 = 0; // 0..3
override size: f32 = 2.0; // 1..30
override gap_x: f32 = 32.0; // 2..100
override gap_y: f32 = 32.0; // 2..100
override stroke_width: f32 = 0.0; // 0..20
override size_range: f32 = 0.0; // 0..1
override opacity_range: f32 = 0.0; // 0..1
override back_r: f32 = 0.0;
override back_g: f32 = 0.0;
override back_b: f32 = 0.0;
override fill_r: f32 = 1.0;
override fill_g: f32 = 1.0;
override fill_b: f32 = 1.0;
override stroke_r: f32 = 1.0;
override stroke_g: f32 = 0.6666667;
override stroke_b: f32 = 0.0;

const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Pixels from the centre, with y up.
  let su = vec2f(x - f32(width) * 0.5, f32(height) * 0.5 - y) / scale;
  let gap = max(abs(vec2f(gap_x, gap_y)), vec2f(0.000001));
  let cell = floor(su / gap);
  var size_noise = 0.0;
  var opacity_noise = 0.0;
  if size_range > 0.0 {
${simplexNoiseWgsl("size_noise", "2.0 * vec2f(cell.x * 100.0, cell.y)", "sz_")}
  }
  if opacity_range > 0.0 {
${simplexNoiseWgsl("opacity_noise", "2.0 * vec2f(cell.y, cell.x)", "op_")}
  }
  let size_rand = 0.5 + 0.8 * size_noise;
  let opacity_rand = 0.5 + 0.7 * opacity_noise;
  let base = size * (1.0 - size_rand * size_range);
  let sw = stroke_width * (1.0 - size_rand * size_range) * select(1.0, 1.5, shape == 1u || shape >= 3u);
  let p = (fract(su / gap) + 0.0001 - vec2f(0.499)) * vec2f(gap_x, gap_y);`];
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  var px${s} = p.x + ${dx}.0 / scale;
  var py${s} = p.y - ${dy}.0 / scale;
  var dist${s} = 0.0;
  if shape == 0u {
    dist${s} = length(vec2f(px${s}, py${s}));
  } else if shape == 1u {
    ${polygonWgsl(`dist${s}`, `1.5 * px${s}`, `1.5 * py${s}`, "4.0", "0.25 * PI")}
  } else if shape == 2u {
    ${polygonWgsl(`dist${s}`, `1.03 * px${s}`, `1.03 * py${s}`, "4.0", "0.001")}
  } else {
    px${s} = (px${s} * 2.0 - 1.0) * 0.9;
    py${s} = 1.0 - (py${s} * 2.0 - 1.0) * 0.9 - 0.75 * base;
    ${polygonWgsl(`dist${s}`, `px${s}`, `py${s}`, "3.0", "0.001")}
  }`);
  }
  lines.push(`  // A floor keeps the smoothstep edges apart where the distance is flat.
  let edge = max(abs(dist_x - dist) + abs(dist_y - dist), 0.000001);
  let dot_opacity = max(0.0, 1.0 - opacity_rand * opacity_range);
  let outer = 1.0 - smoothstep(base - edge, base + edge, dist - sw);
  let inner = (1.0 - smoothstep(base - edge, base + edge, dist)) * dot_opacity;
  let stroke = outer * dot_opacity - inner;
  let color = stroke * vec3f(stroke_r, stroke_g, stroke_b) + inner * vec3f(fill_r, fill_g, fill_b) +
    (1.0 - inner - stroke) * vec3f(back_r, back_g, back_b);
  // The opacity randomizer can exceed 1, so clamp like Paper's framebuffer.
  dst[id.x] = vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's Voronoi (Apache-2.0). Both cell searches are unrolled, and
// Paper's hash22 replaces its noise texture.
function voronoiShader() {
  const hash = (cell) => `let q = fract((${cell}) * vec2f(0.3183099, 0.3678794)) + 0.1;
    let q2 = q + dot(q, q.yx + 19.19);
    let o0 = fract(vec2f(q2.x * q2.y, q2.x + q2.y));
    let r = g + 0.5 + distortion * sin(t + TWO_PI * o0) - fp;`;
  const lines = [`// Voronoi, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move time to move the cells. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 0.5; // 0.1..4
override time: f32 = 0.0; // 0..20
override color_count: u32 = 2; // 1..3
override steps_per_color: f32 = 3.0; // 1..3
override distortion: f32 = 0.4; // 0..0.5
override gap: f32 = 0.04; // 0..0.1
override glow: f32 = 0.0; // 0..1
override color1_r: f32 = 1.0;
override color1_g: f32 = 0.5098039;
override color1_b: f32 = 0.2784314;
override color2_r: f32 = 1.0;
override color2_g: f32 = 0.8980392;
override color2_b: f32 = 0.2392157;
override color3_r: f32 = 0.6;
override color3_g: f32 = 0.1;
override color3_b: f32 = 0.2;
override glow_r: f32 = 1.0;
override glow_g: f32 = 1.0;
override glow_b: f32 = 1.0;
override gap_r: f32 = 0.1803922;
override gap_g: f32 = 0.0;
override gap_b: f32 = 0.0;

const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  let sc = max(scale, 0.01);
  // Paper's pattern units are 100 pixels, and Voronoi scales them by 1.25.
  let uv = vec2f(x - f32(width) * 0.5, f32(height) * 0.5 - y) * (0.0125 / sc);
  let t = time;
  let ip = floor(uv);
  let fp = fract(uv);
  // Find the nearest cell centre.
  var md = 8.0;
  var mr = vec2f(0.0);
  var mg = vec2f(0.0);
  var rand = 0.0;`];
  for (let j = -1; j <= 1; j++) {
    for (let i = -1; i <= 1; i++) {
      lines.push(`  {
    let g = vec2f(${i}.0, ${j}.0);
    ${hash("ip + g")}
    let d = dot(r, r);
    if d < md {
      md = d;
      mr = r;
      mg = g;
      rand = o0.x;
    }
  }`);
    }
  }
  lines.push(`  // Then the distance to the nearest edge, around that cell.
  md = 8.0;`);
  for (let j = -2; j <= 2; j++) {
    for (let i = -2; i <= 2; i++) {
      lines.push(`  {
    let g = mg + vec2f(${i}.0, ${j}.0);
    ${hash("ip + g")}
    if dot(mr - r, mr - r) > 0.00001 {
      md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
    }
  }`);
    }
  }
  lines.push(`  let count = clamp(color_count, 1u, 3u);
  let cn = f32(count);
  let mixer = (clamp(rand, 0.0, 1.0) - 0.5 / cn) * cn;
  let steps = max(1.0, steps_per_color);
  let c1 = vec3f(color1_r, color1_g, color1_b);
  let c2 = vec3f(color2_r, color2_g, color2_b);
  let c3 = vec3f(color3_r, color3_g, color3_b);
  var cell_color = c1;
  if count > 1u { cell_color = mix(cell_color, c2, round(clamp(mixer, 0.0, 1.0) * steps) / steps); }
  if count > 2u { cell_color = mix(cell_color, c3, round(clamp(mixer - 1.0, 0.0, 1.0) * steps) / steps); }
  // Wrap the ends of the gradient from the last color back to the first.
  if mixer < 0.0 || mixer > cn - 1.0 {
    var wrap = mixer + 1.0;
    if mixer > cn - 1.0 { wrap = mixer - (cn - 1.0); }
    let last = select(select(c1, c2, count == 2u), c3, count == 3u);
    cell_color = mix(last, c1, round(wrap * steps) / steps);
  }
  // Paper's pow(glows, 1.5), written so it stays defined at 0.
  let gl = length(mr * glow);
  let glows = gl * sqrt(gl);
  let color = mix(cell_color, vec3f(glow_r, glow_g, glow_b), glows);
  let se = 0.02 / (2.0 * sc) * (1.0 + 0.5 * gap);
  let edge = smoothstep(gap - se, gap + se, md);
  // Glow can push past 1, so clamp like Paper's framebuffer.
  let shaded = mix(vec3f(gap_r, gap_g, gap_b), clamp(color, vec3f(0.0), vec3f(1.0)), edge);
  dst[id.x] = vec4f(shaded, 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's image dithering (Apache-2.0). The Bayer tables are built
// from interleaved bits of x ^ y and y, in place of constant arrays.
function imageDitheringShader() {
  return `// Image dithering, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// dither_type: 1 random, 2 2x2 Bayer, 3 4x4 Bayer, 4 8x8 Bayer.
override width: u32 = 256;
override dither_type: u32 = 4; // 1..4
override size: f32 = 2.0; // 0.5..20
override color_steps: u32 = 2; // 1..7
override original_colors: u32 = 0; // 0..1
override inverted: u32 = 0; // 0..1
override back_r: f32 = 0.0;
override back_g: f32 = 0.0470588;
override back_b: f32 = 0.2196078;
override front_r: f32 = 0.5803922;
override front_g: f32 = 1.0;
override front_b: f32 = 0.6862745;
override highlight_r: f32 = 0.9176471;
override highlight_g: f32 = 1.0;
override highlight_b: f32 = 0.5803922;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let w = f32(width);
  let h = f32(height);
  let px_size = max(size, 0.5);
  // Dithering cells from the centre, with y up like gl_FragCoord.
  let pxuv = vec2f(f32(id.x % width) + 0.5 - w * 0.5, h * 0.5 - (f32(id.x / width) + 0.5)) / px_size;
  let cell = floor(pxuv);
  let pixelized = (cell + 0.5) * px_size;
  // Sample the image at the cell's centre, nearest-neighbour.
  let sx = clamp(pixelized.x + w * 0.5, 0.0, w - 1.0);
  let sy = clamp(h * 0.5 - pixelized.y, 0.0, h - 1.0);
  let image = src[u32(sy) * width + u32(sx)];
  var lum = dot(vec3f(0.2126, 0.7152, 0.0722), image.rgb);
  if inverted != 0u { lum = 1.0 - lum; }
  var dithering = 0.0;
  if dither_type <= 1u {
    // Paper's hash21 on the cell centre.
    var q = fract(pixelized * vec2f(0.3183099, 0.3678794)) + 0.1;
    q += dot(q, q + 19.19);
    dithering = step(fract(q.x * q.y), lum);
  } else {
    let bx = u32(i32(cell.x));
    let by = u32(i32(cell.y));
    let bxy = bx ^ by;
    let b0 = ((bxy & 1u) << 1u) | (by & 1u);
    let b1 = (((bxy >> 1u) & 1u) << 1u) | ((by >> 1u) & 1u);
    let b2 = (((bxy >> 2u) & 1u) << 1u) | ((by >> 2u) & 1u);
    if dither_type == 2u {
      dithering = f32(b0) / 4.0;
    } else if dither_type == 3u {
      dithering = f32(b0 * 4u + b1) / 16.0;
    } else {
      dithering = f32(b0 * 16u + b1 * 4u + b2) / 64.0;
    }
  }
  let steps = f32(max(color_steps, 1u));
  let brightness = clamp(lum + (dithering - 0.5) / steps, 0.0, 1.0) * image.a;
  let quant = floor(brightness * steps + 0.5) / steps;
  var color = vec3f(0.0);
  var opacity = 1.0;
  if original_colors != 0u {
    color = image.rgb / max(lum, 0.001) * quant;
    opacity = mix(quant, 1.0, floor(image.a * steps + 0.5) / steps);
  } else {
    let lit = step(1.02 - 0.02 * steps, brightness);
    let fg = mix(vec3f(front_r, front_g, front_b), vec3f(highlight_r, highlight_g, highlight_b), lit);
    color = fg * quant + vec3f(back_r, back_g, back_b) * (1.0 - quant);
  }
  // Original colors divide by luma, so clamp like Paper's framebuffer.
  dst[id.x] = vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), opacity);
}`;
}

// Port of Paper's simplex noise (Apache-2.0) with five colors, unrolled.
// fwidth of each color's mix comes from the right and lower neighbours.
function simplexNoiseShader() {
  const colors = [[0.2666667, 0.2862745, 0.8117647], [1.0, 0.8196078, 0.8784314],
    [0.9764706, 0.2666667, 0.2745098], [1.0, 0.827451, 0.4196078], [1.0, 1.0, 1.0]];
  const lines = [`// Simplex noise, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move time to animate the noise. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 0.6; // 0.1..4
override time: f32 = 0.0; // 0..20
override color_count: u32 = 5; // 1..5
override steps_per_color: f32 = 2.0; // 1..10
override softness: f32 = 0.0; // 0..1`];
  colors.forEach((c, i) => ["r", "g", "b"].forEach((ch, j) =>
    lines.push(`override color${i + 1}_${ch}: f32 = ${c[j].toFixed(7)};`)));
  lines.push(`
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's pattern units are 100 pixels, and simplex noise scales them by 0.1.
  let k = 0.001 / scale;
  let t = 0.2 * time;
  let count = clamp(color_count, 1u, 5u);
  let cn = f32(count);
  let steps = max(1.0, steps_per_color);
  let soft = 0.5 * softness;`);
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  let uv${s} = vec2f(x + ${dx}.0 - f32(width) * 0.5, f32(height) * 0.5 - (y + ${dy}.0)) * k;
  var na${s} = 0.0;
  var nb${s} = 0.0;
  {
${simplexNoiseWgsl(`na${s}`, `uv${s} - vec2f(0.0, 0.3 * t)`, `a${s}_`)}
  }
  {
${simplexNoiseWgsl(`nb${s}`, `2.0 * uv${s} + vec2f(0.0, 0.32 * t)`, `b${s}_`)}
  }
  let mixer${s} = (0.5 + 0.25 * na${s} + 0.25 * nb${s} - 0.5 / cn) * cn;`);
  }
  // Paper's steppedSmooth, with fwidth from the neighbours' values of `m`.
  const stepped = (out, m) => {
    const [m0, mx, my] = paperNeighbours().map(([s]) => m(s));
    return `{
      let m = ${m0};
      // A floor keeps the smoothstep edges apart when softness is 0.
      let fw = max(steps * (abs(${mx} - m) + abs(${my} - m)), 0.000001);
      let f = m * steps - floor(m * steps);
      ${out} = floor(m * steps) / steps + smoothstep(0.5 - soft, min(1.0, 0.5 + soft + fw), f) / steps;
    }`;
  };
  lines.push(`  var gradient = vec3f(color1_r, color1_g, color1_b);
  var local_m = 0.0;`);
  for (let i = 1; i < colors.length; i++) {
    lines.push(`  if count > ${i}u {
    ${stepped("local_m", (s) => `clamp(mixer${s} - ${i - 1}.0, 0.0, 1.0)`)}
    gradient = mix(gradient, vec3f(color${i + 1}_r, color${i + 1}_g, color${i + 1}_b), local_m);
  }`);
  }
  lines.push(`  // Wrap the ends of the gradient from the last color back to the first.
  if mixer < 0.0 || mixer > cn - 1.0 {
    let shift = select(1.0, 1.0 - cn, mixer > cn - 1.0);
    ${stepped("local_m", (s) => `(mixer${s} + shift)`)}
    var last = vec3f(color1_r, color1_g, color1_b);`);
  for (let i = 2; i <= colors.length; i++) {
    lines.push(`    if count == ${i}u { last = vec3f(color${i}_r, color${i}_g, color${i}_b); }`);
  }
  lines.push(`    gradient = mix(last, vec3f(color1_r, color1_g, color1_b), local_m);
  }
  dst[id.x] = vec4f(gradient, 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's static mesh gradient (Apache-2.0) with four colors and
// both wave passes unrolled. Grain is left out.
function staticMeshGradientShader() {
  const colors = [[1.0, 0.6784314, 0.0392157], [0.3843137, 0.0, 1.0],
    [0.8862745, 0.6392157, 1.0], [1.0, 0.6, 0.9921569]];
  const lines = [`// Static mesh gradient, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Move positions to rearrange the color spots. Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override rotation: f32 = 270.0; // 0..360
override color_count: u32 = 4; // 1..4
override positions: f32 = 2.0; // 0..100
override wave_x: f32 = 1.0; // 0..1
override wave_x_shift: f32 = 0.6; // 0..1
override wave_y: f32 = 1.0; // 0..1
override wave_y_shift: f32 = 0.21; // 0..1
override mixing: f32 = 0.93; // 0..1`];
  colors.forEach((c, i) => ["r", "g", "b"].forEach((ch, j) =>
    lines.push(`override color${i + 1}_${ch}: f32 = ${c[j].toFixed(7)};`)));
  lines.push(`
const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's object units span the shorter side, rotated after scaling.
  let k = 1.0 / (f32(max(min(width, height), 1u)) * scale);
  let ox = (x - f32(width) * 0.5) * k;
  let oy = (f32(height) * 0.5 - y) * k;
  let r = rotation * PI / 180.0;
  var ux = cos(r) * ox - sin(r) * oy + 0.5;
  var uy = sin(r) * ox + cos(r) * oy + 0.5;
  let center = 1.0 - smoothstep(0.0, 1.0, length(vec2f(ux - 0.5, uy - 0.5)));`);
  for (const i of [1, 2]) {
    lines.push(`  ux += wave_x * center / ${i}.0 * cos(TWO_PI * wave_x_shift + ${i * 2}.0 * smoothstep(0.0, 1.0, uy));
  uy += wave_y * center / ${i}.0 * cos(TWO_PI * wave_y_shift + ${i * 2}.0 * smoothstep(0.0, 1.0, ux));`);
  }
  lines.push(`  let seed = 25.0 + 0.33 * positions;
  // Paper's pow(mixing, 0.7), floored so pow stays defined at 0.
  let mx = pow(max(mixing, 0.000001), 0.7);
  let power = mix(2.0, 1.0, mx);
  var color = vec3f(0.0);
  var total = 0.0;`);
  for (let i = 0; i < colors.length; i++) {
    lines.push(`  if color_count > ${i}u {
    let pos = 0.5 + 0.5 * vec2f(sin(seed * ${(0.6 + (i % 3) * 0.3).toFixed(2)} + ${(i * 0.37).toFixed(2)}),
      cos(seed * ${(0.8 + ((i + 1) % 4) * 0.25).toFixed(2)} + ${(i * 0.37 * 1.5).toFixed(3)}));
    // The floor keeps pow defined where the distance is 0.
    let d = pow(max(length(vec2f(ux, uy) - pos), 0.000001), power);
    let w0 = 1.0 / (d + 0.001);
    let sharpness = mix(mix(0.0, 8.0, clamp(w0, 0.0, 1.0)), 1.0, mx);
    let weight = pow(w0, sharpness);
    color += vec3f(color${i + 1}_r, color${i + 1}_g, color${i + 1}_b) * weight;
    total += weight;
  }`);
  }
  lines.push(`  dst[id.x] = vec4f(color / max(0.0001, total), 1.0);
}`);
  return lines.join("\n");
}

// Port of Paper's static radial gradient (Apache-2.0) with three colors.
// The shape is computed at the right and lower neighbours for fwidth.
function staticRadialGradientShader() {
  const colors = [[0.0, 0.7333333, 1.0], [0.0, 1.0, 0.8823529], [1.0, 1.0, 1.0]];
  const lines = [`// Static radial gradient, ported from Paper Shaders (Apache-2.0):
// https://github.com/paper-design/shaders. Changes are listed on qip.dev/wgsl.
// Input colors are unused.
override width: u32 = 256;
override scale: f32 = 1.0; // 0.1..4
override color_count: u32 = 3; // 1..3
override radius: f32 = 0.8; // 0..3
override focal_distance: f32 = 0.99; // 0..3
override focal_angle: f32 = 0.0; // 0..360
override falloff: f32 = 0.24; // -1..1
override mixing: f32 = 0.5; // 0..1
override distortion: f32 = 0.0; // 0..1
override distortion_shift: f32 = 0.0; // -1..1
override distortion_freq: f32 = 12.0; // 0..20
override back_r: f32 = 0.0;
override back_g: f32 = 0.0;
override back_b: f32 = 0.0;`];
  colors.forEach((c, i) => ["r", "g", "b"].forEach((ch, j) =>
    lines.push(`override color${i + 1}_${ch}: f32 = ${c[j].toFixed(7)};`)));
  lines.push(`
const PI: f32 = 3.14159265358979323846;
const TWO_PI: f32 = 6.28318530718;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = f32(id.x % width) + 0.5;
  let y = f32(id.x / width) + 0.5;
  // Paper's object units span the shorter side, doubled by this shader.
  let k = 2.0 / (f32(max(min(width, height), 1u)) * scale);
  let angle_rad = -(focal_angle + 90.0) * PI / 180.0;
  let focal = vec2f(cos(angle_rad), sin(angle_rad)) * focal_distance;
  let f_to_c = -focal;
  let half_angle = acos(clamp(radius / max(focal_distance, 0.0001), 0.0, 1.0));
  let e0 = 0.6 * PI;
  let lo = min(e0, half_angle);
  let hi = max(e0, half_angle);
  let falloff_mapped = mix(0.2 + 0.8 * max(0.0, falloff + 1.0), mix(1.0, 15.0, falloff * falloff), step(0.0, falloff));
  let cn = f32(clamp(color_count, 1u, 3u));`);
  for (const [s, dx, dy] of paperNeighbours()) {
    lines.push(`  var shape${s} = 0.0;
  {
    let uv = vec2f(x + ${dx}.0 - f32(width) * 0.5, f32(height) * 0.5 - (y + ${dy}.0)) * k;
    let f_to_uv = uv - focal;
    let r = length(uv);
    let frag_angle = atan2(uv.y, uv.x);
    let angle_diff = fract((frag_angle - angle_rad + PI) / TWO_PI) * TWO_PI - PI;
    let sector = smoothstep(lo, hi, abs(angle_diff));
    let in_sector = select(sector, 1.0 - sector, half_angle >= e0);
    let a = dot(f_to_uv, f_to_uv);
    let b = -2.0 * dot(f_to_uv, f_to_c);
    let c = dot(f_to_c, f_to_c) - radius * radius;
    let disc = b * b - 4.0 * a * c;
    var t = 1.0;
    if disc >= 0.0 {
      let sd = sqrt(disc);
      let div = max(0.0001, 2.0 * a);
      t = max(0.0, max((-b - sd) / div, (-b + sd) / div));
    }
    let dist = length(f_to_uv);
    var sh = clamp(dist / max(0.0001, length(f_to_uv * t)), 0.0, 1.0);
    // Paper's pow(shape, exponent), kept defined at 0.
    sh = select(0.0, pow(sh, mix(falloff_mapped, 1.0, sh)), sh > 0.0);
    sh = 1.0 - clamp(sh, 0.0, 1.0);
    let outer = mix(1.0 - smoothstep(radius - 0.002, radius + 0.002, r), 1.0, in_sector);
    sh = sh * outer * (1.0 - smoothstep(radius - 0.01, radius, r));
    let wave = sin(PI * clamp(dist - 0.2 + distortion_shift, 0.0, 1.0));
    let wave2 = wave * wave;
    let angle = atan2(f_to_uv.y, f_to_uv.x);
    sh -= distortion * distortion * sh * wave2 * wave2 *
      (sin(distortion_freq * angle) + cos(floor(0.65 * distortion_freq) * angle));
    shape${s} = sh;
  }
  let mixer${s} = shape${s} * cn;`);
  }
  lines.push(`  let mix_width = min(mixing, 0.5);
  let p = mix(2.0, 1.0, clamp((mixing - 0.5) * 2.0, 0.0, 1.0));
  let quad_blend = clamp((mixing - 0.5) * 2.0, 0.0, 1.0);
  var gradient = vec3f(color1_r, color1_g, color1_b);
  var outer_shape = 0.0;`);
  for (let i = 1; i <= colors.length; i++) {
    lines.push(`  if cn >= ${i}.0 {
    let ml = clamp(mixer - ${i - 1}.0, 0.0, 1.0);
    // A floor keeps the division defined when mixing is 0.
    let aa = max(abs(clamp(mixer_x - ${i - 1}.0, 0.0, 1.0) - ml) + abs(clamp(mixer_y - ${i - 1}.0, 0.0, 1.0) - ml), 0.000001);
    let t = clamp((ml - (0.5 - mix_width - aa)) / (2.0 * mix_width + 2.0 * aa), 0.0, 1.0);
    // The floors keep pow defined at 0.
    var m = select(1.0 - 0.5 * pow(max(2.0 * (1.0 - t), 1e-20), p), 0.5 * pow(max(2.0 * t, 1e-20), p), t < 0.5);
    m = mix(m, m * m, 0.5 * quad_blend);
    ${i === 1 ? "outer_shape = m;\n    " : ""}gradient = mix(gradient, vec3f(color${i}_r, color${i}_g, color${i}_b), m);
  }`);
  }
  lines.push(`  let color = gradient * outer_shape + vec3f(back_r, back_g, back_b) * (1.0 - outer_shape);
  dst[id.x] = vec4f(color, 1.0);
}`);
  return lines.join("\n");
}

const [compilerModule, gpu] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/text/wgsl/wgsl-to-wasm.wasm")),
  initGPU(),
]);
const compiler = new WebAssembly.Instance(compilerModule, {}).exports;

let image = testCard();
let uniformValues = new Map();
let wasmCache = { source: null, variants: new Map() };
let gpuCache = { key: null, pipeline: null, error: null, ms: 0 };
let gpuBuffers = { key: null, buffers: [], entries: [], output: null, readback: null, bindGroups: null };
let running = false;
let pending = false;
let camera = null;

async function initGPU() {
  if (!navigator.gpu) return { error: "This browser has no WebGPU." };
  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return { error: "No WebGPU adapter is available." };
    return { device: await adapter.requestDevice() };
  } catch (error) {
    return { error: error.message };
  }
}

// Reads what both runners need from the source: overrides (with an optional
// trailing `// min..max`), storage bindings, element size and workgroup size.
function parseShader(source) {
  const overrides = [];
  const overridePattern =
    /^\s*override\s+(\w+)\s*:\s*(f32|u32|i32)\s*(?:=\s*([^;]+))?;[ \t]*(?:\/\/\s*(-?[\d.]+)\s*\.\.\s*(-?[\d.]+))?/gm;
  for (const match of source.matchAll(overridePattern)) {
    overrides.push({
      name: match[1],
      type: match[2],
      value: Number.parseFloat(match[3] ?? "0") || 0,
      min: match[4] === undefined ? null : Number(match[4]),
      max: match[5] === undefined ? null : Number(match[5]),
    });
  }
  const bindings = [];
  const bindingPattern = /@binding\((\d+)\)\s*var<storage,\s*(read|read_write)>\s*\w+\s*:\s*array<(\w+(?:<\w+>)?)>/g;
  for (const match of source.matchAll(bindingPattern)) {
    bindings.push({ binding: Number(match[1]), access: match[2], element: match[3] });
  }
  const workgroup = /@workgroup_size\(\s*(\d+)/.exec(source);
  const fragment = /@fragment[\s\S]*?fn\s+(\w+)/.exec(source);
  const entry = fragment ?? /@compute[\s\S]*?fn\s+(\w+)/.exec(source);
  // A fragment shader's input image. `layout: "auto"` leaves out a texture the
  // shader never reads, so it is bound only when used.
  const texture = /@binding\((\d+)\)\s*var\s+(\w+)\s*:\s*texture_2d<f32>/.exec(source);
  const textureUsed = texture !== null &&
    new RegExp("\\b(?:textureLoad|textureDimensions)\\s*\\(\\s*" + texture[2] + "\\b").test(source);
  return {
    stage: fragment ? "fragment" : "compute",
    texture: textureUsed ? { binding: Number(texture[1]) } : null,
    overrides,
    bindings,
    elementSize: bindings.some((b) => b.element.startsWith("vec4")) ? 16 : 4,
    workgroupSize: workgroup ? Number(workgroup[1]) : 1,
    entry: entry ? entry[1] : "main",
  };
}

function renderUniformControls(overrides) {
  uniformsBox.replaceChildren();
  const effect = shaderSelect.selectedOptions[0]?.text;
  const shapeHints = {
    "Fluted glass": {
      shape: "1 lines · 2 irregular lines · 3 wave · 4 zigzag · 5 pattern",
      distortion_shape: "1 prism · 2 lens · 3 contour · 4 cascade · 5 flat",
    },
    Waves: { shape: "0 zigzag · 1 sine · 2–3 irregular; fractions blend shapes" },
    "Dot grid": { shape: "0 circle · 1 diamond · 2 square · 3 triangle" },
    "Image dithering": { dither_type: "1 random · 2 2×2 Bayer · 3 4×4 Bayer · 4 8×8 Bayer" },
    "Liquid metal (shapes)": { shape: "0 canvas · 1 circle · 2 daisy · 3 diamond · 4 metaballs" },
  };
  for (const o of overrides) {
    if (!uniformValues.has(o.name)) uniformValues.set(o.name, o.value);
  }
  // Each f32 triple `<prefix>_r`, `_g` and `_b` gets a color picker.
  const colorUniforms = new Set();
  const titles = { back: "Background", front: "Foreground" };
  for (const o of overrides) {
    if (o.type !== "f32" || !o.name.endsWith("_r")) continue;
    const prefix = o.name.slice(0, -2);
    const names = ["r", "g", "b"].map((channel) => prefix + "_" + channel);
    if (!names.every((name) => overrides.some((o) => o.name === name && o.type === "f32"))) continue;
    const title = titles[prefix] ?? (prefix[0].toUpperCase() + prefix.slice(1)).replace(/(\d+)$/, " $1");
    const label = document.createElement("label");
    const input = document.createElement("input");
    input.type = "color";
    input.value = "#" + names.map((name) => Math.round(Math.min(1, Math.max(0, uniformValues.get(name))) * 255)
      .toString(16).padStart(2, "0")).join("");
    input.addEventListener("input", () => {
      names.forEach((name, i) => uniformValues.set(name, Number.parseInt(input.value.slice(1 + i * 2, 3 + i * 2), 16) / 255));
      run();
    });
    names.forEach((name) => colorUniforms.add(name));
    label.append(controlName(title), input);
    uniformsBox.append(label);
  }
  for (const o of overrides) {
    if (o.name === "width" || colorUniforms.has(o.name)) continue;
    const label = document.createElement("label");
    const input = document.createElement("input");
    const output = document.createElement("output");
    const ranged = o.min !== null && o.max !== null;
    input.type = ranged ? "range" : "number";
    input.step = o.type === "f32" ? "any" : "1";
    if (ranged) {
      input.min = String(o.min);
      input.max = String(o.max);
    }
    input.value = String(uniformValues.get(o.name));
    output.value = input.value;
    input.addEventListener("input", () => {
      uniformValues.set(o.name, Number(input.value));
      output.value = input.value;
      run();
    });
    label.append(controlName(o.name), input);
    if (ranged) label.append(output);
    const hint = shapeHints[effect]?.[o.name];
    if (hint) {
      const help = document.createElement("small");
      // Keep each separator with the option before it when the hint wraps.
      help.textContent = hint.replaceAll(" · ", " · ");
      label.append(help);
    }
    uniformsBox.append(label);
  }
}

function controlName(text) {
  const span = document.createElement("span");
  span.textContent = text;
  return span;
}

function constantsFor(overrides) {
  const constants = {};
  for (const o of overrides) {
    constants[o.name] = o.name === "width" ? image.width : uniformValues.get(o.name) ?? o.value;
    if (o.type !== "f32") constants[o.name] = Math.trunc(constants[o.name]);
  }
  return constants;
}

function compileWasm(source) {
  const vectorize = vectorizeInput.checked;
  if (wasmCache.source !== source) wasmCache = { source, variants: new Map() };
  if (wasmCache.variants.has(vectorize)) return wasmCache.variants.get(vectorize);
  const start = performance.now();
  const compiled = { source, vectorize, vectorized: false, module: null, error: null, ms: 0 };
  wasmCache.variants.set(vectorize, compiled);
  try {
    const input = new TextEncoder().encode(source);
    if (input.byteLength > compiler.input_utf8_cap()) throw Error("shader exceeds compiler input capacity");
    if (vectorize && !compiler.uniform_set_vectorize_invocations) {
      throw Error("Hard-refresh the page or restart the dev server to load the rebuilt WGSL compiler.");
    }
    compiler.uniform_set_vectorize_invocations?.(Number(vectorize));
    new Uint8Array(compiler.memory.buffer, compiler.input_ptr(), input.byteLength).set(input);
    const bits = BigInt.asUintN(64, compiler.render(input.byteLength));
    const size = Number(bits & 0xffff_ffffn);
    if (bits >> 63n) {
      const modes = compiler.failure_modes_per_input_offset();
      throw Error("rejected input at input offset " + Math.floor(size / modes) + " with mode " + size % modes);
    }
    const ptr = Number(bits >> 32n);
    compiled.module = new WebAssembly.Module(new Uint8Array(compiler.memory.buffer, ptr, size));
    compiled.vectorized = WebAssembly.Module.customSections(compiled.module, "qip.vectorize_invocations").length > 0;
  } catch (error) {
    compiled.error = describeCompileError(source, error.message);
  }
  compiled.ms = performance.now() - start;
  return compiled;
}

function describeCompileError(source, message) {
  const match = /input offset (\d+) with mode (\d+)/.exec(message);
  if (!match) return message;
  const before = new TextDecoder().decode(new TextEncoder().encode(source).subarray(0, Number(match[1])));
  const lines = before.split("\n");
  return (COMPILE_FAILURES[Number(match[2])] ?? "rejected") +
    " at line " + lines.length + ":" + (lines.at(-1).length + 1);
}

// One instance per compiled module, so its memory is allocated once and
// slider changes only call the uniform setters again.
function runWasm(compiled, input, constants) {
  compiled.instance ??= new WebAssembly.Instance(compiled.module, {});
  const exports = compiled.instance.exports;
  for (const [name, value] of Object.entries(constants)) exports["uniform_set_" + name]?.(value);
  // A fragment module's own uniform for the image rows.
  exports.uniform_set_width?.(image.width);
  if (input.byteLength > exports.input_bytes_cap()) throw Error("input exceeds component capacity");
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.byteLength).set(input);
  const bits = BigInt.asUintN(64, exports.render(input.byteLength));
  if (bits >> 63n) throw Error("render rejected the input");
  const size = Number(bits & 0xffff_ffffn);
  const ptr = Number((bits >> 32n) & 0x7fff_ffffn);
  return new Float32Array(exports.memory.buffer.slice(ptr, ptr + size));
}

async function gpuPipeline(source, info, constants) {
  const key = source + "\0" + JSON.stringify(constants);
  if (gpuCache.key === key) return gpuCache;
  const start = performance.now();
  gpuCache = { key, pipeline: null, error: null, ms: 0 };
  const module = gpu.device.createShaderModule({ code: source });
  const errors = (await module.getCompilationInfo()).messages.filter((m) => m.type === "error");
  if (errors.length > 0) {
    gpuCache.error = "line " + errors[0].lineNum + ":" + errors[0].linePos + " " + errors[0].message;
  } else {
    try {
      gpuCache.pipeline = info.stage === "fragment"
        ? await gpu.device.createRenderPipelineAsync({
          layout: "auto",
          vertex: { module: fullscreenVertexModule() },
          fragment: { module, entryPoint: info.entry, constants, targets: [{ format: "rgba32float" }] },
        })
        : await gpu.device.createComputePipelineAsync({
          layout: "auto",
          compute: { module, entryPoint: info.entry, constants },
        });
    } catch (error) {
      gpuCache.error = error.message;
    }
  }
  gpuCache.ms = performance.now() - start;
  return gpuCache;
}

// One triangle that covers the viewport, at depth 0 with w = 1, so each
// fragment's position is (x + 0.5, y + 0.5, 0, 1) as in the Wasm render.
function fullscreenVertexModule() {
  gpu.vertexModule ??= gpu.device.createShaderModule({
    code: `@vertex fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}`,
  });
  return gpu.vertexModule;
}

// Renders a fragment shader into an rgba32float texture cleared to
// transparent black, reading the image from another rgba32float texture.
async function runGPUFragment(pipeline, info, input) {
  const device = gpu.device;
  const { width, height } = image;
  const key = "fragment\0" + width + "x" + height;
  if (gpuBuffers.key !== key) {
    for (const buffer of gpuBuffers.buffers) buffer.destroy();
    gpuBuffers.readback?.destroy();
    const bytesPerRow = Math.ceil(width * 16 / 256) * 256;
    const size = [width, height];
    gpuBuffers = {
      key,
      buffers: [],
      entries: [],
      bytesPerRow,
      source: device.createTexture({ size, format: "rgba32float", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST }),
      target: device.createTexture({ size, format: "rgba32float", usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC }),
      readback: device.createBuffer({ size: bytesPerRow * height, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST }),
      bindGroups: new WeakMap(),
    };
    gpuBuffers.buffers.push(gpuBuffers.source, gpuBuffers.target);
  }
  const { source, target, readback, bytesPerRow } = gpuBuffers;
  device.queue.writeTexture({ texture: source }, input, { bytesPerRow: width * 16 }, [width, height]);
  if (info.texture && !gpuBuffers.bindGroups.has(pipeline)) {
    gpuBuffers.bindGroups.set(pipeline, device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [{ binding: info.texture.binding, resource: source.createView() }],
    }));
  }
  device.pushErrorScope("validation");
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginRenderPass({
    colorAttachments: [{ view: target.createView(), loadOp: "clear", clearValue: [0, 0, 0, 0], storeOp: "store" }],
  });
  pass.setPipeline(pipeline);
  if (info.texture) pass.setBindGroup(0, gpuBuffers.bindGroups.get(pipeline));
  pass.draw(3);
  pass.end();
  encoder.copyTextureToBuffer({ texture: target }, { buffer: readback, bytesPerRow }, [width, height]);
  device.queue.submit([encoder.finish()]);
  const error = await device.popErrorScope();
  if (error) throw Error(error.message);
  await readback.mapAsync(GPUMapMode.READ);
  try {
    const mapped = new Float32Array(readback.getMappedRange());
    const output = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++) {
      output.set(mapped.subarray(y * bytesPerRow / 4, y * bytesPerRow / 4 + width * 4), y * width * 4);
    }
    return output;
  } finally {
    readback.unmap();
  }
}

async function runGPU(pipeline, info, input) {
  if (info.stage === "fragment") return runGPUFragment(pipeline, info, input);
  const device = gpu.device;
  const count = input.byteLength / info.elementSize;
  const groups = Math.ceil(count / info.workgroupSize);
  if (groups > device.limits.maxComputeWorkgroupsPerDimension) {
    throw Error(groups + " workgroups exceeds this GPU's limit; raise @workgroup_size");
  }
  const { buffers, output, readback } = gpuBuffersFor(info, input.byteLength);
  if (output === null) throw Error("the shader needs a var<storage, read_write> buffer");
  for (const [i, b] of info.bindings.entries()) {
    if (b.access === "read" || info.bindings.length === 1) device.queue.writeBuffer(buffers[i], 0, input);
  }
  gpuBuffers.bindGroups.set(pipeline, gpuBuffers.bindGroups.get(pipeline) ??
    device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: gpuBuffers.entries }));
  device.pushErrorScope("validation");
  const encoder = device.createCommandEncoder();
  // The output starts zeroed, unless the shader works in place.
  for (const [i, b] of info.bindings.entries()) {
    if (b.access === "read_write" && info.bindings.length > 1) encoder.clearBuffer(buffers[i]);
  }
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, gpuBuffers.bindGroups.get(pipeline));
  pass.dispatchWorkgroups(groups);
  pass.end();
  encoder.copyBufferToBuffer(output, 0, readback, 0, input.byteLength);
  device.queue.submit([encoder.finish()]);
  const error = await device.popErrorScope();
  if (error) throw Error(error.message);
  await readback.mapAsync(GPUMapMode.READ);
  try {
    return new Float32Array(readback.getMappedRange().slice(0));
  } finally {
    readback.unmap();
  }
}

// Storage and readback buffers live until the shader's bindings or the image
// size change, like the wasm instance's memory. Slider changes keep them.
function gpuBuffersFor(info, byteLength) {
  const key = JSON.stringify(info.bindings) + "\0" + byteLength;
  if (gpuBuffers.key === key) return gpuBuffers;
  for (const buffer of gpuBuffers.buffers) buffer.destroy();
  gpuBuffers.readback?.destroy();
  const device = gpu.device;
  const usage = GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST;
  gpuBuffers = { key, buffers: [], entries: [], output: null, readback: null, bindGroups: new WeakMap() };
  for (const b of info.bindings) {
    const buffer = device.createBuffer({ size: byteLength, usage });
    if (b.access === "read_write") gpuBuffers.output = buffer;
    gpuBuffers.buffers.push(buffer);
    gpuBuffers.entries.push({ binding: b.binding, resource: { buffer } });
  }
  gpuBuffers.readback = device.createBuffer({
    size: byteLength,
    usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
  });
  return gpuBuffers;
}

async function run() {
  if (running) {
    pending = true;
    return;
  }
  running = true;
  try {
    do {
      pending = false;
      await runOnce();
    } while (pending);
  } finally {
    running = false;
  }
}

async function runOnce() {
  const source = sourceInput.value;
  const info = parseShader(source);
  const constants = constantsFor(info.overrides);
  const input = new Uint8Array(image.pixels.buffer);
  drawPixels(inputCanvas, image.pixels, image.width, image.height);
  inputCaption.textContent = "Input, " + image.width + "×" + image.height;

  let wasmOutput = null;
  const compiled = compileWasm(source);
  if (compiled.error) {
    showError(wasmCanvas, wasmCaption, "WebAssembly: " + compiled.error);
  } else {
    try {
      const start = performance.now();
      wasmOutput = runWasm(compiled, input, constants);
      const ms = performance.now() - start;
      drawPixels(wasmCanvas, wasmOutput, image.width, image.height);
      wasmCaption.className = "";
      const mode = compiled.vectorize ? (compiled.vectorized ? " (4 invocations)" : " (scalar fallback)") : "";
      wasmCaption.textContent = "WebAssembly" + mode + ": compile " + formatMs(compiled.ms) + ", run " + formatMs(ms);
    } catch (error) {
      // A trap may leave the instance half written, so start fresh next run.
      compiled.instance = null;
      showError(wasmCanvas, wasmCaption, "WebAssembly: " + error.message);
    }
  }

  let gpuOutput = null;
  if (gpu.error) {
    showError(gpuCanvas, gpuCaption, "WebGPU: " + gpu.error);
  } else {
    const pipeline = await gpuPipeline(source, info, constants);
    if (pipeline.error) {
      showError(gpuCanvas, gpuCaption, "WebGPU: " + pipeline.error);
    } else {
      try {
        const start = performance.now();
        gpuOutput = await runGPU(pipeline.pipeline, info, input);
        const ms = performance.now() - start;
        drawPixels(gpuCanvas, gpuOutput, image.width, image.height);
        gpuCaption.className = "";
        gpuCaption.textContent = "WebGPU: pipeline " + formatMs(pipeline.ms) + ", run " + formatMs(ms);
      } catch (error) {
        showError(gpuCanvas, gpuCaption, "WebGPU: " + error.message);
      }
    }
  }

  if (wasmOutput && gpuOutput) {
    comparisonOutputs = [gpuOutput, wasmOutput];
    summary.textContent = compare(gpuOutput, wasmOutput);
  } else {
    comparisonOutputs = null;
    clearCanvas(diffCanvas);
    summary.textContent = "Both runs must succeed to compare them.";
  }
}

// Count bitwise mismatches, but scale heatmap brightness by absolute error.
// Hover or keyboard focus magnifies small errors without rerunning the shaders.
function compare(a, b) {
  const gain = diffCanvas.matches(":hover, :focus") ? 1048576 : 65536;
  diffCaption.textContent = "Absolute difference ×" + gain.toLocaleString() + ": black → red → yellow";
  const aBits = new Int32Array(a.buffer);
  const bBits = new Int32Array(b.buffer);
  const pixels = image.width * image.height;
  const lanes = a.length / pixels;
  const heat = new Uint8ClampedArray(pixels * 4);
  let floats = 0;
  let pixelsDiffering = 0;
  let maxAbs = 0;
  let maxUlp = 0;
  for (let p = 0; p < pixels; p += 1) {
    let pixelMax = -1;
    for (let lane = 0; lane < lanes; lane += 1) {
      const i = p * lanes + lane;
      if (aBits[i] === bBits[i] || (Number.isNaN(a[i]) && Number.isNaN(b[i]))) continue;
      const abs = Math.abs(a[i] - b[i]);
      floats += 1;
      pixelMax = Math.max(pixelMax, abs);
      maxAbs = Math.max(maxAbs, abs);
      maxUlp = Math.max(maxUlp, Math.abs(orderedBits(aBits[i]) - orderedBits(bBits[i])));
    }
    const o = p * 4;
    if (pixelMax >= 0) {
      pixelsDiffering += 1;
      const intensity = Math.min(pixelMax * gain, 1);
      heat[o] = intensity * 255;
      heat[o + 1] = intensity * intensity * 255;
    }
    heat[o + 3] = 255;
  }
  drawBytes(diffCanvas, heat, image.width, image.height);
  if (floats === 0) return "Identical: all " + a.length.toLocaleString() + " floats match bit for bit.";
  return floats.toLocaleString() + " of " + a.length.toLocaleString() + " floats differ, in " +
    pixelsDiffering.toLocaleString() + " pixels. Largest difference " + maxAbs.toPrecision(3) +
    " (" + maxUlp.toLocaleString() + " ULP).";
}

// Maps f32 bit patterns onto a line where adjacent floats differ by 1.
function orderedBits(bits) {
  return bits >= 0 ? bits : -(bits & 0x7fff_ffff);
}

function drawPixels(canvas, floats, width, height) {
  const bytes = new Uint8ClampedArray(width * height * 4);
  const lanes = floats.length / (width * height);
  for (let p = 0; p < width * height; p += 1) {
    for (let c = 0; c < 4; c += 1) {
      bytes[p * 4 + c] = lanes === 4 || c === 3 ? Math.round(floats[p * lanes + Math.min(c, lanes - 1)] * 255) : 0;
    }
  }
  drawBytes(canvas, bytes, width, height);
}

function drawBytes(canvas, bytes, width, height) {
  canvas.width = width;
  canvas.height = height;
  canvas.getContext("2d").putImageData(new ImageData(bytes, width, height), 0, 0);
}

function clearCanvas(canvas) {
  canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
}

function showError(canvas, caption, message) {
  clearCanvas(canvas);
  caption.className = "wgsl-error";
  caption.textContent = message;
}

function formatMs(ms) {
  return (ms < 10 ? ms.toFixed(1) : Math.round(ms)) + " ms";
}

function pixelsFrom(source, sourceWidth, sourceHeight) {
  const scale = Math.min(1, MAX_SIDE / sourceWidth, MAX_SIDE / sourceHeight);
  const width = Math.max(1, Math.round(sourceWidth * scale));
  const height = Math.max(1, Math.round(sourceHeight * scale));
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context.drawImage(source, 0, 0, width, height);
  const bytes = context.getImageData(0, 0, width, height).data;
  const pixels = new Float32Array(bytes.length);
  for (let i = 0; i < bytes.length; i += 1) pixels[i] = bytes[i] / 255;
  return { width, height, pixels };
}

// A generated 512×384 test card: gradients, shapes, and text with hard edges.
// It is drawn in 256×192 units at twice the scale.
function testCard() {
  const canvas = new OffscreenCanvas(512, 384);
  const context = canvas.getContext("2d");
  context.scale(2, 2);
  const sky = context.createLinearGradient(0, 0, 0, 192);
  sky.addColorStop(0, "#1b3a6b");
  sky.addColorStop(0.6, "#e98b5a");
  sky.addColorStop(1, "#f6d27a");
  context.fillStyle = sky;
  context.fillRect(0, 0, 256, 192);
  const sun = context.createRadialGradient(176, 92, 4, 176, 92, 44);
  sun.addColorStop(0, "#fff8d0");
  sun.addColorStop(1, "#f2a44a00");
  context.fillStyle = sun;
  context.fillRect(120, 40, 112, 112);
  context.fillStyle = "#24283b";
  context.beginPath();
  context.moveTo(0, 192);
  context.lineTo(0, 140);
  context.lineTo(60, 104);
  context.lineTo(110, 150);
  context.lineTo(170, 118);
  context.lineTo(256, 160);
  context.lineTo(256, 192);
  context.fill();
  context.fillStyle = "#ffffff";
  context.font = "bold 56px system-ui, sans-serif";
  context.fillText("WGSL", 16, 72);
  for (let i = 0; i < 8; i += 1) {
    context.fillStyle = "hsl(" + i * 45 + " 80% 55%)";
    context.fillRect(16 + i * 28, 168, 24, 16);
  }
  return pixelsFrom(canvas, 512, 384);
}

function selectShader() {
  sourceInput.value = shaders[Number(shaderSelect.value)].textContent.trim() + "\n";
  uniformValues = new Map();
  renderUniformControls(parseShader(sourceInput.value).overrides);
  run();
}

async function toggleCamera() {
  if (camera) {
    for (const track of camera.srcObject.getTracks()) track.stop();
    camera = null;
    cameraButton.textContent = "Use camera";
    return;
  }
  try {
    const video = document.createElement("video");
    video.muted = true;
    video.playsInline = true;
    video.srcObject = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 } });
    await video.play();
    camera = video;
    cameraButton.textContent = "Stop camera";
    const frame = async () => {
      if (camera !== video) return;
      if (!running) {
        image = pixelsFrom(video, video.videoWidth, video.videoHeight);
        await run();
      }
      requestAnimationFrame(frame);
    };
    frame();
  } catch (error) {
    summary.textContent = "Camera unavailable: " + error.message;
  }
}

let editTimer = 0;
sourceInput.addEventListener("input", () => {
  clearTimeout(editTimer);
  editTimer = setTimeout(() => {
    renderUniformControls(parseShader(sourceInput.value).overrides);
    run();
  }, 300);
});
shaderSelect.addEventListener("change", selectShader);
vectorizeInput.addEventListener("change", run);
for (const event of ["mouseenter", "mouseleave", "focus", "blur"]) {
  diffCanvas.addEventListener(event, () => {
    if (comparisonOutputs) compare(...comparisonOutputs);
  });
}
cameraButton.addEventListener("click", toggleCamera);
fileInput.addEventListener("change", async () => {
  const file = fileInput.files[0];
  if (!file) return;
  try {
    const bitmap = await createImageBitmap(file);
    image = pixelsFrom(bitmap, bitmap.width, bitmap.height);
    run();
  } catch (error) {
    summary.textContent = "Could not decode " + file.name + ": " + error.message;
  }
});

selectShader();
</script>
