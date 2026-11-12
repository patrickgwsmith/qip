// Code shared by the qiptui and qipgui npm packages: the component loader, Strict Wasm
// Profile checks, uniform handling and terminal key decoder.
//
// npm/shared/qip-host.mjs is the single source. `make npm-shared` (npm/sync-shared.mjs)
// copies it into each package so every package stays self-contained and dependency-free;
// `make check-npm-shared` fails when a copy is out of date. Edit only the source.

import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";

export const decoder = new TextDecoder("utf-8", { fatal: true });

export const FLAG_KEY_DOWN = 1 << 0;
export const FLAG_SHIFT = 1 << 2;
export const FLAG_CONTROL = 1 << 3;
export const FLAG_ALT = 1 << 4;

export const XK_BACKSPACE = 0xff08;
export const XK_TAB = 0xff09;
export const XK_RETURN = 0xff0d;
export const XK_ESCAPE = 0xff1b;
export const XK_HOME = 0xff50;
export const XK_LEFT = 0xff51;
export const XK_UP = 0xff52;
export const XK_RIGHT = 0xff53;
export const XK_DOWN = 0xff54;
export const XK_PAGE_UP = 0xff55;
export const XK_PAGE_DOWN = 0xff56;
export const XK_END = 0xff57;
export const XK_INSERT = 0xff63;
export const XK_DELETE = 0xffff;
export const XK_F1 = 0xffbe;

export function utf8SequenceLength(first) {
  if (first < 0x80) return 1;
  if (first >= 0xc2 && first <= 0xdf) return 2;
  if (first >= 0xe0 && first <= 0xef) return 3;
  if (first >= 0xf0 && first <= 0xf4) return 4;
  return 0;
}

function modifierFlags(parameter) {
  const encoded = parameter - 1;
  if (encoded < 0 || encoded > 7) return null;
  return ((encoded & 1) ? FLAG_SHIFT : 0) |
    ((encoded & 2) ? FLAG_ALT : 0) |
    ((encoded & 4) ? FLAG_CONTROL : 0);
}

function csiKey(body, final) {
  let base;
  if (final === "A") base = XK_UP;
  else if (final === "B") base = XK_DOWN;
  else if (final === "C") base = XK_RIGHT;
  else if (final === "D") base = XK_LEFT;
  else if (final === "H") base = XK_HOME;
  else if (final === "F") base = XK_END;
  else if (final === "Z" && body === "") return { keysym: XK_TAB, flags: FLAG_SHIFT };
  if (base !== undefined) {
    if (body === "") return { keysym: base, flags: 0 };
    const match = /^(?:1)?;(\d+)$/.exec(body);
    if (!match) return null;
    const flags = modifierFlags(Number(match[1]));
    return flags === null ? null : { keysym: base, flags };
  }
  if (final !== "~") return null;
  const match = /^(\d+)(?:;(\d+))?$/.exec(body);
  if (!match) return null;
  const number = Number(match[1]);
  const keys = new Map([
    [1, XK_HOME], [2, XK_INSERT], [3, XK_DELETE], [4, XK_END],
    [5, XK_PAGE_UP], [6, XK_PAGE_DOWN], [7, XK_HOME], [8, XK_END],
    [11, XK_F1], [12, XK_F1 + 1], [13, XK_F1 + 2], [14, XK_F1 + 3],
    [15, XK_F1 + 4], [17, XK_F1 + 5], [18, XK_F1 + 6], [19, XK_F1 + 7],
    [20, XK_F1 + 8], [21, XK_F1 + 9], [23, XK_F1 + 10], [24, XK_F1 + 11],
  ]);
  const keysym = keys.get(number);
  if (keysym === undefined) return null;
  const flags = match[2] === undefined ? 0 : modifierFlags(Number(match[2]));
  return flags === null ? null : { keysym, flags };
}

function decodeCodepoint(buffer, offset) {
  const width = utf8SequenceLength(buffer[offset]);
  if (width === 0) return { invalid: true, consumed: 1 };
  if (offset + width > buffer.length) return { incomplete: true };
  try {
    const text = decoder.decode(buffer.subarray(offset, offset + width));
    return { keysym: text.codePointAt(0), consumed: width };
  } catch {
    return { invalid: true, consumed: 1 };
  }
}

function printableFlags(keysym) {
  return keysym >= 0x41 && keysym <= 0x5a ? FLAG_SHIFT : 0;
}

function decodeOne(buffer, final) {
  if (buffer.length === 0) return { incomplete: true };
  const first = buffer[0];
  if (first === 0x1b) {
    if (buffer.length === 1) return final
      ? { event: { keysym: XK_ESCAPE, flags: 0 }, consumed: 1 }
      : { incomplete: true };
    if (buffer[1] === 0x5b) {
      let end = 2;
      while (end < buffer.length && !(buffer[end] >= 0x40 && buffer[end] <= 0x7e)) end += 1;
      if (end === buffer.length) {
        if (!final) return { incomplete: true };
        if (buffer.length === 2) return { event: { keysym: 0x5b, flags: FLAG_ALT }, consumed: 2 };
        return { event: { keysym: XK_ESCAPE, flags: 0 }, consumed: 1 };
      }
      const body = decoder.decode(buffer.subarray(2, end));
      if (body === "200" && buffer[end] === 0x7e) return { pasteStart: true, consumed: end + 1 };
      return { event: csiKey(body, String.fromCharCode(buffer[end])), consumed: end + 1 };
    }
    if (buffer[1] === 0x4f) {
      if (buffer.length < 3) return final
        ? { event: { keysym: XK_ESCAPE, flags: 0 }, consumed: 1 }
        : { incomplete: true };
      const key = { P: 0, Q: 1, R: 2, S: 3 }[String.fromCharCode(buffer[2])];
      return { event: key === undefined ? null : { keysym: XK_F1 + key, flags: 0 }, consumed: 3 };
    }
    const decoded = decodeCodepoint(buffer, 1);
    if (decoded.incomplete && !final) return decoded;
    if (decoded.keysym !== undefined) {
      return { event: { keysym: decoded.keysym, flags: FLAG_ALT | printableFlags(decoded.keysym) }, consumed: decoded.consumed + 1 };
    }
    return { event: { keysym: XK_ESCAPE, flags: 0 }, consumed: 1 };
  }
  if (first === 0x08 || first === 0x7f) return { event: { keysym: XK_BACKSPACE, flags: 0 }, consumed: 1 };
  if (first === 0x09) return { event: { keysym: XK_TAB, flags: 0 }, consumed: 1 };
  if (first === 0x0a || first === 0x0d) return { event: { keysym: XK_RETURN, flags: 0 }, consumed: 1 };
  if (first >= 1 && first <= 26) {
    return { event: { keysym: 0x60 + first, flags: FLAG_CONTROL }, consumed: 1 };
  }
  if (first < 0x20) return { event: null, consumed: 1 };
  const decoded = decodeCodepoint(buffer, 0);
  if (decoded.incomplete && !final) return decoded;
  return {
    event: decoded.keysym === undefined ? null : { keysym: decoded.keysym, flags: printableFlags(decoded.keysym) },
    text: decoded.keysym === undefined ? undefined : String.fromCodePoint(decoded.keysym),
    consumed: decoded.consumed ?? 1,
  };
}

export class TerminalKeyDecoder {
  constructor(emit, { text = null, paste = null, pasteCapacity = 0 } = {}) {
    this.emit = emit;
    this.emitText = text;
    this.emitPaste = paste;
    this.pasteCapacity = pasteCapacity;
    this.pasteChunks = null;
    this.pasteSize = 0;
    this.pending = new Uint8Array();
  }

  push(chunk) {
    const incoming = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk);
    const joined = new Uint8Array(this.pending.length + incoming.length);
    joined.set(this.pending);
    joined.set(incoming, this.pending.length);
    this.pending = joined;
    this.#drain(false);
    return this.pending.length > 0;
  }

  flush() {
    this.#drain(true);
  }

  #drain(final) {
    while (this.pending.length > 0) {
      if (this.pasteChunks !== null) {
        const endMarker = Buffer.from("\x1b[201~");
        const end = Buffer.from(this.pending).indexOf(endMarker);
        const consumed = end >= 0 ? end : Math.max(0, this.pending.length - endMarker.length + 1);
        const kept = Math.min(consumed, Math.max(0, this.pasteCapacity - this.pasteSize));
        if (kept) this.pasteChunks.push(this.pending.slice(0, kept));
        this.pasteSize += consumed;
        this.pending = this.pending.subarray(consumed + (end >= 0 ? endMarker.length : 0));
        if (end < 0) return;
        const bytes = Buffer.concat(this.pasteChunks);
        const exceeded = this.pasteSize > this.pasteCapacity;
        this.pasteChunks = null;
        this.pasteSize = 0;
        this.emitPaste(bytes, exceeded);
        continue;
      }
      const decoded = decodeOne(this.pending, final);
      if (decoded.incomplete) return;
      this.pending = this.pending.subarray(decoded.consumed);
      if (decoded.pasteStart && this.emitPaste) this.pasteChunks = [];
      if (decoded.text !== undefined && this.emitText) this.emitText(decoded.text);
      else if (decoded.event) this.emit(decoded.event);
    }
  }
}

const MAX_DOWNLOAD = 16 * 1024 * 1024;

export function hostedPath(value) {
  if (value.startsWith("./") || value.startsWith("../") || isAbsolute(value)) return null;
  const slash = value.indexOf("/");
  if (slash < 0) return null;
  const host = value.slice(0, slash).toLowerCase();
  if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+(?::[1-9][0-9]{0,4})?$/.test(host)) return null;
  const port = host.lastIndexOf(":");
  if (port !== -1 && Number(host.slice(port + 1)) > 65535) throw new Error(`invalid host port in ${value}`);
  const path = value.slice(slash + 1);
  if (path.includes("\\") || /[?#\x00-\x1f\x7f]/.test(path) ||
      path.split("/").some((segment) => !segment || segment === "." || segment === "..")) {
    throw new Error(`invalid hosted component path ${value}`);
  }
  if (!path.endsWith(".wasm")) {
    throw new Error(`hosted component path ${value} must end in .wasm; check the filename on ${host}`);
  }
  return { host, path };
}

async function download(host, path) {
  const origin = `https://${host}`;
  let url = `${origin}/${path.split("/").map(encodeURIComponent).join("/")}`;
  const signal = AbortSignal.timeout(30_000);
  for (let redirects = 0; redirects <= 2; redirects += 1) {
    const response = await fetch(url, { redirect: "manual", signal });
    if (response.status >= 300 && response.status <= 399) {
      if (redirects === 2) throw new Error(`${url} redirected too many times`);
      const location = response.headers.get("location");
      if (!location) throw new Error(`${url} redirected without Location`);
      const next = new URL(location, url);
      if (next.protocol !== "https:" || next.origin !== origin || next.username || next.password) {
        throw new Error(`${url} redirected outside its HTTPS origin`);
      }
      await response.body?.cancel();
      url = next.href;
      continue;
    }
    if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
    if (Number(response.headers.get("content-length")) > MAX_DOWNLOAD) throw new Error(`${url} exceeds 16 MiB`);
    const chunks = [];
    let length = 0;
    for await (const chunk of response.body ?? []) {
      length += chunk.byteLength;
      if (length > MAX_DOWNLOAD) throw new Error(`${url} exceeds 16 MiB`);
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, length);
  }
}

function missingFileError(error) {
  return error?.code === "ENOENT" || error?.code === "ENOTDIR";
}

// hosts is one host or a list. Like qipx and qipok, each missing relative file tries the hosts
// in order, so components in one pipeline may come from different hosts.
export async function loadWasm(value, validate, hosts = []) {
  hosts = (typeof hosts === "string" ? [hosts] : hosts).filter(Boolean);
  const explicit = hostedPath(value);
  const relative = !explicit && hosts.length && !value.startsWith("./") && !value.startsWith("../") && !isAbsolute(value)
    ? hosts.map((host) => hostedPath(`${host}/${value}`)).filter(Boolean)
    : [];
  let data;
  if (explicit) {
    data = await download(explicit.host, explicit.path);
  } else if (relative.length) {
    // A leading host only supplies relative files that are missing locally.
    try {
      data = await readFile(value);
    } catch (error) {
      if (!missingFileError(error)) throw error;
      const failures = [];
      for (const source of relative) {
        try {
          data = await download(source.host, source.path);
          break;
        } catch (failure) {
          failures.push(failure.message ?? String(failure));
        }
      }
      if (!data) {
        throw new Error(failures.length === 1 ? failures[0] : `${value} is unavailable from every host (${failures.join("; ")})`);
      }
    }
  } else {
    data = await readFile(value);
  }
  validate(data);
  return data;
}

export function wasmHeader(data) {
  if (data.length < 8 || !data.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) {
    throw new Error("file is not a WebAssembly 1.0 module");
  }
}

// Uniform parsing matches @qip.dev/qipx and the Go CLI: each value is parsed for its setter's
// parameter type and rejected unless that type holds it exactly, so nothing is truncated,
// wrapped, or rounded to Infinity.
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

// Wasm i64 parameters only accept a BigInt: signed decimal or 0x hex within the i64 range.
function parseUniformI64(value) {
  const match = /^([-+]?)(0x[0-9a-f]+|\d+)$/i.exec(String(value).trim());
  if (match) {
    const magnitude = BigInt(match[2]);
    const parsed = match[1] === "-" ? -magnitude : magnitude;
    if (parsed >= minI64 && parsed <= maxI64) return parsed;
  }
  throw new Error(`uniform value ${JSON.stringify(value)} is not an i64 integer`);
}

// i32 uniforms are unsigned: exact decimal or 0x hex integers from 0 to 2^32 - 1.
function parseUniformU32(value) {
  const trimmed = String(value).trim();
  if (/^(?:0x[0-9a-f]+|\d+)$/i.test(trimmed)) {
    const parsed = BigInt(trimmed);
    if (parsed <= 0xffffffffn) return Number(parsed);
  }
  throw new Error(`uniform value ${JSON.stringify(value)} is not an unsigned i32 integer`);
}

function parseUniformFloat(value, f32) {
  const parsed = parseUniformValue(value);
  if (!Number.isFinite(f32 ? Math.fround(parsed) : parsed)) {
    throw new Error(`uniform value ${JSON.stringify(value)} is not a finite ${f32 ? "f32" : "f64"} number`);
  }
  return parsed;
}

function uniformArgument(stage, key, rawValue) {
  const params = stage.component.uniformParamTypes.get(key);
  if (params === undefined || params.length !== 1) throw new Error(`${stage.label} uniform_set_${key} must accept exactly one argument`);
  switch (params[0]) {
    case 0x7f: return parseUniformU32(rawValue);
    case 0x7e: return parseUniformI64(rawValue);
    case 0x7d: return parseUniformFloat(rawValue, true);
    case 0x7c: return parseUniformFloat(rawValue, false);
    default: throw new Error(`${stage.label} uniform_set_${key} has an unsupported parameter type`);
  }
}

// Maps each uniform key to its uniform_set_* parameter types, decoded from the type, function
// and export sections. The JS API does not expose a function's signature, and the setter's
// parameter type decides whether it takes a Number or a BigInt. Components must not import,
// so function indices are function-section indices.
export function readUniformParamTypes(wasm, label = "component") {
  const types = [];
  let functionTypes = [];
  const setters = [];
  let offset = 8;
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    offset = readULEB(wasm, offset);
    const sectionEnd = offset + lebValue;
    if (sectionID === 1) {
      let cursor = readULEB(wasm, offset);
      for (let count = lebValue; count > 0; count -= 1) {
        cursor = readULEB(wasm, cursor + 1);
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
        cursor = readULEB(wasm, cursor);
        const nameEnd = cursor + lebValue;
        const name = decoder.decode(wasm.subarray(cursor, nameEnd));
        const kind = wasm[nameEnd];
        cursor = readULEB(wasm, nameEnd + 1);
        if (kind === 0x00 && name.startsWith("uniform_set_")) setters.push([name, lebValue]);
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

// Maps each uniform key to the export that sets it. A setter export is uniform_set_<key>,
// optionally followed by "__" and a suffix reserved for declaring the uniform's maxima, so
// hosts match on <key> alone. A module that exports two setters for one key is rejected.
export function uniformSetterNames(exportNames, label = "component") {
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

// Parses -u values once, before the terminal is taken over, so a bad value fails up front.
export function parseUniforms(stage) {
  const parsed = new Map();
  const setters = uniformSetterNames(Object.keys(stage.component.exports), stage.label);
  for (const value of stage.uniforms) {
    const at = value.indexOf("=");
    const key = at < 0 ? value : value.slice(0, at);
    if (at < 1 || !validUniformKey(key)) throw new Error(`invalid uniform ${value}`);
    if (typeof stage.component.exports[setters.get(key)] !== "function") throw new Error(`${stage.label} does not export uniform_set_${key}`);
    parsed.set(key, uniformArgument(stage, key, value.slice(at + 1)));
  }
  return parsed;
}

export function applyUniforms(stage, dimensions) {
  const settings = new Map();
  const setters = uniformSetterNames(Object.keys(stage.component.exports), stage.label);
  for (const [key, value] of [["columns", dimensions.columns], ["lines", dimensions.lines]]) {
    if (typeof stage.component.exports[setters.get(key)] === "function") settings.set(key, uniformArgument(stage, key, String(value)));
  }
  for (const [key, value] of stage.uniformArguments) settings.set(key, value);
  for (const [key, value] of settings) stage.component.exports[setters.get(key)](value);
}

const staticExportNames = new Set([
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
]);

// readULEB leaves the decoded value in lebValue and returns the offset after it; skipLEB
// steps over signed or unsigned values whose magnitude does not matter.
let lebValue = 0;

function readULEB(wasm, offset) {
  let value = 0;
  let scale = 1;
  let byte;
  do {
    byte = wasm[offset++];
    value += (byte & 0x7f) * scale;
    scale *= 128;
  } while (byte & 0x80);
  lebValue = value;
  return offset;
}

function skipLEB(wasm, offset) {
  while (wasm[offset++] & 0x80);
  return offset;
}

function skipBlockType(wasm, offset) {
  const byte = wasm[offset];
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

// Steps over one instruction. Sets bodyIsDynamic when the instruction disqualifies the
// enclosing function from being a static getter: control flow, calls, locals, globals,
// memory, or tables.
let bodyIsDynamic = false;

function skipInstruction(wasm, offset, label) {
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
    case 0x23: // global.get: allowed in static getters, matching qipx
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
      if (sub <= 7) return offset; // trunc_sat has no immediates
      if (sub === 8 || sub === 10 || sub === 12 || sub === 14) return skipLEB(wasm, skipLEB(wasm, offset));
      return skipLEB(wasm, offset);
    }
    case 0xfd:
      return skipSIMDInstruction(wasm, offset, label);
    case 0xfe:
      throw new Error(`${label} uses atomic instructions, which are outside the Strict Wasm Profile`);
    default:
      if (opcode >= 0x28 && opcode <= 0x3e) { // loads and stores
        bodyIsDynamic = true;
        return skipMemarg(wasm, offset);
      }
      if (opcode >= 0x45 && opcode <= 0xc4) return offset; // numeric, including sign extension
      throw new Error(`${label} uses unsupported Wasm opcode 0x${opcode.toString(16)} at byte offset ${offset - 1}`);
  }
}

// Pre-execution checks, matching @qip.dev/qipx: one memory with a finite, unshared maximum
// no larger than maxMemory, no imports, no start function, no memory.grow, no atomics, only
// Strict Wasm Profile opcodes, and static Content ABI getters. Each host sets its own limit.
//
// The engine compiles the module before this scan runs, so the bytes are known to be well
// formed: LEB128 values are complete, sections and bodies are in bounds, and every opcode is
// one the engine accepts. The scan therefore reads plain Numbers, walks the code section
// once, and never re-checks structure. The one structural assertion left, that a body ends
// where its size says, guards against a decoding mistake in this file rather than bad input.
export function validateStrictProfile(wasm, label, { maxMemory }) {
  if (!Number.isSafeInteger(maxMemory) || maxMemory <= 0) throw new Error("validateStrictProfile needs a maxMemory limit in bytes");
  let offset = 8;
  let memories = 0;
  const staticExports = [];
  let dynamicFunctions = null;
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    offset = readULEB(wasm, offset);
    const sectionEnd = offset + lebValue;
    if (sectionID === 2) {
      readULEB(wasm, offset);
      if (lebValue !== 0) throw new Error(`${label} imports host functions or state, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 5) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      memories += count;
      for (let index = 0; index < count; index += 1) {
        const flags = wasm[cursor++];
        cursor = skipLEB(wasm, cursor);
        if ((flags & 1) === 0 || (flags & 2) !== 0) throw new Error(`${label} memory needs a finite, unshared maximum`);
        cursor = readULEB(wasm, cursor);
        if (lebValue * 65536 > maxMemory) throw new Error(`${label} memory maximum exceeds ${maxMemory / 1024 / 1024} MiB`);
      }
    } else if (sectionID === 7) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      for (let index = 0; index < count; index += 1) {
        cursor = readULEB(wasm, cursor);
        const nameEnd = cursor + lebValue;
        const name = decoder.decode(wasm.subarray(cursor, nameEnd));
        const kind = wasm[nameEnd];
        cursor = readULEB(wasm, nameEnd + 1);
        if (staticExportNames.has(name)) {
          if (kind !== 0x00) throw new Error(`${label} export ${name} must be a function`);
          staticExports.push(lebValue);
        }
      }
    } else if (sectionID === 8) {
      throw new Error(`${label} declares a start function, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 10) {
      let cursor = readULEB(wasm, offset);
      const count = lebValue;
      dynamicFunctions = new Uint8Array(count);
      for (let funcIndex = 0; funcIndex < count; funcIndex += 1) {
        cursor = readULEB(wasm, cursor);
        const bodyEnd = cursor + lebValue;
        cursor = readULEB(wasm, cursor);
        for (let groups = lebValue; groups > 0; groups -= 1) cursor = skipLEB(wasm, cursor) + 1;
        bodyIsDynamic = false;
        while (cursor < bodyEnd) cursor = skipInstruction(wasm, cursor, label);
        if (cursor !== bodyEnd) throw new Error(`${label} function body is malformed`);
        dynamicFunctions[funcIndex] = bodyIsDynamic ? 1 : 0;
      }
    }
    offset = sectionEnd;
  }
  if (memories !== 1) throw new Error(`${label} must declare one memory`);
  for (const index of staticExports) {
    if (dynamicFunctions === null || dynamicFunctions[index] !== 0) throw new Error("comply: static qip contract checks failed");
  }
}
