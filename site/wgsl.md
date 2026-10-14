<title>WGSL compute shaders: WebGPU vs WebAssembly</title>

# WGSL compute shaders: WebGPU vs WebAssembly

Pick an effect, or edit the shader. The page runs the same WGSL on your GPU
with WebGPU, and as WebAssembly that it compiles in your browser with
[`wgsl-compute-to-wasm.wasm`](/text/wgsl/wgsl-compute-to-wasm.wasm). Then it
compares the two outputs float for float. Nothing is uploaded.

<style>
.wgsl {
  display: grid;
  gap: 1rem;
}
.wgsl-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem 1.25rem;
  align-items: center;
}
.wgsl-controls label {
  display: inline-flex;
  gap: 0.4rem;
  align-items: center;
}
.wgsl-controls select,
.wgsl-controls button,
.wgsl-controls input {
  font: inherit;
}
.wgsl-controls output {
  min-width: 3.5em;
  font-variant-numeric: tabular-nums;
}
.wgsl-upload input {
  max-width: 13rem;
}
.wgsl-outputs {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.75rem;
}
.wgsl-outputs figure {
  margin: 0;
}
.wgsl-outputs canvas {
  display: block;
  width: 100%;
  height: auto;
  image-rendering: pixelated;
  border-radius: 0.35rem;
  background: repeating-conic-gradient(#8884 0 25%, transparent 0 50%) 0 0 / 16px 16px;
}
.wgsl-outputs figcaption {
  margin-top: 0.35rem;
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}
.wgsl-error {
  color: #c33;
}
.wgsl-summary {
  min-height: 1.5rem;
  margin: 0;
  font-variant-numeric: tabular-nums;
}
.wgsl-source {
  box-sizing: border-box;
  width: 100%;
  min-height: 24rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
  tab-size: 2;
}
@media (max-width: 720px) {
  .wgsl-outputs {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>

<div class="wgsl">
  <div class="wgsl-controls">
    <label>Effect <select id="wgsl-shader"></select></label>
    <label class="wgsl-upload">Image <input id="wgsl-file" type="file" accept="image/*"></label>
    <button id="wgsl-camera" type="button">Use camera</button>
  </div>
  <div id="wgsl-uniforms" class="wgsl-controls"></div>
  <div class="wgsl-outputs">
    <figure><canvas id="wgsl-input"></canvas><figcaption id="wgsl-input-caption">Input</figcaption></figure>
    <figure><canvas id="wgsl-gpu"></canvas><figcaption id="wgsl-gpu-caption">WebGPU</figcaption></figure>
    <figure><canvas id="wgsl-wasm"></canvas><figcaption id="wgsl-wasm-caption">WebAssembly</figcaption></figure>
    <figure><canvas id="wgsl-diff"></canvas><figcaption>Difference ×256, red to yellow</figcaption></figure>
  </div>
  <p id="wgsl-summary" class="wgsl-summary" aria-live="polite">Loading…</p>
  <textarea id="wgsl-source" class="wgsl-source" spellcheck="false" aria-label="WGSL source"></textarea>
</div>

## Why the outputs can differ

Wasm `f32` arithmetic is IEEE 754 with correct rounding, so the Wasm output is
the same on every machine. WGSL lets GPUs compute `sqrt` and division less
precisely, and shader compilers can reorder or fuse floating-point operations.
Those differences are a few ULP (units in the last place) and show only in the
heatmap. The ULP count looks large near zero, where adjacent floats are closest
together: 7e-7 can be hundreds of ULP. **Comic book** and **Bulge** compare
floats or turn them into pixel indexes, so a one-ULP change could move an
outline or a sampled pixel; whether it does depends on the GPU and the image.
**Mirror** and **Pop art** index with integers, so they should match bit for
bit.

## How it works

Each shader reads one `array<vec4f>` of RGBA32F pixels (16 bytes each),
up to 256×256, and writes one `vec4f` per invocation. Pixel values are the
image's sRGB values divided by 255, without conversion to linear light.

- **WebGPU:** the page creates a compute pipeline with `layout: "auto"`, passes
  each `override` as a pipeline constant, dispatches one invocation per pixel,
  and copies the output buffer back.
- **WebAssembly:** `wgsl-compute-to-wasm.wasm` compiles the source to a QIP
  content component. Each `override` becomes a `uniform_set_<name>` export, and
  `render` runs the entry point once per element with SIMD for `vec4f`.

The page sets `width` to the image width. A trailing `// min..max` comment on an
`override` gives it a slider. The compiler accepts a subset of WGSL: no loops,
no helper functions and no `sin`, `cos` or `pow`, so each effect reads its
neighbours one by one. Run it on the command line with `qip`:

```bash
qip run -i edges.wgsl -o edges.wasm text/wgsl/wgsl-compute-to-wasm.wasm
qip run -i photo.rgba32f -o edges.rgba32f edges.wasm -u width=256 -u threshold=0.3
```

To add an effect, add a `<script type="text/wgsl" data-name="…">` block to
this page.

<script type="text/wgsl" data-name="Edges">
// Sobel edge detection on luma. A threshold of 0 shows the gradient strength.
override width: u32 = 256;
override threshold: f32 = 0.0; // 0..1
override gain: f32 = 1.0; // 0..4

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  // Clamp neighbours to the edge of the image.
  let l = max(x, 1u) - 1u;
  let r = min(x + 1u, width - 1u);
  let u = (max(y, 1u) - 1u) * width;
  let m = y * width;
  let d = min(y + 1u, height - 1u) * width;
  let k = vec3f(0.2126, 0.7152, 0.0722);
  let tl = dot(src[u + l].rgb, k);
  let tm = dot(src[u + x].rgb, k);
  let tr = dot(src[u + r].rgb, k);
  let ml = dot(src[m + l].rgb, k);
  let mr = dot(src[m + r].rgb, k);
  let bl = dot(src[d + l].rgb, k);
  let bm = dot(src[d + x].rgb, k);
  let br = dot(src[d + r].rgb, k);
  let gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
  let gy = (bl + 2.0 * bm + br) - (tl + 2.0 * tm + tr);
  let g = sqrt(gx * gx + gy * gy) * gain;
  var e = min(g, 1.0);
  if threshold > 0.0 { e = select(0.0, 1.0, g > threshold); }
  dst[id.x] = vec4f(e, e, e, 1.0);
}
</script>

<script type="text/wgsl" data-name="Comic book">
// Three flat tones with black Sobel outlines.
override width: u32 = 256;
override outline: f32 = 0.35; // 0..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  let l = max(x, 1u) - 1u;
  let r = min(x + 1u, width - 1u);
  let u = (max(y, 1u) - 1u) * width;
  let m = y * width;
  let d = min(y + 1u, height - 1u) * width;
  let k = vec3f(0.2126, 0.7152, 0.0722);
  let tl = dot(src[u + l].rgb, k);
  let tm = dot(src[u + x].rgb, k);
  let tr = dot(src[u + r].rgb, k);
  let ml = dot(src[m + l].rgb, k);
  let mr = dot(src[m + r].rgb, k);
  let bl = dot(src[d + l].rgb, k);
  let bm = dot(src[d + x].rgb, k);
  let br = dot(src[d + r].rgb, k);
  let gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
  let gy = (bl + 2.0 * bm + br) - (tl + 2.0 * tm + tr);
  let c = src[id.x];
  let tone = floor(clamp(dot(c.rgb, k), 0.0, 0.999) * 3.0) / 2.0;
  var ink = mix(vec3f(0.15, 0.1, 0.35), vec3f(1.0, 0.95, 0.8), tone);
  if gx * gx + gy * gy > outline * outline { ink = vec3f(0.0); }
  dst[id.x] = vec4f(ink, 1.0);
}
</script>

<script type="text/wgsl" data-name="Thermal camera">
// Brightness mapped to a black-body style palette.
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let c = src[id.x];
  let t = clamp(dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722)), 0.0, 1.0) * 4.0;
  var h = mix(vec3f(0.0, 0.0, 0.25), vec3f(0.45, 0.0, 0.75), clamp(t, 0.0, 1.0));
  h = mix(h, vec3f(1.0, 0.0, 0.25), clamp(t - 1.0, 0.0, 1.0));
  h = mix(h, vec3f(1.0, 0.8, 0.0), clamp(t - 2.0, 0.0, 1.0));
  h = mix(h, vec3f(1.0), clamp(t - 3.0, 0.0, 1.0));
  dst[id.x] = vec4f(h, c.a);
}
</script>

<script type="text/wgsl" data-name="X-ray">
// Inverted brightness with a cold blue tint.
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let c = src[id.x];
  let l = 1.0 - dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722));
  dst[id.x] = vec4f(l * vec3f(0.8, 0.9, 1.0), c.a);
}
</script>

<script type="text/wgsl" data-name="Pop art">
// Four two-colour copies of the image, one per quadrant.
override width: u32 = 256;
override threshold: f32 = 0.45; // 0..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  let tile = select(0u, 1u, x * 2u >= width) + select(0u, 2u, y * 2u >= height);
  let sx = min(x * 2u % width, width - 1u);
  let sy = min(y * 2u % height, height - 1u);
  let c = src[sy * width + sx];
  let light = dot(c.rgb, vec3f(0.2126, 0.7152, 0.0722)) > threshold;
  var ink = vec3f(0.9, 0.1, 0.5);
  var paper = vec3f(1.0, 0.9, 0.1);
  if tile == 1u {
    ink = vec3f(0.1, 0.2, 0.7);
    paper = vec3f(1.0, 0.5, 0.6);
  } else if tile == 2u {
    ink = vec3f(0.0, 0.5, 0.3);
    paper = vec3f(0.6, 0.9, 1.0);
  } else if tile == 3u {
    ink = vec3f(0.4, 0.1, 0.6);
    paper = vec3f(1.0, 0.6, 0.2);
  }
  dst[id.x] = vec4f(select(ink, paper, light), 1.0);
}
</script>

<script type="text/wgsl" data-name="Sepia">
// Sepia tone, blended with the original by amount.
override amount: f32 = 1.0; // 0..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let c = src[id.x];
  let s = vec3f(
    dot(c.rgb, vec3f(0.393, 0.769, 0.189)),
    dot(c.rgb, vec3f(0.349, 0.686, 0.168)),
    dot(c.rgb, vec3f(0.272, 0.534, 0.131))
  );
  dst[id.x] = vec4f(mix(c.rgb, min(s, vec3f(1.0)), amount), c.a);
}
</script>

<script type="text/wgsl" data-name="Bulge">
// Bulge (strength > 0) or dent (strength < 0) around the centre, sampled
// nearest-neighbour.
override width: u32 = 256;
override strength: f32 = 0.6; // -1..1
override radius: f32 = 0.8; // 0.1..1

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  let height = n / width;
  let cx = f32(width) * 0.5;
  let cy = f32(height) * 0.5;
  let dx = f32(id.x % width) + 0.5 - cx;
  let dy = f32(id.x / width) + 0.5 - cy;
  let r = sqrt(dx * dx + dy * dy) / (radius * min(cx, cy));
  var s = 1.0;
  if r < 1.0 { s = mix(1.0, r, strength); }
  let sx = u32(clamp(cx + dx * s, 0.0, f32(width - 1u)));
  let sy = u32(clamp(cy + dy * s, 0.0, f32(height - 1u)));
  dst[id.x] = src[sy * width + sx];
}
</script>

<script type="text/wgsl" data-name="Mirror">
// The left half reflected onto the right. Integer indexing only, so WebGPU
// and Wasm should match exactly.
override width: u32 = 256;

@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  let x = id.x % width;
  let y = id.x / width;
  let mx = select(x, width - 1u - x, x >= width / 2u);
  dst[id.x] = src[y * width + mx];
}
</script>

<script type="module">
import { contentComponent, contentTypeBytes, contentTypeUTF8 } from "/qip-runner.js";

const MAX_SIDE = 256;
const COMPILE_FAILURES = ["syntax error", "unsupported WGSL", "type error", "unknown or duplicate name"];
const shaderSelect = document.getElementById("wgsl-shader");
const fileInput = document.getElementById("wgsl-file");
const cameraButton = document.getElementById("wgsl-camera");
const uniformsBox = document.getElementById("wgsl-uniforms");
const sourceInput = document.getElementById("wgsl-source");
const summary = document.getElementById("wgsl-summary");
const inputCanvas = document.getElementById("wgsl-input");
const inputCaption = document.getElementById("wgsl-input-caption");
const gpuCanvas = document.getElementById("wgsl-gpu");
const gpuCaption = document.getElementById("wgsl-gpu-caption");
const wasmCanvas = document.getElementById("wgsl-wasm");
const wasmCaption = document.getElementById("wgsl-wasm-caption");
const diffCanvas = document.getElementById("wgsl-diff");

const shaders = [...document.querySelectorAll('script[type="text/wgsl"]')];
for (const [index, script] of shaders.entries()) {
  shaderSelect.add(new Option(script.dataset.name, String(index)));
}

const [compilerModule, gpu] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/text/wgsl/wgsl-compute-to-wasm.wasm")),
  initGPU(),
]);
const compiler = contentComponent(
  contentTypeUTF8("text/wgsl"),
  compilerModule,
  contentTypeBytes("application/wasm"),
);

let image = testCard();
let uniformValues = new Map();
let wasmCache = { source: null, module: null, error: null, ms: 0 };
let gpuCache = { key: null, pipeline: null, error: null, ms: 0 };
let gpuBuffers = { key: null, buffers: [], entries: [], output: null, readback: null, bindGroups: null };
let running = false;
let pending = false;
let camera = null;

async function initGPU() {
  if (!navigator.gpu) return { error: "This browser has no WebGPU." };
  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return { error: "No WebGPU adapter is available." };
    return { device: await adapter.requestDevice() };
  } catch (error) {
    return { error: error.message };
  }
}

// Reads what both runners need from the source: overrides (with an optional
// trailing `// min..max`), storage bindings, element size and workgroup size.
function parseShader(source) {
  const overrides = [];
  const overridePattern =
    /^\s*override\s+(\w+)\s*:\s*(f32|u32|i32)\s*(?:=\s*([^;]+))?;[ \t]*(?:\/\/\s*(-?[\d.]+)\s*\.\.\s*(-?[\d.]+))?/gm;
  for (const match of source.matchAll(overridePattern)) {
    overrides.push({
      name: match[1],
      type: match[2],
      value: Number.parseFloat(match[3] ?? "0") || 0,
      min: match[4] === undefined ? null : Number(match[4]),
      max: match[5] === undefined ? null : Number(match[5]),
    });
  }
  const bindings = [];
  const bindingPattern = /@binding\((\d+)\)\s*var<storage,\s*(read|read_write)>\s*\w+\s*:\s*array<(\w+(?:<\w+>)?)>/g;
  for (const match of source.matchAll(bindingPattern)) {
    bindings.push({ binding: Number(match[1]), access: match[2], element: match[3] });
  }
  const workgroup = /@workgroup_size\(\s*(\d+)/.exec(source);
  const entry = /@compute[\s\S]*?fn\s+(\w+)/.exec(source);
  return {
    overrides,
    bindings,
    elementSize: bindings.some((b) => b.element.startsWith("vec4")) ? 16 : 4,
    workgroupSize: workgroup ? Number(workgroup[1]) : 1,
    entry: entry ? entry[1] : "main",
  };
}

function renderUniformControls(overrides) {
  uniformsBox.replaceChildren();
  for (const o of overrides) {
    if (o.name === "width") continue;
    if (!uniformValues.has(o.name)) uniformValues.set(o.name, o.value);
    const label = document.createElement("label");
    const input = document.createElement("input");
    const output = document.createElement("output");
    const ranged = o.min !== null && o.max !== null;
    input.type = ranged ? "range" : "number";
    input.step = o.type === "f32" ? (ranged ? String((o.max - o.min) / 200) : "any") : "1";
    if (ranged) {
      input.min = String(o.min);
      input.max = String(o.max);
    }
    input.value = String(uniformValues.get(o.name));
    output.value = input.value;
    input.addEventListener("input", () => {
      uniformValues.set(o.name, Number(input.value));
      output.value = input.value;
      run();
    });
    label.append(o.name + " ", input);
    if (ranged) label.append(output);
    uniformsBox.append(label);
  }
}

function constantsFor(overrides) {
  const constants = {};
  for (const o of overrides) {
    constants[o.name] = o.name === "width" ? image.width : uniformValues.get(o.name) ?? o.value;
    if (o.type !== "f32") constants[o.name] = Math.trunc(constants[o.name]);
  }
  return constants;
}

function compileWasm(source) {
  if (wasmCache.source === source) return wasmCache;
  const start = performance.now();
  wasmCache = { source, module: null, error: null, ms: 0 };
  try {
    wasmCache.module = new WebAssembly.Module(compiler(source));
  } catch (error) {
    wasmCache.error = describeCompileError(source, error.message);
  }
  wasmCache.ms = performance.now() - start;
  return wasmCache;
}

function describeCompileError(source, message) {
  const match = /input offset (\d+) with mode (\d+)/.exec(message);
  if (!match) return message;
  const before = new TextDecoder().decode(new TextEncoder().encode(source).subarray(0, Number(match[1])));
  const lines = before.split("\n");
  return (COMPILE_FAILURES[Number(match[2])] ?? "rejected") +
    " at line " + lines.length + ":" + (lines.at(-1).length + 1);
}

// One instance per compiled module, so its memory is allocated once and
// slider changes only call the uniform setters again.
function runWasm(compiled, input, constants) {
  compiled.instance ??= new WebAssembly.Instance(compiled.module, {});
  const exports = compiled.instance.exports;
  for (const [name, value] of Object.entries(constants)) exports["uniform_set_" + name]?.(value);
  if (input.byteLength > exports.input_bytes_cap()) throw Error("input exceeds component capacity");
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.byteLength).set(input);
  const bits = BigInt.asUintN(64, exports.render(input.byteLength));
  if (bits >> 63n) throw Error("render rejected the input");
  const size = Number(bits & 0xffff_ffffn);
  const ptr = Number((bits >> 32n) & 0x7fff_ffffn);
  return new Float32Array(exports.memory.buffer.slice(ptr, ptr + size));
}

async function gpuPipeline(source, info, constants) {
  const key = source + "\0" + JSON.stringify(constants);
  if (gpuCache.key === key) return gpuCache;
  const start = performance.now();
  gpuCache = { key, pipeline: null, error: null, ms: 0 };
  const module = gpu.device.createShaderModule({ code: source });
  const errors = (await module.getCompilationInfo()).messages.filter((m) => m.type === "error");
  if (errors.length > 0) {
    gpuCache.error = "line " + errors[0].lineNum + ":" + errors[0].linePos + " " + errors[0].message;
  } else {
    try {
      gpuCache.pipeline = await gpu.device.createComputePipelineAsync({
        layout: "auto",
        compute: { module, entryPoint: info.entry, constants },
      });
    } catch (error) {
      gpuCache.error = error.message;
    }
  }
  gpuCache.ms = performance.now() - start;
  return gpuCache;
}

async function runGPU(pipeline, info, input) {
  const device = gpu.device;
  const count = input.byteLength / info.elementSize;
  const groups = Math.ceil(count / info.workgroupSize);
  if (groups > device.limits.maxComputeWorkgroupsPerDimension) {
    throw Error(groups + " workgroups exceeds this GPU's limit; raise @workgroup_size");
  }
  const { buffers, output, readback } = gpuBuffersFor(info, input.byteLength);
  if (output === null) throw Error("the shader needs a var<storage, read_write> buffer");
  for (const [i, b] of info.bindings.entries()) {
    if (b.access === "read" || info.bindings.length === 1) device.queue.writeBuffer(buffers[i], 0, input);
  }
  gpuBuffers.bindGroups.set(pipeline, gpuBuffers.bindGroups.get(pipeline) ??
    device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: gpuBuffers.entries }));
  device.pushErrorScope("validation");
  const encoder = device.createCommandEncoder();
  // The output starts zeroed, unless the shader works in place.
  for (const [i, b] of info.bindings.entries()) {
    if (b.access === "read_write" && info.bindings.length > 1) encoder.clearBuffer(buffers[i]);
  }
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, gpuBuffers.bindGroups.get(pipeline));
  pass.dispatchWorkgroups(groups);
  pass.end();
  encoder.copyBufferToBuffer(output, 0, readback, 0, input.byteLength);
  device.queue.submit([encoder.finish()]);
  const error = await device.popErrorScope();
  if (error) throw Error(error.message);
  await readback.mapAsync(GPUMapMode.READ);
  try {
    return new Float32Array(readback.getMappedRange().slice(0));
  } finally {
    readback.unmap();
  }
}

// Storage and readback buffers live until the shader's bindings or the image
// size change, like the wasm instance's memory. Slider changes keep them.
function gpuBuffersFor(info, byteLength) {
  const key = JSON.stringify(info.bindings) + "\0" + byteLength;
  if (gpuBuffers.key === key) return gpuBuffers;
  for (const buffer of gpuBuffers.buffers) buffer.destroy();
  gpuBuffers.readback?.destroy();
  const device = gpu.device;
  const usage = GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST;
  gpuBuffers = { key, buffers: [], entries: [], output: null, readback: null, bindGroups: new WeakMap() };
  for (const b of info.bindings) {
    const buffer = device.createBuffer({ size: byteLength, usage });
    if (b.access === "read_write") gpuBuffers.output = buffer;
    gpuBuffers.buffers.push(buffer);
    gpuBuffers.entries.push({ binding: b.binding, resource: { buffer } });
  }
  gpuBuffers.readback = device.createBuffer({
    size: byteLength,
    usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
  });
  return gpuBuffers;
}

async function run() {
  if (running) {
    pending = true;
    return;
  }
  running = true;
  try {
    do {
      pending = false;
      await runOnce();
    } while (pending);
  } finally {
    running = false;
  }
}

async function runOnce() {
  const source = sourceInput.value;
  const info = parseShader(source);
  const constants = constantsFor(info.overrides);
  const input = new Uint8Array(image.pixels.buffer);
  drawPixels(inputCanvas, image.pixels, image.width, image.height);
  inputCaption.textContent = "Input, " + image.width + "×" + image.height;

  let wasmOutput = null;
  const compiled = compileWasm(source);
  if (compiled.error) {
    showError(wasmCanvas, wasmCaption, "WebAssembly: " + compiled.error);
  } else {
    try {
      const start = performance.now();
      wasmOutput = runWasm(compiled, input, constants);
      const ms = performance.now() - start;
      drawPixels(wasmCanvas, wasmOutput, image.width, image.height);
      wasmCaption.className = "";
      wasmCaption.textContent = "WebAssembly: compile " + formatMs(compiled.ms) + ", run " + formatMs(ms);
    } catch (error) {
      // A trap may leave the instance half written, so start fresh next run.
      compiled.instance = null;
      showError(wasmCanvas, wasmCaption, "WebAssembly: " + error.message);
    }
  }

  let gpuOutput = null;
  if (gpu.error) {
    showError(gpuCanvas, gpuCaption, "WebGPU: " + gpu.error);
  } else {
    const pipeline = await gpuPipeline(source, info, constants);
    if (pipeline.error) {
      showError(gpuCanvas, gpuCaption, "WebGPU: " + pipeline.error);
    } else {
      try {
        const start = performance.now();
        gpuOutput = await runGPU(pipeline.pipeline, info, input);
        const ms = performance.now() - start;
        drawPixels(gpuCanvas, gpuOutput, image.width, image.height);
        gpuCaption.className = "";
        gpuCaption.textContent = "WebGPU: pipeline " + formatMs(pipeline.ms) + ", run " + formatMs(ms);
      } catch (error) {
        showError(gpuCanvas, gpuCaption, "WebGPU: " + error.message);
      }
    }
  }

  if (wasmOutput && gpuOutput) {
    summary.textContent = compare(gpuOutput, wasmOutput);
  } else {
    clearCanvas(diffCanvas);
    summary.textContent = "Both runs must succeed to compare them.";
  }
}

// Bitwise comparison. The heatmap dims matching pixels and colours
// differing ones from red to yellow by their largest channel difference.
function compare(a, b) {
  const aBits = new Int32Array(a.buffer);
  const bBits = new Int32Array(b.buffer);
  const pixels = image.width * image.height;
  const lanes = a.length / pixels;
  const heat = new Uint8ClampedArray(pixels * 4);
  let floats = 0;
  let pixelsDiffering = 0;
  let maxAbs = 0;
  let maxUlp = 0;
  for (let p = 0; p < pixels; p += 1) {
    let pixelMax = -1;
    for (let lane = 0; lane < lanes; lane += 1) {
      const i = p * lanes + lane;
      if (aBits[i] === bBits[i] || (Number.isNaN(a[i]) && Number.isNaN(b[i]))) continue;
      const abs = Math.abs(a[i] - b[i]);
      floats += 1;
      pixelMax = Math.max(pixelMax, abs);
      maxAbs = Math.max(maxAbs, abs);
      maxUlp = Math.max(maxUlp, Math.abs(orderedBits(aBits[i]) - orderedBits(bBits[i])));
    }
    const o = p * 4;
    if (pixelMax >= 0) {
      pixelsDiffering += 1;
      heat[o] = 255;
      heat[o + 1] = 40 + pixelMax * 256 * 215;
    } else {
      const v = 0.25 * (b[p * lanes] + b[p * lanes + 1] + b[p * lanes + 2]) / 3;
      heat[o] = heat[o + 1] = heat[o + 2] = v * 255;
    }
    heat[o + 3] = 255;
  }
  drawBytes(diffCanvas, heat, image.width, image.height);
  if (floats === 0) return "Identical: all " + a.length.toLocaleString() + " floats match bit for bit.";
  return floats.toLocaleString() + " of " + a.length.toLocaleString() + " floats differ, in " +
    pixelsDiffering.toLocaleString() + " pixels. Largest difference " + maxAbs.toPrecision(3) +
    " (" + maxUlp.toLocaleString() + " ULP).";
}

// Maps f32 bit patterns onto a line where adjacent floats differ by 1.
function orderedBits(bits) {
  return bits >= 0 ? bits : -(bits & 0x7fff_ffff);
}

function drawPixels(canvas, floats, width, height) {
  const bytes = new Uint8ClampedArray(width * height * 4);
  const lanes = floats.length / (width * height);
  for (let p = 0; p < width * height; p += 1) {
    for (let c = 0; c < 4; c += 1) {
      bytes[p * 4 + c] = lanes === 4 || c === 3 ? floats[p * lanes + Math.min(c, lanes - 1)] * 255 + 0.5 : 0;
    }
  }
  drawBytes(canvas, bytes, width, height);
}

function drawBytes(canvas, bytes, width, height) {
  canvas.width = width;
  canvas.height = height;
  canvas.getContext("2d").putImageData(new ImageData(bytes, width, height), 0, 0);
}

function clearCanvas(canvas) {
  canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
}

function showError(canvas, caption, message) {
  clearCanvas(canvas);
  caption.className = "wgsl-error";
  caption.textContent = message;
}

function formatMs(ms) {
  return (ms < 10 ? ms.toFixed(1) : Math.round(ms)) + " ms";
}

function pixelsFrom(source, sourceWidth, sourceHeight) {
  const scale = Math.min(1, MAX_SIDE / sourceWidth, MAX_SIDE / sourceHeight);
  const width = Math.max(1, Math.round(sourceWidth * scale));
  const height = Math.max(1, Math.round(sourceHeight * scale));
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context.drawImage(source, 0, 0, width, height);
  const bytes = context.getImageData(0, 0, width, height).data;
  const pixels = new Float32Array(bytes.length);
  for (let i = 0; i < bytes.length; i += 1) pixels[i] = bytes[i] / 255;
  return { width, height, pixels };
}

// A generated 256×192 test card: gradients, shapes, and text with hard edges.
function testCard() {
  const canvas = new OffscreenCanvas(256, 192);
  const context = canvas.getContext("2d");
  const sky = context.createLinearGradient(0, 0, 0, 192);
  sky.addColorStop(0, "#1b3a6b");
  sky.addColorStop(0.6, "#e98b5a");
  sky.addColorStop(1, "#f6d27a");
  context.fillStyle = sky;
  context.fillRect(0, 0, 256, 192);
  const sun = context.createRadialGradient(176, 92, 4, 176, 92, 44);
  sun.addColorStop(0, "#fff8d0");
  sun.addColorStop(1, "#f2a44a00");
  context.fillStyle = sun;
  context.fillRect(120, 40, 112, 112);
  context.fillStyle = "#24283b";
  context.beginPath();
  context.moveTo(0, 192);
  context.lineTo(0, 140);
  context.lineTo(60, 104);
  context.lineTo(110, 150);
  context.lineTo(170, 118);
  context.lineTo(256, 160);
  context.lineTo(256, 192);
  context.fill();
  context.fillStyle = "#ffffff";
  context.font = "bold 56px system-ui, sans-serif";
  context.fillText("WGSL", 16, 72);
  for (let i = 0; i < 8; i += 1) {
    context.fillStyle = "hsl(" + i * 45 + " 80% 55%)";
    context.fillRect(16 + i * 28, 168, 24, 16);
  }
  return pixelsFrom(canvas, 256, 192);
}

function selectShader() {
  sourceInput.value = shaders[Number(shaderSelect.value)].textContent.trim() + "\n";
  uniformValues = new Map();
  renderUniformControls(parseShader(sourceInput.value).overrides);
  run();
}

async function toggleCamera() {
  if (camera) {
    for (const track of camera.srcObject.getTracks()) track.stop();
    camera = null;
    cameraButton.textContent = "Use camera";
    return;
  }
  try {
    const video = document.createElement("video");
    video.muted = true;
    video.playsInline = true;
    video.srcObject = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 } });
    await video.play();
    camera = video;
    cameraButton.textContent = "Stop camera";
    const frame = async () => {
      if (camera !== video) return;
      if (!running) {
        image = pixelsFrom(video, video.videoWidth, video.videoHeight);
        await run();
      }
      requestAnimationFrame(frame);
    };
    frame();
  } catch (error) {
    summary.textContent = "Camera unavailable: " + error.message;
  }
}

let editTimer = 0;
sourceInput.addEventListener("input", () => {
  clearTimeout(editTimer);
  editTimer = setTimeout(() => {
    renderUniformControls(parseShader(sourceInput.value).overrides);
    run();
  }, 300);
});
shaderSelect.addEventListener("change", selectShader);
cameraButton.addEventListener("click", toggleCamera);
fileInput.addEventListener("change", async () => {
  const file = fileInput.files[0];
  if (!file) return;
  try {
    const bitmap = await createImageBitmap(file);
    image = pixelsFrom(bitmap, bitmap.width, bitmap.height);
    run();
  } catch (error) {
    summary.textContent = "Could not decode " + file.name + ": " + error.message;
  }
});

selectShader();
</script>
