import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const coverFlowWasm = await readFile("gui/cover-flow.wasm");
const shadowRenderingWasm = await readFile("gui/shadow-rendering.wasm");

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function assertTransactionalInteractiveABI(exports) {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
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
}

test("shadow rendering keeps its controls as update component state", () => {
  const shadow = instantiate(shadowRenderingWasm);
  assertTransactionalInteractiveABI(shadow);
  for (const name of ["x_offset", "y_offset", "blur", "spread", "opacity", "radius"]) {
    assert.equal(shadow[`uniform_set_${name}`], undefined);
  }
  assert.equal(shadow.begin_at, undefined);
  assert.equal(shadow.commit, undefined);

  const size = qipRenderSize(shadow, 0);
  assert.equal(size, 224 + 1120 * 720 * 4);
  const initialDigest = digest(output(shadow, size));

  shadow.begin_update_at(1n);
  assert.equal(shadow.key_event(0xff51, 1), 1);
  assert.equal(shadow.finish_update(), 1n);
  assert.equal(digest(output(shadow, size)), initialDigest);
  assert.equal(qipRenderSize(shadow, 0), size);
  const adjustedDigest = digest(output(shadow, size));
  assert.notEqual(adjustedDigest, initialDigest);

  shadow.begin_update_at(2n);
  assert.equal(shadow.key_event("R".codePointAt(0), 1), 1);
  assert.equal(shadow.finish_update(), 2n);
  assert.equal(digest(output(shadow, size)), adjustedDigest);

  assert.equal(qipRenderSize(shadow, 0), size);
  assert.equal(digest(output(shadow, size)), initialDigest);
});

test("cover flow finishes event state and schedules animation without publishing a frame", () => {
  const cover = instantiate(coverFlowWasm);
  assertTransactionalInteractiveABI(cover);
  assert.equal(cover.uniform_set_feature_mask, undefined);
  assert.equal(cover.begin_at, undefined);
  assert.equal(cover.commit, undefined);

  const size = qipRenderSize(cover, 0);
  assert.equal(size, 224 + 1440 * 960 * 4);
  const initialDigest = digest(output(cover, size));

  cover.begin_update_at(1n);
  assert.equal(cover.key_event(0xff53, 1), 1);
  assert.equal(cover.finish_update(), 17n);
  assert.equal(digest(output(cover, size)), initialDigest);

  cover.begin_update_at(17n);
  assert.equal(cover.finish_update(), 33n);
  assert.equal(qipRenderSize(cover, 0), size);
  assert.notEqual(digest(output(cover, size)), initialDigest);
});

test("cover flow and shadow rendering trap on lifecycle misuse", () => {
  for (const bytes of [coverFlowWasm, shadowRenderingWasm]) {
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
