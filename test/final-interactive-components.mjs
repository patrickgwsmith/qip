import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const specs = [
  { name: "gameboy-camera", width: 320, height: 220, event: (exports) => exports.key_event(0xff53, 1), wake: 17n },
  { name: "liars-dice", width: 920, height: 580, event: (exports) => exports.key_event("R".codePointAt(0), 1) },
  { name: "org_planner", width: 600, height: 450, event: (exports) => exports.pointer_event(1, 120, 20), wake: 101n },
  { name: "peon-gold", width: 320, height: 220, event: (exports) => exports.key_event(0xff53, 1), wake: 16n },
  { name: "vertical-shooter", width: 240, height: 240, event: (exports) => exports.pointer_event(1, 40, 100), wake: 16n },
  { name: "textedit", width: 375, height: 667, event: (exports) => exports.key_event("Q".codePointAt(0), 1), wake: 501n },
  { name: "macos9-desktop", width: 320, height: 220, event: (exports) => exports.pointer_event(1, 246, 36), wake: 1n },
  { name: "windows95-desktop", width: 320, height: 220, event: (exports) => exports.pointer_event(1, 12, 206), wake: 1n },
  { name: "macosx-leopard-desktop", width: 320, height: 220, event: (exports) => exports.pointer_event(0, 150, 190), wake: 1n },
];

const modules = Object.fromEntries(
  await Promise.all(specs.map(async ({ name }) => [name, await readFile(`components/interactive/${name}.wasm`)])),
);

function instantiate(name) {
  return new WebAssembly.Instance(new WebAssembly.Module(modules[name]), {}).exports;
}

function digest(exports, size) {
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
  const type = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, exports.output_content_type_ptr(), exports.output_content_type_size()),
  );
  assert.equal(type, "image/ktx2");
}

for (const { name, width, height, event, wake } of specs) {
  test(`${name} updates state separately from KTX2 presentation`, () => {
    const exports = instantiate(name);
    assertUpdateKTX2ABI(exports);
    const size = qipRenderSize(exports, 0);
    assert.equal(size, 224 + width * height * 4);
    const initial = digest(exports, size);

    exports.begin_update_at(1n);
    event(exports);
    const nextWake = exports.finish_update();
    if (wake === undefined) assert.ok(nextWake >= 1n);
    else assert.equal(nextWake, wake);
    assert.equal(digest(exports, size), initial);

    assert.equal(qipRenderSize(exports, 0), size);
    assert.notEqual(digest(exports, size), initial);
  });
}

test("Eventful components trap on lifecycle misuse", () => {
  for (const name of Object.keys(modules)) {
    const exports = instantiate(name);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
    qipRenderSize(exports, 0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => qipRenderSize(exports, 0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
