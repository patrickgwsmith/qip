// <qip-play> through its public lifecycle only: connectedCallback, DOM events on
// the surface it builds, animation frames and timers. It never reads or calls
// the element's private fields, so it guards refactors of the internals.
//
// Real components come from the repo; contract edge cases use fake components,
// served as tiny valid Wasm modules whose instantiation is swapped for a JS
// exports object.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mock, test } from "node:test";

// ---- Fake DOM ---------------------------------------------------------------

function callListener(listener, event) {
  if (typeof listener === "function") listener(event);
  else listener.handleEvent(event);
}

class FakeNode {
  constructor(localName = "", attributes = {}) {
    this.localName = localName;
    this.attributes = new Map(Object.entries(attributes));
    this.children = [];
    this.style = {};
    this.listeners = [];
    this.textContent = "";
    this.tabIndex = -1;
    this.focusN = 0;
  }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  hasAttribute(name) { return this.attributes.has(name); }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  removeAttribute(name) { this.attributes.delete(name); }
  getAttributeNames() { return [...this.attributes.keys()]; }
  get value() { return this.attributes.get("value") ?? ""; }
  addEventListener(type, listener, options) {
    const capture = options === true || options?.capture === true;
    if (options?.signal?.aborted) return;
    this.listeners.push({ type, listener, capture });
    options?.signal?.addEventListener("abort", () => this.removeEventListener(type, listener, { capture }), { once: true });
  }
  removeEventListener(type, listener, options) {
    const capture = options === true || options?.capture === true;
    this.listeners = this.listeners.filter((entry) =>
      entry.type !== type || entry.listener !== listener || entry.capture !== capture);
  }
  listenerTypes() { return this.listeners.map((entry) => entry.type).sort(); }
  fire(type, init = {}) {
    const event = {
      type, defaultPrevented: false, propagationStopped: false, repeat: false,
      key: "", code: "", buttons: 0, clientX: 0, clientY: 0, pointerId: 1, pointerType: "mouse",
      ...init,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.propagationStopped = true; },
    };
    for (const entry of [...this.listeners]) if (entry.type === type) callListener(entry.listener, event);
    return event;
  }
  replaceChildren(...children) { this.children = children; }
  appendChild(child) { this.children.push(child); return child; }
  replaceWith() {}
  focus() { this.focusN++; }
  getBoundingClientRect() { return { left: 0, top: 0, width: this.rectWidth ?? 100, height: this.rectHeight ?? 100 }; }
  setPointerCapture() {}
  hasPointerCapture() { return false; }
  releasePointerCapture() {}
  querySelector(selector) {
    if (selector !== 'input[name="input"], textarea[name="input"]') throw new Error("unexpected selector " + selector);
    const walk = (node) => {
      for (const child of node.children) {
        if ((child.localName === "input" || child.localName === "textarea") && child.getAttribute("name") === "input") return child;
        const found = walk(child);
        if (found) return found;
      }
      return null;
    };
    return walk(this);
  }
}

class FakeCanvas extends FakeNode {
  constructor() {
    super("canvas");
    this.draws = [];
  }
  getContext() {
    const canvas = this;
    return {
      createImageData(width, height) { return { width, height, data: new Uint8ClampedArray(width * height * 4) }; },
      putImageData(imageData) { canvas.draws.push(imageData.data.slice()); },
    };
  }
}

let QIPPlayElement;
let rafCallbacks = [];
let clock = 1000;
const documentListeners = [];

globalThis.HTMLElement = class extends FakeNode { constructor() { super("qip-play"); } };
globalThis.customElements = {
  get() { return undefined; },
  define(name, value) { if (name === "qip-play") QIPPlayElement = value; },
};
globalThis.document = {
  baseURI: "http://example.test/",
  hidden: false,
  activeElement: null,
  pointerLockElement: null,
  createElement(name) { return name === "canvas" ? new FakeCanvas() : new FakeNode(name); },
  addEventListener(type, listener, options) {
    if (options?.signal?.aborted) return;
    documentListeners.push({ type, listener });
    options?.signal?.addEventListener("abort", () => this.removeEventListener(type, listener), { once: true });
  },
  removeEventListener(type, listener) {
    const index = documentListeners.findIndex((entry) => entry.type === type && entry.listener === listener);
    if (index !== -1) documentListeners.splice(index, 1);
  },
};
globalThis.getComputedStyle = () => ({ getPropertyValue() { return ""; } });
globalThis.requestAnimationFrame = (callback) => rafCallbacks.push(callback);
globalThis.cancelAnimationFrame = (id) => { if (id > 0) rafCallbacks[id - 1] = null; };
globalThis.DOMParser = class {
  parseFromString(markup) {
    const match = /^<(\w+)(?:\s+xmlns="([^"]*)")?/.exec(markup.trim());
    return { documentElement: { localName: match?.[1], namespaceURI: match?.[2] ?? null, style: {}, markup } };
  }
};
Object.defineProperty(globalThis, "performance", { value: { now: () => clock }, configurable: true });

await import("../site/_elements/qip-play.js");

// ---- Fake components and fetch -------------------------------------------

const fakes = new Map();
// A valid empty module with a custom section naming the fake it stands for.
function fakeModuleBytes(name) {
  const nameBytes = new TextEncoder().encode(name);
  return new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 0, nameBytes.length + 1, nameBytes.length, ...nameBytes]);
}
const realInstantiate = WebAssembly.instantiate;
WebAssembly.instantiate = async (bytes, imports) => {
  const view = new Uint8Array(bytes);
  if (view.length > 11 && view[8] === 0) {
    const name = new TextDecoder().decode(view.subarray(11, 11 + view[10]));
    if (fakes.has(name)) return { instance: { exports: fakes.get(name)() } };
  }
  return realInstantiate(bytes, imports);
};
globalThis.fetch = async (url) => {
  const path = new URL(url).pathname;
  if (path.startsWith("/fake/")) {
    const name = path.slice("/fake/".length);
    return { ok: true, status: 200, arrayBuffer: async () => fakeModuleBytes(name).buffer };
  }
  try {
    const bytes = readFileSync(path.slice(1));
    return { ok: true, status: 200, arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) };
  } catch {
    return { ok: false, status: 404 };
  }
};

function writeText(memory, ptr, text) {
  const bytes = new TextEncoder().encode(text);
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return bytes.length;
}

// Interactive component that renders `output()` (a string or bytes) at offset 4096.
function fakeComponent({ type = "image/svg+xml", output = () => '<svg xmlns="http://www.w3.org/2000/svg"/>', pages = 1, extra = {} } = {}) {
  return () => {
    const memory = new WebAssembly.Memory({ initial: pages });
    const typeLen = writeText(memory, 0, type);
    const log = [];
    const exports = {
      memory,
      log,
      output_content_type_ptr: () => 0,
      output_content_type_size: () => typeLen,
      output_utf8_cap: () => 60000,
      begin_update_at(at) { log.push(["begin", at]); exports.at = at; },
      // Returning the update time itself requests no wake.
      finish_update() { log.push(["finish"]); return exports.at; },
      render(inputSize) {
        log.push(["render", inputSize]);
        const value = output(inputSize, exports);
        if (typeof value === "bigint") return value;
        const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
        new Uint8Array(memory.buffer, 4096, bytes.length).set(bytes);
        return (4096n << 32n) | BigInt(bytes.length);
      },
      ...extra,
    };
    return exports;
  };
}

// ---- Helpers ------------------------------------------------------------------

function source(src, attributes = {}) {
  return new FakeNode("source", { src, type: "application/wasm", ...attributes });
}

async function mount(children, attributes = {}) {
  rafCallbacks = [];
  const element = new QIPPlayElement();
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
  element.children = children;
  await element.connectedCallback();
  return element;
}

function runFrames(limit = 10) {
  for (let i = 0; i < limit; i++) {
    const callbacks = rafCallbacks.filter(Boolean);
    rafCallbacks = [];
    if (callbacks.length === 0) return i;
    for (const callback of callbacks) callback(clock);
  }
  return limit;
}

function advance(ms) {
  clock += ms;
  mock.timers.tick(ms);
}

const surfaceOf = (element) => element.children[0];
const statsOf = (element) => element.children.find((child) => child.getAttribute("aria-label") === "qip-play stats");
const errorOf = (element) => element.children.find((child) => child.getAttribute("role") === "alert")?.textContent ?? null;
const lastSVG = (element) => surfaceOf(element).children[0].markup;

// ---- Tests --------------------------------------------------------------------

test("a real KTX2 component draws its first frame and redraws after a key", async () => {
  const element = await mount([source("/gui/calculator.wasm")]);
  const canvas = surfaceOf(element);
  assert.equal(errorOf(element), null);
  assert.equal(canvas.localName, "canvas");
  assert.deepEqual([canvas.width, canvas.height], [220, 220]);
  assert.equal(canvas.style.width, "220px");
  assert.equal(canvas.style.touchAction, "none");
  assert.equal(canvas.tabIndex, 0);
  assert.equal(canvas.draws.length, 1);
  assert.equal(statsOf(element).style.maxWidth, "220px");
  assert.match(statsOf(element).textContent,
    /^wasm 3\.9 kB \| memory 1\.2 MB \| output rgba-unorm8 srgb \| canvas rgba-unorm8 srgb \| update +0 \d+\.\d ms \| render +1 \d+\.\d ms$/);
  assert.deepEqual(canvas.listenerTypes(), [
    "blur", "click", "contextmenu", "keydown", "keyup", "pointercancel", "pointerdown", "pointerleave", "pointermove", "pointerup",
  ]);

  clock += 5;
  const keydown = canvas.fire("keydown", { key: "7", code: "Digit7" });
  assert.equal(keydown.defaultPrevented, true);
  runFrames();
  canvas.fire("keyup", { key: "7", code: "Digit7" });
  runFrames();
  assert.equal(canvas.draws.length, 2);
  assert.notDeepEqual(canvas.draws[1], canvas.draws[0]);
  assert.match(statsOf(element).textContent, /\| update +3 .*\| render +2 /);

  element.disconnectedCallback();
  assert.deepEqual(canvas.listenerTypes(), []);
  assert.equal(documentListeners.length, 0);
});

test("pointer buttons map to QIP masks and coordinates clamp to the render size", async () => {
  const events = [];
  fakes.set("pointer", fakeComponent({
    extra: { pointer_event(mask, x, y) { events.push([mask, x, y]); return 1; } },
  }));
  const element = await mount([source("/fake/pointer")], { "svg-inline": "", "svg-width": "200", "svg-height": "100" });
  const surface = surfaceOf(element);
  surface.rectWidth = 400;
  surface.rectHeight = 200;
  surface.fire("pointerdown", { buttons: 1, clientX: 100, clientY: 50 });
  surface.fire("pointermove", { buttons: 2, clientX: 500, clientY: -10 });
  surface.fire("pointermove", { buttons: 4, clientX: -3, clientY: 199.9 });
  surface.fire("pointerup", { buttons: 7, clientX: 399, clientY: 0 });
  surface.fire("pointerleave");
  runFrames();
  assert.deepEqual(events, [[1, 50, 25], [4, 199, 0], [2, 0, 99], [7, 199, 0], [0, -1, -1]]);
  assert.equal(surface.focusN, 1);
  element.disconnectedCallback();
});

const step = (name, ...sources) => Object.assign(new FakeNode("qip-step", { name }), { children: sources });

test("pointer coordinates use the first component's size when a later step resizes it", async () => {
  // The real calculator (220x220 KTX2), with pointer_event wrapped to record coordinates.
  const calculator = (await realInstantiate(readFileSync("gui/calculator.wasm"))).instance.exports;
  const events = [];
  fakes.set("logged-calculator", () => ({
    ...calculator,
    pointer_event(mask, x, y) { events.push([mask, x, y]); return calculator.pointer_event(mask, x, y); },
  }));
  const element = await mount([
    step("calculator", source("/fake/logged-calculator")),
    step("resize", source("/image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm", { "data-uniform-width": "440" })),
  ]);
  assert.equal(errorOf(element), null);
  const canvas = surfaceOf(element);
  assert.deepEqual([canvas.width, canvas.height], [440, 440]);
  canvas.fire("pointerdown", { buttons: 1, clientX: 50, clientY: 25 });
  canvas.fire("pointerup", { buttons: 0, clientX: 99.9, clientY: 99.9 });
  runFrames();
  assert.deepEqual(events, [[1, 110, 55], [0, 219, 219]]);
  element.disconnectedCallback();
});

test("pointer coordinates use svg-width/svg-height when an SVG is rasterized by a later step", async () => {
  const events = [];
  fakes.set("small-svg", fakeComponent({
    output: () => '<svg xmlns="http://www.w3.org/2000/svg" width="50" height="25"><rect width="50" height="25" fill="#f00"/></svg>',
    extra: { pointer_event(mask, x, y) { events.push([mask, x, y]); return 1; } },
  }));
  const element = await mount([
    step("svg", source("/fake/small-svg")),
    step("rasterize", source("/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm")),
  ], { "svg-width": "200", "svg-height": "100" });
  assert.equal(errorOf(element), null);
  const canvas = surfaceOf(element);
  assert.deepEqual([canvas.width, canvas.height], [50, 25]);
  canvas.fire("pointerdown", { buttons: 1, clientX: 50, clientY: 50 });
  runFrames();
  assert.deepEqual(events, [[1, 100, 50]]);
  element.disconnectedCallback();
});

test("Meta shortcuts reach the component only for editing and navigation keys", async () => {
  const keys = [];
  fakes.set("keys", fakeComponent({ extra: { key_event(keysym, flags) { keys.push([keysym, flags]); return 1; } } }));
  const element = await mount([source("/fake/keys")], { "svg-inline": "" });
  const surface = surfaceOf(element);
  const press = (init) => {
    const down = surface.fire("keydown", init);
    surface.fire("keyup", init);
    return down.defaultPrevented;
  };
  assert.equal(press({ key: "r", code: "KeyR", metaKey: true }), false);
  assert.equal(press({ key: "c", code: "KeyC", metaKey: true }), true);
  assert.equal(press({ key: "c", code: "KeyC", metaKey: true, ctrlKey: true }), false);
  assert.equal(press({ key: "ArrowLeft", code: "ArrowLeft", metaKey: true }), true);
  assert.equal(press({ key: "Unidentified" }), false);
  runFrames();
  assert.deepEqual(keys, [[0x63, 33], [0x63, 32], [0xff51, 33], [0xff51, 32]]);
  element.disconnectedCallback();
});

test("held keys repeat on the host's schedule and release on blur", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const keys = [];
    const pointers = [];
    fakes.set("repeat", fakeComponent({
      extra: {
        key_event(keysym, flags) { keys.push([keysym, flags]); return 0; },
        pointer_event(mask, x, y) { pointers.push([mask, x, y]); return 0; },
      },
    }));
    const element = await mount([source("/fake/repeat")], { "svg-inline": "" });
    const surface = surfaceOf(element);
    surface.fire("keydown", { key: "a", code: "KeyA" });
    surface.fire("keydown", { key: "a", code: "KeyA", repeat: true }); // browser repeat: ignored
    runFrames();
    assert.deepEqual(keys, [[0x61, 1]]);
    advance(249);
    runFrames();
    assert.equal(keys.length, 1);
    advance(1);
    runFrames();
    advance(33);
    runFrames();
    assert.deepEqual(keys.slice(1), [[0x61, 3], [0x61, 3]]);
    surface.fire("blur");
    advance(100);
    runFrames();
    assert.deepEqual(keys.slice(3), [[0x61, 0]]);
    assert.deepEqual(pointers, [[0, -1, -1]]);
    element.disconnectedCallback();
  } finally {
    mock.timers.reset();
  }
});

test("render rejections report the input offset and failure mode", async () => {
  const cases = [
    [0, 0n, "Play error: qip-play input was rejected"],
    [1, 7n, "Play error: qip-play input was rejected at input offset 7"],
    [3, 7n, "Play error: qip-play input was rejected at input offset 2 with mode 1"],
    [0, 5n, "Play error: qip-play render returned failure detail despite declaring no failure modes"],
    [null, 0n, "Play error: qip-play render returned failure without failure_modes_per_input_offset"],
  ];
  for (const [modes, detail, message] of cases) {
    const extra = modes === null ? {} : { failure_modes_per_input_offset: () => modes };
    fakes.set("reject", fakeComponent({ output: () => (1n << 63n) | detail, extra }));
    assert.equal(errorOf(await mount([source("/fake/reject")])), message);
  }
  fakes.set("number-render", fakeComponent({ output: () => 0n, extra: { render: () => 0 } }));
  assert.equal(errorOf(await mount([source("/fake/number-render")])),
    "Play error: qip-play render export must have signature render(i32) -> i64");
});

test("components that break the presentation contract are reported", async () => {
  const cases = [
    [{ extra: { finish_update: undefined } }, "qip-play module missing export finish_update"],
    [{ extra: { output_bytes_cap: () => 10 } }, "qip-play module must export exactly one output capacity getter"],
    [{ extra: { output_utf8_cap: undefined, output_bytes_cap: () => 10 } }, "qip-play SVG output must declare output_utf8_cap"],
    [{ type: "text/plain" }, "qip-play presentation output must declare image/ktx2, image/svg+xml, or multipart/related with one of them as its type"],
    [{ type: 'multipart/related; type="image/svg+xml"' }, 'qip-play multipart/related output must declare type="image/ktx2" or type="image/svg+xml" and a boundary'],
    [{ output: () => "<html/>" }, "qip-play SVG output must have an SVG root element"],
    [{ pages: 2, output: () => "x".repeat(70000) }, "qip-play Timed render returned output outside its output capacity"],
  ];
  for (const [options, message] of cases) {
    const factory = fakeComponent(options);
    fakes.set("broken", () => {
      const exports = factory();
      for (const [name, value] of Object.entries(exports)) if (value === undefined) delete exports[name];
      return exports;
    });
    assert.equal(errorOf(await mount([source("/fake/broken")], { "svg-inline": "" })), "Play error: " + message);
  }
  assert.equal(errorOf(await mount([source("")])), "Play error: <qip-play> <source> requires a non-empty src");
  assert.equal(errorOf(await mount([])),
    "Play error: <qip-play> requires one direct <source> or one or more <qip-step> children");
});

test("multipart/related SVG output presents only its root part", async () => {
  const boundary = "b-123";
  const root = '<svg xmlns="http://www.w3.org/2000/svg"><text>root</text></svg>';
  const body = `--${boundary}\r\nContent-Type: image/svg+xml\r\n\r\n${root}\r\n--${boundary}\r\nContent-Type: text/plain\r\n\r\nlater\r\n--${boundary}--\r\n`;
  fakes.set("related", fakeComponent({ type: `multipart/related; type="image/svg+xml"; boundary=${boundary}`, output: () => body }));
  const element = await mount([source("/fake/related")], { "svg-inline": "" });
  assert.equal(errorOf(element), null);
  assert.equal(lastSVG(element), root);

  for (const [bad, reason] of [
    [`--other\r\n`, "must start with its boundary delimiter"],
    [`--${boundary}\r\nContent-Type: image/svg+xml\r\n`, "root part headers are unterminated"],
    [`--${boundary}\r\nContent-Type: text/plain\r\n\r\nx`, "root part must be image/svg+xml, got text/plain"],
    [`--${boundary}\r\nContent-ID: <a>\r\n\r\n${root}`, "root part must be image/svg+xml, got no Content-Type"],
    [`--${boundary}\r\nContent-Type: image/svg+xml\r\n\r\n${root}`, "root part is not followed by a boundary delimiter"],
  ]) {
    fakes.set("related", fakeComponent({ type: `multipart/related; type="image/svg+xml"; boundary=${boundary}`, output: () => bad }));
    assert.equal(errorOf(await mount([source("/fake/related")], { "svg-inline": "" })),
      "Play error: qip-play multipart/related output " + reason);
  }
});

test("stats report sizes in B, kB and MB", async () => {
  fakes.set("sizes", fakeComponent({ pages: 1600 }));
  const element = await mount([source("/fake/sizes")], { "svg-inline": "" });
  assert.match(statsOf(element).textContent, /^wasm 16 B \| memory 105 MB \| update +0 \d+\.\d ms \| render +1 \d+\.\d ms$/);
  fakes.set("sizes", fakeComponent({ pages: 2 }));
  assert.match(statsOf(await mount([source("/fake/sizes")], { "svg-inline": "" })).textContent, /memory 131 kB/);
  fakes.set("sizes", fakeComponent({ pages: 16 }));
  assert.match(statsOf(await mount([source("/fake/sizes")], { "svg-inline": "" })).textContent, /memory 1\.0 MB/);
});

test("inline input text is written to the component before its first render", async () => {
  fakes.set("input", fakeComponent({
    output: (size, exports) => {
      const text = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, 8192, size));
      return `<svg xmlns="http://www.w3.org/2000/svg"><text>${text}</text></svg>`;
    },
    extra: { input_ptr: () => 8192, input_utf8_cap: () => 64 },
  }));
  const textarea = new FakeNode("textarea", { name: "input", value: "héllo" });
  const element = await mount([textarea, source("/fake/input")], { "svg-inline": "" });
  assert.equal(lastSVG(element), '<svg xmlns="http://www.w3.org/2000/svg"><text>héllo</text></svg>');
  assert.equal(element.children[1], textarea);

  const tooLong = new FakeNode("textarea", { name: "input", value: "x".repeat(65) });
  assert.equal(errorOf(await mount([tooLong, source("/fake/input")], { "svg-inline": "" })),
    "Play error: qip-play input exceeds module input_utf8_cap: 65 > 64");
  fakes.set("no-input", fakeComponent());
  assert.equal(errorOf(await mount([new FakeNode("textarea", { name: "input" }), source("/fake/no-input")])),
    "Play error: <qip-play> input requires module exports input_ptr and input_utf8_cap or input_bytes_cap");
});

test("inline input is written to components that export input_bytes_cap", async () => {
  fakes.set("bytes-input", fakeComponent({
    output: (size, exports) => {
      const text = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, 8192, size));
      return `<svg xmlns="http://www.w3.org/2000/svg"><text>${text}</text></svg>`;
    },
    extra: { input_ptr: () => 8192, input_bytes_cap: () => 16 },
  }));
  const textarea = new FakeNode("textarea", { name: "input", value: "2026-05-31" });
  const element = await mount([textarea, source("/fake/bytes-input")], { "svg-inline": "" });
  assert.equal(lastSVG(element), '<svg xmlns="http://www.w3.org/2000/svg"><text>2026-05-31</text></svg>');

  const tooLong = new FakeNode("textarea", { name: "input", value: "x".repeat(17) });
  assert.equal(errorOf(await mount([tooLong, source("/fake/bytes-input")], { "svg-inline": "" })),
    "Play error: qip-play input exceeds module input_bytes_cap: 17 > 16");
});

test("source uniforms are applied before every update and render", async () => {
  const calls = [];
  fakes.set("uniform", fakeComponent({
    extra: {
      uniform_set_speed(value) { calls.push(["speed", value]); },
      key_event() { return 1; },
    },
  }));
  const element = await mount([source("/fake/uniform", { "data-uniform-speed": "3" })], { "svg-inline": "" });
  const exports = calls.length;
  assert.ok(exports >= 2);
  assert.deepEqual(calls[0], ["speed", 3]);
  surfaceOf(element).fire("keydown", { key: "x", code: "KeyX" });
  runFrames();
  assert.ok(calls.length > exports);
  element.disconnectedCallback();
});

test("a timed component's wake is scheduled on a timer and stops after disconnect", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    let frame = 0;
    fakes.set("timed", fakeComponent({
      output: () => `<svg xmlns="http://www.w3.org/2000/svg"><text>${frame}</text></svg>`,
      extra: {
        begin_update_at(at) { this.at = at; },
        finish_update() { frame++; return this.at + 100n; },
      },
    }));
    const element = await mount([source("/fake/timed")], { "svg-inline": "" });
    assert.equal(lastSVG(element), '<svg xmlns="http://www.w3.org/2000/svg"><text>0</text></svg>');
    assert.match(statsOf(element).textContent, /\| render +1 /);
    // The bootstrap update at time 1 asked to wake at 101.
    advance(100);
    runFrames();
    assert.equal(lastSVG(element), '<svg xmlns="http://www.w3.org/2000/svg"><text>0</text></svg>');
    advance(1);
    runFrames();
    assert.equal(lastSVG(element), '<svg xmlns="http://www.w3.org/2000/svg"><text>2</text></svg>');
    assert.match(statsOf(element).textContent, /\| render +2 /);
    element.disconnectedCallback();
    const before = frame;
    advance(1000);
    runFrames();
    assert.equal(frame, before);
  } finally {
    mock.timers.reset();
  }
});
