import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { decodeRenderResult, renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const downPath = "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm";
const upPath = "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm";

function instantiate(path) {
  return new WebAssembly.Instance(new WebAssembly.Module(readFileSync(path)), {}).exports;
}

function canonicalHeader() {
  const desktop = instantiate("components/interactive/macintosh-1bit.wasm");
  const size = renderSize(desktop, 0);
  return Uint8Array.from(new Uint8Array(
    desktop.memory.buffer,
    renderedOutputPointer(desktop),
    size,
  ).subarray(0, 224));
}

const header = canonicalHeader();

function ktx2(width, height, rgba) {
  assert.equal(rgba.length, width * height * 4);
  const bytes = new Uint8Array(224 + rgba.length);
  bytes.set(header);
  bytes.set(rgba, 224);
  const view = new DataView(bytes.buffer);
  view.setUint32(20, width, true);
  view.setUint32(24, height, true);
  view.setBigUint64(88, BigInt(rgba.length), true);
  view.setBigUint64(96, BigInt(rgba.length), true);
  return bytes;
}

function resize(path, input, width, height) {
  const exports = instantiate(path);
  assert.equal(exports.uniform_set_width(width), width);
  assert.equal(exports.uniform_set_height(height), height);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const size = renderSize(exports, input.length);
  return {
    exports,
    bytes: Uint8Array.from(new Uint8Array(
      exports.memory.buffer,
      renderedOutputPointer(exports),
      size,
    )),
  };
}

function solid(width, height, color) {
  const pixels = new Uint8Array(width * height * 4);
  for (let offset = 0; offset < pixels.length; offset += 4) pixels.set(color, offset);
  return ktx2(width, height, pixels);
}

function assertImage(bytes, width, height, color) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(view.getUint32(12, true), 43);
  assert.equal(view.getUint32(20, true), width);
  assert.equal(view.getUint32(24, true), height);
  assert.equal(bytes.length, 224 + width * height * 4);
  for (let offset = 224; offset < bytes.length; offset += 4) {
    assert.deepEqual(Array.from(bytes.subarray(offset, offset + 4)), color);
  }
}

test("Lanczos3 reduction preserves constant linear-light color", () => {
  const color = [71, 133, 209, 147];
  const result = resize(downPath, solid(7, 5, color), 3, 2);
  assertImage(result.bytes, 3, 2, color);

  const input = solid(7, 5, color);
  new Uint8Array(result.exports.memory.buffer, result.exports.input_ptr(), input.length).set(input);
  const resetSize = renderSize(result.exports, input.length);
  const resetBytes = new Uint8Array(
    result.exports.memory.buffer,
    renderedOutputPointer(result.exports),
    resetSize,
  );
  assertImage(resetBytes, 4, 3, color);
});

test("Mitchell enlargement preserves constant linear-light color", () => {
  const color = [225, 91, 32, 203];
  const result = resize(upPath, solid(3, 2, color), 8, 7);
  assertImage(result.bytes, 8, 7, color);
});

test("premultiplied enlargement does not bleed hidden RGB", () => {
  const input = ktx2(2, 1, new Uint8Array([
    255, 0, 0, 0,
    0, 0, 255, 255,
  ]));
  const { bytes } = resize(upPath, input, 12, 3);
  for (let offset = 224; offset < bytes.length; offset += 4) {
    assert.equal(bytes[offset], 0, "transparent red must not enter visible pixels");
  }
});

test("direction-specific components reject the opposite operation", () => {
  const input = solid(2, 2, [20, 40, 60, 255]);
  for (const [path, rejectedSize, acceptedSize] of [
    [downPath, 3, 1],
    [upPath, 1, 3],
  ]) {
    const exports = instantiate(path);
    new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
    exports.uniform_set_width(rejectedSize);
    exports.uniform_set_height(rejectedSize);
    const rejected = decodeRenderResult(exports.render(input.length));
    assert.equal(rejected.failed, true);
    assert.equal(rejected.value, 0);
    assert.equal(exports.failure_modes_per_input_offset(), 0);

    exports.uniform_set_width(acceptedSize);
    exports.uniform_set_height(acceptedSize);
    assert.ok(renderSize(exports, input.length) > 0, "the rejected instance remains reusable");
  }
});

test("an unchanged axis remains exact", () => {
  const pixels = new Uint8Array([
    10, 20, 30, 255,
    70, 80, 90, 255,
    140, 150, 160, 255,
  ]);
  const { bytes } = resize(upPath, ktx2(3, 1, pixels), 3, 4);
  for (let y = 0; y < 4; y += 1) {
    assert.deepEqual(Array.from(bytes.subarray(224 + y * 12, 224 + y * 12 + 12)), Array.from(pixels));
  }
});

test("an omitted dimension preserves aspect ratio", () => {
  const color = [44, 88, 132, 255];
  const { bytes } = resize(upPath, solid(3, 2, color), 6, 0);
  assertImage(bytes, 6, 4, color);
});
