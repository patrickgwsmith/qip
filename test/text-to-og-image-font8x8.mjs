import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const components = [
  "text/text-to-og-image-font8x8.wasm",
  "text/text-to-og-image-dejavu-sans-mono.wasm",
];

function hasPixel(bytes, b, g, r, a) {
  for (let i = 54; i + 3 < bytes.length; i += 4) {
    if (
      bytes[i] === b &&
      bytes[i + 1] === g &&
      bytes[i + 2] === r &&
      bytes[i + 3] === a
    ) {
      return true;
    }
  }
  return false;
}

for (const component of components) {
  test(`${component} resets colors to black text on white`, async () => {
    const { instance } = await WebAssembly.instantiate(await readFile(component));
    const e = instance.exports;
    const memory = new Uint8Array(e.memory.buffer);
    memory[e.input_ptr()] = "A".charCodeAt(0);

    e.uniform_set_text_color_rgba(0xff0000ff);
    e.uniform_set_background_color_rgba(0x0000ffff);
    const configuredSize = qipRenderSize(e, 1);
    const configured = memory.slice(qipRenderedOutputPointer(e), qipRenderedOutputPointer(e) + configuredSize);
    assert.equal(hasPixel(configured, 0, 0, 255, 255), true);
    assert.equal(hasPixel(configured, 255, 0, 0, 255), true);

    const defaultSize = qipRenderSize(e, 1);
    const defaults = memory.slice(qipRenderedOutputPointer(e), qipRenderedOutputPointer(e) + defaultSize);
    assert.equal(hasPixel(defaults, 0, 0, 0, 255), true);
    assert.equal(hasPixel(defaults, 255, 255, 255, 255), true);
  });

  test(`${component} traps above its advertised input capacity`, async () => {
    const { instance } = await WebAssembly.instantiate(await readFile(component));
    const e = instance.exports;
    assert.throws(() => qipRenderSize(e, e.input_utf8_cap() + 1), WebAssembly.RuntimeError);
  });
}
