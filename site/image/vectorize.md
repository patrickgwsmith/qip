<title>Vectorize image</title>

# Vectorize image

Convert flat PNG, JPEG, WebP, AVIF, or canonical KTX2 artwork into an SVG in
your browser. Files are not uploaded. The tool first decodes the image to
canonical RGBA8 sRGB KTX2, then traces connected color regions as grid-aligned
SVG paths.

<style>
.vectorize-tool {
  display: grid;
  gap: 1rem;
}
.vectorize-tool input,
.vectorize-tool button {
  font: inherit;
}
.vectorize-options,
.vectorize-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: end;
}
.vectorize-options label {
  display: grid;
  gap: 0.25rem;
}
.vectorize-options input {
  box-sizing: border-box;
  width: 9rem;
}
.vectorize-preview {
  display: block;
  max-width: min(32rem, 100%);
  max-height: 32rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
  background: repeating-conic-gradient(#ddd 0 25%, #fff 0 50%) 50% / 1rem 1rem;
  image-rendering: pixelated;
}
.vectorize-status {
  min-height: 1.5rem;
  margin: 0;
}
</style>

<div class="vectorize-tool">
  <label>
    <strong>Image</strong><br>
    <input id="vectorize-input" type="file" accept="image/png,image/jpeg,image/webp,image/avif,image/ktx2,.png,.jpg,.jpeg,.webp,.avif,.ktx2" />
  </label>
  <div class="vectorize-options">
    <label>Colors
      <input id="vectorize-colors" type="number" min="1" max="8" step="1" value="8" />
    </label>
    <label>Alpha threshold
      <input id="vectorize-alpha" type="number" min="1" max="255" step="1" value="128" />
    </label>
  </div>
  <div class="vectorize-actions">
    <button id="vectorize-run" type="button">Vectorize</button>
    <button id="vectorize-download" type="button" disabled>Download SVG</button>
  </div>
  <p id="vectorize-status" class="vectorize-status" role="status" aria-live="polite"></p>
  <img id="vectorize-preview" class="vectorize-preview" alt="Generated SVG preview" hidden />
</div>

<script type="module">
const input = document.getElementById("vectorize-input");
const colors = document.getElementById("vectorize-colors");
const alpha = document.getElementById("vectorize-alpha");
const runButton = document.getElementById("vectorize-run");
const downloadButton = document.getElementById("vectorize-download");
const status = document.getElementById("vectorize-status");
const preview = document.getElementById("vectorize-preview");

const vectorizerURL = "/image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm";
const resizeURL = "/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm";
const maxVectorPixels = 8_000_000;
const decoderURLs = {
  png: "/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
  jpeg: "/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm",
  webp: "/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm",
  avif: "/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm",
};
const modules = new Map();
let downloadURL = "";
let outputName = "vectorized.svg";

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
  }
  return module;
}

function renderBytes(module, source, configure) {
  const exports = new WebAssembly.Instance(module).exports;
  const inputCap = readExport(exports, "input_bytes_cap");
  if (source.length > inputCap) throw Error(`Image exceeds this stage's ${inputCap.toLocaleString()} byte input limit.`);
  const inputPtr = readExport(exports, "input_ptr");
  const memory = new Uint8Array(exports.memory.buffer);
  if (inputPtr + source.length > memory.length) throw Error("Component input buffer is outside Wasm memory.");
  memory.set(source, inputPtr);
  configure?.(exports);

  const bits = BigInt.asUintN(64, exports.render(source.length));
  if ((bits & (1n << 63n)) !== 0n) throw Error("This image is unsupported or exceeds the vectorizer's complexity limit.");
  const size = Number(bits & 0xffff_ffffn);
  const outputPtr = Number((bits >> 32n) & 0x7fff_ffffn);
  const outputCap = typeof exports.output_utf8_cap === "function"
    ? readExport(exports, "output_utf8_cap")
    : readExport(exports, "output_bytes_cap");
  if (size > outputCap || outputPtr + size > exports.memory.buffer.byteLength) {
    throw Error("Component returned output outside its declared buffer.");
  }
  return new Uint8Array(exports.memory.buffer, outputPtr, size).slice();
}

function imageKind(file) {
  const extension = file.name.split(".").pop()?.toLowerCase();
  if (file.type === "image/ktx2" || extension === "ktx2") return "ktx2";
  if (file.type === "image/png" || extension === "png") return "png";
  if (file.type === "image/jpeg" || extension === "jpg" || extension === "jpeg") return "jpeg";
  if (file.type === "image/webp" || extension === "webp") return "webp";
  if (file.type === "image/avif" || extension === "avif") return "avif";
  return "";
}

function selectedInteger(field, label, minimum, maximum) {
  const value = Number(field.value);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw Error(`${label} must be an integer from ${minimum} through ${maximum}.`);
  }
  return value;
}

function ktx2Dimensions(bytes) {
  if (bytes.length < 28) throw Error("Decoder did not return a complete KTX2 image.");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const width = view.getUint32(20, true);
  const height = view.getUint32(24, true);
  if (width === 0 || height === 0) throw Error("KTX2 dimensions must be positive.");
  return { width, height };
}

function vectorDimensions(width, height) {
  const scale = Math.sqrt(maxVectorPixels / (width * height));
  return {
    width: Math.max(1, Math.floor(width * scale)),
    height: Math.max(1, Math.floor(height * scale)),
  };
}

function replacePreview(svg) {
  if (downloadURL !== "") URL.revokeObjectURL(downloadURL);
  downloadURL = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
  preview.src = downloadURL;
  preview.hidden = false;
  downloadButton.disabled = false;
}

runButton.addEventListener("click", async () => {
  const file = input.files?.[0];
  if (!file) {
    status.textContent = "Choose a PNG, JPEG, WebP, AVIF, or KTX2 image first.";
    return;
  }
  try {
    const kind = imageKind(file);
    if (kind === "") throw Error("Choose a PNG, JPEG, WebP, AVIF, or KTX2 image.");
    const selectedColors = selectedInteger(colors, "Colors", 1, 8);
    const selectedAlpha = selectedInteger(alpha, "Alpha threshold", 1, 255);
    runButton.disabled = true;
    downloadButton.disabled = true;
    status.textContent = "Vectorizing locally…";

    const source = new Uint8Array(await file.arrayBuffer());
    let ktx2 = kind === "ktx2"
      ? source
      : renderBytes(await loadModule(decoderURLs[kind]), source);
    const sourceDimensions = ktx2Dimensions(ktx2);
    let resized = "";
    if (sourceDimensions.width * sourceDimensions.height > maxVectorPixels) {
      const target = vectorDimensions(sourceDimensions.width, sourceDimensions.height);
      ktx2 = renderBytes(await loadModule(resizeURL), ktx2, (exports) => {
        exports.uniform_set_width(target.width);
        exports.uniform_set_height(target.height);
      });
      resized = ` Reduced ${sourceDimensions.width}×${sourceDimensions.height} to ${target.width}×${target.height} before tracing.`;
    }
    const svgBytes = renderBytes(await loadModule(vectorizerURL), ktx2, (exports) => {
      exports.uniform_set_colors(selectedColors);
      exports.uniform_set_alpha_threshold(selectedAlpha);
    });
    const svg = new TextDecoder("utf-8", { fatal: true }).decode(svgBytes);
    replacePreview(svg);
    outputName = `${file.name.replace(/\.[^.]*$/, "") || "vectorized"}.svg`;
    status.textContent = `SVG ready (${svgBytes.length.toLocaleString()} bytes).${resized}`;
  } catch (error) {
    preview.hidden = true;
    status.textContent = error instanceof Error ? error.message : String(error);
  } finally {
    runButton.disabled = false;
  }
});

downloadButton.addEventListener("click", () => {
  if (downloadURL === "") return;
  const link = document.createElement("a");
  link.href = downloadURL;
  link.download = outputName;
  link.click();
});
</script>

## What it produces

The component reduces retained pixels to one through eight representative RGB
colors, groups 4-connected pixels of each color, and traces their outer edges
and holes. It emits only grid-aligned `M`, `H`, `V`, and `Z` path commands.
The result is deterministic and preserves the source dimensions, but it is not
a smooth curve tracer.

`Colors` controls the number of retained palette colors. `Alpha threshold`
controls transparency: pixels below the threshold are omitted, while retained
pixels become opaque in the SVG. The tracing component accepts at most eight
million pixels. The browser tool reduces larger inputs to that limit before
tracing and reports the resulting dimensions. The component also rejects paths
or SVG output that exceed its fixed limits.

## When to use it

Use it for small logos, pixel art, flat diagrams, and icons with large color
regions. It can make an editable SVG that remains recognizably close to the
source.

Do not use it for photos, gradients, shadows, or anti-aliased illustrations.
Palette reduction turns those details into many stepped regions; the SVG can
be larger than the raster source or be rejected by the component limit.

## Run with Node.js and qipx

[`qipx`](/docs/qipx) is the Node.js Content-component host. For a PNG, it
downloads missing components from `qip.dev` once, validates them, and then runs
the decoder and vectorizer as one local pipeline:

```bash
npx @qip.dev/qipx qip.dev run \
  image/png/png-to-ktx2-r8g8b8a8-srgb.wasm \
  image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm \
  -u colors=6 -u alpha_threshold=128 \
  < badge.png > badge.svg
```

Replace the PNG decoder with the JPEG, WebP, or AVIF KTX2 decoder for those
formats. A canonical RGBA8 sRGB KTX2 can start at the vectorizer stage. Use
Node.js 22 or later for qipx.

## Component

- <a href="/image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm" download>ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm</a> — <qip-content-size src="/image/ktx2/ktx2-r8g8b8a8-srgb-vectorize-to-svg.wasm"></qip-content-size>
