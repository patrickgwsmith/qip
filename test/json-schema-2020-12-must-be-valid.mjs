// Contract edges of the JSON Schema validator that the JSON-Schema-Test-Suite
// oracle does not reach: the envelope layout, remote documents, the accepted
// output bytes, and which failures trap instead of rejecting.
// compliance/json-schema-2020-12.comply.wasm covers the keywords themselves.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const WASM = "application/json/json-schema-2020-12-must-be-valid.wasm";
const module = new WebAssembly.Module(await readFile(WASM));
const encoder = new TextEncoder();

// Joins JSON texts into an envelope without reformatting them.
function envelope({ schema, instance, schemas }) {
  const parts = [];
  if (schemas) parts.push(`"schemas":{${Object.entries(schemas).map(([uri, json]) => `${JSON.stringify(uri)}:${json}`).join(",")}}`);
  if (schema !== undefined) parts.push(`"schema":${schema}`);
  if (instance !== undefined) parts.push(`"instance":${instance}`);
  return `{${parts.join(",")}}`;
}

// Returns { accepted, output } or throws on trap.
function validate(text) {
  const input = encoder.encode(text);
  const { exports } = new WebAssembly.Instance(module, {});
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  if (result >> 63n) return { accepted: false };
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  const size = Number(result & 0xffffffffn);
  return { accepted: true, output: Buffer.from(exports.memory.buffer, ptr, size).toString("utf8") };
}

const check = (schema, instance, schemas) => validate(envelope({ schema: JSON.stringify(schema), instance, schemas }));

test("accepted output is the instance bytes unchanged", () => {
  const instance = '{ "b": 1,\n  "a": [1.50, "\\u00e9"] }';
  const r = check({ type: "object" }, instance);
  assert.deepEqual(r, { accepted: true, output: instance });
});

test("a nonconforming instance is rejected, not trapped", () => {
  assert.deepEqual(check({ type: "string" }, "42"), { accepted: false });
  assert.deepEqual(check(false, "null"), { accepted: false });
});

test("envelope keys may come in any order, with whitespace around them", () => {
  const input = ' {\n  "instance" : 3 ,\n  "schema" : {"minimum": 2}\n}\n';
  assert.deepEqual(validate(input), { accepted: true, output: "3" });
  assert.deepEqual(validate('{"instance": 1, "schemas": {}, "schema": {"minimum": 2}}'), { accepted: false });
});

test("schemas supplies a remote document by URI", () => {
  const schema = { $ref: "https://example.com/defs/positive.json" };
  const schemas = { "https://example.com/defs/positive.json": '{"type": "number", "exclusiveMinimum": 0}' };
  assert.equal(check(schema, "5", schemas).accepted, true);
  assert.equal(check(schema, "-5", schemas).accepted, false);
});

test("a urn key and a remote's own $id also resolve", () => {
  const urn = { "urn:example:even": '{"multipleOf": 2}' };
  assert.equal(check({ $ref: "urn:example:even" }, "4", urn).accepted, true);
  assert.equal(check({ $ref: "urn:example:even" }, "3", urn).accepted, false);
  const byId = { "https://elsewhere.example/x.json": '{"$id": "https://example.com/name.json", "type": "string"}' };
  assert.equal(check({ $ref: "https://example.com/name.json" }, '"hi"', byId).accepted, true);
});

test("the 2020-12 meta-schema is built in", () => {
  const meta = { $ref: "https://json-schema.org/draft/2020-12/schema" };
  assert.equal(check(meta, '{"type": "string", "minLength": 1}').accepted, true);
  assert.equal(check(meta, '{"minLength": -1}').accepted, false);
});

test("pattern is ECMA-262 with the u flag and is not anchored", () => {
  assert.equal(check({ pattern: "\\p{L}{2}\\d" }, '"--πx7--"').accepted, true);
  assert.equal(check({ pattern: "^\\d{3}-\\d{4}$" }, '"555-1234"').accepted, true);
  assert.equal(check({ pattern: "^\\d{3}-\\d{4}$" }, '"555-12345"').accepted, false);
  // A Pike VM: no exponential blowup on the classic catastrophic pattern.
  const started = performance.now();
  assert.equal(check({ pattern: "^(a+)+$" }, JSON.stringify("a".repeat(5000) + "!")).accepted, false);
  assert.ok(performance.now() - started < 2000);
});

test("broken inputs and schemas trap rather than look like invalid instances", () => {
  const traps = {
    "empty envelope": "{}",
    "envelope is not an object": "[]",
    "missing instance": '{"schema": {}}',
    "missing schema": '{"instance": 1}',
    "unknown key": '{"schema": {}, "instance": 1, "notes": "hi"}',
    "repeated key": '{"schema": {}, "instance": 1, "instance": 2}',
    "schemas is not an object": '{"schema": {}, "instance": 1, "schemas": []}',
    "trailing bytes": '{"schema": {}, "instance": 1} {}',
    "invalid instance JSON": '{"schema": {}, "instance": {}',
    "invalid schema JSON": '{"schema": {,}, "instance": 1}',
    "unresolvable $ref": envelope({ schema: '{"$ref": "https://nowhere.example/x"}', instance: "1" }),
    "lookahead in pattern": envelope({ schema: '{"pattern": "(?=a)"}', instance: '"a"' }),
    "unknown required vocabulary": envelope({
      schema: '{"$schema": "https://example.com/meta"}',
      instance: "1",
      schemas: { "https://example.com/meta": '{"$vocabulary": {"https://example.com/vocab/custom": true}}' },
    }),
    "infinite $ref loop": envelope({ schema: '{"$ref": "#"}', instance: "1" }),
  };
  for (const [name, input] of Object.entries(traps)) {
    assert.throws(() => validate(input), WebAssembly.RuntimeError, name);
  }
});
