import assert from "node:assert/strict";
import test from "node:test";

let QIPPlayElement;
globalThis.HTMLElement = class {
  constructor() { this.children = []; this._attrs = new Map(); }
  hasAttribute(name) { return this._attrs.has(name); }
  getAttribute(name) { return this._attrs.get(name) || ""; }
  removeAttribute(name) { this._attrs.delete(name); }
  querySelector() { return null; }
  addEventListener() {}
  removeEventListener() {}
};
globalThis.customElements = {
  get() { return undefined; },
  define(name, value) { if (name === "qip-play") QIPPlayElement = value; },
};

function imageElement() {
  return {
    style: {}, tabIndex: -1, draggable: true, src: "", onload: null, onerror: null,
    focused: false, captured: [], released: [], children: [], attributes: new Map(),
    addEventListener() {}, removeEventListener() {},
    setAttribute(name, value) { this.attributes.set(name, value); },
    replaceChildren(...children) { this.children = children; },
    focus() { this.focused = true; },
    setPointerCapture(id) { this.captured.push(id); },
    hasPointerCapture(id) { return this.captured.includes(id); },
    releasePointerCapture(id) { this.released.push(id); },
    getBoundingClientRect() { return { left: 10, top: 20, width: 400, height: 300 }; },
  };
}

globalThis.document = {
  baseURI: "http://example.test/", hidden: false, activeElement: null,
  createElement(name) { return name === "img" || name === "div" ? imageElement() : { style: {}, setAttribute() {} }; },
  addEventListener() {}, removeEventListener() {},
};
globalThis.getComputedStyle = () => ({ getPropertyValue() { return ""; } });
await import("../site/_elements/qip-play.js");

function inputExports() {
  const memory = new WebAssembly.Memory({ initial: 2 });
  new TextEncoder().encodeInto("image/svg+xml", new Uint8Array(memory.buffer, 0, 13));
  return {
    memory,
    input_ptr() { return 100; },
    input_utf8_cap() { return 1024; },
    input_content_type_ptr() { return 0; },
    input_content_type_size() { return 13; },
  };
}

test("named source input takes precedence over inline input and is initialization-only", async () => {
  const element = new QIPPlayElement();
  const exports = inputExports();
  element._exports = exports;
  element._memory = exports.memory;
  const source = { getAttribute(name) { return name === "src" ? "/drawing.svg" : name === "type" ? "image/svg+xml" : ""; } };
  const inline = { value: "<svg id=\"inline\"/>", textContent: "", removeEventListener() {} };
  const oldFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, async text() { return "<svg id=\"source\"/>"; } });
  try { await element._setupInitialInput(source, inline); } finally { globalThis.fetch = oldFetch; }
  const text = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, 100, element._inputSize));
  assert.equal(text, '<svg id="source"/>');
  assert.equal(element._boundInputChange, null);
});

test("SVG image is focusable, non-draggable, captures pointers, and maps to 800 by 600", () => {
  const element = new QIPPlayElement();
  const events = [];
  element._exports = { pointer_event(mask, x, y) { events.push({ mask, x, y }); return 1; } };
  element._memory = new WebAssembly.Memory({ initial: 1 });
  element._resumeLoop = () => {};
  element._installSVGPresentation();
  assert.equal(element._canvas.draggable, false);
  assert.equal(element._canvas.tabIndex, 0);
  const native = { type: "pointerdown", pointerId: 7, buttons: 1, clientX: 210, clientY: 170, preventDefault() {} };
  element._dispatchPointer(native);
  assert.equal(element._canvas.focused, true);
  assert.deepEqual(element._canvas.captured, [7]);
  assert.deepEqual(element._pendingEvents[0], { type: "pointer", buttonMask: 1, x: 400, y: 300, timeMS: 0, sequence: 1 });
});

test("pointer modifiers recover Shift when the SVG gains focus on pointerdown", () => {
  const element = new QIPPlayElement();
  element._exports = { key_event() { return 0; }, pointer_event() { return 1; } };
  element._memory = new WebAssembly.Memory({ initial: 1 });
  element._resumeLoop = () => {};
  element._installSVGPresentation();
  element._dispatchPointer({
    type: "pointerdown", pointerId: 8, buttons: 1, shiftKey: true, altKey: false,
    clientX: 110, clientY: 70, preventDefault() {},
  });
  assert.deepEqual(element._pendingEvents.map(({ type, keysym, flags, buttonMask }) => ({ type, keysym, flags, buttonMask })), [
    { type: "key", keysym: 0xffe1, flags: 5, buttonMask: undefined },
    { type: "pointer", keysym: undefined, flags: undefined, buttonMask: 1 },
  ]);
});

test("SVG presentation revokes the replaced Blob URL after the current load", () => {
  const element = new QIPPlayElement();
  element._memory = new WebAssembly.Memory({ initial: 1 });
  element._steps = [];
  element._installSVGPresentation();
  const created = [];
  const revoked = [];
  const oldCreate = URL.createObjectURL;
  const oldRevoke = URL.revokeObjectURL;
  URL.createObjectURL = () => `blob:test-${created.push(1)}`;
  URL.revokeObjectURL = (url) => revoked.push(url);
  const bytes = new TextEncoder().encode("<svg/>");
  new Uint8Array(element._memory.buffer, 0, bytes.length).set(bytes);
  const rendered = { memory: element._memory, outputPtr: 0, outputLen: bytes.length, outputCapacity: 1024 };
  try {
    element._presentSVGOutput(rendered, 1, "initial");
    const staleLoad = element._canvas.onload;
    element._presentSVGOutput(rendered, 1);
    staleLoad();
    assert.deepEqual(revoked, []);
    element._canvas.onload();
    assert.deepEqual(revoked, ["blob:test-1"]);
    element.disconnectedCallback();
    assert.deepEqual(revoked, ["blob:test-1", "blob:test-2"]);
  } finally {
    URL.createObjectURL = oldCreate;
    URL.revokeObjectURL = oldRevoke;
  }
});

test("inline SVG swaps only the child and keeps the focused pointer surface", () => {
  const element = new QIPPlayElement();
  element._attrs.set("svg-inline", "");
  element._memory = new WebAssembly.Memory({ initial: 1 });
  element._steps = [];
  element._installSVGPresentation();
  const surface = element._canvas;
  const oldParser = globalThis.DOMParser;
  const oldCreate = URL.createObjectURL;
  globalThis.DOMParser = class {
    parseFromString(markup, type) {
      assert.equal(type, "image/svg+xml");
      return { documentElement: { localName: "svg", namespaceURI: "http://www.w3.org/2000/svg", style: {}, markup } };
    }
  };
  URL.createObjectURL = () => { throw new Error("inline SVG must not create a Blob URL"); };
  try {
    surface.focus();
    surface.setPointerCapture(5);
    for (const markup of ["<svg id=\"first\"/>", "<svg id=\"second\"/>"]) {
      const bytes = new TextEncoder().encode(markup);
      new Uint8Array(element._memory.buffer, 0, bytes.length).set(bytes);
      element._presentSVGOutput({ memory: element._memory, outputPtr: 0, outputLen: bytes.length, outputCapacity: 1024 }, 1);
      assert.equal(element._canvas, surface);
      assert.equal(surface.children.length, 1);
    }
    assert.equal(surface.children[0].markup, '<svg id="second"/>');
    assert.equal(surface.focused, true);
    assert.deepEqual(surface.captured, [5]);
    assert.equal(surface.children[0].style.width, "100%");
    assert.equal(surface.style.userSelect, "text");
    element._exports = { pointer_event() { return 0; } };
    element._resumeLoop = () => {};
    let prevented = 0;
    element._dispatchPointer({
      type: "pointerdown", pointerType: "mouse", pointerId: 6, buttons: 1,
      clientX: 110, clientY: 70, preventDefault() { prevented++; },
    });
    assert.equal(prevented, 0);
    element._dispatchPointer({
      type: "pointerdown", pointerType: "touch", pointerId: 7, buttons: 1,
      clientX: 110, clientY: 70, preventDefault() { prevented++; },
    });
    assert.equal(prevented, 1);
    const captures = surface.captured.length;
    element._dispatchPointer({
      type: "pointerdown", pointerType: "mouse", pointerId: 8, buttons: 1,
      target: { closest(selector) { return selector === "text" ? {} : null; } },
      clientX: 110, clientY: 70, preventDefault() { prevented++; },
    });
    assert.equal(surface.captured.length, captures);
  } finally {
    globalThis.DOMParser = oldParser;
    URL.createObjectURL = oldCreate;
  }
});
