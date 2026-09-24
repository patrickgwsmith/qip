import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const modules = Object.fromEntries(
  await Promise.all(
    ["paint", "ps2-menu"].map(async (name) => [name, await readFile(`gui/${name}.wasm`)]),
  ),
);

function instantiate(name) {
  return new WebAssembly.Instance(new WebAssembly.Module(modules[name]), {}).exports;
}

function digest(exports, size) {
  return createHash("sha256")
    .update(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size))
    .digest("hex");
}

function assertABI(exports) {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.input_bytes_cap(), 0);
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  const type = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, exports.output_content_type_ptr(), exports.output_content_type_size()),
  );
  assert.equal(type, "image/ktx2");
}

test("paint finishes a stroke without replacing the published image", () => {
  const exports = instantiate("paint");
  assertABI(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 320 * 220 * 4);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
  const initial = digest(exports, size);

  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(1, 60, 40), 1);
  assert.equal(exports.pointer_event(1, 72, 40), 1);
  assert.equal(exports.pointer_event(0, 72, 40), 1);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(digest(exports, size), initial);

  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("ps2-menu retains selection and schedules its time-derived pulse", () => {
  const exports = instantiate("ps2-menu");
  assertABI(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 320 * 220 * 4);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
  const initial = digest(exports, size);

  exports.begin_update_at(16n);
  assert.equal(exports.key_event(0xff54, 1), 1);
  assert.equal(exports.finish_update(), 32n);
  assert.equal(digest(exports, size), initial);

  exports.begin_update_at(32n);
  assert.equal(exports.finish_update(), 48n);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("paint and PS2 trap on update lifecycle misuse", () => {
  for (const name of Object.keys(modules)) {
    const exports = instantiate(name);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
