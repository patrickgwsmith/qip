import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";

const complianceBytes = await readFile(
  new URL("../compliance/currency-format-usd-en-us.comply.wasm", import.meta.url),
);

const CURATED_COUNT = 24;
registerGenericComplianceTests(test, complianceBytes, { curatedCount: CURATED_COUNT });

test("curated cases define grouping, cents, rounding, negative zero, and rejection", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);
  const outputs = new Map(cases.map((c) => [c.input.toString(), c.expected?.toString()]));
  assert.equal(outputs.get("1234.5"), "$1,234.50");
  assert.equal(outputs.get("-9876543.21"), "-$9,876,543.21");
  assert.equal(outputs.get("0.005"), "$0.01");
  assert.equal(outputs.get("999.995"), "$1,000.00");
  assert.equal(outputs.get("-0"), "-$0.00");
  assert.equal(outputs.get("1e3"), undefined);
});

test("duel: Intl.NumberFormat agrees for the supported decimal subset", async () => {
  const intl = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
  const format = (input) => Buffer.from(intl.format(input.toString()), "utf8");
  const { cases } = await runComplianceComponent(complianceBytes, { impl: format });
  const valid = cases.filter((c) => c.expected !== null);
  const failures = valid.filter((c) => !format(c.input).equals(c.expected)).map((c) => c.ordinal);
  assert.deepEqual(failures, [], "Intl currency output diverged on supported inputs");
});

test("duel: text/currency-format-usd-en-us.wasm is fully compliant", async () => {
  const implBytes = await readFile(
    new URL("../text/currency-format-usd-en-us.wasm", import.meta.url),
  );
  const implModule = await WebAssembly.compile(implBytes);
  let impl = new WebAssembly.Instance(implModule).exports;
  const readI32 = (name) => (typeof impl[name] === "function" ? impl[name]() : impl[name].value);
  const wasmFormat = (input) => {
    new Uint8Array(impl.memory.buffer, readI32("input_ptr"), input.length).set(input);
    try {
      const outLen = qipRenderSize(impl, input.length);
      return Buffer.from(new Uint8Array(impl.memory.buffer, qipRenderedOutputPointer(impl), outLen));
    } catch {
      impl = new WebAssembly.Instance(implModule).exports;
      return null;
    }
  };

  const { cases } = await runComplianceComponent(complianceBytes, { impl: wasmFormat });
  const failures = cases
    .filter((c) => (c.expected === null ? wasmFormat(c.input) !== null : !wasmFormat(c.input)?.equals(c.expected)))
    .map((c) => c.ordinal);
  assert.deepEqual(failures, [], "currency-format implementation diverged");
});
