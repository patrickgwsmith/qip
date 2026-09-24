import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const spreadsheetWasm = await readFile("gui/spreadsheet.wasm");
const platformerWasm = await readFile("gui/side-scroller-platformer.wasm");

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
}

function digestOutput(exports, size) {
  return createHash("sha256")
    .update(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size))
    .digest("hex");
}

function assertUpdateKTX2ABI(exports) {
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
}

test("spreadsheet schedules caret updates and presents them separately", () => {
  const sheet = instantiate(spreadsheetWasm);
  assertUpdateKTX2ABI(sheet);
  const size = qipRenderSize(sheet, 0);
  assert.equal(size, 224 + 375 * 667 * 4);
  const initial = digestOutput(sheet, size);

  sheet.begin_update_at(1n);
  assert.equal(sheet.finish_update(), 1n);

  sheet.begin_update_at(2n);
  assert.equal(sheet.key_event("A".codePointAt(0), 1), 1);
  assert.equal(sheet.finish_update(), 502n);
  assert.equal(digestOutput(sheet, size), initial);

  assert.equal(qipRenderSize(sheet, 0), size);
  const editing = digestOutput(sheet, size);
  assert.notEqual(editing, initial);

  sheet.begin_update_at(502n);
  assert.equal(sheet.finish_update(), 1002n);
  assert.equal(digestOutput(sheet, size), editing);
});

test("side scroller uses bounded fixed updates before held-key events", () => {
  const game = instantiate(platformerWasm);
  assertUpdateKTX2ABI(game);
  const size = qipRenderSize(game, 0);
  assert.equal(size, 224 + 480 * 270 * 4);
  const initial = digestOutput(game, size);

  game.begin_update_at(1n);
  assert.equal(game.finish_update(), 16n);

  game.begin_update_at(16n);
  assert.equal(game.key_event(0xff53, 1), 1);
  assert.equal(game.finish_update(), 32n);
  assert.equal(digestOutput(game, size), initial);

  game.begin_update_at(32n);
  assert.equal(game.finish_update(), 48n);
  assert.equal(qipRenderSize(game, 0), size);
  assert.notEqual(digestOutput(game, size), initial);

  game.begin_update_at(10_000n);
  assert.equal(game.finish_update(), 10_016n);
});

test("both components trap on update lifecycle misuse", () => {
  for (const bytes of [spreadsheetWasm, platformerWasm]) {
    const exports = instantiate(bytes);
    assert.throws(() => exports.key_event(0x20, 1), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
