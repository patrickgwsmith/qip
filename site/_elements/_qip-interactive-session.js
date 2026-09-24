// The Time and Events ABI shared by browser GUI and TUI hosts. Presentation,
// input policy, and scheduling stay with the owning element.

function decodeRenderResult(result, capacity, memory, label = "component") {
  if (typeof result !== "bigint") {
    throw new TypeError(label + " render export must have signature render(i32) -> i64");
  }
  const bits = BigInt.asUintN(64, result);
  const size = Number(bits & 0xffff_ffffn);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    return { failed: true, detail: size };
  }
  if (size > capacity || pointer + size > memory.buffer.byteLength) {
    throw new Error(label + " render returned output outside its declared buffer");
  }
  return { failed: false, pointer, size };
}

function mapKeyboardEventToKeysym(event) {
  const key = event.key || "";
  const named = {
    ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54,
    Home: 0xff50, End: 0xff57, PageUp: 0xff55, PageDown: 0xff56,
    Insert: 0xff63, Delete: 0xffff, Escape: 0xff1b, Enter: 0xff0d,
    Tab: 0xff09, Backspace: 0xff08, " ": 0x20,
  };
  if (Object.hasOwn(named, key)) return named[key];
  if (key === "Shift") return event.location === 2 ? 0xffe2 : 0xffe1;
  if (key === "Alt") return event.location === 2 ? 0xffea : 0xffe9;
  if (/^F(?:[1-9]|1[0-2])$/.test(key)) return 0xffbe + Number(key.slice(1)) - 1;
  return [...key].length === 1 ? key.codePointAt(0) : null;
}

function keyFlags(event, down) {
  return (down ? 1 : 0) | (event.repeat ? 2 : 0) |
    (event.shiftKey ? 4 : 0) | (event.ctrlKey ? 8 : 0) |
    (event.altKey ? 16 : 0) | (event.metaKey ? 32 : 0);
}

class QIPInteractiveSession {
  constructor(exportsObj, memory) {
    for (const name of ["begin_update_at", "finish_update", "render"]) {
      if (typeof exportsObj[name] !== "function") throw new Error("component missing export " + name);
    }
    this.exports = exportsObj;
    this.memory = memory;
    this.finishedAt = 0;
    this.nextWakeAt = 0;
  }

  begin(nowMS) {
    const at = Math.max(1, Math.floor(nowMS), this.finishedAt + 1);
    this.exports.begin_update_at(BigInt(at));
    return at;
  }

  finish(at) {
    const raw = this.exports.finish_update();
    if (typeof raw !== "bigint") throw new TypeError("finish_update must return i64");
    const bounded = raw > BigInt(Number.MAX_SAFE_INTEGER) ? Number.MAX_SAFE_INTEGER : Number(raw);
    if (bounded < at) throw new Error("finish_update returned a time before the update time");
    this.finishedAt = at;
    this.nextWakeAt = bounded === at ? 0 : bounded;
    return this.nextWakeAt;
  }

  update(nowMS, events = [], uniforms = null) {
    const at = this.begin(nowMS);
    if (uniforms) uniforms();
    let accepted = false;
    for (const event of events) {
      if (event.type === "key" && typeof this.exports.key_event === "function") {
        accepted = this.exports.key_event(event.keysym, event.flags) !== 0 || accepted;
      } else if (event.type === "pointer" && typeof this.exports.pointer_event === "function") {
        accepted = this.exports.pointer_event(event.buttonMask, event.x, event.y) !== 0 || accepted;
      }
    }
    return { accepted, nextWakeAt: this.finish(at), at };
  }
}

export { QIPInteractiveSession, decodeRenderResult, mapKeyboardEventToKeysym, keyFlags };
