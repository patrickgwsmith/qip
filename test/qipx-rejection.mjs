import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { ContentRejection, newComponent, render, wasmMustComplyWithComponentContract } from "../npm/qipx/qipx.mjs";

test("qipx accepts and rejects fallible Content renders", async () => {
  const wasm = await readFile("text/utf8-must-be-valid.wasm");
  const { instance } = await WebAssembly.instantiate(wasm);
  const component = newComponent(instance, { label: "utf8 validator" });

  assert.equal(render(component, "hello").outputString, "hello");
  let rejected;
  assert.throws(
    () => render(component, new Uint8Array([0x41, 0xc3, 0x28])),
    (error) => {
      rejected = error;
      return error instanceof ContentRejection;
    },
  );
  assert.equal(rejected.label, "utf8 validator");
  assert.equal(rejected.inputOffset, 2);
  assert.equal(rejected.failureMode, 0);
  assert.match(rejected.message, /rejected input at input offset 2/);

  // Recoverable rejection leaves the same instance ready for another render.
  assert.equal(render(component, "again").outputString, "again");
});

test("qipx runs the inputless OKLCH Content generator", async () => {
  const wasm = await readFile("image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm");
  wasmMustComplyWithComponentContract(wasm, { label: "OKLCH solid color" });
  const { instance } = await WebAssembly.instantiate(wasm);
  const component = newComponent(instance, { label: "OKLCH solid color" });

  assert.equal(component.inputless, true);
  assert.equal(instance.exports.input_ptr, undefined);
  instance.exports.uniform_set_width(2);
  instance.exports.uniform_set_height(1);
  instance.exports.uniform_set_lightness(0.7);
  instance.exports.uniform_set_chroma(0.5);
  instance.exports.uniform_set_hue_degrees(30);
  instance.exports.uniform_set_alpha(0.25);
  const output = render(component, new Uint8Array()).outputBytes;
  assert.equal(output.byteLength, 256);

  const defaults = render(component, new Uint8Array()).outputBytes;
  assert.equal(defaults.byteLength, 224 + 1200 * 630 * 16);
  const defaultView = new DataView(defaults.buffer, defaults.byteOffset, defaults.byteLength);
  assert.equal(defaultView.getUint32(20, true), 1200);
  assert.equal(defaultView.getUint32(24, true), 630);
  const defaultRed = defaultView.getFloat32(224, true);
  assert.ok(Math.abs(defaultRed - 0.125) < 0.001);
  assert.ok(Math.abs(defaultRed - defaultView.getFloat32(228, true)) < 0.0002);
  assert.ok(Math.abs(defaultRed - defaultView.getFloat32(232, true)) < 0.0002);
  assert.equal(defaultView.getFloat32(236, true), 1);

  instance.exports.uniform_set_width(1);
  instance.exports.uniform_set_height(1);
  instance.exports.uniform_set_chroma(0.2);
  const resetHue = render(component, new Uint8Array()).outputBytes;

  const { instance: freshInstance } = await WebAssembly.instantiate(wasm);
  const freshComponent = newComponent(freshInstance, { label: "fresh OKLCH solid color" });
  freshInstance.exports.uniform_set_width(1);
  freshInstance.exports.uniform_set_height(1);
  freshInstance.exports.uniform_set_chroma(0.2);
  const freshHue = render(freshComponent, new Uint8Array()).outputBytes;
  assert.deepEqual(resetHue, freshHue);

  assert.throws(
    () => render(component, "x"),
    /inputless generator and cannot receive input bytes/,
  );
});

test("qipx Compliance supports must_reject", () => {
  const run = spawnSync(process.execPath, [
    "npm/qipx/cli.mjs",
    "comply",
    "text/utf8-must-be-valid.wasm",
    "--with",
    "compliance/reject-invalid-utf8.wasm",
  ], { encoding: "utf8" });

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /10 cases/);
  assert.match(run.stdout, /pass=2 fail=0 total=2/);
});
