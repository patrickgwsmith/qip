import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const rasterizerPath = new URL(
  "../image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm",
  import.meta.url,
);
const boundedOutputPath = new URL(
  "../application/wasm/wasm-bounded-output.wasm",
  import.meta.url,
);
const rgba8RasterizerPath = new URL(
  "../image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm",
  import.meta.url,
);
const tigerPath = new URL("fixtures/svg/ghostscript-tiger.svg", import.meta.url);
const pixelOffset = 224;

function decodeResult(result) {
  const bits = BigInt.asUintN(64, result);
  return {
    sizeOrFailure: Number(bits & 0xffffffffn),
    pointer: Number((bits >> 32n) & 0x7fffffffn),
    failed: Number(bits >> 63n),
  };
}

async function instantiate() {
  const { instance } = await WebAssembly.instantiate(await readFile(rasterizerPath));
  return instance.exports;
}

async function instantiateAt(path) {
  const { instance } = await WebAssembly.instantiate(await readFile(path));
  return instance.exports;
}

test("RGBA32F SVG rasterizer carries a bounded-output proof", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(boundedOutputPath));
  const wasm = await readFile(rasterizerPath);
  new Uint8Array(instance.exports.memory.buffer, instance.exports.input_ptr(), wasm.length).set(wasm);
  const result = decodeResult(instance.exports.render(wasm.length));
  assert.equal(result.failed, 0);
  assert.equal(result.sizeOrFailure, wasm.length);
});

test("matched-quality RGBA8 SVG rasterizer carries a bounded-output proof", async () => {
  const { instance } = await WebAssembly.instantiate(await readFile(boundedOutputPath));
  const wasm = await readFile(rgba8RasterizerPath);
  new Uint8Array(instance.exports.memory.buffer, instance.exports.input_ptr(), wasm.length).set(wasm);
  const result = decodeResult(instance.exports.render(wasm.length));
  assert.equal(result.failed, 0);
  assert.equal(result.sizeOrFailure, wasm.length);
});

test("matched-quality RGBA8 renderer quantizes fractional coverage once", async () => {
  const exports = await instantiateAt(rgba8RasterizerPath);
  const result = render(
    exports,
    '<svg width="2" height="2"><rect x="0.25" y="0.25" width="1" height="1" fill="#ff0000"/></svg>',
  );
  const view = new DataView(exports.memory.buffer, result.pointer, result.sizeOrFailure);
  assert.equal(view.getUint32(12, true), 43);
  assert.equal(result.sizeOrFailure, pixelOffset + 2 * 2 * 4);
  assert.deepEqual(
    [...new Uint8Array(exports.memory.buffer, result.pointer + pixelOffset, 16)],
    [255, 0, 0, 143, 255, 0, 0, 48, 255, 0, 0, 48, 255, 0, 0, 16],
  );
});

test("matched-quality RGBA8 renderer resolves currentColor", async () => {
  const exports = await instantiateAt(rgba8RasterizerPath);
  const svg = '<svg width="1" height="1"><rect width="1" height="1" fill="currentColor"/></svg>';

  let result = render(exports, svg);
  assert.deepEqual(
    [...new Uint8Array(exports.memory.buffer, result.pointer + pixelOffset, 4)],
    [0, 0, 0, 255],
  );

  assert.equal(exports.uniform_set_current_color_rgba(0xff0000ff) >>> 0, 0xff0000ff);
  result = render(exports, svg);
  assert.deepEqual(
    [...new Uint8Array(exports.memory.buffer, result.pointer + pixelOffset, 4)],
    [255, 0, 0, 255],
  );
});

function render(exports, source, width = 0, height = 0) {
  const input = typeof source === "string" ? encoder.encode(source) : source;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  if (width !== 0) assert.equal(exports.uniform_set_width(width), width);
  if (height !== 0) assert.equal(exports.uniform_set_height(height), height);
  const result = decodeResult(exports.render(input.length));
  assert.equal(result.failed, 0);
  return result;
}

function inspectKtx2(exports, result, width, height) {
  const view = new DataView(exports.memory.buffer, result.pointer, result.sizeOrFailure);
  assert.equal(view.getUint32(12, true), 109);
  assert.equal(view.getUint32(20, true), width);
  assert.equal(view.getUint32(24, true), height);
  assert.equal(result.sizeOrFailure, pixelOffset + width * height * 16);
  return view;
}

function pixel(view, width, x, y) {
  const offset = pixelOffset + (y * width + x) * 16;
  return [0, 4, 8, 12].map((channel) => view.getFloat32(offset + channel, true));
}

function closeTo(actual, expected, epsilon = 1e-6) {
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < actual.length; index += 1) {
    assert.ok(
      Math.abs(actual[index] - expected[index]) <= epsilon,
      `channel ${index}: expected ${expected[index]}, received ${actual[index]}`,
    );
  }
}

test("RGBA32F SVG rasterizer produces fractional SIMD coverage", async () => {
  const exports = await instantiate();
  const result = render(
    exports,
    '<svg width="2" height="2"><rect x="0.25" y="0.25" width="1" height="1" fill="#ff0000"/></svg>',
  );
  const view = inspectKtx2(exports, result, 2, 2);

  closeTo(pixel(view, 2, 0, 0), [1, 0, 0, 9 / 16]);
  closeTo(pixel(view, 2, 1, 0), [1, 0, 0, 3 / 16]);
  closeTo(pixel(view, 2, 0, 1), [1, 0, 0, 3 / 16]);
  closeTo(pixel(view, 2, 1, 1), [1, 0, 0, 1 / 16]);
});

test("RGBA32F SVG rasterizer resolves currentColor", async () => {
  const exports = await instantiate();
  const svg = '<svg width="1" height="1"><rect width="1" height="1" fill="currentColor"/></svg>';

  let result = render(exports, svg);
  closeTo(pixel(inspectKtx2(exports, result, 1, 1), 1, 0, 0), [0, 0, 0, 1]);

  assert.equal(exports.uniform_set_current_color_rgba(0xff0000ff) >>> 0, 0xff0000ff);
  result = render(exports, svg);
  closeTo(pixel(inspectKtx2(exports, result, 1, 1), 1, 0, 0), [1, 0, 0, 1]);
});

test("RGBA32F SVG rasterizer scan-converts path spans", async () => {
  const exports = await instantiate();
  const result = render(
    exports,
    '<svg width="2" height="2"><path d="M.25 .25H1.25V1.25H.25Z" fill="#ff0000"/></svg>',
  );
  const view = inspectKtx2(exports, result, 2, 2);

  closeTo(pixel(view, 2, 0, 0), [1, 0, 0, 9 / 16]);
  closeTo(pixel(view, 2, 1, 0), [1, 0, 0, 3 / 16]);
  closeTo(pixel(view, 2, 0, 1), [1, 0, 0, 3 / 16]);
  closeTo(pixel(view, 2, 1, 1), [1, 0, 0, 1 / 16]);
});

test("RGBA32F SVG rasterizer composites coverage in linear light", async () => {
  const exports = await instantiate();
  assert.equal(exports.uniform_set_background_color_rgba(0x0000ffff), 0x0000ffff);
  const result = render(
    exports,
    '<svg width="1" height="1"><rect width="0.5" height="1" fill="#ff0000"/></svg>',
  );
  const view = inspectKtx2(exports, result, 1, 1);

  closeTo(pixel(view, 1, 0, 0), [0.5, 0, 0.5, 1]);
});

test("RGBA32F SVG rasterizer sizes a viewBox and applies matrix transforms", async () => {
  const exports = await instantiate();
  const result = render(
    exports,
    '<svg viewBox="0 0 4 2"><g transform="matrix(1,0,0,1,1,0)"><rect width="1" height="2" fill="#00ff00"/></g></svg>',
    4,
    2,
  );
  const view = inspectKtx2(exports, result, 4, 2);

  closeTo(pixel(view, 4, 0, 0), [0, 0, 0, 0]);
  closeTo(pixel(view, 4, 1, 0), [0, 1, 0, 1]);
  closeTo(pixel(view, 4, 2, 0), [0, 0, 0, 0]);
});

test("RGBA32F SVG rasterizer renders the unchanged Ghostscript Tiger fixture", async () => {
  const exports = await instantiate();
  const result = render(exports, await readFile(tigerPath), 64, 64);
  const view = inspectKtx2(exports, result, 64, 64);
  const output = new Uint8Array(exports.memory.buffer, result.pointer, result.sizeOrFailure);
  assert.equal(
    createHash("sha256").update(output).digest("hex"),
    "37b6a78b105c7c8534db583075e24c960200e6076e6313d4615f96ab9b2bda77",
  );
  let painted = 0;
  let fractionalAlpha = 0;
  const colors = new Set();

  for (let y = 0; y < 64; y += 1) {
    for (let x = 0; x < 64; x += 1) {
      const [red, green, blue, alpha] = pixel(view, 64, x, y);
      if (alpha > 0) painted += 1;
      if (alpha > 0 && alpha < 1) fractionalAlpha += 1;
      if (alpha > 0.5) colors.add(`${red.toFixed(2)},${green.toFixed(2)},${blue.toFixed(2)}`);
    }
  }

  assert.ok(painted > 500, `expected a substantial drawing, received ${painted} painted pixels`);
  assert.ok(fractionalAlpha > 50, `expected antialiased edges, received ${fractionalAlpha} fractional pixels`);
  assert.ok(colors.size > 8, `expected multiple Tiger colors, received ${colors.size}`);
});
