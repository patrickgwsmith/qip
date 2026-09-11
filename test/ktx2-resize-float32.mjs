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
  for (const [name, value] of Object.entries(workerData.uniforms)) {
    exports["uniform_set_" + name](value);
  }
  const bits = BigInt.asUintN(64, exports.render(input.length));
  const value = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    parentPort.postMessage({ failed: true, value });
  } else {
    const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
    const output = Uint8Array.from(new Uint8Array(exports.memory.buffer, pointer, value));
    parentPort.postMessage({ failed: false, output }, [output.buffer]);
  }
} catch (error) {
  parentPort.postMessage({ error: error instanceof Error ? error.message : String(error) });
}
`;

function isolatedRun(path, input, uniforms = {}) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(workerSource, {
      eval: true,
      workerData: { path, input, uniforms },
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

function rgba8KTX2(width, height, color) {
  const desktop = instantiate("components/interactive/macintosh-1bit.wasm");
  const size = renderSize(desktop, 0);
  const rendered = new Uint8Array(
    desktop.memory.buffer,
    renderedOutputPointer(desktop),
    size,
  );
  const bytes = new Uint8Array(224 + width * height * 4);
  bytes.set(rendered.subarray(0, 224));
  for (let offset = 224; offset < bytes.length; offset += 4) bytes.set(color, offset);
  const view = new DataView(bytes.buffer);
  view.setUint32(20, width, true);
  view.setUint32(24, height, true);
  view.setBigUint64(88, BigInt(bytes.length - 224), true);
  view.setBigUint64(96, BigInt(bytes.length - 224), true);
  return bytes;
}

function setFloatPixels(bytes, color) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let offset = 224; offset < bytes.length; offset += 16) {
    for (let channel = 0; channel < 4; channel += 1) {
      view.setFloat32(offset + channel * 4, color[channel], true);
    }
  }
}

function assertFloatImage(bytes, width, height, primaries, color) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(view.getUint32(12, true), 109);
  assert.equal(view.getUint32(20, true), width);
  assert.equal(view.getUint32(24, true), height);
  assert.equal(bytes[117], primaries);
  assert.equal(bytes[118], 1, "the transfer function remains linear");
  assert.equal(bytes.length, 224 + width * height * 16);
  for (let offset = 224; offset < bytes.length; offset += 16) {
    for (let channel = 0; channel < 4; channel += 1) {
      assert.ok(
        Math.abs(view.getFloat32(offset + channel * 4, true) - color[channel]) < 0.00001,
        `pixel channel ${channel} differs at byte ${offset}`,
      );
    }
  }
}

test("profile-named float32 resizers preserve linear BT.709 and Display P3", async () => {
  const rgba8 = rgba8KTX2(4, 2, [120, 80, 40, 255]);
  const bt709 = await isolatedRun(
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm",
    rgba8,
  );
  const p3 = await isolatedRun(
    "image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm",
    rgba8,
  );
  const hdrColor = [2.5, -0.25, 0.75, 0.5];
  setFloatPixels(bt709.output, hdrColor);
  setFloatPixels(p3.output, hdrColor);

  const bt709Down = await isolatedRun(
    "image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm",
    bt709.output,
    { width: 2, height: 1 },
  );
  assertFloatImage(bt709Down.output, 2, 1, 1, hdrColor);

  const p3Up = await isolatedRun(
    "image/ktx2/ktx2-rgba32float-display-p3-linear-resize-up-mitchell.wasm",
    p3.output,
    { width: 8, height: 4 },
  );
  assertFloatImage(p3Up.output, 8, 4, 12, hdrColor);

  await assert.rejects(
    isolatedRun(
      "image/ktx2/ktx2-rgba32float-bt709-linear-resize-down-lanczos3.wasm",
      p3.output,
      { width: 2, height: 1 },
    ),
    /unreachable|out of bounds|wasm/i,
    "a BT.709 component must reject the Display P3 profile",
  );
});
