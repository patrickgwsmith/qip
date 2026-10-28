<title>Flurry: looped WGSL vs persistent state</title>

# Flurry: looped WGSL vs persistent state

[Flurry](https://github.com/calumr/flurry) is Calum Robinson's 2002
screensaver, which Apple shipped with Mac OS X. Glowing streams of smoke whip
around a dark screen. This page ports its Classic preset (five streams in
tie-dye colors) two ways, from the Mac source and the version in
[xscreensaver](https://www.jwz.org/xscreensaver/) (`hacks/glx/flurry*.c`).
Flurry is © 2002 Calum Robinson and licensed under the
[BSD 3-Clause License](/licenses/flurry-LICENSE.txt).

1. **Looped WGSL:** a stateless shader draws each frame from the time alone. The page runs it with WebGPU and as WebAssembly compiled by [`wgsl-to-wasm.wasm`](/text/wgsl/wgsl-to-wasm.wasm), and compares the two.
2. **Persistent state:** a [`<qip-play>`](/play) component keeps Flurry's particles and its last frame in memory, and draws each new frame on top of the previous one, as Flurry does.

## How Flurry draws a frame

- **A star and five sparks** fly along fixed orbits. Their positions are sums
  of sines and cosines of the time, so any frame's positions can be computed
  directly.
- **Smoke particles** leave the star, one per stream each frame, aimed at the
  stream's spark. Each frame, every spark pulls every particle with
  inverse-square gravity, its own stream's spark 8 times as hard. A particle
  lives 2.5 s, widening and dimming as it ages. At 50 fps, about 625 are
  alive at once.
- **Each particle** is drawn as a quad of animated smoke texture, stretched
  along its motion that frame, and added to the screen (`GL_SRC_ALPHA, GL_ONE`).
- **The previous frame** isn't cleared. Flurry darkens it with a black
  rectangle at alpha 5 × frame time, capped at 0.2: 0.1 at its intended 50 fps.
  Old light drops below one 8-bit level after about 53 frames, about 1.1 s.

A particle's path depends on every frame before it, so a shader can't compute
it from the time. The looped version approximates it; the `<qip-play>`
version runs the simulation itself.

## 1. Looped WGSL: every frame from scratch

<style>
.flurry {
  --flurry-width: min(90em, 100vw - 2em);
  box-sizing: border-box;
  width: var(--flurry-width);
  margin-inline: calc((100% - var(--flurry-width)) / 2);
  display: grid;
  gap: 1rem;
}
.flurry-controls {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem 1.25rem;
}
.flurry-controls label {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.flurry-controls output {
  min-width: 4.5em;
  font-variant-numeric: tabular-nums;
}
.flurry-outputs {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 24em), 1fr));
  gap: 1rem;
}
.flurry figure {
  margin: 0;
}
.flurry canvas,
.flurry-play canvas {
  display: block;
  width: 100%;
  height: auto;
  border-radius: 0.35rem;
  background: #000;
}
.flurry figcaption {
  margin-top: 0.35rem;
  font-size: 0.85em;
  font-variant-numeric: tabular-nums;
}
.flurry-error {
  color: #c33;
}
.flurry-summary {
  min-height: 1.5rem;
  margin: 0;
  font-variant-numeric: tabular-nums;
}
.flurry-sources {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 30em), 1fr));
  gap: 1rem;
}
.flurry-sources label {
  display: grid;
  gap: 0.35rem;
  font-size: 0.85em;
}
.flurry-sources textarea {
  box-sizing: border-box;
  width: 100%;
  min-height: 24rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
  tab-size: 2;
}
.flurry-play {
  max-width: 640px;
}
</style>

<div class="flurry">
  <div class="flurry-controls">
    <label>time <input id="flurry-time" type="range" min="0" max="600" step="0.02" value="140"><output id="flurry-time-value">140.00 s</output></label>
    <label>gain <input id="flurry-gain" type="range" min="0" max="8" step="0.1" value="2.5"><output id="flurry-gain-value">2.5</output></label>
    <label>Size <select id="flurry-size"><option value="640x400">640×400</option><option value="320x200">320×200</option></select></label>
    <button id="flurry-play" type="button">Play</button>
  </div>
  <div class="flurry-outputs">
    <figure><canvas id="flurry-gpu" width="640" height="400"></canvas><figcaption id="flurry-gpu-caption">WebGPU</figcaption></figure>
    <figure><canvas id="flurry-wasm" width="640" height="400"></canvas><figcaption id="flurry-wasm-caption">WebAssembly</figcaption></figure>
    <figure><canvas id="flurry-diff" width="640" height="400"></canvas><figcaption>Absolute difference ×255: black → red → yellow, so yellow is a whole 8-bit level or more</figcaption></figure>
  </div>
  <p id="flurry-summary" class="flurry-summary" aria-live="polite">Loading…</p>
  <div class="flurry-sources">
    <label>Pass 1, points (41×10 pixels)<textarea id="flurry-points-source" spellcheck="false"></textarea></label>
    <label>Pass 2, ribbons (every pixel)<textarea id="flurry-ribbons-source" spellcheck="false"></textarea></label>
  </div>
</div>

The looped version replaces the particle simulation with a formula. A particle
born `age` seconds ago is placed partway along the line from where the star
was at its birth towards where its spark was a quarter of the way through its
flight, `0.28·age + 0.03·age²` of the way along. We fitted that curve and the
quarter to the positions in a run of Flurry's own simulation. The real
particles scatter about 140 units around the fitted line, so the shader widens
older smoke to match.

It runs as two fragment shaders, each the same WGSL on both sides:

1. **Points** computes 41 points along each of the 5 ribbons, and each segment's color, into a 41×10 corner of an RGBA32F texture. The rest of the texture stays black, and only its size is used.
2. **Ribbons** draws every pixel by looping over all 200 segments, adding a soft capsule for each one that's near. It reads the points with `textureLoad`.

The split keeps the star and spark trigonometry out of the per-pixel loop.
Each frame still redraws 2.5 s of history at every pixel, so the work grows
with how much history it reconstructs. The ribbons don't have Flurry's smoke
texture, and the shader doesn't add the 1.1 s motion blur from the fade.

The star and sparks take `sin` and `cos` of angles up to about 140 radians.
WGSL doesn't bound the GPU's error outside [−π, π], while the Wasm build
reduces the angle by π/2 first. So the two sides' points can drift apart, and a
point that moves moves the edge of a ribbon. The summary reports how far the
points moved and how many pixels differ by a whole 8-bit level. In headless
Chrome on a Mac at the default time, the points moved by about 0.015 px and no
pixel differed by a level.

<script type="text/wgsl" id="flurry-points">
// Flurry's Classic preset, after Calum Robinson's Flurry. BSD license:
// qip.dev/licenses/flurry-LICENSE.txt
// The star and five sparks are closed-form functions of time, so this pass
// needs no state. It writes the ribbon through each stream's smoke: pixel
// (k, i) holds stream i's point for the particle born k/40 of 2.5 s ago as
// (x, y, radius, visible), and pixel (k, i + 5) holds its segment's color.
override time: f32 = 140.0; // 0..600
override color_seed: f32 = 37.0; // 0..300

@group(0) @binding(0) var src: texture_2d<f32>;

const SEGMENTS: i32 = 40;
const STREAMS: i32 = 5;
const LIFE: f32 = 2.5;
const STREAM_SIZE: f32 = 25000.0;
const EXPANSION: f32 = 10000.0;

// UpdateStar and UpdateSpark without their random jitter, which Flurry
// scales by fieldCoherence = 0.
fn orbit(t: f32, mystery: f32, cf_add: f32, range: f32) -> vec3f {
  let angle = t * 0.0046019;
  let cf = (cos(7.0 * angle) + cos(3.0 * angle) + cos(13.0 * angle)) / 6.0 + cf_add;
  let p = 6.2831853 * mystery / 1800.0;
  let x = range * cf * cos(11.0 * (p + 3.0 * angle));
  let y = range * cf * sin(12.0 * (p + 4.0 * angle));
  let z = range * cos(23.0 * (p + 12.0 * angle));
  var r = angle * 0.501 + 5.01 * mystery / 1800.0;
  var c = cos(r);
  var s = sin(r);
  let x1 = x * c - y * s;
  let y1 = y * c + x * s;
  let x2 = x1 * c - z * s;
  let z2 = z * c + x1 * s;
  let y3 = y1 * c - z2 * s;
  let z3 = z2 * c + y1 * s + 2000.0;
  r = angle * 2.501 + 85.01 * mystery / 1800.0;
  c = cos(r);
  s = sin(r);
  return vec3f(x2 * c - y3 * s, y3 * c + x2 * s, z3);
}

// UpdateSparkColour in tie-dye mode, which cycles every 4.5 s.
fn spark_color(t: f32, mystery: f32) -> vec3f {
  let angle = t * 0.0046019;
  let p = 6.2831853 * mystery / 1800.0;
  let phase = (t + color_seed) * 1.3962634;
  let base = 0.109375 * (cos(vec3f(phase, phase + 2.0943951, phase + 4.1887902)) + 1.0);
  return base + 0.0625 * vec3f(
    0.5 + cos(15.0 * (p + 3.0 * angle)) + sin(7.0 * (p + angle)),
    0.5 + sin(p + angle),
    0.5 + cos(37.0 * (p + angle)));
}

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let k = i32(pos.x);
  let row = i32(pos.y);
  if (k > SEGMENTS || row >= 2 * STREAMS) {
    return vec4f(0.0);
  }
  let size = vec2f(textureDimensions(src));
  let stream = row % STREAMS;
  let mystery = floor(1800.0 * f32(stream + 1) / 13.0);
  let ratio = size.x / 1024.0;
  let max_width = (STREAM_SIZE + LIFE * EXPANSION) * ratio;
  if (row >= STREAMS) {
    // The segment from point k - 1 to k, colored at its middle age. The
    // factors are the means of Flurry's random color and alpha scales.
    let age = LIFE * (f32(k) - 0.5) / f32(SEGMENTS);
    let cm = (1.375 - (STREAM_SIZE + age * EXPANSION) * ratio / max_width) * 0.5318296;
    // GL clamps vertex colors, so negative channels add nothing.
    return vec4f(max(spark_color(time - age, mystery), vec3f(0.0)) * (0.8875 * 0.8015625 * cm * cm), 1.0);
  }
  // A particle born `age` ago left the star then and heads for where its
  // spark was a quarter of the way through its flight. g is fitted to
  // Flurry's own simulation.
  let age = LIFE * f32(k) / f32(SEGMENTS);
  let born = time - age;
  let star = orbit(born, 5.0, 0.75, 250.0);
  let spark = orbit(born + 0.25 * age, mystery, 2.0, 1000.0);
  let p = mix(star, spark, 0.28 * age + 0.03 * age * age);
  let width = (STREAM_SIZE + age * EXPANSION) * ratio;
  // Flurry projects with y up; rows here run down.
  let screen = vec2f(p.x * size.x / p.z + size.x * 0.5, size.y * 0.5 - p.y * size.x / p.z);
  return vec4f(screen, max(1.0, width / max(p.z, 25.0)), select(0.0, 1.0, p.z >= 25.0));
}
</script>

<script type="text/wgsl" id="flurry-ribbons">
// Draws the ribbons from the points pass: a soft capsule per segment, summed
// additively like Flurry's GL_SRC_ALPHA, GL_ONE blending. Every pixel loops
// over all 200 segments, so the cost grows with the history it reconstructs.
override gain: f32 = 2.5; // 0..8

@group(0) @binding(0) var points: texture_2d<f32>;

const POINTS: i32 = 41;
const STREAMS: i32 = 5;
const LIFE: f32 = 2.5;

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let size = vec2f(textureDimensions(points));
  let da = LIFE / f32(POINTS - 1);
  var sum = vec3f(0.0);
  for (var i = 0; i < STREAMS; i++) {
    var prev = textureLoad(points, vec2i(0, i), 0);
    for (var k = 1; k < POINTS; k++) {
      let cur = textureLoad(points, vec2i(k, i), 0);
      let a = prev.xy;
      let ab = cur.xy - a;
      let w = 0.5 * (prev.z + cur.z);
      // Older smoke has spread out; widen it and keep its total light.
      let spread = 1.25 * w + 0.025 * size.x * (f32(k) - 0.5) * da;
      let len2 = dot(ab, ab);
      let h = clamp(dot(pos.xy - a, ab) / max(len2, 1e-6), 0.0, 1.0);
      let d = length(pos.xy - a - ab * h) / spread;
      if (d < 1.0 && prev.w * cur.w > 0.0) {
        let falloff = cos(d * 1.5707964);
        // A segment longer than its width spreads its particles along it.
        let density = 50.0 * da * min(1.0, 2.0 * spread / sqrt(len2 + 1e-6));
        let color = textureLoad(points, vec2i(k, i + STREAMS), 0).rgb;
        sum += color * (gain * density * falloff * falloff * 1.25 * w / spread);
      }
      prev = cur;
    }
  }
  return vec4f(min(sum, vec3f(1.0)), 1.0);
}
</script>

<script type="module">
const pointsSource = document.getElementById("flurry-points-source");
const ribbonsSource = document.getElementById("flurry-ribbons-source");
const timeInput = document.getElementById("flurry-time");
const timeValue = document.getElementById("flurry-time-value");
const gainInput = document.getElementById("flurry-gain");
const gainValue = document.getElementById("flurry-gain-value");
const sizeSelect = document.getElementById("flurry-size");
const playButton = document.getElementById("flurry-play");
const gpuCanvas = document.getElementById("flurry-gpu");
const gpuCaption = document.getElementById("flurry-gpu-caption");
const wasmCanvas = document.getElementById("flurry-wasm");
const wasmCaption = document.getElementById("flurry-wasm-caption");
const diffCanvas = document.getElementById("flurry-diff");
const summary = document.getElementById("flurry-summary");
pointsSource.value = document.getElementById("flurry-points").textContent.trim() + "\n";
ribbonsSource.value = document.getElementById("flurry-ribbons").textContent.trim() + "\n";

const [compilerModule, gpu] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/text/wgsl/wgsl-to-wasm.wasm")),
  initGPU(),
]);
const compiler = new WebAssembly.Instance(compilerModule, {}).exports;
const wasmModules = new Map();
const gpuPipelines = new Map();
let gpuTargets = null;
let running = false;
let pending = false;
let playing = false;

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

function size() {
  const [width, height] = sizeSelect.value.split("x").map(Number);
  return { width, height };
}

// Compiles once per source. Each module has one instance, so its memory is
// allocated once and later frames only set uniforms and render.
function wasmFor(source) {
  if (wasmModules.has(source)) return wasmModules.get(source);
  const start = performance.now();
  const input = new TextEncoder().encode(source);
  if (input.byteLength > compiler.input_utf8_cap()) throw Error("shader exceeds compiler input capacity");
  new Uint8Array(compiler.memory.buffer, compiler.input_ptr(), input.byteLength).set(input);
  const bits = BigInt.asUintN(64, compiler.render(input.byteLength));
  const length = Number(bits & 0xffff_ffffn);
  if (bits >> 63n) {
    const modes = compiler.failure_modes_per_input_offset();
    const before = source.slice(0, new TextDecoder().decode(input.subarray(0, Math.floor(length / modes))).length).split("\n");
    throw Error("rejected at line " + before.length + ":" + (before.at(-1).length + 1) + " with mode " + length % modes);
  }
  const ptr = Number(bits >> 32n);
  const module = new WebAssembly.Module(new Uint8Array(compiler.memory.buffer, ptr, length));
  const compiled = { instance: new WebAssembly.Instance(module, {}), ms: performance.now() - start };
  wasmModules.set(source, compiled);
  return compiled;
}

function runWasm(compiled, input, width, uniforms) {
  const exports = compiled.instance.exports;
  for (const [name, value] of Object.entries(uniforms)) exports["uniform_set_" + name]?.(value);
  exports.uniform_set_width(width);
  const bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  if (bytes.byteLength > exports.input_bytes_cap()) throw Error("input exceeds component capacity");
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.byteLength).set(bytes);
  const bits = BigInt.asUintN(64, exports.render(bytes.byteLength));
  if (bits >> 63n) throw Error("render rejected the input");
  const length = Number(bits & 0xffff_ffffn);
  const ptr = Number((bits >> 32n) & 0x7fff_ffffn);
  return new Float32Array(exports.memory.buffer.slice(ptr, ptr + length));
}

function fullscreenVertexModule() {
  gpu.vertexModule ??= gpu.device.createShaderModule({
    code: `@vertex fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
  return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}`,
  });
  return gpu.vertexModule;
}

// Overrides are pipeline constants, so a new time means a new pipeline. The
// cache keeps the latest few.
async function gpuPipeline(source, constants) {
  const key = source + "\0" + JSON.stringify(constants);
  if (gpuPipelines.has(key)) return gpuPipelines.get(key);
  const start = performance.now();
  const module = gpu.device.createShaderModule({ code: source });
  const errors = (await module.getCompilationInfo()).messages.filter((m) => m.type === "error");
  if (errors.length > 0) throw Error("line " + errors[0].lineNum + ":" + errors[0].linePos + " " + errors[0].message);
  const pipeline = await gpu.device.createRenderPipelineAsync({
    layout: "auto",
    vertex: { module: fullscreenVertexModule() },
    fragment: { module, entryPoint: "main", constants, targets: [{ format: "rgba32float" }] },
  });
  const entry = { pipeline, ms: performance.now() - start };
  gpuPipelines.set(key, entry);
  if (gpuPipelines.size > 8) gpuPipelines.delete(gpuPipelines.keys().next().value);
  return entry;
}

function targetsFor(width, height) {
  if (gpuTargets?.width === width && gpuTargets?.height === height) return gpuTargets;
  for (const resource of gpuTargets?.resources ?? []) resource.destroy();
  const usage = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST;
  const texture = () => gpu.device.createTexture({ size: [width, height], format: "rgba32float", usage });
  const bytesPerRow = Math.ceil(width * 16 / 256) * 256;
  const readback = () => gpu.device.createBuffer({ size: bytesPerRow * height, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
  gpuTargets = { width, height, bytesPerRow, blank: texture(), points: texture(), output: texture(), pointsReadback: readback(), outputReadback: readback() };
  gpuTargets.resources = [gpuTargets.blank, gpuTargets.points, gpuTargets.output, gpuTargets.pointsReadback, gpuTargets.outputReadback];
  return gpuTargets;
}

function drawPass(encoder, pipeline, source, target) {
  const pass = encoder.beginRenderPass({
    colorAttachments: [{ view: target.createView(), loadOp: "clear", clearValue: [0, 0, 0, 0], storeOp: "store" }],
  });
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, gpu.device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: source.createView() }],
  }));
  pass.draw(3);
  pass.end();
}

async function readTexture(targets, buffer) {
  const { width, height, bytesPerRow } = targets;
  await buffer.mapAsync(GPUMapMode.READ);
  try {
    const mapped = new Float32Array(buffer.getMappedRange());
    const output = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++) {
      output.set(mapped.subarray(y * bytesPerRow / 4, y * bytesPerRow / 4 + width * 4), y * width * 4);
    }
    return output;
  } finally {
    buffer.unmap();
  }
}

async function runGPU(width, height, time, gain) {
  const points = await gpuPipeline(pointsSource.value, { time });
  const ribbons = await gpuPipeline(ribbonsSource.value, { gain });
  const targets = targetsFor(width, height);
  const device = gpu.device;
  const start = performance.now();
  device.pushErrorScope("validation");
  const encoder = device.createCommandEncoder();
  drawPass(encoder, points.pipeline, targets.blank, targets.points);
  drawPass(encoder, ribbons.pipeline, targets.points, targets.output);
  encoder.copyTextureToBuffer({ texture: targets.points }, { buffer: targets.pointsReadback, bytesPerRow: targets.bytesPerRow }, [width, height]);
  encoder.copyTextureToBuffer({ texture: targets.output }, { buffer: targets.outputReadback, bytesPerRow: targets.bytesPerRow }, [width, height]);
  device.queue.submit([encoder.finish()]);
  const error = await device.popErrorScope();
  if (error) throw Error(error.message);
  const [pointData, output] = await Promise.all([
    readTexture(targets, targets.pointsReadback),
    readTexture(targets, targets.outputReadback),
  ]);
  return { pointData, output, ms: performance.now() - start, pipelineMs: points.ms + ribbons.ms };
}

function runAllWasm(width, height, time, gain) {
  const points = wasmFor(pointsSource.value);
  const ribbons = wasmFor(ribbonsSource.value);
  const start = performance.now();
  const pointData = runWasm(points, new Float32Array(width * height * 4), width, { time });
  const pointsMs = performance.now() - start;
  const output = runWasm(ribbons, pointData, width, { gain });
  return { pointData, output, pointsMs, ms: performance.now() - start, compileMs: points.ms + ribbons.ms };
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
  const { width, height } = size();
  const time = Number(timeInput.value);
  const gain = Number(gainInput.value);
  timeValue.value = time.toFixed(2) + " s";
  gainValue.value = gain.toFixed(1);

  let wasm = null;
  try {
    wasm = runAllWasm(width, height, time, gain);
    drawFloats(wasmCanvas, wasm.output, width, height);
    wasmCaption.className = "";
    wasmCaption.textContent = "WebAssembly: points " + formatMs(wasm.pointsMs) + ", total " + formatMs(wasm.ms);
  } catch (error) {
    // A trap may leave an instance half written, so compile fresh next run.
    wasmModules.clear();
    showError(wasmCanvas, wasmCaption, "WebAssembly: " + error.message);
  }

  let webgpu = null;
  if (gpu.error) {
    showError(gpuCanvas, gpuCaption, "WebGPU: " + gpu.error);
  } else {
    try {
      webgpu = await runGPU(width, height, time, gain);
      drawFloats(gpuCanvas, webgpu.output, width, height);
      gpuCaption.className = "";
      gpuCaption.textContent = "WebGPU: pipelines " + formatMs(webgpu.pipelineMs) + ", run " + formatMs(webgpu.ms);
    } catch (error) {
      showError(gpuCanvas, gpuCaption, "WebGPU: " + error.message);
    }
  }

  if (wasm && webgpu) {
    summary.textContent = compare(webgpu, wasm, width, height);
  } else {
    clearCanvas(diffCanvas);
    summary.textContent = "Both runs must succeed to compare them.";
  }
}

// Points live in the 41×5 corner; their x and y are screen positions.
function compare(gpuRun, wasmRun, width, height) {
  let pointShift = 0;
  for (let row = 0; row < 5; row++) {
    for (let k = 0; k < 41; k++) {
      const i = (row * width + k) * 4;
      const shift = Math.hypot(gpuRun.pointData[i] - wasmRun.pointData[i], gpuRun.pointData[i + 1] - wasmRun.pointData[i + 1]);
      if (Number.isFinite(shift)) pointShift = Math.max(pointShift, shift);
    }
  }
  const a = gpuRun.output;
  const b = wasmRun.output;
  const heat = new Uint8ClampedArray(width * height * 4);
  let floats = 0;
  let levels = 0;
  let maxAbs = 0;
  for (let p = 0; p < width * height; p++) {
    let pixelMax = 0;
    for (let c = 0; c < 3; c++) {
      const abs = Math.abs(a[p * 4 + c] - b[p * 4 + c]);
      if (abs > 0) floats++;
      pixelMax = Math.max(pixelMax, abs);
    }
    maxAbs = Math.max(maxAbs, pixelMax);
    if (Math.round(pixelMax * 255) >= 1) levels++;
    const intensity = Math.min(pixelMax * 255, 1);
    heat[p * 4] = intensity * 255;
    heat[p * 4 + 1] = intensity * intensity * 255;
    heat[p * 4 + 3] = 255;
  }
  drawBytes(diffCanvas, heat, width, height);
  if (floats === 0) return "Identical: every color channel matches bit for bit.";
  return floats.toLocaleString() + " color channels differ. " + levels.toLocaleString() +
    " pixels differ by at least one 8-bit level; the largest difference is " + maxAbs.toPrecision(3) +
    ". Ribbon points moved by up to " + pointShift.toPrecision(3) + " px.";
}

function drawFloats(canvas, floats, width, height) {
  const bytes = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < bytes.length; i++) bytes[i] = Math.round(floats[i] * 255);
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
  caption.className = "flurry-error";
  caption.textContent = message;
}

function formatMs(ms) {
  return (ms < 10 ? ms.toFixed(1) : Math.round(ms)) + " ms";
}

// Plays in real time. Each frame waits for both renders, so the slower one
// sets the frame rate.
async function play() {
  let last = performance.now();
  while (playing) {
    await run();
    await new Promise(requestAnimationFrame);
    const now = performance.now();
    const time = (Number(timeInput.value) + (now - last) / 1000) % 600;
    last = now;
    timeInput.value = String(time);
  }
}

let editTimer = 0;
for (const textarea of [pointsSource, ribbonsSource]) {
  textarea.addEventListener("input", () => {
    clearTimeout(editTimer);
    editTimer = setTimeout(run, 300);
  });
}
timeInput.addEventListener("input", run);
gainInput.addEventListener("input", run);
sizeSelect.addEventListener("change", run);
playButton.addEventListener("click", () => {
  playing = !playing;
  playButton.textContent = playing ? "Pause" : "Play";
  if (playing) play();
});

run();
</script>

## 2. Persistent state: a `<qip-play>` component

<div class="flurry-play">
<qip-play canvas-width="100%">
  <source src="/gui/flurry.wasm" type="application/wasm" />
</qip-play>
</div>

[`flurry.wasm`](/gui/flurry.wasm) is a port of Flurry's update and draw code
to Zig (`gui/flurry.zig` in the qip repository). It keeps two things in its memory between
frames:

- **The particles:** 3,600 slots, each with a position, velocity, color and
  age, integrated under the sparks' gravity every 20 ms.
- **The framebuffer:** 640×400 RGB floats. Each step multiplies it by 0.9, as
  Flurry's black rectangle at alpha 0.1 does. Then it rasterizes about 625
  textured smoke quads into it with additive blending, using Flurry's 8×8
  atlas of noisy smoke frames.

`<qip-play>` asks for a wake every 20 ms. A frame costs only that step's work,
whatever the length of the trails, because the trails are already in the
framebuffer. If the page falls behind, the component runs up to 4 steps per
wake and drops the rest.

It differs from Flurry in a few ways:

- **Steady gravity:** Flurry scales gravity by `42.5 / (frames / fTime)`.
  Its `fTime` starts at a random 0–300 s, so for the first minutes the ratio
  is far below the frame rate and gravity is many times stronger. The port
  uses the value that ratio settles towards at 50 fps, 0.85.
- **A float framebuffer:** GL's 8-bit framebuffer rounds each fade, which can
  leave faint smoke that never quite fades. The port's float framebuffer
  decays smoothly.
- **Fixed steps:** the port always steps 20 ms. Flurry uses the real frame
  time, and scales its brightness and fade to match.
- **Its own random numbers:** the texture speckle and particle jitter use a
  fixed xorshift seed, so each load plays the same.

## Looped vs persistent

| Property | Looped WGSL | `<qip-play>` |
| --- | --- | --- |
| State between frames | None: a frame is a function of `time` | Particles and the last frame |
| Smoke paths | Fitted formula | Flurry's simulation |
| Trails | Redrawn from 2.5 s of history | Kept in the framebuffer, faded 10% per frame |
| Work per frame | 200 segments at every pixel | About 625 smoke quads, plus a fade of every pixel |
| Scrub to any time | Yes | No, it must simulate up to it |
| Runs on | WebGPU, or WebAssembly via `wgsl-to-wasm` | WebAssembly |
