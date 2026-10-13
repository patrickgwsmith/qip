import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const compiler = join(process.cwd(), "text/wgsl/wgsl-compute-to-wasm.wasm");
const strictCheckers = [
  "application/wasm/wasm-strict-profile.wasm",
  "application/wasm/wasm-bounded-loops.wasm",
  "application/wasm/wasm-nontrapping-divides.wasm",
].map((path) => join(process.cwd(), path));

const scaleShader = `
override gain: f32 = 2.0;
override offset: f32 = 0.0;

@group(0) @binding(0) var<storage, read> src: array<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  let i = id.x;
  if i >= arrayLength(&src) { return; }
  dst[i] = clamp(src[i] * gain + offset, -10.0, 10.0);
}
`;

// In place: a shader with only a read_write buffer transforms its input.
const integerShader = `
const MIN_I32: i32 = -2147483648;
override divisor: i32 = 0;
@group(0) @binding(0) var<storage, read_write> data: array<i32>;

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) gid: vec3u) {
  let v = data[gid.x];
  var r: i32;
  if gid.x == 0u {
    r = v / divisor;
  } else if gid.x == 1u {
    r = v % divisor;
  } else if gid.x == 2u {
    r = MIN_I32 / -1;
  } else {
    var t = select(v, -v, v < 0);
    t *= 3;
    t++;
    r = max(t, 10) + min(i32(f32(v) / 2.0), 0) + i32(3.9e9);
  }
  data[gid.x] = r;
  data[gid.x + 100u] = 7;
}
`;

// RGBA32F pixels: one vec4f per invocation.
const pixelShader = `
override exposure: f32 = 1.0;
@group(0) @binding(0) var<storage, read> src: array<vec4<f32>>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let p = src[id.x];
  var c = vec4f(p.r, p.g, p.b, 1.0) * exposure;
  c = clamp(c, vec4f(0.0), vec4f(1));
  c.a = p.a;
  c.r *= 0.5;
  let gray = (c.r + c.g + c.b) / 3.0;
  dst[id.x] = select(c, vec4f(gray, gray, gray, c.a), p.a < 0.25);
}
`;

// In place, with scalar-on-the-left splats, %, unary minus and rounding.
const vectorOpsShader = `
@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let x = v[id.x];
  var r = 10.0 - x;
  r += x % vec4f(3.0);
  r /= 2;
  v[id.x] = -abs(round(r)) + max(floor(x), vec4<f32>());
}
`;

// A luminance-driven warm tint: swizzles, dot, vec3f and mix.
const warmShader = `
override strength: f32 = 0.5;
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let c = src[id.x];
  let luma = dot(c.rgb, vec3f(0.25, 0.5, 0.25));
  let warm = vec3f(luma) * vec3<f32>(1.0, 0.75, 0.5);
  dst[id.x] = vec4f(mix(c.rgb, warm, strength), c.a);
}
`;

// In place: vec2f lane writes, constructors from mixed vectors and scalars,
// repeated and reversed swizzles, and mix with a vector weight.
const swizzleShader = `
@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let c = v[id.x];
  var p: vec2f = c.wz;
  p.y += 10.0;
  let q = vec3f(p, c.x) - c.yyy;
  v[id.x] = vec4f(c.x, q.zx, dot(p, vec2<f32>(1.0, 2.0))) + mix(vec4f(), c.abgr, vec4f(0, 0.5, 1, 0));
}
`;

async function tempDir() {
  return mkdtemp(join(tmpdir(), "qip-wgsl-"));
}

async function compile(source) {
  const directory = await tempDir();
  const sourcePath = join(directory, "shader.wgsl");
  const modulePath = join(directory, "shader.wasm");
  await writeFile(sourcePath, source);
  await execFileAsync(qip, ["run", "-i", sourcePath, "-o", modulePath, compiler]);
  return modulePath;
}

async function run(modulePath, input, uniforms = []) {
  const directory = await tempDir();
  const inputPath = join(directory, "input.bin");
  const outputPath = join(directory, "output.bin");
  await writeFile(inputPath, input);
  const args = ["run", "-i", inputPath, "-o", outputPath, modulePath];
  for (const uniform of uniforms) args.push("-u", uniform);
  await execFileAsync(qip, args);
  return readFile(outputPath);
}

function f32Bytes(values) {
  return Buffer.from(new Float32Array(values).buffer);
}

function f32Values(bytes) {
  return Array.from(new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4));
}

function i32Bytes(values) {
  return Buffer.from(new Int32Array(values).buffer);
}

function i32Values(bytes) {
  return Array.from(new Int32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4));
}

test("compiled shader scales f32 input with override uniforms", async () => {
  const module = await compile(scaleShader);
  const input = f32Bytes([1, 2.5, -3, 100, -0.25]);
  assert.deepEqual(f32Values(await run(module, input)), [2, 5, -6, 10, -0.5]);
  assert.deepEqual(
    f32Values(await run(module, input, ["gain=0.5", "offset=1"])),
    [1.5, 2.25, -0.5, 10, 0.875],
  );
  // Uniforms reset to their defaults after each render.
  assert.deepEqual(f32Values(await run(module, input)), [2, 5, -6, 10, -0.5]);
});

test("compiled shader rejects a partial element at its offset", async () => {
  const module = await compile(scaleShader);
  await assert.rejects(run(module, Buffer.from("abcdef")), /rejected input at input offset 4\b/);
});

test("compiled integer shader follows WGSL division and conversion rules", async () => {
  const module = await compile(integerShader);
  const input = i32Bytes([17, 17, 0, -5, 2]);
  const min = -2147483648;
  // 16 + -2 + 2147483647 and 10 + 0 + 2147483647 wrap around.
  const tail = [16 - 2 + 2147483647 - 2 ** 32, 10 + 2147483647 - 2 ** 32];
  assert.deepEqual(i32Values(await run(module, input)), [17, 0, min, ...tail]);
  assert.deepEqual(i32Values(await run(module, input, ["divisor=5"])), [3, 2, min, ...tail]);
  assert.deepEqual(i32Values(await run(module, input, ["divisor=-1"])), [-17, 0, min, ...tail]);
});

test("compiled vec4f shader transforms RGBA32F pixels", async () => {
  const module = await compile(pixelShader);
  const input = f32Bytes([0.4, 0.8, 2, 1, -1, 0.5, 0.25, 0.1]);
  const f = Math.fround;
  const gray = f((f(f(0) + f(0.5)) + f(0.25)) / 3);
  assert.deepEqual(f32Values(await run(module, input)), [f(0.4 * 0.5), f(0.8), 1, 1, gray, gray, gray, f(0.1)]);
  assert.deepEqual(
    f32Values(await run(module, input, ["exposure=0.5"])),
    [f(f(0.4 * 0.5) * 0.5), f(0.8 * 0.5), 1, 1, gray, gray, gray, f(0.1)].map((value, i) =>
      i === 4 || i === 5 || i === 6 ? f((f(f(0) + f(0.25)) + f(0.125)) / 3) : value,
    ),
  );
  await assert.rejects(run(module, Buffer.alloc(40)), /rejected input at input offset 32\b/);
});

test("compiled vec4f shader splats scalars and rounds lane-wise", async () => {
  const module = await compile(vectorOpsShader);
  const x = [1, 5.5, -7, 12];
  const expected = x.map((value) => {
    const remainder = value - 3 * Math.trunc(value / 3);
    const r = (10 - value + remainder) / 2;
    // round() ties to even.
    const rounded = Math.abs(r - Math.floor(r)) === 0.5 ? 2 * Math.round(r / 2) : Math.round(r);
    return -Math.abs(rounded) + Math.max(Math.floor(value), 0) + 0;
  });
  assert.deepEqual(f32Values(await run(module, f32Bytes(x))), expected);
});

test("compiled shader tints with swizzles, dot and mix", async () => {
  const module = await compile(warmShader);
  const f = Math.fround;
  const pixels = [
    [0.8, 0.4, 0.2, 1],
    [0.1, 0.6, 0.9, 0.5],
  ];
  const expected = (strength) =>
    pixels.flatMap(([r, g, b, a]) => {
      const luma = f(f(f(r * 0.25) + f(g * 0.5)) + f(b * 0.25));
      const warm = [luma, f(luma * 0.75), f(luma * 0.5)];
      const t = f(strength);
      return [...[r, g, b].map((value, i) => f(f(f(value) * f(1 - t)) + f(warm[i] * t))), f(a)];
    });
  const input = f32Bytes(pixels.flat());
  assert.deepEqual(f32Values(await run(module, input)), expected(0.5));
  assert.deepEqual(f32Values(await run(module, input, ["strength=0.2"])), expected(0.2));
});

test("compiled shader builds vectors from swizzles and mixed arguments", async () => {
  const module = await compile(swizzleShader);
  const elements = [
    [1, 2, 3, 4],
    [-1.5, 0.25, 8, -2],
  ];
  const expected = elements.flatMap(([x, y, z, w]) => {
    const p = [w, z + 10];
    const q = [p[0] - y, p[1] - y, x - y];
    const base = [x, q[2], q[0], p[0] + p[1] * 2];
    // mix(0, c.abgr, t) is 0 * (1 - t) + c.abgr * t; adding it to base
    // turns any -0 into +0.
    const mixed = [w * 0, z * 0.5, y * 1, x * 0];
    return base.map((value, i) => value + mixed[i] + 0);
  });
  assert.deepEqual(f32Values(await run(module, f32Bytes(elements.flat()))), expected);
});

test("compiled shaders pass the strict profile, loop and division checkers", async () => {
  for (const source of [scaleShader, integerShader, pixelShader, vectorOpsShader, warmShader, swizzleShader]) {
    const module = await compile(source);
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});

test("compiler rejects unsupported WGSL with offset and mode", async () => {
  const loop = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;
@compute @workgroup_size(1) fn main() { for (var i = 0u; i < 4u; i++) {} }
`;
  await assert.rejects(
    compile(loop),
    new RegExp(`rejected input at input offset ${loop.indexOf("for")} with mode 1\\b`),
  );
  const mismatch = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) { v[id.x] = 1u; }
`;
  await assert.rejects(
    compile(mismatch),
    new RegExp(`rejected input at input offset ${mismatch.indexOf("1u")} with mode 2\\b`),
  );
});

async function compileExample(name) {
  return compile(await readFile(join(process.cwd(), "text/wgsl/examples", `${name}.wgsl`), "utf8"));
}

function u32Bytes(values) {
  return Buffer.from(new Uint32Array(values).buffer);
}

function u32Values(bytes) {
  return Array.from(new Uint32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4));
}

test("example life shader moves a glider one cell diagonally in four generations", async () => {
  const module = await compileExample("life");
  const grid = (cells) => {
    const g = new Array(36).fill(0);
    for (const [x, y] of cells) g[y * 6 + x] = 1;
    return g;
  };
  let state = u32Bytes(grid([[1, 0], [2, 1], [0, 2], [1, 2], [2, 2]]));
  for (let i = 0; i < 4; i++) state = await run(module, state, ["width=6"]);
  assert.deepEqual(u32Values(state), grid([[2, 1], [3, 2], [1, 3], [2, 3], [3, 3]]));
});

test("example RGBA8 shaders premultiply alpha and swap byte order", async () => {
  const pixels = [0x80ff8040, 0xffffffff, 0x00ffffff, 0x7f010203];
  const premultiplied = pixels.map((p) => {
    const a = p >>> 24;
    const c = (shift) => Math.round((((p >>> shift) & 255) * a) / 255);
    return (c(0) | (c(8) << 8) | (c(16) << 16) | (a << 24)) >>> 0;
  });
  assert.deepEqual(u32Values(await run(await compileExample("rgba8-premultiply"), u32Bytes(pixels))), premultiplied);
  assert.deepEqual(
    [...(await run(await compileExample("byteswap32"), Buffer.from([1, 2, 3, 4, 0xaa, 0xbb, 0xcc, 0xdd])))],
    [4, 3, 2, 1, 0xdd, 0xcc, 0xbb, 0xaa],
  );
});

test("example signal shaders smooth, dither and round-trip mid/side stereo", async () => {
  assert.deepEqual(f32Values(await run(await compileExample("smooth3"), f32Bytes([0, 0, 4, 0, 0, 8]))), [0, 1, 2, 1, 2, 6]);

  const midSide = await compileExample("stereo-mid-side");
  const encoded = await run(midSide, f32Bytes([0.5, 0.25, -1, 1]));
  assert.deepEqual(f32Values(encoded), [0.375, 0.125, 0, -1]);
  assert.deepEqual(f32Values(await run(midSide, encoded, ["k=1"])), [0.5, 0.25, -1, 1]);

  const dither = await compileExample("dither");
  const ramp = f32Bytes(Array.from({ length: 64 }, (_, i) => i / 63));
  const levels = new Set([0, 1, 2, 3].map((i) => Math.fround(i / 3)));
  const dithered = f32Values(await run(dither, ramp));
  assert.ok(dithered.every((value) => levels.has(value)));
  assert.deepEqual(f32Values(await run(dither, ramp)), dithered);
  assert.notDeepEqual(f32Values(await run(dither, ramp, ["seed=1"])), dithered);
});

test("example image shaders tone map and flip RGBA32F pixels", async () => {
  const f = Math.fround;
  const aces = (x) => Math.min(1, (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
  const mapped = f32Values(await run(await compileExample("tonemap-aces"), f32Bytes([0.18, 1, 10, 0.5])));
  [aces(0.18), aces(1), 1, 0.5].forEach((value, i) => assert.ok(Math.abs(mapped[i] - f(value)) < 1e-6));

  const flip = await compileExample("flip");
  const image = f32Bytes([...Array(24).keys()]);
  const pixel = (i) => [4 * i, 4 * i + 1, 4 * i + 2, 4 * i + 3];
  assert.deepEqual(f32Values(await run(flip, image, ["width=3"])), [2, 1, 0, 5, 4, 3].flatMap(pixel));
  assert.deepEqual(
    f32Values(await run(flip, image, ["width=3", "horizontal=0", "vertical=1"])),
    [3, 4, 5, 0, 1, 2].flatMap(pixel),
  );
});

test("example shaders pass the strict profile, loop and division checkers", async () => {
  for (const name of ["life", "rgba8-premultiply", "byteswap32", "smooth3", "stereo-mid-side", "dither", "tonemap-aces", "flip"]) {
    const module = await compileExample(name);
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});
