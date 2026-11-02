// Contract edges of the JSON Schema validator that the JSON-Schema-Test-Suite
// oracle does not reach: the TAR layout, remote documents, the accepted output
// bytes, and which failures trap instead of rejecting.
// compliance/json-schema-2020-12.comply.wasm covers the keywords themselves.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const WASM = "application/x-tar/json-schema-2020-12-must-be-valid.wasm";
const module = new WebAssembly.Module(await readFile(WASM));
const encoder = new TextEncoder();

function octal(header, offset, length, value) {
  header.set(encoder.encode(value.toString(8).padStart(length - 1, "0")), offset);
}

function tar(files, { prefix = "" } = {}) {
  const chunks = [];
  for (const [name, text] of files) {
    const data = encoder.encode(text);
    const header = new Uint8Array(512);
    header.set(encoder.encode(prefix + name), 0);
    octal(header, 100, 8, 0o644);
    octal(header, 108, 8, 0);
    octal(header, 116, 8, 0);
    octal(header, 124, 12, data.length);
    octal(header, 136, 12, 0);
    header[156] = 0x30;
    header.set(encoder.encode("ustar\0" + "00"), 257);
    header.fill(0x20, 148, 156);
    octal(header, 148, 7, header.reduce((a, b) => a + b, 0));
    chunks.push(header, data, new Uint8Array((512 - (data.length % 512)) % 512));
  }
  chunks.push(new Uint8Array(1024));
  return Buffer.concat(chunks);
}

// Returns { accepted, output } or throws on trap.
function validate(input) {
  const { exports } = new WebAssembly.Instance(module, {});
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  if (result >> 63n) return { accepted: false };
  const ptr = Number((result >> 32n) & 0x7fffffffn);
  const size = Number(result & 0xffffffffn);
  return { accepted: true, output: Buffer.from(exports.memory.buffer, ptr, size).toString("utf8") };
}

const check = (schema, instance, extra = []) =>
  validate(tar([["schema.json", JSON.stringify(schema)], ["instance.json", instance], ...extra]));

test("accepted output is the instance bytes unchanged", () => {
  const instance = '{ "b": 1,\n  "a": [1.50, "\\u00e9"] }\n';
  const r = check({ type: "object" }, instance);
  assert.deepEqual(r, { accepted: true, output: instance });
});

test("a nonconforming instance is rejected, not trapped", () => {
  assert.deepEqual(check({ type: "string" }, "42"), { accepted: false });
  assert.deepEqual(check(false, "null"), { accepted: false });
});

test("entry names may start with ./ as tar -C dir -c . writes them", () => {
  const input = tar([["schema.json", '{"minimum": 2}'], ["instance.json", "3"]], { prefix: "./" });
  assert.equal(validate(input).accepted, true);
});

test("schemas/<scheme>/<rest> supplies a remote document by URI", () => {
  const schema = { $ref: "https://example.com/defs/positive.json" };
  const remote = ["schemas/https/example.com/defs/positive.json", '{"type": "number", "exclusiveMinimum": 0}'];
  assert.equal(check(schema, "5", [remote]).accepted, true);
  assert.equal(check(schema, "-5", [remote]).accepted, false);
});

test("schemas/<urn> and a remote's own $id also resolve", () => {
  const urn = ["schemas/urn:example:even", '{"multipleOf": 2}'];
  assert.equal(check({ $ref: "urn:example:even" }, "4", [urn]).accepted, true);
  assert.equal(check({ $ref: "urn:example:even" }, "3", [urn]).accepted, false);
  const byId = ["schemas/https/elsewhere.example/x.json", '{"$id": "https://example.com/name.json", "type": "string"}'];
  assert.equal(check({ $ref: "https://example.com/name.json" }, '"hi"', [byId]).accepted, true);
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
    "missing instance.json": tar([["schema.json", "{}"]]),
    "unknown entry": tar([["schema.json", "{}"], ["instance.json", "1"], ["notes.txt", "hi"]]),
    "invalid instance JSON": tar([["schema.json", "{}"], ["instance.json", "{"]]),
    "invalid schema JSON": tar([["schema.json", "{,}"], ["instance.json", "1"]]),
    "unresolvable $ref": tar([["schema.json", '{"$ref": "https://nowhere.example/x"}'], ["instance.json", "1"]]),
    "lookahead in pattern": tar([["schema.json", '{"pattern": "(?=a)"}'], ["instance.json", '"a"']]),
    "unknown required vocabulary": tar([
      ["schema.json", '{"$schema": "https://example.com/meta"}'],
      ["instance.json", "1"],
      ["schemas/https/example.com/meta", '{"$vocabulary": {"https://example.com/vocab/custom": true}}'],
    ]),
    "infinite $ref loop": tar([["schema.json", '{"$ref": "#"}'], ["instance.json", "1"]]),
  };
  for (const [name, input] of Object.entries(traps)) {
    assert.throws(() => validate(input), WebAssembly.RuntimeError, name);
  }
});
