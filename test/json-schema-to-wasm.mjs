// json-schema-to-wasm: the compiler's input and rejections, the generated
// module's contract, the whole JSON-Schema-Test-Suite through compiled
// modules, and a differential check against json-schema-2020-12-must-be-valid
// on random instances.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { makeOrders, orderSchema } from "../benchmarks/json-schema-2020-12/orders.mjs";

const COMPILER = "application/json/json-schema-to-wasm.wasm";
const VALIDATOR = "application/json/json-schema-2020-12-must-be-valid.wasm";
const ORACLE = "compliance/json-schema-2020-12.comply.wasm";
const compilerModule = new WebAssembly.Module(await readFile(COMPILER));
const validatorModule = new WebAssembly.Module(await readFile(VALIDATOR));
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Renders once in a fresh instance. Returns { accepted, output } (output as
// bytes) or throws on trap.
function render(module, input) {
  const bytes = typeof input === "string" ? encoder.encode(input) : input;
  const { exports } = new WebAssembly.Instance(module, {});
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  const result = BigInt.asUintN(64, exports.render(bytes.length));
  if (result >> 63n) return { accepted: false };
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  const size = Number(result & 0xffffffffn);
  return { accepted: true, output: new Uint8Array(exports.memory.buffer, ptr, size).slice() };
}

function envelope({ schema, schemas, instance }) {
  const parts = [];
  if (schemas) parts.push(`"schemas":{${Object.entries(schemas).map(([uri, json]) => `${JSON.stringify(uri)}:${json}`).join(",")}}`);
  if (schema !== undefined) parts.push(`"schema":${schema}`);
  if (instance !== undefined) parts.push(`"instance":${instance}`);
  return `{${parts.join(",")}}`;
}

function compileText(text) {
  const r = render(compilerModule, text);
  return r.accepted ? new WebAssembly.Module(r.output) : null;
}

const compile = (schema, schemas) => compileText(envelope({ schema: JSON.stringify(schema), schemas }));

// A generated module kept across renders, as a host would.
function component(module) {
  const { exports } = new WebAssembly.Instance(module, {});
  return (text) => {
    const bytes = encoder.encode(text);
    new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
    const result = BigInt.asUintN(64, exports.render(bytes.length));
    return !(result >> 63n);
  };
}

test("the generated module outputs accepted input unchanged and rejects the rest", () => {
  const module = compile({ type: "object", properties: { a: { type: "array", items: { type: "number" } } } });
  const instance = '{ "b": 1,\n  "a": [1.50, 2e3] , "c":"\\u00e9" }';
  const r = render(module, instance);
  assert.equal(r.accepted, true);
  assert.equal(decoder.decode(r.output), instance);
  assert.deepEqual(render(module, '{"a": ["x"]}'), { accepted: false });
  assert.deepEqual(render(module, "[]"), { accepted: false });
});

test("invalid JSON instances trap", () => {
  const module = compile(true);
  for (const bad of ["", "[1,]", "{\"a\":1,}", "01", "\"\\x\"", "[1] [2]", "\"\u0001\"", "nul", "[".repeat(600) + "]".repeat(600)]) {
    assert.throws(() => render(module, bad), WebAssembly.RuntimeError, JSON.stringify(bad));
  }
  assert.equal(render(module, " [1, {\"a\": null}, \"x\"] ").accepted, true);
});

test("the module records its schema and exports the Content contract", () => {
  const input = envelope({ schema: '{"minimum": 1}' });
  const r = render(compilerModule, input);
  const module = new WebAssembly.Module(r.output);
  const [section] = WebAssembly.Module.customSections(module, "qip.json-schema");
  assert.equal(decoder.decode(section), input);
  const exports = WebAssembly.Module.exports(module).map((e) => e.name).sort();
  assert.deepEqual(exports, ["failure_modes_per_input_offset", "input_bytes_cap", "input_content_type_ptr", "input_content_type_size", "input_ptr", "memory", "output_content_type_ptr", "output_content_type_size", "output_utf8_cap", "render"]);
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  // The runtime plus a small program and the custom section.
  assert.ok(r.output.length < 48 * 1024, `${r.output.length} bytes`);
});

test("remote documents and the meta-schema resolve at compile time", () => {
  const remote = { "https://example.com/positive.json": '{"type": "number", "exclusiveMinimum": 0}' };
  const check = component(compile({ $ref: "https://example.com/positive.json" }, remote));
  assert.equal(check("5"), true);
  assert.equal(check("0"), false);
  const meta = component(compile({ $ref: "https://json-schema.org/draft/2020-12/schema" }));
  assert.equal(meta('{"type": "string", "minLength": 1}'), true);
  assert.equal(meta('{"minLength": -1}'), false);
  assert.equal(meta('{"$defs": {"a": {"type": 7}}}'), false);
});

test("inputs that cannot be compiled are rejected", () => {
  const rejected = [
    "not json",
    "{}",
    '{"schema": {}, "instance": 1}',
    '{"schema": {}, "other": 1}',
    '{"schema": {}, "schema": {}}',
    '{"schema": {}, "schemas": []}',
    envelope({ schema: '{"$ref": "#/$defs/missing"}' }),
    envelope({ schema: '{"$ref": "https://example.com/nowhere.json"}' }),
    envelope({ schema: '{"pattern": "(?=a)"}' }),
    envelope({ schema: '{"patternProperties": {"\\\\1": true}}' }),
    envelope({ schema: '{"minLength": "1"}' }),
    envelope({ schema: '{"type": 1}' }),
    envelope({ schema: '{"required": [1]}' }),
    envelope({ schema: '{"allOf": {}}' }),
    envelope({ schema: '{"multipleOf": 1.0000000000000000000000000000000000001}' }),
    envelope({ schema: '{"$schema": "https://example.com/unknown-dialect"}' }),
  ];
  for (const text of rejected) assert.equal(compileText(text), null, text);
  // Keywords the compiler does not know are ignored, as in the validator.
  assert.ok(compileText(envelope({ schema: '{"x-anything": {"pattern": "(?=a)"}}' })));
});

test("count keywords round the way exact comparison does", () => {
  // Raw text: JSON.stringify would write 1e400 as null.
  const check = component(compileText(envelope({ schema: '{"minLength": 1.5, "maxLength": 3.5, "maxItems": 0, "minProperties": 1e400}' })));
  assert.equal(check('"a"'), false);
  assert.equal(check('"ab"'), true);
  assert.equal(check('"abc"'), true);
  assert.equal(check('"abcd"'), false);
  assert.equal(check('"πλ"'), true);
  assert.equal(check("[]"), true);
  assert.equal(check("[1]"), false);
  assert.equal(check('{"a": 1}'), false);
  const negative = component(compile({ maxLength: -1 }));
  assert.equal(negative('""'), false);
  assert.equal(negative("1"), true);
});

test("the JSON-Schema-Test-Suite passes through compiled modules", () => {
  // The same oracle `qip comply` runs, bridged to compile-then-validate: each
  // case's envelope is split into its schema and its instance.
  const cache = new Map();
  let oracleMemory = null;
  let declared = 0;
  const failures = [];
  const run = (ptr, len) => {
    const env = JSON.parse(decoder.decode(new Uint8Array(oracleMemory.buffer, ptr, len)));
    const remotes = Object.fromEntries(Object.entries(env.schemas ?? {}).map(([uri, doc]) => [uri, JSON.stringify(doc)]));
    const key = JSON.stringify([env.schema, remotes]);
    if (!cache.has(key)) cache.set(key, compile(env.schema, remotes));
    const module = cache.get(key);
    assert.ok(module, `schema did not compile: ${key}`);
    const instance = JSON.stringify(env.instance);
    try {
      const r = render(module, instance);
      return r.accepted ? { status: "accept", output: decoder.decode(r.output), instance } : { status: "reject" };
    } catch (error) {
      return { status: "trap", message: error.message };
    }
  };
  const imports = {
    qip: {
      must_render_exactly(ordinal, ptr, len) {
        declared += 1;
        const r = run(ptr, len);
        const ok = r.status === "accept" && r.output === r.instance;
        if (!ok) failures.push(`#${ordinal} expected accept, got ${r.status}`);
        return ok ? 1 : 0;
      },
      must_reject(ordinal, ptr, len) {
        declared += 1;
        const r = run(ptr, len);
        if (r.status !== "reject") failures.push(`#${ordinal} expected reject, got ${r.status}`);
        return r.status === "reject" ? 1 : 0;
      },
    },
  };
  return readFile(ORACLE).then((bytes) => {
    const oracle = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
    oracleMemory = oracle.exports.memory;
    assert.equal(oracle.exports.comply(), declared);
    assert.equal(declared, 1298);
    assert.deepEqual(failures, []);
  });
});

// Random JSON with the shapes that stress the tape parser: escapes, non-ASCII,
// long strings that cross 8-byte chunks, exponents, nesting.
function randomValue(rand, depth = 0) {
  const pick = (xs) => xs[Math.floor(rand() * xs.length)];
  const kind = depth > 3 ? pick(["s", "n", "b"]) : pick(["s", "n", "b", "a", "o", "o"]);
  switch (kind) {
    case "s": {
      const chars = ["a", "b", "Z", "-", "@", ".", "1", "é", "π", "😀", "\n", '"', "\\", " ", "\u2028", "\u0000"];
      let s = "";
      for (let i = 0, n = Math.floor(rand() * 20); i < n; i++) s += pick(chars);
      return s;
    }
    case "n":
      return pick([0, 1, -1, 2, 0.5, 1.25, 12.34, 1e21, -0.001, 1000, 7, 3.14159, 100.01]);
    case "b":
      return pick([true, false, null]);
    case "a":
      return Array.from({ length: Math.floor(rand() * 5) }, () => randomValue(rand, depth + 1));
    default:
      return Object.fromEntries(Array.from({ length: Math.floor(rand() * 5) }, () => [pick(["a", "b", "c", "x-1", "é", "foo"]), randomValue(rand, depth + 1)]));
  }
}

function mulberry32(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test("compiled modules agree with the validator on random instances", () => {
  const schemas = [
    orderSchema,
    { type: "object", properties: { a: { type: "string", pattern: "^[a-z]+$" }, b: { const: [1, { x: null }] } }, patternProperties: { "^x-": { type: "integer" } }, additionalProperties: { enum: [true, false, "é"] } },
    { anyOf: [{ type: "array", uniqueItems: true, contains: { type: "number" }, maxContains: 2 }, { type: "string", minLength: 3, pattern: "π|😀" }] },
    { oneOf: [{ multipleOf: 0.5 }, { minimum: 10 }], not: { enum: [1e21, "a"] } },
    { prefixItems: [{ type: "string" }, { type: "number" }], items: false, unevaluatedItems: false },
    { properties: { a: true }, dependentRequired: { a: ["b"] }, dependentSchemas: { c: { required: ["foo"] } }, unevaluatedProperties: { type: "number" }, propertyNames: { maxLength: 3 } },
    { $defs: { node: { type: "object", properties: { foo: { $ref: "#/$defs/node" } } } }, $ref: "#/$defs/node" },
  ];
  const rand = mulberry32(2026);
  let compared = 0;
  for (const schema of schemas) {
    const check = component(compile(schema));
    const instances = schema === orderSchema ? [makeOrders(3), ...Array.from({ length: 30 }, () => randomValue(rand))] : Array.from({ length: 300 }, () => randomValue(rand));
    for (const value of instances) {
      const text = JSON.stringify(value);
      const want = render(validatorModule, envelope({ schema: JSON.stringify(schema), instance: text })).accepted;
      assert.equal(check(text), want, `${JSON.stringify(schema)} on ${text}`);
      compared += 1;
    }
  }
  assert.ok(compared > 1800);
});

test("the order book document validates the same as the validator", () => {
  const check = component(compile(orderSchema));
  const doc = makeOrders(300);
  assert.equal(check(JSON.stringify(doc)), true);
  doc.orders[299].lines[0].sku = "bad-sku";
  assert.equal(check(JSON.stringify(doc)), false);
  doc.orders[299].lines[0].sku = "ABC-1234";
  doc.orders[0].lines[0].price = 1.005;
  assert.equal(check(JSON.stringify(doc)), false);
});
