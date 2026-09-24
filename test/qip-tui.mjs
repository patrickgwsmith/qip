import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

let TUIElement;
globalThis.HTMLElement = class {};
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
  const bytes = await readFile(new URL("../components/interactive/calendar-gregorian.wasm", import.meta.url));
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
