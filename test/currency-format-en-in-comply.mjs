import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";

const complianceBytes = await readFile(
  new URL("../compliance/currency-format-en-in.comply.wasm", import.meta.url),
);
const currencies = JSON.parse(
  await readFile(new URL("./fixtures/currency-format-en-us.json", import.meta.url), "utf8"),
);

registerGenericComplianceTests(test, complianceBytes, { curatedCount: 25 });

test("compliance drives the implementation uniform through the qip bridge", async () => {
  const module = await WebAssembly.compile(complianceBytes);
  const exports = WebAssembly.Module.exports(module).map(({ name }) => name);
  const imports = WebAssembly.Module.imports(module).map(({ module: namespace, name }) => `${namespace}.${name}`);
  assert.ok(!exports.includes("uniform_set_currency"));
  assert.ok(imports.includes("qip.set_uniform_u32"));
});

test("corpus contains active country currencies plus XDR and excludes other special-purpose codes", () => {
  const alpha = new Set(currencies.map((currency) => currency.alpha));
  assert.equal(currencies.length, 156);
  for (const code of ["USD", "EUR", "XAF", "XCD", "XCG", "XOF", "XPF", "XDR", "ZWG"]) {
    assert.ok(alpha.has(code), `expected active country currency ${code}`);
  }
  for (const code of ["XAU", "XTS", "XXX", "BOV", "CLF", "USN", "UYI", "XAD", "UYW"]) {
    assert.ok(!alpha.has(code), `special-purpose code ${code} should be excluded`);
  }
});

test("compliance oracle requires Indian secondary grouping", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);
  const groupingCase = cases.find(
    (c) => c.uniforms.currency === 840 && c.input.toString() === "1234567.89",
  );
  assert.equal(groupingCase?.expected.toString(), "$12,34,567.89");
});

test("duel: Intl.NumberFormat en-IN agrees for every supported ISO 4217 code", async () => {
  const byNumeric = new Map(currencies.map((currency) => [currency.numeric, currency]));
  const { cases } = await runComplianceComponent(complianceBytes);
  assert.equal(cases.length, currencies.length * 57);
  const failures = cases
    .filter((c) => c.expected !== null)
    .filter((c) => {
      const currency = byNumeric.get(c.uniforms.currency);
      assert.ok(currency, `unknown compliance currency ${c.uniforms.currency}`);
      const intl = new Intl.NumberFormat("en-IN", { style: "currency", currency: currency.alpha });
      return Buffer.from(intl.format(c.input.toString()), "utf8").compare(c.expected) !== 0;
    })
    .map((c) => c.ordinal);
  assert.deepEqual(failures, [], "currency output diverged from Intl");
});

test("duel: currency-format-en-in.wasm uses Indian grouping for every supported currency", async () => {
  const implBytes = await readFile(new URL("../text/currency-format-en-in.wasm", import.meta.url));

  const implModule = await WebAssembly.compile(implBytes);
  let impl = new WebAssembly.Instance(implModule).exports;
  const readI32 = (name) => (typeof impl[name] === "function" ? impl[name]() : impl[name].value);
  const format = (input) => {
    new Uint8Array(impl.memory.buffer, readI32("input_ptr"), input.length).set(input);
    try {
      const outputLen = qipRenderSize(impl, input.length);
      return Buffer.from(new Uint8Array(impl.memory.buffer, qipRenderedOutputPointer(impl), outputLen));
    } catch {
      impl = new WebAssembly.Instance(implModule).exports;
      return null;
    }
  };
  const configured = [];
  const { cases } = await runComplianceComponent(complianceBytes, {
    setUniform(name, value) {
      assert.equal(name, "currency");
      configured.push(value);
      return impl.uniform_set_currency(value);
    },
  });
  assert.deepEqual(configured, cases.map((c) => c.uniforms.currency));
  const failures = cases
    .filter((c) => {
      impl.uniform_set_currency(c.uniforms.currency);
      return c.expected === null ? format(c.input) !== null : !format(c.input)?.equals(c.expected);
    })
    .map((c) => c.ordinal);
  assert.deepEqual(failures, [], "currency implementation diverged");
});

test("currency formatter stays within its compact artifact and memory budgets", async () => {
  const implBytes = await readFile(new URL("../text/currency-format-en-in.wasm", import.meta.url));
  assert.ok(implBytes.byteLength <= 2300, `expected at most 2300 bytes, got ${implBytes.byteLength}`);

  const { instance } = await WebAssembly.instantiate(implBytes);
  assert.equal(instance.exports.memory.buffer.byteLength, 64 * 1024);
});

test("unsupported numeric currency codes trap at render", async () => {
  const implBytes = await readFile(new URL("../text/currency-format-en-in.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(implBytes);
  instance.exports.uniform_set_currency(0);
  assert.throws(() => instance.exports.render(0));
});
