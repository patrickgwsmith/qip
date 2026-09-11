import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
// Component-specific checks for the Unicode 17 lowercase Content Compliance
// component. Generic meta-contract checks come from the shared harness.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";

const wasmBytes = await readFile(
  new URL("../compliance/unicode-17-lowercase.comply.wasm", import.meta.url),
);

const CURATED_COUNT = 37; // 13 curated + 24 generated inputs from casegen

registerGenericComplianceTests(test, wasmBytes, { curatedCount: CURATED_COUNT });

test("curated cases carry the expected UCD 17 content including Final_Sigma", async () => {
  const { cases, predicates } = await runComplianceComponent(wasmBytes);
  assert.ok(cases.length >= 100, `expected curated + fuzz equality cases, got ${cases.length}`);
  assert.ok(predicates.length >= 20, `expected examination cases, got ${predicates.length}`);
  const sigma = cases.find((c) => c.input.toString().includes("ΟΔΥΣΣΕΥΣ"));
  assert.ok(sigma, "expected a Final_Sigma curated case");
  assert.ok(sigma.expected.toString().includes("οδυσσευς"), "final sigma should map to ς");
  assert.ok(predicates.every((p) => p.ok));
});

test("duel: text/unicode-17-lowercase.wasm is fully compliant", async () => {
  const implBytes = await readFile(
    new URL("../text/unicode-17-lowercase.wasm", import.meta.url),
  );
  const { instance } = await WebAssembly.instantiate(implBytes);
  const impl = instance.exports;
  const readI32 = (name) => (typeof impl[name] === "function" ? impl[name]() : impl[name].value);
  const wasmLower = (input) => {
    new Uint8Array(impl.memory.buffer, readI32("input_ptr"), input.length).set(input);
    const outLen = qipRenderSize(impl, input.length);
    return Buffer.from(new Uint8Array(impl.memory.buffer, qipRenderedOutputPointer(impl), outLen));
  };

  const { cases, predicates } = await runComplianceComponent(wasmBytes, { impl: wasmLower });
  const failures = cases.filter((c) => !wasmLower(c.input).equals(c.expected)).map((c) => c.ordinal);
  assert.deepEqual(failures, [], "equality cases diverged");
  assert.ok(predicates.every((p) => p.ok), "property cases failed");
  console.log(`wasm impl duel: ${cases.length} equality + ${predicates.length} examination cases, fully compliant`);
});

test("duel: JavaScript toLowerCase vs the UCD 17 corpus", async () => {
  const lossy = new TextDecoder("utf-8");
  const jsLower = (input) => Buffer.from(lossy.decode(input).toLowerCase(), "utf8");
  const { cases, predicates } = await runComplianceComponent(wasmBytes, { impl: jsLower });

  const strict = new TextDecoder("utf-8", { fatal: true });
  const divergences = [];
  let dueled = 0;
  for (const c of cases) {
    try {
      strict.decode(c.input);
    } catch {
      continue;
    }
    dueled++;
    if (!jsLower(c.input).equals(c.expected)) {
      divergences.push(c.ordinal);
    }
  }
  assert.ok(dueled >= 30, `expected to duel the valid-UTF-8 cases, dueled ${dueled}`);
  assert.ok(predicates.every((p) => p.ok), "JS toLowerCase failed a property check");
  console.log(
    `toLowerCase duel: ${dueled} equality cases (${divergences.length} divergences at:`,
    `${divergences.join(", ") || "none"}), ${predicates.length} examination cases all passing`,
  );
});
