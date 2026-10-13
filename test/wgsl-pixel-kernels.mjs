import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import {
  fusePixelKernels,
  fusedUniformValues,
  pixelKernelNames,
  pixelKernelsToComputeShader,
} from "../text/wgsl/pixel-kernels.mjs";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const compiler = join(process.cwd(), "text/wgsl/wgsl-compute-to-wasm.wasm");
// The strict profile expects Content getters, so Tile components skip it.
const tileCheckers = ["application/wasm/wasm-bounded-loops.wasm", "application/wasm/wasm-nontrapping-divides.wasm"].map(
  (path) => join(process.cwd(), path),
);

const TILE_FLOATS = 64 * 64 * 4;

async function compile(source) {
  const directory = await mkdtemp(join(tmpdir(), "qip-pixel-kernel-"));
  const sourcePath = join(directory, "kernel.wgsl");
  const modulePath = join(directory, "kernel.wasm");
  await writeFile(sourcePath, source);
  await execFileAsync(qip, ["run", "-i", sourcePath, "-o", modulePath, compiler]);
  return modulePath;
}

async function instantiateTile(modulePath, uniforms = {}) {
  const { instance } = await WebAssembly.instantiate(await readFile(modulePath));
  for (const [name, value] of Object.entries(uniforms)) instance.exports[`uniform_set_${name}`](value);
  return instance.exports;
}

// Runs one 64x64 tile through the Tile ABI and returns a copy of the result.
function runTile(exports, tile) {
  assert.ok(exports.input_bytes_cap() >= tile.byteLength);
  const view = new Float32Array(exports.memory.buffer, exports.input_ptr(), TILE_FLOATS);
  view.set(tile);
  exports.tile_rgba32float_64x64(0, 0);
  return Float32Array.from(view);
}

// Deterministic RGBA in [0, 1], including the endpoints.
function sampleTile() {
  const tile = new Float32Array(TILE_FLOATS);
  let state = 0x9e3779b9;
  for (let i = 0; i < tile.length; i++) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    tile[i] = i % 97 === 0 ? 0 : i % 89 === 0 ? 1 : state / 0xffffffff;
  }
  return tile;
}

function assertBitsEqual(actual, expected) {
  const a = new Uint32Array(actual.buffer, actual.byteOffset, actual.length);
  const e = new Uint32Array(expected.buffer, expected.byteOffset, expected.length);
  const at = a.findIndex((bits, i) => bits !== e[i]);
  assert.equal(at, -1, `pixel ${at >> 2} lane ${at & 3}: ${actual[at]} !== ${expected[at]}`);
}

const kernelPaths = {
  brightness: "components/rgba/brightness.wgsl",
  invert: "components/rgba/invert.wgsl",
};

async function kernelSource(name) {
  return readFile(kernelPaths[name], "utf8");
}

test("committed component builds match their kernel sources", async () => {
  const tile = sampleTile();
  for (const [name, uniforms] of [
    ["brightness", { brightness: 0.3 }],
    ["brightness", { brightness: -0.4 }],
    ["invert", {}],
  ]) {
    const compiled = await instantiateTile(await compile(await kernelSource(name)), uniforms);
    const committed = await instantiateTile(join(process.cwd(), `components/rgba/${name}.wasm`), uniforms);
    assertBitsEqual(runTile(compiled, tile), runTile(committed, tile));
  }
});

test("brightness kernel clamps its uniform and preserves alpha", async () => {
  const exports = await instantiateTile(await compile(await kernelSource("brightness")), { brightness: 2 });
  const tile = sampleTile();
  const out = runTile(exports, tile);
  for (let i = 0; i < out.length; i += 4) {
    assert.deepEqual([out[i], out[i + 1], out[i + 2]], [1, 1, 1]);
    assert.equal(out[i + 3], tile[i + 3]);
  }
});

test("fused point kernels match running each stage in turn", async () => {
  const stages = [
    ["brightness", { brightness: 0.25 }],
    ["invert", {}],
    ["brightness", { brightness: -0.6 }],
  ];
  const sources = await Promise.all(stages.map(([name]) => kernelSource(name)));
  const fused = fusePixelKernels(sources);
  assert.deepEqual(pixelKernelNames(fused.source), ["s0_pixel", "s1_pixel", "s2_pixel"]);
  const uniforms = fusedUniformValues(
    fused.uniforms,
    stages.map(([, values]) => values),
  );
  assert.deepEqual(uniforms, { s0_brightness: 0.25, s2_brightness: -0.6 });

  const tile = sampleTile();
  let expected = tile;
  for (const [i, [, values]] of stages.entries()) {
    expected = runTile(await instantiateTile(await compile(sources[i]), values), expected);
  }
  const fusedModule = await compile(fused.source);
  assertBitsEqual(runTile(await instantiateTile(fusedModule, uniforms), tile), expected);
  await execFileAsync(qip, ["run", "-i", fusedModule, "--", ...tileCheckers]);
});

test("fusion renames module-scope names but not members", () => {
  const { source, uniforms } = fusePixelKernels([
    "const r = 0.5;\noverride gain: f32 = 1.0;\nfn pixel(c: vec4f) -> vec4f { return vec4f(c.r * r * gain, c.gba); }",
  ]);
  assert.match(source, /const s0_r = 0\.5;/);
  assert.match(source, /c\.r \* s0_r \* s0_gain/);
  assert.deepEqual([...uniforms[0]], [["gain", "s0_gain"]]);
  assert.throws(() => fusedUniformValues(uniforms, [{ missing: 1 }]), /stage 0 has no uniform missing/);
});

test("compute wrapper calls every kernel in order for WebGPU", async () => {
  const fused = fusePixelKernels([await kernelSource("brightness"), await kernelSource("invert")]);
  const shader = pixelKernelsToComputeShader(fused.source);
  assert.match(shader, /var c = qip_src\[id\.x\];\n  c = s0_pixel\(c\);\n  c = s1_pixel\(c\);\n  qip_dst\[id\.x\] = c;/);
  assert.match(shader, /@compute @workgroup_size\(64\)/);
});
