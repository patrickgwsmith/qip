import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const boundedOutputPath = new URL("../application/wasm/wasm-bounded-output.wasm", import.meta.url);
const modules = [
  {
    name: "BMP",
    path: new URL("../image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm", import.meta.url),
    pixelOffset: 54,
    red: [0, 0, 255, 255],
  },
  {
    name: "KTX2",
    path: new URL("../image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm", import.meta.url),
    pixelOffset: 224,
    red: [255, 0, 0, 255],
  },
];

function decodeResult(result) {
  const bits = BigInt.asUintN(64, result);
  return {
    sizeOrFailure: Number(bits & 0xffffffffn),
    pointer: Number((bits >> 32n) & 0x7fffffffn),
    failed: Number(bits >> 63n),
  };
}

async function instantiate(path) {
  const { instance } = await WebAssembly.instantiate(await readFile(path));
  return instance.exports;
}

function writeInput(exports, text) {
  const input = encoder.encode(text);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  return input.length;
}

for (const module of modules) {
  test(`${module.name} SVG rasterizer carries a bounded-output proof`, async () => {
    const checker = await instantiate(boundedOutputPath);
    const wasm = await readFile(module.path);
    new Uint8Array(checker.memory.buffer, checker.input_ptr(), wasm.length).set(wasm);
    const checked = decodeResult(checker.render(wasm.length));
    assert.equal(checked.failed, 0);
    assert.equal(checked.sizeOrFailure, wasm.length);
  });

  test(`${module.name} SVG rasterizer rejects unsupported dimensions and recovers`, async () => {
    const exports = await instantiate(module.path);
    assert.equal(exports.failure_modes_per_input_offset(), 0);

    exports.uniform_set_background_color_rgba(0xff0000ff);
    const rejected = decodeResult(exports.render(writeInput(exports, "<svg/>")));
    assert.deepEqual(rejected, { sizeOrFailure: 0, pointer: 0, failed: 1 });

    const accepted = decodeResult(exports.render(writeInput(exports, '<svg width="1" height="1"></svg>')));
    assert.equal(accepted.failed, 0);
    assert.ok(accepted.sizeOrFailure > module.pixelOffset);
    assert.deepEqual(
      [...new Uint8Array(exports.memory.buffer, accepted.pointer + module.pixelOffset, 4)],
      [0, 0, 0, 0],
    );
  });

  test(`${module.name} SVG rasterizer resets its background uniform`, async () => {
    const exports = await instantiate(module.path);
    const inputSize = writeInput(exports, '<svg width="1" height="1"></svg>');

    assert.equal(exports.uniform_set_background_color_rgba(0xff0000ff), 0xff0000ff | 0);
    const red = decodeResult(exports.render(inputSize));
    assert.equal(red.failed, 0);
    assert.deepEqual(
      [...new Uint8Array(exports.memory.buffer, red.pointer + module.pixelOffset, 4)],
      module.red,
    );

    const transparent = decodeResult(exports.render(inputSize));
    assert.equal(transparent.failed, 0);
    assert.deepEqual(
      [...new Uint8Array(exports.memory.buffer, transparent.pointer + module.pixelOffset, 4)],
      [0, 0, 0, 0],
    );
  });
}
