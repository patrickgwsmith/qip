import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const modules = Object.fromEntries(
  await Promise.all(
    ["photo-light-table", "xbox-dashboard"].map(async (name) => [
      name,
      await readFile(`gui/${name}.wasm`),
    ]),
  ),
);

function instantiate(name) {
  return new WebAssembly.Instance(new WebAssembly.Module(modules[name]), {}).exports;
}

function digest(exports, size) {
  const bytes = new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
  return createHash("sha256").update(bytes).digest("hex");
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

test("photo-light-table retains selection animation without publishing a frame", () => {
  const exports = instantiate("photo-light-table");
  assertABI(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 1600 * 1040 * 4);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
  const initial = digest(exports, size);

  exports.begin_update_at(1n);
  assert.equal(exports.key_event(0xff53, 1), 1);
  assert.equal(exports.finish_update(), 17n);
  assert.equal(digest(exports, size), initial);

  exports.begin_update_at(17n);
  assert.equal(exports.finish_update(), 33n);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("xbox-dashboard derives its continuous pulse from update time", () => {
  const exports = instantiate("xbox-dashboard");
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

test("photo and Xbox trap on update lifecycle misuse", () => {
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
