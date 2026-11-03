#!/usr/bin/env node

// qipdo runs a chain of QIP Content components. It is a separate implementation from
// @qip.dev/qipx and the Rust qipx: test/qipx-parity.mjs runs the shared run and dry-run
// suite against all of them so their behavior and messages stay the same.

import { randomUUID } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { link, mkdir, open, readFile, realpath, stat, unlink, writeFile } from "node:fs/promises";
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

async function readInputFile(filePath) {
  try {
    return await readFile(filePath);
  } catch (error) {
    throw new Error(`cannot read ${filePath}: ${ioErrorReason(error)}`);
  }
}

async function writeOutputFile(filePath, data) {
  try {
    await writeFile(filePath, data);
  } catch (error) {
    throw new Error(`cannot write ${filePath}: ${ioErrorReason(error)}`);
  }
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
  const temporaryPath = join(parent, `.${basename(filePath)}.qipdo-${process.pid}-${randomUUID()}.tmp`);
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

const canonicalWasmHeader = Uint8Array.of(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

function wasmHeaderMustBeValid(candidate, label) {
  const data = bytes(candidate);
  if (data.byteLength < canonicalWasmHeader.byteLength) throw new Error(`${label} does not have a WebAssembly 1.0 header`);
  for (let index = 0; index < canonicalWasmHeader.byteLength; index += 1) {
    if (data[index] !== canonicalWasmHeader[index]) throw new Error(`${label} does not have a WebAssembly 1.0 header`);
  }
}

async function loadMultipartFile(filePath, plan) {
  try {
    return await readFile(filePath);
  } catch (error) {
    if (!missingFileError(error) || plan.sources.length === 1) throw error;
  }
  return resolveSource(plan, wasmHeaderMustBeValid);
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

// Parameters are keyed by lowercase name; `names` keeps each name's declared spelling.
// A quoted value, such as multipart/related's type parameter, is compared without its quotes.
function parseContentType(value) {
  const segments = String(value ?? "").split(";");
  const mediaType = segments[0].trim().toLowerCase();
  const params = new Map();
  const names = new Map();
  for (const segment of segments.slice(1)) {
    const eq = segment.indexOf("=");
    if (eq === -1) continue;
    const declaredName = segment.slice(0, eq).trim();
    const name = declaredName.toLowerCase();
    if (name === "") continue;
    const parameterValue = segment.slice(eq + 1).trim();
    params.set(name, /^".*"$/.test(parameterValue) ? parameterValue.slice(1, -1) : parameterValue);
    names.set(name, declaredName);
  }
  return { mediaType, params, names };
}

// Whether content of type `incoming` satisfies a declared `expected` type: the media types
// must match, and any parameter both declare must have the same value. A parameter only
// one side declares is not required, so bare declarations keep matching.
function contentTypeAccepts(expected, incoming) {
  return contentTypeMismatch(expected, incoming) === "";
}

// Renders the incoming type for an "expected A, got B" message: only its parameters when it
// shares the media type with `expected`, since repeating the media type adds nothing.
function incomingForMessage(expected, incoming) {
  if (parseContentType(expected).mediaType !== parseContentType(incoming).mediaType) return incoming;
  const cut = String(incoming).indexOf(";");
  return cut === -1 ? incoming : String(incoming).slice(cut + 1).trim();
}

// Why `incoming` does not satisfy `expected`, or "" when it does: the media types differ,
// or every parameter both declare with different values. Shared wording across QIP hosts.
function contentTypeMismatch(expected, incoming) {
  const want = parseContentType(expected);
  const got = parseContentType(incoming);
  if (want.mediaType !== got.mediaType) return `media type expected ${want.mediaType} got ${got.mediaType}`;
  const details = [];
  for (const [name, value] of want.params) {
    if (got.params.has(name) && got.params.get(name) !== value) {
      const shown = want.names.get(name);
      details.push(`${shown} expected ${value} got ${got.params.get(name)}`);
    }
  }
  return details.join("; ");
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


const contentComponentContractBrand = Symbol("qipdo.contentComponentContract");

class ContentComponentContractSpec {
  constructor(options = {}) {
    this[contentComponentContractBrand] = true;
    this.label = options.label;
    this.maxMemory = options.maxMemory === undefined ? undefined : parseMaxMemory(options.maxMemory);
    this.inputType = options.inputType;
    this.outputType = options.outputType;
    if (this.inputType !== undefined && !isContentType(this.inputType)) throw new Error("inputType must be contentTypeUTF8(...) or contentTypeBytes(...)");
    if (this.outputType !== undefined && !isContentType(this.outputType)) throw new Error("outputType must be contentTypeUTF8(...) or contentTypeBytes(...)");
    Object.freeze(this);
  }
}

function newContentComponentContract(options = {}) {
  return new ContentComponentContractSpec(options);
}

function componentContractOptions(options = {}) {
  return options?.[contentComponentContractBrand] ? options : options;
}

function isContentType(value) {
  return value instanceof ContentType;
}

function describeContentType(type) {
  return `${type.encoding}${type.mediaType ? ` ${type.mediaType}` : ""}`;
}

function assertComponentContract(component, field, expected) {
  if (expected === undefined) return;
  if (!isContentType(expected)) throw new Error(`${field} must be contentTypeUTF8(...) or contentTypeBytes(...)`);
  const actual = component[field];
  if (actual.encoding !== expected.encoding || (expected.mediaType !== undefined && !contentTypeAccepts(expected.mediaType, actual.mediaType))) {
    throw new Error(`${component.label} ${field} contract mismatch: expected ${describeContentType(expected)}, got ${describeContentType(actual)}`);
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
  const contract = componentContractOptions(options);
  const label = contract.label ?? "component";
  const data = bytes(wasm);
  const maxMemory = contract.maxMemory === undefined || contract.maxMemory === null || contract.maxMemory === "" ? undefined : parseMaxMemory(contract.maxMemory);
  wasmMustExportComponentFunctions(analyzeStrictModule(data, label, maxMemory), label);
}

// The module bytes give each uniform setter's parameter type, which an instance cannot report.
function newComponent(wasm, instance, options = {}) {
  const contract = componentContractOptions(options);
  const label = contract.label ?? "component";
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
  if (inputless && contract.inputType !== undefined) throw new Error(`${label} inputless generator does not accept an inputType contract`);
  if (!inputless) assertComponentContract(component, "inputType", contract.inputType);
  assertComponentContract(component, "outputType", contract.outputType);
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

function resolveStageInputType(stage, currentType, allowMissingInputContentType, index = 0, previous = null) {
  if (stage.inputless) return "";
  let effectiveType = currentType;
  if (!effectiveType && stage.inputType.mediaType && allowMissingInputContentType) effectiveType = stage.inputType.mediaType;
  if (stage.inputType.mediaType) {
    const step = `step ${index + 1} ${stage.label}`;
    if (!effectiveType) throw new Error(`${step} expected ${stage.inputType.mediaType}, but pipeline content type is unspecified`);
    const mismatch = contentTypeMismatch(stage.inputType.mediaType, effectiveType);
    if (mismatch !== "") {
      const source = previous ? ` from step ${previous.index + 1} ${previous.stage.label}` : "";
      throw new Error(`${step} expected ${stage.inputType.mediaType}, got ${incomingForMessage(stage.inputType.mediaType, effectiveType)}${source}: ${mismatch}`);
    }
  }
  return effectiveType;
}

// The most recent stage whose output set the pipeline's content type.
function previousTypedStage(stages, index) {
  for (let candidate = index - 1; candidate >= 0; candidate -= 1) {
    const stage = stages[candidate];
    if (stage.outputType.mediaType || !stage.clearsContentType) return { stage, index: candidate };
  }
  return null;
}

function nextContentType(stage, effectiveInputType) {
  if (stage.outputType.mediaType) return stage.outputType.mediaType;
  if (stage.clearsContentType) return "";
  return effectiveInputType;
}

function parseMaxMemory(value) {
  if (value === undefined) throw new Error("--max-memory requires <bytes>");
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid --max-memory ${value}`);
  const parsed = BigInt(value);
  if (parsed <= 0n || parsed > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`invalid --max-memory ${value}`);
  return Number(parsed);
}



// The byte offset of the first invalid UTF-8 sequence in `bytes`, or -1 when it is all valid.
// Follows the Unicode well-formed byte sequence table, so overlong forms and surrogates are
// invalid. The offset matches the "input offset" a rejecting component reports.
function firstInvalidUTF8Offset(bytes) {
  const n = bytes.length;
  let i = 0;
  while (i < n) {
    const b = bytes[i];
    if (b < 0x80) { i += 1; continue; }
    let need;
    let lo = 0x80;
    let hi = 0xbf;
    if (b >= 0xc2 && b <= 0xdf) need = 1;
    else if (b === 0xe0) { need = 2; lo = 0xa0; }
    else if (b >= 0xe1 && b <= 0xec) need = 2;
    else if (b === 0xed) { need = 2; hi = 0x9f; }
    else if (b >= 0xee && b <= 0xef) need = 2;
    else if (b === 0xf0) { need = 3; lo = 0x90; }
    else if (b >= 0xf1 && b <= 0xf3) need = 3;
    else if (b === 0xf4) { need = 3; hi = 0x8f; }
    else return i;
    if (i + need >= n) return i;
    const second = bytes[i + 1];
    if (second < lo || second > hi) return i;
    for (let k = 2; k <= need; k += 1) {
      const c = bytes[i + k];
      if (c < 0x80 || c > 0xbf) return i;
    }
    i += need + 1;
  }
  return -1;
}

// The pipeline's own input is validated for a UTF-8 first stage, because nothing before it
// established the guarantee. Later stages trust the preceding UTF-8 output.
function checkInitialUTF8(stage, input) {
  if (stage.inputless || stage.inputType.encoding !== "utf8") return;
  const offset = firstInvalidUTF8Offset(input);
  if (offset !== -1) throw new Error(`step 1 ${stage.label} expected UTF-8 input, got invalid UTF-8 at input offset ${offset}`);
}

// A UTF-8 output may feed a bytes input; a bytes output may not feed a UTF-8 input, because
// the host never re-validates bytes and a UTF-8 component relies on valid input.
function checkStageEncoding(stages, index) {
  const stage = stages[index];
  if (stage.inputless || index === 0) return;
  const previous = stages[index - 1];
  const incoming = previous.outputType.encoding;
  const expected = stage.inputType.encoding;
  if (incoming === expected || (incoming === "utf8" && expected === "bytes")) return;
  throw new Error(`step ${index + 1} ${stage.label} expected UTF-8 input, got bytes from step ${index} ${previous.label}`);
}

function checkStagePosition(stages, index) {
  if (stages[index].inputless && index !== 0) {
    throw new Error(`step ${index + 1} ${stages[index].label} inputless generator must be the first pipeline stage`);
  }
}

// The capacity note and error share their wording with qip and the Rust qipx.
function capacityOverflow(stages, index) {
  if (index === 0 || stages[index].inputless) return null;
  const previous = stages[index - 1];
  if (previous.outputCapacity <= stages[index].inputCapacity) return null;
  return { previous, stage: stages[index], index };
}

function validatePipeline(stages, options = {}) {
  if (!Array.isArray(stages) || stages.length === 0) throw new Error("at least one component is required");
  let currentType = "";
  stages.forEach((stage, index) => {
    checkStagePosition(stages, index);
    checkStageEncoding(stages, index);
    const overflow = capacityOverflow(stages, index);
    if (overflow && options.strictCapacities) {
      throw new Error(
        `step ${index + 1} ${stage.label} input capacity ${formatBytes(stage.inputCapacity)} cannot fit step ${index} ${overflow.previous.label} output capacity ${formatBytes(overflow.previous.outputCapacity)}`,
      );
    }
    const effectiveType = resolveStageInputType(stage, currentType, index === 0, index, previousTypedStage(stages, index));
    currentType = nextContentType(stage, effectiveType);
  });
  const last = stages.at(-1);
  return Object.freeze({
    stages,
    outputType: new ContentType(last.outputType.encoding, currentType || undefined),
  });
}

function runPreparedPipeline(input, pipeline, initialContentType = "") {
  let output = bytes(input);
  let currentType = initialContentType;
  for (let index = 0; index < pipeline.stages.length; index += 1) {
    const stage = pipeline.stages[index];
    checkStagePosition(pipeline.stages, index);
    checkStageEncoding(pipeline.stages, index);
    if (index === 0) checkInitialUTF8(stage, output);
    const effectiveType = resolveStageInputType(stage, currentType, index === 0, index, previousTypedStage(pipeline.stages, index));
    output = runStage(stage, output, index + 1);
    currentType = nextContentType(stage, effectiveType);
  }
  return pipelineResult(output, new ContentType(pipeline.stages.at(-1).outputType.encoding, currentType || undefined));
}

function pipelineResult(outputBytes, outputType) {
  const result = {
    outputBytes,
    outputType,
  };
  if (outputType.encoding === "utf8") {
    let outputString;
    Object.defineProperty(result, "outputString", {
      enumerable: true,
      get() {
        if (outputString === undefined) outputString = decoder.decode(outputBytes);
        return outputString;
      },
    });
  }
  return Object.freeze(result);
}


function createRecipe(steps, options = {}) {
  const stages = [];
  for (const step of steps) {
    if (step && Array.isArray(step.stages)) {
      stages.push(...step.stages);
      continue;
    }
    if (step && step.instance instanceof WebAssembly.Instance) {
      stages.push(makeStage({ component: step }, step));
      continue;
    }
    if (!step?.component) throw new Error("recipe step requires component or recipe");
    stages.push(makeStage(step, step.component));
  }
  return validatePipeline(stages, options);
}

function parseStageArgs(args) {
  const stages = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "-u" || arg === "--uniform") {
      if (stages.length === 0) throw new Error(`${arg} must follow a component path`);
      const assignment = args[++index];
      if (assignment === undefined) throw new Error(`${arg} requires <name=value>`);
      const equals = assignment.indexOf("=");
      if (equals <= 0) throw new Error(`${arg} requires <name=value>, got ${JSON.stringify(assignment)}`);
      stages.at(-1).uniforms.push([assignment.slice(0, equals), assignment.slice(equals + 1)]);
      continue;
    }
    if (!arg) throw new Error("component path must not be empty");
    if (arg.startsWith("?")) throw new Error(`uniform query arguments are not supported; use -u <name=value>`);
    stages.push({ filePath: arg, label: arg, uniforms: [] });
  }
  return stages;
}

// parseCLIFormValue parses one -F value. With -i the value is a related part, which may omit
// its unused name, as in -F '@Inter.ttf;type=font/ttf'; otherwise it is a form field.
function parseCLIFormValue(value, related) {
  if (related) return parseRelatedAssignment(value);
  if (value.startsWith("@")) throw new Error(`-F ${JSON.stringify(value)} has no field name; only related parts with -i may omit it`);
  return parseFormAssignment(value);
}

function parseRelatedAssignment(value) {
  const part = parseFormAssignment(value.startsWith("@") ? `part=${value}` : value);
  if (part.fileMode !== "@" || !part.contentType) {
    throw new Error(`related -F ${JSON.stringify(value)} requires [name=]@path;type=<content-type>`);
  }
  return part;
}

function validateFormValues(options) {
  const related = options.inputFromCLI;
  let stdinParts = 0;
  for (const value of options.formValues) {
    const part = parseCLIFormValue(value, related);
    if (!related) continue;
    if (part.filePath === "-" && ++stdinParts > 1) throw new Error("only one related -F part may read stdin");
    if (options.input === "-" && part.filePath === "-") throw new Error("-i - and related -F @- cannot both read stdin");
  }
}

// A positional argument before the first component is a host when it is not a path to a
// .wasm file. Options may appear anywhere, as in git and curl, so `--dry-run qip.dev a.wasm`
// and `qip.dev --dry-run a.wasm` mean the same. The last positional argument is always a
// component, so `qipdo README.md` reports a bad module instead of a missing component.
function looksLikeHost(arg) {
  return !arg.endsWith(".wasm") && !arg.includes("/") && !arg.includes("\\");
}

function parseCLI(argv) {
  const options = {
    input: "-",
    inputFromCLI: false,
    formValues: [],
    output: "-",
    maxMemory: undefined,
    strictCapacities: false,
    dryRun: false,
    help: false,
    version: false,
  };
  const hostArgs = [];
  const components = [];
  // Hosts stay open until the first component or uniform. While they are open no component
  // has been seen, so closing them early makes the last host-like argument the component.
  let hostsOpen = true;
  const closeHosts = () => {
    if (hostsOpen && hostArgs.length > 0) components.push(hostArgs.pop());
    hostsOpen = false;
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--") {
      hostsOpen = false;
      components.push(...argv.slice(index + 1));
      break;
    } else if (arg === "-i" || arg === "--input") {
      options.input = argv[++index];
      options.inputFromCLI = true;
    } else if (arg === "-F" || arg === "--form") {
      const value = argv[++index];
      if (value === undefined) throw new Error(`${arg} requires <name=value>`);
      options.formValues.push(value);
    } else if (arg === "-o" || arg === "--output") {
      options.output = argv[++index];
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--strict-capacities") {
      options.strictCapacities = true;
    } else if (arg === "--dry-run") {
      options.dryRun = true;
    } else if (arg === "-h" || arg === "--help") {
      options.help = true;
    } else if (arg === "--version") {
      options.version = true;
    } else if (arg === "--capacities-must-fit") {
      throw new Error("unknown option --capacities-must-fit; use --strict-capacities");
    } else if (isUniformFlag(arg)) {
      closeHosts();
      components.push(arg);
      if (index + 1 >= argv.length) throw new Error(`${arg} requires <name=value>`);
      components.push(argv[++index]);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option ${arg}`);
    } else if (hostsOpen && looksLikeHost(arg)) {
      hostArgs.push(arg);
    } else {
      hostsOpen = false;
      components.push(arg);
    }
  }
  closeHosts();
  if (options.help || options.version) return { options, hosts: [], components: [] };
  const hosts = hostArgs.map(parseHost);
  if (!options.input) throw new Error("--input requires a path");
  if (!options.output) throw new Error("--output requires a path");
  validateFormValues(options);
  return { options, hosts, components: parseStageArgs(components) };
}

function isUniformFlag(arg) {
  return arg === "-u" || arg === "--uniform";
}

async function loadStages(componentSpecs, options, hosts) {
  const stages = [];
  for (const spec of componentSpecs) {
    const contract = newContentComponentContract({ maxMemory: options.maxMemory, label: spec.label });
    const wasm = await resolveSource(sourcePlan(spec.filePath, hosts), (candidate) => {
      wasmMustComplyWithComponentContract(candidate, contract);
    });
    const module = new WebAssembly.Module(wasm);
    const instance = new WebAssembly.Instance(module);
    const component = newComponent(wasm, instance, contract);
    stages.push({ component, label: spec.label, uniforms: spec.uniforms });
  }
  return stages;
}

async function prepareRunPipeline({ options, hosts, components }) {
  const stages = await loadStages(components, options, hosts);
  const pipeline = createRecipe(stages, {
    strictCapacities: options.strictCapacities,
  });
  return { options, pipeline };
}

function printSourceObservations(observations) {
  console.log("Sources:");
  observations.forEach(({ plan }, componentIndex) => {
    if (observations.length > 1) console.log(`  Component ${componentIndex + 1}: ${displayText(plan.filePath)}`);
    plan.sources.forEach((source, sourceIndex) => {
      const indent = observations.length > 1 ? "    " : "  ";
      console.log(`${indent}${sourceIndex}  ${source.kind.padEnd(5)}  ${displayText(source.kind === "local" ? source.path : source.url)}`);
    });
  });
  console.log("\nResolution:");
  observations.forEach(({ plan, local }, componentIndex) => {
    if (observations.length > 1) console.log(`  Component ${componentIndex + 1}: ${displayText(plan.filePath)}`);
    const indent = observations.length > 1 ? "    " : "  ";
    console.log(`${indent}0  ${local.state}`);
    for (let index = 1; index < plan.sources.length; index += 1) console.log(`${indent}${index}  unexamined`);
  });
}

async function observeMultipartFileSources(formPlan) {
  const observations = [];
  for (const field of formPlan.fields) {
    const { assignment, sourcePlan: plan } = field;
    if (!assignment.filePath || assignment.filePath === "-") continue;
    let state;
    try {
      await stat(assignment.filePath);
      state = "present (contents not read)";
    } catch (error) {
      if (!missingFileError(error)) throw error;
      state = "missing";
    }
    observations.push({ assignment, plan, state });
  }
  return observations;
}

function printMultipartFileObservations(observations) {
  if (observations.length === 0) return;
  console.log("\nMultipart files:");
  for (const { assignment, plan, state } of observations) {
    console.log(`  Field ${displayText(JSON.stringify(assignment.name))}: ${displayText(plan.filePath)}`);
    plan.sources.forEach((source, index) => {
      const label = source.kind === "local" ? source.path : source.url;
      console.log(`    ${index}  ${source.kind.padEnd(5)}  ${displayText(label)}  ${index === 0 ? state : "unexamined"}`);
    });
  }
}

async function dryRunCommand({ options, hosts, components }) {
  if (components.length === 0) throw new Error("at least one component is required");
  // Plan form fields before printing so field errors leave no partial report, as in Rust qipx.
  const formPlan = planMultipartFormInput(options.inputFromCLI ? [] : options.formValues, hosts);
  const observations = [];
  for (const spec of components) {
    const plan = sourcePlan(spec.filePath, hosts);
    observations.push({ spec, plan, local: await observeLocalSource(plan) });
  }
  printSourceObservations(observations);
  printMultipartFileObservations(await observeMultipartFileSources(formPlan));
  console.log("\nValidation:");
  const stages = [];
  let missing = 0;
  for (const observation of observations) {
    if (observation.local.state === "missing") {
      console.log(`  ${displayText(observation.spec.label)}: deferred (local file missing)`);
      missing += 1;
      continue;
    }
    const contract = newContentComponentContract({ maxMemory: options.maxMemory, label: observation.spec.label });
    wasmMustComplyWithComponentContract(observation.local.bytes, contract);
    const module = new WebAssembly.Module(observation.local.bytes);
    const instance = new WebAssembly.Instance(module);
    const component = newComponent(observation.local.bytes, instance, contract);
    const stage = makeStage({ component, label: observation.spec.label, uniforms: observation.spec.uniforms }, component);
    applyUniforms(stage);
    stages.push(stage);
    console.log(`  ${displayText(observation.spec.label)}: valid`);
  }
  if (missing > 0) {
    console.log(`Pipeline compatibility: deferred (${missing} component${missing === 1 ? "" : "s"} missing locally)`);
    return;
  }
  const pipeline = createRecipe(stages, { strictCapacities: options.strictCapacities });
  if (options.inputFromCLI && options.formValues.length > 0 && !isCanonicalMultipartRelatedContentType(pipeline.stages[0]?.inputType.mediaType)) {
    throw new Error("-i with -F requires the first component to declare multipart/related with a root type");
  }
  printDryRunPlan(pipeline);
}

function formatBytes(count) {
  if (count < 1024) return `${count} B`;
  const units = ["KiB", "MiB", "GiB"];
  let value = count;
  let unit = "bytes";
  for (const next of units) {
    if (value < 1024) break;
    value /= 1024;
    unit = next;
  }
  // Round half to even like Go qip and Rust qipx. value is count over a power of two, so
  // value * 10 is exact and the tie test below is reliable.
  const tenths = value * 10;
  const floor = Math.floor(tenths);
  const remainder = tenths - floor;
  const rounded = remainder > 0.5 || (remainder === 0.5 && floor % 2 === 1) ? floor + 1 : floor;
  return `${(rounded / 10).toFixed(1)} ${unit} (${count} bytes)`;
}

function printDryRunPlan(plan) {
  console.log(`Pipeline compatible: ${plan.stages.length} step(s)`);
  let total = 0;
  plan.stages.forEach((stage, index) => {
    const buffers = stage.inputCapacity + stage.outputCapacity;
    total += buffers;
    console.log(`${index + 1}. ${displayText(stage.label)} — Content`);
    console.log(`   Input:  encoding=${stage.inputless ? "none" : (stage.inputType.encoding === "utf8" ? "UTF-8" : "bytes")}, type=${stage.inputless ? "unspecified" : (stage.inputType.mediaType || "unspecified")}, capacity=${formatBytes(stage.inputCapacity)}`);
    console.log(`   Output: encoding=${stage.outputType.encoding === "utf8" ? "UTF-8" : "bytes"}, type=${stage.outputType.mediaType || "unspecified"}, capacity=${formatBytes(stage.outputCapacity)}`);
    console.log(`   Buffers: ${formatBytes(buffers)}`);
  });
  console.log(`Total declared buffer capacity: ${formatBytes(total)}`);
  plan.stages.forEach((stage, index) => {
    const overflow = capacityOverflow(plan.stages, index);
    if (!overflow) return;
    console.log(
      `   Note: step ${index + 1} ${displayText(stage.label)}: previous output capacity ${formatBytes(overflow.previous.outputCapacity)} exceeds this input capacity ${formatBytes(stage.inputCapacity)}; the run remains valid when the actual intermediate output fits`,
    );
  });
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(bytes(chunk));
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

const canonicalFormBoundary = "uuid-00000000-0000-0000-0000-000000000000";
const canonicalFormContentType = `multipart/form-data;boundary=${canonicalFormBoundary}`;

function validateFormQuotedValue(value, label) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x20 || code > 0x7e || value[index] === '"' || value[index] === "\\") {
      throw new Error(`multipart ${label} ${JSON.stringify(value)} must use printable ASCII without quotes or backslashes`);
    }
  }
}

function parseFormAssignment(value) {
  const equals = value.indexOf("=");
  if (equals <= 0) throw new Error(`-F requires <name=value>, got ${JSON.stringify(value)}`);
  const name = value.slice(0, equals);
  const rawValue = value.slice(equals + 1);
  validateFormQuotedValue(name, "field name");
  const fileMode = rawValue[0] === "@" || rawValue[0] === "<" ? rawValue[0] : "";
  if (!fileMode) return { name, value: rawValue, filePath: "", fileMode };
  let filePath = rawValue.slice(1);
  let contentType = "";
  if (filePath.includes(";type=")) {
    [filePath, contentType] = filePath.split(";type=", 2);
    validateContentType(contentType, "-F part content type");
    if (contentType.startsWith("multipart/")) throw new Error(`-F part type ${JSON.stringify(contentType)} must not be multipart`);
  }
  if (!filePath) throw new Error(`-F ${JSON.stringify(value)} has an empty file path`);
  return { name, value: "", filePath, fileMode, contentType };
}

function planMultipartFormInput(values, hosts = []) {
  const fields = values.map((value) => {
    const assignment = parseFormAssignment(value);
    const fileSourcePlan = assignment.filePath && assignment.filePath !== "-"
      ? sourcePlan(assignment.filePath, hosts)
      : undefined;
    return Object.freeze({ assignment: Object.freeze(assignment), sourcePlan: fileSourcePlan });
  });
  if (fields.filter(({ assignment }) => assignment.filePath === "-").length > 1) {
    throw new Error("only one -F field may read from stdin with @- or <-");
  }
  return Object.freeze({ fields: Object.freeze(fields) });
}

function canonicalFormFilename(filePath) {
  const filename = filePath.split(/[\\/]/).at(-1);
  if (!filename) throw new Error(`multipart file path ${JSON.stringify(filePath)} has no filename`);
  validateFormQuotedValue(filename, "filename");
  return filename;
}

// Scans body framed by the CRLFs the builders write around every part, so a delimiter at the
// very start or end of body is found too. A delimiter line is CRLF, "--", the boundary, then
// CRLF or "--".
function multipartBodyContainsBoundary(body, boundary = canonicalFormBoundary) {
  const marker = Buffer.from(`\r\n--${boundary}`);
  const source = Buffer.concat([Buffer.from("\r\n"), Buffer.from(body.buffer, body.byteOffset, body.byteLength), Buffer.from("\r\n")]);
  for (let offset = 0; ;) {
    const index = source.indexOf(marker, offset);
    if (index < 0) return false;
    const after = index + marker.length;
    if (after + 2 <= source.length) {
      const suffix = source.subarray(after, after + 2);
      if (suffix.equals(Buffer.from("\r\n")) || suffix.equals(Buffer.from("--"))) return true;
    }
    offset = index + 1;
  }
}

async function buildMultipartFormInput(values, { stdin, hosts = [], loadFile } = {}) {
  const formPlan = planMultipartFormInput(values, hosts);
  return buildMultipartFormInputFromPlan(formPlan, { stdin, loadFile });
}

async function buildMultipartFormInputFromPlan(formPlan, { stdin, loadFile } = {}) {
  const chunks = [];
  for (const { assignment, sourcePlan: fileSourcePlan } of formPlan.fields) {
    let body;
    let filename = "";
    if (!assignment.filePath) {
      body = encoder.encode(assignment.value);
    } else if (assignment.filePath === "-") {
      body = stdin === undefined ? await readStdin() : bytes(stdin);
      if (assignment.fileMode === "@") filename = "-";
    } else {
      try {
        body = bytes(await (loadFile
          ? loadFile(assignment.filePath, fileSourcePlan)
          : loadMultipartFile(assignment.filePath, fileSourcePlan)));
        if (assignment.fileMode === "@") filename = canonicalFormFilename(assignment.filePath);
      } catch (error) {
        throw new Error(`read -F ${assignment.name}=${assignment.fileMode}${assignment.filePath}: ${ioErrorReason(error)}`);
      }
    }
    if (multipartBodyContainsBoundary(body)) {
      throw new Error(`-F field ${JSON.stringify(assignment.name)} contains the multipart boundary as a delimiter line`);
    }

    let header = `--${canonicalFormBoundary}\r\nContent-Disposition: form-data; name="${assignment.name}"`;
    if (filename) header += `; filename="${filename}"`;
    if (assignment.contentType || filename) header += `\r\nContent-Type: ${assignment.contentType || "application/octet-stream"}`;
    chunks.push(encoder.encode(`${header}\r\n\r\n`), body, encoder.encode("\r\n"));
  }
  chunks.push(encoder.encode(`--${canonicalFormBoundary}--\r\n`));
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return Object.freeze({ bytes: output, contentType: canonicalFormContentType });
}

async function buildMultipartRelatedInput(root, declared, values, { stdin } = {}) {
  if (!isCanonicalMultipartRelatedContentType(declared)) throw new Error("-i with -F requires the first component to declare multipart/related with a root type");
  const rootType = declared.slice('multipart/related;type="'.length, declared.indexOf('";boundary='));
  const boundary = declared.split(";boundary=")[1];
  const chunks = [];
  const addPart = (body, type, label) => {
    if (multipartBodyContainsBoundary(body, boundary)) throw new Error(`${label} contains the multipart boundary as a delimiter line`);
    chunks.push(encoder.encode(`--${boundary}\r\nContent-Type: ${type}\r\n\r\n`), body, encoder.encode("\r\n"));
  };
  addPart(bytes(root), rootType, "-i root");
  let stdinParts = 0;
  for (const value of values) {
    const part = parseRelatedAssignment(value);
    if (part.filePath === "-" && ++stdinParts > 1) throw new Error("only one related -F part may read stdin");
    const body = part.filePath === "-" ? (stdin === undefined ? await readStdin() : bytes(stdin)) : bytes(await readFile(part.filePath));
    addPart(body, part.contentType, "-F part");
  }
  chunks.push(encoder.encode(`--${boundary}--\r\n`));
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return Object.freeze({ bytes: output, contentType: declared });
}

export function usage() {
  return `Usage: qipdo [host ...] [options] <component.wasm> [component2.wasm ...]\n\n` +
    `Run components in order. Each one's output becomes the next one's input.\n\n` +
    `Options:\n` +
    `  -i, --input <path>          Read input from a file instead of stdin\n` +
    `  -F, --form <name=value>     Add a form field, or a typed related part with -i (repeatable)\n` +
    `  -o, --output <path>         Write output to a file instead of stdout\n` +
    `  -u, --uniform <name=value>  Set a uniform on the preceding component (repeatable)\n` +
    `  --max-memory <bytes>        Reject modules whose declared memory exceeds bytes\n` +
    `  --strict-capacities         Fail when a step's output capacity exceeds the next input capacity\n` +
    `  --dry-run                   Check the chain without reading input or rendering\n` +
    `  -h, --help                  Show this help\n` +
    `  --version                   Show the qipdo version\n\n` +
    `Hosts:\n` +
    `  Dotted DNS names such as qip.dev, before the first component. Options may come\n` +
    `  before or after them. Relative .wasm files that are missing locally, including\n` +
    `  -F @path and <path fields, are downloaded over HTTPS and saved.\n\n` +
    `Capacities:\n` +
    `  By default a step may declare a larger output capacity than the next step's input\n` +
    `  capacity: --dry-run notes it, and a run fails only if the real output is too big.\n\n` +
    `Form fields:\n` +
    `  -F name=value, -F name=@path (file with filename), -F 'name=<path' (file without\n` +
    `  filename), -F 'name=@path;type=<type>'. Use @- or <- to read stdin.\n\n` +
    `Examples:\n` +
    `  echo hi | qipdo text/html/html-escape.wasm\n` +
    `  qipdo qip.dev -i page.md text/markdown/markdown-basic.wasm -o page.html\n` +
    `  qipdo --dry-run qip.dev text/markdown/markdown-basic.wasm\n\n` +
    `Documentation: https://qip.dev/docs/content-component\n`;
}

async function runCommand(parsed) {
  const { options, hosts } = parsed;
  const { pipeline } = await prepareRunPipeline(parsed);
  let input;
  let inputContentType = "";
  if (options.formValues.length > 0 && !options.inputFromCLI) {
    const form = await buildMultipartFormInput(options.formValues, { hosts });
    input = form.bytes;
    inputContentType = form.contentType;
  } else {
    input = options.input === "-" && !options.inputFromCLI && process.stdin.isTTY
      ? new Uint8Array()
      : (options.input === "-" ? await readStdin() : await readInputFile(options.input));
  }
  if (options.inputFromCLI && options.formValues.length > 0) {
    const related = await buildMultipartRelatedInput(input, pipeline.stages[0].inputType.mediaType, options.formValues);
    input = related.bytes;
    inputContentType = related.contentType;
  }
  const result = runPreparedPipeline(input, pipeline, inputContentType);
  if (options.output === "-") {
    process.stdout.write(result.outputBytes);
    if (result.outputType.encoding === "utf8") process.stdout.write("\n");
  } else {
    await writeOutputFile(options.output, result.outputBytes);
  }
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
  if (parsed.options.dryRun) {
    await dryRunCommand(parsed);
    return;
  }
  await runCommand(parsed);
}

const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : "";
const modulePath = realpathSync(fileURLToPath(import.meta.url));
if (invokedPath === modulePath) {
  main().catch((error) => {
    console.error(`qipdo: ${displayText(error.message ?? error)}`);
    process.exitCode = 1;
  });
}
