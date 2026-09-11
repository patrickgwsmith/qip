import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Worker } from "node:worker_threads";
import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const workerSource = String.raw`
const { parentPort, workerData } = require("node:worker_threads");
const { readFileSync } = require("node:fs");
try {
  const exports = new WebAssembly.Instance(
    new WebAssembly.Module(readFileSync(workerData.path)),
    {},
  ).exports;
  exports._initialize?.();
  const input = new Uint8Array(workerData.input);
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length).set(input);
  exports.uniform_set_width(workerData.width);
  exports.uniform_set_height(workerData.height);
  const bits = BigInt.asUintN(64, exports.render(input.length));
  if ((bits & (1n << 63n)) !== 0n) throw new Error("render rejected input");
  const size = Number(bits & 0xffff_ffffn);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const output = Uint8Array.from(new Uint8Array(exports.memory.buffer, pointer, size));
  parentPort.postMessage(output, [output.buffer]);
} catch (error) {
  parentPort.postMessage({ error: error instanceof Error ? error.message : String(error) });
}
`;

function isolatedRun(path, input, width, height) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(workerSource, {
      eval: true,
      workerData: { path, input, width, height },
    });
    worker.once("message", async (message) => {
      await worker.terminate();
      if (message.error) reject(new Error(message.error));
      else resolve(message);
    });
    worker.once("error", reject);
  });
}

function instantiate(path) {
  return new WebAssembly.Instance(new WebAssembly.Module(readFileSync(path)), {}).exports;
}

function rgba8KTX2(width, height) {
  const desktop = instantiate("components/interactive/macintosh-1bit.wasm");
  const renderedSize = renderSize(desktop, 0);
  const rendered = new Uint8Array(
    desktop.memory.buffer,
    renderedOutputPointer(desktop),
    renderedSize,
  );
  const bytes = new Uint8Array(224 + width * height * 4);
  bytes.set(rendered.subarray(0, 224));
  for (let pixel = 0; pixel < width * height; pixel++) {
    const offset = 224 + pixel * 4;
    bytes.set([
      (pixel * 37 + 11) & 255,
      (pixel * 73 + 29) & 255,
      (pixel * 17 + 191) & 255,
      (pixel * 41 + 53) & 255,
    ], offset);
  }
  const view = new DataView(bytes.buffer);
  view.setUint32(20, width, true);
  view.setUint32(24, height, true);
  view.setBigUint64(88, BigInt(bytes.length - 224), true);
  view.setBigUint64(96, BigInt(bytes.length - 224), true);
  return bytes;
}

async function toFloat(input) {
  const converter = instantiate(
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm",
  );
  new Uint8Array(converter.memory.buffer, converter.input_ptr(), input.length).set(input);
  const size = renderSize(converter, input.length);
  return Uint8Array.from(new Uint8Array(
    converter.memory.buffer,
    renderedOutputPointer(converter),
    size,
  ));
}

async function toDisplayP3Float(input) {
  const converter = instantiate(
    "image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm",
  );
  new Uint8Array(converter.memory.buffer, converter.input_ptr(), input.length).set(input);
  const size = renderSize(converter, input.length);
  return Uint8Array.from(new Uint8Array(
    converter.memory.buffer,
    renderedOutputPointer(converter),
    size,
  ));
}

test("RGBA8 SIMD resizers match the scalar components byte for byte", async () => {
  const input = rgba8KTX2(9, 7);
  for (const [scalar, simd, width, height] of [
    [
      "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm",
      "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm",
      5,
      3,
    ],
    [
      "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm",
      "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.wasm",
      17,
      13,
    ],
  ]) {
    const expected = await isolatedRun(scalar, input, width, height);
    const actual = await isolatedRun(simd, input, width, height);
    assert.deepEqual(actual, expected);
  }
});

test("float32 Zig and Odin SIMD enlargement matches scalar output", async () => {
  const input = await toFloat(rgba8KTX2(7, 5));
  const width = 15;
  const height = 11;
  const scalar = await isolatedRun(
    "image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell.wasm",
    input,
    width,
    height,
  );
  for (const path of [
    "image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-simd.wasm",
    "image/ktx2/ktx2-rgba32float-bt709-linear-resize-up-mitchell-odin-simd.wasm",
  ]) {
    assert.deepEqual(await isolatedRun(path, input, width, height), scalar);
  }
});

test("Display P3 float32 SIMD resizers match the scalar components", async () => {
  const input = await toDisplayP3Float(rgba8KTX2(9, 7));
  for (const [scalar, simd, width, height] of [
    [
      "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3.wasm",
      "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-down-lanczos3-simd.wasm",
      5,
      3,
    ],
    [
      "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm",
      "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell-simd.wasm",
      17,
      13,
    ],
  ]) {
    const expected = await isolatedRun(scalar, input, width, height);
    const actual = await isolatedRun(simd, input, width, height);
    assert.deepEqual(actual, expected);
  }
});
