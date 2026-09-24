import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const wasm = readFileSync("gui/gif-player.wasm");
const gif = Uint8Array.from([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0,
  0, 0, 0, 255, 0, 0,
  0x21, 0xff, 11, 0x4e, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2e, 0x30, 3, 1, 0, 0, 0,
  0x21, 0xf9, 4, 0, 2, 0, 0, 0,
  0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0,
  0x21, 0xf9, 4, 0, 3, 0, 0, 0,
  0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x4c, 0x01, 0,
  0x3b,
]);

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm)).exports;
}

function bytes(exports, pointer, size) {
  return new Uint8Array(exports.memory.buffer, pointer, size);
}

function contentType(exports, prefix) {
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes(
    exports,
    exports[`${prefix}_content_type_ptr`](),
    exports[`${prefix}_content_type_size`](),
  ));
}

test("GIF player rejects malformed initialization and recovers in place", () => {
  const exports = instantiate();
  assert.equal(decodeRenderResult(exports.render(0)).failed, true);
  bytes(exports, exports.input_ptr(), 1)[0] = 0;
  assert.equal(decodeRenderResult(exports.render(1)).failed, true);

  bytes(exports, exports.input_ptr(), gif.length).set(gif);
  const accepted = decodeRenderResult(exports.render(gif.length));
  assert.equal(accepted.failed, false);
  assert.equal(accepted.value, 228);
  assert.equal(contentType(exports, "input"), "image/gif");
  assert.equal(contentType(exports, "output"), "image/ktx2");
});

test("GIF player schedules and presents GIF frames", () => {
  const exports = instantiate();
  bytes(exports, exports.input_ptr(), gif.length).set(gif);
  let rendered = decodeRenderResult(exports.render(gif.length));
  const size = rendered.value;
  assert.equal(rendered.failed, false);
  assert.deepEqual([...bytes(exports, rendered.outputPointer + 224, 4)], [0, 0, 0, 255]);

  exports.begin_update_at(1n);
  assert.equal(exports.finish_update(), 20n);
  // Updates do not publish output.
  assert.deepEqual([...bytes(exports, rendered.outputPointer + 224, 4)], [0, 0, 0, 255]);

  exports.begin_update_at(20n);
  assert.equal(exports.finish_update(), 50n);
  assert.deepEqual([...bytes(exports, rendered.outputPointer + 224, 4)], [0, 0, 0, 255]);
  rendered = decodeRenderResult(exports.render(0));
  assert.equal(rendered.value, size);
  assert.deepEqual([...bytes(exports, rendered.outputPointer + 224, 4)], [255, 0, 0, 255]);
});
