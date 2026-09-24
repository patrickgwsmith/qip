import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const paths = {
  moon: "gui/moon-phases.wasm",
  cover: "gui/cover-flow-lofi.wasm",
  dock: "gui/dock-magnification.wasm",
};

const wasm = Object.fromEntries(
  await Promise.all(Object.entries(paths).map(async ([name, path]) => [name, await readFile(path)])),
);

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
}

function bytesAt(exports, pointer, size) {
  return new Uint8Array(exports.memory.buffer, pointer, size);
}

function digestOutput(exports, size) {
  return createHash("sha256").update(bytesAt(exports, qipRenderedOutputPointer(exports), size)).digest("hex");
}

function assertABI(exports, inputCapacity) {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  assert.equal(exports.input_bytes_cap(), inputCapacity);
  const type = new TextDecoder("utf-8", { fatal: true }).decode(
    bytesAt(exports, exports.output_content_type_ptr(), exports.output_content_type_size()),
  );
  assert.equal(type, "image/ktx2");
}

function assertUpdateABI(exports, inputCapacity) {
  assertABI(exports, inputCapacity);
  assert.equal(exports.begin_at, undefined);
  assert.equal(exports.commit, undefined);
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
}

function writeInput(exports, text) {
  const encoded = new TextEncoder().encode(text);
  assert.ok(encoded.length <= exports.input_bytes_cap());
  bytesAt(exports, exports.input_ptr(), encoded.length).set(encoded);
  return encoded.length;
}

test("moon phases combines initial source input with later navigation updates", () => {
  const moon = instantiate(wasm.moon);
  assertUpdateABI(moon, 64);

  const inputSize = writeInput(moon, "2026-06-15");
  const size = qipRenderSize(moon, inputSize);
  assert.equal(size, 224 + 420 * 300 * 4);
  const initial = digestOutput(moon, size);

  moon.begin_update_at(1n);
  assert.equal(moon.key_event(0xff53, 1), 1);
  assert.equal(moon.finish_update(), 1n);
  assert.equal(digestOutput(moon, size), initial);

  assert.equal(qipRenderSize(moon, 0), size);
  assert.notEqual(digestOutput(moon, size), initial);

  const replacementSize = writeInput(moon, "2026-07-01");
  assert.throws(() => qipRenderSize(moon, replacementSize), WebAssembly.RuntimeError);
});

test("cover flow lofi publishes animation only when rendered", () => {
  const cover = instantiate(wasm.cover);
  assertUpdateABI(cover, 0);

  const size = qipRenderSize(cover, 0);
  assert.equal(size, 224 + 720 * 480 * 4);
  const initial = digestOutput(cover, size);

  cover.begin_update_at(1n);
  assert.equal(cover.key_event(0xff53, 1), 1);
  assert.equal(cover.finish_update(), 17n);
  assert.equal(digestOutput(cover, size), initial);

  cover.begin_update_at(17n);
  assert.equal(cover.finish_update(), 33n);
  assert.equal(qipRenderSize(cover, 0), size);
  assert.notEqual(digestOutput(cover, size), initial);
});

test("dock hover animation updates independently of output publication", () => {
  const dock = instantiate(wasm.dock);
  assertUpdateABI(dock, 0);

  const size = qipRenderSize(dock, 0);
  assert.equal(size, 224 + 1800 * 840 * 4);
  const initial = digestOutput(dock, size);

  dock.begin_update_at(1n);
  assert.equal(dock.pointer_event(0, 900, 700), 1);
  assert.equal(dock.finish_update(), 17n);
  assert.equal(digestOutput(dock, size), initial);

  dock.begin_update_at(17n);
  assert.equal(dock.finish_update(), 33n);
  assert.equal(qipRenderSize(dock, 0), size);
  assert.notEqual(digestOutput(dock, size), initial);
});

test("all three components trap on update misuse", () => {
  for (const name of ["moon", "cover", "dock"]) {
    const exports = instantiate(wasm[name]);
    const inputSize = name === "moon" ? writeInput(exports, "2026-05-31") : 0;
    qipRenderSize(exports, inputSize);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
