import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const calculatorWasm = await readFile("gui/calculator.wasm");
const snakeWasm = await readFile("gui/snake.wasm");

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
  for (const legacy of ["tick", "begin_at", "commit", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
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

test("calculator applies an ordered app update, then presents it separately", () => {
  const calculator = instantiate(calculatorWasm);
  assertTransactionalInteractiveABI(calculator);
  const size = qipRenderSize(calculator, 0);
  assert.equal(size, 224 + 220 * 220 * 4);
  const initialDigest = digest(output(calculator, size));

  calculator.begin_update_at(1n);
  assert.equal(calculator.finish_update(), 1n);

  calculator.begin_update_at(2n);
  for (const key of ["2", "+", "3", "="]) {
    assert.equal(calculator.key_event(key.codePointAt(0), 1), 1);
  }
  assert.equal(calculator.finish_update(), 2n);
  assert.equal(digest(output(calculator, size)), initialDigest);

  assert.equal(qipRenderSize(calculator, 0), size);
  const resultDigest = digest(output(calculator, size));
  assert.notEqual(resultDigest, initialDigest);
  assert.equal(qipRenderSize(calculator, 0), size);
  assert.equal(digest(output(calculator, size)), resultDigest);

  calculator.begin_update_at(3n);
  assert.equal(calculator.key_event("C".codePointAt(0), 1), 1);
  assert.equal(calculator.finish_update(), 3n);
  assert.equal(digest(output(calculator, size)), resultDigest);
});

test("snake uses fixed-step updates and keeps presentation separate", () => {
  const snake = instantiate(snakeWasm);
  assertTransactionalInteractiveABI(snake);
  const size = qipRenderSize(snake, 0);
  assert.equal(size, 224 + 400 * 280 * 4);
  const initialDigest = digest(output(snake, size));

  snake.begin_update_at(1n);
  assert.equal(snake.finish_update(), 120n);

  snake.begin_update_at(120n);
  assert.equal(snake.key_event(0xff52, 1), 1);
  assert.equal(snake.finish_update(), 240n);
  assert.equal(digest(output(snake, size)), initialDigest);

  assert.equal(qipRenderSize(snake, 0), size);
  const movedDigest = digest(output(snake, size));
  assert.notEqual(movedDigest, initialDigest);

  snake.begin_update_at(240n);
  assert.equal(snake.finish_update(), 360n);
  assert.equal(digest(output(snake, size)), movedDigest);

  snake.begin_update_at(360n);
  assert.equal(snake.key_event(0x20, 1), 1);
  assert.equal(snake.finish_update(), 360n);
  assert.equal(digest(output(snake, size)), movedDigest);
});

test("calculator and snake trap on host lifecycle violations", () => {
  for (const bytes of [calculatorWasm, snakeWasm]) {
    const exports = instantiate(bytes);
    assert.throws(() => exports.key_event(0x20, 1), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    assert.ok(exports.finish_update() >= 1n);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
