import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  renderSize,
  renderedOutputPointer,
} from "./lib/content-component-host.mjs";

const wasm = await readFile("components/interactive/calendar-gregorian.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm)).exports;
}

function renderText(exports) {
  const size = renderSize(exports, 0);
  return new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), size),
  );
}

test("calendar TUI is an inputless UTF-8 Time and Events component", () => {
  const exports = instantiate();
  assert.equal(exports.input_ptr, undefined);
  assert.equal(exports.input_utf8_cap, undefined);
  assert.equal(exports.input_bytes_cap, undefined);
  assert.equal(exports.output_utf8_cap(), 1024);
  assert.equal(exports.begin_update_at.length, 1);
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.finish_update.length, 0);

  const initial = renderText(exports);
  assert.match(initial, /January 2024/);
  assert.match(initial, /Up: previous month    Down: next month/);
});

test("calendar TUI changes months only after a finished update is rendered", () => {
  const exports = instantiate();
  const initial = renderText(exports);

  exports.begin_update_at(1n);
  assert.equal(exports.key_event(0xff52, 1), 1);
  assert.equal(exports.key_event(0xff52, 0), 0);
  assert.equal(exports.finish_update(), 1n);

  const beforeRender = new TextDecoder().decode(
    new Uint8Array(
      exports.memory.buffer,
      renderedOutputPointer(exports),
      new TextEncoder().encode(initial).byteLength,
    ),
  );
  assert.equal(beforeRender, initial);
  assert.match(renderText(exports), /December 2023/);

  exports.begin_update_at(2n);
  assert.equal(exports.key_event(0xff54, 1), 1);
  assert.equal(exports.finish_update(), 2n);
  assert.match(renderText(exports), /January 2024/);
});

test("calendar TUI traps on invalid lifecycle order", () => {
  const exports = instantiate();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  renderText(exports);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => exports.render(0), WebAssembly.RuntimeError);
});
