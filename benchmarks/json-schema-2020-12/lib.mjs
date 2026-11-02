// Shared pieces for suite.mjs and bench.mjs: the fixture reader, a minimal
// ustar reader and writer, the Compliance oracle bridge, and one adapter per
// validator. Every adapter takes the same TAR input as the QIP component
// (schema.json, instance.json, schemas/<scheme>/<rest>) so the comply oracle
// can drive all three.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Validator as CfworkerValidator } from "@cfworker/json-schema";
import { Validator as AtaValidator } from "ata-validator";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
export const componentPath = path.join(root, "application/x-tar/json-schema-2020-12-must-be-valid.wasm");
export const oraclePath = path.join(root, "compliance/json-schema-2020-12.comply.wasm");
export const fixturePath = path.join(root, "compliance/json-schema-2020-12.fixtures.txt");
const metaDir = path.join(root, "application/x-tar/lib/json-schema-2020-12");

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
// TAR

function octal(header, offset, length, value) {
  const text = value.toString(8).padStart(length - 1, "0");
  header.set(encoder.encode(text), offset);
  header[offset + length - 1] = 0;
}

export function writeTar(files) {
  const chunks = [];
  for (const [name, data] of files) {
    const bytes = typeof data === "string" ? encoder.encode(data) : data;
    const header = new Uint8Array(512);
    const nameBytes = encoder.encode(name);
    if (nameBytes.length > 100) throw new Error(`tar path too long: ${name}`);
    header.set(nameBytes, 0);
    octal(header, 100, 8, 0o644);
    octal(header, 108, 8, 0);
    octal(header, 116, 8, 0);
    octal(header, 124, 12, bytes.length);
    octal(header, 136, 12, 0);
    header[156] = "0".charCodeAt(0);
    header.set(encoder.encode("ustar\0"), 257);
    header.set(encoder.encode("00"), 263);
    header.fill(0x20, 148, 156);
    let sum = 0;
    for (const b of header) sum += b;
    octal(header, 148, 7, sum);
    header[155] = 0x20;
    chunks.push(header, bytes, new Uint8Array((512 - (bytes.length % 512)) % 512));
  }
  chunks.push(new Uint8Array(1024));
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

function cString(bytes) {
  const end = bytes.indexOf(0);
  return decoder.decode(end < 0 ? bytes : bytes.subarray(0, end));
}

export function readTar(input) {
  const files = new Map();
  let pos = 0;
  while (pos + 512 <= input.length) {
    const header = input.subarray(pos, pos + 512);
    if (header.every((b) => b === 0)) break;
    let name = cString(header.subarray(0, 100));
    const prefix = cString(header.subarray(345, 500));
    if (prefix) name = `${prefix}/${name}`;
    const size = parseInt(cString(header.subarray(124, 136)).trim() || "0", 8);
    const data = input.subarray(pos + 512, pos + 512 + size);
    if (header[156] === 0 || header[156] === 0x30) files.set(name.replace(/^(\.\/)+/, ""), data);
    pos += 512 + Math.ceil(size / 512) * 512;
  }
  return files;
}

export function caseTar(group, data) {
  const files = [
    ["schema.json", group.schema],
    ["instance.json", data],
  ];
  for (const remote of group.remotes) {
    const [scheme, rest] = remote.uri.split("://");
    files.push([`schemas/${scheme}/${rest}`, remote.json]);
  }
  return writeTar(files);
}

// Splits a case archive into JSON texts: { schema, instance, remotes: {uri: text} }.
export function unpackCase(input) {
  const files = readTar(input);
  const remotes = {};
  for (const [name, data] of files) {
    if (!name.startsWith("schemas/")) continue;
    const rest = name.slice("schemas/".length);
    const slash = rest.indexOf("/");
    const first = slash < 0 ? rest : rest.slice(0, slash);
    const uri = first.includes(":") ? rest : `${first}://${rest.slice(slash + 1)}`;
    remotes[uri] = decoder.decode(data);
  }
  return {
    schemaText: decoder.decode(files.get("schema.json")),
    instanceBytes: files.get("instance.json"),
    instanceText: decoder.decode(files.get("instance.json")),
    remotes,
  };
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
// for an already-parsed instance. `run(input)` is the whole TAR-in path used
// by the oracle: { status: "accept", output } | { status: "reject" } |
// { status: "error", message }.

export function qipValidator() {
  const module = new WebAssembly.Module(fs.readFileSync(componentPath));
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
  return [qipValidator(), cfworkerValidator(), ataValidator()];
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
