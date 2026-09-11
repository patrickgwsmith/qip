import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";

const complianceBytes = await readFile(
  new URL("../compliance/iso-4217-alpha-to-numeric.comply.wasm", import.meta.url),
);

registerGenericComplianceTests(test, complianceBytes, {
  curatedCount: 186,
  expectSeedVariation: false,
});

test("the exhaustive corpus preserves three-digit numeric codes", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);
  assert.equal(cases.filter((c) => c.expected !== null).length, 178);
  const mappings = new Map(cases.map((c) => [c.input.toString(), c.expected?.toString()]));
  assert.equal(mappings.get("USD"), "840");
  assert.equal(mappings.get("AUD"), "036");
  assert.equal(mappings.get("BHD"), "048");
  assert.equal(mappings.get("JPY"), "392");
  assert.equal(mappings.get("XXX"), "999");
  assert.equal(mappings.get("usd"), undefined);
});

test("duel: iso-4217-alpha-to-numeric.wasm satisfies all 186 cases", async () => {
  const implBytes = await readFile(
    new URL("../text/iso-4217-alpha-to-numeric.wasm", import.meta.url),
  );
  const { instance } = await WebAssembly.instantiate(implBytes);
  const impl = instance.exports;
  const readI32 = (name) => (typeof impl[name] === "function" ? impl[name]() : impl[name].value);
  const convert = (input) => {
    new Uint8Array(impl.memory.buffer, readI32("input_ptr"), input.length).set(input);
    try {
      const outputLen = qipRenderSize(impl, input.length);
      return Buffer.from(new Uint8Array(impl.memory.buffer, qipRenderedOutputPointer(impl), outputLen));
    } catch {
      return null;
    }
  };
  const { cases } = await runComplianceComponent(complianceBytes);
  const failures = cases
    .filter((c) => (c.expected === null ? convert(c.input) !== null : !convert(c.input)?.equals(c.expected)))
    .map((c) => c.ordinal);
  assert.deepEqual(failures, []);
});
