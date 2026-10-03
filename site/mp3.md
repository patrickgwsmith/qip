<title>WAV to MP3 encoder</title>

# WAV to MP3 encoder

Convert a WAV recording to a constant-bitrate MP3 locally in your browser,
using LAME 3.101 compiled to a QIP component. The audio is not uploaded to a
server.

<style>
.mp3-tool {
  display: grid;
  gap: 1rem;
}
.mp3-tool input,
.mp3-tool select,
.mp3-tool button {
  font: inherit;
}
.mp3-options {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: end;
}
.mp3-options label {
  display: grid;
  gap: 0.25rem;
}
.mp3-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.mp3-status {
  min-height: 1.5rem;
}
.mp3-preview {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(18rem, 100%), 1fr));
  gap: 1rem;
}
.mp3-preview audio {
  width: 100%;
}
.mp3-meta {
  font-variant-numeric: tabular-nums;
}
</style>

<div class="mp3-tool">
  <label>
    <strong>16-bit PCM WAV, mono or stereo, 8–48 kHz</strong><br>
    <input id="mp3-input" type="file" accept="audio/wav,audio/x-wav,.wav">
  </label>
  <p id="mp3-input-meta" class="mp3-meta"></p>

  <div class="mp3-options">
    <label>Use
      <select id="mp3-use">
        <option value="32">Voice memo or draft for review</option>
        <option value="64">Spoken podcast, audiobook or lecture</option>
        <option value="128">Podcast with music, or interview in stereo</option>
        <option value="192" selected>Music demo, mix or rehearsal to share</option>
        <option value="320">Music at highest MP3 quality</option>
        <option value="custom">Custom bitrate</option>
      </select>
    </label>
    <label>Bitrate
      <select id="mp3-bitrate">
        <option value="32">32 kbps</option>
        <option value="64">64 kbps</option>
        <option value="96">96 kbps</option>
        <option value="128">128 kbps</option>
        <option value="160">160 kbps</option>
        <option value="192" selected>192 kbps</option>
        <option value="256">256 kbps</option>
        <option value="320">320 kbps</option>
      </select>
    </label>
  </div>
  <p id="mp3-use-hint" class="mp3-meta"></p>

  <p class="mp3-actions">
    <button id="mp3-encode" type="button" disabled>Encode MP3</button>
    <button id="mp3-cancel" type="button" disabled>Cancel</button>
    <button id="mp3-download" type="button" disabled>Download MP3</button>
  </p>
  <p id="mp3-status" class="mp3-status" role="status"></p>

  <div class="mp3-preview">
    <section id="mp3-input-preview-section" hidden>
      <h2>Input</h2>
      <audio id="mp3-input-preview" controls></audio>
    </section>
    <section id="mp3-output-preview-section" hidden>
      <h2>MP3 output</h2>
      <audio id="mp3-output-preview" controls></audio>
    </section>
  </div>
</div>

<script type="module">
const fileInput = document.getElementById("mp3-input");
const inputMeta = document.getElementById("mp3-input-meta");
const useSelect = document.getElementById("mp3-use");
const useHint = document.getElementById("mp3-use-hint");
const bitrateSelect = document.getElementById("mp3-bitrate");
const encodeButton = document.getElementById("mp3-encode");
const cancelButton = document.getElementById("mp3-cancel");
const downloadButton = document.getElementById("mp3-download");
const status = document.getElementById("mp3-status");
const inputPreviewSection = document.getElementById("mp3-input-preview-section");
const outputPreviewSection = document.getElementById("mp3-output-preview-section");
const inputPreview = document.getElementById("mp3-input-preview");
const outputPreview = document.getElementById("mp3-output-preview");

const useHints = {
  32: "Small enough to email or message; speech stays intelligible but sounds thin.",
  64: "Common for speech-only podcasts. Export mono for the clearest voice at this size.",
  128: "Keeps music beds, intros and stereo room sound clean. Widely used for podcasts.",
  192: "Hard to tell from the original for most listeners, at about a seventh of CD size.",
  320: "The largest MP3 bitrate, for sending to DJs or collaborators who only take MP3.",
  custom: "",
};

let selectedFile = null;
let selectedSeconds = 0;
let inputURL = "";
let outputURL = "";
let outputName = "output.mp3";
let worker = null;

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}

function formatDuration(seconds) {
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${(seconds - minutes * 60).toFixed(1).padStart(4, "0")}`;
}

function tag(bytes, offset) {
  return String.fromCharCode(...bytes.subarray(offset, offset + 4));
}

async function readBytes(file, offset, length) {
  return new Uint8Array(await file.slice(offset, offset + length).arrayBuffer());
}

// Mirrors the component's checks so unsupported files are explained up front.
// Only chunk headers and the fmt chunk are read, not the audio itself.
async function parseWAV(file) {
  const header = await readBytes(file, 0, 12);
  if (file.size < 44 || tag(header, 0) !== "RIFF" || tag(header, 8) !== "WAVE") {
    throw Error("Choose a RIFF WAVE file.");
  }
  let fmt = null;
  let dataSize = 0;
  let offset = 12;
  while (offset + 8 <= file.size) {
    const chunk = await readBytes(file, offset, 24);
    const view = new DataView(chunk.buffer);
    const size = view.getUint32(4, true);
    const body = offset + 8;
    if (size > file.size - body) throw Error("The WAV is truncated.");
    if (tag(chunk, 0) === "fmt " && size >= 16) {
      fmt = {
        format: view.getUint16(8, true),
        channels: view.getUint16(10, true),
        sampleRate: view.getUint32(12, true),
        blockAlign: view.getUint16(20, true),
        bits: view.getUint16(22, true),
      };
    } else if (tag(chunk, 0) === "data") {
      dataSize = size;
    }
    offset = body + size + (size & 1);
  }
  if (fmt === null || dataSize === 0) throw Error("The WAV has no format or audio data.");
  if (fmt.format !== 1 || fmt.bits !== 16) {
    throw Error("The encoder accepts 16-bit integer PCM only. Convert float or 24-bit WAV first.");
  }
  if (fmt.channels !== 1 && fmt.channels !== 2) {
    throw Error("The encoder accepts mono or stereo WAV only.");
  }
  if (fmt.sampleRate < 8000 || fmt.sampleRate > 48000) {
    throw Error("The encoder accepts sample rates from 8 kHz to 48 kHz.");
  }
  if (fmt.blockAlign !== fmt.channels * 2 || dataSize % fmt.blockAlign !== 0) {
    throw Error("The WAV's block alignment does not match its format.");
  }
  return { ...fmt, seconds: dataSize / fmt.blockAlign / fmt.sampleRate };
}

// CBR output size is bitrate × duration, so the estimate is close to exact.
function updateUseHint() {
  const bitrateKbps = Number.parseInt(bitrateSelect.value, 10);
  const size = selectedSeconds > 0
    ? `About ${formatBytes(Math.round(bitrateKbps * 125 * selectedSeconds))} for this file.`
    : `About ${formatBytes(bitrateKbps * 125 * 3600)} per hour.`;
  useHint.textContent = [useHints[useSelect.value], size].filter(Boolean).join(" ");
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

fileInput.addEventListener("change", async () => {
  selectedFile = null;
  selectedSeconds = 0;
  encodeButton.disabled = true;
  resetOutput();
  updateUseHint();
  if (inputURL !== "") URL.revokeObjectURL(inputURL);
  inputURL = "";
  inputPreviewSection.hidden = true;
  inputMeta.textContent = "";
  const file = fileInput.files?.[0];
  if (!file) {
    status.textContent = "";
    return;
  }
  if (file.size > 1008 * 1024 * 1024) {
    status.textContent = "The WAV exceeds the component's 1008 MiB input capacity.";
    return;
  }
  try {
    const wav = await parseWAV(file);
    selectedFile = file;
    selectedSeconds = wav.seconds;
    updateUseHint();
    const channels = wav.channels === 1 ? "mono" : "stereo";
    inputMeta.textContent =
      `${channels} · ${(wav.sampleRate / 1000).toFixed(wav.sampleRate % 1000 ? 2 : 0)} kHz · ` +
      `${formatDuration(wav.seconds)} · ${formatBytes(file.size)}`;
    inputURL = URL.createObjectURL(file);
    inputPreview.src = inputURL;
    inputPreviewSection.hidden = false;
    encodeButton.disabled = false;
    status.textContent = "Ready to encode.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

useSelect.addEventListener("change", () => {
  if (useSelect.value !== "custom") bitrateSelect.value = useSelect.value;
  resetOutput();
  updateUseHint();
});

bitrateSelect.addEventListener("change", () => {
  useSelect.value = bitrateSelect.value in useHints ? bitrateSelect.value : "custom";
  resetOutput();
  updateUseHint();
});

updateUseHint();

encodeButton.addEventListener("click", async () => {
  if (!selectedFile || worker !== null) return;
  resetOutput();
  const bitrateKbps = Number.parseInt(bitrateSelect.value, 10);
  const inputName = selectedFile.name;
  encodeButton.disabled = true;
  cancelButton.disabled = false;
  status.textContent = `Encoding ${bitrateKbps} kbps MP3 in a worker…`;
  try {
    const input = await selectedFile.arrayBuffer();
    worker = new Worker("/mp3-worker.js", { type: "module" });
    worker.onmessage = (event) => {
      if (event.data.type === "error") {
        status.textContent = event.data.message;
        finish();
        return;
      }
      const output = new Uint8Array(event.data.output);
      outputURL = URL.createObjectURL(new Blob([output], { type: "audio/mpeg" }));
      outputPreview.src = outputURL;
      outputPreviewSection.hidden = false;
      downloadButton.disabled = false;
      outputName = inputName.replace(/\.wav$/i, "") + ".mp3";
      status.textContent =
        `${formatBytes(output.length)} MP3 ready in ${(event.data.elapsedMs / 1000).toFixed(2)} s · ` +
        `encoder peak ${formatBytes(event.data.peakBytes)}.`;
      finish();
    };
    worker.onerror = (event) => {
      status.textContent = event.message || "The MP3 worker failed.";
      finish();
    };
    worker.postMessage({ input, bitrateKbps }, [input]);
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

The component accepts WAV files up to 1008 MiB: about 100 minutes of 44.1 kHz
stereo, 90 minutes of 48 kHz stereo, or over three hours of mono. It encodes at a constant bitrate with LAME's `-q 2` quality setting and
writes no ID3 or Xing header. At low bitrates LAME lowers the sample rate:
44.1 kHz stereo becomes 32 kHz at 96 kbps, 24 kHz at 64 kbps and 16 kHz at 32
kbps. For speech, a mono WAV keeps more detail at the same bitrate than a
stereo one. Input below 32 kHz keeps its sample
rate and is encoded as MPEG-2, whose bitrates top out at 160 kbps, so higher
choices are capped there. On the CLI, `bitrate_kbps` rounds to the nearest MP3
bitrate from 32 to 320 kbps, for example 100 becomes 96, and applies to one
encode only.

The encoder is LAME, licensed under the LGPL v2. Its unmodified source and the
wrapper that builds this component are in the QIP repository under
`third_party/lame-3.101` and `audio/wav/wav-to-mp3-lossy.c`.

## Components

- <a href="/audio/wav/wav-to-mp3-lossy.wasm" download>wav-to-mp3-lossy.wasm</a> — <qip-content-size src="/audio/wav/wav-to-mp3-lossy.wasm"></qip-content-size>

Browse all [audio components](/audio).

## CLI equivalent

```bash
qip run audio/wav/wav-to-mp3-lossy.wasm -u bitrate_kbps=192 \
  < input.wav > output.mp3
```
