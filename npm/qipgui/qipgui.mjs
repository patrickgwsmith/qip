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
import { createInterface } from "node:readline/promises";

import { ChannelClient, ChannelError, ChannelTimeline, fetchModule } from "./qip-channel.mjs";

import {
  applyUniforms,
  hostedPath,
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

// Loads the module of a channel's module entry as a stage, after the integrity check.
// A prefetch entry starts the download early; the module entry then reuses it.
export function createChannelStageLoader({ transforms = [], fetch = globalThis.fetch } = {}) {
  const downloads = new Map();
  const download = (entry) => {
    if (!downloads.has(entry.integrity)) {
      // Keep only a few modules: the server decides how many prefetch entries it sends.
      if (downloads.size >= 4) downloads.delete(downloads.keys().next().value);
      downloads.set(entry.integrity, fetchModule(entry, { fetch }));
    }
    return downloads.get(entry.integrity);
  };
  return {
    prefetch(entry) {
      // A failed prefetch is forgotten, so the module entry tries the download again.
      download(entry).catch(() => downloads.delete(entry.integrity));
    },
    async load(entry) {
      let data;
      try {
        data = await download(entry);
      } catch (error) {
        downloads.delete(entry.integrity);
        throw new ChannelError(`cannot load the channel's module: ${error.message ?? error}`);
      }
      const label = entry.url;
      try {
        validateGUIBinary(data, label);
        const names = new Set(WebAssembly.Module.exports(new WebAssembly.Module(data)).map(({ name }) => name));
        if (!names.has("begin_update_at") || !names.has("finish_update")) {
          throw new Error(`${label} does not export begin_update_at and finish_update, which a channel needs`);
        }
        // A replay needs a new instance of the same module.
        const make = () => Object.assign(createStage(data, label), { fresh: make });
        const stage = make();
        checkChain([stage, ...transforms]);
        return stage;
      } catch (error) {
        throw new ChannelError(error.message ?? String(error));
      }
    },
  };
}

// Text from a server goes to the terminal, so it must not hold control characters.
const printable = (text) => String(text).replace(/[\x00-\x1f\x7f-\x9f]/g, " ");

export function channelStatusText({ host, connection, role, seq, message }) {
  const parts = [`connect ${host}`];
  if (connection === "closed") parts.push(`channel closed (${message})`, "Ctrl-C exits");
  else {
    parts.push({ editor: "editor: your input is sent", viewer: "viewer", "view-only": "view only" }[role] ?? "input is sent if this URL permits it");
    parts.push(connection === "connected" ? (seq === null ? "loading" : `seq ${seq}`) : connection);
    if (message) parts.push(message);
  }
  return printable(parts.join(" \u00b7 "));
}

// With channel set ({ url, view, fetch }), the component, its input, the update times and
// all key and pointer events come from the channel's log instead of from this terminal.
// Local keys and pointer events are only sent to the server, and take effect when they
// come back in the log. The component's wakes run on an estimate of the channel clock, and
// a log entry that arrives after a wake with a later time causes a replay. Focus does not
// reach the component, because it would make clients differ. channel.onStage(stage,
// timeline) is called each time a module entry or a replay makes a new instance. See
// docs/qipgui-sync-protocol.md.
export async function runGUI({
  stage = null, transforms = [], input = new Uint8Array(), size = "auto", transport = "direct", stats = null,
  stdin = process.stdin, stdout = process.stdout, channel = null,
}) {
  if (!stdin.isTTY || !stdout.isTTY || typeof stdin.setRawMode !== "function") {
    throw new Error("qipgui requires terminal stdin and stdout");
  }
  let exports;
  let beginUpdate;
  let finishUpdate;
  let keyEvent;
  let pointerEvent;
  // Components draw their own focus state (such as an inactive window) from this
  // uniform. It defaults to 1, and the terminal is assumed focused at launch.
  // Focus is render-only, like a fragment shader input: it is set before each
  // render and never inside an update, so it cannot change component state.
  // That keeps channel clients identical whatever their local focus.
  let setFocused;
  let focused = true;
  let source;
  // A channel calls this again for each module entry, which replaces the component.
  const useStage = (next, bytes) => {
    const functions = [
      ["begin_update_at", 1], ["finish_update", 0], ["key_event", 2], ["pointer_event", 3], ["uniform_set_is_focused", 1],
    ].map(([name, arity]) => optionalFunction(next.component.exports, name, arity));
    const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (data.byteLength) {
      if (next.inputless) throw new Error(`${next.label} is inputless and cannot receive input`);
      if (data.byteLength > next.inputCapacity) throw new Error(`${next.label} input exceeds its capacity`);
      new Uint8Array(next.component.exports.memory.buffer, next.component.exports.input_ptr(), data.byteLength).set(data);
    }
    stage = next;
    exports = next.component.exports;
    [beginUpdate, finishUpdate, keyEvent, pointerEvent, setFocused] = functions;
    source = data;
  };
  if (!channel) useStage(stage, input);
  let statusText = "";
  let client = null;

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

  // The status line of a channel, on the last row of the terminal.
  const statusLine = () => {
    if (!channel) return "";
    const text = statusText.slice(0, Math.max(0, (stdout.columns || 80) - 1));
    return `\x1b[${stdout.rows || 24};1H\x1b[2K\x1b[2m${text}\x1b[0m`;
  };

  const renderFrame = (initial = false) => {
    if (!stage) return;
    if (writeBlocked) {
      dirty = true;
      if (stats) stats.skipped += 1;
      return;
    }
    dirty = false;
    const renderStart = performance.now();
    const dimensions = { columns: stdout.columns || 80, lines: stdout.rows || 24 };
    applyUniforms(stage, dimensions);
    if (setFocused) setFocused(focused ? 1 : 0);
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
      // A channel keeps the last row free for its status line.
      ...layoutImage({
        ...image, size, cell, columns: dimensions.columns,
        window: window && channel
          ? { ...window, height: Math.max(1, window.height - (cell?.height || window.height / dimensions.lines)) }
          : window,
      }),
    };
    const id = imageID;
    imageID = imageID === 1 ? 2 : 1;
    // Place the new image before deleting the old one so the terminal never shows a gap.
    const frame = SYNC_BEGIN + "\x1b[H" +
      kittyImage({ id, ...image, columns: layout.columns, transport, fileIndex: fileIndex++ }) +
      (shownID ? kittyDelete(shownID) : "") + statusLine() + SYNC_END;
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

  // Channel mode: renders once after a burst of log entries, such as a replay.
  let renderTimer = null;
  const renderSoon = () => {
    dirty = true;
    renderTimer ??= setImmediate(() => {
      renderTimer = null;
      if (settled || !dirty || writeBlocked) return;
      try { renderFrame(false); } catch (error) { fail(error); }
    });
  };

  // Channel mode: applies one log entry. Only the times and inputs in the log, and the
  // wakes that they cause, change the component's state, so every client reaches the
  // same state.
  let loadedStage = null;
  let loading = false;
  let channelClosed = false;
  let channelTimer = null;
  const timeline = new ChannelTimeline({
    reset: (entry) => {
      // A module entry uses the instance that the loader made. A replay makes a new one.
      useStage(loadedStage ?? stage.fresh(), entry.input);
      loadedStage = null;
      applyUniforms(stage, { columns: stdout.columns || 80, lines: stdout.rows || 24 });
      unpackRender(stage, exports.render(source.byteLength));
      channel.onStage?.(stage, timeline);
    },
    update: (time, inputs) => {
      beginUpdate(time);
      let accepted = false;
      for (const event of inputs) {
        if (event.type === "key" && keyEvent) accepted = keyEvent(event.keysym, event.flags) === 1 || accepted;
        else if (event.type === "pointer" && pointerEvent) accepted = pointerEvent(event.mask, event.x, event.y) === 1 || accepted;
      }
      return { wake: finishUpdate(), accepted };
    },
  });
  // Runs the next wake when the estimated channel clock reaches it.
  const scheduleChannelWake = () => {
    if (channelTimer !== null) clearTimeout(channelTimer);
    channelTimer = null;
    if (settled || channelClosed || loading || timeline.wake === null) return;
    const now = timeline.now(performance.now());
    if (now === null) return;
    const delay = Math.min(Math.max(0, Number(timeline.wake - now)), 2 ** 31 - 1);
    channelTimer = setTimeout(() => {
      channelTimer = null;
      if (settled || loading) return;
      try {
        if (timeline.advanceTo(timeline.now(performance.now()))) renderSoon();
        scheduleChannelWake();
      } catch (error) {
        fail(error);
      }
    }, delay);
  };
  const applyEntry = async (entry) => {
    if (entry.type === "prefetch") return channel.loader.prefetch(entry);
    if (entry.type === "closed") {
      // No entry follows, so no later time confirms a wake. The last frame stays.
      channelClosed = true;
      return scheduleChannelWake();
    }
    timeline.observe(entry.time, performance.now());
    if (entry.type === "module") {
      loading = true;
      try {
        loadedStage = await channel.loader.load(entry);
      } finally {
        loading = false;
      }
      if (settled) return;
      timeline.startModule(entry);
      pointerMask = 0;
      pointerInside = false;
      renderSoon();
    } else if (timeline.applyUpdate(entry)) renderSoon();
    scheduleChannelWake();
  };

  // Channel mode: keys and pointer events go to the server. Focus stays local,
  // which is safe because it only affects rendering.
  const sendEvents = (events) => {
    const inputs = [];
    for (const event of events) {
      if (event.type === "key") {
        inputs.push({ type: "key", keysym: event.keysym, flags: event.flags | FLAG_KEY_DOWN });
        inputs.push({ type: "key", keysym: event.keysym, flags: event.flags & ~FLAG_KEY_DOWN });
      } else if (event.type === "pointer") inputs.push(event);
    }
    if (inputs.length) client.send(inputs);
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
    } else if (report.type === "focus") {
      if (!report.focused && (pointerMask || pointerInside)) {
        pointerMask = 0;
        pointerInside = false;
        queued.push({ type: "pointer", mask: 0, x: -1, y: -1 });
      }
      // Terminals may repeat a focus report, so only real changes redraw. The
      // next render passes the new value; no update runs.
      if (setFocused && report.focused !== focused && layout) dirty = true;
      focused = report.focused;
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
      if (events.length && channel) sendEvents(events);
      else if (events.length) {
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
    if (channel) {
      channel.loader ??= createChannelStageLoader({ transforms, fetch: channel.fetch });
      client = new ChannelClient({
        url: channel.url, view: channel.view, fetch: channel.fetch, retryMS: channel.retryMS, apply: applyEntry,
        onTime: (time) => {
          timeline.observe(time, performance.now());
          scheduleChannelWake();
        },
        onStatus: (status) => {
          statusText = channelStatusText(status);
          if (terminalActive && !settled) stdout.write(statusLine());
        },
      });
      client.setStatus({});
      // After the closed entry the last frame stays up until the user exits.
      client.run().catch(fail);
    } else {
      renderFrame(true);
      runUpdate([]);
    }
    await done;
  } finally {
    client?.stop();
    if (renderTimer !== null) clearImmediate(renderTimer);
    if (channelTimer !== null) clearTimeout(channelTimer);
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
  return `Usage: qipgui [host ...] [options] <gui.wasm> [transform.wasm ...]\n` +
    `       qipgui connect [options] <channel-url> [transform.wasm ...]\n\n` +
    `The first component renders and receives keys and pointer events. Each later\n` +
    `component transforms the frame before it, and the last must output KTX2 RGBA8.\n` +
    `Components may be local files or host/path.wasm downloads over HTTPS. Leading\n` +
    `hosts such as qip.dev supply relative components that are missing locally; each\n` +
    `component tries them in order, so a pipeline may mix hosts.\n\n` +
    `  -i, --input <file|->       Initial input for the first component, or piped stdin\n` +
    `  -u, --uniform <name=n>     Set a numeric uniform on the preceding component\n` +
    `      --size <mode>          auto (1:1, shrink to fit), native, or fill\n` +
    `      --transport <mode>     direct (base64 RGBA), zlib, or file (local terminals only)\n` +
    `      --stats                Print frame rate, bytes and input latency on exit\n` +
    `  -h, --help                 Show this help\n\n` +
    `connect joins a shared channel. Unlike the local form, it uses the network while it\n` +
    `runs: the channel's server chooses the component, and your keys and pointer events\n` +
    `are sent to that server when the URL permits editing. It asks before it starts.\n\n` +
    `      --view                 Only watch: never send input\n` +
    `  -y, --yes                  Do not ask before input is sent to the server\n\n` +
    `Requires a terminal with the Kitty graphics protocol and SGR pixel mouse reports.\n` +
    `Ctrl-C exits.\n\n` +
    `Examples:\n` +
    `  qipgui gui/calculator.wasm\n` +
    `  qipgui qip.dev gui/calculator.wasm\n` +
    `  qipgui --stats --transport zlib gui/snake.wasm\n` +
    `  qipgui gui/klondike.wasm image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm\n` +
    `  qipgui connect https://sync.example.org/v1/channels/Rk3v...\n`;
}

// Uniforms before the first component apply to it, so `-u name=n gui.wasm` keeps working.
export function parseArgs(args) {
  const options = { components: [], hosts: [], input: undefined, size: "auto", transport: "direct", stats: false };
  const leading = [];
  // connect takes a channel URL in place of the first component. The components after it
  // are local transforms.
  const connect = args[0] === "connect";
  if (connect) Object.assign(options, { connect: null, view: false, yes: false });
  for (let index = connect ? 1 : 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "-h" || arg === "--help") return { help: true };
    if (arg === "--stats") options.stats = true;
    else if (connect && arg === "--view") options.view = true;
    else if (connect && (arg === "-y" || arg === "--yes")) options.yes = true;
    else if (connect && (arg === "-i" || arg === "--input")) throw new Error("connect takes its input from the channel, not from -i");
    else if (connect && !arg.startsWith("-") && options.connect === null) options.connect = arg;
    else if (connect && (arg === "-u" || arg === "--uniform") && !options.components.length) {
      throw new Error("with connect, -u must follow a transform; the channel's component takes no local uniforms");
    }
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
    else if (!options.components.length && !arg.endsWith(".wasm") && !arg.includes("/") && hostedPath(`${arg}/component.wasm`)) {
      options.hosts.push(arg.toLowerCase());
    } else options.components.push({ path: arg, uniforms: options.components.length ? [] : leading });
  }
  if (connect) {
    if (options.connect === null) throw new Error("qipgui connect requires a channel URL; run --help for usage");
    if (options.hosts.length) throw new Error("qipgui connect takes a channel URL and then transforms, not a leading host");
    delete options.input;
    return options;
  }
  if (!options.components.length) throw new Error("qipgui requires a component; run --help for usage");
  return options;
}

// Says what leaves this machine, and asks before any input can be sent.
export async function confirmConnect(host, { stdin = process.stdin, stderr = process.stderr } = {}) {
  if (!stdin.isTTY) throw new Error("qipgui connect sends your input to a server; pass --yes to permit that, or --view to only watch");
  const prompt = createInterface({ input: stdin, output: stderr });
  try {
    const answer = await prompt.question(
      `qipgui connect is not local. ${host} chooses the component that runs here.\n` +
      `If this URL permits editing, your keys and pointer events in this window are sent to ${host}.\n` +
      `Use --view to only watch. Continue? [y/N] `,
    );
    return /^y(es)?$/i.test(answer.trim());
  } finally {
    prompt.close();
  }
}

async function connect(options) {
  // Checks the URL before the prompt, so the host that the prompt names is the real one.
  const { host } = new ChannelClient({ url: options.connect, apply: () => {} });
  const transforms = [];
  for (const { path, uniforms } of options.components) {
    const data = await loadWasm(path, (bytes) => validateTransformBinary(bytes, path));
    transforms.push(createStage(data, path, uniforms));
  }
  if (!options.view && !options.yes && !(await confirmConnect(printable(host)))) {
    process.exitCode = 1;
    return;
  }
  await runGUI({
    transforms, size: options.size, transport: options.transport, stats: options.stats ? new Stats() : null,
    channel: { url: options.connect, view: options.view },
  });
}

export async function main(args = process.argv.slice(2)) {
  const options = parseArgs(args);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  if (options.connect !== undefined) return connect(options);
  const stages = [];
  for (const { path, uniforms } of options.components) {
    const validate = stages.length ? validateTransformBinary : validateGUIBinary;
    const data = await loadWasm(path, (bytes) => validate(bytes, path), options.hosts);
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
