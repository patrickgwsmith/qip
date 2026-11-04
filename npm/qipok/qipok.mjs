#!/usr/bin/env node

// qipok checks QIP Content components for compliance: the Content ABI, the Strict Wasm
// Profile, and any --suite Compliance oracles. It is a separate implementation from
// `qipx comply` in @qip.dev/qipx and the Rust qipx: test/qipx-parity.mjs runs the shared
// comply suite against all of them so their behavior and messages stay the same.

import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { link, mkdir, open, readdir, readFile, realpath, stat, unlink } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

const downloadByteLimit = 16 * 1024 * 1024;
const downloadTimeoutMilliseconds = 30_000;
const redirectLimit = 2;

function displayText(value) {
  // Keep untrusted paths and labels from changing terminal display.
  return Array.from(String(value), (character) =>
    /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(character)
      ? `\\u{${character.codePointAt(0).toString(16)}}`
      : character,
  ).join("");
}

function parseHost(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 259) {
    throw new Error(`invalid host ${JSON.stringify(value)}`);
  }
  const match = /^([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)(?::([0-9]{1,5}))?$/.exec(value);
  if (!match || match[1].length > 253) throw new Error(`invalid host ${JSON.stringify(value)}; use a dotted DNS name with an optional port`);
  if (!/[A-Za-z]/.test(match[1].split(".").at(-1))) throw new Error(`invalid host ${JSON.stringify(value)}; IP addresses are not supported`);
  if (match[2] !== undefined) {
    const port = Number(match[2]);
    if (port < 1 || port > 65535) throw new Error(`invalid host port in ${JSON.stringify(value)}`);
  }
  const authority = `${match[1].toLowerCase()}${match[2] === undefined ? "" : `:${Number(match[2])}`}`;
  return Object.freeze({ authority, origin: `https://${authority}` });
}

function remotelyEligiblePath(filePath) {
  if (typeof filePath !== "string" || !filePath.endsWith(".wasm")) return false;
  if (!/^[\x20-\x7e]+$/.test(filePath)) return false;
  if (isAbsolute(filePath) || filePath.includes(":") || filePath.includes("\\")) return false;
  if (filePath.includes("?") || filePath.includes("#")) return false;
  const segments = filePath.split("/");
  return segments.length > 0 && segments.every((segment) => segment !== "" && segment !== "." && segment !== "..");
}

function sourcePlan(filePath, hosts) {
  const sources = [{ kind: "local", path: filePath }];
  if (remotelyEligiblePath(filePath)) {
    const requestPath = filePath.split("/").map(encodeURIComponent).join("/");
    for (const host of hosts) sources.push({ kind: "https", url: `${host.origin}/${requestPath}` });
  }
  return Object.freeze({ filePath, sources: Object.freeze(sources.map(Object.freeze)) });
}

function missingFileError(error) {
  return error?.code === "ENOENT" || error?.code === "ENOTDIR";
}

// ioErrorReason matches io_reason in rust/qipx/src/main.rs so file errors read the same in both hosts.
function ioErrorReason(error) {
  const reasons = {
    ENOENT: "no such file or directory",
    EACCES: "permission denied",
    EPERM: "permission denied",
    EISDIR: "is a directory",
    ENOTDIR: "not a directory",
  };
  return reasons[error?.code] ?? error?.message ?? String(error);
}

async function observeLocalSource(plan) {
  try {
    return { state: "selected", bytes: await readFile(plan.filePath) };
  } catch (error) {
    if (missingFileError(error)) return { state: "missing" };
    throw error;
  }
}

async function readDownload(response, url) {
  const declaredLength = response.headers.get("content-length");
  if (declaredLength !== null && /^\d+$/.test(declaredLength) && Number(declaredLength) > downloadByteLimit) {
    throw new Error(`${url} exceeds the ${downloadByteLimit}-byte download limit`);
  }
  if (!response.body) return new Uint8Array();
  const chunks = [];
  let length = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > downloadByteLimit) throw new Error(`${url} exceeds the ${downloadByteLimit}-byte download limit`);
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

async function fetchSource(source) {
  let response;
  let url = source.url;
  const sourceOrigin = new URL(source.url).origin;
  const signal = AbortSignal.timeout(downloadTimeoutMilliseconds);
  for (let redirects = 0; redirects <= redirectLimit; redirects += 1) {
    try {
      response = await fetch(url, { redirect: "manual", signal });
    } catch (error) {
      return { unavailable: true, reason: error.message ?? String(error) };
    }
    if (response.status < 300 || response.status > 399) break;
    if (response.body) await response.body.cancel();
    if (redirects === redirectLimit) {
      throw new Error(`${source.url} exceeded the ${redirectLimit}-redirect limit`);
    }
    const location = response.headers.get("location");
    if (!location) throw new Error(`${url} returned HTTP ${response.status} without Location`);
    const next = new URL(location, url);
    if (next.protocol !== "https:" || next.origin !== sourceOrigin || next.username || next.password) {
      throw new Error(`${url} redirected outside its HTTPS origin`);
    }
    url = next.href;
  }
  if (response.status === 404 || response.status === 410 || response.status >= 500) {
    return { unavailable: true, reason: `HTTP ${response.status}` };
  }
  if (response.status !== 200) throw new Error(`${url} returned HTTP ${response.status}`);
  return { unavailable: false, bytes: await readDownload(response, url), url };
}

function pathIsInside(root, child) {
  const difference = relative(root, child);
  return difference === "" || (!difference.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) && difference !== ".." && !isAbsolute(difference));
}

async function vendorDownload(filePath, wasm) {
  const root = await realpath(".");
  const parent = dirname(filePath);
  let existingAncestor = parent;
  while (true) {
    try {
      const resolvedAncestor = await realpath(existingAncestor);
      if (!pathIsInside(root, resolvedAncestor)) throw new Error(`refusing to vendor outside the current directory: ${filePath}`);
      break;
    } catch (error) {
      if (!missingFileError(error)) throw error;
      const next = dirname(existingAncestor);
      if (next === existingAncestor) throw error;
      existingAncestor = next;
    }
  }
  await mkdir(parent, { recursive: true });
  const resolvedParent = await realpath(parent);
  if (!pathIsInside(root, resolvedParent)) throw new Error(`refusing to vendor outside the current directory: ${filePath}`);
  const temporaryPath = join(parent, `.${basename(filePath)}.qipok-${process.pid}-${randomUUID()}.tmp`);
  let output = await open(temporaryPath, "wx");
  try {
    await output.writeFile(wasm);
    await output.close();
    output = null;
    try {
      await link(temporaryPath, filePath);
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  } finally {
    if (output) await output.close();
    try {
      await unlink(temporaryPath);
    } catch (error) {
      if (!missingFileError(error)) throw error;
    }
  }
  return readFile(filePath);
}

async function resolveSource(plan, validate) {
  const local = await observeLocalSource(plan);
  if (local.state === "selected") {
    validate(local.bytes, plan.filePath);
    return local.bytes;
  }
  const unavailable = [];
  for (const source of plan.sources.slice(1)) {
    const fetched = await fetchSource(source);
    if (fetched.unavailable) {
      unavailable.push(`${source.url}: ${fetched.reason}`);
      continue;
    }
    validate(fetched.bytes, fetched.url);
    const installed = await vendorDownload(plan.filePath, fetched.bytes);
    validate(installed, plan.filePath);
    return installed;
  }
  if (plan.sources.length === 1 && !remotelyEligiblePath(plan.filePath)) {
    throw new Error(`${plan.filePath} is missing; only missing relative paths ending in .wasm can be downloaded`);
  }
  const detail = unavailable.length === 0 ? "" : ` (${unavailable.join("; ")})`;
  throw new Error(`${plan.filePath} is unavailable from every source${detail}`);
}

function bytes(value) {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return encoder.encode(value);
  return new Uint8Array(value);
}

function exportedValue(exports, name, label) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`${label} must export ${name}() -> i32`);
  return Number(item()) >>> 0;
}

function requireFunction(exports, name, label) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`${label} must export ${name}`);
  return item;
}

function declaredType(exports, prefix, label) {
  const pointer = exports[`${prefix}_content_type_ptr`];
  const size = exports[`${prefix}_content_type_size`];
  if (pointer === undefined && size === undefined) return "";
  if (pointer === undefined || size === undefined) throw new Error(`${label} has incomplete ${prefix} content-type exports`);
  const start = exportedValue(exports, `${prefix}_content_type_ptr`, label);
  const length = exportedValue(exports, `${prefix}_content_type_size`, label);
  const type = decoder.decode(new Uint8Array(exports.memory.buffer, start, length));
  validateContentType(type, `${label} ${prefix} content type`);
  return type;
}

// A lowercase media type, optionally followed by ";name=value" parameters with no whitespace
// anywhere. Parameter names are case-insensitive; values are case-sensitive and kept
// verbatim, as in "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR".
// multipart/form-data is valid only in its canonical placeholder-boundary form, and
// multipart/related only as multipart/related;type="<type>/<subtype>";boundary=uuid-<uuid>.
function validateContentType(type, label = "content type") {
  if (type === "multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000") return;
  if (isCanonicalMultipartRelatedContentType(type)) return;
  if (
    !String(type).startsWith("multipart/form-data") &&
    !String(type).startsWith("multipart/related") &&
    /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+(?:;[A-Za-z0-9!#$&^_.+-]+=[^\s;"=]+)*$/.test(type)
  ) return;
  throw new Error(`invalid ${label}: ${type}`);
}

const multipartRelatedPattern = /^multipart\/related;type="([a-z0-9!#$&^_.+-]+)\/[a-z0-9!#$&^_.+-]+";boundary=uuid-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isCanonicalMultipartRelatedContentType(type) {
  const match = multipartRelatedPattern.exec(String(type));
  return match !== null && match[1] !== "multipart";
}

function optionalContentType(type, label = "contentType") {
  if (type === undefined) return undefined;
  validateContentType(type, label);
  return type;
}

class ContentType {
  constructor(encoding, optionalMIMEType) {
    this.encoding = encoding;
    this.mediaType = optionalContentType(optionalMIMEType, "mediaType");
    Object.freeze(this);
  }
}

function validUniformKey(key) {
  return key.length >= 1 && key.length <= 63 && /^[a-z][a-z0-9_]*$/.test(key) && !key.endsWith("_") && !key.includes("__");
}

function parseUniformValue(value) {
  const trimmed = String(value).trim();
  if (/^[-+]?0x[0-9a-f]+$/i.test(trimmed)) return Number.parseInt(trimmed, 16);
  if (/^[-+]?\d+$/.test(trimmed)) return Number.parseInt(trimmed, 10);
  if (/^[-+]?(?:\d+\.\d*|\d*\.\d+|\d+)(?:e[-+]?\d+)?$/i.test(trimmed)) return Number(trimmed);
  throw new Error(`uniform value ${JSON.stringify(value)} is not a number`);
}

const minI64 = -(2n ** 63n);
const maxI64 = 2n ** 63n - 1n;

// Wasm i64 parameters only accept a BigInt, so i64 uniforms are parsed exactly rather than
// through a Number. Matches the Go CLI: signed decimal or 0x hex within the i64 range.
function parseUniformI64(value) {
  const match = /^([-+]?)(0x[0-9a-f]+|\d+)$/i.exec(String(value).trim());
  if (match) {
    const magnitude = BigInt(match[2]);
    const parsed = match[1] === "-" ? -magnitude : magnitude;
    if (parsed >= minI64 && parsed <= maxI64) return parsed;
  }
  throw new Error(`uniform value ${JSON.stringify(value)} is not an i64 integer`);
}

// i32 uniforms are unsigned. Like the Go CLI, only exact decimal or 0x hex integers from 0 to
// 2^32 - 1 are accepted, so fractions are not truncated and large values do not wrap.
function parseUniformU32(value) {
  const trimmed = String(value).trim();
  if (/^(?:0x[0-9a-f]+|\d+)$/i.test(trimmed)) {
    const parsed = BigInt(trimmed);
    if (parsed <= 0xffffffffn) return Number(parsed);
  }
  throw new Error(`uniform value ${JSON.stringify(value)} is not an unsigned i32 integer`);
}

// Rejects values that overflow to Infinity instead of passing them to the setter.
function parseUniformFloat(value, f32) {
  const parsed = parseUniformValue(value);
  if (!Number.isFinite(f32 ? Math.fround(parsed) : parsed)) {
    throw new Error(`uniform value ${JSON.stringify(value)} is not a finite ${f32 ? "f32" : "f64"} number`);
  }
  return parsed;
}

function uniformArgument(stage, key, rawValue) {
  const params = stage.component.uniformParamTypes.get(key);
  if (params.length !== 1) throw new Error(`${stage.label} uniform_set_${key} must accept exactly one argument`);
  switch (params[0]) {
    case 0x7f: return parseUniformU32(rawValue);
    case 0x7e: return parseUniformI64(rawValue);
    case 0x7d: return parseUniformFloat(rawValue, true);
    case 0x7c: return parseUniformFloat(rawValue, false);
    default: throw new Error(`${stage.label} uniform_set_${key} has an unsupported parameter type`);
  }
}

function validateUniforms(stage) {
  for (const [key, rawValue] of stage.uniforms ?? []) {
    if (!validUniformKey(key)) throw new Error(`${stage.label} has invalid uniform key ${key}`);
    if (!stage.component.uniformSetterNames.has(key)) throw new Error(`${stage.label} does not export uniform_set_${key}`);
    uniformArgument(stage, key, rawValue);
  }
}

function applyUniforms(stage) {
  validateUniforms(stage);
  for (const [key, rawValue] of stage.uniforms ?? []) {
    stage.component.exports[stage.component.uniformSetterNames.get(key)](uniformArgument(stage, key, rawValue));
  }
}

// Maps each uniform key to the export that sets it. A setter export is uniform_set_<key>,
// optionally followed by "__" and a suffix reserved for declaring the uniform's maxima, so
// hosts match on <key> alone. A module that exports two setters for one key is rejected.
function uniformSetterNames(exportNames, label) {
  const names = new Map();
  for (const name of exportNames) {
    if (!name.startsWith("uniform_set_")) continue;
    const end = name.indexOf("__", 12);
    const key = name.slice(12, end < 0 ? undefined : end);
    if (names.has(key)) {
      const [first, second] = [names.get(key), name].sort();
      throw new Error(`${label} exports both ${first} and ${second} for uniform ${key}`);
    }
    names.set(key, name);
  }
  return names;
}

// Maps each uniform key to its uniform_set_* parameter types, decoded from the type, function
// and export sections. The JS API does not expose a function's signature, and the setter's
// parameter type decides whether it takes a Number or a BigInt. Because components must not
// import, function indices are function-section indices.
function readUniformParamTypes(wasm, label) {
  const types = [];
  let functionTypes = [];
  const setters = [];
  let offset = 8;
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    offset = readULEB(wasm, offset);
    const sectionEnd = offset + lebValue;
    if (sectionEnd > wasm.length) throw new Error("truncated Wasm section");
    if (sectionID === 1) {
      let cursor = readULEB(wasm, offset);
      for (let count = lebValue; count > 0; count -= 1) {
        if (wasm[cursor++] !== 0x60) throw new Error("unsupported Wasm type form");
        cursor = readULEB(wasm, cursor);
        const params = Array.from(wasm.subarray(cursor, cursor + lebValue));
        cursor = readULEB(wasm, cursor + lebValue);
        cursor += lebValue;
        types.push(params);
      }
    } else if (sectionID === 3) {
      let cursor = readULEB(wasm, offset);
      functionTypes = new Array(lebValue);
      for (let index = 0; index < functionTypes.length; index += 1) {
        cursor = readULEB(wasm, cursor);
        functionTypes[index] = lebValue;
      }
    } else if (sectionID === 7) {
      let cursor = readULEB(wasm, offset);
      for (let count = lebValue; count > 0; count -= 1) {
        const name = readName(wasm, cursor);
        const kind = wasm[name.offset];
        cursor = readULEB(wasm, name.offset + 1);
        if (kind === 0x00 && name.value.startsWith("uniform_set_")) setters.push([name.value, lebValue]);
      }
    }
    offset = sectionEnd;
  }
  const funcIndices = new Map(setters);
  const paramTypes = new Map();
  for (const [key, name] of uniformSetterNames(funcIndices.keys(), label)) {
    const params = types[functionTypes[funcIndices.get(name)]];
    if (params !== undefined) paramTypes.set(key, params);
  }
  return paramTypes;
}

// Module inspection reads plain Numbers: every LEB128 value the checks decode (section
// sizes, counts, indices, page limits) fits in 53 bits. readULEB leaves the decoded value in
// lebValue and returns the offset after it; skipLEB steps over values whose magnitude does not
// matter. Both throw on truncation so malformed input fails here rather than in the engine.
let lebValue = 0;

function readULEB(bytes, offset) {
  let value = 0;
  let scale = 1;
  let byte;
  do {
    byte = bytes[offset++];
    if (byte === undefined) throw new Error("truncated Wasm LEB128 integer");
    value += (byte & 0x7f) * scale;
    scale *= 128;
  } while (byte & 0x80);
  lebValue = value;
  return offset;
}

function skipLEB(bytes, offset) {
  let byte;
  do {
    byte = bytes[offset++];
    if (byte === undefined) throw new Error("truncated Wasm LEB128 integer");
  } while (byte & 0x80);
  return offset;
}

function readName(bytes, offset) {
  const start = readULEB(bytes, offset);
  const end = start + lebValue;
  if (end > bytes.length) throw new Error("truncated Wasm name");
  return { value: decoder.decode(bytes.subarray(start, end)), offset: end };
}

function readLimits(bytes, offset, label) {
  const flags = bytes[offset++];
  if (flags === undefined) throw new Error(`${label} has truncated limits`);
  offset = readULEB(bytes, offset);
  const minimum = lebValue;
  let maximum = null;
  if ((flags & 0x01) !== 0) {
    offset = readULEB(bytes, offset);
    maximum = lebValue;
  }
  return { flags, minimum, maximum, offset };
}

function validateMemoryLimits(limits, label, maxMemory) {
  if ((limits.flags & 0x02) !== 0) throw new Error(`${label} declares shared memory, which is outside the Strict Wasm Profile`);
  if (limits.maximum === null) throw new Error(`${label} declares memory without a maximum, which is outside the Strict Wasm Profile`);
  if (maxMemory === undefined || maxMemory === null) return;
  const cap = BigInt(maxMemory);
  const minBytes = BigInt(limits.minimum) * 65536n;
  if (minBytes > cap) throw new Error(`${label} declares minimum memory ${minBytes} bytes, exceeding --max-memory ${cap}`);
  const maxBytes = BigInt(limits.maximum) * 65536n;
  if (maxBytes > cap) throw new Error(`${label} declares maximum memory ${maxBytes} bytes, exceeding --max-memory ${cap}`);
}

function skipBlockType(wasm, offset) {
  const byte = wasm[offset];
  if (byte === undefined) throw new Error("truncated Wasm block type");
  if (byte === 0x40 || (byte >= 0x6f && byte <= 0x7f)) return offset + 1;
  return skipLEB(wasm, offset);
}

function skipMemarg(wasm, offset) {
  return skipLEB(wasm, skipLEB(wasm, offset));
}

function skipSIMDInstruction(wasm, offset, label) {
  offset = readULEB(wasm, offset);
  const code = lebValue;
  if (code <= 11 || code === 92 || code === 93) return skipMemarg(wasm, offset);
  if (code === 12 || code === 13) return offset + 16;
  if (code >= 21 && code <= 34) return offset + 1;
  if (code >= 84 && code <= 91) return skipMemarg(wasm, offset) + 1;
  if (code <= 255) return offset;
  throw new Error(`${label} uses unsupported SIMD opcode 0x${code.toString(16)}`);
}

// Steps over one Strict Wasm Profile instruction, rejecting anything outside the profile.
// Sets bodyIsDynamic when the instruction disqualifies the enclosing function from being a
// static getter: control flow, calls, locals, global writes, memory, or tables. Reading a
// global is allowed.
let bodyIsDynamic = false;

function skipStrictInstruction(wasm, offset, label) {
  const opcode = wasm[offset++];
  switch (opcode) {
    case 0x00: // unreachable
    case 0x01: // nop
    case 0x05: // else
    case 0x0b: // end
    case 0x0f: // return
    case 0x1a: // drop
    case 0x1b: // select
      return offset;
    case 0x02: // block
    case 0x03: // loop
    case 0x04: // if
      bodyIsDynamic = true;
      return skipBlockType(wasm, offset);
    case 0x0c: // br
    case 0x0d: // br_if
    case 0x10: // call
    case 0x20: // local.get
    case 0x21: // local.set
    case 0x22: // local.tee
    case 0x24: // global.set
    case 0x25: // table.get
    case 0x26: // table.set
    case 0xd2: // ref.func
      bodyIsDynamic = true;
      return skipLEB(wasm, offset);
    case 0x23: // global.get
      return skipLEB(wasm, offset);
    case 0x0e: { // br_table
      bodyIsDynamic = true;
      offset = readULEB(wasm, offset);
      for (let count = lebValue; count >= 0; count -= 1) offset = skipLEB(wasm, offset);
      return offset;
    }
    case 0x11: // call_indirect
      bodyIsDynamic = true;
      return skipLEB(wasm, skipLEB(wasm, offset));
    case 0x1c: // select t*
      offset = readULEB(wasm, offset);
      return offset + lebValue;
    case 0x3f: // memory.size
      bodyIsDynamic = true;
      return offset + 1;
    case 0x40: // memory.grow
      throw new Error(`${label} uses memory.grow, which is outside the Strict Wasm Profile`);
    case 0x41: // i32.const
    case 0x42: // i64.const
    case 0xd0: // ref.null
      return skipLEB(wasm, offset);
    case 0x43: // f32.const
      return offset + 4;
    case 0x44: // f64.const
      return offset + 8;
    case 0xfc: { // saturating truncation, bulk memory, table operations
      bodyIsDynamic = true;
      offset = readULEB(wasm, offset);
      const sub = lebValue;
      if (sub <= 7) return offset;
      if (sub === 8 || sub === 10 || sub === 12 || sub === 14) return skipLEB(wasm, skipLEB(wasm, offset));
      return skipLEB(wasm, offset);
    }
    case 0xfd:
      return skipSIMDInstruction(wasm, offset, label);
    case 0xfe:
      throw new Error(`${label} uses atomic instructions, which are outside the Strict Wasm Profile`);
    case undefined:
      throw new Error(`${label} has a truncated instruction`);
    default:
      if (opcode >= 0x28 && opcode <= 0x3e) { // loads and stores
        bodyIsDynamic = true;
        return skipMemarg(wasm, offset);
      }
      if (opcode >= 0x45 && opcode <= 0xc4) return offset; // numeric, including sign extension
      throw new Error(`${label} uses unsupported Wasm opcode 0x${opcode.toString(16)} at byte offset ${offset - 1}`);
  }
}

const staticExportNames = [
  "input_ptr",
  "input_utf8_cap",
  "input_bytes_cap",
  "output_utf8_cap",
  "output_bytes_cap",
  "failure_modes_per_input_offset",
  "input_content_type_ptr",
  "input_content_type_size",
  "output_content_type_ptr",
  "output_content_type_size",
];

// One pass over the module in binary section order, so every implementation reports the
// same first failure: imports, then memory limits, then exports, then a start function, then
// instructions outside the Strict Wasm Profile. Records which defined functions are static
// getters; because imports are rejected, function indices are code-section indices.
function analyzeStrictModule(wasm, label, maxMemory) {
  if (wasm.length < 8 || wasm[0] !== 0x00 || wasm[1] !== 0x61 || wasm[2] !== 0x73 || wasm[3] !== 0x6d) {
    throw new Error(`${label} is not a WebAssembly binary module`);
  }
  let offset = 8;
  let functionCount = 0;
  let memoryCount = 0;
  const exportsByName = new Map();
  let dynamicFunctions = new Uint8Array(0);
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    offset = readULEB(wasm, offset);
    const sectionEnd = offset + lebValue;
    if (sectionEnd > wasm.length) throw new Error(`${label} has a truncated Wasm section`);
    if (sectionID === 2) {
      readULEB(wasm, offset);
      if (lebValue !== 0) throw new Error(`${label} imports host functions or state, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 3) {
      readULEB(wasm, offset);
      functionCount = lebValue;
    } else if (sectionID === 5) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      for (let index = 0; index < count; index += 1) {
        const limits = readLimits(wasm, cursor, label);
        cursor = limits.offset;
        memoryCount += 1;
        validateMemoryLimits(limits, label, maxMemory);
      }
    } else if (sectionID === 7) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      for (let index = 0; index < count; index += 1) {
        const name = readName(wasm, cursor);
        const kind = wasm[name.offset];
        cursor = readULEB(wasm, name.offset + 1);
        exportsByName.set(name.value, { kind, index: lebValue });
      }
    } else if (sectionID === 8) {
      throw new Error(`${label} declares a start function, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 10) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      if (count !== functionCount) throw new Error(`${label} code/function section count mismatch`);
      dynamicFunctions = new Uint8Array(count);
      for (let funcIndex = 0; funcIndex < count; funcIndex += 1) {
        cursor = readULEB(wasm, cursor);
        const bodyEnd = cursor + lebValue;
        if (bodyEnd > sectionEnd) throw new Error(`${label} has a truncated Wasm section`);
        cursor = readULEB(wasm, cursor);
        for (let groups = lebValue; groups > 0; groups -= 1) cursor = skipLEB(wasm, cursor) + 1;
        bodyIsDynamic = false;
        while (cursor < bodyEnd) cursor = skipStrictInstruction(wasm, cursor, label);
        if (cursor !== bodyEnd) throw new Error(`${label} function body is malformed`);
        dynamicFunctions[funcIndex] = bodyIsDynamic ? 1 : 0;
      }
    }
    offset = sectionEnd;
  }
  if (memoryCount !== 1) throw new Error(`${label} must declare exactly one memory`);
  return { exportsByName, dynamicFunctions };
}

function failStaticExports(message) {
  throw new Error(message ?? "comply: static qip contract checks failed");
}

function requireFunctionExport(analysis, name, label) {
  const exp = analysis.exportsByName.get(name);
  if (!exp) failStaticExports(`${label} must export ${name}`);
  if (exp.kind !== 0x00) failStaticExports(`${label} export ${name} must be a function`);
  return exp;
}

function requireStaticFunctionExport(analysis, name, label) {
  const exp = requireFunctionExport(analysis, name, label);
  if (analysis.dynamicFunctions[exp.index] !== 0) failStaticExports("comply: static qip contract checks failed");
}

function wasmMustExportComponentFunctions(analysis, label) {
  const memory = analysis.exportsByName.get("memory");
  if (!memory) failStaticExports(`${label} does not export memory`);
  if (memory.kind !== 0x02) failStaticExports(`${label} export memory must be memory`);
  requireFunctionExport(analysis, "render", label);
  const hasInputPointer = analysis.exportsByName.has("input_ptr");
  const hasInputUTF8 = analysis.exportsByName.has("input_utf8_cap");
  const hasInputBytes = analysis.exportsByName.has("input_bytes_cap");
  if (hasInputPointer) {
    if (hasInputUTF8 === hasInputBytes) failStaticExports(`${label} transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap`);
    requireStaticFunctionExport(analysis, "input_ptr", label);
    requireStaticFunctionExport(analysis, hasInputUTF8 ? "input_utf8_cap" : "input_bytes_cap", label);
  } else if (hasInputUTF8 || hasInputBytes) {
    failStaticExports(`${label} inputless generator must not export an input capacity`);
  }
  const hasOutputUTF8 = analysis.exportsByName.has("output_utf8_cap");
  const hasOutputBytes = analysis.exportsByName.has("output_bytes_cap");
  if (hasOutputUTF8 === hasOutputBytes) failStaticExports(`${label} must export exactly one output capacity: output_utf8_cap or output_bytes_cap`);
  requireStaticFunctionExport(analysis, hasOutputUTF8 ? "output_utf8_cap" : "output_bytes_cap", label);

  for (const prefix of ["input", "output"]) {
    const hasPtr = analysis.exportsByName.has(`${prefix}_content_type_ptr`);
    const hasSize = analysis.exportsByName.has(`${prefix}_content_type_size`);
    if (hasPtr !== hasSize) failStaticExports(`${label} has incomplete ${prefix} content-type exports`);
    if (hasPtr) {
      if (prefix === "input" && !hasInputPointer) failStaticExports(`${label} inputless generator must not declare an input content type`);
      requireStaticFunctionExport(analysis, `${prefix}_content_type_ptr`, label);
      requireStaticFunctionExport(analysis, `${prefix}_content_type_size`, label);
    }
  }

  for (const name of staticExportNames) {
    if (analysis.exportsByName.has(name)) requireStaticFunctionExport(analysis, name, label);
  }
}

function wasmMustComplyWithComponentContract(wasm, options = {}) {
  const label = options.label ?? "component";
  const data = bytes(wasm);
  const maxMemory = options.maxMemory === undefined ? undefined : parseMaxMemory(options.maxMemory);
  wasmMustExportComponentFunctions(analyzeStrictModule(data, label, maxMemory), label);
}

// The module bytes give each uniform setter's parameter type, which an instance cannot report.
function newComponent(wasm, instance, options = {}) {
  const label = options.label ?? "component";
  if (!(wasm instanceof Uint8Array || wasm instanceof ArrayBuffer)) throw new TypeError(`${label} newComponent(wasm, instance, contract) requires the module bytes as a Uint8Array or ArrayBuffer`);
  if (!(instance instanceof WebAssembly.Instance)) throw new TypeError(`${label} newComponent(wasm, instance, contract) requires a WebAssembly.Instance`);
  const uniformParamTypes = readUniformParamTypes(bytes(wasm), label);
  const exports = instance.exports;
  const uniformSetterNamesByKey = uniformSetterNames(Object.keys(exports), label);
  for (const [key, name] of uniformSetterNamesByKey) {
    if (!uniformParamTypes.has(key)) throw new Error(`${label} instance exports ${name}, which the module bytes do not; pass the bytes the instance was created from`);
  }
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error(`${label} does not export memory`);
  requireFunction(exports, "render", label);
  const hasInputUTF8 = typeof exports.input_utf8_cap === "function";
  const hasInputBytes = typeof exports.input_bytes_cap === "function";
  const hasInputPointer = exports.input_ptr !== undefined;
  const inputless = !hasInputPointer;
  const hasOutputUTF8 = typeof exports.output_utf8_cap === "function";
  const hasOutputBytes = typeof exports.output_bytes_cap === "function";
  if (!inputless && hasInputUTF8 === hasInputBytes) throw new Error(`${label} transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap`);
  if (inputless && (hasInputUTF8 || hasInputBytes)) throw new Error(`${label} inputless generator must not export an input capacity`);
  if (hasOutputUTF8 === hasOutputBytes) throw new Error(`${label} must export exactly one output capacity: output_utf8_cap or output_bytes_cap`);
  const inputCapName = inputless ? undefined : (hasInputUTF8 ? "input_utf8_cap" : "input_bytes_cap");
  const outputCapName = hasOutputUTF8 ? "output_utf8_cap" : "output_bytes_cap";
  if (!inputless) {
    exportedValue(exports, "input_ptr", label);
    exportedValue(exports, inputCapName, label);
  }
  exportedValue(exports, outputCapName, label);
  const inputMediaType = declaredType(exports, "input", label) || undefined;
  if (inputless && inputMediaType !== undefined) throw new Error(`${label} inputless generator must not declare an input content type`);
  const component = Object.freeze({
    label,
    instance,
    exports,
    inputType: inputless ? undefined : new ContentType(hasInputUTF8 ? "utf8" : "bytes", inputMediaType),
    outputType: new ContentType(hasOutputUTF8 ? "utf8" : "bytes", declaredType(exports, "output", label) || undefined),
    inputCapName,
    outputCapName,
    inputless,
    clearsContentType: !inputless && hasOutputUTF8 && hasInputBytes,
    inputCapacity: inputless ? 0 : exportedValue(exports, inputCapName, label),
    outputCapacity: exportedValue(exports, outputCapName, label),
    uniformParamTypes,
    uniformSetterNames: uniformSetterNamesByKey,
  });
  return component;
}

function makeStage(spec, component) {
  const stage = {
    label: spec.label ?? spec.filePath ?? component.label,
    uniforms: spec.uniforms ?? [],
    component,
    inputless: component.inputless,
    inputType: component.inputType,
    outputType: component.outputType,
    inputCapName: component.inputCapName,
    outputCapName: component.outputCapName,
    clearsContentType: component.clearsContentType,
    inputCapacity: component.inputCapacity,
    outputCapacity: component.outputCapacity,
  };
  validateUniforms(stage);
  return stage;
}

class ContentRejection extends Error {
  constructor(label, inputOffset, failureMode) {
    super(inputOffset === undefined
      ? `${label} rejected input`
      : failureMode === 0
        ? `${label} rejected input at input offset ${inputOffset}`
        : `${label} rejected input at input offset ${inputOffset} with mode ${failureMode}`);
    this.name = "ContentRejection";
    this.label = label;
    this.inputOffset = inputOffset;
    this.failureMode = failureMode;
  }
}

// `stepNumber`, when given, prefixes failure messages with the step as every QIP host does:
// "step 2 <path> rejected input at input offset 7", "step 1 <path> trapped: <reason>".
function runStage(stage, input, stepNumber) {
  applyUniforms(stage);
  const label = stepNumber === undefined ? stage.label : `step ${stepNumber} ${stage.label}`;
  const { exports } = stage.component;
  if (stage.inputless) {
    if (input.byteLength !== 0) throw new RangeError(`${label} is an inputless generator and cannot receive input bytes`);
  } else {
    const inputPointer = exportedValue(exports, "input_ptr", stage.label);
    const inputCapacity = exportedValue(exports, stage.inputCapName, stage.label);
    if (input.byteLength > inputCapacity) {
      throw new RangeError(`${label} input is too large (${input.byteLength} bytes > ${inputCapacity} bytes input capacity)`);
    }
    if (inputPointer + input.byteLength > exports.memory.buffer.byteLength) {
      throw new RangeError(`${label} input exceeds linear memory`);
    }
    new Uint8Array(exports.memory.buffer, inputPointer, input.byteLength).set(input);
  }
  let renderResult;
  try {
    renderResult = exports.render(stage.inputless ? 0 : input.byteLength);
  } catch (error) {
    if (error instanceof WebAssembly.RuntimeError) throw new Error(`${label} trapped: ${error.message}`);
    throw error;
  }
  if (typeof renderResult !== "bigint") {
    throw new TypeError(`${label} render export must have signature render(i32) -> i64`);
  }
  const bits = BigInt.asUintN(64, renderResult);
  const outputLength = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    if (typeof exports.failure_modes_per_input_offset !== "function") {
      throw new TypeError(`${label} returned failure without failure_modes_per_input_offset`);
    }
    const failureModesPerInputOffset = exportedValue(
      exports,
      "failure_modes_per_input_offset",
      stage.label,
    );
    const rejection = new ContentRejection(
      stage.label,
      failureModesPerInputOffset === 0 ? undefined : Math.floor(outputLength / failureModesPerInputOffset),
      failureModesPerInputOffset === 0 ? undefined : outputLength % failureModesPerInputOffset,
    );
    if (stepNumber !== undefined) rejection.message = `step ${stepNumber} ${rejection.message}`;
    throw rejection;
  }
  const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const outputCapacity = exportedValue(exports, stage.outputCapName, stage.label);
  if (outputLength > outputCapacity || outputPointer + outputLength > exports.memory.buffer.byteLength) {
    throw new RangeError(`${label} returned an invalid output length`);
  }
  return new Uint8Array(exports.memory.buffer, outputPointer, outputLength).slice();
}
function parseMaxMemory(value) {
  if (value === undefined) throw new Error("--max-memory requires <bytes>");
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid --max-memory ${value}`);
  const parsed = BigInt(value);
  if (parsed <= 0n || parsed > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`invalid --max-memory ${value}`);
  return Number(parsed);
}

function parseU32Flag(name, value) {
  if (value === undefined) throw new Error(`${name} requires <n>`);
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid ${name} ${value}`);
  const parsed = BigInt(value);
  if (parsed < 0n || parsed > 0xffffffffn) throw new Error(`invalid ${name} ${value}`);
  return Number(parsed);
}

// Sort like Rust's byte order so comply reports list files the same way in every host.
function compareCodeUnits(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

async function walkWasmFiles(path) {
  const info = await stat(path);
  if (info.isFile()) {
    if (!path.endsWith(".wasm")) throw new Error(`${path} is not a .wasm file`);
    return [path];
  }
  if (!info.isDirectory()) throw new Error(`${path} is not a file or directory`);
  const files = [];
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => compareCodeUnits(a.name, b.name));
    for (const entry of entries) {
      const child = join(directory, entry.name);
      if (entry.isDirectory()) await walk(child);
      else if (entry.isFile() && entry.name.endsWith(".wasm")) files.push(child);
    }
  }
  await walk(path);
  return files;
}

async function discoverWasmFiles(paths) {
  const files = [];
  for (const path of paths) {
    try {
      files.push(...await walkWasmFiles(path));
    } catch (error) {
      if (missingFileError(error) && remotelyEligiblePath(path)) files.push(path);
      else if (error?.code) throw new Error(`cannot read ${path}: ${ioErrorReason(error)}`);
      else throw error;
    }
  }
  return [...new Set(files)].sort(compareCodeUnits);
}

// A positional argument before the first file or directory is a host when it is a dotted
// name that is not a .wasm path, has no slash, and does not exist locally. Options may
// appear anywhere, so `qipok --seed 1 qip.dev a.wasm` and `qipok qip.dev --seed 1 a.wasm`
// mean the same. The last positional argument is always a file or directory, so
// `qipok README.md` reports that README.md is not a .wasm file.
function looksLikeHost(arg) {
  return arg.includes(".") && !arg.endsWith(".wasm") && !arg.includes("/") && !arg.includes("\\") && !existsSync(arg);
}

function parseCLI(argv) {
  const options = { maxMemory: undefined, suites: [], seed: undefined, help: false, version: false };
  const hostArgs = [];
  const paths = [];
  // Hosts stay open until the first file or directory. While they are open no path has
  // been seen, so closing them makes the last host-like argument a path.
  let hostsOpen = true;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "-h" || arg === "--help") {
      options.help = true;
    } else if (arg === "--version") {
      options.version = true;
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--suite") {
      const value = argv[++index];
      if (!value) throw new Error(`${arg} requires a path`);
      options.suites.push(value);
    } else if (arg === "--seed") {
      options.seed = parseU32Flag("--seed", argv[++index]);
    } else if (arg === "--with") {
      throw new Error("unknown option --with; use --suite");
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option ${arg}`);
    } else if (hostsOpen && looksLikeHost(arg)) {
      hostArgs.push(arg);
    } else {
      hostsOpen = false;
      paths.push(arg);
    }
  }
  if (hostsOpen && hostArgs.length > 0) paths.push(hostArgs.pop());
  if (options.help || options.version) return { options, hosts: [], paths: [] };
  const hosts = hostArgs.map(parseHost);
  if (paths.length === 0) throw new Error("comply requires at least one file or directory");
  options.suites.sort(compareCodeUnits);
  // Without --seed, seed oracles that accept one randomly and report it in the summary.
  options.seedExplicit = options.seed !== undefined;
  if (!options.seedExplicit) options.seed = globalThis.crypto.getRandomValues(new Uint32Array(1))[0];
  options.seedUsed = false;
  return { options, hosts, paths };
}

function readMemory(memory, ptr, length) {
  const start = Number(ptr) >>> 0;
  const size = Number(length) >>> 0;
  if (start + size > memory.buffer.byteLength) return null;
  return new Uint8Array(memory.buffer, start, size).slice();
}

function renderComponent(component, input) {
  const stage = makeStage({ component }, component);
  return runStage(stage, bytes(input));
}

async function instantiateContentComponent(wasm, label, options = {}) {
  wasmMustComplyWithComponentContract(wasm, { label, maxMemory: options.maxMemory });
  const module = new WebAssembly.Module(wasm);
  const instance = new WebAssembly.Instance(module);
  return newComponent(wasm, instance, { label });
}

function instantiateComplianceOracle(wasm, label, imports) {
  const module = new WebAssembly.Module(wasm);
  const instance = new WebAssembly.Instance(module, imports);
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) throw new Error(`${label} Compliance oracle must export memory`);
  if (typeof instance.exports.comply !== "function") throw new Error(`${label} Compliance oracle must export comply() -> i32`);
  return instance;
}

async function runComplianceOracle(implWasm, implPath, oraclePath, oracleWasm, options = {}) {
  const impl = await instantiateContentComponent(implWasm, implPath, options);
  let oracleInstance;
  const state = { next: 0n, openRenderInto: null, openRenderIntoFailed: false, openRenderIntoErrorCount: 0, failCount: 0, failures: [], protocolError: null };
  const failProtocol = (message) => {
    if (!state.protocolError) state.protocolError = message;
  };
  const oracleMemory = () => oracleInstance?.exports?.memory;
  const readOracle = (ptr, length) => {
    const memory = oracleMemory();
    if (!(memory instanceof WebAssembly.Memory)) return null;
    return readMemory(memory, ptr, length);
  };
  const caseOpen = (ordinal, kind) => {
    const ord = BigInt(ordinal);
    if (state.openRenderInto !== null) {
      failProtocol(`${kind} at ordinal ${ord} inside open must_render_into case ${state.openRenderInto}`);
      return false;
    }
    if (ord !== state.next) {
      failProtocol(`${kind} declared ordinal ${ord}, host expected ${state.next}`);
      return false;
    }
    return true;
  };
  const qip = {
    set_uniform_u32(namePtr, nameLen, value) {
      if (state.openRenderInto !== null) {
        failProtocol(`set_uniform_u32 called inside open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      if (nameLen === 0 || nameLen > 128) {
        failProtocol(`set_uniform_u32 name length ${nameLen} is outside 1..128`);
        return 0;
      }
      const nameBytes = readOracle(namePtr, nameLen);
      if (!nameBytes) {
        failProtocol("set_uniform_u32 name pointer out of range");
        return 0;
      }
      const name = decoder.decode(nameBytes);
      if (!validUniformKey(name)) {
        failProtocol(`set_uniform_u32 name ${JSON.stringify(name)} is not a valid uniform key`);
        return 0;
      }
      const setterName = impl.uniformSetterNames.get(name);
      if (setterName === undefined) {
        failProtocol(`implementation does not export uniform_set_${name}`);
        return 0;
      }
      try {
        return Number(impl.exports[setterName](Number(value) >>> 0)) | 0;
      } catch (error) {
        failProtocol(`${setterName} trapped: ${error.message ?? error}`);
        return 0;
      }
    },
    must_render_exactly(ordinal, inPtr, inLen, expPtr, expLen) {
      if (!caseOpen(ordinal, "must_render_exactly")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      const expected = readOracle(expPtr, expLen);
      if (!input || !expected) {
        failProtocol(`must_render_exactly pointers out of range at ordinal ${ordinal}`);
        return 0;
      }
      try {
        const actual = renderComponent(impl, input);
        if (actual.byteLength !== expected.byteLength || actual.some((byte, index) => byte !== expected[index])) {
          state.failCount += 1;
          state.failures.push(`case ${ordinal}: output mismatch`);
          return 0;
        }
        return 1;
      } catch (error) {
        state.failCount += 1;
        if (error instanceof ContentRejection) {
          state.failures.push(`case ${ordinal}: unexpected rejection (failure detail ${error.detail})`);
        } else {
          state.failures.push(`case ${ordinal}: trapped: ${error.message ?? error}`);
        }
        return 0;
      }
    },
    must_trap(ordinal, inPtr, inLen) {
      if (!caseOpen(ordinal, "must_trap")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        failProtocol(`must_trap pointer out of range at ordinal ${ordinal}`);
        return 0;
      }
      try {
        renderComponent(impl, input);
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected trap, got output`);
        return 0;
      } catch (error) {
        if (error instanceof ContentRejection) {
          state.failCount += 1;
          state.failures.push(`case ${ordinal}: expected trap, got rejection (failure detail ${error.detail})`);
          return 0;
        }
        return 1;
      }
    },
    must_reject(ordinal, inPtr, inLen) {
      if (!caseOpen(ordinal, "must_reject")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        failProtocol(`must_reject pointer out of range at ordinal ${ordinal}`);
        return 0;
      }
      if (typeof impl.exports.failure_modes_per_input_offset !== "function") {
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected rejection, but implementation does not export failure_modes_per_input_offset`);
        return 0;
      }
      try {
        renderComponent(impl, input);
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected rejection, render was accepted`);
        return 0;
      } catch (error) {
        if (error instanceof ContentRejection) return 1;
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected rejection: ${error.message ?? error}`);
        return 0;
      }
    },
    must_render_into(ordinal, inPtr, inLen, outPtr, outCap) {
      const ord = BigInt(ordinal);
      if (state.openRenderInto !== null) {
        failProtocol(`must_render_into opened ordinal ${ord} while ordinal ${state.openRenderInto} is still open`);
        return -1;
      }
      if (ord !== state.next) {
        failProtocol(`must_render_into opened ordinal ${ord}, host expected ${state.next}`);
        return -1;
      }
      state.openRenderInto = ord;
      state.openRenderIntoFailed = false;
      state.openRenderIntoErrorCount = 0;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        state.openRenderIntoFailed = true;
        failProtocol(`must_render_into pointer out of range at ordinal ${ord}`);
        return -1;
      }
      let output;
      try {
        output = renderComponent(impl, input);
      } catch {
        state.openRenderIntoFailed = true;
        return -1;
      }
      if (output.byteLength > (Number(outCap) >>> 0)) {
        state.openRenderIntoFailed = true;
        return -2;
      }
      const memory = oracleMemory();
      const outStart = Number(outPtr) >>> 0;
      if (outStart + output.byteLength > memory.buffer.byteLength) {
        state.openRenderIntoFailed = true;
        failProtocol(`must_render_into out pointer out of range at ordinal ${ord}`);
        return -1;
      }
      new Uint8Array(memory.buffer, outStart, output.byteLength).set(output);
      return output.byteLength;
    },
    must_render_into_emit_error(ordinal, messagePtr, messageSize) {
      const ord = BigInt(ordinal);
      if (state.openRenderInto === null || state.openRenderInto !== ord) {
        failProtocol(`must_render_into_emit_error ordinal ${ord} does not match open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      const message = readOracle(messagePtr, messageSize);
      if (!message) {
        failProtocol(`must_render_into_emit_error message pointer out of range at ordinal ${ord}`);
        return 0;
      }
      state.openRenderIntoErrorCount += 1;
      state.failures.push(`case ${ord}: render_into error: ${decoder.decode(message)}`);
      return 1;
    },
    must_render_into_finish(ordinal, errorCount) {
      const ord = BigInt(ordinal);
      const count = Number(errorCount) >>> 0;
      if (state.openRenderInto === null || state.openRenderInto !== ord) {
        failProtocol(`must_render_into_finish ordinal ${ord} does not match open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      if (count !== state.openRenderIntoErrorCount) {
        failProtocol(`must_render_into_finish ordinal ${ord} reported ${count} errors, host observed ${state.openRenderIntoErrorCount}`);
        return 0;
      }
      if (state.openRenderIntoFailed && count === 0) {
        failProtocol(`must_render_into_finish ordinal ${ord} reported 0 errors after render failure`);
        return 0;
      }
      if (count > 0) state.failCount += 1;
      state.openRenderInto = null;
      state.openRenderIntoFailed = false;
      state.openRenderIntoErrorCount = 0;
      state.next += 1n;
      return 1;
    },
  };
  oracleInstance = instantiateComplianceOracle(oracleWasm, oraclePath, { qip });
  const seedSetterName = uniformSetterNames(Object.keys(oracleInstance.exports), oraclePath).get("seed");
  if (seedSetterName === undefined && options.seedExplicit) {
    throw new Error(`${oraclePath}: --seed given but Compliance oracle does not export uniform_set_seed`);
  }
  if (seedSetterName !== undefined && options.seed !== undefined) {
    options.seedUsed = true;
    try {
      oracleInstance.exports[seedSetterName](options.seed >>> 0);
    } catch (error) {
      throw new Error(`${oraclePath}: ${seedSetterName} failed: ${error.message ?? error}`);
    }
  }
  let declared;
  try {
    declared = Number(oracleInstance.exports.comply()) | 0;
  } catch (error) {
    throw new Error(`${oraclePath}: comply() trapped: ${error.message ?? error}`);
  }
  if (state.protocolError) throw new Error(`${oraclePath}: bridge protocol violation: ${state.protocolError}`);
  if (state.openRenderInto !== null) throw new Error(`${oraclePath}: comply() returned with must_render_into case ${state.openRenderInto} still open`);
  if (declared <= 0) throw new Error(`${oraclePath}: comply() declared no cases (returned ${declared})`);
  if (BigInt(declared >>> 0) !== state.next) throw new Error(`${oraclePath}: comply() returned ${declared} cases but host counted ${state.next}`);
  if (state.failCount > 0) throw new Error(`${oraclePath}: ${state.failCount}/${state.next} cases failed; ${state.failures[0]}`);
  return { cases: Number(state.next) };
}

async function complyCommand({ options, hosts, paths }) {
  const files = await discoverWasmFiles(paths);
  if (files.length === 0) throw new Error("No .wasm files found");
  const oracles = [];
  for (const oraclePath of options.suites) {
    const oracleWasm = await resolveSource(sourcePlan(oraclePath, hosts), (wasm, label) => {
      if (wasm.length < 8 || wasm[0] !== 0x00 || wasm[1] !== 0x61 || wasm[2] !== 0x73 || wasm[3] !== 0x6d) {
        throw new Error(`${label} is not a WebAssembly binary module`);
      }
      try {
        new WebAssembly.Module(wasm);
      } catch (error) {
        throw new Error(`${label} is not valid WebAssembly: ${error.message ?? error}`);
      }
    });
    oracles.push({ path: oraclePath, wasm: oracleWasm });
  }
  let pass = 0;
  let fail = 0;
  for (const file of files) {
    let wasm;
    try {
      wasm = await resolveSource(sourcePlan(file, hosts), (candidate, label) => {
        wasmMustComplyWithComponentContract(candidate, { label, maxMemory: options.maxMemory });
      });
      await instantiateContentComponent(wasm, file, options);
      console.log(`PASS ${displayText(file)}`);
      pass += 1;
    } catch (error) {
      console.log(`FAIL ${displayText(file)}: ${displayText(error.message ?? error)}`);
      fail += 1;
      continue;
    }
    for (const oracle of oracles) {
      try {
        const result = await runComplianceOracle(wasm, file, oracle.path, oracle.wasm, options);
        console.log(`PASS ${displayText(file)} --suite ${displayText(oracle.path)} (${result.cases} cases)`);
        pass += 1;
      } catch (error) {
        console.log(`FAIL ${displayText(file)} --suite ${displayText(oracle.path)}: ${displayText(error.message ?? error)}`);
        fail += 1;
      }
    }
  }
  const seedReport = options.seedUsed ? ` seed=${options.seed >>> 0}` : "";
  console.log(`\npass=${pass} fail=${fail} total=${pass + fail}${seedReport}`);
  if (fail > 0) process.exitCode = 1;
}

export function usage() {
  return `Usage: qipok [host ...] [options] <file-or-dir> [...]\n\n` +
    `Check that components follow the QIP Content ABI and the Strict Wasm Profile.\n` +
    `Directories are searched for .wasm files.\n\n` +
    `Options:\n` +
    `  --suite <suite.wasm>        Also run a Compliance suite on each component (repeatable)\n` +
    `  --seed <n>                  Seed suites that export uniform_set_seed (u32)\n` +
    `  --max-memory <bytes>        Reject components whose declared memory exceeds bytes\n` +
    `  -h, --help                  Show this help\n` +
    `  --version                   Show the qipok version\n\n` +
    `Seeds:\n` +
    `  Without --seed, suites that export uniform_set_seed get a random seed. The\n` +
    `  summary prints it, so pass it to --seed to repeat the run.\n\n` +
    `Hosts:\n` +
    `  Dotted DNS names such as qip.dev, before the first file or directory. Options\n` +
    `  may come before or after them. Relative .wasm files and suites that are missing\n` +
    `  locally are downloaded over HTTPS and saved.\n\n` +
    `Examples:\n` +
    `  qipok text/hello.wasm\n` +
    `  qipok text/luhn.wasm --suite compliance/luhn.comply.wasm\n` +
    `  qipok qip.dev text/cve.wasm --suite compliance/cve.comply.wasm\n\n` +
    `Documentation: https://qip.dev/docs/comply\n`;
}

export { parseCLI as parseArgs };

export async function main(argv = process.argv.slice(2)) {
  if (argv.length === 0) {
    console.log(usage());
    return;
  }
  const parsed = parseCLI(argv);
  if (parsed.options.help) {
    console.log(usage());
    return;
  }
  if (parsed.options.version) {
    console.log(JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")).version);
    return;
  }
  await complyCommand(parsed);
}

const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : "";
const modulePath = realpathSync(fileURLToPath(import.meta.url));
if (invokedPath === modulePath) {
  main().catch((error) => {
    console.error(`qipok: ${displayText(error.message ?? error)}`);
    process.exitCode = 1;
  });
}
