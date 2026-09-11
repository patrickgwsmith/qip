import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

async function instantiate() {
  const wasmBytes = await readFile(new URL("../text/unicode-17-lowercase.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  return instance.exports;
}

function renderBytes(exports, bytes) {
  const inputPtr = readI32Export(exports, "input_ptr");
  const inputCap = readI32Export(exports, "input_utf8_cap");
  assert.ok(bytes.length <= inputCap);
  new Uint8Array(exports.memory.buffer, inputPtr, bytes.length).set(bytes);
  const result = decodeRenderResult(exports.render(bytes.length));
  assert.equal(result.failed, false);
  return Buffer.from(new Uint8Array(exports.memory.buffer, result.outputPointer, result.value));
}

test("lowercase matches the UCD 17 fixtures byte for byte", async () => {
  const exports = await instantiate();
  const fixtures = JSON.parse(
    await readFile(new URL("./fixtures/unicode-17-lowercase.json", import.meta.url), "utf8"),
  );
  assert.ok(fixtures.length > 0);
  for (const fixture of fixtures) {
    const input = Buffer.from(fixture.input_b64, "base64");
    const want = Buffer.from(fixture.want_b64, "base64");
    const got = renderBytes(exports, input);
    assert.deepEqual(got, want, `fixture ${fixture.name}`);
  }
});

test("final sigma depends on following context across renders", async () => {
  const exports = await instantiate();
  assert.equal(renderBytes(exports, Buffer.from("ΟΔΥΣΣΕΥΣ")).toString(), "οδυσσευς");
  assert.equal(renderBytes(exports, Buffer.from("ΣΟΦΟΣ ΣΟΦΟΣΒ")).toString(), "σοφος σοφοσβ");
  assert.equal(renderBytes(exports, Buffer.from("Σ")).toString(), "σ");
});

test("repeated renders on one instance leave no stale output", async () => {
  const exports = await instantiate();
  renderBytes(exports, Buffer.from("ΑΣ ".repeat(200)));
  assert.equal(renderBytes(exports, Buffer.from("QIP")).toString(), "qip");
});

test("malformed UTF-8 violates the input precondition", async () => {
  for (const bytes of [Buffer.from([0xff]), Buffer.from([0xc3]), Buffer.from([0x80])]) {
    const exports = await instantiate();
    assert.throws(() => renderBytes(exports, bytes), WebAssembly.RuntimeError);
    // A host discards this instance instead of testing another render on it.
  }
});
