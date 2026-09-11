import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const componentPath = new URL(
  "../image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm",
  import.meta.url,
);
const tigerPath = new URL("fixtures/svg/ghostscript-tiger.svg", import.meta.url);
const pixelOffset = 224;

function decodeResult(value) {
  const bits = BigInt.asUintN(64, value);
  return {
    size: Number(bits & 0xffffffffn),
    pointer: Number((bits >> 32n) & 0x7fffffffn),
    failed: Number(bits >> 63n),
  };
}

async function instantiate(path = componentPath) {
  const { instance } = await WebAssembly.instantiate(await readFile(path));
  return instance.exports;
}

function render(exports, source, width = 0, height = 0) {
  const input = typeof source === "string" ? encoder.encode(source) : source;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  if (width) assert.equal(exports.uniform_set_width(width), width);
  if (height) assert.equal(exports.uniform_set_height(height), height);
  return decodeResult(exports.render(input.length));
}

function inspectKtx2(exports, result, width, height) {
  assert.equal(result.failed, 0);
  assert.equal(result.size, pixelOffset + width * height * 4);
  const view = new DataView(exports.memory.buffer, result.pointer, result.size);
  assert.equal(view.getUint32(12, true), 43);
  assert.equal(view.getUint32(20, true), width);
  assert.equal(view.getUint32(24, true), height);
  return new Uint8Array(
    exports.memory.buffer,
    result.pointer + pixelOffset,
    width * height * 4,
  );
}

test("ThorVG SVG rasterizer has no host imports", async () => {
  const module = await WebAssembly.compile(await readFile(componentPath));
  assert.deepEqual(WebAssembly.Module.imports(module), []);
});

test("ThorVG scan conversion produces fractional edge coverage", async () => {
  const exports = await instantiate();
  const result = render(
    exports,
    '<svg width="16" height="16"><path d="M1 1L15 8L1 15Z" fill="#ff0000"/></svg>',
  );
  const pixels = inspectKtx2(exports, result, 16, 16);
  let fractionalAlpha = 0;
  let opaque = 0;
  for (let index = 3; index < pixels.length; index += 4) {
    if (pixels[index] > 0 && pixels[index] < 255) fractionalAlpha += 1;
    if (pixels[index] === 255) opaque += 1;
  }
  assert.equal(fractionalAlpha, 28);
  assert.equal(opaque, 84);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
});

test("ThorVG rasterizer applies an RGBA background and resets uniforms", async () => {
  const exports = await instantiate();
  assert.equal(exports.uniform_set_background_color_rgba(0x112233ff), 0x112233ff);
  let result = render(exports, '<svg width="1" height="1"/>');
  assert.deepEqual([...inspectKtx2(exports, result, 1, 1)], [0x11, 0x22, 0x33, 0xff]);
  result = render(exports, '<svg width="1" height="1"/>');
  assert.deepEqual([...inspectKtx2(exports, result, 1, 1)], [0, 0, 0, 0]);
});

test("ThorVG rasterizer renders the unchanged Ghostscript Tiger fixture", async () => {
  const exports = await instantiate();
  const result = render(exports, await readFile(tigerPath), 64, 64);
  const pixels = inspectKtx2(exports, result, 64, 64);
  const output = new Uint8Array(exports.memory.buffer, result.pointer, result.size);
  assert.equal(
    createHash("sha256").update(output).digest("hex"),
    "51671f54a0e94edf81ffacfa10485997cea25ad87c391581363e1ef105e76525",
  );
  let painted = 0;
  let fractionalAlpha = 0;
  for (let index = 3; index < pixels.length; index += 4) {
    if (pixels[index] > 0) painted += 1;
    if (pixels[index] > 0 && pixels[index] < 255) fractionalAlpha += 1;
  }
  assert.equal(painted, 2811);
  assert.equal(fractionalAlpha, 406);
  assert.equal(exports.arena_live_bytes(), 0);
});

test("ThorVG rasterizer rejects malformed SVG recoverably", async () => {
  const exports = await instantiate();
  const result = render(exports, "<svg><path></svg>");
  assert.equal(result.failed, 0);
  assert.equal(result.size, 0);
  assert.equal(exports.arena_live_bytes(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);
  assert.equal(exports.arena_free_unmatched_count(), 0);
});
