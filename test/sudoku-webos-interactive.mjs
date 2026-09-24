import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/webos-card-view.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function digest(exports, size) {
  return createHash("sha256")
    .update(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size))
    .digest("hex");
}

test("WebOS Card View advances animation without replacing its KTX2 frame", () => {
  const exports = instantiate();
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);

  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 320 * 220 * 4);
  const initial = digest(exports, size);

  exports.begin_update_at(16n);
  assert.equal(exports.key_event(0xff53, 1), 1);
  assert.equal(exports.finish_update(), 32n);
  assert.equal(digest(exports, size), initial);

  exports.begin_update_at(32n);
  assert.equal(exports.finish_update(), 48n);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("WebOS Card View traps on lifecycle misuse", () => {
  const exports = instantiate();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  qipRenderSize(exports, 0);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
  exports.finish_update();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
});
