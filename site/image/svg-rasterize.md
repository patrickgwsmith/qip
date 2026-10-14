<title>Compare SVG rasterizers</title>

# Compare SVG rasterizers

Render the same SVG with each of QIP’s SVG rasterizer components and compare
the results. Edit the SVG, choose a component, and the image renders again in
your browser. Nothing is uploaded.

<style>
.svg-rasterize-tool {
  display: grid;
  gap: 1rem;
}
.svg-rasterize-tool textarea,
.svg-rasterize-tool input,
.svg-rasterize-tool button {
  font: inherit;
}
.svg-rasterize-tool textarea {
  box-sizing: border-box;
  width: 100%;
  min-height: 16rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85rem;
}
.svg-rasterize-components {
  display: grid;
  gap: 0.25rem;
  margin: 0;
  padding: 0.5rem 0.75rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.svg-rasterize-components label {
  display: flex;
  gap: 0.5rem;
  align-items: baseline;
}
.svg-rasterize-components small {
  opacity: 0.7;
}
.svg-rasterize-options {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: end;
}
.svg-rasterize-options label {
  display: grid;
  gap: 0.25rem;
}
.svg-rasterize-options input[type="number"] {
  box-sizing: border-box;
  width: 7rem;
}
.svg-rasterize-preview {
  display: block;
  max-width: 100%;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
  background: repeating-conic-gradient(#ddd 0 25%, #fff 0 50%) 50% / 1rem 1rem;
}
.svg-rasterize-status {
  min-height: 1.5rem;
  margin: 0;
}
</style>

<div class="svg-rasterize-tool">
  <label>
    <strong>SVG</strong><br>
    <textarea id="svg-rasterize-input" spellcheck="false" aria-describedby="svg-rasterize-status"><svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#ff7a59"/>
      <stop offset="1" stop-color="#6a5cff"/>
    </linearGradient>
  </defs>
  <rect x="10" y="10" width="300" height="180" rx="24" fill="url(#sky)"/>
  <circle cx="90" cy="100" r="50" fill="#ffd23f" fill-opacity="0.85"/>
  <path d="M150 160 C180 40 260 40 290 160 Z" fill="#0b132b" fill-opacity="0.7"/>
  <path d="M30 170 L130 30" stroke="#ffffff" stroke-width="6" stroke-linecap="round"/>
  <text x="160" y="185" font-family="Inter" font-size="18" font-weight="bold" fill="#ffffff" text-anchor="middle">Hello, SVG</text>
</svg></textarea>
  </label>
  <fieldset class="svg-rasterize-components">
    <legend>Component</legend>
    <label><input type="radio" name="svg-rasterize-component" value="skia" checked> Skia <small>RGBA8 sRGB KTX2</small></label>
    <label><input type="radio" name="svg-rasterize-component" value="thorvg"> ThorVG <small>RGBA8 sRGB KTX2</small></label>
    <label><input type="radio" name="svg-rasterize-component" value="rgba32float"> QIP SIMD, linear light <small>RGBA32F linear BT.709 KTX2</small></label>
    <label><input type="radio" name="svg-rasterize-component" value="rgba8-simd"> QIP SIMD <small>RGBA8 sRGB KTX2</small></label>
    <label><input type="radio" name="svg-rasterize-component" value="rgba8"> QIP center-sampled <small>RGBA8 sRGB KTX2</small></label>
    <label><input type="radio" name="svg-rasterize-component" value="bmp"> QIP center-sampled <small>B8G8R8A8 sRGB BMP</small></label>
  </fieldset>
  <div class="svg-rasterize-options">
    <label>Width
      <input id="svg-rasterize-width" type="number" min="0" max="8192" step="1" value="0" />
    </label>
    <label>Height
      <input id="svg-rasterize-height" type="number" min="0" max="8192" step="1" value="0" />
    </label>
    <label>
      <span><input id="svg-rasterize-background" type="checkbox" /> White background</span>
    </label>
  </div>
  <p id="svg-rasterize-status" class="svg-rasterize-status" role="status" aria-live="polite"></p>
  <canvas id="svg-rasterize-preview" class="svg-rasterize-preview" width="0" height="0" hidden></canvas>
</div>

<script type="module">
const input = document.getElementById("svg-rasterize-input");
const widthField = document.getElementById("svg-rasterize-width");
const heightField = document.getElementById("svg-rasterize-height");
const backgroundField = document.getElementById("svg-rasterize-background");
const status = document.getElementById("svg-rasterize-status");
const canvas = document.getElementById("svg-rasterize-preview");
const radios = document.querySelectorAll('input[name="svg-rasterize-component"]');

const componentURLs = {
  skia: "/image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm",
  thorvg: "/image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm",
  rgba32float: "/image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm",
  "rgba8-simd": "/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm",
  rgba8: "/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm",
  bmp: "/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm",
};
// Skia takes its fonts as multipart/related parts after the SVG root.
const relatedFontURLs = ["/fonts/InterDisplay-Regular.ttf", "/fonts/InterDisplay-Bold.ttf"];
const relatedBoundary = "uuid-00000000-0000-0000-0000-000000000000";
let relatedFonts = null;
const VK_FORMAT_R8G8B8A8_SRGB = 43;
const VK_FORMAT_R32G32B32A32_SFLOAT = 109;
const modules = new Map();
// Several components reserve 512 MiB of fixed memory, so keep only the
// selected component's instance alive. Uniforms reset after each render.
let current = { key: "", exports: null };
let generation = 0;
let timer = 0;

function readExport(exports, name) {
  if (typeof exports[name] !== "function") throw Error(`Component does not export ${name}.`);
  return Number(exports[name]()) >>> 0;
}

async function loadModule(url) {
  let module = modules.get(url);
  if (!module) {
    module = WebAssembly.compileStreaming(fetch(url).then((response) => {
      if (!response.ok) throw Error(`Could not load ${url}.`);
      return response;
    }));
    modules.set(url, module);
    module.catch(() => modules.delete(url));
  }
  return module;
}

async function instanceFor(key) {
  if (current.key !== key || current.exports === null) {
    current = { key: "", exports: null };
    const module = await loadModule(componentURLs[key]);
    current = { key, exports: new WebAssembly.Instance(module).exports };
  }
  return current.exports;
}

function loadRelatedFonts() {
  if (!relatedFonts) {
    relatedFonts = Promise.all(relatedFontURLs.map(async (url) => {
      const response = await fetch(url);
      if (!response.ok) throw Error(`Could not load ${url}.`);
      return new Uint8Array(await response.arrayBuffer());
    }));
    relatedFonts.catch(() => { relatedFonts = null; });
  }
  return relatedFonts;
}

async function relatedBody(svg) {
  const encoder = new TextEncoder();
  const parts = [["image/svg+xml", svg], ...(await loadRelatedFonts()).map((font) => ["font/ttf", font])];
  const chunks = parts.flatMap(([type, bytes]) => [
    encoder.encode(`--${relatedBoundary}\r\nContent-Type: ${type}\r\n\r\n`), bytes, encoder.encode("\r\n"),
  ]);
  chunks.push(encoder.encode(`--${relatedBoundary}--\r\n`));
  const body = new Uint8Array(chunks.reduce((size, chunk) => size + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}

function selectedDimension(field, label) {
  const value = Number(field.value || 0);
  if (!Number.isInteger(value) || value < 0 || value > 8192) {
    throw Error(`${label} must be an integer from 0 through 8192.`);
  }
  return value;
}

function render(exports, source, width, height, background) {
  const inputCap = typeof exports.input_utf8_cap === "function"
    ? readExport(exports, "input_utf8_cap")
    : readExport(exports, "input_bytes_cap");
  if (source.length > inputCap) throw Error(`SVG exceeds this component's ${inputCap.toLocaleString()} byte input limit.`);
  const inputPtr = readExport(exports, "input_ptr");
  new Uint8Array(exports.memory.buffer, inputPtr, source.length).set(source);
  const ignored = [];
  if (width !== 0) {
    if (typeof exports.uniform_set_width === "function") exports.uniform_set_width(width);
    else ignored.push("width");
  }
  if (height !== 0) {
    if (typeof exports.uniform_set_height === "function") exports.uniform_set_height(height);
    else ignored.push("height");
  }
  if (background) exports.uniform_set_background_color_rgba(0xffffffff);

  const start = performance.now();
  const bits = BigInt.asUintN(64, exports.render(source.length));
  const elapsed = performance.now() - start;
  if ((bits & (1n << 63n)) !== 0n) throw Error("This component rejected the SVG.");
  const size = Number(bits & 0xffff_ffffn);
  const outputPtr = Number((bits >> 32n) & 0x7fff_ffffn);
  if (size > readExport(exports, "output_bytes_cap") || outputPtr + size > exports.memory.buffer.byteLength) {
    throw Error("Component returned output outside its declared buffer.");
  }
  return { bytes: new Uint8Array(exports.memory.buffer, outputPtr, size).slice(), elapsed, ignored };
}

function linearToSRGB(value) {
  const v = Math.min(1, Math.max(0, value));
  const encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055;
  return Math.round(encoded * 255);
}

function ktx2ToImageData(bytes) {
  if (bytes.length < 104) throw Error("Component did not return a complete KTX2 image.");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const format = view.getUint32(12, true);
  const width = view.getUint32(20, true);
  const height = view.getUint32(24, true);
  const offset = Number(view.getBigUint64(80, true));
  const pixelCount = width * height;
  const image = new ImageData(width, height);
  if (format === VK_FORMAT_R8G8B8A8_SRGB) {
    if (offset + pixelCount * 4 > bytes.length) throw Error("KTX2 level is truncated.");
    image.data.set(bytes.subarray(offset, offset + pixelCount * 4));
  } else if (format === VK_FORMAT_R32G32B32A32_SFLOAT) {
    if (offset + pixelCount * 16 > bytes.length) throw Error("KTX2 level is truncated.");
    // Straight-alpha linear BT.709 converts to sRGB channel by channel.
    for (let i = 0; i < pixelCount * 4; i += 4) {
      const at = offset + i * 4;
      image.data[i] = linearToSRGB(view.getFloat32(at, true));
      image.data[i + 1] = linearToSRGB(view.getFloat32(at + 4, true));
      image.data[i + 2] = linearToSRGB(view.getFloat32(at + 8, true));
      image.data[i + 3] = Math.round(Math.min(1, Math.max(0, view.getFloat32(at + 12, true))) * 255);
    }
  } else {
    throw Error(`Unsupported KTX2 format ${format}.`);
  }
  return image;
}

// Browsers ignore the alpha channel of 32-bit BMPs, so decode the pixels here.
function bmpToImageData(bytes) {
  if (bytes.length < 54) throw Error("Component did not return a complete BMP image.");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const offset = view.getUint32(10, true);
  const width = view.getInt32(18, true);
  const rawHeight = view.getInt32(22, true);
  const height = Math.abs(rawHeight);
  if (view.getUint16(28, true) !== 32) throw Error("Expected a 32-bit BMP.");
  if (offset + width * height * 4 > bytes.length) throw Error("BMP pixel data is truncated.");
  const image = new ImageData(width, height);
  for (let y = 0; y < height; y++) {
    const sourceRow = rawHeight > 0 ? height - 1 - y : y;
    for (let x = 0; x < width; x++) {
      const from = offset + (sourceRow * width + x) * 4;
      const to = (y * width + x) * 4;
      image.data[to] = bytes[from + 2];
      image.data[to + 1] = bytes[from + 1];
      image.data[to + 2] = bytes[from];
      image.data[to + 3] = bytes[from + 3];
    }
  }
  return image;
}

function draw(bytes, isBMP) {
  const image = isBMP ? bmpToImageData(bytes) : ktx2ToImageData(bytes);
  canvas.width = image.width;
  canvas.height = image.height;
  canvas.getContext("2d").putImageData(image, 0, 0);
  canvas.hidden = false;
}

async function run() {
  const run = ++generation;
  const key = [...radios].find((radio) => radio.checked)?.value ?? "skia";
  try {
    const width = selectedDimension(widthField, "Width");
    const height = selectedDimension(heightField, "Height");
    const svg = new TextEncoder().encode(input.value);
    status.textContent = modules.has(componentURLs[key]) ? "Rendering…" : "Loading component…";
    let exports = await instanceFor(key);
    const source = key === "skia" ? await relatedBody(svg) : svg;
    if (run !== generation) return;
    let result;
    try {
      result = render(exports, source, width, height, backgroundField.checked);
    } catch (error) {
      // A trap leaves the instance unusable; the next render makes a new one.
      if (error instanceof WebAssembly.RuntimeError) current = { key: "", exports: null };
      throw error;
    }
    draw(result.bytes, key === "bmp");
    const ignored = result.ignored.length > 0
      ? ` This component has no ${result.ignored.join(" or ")} uniform, so it used the SVG size.`
      : "";
    status.textContent = `${canvas.width}×${canvas.height} in ${result.elapsed.toFixed(1)} ms, ` +
      `${result.bytes.length.toLocaleString()} output bytes.${ignored}`;
  } catch (error) {
    if (run !== generation) return;
    canvas.hidden = true;
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

function schedule() {
  clearTimeout(timer);
  timer = setTimeout(run, 250);
}

input.addEventListener("input", schedule);
widthField.addEventListener("input", schedule);
heightField.addEventListener("input", schedule);
backgroundField.addEventListener("change", run);
for (const radio of radios) radio.addEventListener("change", run);
run();
</script>

The time shown is one `render` call on an already compiled and instantiated
module. The first render of each component also downloads and compiles it.
Width and height of zero use the SVG’s own size. The RGBA32F output is
converted from linear light to sRGB for display.

## Components

| Component | Renderer | Output | Size | Memory limit | Text |
| --- | --- | --- | --- | --- | --- |
| [Skia](/image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm) | Skia CPU, analytic coverage | RGBA8 sRGB KTX2 | <qip-content-size src="/image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm"></qip-content-size> | 544 MiB | TrueType, OpenType, WOFF, or WOFF2 fonts sent as `multipart/related` parts; this page sends Inter Display Regular and Bold |
| [ThorVG](/image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm) | ThorVG CPU scan converter | RGBA8 sRGB KTX2 | <qip-content-size src="/image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm"></qip-content-size> | 512 MiB | None |
| [QIP SIMD, linear light](/image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm) | 4 by 4 sample grid | RGBA32F linear BT.709 KTX2 | <qip-content-size src="/image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm"></qip-content-size> | 512 MiB | Inter Display Regular and Bold outlines |
| [QIP SIMD](/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm) | 4 by 4 sample grid | RGBA8 sRGB KTX2 | <qip-content-size src="/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm"></qip-content-size> | 512 MiB | Inter Display Regular and Bold outlines |
| [QIP center-sampled](/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm) | One sample per pixel | RGBA8 sRGB KTX2 | <qip-content-size src="/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm"></qip-content-size> | 128 MiB | Inter Display Regular and Bold outlines |
| [QIP center-sampled BMP](/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm) | One sample per pixel | B8G8R8A8 sRGB BMP | <qip-content-size src="/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm"></qip-content-size> | 128 MiB | Inter Display Regular and Bold outlines |

Skia accepts up to 32 MiB of SVG and fonts together; the others accept up to
1 MiB of SVG. All output at most 8192 pixels per side and 25 million pixels in
total. None of them load external resources. The BMP
component has no `width` or `height` uniform.

## Choosing one

- **Skia** has the broadest SVG support, including masks, filters, and
  `<text>`. It is by far the largest download.
- **ThorVG** covers a broad SVG paint model with antialiased edges at a
  fraction of Skia’s size, but it does not render text.
- **QIP SIMD, linear light** keeps floating-point linear-light output for
  later linear-light stages.
- **QIP SIMD** uses the same antialiasing and quantizes to RGBA8.
- **QIP center-sampled** uses the least memory and takes one sample per pixel,
  so edges are not antialiased.

The QIP rasterizers support a limited SVG subset: `rect` (including `rx` and
`ry`), `circle`, `line`, `path`, `polygon`, `polyline`, `text`, and `g`
elements with transforms, solid colors, linear and radial gradients,
`opacity`, `fill-opacity`, and `stroke-opacity`. Text is always drawn with
Inter Display, whatever `font-family` says. They use the `current_color_rgba`
uniform for `currentColor` instead of the CSS `color` property, ignore the
`style` attribute, approximate arcs with straight segments, and draw every
stroke with round caps and joins. Group `opacity` is applied to each child
separately, so overlapping children show through each other.

## Run with Node.js and qipx

[`qipx`](/docs/qipx) runs the same components locally:

```bash
npx @qip.dev/qipx qip.dev run -i drawing.svg \
  -F 'regular=@InterDisplay-Regular.ttf;type=font/ttf' \
  -F 'bold=@InterDisplay-Bold.ttf;type=font/ttf' \
  image/svg+xml/svg-rasterize-skia-with-fonts-to-ktx2-r8g8b8a8-srgb.wasm \
  -u width=640 -u height=400 > drawing.ktx2
```

Replace the component path to try a different rasterizer. The others take
plain SVG, so drop the `-F` fonts for them.
