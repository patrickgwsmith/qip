import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("bytes-to-sha256 returns the raw 32-byte digest", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("bytes/bytes-to-sha256.wasm"),
    {},
  );
  assert.equal(instance.exports.output_content_type_ptr, undefined);
  assert.equal(instance.exports.output_content_type_size, undefined);

  const input = Buffer.from("abc");
  new Uint8Array(
    instance.exports.memory.buffer,
    instance.exports.input_ptr(),
    input.length,
  ).set(input);
  const outputSize = qipRenderSize(instance.exports, input.length);
  const output = Buffer.from(
    new Uint8Array(
      instance.exports.memory.buffer,
      qipRenderedOutputPointer(instance.exports),
      outputSize,
    ),
  );
  assert.equal(
    output.toString("hex"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});
