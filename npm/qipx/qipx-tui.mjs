import process from "node:process";

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

export function decodeTerminalBytes(bytes, { final = true } = {}) {
  const events = [];
  const input = new TerminalKeyDecoder((event) => events.push(event));
  input.push(bytes);
  if (final) input.flush();
  return events;
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

export async function runTUI({ pipeline, input, applyUniforms, transformOutput, stdin = process.stdin, stdout = process.stdout }) {
  if (!stdin.isTTY || !stdout.isTTY || typeof stdin.setRawMode !== "function") {
    throw new Error("tui requires terminal stdin and stdout");
  }
  const stage = pipeline.stages[0];
  const exports = stage.component.exports;
  const beginUpdate = requireFunction(exports, "begin_update_at", 1);
  const finishUpdate = requireFunction(exports, "finish_update", 0);
  const keyEvent = requireFunction(exports, "key_event", 2);
  for (const post of pipeline.stages.slice(1)) {
    if (typeof post.component.exports.begin_update_at === "function" || typeof post.component.exports.finish_update === "function") {
      throw new Error(`${post.label} must be a Content component when used after a TUI component`);
    }
  }

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
      const primary = unpackRender(stage, packed);
      const output = transformOutput(primary, dimensions);
      if (output.encoding !== "utf8") throw new Error("TUI pipeline must produce UTF-8 output");
      const safe = validateTerminalFrame(output.bytes);
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
