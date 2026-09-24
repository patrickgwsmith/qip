import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = Object.fromEntries(
  await Promise.all(
    ["layout-systems", "browser-security", "graph-calculator"].map(async (name) => [
      name,
      await readFile(`gui/${name}.wasm`),
    ]),
  ),
);

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
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
    new Uint8Array(
      exports.memory.buffer,
      exports.output_content_type_ptr(),
      exports.output_content_type_size(),
    ),
  );
  assert.equal(type, "image/ktx2");
}

function initialFrame(exports, pixelBytes) {
  assertABI(exports);
  const size = qipRenderSize(exports, 0);
  assert.equal(size, 224 + pixelBytes);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
  return { size, digest: digest(exports, size) };
}

test("layout controls update without publishing until render", () => {
  const layout = instantiate(wasm["layout-systems"]);
  const initial = initialFrame(layout, 640 * 420 * 4);

  layout.begin_update_at(1n);
  assert.equal(layout.pointer_event(1, 180, 60), 1);
  assert.equal(layout.pointer_event(0, 180, 60), 1);
  assert.equal(layout.finish_update(), 1n);
  assert.equal(digest(layout, initial.size), initial.digest);

  assert.equal(qipRenderSize(layout, 0), initial.size);
  assert.notEqual(digest(layout, initial.size), initial.digest);
});

test("browser security retains its selected topic across updates", () => {
  const security = instantiate(wasm["browser-security"]);
  const initial = initialFrame(security, 640 * 420 * 4);

  security.begin_update_at(1n);
  assert.equal(security.pointer_event(1, 120, 60), 1);
  assert.equal(security.pointer_event(0, 120, 60), 1);
  assert.equal(security.finish_update(), 1n);
  assert.equal(digest(security, initial.size), initial.digest);

  assert.equal(qipRenderSize(security, 0), initial.size);
  assert.notEqual(digest(security, initial.size), initial.digest);
});

test("graph calculator distinguishes cleared input from uninitialized state", () => {
  const graph = instantiate(wasm["graph-calculator"]);
  const initial = initialFrame(graph, 320 * 220 * 4);

  graph.begin_update_at(1n);
  assert.equal(graph.key_event("C".codePointAt(0), 1), 1);
  assert.equal(graph.finish_update(), 1n);
  assert.equal(digest(graph, initial.size), initial.digest);
  assert.equal(qipRenderSize(graph, 0), initial.size);
  const cleared = digest(graph, initial.size);
  assert.notEqual(cleared, initial.digest);

  graph.begin_update_at(2n);
  assert.equal(graph.finish_update(), 2n);
  assert.equal(qipRenderSize(graph, 0), initial.size);
  assert.equal(digest(graph, initial.size), cleared);
});

test("all three trap on lifecycle misuse", () => {
  for (const bytes of Object.values(wasm)) {
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
