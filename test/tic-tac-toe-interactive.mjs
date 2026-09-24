import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/tic-tac-toe-sun-moon.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function renderInitial(exports) {
  return qipRenderSize(exports, 0);
}

test("tic-tac-toe exposes timestamp-free Interactive events and KTX2 output", () => {
  const exports = instantiate();
  for (const legacy of ["tick", "begin_at", "commit", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  assert.equal(exports.input_bytes_cap(), 0);

  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(
      exports.memory.buffer,
      exports.output_content_type_ptr(),
      exports.output_content_type_size(),
    ),
  );
  assert.equal(contentType, "image/ktx2");

  const size = renderInitial(exports);
  const bytes = output(exports, size);
  assert.equal(size, 224 + 320 * 320 * 4);
  assert.deepEqual([...bytes.subarray(0, 12)], [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a]);
  const header = new DataView(bytes.buffer, bytes.byteOffset, 104);
  assert.equal(header.getUint32(20, true), 320);
  assert.equal(header.getUint32(24, true), 320);
});

test("events update state while presentation remains unchanged", () => {
  const exports = instantiate();
  const size = renderInitial(exports);
  const initialDigest = digest(output(exports, size));

  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(1, 64, 64), 1);
  assert.equal(exports.pointer_event(0, 64, 64), 0);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(digest(output(exports, size)), initialDigest);

  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(output(exports, size)), initialDigest);

  exports.begin_update_at(2n);
  assert.equal(exports.key_event(0x72, 1), 1);
  assert.equal(exports.finish_update(), 2n);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), initialDigest);
});

test("events outside an update and rendering inside one trap", () => {
  const exports = instantiate();
  const size = renderInitial(exports);

  assert.throws(() => exports.pointer_event(1, 64, 64), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(1, 64, 64), 1);
  assert.equal(exports.pointer_event(0, 64, 64), 0);
  assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(qipRenderSize(exports, 0), size);
});

test("non-increasing update time is host protocol misuse", () => {
  const exports = instantiate();
  renderInitial(exports);
  exports.begin_update_at(1n);
  assert.equal(exports.finish_update(), 1n);
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
});
