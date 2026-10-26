import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

globalThis.HTMLElement = class {};
globalThis.customElements = {
  get() {
    return true;
  },
  define() {},
};

vm.runInThisContext(
  readFileSync("site/_elements/qip-edit.js", "utf8") +
    "\nglobalThis.__qipEditReadModulePolicy = qipEditReadModulePolicy;" +
    "\nglobalThis.__qipEditValidateWasmModulePolicy = qipEditValidateWasmModulePolicy;",
  { filename: "site/_elements/qip-edit.js" },
);
const qipPlayPolicy = await import("../site/_elements/qip-wasm-policy.js");
globalThis.__qipPlayReadModulePolicy = qipPlayPolicy.readModulePolicy;
globalThis.__qipPlayValidateWasmModulePolicy = qipPlayPolicy.validateWasmModulePolicy;

const page = 65536;
const opcodeMemoryGrow = 0x40;
const fixedMemoryPolicy = { maxMemoryBytes: 0, rejectOpcodes: [opcodeMemoryGrow] };

function encodeU32(value) {
  const out = [];
  let v = value >>> 0;
  do {
    let b = v & 0x7f;
    v >>>= 7;
    if (v !== 0) b |= 0x80;
    out.push(b);
  } while (v !== 0);
  return out;
}

function section(id, payload) {
  return [id, ...encodeU32(payload.length), ...payload];
}

function buildModule({ ops, memory }) {
  const typeSection = section(1, [0x01, 0x60, 0x00, 0x00]);
  const functionSection = section(3, [0x01, 0x00]);
  const memorySection = memory
    ? section(5, [
        0x01,
        memory.hasMax ? 0x01 : 0x00,
        ...encodeU32(memory.min),
        ...(memory.hasMax ? encodeU32(memory.max) : []),
      ])
    : [];
  const body = [0x00, ...ops];
  const codeSection = section(10, [0x01, ...encodeU32(body.length), ...body]);
  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    ...typeSection,
    ...functionSection,
    ...memorySection,
    ...codeSection,
  ]);
}

function validateWithBoth(moduleBytes, policy) {
  __qipEditValidateWasmModulePolicy(moduleBytes.buffer, policy, "test.wasm");
  __qipPlayValidateWasmModulePolicy(moduleBytes.buffer, policy, "test.wasm");
}

function policyElement(attributes = {}) {
  return {
    getAttribute(name) {
      return Object.hasOwn(attributes, name) ? attributes[name] : null;
    },
    hasAttribute(name) {
      return Object.hasOwn(attributes, name);
    },
  };
}

function readPolicyWithBoth(attributes) {
  const element = policyElement(attributes);
  return [
    __qipEditReadModulePolicy(element),
    __qipPlayReadModulePolicy(element),
  ];
}

test("browser wasm policy rejects memory.grow by default", () => {
  for (const policy of readPolicyWithBoth()) {
    assert.deepEqual(policy, fixedMemoryPolicy);
  }
});

test("browser wasm policy rejects memory.grow under a memory cap", () => {
  for (const policy of readPolicyWithBoth({ "max-memory": String(2 * page) })) {
    assert.deepEqual(policy, { maxMemoryBytes: 2 * page, rejectOpcodes: [opcodeMemoryGrow] });
  }
});

test("browser wasm policy refuses the removed allow-memory-grow attribute", () => {
  for (const attributes of [{ "allow-memory-grow": "" }, { "allow-memory-grow": "", "max-memory": String(2 * page) }]) {
    assert.throws(() => __qipEditReadModulePolicy(policyElement(attributes)), /allow-memory-grow has been removed/);
    assert.throws(() => __qipPlayReadModulePolicy(policyElement(attributes)), /allow-memory-grow has been removed/);
  }
});

test("browser wasm policy rejects memory.grow", () => {
  const moduleBytes = buildModule({
    memory: { min: 1, hasMax: true, max: 1 },
    ops: [
      0x41, 0x01, // i32.const 1
      0x40, 0x00, // memory.grow 0
      0x1a, // drop
      0x0b, // end
    ],
  });

  assert.throws(
    () => validateWithBoth(moduleBytes, fixedMemoryPolicy),
    /violates fixed-memory policy/,
  );
});

test("browser wasm policy enforces declared memory maximum", () => {
  const noMax = buildModule({
    memory: { min: 1, hasMax: false, max: 0 },
    ops: [0x0b],
  });
  assert.throws(
    () => validateWithBoth(noMax, { maxMemoryBytes: 2 * page, rejectOpcodes: [] }),
    /has no declared maximum/,
  );

  const bounded = buildModule({
    memory: { min: 1, hasMax: true, max: 2 },
    ops: [0x0b],
  });
  assert.doesNotThrow(() =>
    validateWithBoth(bounded, { maxMemoryBytes: 2 * page, rejectOpcodes: [] }),
  );
});

test("browser wasm policy parses current bulk memory and SIMD immediates", () => {
  const moduleBytes = buildModule({
    memory: { min: 1, hasMax: true, max: 1 },
    ops: [
      0xfc, 0x0a, 0x00, 0x00, // memory.copy 0 0
      0xfc, 0x0b, 0x00, // memory.fill 0
      0xfd, 0x56, 0x00, 0x00, 0x01, // v128.load32_lane align=0 offset=0 lane=1
      0xfd, 0x5a, 0x00, 0x00, 0x02, // v128.store32_lane align=0 offset=0 lane=2
      0xfd, 0x5c, 0x00, 0x00, // v128.load32_zero align=0 offset=0
      0x0b,
    ],
  });

  assert.doesNotThrow(() => validateWithBoth(moduleBytes, fixedMemoryPolicy));
});
