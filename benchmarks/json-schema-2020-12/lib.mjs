// Shared pieces for suite.mjs and bench.mjs: the fixture reader, the JSON
// envelope writer and reader, the Compliance oracle bridge, and one adapter
// per validator. Every adapter takes the same envelope input as the QIP
// component ({"schemas": {uri: …}, "schema": …, "instance": …}) so the comply
// oracle can drive all three.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Validator as CfworkerValidator } from "@cfworker/json-schema";
import { Validator as AtaValidator } from "ata-validator";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const componentPath = path.join(root, "application/json/json-schema-2020-12-must-be-valid.wasm");
export const compilerPath = path.join(root, "application/json/json-schema-to-wasm.wasm");
export const oraclePath = path.join(root, "compliance/json-schema-2020-12.comply.wasm");
export const fixturePath = path.join(root, "compliance/json-schema-2020-12.fixtures.txt");
const metaDir = path.join(root, "application/json/lib/json-schema-2020-12");

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

// ---------------------------------------------------------------------------
// Fixture: the same flattened suite the oracle embeds.

export function readFixture() {
  const lines = fs.readFileSync(fixturePath, "utf8").split("\n");
  const expected = Number(lines[0].replace(/^cases /, ""));
  const groups = [];
  let group = null;
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (line === "") continue;
    if (line.startsWith("group ")) {
      const [, file, ...rest] = line.split(" ");
      group = { file, description: rest.join(" "), remotes: [], schema: null, tests: [] };
      groups.push(group);
    } else if (line.startsWith("remote ")) {
      group.remotes.push({ uri: line.slice(7), json: lines[++i] });
    } else if (line === "schema") {
      group.schema = lines[++i];
    } else if (line.startsWith("valid ") || line.startsWith("invalid ")) {
      const valid = line.startsWith("valid ");
      group.tests.push({ valid, description: line.slice(valid ? 6 : 8), data: lines[++i] });
    } else throw new Error(`unexpected fixture line ${i + 1}: ${line}`);
  }
  const cases = groups.flatMap((g) => g.tests.map((t) => ({ group: g, test: t })));
  if (cases.length !== expected) throw new Error(`fixture declares ${expected} cases, found ${cases.length}`);
  return { groups, cases };
}

// ---------------------------------------------------------------------------
// JSON envelope

// Joins JSON texts the host already has into one envelope, without parsing
// or reformatting them. "instance" goes last, as the comply oracle writes it.
export function writeEnvelope({ schema, instance, schemas = {} }) {
  const entries = Object.entries(schemas);
  const parts = [];
  if (entries.length > 0) parts.push(`"schemas":{${entries.map(([uri, json]) => `${JSON.stringify(uri)}:${json}`).join(",")}}`);
  parts.push(`"schema":${schema}`, `"instance":${instance}`);
  return encoder.encode(`{${parts.join(",")}}`);
}

export function caseEnvelope(group, data) {
  return writeEnvelope({ schema: group.schema, instance: data, schemas: Object.fromEntries(group.remotes.map((r) => [r.uri, r.json])) });
}

// Splits an envelope into JSON texts: { schemaText, instanceText,
// instanceBytes, remotes: {uri: text} }. The texts are re-serialized; for the
// fixture's JSON.stringify output that gives back the same bytes.
export function unpackCase(input) {
  const env = JSON.parse(decoder.decode(input));
  const instanceText = JSON.stringify(env.instance);
  const remotes = Object.fromEntries(Object.entries(env.schemas ?? {}).map(([uri, doc]) => [uri, JSON.stringify(doc)]));
  return { schemaText: JSON.stringify(env.schema), instanceText, instanceBytes: encoder.encode(instanceText), remotes };
}

// The 2020-12 meta-schemas, for libraries that want them registered.
export function metaSchemas() {
  const map = {
    "https://json-schema.org/draft/2020-12/schema": "schema.json",
    "https://json-schema.org/draft/2020-12/meta/core": "meta-core.json",
    "https://json-schema.org/draft/2020-12/meta/applicator": "meta-applicator.json",
    "https://json-schema.org/draft/2020-12/meta/unevaluated": "meta-unevaluated.json",
    "https://json-schema.org/draft/2020-12/meta/validation": "meta-validation.json",
    "https://json-schema.org/draft/2020-12/meta/meta-data": "meta-meta-data.json",
    "https://json-schema.org/draft/2020-12/meta/format-annotation": "meta-format-annotation.json",
    "https://json-schema.org/draft/2020-12/meta/content": "meta-content.json",
  };
  return Object.fromEntries(Object.entries(map).map(([uri, file]) => [uri, JSON.parse(fs.readFileSync(path.join(metaDir, file), "utf8"))]));
}

// ---------------------------------------------------------------------------
// Validators. Each `compile(schemaText, remotes)` returns `(instance) => bool`
// for an already-parsed instance. `run(input)` is the whole envelope-in path used
// by the oracle: { status: "accept", output } | { status: "reject" } |
// { status: "error", message }.

export function qipValidator(wasmPath = componentPath) {
  const module = new WebAssembly.Module(fs.readFileSync(wasmPath));
  let instance = null;
  let memory = null;
  let inputPtr = 0;
  let cap = 0;
  const fresh = () => {
    instance = new WebAssembly.Instance(module, {});
    memory = instance.exports.memory;
    inputPtr = instance.exports.input_ptr();
    cap = instance.exports.input_bytes_cap();
  };
  fresh();
  // Returns true (accept), false (reject) or throws (trap).
  const render = (input) => {
    if (input.length > cap) throw new Error("input over capacity");
    new Uint8Array(memory.buffer, inputPtr, input.length).set(input);
    let result;
    try {
      result = BigInt.asUintN(64, instance.exports.render(input.length));
    } catch (error) {
      fresh();
      throw error;
    }
    if (result >> 63n) return { accepted: false };
    const ptr = Number((result >> 32n) & 0x7fffffffn);
    const size = Number(result & 0xffffffffn);
    return { accepted: true, ptr, size };
  };
  return {
    name: "qip (Zig → Wasm)",
    render,
    run(input) {
      try {
        const r = render(input);
        if (!r.accepted) return { status: "reject" };
        return { status: "accept", output: new Uint8Array(memory.buffer, r.ptr, r.size).slice() };
      } catch (error) {
        return { status: "error", message: `trap: ${error.message}` };
      }
    },
  };
}

// Runs a QIP Content component: copy input in, render, read the result.
// render returns { accepted, ptr, size } or throws on a trap, after which the
// instance is replaced so the next call starts clean.
function qipComponent(module) {
  let instance = null;
  let memory = null;
  let inputPtr = 0;
  let cap = 0;
  const fresh = () => {
    instance = new WebAssembly.Instance(module, {});
    memory = instance.exports.memory;
    inputPtr = instance.exports.input_ptr();
    cap = (instance.exports.input_bytes_cap ?? instance.exports.input_utf8_cap)();
  };
  fresh();
  return {
    render(input) {
      if (input.length > cap) throw new Error("input over capacity");
      new Uint8Array(memory.buffer, inputPtr, input.length).set(input);
      let result;
      try {
        result = BigInt.asUintN(64, instance.exports.render(input.length));
      } catch (error) {
        fresh();
        throw error;
      }
      if (result >> 63n) return { accepted: false };
      const ptr = Number((result >> 32n) & 0x7fffffffn);
      const size = Number(result & 0xffffffffn);
      return { accepted: true, ptr, size };
    },
    bytes: (ptr, size) => new Uint8Array(memory.buffer, ptr, size).slice(),
  };
}

// The compiled path: json-schema-to-wasm turns {"schema", "schemas"} into a
// module, which then validates bare instances. compile() returns a check
// over instance bytes, with .module and .component for benchmarks.
export function qipCompiledValidator(wasmPath = compilerPath) {
  const compiler = qipComponent(new WebAssembly.Module(fs.readFileSync(wasmPath)));
  const compileModule = (schemaText, remotes = {}) => {
    const entries = Object.entries(remotes);
    const parts = [];
    if (entries.length > 0) parts.push(`"schemas":{${entries.map(([uri, json]) => `${JSON.stringify(uri)}:${json}`).join(",")}}`);
    parts.push(`"schema":${schemaText}`);
    const r = compiler.render(encoder.encode(`{${parts.join(",")}}`));
    if (!r.accepted) throw new Error("json-schema-to-wasm rejected the schema");
    return new WebAssembly.Module(compiler.bytes(r.ptr, r.size));
  };
  const compile = (schemaText, remotes = {}) => {
    const module = compileModule(schemaText, remotes);
    const component = qipComponent(module);
    const check = (bytes) => component.render(bytes).accepted;
    check.module = module;
    check.component = component;
    return check;
  };
  const cache = new Map();
  return {
    name: "qip compiled (json-schema-to-wasm)",
    compileModule,
    compile,
    run(input) {
      try {
        const { schemaText, instanceBytes, remotes } = unpackCase(input);
        const key = JSON.stringify([schemaText, remotes]);
        if (!cache.has(key)) cache.set(key, compile(schemaText, remotes));
        const check = cache.get(key);
        const r = check.component.render(instanceBytes);
        if (!r.accepted) return { status: "reject" };
        return { status: "accept", output: check.component.bytes(r.ptr, r.size) };
      } catch (error) {
        return { status: "error", message: `trap: ${error.message}` };
      }
    },
  };
}

function jsRun(compile) {
  return (input) => {
    try {
      const { schemaText, instanceText, instanceBytes, remotes } = unpackCase(input);
      const check = compile(schemaText, remotes);
      return check(JSON.parse(instanceText)) ? { status: "accept", output: instanceBytes } : { status: "reject" };
    } catch (error) {
      return { status: "error", message: String(error?.message ?? error).split("\n")[0] };
    }
  };
}

export function cfworkerValidator() {
  // cfworker does not bundle the 2020-12 meta-schemas, so register them as
  // remotes; without this it cannot resolve "$ref" to the meta-schema.
  const metas = Object.entries(metaSchemas());
  const compile = (schemaText, remotes = {}) => {
    const v = new CfworkerValidator(JSON.parse(schemaText), "2020-12", true);
    for (const [uri, schema] of metas) v.addSchema(schema, uri);
    for (const [uri, text] of Object.entries(remotes)) v.addSchema(JSON.parse(text), uri);
    return (instance) => v.validate(instance).valid;
  };
  return { name: "@cfworker/json-schema", compile, run: jsRun(compile) };
}

export function ataValidator() {
  const compile = (schemaText, remotes = {}) => {
    const schemas = Object.fromEntries(Object.entries(remotes).map(([uri, text]) => [uri, JSON.parse(text)]));
    // Defaults off and format as an annotation: the 2020-12 default dialect.
    const v = new AtaValidator(JSON.parse(schemaText), { schemas, useDefaults: false, assertFormat: false });
    const check = (instance) => v.isValidObject(instance);
    check.bytes = (bytes) => v.isValid(bytes);
    return check;
  };
  return { name: "ata-validator", compile, run: jsRun(compile) };
}

export function allValidators() {
  return [qipValidator(), qipCompiledValidator(), cfworkerValidator(), ataValidator()];
}

// ---------------------------------------------------------------------------
// Compliance oracle bridge: runs compliance/json-schema-2020-12.comply.wasm
// against any `run(input)` adapter, the way `qip comply` does.

export function runOracle(validator) {
  let oracleMemory = null;
  const failures = [];
  let declared = 0;
  const bytes = (ptr, len) => new Uint8Array(oracleMemory.buffer, ptr, len).slice();
  const record = (ordinal, ok, detail) => {
    declared += 1;
    if (!ok) failures.push({ ordinal: Number(ordinal), detail });
    return ok ? 1 : 0;
  };
  const imports = {
    qip: {
      must_render_exactly(ordinal, inputPtr, inputLen, expectedPtr, expectedLen) {
        const result = validator.run(bytes(inputPtr, inputLen));
        if (result.status !== "accept") return record(ordinal, false, `expected accept, got ${result.status}${result.message ? `: ${result.message}` : ""}`);
        const expected = bytes(expectedPtr, expectedLen);
        const same = result.output.length === expected.length && result.output.every((b, i) => b === expected[i]);
        return record(ordinal, same, "accepted with different output bytes");
      },
      must_reject(ordinal, inputPtr, inputLen) {
        const result = validator.run(bytes(inputPtr, inputLen));
        return record(ordinal, result.status === "reject", `expected reject, got ${result.status}${result.message ? `: ${result.message}` : ""}`);
      },
    },
  };
  const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(oraclePath)), imports);
  oracleMemory = instance.exports.memory;
  const returned = instance.exports.comply();
  if (returned !== declared) throw new Error(`oracle returned ${returned} but declared ${declared} cases`);
  return { total: declared, failures };
}
