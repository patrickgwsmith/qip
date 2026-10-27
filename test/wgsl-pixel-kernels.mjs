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
  pixelKernelPasses,
  pixelKernelsToComputeShader,
} from "../text/wgsl/pixel-kernels.mjs";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const compiler = join(process.cwd(), "text/wgsl/wgsl-to-wasm.wasm");
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

// Runs a whole image through the Tile ABI the way main.go does: tiles of 64,
// each padded by the module's halo with edge-clamped pixels, keeping only
// each tile's core.
function runImage(exports, pixels, width, height) {
  exports.uniform_set_width_and_height?.(width, height);
  const halo = Math.max(0, exports.calculate_halo_px?.() ?? 0);
  const span = 64 + 2 * halo;
  assert.ok(exports.input_bytes_cap() >= span * span * 16);
  const view = new Float32Array(exports.memory.buffer, exports.input_ptr(), span * span * 4);
  const out = new Float32Array(pixels.length);
  const clamp = (v, max) => Math.min(Math.max(v, 0), max - 1);
  for (let y = 0; y < height; y += 64) {
    for (let x = 0; x < width; x += 64) {
      for (let row = 0; row < span; row++) {
        for (let col = 0; col < span; col++) {
          const s = (clamp(y + row - halo, height) * width + clamp(x + col - halo, width)) * 4;
          view.set(pixels.subarray(s, s + 4), (row * span + col) * 4);
        }
      }
      exports.tile_rgba32float_64x64(x - halo, y - halo);
      for (let row = 0; row < Math.min(64, height - y); row++) {
        for (let col = 0; col < Math.min(64, width - x); col++) {
          const s = ((row + halo) * span + col + halo) * 4;
          out.set(view.subarray(s, s + 4), ((y + row) * width + x + col) * 4);
        }
      }
    }
  }
  return out;
}

// Deterministic RGBA in [0, 1], including the endpoints.
function sampleTile(floats = TILE_FLOATS) {
  const tile = new Float32Array(floats);
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
  "box-blur-3x3": "components/rgba/box-blur-3x3.wgsl",
  brightness: "components/rgba/brightness.wgsl",
  invert: "components/rgba/invert.wgsl",
};

// Not multiples of 64, so edge tiles are partial.
const WIDTH = 150;
const HEIGHT = 90;

async function kernelSource(name) {
  return readFile(kernelPaths[name], "utf8");
}

test("committed component builds match their kernel sources", async () => {
  const image = sampleTile(WIDTH * HEIGHT * 4);
  for (const [name, uniforms] of [
    ["box-blur-3x3", {}],
    ["brightness", { brightness: 0.3 }],
    ["brightness", { brightness: -0.4 }],
    ["invert", {}],
  ]) {
    const compiled = await instantiateTile(await compile(await kernelSource(name)), uniforms);
    const committed = await instantiateTile(join(process.cwd(), `components/rgba/${name}.wasm`), uniforms);
    assertBitsEqual(runImage(compiled, image, WIDTH, HEIGHT), runImage(committed, image, WIDTH, HEIGHT));
  }
});

test("box blur averages the 3x3 neighborhood, clamped at the image edges", async () => {
  const exports = await instantiateTile(await compile(await kernelSource("box-blur-3x3")));
  assert.equal(exports.calculate_halo_px(), 1);
  const image = sampleTile(WIDTH * HEIGHT * 4);
  const out = runImage(exports, image, WIDTH, HEIGHT);
  // The kernel's f32 operations, in its order.
  const f = Math.fround;
  const at = (x, y, lane) =>
    image[(Math.min(Math.max(y, 0), HEIGHT - 1) * WIDTH + Math.min(Math.max(x, 0), WIDTH - 1)) * 4 + lane];
  const row = (x, y, lane) => f(f(at(x - 1, y, lane) + at(x, y, lane)) + at(x + 1, y, lane));
  const expected = new Float32Array(image.length);
  for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
      for (let lane = 0; lane < 4; lane++) {
        const sum = f(f(row(x, y - 1, lane) + row(x, y, lane)) + row(x, y + 1, lane));
        expected[(y * WIDTH + x) * 4 + lane] = f(sum / 9);
      }
    }
  }
  assertBitsEqual(out, expected);
});

test("fused sampling kernels match running each stage in turn", async () => {
  const stages = [
    ["brightness", { brightness: 0.2 }],
    ["box-blur-3x3", {}],
    ["invert", {}],
    ["box-blur-3x3", {}],
    ["brightness", { brightness: -0.3 }],
  ];
  const sources = await Promise.all(stages.map(([name]) => kernelSource(name)));
  const fused = fusePixelKernels(sources);
  assert.deepEqual(pixelKernelPasses(fused.source), [["s0_pixel"], ["s1_pixel", "s2_pixel"], ["s3_pixel", "s4_pixel"]]);
  const uniforms = fusedUniformValues(
    fused.uniforms,
    stages.map(([, values]) => values),
  );

  const image = sampleTile(WIDTH * HEIGHT * 4);
  let expected = image;
  for (const [i, [, values]] of stages.entries()) {
    expected = runImage(await instantiateTile(await compile(sources[i]), values), expected, WIDTH, HEIGHT);
  }
  const fusedModule = await compile(fused.source);
  const exports = await instantiateTile(fusedModule, uniforms);
  assert.equal(exports.calculate_halo_px(), 2);
  assertBitsEqual(runImage(exports, image, WIDTH, HEIGHT), expected);
  await execFileAsync(qip, ["run", "-i", fusedModule, "--", ...tileCheckers]);
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
  assert.match(shader, /@compute @workgroup_size\(64\)\nfn qip_pass0\(/);
  assert.doesNotMatch(shader, /qip_pass1|fn sample|qip_width/);
});

test("compute wrapper starts a pass at each kernel that samples", async () => {
  const fused = fusePixelKernels([
    await kernelSource("invert"),
    await kernelSource("box-blur-3x3"),
    await kernelSource("brightness"),
  ]);
  const shader = pixelKernelsToComputeShader(fused.source);
  assert.match(shader, /fn qip_pass0\([^]*c = s0_pixel\(c\);\n  qip_dst/);
  assert.match(shader, /fn qip_pass1\([^]*c = s1_pixel\(c\);\n  c = s2_pixel\(c\);\n  qip_dst/);
  assert.match(shader, /override qip_width: u32;/);
  assert.match(shader, /fn sample\(dx: i32, dy: i32\) -> vec4f/);
  // A member named `sample` does not make a kernel sample.
  assert.deepEqual(pixelKernelPasses("fn a(c: vec4f) -> vec4f { return c.sample; }\nfn b(c: vec4f) -> vec4f { return c; }"), [["a", "b"]]);
});
