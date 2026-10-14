import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("gui/highway-chase.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function digestOutput(exports, size) {
  return createHash("sha256")
    .update(new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), size))
    .digest("hex");
}

test("highway chase declares KTX2 output and a 2 MiB memory cap", () => {
  const module = new WebAssembly.Module(wasm);
  const memory = WebAssembly.Module.exports(module).find((entry) => entry.kind === "memory");
  assert.ok(memory);
  const game = instantiate();
  assert.equal(game.key_event.length, 2);
  assert.equal(game.input_bytes_cap(), 0);
  assert.ok(game.memory.buffer.byteLength <= 2 * 1024 * 1024);
  const contentType = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(game.memory.buffer, game.output_content_type_ptr(), game.output_content_type_size()),
  );
  assert.equal(contentType.split(";")[0].trim(), "image/ktx2");
});

test("highway chase idles on the title, then drives in fixed steps", () => {
  const game = instantiate();
  const size = qipRenderSize(game, 0);
  assert.equal(size, 224 + 320 * 480 * 4);
  const title = digestOutput(game, size);

  game.begin_update_at(1n);
  assert.equal(game.finish_update(), 1n);

  game.begin_update_at(2n);
  assert.equal(game.key_event(0x20, 1), 1);
  assert.equal(game.finish_update(), 18n);
  assert.equal(digestOutput(game, size), title);

  game.begin_update_at(18n);
  assert.equal(game.key_event(0x20, 0), 1);
  assert.equal(game.key_event(0xff52, 1), 1);
  assert.equal(game.key_event(0xff52, 1), 0);
  assert.equal(game.finish_update(), 34n);

  let now = 34n;
  for (let i = 0; i < 60; i += 1) {
    game.begin_update_at(now);
    now += 16n;
    assert.equal(game.finish_update(), now);
  }
  assert.equal(digestOutput(game, size), title);
  assert.equal(qipRenderSize(game, 0), size);
  assert.notEqual(digestOutput(game, size), title);
});

test("highway chase pauses without wakes", () => {
  const game = instantiate();
  qipRenderSize(game, 0);
  game.begin_update_at(1n);
  game.key_event(0x20, 1);
  game.finish_update();

  game.begin_update_at(17n);
  assert.equal(game.key_event("p".codePointAt(0), 1), 1);
  assert.equal(game.finish_update(), 17n);

  game.begin_update_at(5000n);
  assert.equal(game.key_event("p".codePointAt(0), 1), 1);
  assert.equal(game.finish_update(), 5016n);
});
