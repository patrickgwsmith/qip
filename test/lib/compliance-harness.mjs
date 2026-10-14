// Shared host harness for Content Compliance oracles.
//
// This is the JS reference for the future `qip comply` bridge. It provides
// the qip.* imports, enforces the wire protocol on every run (sequential u64
// ordinals, must_render_into open/emit/finish discipline — violations throw at
// the exact offending call), and registers the *generic* meta-contract tests
// every Compliance oracle must satisfy: deterministic declarations and
// seed behavior. Per-component harnesses should only add component-specific
// checks (curated-case spot checks, duels against real implementations).
// Eventually the generic layer belongs in `qip comply` base validation, the
// way static contract checks already work for render components.
import assert from "node:assert/strict";

import { uniformSetterNames } from "./content-component-host.mjs";

// Drives the component with a given impl function (bytes -> bytes, or null
// to echo input as a null impl). Records equality cases (the extractable
// corpus) and must_render_into verdicts separately.
export async function runComplianceComponent(wasmBytes, { seed, impl, setUniform } = {}) {
  const cases = [];
  const predicates = [];
  let memory;
  const view = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const bytes = (ptr, len) => Buffer.from(view(ptr, len));
  const applyImpl = (input) => (impl ? impl(input) : input);
  let hostOrdinal = 0n;
  let openRenderInto = null;
  let openRenderIntoErrors = 0;
  const activeUniforms = {};
  const uniformNameDecoder = new TextDecoder("utf-8", { fatal: true });
  const uniformSnapshot = () => Object.freeze({ ...activeUniforms });
  const checkOrdinal = (declared) => {
    assert.equal(declared, hostOrdinal, "component and host disagree on case ordinal");
    hostOrdinal++;
  };
  const finishRenderInto = (declaredOrdinal, errorCount) => {
    assert.equal(openRenderInto, declaredOrdinal, "finish must close the open must_render_into case");
    assert.equal(errorCount >>> 0, openRenderIntoErrors, "finish error count must match emitted errors");
    openRenderInto = null;
    openRenderIntoErrors = 0;
    checkOrdinal(declaredOrdinal);
    predicates.push({ ordinal: Number(declaredOrdinal), ok: errorCount === 0 });
    return 1;
  };
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    qip: {
      must_render_exactly(declaredOrdinal, inputPtr, inputLen, expectedPtr, expectedLen) {
        assert.equal(openRenderInto, null, "requirement declared inside an open must_render_into case");
        checkOrdinal(declaredOrdinal);
        cases.push({
          ordinal: Number(declaredOrdinal),
          input: bytes(inputPtr, inputLen),
          expected: bytes(expectedPtr, expectedLen),
          uniforms: uniformSnapshot(),
        });
        return 1;
      },
      must_trap(declaredOrdinal, inputPtr, inputLen) {
        assert.equal(openRenderInto, null, "requirement declared inside an open must_render_into case");
        checkOrdinal(declaredOrdinal);
        cases.push({
          ordinal: Number(declaredOrdinal),
          input: bytes(inputPtr, inputLen),
          expected: null, // must trap
          uniforms: uniformSnapshot(),
        });
        return 1;
      },
      must_render_into(declaredOrdinal, inputPtr, inputLen, outPtr, outCap) {
        assert.equal(openRenderInto, null, "must_render_into cannot open while an must_render_into case is open");
        assert.equal(declaredOrdinal, hostOrdinal, "must_render_into should open the pending case");
        openRenderInto = declaredOrdinal;
        openRenderIntoErrors = 0;
        const output = applyImpl(bytes(inputPtr, inputLen));
        if (output === null) return -1;
        if (output.length > outCap) return -2;
        view(outPtr, output.length).set(output);
        return output.length;
      },
      must_render_into_emit_error(declaredOrdinal) {
        assert.equal(openRenderInto, declaredOrdinal, "error must match the open must_render_into case");
        openRenderIntoErrors++;
        return 1;
      },
      must_render_into_finish(declaredOrdinal, errorCount) {
        return finishRenderInto(declaredOrdinal, errorCount >>> 0);
      },
      set_uniform_u32(namePtr, nameLen, value) {
        assert.equal(openRenderInto, null, "uniform cannot change inside a must_render_into case");
        const name = uniformNameDecoder.decode(view(namePtr, nameLen));
        assert.match(name, /^[a-z][a-z0-9_]{0,62}$/, "uniform name must be a lowercase snake identifier");
        assert.equal(name.endsWith("_"), false, "uniform name must not end with underscore");
        assert.equal(name.includes("__"), false, "uniform name must not contain double underscore");
        const unsignedValue = value >>> 0;
        const applied = setUniform ? setUniform(name, unsignedValue) : unsignedValue;
        const unsignedApplied = applied >>> 0;
        activeUniforms[name] = unsignedApplied;
        return unsignedApplied;
      },
    },
  });
  memory = instance.exports.memory;
  if (seed !== undefined) {
    instance.exports[uniformSetterNames(Object.keys(instance.exports)).get("seed")](seed);
  }
  const declared = instance.exports.comply();
  assert.equal(openRenderInto, null, "comply() returned with an unclosed must_render_into case");
  return { cases, predicates, declared };
}

function assertSameDeclarations(a, b) {
  assert.equal(a.cases.length, b.cases.length);
  assert.equal(a.predicates.length, b.predicates.length);
  for (let i = 0; i < a.cases.length; i++) {
    assert.deepEqual(a.cases[i].input, b.cases[i].input, `case ${a.cases[i].ordinal} input`);
    assert.deepEqual(a.cases[i].expected, b.cases[i].expected, `case ${a.cases[i].ordinal} expected`);
    assert.deepEqual(a.cases[i].uniforms, b.cases[i].uniforms, `case ${a.cases[i].ordinal} uniforms`);
  }
}

// The meta-contract every Content Compliance oracle must satisfy.
// `curatedCount` = declarations that must not vary with the seed;
// set `expectSeedVariation: false` for components with no fuzz phase.
export function registerGenericComplianceTests(
  test,
  wasmBytes,
  { seedVariant = 42, curatedCount = 0, expectSeedVariation = true } = {},
) {
  test("generic: declares at least one case and counts them correctly", async () => {
    const { cases, predicates, declared } = await runComplianceComponent(wasmBytes);
    assert.ok(cases.length + predicates.length > 0);
    assert.equal(declared, cases.length + predicates.length);
  });

  test("generic: declarations are deterministic — same component, same bytes, every run", async () => {
    assertSameDeclarations(
      await runComplianceComponent(wasmBytes),
      await runComplianceComponent(wasmBytes),
    );
  });

  test("generic: a reseeded corpus is itself deterministic", async () => {
    assertSameDeclarations(
      await runComplianceComponent(wasmBytes, { seed: seedVariant }),
      await runComplianceComponent(wasmBytes, { seed: seedVariant }),
    );
  });

  if (expectSeedVariation) {
    test("generic: seed varies the fuzz corpus but not the curated cases", async () => {
      const base = await runComplianceComponent(wasmBytes);
      const reseeded = await runComplianceComponent(wasmBytes, { seed: seedVariant });
      assert.equal(base.cases.length, reseeded.cases.length);
      for (let i = 0; i < curatedCount; i++) {
        assert.deepEqual(reseeded.cases[i].input, base.cases[i].input, `curated ${i}`);
      }
      const fuzzDiffers = base.cases.some(
        (c, i) => i >= curatedCount && !c.input.equals(reseeded.cases[i].input),
      );
      assert.ok(fuzzDiffers, "reseeding should produce a different fuzz corpus");
    });
  }
}
