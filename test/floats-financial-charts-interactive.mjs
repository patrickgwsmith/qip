import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const specs = [
  ["ieee-754-floats", 760, 560, "6"],
  ["shutterstock-earnings", 1520, 1040, "1"],
  ["openai-anthropic-arr", 1640, 1080, "1"],
];

const modules = Object.fromEntries(
  await Promise.all(specs.map(async ([name]) => [name, await readFile(`gui/${name}.wasm`)])),
);

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
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

for (const [name, width, height, key] of specs) {
  test(`${name} retains a selection until a separate render`, () => {
    const exports = instantiate(modules[name]);
    assertABI(exports);
    const size = qipRenderSize(exports, 0);
    assert.equal(size, 224 + width * height * 4);
    const initial = digest(exports, size);

    assert.equal(exports.begin_at, undefined);
    assert.equal(exports.commit, undefined);
    exports.begin_update_at(1n);
    assert.equal(exports.key_event(key.codePointAt(0), 1), 1);
    assert.equal(exports.finish_update(), 1n);
    assert.equal(digest(exports, size), initial);
    assert.equal(qipRenderSize(exports, 0), size);
    assert.notEqual(digest(exports, size), initial);
  });
}

test("all three components trap on update lifecycle misuse", () => {
  for (const bytes of Object.values(modules)) {
    const exports = instantiate(bytes);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});

test("openai-anthropic-arr animates scale changes for 300 milliseconds", () => {
  const exports = instantiate(modules["openai-anthropic-arr"]);
  const size = qipRenderSize(exports, 0);
  const logFrame = digest(exports, size);

  exports.begin_update_at(1n);
  assert.equal(exports.key_event("L".codePointAt(0), 1), 1);
  assert.equal(exports.finish_update(), 17n);
  assert.equal(qipRenderSize(exports, 0), size);
  const transitionStart = digest(exports, size);
  assert.notEqual(transitionStart, logFrame);

  exports.begin_update_at(151n);
  assert.equal(exports.finish_update(), 167n);
  assert.equal(qipRenderSize(exports, 0), size);
  const midpoint = digest(exports, size);
  assert.notEqual(midpoint, transitionStart);

  exports.begin_update_at(301n);
  assert.equal(exports.finish_update(), 301n);
  assert.equal(qipRenderSize(exports, 0), size);
  const linearFrame = digest(exports, size);
  assert.notEqual(linearFrame, midpoint);
  assert.notEqual(linearFrame, logFrame);
});

test("openai-anthropic-arr uses the full milestone hover area for its tooltip", () => {
  const exports = instantiate(modules["openai-anthropic-arr"]);
  const size = qipRenderSize(exports, 0);
  const initial = digest(exports, size);

  exports.begin_update_at(1n);
  assert.equal(exports.pointer_event(0, 1426, 212), 1); // 24 logical pixels above the July 2026 Anthropic point.
  assert.equal(exports.finish_update(), 1n);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.notEqual(digest(exports, size), initial);

  exports.begin_update_at(2n);
  assert.equal(exports.pointer_event(0, -1, -1), 1);
  assert.equal(exports.finish_update(), 2n);
  assert.equal(qipRenderSize(exports, 0), size);
  assert.equal(digest(exports, size), initial);
});
