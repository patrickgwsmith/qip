#!/usr/bin/env node

// qipgui: a prototype host that runs a QIP GUI component (with optional Time and Events
// exports) in a terminal that supports the Kitty graphics protocol. Further components
// transform each rendered frame in order, and the last one must output KTX2 RGBA8. It
// shares its loader, Strict Wasm Profile checks, uniform handling and key decoder with
// qiptui through qip-host.mjs, a copy of npm/shared/qip-host.mjs.

import process from "node:process";
import { realpathSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ReadStream } from "node:tty";
import { deflateSync } from "node:zlib";

import {
  applyUniforms,
  loadWasm,
  parseUniforms,
  readUniformParamTypes,
  TerminalKeyDecoder,
  validateStrictProfile,
} from "./qip-host.mjs";

// Per-component memory limit. Higher than qiptui's 256 MiB so rasterizers such as the
// SIMD (512 MiB), ThorVG (512 MiB) and Skia (544 MiB) ones can run as transforms.
export const MAX_MEMORY = 1024 * 1024 * 1024;

const FLAG_KEY_DOWN = 1 << 0;
const FLAG_CONTROL = 1 << 3;

const ENTER_SCREEN = "\x1b[?1049h\x1b[?25l";
const LEAVE_SCREEN = "\x1b[0m\x1b[?25h\x1b[?1049l";
// 1003: report all motion, 1006: SGR encoding, 1016: SGR pixel coordinates, 1004: focus.
const ENABLE_MOUSE = "\x1b[?1003h\x1b[?1006h\x1b[?1016h\x1b[?1004h";
const DISABLE_MOUSE = "\x1b[?1004l\x1b[?1016l\x1b[?1006l\x1b[?1003l";
const SYNC_BEGIN = "\x1b[?2026h";
const SYNC_END = "\x1b[?2026l";
// A 1x1 RGB query that the terminal answers but never displays, followed by DA1 so a
// terminal without graphics support still answers something.
const GRAPHICS_QUERY = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
const SIZE_QUERY = "\x1b[14t\x1b[16t";
const DA1_QUERY = "\x1b[c";
const CHUNK = 4096;

const KTX2_IDENTIFIER = Buffer.from([0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a]);
const VK_FORMAT_R8G8B8A8_SRGB = 43;

// Returns the level 0 RGBA8 pixels of a single-image KTX2 file without copying them.
export function parseKTX2RGBA8(bytes) {
  if (bytes.length < 104 || !KTX2_IDENTIFIER.equals(bytes.subarray(0, 12))) {
    throw new Error("GUI output is not KTX2");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u32 = (offset) => view.getUint32(offset, true);
  const u64 = (offset) => Number(view.getBigUint64(offset, true));
  const vkFormat = u32(12);
  if (vkFormat !== VK_FORMAT_R8G8B8A8_SRGB || u32(16) !== 1) {
    throw new Error(`qipgui only presents KTX2 R8G8B8A8_SRGB (vkFormat 43), not vkFormat ${vkFormat}`);
  }
  const width = u32(20);
  const height = u32(24);
  if (width === 0 || height === 0 || u32(28) !== 0 || u32(32) > 1 || u32(36) !== 1 || u32(44) !== 0) {
    throw new Error("GUI output must be one 2D KTX2 image without supercompression");
  }
  const offset = u64(80);
  const length = u64(88);
  if (length !== width * height * 4 || offset + length > bytes.length) {
    throw new Error("GUI output KTX2 level 0 is outside the file or the wrong size");
  }
  return { width, height, pixels: bytes.subarray(offset, offset + length) };
}

// Builds the escape sequences that transmit RGBA pixels and place them at the cursor.
// "direct" sends base64 RGBA, "zlib" sends deflated RGBA, and "file" writes a temporary
// file that the terminal reads and deletes, which only works when the terminal is local.
export function kittyImage({ id, width, height, pixels, columns = 0, transport = "direct", fileIndex = 0 }) {
  const keys = [`a=T`, `f=32`, `s=${width}`, `v=${height}`, `i=${id}`, `p=1`, `q=2`, `C=1`];
  if (columns > 0) keys.push(`c=${columns}`);
  let payload;
  if (transport === "file") {
    const path = join(tmpdir(), `tty-graphics-protocol-qipgui-${process.pid}-${fileIndex}.rgba`);
    writeFileSync(path, pixels);
    keys.push("t=t");
    payload = Buffer.from(path).toString("base64");
  } else if (transport === "zlib") {
    keys.push("o=z");
    payload = deflateSync(pixels, { level: 1 }).toString("base64");
  } else {
    payload = Buffer.from(pixels.buffer, pixels.byteOffset, pixels.byteLength).toString("base64");
  }
  if (payload.length <= CHUNK) return `\x1b_G${keys.join(",")};${payload}\x1b\\`;
  const parts = [];
  for (let start = 0; start < payload.length; start += CHUNK) {
    const more = start + CHUNK < payload.length ? 1 : 0;
    const control = start === 0 ? `${keys.join(",")},m=${more}` : `m=${more}`;
    parts.push(`\x1b_G${control};${payload.slice(start, start + CHUNK)}\x1b\\`);
  }
  return parts.join("");
}

export function kittyDelete(id) {
  return `\x1b_Ga=d,d=I,i=${id},q=2\x1b\\`;
}

const REPORTS = /\x1b\[<(\d+);(\d+);(\d+)([Mm])|\x1b\[([46]);(\d+);(\d+)t|\x1b_G([^\x1b]*)\x1b\\|\x1b\[\?[\d;]*c|\x1b\[([IO])/g;
// Only hold back prefixes that cannot be a complete key, so Escape still reaches the key decoder.
const INCOMPLETE_REPORT = /\x1b(?:\[<[\d;]*|\[\?[\d;]*|\[[46];[\d;]*|_G[^\x1b]*\x1b?)$/;

// Separates mouse reports, terminal replies and focus changes from key bytes.
export class TerminalInputSplitter {
  constructor() {
    this.pending = "";
  }

  push(chunk) {
    let text = this.pending + Buffer.from(chunk).toString("latin1");
    this.pending = "";
    const tail = INCOMPLETE_REPORT.exec(text);
    if (tail) {
      this.pending = tail[0];
      text = text.slice(0, tail.index);
    }
    const reports = [];
    const keys = text.replace(REPORTS, (_, button, x, y, final, kind, height, width, graphics, focus) => {
      if (button !== undefined) {
        reports.push({ type: "mouse", button: Number(button), x: Number(x), y: Number(y), release: final === "m" });
      } else if (kind !== undefined) {
        reports.push({ type: kind === "4" ? "window" : "cell", width: Number(width), height: Number(height) });
      } else if (graphics !== undefined) {
        reports.push({ type: "graphics", ok: /;OK$/.test(graphics) });
      } else if (focus !== undefined) {
        reports.push({ type: "focus", focused: focus === "I" });
      } else {
        reports.push({ type: "da1" });
      }
      return "";
    });
    return { keys: Buffer.from(keys, "latin1"), reports };
  }
}

// SGR button codes to the QIP mask: left 1, middle 2, right 4.
const SGR_BUTTON_MASK = [1, 2, 4];

// Tracks held buttons from SGR reports. Returns null for reports that QIP has no event for.
export function pointerState(previousMask, report) {
  const code = report.button;
  if (code & 64) return null; // wheel and extra buttons
  const button = code & 3;
  if (code & 32) return previousMask; // motion keeps the held buttons
  if (button === 3) return 0; // legacy release of all buttons
  const bit = SGR_BUTTON_MASK[button];
  return report.release ? previousMask & ~bit : previousMask | bit;
}

// Chooses how many columns the image spans. Returns columns = 0 for 1:1 pixels.
export function layoutImage({ width, height, size, window, cell, columns }) {
  if (size === "native" || !window) return { columns: 0, displayWidth: width };
  const cellWidth = cell?.width || window.width / Math.max(1, columns);
  const fit = Math.min(window.width, window.height * width / height);
  if (size === "auto" && width <= fit) return { columns: 0, displayWidth: width };
  const spanned = Math.max(1, Math.floor(fit / cellWidth));
  return { columns: spanned, displayWidth: spanned * cellWidth };
}

// The size a frame's pixels are measured in, read from its header: KTX2 width and height,
// or an SVG root's numeric width and height, falling back to its viewBox like the
// rasterizers do. Returns null for formats without a known size.
export function naturalSize(bytes) {
  if (bytes.length >= 28 && KTX2_IDENTIFIER.equals(Buffer.from(bytes.buffer, bytes.byteOffset, 12))) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return { width: view.getUint32(20, true), height: view.getUint32(24, true) };
  }
  const text = Buffer.from(bytes.buffer, bytes.byteOffset, Math.min(bytes.byteLength, 4096)).toString("latin1");
  const root = /<svg\b[^>]*>/.exec(text)?.[0];
  if (!root) return null;
  const attribute = (name) => new RegExp(`\\s${name}\\s*=\\s*["']([^"']*)["']`).exec(root)?.[1];
  const length = (value) => {
    const match = /^\s*([\d.]+)\s*(px)?\s*$/.exec(value ?? "");
    return match && Number(match[1]) > 0 ? Number(match[1]) : null;
  };
  const width = length(attribute("width"));
  const height = length(attribute("height"));
  if (width && height) return { width, height };
  const box = (attribute("viewBox") ?? "").trim().split(/[\s,]+/).map(Number);
  if (box.length === 4 && box[2] > 0 && box[3] > 0) return { width: box[2], height: box[3] };
  return null;
}

function unpackRender(stage, packed) {
  if (typeof packed !== "bigint") throw new Error(`${stage.label} render must return i64`);
  const bits = BigInt.asUintN(64, packed);
  if ((bits & (1n << 63n)) !== 0n) throw new Error(`${stage.label} rejected input`);
  const size = Number(bits & 0xffff_ffffn);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const memory = stage.component.exports.memory.buffer;
  if (size > stage.outputCapacity || pointer + size > memory.byteLength) {
    throw new Error(`${stage.label} returned output outside its declared capacity`);
  }
  return new Uint8Array(memory, pointer, size);
}

function contentType(exports, direction) {
  const pointer = exports[`${direction}_content_type_ptr`];
  const size = exports[`${direction}_content_type_size`];
  if (typeof pointer !== "function" || typeof size !== "function") return "";
  const start = pointer() >>> 0;
  const length = size() >>> 0;
  if (start + length > exports.memory.buffer.byteLength) throw new Error(`${direction} content type is outside memory`);
  return new TextDecoder().decode(new Uint8Array(exports.memory.buffer, start, length));
}

function optionalFunction(exports, name, arity) {
  const fn = exports[name];
  if (fn === undefined) return null;
  if (typeof fn !== "function" || fn.length !== arity) throw new Error(`GUI component export ${name} must take ${arity} arguments`);
  return fn;
}

const FORMAT_NAMES = { "image/ktx2": "KTX2", "image/svg+xml": "SVG", "text/html": "HTML", "text/plain": "plain text" };

export function requireKTX2Output(exports, label = "GUI component") {
  const type = contentType(exports, "output");
  const mediaType = type.split(";")[0].trim().toLowerCase();
  if (typeof exports.output_bytes_cap === "function" && (!mediaType || mediaType === "image/ktx2")) return;
  const format = FORMAT_NAMES[mediaType] ?? (mediaType || "text");
  throw new Error(`${label} renders ${format}, but qipgui only displays KTX2 RGBA8 images`);
}

export function validateGUIBinary(data, label = "GUI component") {
  if (data.length < 8 || !data.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) {
    throw new Error("file is not a WebAssembly 1.0 module");
  }
  const module = new WebAssembly.Module(data);
  validateStrictProfile(data, label, { maxMemory: MAX_MEMORY });
  const exports = new Map(WebAssembly.Module.exports(module).map((entry) => [entry.name, entry.kind]));
  if (exports.get("memory") !== "memory") throw new Error("GUI component must export memory");
  if (exports.get("render") !== "function") throw new Error("GUI component must export render");
  // Text-output components pass here so requireKTX2Output can name their format after instantiation.
  if (exports.get("output_bytes_cap") !== "function" && exports.get("output_utf8_cap") !== "function") {
    throw new Error("GUI component must export output_bytes_cap");
  }
  const timed = ["begin_update_at", "finish_update"].filter((name) => exports.has(name)).length;
  if (timed === 1) throw new Error("GUI component must export both begin_update_at and finish_update");
  if (!timed && (exports.has("key_event") || exports.has("pointer_event"))) {
    throw new Error("GUI component events need begin_update_at and finish_update");
  }
}

const EVENT_EXPORTS = ["begin_update_at", "finish_update", "key_event", "pointer_event"];

// Components after the first transform each frame, so they take input and handle no events.
export function validateTransformBinary(data, label) {
  if (data.length < 8 || !data.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) {
    throw new Error(`${label} is not a WebAssembly 1.0 module`);
  }
  const module = new WebAssembly.Module(data);
  validateStrictProfile(data, label, { maxMemory: MAX_MEMORY });
  const exports = new Map(WebAssembly.Module.exports(module).map((entry) => [entry.name, entry.kind]));
  if (exports.get("memory") !== "memory") throw new Error(`${label} must export memory`);
  if (exports.get("render") !== "function") throw new Error(`${label} must export render`);
  if (EVENT_EXPORTS.some((name) => exports.has(name))) {
    throw new Error(`${label} handles events, but only the first component can; later components must be content transforms`);
  }
  if (!exports.has("input_ptr") || (!exports.has("input_bytes_cap") && !exports.has("input_utf8_cap"))) {
    throw new Error(`${label} takes no input, so it cannot transform the previous component's output`);
  }
  if (exports.get("output_bytes_cap") !== "function" && exports.get("output_utf8_cap") !== "function") {
    throw new Error(`${label} must export output_bytes_cap or output_utf8_cap`);
  }
}

// Instantiates a validated module as a stage that runWithTransforms and runGUI accept.
export function createStage(data, label, uniforms = []) {
  const exports = new WebAssembly.Instance(new WebAssembly.Module(data)).exports;
  const inputless = exports.input_ptr === undefined;
  const inputCapacity = exports.input_bytes_cap ?? exports.input_utf8_cap;
  const outputCapacity = exports.output_bytes_cap ?? exports.output_utf8_cap;
  const stage = {
    label,
    component: { exports, uniformParamTypes: readUniformParamTypes(data, label) },
    inputless,
    inputCapacity: inputless || typeof inputCapacity !== "function" ? 0 : inputCapacity(),
    outputCapacity: outputCapacity(),
    inputType: contentType(exports, "input"),
    outputType: contentType(exports, "output"),
    uniforms,
  };
  stage.uniformArguments = parseUniforms(stage);
  return stage;
}

const mediaTypeOf = (type) => type.split(";")[0].trim().toLowerCase();

// Checks that each transform accepts what the stage before it renders, and that the last
// stage renders KTX2. Types that a component leaves undeclared are not checked.
export function checkChain(stages) {
  for (let index = 1; index < stages.length; index += 1) {
    const previous = stages[index - 1];
    const stage = stages[index];
    const wanted = mediaTypeOf(stage.inputType);
    const given = mediaTypeOf(previous.outputType);
    if (wanted && given && wanted !== given) {
      throw new Error(`${stage.label} takes ${FORMAT_NAMES[wanted] ?? wanted}, but ${previous.label} renders ${FORMAT_NAMES[given] ?? given}`);
    }
  }
  const last = stages.at(-1);
  requireKTX2Output(last.component.exports, last.label);
}

function writeInput(stage, bytes) {
  const { exports } = stage.component;
  const pointer = exports.input_ptr();
  if (bytes.byteLength > stage.inputCapacity || pointer + bytes.byteLength > exports.memory.buffer.byteLength) {
    throw new Error(`${stage.label} input is too large (${bytes.byteLength} bytes > ${stage.inputCapacity} bytes input capacity)`);
  }
  new Uint8Array(exports.memory.buffer, pointer, bytes.byteLength).set(bytes);
}

// Pipes one frame through the transforms. Each output is a view into its stage's memory,
// which stays valid because the next stage only writes to its own memory.
export function runTransforms(transforms, bytes, dimensions) {
  let current = bytes;
  for (const stage of transforms) {
    applyUniforms(stage, dimensions);
    writeInput(stage, current);
    current = unpackRender(stage, stage.component.exports.render(current.byteLength));
  }
  return current;
}

class Stats {
  constructor() {
    this.startedAt = performance.now();
    this.frames = 0;
    this.skipped = 0;
    this.renderMS = 0;
    this.encodeMS = 0;
    this.bytes = 0;
    this.latencies = [];
  }

  summary() {
    const seconds = (performance.now() - this.startedAt) / 1000;
    const frames = Math.max(1, this.frames);
    const sorted = [...this.latencies].sort((a, b) => a - b);
    const percentile = (p) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))].toFixed(1) : "-";
    return [
      `qipgui: ${this.frames} frames in ${seconds.toFixed(1)}s (${(this.frames / seconds).toFixed(1)} fps average)`,
      `  render ${(this.renderMS / frames).toFixed(2)}ms, encode ${(this.encodeMS / frames).toFixed(2)}ms, ` +
        `${(this.bytes / frames / 1024).toFixed(0)} KiB per frame, ${(this.bytes / seconds / 1024 / 1024).toFixed(1)} MiB/s`,
      `  ${this.skipped} renders deferred while the terminal was still reading the previous frame`,
      `  input to frame flushed: p50 ${percentile(0.5)}ms, p95 ${percentile(0.95)}ms over ${sorted.length} inputs`,
    ].join("\n") + "\n";
  }
}

export async function runGUI({
  stage, transforms = [], input, size = "auto", transport = "direct", stats = null,
  stdin = process.stdin, stdout = process.stdout,
}) {
  if (!stdin.isTTY || !stdout.isTTY || typeof stdin.setRawMode !== "function") {
    throw new Error("qipgui requires terminal stdin and stdout");
  }
  const exports = stage.component.exports;
  const beginUpdate = optionalFunction(exports, "begin_update_at", 1);
  const finishUpdate = optionalFunction(exports, "finish_update", 0);
  const keyEvent = optionalFunction(exports, "key_event", 2);
  const pointerEvent = optionalFunction(exports, "pointer_event", 3);
  const source = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (source.byteLength) {
    if (stage.inputless) throw new Error(`${stage.label} is inputless and cannot receive input`);
    if (source.byteLength > stage.inputCapacity) throw new Error(`${stage.label} input exceeds its capacity`);
    new Uint8Array(exports.memory.buffer, exports.input_ptr(), source.byteLength).set(source);
  }

  const wasRaw = Boolean(stdin.isRaw);
  const startedAt = performance.now();
  const splitter = new TerminalInputSplitter();
  let terminalActive = false;
  let lastUpdate = 0;
  let nextWake = 0;
  let wakeTimer = null;
  let escapeTimer = null;
  let settled = false;
  let writeBlocked = false;
  let dirty = false;
  let imageID = 1;
  let shownID = 0;
  let fileIndex = 0;
  let pointerMask = 0;
  let pointerInside = false;
  let layout = null;
  let window = null;
  let cell = null;
  let graphics = null;
  let probed = null;
  const probeDone = new Promise((resolve) => { probed = resolve; });
  // Input arrival times waiting for the frame that shows their effect.
  let pendingInputs = [];

  const enterTerminal = () => {
    if (!wasRaw) stdin.setRawMode(true);
    stdin.resume();
    stdout.write(ENTER_SCREEN + ENABLE_MOUSE);
    terminalActive = true;
  };
  const leaveTerminal = () => {
    if (terminalActive) stdout.write(kittyDelete(1) + kittyDelete(2) + DISABLE_MOUSE + LEAVE_SCREEN);
    terminalActive = false;
    shownID = 0;
    if (!wasRaw && stdin.isTTY) stdin.setRawMode(false);
  };

  const renderFrame = (initial = false) => {
    if (writeBlocked) {
      dirty = true;
      if (stats) stats.skipped += 1;
      return;
    }
    dirty = false;
    const renderStart = performance.now();
    const dimensions = { columns: stdout.columns || 80, lines: stdout.rows || 24 };
    applyUniforms(stage, dimensions);
    const primary = unpackRender(stage, exports.render(initial ? source.byteLength : 0));
    // Pointer events use the first component's own size, so transforms that scale the
    // frame still get clicks in its coordinates.
    const pointerSize = transforms.length ? naturalSize(primary) : null;
    const output = runTransforms(transforms, primary, dimensions);
    const encodeStart = performance.now();
    const image = parseKTX2RGBA8(output);
    layout = {
      ...image,
      pointer: pointerSize ?? { width: image.width, height: image.height },
      ...layoutImage({ ...image, size, window, cell, columns: dimensions.columns }),
    };
    const id = imageID;
    imageID = imageID === 1 ? 2 : 1;
    // Place the new image before deleting the old one so the terminal never shows a gap.
    const frame = SYNC_BEGIN + "\x1b[H" +
      kittyImage({ id, ...image, columns: layout.columns, transport, fileIndex: fileIndex++ }) +
      (shownID ? kittyDelete(shownID) : "") + SYNC_END;
    shownID = id;
    const encodeEnd = performance.now();
    const inputs = pendingInputs;
    pendingInputs = [];
    const flushed = stdout.write(frame, () => {
      if (!stats) return;
      const now = performance.now();
      for (const at of inputs) stats.latencies.push(now - at);
    });
    if (stats) {
      stats.frames += 1;
      stats.renderMS += encodeStart - renderStart;
      stats.encodeMS += encodeEnd - encodeStart;
      stats.bytes += frame.length;
    }
    if (!flushed) writeBlocked = true;
  };

  const onDrain = () => {
    writeBlocked = false;
    if (dirty) {
      try { renderFrame(false); } catch (error) { fail(error); }
    }
  };

  const scheduleWake = () => {
    if (wakeTimer !== null) clearTimeout(wakeTimer);
    wakeTimer = null;
    if (nextWake <= lastUpdate) return;
    const elapsed = Math.floor(performance.now() - startedAt) + 1;
    wakeTimer = setTimeout(() => {
      wakeTimer = null;
      try { runUpdate([], true, nextWake); } catch (error) { fail(error); }
    }, Math.max(0, nextWake - elapsed));
  };

  const runUpdate = (events, forceRender = false, requestedTime = 0) => {
    if (!beginUpdate) return;
    const now = Math.max(Math.floor(performance.now() - startedAt) + 1, lastUpdate + 1, requestedTime);
    beginUpdate(BigInt(now));
    applyUniforms(stage, { columns: stdout.columns || 80, lines: stdout.rows || 24 });
    let accepted = false;
    for (const event of events) {
      if (event.type === "key" && keyEvent) {
        accepted = keyEvent(event.keysym, event.flags | FLAG_KEY_DOWN) === 1 || accepted;
        accepted = keyEvent(event.keysym, event.flags) === 1 || accepted;
      } else if (event.type === "pointer" && pointerEvent) {
        accepted = pointerEvent(event.mask, event.x, event.y) === 1 || accepted;
      }
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
  const done = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject; });
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

  // Converts a terminal pixel position to the first component's coordinates. Transforms
  // are assumed only to scale, so the same fraction of the frame maps back.
  const toImage = (report) => {
    if (!layout) return null;
    // SGR pixel reports are treated as 0-based; check against your terminal (see README).
    const fx = report.x / layout.displayWidth;
    const fy = report.y * (layout.width / layout.height) / layout.displayWidth;
    const { width, height } = layout.pointer;
    return {
      x: Math.floor(fx * width), y: Math.floor(fy * height), width, height,
      inside: fx >= 0 && fy >= 0 && fx < 1 && fy < 1,
    };
  };

  let queued = [];
  const queueKey = (event) => {
    if ((event.flags & FLAG_CONTROL) !== 0 && event.keysym === 0x63) return finish();
    if ((event.flags & FLAG_CONTROL) !== 0 && event.keysym === 0x7a) return suspend();
    queued.push({ type: "key", ...event });
  };
  const keyDecoder = new TerminalKeyDecoder(queueKey);

  const onReport = (report) => {
    if (report.type === "graphics") graphics = report.ok;
    else if (report.type === "da1") probed();
    else if (report.type === "window") {
      window = { width: report.width, height: report.height };
      if (layout) dirty = true;
    } else if (report.type === "cell") {
      cell = { width: report.width, height: report.height };
    } else if (report.type === "focus" && !report.focused && (pointerMask || pointerInside)) {
      pointerMask = 0;
      pointerInside = false;
      queued.push({ type: "pointer", mask: 0, x: -1, y: -1 });
    } else if (report.type === "mouse") {
      const mask = pointerState(pointerMask, report);
      if (mask === null) return;
      const point = toImage(report);
      if (!point) return;
      if (!point.inside && mask === 0 && pointerMask === 0) {
        if (pointerInside) queued.push({ type: "pointer", mask: 0, x: -1, y: -1 });
        pointerInside = false;
        return;
      }
      // A drag that leaves the image keeps reporting the nearest edge pixel.
      const x = Math.min(Math.max(point.x, 0), Math.ceil(point.width) - 1);
      const y = Math.min(Math.max(point.y, 0), Math.ceil(point.height) - 1);
      pointerInside = point.inside;
      pointerMask = mask;
      queued.push({ type: "pointer", mask, x, y });
    }
  };

  const deliver = () => {
    const events = queued;
    queued = [];
    try {
      if (events.length) {
        const waiting = pendingInputs.length;
        pendingInputs.push(performance.now());
        runUpdate(events);
        // An ignored input produces no frame, so it has no latency to report.
        if (!dirty && pendingInputs.length > waiting) pendingInputs.length = waiting;
      }
      if (dirty && !writeBlocked) renderFrame(false);
    } catch (error) {
      fail(error);
    }
  };

  const onData = (chunk) => {
    const { keys, reports } = splitter.push(chunk);
    for (const report of reports) onReport(report);
    if (keys.length) {
      if (keyDecoder.push(keys)) {
        if (escapeTimer !== null) clearTimeout(escapeTimer);
        escapeTimer = setTimeout(() => {
          escapeTimer = null;
          keyDecoder.flush();
          deliver();
        }, 30);
      }
    }
    deliver();
  };

  const suspend = () => {
    if (process.platform === "win32") return;
    leaveTerminal();
    process.kill(process.pid, "SIGTSTP");
    enterTerminal();
    stdout.write(SIZE_QUERY);
    dirty = true;
  };
  const onResize = () => stdout.write(SIZE_QUERY);
  const signals = [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]].map(
    ([signal, code]) => [signal, () => finish(code)],
  );

  enterTerminal();
  stdin.on("data", onData);
  stdout.on("drain", onDrain);
  stdout.on("resize", onResize);
  for (const [signal, handler] of signals) process.on(signal, handler);
  try {
    stdout.write(GRAPHICS_QUERY + SIZE_QUERY + DA1_QUERY);
    const timeout = new Promise((resolve) => setTimeout(resolve, 1000).unref());
    await Promise.race([probeDone, timeout]);
    if (!graphics) throw new Error("this terminal did not answer a Kitty graphics protocol query; try kitty, Ghostty or WezTerm");
    renderFrame(true);
    runUpdate([]);
    await done;
  } finally {
    if (wakeTimer !== null) clearTimeout(wakeTimer);
    if (escapeTimer !== null) clearTimeout(escapeTimer);
    stdin.off("data", onData);
    stdout.off("drain", onDrain);
    stdout.off("resize", onResize);
    for (const [signal, handler] of signals) process.off(signal, handler);
    stdin.pause();
    leaveTerminal();
    if (stats) process.stderr.write(stats.summary());
  }
}

function usage() {
  return `Usage: qipgui [options] <gui.wasm> [transform.wasm ...]\n\n` +
    `The first component renders and receives keys and pointer events. Each later\n` +
    `component transforms the frame before it, and the last must output KTX2 RGBA8.\n` +
    `Components may be local files or host/path.wasm downloads.\n\n` +
    `  -i, --input <file|->       Initial input for the first component, or piped stdin\n` +
    `  -u, --uniform <name=n>     Set a numeric uniform on the preceding component\n` +
    `      --size <mode>          auto (1:1, shrink to fit), native, or fill\n` +
    `      --transport <mode>     direct (base64 RGBA), zlib, or file (local terminals only)\n` +
    `      --stats                Print frame rate, bytes and input latency on exit\n` +
    `  -h, --help                 Show this help\n\n` +
    `Requires a terminal with the Kitty graphics protocol and SGR pixel mouse reports.\n` +
    `Ctrl-C exits.\n\n` +
    `Examples:\n` +
    `  qipgui gui/calculator.wasm\n` +
    `  qipgui --stats --transport zlib gui/snake.wasm\n` +
    `  qipgui gui/klondike.wasm image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm\n`;
}

// Uniforms before the first component apply to it, so `-u name=n gui.wasm` keeps working.
export function parseArgs(args) {
  const options = { components: [], input: undefined, size: "auto", transport: "direct", stats: false };
  const leading = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "-h" || arg === "--help") return { help: true };
    if (arg === "--stats") options.stats = true;
    else if (["-i", "--input", "-u", "--uniform", "--size", "--transport"].includes(arg)) {
      const value = args[++index];
      if (value === undefined) throw new Error(`${arg} requires a value`);
      if (arg === "-i" || arg === "--input") options.input = value;
      else if (arg === "-u" || arg === "--uniform") (options.components.at(-1)?.uniforms ?? leading).push(value);
      else if (arg === "--size") {
        if (!["auto", "native", "fill"].includes(value)) throw new Error("--size must be auto, native or fill");
        options.size = value;
      } else {
        if (!["direct", "zlib", "file"].includes(value)) throw new Error("--transport must be direct, zlib or file");
        options.transport = value;
      }
    } else if (arg.startsWith("-")) throw new Error(`unknown option ${arg}`);
    else options.components.push({ path: arg, uniforms: options.components.length ? [] : leading });
  }
  if (!options.components.length) throw new Error("qipgui requires a component; run --help for usage");
  return options;
}

export async function main(args = process.argv.slice(2)) {
  const options = parseArgs(args);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  const stages = [];
  for (const { path, uniforms } of options.components) {
    const validate = stages.length ? validateTransformBinary : validateGUIBinary;
    const data = await loadWasm(path, (bytes) => validate(bytes, path));
    stages.push(createStage(data, path, uniforms));
  }
  checkChain(stages);
  const [stage, ...transforms] = stages;
  const piped = options.input === "-";
  if (piped && (process.stdin.isTTY || !process.stderr.isTTY)) {
    throw new Error("piped input needs stdin from a pipe and stderr attached to a terminal for keyboard input");
  }
  const input = piped ? Buffer.concat(await Array.fromAsync(process.stdin))
    : options.input ? await readFile(options.input) : new Uint8Array();
  const keyboard = piped ? new ReadStream(2) : process.stdin;
  try {
    await runGUI({
      stage, transforms, input, size: options.size, transport: options.transport,
      stats: options.stats ? new Stats() : null, stdin: keyboard,
    });
  } finally {
    if (piped) keyboard.destroy();
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
