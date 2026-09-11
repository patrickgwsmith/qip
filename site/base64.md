<title>Base64 encoder and decoder</title>

# Base64 encoder and decoder

Encode text to Base64 and decode Base64 back locally in your browser. Each
direction is its own QIP component:
<a href="/bytes/base64-encode.wasm" download><qip-content-size src="/bytes/base64-encode.wasm"></qip-content-size> of WebAssembly to encode</a>
and <a href="/text/base64-decode.wasm" download><qip-content-size src="/text/base64-decode.wasm"></qip-content-size> to decode</a>.

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 860px) {
  .tool-grid { grid-template-columns: 1fr 1fr; }
}
.tool-panel {
  display: grid;
  gap: 0.5rem;
}
.tool-panel textarea {
  box-sizing: border-box;
  min-height: 18rem;
  width: 100%;
  resize: vertical;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.tool-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.tool-status {
  min-height: 1.5rem;
}
</style>

<div class="tool-grid">
  <label class="tool-panel">
    <strong>Text</strong>
    <textarea id="base64-text" spellcheck="false">hello wasm</textarea>
  </label>
  <label class="tool-panel">
    <strong>Base64</strong>
    <textarea id="base64-encoded" spellcheck="false"></textarea>
  </label>
</div>

<p class="tool-actions">
  <button id="base64-copy-encoded" type="button">Copy Base64</button>
  <button id="base64-copy-text" type="button">Copy text</button>
  <button id="base64-download" type="button">Download decoded bytes</button>
  <span id="base64-status" class="tool-status" role="status"></span>
</p>

<script type="module">
import { contentComponent, contentTypeBytes, contentTypeUTF8 } from "/qip-runner.js";

const textArea = document.getElementById("base64-text");
const encodedArea = document.getElementById("base64-encoded");
const copyEncodedButton = document.getElementById("base64-copy-encoded");
const copyTextButton = document.getElementById("base64-copy-text");
const downloadButton = document.getElementById("base64-download");
const status = document.getElementById("base64-status");
const bytes = contentTypeBytes();
const text = contentTypeUTF8();
const [encodeModule, decodeModule] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/bytes/base64-encode.wasm")),
  WebAssembly.compileStreaming(fetch("/text/base64-decode.wasm")),
]);
const encodeComponent = contentComponent(bytes, encodeModule, text);
const decodeComponent = contentComponent(text, decodeModule, bytes);
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
let decodedBytes = new Uint8Array(0);

function encode() {
  try {
    decodedBytes = textEncoder.encode(textArea.value);
    encodedArea.value = encodeComponent(decodedBytes);
    status.textContent = "Encoded " + decodedBytes.length + " bytes.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

function decode() {
  const compact = encodedArea.value.replace(/\s+/g, "");
  if (compact.length % 4 === 1 || !/^[A-Za-z0-9+/]*={0,2}$/.test(compact)) {
    status.textContent = "Not valid Base64.";
    return;
  }
  const padded = compact + "=".repeat((4 - (compact.length % 4)) % 4);
  try {
    decodedBytes = decodeComponent(padded);
    textArea.value = textDecoder.decode(decodedBytes);
    status.textContent = "Decoded " + decodedBytes.length + " bytes.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

copyEncodedButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(encodedArea.value);
  status.textContent = "Copied Base64.";
});
copyTextButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(textArea.value);
  status.textContent = "Copied text.";
});
downloadButton.addEventListener("click", () => {
  const blob = new Blob([decodedBytes], { type: "application/octet-stream" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = "decoded.bin";
  link.click();
  URL.revokeObjectURL(url);
});
textArea.addEventListener("input", encode);
encodedArea.addEventListener("input", decode);
encode();
</script>

Text decoded from Base64 is shown as UTF-8; binary payloads display as
replacement characters, so use **Download decoded bytes** for those. Both
components handle up to 64 KiB.

## Download

- <a href="/bytes/base64-encode.wasm" download>base64-encode.wasm</a> — <qip-content-size src="/bytes/base64-encode.wasm"></qip-content-size>
- <a href="/text/base64-decode.wasm" download>base64-decode.wasm</a> — <qip-content-size src="/text/base64-decode.wasm"></qip-content-size>

## CLI equivalent

```bash
qip run bytes/base64-encode.wasm < image.png > image.png.b64
qip run text/base64-decode.wasm < image.png.b64 > image.png
```

The decoder accepts canonical RFC 4648 Base64. The input length must be a
multiple of four. Padding is allowed only in the final group, and unused pad
bits must be zero. A failed `render` rejects malformed input instead of
producing partial bytes.

The decoder treats every input byte as Base64 data, so strip whitespace first
when a file wraps its lines. Add `=` padding when the source omitted it before
running `qip run text/base64-decode.wasm`.
