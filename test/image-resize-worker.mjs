import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const context = vm.createContext({
  BigInt,
  DataView,
  Error,
  Number,
  Object,
  String,
  TypeError,
  Uint8Array,
  WebAssembly,
  fetch: async () => { throw new Error("unexpected fetch in worker unit test"); },
  performance,
  self: {},
});
const workerSource = readFileSync("site/image-resize-worker.js", "utf8") +
  "\nglobalThis.__imageResizeWorkerTest = { run, readKTX2Size, calculateDimensions, RESIZE_PATHS, ENCODERS };";
vm.runInContext(workerSource, context, { filename: "site/image-resize-worker.js" });
const { run, readKTX2Size, calculateDimensions, RESIZE_PATHS, ENCODERS } =
  context.__imageResizeWorkerTest;

function module(path) {
  return new WebAssembly.Module(readFileSync(path));
}

function initialKTX2() {
  const exports = new WebAssembly.Instance(
    module("components/interactive/macintosh-1bit.wasm"),
    {},
  ).exports;
  const size = renderSize(exports, 0);
  return Uint8Array.from(new Uint8Array(
    exports.memory.buffer,
    renderedOutputPointer(exports),
    size,
  ));
}

test("image resize worker components enforce their explicit directions", () => {
  const input = initialKTX2();
  assert.deepEqual({ ...readKTX2Size(input) }, { width: 512, height: 342 });
  const down = module("image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm");
  const up = module("image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm");

  const reduction = run(down, input, { width: 128, height: 86 });
  assert.equal(reduction.status, "accepted");
  assert.deepEqual({ ...readKTX2Size(reduction.output) }, { width: 128, height: 86 });
  assert.equal(run(up, input, { width: 128, height: 86 }).status, "rejected");

  assert.equal(run(down, input, { width: 768, height: 513 }).status, "rejected");
  const enlargement = run(up, input, { width: 768, height: 513 });
  assert.equal(enlargement.status, "accepted");
  assert.deepEqual({ ...readKTX2Size(enlargement.output) }, { width: 768, height: 513 });
});

test("image resize worker prefers SIMD and retains scalar fallbacks", () => {
  for (const config of Object.values(RESIZE_PATHS)) {
    assert.equal(config.paths.length, 2);
    assert.match(config.paths[0], /-simd\.wasm$/);
    assert.doesNotMatch(config.paths[1], /-simd\.wasm$/);
    for (const path of config.paths) assert.equal(existsSync(`.${path}`), true, path);
  }
});

test("image resize dimensions fit the box and enlarge only when requested", () => {
  assert.deepEqual(
    { ...calculateDimensions(4000, 3000, 1600, 1600, false) },
    { width: 1600, height: 1200 },
  );
  assert.deepEqual(
    { ...calculateDimensions(800, 600, 1600, 1600, false) },
    { width: 800, height: 600 },
  );
  assert.deepEqual(
    { ...calculateDimensions(800, 600, 1600, 1600, true) },
    { width: 1600, height: 1200 },
  );
  assert.deepEqual(
    { ...calculateDimensions(600, 800, 1600, 1000, true) },
    { width: 750, height: 1000 },
  );
});

test("image resize worker declares the four output choices", () => {
  assert.deepEqual(Object.keys(ENCODERS), [
    "jpeg",
    "png",
    "webp-lossless",
    "webp-lossy",
  ]);
  for (const config of Object.values(ENCODERS)) {
    assert.equal(existsSync(`.${config.path}`), true, config.path);
  }
  assert.equal(ENCODERS.jpeg.lossy, true);
  assert.equal(ENCODERS["webp-lossy"].lossy, true);
  assert.equal(ENCODERS.png.lossy, false);
  assert.equal(ENCODERS["webp-lossless"].lossy, false);
});

test("image resize worker output enters the selected encoder", () => {
  const down = module("image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm");
  const resized = run(down, initialKTX2(), { width: 64, height: 43 });
  const config = ENCODERS.png;
  const encoded = run(module(`.${config.path}`), resized.output);
  assert.equal(encoded.status, "accepted");
  assert.deepEqual(
    Array.from(encoded.output.subarray(0, 8)),
    [137, 80, 78, 71, 13, 10, 26, 10],
  );
});
