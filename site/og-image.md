<title>Open Graph image maker</title>

# Open Graph image maker

Create social media images locally in your browser. Share the link. Nothing is
uploaded.

<style>
.og-form {
  display: grid;
  gap: 1rem;
  margin-block: 1.5rem;
}
.og-fields {
  display: grid;
  gap: 1rem;
}
@media (min-width: 720px) {
  .og-fields { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
.og-field {
  display: grid;
  gap: 0.35rem;
}
.og-field textarea {
  box-sizing: border-box;
  width: 100%;
  font: inherit;
  min-height: 6rem;
  resize: vertical;
}
.og-options {
  display: flex;
  flex-wrap: wrap;
  gap: 2rem;
}
.og-option {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.og-option input[type="color"] {
  width: 3rem;
  height: 2.25rem;
  padding: 0.1rem;
}
.og-previews {
  display: grid;
  gap: 1.5rem;
}
@media (min-width: 960px) {
  .og-previews { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
.og-preview {
  margin: 0;
}
.og-preview img {
  display: block;
  width: 100%;
  aspect-ratio: 1200 / 630;
  border: 1px solid color-mix(in srgb, currentColor 22%, transparent);
  background: #eee;
}
.og-preview figcaption {
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  margin-top: 0.5rem;
}
.og-downloads {
  display: grid;
  margin: 0;
  padding: 0;
  list-style: none;
  text-align: right;
}
.og-downloads button {
  appearance: none;
  border: 0;
  padding: 0;
  color: inherit;
  background: transparent;
  font: inherit;
  text-decoration: underline;
  cursor: pointer;
}
.og-downloads button:disabled {
  cursor: wait;
  opacity: 0.65;
}
.og-status {
  min-height: 1.5rem;
}
</style>

<form id="og-form" class="og-form">
  <fieldset class="og-fields">
    <label class="og-field">
      <strong>Title</strong>
      <textarea name="title">Reusable components make Open Graph images easier</textarea>
    </label>
    <label class="og-field">
      <strong>Subtitle</strong>
      <textarea name="subtitle">Rendered locally with embedded font paths</textarea>
    </label>
  </fieldset>
  <fieldset class="og-options">
    <label class="og-option">Text color <input id="og-text-color" type="color" value="#ffffff" /></label>
    <label class="og-option">Background color <input id="og-background-color" type="color" value="#4b2e83" /></label>
    <label class="og-option">Font size <input id="og-font-max-size" type="number" value="112" min="32" max="160" step="2" inputmode="numeric" /> px</label>
    <label class="og-option">Font weight
      <select id="og-font-weight">
        <option value="700" selected>Bold</option>
        <option value="400">Regular</option>
      </select>
    </label>
  </fieldset>
</form>

<div class="og-previews">
  <figure class="og-preview">
    <img id="og-inter" alt="Open Graph image preview rendered with Inter Display" />
    <figcaption>
      <strong>Inter Display</strong>
      <ul class="og-downloads">
        <li><button type="button" data-preview="0" data-download="svg">Download SVG</button></li>
        <li><button type="button" data-preview="0" data-download="png">Download PNG</button></li>
        <li><button type="button" data-preview="0" data-download="webp">Download WebP</button></li>
      </ul>
    </figcaption>
  </figure>
  <figure class="og-preview">
    <img id="og-dejavu" alt="Open Graph image preview rendered with DejaVu Sans Mono" />
    <figcaption>
      <strong>DejaVu Sans Mono</strong>
      <ul class="og-downloads">
        <li><button type="button" data-preview="1" data-download="svg">Download SVG</button></li>
        <li><button type="button" data-preview="1" data-download="png">Download PNG</button></li>
        <li><button type="button" data-preview="1" data-download="webp">Download WebP</button></li>
      </ul>
    </figcaption>
  </figure>
</div>

<p id="og-status" class="og-status" role="status" aria-live="polite"></p>

<script type="module">
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function renderOutput(exports, inputSize) {
  const result = BigInt.asUintN(64, exports.render(inputSize));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  return {
    size: Number(result & 0xffff_ffffn),
    ptr: Number((result >> 32n) & 0x7fff_ffffn),
  };
}
const form = document.getElementById("og-form");
const textColor = document.getElementById("og-text-color");
const backgroundColor = document.getElementById("og-background-color");
const fontMaxSize = document.getElementById("og-font-max-size");
const fontWeight = document.getElementById("og-font-weight");
const status = document.getElementById("og-status");
const titleInput = form.elements.namedItem("title");
const subtitleInput = form.elements.namedItem("subtitle");
const rasterComponentURLs = {
  svg: "/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm",
  png: "/image/bmp/bmp-to-png.wasm",
  webp: "/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm",
};
const rasterComponents = new Map();

const initialState = new URLSearchParams(location.search);
if (initialState.has("title")) titleInput.value = initialState.get("title");
if (initialState.has("subtitle")) subtitleInput.value = initialState.get("subtitle");
for (const [name, input] of [
  ["text_color_rgba", textColor],
  ["background_color_rgba", backgroundColor],
]) {
  const value = initialState.get(name);
  if (value && /^#?[0-9a-f]{6}$/i.test(value)) {
    input.value = value.startsWith("#") ? value : `#${value}`;
  }
}
const initialFontMaxSize = Number(initialState.get("font_max_size"));
if (Number.isInteger(initialFontMaxSize) && initialFontMaxSize >= 32 && initialFontMaxSize <= 160) {
  fontMaxSize.value = String(initialFontMaxSize);
}
const initialFontWeight = initialState.get("font_weight");
if (initialFontWeight === "400" || initialFontWeight === "700") {
  fontWeight.value = initialFontWeight;
}

const previews = [
  {
    name: "og-image-inter",
    url: "/text/text-to-og-image-svg-inter.wasm",
    image: document.getElementById("og-inter"),
    objectURL: null,
    svg: null,
  },
  {
    name: "og-image-dejavu-sans-mono",
    url: "/text/text-to-og-image-svg-dejavu-sans-mono.wasm",
    image: document.getElementById("og-dejavu"),
    objectURL: null,
    svg: null,
  },
];

function rgba(color) {
  return Number.parseInt(color.slice(1), 16) * 256 + 255;
}

function selectedMaxFontSize() {
  if (fontMaxSize.value === "") return 112;
  const value = Number(fontMaxSize.value);
  return Number.isFinite(value) ? Math.min(160, Math.max(32, Math.round(value))) : 112;
}

function renderSVG(exports, input) {
  const inputBuffer = new Uint8Array(
    exports.memory.buffer,
    exports.input_ptr(),
    exports.input_utf8_cap(),
  );
  const { read, written } = encoder.encodeInto(input, inputBuffer);
  if (read !== input.length) throw Error("Form data is too long.");
  exports.uniform_set_text_color_rgba(rgba(textColor.value));
  exports.uniform_set_background_color_rgba(rgba(backgroundColor.value));
  exports.uniform_set_font_max_size(selectedMaxFontSize());
  exports.uniform_set_font_weight(Number(fontWeight.value));
  const output = renderOutput(exports, written);
  return decoder.decode(new Uint8Array(exports.memory.buffer, output.ptr, output.size));
}

function showSVG(preview, svg) {
  if (preview.objectURL) URL.revokeObjectURL(preview.objectURL);
  preview.objectURL = URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
  preview.image.src = preview.objectURL;
  preview.svg = svg;
}

function loadRasterComponent(url) {
  let component = rasterComponents.get(url);
  if (!component) {
    component = WebAssembly.instantiateStreaming(fetch(url)).then(
      ({ instance }) => instance.exports,
    );
    rasterComponents.set(url, component);
  }
  return component;
}

async function rasterBytes(svg, format) {
  const [svgRasterizer, imageEncoder] = await Promise.all([
    loadRasterComponent(rasterComponentURLs.svg),
    loadRasterComponent(rasterComponentURLs[format]),
  ]);
  const svgInput = new Uint8Array(
    svgRasterizer.memory.buffer,
    svgRasterizer.input_ptr(),
    svgRasterizer.input_utf8_cap(),
  );
  const { read, written } = encoder.encodeInto(svg, svgInput);
  if (read !== svg.length) throw new RangeError("The SVG is too large to rasterize.");
  const bmpOutput = renderOutput(svgRasterizer, written);
  if (bmpOutput.size > svgRasterizer.output_bytes_cap()) {
    throw new RangeError("The rasterized BMP is too large.");
  }
  const bmp = new Uint8Array(
    svgRasterizer.memory.buffer,
    bmpOutput.ptr,
    bmpOutput.size,
  );
  if (bmp.length > imageEncoder.input_bytes_cap()) {
    throw new RangeError("The BMP is too large to encode.");
  }
  new Uint8Array(
    imageEncoder.memory.buffer,
    imageEncoder.input_ptr(),
    bmp.length,
  ).set(bmp);
  const output = renderOutput(imageEncoder, bmp.length);
  if (output.size > imageEncoder.output_bytes_cap()) {
    throw new RangeError(`The ${format.toUpperCase()} output is too large.`);
  }
  return new Uint8Array(
    imageEncoder.memory.buffer,
    output.ptr,
    output.size,
  ).slice();
}

function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

async function downloadRaster(button) {
  const preview = previews[Number(button.dataset.preview)];
  const format = button.dataset.download;
  if (!preview?.svg || (format !== "png" && format !== "webp")) return;
  const label = button.textContent;
  button.disabled = true;
  button.textContent = "Rendering…";
  status.textContent = "";
  try {
    const bytes = await rasterBytes(preview.svg, format);
    const blob = new Blob([bytes], { type: `image/${format}` });
    downloadBlob(blob, `${preview.name}.${format}`);
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

let renderers;
let frame;
let urlTimer;
async function update() {
  frame = undefined;
  try {
    renderers ??= await Promise.all(previews.map(async (preview) => {
      const module = await WebAssembly.compileStreaming(fetch(preview.url));
      return new WebAssembly.Instance(module, {}).exports;
    }));
    const values = new FormData(form);
    const payload = new URLSearchParams({
      title: String(values.get("title") ?? ""),
      subtitle: String(values.get("subtitle") ?? ""),
    }).toString();
    for (let index = 0; index < previews.length; index += 1) {
      showSVG(previews[index], renderSVG(renderers[index], payload));
    }
    status.textContent = "";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

function scheduleUpdate() {
  if (frame === undefined) frame = requestAnimationFrame(update);
  clearTimeout(urlTimer);
  urlTimer = setTimeout(replaceURLState, 1000);
}

function replaceURLState() {
  fontMaxSize.value = String(selectedMaxFontSize());
  const url = new URL(location.href);
  url.searchParams.set("title", titleInput.value);
  url.searchParams.set("subtitle", subtitleInput.value);
  url.searchParams.set("text_color_rgba", textColor.value);
  url.searchParams.set("background_color_rgba", backgroundColor.value);
  url.searchParams.set("font_max_size", fontMaxSize.value);
  url.searchParams.set("font_weight", fontWeight.value);
  history.replaceState(null, "", url);
}

form.addEventListener("submit", (event) => event.preventDefault());
form.addEventListener("input", scheduleUpdate);
for (const button of document.querySelectorAll("[data-download]")) {
  button.addEventListener("click", () => {
    const preview = previews[Number(button.dataset.preview)];
    if (!preview?.svg) return;
    if (button.dataset.download === "svg") {
      downloadBlob(new Blob([preview.svg], { type: "image/svg+xml" }), `${preview.name}.svg`);
    } else {
      downloadRaster(button);
    }
  });
}
window.addEventListener("pagehide", () => {
  clearTimeout(urlTimer);
  for (const preview of previews) {
    if (preview.objectURL) URL.revokeObjectURL(preview.objectURL);
  }
});
update();
</script>

## Download

- <a href="/text/text-to-og-image-svg-inter.wasm" download>text-to-og-image-svg-inter.wasm</a> — <qip-content-size src="/text/text-to-og-image-svg-inter.wasm"></qip-content-size>
- <a href="/text/text-to-og-image-svg-dejavu-sans-mono.wasm" download>text-to-og-image-svg-dejavu-sans-mono.wasm</a> — <qip-content-size src="/text/text-to-og-image-svg-dejavu-sans-mono.wasm"></qip-content-size>
- <a href="/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm" download>svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm</a> — <qip-content-size src="/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm"></qip-content-size>
- <a href="/image/bmp/bmp-to-png.wasm" download>bmp-to-png.wasm</a> — <qip-content-size src="/image/bmp/bmp-to-png.wasm"></qip-content-size>
- <a href="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm" download>bmp-b8g8r8a8-srgb-to-webp-lossless.wasm</a> — <qip-content-size src="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm"></qip-content-size>

## JavaScript

This ES module uses static WebAssembly instance imports and includes SVG, PNG,
and WebP output. Remove imports and output calls that your application does not use.

<copy-code>

```js
// Both font components accept application/x-www-form-urlencoded. The `title`
// field must be present but may be empty; `subtitle` is optional. Input is
// limited to 4 KiB, each field to 2 KiB, and each field to 16 wrapped lines.
//
// The renderers support Latin-1 from U+0020 through U+00FF, except soft hyphen
// U+00AD. They do not provide bidirectional layout, hyphenation, or font
// fallback. Inter is proportional and applies pair kerning. DejaVu is monospaced.
//
// Output is a self-contained 1200x630 SVG made from paths. The viewer does not
// need the font. Choose one font component:
import * as ogImageRenderer from "./text-to-og-image-svg-inter.wasm";
// import * as ogImageRenderer from "./text-to-og-image-svg-dejavu-sans-mono.wasm";

// The SVG rasterizer produces a BGRA BMP. The other two components encode that
// BMP as PNG or lossless WebP. Remove imports and calls for formats you do not use.
import * as svgRasterizer from "./svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm";
import * as pngEncoder from "./bmp-to-png.wasm";
// This lossless WebP encoder reserves 1.5 GiB of Wasm memory when imported.
import * as webpEncoder from "./bmp-b8g8r8a8-srgb-to-webp-lossless.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function renderOutput(exports, inputSize) {
  const result = BigInt.asUintN(64, exports.render(inputSize));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  return {
    size: Number(result & 0xffff_ffffn),
    ptr: Number((result >> 32n) & 0x7fff_ffffn),
  };
}

export function renderOGImageToSVG({
  title = "",
  subtitle = "",
  textColor = 0xffffffff,
  backgroundColor = 0x4b2e83ff,
  fontMaxSize = 112,
  fontWeight = 700,
} = {}) {
  const form = new URLSearchParams({ title, subtitle }).toString();
  const input = new Uint8Array(
    ogImageRenderer.memory.buffer,
    ogImageRenderer.input_ptr(),
    ogImageRenderer.input_utf8_cap(),
  );
  const { read, written } = encoder.encodeInto(form, input);
  if (read !== form.length) {
    throw new RangeError("Open Graph image input is too large");
  }
  ogImageRenderer.uniform_set_text_color_rgba(textColor);
  ogImageRenderer.uniform_set_background_color_rgba(backgroundColor);
  ogImageRenderer.uniform_set_font_max_size(fontMaxSize);
  ogImageRenderer.uniform_set_font_weight(fontWeight);

  const output = renderOutput(ogImageRenderer, written);
  if (output.size > ogImageRenderer.output_utf8_cap()) {
    throw new RangeError("Open Graph image output is too large");
  }
  return decoder.decode(new Uint8Array(
    ogImageRenderer.memory.buffer,
    output.ptr,
    output.size,
  ));
}

export function renderOGImageToPNG(options) {
  const svg = renderOGImageToSVG(options);
  const input = new Uint8Array(
    svgRasterizer.memory.buffer,
    svgRasterizer.input_ptr(),
    svgRasterizer.input_utf8_cap(),
  );
  const { read, written } = encoder.encodeInto(svg, input);
  if (read !== svg.length) {
    throw new RangeError("Open Graph SVG is too large to rasterize");
  }
  const bmpOutput = renderOutput(svgRasterizer, written);
  if (bmpOutput.size > svgRasterizer.output_bytes_cap()) {
    throw new RangeError("Open Graph BMP output is too large");
  }
  const bmp = new Uint8Array(
    svgRasterizer.memory.buffer,
    bmpOutput.ptr,
    bmpOutput.size,
  );
  if (bmp.length > pngEncoder.input_bytes_cap()) {
    throw new RangeError("Open Graph BMP input is too large");
  }
  new Uint8Array(
    pngEncoder.memory.buffer,
    pngEncoder.input_ptr(),
    bmp.length,
  ).set(bmp);
  const pngOutput = renderOutput(pngEncoder, bmp.length);
  if (pngOutput.size > pngEncoder.output_bytes_cap()) {
    throw new RangeError("Open Graph PNG output is too large");
  }
  return new Uint8Array(
    pngEncoder.memory.buffer,
    pngOutput.ptr,
    pngOutput.size,
  ).slice();
}

export function renderOGImageToWebp(options) {
  const svg = renderOGImageToSVG(options);
  const input = new Uint8Array(
    svgRasterizer.memory.buffer,
    svgRasterizer.input_ptr(),
    svgRasterizer.input_utf8_cap(),
  );
  const { read, written } = encoder.encodeInto(svg, input);
  if (read !== svg.length) {
    throw new RangeError("Open Graph SVG is too large to rasterize");
  }
  const bmpOutput = renderOutput(svgRasterizer, written);
  if (bmpOutput.size > svgRasterizer.output_bytes_cap()) {
    throw new RangeError("Open Graph BMP output is too large");
  }
  const bmp = new Uint8Array(
    svgRasterizer.memory.buffer,
    bmpOutput.ptr,
    bmpOutput.size,
  );
  if (bmp.length > webpEncoder.input_bytes_cap()) {
    throw new RangeError("Open Graph BMP input is too large");
  }
  new Uint8Array(
    webpEncoder.memory.buffer,
    webpEncoder.input_ptr(),
    bmp.length,
  ).set(bmp);
  const webpOutput = renderOutput(webpEncoder, bmp.length);
  if (webpOutput.size > webpEncoder.output_bytes_cap()) {
    throw new RangeError("Open Graph WebP output is too large");
  }
  return new Uint8Array(
    webpEncoder.memory.buffer,
    webpOutput.ptr,
    webpOutput.size,
  ).slice();
}

const options = {
  title: "Reusable components",
  subtitle: "Rendered locally with embedded Inter paths",
  textColor: 0xffffffff,
  backgroundColor: 0x4b2e83ff,
  fontMaxSize: 112,
  fontWeight: 700,
};

const svg = renderOGImageToSVG(options);
const png = renderOGImageToPNG(options);
const webp = renderOGImageToWebp(options);

console.log({ svg, png, webp });
```

</copy-code>
