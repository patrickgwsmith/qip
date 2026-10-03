import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createRecipe, newComponent, render } from "../npm/qipx/qipx.mjs";

const sigv4 = "multipart/form-data/aws-sigv4-sign.wasm";
const oklch = "image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm";
// AWS SigV4 test suite get-vanilla.
const getVanillaForm = [
  "-F", "method=GET",
  "-F", "url=https://example.amazonaws.com/",
  "-F", "region=us-east-1",
  "-F", "service=service",
  "-F", "access_key_id=AKIDEXAMPLE",
  "-F", "secret_access_key=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
];

function qipx(args) {
  return spawnSync(process.execPath, ["npm/qipx/cli.mjs", "run", ...args], { maxBuffer: 4 * 1024 * 1024 });
}

test("qipx passes i64 uniforms to their setters as BigInt", () => {
  const result = qipx([...getVanillaForm, sigv4, "-u", "timestamp=1440938160"]);
  assert.equal(result.status, 0, result.stderr.toString());
  assert.match(result.stdout.toString(), /Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31/);
});

test("qipx rejects i64 uniform values outside the signed 64-bit integer range", () => {
  for (const value of ["9223372036854775808", "-9223372036854775809", "1.5", "1e3", "abc"]) {
    const result = qipx([...getVanillaForm, sigv4, "-u", `timestamp=${value}`]);
    assert.notEqual(result.status, 0, value);
    assert.match(result.stderr.toString(), /is not an i64 integer/, value);
  }
});

test("newComponent passes each uniform as its setter's type", async () => {
  const wasm = await readFile(oklch);
  const { instance } = await WebAssembly.instantiate(wasm);
  const component = newComponent(wasm, instance, { label: "OKLCH solid color" });
  // width and height are i32 setters; lightness and alpha are f32 setters.
  const recipe = createRecipe([{
    component,
    uniforms: [["width", "2"], ["height", "1"], ["lightness", "0.7"], ["alpha", "0.25"]],
  }]);
  assert.ok(render(recipe, new Uint8Array()).outputBytes.byteLength > 0);
});

test("newComponent requires the module bytes the instance was created from", async () => {
  const wasm = await readFile(oklch);
  const { instance } = await WebAssembly.instantiate(wasm);
  assert.throws(() => newComponent(instance, { label: "OKLCH solid color" }), /requires the module bytes/);
  assert.throws(() => newComponent(wasm, undefined, { label: "OKLCH solid color" }), /requires a WebAssembly.Instance/);
  const otherWasm = await readFile("text/utf8-must-be-valid.wasm");
  assert.throws(
    () => newComponent(otherWasm, instance, { label: "OKLCH solid color" }),
    /instance exports uniform_set_\w+, which the module bytes do not/,
  );
});
