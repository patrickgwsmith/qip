<title>Image compressor</title>

# Image compressor

Compress images locally in your browser. Nothing is uploaded.

<style>
.image-compress-tool {
  display: grid;
  gap: 1rem;
}
.image-compress-tool input,
.image-compress-tool button {
  font: inherit;
}
.image-compress-formats {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem 1.25rem;
  margin: 0;
  padding: 0.75rem 1rem;
}
.image-compress-formats label {
  white-space: nowrap;
}
#image-compress-input {
  box-sizing: border-box;
  width: 100%;
}
.image-compress-meta,
.image-compress-status {
  min-height: 1.5rem;
  font-variant-numeric: tabular-nums;
}
.image-compress-note {
  max-width: 62rem;
}
.image-compress-original {
  max-width: min(100%, 42rem);
}
.image-compress-original img {
  display: block;
  max-width: 100%;
  max-height: 32rem;
  object-fit: contain;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.image-compress-results {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(24rem, 100%), 1fr));
  gap: 1rem;
  align-items: start;
}
.image-compress-codec {
  display: grid;
  gap: 0.75rem;
}
.image-compress-codec h2 {
  margin: 0;
  text-align: center;
}
.image-compress-quality-list {
  display: grid;
  gap: 0.75rem;
}
.image-compress-quality-button {
  justify-self: center;
}
.image-compress-card {
  display: grid;
  gap: 0.75rem;
  padding: 1rem;
  border: 1px solid color-mix(in srgb, currentColor 22%, transparent);
  border-radius: 0.35rem;
}
.image-compress-card h2,
.image-compress-card p {
  margin: 0;
}
.image-compress-card-heading {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.75rem;
}
.image-compress-preview {
  overflow: hidden;
  max-height: 32rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
  background: repeating-conic-gradient(#ddd 0 25%, #fff 0 50%) 50% / 1rem 1rem;
  cursor: zoom-in;
}
.image-compress-preview img {
  display: block;
  width: 100%;
  max-height: 32rem;
  object-fit: contain;
  border: 0;
  transition: transform 120ms ease;
  transform-origin: 0 0;
}
.image-compress-preview:hover img {
  transform: scale(var(--image-compress-zoom, 1));
}
.image-compress-size {
  font-size: 1.15rem;
  font-weight: 700;
}
.image-compress-empty {
  padding: 1rem;
  border: 1px dashed color-mix(in srgb, currentColor 30%, transparent);
}
</style>

<div class="image-compress-tool">
  <fieldset class="image-compress-formats">
    <legend><strong>Output formats</strong></legend>
    <label><input type="checkbox" name="image-compress-codec" value="webp" checked> WebP</label>
    <label><input type="checkbox" name="image-compress-codec" value="avif" checked> AVIF</label>
    <label><input type="checkbox" name="image-compress-codec" value="jpeg"> JPEG</label>
  </fieldset>
  <label>
    <strong>Select a JPEG, PNG, WebP or AVIF image.</strong><br>
    <input id="image-compress-input" type="file"
      accept="image/jpeg,image/png,image/webp,image/avif,.jpg,.jpeg,.png,.webp,.avif" />
  </label>
  <p id="image-compress-input-meta" class="image-compress-meta"></p>

  <p id="image-compress-status" class="image-compress-status" role="status" aria-live="polite"></p>

  <section id="image-compress-original" class="image-compress-original" hidden>
    <h2>Original image</h2>
    <img id="image-compress-original-preview" alt="Preview of the original image">
  </section>

  <div id="image-compress-results" class="image-compress-results" hidden></div>
  <p id="image-compress-empty" class="image-compress-empty">
    Select an image to start.
  </p>
</div>

<script type="module">
const MAX_AVIF_PIXELS = 12_000_000;
const IMAGE_EDGE_BUFFER = 8;
const QUALITY = { initial: 40, step: 10, min: 5, max: 90 };

const fileInput = document.getElementById("image-compress-input");
const inputMeta = document.getElementById("image-compress-input-meta");
const status = document.getElementById("image-compress-status");
const originalSection = document.getElementById("image-compress-original");
const originalPreview = document.getElementById("image-compress-original-preview");
const resultsElement = document.getElementById("image-compress-results");
const emptyElement = document.getElementById("image-compress-empty");
const codecInputs = [...document.querySelectorAll('input[name="image-compress-codec"]')];

let selectedFile = null;
let selectedFormat = null;
let inputURL = "";
let decoderWorker = null;
let decoded = null;
let runToken = 0;
let pendingJobs = 0;
const workers = new Map();
const scheduled = new Set();
const results = new Map();
const resultURLs = new Map();

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}

function fileFormat(file) {
  if (file.type === "image/jpeg" || /\.jpe?g$/i.test(file.name)) return "jpeg";
  if (file.type === "image/png" || /\.png$/i.test(file.name)) return "png";
  if (file.type === "image/webp" || /\.webp$/i.test(file.name)) return "webp";
  if (file.type === "image/avif" || /\.avif$/i.test(file.name)) return "avif";
  return null;
}

function formatName(format) {
  return { avif: "AVIF", jpeg: "JPEG", png: "PNG", webp: "WebP" }[format] ?? format;
}

function codecName(codec) {
  return { avif: "AVIF", jpeg: "JPEG", webp: "WebP" }[codec] ?? codec;
}

function codecMime(codec) {
  return { avif: "image/avif", jpeg: "image/jpeg", webp: "image/webp" }[codec];
}

function selectedCodecs() {
  return codecInputs.filter((input) => input.checked).map((input) => input.value);
}

function formatNames(codecs) {
  const names = codecs.map(codecName);
  if (names.length < 2) return names[0] ?? "";
  return `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

function jobKey(codec, quality) {
  return `${codec}:${quality}`;
}

function clearResults() {
  for (const url of resultURLs.values()) URL.revokeObjectURL(url);
  resultURLs.clear();
  results.clear();
  scheduled.clear();
  resultsElement.replaceChildren();
  resultsElement.hidden = true;
  emptyElement.hidden = false;
}

function terminateWorkers() {
  decoderWorker?.terminate();
  decoderWorker = null;
  for (const state of workers.values()) state.worker.terminate();
  workers.clear();
  pendingJobs = 0;
}

function resetRun() {
  runToken += 1;
  terminateWorkers();
  clearResults();
  decoded = null;
}

function setIdleStatus() {
  if (pendingJobs !== 0) return;
  const available = [...workers.values()].filter((state) => !state.failed).length;
  const unavailable = [...workers.entries()]
    .filter(([, state]) => state.failed)
    .map(([codec]) => codecName(codec));
  if (available === 0) {
    status.textContent = "The tool could not start an encoder.";
  } else if (results.size !== 0) {
    const suffix = unavailable.length === 0
      ? ""
      : ` ${unavailable.join(" and ")} ${unavailable.length === 1 ? "is" : "are"} not available.`;
    status.textContent = `The first results are ready.${suffix} Use the buttons to test other quality settings.`;
  }
}

function failCodec(codec, error) {
  const state = workers.get(codec);
  if (!state || state.failed) return;
  state.failed = true;
  state.worker.terminate();
  pendingJobs -= state.queued.size;
  state.queued.clear();
  const detail = error instanceof Error ? error.message : String(error);
  status.textContent = `${codecName(codec)} could not start. ${detail}`;
  setIdleStatus();
}

function enqueue(codec, quality) {
  const config = QUALITY;
  const bounded = Math.min(config.max, Math.max(config.min, quality));
  const id = jobKey(codec, bounded);
  const state = workers.get(codec);
  if (!state || state.failed || !state.ready || scheduled.has(id)) return;
  scheduled.add(id);
  state.queued.add(id);
  pendingJobs += 1;
  state.worker.postMessage({ type: "encode", id, quality: bounded });
  renderResults();
}

function qualityButton(codec, quality, label) {
  const button = document.createElement("button");
  button.className = "image-compress-quality-button";
  button.type = "button";
  button.textContent = label;
  const state = workers.get(codec);
  button.disabled = scheduled.has(jobKey(codec, quality)) ||
    !state || state.failed || !state.ready;
  button.addEventListener("click", () => enqueue(codec, quality));
  return button;
}

function resultCard(result) {
  const card = document.createElement("article");
  card.className = "image-compress-card";
  const key = jobKey(result.codec, result.quality);
  const image = document.createElement("img");
  image.src = resultURLs.get(key);
  image.alt = `${codecName(result.codec)} preview. Quality ${result.quality}.`;
  image.draggable = false;
  const preview = document.createElement("div");
  preview.className = "image-compress-preview";
  let showingOriginal = false;
  let zoomScale = 1;
  function updateZoomScale() {
    if (image.naturalWidth === 0 || image.clientWidth === 0) return;
    zoomScale = image.naturalWidth / image.clientWidth;
    image.style.setProperty(
      "--image-compress-zoom",
      `${zoomScale}`,
    );
  }
  function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, value));
  }
  function zoomOffset(pointer, frameSize, imageSize) {
    if (imageSize <= frameSize) return (frameSize - imageSize) / 2;
    const buffer = Math.min(IMAGE_EDGE_BUFFER, frameSize / 2);
    const usableSize = Math.max(1, frameSize - 2 * buffer);
    const safePointer = clamp(pointer, buffer, frameSize - buffer);
    const imagePoint = (safePointer - buffer) / usableSize * imageSize;
    return safePointer - imagePoint;
  }
  function positionZoom(event) {
    updateZoomScale();
    if (image.clientWidth === 0 || image.clientHeight === 0) return;
    const bounds = preview.getBoundingClientRect();
    const frameWidth = preview.clientWidth;
    const frameHeight = preview.clientHeight;
    const pointerX = event.clientX - bounds.left - preview.clientLeft;
    const pointerY = event.clientY - bounds.top - preview.clientTop;
    const imageWidth = image.clientWidth * zoomScale;
    const imageHeight = image.clientHeight * zoomScale;
    const offsetX = zoomOffset(pointerX, frameWidth, imageWidth);
    const offsetY = zoomOffset(pointerY, frameHeight, imageHeight);
    image.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${zoomScale})`;
  }
  function showOriginal() {
    if (showingOriginal) return;
    showingOriginal = true;
    image.src = inputURL;
    image.alt = "Original image preview.";
  }
  function showResult() {
    if (!showingOriginal) return;
    showingOriginal = false;
    image.src = resultURLs.get(key);
    image.alt = `${codecName(result.codec)} preview. Quality ${result.quality}.`;
  }
  image.addEventListener("load", updateZoomScale);
  preview.addEventListener("pointerenter", positionZoom);
  preview.addEventListener("pointermove", positionZoom);
  preview.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    showOriginal();
    preview.setPointerCapture?.(event.pointerId);
  });
  preview.addEventListener("pointerup", showResult);
  preview.addEventListener("pointercancel", showResult);
  preview.addEventListener("lostpointercapture", showResult);
  preview.addEventListener("pointerleave", () => {
    showResult();
    image.style.transform = "";
  });
  preview.append(image);

  const heading = document.createElement("div");
  heading.className = "image-compress-card-heading";
  const title = document.createElement("h2");
  title.textContent = `Quality ${result.quality}`;
  heading.append(title);
  const download = document.createElement("button");
  download.type = "button";
  download.textContent = "Download";
  download.addEventListener("click", () => {
    const link = document.createElement("a");
    link.href = resultURLs.get(key);
    link.download = `${selectedFile.name.replace(/\.[^.]+$/, "")}-${result.codec}-q${result.quality}.${result.codec}`;
    link.click();
  });
  heading.append(download);
  card.append(heading, preview);

  const size = document.createElement("p");
  size.className = "image-compress-size";
  const ratio = result.bytes / selectedFile.size * 100;
  size.textContent = `File size: ${formatBytes(result.bytes)} (${ratio.toFixed(1)}% of original)`;
  card.append(size);
  return card;
}

function renderResults() {
  const sections = [];
  for (const codec of ["webp", "avif", "jpeg"]) {
    const ordered = [...results.values()]
      .filter((result) => result.codec === codec)
      .sort((a, b) => a.quality - b.quality);
    if (ordered.length === 0) continue;

    const section = document.createElement("section");
    section.className = "image-compress-codec";
    const heading = document.createElement("h2");
    heading.textContent = codecName(codec);
    section.append(heading);
    const list = document.createElement("div");
    list.className = "image-compress-quality-list";
    const config = QUALITY;
    const first = ordered[0];
    if (first.quality > config.min) {
      list.append(qualityButton(
        codec,
        Math.max(config.min, first.quality - config.step),
        "More compression",
      ));
    }
    for (let index = 0; index < ordered.length; index += 1) {
      const current = ordered[index];
      list.append(resultCard(current));
      const next = ordered[index + 1];
      if (next) {
        const midpoint = Math.floor((current.quality + next.quality) / 2);
        if (midpoint > current.quality && midpoint < next.quality) {
          list.append(qualityButton(codec, midpoint, `${midpoint} quality`));
        }
      } else if (current.quality < config.max) {
        list.append(qualityButton(
          codec,
          Math.min(config.max, current.quality + config.step),
          "Higher quality",
        ));
      }
    }
    section.append(list);
    sections.push(section);
  }
  resultsElement.replaceChildren(...sections);
  resultsElement.hidden = sections.length === 0;
  emptyElement.hidden = sections.length !== 0;
}

function handleCodecMessage(token, event) {
  if (token !== runToken) return;
  const data = event.data;
  const state = workers.get(data.codec);
  if (!state) return;
  if (data.type === "ready") {
    state.ready = true;
    enqueue(data.codec, QUALITY.initial);
    return;
  }
  if (data.type === "result") {
    const id = data.id;
    state.queued.delete(id);
    pendingJobs -= 1;
    const output = new Uint8Array(data.output);
    results.set(id, {
      codec: data.codec,
      quality: data.quality,
      bytes: output.byteLength,
    });
    resultURLs.set(id, URL.createObjectURL(new Blob([output], {
      type: codecMime(data.codec),
    })));
    renderResults();
    setIdleStatus();
    return;
  }
  if (data.type === "job-error") {
    const stateJob = state.queued;
    stateJob.delete(data.id);
    pendingJobs -= 1;
    failCodec(data.codec, data.message);
    renderResults();
    return;
  }
  if (data.type === "error") {
    failCodec(data.codec, data.message);
  }
}

function startCodec(codec, input, hasAlpha, token) {
  const worker = new Worker("/image-compress-worker.js", { type: "module" });
  const state = { worker, ready: false, failed: false, queued: new Set() };
  workers.set(codec, state);
  worker.onmessage = (event) => handleCodecMessage(token, event);
  worker.onerror = (event) => failCodec(codec, event.message || "The codec worker failed.");
  worker.postMessage({ type: "init", codec, input, hasAlpha }, [input]);
}

function startEncoders(token) {
  const selected = selectedCodecs();
  const skippedAvif = selected.includes("avif") && decoded.pixels > MAX_AVIF_PIXELS;
  const runnable = selected.filter((codec) => codec !== "avif" || !skippedAvif);
  if (runnable.length === 0) {
    status.textContent = skippedAvif
      ? "AVIF supports a maximum of 12 MP. Select another output format."
      : "Select at least one output format.";
    return;
  }
  const inputs = runnable.map((codec, index) =>
    index === runnable.length - 1 ? decoded.ktx2 : decoded.ktx2.slice(0)
  );
  runnable.forEach((codec, index) => {
    startCodec(codec, inputs[index], decoded.hasAlpha, token);
  });
  const suffix = skippedAvif ? " AVIF supports a maximum of 12 MP." : "";
  status.textContent = `Image decoded. Starting ${formatNames(runnable)} compression…${suffix}`;
}

function startDecode() {
  const token = ++runToken;
  terminateWorkers();
  clearResults();
  decoded = null;
  if (selectedCodecs().length === 0) {
    status.textContent = "Select at least one output format.";
    return;
  }
  status.textContent = `Decoding ${formatName(selectedFormat)} in your browser…`;
  decoderWorker = new Worker("/image-compress-decode-worker.js", { type: "module" });
  decoderWorker.onmessage = (event) => {
    if (token !== runToken) return;
    const data = event.data;
    if (data.type === "error") {
      status.textContent = `The tool could not decode the image. ${data.message}`;
      return;
    }
    if (data.type !== "done") return;
    decoded = {
      ktx2: data.output,
      width: data.width,
      height: data.height,
      pixels: data.pixels,
      hasAlpha: data.hasAlpha,
    };
    const alpha = decoded.hasAlpha ? " · transparency" : " · opaque";
    inputMeta.textContent = `${selectedFile.name} · ${decoded.width}×${decoded.height} · ${(decoded.pixels / 1000000).toFixed(2)} MP${alpha} · ${formatBytes(selectedFile.size)}`;
    startEncoders(token);
  };
  decoderWorker.onerror = (event) => {
    if (token !== runToken) return;
    status.textContent = event.message || "The decoder stopped.";
  };
  selectedFile.arrayBuffer().then((input) => {
    if (token !== runToken) return;
    decoderWorker.postMessage({ type: "decode", format: selectedFormat, input }, [input]);
  }).catch((error) => {
    if (token !== runToken) return;
    status.textContent = error instanceof Error ? error.message : String(error);
  });
}

fileInput.addEventListener("change", () => {
  selectedFile = fileInput.files?.[0] || null;
  selectedFormat = selectedFile ? fileFormat(selectedFile) : null;
  resetRun();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  inputURL = "";
  if (!selectedFile || !selectedFormat) {
    inputMeta.textContent = "";
    originalPreview.removeAttribute("src");
    originalSection.hidden = true;
    status.textContent = selectedFile ? "Choose a JPEG, PNG, WebP or AVIF image." : "";
    return;
  }
  inputURL = URL.createObjectURL(selectedFile);
  originalPreview.src = inputURL;
  originalSection.hidden = false;
  inputMeta.textContent = `${selectedFile.name} · ${formatBytes(selectedFile.size)}`;
  startDecode();
});

for (const input of codecInputs) {
  input.addEventListener("change", () => {
    if (selectedFile && selectedFormat) startDecode();
  });
}

addEventListener("beforeunload", () => {
  terminateWorkers();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  for (const url of resultURLs.values()) URL.revokeObjectURL(url);
});
</script>

The tool shows each selected format in quality order. Lower quality is above higher
quality. The tool shows the file size on each result. A smaller file is not
always a better image. Compare the previews. The same quality values are used
for WebP, AVIF, and JPEG, but the codecs can produce different file sizes and visual
results. Move the pointer over a preview to view source pixels at 1x scale.
Hold the mouse button to view the original image. The decoders support
images up to 25 MP. AVIF output supports up to 12 MP.

The JPEG decoder supports baseline and progressive JPEG. The PNG decoder
supports common non-interlaced 8-bit PNG files. The WebP decoder supports still
lossy and lossless WebP. The AVIF decoder supports still sRGB AVIF images
without an embedded ICC profile. The tool rejects other image features,
including animated WebP and AVIF. It does not send your file to a server. Each
image is decoded to KTX2 (R8G8B8A8 sRGB) pixels, and each encoder reads those
pixels. The AVIF components use libavif and libaom. The JPEG component uses
MozJPEG and composites transparency onto white. Quality 100 is not lossless.

The tool supports sRGB images only. It does not convert wider color profiles.
Images with wider profiles, such as some Mac screenshots, can have color
shifts. Convert them to sRGB before selecting them.

## Components used by this tool

- <a href="/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm" download>jpeg-to-ktx2-r8g8b8a8-srgb.wasm</a>
- <a href="/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm" download>png-to-ktx2-r8g8b8a8-srgb.wasm</a>
- <a href="/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm" download>webp-to-ktx2-r8g8b8a8-srgb.wasm</a>
- <a href="/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm" download>avif-to-ktx2-r8g8b8a8-srgb.wasm</a>
- <a href="/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm" download>ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm</a>
- <a href="/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm" download>ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm</a>
- <a href="/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm" download>ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm</a>
- <a href="/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm" download>ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm</a>
