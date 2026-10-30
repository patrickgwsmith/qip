import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function runSRI(path, input) {
  const { instance } = await WebAssembly.instantiate(await readFile(path), {});
  assert.equal(typeof instance.exports.output_utf8_cap, "function");
  new Uint8Array(
    instance.exports.memory.buffer,
    instance.exports.input_ptr(),
    input.length,
  ).set(input);
  const outputSize = qipRenderSize(instance.exports, input.length);
  return Buffer.from(
    new Uint8Array(
      instance.exports.memory.buffer,
      qipRenderedOutputPointer(instance.exports),
      outputSize,
    ),
  ).toString("utf8");
}

for (const algorithm of ["sha256", "sha384", "sha512"]) {
  test(`bytes-to-sri-${algorithm} matches node:crypto`, async () => {
    const inputs = [
      Buffer.alloc(0),
      Buffer.from("abc"),
      Buffer.from("alert('Hello, world.');"),
      randomBytes(1 << 20),
    ];
    for (const input of inputs) {
      const expected = `${algorithm}-${createHash(algorithm).update(input).digest("base64")}`;
      assert.equal(await runSRI(`bytes/bytes-to-sri-${algorithm}.wasm`, input), expected);
    }
  });
}
