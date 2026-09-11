import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
// Component-specific checks for the Unicode 17 uppercase Content Compliance
// component. The generic meta-contract (determinism, seed behavior, ordinal
// and examination protocol discipline) is verified by the shared harness in
// test/lib/compliance-harness.mjs — per-component files only spot-check
// curated content and duel real implementations.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";

const wasmBytes = await readFile(
  new URL("../compliance/unicode-17-uppercase.comply.wasm", import.meta.url),
);

const CURATED_COUNT = 13;
const ORDINAL = { ascii: 1, sharpS: 2, ligatures: 3, greekAccents: 5, ypogegrammeni: 6 };

registerGenericComplianceTests(test, wasmBytes, { curatedCount: CURATED_COUNT });

test("curated cases carry the expected UCD 17 content", async () => {
  const { cases, predicates } = await runComplianceComponent(wasmBytes);
  assert.ok(cases.length >= 80, `expected curated + fuzz equality cases, got ${cases.length}`);
  assert.ok(predicates.length >= 20, `expected examination cases, got ${predicates.length}`);
  assert.equal(cases[ORDINAL.sharpS].input.toString(), "straße ß groß ẞ");
  assert.equal(cases[ORDINAL.sharpS].expected.toString(), "STRASSE SS GROSS ẞ");
  // Against the identity impl, idempotence and ASCII-preservation hold.
  assert.ok(predicates.every((p) => p.ok));
});

test("duel: JavaScript toUpperCase vs the UCD 17 corpus and properties", async () => {
  const lossy = new TextDecoder("utf-8");
  const jsUpper = (input) => Buffer.from(lossy.decode(input).toUpperCase(), "utf8");
  const { cases, predicates } = await runComplianceComponent(wasmBytes, { impl: jsUpper });

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
    if (!jsUpper(c.input).equals(c.expected)) {
      divergences.push(c.ordinal);
    }
  }
  assert.ok(dueled >= 20, `expected to duel the valid-UTF-8 cases, dueled ${dueled}`);
  // Node's ICU trails UCD 17, so Unicode 16/17 additions legitimately
  // diverge (Garay, U+A7CB..). The core curated ordinals must match.
  for (const [label, ordinal] of Object.entries(ORDINAL)) {
    assert.ok(!divergences.includes(ordinal), `curated case ${label} (#${ordinal}) diverged`);
  }
  // Properties hold for JS toUpperCase too: idempotent, ASCII-preserving.
  assert.ok(predicates.every((p) => p.ok), "JS toUpperCase failed a property check");
  console.log(
    `toUpperCase duel: ${dueled} equality cases (${divergences.length} divergences at:`,
    `${divergences.join(", ") || "none"}), ${predicates.length} examination cases all passing`,
  );
});

test("duel: text/unicode-17-uppercase.wasm is fully compliant", async () => {
  const implBytes = await readFile(
    new URL("../text/unicode-17-uppercase.wasm", import.meta.url),
  );
  const { instance } = await WebAssembly.instantiate(implBytes);
  const impl = instance.exports;
  const readI32 = (name) => (typeof impl[name] === "function" ? impl[name]() : impl[name].value);
  const wasmUpper = (input) => {
    new Uint8Array(impl.memory.buffer, readI32("input_ptr"), input.length).set(input);
    const outLen = qipRenderSize(impl, input.length);
    return Buffer.from(new Uint8Array(impl.memory.buffer, qipRenderedOutputPointer(impl), outLen));
  };

  const { cases, predicates } = await runComplianceComponent(wasmBytes, { impl: wasmUpper });
  const failures = cases.filter((c) => !wasmUpper(c.input).equals(c.expected)).map((c) => c.ordinal);
  assert.deepEqual(failures, [], "equality cases diverged");
  assert.ok(predicates.every((p) => p.ok), "property cases failed");
  console.log(`wasm impl duel: ${cases.length} equality + ${predicates.length} examination cases, fully compliant`);
});

test("malformed UTF-8 violates the component input precondition", async () => {
  const implBytes = await readFile(
    new URL("../text/unicode-17-uppercase.wasm", import.meta.url),
  );

  for (const input of [Buffer.from([0xff]), Buffer.from([0xc3]), Buffer.from([0x80])]) {
    const { instance } = await WebAssembly.instantiate(implBytes);
    const impl = instance.exports;
    const readI32 = (name) => (typeof impl[name] === "function" ? impl[name]() : impl[name].value);
    new Uint8Array(impl.memory.buffer, readI32("input_ptr"), input.length).set(input);
    assert.throws(() => impl.render(input.length), WebAssembly.RuntimeError);
    // A host creates another instance after each trap.
  }
});
