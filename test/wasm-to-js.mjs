import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const decoder = new TextDecoder("utf-8", { fatal: true });
const translatorBytes = await readFile(
  new URL("../application/wasm/wasm-to-js.wasm", import.meta.url),
);

async function translate(componentPath) {
  const componentBytes = await readFile(new URL(componentPath, import.meta.url));
  const translator = new ContentComponentHost(translatorBytes, { label: "wasm-to-js" });
  const translated = translator.run(componentBytes);
  assert.equal(translated.status, "accepted");

  const source = decoder.decode(translated.output);
  const sourceURL = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`;
  return { module: await import(sourceURL), source };
}

test("generated JavaScript runs an infallible component", async () => {
  const { module, source } = await translate("../text/hello.wasm");

  assert.equal(module.default("Node"), "Hello, Node");
  assert.deepEqual(module.input, { encoding: "utf-8" });
  assert.deepEqual(module.output, { encoding: "utf-8" });
  assert.equal(module.default.input, module.input);
  assert.equal(module.default.output, module.output);
  assert.doesNotMatch(source, /\.output_ptr\s*\(/);
  assert.doesNotMatch(source, /\.commit\s*\(/);
});

test("generated JavaScript reports recoverable rejection detail", async () => {
  const { module } = await translate("../text/html/html-id-validator.wasm");

  assert.equal(module.default("main-content"), "main-content");
  assert.throws(
    () => module.default("main content"),
    (error) => {
      assert.equal(error.message, "component rejected input");
      assert.equal(error.failureDetail, 4);
      assert.equal(error.failureModesPerInputOffset, 1);
      assert.equal(error.inputOffset, 4);
      assert.equal(error.failureMode, 0);
      return true;
    },
  );
});

test("generated JavaScript reads an immutable interior input slice", async () => {
  const { module } = await translate("../text/css/css-class-validator.wasm");

  assert.equal(module.default(" \tbutton-primary \n"), "button-primary");
});

test("generated JavaScript runs a byte-to-UTF-8 guard", async () => {
  const { module } = await translate("../text/utf8-must-be-valid.wasm");
  const valid = new TextEncoder().encode("Café");

  assert.equal(module.default(valid), "Café");
  assert.deepEqual(module.input, { encoding: "bytes" });
  assert.deepEqual(module.output, { encoding: "utf-8" });
  assert.throws(
    () => module.default(Uint8Array.of(0x41, 0xc3, 0x28)),
    (error) => {
      assert.equal(error.message, "component rejected input");
      assert.equal(error.failureDetail, 2);
      assert.equal(error.failureModesPerInputOffset, 1);
      assert.equal(error.inputOffset, 2);
      assert.equal(error.failureMode, 0);
      return true;
    },
  );
});
