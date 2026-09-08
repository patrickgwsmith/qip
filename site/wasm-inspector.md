<title>WebAssembly module inspector</title>

# WebAssembly module inspector

Drop in a WebAssembly module or choose one from this site. The module is
measured locally by another WebAssembly module; it is not instantiated or
uploaded.

<style>
.wasm-inspector {
  display: grid;
  gap: 1.25rem;
}
.wasm-source {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 0.75rem;
  align-items: end;
  padding: 1rem;
  border: 1px solid color-mix(in srgb, currentColor 24%, transparent);
  border-radius: 0.75rem;
}
.wasm-source label:first-child {
  display: grid;
  gap: 0.35rem;
}
.wasm-source select,
.wasm-source button,
.wasm-source input {
  font: inherit;
}
.wasm-source select {
  box-sizing: border-box;
  width: 100%;
  min-width: 0;
}
.wasm-upload {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 2.25rem;
  padding: 0 0.9rem;
  border: 1px solid currentColor;
  border-radius: 0.35rem;
  cursor: pointer;
  white-space: nowrap;
}
.wasm-upload:hover,
.wasm-upload:focus-within {
  background: color-mix(in srgb, currentColor 10%, transparent);
}
.wasm-upload input {
  position: absolute;
  width: 1px;
  height: 1px;
  opacity: 0;
}
.wasm-inspector.is-dragging .wasm-source {
  outline: 3px solid color-mix(in srgb, currentColor 55%, transparent);
  outline-offset: 3px;
}
.wasm-status {
  min-height: 1.5rem;
  margin: 0;
}
.wasm-report {
  display: grid;
  gap: 1rem;
}
.wasm-report[hidden] {
  display: none;
}
.wasm-report-header {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: 0.5rem 1rem;
  align-items: baseline;
}
.wasm-report-header h2,
.wasm-report-header p {
  margin: 0;
}
.wasm-report-header h2 {
  overflow-wrap: anywhere;
}
.wasm-headline {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 1px;
  overflow: hidden;
  border: 1px solid color-mix(in srgb, currentColor 24%, transparent);
  border-radius: 0.75rem;
  background: color-mix(in srgb, currentColor 20%, transparent);
}
.wasm-stat {
  display: grid;
  gap: 0.15rem;
  padding: 1rem;
  background: Canvas;
  color: CanvasText;
}
.wasm-stat strong {
  font-size: clamp(1.15rem, 3vw, 1.8rem);
  font-variant-numeric: tabular-nums;
  line-height: 1.1;
}
.wasm-stat span {
  color: color-mix(in srgb, currentColor 70%, transparent);
  font-size: 0.85em;
}
.wasm-panels {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}
.wasm-panel {
  padding: 1rem;
  border: 1px solid color-mix(in srgb, currentColor 24%, transparent);
  border-radius: 0.75rem;
}
.wasm-panel h3 {
  margin-top: 0;
}
.wasm-traits {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin: 0;
  padding: 0;
  list-style: none;
}
.wasm-traits li {
  padding: 0.2rem 0.55rem;
  border: 1px solid color-mix(in srgb, currentColor 35%, transparent);
  border-radius: 999px;
  font-size: 0.85em;
}
.wasm-traits .wasm-trait-notable {
  background: color-mix(in srgb, #eecc33 22%, Canvas);
  color: color-mix(in srgb, CanvasText 90%, #4c3e00);
}
.wasm-bars {
  display: grid;
  gap: 0.65rem;
}
.wasm-bar-row {
  display: grid;
  grid-template-columns: minmax(6.5rem, auto) 1fr auto;
  gap: 0.6rem;
  align-items: center;
}
.wasm-bar-track {
  height: 0.55rem;
  overflow: hidden;
  border-radius: 999px;
  background: color-mix(in srgb, currentColor 12%, transparent);
}
.wasm-bar-fill {
  height: 100%;
  min-width: 2px;
  border-radius: inherit;
  background: currentColor;
}
.wasm-bar-value {
  min-width: 5.5rem;
  text-align: right;
  font-variant-numeric: tabular-nums;
  font-size: 0.85em;
}
.wasm-memory-track {
  position: relative;
  height: 1.25rem;
  overflow: hidden;
  border-radius: 0.3rem;
  background: color-mix(in srgb, currentColor 10%, transparent);
}
.wasm-memory-initial {
  height: 100%;
  min-width: 2px;
  background: color-mix(in srgb, #eecc33 70%, currentColor);
}
.wasm-memory-copy {
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  margin: 0.4rem 0 0;
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}
.wasm-shape {
  font-variant-numeric: tabular-nums;
}
.wasm-shape th,
.wasm-shape td {
  text-align: right;
}
.wasm-shape th:first-child {
  text-align: left;
}
.wasm-raw summary {
  cursor: pointer;
}
.wasm-raw-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
  margin: 0.75rem 0;
}
.wasm-raw-actions button {
  font: inherit;
}
.wasm-raw pre {
  max-height: 26rem;
  overflow: auto;
}
@media (max-width: 720px) {
  .wasm-source,
  .wasm-panels {
    grid-template-columns: 1fr;
  }
  .wasm-headline {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>

<div id="wasm-inspector" class="wasm-inspector">
  <div class="wasm-source">
    <label>
      <strong>Module from this site</strong>
      <select id="wasm-module-select">
        <option value="">Loading module catalog…</option>
      </select>
    </label>
    <label class="wasm-upload">
      <span>Open local .wasm</span>
      <input id="wasm-file-input" type="file" accept="application/wasm,.wasm">
    </label>
  </div>
  <p id="wasm-inspector-status" class="wasm-status" role="status" aria-live="polite">
    Loading inspector…
  </p>
  <section id="wasm-report" class="wasm-report" aria-live="polite" hidden>
    <header class="wasm-report-header">
      <h2 id="wasm-report-name"></h2>
      <p id="wasm-report-summary"></p>
    </header>
    <div class="wasm-headline">
      <div class="wasm-stat"><strong id="wasm-size"></strong><span>module size</span></div>
      <div class="wasm-stat"><strong id="wasm-instructions"></strong><span>instructions</span></div>
      <div class="wasm-stat"><strong id="wasm-functions"></strong><span>defined functions</span></div>
      <div class="wasm-stat"><strong id="wasm-data"></strong><span>static data</span></div>
    </div>
    <div class="wasm-panels">
      <section class="wasm-panel">
        <h3>Module traits</h3>
        <ul id="wasm-traits" class="wasm-traits"></ul>
      </section>
      <section class="wasm-panel">
        <h3>Declared memory</h3>
        <div class="wasm-memory-track" aria-hidden="true">
          <div id="wasm-memory-initial" class="wasm-memory-initial"></div>
        </div>
        <p class="wasm-memory-copy">
          <span id="wasm-memory-start"></span>
          <span id="wasm-memory-max"></span>
        </p>
      </section>
      <section class="wasm-panel">
        <h3>Instruction activity</h3>
        <div id="wasm-bars" class="wasm-bars"></div>
      </section>
      <section class="wasm-panel">
        <h3>Module shape</h3>
        <table class="wasm-shape">
          <thead><tr><th>Kind</th><th>Defined</th><th>Imported</th></tr></thead>
          <tbody id="wasm-shape"></tbody>
        </table>
      </section>
    </div>
    <details class="wasm-raw">
      <summary>All metrics as CSV</summary>
      <p class="wasm-raw-actions">
        <button id="wasm-copy-csv" type="button">Copy CSV</button>
        <span id="wasm-copy-status" role="status"></span>
      </p>
      <pre><code id="wasm-raw-csv"></code></pre>
    </details>
  </section>
</div>

<script type="module">
import { contentComponent, contentTypeBytes, contentTypeUTF8 } from "/qip-runner.js";

const MAX_MODULE_BYTES = 8 * 1024 * 1024;
const DEFAULT_MODULE = "/text/markdown/gfm-commonmark.0.31.2.wasm";
const inspector = document.getElementById("wasm-inspector");
const moduleSelect = document.getElementById("wasm-module-select");
const fileInput = document.getElementById("wasm-file-input");
const status = document.getElementById("wasm-inspector-status");
const report = document.getElementById("wasm-report");
const copyStatus = document.getElementById("wasm-copy-status");
let rawCSV = "";
let inspectionNumber = 0;

const [counterModule, viewSourceResponse] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/application/wasm/wasm-counts.wasm")),
  fetch("/view-source"),
]);
if (!viewSourceResponse.ok) {
  throw Error("Could not load /view-source. Run the router with --view-source.");
}

const countModule = contentComponent(
  contentTypeBytes("application/wasm"),
  counterModule,
  contentTypeUTF8("text/csv"),
);
const viewSource = new DOMParser().parseFromString(
  await viewSourceResponse.text(),
  "text/html",
);
const modulePaths = [
  ...new Set(
    [...viewSource.querySelectorAll('a[href^="/"][href$=".wasm"]')]
      .map((link) => new URL(link.getAttribute("href"), location.origin).pathname),
  ),
].sort();

function shortName(path) {
  return path.slice(path.lastIndexOf("/") + 1);
}

function categoryFor(path) {
  const parts = path.split("/");
  if (parts[2] === "application" || parts[2] === "image" || parts[2] === "text") {
    return parts[2] + "/" + parts[3];
  }
  return parts[2];
}

function populateCatalog() {
  moduleSelect.replaceChildren();
  const groups = new Map();
  for (const path of modulePaths) {
    const category = categoryFor(path);
    if (!groups.has(category)) groups.set(category, []);
    groups.get(category).push(path);
  }
  for (const [category, paths] of groups) {
    const group = document.createElement("optgroup");
    group.label = category;
    for (const path of paths) {
      const option = document.createElement("option");
      option.value = path;
      option.textContent = path.slice("/".length);
      group.append(option);
    }
    moduleSelect.append(group);
  }
}

function parseCounts(csv) {
  const lines = csv.trimEnd().split("\n");
  if (lines.shift() !== "metric,value") throw Error("Unexpected wasm-counts output.");
  const metrics = new Map();
  for (const line of lines) {
    const comma = line.indexOf(",");
    const name = line.slice(0, comma);
    const value = Number(line.slice(comma + 1));
    if (comma < 1 || !Number.isSafeInteger(value) || value < 0) {
      throw Error("Invalid metric in wasm-counts output.");
    }
    metrics.set(name, value);
  }
  return metrics;
}

function metric(metrics, name) {
  const value = metrics.get(name);
  if (value === undefined) throw Error("Missing metric: " + name);
  return value;
}

function formatNumber(value) {
  return new Intl.NumberFormat().format(value);
}

function formatBytes(value) {
  if (value < 1024) return formatNumber(value) + (value === 1 ? " byte" : " bytes");
  if (value < 1024 * 1024) return (value / 1024).toFixed(value < 10 * 1024 ? 1 : 0) + " KiB";
  return (value / (1024 * 1024)).toFixed(value < 10 * 1024 * 1024 ? 2 : 1) + " MiB";
}

function addTrait(text, notable = false) {
  const item = document.createElement("li");
  item.textContent = text;
  if (notable) item.className = "wasm-trait-notable";
  document.getElementById("wasm-traits").append(item);
}

function renderTraits(metrics) {
  const traits = document.getElementById("wasm-traits");
  traits.replaceChildren();
  const memories = metric(metrics, "memories_defined") + metric(metrics, "memories_imported");
  const imports =
    metric(metrics, "functions_imported") +
    metric(metrics, "tables_imported") +
    metric(metrics, "globals_imported") +
    metric(metrics, "memories_imported");
  addTrait(imports === 0 ? "Import-free" : formatNumber(imports) + " imports", imports > 0);
  if (memories === 0) {
    addTrait("No linear memory");
  } else {
    addTrait(
      metric(metrics, "memories_with_maximum") > 0 ? "Memory maximum" : "No memory maximum",
      metric(metrics, "memories_with_maximum") === 0,
    );
  }
  if (metric(metrics, "simd_instructions") > 0) addTrait("SIMD", true);
  if (metric(metrics, "calls_indirect") > 0) addTrait("Indirect calls", true);
  if (metric(metrics, "memories_shared") > 0) addTrait("Shared memory", true);
  if (metric(metrics, "memories_memory64") > 0) addTrait("Memory64", true);
  if (metric(metrics, "explicit_traps") > 0) addTrait("Explicit traps", true);
  if (metric(metrics, "custom_sections") > 0) {
    addTrait(formatNumber(metric(metrics, "custom_sections")) + " custom sections");
  }
  if (metric(metrics, "loops") === 0) addTrait("No loops");
}

function renderMemory(metrics) {
  const initial = metric(metrics, "memory_initial_bytes");
  const maximum = metric(metrics, "memory_maximum_bytes");
  const memories = metric(metrics, "memories_defined") + metric(metrics, "memories_imported");
  const percent = maximum > 0 ? Math.min(100, initial / maximum * 100) : 0;
  document.getElementById("wasm-memory-initial").style.width = percent + "%";
  document.getElementById("wasm-memory-start").textContent =
    memories === 0 ? "No linear memory" : formatBytes(initial) + " initial";
  document.getElementById("wasm-memory-max").textContent =
    memories === 0 ? "" : maximum > 0 ? formatBytes(maximum) + " maximum" : "No maximum";
}

function renderBars(metrics) {
  const instructions = Math.max(1, metric(metrics, "instructions"));
  const calls =
    metric(metrics, "calls_direct_local") +
    metric(metrics, "calls_direct_imported") +
    metric(metrics, "calls_indirect");
  const rows = [
    ["Branches", metric(metrics, "branches") + metric(metrics, "conditional_branches")],
    ["Calls", calls],
    ["Memory ops", metric(metrics, "potentially_trapping_memory")],
    ["Loops", metric(metrics, "loops")],
    ["SIMD", metric(metrics, "simd_instructions")],
  ];
  const bars = document.getElementById("wasm-bars");
  bars.replaceChildren();
  for (const [label, value] of rows) {
    const percent = Math.min(100, value / instructions * 100);
    const row = document.createElement("div");
    row.className = "wasm-bar-row";
    const name = document.createElement("span");
    name.textContent = label;
    const track = document.createElement("div");
    track.className = "wasm-bar-track";
    const fill = document.createElement("div");
    fill.className = "wasm-bar-fill";
    fill.style.width = percent + "%";
    track.append(fill);
    const amount = document.createElement("span");
    amount.className = "wasm-bar-value";
    amount.textContent = formatNumber(value) + " · " + percent.toFixed(percent < 1 ? 2 : 1) + "%";
    row.append(name, track, amount);
    bars.append(row);
  }
}

function renderShape(metrics) {
  const rows = [
    ["Functions", "functions_defined", "functions_imported"],
    ["Tables", "tables_defined", "tables_imported"],
    ["Globals", "globals_defined", "globals_imported"],
    ["Memories", "memories_defined", "memories_imported"],
  ];
  const body = document.getElementById("wasm-shape");
  body.replaceChildren();
  for (const [label, definedName, importedName] of rows) {
    const row = document.createElement("tr");
    for (const value of [
      label,
      formatNumber(metric(metrics, definedName)),
      formatNumber(metric(metrics, importedName)),
    ]) {
      const cell = document.createElement(label === value ? "th" : "td");
      cell.textContent = value;
      if (cell.tagName === "TH") cell.scope = "row";
      row.append(cell);
    }
    body.append(row);
  }
}

function renderReport(name, metrics, csv) {
  rawCSV = csv;
  document.getElementById("wasm-report-name").textContent = name;
  document.getElementById("wasm-report-summary").textContent =
    formatNumber(metric(metrics, "sections")) + " sections · " +
    formatNumber(metric(metrics, "types")) + " types · " +
    formatNumber(metric(metrics, "data_segments")) + " data segments";
  document.getElementById("wasm-size").textContent = formatBytes(metric(metrics, "module_bytes"));
  document.getElementById("wasm-instructions").textContent =
    formatNumber(metric(metrics, "instructions"));
  document.getElementById("wasm-functions").textContent =
    formatNumber(metric(metrics, "functions_defined"));
  document.getElementById("wasm-data").textContent = formatBytes(metric(metrics, "data_bytes"));
  document.getElementById("wasm-raw-csv").textContent = csv;
  renderTraits(metrics);
  renderMemory(metrics);
  renderBars(metrics);
  renderShape(metrics);
  report.hidden = false;
}

async function inspectBytes(name, bytes, sourcePath = "", currentInspection = ++inspectionNumber) {
  report.hidden = true;
  copyStatus.textContent = "";
  status.textContent = "Inspecting " + name + "…";
  await new Promise((resolve) => requestAnimationFrame(resolve));
  try {
    if (bytes.length > MAX_MODULE_BYTES) {
      throw Error("Module exceeds the inspector's 8 MiB input capacity.");
    }
    const csv = countModule(bytes);
    if (currentInspection !== inspectionNumber) return;
    renderReport(name, parseCounts(csv), csv);
    status.textContent = "Measured " + formatBytes(bytes.length) + " locally.";
    const url = new URL(location.href);
    if (sourcePath === "") {
      url.searchParams.delete("module");
    } else {
      url.searchParams.set("module", sourcePath);
    }
    history.replaceState(null, "", url);
  } catch (error) {
    if (currentInspection !== inspectionNumber) return;
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

async function inspectPath(path) {
  const currentInspection = ++inspectionNumber;
  report.hidden = true;
  status.textContent = "Fetching " + shortName(path) + "…";
  try {
    const response = await fetch(path);
    if (!response.ok) throw Error("Could not fetch module: HTTP " + response.status);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (currentInspection !== inspectionNumber) return;
    await inspectBytes(shortName(path), bytes, path, currentInspection);
  } catch (error) {
    if (currentInspection !== inspectionNumber) return;
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

moduleSelect.addEventListener("change", () => {
  if (moduleSelect.value !== "") inspectPath(moduleSelect.value);
});

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  moduleSelect.selectedIndex = -1;
  await inspectBytes(file.name, new Uint8Array(await file.arrayBuffer()));
});

for (const eventName of ["dragenter", "dragover"]) {
  inspector.addEventListener(eventName, (event) => {
    event.preventDefault();
    inspector.classList.add("is-dragging");
  });
}
for (const eventName of ["dragleave", "drop"]) {
  inspector.addEventListener(eventName, (event) => {
    event.preventDefault();
    inspector.classList.remove("is-dragging");
  });
}
inspector.addEventListener("drop", async (event) => {
  const file = event.dataTransfer?.files?.[0];
  if (!file) return;
  moduleSelect.selectedIndex = -1;
  await inspectBytes(file.name, new Uint8Array(await file.arrayBuffer()));
});

document.getElementById("wasm-copy-csv").addEventListener("click", async () => {
  await navigator.clipboard.writeText(rawCSV);
  copyStatus.textContent = "Copied.";
});

populateCatalog();
const requestedModule = new URL(location.href).searchParams.get("module");
const initialModule = modulePaths.includes(requestedModule) ? requestedModule : DEFAULT_MODULE;
moduleSelect.value = initialModule;
await inspectPath(initialModule);
</script>

The activity bars compare each count with the module's total decoded
instruction count. Categories can overlap: for example, a memory instruction
may also be potentially trapping. These are factual counts, not a security or
performance score.

## Download

- <a href="/application/wasm/wasm-counts.wasm" download>wasm-counts.wasm</a> — <qip-content-size src="/application/wasm/wasm-counts.wasm"></qip-content-size>
## CLI equivalent

```bash
qip run -i component.wasm -- components/application/wasm/wasm-counts.wasm
```
