#!/usr/bin/env node

import process from "node:process";
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { ReadStream } from "node:tty";

import {
  applyUniforms,
  decoder,
  FLAG_ALT,
  FLAG_CONTROL,
  FLAG_KEY_DOWN,
  hostedPath,
  loadWasm,
  parseUniforms,
  readUniformParamTypes,
  TerminalKeyDecoder,
  uniformSetterNames,
  utf8SequenceLength,
  validateStrictProfile,
  wasmHeader,
  XK_BACKSPACE,
  XK_DELETE,
  XK_DOWN,
  XK_END,
  XK_HOME,
  XK_LEFT,
  XK_PAGE_DOWN,
  XK_PAGE_UP,
  XK_RIGHT,
  XK_UP,
} from "./qip-host.mjs";

// Re-exported so existing importers of qiptui.mjs keep working.
export { applyUniforms, loadWasm, parseUniforms, readUniformParamTypes, TerminalKeyDecoder, uniformSetterNames };

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
  if ((bits & (1n << 63n)) !== 0n) throw new Error(`${stage.label} rejected input`);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  if (size > stage.outputCapacity || pointer + size > stage.component.exports.memory.buffer.byteLength) {
    throw new Error(`${stage.label} returned output outside its declared capacity`);
  }
  return new Uint8Array(stage.component.exports.memory.buffer, pointer, size).slice();
}

// A plain-text Content transform opts into host editing by omitting events and
// declaring UTF-8 text/plain input. Navigation is an optional pair of exports.
export function textInputMode(exports, label = "TUI component") {
  const setters = uniformSetterNames(Object.keys(exports), label);
  const eventNames = ["begin_update_at", "finish_update", "key_event", "pointer_event"];
  if (eventNames.some((name) => exports[name] !== undefined)) {
    requireFunction(exports, "begin_update_at", 1);
    requireFunction(exports, "finish_update", 0);
    requireFunction(exports, "key_event", 2);
    return false;
  }
  requireFunction(exports, "input_ptr", 0);
  requireFunction(exports, "input_utf8_cap", 0);
  if (exports.input_bytes_cap !== undefined || declaredInputType(exports, label) !== "text/plain") {
    throw new Error(`${label} text input requires UTF-8 text/plain input`);
  }
  if (setters.has("active_index") || exports.active_count !== undefined) {
    requireFunction(exports, setters.get("active_index") ?? "uniform_set_active_index", 1);
    requireFunction(exports, "active_count", 0);
  }
  if (setters.has("detail_offset") || ["detail_count", "detail_page_size"].some((name) => exports[name] !== undefined)) {
    requireFunction(exports, setters.get("detail_offset") ?? "uniform_set_detail_offset", 1);
    requireFunction(exports, "detail_count", 0);
    requireFunction(exports, "detail_page_size", 0);
  }
  return true;
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const textEncoder = new TextEncoder();

export class TextInputState {
  constructor(value, capacity) {
    this.capacity = capacity;
    this.value = decoder.decode(value);
    if (value.byteLength > capacity) throw new Error("text input exceeds its UTF-8 byte capacity");
    if (/[\u0000-\u001f\u007f-\u009f]/u.test(this.value)) throw new Error("text input must be one printable line");
    this.cursor = this.value.length;
    this.activeIndex = 0;
    this.activeCount = 0;
    this.detailOffset = 0;
    this.detailCount = 0;
    this.detailPageSize = 0;
    this.error = "";
  }

  setActiveCount(count) {
    if (!Number.isInteger(count) || count < 0 || count > 0xffff_ffff) throw new Error("active_count must return a u32 result count");
    this.activeCount = count;
    this.activeIndex = Math.min(this.activeIndex, Math.max(0, count - 1));
  }

  setDetailWindow(count, pageSize) {
    for (const value of [count, pageSize]) {
      if (!Number.isInteger(value) || value < 0 || value > 0xffff_ffff) throw new Error("detail metadata must return u32 counts");
    }
    this.detailCount = count;
    this.detailPageSize = pageSize;
    this.detailOffset = Math.min(this.detailOffset, Math.max(0, count - pageSize));
  }

  insertText(text) {
    if (/[\u0000-\u001f\u007f-\u009f]/u.test(text)) {
      this.error = "Use one printable line";
      return true;
    }
    const value = this.value.slice(0, this.cursor) + text + this.value.slice(this.cursor);
    if (textEncoder.encode(value).byteLength > this.capacity) {
      this.error = `Input limit: ${this.capacity} UTF-8 bytes`;
      return true;
    }
    if (!text) return false;
    this.value = value;
    this.cursor += text.length;
    this.activeIndex = 0;
    this.detailOffset = 0;
    this.error = "";
    return true;
  }

  handleKey({ keysym, flags = 0 }) {
    const control = (flags & FLAG_CONTROL) !== 0;
    if ((flags & FLAG_ALT) !== 0) return false;
    const segments = [...graphemes.segment(this.value)];
    const previous = segments.findLast((part) => part.index < this.cursor)?.index ?? 0;
    const next = segments.find((part) => part.index >= this.cursor);
    const following = next ? next.index + next.segment.length : this.value.length;
    if (keysym === XK_PAGE_UP || keysym === XK_PAGE_DOWN) {
      if (!this.detailPageSize) return false;
      const offset = Math.max(0, Math.min(this.detailOffset + (keysym === XK_PAGE_UP ? -1 : 1) * this.detailPageSize,
        this.detailCount - this.detailPageSize));
      if (offset === this.detailOffset) return false;
      this.detailOffset = offset;
      return true;
    }
    if (keysym === XK_UP || keysym === XK_DOWN) {
      const index = Math.max(0, Math.min(this.activeIndex + (keysym === XK_UP ? -1 : 1), this.activeCount - 1));
      if (index === this.activeIndex) return false;
      this.activeIndex = index;
      this.detailOffset = 0;
      return true;
    }
    if (keysym === XK_LEFT || keysym === XK_RIGHT || keysym === XK_HOME || keysym === XK_END ||
        (control && (keysym === 0x61 || keysym === 0x65))) {
      this.cursor = keysym === XK_LEFT ? previous : keysym === XK_RIGHT ? following :
        keysym === XK_HOME || keysym === 0x61 ? 0 : this.value.length;
      return true;
    }
    let start = this.cursor;
    let end = this.cursor;
    let inserted = "";
    if (keysym === XK_BACKSPACE && !control) start = previous;
    else if (keysym === XK_DELETE && !control) end = following;
    else if (control && keysym === 0x75) start = 0;
    else if (control && keysym === 0x6b) end = this.value.length;
    else if (control && keysym === 0x77) {
      start = this.value.slice(0, this.cursor).replace(/\s*\S+\s*$/u, "").length;
    } else if (!control && keysym >= 0x20 && keysym <= 0x10ffff &&
               !(keysym >= 0x7f && keysym <= 0x9f) && !(keysym >= 0xd800 && keysym <= 0xdfff) &&
               !(keysym >= 0xff00 && keysym <= 0xffff)) inserted = String.fromCodePoint(keysym);
    else return false;
    const value = this.value.slice(0, start) + inserted + this.value.slice(end);
    if (value === this.value) return false;
    if (textEncoder.encode(value).byteLength > this.capacity) {
      this.error = `Input limit: ${this.capacity} UTF-8 bytes`;
      return true;
    }
    this.value = value;
    this.cursor = start + inserted.length;
    this.activeIndex = 0;
    this.detailOffset = 0;
    this.error = "";
    return true;
  }
}

function cellWidth(value) {
  if (/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(value)) return 2;
  const codepoint = value.codePointAt(0);
  return codepoint >= 0x1100 && (codepoint <= 0x115f || codepoint >= 0x2e80 && codepoint <= 0xa4cf ||
    codepoint >= 0xac00 && codepoint <= 0xd7a3 || codepoint >= 0xf900 && codepoint <= 0xfaff ||
    codepoint >= 0xfe10 && codepoint <= 0xfe6f || codepoint >= 0xff01 && codepoint <= 0xff60 ||
    codepoint >= 0x20000 && codepoint <= 0x3fffd) ? 2 : 1;
}

function textInputLine(state, columns) {
  const prefix = "Find: ".slice(0, Math.max(0, columns - 1));
  const available = Math.max(0, columns - prefix.length - 1);
  const parts = [...graphemes.segment(state.value)];
  const cursor = parts.filter((part) => part.index < state.cursor).length;
  let first = cursor;
  let before = 0;
  while (first > 0 && before + cellWidth(parts[first - 1].segment) <= available) {
    before += cellWidth(parts[--first].segment);
  }
  let visible = "";
  let width = 0;
  for (let index = first; index < parts.length; index++) {
    const nextWidth = cellWidth(parts[index].segment);
    if (width + nextWidth > available) break;
    visible += parts[index].segment;
    width += nextWidth;
  }
  return { text: prefix + visible, cursorColumn: prefix.length + before + 1 };
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
  const textMode = textInputMode(exports, stage.label);
  const setters = uniformSetterNames(Object.keys(exports), stage.label);
  const beginUpdate = textMode ? null : requireFunction(exports, "begin_update_at", 1);
  const finishUpdate = textMode ? null : requireFunction(exports, "finish_update", 0);
  const keyEvent = textMode ? null : requireFunction(exports, "key_event", 2);
  const source = input instanceof Uint8Array ? input : new Uint8Array(input);
  const editor = textMode ? new TextInputState(source, stage.inputCapacity) : null;
  if (editor) {
    const configuredIndex = stage.uniforms?.findLast((value) => value.startsWith("active_index="));
    if (configuredIndex) editor.activeIndex = parseUniformU32(configuredIndex.slice("active_index=".length));
    const configuredOffset = stage.uniforms?.findLast((value) => value.startsWith("detail_offset="));
    if (configuredOffset) editor.detailOffset = parseUniformU32(configuredOffset.slice("detail_offset=".length));
  }
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
    if (editor) stdout.write("\x1b[?2004h");
    terminalActive = true;
  };
  const leaveTerminal = () => {
    if (terminalActive && editor) stdout.write("\x1b[?2004l");
    if (terminalActive) stdout.write(LEAVE_SCREEN);
    terminalActive = false;
    if (!wasRaw && stdin.isTTY) stdin.setRawMode(false);
  };

  const renderFrame = (initial = false) => {
    if (rendering) return;
    rendering = true;
    try {
      const terminal = size();
      const inputLines = editor ? (editor.error ? 2 : 1) : 0;
      const dimensions = { ...terminal, lines: Math.max(1, terminal.lines - inputLines) };
      const currentInput = editor ? textEncoder.encode(editor.value) : source;
      if (editor) writeInitialInput(stage, currentInput);
      applyUniforms(stage, dimensions);
      if (editor && setters.has("active_index")) exports[setters.get("active_index")](editor.activeIndex);
      if (editor && setters.has("detail_offset")) exports[setters.get("detail_offset")](editor.detailOffset);
      const packed = exports.render(editor ? currentInput.byteLength : initial ? (stage.inputless ? 0 : source.byteLength) : 0);
      const safe = validateTerminalFrame(unpackRender(stage, packed));
      if (editor && typeof exports.active_count === "function") {
        const count = exports.active_count();
        if (!Number.isInteger(count)) throw new Error("active_count must return i32");
        editor.setActiveCount(count >>> 0);
      }
      if (editor && typeof exports.detail_count === "function") {
        editor.setDetailWindow(exports.detail_count() >>> 0, exports.detail_page_size() >>> 0);
      }
      stdout.write(REDRAW_PREFIX);
      let field;
      if (editor) {
        field = textInputLine(editor, terminal.columns);
        stdout.write(field.text + "\r\n");
        if (editor.error) stdout.write(editor.error.slice(0, terminal.columns) + "\r\n");
      }
      stdout.write(Buffer.from(decoder.decode(safe).replaceAll("\n", "\r\n")));
      stdout.write(REDRAW_SUFFIX);
      if (editor) stdout.write(`\x1b[1;${field.cursorColumn}H\x1b[?25h`);
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
      if (editor) {
        if (editor.handleKey(event)) renderFrame(false);
      } else runUpdate([event]);
    } catch (error) {
      fail(error);
    }
  };
  const keyDecoder = new TerminalKeyDecoder(onKey, editor ? {
    pasteCapacity: stage.inputCapacity,
    text(value) {
      try { if (editor.insertText(value)) renderFrame(false); }
      catch (error) { fail(error); }
    },
    paste(bytes, exceeded) {
      try {
        if (exceeded) editor.error = `Input limit: ${stage.inputCapacity} UTF-8 bytes`;
        else editor.insertText(decoder.decode(bytes));
        renderFrame(false);
      } catch (error) { fail(error); }
    },
  } : {});
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
    if (editor) editor.detailOffset = 0;
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
    if (!editor) runUpdate([]);
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

const MAX_MEMORY = 256 * 1024 * 1024;

function usage() {
  return `Usage: qiptui [host] [options] <component.wasm | host/path.wasm>\n\n` +
    `  -i, --input <file|->      Initial input file or piped stdin\n` +
    `  -F, --form <name=value>  Add a multipart field (repeatable)\n` +
    `  -u, --uniform <name=n>   Set a numeric component uniform\n` +
    `  -h, --help               Show this help\n\n` +
    `Multipart fields:\n` +
    `  -F name=value            UTF-8 text field\n` +
    `  -F name=@path            Exact file bytes with the basename as filename\n` +
    `  -F 'name=<path'          Exact file bytes as a regular field, without filename\n` +
    `  -F 'name=<-'             Piped stdin as a regular field\n` +
    `@path sends Content-Type: application/octet-stream; <path omits that part header.\n` +
    `  -F name=@-              Piped stdin as a file named -\n` +
    `Use piped stdin only once; keyboard input then uses terminal stderr.\n` +
    `Quote arguments containing < in a shell.\n\n` +
    `Examples:\n` +
    `  qiptui qip.dev/tui/calendar-gregorian.wasm\n` +
    `  qiptui qip.dev/tui/emoji-finder.wasm\n` +
    `  qiptui -F 'component=@text/wc.wasm' tui/qipdb.wasm\n` +
    `  qiptui -F 'component=<text/wc.wasm' tui/qipdb.wasm\n\n` +
    `A leading host or a hosted path such as qip.dev/tui/calendar-gregorian.wasm uses HTTPS.\n` +
    `Hosted components are downloaded into memory for each run.\n` +
    `Plain-text Content components get a text field. Up/Down changes active_index when supported.\n`;
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
  return { component, host, input, forms, uniforms };
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

async function readStream(stream, limit) {
  const chunks = [];
  let length = 0;
  for await (const chunk of stream) {
    length += chunk.byteLength;
    if (length > limit) throw new Error("piped input exceeds the component's input capacity");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, length);
}

export async function multipart(values, host = "", stdin = process.stdin, limit = Infinity) {
  const boundary = FORM_BOUNDARY;
  const chunks = [];
  let usedStdin = false;
  for (const value of values) {
    const { name, raw } = field(value);
    const fileMode = raw[0] === "@" || raw[0] === "<" ? raw[0] : "";
    const path = fileMode ? raw.slice(1) : "";
    if (fileMode && !path) throw new Error("form files need a path or - for piped stdin");
    if (path === "-") {
      if (usedStdin) throw new Error("piped stdin can only be used once");
      usedStdin = true;
    }
    const filename = fileMode === "@" ? basename(hostedPath(path)?.path ?? path) : "";
    if (filename && !/^[\x20-\x21\x23-\x5b\x5d-\x7e]+$/.test(filename)) throw new Error(`invalid form filename ${filename}`);
    const body = fileMode
      ? (path === "-" ? await readStream(stdin, limit) : path.endsWith(".wasm") ? await loadWasm(path, wasmHeader, host) : await readFile(path))
      : Buffer.from(raw);
    if (body.includes(Buffer.from(`\r\n--${boundary}`))) throw new Error(`form field ${name} contains the multipart boundary`);
    const header = `--${boundary}\r\nContent-Disposition: form-data; name="${name}"` +
      (fileMode === "@" ? `; filename="${filename}"\r\nContent-Type: application/octet-stream` : "") + "\r\n\r\n";
    chunks.push(Buffer.from(header), body, Buffer.from("\r\n"));
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

function declaredInputType(exports, label, direction = "input") {
  const pointer = exports[`${direction}_content_type_ptr`];
  const size = exports[`${direction}_content_type_size`];
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

export function validateTUIBinary(data, label = "TUI component") {
  wasmHeader(data);
  const module = new WebAssembly.Module(data);
  validateStrictProfile(data, label, { maxMemory: MAX_MEMORY });
  const exports = new Map(WebAssembly.Module.exports(module).map((entry) => [entry.name, entry.kind]));
  if (exports.get("memory") !== "memory") throw new Error("TUI component must export memory");
  const eventful = ["begin_update_at", "finish_update", "key_event", "pointer_event"].some((name) => exports.has(name));
  const required = eventful ? ["begin_update_at", "finish_update", "key_event"] :
    ["input_ptr", "input_utf8_cap", "input_content_type_ptr", "input_content_type_size"];
  const setters = uniformSetterNames(exports.keys(), label);
  if (!eventful && (exports.has("active_count") || setters.has("active_index"))) {
    required.push("active_count", setters.get("active_index") ?? "uniform_set_active_index");
  }
  for (const name of ["render", "output_utf8_cap", ...required]) {
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
  const exports = new WebAssembly.Instance(module).exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error("TUI component must export memory");
  requireFunction(exports, "render", 1);
  textInputMode(exports, options.component);
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
    component: { exports, uniformParamTypes: readUniformParamTypes(data, options.component) },
    inputless,
    inputCapacity: inputless ? 0 : exports[inputCapName](),
    outputCapacity: exports.output_utf8_cap(),
    uniforms: options.uniforms,
  };
  stage.uniformArguments = parseUniforms(stage);
  const inputType = declaredInputType(exports, options.component);
  if (options.forms.length && inputType && inputType !== FORM_CONTENT_TYPE) {
    throw new Error(`${options.component} expects ${inputType}, but -F supplies ${FORM_CONTENT_TYPE}`);
  }
  const outputType = declaredInputType(exports, options.component, "output");
  if (outputType && outputType !== "text/plain") throw new Error("TUI output must be text/plain");
  const stdinFields = options.forms.filter((value) => {
    const raw = field(value).raw;
    return raw === "@-" || raw === "<-";
  });
  const pipedInput = options.input === "-" || stdinFields.length > 0;
  if (stdinFields.length > 1) throw new Error("piped stdin can only be used once");
  if (pipedInput && (process.stdin.isTTY || !process.stderr.isTTY)) {
    throw new Error("piped input needs stdin from a pipe and stderr attached to a terminal for keyboard input");
  }
  const input = options.forms.length ? await multipart(options.forms, options.host, process.stdin, stage.inputCapacity)
    : options.input === "-" ? await readStream(process.stdin, stage.inputCapacity)
      : options.input ? await readFile(options.input) : new Uint8Array();
  const keyboard = pipedInput ? new ReadStream(2) : process.stdin;
  try {
    await runTUI({ stage, input, applyUniforms, stdin: keyboard });
  } finally {
    if (pipedInput) keyboard.destroy();
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
