import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { createContext, runInContext, runInNewContext } from "node:vm";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const compiler = join(process.cwd(), "text/wgsl/wgsl-to-wasm.wasm");
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

async function compile(source, uniforms = []) {
  const directory = await tempDir();
  const sourcePath = join(directory, "shader.wgsl");
  const modulePath = join(directory, "shader.wasm");
  await writeFile(sourcePath, source);
  await execFileAsync(qip, ["run", "-i", sourcePath, "-o", modulePath, compiler,
    ...uniforms.flatMap((uniform) => ["-u", uniform])]);
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

// One output per builtin, from an f32 input; `y` is a second pow operand.
const mathShader = (type) => `
@group(0) @binding(0) var<storage, read> src: array<${type}>;
@group(0) @binding(1) var<storage, read_write> dst: array<${type}>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let x = src[id.x];
  let y = x * 0.25;
  var r = sin(x) * 1000.0 + cos(x) * 100.0;
  r += exp2(x * 0.125) + exp(x * 0.0625) + log2(abs(x) + 1.0) + log(abs(x) + 0.5);
  r += pow(abs(x) + 0.5, y) + fract(x * 0.1);
  r += tan(x * 0.1) + asin(fract(x)) + acos(fract(y)) + atan(x) + atan2(y, x + 0.5) + tanh(y);
  r += inverseSqrt(abs(x) + 1.0) + step(y, x) + smoothstep(y - 1.0, y + 2.0, x) + sign(x);
  dst[id.x] = r;
}
`;

function ulpOf(value) {
  const magnitude = Math.abs(Math.fround(value));
  if (magnitude < 2 ** -126) return 2 ** -149;
  return 2 ** (Math.floor(Math.log2(magnitude)) - 23);
}

test("transcendental builtins stay within WGSL accuracy and agree across paths", async () => {
  const cases = [
    ["sin", Math.sin, [-Math.PI, Math.PI], (want) => 2 ** -22],
    ["cos", Math.cos, [-Math.PI, Math.PI], (want) => 2 ** -22],
    ["sin", Math.sin, [-8192, 8192], (want) => 2 ** -22],
    ["exp2", (x) => 2 ** x, [-140, 127.9], (want) => 2 * ulpOf(want)],
    ["exp", Math.exp, [-95, 88.7], (want) => 2 * ulpOf(want)],
    ["log2", Math.log2, [1e-40, 3e38], (want) => 2 * ulpOf(want)],
    ["log", Math.log, [0.5, 2], (want) => 2 ** -21],
    ["tan", Math.tan, [-1.5, 1.5], (want) => 3 * ulpOf(want)],
    ["tan", Math.tan, [-8000, 8000], (want) => 3 * ulpOf(want)],
    ["asin", Math.asin, [-1, 1], (want) => 3 * ulpOf(want)],
    ["acos", Math.acos, [-1, 1], (want) => 2 * ulpOf(want)],
    ["atan", Math.atan, [-100, 100], (want) => 2 * ulpOf(want)],
    ["tanh", Math.tanh, [-12, 12], (want) => 2 * ulpOf(want)],
    ["inverseSqrt", (x) => 1 / Math.sqrt(x), [1e-30, 1e30], (want) => 2 * ulpOf(want)],
  ];
  for (const [name, reference, [low, high], tolerance] of cases) {
    const shader = (type) => `
@group(0) @binding(0) var<storage, read> src: array<${type}>;
@group(0) @binding(1) var<storage, read_write> dst: array<${type}>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) { dst[id.x] = ${name}(src[id.x]); }
`;
    const logScale = low > 0 && high / low > 1e6;
    const input = new Float32Array(4096).map((_, i) => {
      const t = i / 4095;
      return logScale ? low * (high / low) ** t : low + (high - low) * t;
    });
    const bytes = Buffer.from(input.buffer);
    const [scalar, vector, batch] = await Promise.all([
      compile(shader("f32")), compile(shader("vec4f")), compile(shader("f32"), ["vectorize_invocations=1"]),
    ]);
    const output = await run(scalar, bytes);
    assert.deepEqual(await run(vector, bytes), output, `${name} vec4f`);
    assert.deepEqual(await run(batch, bytes), output, `${name} vectorized`);
    f32Values(output).forEach((got, i) => {
      const want = reference(input[i]);
      assert.ok(Math.abs(got - want) <= tolerance(want), `${name}(${input[i]}) = ${got}, want ${want}`);
    });
  }
});

test("transcendental builtins handle special values and compose in expressions", async () => {
  const shader = `
@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;
@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let x = v[id.x].x;
  v[id.x] = vec4f(sin(x), exp2(x), log2(x), fract(x));
}
`;
  const module = await compile(shader);
  const specials = [0, Infinity, -Infinity, NaN, -1, 2 ** -149, 3, 128, -151, 1e30];
  const output = f32Values(await run(module, f32Bytes(specials.flatMap((x) => [x, 0, 0, 0]))));
  const lanes = (lane) => specials.map((_, i) => output[4 * i + lane]);
  const s = lanes(0);
  assert.deepEqual(s.slice(0, 4), [0, NaN, NaN, NaN]);
  assert.ok(s.slice(4).every((value) => Math.abs(value) <= 1), "sin stays in [-1, 1] for finite input");
  assert.deepEqual(lanes(1), [1, Infinity, 0, NaN, 0.5, 1, 8, Infinity, 0, Infinity]);
  assert.deepEqual(lanes(2).slice(0, 8), [-Infinity, Infinity, NaN, NaN, NaN, -149, Math.fround(Math.log2(3)), 7]);
  assert.deepEqual(lanes(3).slice(4), [0, 2 ** -149, 0, 0, 0, 0]);

  // Scalar, vector and vectorized code paths give the same bits.
  const input = f32Bytes(Array.from({ length: 256 }, (_, i) => (i - 128) * 0.37));
  const [scalar, vector, batch] = await Promise.all([
    compile(mathShader("f32")), compile(mathShader("vec4f")), compile(mathShader("f32"), ["vectorize_invocations=1"]),
  ]);
  const want = await run(scalar, input);
  assert.deepEqual(await run(vector, input), want);
  assert.deepEqual(await run(batch, input), want);
  f32Values(want).forEach((got) => assert.ok(Number.isFinite(got)));

  // pow(x, y) is exp2(y * log2(x)): exact at y = 0 and powers of two.
  const powModule = await compile(`
@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;
@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let p = v[id.x];
  v[id.x] = vec4f(pow(p.x, p.y), pow(p.zw, vec2f(2.0, 0.5)), 0.0);
}
`);
  const powOut = f32Values(await run(powModule, f32Bytes([2, 10, 4, 9, 5, 0, -1, 1])));
  assert.deepEqual(powOut.slice(0, 3), [1024, 16, 3]);
  assert.deepEqual(powOut.slice(4, 7), [1, NaN, 1]);
});

test("geometric, step, sign and atan2 builtins match references across paths", async () => {
  const shader = `
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let p = src[id.x];
  let n = normalize(p.xyz);
  dst[id.x] = vec4f(
    length(p.xy) + distance(p.z, p.w) + length(p.w) + distance(p, p.wzyx),
    n.x + n.y * 2.0 + n.z * 3.0,
    step(0.5, p.x) + smoothstep(-1.0, 2.0, p.y) + sign(p.z) + f32(sign(i32(p.w * 3.0))) * 10.0,
    dot(step(p.xy, p.zw), smoothstep(vec2f(0.0), vec2f(1.0, 2.0), p.zw)) + atan2(p.x, p.y - 1.0));
}
`;
  const input = new Float32Array(4096).map((_, i) => Math.fround(Math.sin(i * 12.9898) * 2));
  const bytes = Buffer.from(input.buffer);
  const [plain, batch] = await Promise.all([compile(shader), compile(shader, ["vectorize_invocations=1"])]);
  const output = await run(plain, bytes);
  assert.deepEqual(await run(batch, bytes), output);
  const smoothstep = (low, high, x) => {
    const t = Math.min(1, Math.max(0, (x - low) / (high - low)));
    return t * t * (3 - 2 * t);
  };
  const got = f32Values(output);
  for (let i = 0; i < 1024; i++) {
    const [x, y, z, w] = input.slice(4 * i, 4 * i + 4);
    const length = Math.hypot(x, y, z);
    const want = [
      Math.hypot(x, y) + Math.abs(z - w) + Math.abs(w) + Math.hypot(x - w, y - z, z - y, w - x),
      (x + 2 * y + 3 * z) / length,
      (x >= 0.5) + smoothstep(-1, 2, y) + Math.sign(z) + Math.sign(Math.trunc(w * 3)) * 10,
      (z >= x) * smoothstep(0, 1, z) + (w >= y) * smoothstep(0, 2, w) + Math.atan2(x, Math.fround(y - 1)),
    ];
    want.forEach((value, lane) => {
      assert.ok(Math.abs(got[4 * i + lane] - value) <= 4e-6, `input ${i} lane ${lane}: ${got[4 * i + lane]}, want ${value}`);
    });
  }

  // atan2 takes its quadrant from both signs, as libm does.
  const atan2Module = await compile(`
@group(0) @binding(0) var<storage, read_write> v: array<vec4f>;
@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3u) { v[id.x] = vec4f(atan2(v[id.x].x, v[id.x].y), sign(v[id.x].x), 0.0, 0.0); }
`);
  const pairs = [[0, 0], [0, -1], [-0, -1], [1, 0], [-1, 0], [Infinity, 1], [1, -Infinity], [NaN, 1], [-2, -2],
    [0, -0], [-0, -0], [-0, 0], [1, -0], [Infinity, Infinity], [-Infinity, -Infinity], [Infinity, NaN], [1, NaN]];
  const atan2Out = f32Values(await run(atan2Module, f32Bytes(pairs.flatMap(([y, x]) => [y, x, 0, 0]))));
  assert.deepEqual(pairs.map((_, i) => atan2Out[4 * i]), pairs.map(([y, x]) => Math.fround(Math.atan2(y, x))));
  // sign keeps zeros, including -0, and NaN.
  assert.deepEqual(pairs.map((_, i) => atan2Out[4 * i + 1]), [0, 0, -0, 1, -1, 1, 1, NaN, -1, 0, -0, -0, 1, 1, -1, 1, 1]);

  const intModule = `
@group(0) @binding(0) var<storage, read_write> v: array<i32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) { v[id.x] = sign(v[id.x]); }
`;
  const ints = i32Bytes([-5, 0, 7, -2147483648, 2147483647, 1, -1, 3]);
  for (const module of await Promise.all([compile(intModule), compile(intModule, ["vectorize_invocations=1"])])) {
    assert.deepEqual(i32Values(await run(module, ints)), [-1, 0, 1, -1, 1, 1, -1, 1]);
  }
});

test("pixel kernels compile transcendental builtins into Tile components", async () => {
  const module = await compile(`
override phase: f32 = 0.0;
fn wave(c: vec4f) -> vec4f {
  return vec4f(0.5 + 0.5 * sin(c.rgb * 6.2831855 + phase), pow(c.a, 2.2));
}
`);
  const exports = new WebAssembly.Instance(new WebAssembly.Module(await readFile(module))).exports;
  const tile = new Float32Array(exports.memory.buffer, Number(exports.input_ptr()), 64 * 64 * 4);
  tile.set([0.25, 0.5, 0, 0.5]);
  exports.tile_rgba32float_64x64(0, 0);
  const [r, g, b, a] = tile.slice(0, 4);
  assert.ok(Math.abs(r - 1) < 1e-6 && Math.abs(g - 0.5) < 1e-6 && Math.abs(b - 0.5) < 1e-6, `${r} ${g} ${b}`);
  assert.ok(Math.abs(a - 0.5 ** 2.2) < 1e-6, `${a}`);
});

test("compiled shaders pass the strict profile, loop and division checkers", async () => {
  for (const source of [scaleShader, integerShader, pixelShader, vectorOpsShader, warmShader, swizzleShader, mathShader("f32"), mathShader("vec4f")]) {
    const module = await compile(source);
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});

// A fragment shader: one invocation per pixel at its centre, reading the
// input image as a texture. Shifts the image right by `shift`, discards the
// bottom row, and writes the position into blue/alpha. Coordinates clamp as
// Dawn does, min(u32(c), size - 1), so negative ones read the last column.
const fragmentShader = `
override shift: i32 = 1;
@group(0) @binding(0) var src: texture_2d<f32>;

@fragment
fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let size = textureDimensions(src);
  if u32(pos.y) == size.y - 1u { discard; }
  let p = vec2i(pos.xy) - vec2i(shift, 0);
  let c = textureLoad(src, p, 0);
  return vec4f(c.rg, pos.x + f32(size.x) * pos.y, pos.w + pos.z);
}
`;

test("fragment shader runs per pixel with textureLoad, textureDimensions and discard", async () => {
  const module = await compile(fragmentShader);
  const width = 3;
  const height = 3;
  const pixels = [];
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) pixels.push(x, y, 0, 0);
  const input = f32Bytes(pixels);
  const expected = (shift) => {
    const out = [];
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      if (y === height - 1) out.push(0, 0, 0, 0);
      else out.push(Math.min(width - 1, (x - shift) >>> 0), y, x + 0.5 + width * (y + 0.5), 1);
    }
    return out;
  };
  assert.deepEqual(f32Values(await run(module, input, [`width=${width}`])), expected(1));
  assert.deepEqual(f32Values(await run(module, input, [`width=${width}`, "shift=-5"])), expected(-5));
  // width is required and must divide the pixel count.
  await assert.rejects(run(module, input), /rejected input at input offset 0\b/);
  await assert.rejects(run(module, input, ["width=2"]), /rejected input at input offset 128\b/);
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

test("fragment shader converts and splats vec2i and vec2u", async () => {
  const module = await compile(`
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let a = vec2u(vec2f(-1.5, 7.9)) + 2u;
  let b = vec2<i32>(3) * vec2i(pos.yx);
  let c = textureLoad(src, vec2u(9u, 0u), 1);
  return vec4f(vec2f(a), f32(b.y), c.x + vec2f(b).yx.x);
}
`);
  const out = f32Values(await run(module, f32Bytes([5, 5, 5, 5, 6, 6, 6, 6]), ["width=2"]));
  assert.deepEqual(out, [2, 9, 0, 0, 2, 9, 3, 3]);
});

// Helpers: functions other than the entry compile to Wasm functions. They
// take scalar and vector parameters, call earlier helpers, read overrides and
// buffers, return early, and may return nothing.
const helperShader = `
override bias: f32 = 0.5;
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;

fn luma(c: vec3f) -> f32 {
  return dot(c, vec3f(0.25, 0.5, 0.25));
}

fn tone(c: vec4f, k: f32) -> vec4f {
  if k < 0.0 { return vec4f(0.0); }
  let l = luma(c.rgb) * k + bias;
  return vec4f(vec3f(l), c.a);
}

fn neighbour(i: u32, n: u32) -> vec4f {
  return src[min(i + 1u, n - 1u)];
}

fn mark(i: u32) {
  dst[i] = vec4f(-1.0);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  if id.x >= n { return; }
  if id.x == 3u { mark(id.x); return; }
  dst[id.x] = tone(src[id.x], 2.0) + tone(neighbour(id.x, n), -1.0) + luma(vec3f(1.0)) * 0.0;
}
`;

test("helper functions compile to Wasm functions in compute shaders", async () => {
  const input = f32Bytes([0.2, 0.4, 0.8, 1, 0, 0, 0, 0.5, 1, 1, 1, 1, 0.5, 0.5, 0.5, 0.5, 0.1, 0.3, 0.5, 0.7]);
  const f = Math.fround;
  const expected = (bias) => {
    const v = f32Values(input);
    const out = [];
    for (let i = 0; i < 5; i++) {
      const [r, g, b, a] = v.slice(i * 4, i * 4 + 4);
      if (i === 3) { out.push(-1, -1, -1, -1); continue; }
      const l = f(f(f(f(f(r * 0.25) + f(g * 0.5)) + f(b * 0.25)) * 2) + bias);
      out.push(l, l, l, a);
    }
    return out;
  };
  for (const vectorize of [0, 1]) {
    const module = await compile(helperShader, [`vectorize_invocations=${vectorize}`]);
    assert.deepEqual(f32Values(await run(module, input)), expected(f(0.5)));
    assert.deepEqual(f32Values(await run(module, input, ["bias=0.25"])), expected(f(0.25)));
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});

test("helper functions work in fragment shaders and read the texture", async () => {
  const module = await compile(`
@group(0) @binding(0) var src: texture_2d<f32>;
fn at(p: vec2i, dx: i32) -> vec4f {
  return textureLoad(src, p + vec2i(dx, 0), 0);
}
fn blur(p: vec2i) -> vec4f {
  return (at(p, -1) + at(p, 0) + at(p, 1)) / 3.0;
}
@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return blur(vec2i(pos.xy));
}
`);
  // Out-of-range coordinates clamp as min(u32(c), size - 1), so x = -1 and
  // x = 3 both read the last column.
  const out = f32Values(await run(module, f32Bytes([3, 3, 3, 3, 6, 6, 6, 6, 9, 9, 9, 9]), ["width=3"]));
  assert.deepEqual(out, [6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 8]);
});

test("compiler rejects helpers outside the subset", async () => {
  const head = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;\n`;
  const entry = `@compute @workgroup_size(1) fn main() { v[0] = 1.0; }\n`;
  const cases = [
    // A helper after the entry, a call before its declaration (so recursion
    // is impossible), and a missing final return.
    [head + entry + `fn late() {}\n`, "fn late", 1],
    [head + `fn a() -> f32 { return a(); }\n` + entry, "a();", 1],
    [head + `fn a(x: f32) -> f32 { if x > 0.0 { return x; } }\n` + entry, "}\n@compute", 1],
    // Wrong argument count and type, and a void result used as a value.
    [head + `fn a(x: f32) -> f32 { return x; }\n@compute @workgroup_size(1) fn main() { v[0] = a(1.0, 2.0); }\n`, "a(1.0", 2],
    [head + `fn a(x: f32) -> f32 { return x; }\n@compute @workgroup_size(1) fn main() { v[0] = a(1u); }\n`, "1u", 2],
    [head + `fn a() {}\n@compute @workgroup_size(1) fn main() { v[0] = a(); }\n`, "a(); }", 2],
    // Duplicate and builtin names.
    [head + `fn a() {}\nfn b() {}\n`.replace("b", "a") + entry, "a() {}\n@", 3],
    [head + `fn sin(x: f32) -> f32 { return x; }\n` + entry, "sin", 3],
  ];
  for (const [source, at, mode] of cases) {
    const offset = source.indexOf(at);
    await assert.rejects(compile(source), new RegExp(`rejected input at input offset ${offset} with mode ${mode}\\b`), source);
  }
});

// Constant-bounded loops: counting up and down, steps other than 1, break
// and continue from inside ifs and else-ifs, nested loops, and a loop in a
// helper.
const loopShader = `
const N: i32 = 5;
@group(0) @binding(0) var<storage, read> src: array<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<f32>;

fn triangle(n: u32) -> u32 {
  var t = 0u;
  for (var k = 1u; k <= 10u; k = k + 1u) {
    if k > n { break; }
    t += k;
  }
  return t;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let limit = src[id.x];
  var sum = 0.0;
  for (var i = 0; i < N; i++) {
    if f32(i) >= limit { break; }
    if i == 1 { continue; } else if i == 3 { sum += 100.0; continue; }
    sum += f32(i);
  }
  var down = 0;
  for (var j: i32 = 10; j > -3; j -= 4) {
    for (var m = 0u; m < 2u; m++) { down += j; }
  }
  dst[id.x] = sum + f32(down) * 1000.0 + f32(triangle(id.x)) * 1e6;
}
`;

test("constant-bounded loops support steps, break, continue and nesting", async () => {
  const limits = [0, 1, 2, 3.5, 4.5, 10];
  const expected = limits.map((limit, x) => {
    let sum = 0;
    for (let i = 0; i < 5; i++) {
      if (i >= limit) break;
      if (i === 1) continue;
      if (i === 3) { sum += 100; continue; }
      sum += i;
    }
    let down = 0;
    for (let j = 10; j > -3; j -= 4) down += 2 * j;
    let t = 0;
    for (let k = 1; k <= 10 && k <= x; k++) t += k;
    return Math.fround(Math.fround(sum + down * 1000) + t * 1e6);
  });
  for (const vectorize of [0, 1]) {
    const module = await compile(loopShader, [`vectorize_invocations=${vectorize}`]);
    assert.deepEqual(f32Values(await run(module, f32Bytes(limits))), expected);
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});

test("compiler rejects loops that are not constant-bounded", async () => {
  const wrap = (loop) => `override n: i32 = 3;
@group(0) @binding(0) var<storage, read_write> v: array<i32>;
@compute @workgroup_size(1) fn main() { ${loop} }
`;
  const cases = [
    // A runtime bound, a step against the comparison, a counter written in
    // the body, a step that wraps past the bound, and break outside a loop.
    ["for (var i = 0; i < n; i++) {}", "n; i++", 1],
    ["for (var i = 0; i < 4; i--) {}", "--", 1],
    ["for (var i = 0; i < 4; i++) { i = 2; }", "i = 2", 2],
    ["for (var i = 0u; i <= 4294967295u; i++) {}", "++", 1],
    ["for (var i = 0; i < 4; i += 0) {}", "+= 0", 1],
    ["break;", "break", 1],
    ["for (var i = 0.0; i < 4.0; i++) {}", "0.0", 2],
  ];
  for (const [loop, at, mode] of cases) {
    const source = wrap(loop);
    await assert.rejects(compile(source), new RegExp(`rejected input at input offset ${source.indexOf(at)} with mode ${mode}\\b`), loop);
  }
});

// Derivatives in fragment shaders run each 2x2 quad together. f varies
// differently in each row and column of a quad, so the fine derivatives
// differ between them.
const derivativeShader = `
override mode: u32 = 0;
fn f(p: vec2f) -> f32 {
  let x = floor(p.x);
  let y = floor(p.y);
  return x * y * 2.0 + y * y + x * x * 3.0;
}
@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let v = f(pos.xy);
  if mode == 1u {
    // Nested: dpdy of dpdx needs a second pass of values.
    return vec4f(dpdy(dpdx(v)), dpdxCoarse(dpdx(v)), 0.0, 1.0);
  }
  if mode == 2u {
    // A demoted lane keeps supplying values to its neighbours.
    if floor(pos.x) == 0.0 { discard; }
    return vec4f(fwidth(v), 0.0, 0.0, 1.0);
  }
  var w = vec2f(0.0);
  for (var i = 0; i < 2; i++) { w += vec2f(dpdxFine(v), dpdyFine(v)); }
  return vec4f(w, fwidth(v) + fwidthCoarse(vec2f(v)).y, 1.0);
}
`;

test("fragment derivatives use 2x2 quads with helper lanes at odd edges", async () => {
  const module = await compile(derivativeShader);
  const width = 5;
  const height = 3;
  const f = (x, y) => x * y * 2 + y * y + x * x * 3;
  const dx = (x, y) => f(x | 1, y) - f(x & ~1, y);
  const dy = (x, y) => f(x, y | 1) - f(x, y & ~1);
  const input = f32Bytes(new Array(width * height * 4).fill(0));
  const pixels = (fn) => {
    const out = [];
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) out.push(...fn(x, y));
    return out;
  };
  assert.deepEqual(
    f32Values(await run(module, input, [`width=${width}`])),
    pixels((x, y) => [2 * dx(x, y), 2 * dy(x, y), 2 * (Math.abs(dx(x, y)) + Math.abs(dy(x, y))), 1]),
  );
  assert.deepEqual(
    f32Values(await run(module, input, [`width=${width}`, "mode=1"])),
    pixels((x, y) => [dx(x, y | 1) - dx(x, y & ~1), 0, 0, 1]),
  );
  assert.deepEqual(
    f32Values(await run(module, input, [`width=${width}`, "mode=2"])),
    pixels((x, y) => x === 0 ? [0, 0, 0, 0] : [Math.abs(dx(x, y)) + Math.abs(dy(x, y)), 0, 0, 1]),
  );
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

test("derivatives are rejected outside fragment shaders", async () => {
  const compute = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;
@compute @workgroup_size(1) fn main() { v[0] = dpdx(v[0]); }
`;
  await assert.rejects(compile(compute), new RegExp(`offset ${compute.indexOf("dpdx")} with mode 1\\b`));
  await assert.rejects(compile(`fn k(c: vec4f) -> vec4f { return fwidth(c); }`), /offset 33 with mode 1\b/);
});

// Constant arrays become a data segment: Paper's 4x4 Bayer matrix as a
// table, a vec3f palette, and an i32 array with a runtime index that clamps
// as Dawn does, min(u32(i), n - 1).
const constArrayShader = `
const BAYER4 = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
const PALETTE: array<vec3f, 3> = array(vec3f(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), vec3f(0.0, 0.0, -1.5));
const STEPS = array(-1, 20, 300);
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let p = vec2u(pos.xy);
  let t = BAYER4[(p.y % 4u) * 4u + p.x % 4u] / 16.0;
  let c = PALETTE[p.x % 3u];
  return vec4f(t, dot(c, vec3f(1.0, 2.0, 3.0)), f32(STEPS[i32(p.x) - 1]), f32(STEPS[7u]));
}
`;

test("constant arrays index a data segment", async () => {
  const width = 6;
  const height = 4;
  const bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
  const palette = [1, 2, -4.5];
  const steps = [-1, 20, 300];
  const expected = [];
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    expected.push(bayer[(y % 4) * 4 + (x % 4)] / 16, palette[x % 3], steps[Math.min((x - 1) >>> 0, 2)], 300);
  }
  for (const vectorize of [0, 1]) {
    const module = await compile(constArrayShader, [`vectorize_invocations=${vectorize}`]);
    const out = f32Values(await run(module, f32Bytes(new Array(width * height * 4).fill(0)), [`width=${width}`]));
    assert.deepEqual(out, expected);
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
  // A compute shader reads them too, and vectorization keeps the scalar path.
  const compute = await compile(`
const K = array<u32, 3>(7u, 8u, 9u);
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) { dst[id.x] = K[src[id.x]]; }
`, ["vectorize_invocations=1"]);
  const input = Buffer.from(new Uint32Array([2, 0, 1, 99]).buffer);
  const out = await run(compute, input);
  assert.deepEqual(Array.from(new Uint32Array(out.buffer, out.byteOffset, 4)), [9, 7, 8, 9]);
});

test("compiler rejects constant arrays outside the subset", async () => {
  const entry = "@fragment fn main() -> @location(0) vec4f { return vec4f(); }\n";
  const cases = [
    ["const A = array<f32, 2>(1.0);\n" + entry, "array<", 2],
    ["const A = array(1.0, 2u);\n" + entry, "2u", 2],
    ["const A = array<bool, 1>(true);\n" + entry, "bool", 1],
    ["const A = array(1.0);\n@fragment fn main() -> @location(0) vec4f { let b = A; return vec4f(); }\n", "; return", 1],
    ["const A = array(1.0);\nfn k(c: vec4f) -> vec4f { return c * A[0]; }\n", "A =", 1],
  ];
  for (const [source, at, mode] of cases) {
    await assert.rejects(compile(source), new RegExp(`rejected input at input offset ${source.indexOf(at)} with mode ${mode}\\b`), source);
  }
});

test("compiler rejects unsupported WGSL with offset and mode", async () => {
  const loop = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;
@compute @workgroup_size(1) fn main() { while (true) {} }
`;
  await assert.rejects(
    compile(loop),
    new RegExp(`rejected input at input offset ${loop.indexOf("while")} with mode 1\\b`),
  );
  const mismatch = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) { v[id.x] = 1u; }
`;
  await assert.rejects(
    compile(mismatch),
    new RegExp(`rejected input at input offset ${mismatch.indexOf("1u")} with mode 2\\b`),
  );
  // sign has no u32 overload, normalize takes only vectors, and smoothstep
  // does not splat a scalar edge.
  for (const call of ["sign(1u)", "normalize(v[0])", "smoothstep(vec2f(0.0), 1.0, vec2f(0.5)).x"]) {
    const source = `@group(0) @binding(0) var<storage, read_write> v: array<f32>;
@compute @workgroup_size(1) fn main() { v[0] = f32(${call}); }
`;
    await assert.rejects(compile(source), /with mode 2\b/, call);
  }
});

test("compiler rejects constant shift counts of 32 or more, like WGSL", async () => {
  const shader = (body) => `@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) {
  const big = 33u;
  let w = src[id.x];
  let v = unpack4xU8(w);
  var x = w;
  ${body}
  dst[id.x] = x ^ pack4xU8(v);
}
`;
  for (const [body, at] of [
    ["x = w << 32u;", "<<"],
    ["x = w >> 40;", ">>"],
    ["x = w << big;", "<<"],
    ["x = w >> (16u + 16u);", ">>"],
    ["x <<= 32u;", "<<="],
    ["x = pack4xU8(v << vec4u(32u));", "<<"],
    ["x = pack4xU8(v >> vec4u(1u, 2u, 3u, 32u));", ">>"],
  ]) {
    const source = shader(body);
    await assert.rejects(
      compile(source),
      new RegExp(`rejected input at input offset ${source.indexOf(at, source.indexOf(body))} with mode 2\\b`),
      body,
    );
  }
  // 31 is the largest valid constant count; runtime counts wrap modulo 32.
  for (const body of ["x = w << 31u;", "x >>= 31u;", "x = w << (w + 32u);", "x = pack4xU8(v >> vec4u(31u, 0u, 1u, 2u));", "x = pack4xU8(v << (v + vec4u(32u)));"]) {
    await compile(shader(body));
  }
});

test("smoothstep rejects equal constant edges", async () => {
  const source = `fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(0.0, 0.0, c.x)); }`;
  await assert.rejects(
    compile(source),
    new RegExp(`rejected input at input offset ${source.indexOf("smoothstep")} with mode 2\\b`),
  );
  await compile(`fn k(c: vec4f) -> vec4f { return vec4f(smoothstep(1.0, 0.0, c.x)); }`);
});

test("demo Atkinson shader matches forward error diffusion, including partial blocks", async () => {
  const page = await readFile("site/wgsl.md", "utf8");
  const generator = page.match(/function atkinsonShader\(\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(generator, "the demo contains its shader generator");
  const module = await compile(runInNewContext(generator + "\natkinsonShader()"));
  const f = Math.fround;
  for (const [width, height] of [[1, 1], [1, 11], [7, 5], [8, 8], [17, 11], [256, 192]]) {
    for (const threshold of [0.3, 0.5, 0.7]) {
      const input = Float32Array.from({ length: width * height * 4 }, (_, i) => ((i * 73 + 31) % 257) / 256);
      const expected = new Float32Array(input.length);
      // Scatter each error forwards, independently of the shader's gathering code.
      for (let oy = 0; oy < height; oy += 8) {
        for (let ox = 0; ox < width; ox += 8) {
          const values = new Float32Array(64);
          const rows = Math.min(8, height - oy);
          const cols = Math.min(8, width - ox);
          for (let y = 0; y < rows; y++) {
            for (let x = 0; x < cols; x++) {
              const i = ((oy + y) * width + ox + x) * 4;
              values[y * 8 + x] = f(f(f(input[i] * f(0.2126)) + f(input[i + 1] * f(0.7152))) +
                f(input[i + 2] * f(0.0722)));
            }
          }
          for (let y = 0; y < rows; y++) {
            for (let x = 0; x < cols; x++) {
              const v = values[y * 8 + x];
              const q = v >= f(threshold) ? 1 : 0;
              const i = ((oy + y) * width + ox + x) * 4;
              expected.set([q, q, q, input[i + 3]], i);
              const error = f(f(v - q) * 0.125);
              for (const [dx, dy] of [[1, 0], [2, 0], [-1, 1], [0, 1], [1, 1], [0, 2]]) {
                const nx = x + dx;
                const ny = y + dy;
                if (nx >= 0 && nx < cols && ny < rows) {
                  values[ny * 8 + nx] = f(values[ny * 8 + nx] + error);
                }
              }
            }
          }
        }
      }
      const actual = await run(module, Buffer.from(input.buffer), [`width=${width}`, `threshold=${threshold}`]);
      assert.deepEqual(f32Values(actual), Array.from(expected), `${width}x${height}, threshold=${threshold}`);
    }
  }
});

async function invocationVariants(source, expectedVectorized = true) {
  const paths = await Promise.all([compile(source), compile(source, ["vectorize_invocations=1"])]);
  const bytes = await Promise.all(paths.map((path) => readFile(path)));
  const modules = bytes.map((body) => new WebAssembly.Module(body));
  const marker = WebAssembly.Module.customSections(modules[1], "qip.vectorize_invocations");
  assert.equal(marker.length, Number(expectedVectorized));
  if (expectedVectorized) assert.deepEqual([...new Uint8Array(marker[0])], [4]);
  else assert.deepEqual(bytes[1], bytes[0], "fallback retains the original module");
  const instances = modules.map((module) => new WebAssembly.Instance(module).exports);
  function execute(exports, input, uniforms) {
    for (const [name, value] of Object.entries(uniforms)) exports[`uniform_set_${name}`](value);
    new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
    const result = BigInt.asUintN(64, exports.render(input.length));
    return { result, output: result >> 63n ? null : Buffer.from(exports.memory.buffer.slice(
      Number(result >> 32n), Number(result >> 32n) + Number(result & 0xffffffffn))) };
  }
  return {
    paths, bytes, instances,
    compare(input, uniforms = {}) {
      const [scalar, vector] = instances.map((exports) => execute(exports, input, uniforms));
      assert.equal(vector.result, scalar.result);
      assert.deepEqual(vector.output, scalar.output);
    },
  };
}

test("invocation vectorization preserves pixels, uniforms, tails and partial-element rejection", async () => {
  for (const [source, lanes, uniforms] of [[scaleShader, 1, { gain: -0.5, offset: 0.25 }],
    [pixelShader, 4, { exposure: 0.75 }], [warmShader, 4, { strength: 0.3 }]]) {
    const variants = await invocationVariants(source);
    for (const count of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 257]) {
      const input = f32Bytes(Array.from({ length: count * lanes }, (_, i) => ((i * 73 + 31) % 257) / 256));
      variants.compare(input, uniforms);
      variants.compare(input); // shader uniforms reset on reused instances
    }
    variants.compare(Buffer.from([1, 2, 3]));
    await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
  }
});

test("invocation vectorization uses one kernel and never stores absent tail lanes", async () => {
  function functionCount(bytes) {
    let offset = 8;
    function uleb() {
      let value = 0, shift = 0, byte;
      do {
        byte = bytes[offset++];
        value += (byte & 127) * 2 ** shift;
        shift += 7;
      } while (byte & 128);
      return value;
    }
    while (offset < bytes.length) {
      const id = bytes[offset++];
      const length = uleb();
      if (id === 3) return uleb();
      offset += length;
    }
    assert.fail("missing function section");
  }
  // No authored bounds check: the compiler must mask the partial batch itself.
  for (const [type, stride, value] of [["u32", 4, "id.x + 1u"], ["f32", 4, "f32(id.x) + 0.5"],
    ["vec4f", 16, "vec4f(f32(id.x), 0.25, 0.5, 1.0)"]]) {
    const source = `
@group(0) @binding(0) var<storage, read> src: array<${type}>;
@group(0) @binding(1) var<storage, read_write> dst: array<${type}>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) { dst[id.x] = ${value}; }`;
    const variants = await invocationVariants(source);
    assert.equal(functionCount(variants.bytes[1]), functionCount(variants.bytes[0]), "no duplicate scalar kernel");
    const e = variants.instances[1];
    const outputPtr = Number(BigInt.asUintN(64, e.render(0)) >> 32n);
    // Include full-capacity batches, then shrink the input on the same instance.
    const cap = e.input_bytes_cap() / stride;
    for (const count of [cap, cap - 1, cap - 2, cap - 3, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]) {
      const length = count * stride;
      const canary = new Uint8Array(e.memory.buffer, outputPtr + length,
        Math.min(64, e.memory.buffer.byteLength - outputPtr - length));
      canary.fill(0xa5);
      variants.compare(Buffer.alloc(length));
      assert.ok(canary.every((byte) => byte === 0xa5), `${type}: ${count} elements`);
    }
    await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
  }
});

test("invocation vectorization masks divergent branches, else-if, lane writes and returns", async () => {
  const source = `
@group(0) @binding(0) var<storage, read> src: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> dst: array<vec4f>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  if id.x >= arrayLength(&src) { return; }
  var c = src[id.x];
  var n: f32;
  if c.r < 0.25 { n = 1.0; c.g += 0.1; }
  else if c.r < 0.75 { n = 2.0; c.b = 0.5; }
  else { n = 3.0; c.a *= 0.25; }
  if (id.x & 3u) == 1u { dst[id.x] = c; return; }
  if c.g > 0.5 {
    if c.b < 0.5 { n += 10.0; } else { n -= 10.0; }
  }
  c.r = n;
  dst[id.x] = c;
}`;
  const variants = await invocationVariants(source);
  for (const count of [4, 7, 19, 1023]) {
    variants.compare(f32Bytes(Array.from({ length: count * 4 }, (_, i) => ((i * 73 + 31) % 257) / 256)));
  }
  await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
});

// ROT13 with one byte per vec4u lane. k wraps below 'a', so k < 26 selects
// letters only, in u32 and in u8 arithmetic alike.
const rot13Shader = `
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let i = id.x;
  if (i < arrayLength(&src)) {
    let b = unpack4xU8(src[i]);
    let k = (b | vec4u(32u)) - vec4u(97u);
    let d = select(vec4u(0u), select(vec4u(243u), vec4u(13u), k < vec4u(13u)), k < vec4u(26u));
    dst[i] = pack4xU8(b + d);
  }
}`;

function rot13(bytes) {
  return Buffer.from(bytes.map((c) => c >= 65 && c <= 90 ? 65 + (c - 52) % 26 : c >= 97 && c <= 122 ? 97 + (c - 84) % 26 : c));
}

test("vec4u supports byte unpacking, bitwise operators, shifts, comparisons and select", async () => {
  const module = await compile(`
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let w = src[id.x];
  let v = unpack4xU8(w);
  // Runtime shift amounts wrap modulo 32; WGSL rejects constant ones past 31.
  let s = (v & vec4u(7u)) + vec4<u32>(0u, 1u, 7u, 30u);
  var r: vec4u;
  if (id.x % 4u == 0u) {
    r = ((v << s) ^ (v >> vec4u(3u))) | (~v & vec4u(0x10u));
  } else if (id.x % 4u == 1u) {
    let m: vec4<bool> = (v < vec4u(64u)) & !(v == vec4u(7u));
    r = select(v * 3u, 200u - v, m | (v >= vec4u(250u)));
  } else if (id.x % 4u == 2u) {
    r = clamp(min(v, vec4u(180u)), vec4u(20u), vec4u(120u)) + max(v.wzyx, vec4u(v.x)) - vec4u(vec4f(v) * 0.5);
  } else {
    r = select(v, v.yxwz, v.x > v.y);
  }
  dst[id.x] = pack4xU8(r) ^ (u32(r.w > 255u) << 31u);
}`);
  const input = Buffer.alloc(4096);
  for (let i = 0; i < input.length; i++) input[i] = (i * 151 + 7 * (i >> 8)) & 255;
  input.writeUInt32LE(0x00ff07ff, 0);
  const output = await run(module, input);
  const u = (x) => x >>> 0;
  const shift = [0, 1, 7, 30];
  for (let e = 0; e < input.length / 4; e++) {
    const v = [...input.subarray(4 * e, 4 * e + 4)];
    let r;
    if (e % 4 === 0) r = v.map((x, c) => u(u(u(x << (((x & 7) + shift[c]) & 31)) ^ (x >>> 3)) | (u(~x) & 0x10)));
    else if (e % 4 === 1) r = v.map((x) => (x < 64 && x !== 7) || x >= 250 ? u(200 - x) : 3 * x);
    else if (e % 4 === 2) {
      const w = [v[3], v[2], v[1], v[0]];
      r = v.map((x, c) => u(Math.max(20, Math.min(120, Math.min(x, 180))) + Math.max(w[c], v[0]) - Math.trunc(x * 0.5)));
    } else r = v[0] > v[1] ? [v[1], v[0], v[3], v[2]] : v;
    const want = u(r.reduce((acc, x, c) => acc | ((x & 255) << (8 * c)), 0) ^ (r[3] > 255 ? 0x80000000 : 0));
    assert.equal(output.readUInt32LE(4 * e), want, `element ${e}: ${v}`);
  }
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

test("byte shaders vectorize as i8x16 and store only existing elements", async () => {
  const variants = await invocationVariants(rot13Shader);
  const all = Buffer.from(Array.from({ length: 1024 }, (_, i) => i & 255));
  for (const length of [0, 4, 8, 12, 16, 20, 1020, 1024]) {
    const input = all.subarray(0, length);
    variants.compare(input);
    assert.deepEqual(await run(variants.paths[1], input), rot13(input));
  }
  // Full capacity, then every partial batch on the same instance.
  const e = variants.instances[1];
  const outputPtr = Number(BigInt.asUintN(64, e.render(0)) >> 32n);
  const cap = e.input_bytes_cap() / 4;
  for (const count of [cap, cap - 1, cap - 2, cap - 3, 9, 7, 6, 5, 3, 2, 1, 0]) {
    const length = count * 4;
    const canary = new Uint8Array(e.memory.buffer, outputPtr + length,
      Math.min(64, e.memory.buffer.byteLength - outputPtr - length));
    canary.fill(0xa5);
    variants.compare(Buffer.alloc(length, 0x61));
    assert.ok(canary.every((byte) => byte === 0xa5), `${count} elements`);
  }
  variants.compare(Buffer.from([1, 2, 3]));
  await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
});

test("byte vectorization falls back when u8 arithmetic would change a stored byte", async () => {
  const shader = (body) => `
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let b = unpack4xU8(src[id.x]);
  dst[id.x] = pack4xU8(${body});
}`;
  const input = Buffer.from(Array.from({ length: 1024 }, (_, i) => (i * 97 + 13) & 255));
  // A shift by 8 clears a u32 lane but is a shift by 0 in an i8x16; a byte
  // below 200 wraps differently in u32 and u8 before the comparison.
  for (const body of ["b >> vec4u(8u)", "select(b, vec4u(1u), b - vec4u(200u) < vec4u(100u))"]) {
    const variants = await invocationVariants(shader(body), false);
    variants.compare(input);
  }
  // The same shapes vectorize when every byte agrees.
  for (const body of ["b >> vec4u(3u)", "select(b, vec4u(1u), b - vec4u(200u) < vec4u(50u))", "max(b, vec4u(9u)) ^ vec4u(1u, 2u, 3u, 4u)"]) {
    const variants = await invocationVariants(shader(body));
    variants.compare(input);
  }
});

test("invocation vectorization keeps unsigned constant division exact over u32", async () => {
  const values = [0, 1, 2, 11, 12, 13, 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff];
  let state = 0x9e3779b9;
  for (let i = 0; i < 2048; i++) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    values.push(state);
  }
  for (const divisor of [0, 1, 2, 3, 7, 12, 255, 65537, 0x7fffffff, 0x80000000, 0xfffffffb, 0xffffffff]) {
    for (const op of ["/", "%"]) {
      const source = `
@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  dst[id.x] = src[id.x] ${op} ${divisor}u;
}`;
      const variants = await invocationVariants(source);
      variants.compare(u32Bytes(values));
      await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
    }
  }
});

test("invocation vectorization retains scalar code for dependencies and non-identity stores", async () => {
  for (const source of [integerShader, vectorOpsShader, swizzleShader,
    scaleShader.replace("dst[i]", "dst[0u]"), scaleShader.replace("src[i]", "dst[i]"),
    scaleShader.replace("let i = id.x;", "var i = id.x; i += 1u;")]) {
    await invocationVariants(source, false);
  }
  const page = await readFile("site/wgsl.md", "utf8");
  const generator = page.match(/function atkinsonShader\(\) \{[\s\S]*?\n\}/)[0];
  await invocationVariants(runInNewContext(generator + "\natkinsonShader()"), false);
  const header = scaleShader.slice(0, scaleShader.indexOf("fn main"));
  // Both sources compile in the scalar path. Exhausting optional IR or code
  // budgets must also retain that valid compilation, rather than reject it.
  await invocationVariants(header + "fn main(@builtin(global_invocation_id) id: vec3u) {" +
    "_ = id.x;".repeat(2050) + "dst[id.x] = 1.0; }", false);
  await invocationVariants(header.replaceAll("array<f32>", "array<vec4f>") + "fn main(@builtin(global_invocation_id) id: vec3u) {" +
    "dst[id.x] = src[id.x];".repeat(300) + "}", false);
});

test("invocation vectorization preserves guarded gathers, signed division, casts and per-lane shifts", async () => {
  const gather = `
@group(0) @binding(0) var<storage, read> src: array<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  dst[id.x] = src[i32(id.x) - 2] + src[id.x + 100u];
}`;
  const gathers = await invocationVariants(gather);
  gathers.compare(f32Bytes([0, 0.1, -0.25, 1, -1, 3.5, 0.75]));
  const signed = `
override divisor: i32 = 0;
@group(0) @binding(0) var<storage, read> src: array<i32>;
@group(0) @binding(1) var<storage, read_write> dst: array<i32>;
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let v = src[id.x];
  let shifted = (v >> id.x) ^ (v << (id.x + 32u));
  let converted = i32(f32(v)) + i32(bool(v));
  dst[id.x] = v / divisor + v % divisor + shifted + converted;
}`;
  const variants = await invocationVariants(signed);
  for (const divisor of [0n, -1n, 1n, 3n, -7n]) {
    variants.compare(i32Bytes([-2147483648, -1, 0, 1, 2147483647, -37, 37, 23, -55]), { divisor });
  }
  await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
});

test("compiler vectorization uniform resets after success and rejection", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(compiler));
  const e = instance.exports;
  function compileSource(source) {
    const input = new TextEncoder().encode(source);
    new Uint8Array(e.memory.buffer, e.input_ptr(), input.length).set(input);
    const result = BigInt.asUintN(64, e.render(input.length));
    return result >> 63n ? null : Buffer.from(e.memory.buffer.slice(Number(result >> 32n),
      Number(result >> 32n) + Number(result & 0xffffffffn)));
  }
  const baseline = compileSource(scaleShader);
  assert.equal(e.uniform_set_vectorize_invocations(7), 1);
  assert.ok(WebAssembly.Module.customSections(new WebAssembly.Module(compileSource(scaleShader)), "qip.vectorize_invocations").length);
  assert.deepEqual(compileSource(scaleShader), baseline);
  e.uniform_set_vectorize_invocations(1);
  assert.equal(compileSource("unsupported"), null);
  assert.deepEqual(compileSource(scaleShader), baseline);
});

test("demo retains both compiler modes for warm comparisons and clears them on source edits", async () => {
  const page = await readFile("site/wgsl.md", "utf8");
  const compileFunction = page.match(/function compileWasm\(source\) \{[\s\S]*?\n\}/)[0];
  const { instance } = await WebAssembly.instantiate(await readFile(compiler));
  const context = createContext({ compiler: instance.exports, wasmCache: { source: null, variants: new Map() },
    vectorizeInput: { checked: false }, WebAssembly, TextEncoder, performance,
    describeCompileError: (_, message) => message });
  runInContext(compileFunction, context);
  const scalar = context.compileWasm(scaleShader);
  assert.equal(scalar.error, null);
  context.vectorizeInput.checked = true;
  const vector = context.compileWasm(scaleShader);
  assert.equal(vector.error, null);
  assert.equal(vector.vectorized, true);
  assert.notEqual(vector, scalar);
  context.vectorizeInput.checked = false;
  assert.equal(context.compileWasm(scaleShader), scalar);
  context.vectorizeInput.checked = true;
  assert.equal(context.compileWasm(scaleShader), vector);
  assert.notEqual(context.compileWasm(scaleShader.replace("2.0", "3.0")), vector);
  assert.equal(context.wasmCache.variants.size, 1);
});

test("invocation vectorization preserves Perlin output at all octave counts and irregular sizes", async () => {
  const page = await readFile("site/wgsl.md", "utf8");
  const generator = page.match(/function perlinNoiseShader\(\) \{[\s\S]*?\n\}/)[0];
  const variants = await invocationVariants(runInNewContext(generator + "\nperlinNoiseShader()"));
  assert.ok(variants.bytes[1].length < 3 * variants.bytes[0].length, "Perlin avoids duplicate kernels and redundant vector copies");
  for (const [width, height] of [[1, 1], [2, 1], [3, 1], [7, 5], [19, 13], [256, 192]]) {
    for (let octaves = 1; octaves <= 8; octaves++) {
      variants.compare(Buffer.alloc(width * height * 16), {
        width, octave_count: octaves, seed: octaves * 7, time: octaves * 0.3,
        persistence: octaves % 2 ? 0.5 : 1, lacunarity: octaves % 2 ? 1.5 : 4,
        scale: octaves % 2 ? 0.1 : 4, softness: octaves % 2 ? 0 : 1,
      });
    }
  }
  await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
});

test("demo Perlin shader matches 3D gradient noise and octave reference", async () => {
  const page = await readFile("site/wgsl.md", "utf8");
  const generator = page.match(/function perlinNoiseShader\(\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(generator);
  const module = await compile(runInNewContext(generator + "\nperlinNoiseShader()"));
  const f = Math.fround;
  const add = (a, b) => f(a + b);
  const sub = (a, b) => f(a - b);
  const mul = (a, b) => f(a * b);
  const mix = (a, b, t) => add(mul(a, sub(1, t)), mul(b, t));
  const fade = (t) => mul(mul(mul(t, t), t), add(mul(t, sub(mul(t, 6), 15)), 10));
  const gradients = [
    [1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0],
    [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1],
    [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1],
  ];
  function noise(point, seed) {
    const cell = point.map(Math.floor);
    const fraction = point.map((v, i) => sub(v, cell[i]));
    const corners = [];
    for (let z = 0; z < 2; z++) for (let y = 0; y < 2; y++) for (let x = 0; x < 2; x++) {
      let h = Math.imul(cell[0] + x, 0x8da6b343) ^ Math.imul(cell[1] + y, 0xd8163841) ^
        Math.imul(cell[2] + z, 0xcb1ab31f) ^ seed;
      h = Math.imul(h ^ (h >>> 16), 0x7feb352d);
      h = Math.imul(h ^ (h >>> 15), 0x846ca68b);
      const gradient = gradients[((h ^ (h >>> 16)) >>> 0) % 12];
      const offset = fraction.map((v, i) => sub(v, [x, y, z][i]));
      corners.push(add(add(mul(gradient[0], offset[0]), mul(gradient[1], offset[1])), mul(gradient[2], offset[2])));
    }
    const [u, v, w] = fraction.map(fade);
    return mix(mix(mix(corners[0], corners[1], u), mix(corners[2], corners[3], u), v),
      mix(mix(corners[4], corners[5], u), mix(corners[6], corners[7], u), v), w);
  }
  const width = 19;
  const height = 13;
  const input = new Float32Array(width * height * 4);
  const defaults = { scale: 1, seed: 0, time: 0, octave_count: 1, persistence: 0.5,
    lacunarity: 1.5, proportion: 0.35, softness: 0.1 };
  for (const changes of [{}, { octave_count: 8, seed: 17, time: 2.3, scale: 1.7 },
    { octave_count: 4, persistence: 1, lacunarity: 4, scale: 4, softness: 1 },
    { octave_count: 8, scale: 0.1, time: 20, softness: 0 }]) {
    const p = Object.fromEntries(Object.entries({ ...defaults, ...changes }).map(([k, v]) => [k, f(v)]));
    const uniforms = [`width=${width}`, ...Object.entries(changes).map(([k, v]) => `${k}=${v}`)];
    const actual = f32Values(await run(module, Buffer.from(input.buffer), uniforms));
    for (let i = 0; i < width * height; i++) {
      const px = f(sub(add(i % width, 0.5), mul(width, 0.5)) / height);
      const py = f(sub(add(Math.floor(i / width), 0.5), mul(height, 0.5)) / height);
      let frequency = f(5 / p.scale);
      let amplitude = 1;
      let total = 0;
      let weight = 0;
      for (let octave = 0; octave < p.octave_count; octave++) {
        const point = [add(mul(px, frequency), 17.25), add(mul(py, frequency), 43.5),
          add(mul(mul(p.time, f(0.2)), frequency), 11.75)];
        total = add(total, mul(noise(point, p.seed ^ (octave * 1013)), amplitude));
        weight = add(weight, amplitude);
        amplitude = mul(amplitude, p.persistence);
        frequency = mul(frequency, p.lacunarity);
      }
      const value = Math.min(1, Math.max(0, add(mul(f(total / weight), 0.5), p.proportion)));
      const halfWidth = Math.max(mul(p.softness, 0.5), f(0.5 / height));
      const t = Math.min(1, Math.max(0, f(sub(value, sub(0.5, halfWidth)) / mul(2, halfWidth))));
      const blend = mul(mul(t, t), sub(3, mul(2, t)));
      for (let c = 0; c < 3; c++) {
        const expected = mix([f(0.3882353), f(0.1647059), f(0.8352941)][c],
          [f(0.9882353), f(0.8117647), f(0.9686275)][c], blend);
        assert.ok(Math.abs(actual[i * 4 + c] - expected) < 0.000002, `pixel ${i}, channel ${c}`);
        assert.ok(actual[i * 4 + c] >= 0 && actual[i * 4 + c] <= 1);
      }
      assert.equal(actual[i * 4 + 3], 1);
    }
  }
  const render = async (uniforms) => f32Values(await run(module, Buffer.from(input.buffer), [`width=${width}`, ...uniforms]));
  const original = await render([]);
  assert.notDeepEqual(await render(["seed=1"]), original);
  assert.notDeepEqual(await render(["time=1"]), original);
  input.fill(1);
  assert.deepEqual(await render([]), original, "noise does not depend on input colors");
  const before = await render(["time=0.24999", "softness=1"]);
  const after = await render(["time=0.25001", "softness=1"]);
  assert.ok(before.every((v, i) => Math.abs(v - after[i]) < 0.0001), "continuous across a z lattice boundary");
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

async function paperShader(name) {
  const page = await readFile("site/wgsl.md", "utf8");
  const helpers = ["paperNeighbours", "simplexNoiseWgsl", "polygonWgsl", name]
    .map((fn) => page.match(new RegExp(`function ${fn}\\([^)]*\\) \\{[\\s\\S]*?\\n\\}(?=\\n)`))?.[0]);
  assert.ok(helpers.every(Boolean), `the demo contains ${name} and its helpers`);
  return runInNewContext(helpers.join("\n") + `\n${name}()`);
}

async function liquidMetalShader() {
  const page = await readFile("site/wgsl.md", "utf8");
  const source = page.match(/<script type="text\/wgsl" data-name="Liquid metal \(shapes\)">([\s\S]*?)<\/script>/)?.[1];
  assert.ok(source, "the Liquid metal shader is on the demo page");
  return source;
}

test("Liquid metal built-in shapes render with fragment derivatives and a bounded loop", async () => {
  const module = await compile(await liquidMetalShader());
  for (const shape of [0, 1, 2, 3, 4]) {
    const input = paperInput(23, 17);
    const output = f32Values(await run(module, input, ["width=23", `shape=${shape}`, "softness=0", "contour=0"]));
    assert.equal(output.length, 23 * 17 * 4);
    assert.ok(output.every((v) => Number.isFinite(v) && v >= 0 && v <= 1), `shape ${shape} has finite colors`);
    assert.ok(output.every((v, i) => i % 4 !== 3 || v === 1), `shape ${shape} is opaque`);
  }
  const input = paperInput(23, 17);
  const first = await run(module, input, ["width=23", "shape=4", "time=0"]);
  const moved = await run(module, input, ["width=23", "shape=4", "time=3"]);
  assert.notDeepEqual(first, moved, "metaballs move with time");
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

test("vgpu color ring matches its formula and ignores input colors", async () => {
  const page = await readFile("site/wgsl.md", "utf8");
  const source = page.match(/<script type="text\/wgsl" data-name="Color ring \(vgpu\)">([\s\S]*?)<\/script>/)?.[1];
  assert.ok(source, "the vgpu color ring is on the demo page");
  const module = await compile(source);
  const [width, height] = [29, 17];
  const output = f32Values(await run(module, paperInput(width, height), [`width=${width}`]));
  assert.equal(output.length, width * height * 4);
  for (let i = 0; i < width * height; i++) {
    const shortest = Math.min(width, height);
    const px = ((i % width + 0.5) / width - 0.5) * (width / shortest);
    const py = ((Math.floor(i / width) + 0.5) / height - 0.5) * (height / shortest);
    const radius = Math.hypot(px, py);
    const angle = Math.atan2(py, px) / 6.28318 + 0.5;
    const ring = Math.exp(-95 * (radius - 0.31) ** 2);
    const halo = Math.exp(-18 * (radius - 0.31) ** 2);
    const bands = 0.82 + 0.18 * Math.sin(angle * 25.13272 + radius * 42);
    for (const [c, phase] of [0, 0.33, 0.67].entries()) {
      const color = 0.55 + 0.45 * Math.cos(6.28318 * (angle + radius * 0.65 + phase));
      const expected = Math.min(1, Math.max(0, color * (ring * bands * 2 + halo * 0.22)));
      assert.ok(Math.abs(output[i * 4 + c] - expected) < 0.0005, `pixel ${i}, channel ${c}`);
    }
    assert.equal(output[i * 4 + 3], 1);
  }
  const white = f32Values(await run(module, f32Bytes(new Array(width * height * 4).fill(1)), [`width=${width}`]));
  assert.deepEqual(white, output, "the ring does not depend on input colors");
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

async function photoBoothShader(name) {
  const page = await readFile("site/wgsl.md", "utf8");
  const source = page.match(new RegExp(`<script type="text/wgsl" data-name="${name} \\(Photo Booth\\)">([\\s\\S]*?)</script>`))?.[1];
  assert.ok(source, `${name} is on the demo page`);
  return compile(source);
}

// The demo's mirrored-edge bilinear sampler, in JS.
function sampleMirrored(pixels, width, height, x, y) {
  const mirror = (p, size) => {
    const s = Math.max(size - 1, 1);
    const f = 0.5 * (p - 0.5) / s;
    return (1 - Math.abs(2 * (f - Math.floor(f)) - 1)) * s;
  };
  const qx = mirror(x, width), qy = mirror(y, height);
  const ax = Math.min(Math.floor(qx), width - 1), ay = Math.min(Math.floor(qy), height - 1);
  const bx = Math.min(ax + 1, width - 1), by = Math.min(ay + 1, height - 1);
  const tx = qx - Math.floor(qx), ty = qy - Math.floor(qy);
  const at = (px, py, c) => pixels[(py * width + px) * 4 + c];
  return [0, 1, 2, 3].map((c) => {
    const top = at(ax, ay, c) + (at(bx, ay, c) - at(ax, ay, c)) * tx;
    const bottom = at(ax, by, c) + (at(bx, by, c) - at(ax, by, c)) * tx;
    return top + (bottom - top) * ty;
  });
}

test("demo Photo Booth distortions pass the image through when switched off", async () => {
  const [width, height] = [31, 23];
  const input = f32Values(paperInput(width, height));
  for (const [name, settings] of [
    ["Stretch", ["amplitude=0"]],
    ["Twirl", ["angle=0"]],
    ["Squeeze", ["scale=0"]],
    // The circle covers the whole image.
    ["Light tunnel", ["radius=1"]],
  ]) {
    const module = await photoBoothShader(name);
    const output = f32Values(await run(module, f32Bytes(input), [`width=${width}`, ...settings]));
    assert.equal(output.length, input.length);
    output.forEach((v, i) => assert.ok(Math.abs(v - input[i]) < 1e-4, `${name} lane ${i}`));
    await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
  }
});

test("demo Photo Booth fish eye follows its kernel with mirrored edges", async () => {
  const module = await photoBoothShader("Fish eye");
  const [width, height] = [31, 23];
  const input = f32Values(paperInput(width, height));
  // factor 1.3 reads up to 1.47 half-diagonals out, past every edge.
  const output = f32Values(await run(module, f32Bytes(input), [`width=${width}`, "factor=1.3"]));
  const [cx, cy] = [width / 2, height / 2];
  const f = 1.3 * Math.hypot(cx, cy);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const [vx, vy] = [x + 0.5 - cx, y + 0.5 - cy];
      const k = 0.6 / (1 - (vx * vx + vy * vy) / (f * f));
      const expected = sampleMirrored(input, width, height, cx + vx * k, cy + vy * k);
      expected.forEach((v, c) => assert.ok(Math.abs(output[(y * width + x) * 4 + c] - v) < 2e-3, `pixel ${x},${y} lane ${c}`));
    }
  }
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

test("demo Photo Booth distortions keep their centres and stay in range", async () => {
  const width = 33;
  const input = f32Values(paperInput(width, width));
  const centre = input.slice((16 * width + 16) * 4, (16 * width + 16) * 4 + 4);
  for (const name of ["Fish eye", "Stretch", "Twirl", "Squeeze", "Light tunnel"]) {
    const module = await photoBoothShader(name);
    const output = f32Values(await run(module, f32Bytes(input), [`width=${width}`]));
    assert.ok(output.every((v) => v >= 0 && v <= 1), `${name} stays in [0, 1]`);
    const pixel = output.slice((16 * width + 16) * 4, (16 * width + 16) * 4 + 4);
    pixel.forEach((v, c) => assert.ok(Math.abs(v - centre[c]) < 1e-4, `${name} keeps the centre pixel, lane ${c}`));
    assert.notDeepEqual(output, input, `${name} moves pixels by default`);
  }
});

test("demo Photo Booth comic book inks black, keeps white and screens greys into dots", async () => {
  const module = await photoBoothShader("Comic book");
  const [width, height] = [24, 20];
  const flat = (v) => f32Bytes(Array.from({ length: width * height * 4 }, (_, i) => (i % 4 === 3 ? 1 : v)));
  const black = f32Values(await run(module, flat(0), [`width=${width}`]));
  black.forEach((v, i) => assert.ok(i % 4 === 3 ? v === 1 : Math.abs(v) < 1e-4, `black lane ${i}`));
  const white = f32Values(await run(module, flat(1), [`width=${width}`]));
  white.forEach((v, i) => assert.ok(Math.abs(v - 1) < 1e-4, `white lane ${i}`));
  // The screen leaves paper-colored dots on the posterized grey.
  const grey = f32Values(await run(module, flat(0.35), [`width=${width}`, "dot_width=6"]));
  assert.ok(grey.every((v) => v >= 0 && v <= 1), "grey stays in [0, 1]");
  const reds = grey.filter((_, i) => i % 4 === 0);
  assert.ok(Math.max(...reds) - Math.min(...reds) > 0.2, "dots stand out from the grey");
  await execFileAsync(qip, ["run", "-i", module, "--", ...strictCheckers]);
});

function paperInput(width, height) {
  return f32Bytes(Array.from({ length: width * height * 4 }, (_, i) =>
    i % 4 === 3 ? 1 : (((i >> 2) * 37 + (i % 4) * 101) % 251) / 250));
}

test("demo Paper shaders stay in range and agree across vectorized paths", async () => {
  for (const [name, uniformSets] of [
    ["flutedGlassShader", [{}, { shape: 5, distortion_shape: 2, angle: 30 }, { shape: 3, distortion_shape: 3, stretch: 0.5 },
      { shape: 2, distortion_shape: 4, shift: -0.5 }, { shape: 4, distortion_shape: 5, size: 0 }]],
    ["wavesShader", [{}, { shape: 2.5, rotation: 45, softness: 0.3 }, { shape: 3, frequency: 0, spacing: 0 }]],
    ["spiralShader", [{}, { noise: 0.5, noise_frequency: 0.5, distortion: 0.6, stroke_taper: 0.5, stroke_cap: 0.5, time: 3 }]],
    ["swirlShader", [{}, { noise: 0, twist: 0, center: 0, softness: 0 },
      { band_count: 0, noise: 0, softness: 0 }, { band_count: 15, noise: 1, noise_frequency: 1 }]],
    ["meshGradientShader", [{}, { color_count: 1, time: 7 }, { distortion: 0, swirl: 1, color_count: 3 }]],
    ["neuroNoiseShader", [{}, { brightness: 1, contrast: 1, time: 5 }, { brightness: 0, contrast: 0, scale: 0.1 }]],
    ["dotGridShader", [{}, { shape: 1, size: 6, stroke_width: 3, size_range: 1, opacity_range: 1 },
      { shape: 2, gap_x: 5, gap_y: 9, scale: 0.5 }, { shape: 3, size: 8, stroke_width: 2, size_range: 0.6, opacity_range: 0.5 }]],
    ["voronoiShader", [{}, { glow: 1, color_count: 3, time: 3 }, { color_count: 1, distortion: 0, gap: 0 },
      { color_count: 0, steps_per_color: 1, scale: 4 }]],
    ["imageDitheringShader", [{}, { dither_type: 1 }, { dither_type: 2, size: 0.5 }, { dither_type: 3, color_steps: 7, inverted: 1 },
      { original_colors: 1, color_steps: 3 }]],
    ["simplexNoiseShader", [{}, { softness: 1, time: 5 }, { color_count: 2, steps_per_color: 1 }, { color_count: 1 }]],
    ["staticMeshGradientShader", [{}, { positions: 40, mixing: 0 }, { wave_x: 0, wave_y: 0, rotation: 0, color_count: 1 }]],
    ["staticRadialGradientShader", [{}, { focal_distance: 0, mixing: 0 }, { distortion: 1, distortion_shift: 0.3, falloff: -0.6 },
      { color_count: 1, radius: 3, mixing: 1 }]],
  ]) {
    // The mesh distortion now uses a WGSL loop, which takes the scalar path.
    const variants = await invocationVariants(await paperShader(name), name !== "meshGradientShader");
    for (const [width, height] of [[1, 1], [7, 5], [37, 23]]) {
      const input = paperInput(width, height);
      for (const uniforms of uniformSets) {
        variants.compare(input, { width, ...uniforms });
        const output = f32Values(await run(variants.paths[0], input, Object.entries({ width, ...uniforms })
          .map(([key, value]) => `${key}=${value}`)));
        assert.ok(output.every((v) => v >= 0 && v <= 1), `${name} ${JSON.stringify(uniforms)} stays in [0, 1]`);
      }
    }
    await execFileAsync(qip, ["run", "-i", variants.paths[1], "--", ...strictCheckers]);
  }
});

test("demo Paper swirl accepts zero bands for ripples", async () => {
  const module = await compile(await paperShader("swirlShader"));
  const width = 33;
  const input = paperInput(width, width);
  const settings = [`width=${width}`, "noise=0", "softness=0"];
  const output = f32Values(await run(module, input, [...settings, "band_count=0"]));
  const angular = f32Values(await run(module, input, [...settings, "band_count=1"]));
  assert.ok(output.every(Number.isFinite));
  assert.notDeepEqual(output, angular, "zero bands removes the angular term");
  assert.ok(new Set(output.filter((_, i) => i % 4 === 0)).size > 2, "ripples vary with radius");
});

test("demo Paper fluted glass without distortion passes the image through", async () => {
  const module = await compile(await paperShader("flutedGlassShader"));
  const [width, height] = [40, 30];
  const input = f32Values(paperInput(width, height));
  const output = f32Values(await run(module, f32Bytes(input),
    [`width=${width}`, "distortion=0", "highlights=0", "shadows=0", "edges=0"]));
  // Bilinear sampling at pixel centres returns each pixel, away from the frame's edge.
  for (let y = 2; y < height - 2; y++) {
    for (let x = 2; x < width - 2; x++) {
      for (let c = 0; c < 4; c++) {
        const i = (y * width + x) * 4 + c;
        assert.ok(Math.abs(output[i] - input[i]) < 1e-4, `pixel ${x},${y} lane ${c}`);
      }
    }
  }
});

test("demo Paper dot grid draws dots at cell centres", async () => {
  const module = await compile(await paperShader("dotGridShader"));
  const width = 64;
  const output = f32Values(await run(module, paperInput(width, width), [`width=${width}`]));
  const pixel = (x, y) => output.slice((y * width + x) * 4, (y * width + x) * 4 + 4);
  // The image centre is a cell corner, so the 32-pixel cells are centred 16 pixels away.
  for (const [x, y] of [[15, 15], [47, 15], [15, 47], [47, 47]]) {
    assert.ok(pixel(x, y).slice(0, 3).every((v) => v > 0.9), `dot at ${x},${y}`);
  }
  for (const [x, y] of [[31, 31], [0, 0], [63, 63], [31, 15]]) {
    assert.deepEqual(pixel(x, y), [0, 0, 0, 1], `background at ${x},${y}`);
  }
});

test("demo Paper image dithering turns mid-grey into Bayer patterns", async () => {
  const module = await compile(await paperShader("imageDitheringShader"));
  const width = 32;
  const grey = f32Bytes(Array.from({ length: width * width * 4 }, (_, i) => (i % 4 === 3 ? 1 : 0.5)));
  for (const [type, size] of [[2, 2], [3, 4], [4, 8]]) {
    const output = f32Values(await run(module, grey, [`width=${width}`, `dither_type=${type}`, "size=1", "color_steps=1"]));
    // With one step, mid-grey lights the upper half of the Bayer thresholds.
    const lit = (x, y) => output[(y * width + x) * 4 + 1] === Math.fround(1);
    let count = 0;
    for (let y = 0; y < width; y++) {
      for (let x = 0; x < width; x++) {
        assert.equal(lit(x, y), lit(x % size, y % size), `${size}x${size} pattern repeats at ${x},${y}`);
        if (x < size && y < size && lit(x, y)) count++;
      }
    }
    assert.equal(count, size * size / 2, `${size}x${size} lights half its cells`);
  }
});

test("demo Paper waves without amplitude draw horizontal lines", async () => {
  const module = await compile(await paperShader("wavesShader"));
  const [width, height] = [24, 40];
  const output = f32Values(await run(module, paperInput(width, height), [`width=${width}`, "amplitude=0", "softness=0.2"]));
  const rows = new Set();
  for (let y = 0; y < height; y++) {
    const row = output.slice(y * width * 4, (y + 1) * width * 4);
    for (let x = 1; x < width; x++) assert.deepEqual(row.slice(x * 4, x * 4 + 4), row.slice(0, 4), `row ${y} is uniform`);
    rows.add(row[0]);
  }
  assert.ok(rows.size > 2, "rows alternate between colors");
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

async function flurryShader(id) {
  const page = await readFile("site/flurry.md", "utf8");
  const source = page.match(new RegExp(`<script type="text/wgsl" id="${id}">([\\s\\S]*?)</script>`))?.[1];
  assert.ok(source, `the Flurry page has the ${id} shader`);
  return source;
}

test("Flurry looped shaders compute ribbon points and draw them additively", async () => {
  const points = await compile(await flurryShader("flurry-points"));
  const ribbons = await compile(await flurryShader("flurry-ribbons"));
  const width = 160;
  const height = 100;
  const data = f32Values(await run(points, f32Bytes(new Array(width * height * 4).fill(0)), [`width=${width}`, "time=140"]));
  for (let row = 0; row < 10; row++) {
    for (let k = 0; k <= 40; k++) {
      const texel = data.slice((row * width + k) * 4, (row * width + k) * 4 + 4);
      assert.ok(texel.every(Number.isFinite), `point (${k}, ${row}) is finite`);
      if (row < 5) assert.ok(texel[2] >= 1 && (texel[3] === 0 || texel[3] === 1), `point (${k}, ${row}) has a radius and a flag`);
      else assert.ok(texel.slice(0, 3).every((c) => c >= 0), `segment color (${k}, ${row}) is not negative`);
    }
  }
  assert.ok(data.slice((10 * width) * 4).every((v) => v === 0), "pixels past the 41×10 corner stay black");
  const output = f32Values(await run(ribbons, f32Bytes(data), [`width=${width}`]));
  let lit = 0;
  for (let p = 0; p < width * height; p++) {
    const pixel = output.slice(p * 4, p * 4 + 4);
    assert.ok(pixel.every((c) => c >= 0 && c <= 1), "colors are clamped");
    assert.equal(pixel[3], 1);
    if (pixel[0] + pixel[1] + pixel[2] > 0.1) lit++;
  }
  assert.ok(lit > 100 && lit < width * height / 2, `some but not most pixels are lit (${lit})`);
  const dark = f32Values(await run(ribbons, f32Bytes(data), [`width=${width}`, "gain=0"]));
  assert.ok(dark.every((v, i) => (i % 4 === 3 ? v === 1 : v === 0)), "gain 0 draws nothing");
});
