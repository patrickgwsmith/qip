<title>QIP component debugger</title>

# QIP component debugger

Load a QIP Content component and step through its WebAssembly instructions.
Everything runs locally in your browser.

<style>
.debugger-shell {
  display: grid;
  gap: 0.8rem;
}
.debugger-source,
.debugger-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.debugger-source button,
.debugger-source select,
.debugger-source input,
.debugger-controls button,
.debugger-upload {
  font: inherit;
}
.debugger-catalog {
  display: inline-flex;
  gap: 0.4rem;
  align-items: center;
}
.debugger-catalog select {
  max-width: min(58ch, 75vw);
}
.debugger-controls kbd {
  margin-left: 0.4rem;
}
.debugger-upload {
  position: relative;
  display: inline-flex;
  padding: 0.4rem 0.75rem;
  border: 1px solid currentColor;
  border-radius: 0.35rem;
  cursor: pointer;
}
.debugger-upload input {
  position: absolute;
  width: 1px;
  height: 1px;
  opacity: 0;
}
.debugger-screen {
  box-sizing: border-box;
  width: min(100%, calc(80ch + 2rem + 2px));
  justify-self: start;
  min-height: 36rem;
  margin: 0;
  padding: 1rem;
  overflow: auto;
  border: 1px solid color-mix(in srgb, currentColor 30%, transparent);
  border-radius: 0.5rem;
  background: #111;
  color: #e8e8e8;
  font: 13px/1.25 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  white-space: pre;
  tab-size: 2;
}
.debugger-screen:focus {
  outline: 3px solid color-mix(in srgb, #1689ff 65%, transparent);
  outline-offset: 2px;
}
.debugger-text-input {
  display: grid;
  gap: 0.25rem;
  width: min(100%, calc(80ch + 2rem + 2px));
}
.debugger-text-input textarea {
  min-height: 5rem;
  padding: 0.5rem;
  resize: vertical;
  font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.debugger-text-input code {
  color: #d670d6;
}
</style>

<div class="debugger-shell">
  <div class="debugger-source">
    <button id="debugger-sample" type="button">Load wc.wasm</button>
    <label class="debugger-catalog">
      <span>Site component</span>
      <select id="debugger-component">
        <option value="">Loading catalog…</option>
      </select>
    </label>
    <label class="debugger-upload">
      <span>Choose .wasm</span>
      <input id="debugger-file" type="file" accept="application/wasm,.wasm">
    </label>
    <label class="debugger-upload">
      <span>Choose input</span>
      <input id="debugger-input" type="file">
    </label>
    <label>
      Instruction budget
      <input id="debugger-instruction-budget" type="number" min="1" max="1000000" step="1000" value="100000">
    </label>
    <span id="debugger-status" role="status" aria-live="polite">Loading debugger…</span>
  </div>
  <label id="debugger-text-input" class="debugger-text-input" hidden>
    <span>Text input <code id="debugger-text-input-pointer"></code></span>
    <textarea id="debugger-text" rows="4" spellcheck="false" placeholder="Enter the component input"></textarea>
  </label>
  <pre id="debugger-screen" class="debugger-screen" tabindex="0" aria-label="Debugger screen">Loading…</pre>
  <div class="debugger-controls" aria-label="Debugger controls and keyboard shortcuts">
    <button type="button" data-debug-key="32">Continue <kbd>Space</kbd></button>
    <button type="button" data-debug-key="110">Step over <kbd>N</kbd> <kbd>F10</kbd></button>
    <button type="button" data-debug-key="65362">Step back <kbd>↑</kbd></button>
    <button type="button" data-debug-key="65364">Step into <kbd>↓</kbd></button>
    <button type="button" data-debug-key="102">Step out <kbd>F</kbd> <kbd>Shift-F11</kbd></button>
    <button type="button" data-debug-key="114">Restart <kbd>R</kbd></button>
    <button type="button" data-debug-key="120">Examine memory <kbd>X</kbd></button>
    <button type="button" data-debug-key="109">Memory map <kbd>M</kbd></button>
    <button type="button" data-debug-prefix="120" data-debug-key="65362">Previous memory page <kbd>X</kbd> <kbd>↑</kbd></button>
    <button type="button" data-debug-prefix="120" data-debug-key="65364">Next memory page <kbd>X</kbd> <kbd>↓</kbd></button>
    <button type="button" data-debug-key="105">Counters <kbd>I</kbd></button>
    <button type="button" data-debug-key="118">Variable format <kbd>V</kbd></button>
    <button type="button" data-debug-key="63">Help <kbd>?</kbd></button>
  </div>
</div>

Choose a published component or a local `.wasm` file. For text components,
type in the text box or paste while the debugger screen has focus. Use `X I`
for input memory, `X O` for output memory, `X R` for the last read, and `X W`
for the last write. Press `M` to switch between memory bytes and the page map.
While examine mode is active, Up and Down Arrow page through memory.

Open the browser console and press a debugger key to see render timings. The
page reports the complete synchronous update, the `innerHTML` assignment, a
forced style and layout pass, and the wait for the next animation frame. To
measure paint and compositing, record the keypress in the browser's Performance
panel. The page adds timestamp markers to that recording. Developer Tools and
console logging add some overhead, so compare several keypresses.

<script type="module">
import { parseCSV } from "/elements/qip-search.js";
import { contentComponent, contentTypeUTF8 } from "/qip-runner.js";

const debuggerModulePromise = WebAssembly.compileStreaming(
  fetch("/interactive/qipdb.wasm"),
);
const plainText = contentTypeUTF8("text/plain");
const htmlText = contentTypeUTF8("text/html");
const ansiHTMLPromise = WebAssembly.compileStreaming(
  fetch("/text/ansi-sgr-to-html.wasm"),
).then((module) => contentComponent(plainText, module, htmlText));
const ansiHTMLPrefix = "<!doctype html><meta charset=\"utf-8\"><" + "pre>";
const ansiHTMLSuffix = "</" + "pre>";
const catalogURL = "/data/component-catalog.csv";
const catalogHeader = "path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes";
const screen = document.getElementById("debugger-screen");
const status = document.getElementById("debugger-status");
const componentSelect = document.getElementById("debugger-component");
const fileInput = document.getElementById("debugger-file");
const targetInput = document.getElementById("debugger-input");
const instructionBudget = document.getElementById("debugger-instruction-budget");
const textInputPanel = document.getElementById("debugger-text-input");
const textInputPointer = document.getElementById("debugger-text-input-pointer");
const textInput = document.getElementById("debugger-text");
let instance = null;
let ansiToHTML = null;
let updateTime = 1n;
let currentComponent = null;
let currentInput = null;
let textInputTimer = 0;
let renderMeasurementNumber = 0;
const qipBoundary = "uuid-00000000-0000-0000-0000-000000000000";
const textEncoder = new TextEncoder();
const defaultWCInput = "The quick brown fox jumps over the lazy dog";

function elapsedMilliseconds(start, end) {
  return (end - start).toFixed(3) + " ms";
}

function beginRenderMeasurement(key) {
  const number = ++renderMeasurementNumber;
  const label = "QIP debugger keypress #" + number + " (" + JSON.stringify(key) + ")";
  const measurement = {
    label,
    start: performance.now(),
    innerHTMLStart: 0,
    innerHTMLEnd: 0,
  };
  console.time(label + ": synchronous update");
  console.timeStamp(label + ": start");
  return measurement;
}

function finishRenderMeasurement(measurement) {
  const synchronousEnd = performance.now();
  console.timeEnd(measurement.label + ": synchronous update");

  const layoutStart = performance.now();
  // Reading scrollHeight makes the browser resolve pending style and layout.
  // Keep this read inside the measurement: it changes the work being measured.
  void screen.scrollHeight;
  const layoutEnd = performance.now();

  console.log(measurement.label, {
    "keypress handler through innerHTML": elapsedMilliseconds(
      measurement.start,
      synchronousEnd,
    ),
    "innerHTML assignment": elapsedMilliseconds(
      measurement.innerHTMLStart,
      measurement.innerHTMLEnd,
    ),
    "forced style and layout": elapsedMilliseconds(layoutStart, layoutEnd),
    "keypress handler through layout": elapsedMilliseconds(
      measurement.start,
      layoutEnd,
    ),
  });
  console.timeStamp(measurement.label + ": DOM and layout complete");

  requestAnimationFrame(() => {
    console.log(
      measurement.label + ": next animation frame after " +
      elapsedMilliseconds(measurement.start, performance.now()) +
      " (paint follows this callback)",
    );
    console.timeStamp(measurement.label + ": next animation frame");
  });
}

function componentName(path) {
  return path.slice(path.lastIndexOf("/") + 1);
}

async function populateComponentCatalog() {
  const response = await fetch(catalogURL);
  if (!response.ok) throw Error("Could not fetch the component catalog: HTTP " + response.status);
  const rows = parseCSV(await response.text());
  if (rows.shift()?.join(",") !== catalogHeader) throw Error("The component catalog has an unexpected header");
  const paths = rows.map((fields, index) => {
    if (fields.length !== 7 || !fields[0].startsWith("/") || !fields[0].endsWith(".wasm")) {
      throw Error("Invalid component catalog row " + (index + 2));
    }
    return fields[0];
  }).sort();

  componentSelect.replaceChildren();
  const prompt = document.createElement("option");
  prompt.value = "";
  prompt.textContent = "Choose a published component…";
  componentSelect.append(prompt);
  const groups = new Map();
  for (const path of paths) {
    const category = path.slice(1, path.lastIndexOf("/"));
    if (!groups.has(category)) groups.set(category, []);
    groups.get(category).push(path);
  }
  for (const [category, categoryPaths] of groups) {
    const group = document.createElement("optgroup");
    group.label = category;
    for (const path of categoryPaths) {
      const option = document.createElement("option");
      option.value = path;
      option.textContent = componentName(path);
      group.append(option);
    }
    componentSelect.append(group);
  }
}

function readI32Export(exports, name) {
  const value = exports[name]();
  if (!Number.isInteger(value) || value < 0) throw Error(name + " returned an invalid value");
  return value;
}

function renderText(inputSize, measurement = null) {
  const bits = BigInt.asUintN(64, instance.exports.render(inputSize));
  if ((bits & (1n << 63n)) !== 0n) throw Error("Debugger rejected its input");
  const size = Number(bits & 0xffff_ffffn);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const capacity = readI32Export(instance.exports, "output_utf8_cap");
  if (size > capacity || pointer + size > instance.exports.memory.buffer.byteLength) {
    throw Error("Debugger returned output outside its declared buffer");
  }
  const ansi = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(instance.exports.memory.buffer, pointer, size),
  );
  const document = ansiToHTML(ansi);
  if (!document.startsWith(ansiHTMLPrefix) || !document.endsWith(ansiHTMLSuffix)) {
    throw Error("ANSI renderer returned an unexpected HTML document");
  }
  if (measurement) measurement.innerHTMLStart = performance.now();
  screen.innerHTML = document.slice(ansiHTMLPrefix.length, -ansiHTMLSuffix.length);
  if (measurement) measurement.innerHTMLEnd = performance.now();
}

function replacedBoundary(body, from, to) {
  const source = new Uint8Array(body);
  const fromBytes = textEncoder.encode("--" + from);
  const toBytes = textEncoder.encode("--" + to);
  const chunks = [];
  let copied = 0;
  for (let index = 0; index + fromBytes.length <= source.length; index++) {
    const atLineStart = index === 0 || (source[index - 2] === 13 && source[index - 1] === 10);
    if (!atLineStart) continue;
    let matches = true;
    for (let offset = 0; offset < fromBytes.length; offset++) {
      if (source[index + offset] !== fromBytes[offset]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    const suffix = index + fromBytes.length;
    const isDelimiter = source[suffix] === 13 && source[suffix + 1] === 10;
    const isClosing = source[suffix] === 45 && source[suffix + 1] === 45;
    if (!isDelimiter && !isClosing) continue;
    chunks.push(source.slice(copied, index), toBytes);
    copied = suffix;
    index = suffix - 1;
  }
  chunks.push(source.slice(copied));
  const size = chunks.reduce((total, chunk) => total + chunk.length, 0);
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
}

async function debuggerForm(component, input) {
  const form = new FormData();
  const componentPath = component.path ? component.path.slice(1) : component.name;
  form.append("component", new Blob([component.bytes], { type: "application/wasm" }), componentPath);
  if (input) {
    form.append("input", new Blob([input.bytes], { type: "application/octet-stream" }), input.name);
  }
  const response = new Response(form);
  const contentType = response.headers.get("content-type") || "";
  const match = /(?:^|;)\s*boundary=([^;]+)$/.exec(contentType);
  if (!match) throw Error("Browser did not serialize FormData as multipart/form-data");
  return replacedBoundary(await response.arrayBuffer(), match[1], qipBoundary);
}

async function inspectInputContract(component) {
  if (component.acceptsText !== undefined) return component;
  try {
    const module = await WebAssembly.compile(component.bytes);
    const acceptsText = WebAssembly.Module.exports(module).some(
      (item) => item.kind === "function" && item.name === "input_utf8_cap",
    );
    return { ...component, acceptsText };
  } catch {
    return { ...component, acceptsText: false };
  }
}

async function loadTarget(component, input = null, focusScreen = true) {
  component = await inspectInputContract(component);
  const { name, bytes } = component;
  const displayName = component.path ?? name;
  status.textContent = "Loading " + displayName + "…";
  textInputPanel.hidden = !component.acceptsText;
  textInputPointer.textContent = "";
  if (bytes.byteLength > 1024 * 1024) throw Error("Component exceeds the debugger's 1 MiB module limit");
  if (input && input.bytes.byteLength > 8 * 1024 * 1024) throw Error("Input exceeds the debugger's 8 MiB component-input limit");
  const [module, ansiRenderer] = await Promise.all([debuggerModulePromise, ansiHTMLPromise]);
  ansiToHTML = ansiRenderer;
  instance = (await WebAssembly.instantiate(module, {}));
  const formBytes = await debuggerForm(component, input);
  const inputPointer = readI32Export(instance.exports, "input_ptr");
  const inputCapacity = readI32Export(instance.exports, "input_bytes_cap");
  if (formBytes.byteLength > inputCapacity) throw Error("Component and input exceed the debugger's multipart input limit");
  if (inputPointer + inputCapacity > instance.exports.memory.buffer.byteLength) {
    throw Error("Debugger input buffer is outside memory");
  }
  new Uint8Array(instance.exports.memory.buffer, inputPointer, formBytes.byteLength).set(formBytes);
  renderText(formBytes.byteLength);
  if (component.acceptsText) {
    const pointer = readI32Export(instance.exports, "target_input_ptr");
    textInputPointer.textContent = "input_ptr=0x" + pointer.toString(16).padStart(8, "0");
  }
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();
  updateTime = 2n;
  currentComponent = component;
  currentInput = input;
  const inputStatus = input ? " with " + input.name + " (" + input.bytes.byteLength + " B)" : "";
  status.textContent = "Debugging " + displayName + inputStatus + " locally. Focus the screen to use keyboard shortcuts or paste text input.";
  if (focusScreen) screen.focus();
}

function dispatch(keysym, shift = false, alt = false, measurement = null) {
  if (!instance) return;
  instance.exports.begin_update_at(updateTime++);
  const appliedBudget = instance.exports.uniform_set_instruction_budget(instructionBudget.valueAsNumber);
  if (appliedBudget !== instructionBudget.valueAsNumber) instructionBudget.value = appliedBudget;
  instance.exports.key_event(keysym, 1 | (shift ? 1 << 2 : 0) | (alt ? 1 << 4 : 0));
  instance.exports.finish_update();
  renderText(0, measurement);
  if (measurement) finishRenderMeasurement(measurement);
}

function showTextInputBytes(input) {
  if (!currentComponent?.acceptsText) return;
  if (!input) {
    textInput.value = "";
    return;
  }
  try {
    textInput.value = new TextDecoder("utf-8", { fatal: true }).decode(input.bytes);
  } catch {
    textInput.value = "";
  }
}

function keyboardCommand(event) {
  if (event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey && event.code === "BracketLeft") {
    return [0x5b, false, true];
  }
  if (event.metaKey || event.ctrlKey || event.altKey) return null;
  if (event.key === "F5") return [0xffc2, false];
  if (event.key === "F10") return [0xffc7, false];
  if (event.key === "F11") return [0xffc8, event.shiftKey];
  if (event.key === "ArrowUp") return [0xff52, false];
  if (event.key === "ArrowDown") return [0xff54, false];
  if (event.key === " ") return [0x20, false];
  if (event.key === "Enter") return [0xff0d, false];
  if (event.key === "Escape") return [0xff1b, false];
  if (event.key === "Backspace") return [0xff08, false];
  if (event.key === "?") return [0x3f, false];
  if (/^[0-9a-fA-FxXiIoOwWmM]$/.test(event.key) || ["n", "N", "s", "S", "r", "R"].includes(event.key)) {
    return [event.key.codePointAt(0), false];
  }
  return null;
}

screen.addEventListener("keydown", (event) => {
  const command = keyboardCommand(event);
  if (!command) return;
  event.preventDefault();
  dispatch(command[0], command[1], command[2], beginRenderMeasurement(event.key));
});

for (const button of document.querySelectorAll("[data-debug-key]")) {
  button.addEventListener("click", () => {
    if (button.dataset.debugPrefix) dispatch(Number(button.dataset.debugPrefix));
    dispatch(
      Number(button.dataset.debugKey),
      button.hasAttribute("data-debug-shift"),
      button.hasAttribute("data-debug-alt"),
    );
    screen.focus();
  });
}

document.getElementById("debugger-sample").addEventListener("click", async () => {
  try {
    const response = await fetch("/text/wc.wasm");
    if (!response.ok) throw Error("Could not fetch wc.wasm: HTTP " + response.status);
    targetInput.value = "";
    textInput.value = defaultWCInput;
    componentSelect.value = "";
    await loadTarget(
      { name: "wc.wasm", bytes: new Uint8Array(await response.arrayBuffer()) },
      { name: "input.txt", bytes: textEncoder.encode(defaultWCInput) },
    );
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

componentSelect.addEventListener("change", async () => {
  const path = componentSelect.value;
  if (!path) return;
  try {
    status.textContent = "Fetching " + path + "…";
    const response = await fetch(path);
    if (!response.ok) throw Error("Could not fetch " + path + ": HTTP " + response.status);
    fileInput.value = "";
    targetInput.value = "";
    textInput.value = "";
    await loadTarget({
      name: componentName(path),
      path,
      bytes: new Uint8Array(await response.arrayBuffer()),
    });
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  try {
    componentSelect.value = "";
    await loadTarget(
      { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) },
      currentInput,
    );
    showTextInputBytes(currentInput);
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

targetInput.addEventListener("change", async () => {
  const file = targetInput.files?.[0];
  if (!file || !currentComponent) return;
  try {
    const input = { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) };
    await loadTarget(currentComponent, input);
    showTextInputBytes(input);
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

textInput.addEventListener("input", () => {
  clearTimeout(textInputTimer);
  const component = currentComponent;
  const value = textInput.value;
  textInputTimer = setTimeout(async () => {
    if (!component || currentComponent !== component) return;
    try {
      targetInput.value = "";
      await loadTarget(component, { name: "input.txt", bytes: textEncoder.encode(value) }, false);
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : String(error);
    }
  }, 250);
});

screen.addEventListener("paste", async (event) => {
  if (!currentComponent) return;
  const pasted = event.clipboardData?.getData("text/plain");
  if (pasted === undefined) return;
  event.preventDefault();
  try {
    targetInput.value = "";
    if (currentComponent.acceptsText) textInput.value = pasted;
    await loadTarget(currentComponent, { name: "paste.txt", bytes: textEncoder.encode(pasted) });
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

populateComponentCatalog().catch((error) => {
  componentSelect.replaceChildren();
  const option = document.createElement("option");
  option.value = "";
  option.textContent = "Component catalog unavailable";
  componentSelect.append(option);
  componentSelect.disabled = true;
  console.error(error);
});
document.getElementById("debugger-sample").click();
</script>

Not every QIP component is supported yet. The interpreter accepts modules up
to 1 MiB with no imports, one memory up to 128 MiB, and one fixed `funcref`
table with up to 4,096 entries. It supports active function-index element
segments and typed `call_indirect`, but not table mutation. An unsupported
component shows the reason in the debugger screen.

Download: <a href="/interactive/qipdb.wasm" download>qipdb.wasm</a>
(<qip-content-size src="/interactive/qipdb.wasm"></qip-content-size>).
