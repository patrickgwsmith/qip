import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

class ElementStub {
  constructor() { this.style = {}; this.children = []; this.attributes = new Map(); this.clientWidth = 800; this.clientHeight = 320; }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  setAttribute(key, value) { this.attributes.set(key, value); }
  removeAttribute(key) { this.attributes.delete(key); }
  hasAttribute(key) { return this.attributes.has(key); }
  append(...children) { for (const child of children) { child.parent = this; this.children.push(child); } }
  prepend(...children) { for (const child of children) child.parent = this; this.children.unshift(...children); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((child) => child !== this); }
  addEventListener() {}
  removeEventListener() {}
  dispatchEvent() {}
  getBoundingClientRect() { return { width: 80, height: 16 }; }
}

let TUIElement;
globalThis.HTMLElement = ElementStub;
globalThis.customElements = {
  get() { return undefined; },
  define(name, value) { if (name === "qip-tui") TUIElement = value; },
};

const { gridDimensions } = await import("../site/_elements/qip-tui.js");
const { QIPInteractiveSession, mapKeyboardEventToKeysym } = await import(
  "../site/_elements/_qip-interactive-session.js"
);

test("text grid floors whole cells and keeps at least one", () => {
  assert.deepEqual(gridDimensions(799, 350, 8, 16), { columns: 99, lines: 21 });
  assert.deepEqual(gridDimensions(2, 2, 8, 16), { columns: 1, lines: 1 });
  assert.ok(TUIElement);
});

test("shared session retains a calendar state across key events and render", async () => {
  const bytes = await readFile(new URL("../tui/calendar-gregorian.wasm", import.meta.url));
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const session = new QIPInteractiveSession(instance.exports, instance.exports.memory);
  const initial = instance.exports.render(0);
  const firstMonth = new TextDecoder().decode(new Uint8Array(
    instance.exports.memory.buffer, Number((initial >> 32n) & 0x7fff_ffffn), Number(initial & 0xffff_ffffn),
  ));
  const event = session.update(1, [{ type: "key", keysym: 0xff54, flags: 1 }]);
  assert.equal(event.accepted, true);
  const next = instance.exports.render(0);
  const nextMonth = new TextDecoder().decode(new Uint8Array(
    instance.exports.memory.buffer, Number((next >> 32n) & 0x7fff_ffffn), Number(next & 0xffff_ffffn),
  ));
  assert.notEqual(nextMonth, firstMonth);
  assert.equal(mapKeyboardEventToKeysym({ key: "ArrowDown" }), 0xff54);
});

test("browser text input rerenders Content, preserves navigation on resize, and resets on edit", async () => {
  const previous = { document: globalThis.document, fetch: globalThis.fetch, NodeFilter: globalThis.NodeFilter,
    getComputedStyle: globalThis.getComputedStyle };
  globalThis.document = { createElement: () => new ElementStub(), createTreeWalker: () => ({ nextNode: () => null }) };
  globalThis.NodeFilter = { SHOW_TEXT: 4 };
  globalThis.getComputedStyle = () => ({ paddingLeft: "0", paddingRight: "0", paddingTop: "0", paddingBottom: "0", lineHeight: "16" });
  const ansi = await readFile("text/ansi-sgr-to-html.wasm");
  globalThis.fetch = async () => new Response(ansi, { headers: { "Content-Type": "application/wasm" } });
  const element = new TUIElement();
  try {
    element.connectedCallback();
    await element.load({ moduleBytes: await readFile("tui/emoji-finder.wasm"), inputBytes: new TextEncoder().encode("woman technologist") });
    assert.equal(element.input.type, "text");
    assert.equal(element.input.value, "woman technologist");
    assert.match(element.screen.innerHTML, /ACTIVE EMOJI  👩‍💻/);
    element.sendKey(0xff54);
    assert.equal(element._activeIndex, 1);
    assert.match(element.screen.innerHTML, /ACTIVE EMOJI  👩🏻‍💻/);
    for (let i = 0; i < 20; i++) element.sendKey(0xff54);
    assert.equal(element._activeIndex, 5);
    element.sendKey(0xff52);
    assert.equal(element._activeIndex, 4);
    element.screen.clientWidth = 640;
    element._measureAndRender();
    assert.equal(element._activeIndex, 4);
    assert.match(element.screen.innerHTML, /ACTIVE EMOJI  👩🏾‍💻/);
    element.input.value = "bear";
    element._onInput({ isComposing: true });
    assert.equal(element._activeIndex, 4);
    element._onInput({ isComposing: false });
    assert.equal(element._activeIndex, 0);
    assert.match(element.screen.innerHTML, /ACTIVE EMOJI  🐻  bear/);
    const frame = element.screen.innerHTML;
    element.input.value = "é".repeat(513);
    element._onInput({});
    assert.equal(element.screen.innerHTML, frame);
    assert.equal(element.input.getAttribute("aria-invalid"), "true");
    assert.match(element._inputError.textContent, /1024 UTF-8 bytes/);
    element.input.value = "";
    element._onInput({});
    assert.match(element.screen.innerHTML, /EMOJI FINDER  3972 \/ 3972/);
    assert.equal(element.input.getAttribute("aria-invalid"), null);
    await element.load({ moduleBytes: await readFile("tui/caniuse-finder.wasm"), inputBytes: new TextEncoder().encode("css-grid") });
    const featureFrame = element.screen.innerHTML;
    for (const browser of ["Chrome", "Firefox", "Safari", "Edge"]) assert.match(featureFrame, new RegExp(`${browser}:`));
    const featureCount = element._activeCount;
    assert.equal(element.sendKey(0xff56), true);
    assert.ok(element._detailOffset > 0);
    assert.notEqual(element.screen.innerHTML, featureFrame);
    assert.equal(element._activeCount, featureCount);
    element.sendKey(0xff55);
    assert.equal(element.screen.innerHTML, featureFrame);
    element.sendKey(0xff56);
    element.sendKey(0xff54);
    assert.equal(element._detailOffset, 0);
    element.sendKey(0xff56);
    element.screen.clientWidth = 720;
    element._measureAndRender();
    assert.equal(element._detailOffset, 0);
    element.sendKey(0xff56);
    element.input.value = "webp";
    element._onInput({});
    assert.equal(element._activeIndex, 0);
    assert.equal(element._detailOffset, 0);
    await element.load({ moduleBytes: await readFile("tui/emoji-finder-old.wasm") });
    assert.equal(element.input, null);
    assert.match(element.screen.innerHTML, /Find:/);
    assert.equal(element.sendKey(0xff54), true);
  } finally {
    element.disconnectedCallback();
    Object.assign(globalThis, previous);
  }
});
