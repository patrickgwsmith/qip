<title>BMP to WebP encoder</title>

# BMP to WebP encoder

Convert an uncompressed BMP to lossy or lossless WebP locally in your browser.
Three statically linked QIP components cover opaque photos, lossy transparency,
and exact lossless pixels; the image is not uploaded.

<style>
.webp-tool {
  display: grid;
  gap: 1rem;
}
.webp-tool input,
.webp-tool select,
.webp-tool button {
  font: inherit;
}
.webp-options {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
  gap: 0.75rem 1rem;
}
.webp-options label {
  display: grid;
  gap: 0.25rem;
}
.webp-mode {
  display: flex;
  flex-wrap: wrap;
  gap: 1rem;
}
.webp-mode label {
  white-space: nowrap;
}
.webp-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.webp-status {
  min-height: 1.5rem;
}
.webp-preview {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(18rem, 100%), 1fr));
  gap: 1rem;
}
.webp-preview img {
  display: block;
  max-width: 100%;
  max-height: 32rem;
  object-fit: contain;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.webp-meta {
  font-variant-numeric: tabular-nums;
}
</style>

<div class="webp-tool">
  <label>
    <strong>24-bit BGR or 32-bit BGRX/BGRA BMP</strong><br>
    <input id="webp-input" type="file" accept="image/bmp,.bmp" />
  </label>
  <p id="webp-input-meta" class="webp-meta"></p>

  <fieldset>
    <legend>Encoding</legend>
    <div class="webp-mode">
      <label><input type="radio" name="webp-mode" value="opaque" checked> Lossy, opaque</label>
      <label><input type="radio" name="webp-mode" value="lossy"> Lossy + alpha</label>
      <label><input type="radio" name="webp-mode" value="lossless"> Lossless</label>
    </div>
  </fieldset>

  <div id="webp-lossy-options" class="webp-options">
    <label>Quality (0–100)
      <input id="webp-quality" type="number" min="0" max="100" value="95">
    </label>
    <label>Method (0 fast – 6 slow)
      <input id="webp-method" type="number" min="0" max="6" value="4">
    </label>
    <label><span>YUV conversion</span>
      <select id="webp-sharp-yuv">
        <option value="1" selected>SharpYUV</option>
        <option value="0">Fast conversion</option>
      </select>
    </label>
    <label><span>Memory strategy</span>
      <select id="webp-low-memory">
        <option value="1" selected>Lower memory</option>
        <option value="0">Faster, more memory</option>
      </select>
    </label>
    <label id="webp-background-option"><span>Background for transparency</span>
      <input id="webp-background" type="color" value="#ffffff">
    </label>
  </div>

  <div id="webp-lossless-options" class="webp-options" hidden>
    <label>Compression level (0 fast – 9 slow)
      <input id="webp-level" type="number" min="0" max="9" value="6">
    </label>
  </div>

  <p id="webp-memory-note">
    Opaque encoding reserves 448 MiB of Wasm memory. Declared V5 alpha is
    composited over the selected background; legacy BI_RGB is treated as opaque.
  </p>

  <p class="webp-actions">
    <button id="webp-encode" type="button" disabled>Encode WebP</button>
    <button id="webp-cancel" type="button" disabled>Cancel</button>
    <button id="webp-download" type="button" disabled>Download WebP</button>
  </p>
  <p id="webp-status" class="webp-status" role="status"></p>

  <div class="webp-preview">
    <section id="webp-input-preview-section" hidden>
      <h2>Input</h2>
      <img id="webp-input-preview" alt="Selected BMP preview">
    </section>
    <section id="webp-output-preview-section" hidden>
      <h2>WebP output</h2>
      <img id="webp-output-preview" alt="Encoded WebP preview">
    </section>
  </div>
</div>

<script type="module">
const fileInput = document.getElementById("webp-input");
const inputMeta = document.getElementById("webp-input-meta");
const lossyOptions = document.getElementById("webp-lossy-options");
const losslessOptions = document.getElementById("webp-lossless-options");
const backgroundOption = document.getElementById("webp-background-option");
const memoryNote = document.getElementById("webp-memory-note");
const encodeButton = document.getElementById("webp-encode");
const cancelButton = document.getElementById("webp-cancel");
const downloadButton = document.getElementById("webp-download");
const status = document.getElementById("webp-status");
const inputPreviewSection = document.getElementById("webp-input-preview-section");
const outputPreviewSection = document.getElementById("webp-output-preview-section");
const inputPreview = document.getElementById("webp-input-preview");
const outputPreview = document.getElementById("webp-output-preview");

let selectedFile = null;
let selectedBMP = null;
let inputURL = "";
let outputURL = "";
let outputName = "output.webp";
let worker = null;

function selectedMode() {
  return document.querySelector('input[name="webp-mode"]:checked').value;
}

function clampInput(id, minimum, maximum) {
  const input = document.getElementById(id);
  const value = Number.parseInt(input.value, 10);
  const clamped = Math.min(maximum, Math.max(minimum, Number.isFinite(value) ? value : minimum));
  input.value = String(clamped);
  return clamped;
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}

function parseBMP(header, fileSize) {
  if (header.byteLength < 54) throw Error("The file is too short to be a BMP.");
  const bytes = new Uint8Array(header);
  const view = new DataView(header);
  if (bytes[0] !== 0x42 || bytes[1] !== 0x4d) throw Error("Choose a BMP file.");
  const pixelOffset = view.getUint32(10, true);
  const dibSize = view.getUint32(14, true);
  const width = view.getInt32(18, true);
  const signedHeight = view.getInt32(22, true);
  const height = Math.abs(signedHeight);
  const pixels = width * height;
  const bits = view.getUint16(28, true);
  const compression = view.getUint32(30, true);
  if (dibSize < 40 || pixelOffset < 54 || width <= 0 || signedHeight === 0 ||
      pixelOffset < 14 + dibSize || signedHeight === -2147483648 ||
      view.getUint16(26, true) !== 1 || (bits !== 24 && bits !== 32)) {
    throw Error("The components require an uncompressed 24-bit or 32-bit Windows BMP.");
  }
  const alphaMask = bits === 32 && dibSize >= 124 && pixelOffset >= 138
    ? view.getUint32(66, true) : 0;
  const v5Alpha = alphaMask === 0xff000000;
  const standardMasks = v5Alpha &&
    view.getUint32(54, true) === 0x00ff0000 &&
    view.getUint32(58, true) === 0x0000ff00 &&
    view.getUint32(62, true) === 0x000000ff;
  const zeroRgbMasks = v5Alpha &&
    view.getUint32(54, true) === 0 && view.getUint32(58, true) === 0 &&
    view.getUint32(62, true) === 0;
  if ((bits === 24 && compression !== 0) ||
      (bits === 32 && compression !== 0 && !(compression === 3 && standardMasks)) ||
      (compression === 0 && alphaMask !== 0 && !(standardMasks || zeroRgbMasks))) {
    throw Error("The BMP compression or channel masks are not supported.");
  }
  if (width > 8192 || height > 8192 || pixels > 25000000) {
    throw Error("The image exceeds 25 MP or 8192 pixels on one side. Resize it first.");
  }
  const stride = Math.ceil(width * bits / 32) * 4;
  if (fileSize > 25000000 * 4 + 64 * 1024 || pixelOffset + stride * height > fileSize) {
    throw Error("The BMP pixel payload is missing or its header exceeds the component capacity.");
  }
  return { width, height, pixels, bits, v5Alpha };
}

function resetOutput() {
  if (outputURL !== "") URL.revokeObjectURL(outputURL);
  outputURL = "";
  outputPreview.removeAttribute("src");
  outputPreviewSection.hidden = true;
  downloadButton.disabled = true;
}

function finish() {
  worker = null;
  encodeButton.disabled = selectedFile === null;
  cancelButton.disabled = true;
}

document.querySelectorAll('input[name="webp-mode"]').forEach((input) => {
  input.addEventListener("change", () => {
    const mode = selectedMode();
    const lossless = mode === "lossless";
    lossyOptions.hidden = lossless;
    losslessOptions.hidden = !lossless;
    backgroundOption.hidden = mode !== "opaque";
    memoryNote.textContent = mode === "lossless"
      ? "Lossless encoding reserves 1.5 GiB of Wasm memory. Alpha and RGB beneath transparent pixels are preserved exactly. Level 9 can take over a minute at 25 MP."
      : mode === "lossy"
        ? "Lossy + alpha reserves 1.1875 GiB of Wasm memory. RGB is lossy; transparency is preserved with lossless alpha compression. Method 6 is capped to 5 for transparent images."
        : "Opaque encoding reserves 448 MiB of Wasm memory. Declared V5 alpha is composited over the selected background; legacy BI_RGB is treated as opaque.";
    resetOutput();
  });
});

fileInput.addEventListener("change", async () => {
  selectedFile = null;
  selectedBMP = null;
  encodeButton.disabled = true;
  resetOutput();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  inputURL = "";
  inputPreviewSection.hidden = true;
  const file = fileInput.files?.[0];
  if (!file) {
    inputMeta.textContent = "";
    return;
  }
  try {
    const header = await file.slice(0, 64 * 1024).arrayBuffer();
    const bmp = parseBMP(header, file.size);
    selectedFile = file;
    selectedBMP = bmp;
    const alpha = bmp.v5Alpha ? " · declared alpha" : "";
    inputMeta.textContent = `${bmp.width}×${bmp.height} · ${bmp.bits}-bit${alpha} · ${(bmp.pixels / 1000000).toFixed(2)} MP · ${formatBytes(file.size)}`;
    inputURL = URL.createObjectURL(file);
    inputPreview.src = inputURL;
    inputPreviewSection.hidden = false;
    encodeButton.disabled = false;
    status.textContent = "Ready to encode.";
  } catch (error) {
    inputMeta.textContent = "";
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

encodeButton.addEventListener("click", async () => {
  if (!selectedFile || !selectedBMP || worker !== null) return;
  resetOutput();
  const mode = selectedMode();
  if (selectedBMP.bits === 24 && mode !== "opaque") {
    status.textContent = "A 24-bit BMP has no alpha channel; use the smaller lossy, opaque component.";
    return;
  }
  const inputName = selectedFile.name;
  const options = mode === "lossless" ? {
    level: clampInput("webp-level", 0, 9),
  } : {
    quality: clampInput("webp-quality", 0, 100),
    method: clampInput("webp-method", 0, 6),
    sharpYuv: document.getElementById("webp-sharp-yuv").value === "1",
    lowMemory: document.getElementById("webp-low-memory").value === "1",
    backgroundColor: Number.parseInt(
      document.getElementById("webp-background").value.slice(1), 16,
    ),
  };
  encodeButton.disabled = true;
  cancelButton.disabled = false;
  status.textContent = `Encoding ${mode} WebP in a worker…`;
  try {
    const input = await selectedFile.arrayBuffer();
    worker = new Worker("/webp-worker.js", { type: "module" });
    worker.onmessage = (event) => {
      if (event.data.type === "error") {
        status.textContent = event.data.message +
          " A 64-bit desktop browser may be required to reserve this mode's fixed Wasm memory.";
        finish();
        return;
      }
      const output = new Uint8Array(event.data.output);
      outputURL = URL.createObjectURL(new Blob([output], { type: "image/webp" }));
      outputPreview.src = outputURL;
      outputPreviewSection.hidden = false;
      downloadButton.disabled = false;
      outputName = inputName.replace(/\.bmp$/i, "") + `-${mode}.webp`;
      status.textContent = `${formatBytes(output.length)} WebP ready in ${(event.data.elapsedMs / 1000).toFixed(2)} s · encoder peak ${formatBytes(event.data.peakBytes)} · ${event.data.allocations} allocations.`;
      finish();
    };
    worker.onerror = (event) => {
      status.textContent = event.message || "The WebP worker failed.";
      finish();
    };
    worker.postMessage({ input, mode, options }, [input]);
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
    worker?.terminate();
    finish();
  }
});

cancelButton.addEventListener("click", () => {
  worker?.terminate();
  finish();
  status.textContent = "Encoding cancelled.";
});

downloadButton.addEventListener("click", () => {
  if (outputURL === "") return;
  const link = document.createElement("a");
  link.href = outputURL;
  link.download = outputName;
  link.click();
});

addEventListener("beforeunload", () => {
  worker?.terminate();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  if (outputURL !== "") URL.revokeObjectURL(outputURL);
});
</script>

All three components accept at most 25,000,000 pixels and 8192 pixels on either
side. Opaque mode accepts 24-bit `BI_RGB`, 32-bit `BI_RGB` BGRX, and explicitly
masked V5 BGRA; declared alpha is flattened over the selected background.
The alpha-preserving modes require 32-bit pixels. Opaque lossy mode is the
better default for photographs, while lossless mode is intended for pixels
that must round-trip exactly. Resize larger camera originals before encoding.

The worker is discarded after every encode. This releases its fixed Wasm
memory instead of keeping a 448 MiB, 1.1875 GiB, or 1.5 GiB instance attached
to the page.

## Components

- <a href="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm" download>bmp-b8g8r8a8-srgb-to-webp-lossy.wasm</a> — <qip-content-size src="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm"></qip-content-size>
- <a href="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm" download>bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm</a> — <qip-content-size src="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm"></qip-content-size>
- <a href="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm" download>bmp-b8g8r8a8-srgb-to-webp-lossless.wasm</a> — <qip-content-size src="/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm"></qip-content-size>

## CLI equivalent

```bash
qip run image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm \
  -u quality=95 -u method=4 -u sharp_yuv=1 -u low_memory=1 \
  -u background_color_rgb=0xffffff \
  < input.bmp > output.webp

qip run image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm \
  -u quality=95 -u method=4 -u sharp_yuv=1 -u low_memory=1 \
  < input.bmp > output.webp

qip run image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm -u level=6 \
  < input.bmp > output.webp
```
