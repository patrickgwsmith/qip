<title>PDF to text</title>

# PDF to text

Extract readable text from a born-digital PDF in your browser. The selected
file is read into WebAssembly memory on this page. It is not uploaded or sent
to a server.

<style>
.pdf-tool {
  display: grid;
  gap: 1rem;
}
.pdf-tool input,
.pdf-tool button,
.pdf-tool textarea {
  font: inherit;
}
.pdf-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
  margin: 0;
}
.pdf-status {
  min-height: 1.5rem;
  margin: 0;
}
.pdf-output {
  display: grid;
  gap: 0.5rem;
}
.pdf-output textarea {
  box-sizing: border-box;
  width: 100%;
  min-height: 28rem;
  resize: vertical;
  padding: 0.75rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  line-height: 1.45;
}
</style>

<div class="pdf-tool">
  <label>
    <strong>PDF file</strong><br>
    <input id="pdf-input" type="file" accept="application/pdf,.pdf" />
  </label>

  <p id="pdf-status" class="pdf-status" role="status">Choose a PDF to extract its text.</p>

  <p class="pdf-actions">
    <button id="pdf-copy" type="button" disabled>Copy text</button>
    <button id="pdf-download" type="button" disabled>Download .txt</button>
  </p>

  <label class="pdf-output">
    <strong>Extracted text</strong>
    <textarea id="pdf-output" readonly spellcheck="false" placeholder="Extracted text will appear here."></textarea>
  </label>
</div>

<script type="module">
const fileInput = document.getElementById("pdf-input");
const status = document.getElementById("pdf-status");
const output = document.getElementById("pdf-output");
const copyButton = document.getElementById("pdf-copy");
const downloadButton = document.getElementById("pdf-download");
const decoder = new TextDecoder("utf-8", { fatal: true });
let extractorPromise = null;

function formatBytes(value) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
}

function outputName(inputName) {
  const stem = inputName.replace(/\.pdf$/i, "") || "document";
  return `${stem}.txt`;
}

async function loadExtractor() {
  if (extractorPromise === null) {
    extractorPromise = WebAssembly.instantiateStreaming(
      fetch("/application/pdf/pdf-extract-text.wasm"),
    ).then(({ instance }) => instance.exports);
  }
  return extractorPromise;
}

function extractText(exports, input) {
  const inputCapacity = exports.input_bytes_cap() >>> 0;
  if (input.length > inputCapacity) {
    throw new RangeError(
      `PDF is ${formatBytes(input.length)}; this component accepts up to ${formatBytes(inputCapacity)}.`,
    );
  }

  const inputPointer = exports.input_ptr() >>> 0;
  new Uint8Array(exports.memory.buffer, inputPointer, input.length).set(input);
  const packed = BigInt.asUintN(64, exports.render(input.length));
  if ((packed >> 63n) !== 0n) throw new Error("The component rejected the PDF.");
  const outputLength = Number(packed & 0xffff_ffffn);
  const outputCapacity = exports.output_utf8_cap() >>> 0;
  if (outputLength > outputCapacity) {
    throw new RangeError("The component returned more text than its output capacity.");
  }
  const outputPointer = Number((packed >> 32n) & 0x7fff_ffffn);
  return decoder.decode(
    new Uint8Array(exports.memory.buffer, outputPointer, outputLength),
  );
}

function setActionsEnabled(enabled) {
  copyButton.disabled = !enabled;
  downloadButton.disabled = !enabled;
}

function describeError(error) {
  if (error instanceof WebAssembly.RuntimeError) {
    return "The file may be encrypted, scanned, malformed, or use PDF features this first extractor does not support.";
  }
  return error instanceof Error ? error.message : String(error);
}

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  output.value = "";
  setActionsEnabled(false);
  if (!file) {
    status.textContent = "Choose a PDF to extract its text.";
    return;
  }

  status.textContent = `Loading the extractor for ${file.name}...`;
  try {
    const input = new Uint8Array(await file.arrayBuffer());
    const exports = await loadExtractor();
    status.textContent = `Extracting text from ${file.name}...`;
    await new Promise((resolve) => requestAnimationFrame(resolve));
    const started = performance.now();
    output.value = extractText(exports, input);
    const elapsed = performance.now() - started;
    setActionsEnabled(true);
    status.textContent = `${file.name}: ${formatBytes(file.size)} PDF to ${formatBytes(new Blob([output.value]).size)} text in ${elapsed.toFixed(0)} ms.`;
  } catch (error) {
    extractorPromise = null;
    status.textContent = `Could not extract this PDF. ${describeError(error)}`;
  }
});

copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(output.value);
    status.textContent = "Extracted text copied.";
  } catch {
    status.textContent = "The browser did not allow clipboard access.";
  }
});

downloadButton.addEventListener("click", () => {
  const file = fileInput.files?.[0];
  const url = URL.createObjectURL(new Blob([output.value], { type: "text/plain;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = outputName(file?.name || "document.pdf");
  link.click();
  URL.revokeObjectURL(url);
});
</script>

The extractor interprets text positioning, common PDF text operators,
WinAnsi fonts, and basic `ToUnicode` maps. It reconstructs visual lines,
inserts likely spaces, removes overlapping duplicate glyphs, and separates
pages with form-feed characters.

It does not perform OCR, infer tables, decrypt files, expand compressed object
streams, or guarantee the reading order of complex multi-column layouts.
Scanned PDFs therefore need an OCR component first. Input is limited to 64
MiB, and output is limited to 32 MiB.

## CLI equivalent

```sh
./qip run -i document.pdf -o document.txt -- \
  application/pdf/pdf-extract-text.wasm
```

## Download the component

- <a href="/application/pdf/pdf-extract-text.wasm" download>pdf-extract-text.wasm</a>
  (<qip-content-size src="/application/pdf/pdf-extract-text.wasm"></qip-content-size>)
