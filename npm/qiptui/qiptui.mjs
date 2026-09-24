#!/usr/bin/env node

import process from "node:process";
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";

const decoder = new TextDecoder("utf-8", { fatal: true });

const FLAG_KEY_DOWN = 1 << 0;
const FLAG_SHIFT = 1 << 2;
const FLAG_CONTROL = 1 << 3;
const FLAG_ALT = 1 << 4;

const XK_BACKSPACE = 0xff08;
const XK_TAB = 0xff09;
const XK_RETURN = 0xff0d;
const XK_ESCAPE = 0xff1b;
const XK_HOME = 0xff50;
const XK_LEFT = 0xff51;
const XK_UP = 0xff52;
const XK_RIGHT = 0xff53;
const XK_DOWN = 0xff54;
const XK_PAGE_UP = 0xff55;
const XK_PAGE_DOWN = 0xff56;
const XK_END = 0xff57;
const XK_INSERT = 0xff63;
const XK_DELETE = 0xffff;
const XK_F1 = 0xffbe;

const ENTER_SCREEN = "\x1b[?1049h\x1b[?25l";
const LEAVE_SCREEN = "\x1b[0m\x1b[?25h\x1b[?1049l";
const REDRAW_PREFIX = "\x1b[H\x1b[J";
const REDRAW_SUFFIX = "\x1b[0m\x1b[J";

const allowedSGRParameters = new Set([
  0, 1, 2, 4, 22, 24,
  30, 31, 32, 33, 34, 35, 36, 37, 39,
  40, 41, 42, 43, 44, 45, 46, 47, 49,
  90, 91, 92, 93, 94, 95, 96, 97,
  100, 101, 102, 103, 104, 105, 106, 107,
]);

function utf8SequenceLength(first) {
  if (first < 0x80) return 1;
  if (first >= 0xc2 && first <= 0xdf) return 2;
  if (first >= 0xe0 && first <= 0xef) return 3;
  if (first >= 0xf0 && first <= 0xf4) return 4;
  return 0;
}

export function validateTerminalFrame(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  decoder.decode(bytes);
  for (let index = 0; index < bytes.length;) {
    const byte = bytes[index];
    if (byte === 0x1b) {
      if (bytes[index + 1] !== 0x5b) throw new Error(`terminal output contains unsupported ESC sequence at byte ${index}`);
      let end = index + 2;
      while (end < bytes.length && bytes[end] !== 0x6d) {
        const current = bytes[end];
        if (!((current >= 0x30 && current <= 0x39) || current === 0x3b)) {
          throw new Error(`terminal output contains unsupported CSI sequence at byte ${index}`);
        }
        end += 1;
      }
      if (end >= bytes.length) throw new Error(`terminal output contains incomplete SGR sequence at byte ${index}`);
      const source = decoder.decode(bytes.subarray(index + 2, end));
      const parameters = source === "" ? [0] : source.split(";").map((part) => part === "" ? 0 : Number(part));
      if (parameters.length > 16 || parameters.some((parameter) => !allowedSGRParameters.has(parameter))) {
        throw new Error(`terminal output contains unsupported SGR parameters at byte ${index}`);
      }
      index = end + 1;
      continue;
    }
    if (byte < 0x20) {
      if (byte !== 0x0a) throw new Error(`terminal output contains control byte 0x${byte.toString(16).padStart(2, "0")} at byte ${index}`);
      index += 1;
      continue;
    }
    if (byte === 0x7f) throw new Error(`terminal output contains DEL at byte ${index}`);
    const width = utf8SequenceLength(byte);
    if (width === 0 || index + width > bytes.length) throw new Error(`terminal output contains invalid UTF-8 at byte ${index}`);
    if (width > 1) {
      const character = decoder.decode(bytes.subarray(index, index + width));
      const codepoint = character.codePointAt(0);
      if (codepoint >= 0x80 && codepoint <= 0x9f) {
        throw new Error(`terminal output contains C1 control U+${codepoint.toString(16).padStart(4, "0")} at byte ${index}`);
      }
    }
    index += width;
  }
  return bytes;
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
    consumed: decoded.consumed ?? 1,
  };
}

export class TerminalKeyDecoder {
  constructor(emit) {
    this.emit = emit;
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
      const decoded = decodeOne(this.pending, final);
      if (decoded.incomplete) return;
      this.pending = this.pending.subarray(decoded.consumed);
      if (decoded.event) this.emit(decoded.event);
    }
  }
}

function requireFunction(exports, name, arity) {
  const fn = exports[name];
  if (typeof fn !== "function" || fn.length !== arity) {
    throw new Error(`TUI component must export ${name}(${arity === 0 ? "" : arity === 1 ? "value" : "x11_key, flags"})`);
  }
  return fn;
}

function unpackRender(stage, packed) {
  if (typeof packed !== "bigint") throw new Error(`${stage.label} render must return i64`);
  const bits = BigInt.asUintN(64, packed);
  const size = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) throw new Error(`${stage.label} rejected its initial input`);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  if (size > stage.outputCapacity || pointer + size > stage.component.exports.memory.buffer.byteLength) {
    throw new Error(`${stage.label} returned output outside its declared capacity`);
  }
  return new Uint8Array(stage.component.exports.memory.buffer, pointer, size).slice();
}

function writeInitialInput(stage, input) {
  if (stage.inputless) {
    if (input.byteLength !== 0) throw new Error(`${stage.label} is inputless and cannot receive TUI input`);
    return;
  }
  const pointerValue = stage.component.exports.input_ptr;
  const pointer = typeof pointerValue === "function" ? pointerValue() : pointerValue.value;
  if (input.byteLength > stage.inputCapacity || pointer + input.byteLength > stage.component.exports.memory.buffer.byteLength) {
    throw new Error(`${stage.label} input exceeds its capacity`);
  }
  new Uint8Array(stage.component.exports.memory.buffer, pointer, input.byteLength).set(input);
}

function logicalNow(startedAt, previous) {
  return Math.max(Math.floor(performance.now() - startedAt) + 1, previous + 1);
}

export async function runTUI({ stage, input, applyUniforms, stdin = process.stdin, stdout = process.stdout }) {
  if (!stdin.isTTY || !stdout.isTTY || typeof stdin.setRawMode !== "function") {
    throw new Error("qiptui requires terminal stdin and stdout");
  }
  const exports = stage.component.exports;
  const beginUpdate = requireFunction(exports, "begin_update_at", 1);
  const finishUpdate = requireFunction(exports, "finish_update", 0);
  const keyEvent = requireFunction(exports, "key_event", 2);
  const source = input instanceof Uint8Array ? input : new Uint8Array(input);
  writeInitialInput(stage, source);
  const wasRaw = Boolean(stdin.isRaw);
  let terminalActive = false;
  let lastUpdate = 0;
  let nextWake = 0;
  let wakeTimer = null;
  let escapeTimer = null;
  let settled = false;
  let rendering = false;
  const startedAt = performance.now();

  const size = () => ({ columns: stdout.columns || 80, lines: stdout.rows || 24 });
  const enterTerminal = () => {
    if (!wasRaw) stdin.setRawMode(true);
    stdin.resume();
    stdout.write(ENTER_SCREEN);
    terminalActive = true;
  };
  const leaveTerminal = () => {
    if (terminalActive) stdout.write(LEAVE_SCREEN);
    terminalActive = false;
    if (!wasRaw && stdin.isTTY) stdin.setRawMode(false);
  };

  const renderFrame = (initial = false) => {
    if (rendering) return;
    rendering = true;
    try {
      const dimensions = size();
      applyUniforms(stage, dimensions);
      const packed = exports.render(initial ? (stage.inputless ? 0 : source.byteLength) : 0);
      const safe = validateTerminalFrame(unpackRender(stage, packed));
      stdout.write(REDRAW_PREFIX);
      stdout.write(safe);
      stdout.write(REDRAW_SUFFIX);
    } finally {
      rendering = false;
    }
  };

  const scheduleWake = () => {
    if (wakeTimer !== null) clearTimeout(wakeTimer);
    wakeTimer = null;
    if (nextWake <= lastUpdate) return;
    const elapsed = Math.floor(performance.now() - startedAt) + 1;
    wakeTimer = setTimeout(() => {
      wakeTimer = null;
      try {
        runUpdate([], true, nextWake);
      } catch (error) {
        fail(error);
      }
    }, Math.max(0, nextWake - elapsed));
  };

  const runUpdate = (events, forceRender = false, requestedTime = 0) => {
    const now = Math.max(logicalNow(startedAt, lastUpdate), requestedTime);
    beginUpdate(BigInt(now));
    applyUniforms(stage, size());
    let accepted = false;
    for (const event of events) {
      accepted = keyEvent(event.keysym, event.flags | FLAG_KEY_DOWN) === 1 || accepted;
      accepted = keyEvent(event.keysym, event.flags) === 1 || accepted;
    }
    const wake = finishUpdate();
    if (typeof wake !== "bigint") throw new Error(`${stage.label} finish_update must return i64`);
    nextWake = Number(wake);
    if (!Number.isSafeInteger(nextWake) || nextWake < now) throw new Error(`${stage.label} returned an invalid wake time`);
    lastUpdate = now;
    if (accepted || forceRender) renderFrame(false);
    scheduleWake();
  };

  let resolveDone;
  let rejectDone;
  const done = new Promise((resolve, reject) => {
    resolveDone = resolve;
    rejectDone = reject;
  });
  const finish = (code = 0) => {
    if (settled) return;
    settled = true;
    process.exitCode = code || process.exitCode;
    resolveDone();
  };
  const fail = (error) => {
    if (settled) return;
    settled = true;
    rejectDone(error);
  };

  const suspend = () => {
    if (process.platform === "win32") return;
    leaveTerminal();
    process.kill(process.pid, "SIGTSTP");
    enterTerminal();
    renderFrame(false);
  };
  const onKey = (event) => {
    if ((event.flags & FLAG_CONTROL) !== 0 && event.keysym === 0x63) return finish();
    if ((event.flags & FLAG_CONTROL) !== 0 && event.keysym === 0x7a) return suspend();
    if ((event.flags & FLAG_CONTROL) !== 0 && (event.keysym === 0x71 || event.keysym === 0x73)) return;
    try {
      runUpdate([event]);
    } catch (error) {
      fail(error);
    }
  };
  const keyDecoder = new TerminalKeyDecoder(onKey);
  const armEscapeTimer = () => {
    if (escapeTimer !== null) clearTimeout(escapeTimer);
    escapeTimer = setTimeout(() => {
      escapeTimer = null;
      keyDecoder.flush();
    }, 30);
  };
  const onData = (chunk) => {
    if (keyDecoder.push(chunk)) armEscapeTimer();
    else if (escapeTimer !== null) {
      clearTimeout(escapeTimer);
      escapeTimer = null;
    }
  };
  const onResize = () => {
    try {
      renderFrame(false);
    } catch (error) {
      fail(error);
    }
  };
  const signals = [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]].map(
    ([signal, code]) => [signal, () => finish(code)],
  );

  enterTerminal();
  stdin.on("data", onData);
  stdout.on("resize", onResize);
  for (const [signal, handler] of signals) process.on(signal, handler);
  try {
    renderFrame(true);
    runUpdate([]);
    await done;
  } finally {
    if (wakeTimer !== null) clearTimeout(wakeTimer);
    if (escapeTimer !== null) clearTimeout(escapeTimer);
    stdin.off("data", onData);
    stdout.off("resize", onResize);
    for (const [signal, handler] of signals) process.off(signal, handler);
    stdin.pause();
    leaveTerminal();
  }
}

const MAX_DOWNLOAD = 16 * 1024 * 1024;
const MAX_MEMORY = 256 * 1024 * 1024;

function usage() {
  return `Usage: qiptui [host] [options] <component.wasm | host/path.wasm>\n\n` +
    `  -i, --input <file>        Initial input file\n` +
    `  -F, --form <name=value>  Add a multipart field (repeatable)\n` +
    `  -u, --uniform <name=n>   Set a numeric component uniform\n` +
    `  -h, --help               Show this help\n\n` +
    `Multipart fields:\n` +
    `  -F name=value            UTF-8 text field\n` +
    `  -F name=@path            Exact file bytes with the basename as filename\n` +
    `  -F 'name=<path'          Exact file bytes as a regular field, without filename\n` +
    `@path sends Content-Type: application/octet-stream; <path omits that part header.\n` +
    `  -F name=@- and -F 'name=<-' are unavailable: stdin carries terminal keys.\n` +
    `Quote arguments containing < in a shell.\n\n` +
    `Examples:\n` +
    `  qiptui qip.dev/interactive/calendar-gregorian.wasm\n` +
    `  qiptui -F 'component=@text/wc.wasm' components/interactive/qipdb.wasm\n` +
    `  qiptui -F 'component=<text/wc.wasm' components/interactive/qipdb.wasm\n\n` +
    `A leading host or a hosted path such as qip.dev/interactive/calendar-gregorian.wasm uses HTTPS.\n` +
    `Hosted components are downloaded into memory for each run.\n`;
}

export function parseArgs(args) {
  let component;
  let host = "";
  let input;
  const forms = [];
  const uniforms = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "-h" || arg === "--help") return { help: true };
    if (arg === "-i" || arg === "--input" || arg === "-F" || arg === "--form" || arg === "-u" || arg === "--uniform") {
      const value = args[++index];
      if (value === undefined) throw new Error(`${arg} requires a value`);
      if (arg === "-i" || arg === "--input") input = value;
      else if (arg === "-F" || arg === "--form") forms.push(value);
      else uniforms.push(value);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option ${arg}`);
    } else if (component === undefined && !arg.endsWith(".wasm") && !arg.includes("/") && hostedPath(`${arg}/component.wasm`)) {
      if (host) throw new Error("qiptui accepts one host");
      host = arg.toLowerCase();
    } else if (component === undefined) {
      component = arg;
    } else {
      throw new Error("qiptui accepts one TUI component");
    }
  }
  if (!component) throw new Error("qiptui requires a component; run --help for usage");
  if (input && forms.length) throw new Error("-i and -F cannot be used together");
  if (input === "-") throw new Error("stdin carries terminal keys; use a file with -i");
  return { component, host, input, forms, uniforms };
}

function hostedPath(value) {
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

export async function loadWasm(value, validate, host = "") {
  const remote = hostedPath(value) ?? (host && !value.startsWith("./") && !value.startsWith("../") && !isAbsolute(value)
    ? hostedPath(`${host}/${value}`)
    : null);
  const data = remote ? await download(remote.host, remote.path) : await readFile(value);
  validate(data);
  return data;
}

function wasmHeader(data) {
  if (data.length < 8 || !data.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) {
    throw new Error("file is not a WebAssembly 1.0 module");
  }
}

function uleb(data, start) {
  let value = 0;
  let shift = 0;
  let cursor = start;
  while (cursor < data.length && shift <= 35) {
    const byte = data[cursor++];
    value += (byte & 127) * 2 ** shift;
    if (!(byte & 128)) return [value, cursor];
    shift += 7;
  }
  throw new Error("invalid WebAssembly section length");
}

function validateMemory(data) {
  wasmHeader(data);
  let offset = 8;
  let memories = 0;
  while (offset < data.length) {
    const id = data[offset++];
    const [size, body] = uleb(data, offset);
    const end = body + size;
    if (end > data.length) throw new Error("truncated WebAssembly section");
    if (id === 5) {
      let cursor = body;
      const [count, afterCount] = uleb(data, cursor);
      cursor = afterCount;
      memories += count;
      for (let index = 0; index < count; index += 1) {
        const [flags, afterFlags] = uleb(data, cursor);
        const [, afterMin] = uleb(data, afterFlags);
        cursor = afterMin;
        if ((flags & 1) === 0 || (flags & 2) !== 0) throw new Error("TUI memory needs a finite, unshared maximum");
        const [maximum, afterMax] = uleb(data, cursor);
        cursor = afterMax;
        if (maximum * 65536 > MAX_MEMORY) throw new Error("TUI memory maximum exceeds 256 MiB");
      }
    }
    offset = end;
  }
  if (memories !== 1) throw new Error("TUI component must declare one memory");
}

function field(value) {
  const at = value.indexOf("=");
  if (at < 1) throw new Error(`invalid form field ${value}`);
  const name = value.slice(0, at);
  if (!/^[\x20-\x21\x23-\x5b\x5d-\x7e]+$/.test(name)) throw new Error(`invalid form field name ${name}`);
  const raw = value.slice(at + 1);
  return { name, raw };
}

const FORM_BOUNDARY = "uuid-00000000-0000-0000-0000-000000000000";
const FORM_CONTENT_TYPE = `multipart/form-data;boundary=${FORM_BOUNDARY}`;

export async function multipart(values, host = "") {
  const boundary = FORM_BOUNDARY;
  const chunks = [];
  for (const value of values) {
    const { name, raw } = field(value);
    const fileMode = raw[0] === "@" || raw[0] === "<" ? raw[0] : "";
    const path = fileMode ? raw.slice(1) : "";
    if (fileMode && (!path || path === "-")) throw new Error("form files need a path; stdin carries terminal keys");
    const filename = fileMode === "@" ? basename(hostedPath(path)?.path ?? path) : "";
    if (filename && !/^[\x20-\x21\x23-\x5b\x5d-\x7e]+$/.test(filename)) throw new Error(`invalid form filename ${filename}`);
    const body = fileMode
      ? (path.endsWith(".wasm") ? await loadWasm(path, wasmHeader, host) : await readFile(path))
      : Buffer.from(raw);
    if (body.includes(Buffer.from(`\r\n--${boundary}`))) throw new Error(`form field ${name} contains the multipart boundary`);
    const header = `--${boundary}\r\nContent-Disposition: form-data; name="${name}"` +
      (fileMode === "@" ? `; filename="${filename}"\r\nContent-Type: application/octet-stream` : "") + "\r\n\r\n";
    chunks.push(Buffer.from(header), body, Buffer.from("\r\n"));
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

function applyUniforms(stage, dimensions) {
  const settings = new Map();
  for (const [key, value] of [["columns", dimensions.columns], ["lines", dimensions.lines]]) {
    if (typeof stage.component.exports[`uniform_set_${key}`] === "function") settings.set(key, value);
  }
  for (const value of stage.uniforms) {
    const at = value.indexOf("=");
    const key = value.slice(0, at);
    const number = Number(value.slice(at + 1));
    if (at < 1 || !/^[a-z][a-z0-9_]*$/.test(key) || !Number.isFinite(number)) throw new Error(`invalid uniform ${value}`);
    settings.set(key, number);
  }
  for (const [key, value] of settings) {
    const setter = stage.component.exports[`uniform_set_${key}`];
    if (typeof setter !== "function") throw new Error(`${stage.label} does not export uniform_set_${key}`);
    setter(value);
  }
}

function declaredInputType(exports, label) {
  const pointer = exports.input_content_type_ptr;
  const size = exports.input_content_type_size;
  if (pointer === undefined && size === undefined) return "";
  if (typeof pointer !== "function" || typeof size !== "function" || pointer.length !== 0 || size.length !== 0) {
    throw new Error(`${label} has incomplete input content-type exports`);
  }
  const start = pointer() >>> 0;
  const length = size() >>> 0;
  const memory = exports.memory.buffer;
  if (start > memory.byteLength || length > memory.byteLength - start) {
    throw new Error(`${label} input content type is outside memory`);
  }
  const type = decoder.decode(new Uint8Array(memory, start, length));
  if (!/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(type) && type !== FORM_CONTENT_TYPE) {
    throw new Error(`${label} has invalid input content type ${JSON.stringify(type)}`);
  }
  return type;
}

function validateTUIBinary(data) {
  validateMemory(data);
  const module = new WebAssembly.Module(data);
  if (WebAssembly.Module.imports(module).length) throw new Error("TUI component must not import host functions or state");
  const exports = new Map(WebAssembly.Module.exports(module).map((entry) => [entry.name, entry.kind]));
  if (exports.get("memory") !== "memory") throw new Error("TUI component must export memory");
  for (const name of ["render", "begin_update_at", "finish_update", "key_event", "output_utf8_cap"]) {
    if (exports.get(name) !== "function") throw new Error(`TUI component must export ${name}`);
  }
  if (exports.has("output_bytes_cap")) throw new Error("TUI component must produce UTF-8");
}

export async function main(args = process.argv.slice(2)) {
  const options = parseArgs(args);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  const data = await loadWasm(options.component, validateTUIBinary, options.host);
  const module = new WebAssembly.Module(data);
  if (WebAssembly.Module.imports(module).length) throw new Error("TUI component must not import host functions or state");
  const exports = new WebAssembly.Instance(module).exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error("TUI component must export memory");
  requireFunction(exports, "render", 1);
  requireFunction(exports, "begin_update_at", 1);
  requireFunction(exports, "finish_update", 0);
  requireFunction(exports, "key_event", 2);
  if (typeof exports.output_utf8_cap !== "function" || typeof exports.output_bytes_cap === "function") {
    throw new Error("TUI component must export output_utf8_cap only");
  }
  const inputless = exports.input_ptr === undefined;
  const inputCapName = typeof exports.input_utf8_cap === "function" ? "input_utf8_cap" : "input_bytes_cap";
  if (inputless ? (typeof exports.input_utf8_cap === "function" || typeof exports.input_bytes_cap === "function") :
      (typeof exports.input_ptr !== "function" || Number(typeof exports.input_utf8_cap === "function") + Number(typeof exports.input_bytes_cap === "function") !== 1)) {
    throw new Error("TUI input pointer and capacity exports are invalid");
  }
  const stage = {
    label: options.component,
    component: { exports },
    inputless,
    inputCapacity: inputless ? 0 : exports[inputCapName](),
    outputCapacity: exports.output_utf8_cap(),
    uniforms: options.uniforms,
  };
  const inputType = declaredInputType(exports, options.component);
  if (options.forms.length && inputType && inputType !== FORM_CONTENT_TYPE) {
    throw new Error(`${options.component} expects ${inputType}, but -F supplies ${FORM_CONTENT_TYPE}`);
  }
  const input = options.forms.length ? await multipart(options.forms, options.host) : options.input ? await readFile(options.input) : new Uint8Array();
  await runTUI({
    stage, input,
    applyUniforms,
  });
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
