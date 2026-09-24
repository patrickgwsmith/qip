import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const modules = Object.fromEntries(
  await Promise.all(
    ["formula-1-map", "page-load-waterfall"].map(async (name) => [
      name,
      await readFile(`gui/${name}.wasm`),
    ]),
  ),
);

function instantiate(name) {
  return new WebAssembly.Instance(new WebAssembly.Module(modules[name]), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(exports, size) {
  return createHash("sha256").update(output(exports, size)).digest("hex");
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
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
}

test("formula-1-map retains an update until a separate render", () => {
  const exports = instantiate("formula-1-map");
  assertABI(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 960 * 560 * 4);
  const initial = digest(exports, size);

  exports.begin_update_at(1n);
  assert.equal(exports.key_event("+".codePointAt(0), 1), 1);
  assert.equal(exports.finish_update(), 1n);
  assert.equal(digest(exports, size), initial);

  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("page-load-waterfall schedules play animation through finish_update", () => {
  const exports = instantiate("page-load-waterfall");
  assertABI(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + 760 * 590 * 4);
  const initial = digest(exports, size);

  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(1, 700, 140), 1);
  exports.pointer_event(0, 700, 140);
  assert.equal(exports.finish_update(), 34n);
  assert.equal(digest(exports, size), initial);

  exports.begin_update_at(34n);
  assert.equal(exports.finish_update(), 67n);
  assert.equal(digest(exports, size), initial);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);
});

test("both components trap on update lifecycle misuse", () => {
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
