import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

let QIPPlayElement = null;

globalThis.HTMLElement = class {
  hasAttribute() { return false; }
  getAttribute() { return ""; }
  querySelector() { return null; }
  addEventListener() {}
  removeEventListener() {}
  replaceChildren() {}
};

globalThis.customElements = {
  get() { return undefined; },
  define(name, elementClass) {
    if (name === "qip-play") QIPPlayElement = elementClass;
  },
};

globalThis.document = {
  baseURI: "http://example.test/",
  hidden: false,
  createElement() {
    return { setAttribute() {}, style: {}, textContent: "" };
  },
};

globalThis.getComputedStyle = () => ({ getPropertyValue() { return ""; } });

await import("../site/_elements/qip-play.js");

function formatWake(value) {
  return value === 0 ? "none" : String(value);
}

function tracedExports(actual, lines) {
  const traced = {};
  for (const property of Object.keys(actual)) {
    const value = actual[property];
    if (typeof value !== "function") {
      traced[property] = value;
      continue;
    }
    if (property === "render") {
      traced[property] = (inputSize) => {
        lines.push(`call render input_size=${inputSize}`);
        const result = value(inputSize);
        lines.push(`return output_bytes=${Number(BigInt.asUintN(64, result) & 0xffff_ffffn)}`);
        return result;
      };
      continue;
    }
    if (property === "begin_update_at") {
      traced[property] = (nowMS) => {
        lines.push(`call begin_update_at now_ms=${nowMS}`);
        value(nowMS);
        lines.push("return ok");
      };
      continue;
    }
    if (property === "finish_update") {
      traced[property] = () => {
        lines.push("call finish_update");
        const result = value();
        lines.push(`return next_wake_at_ms=${result}`);
        return result;
      };
      continue;
    }
    if (property === "key_event") {
      traced[property] = (keysym, flags) => {
        lines.push(`call key_event keysym=${keysym} flags=${flags}`);
        const result = value(keysym, flags);
        lines.push(`return accepted=${result}`);
        return result;
      };
      continue;
    }
    if (property === "pointer_event") {
      traced[property] = (buttons, x, y) => {
        lines.push(`call pointer_event buttons=${buttons} x=${x} y=${y}`);
        const result = value(buttons, x, y);
        lines.push(`return accepted=${result}`);
        return result;
      };
      continue;
    }
    traced[property] = value;
  }
  return traced;
}

function makeElement(component, lines) {
  const wasm = readFileSync(`gui/${component}.wasm`);
  const actual = new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
  const element = new QIPPlayElement();
  element._exports = tracedExports(actual, lines);
  element._memory = actual.memory;
  element._uniforms = [];
  element._outputCapacity = actual.output_bytes_cap();
  element._presentKTX2Output = () => {};
  element._stats = { textContent: "" };
  return element;
}

function traceCalculator(lines) {
  lines.push("calculator");
  const element = makeElement("calculator", lines);

  const initial = element._runInitialContentRender();
  lines.push(`host initial present output_bytes=${initial.rendered.outputLen}`);
  element._runBootstrapUpdate();
  lines.push(`host bootstrap wake=${formatWake(element._nextWakeAtMS)}`);

  element._queuePointerEvent(0, -1, -1, 2);
  let result = element._runUpdate(2, false);
  lines.push(`host update events=${result.eventCount} accepted=${result.acceptedEvent ? "yes" : "no"} wake=${formatWake(result.nextWakeAtMS)} render=${result.rendered ? "yes" : "no"}`);

  // Mixed event kinds must retain enqueue order, including equal timestamps.
  element._queuePointerEvent(0, -1, -1, 3);
  element._queueKeyEvent("1".codePointAt(0), 1, 3);
  result = element._runUpdate(3, false);
  lines.push(`host update events=${result.eventCount} accepted=${result.acceptedEvent ? "yes" : "no"} wake=${formatWake(result.nextWakeAtMS)} render=${result.rendered ? "yes" : "no"}`);
}

function traceSnake(lines) {
  lines.push("snake");
  const element = makeElement("snake", lines);

  const initial = element._runInitialContentRender();
  lines.push(`host initial present output_bytes=${initial.rendered.outputLen}`);
  element._runBootstrapUpdate();
  lines.push(`host bootstrap wake=${formatWake(element._nextWakeAtMS)}`);

  element._queueKeyEvent(0xff52, 1, 120);
  let result = element._runUpdate(120, true);
  lines.push(`host update events=${result.eventCount} accepted=${result.acceptedEvent ? "yes" : "no"} wake=${formatWake(result.nextWakeAtMS)} render=${result.rendered ? "yes" : "no"}`);

  element._queueKeyEvent(0x20, 1, 121);
  result = element._runUpdate(121, false);
  lines.push(`host update events=${result.eventCount} accepted=${result.acceptedEvent ? "yes" : "no"} wake=${formatWake(result.nextWakeAtMS)} render=${result.rendered ? "yes" : "no"}`);
}

test("JavaScript host decisions match the shared Interactive trace", () => {
  const lines = [];
  traceCalculator(lines);
  traceSnake(lines);
  const actual = lines.join("\n") + "\n";
  const expected = readFileSync("testdata/interactive-host-decisions.txt", "utf8");
  assert.equal(actual, expected);
});
