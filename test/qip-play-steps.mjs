import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

let QIPPlayElement = null;

globalThis.HTMLElement = class {
  constructor() { this.children = []; }
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
  createElement() { return { setAttribute() {}, style: {}, textContent: "" }; },
};
globalThis.getComputedStyle = () => ({ getPropertyValue() { return ""; } });

await import("../site/_elements/qip-play.js");
const { sourceSteps: qipPlaySourceSteps, validatePostStage: qipPlayValidatePostStage } =
  await import("../site/_elements/_qip-pipeline.js");

function node(localName, attributes = {}, children = []) {
  return {
    localName,
    children,
    getAttribute(name) { return attributes[name] ?? ""; },
    getAttributeNames() { return Object.keys(attributes); },
  };
}

function instantiate(path) {
  const bytes = readFileSync(path);
  return {
    bytes: bytes.byteLength,
    exports: new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports,
  };
}

test("qip-step groups ordered stages while sources remain alternatives", () => {
  const primary = node("source", { src: "/interactive/macintosh-1bit.wasm", type: "application/wasm" });
  const ignored = node("source", { src: "/unsupported", type: "application/example" });
  const effect = node("source", { src: "/image/duotone.wasm", type: "application/wasm" });
  const play = node("qip-play", {}, [
    node("qip-step", { name: "desktop" }, [primary]),
    node("qip-step", { name: "duotone" }, [ignored, effect]),
  ]);
  const steps = qipPlaySourceSteps(play);
  assert.equal(steps.length, 2);
  assert.equal(steps[0].sourceElement, primary);
  assert.equal(steps[1].sourceElement, effect);
  assert.deepEqual(steps[1].sourceElements, [effect]);

  play.children.push(node("source", { src: "/ambiguous.wasm" }));
  assert.throws(() => qipPlaySourceSteps(play), /cannot mix direct <source>/);
});

test("a named data source is not mistaken for a direct Wasm stage", () => {
  const input = node("source", { name: "input", src: "/example.svg", type: "image/svg+xml" });
  const wasm = node("source", { src: "/interactive/svg-path-editor.wasm", type: "application/wasm" });
  const steps = qipPlaySourceSteps(node("qip-play", {}, [input, wasm]));
  assert.equal(steps.length, 1);
  assert.equal(steps[0].sourceElement, wasm);
});

function declaredCandidate(inputType, outputType) {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const encodedInput = new TextEncoder().encode(inputType);
  const encodedOutput = new TextEncoder().encode(outputType);
  new Uint8Array(memory.buffer, 0, encodedInput.length).set(encodedInput);
  new Uint8Array(memory.buffer, 64, encodedOutput.length).set(encodedOutput);
  return {
    exports: {
      memory,
      input_ptr() { return 128; },
      input_bytes_cap() { return 1024; },
      output_bytes_cap() { return 1024; },
      input_content_type_ptr() { return 0; },
      input_content_type_size() { return encodedInput.length; },
      output_content_type_ptr() { return 64; },
      output_content_type_size() { return encodedOutput.length; },
      render() { return 0n; },
    },
    memory,
  };
}

test("post-step alternatives require identical exact content types", () => {
  const matching = {
    label: "resize",
    candidates: [
      declaredCandidate("image/ktx2", "image/ktx2"),
      declaredCandidate("image/ktx2", "image/ktx2"),
    ],
  };
  assert.equal(qipPlayValidatePostStage(matching, "image/ktx2"), "image/ktx2");

  const mismatch = {
    label: "resize",
    candidates: [
      declaredCandidate("image/ktx2", "image/ktx2"),
      declaredCandidate("image/png", "image/ktx2"),
    ],
  };
  assert.throws(
    () => qipPlayValidatePostStage(mismatch, "image/ktx2"),
    /identical input and output content types/,
  );

  const outputMismatch = {
    label: "effect",
    candidates: [
      declaredCandidate("image/ktx2", "image/ktx2"),
      declaredCandidate("image/ktx2", "image/png"),
    ],
  };
  assert.throws(
    () => qipPlayValidatePostStage(outputMismatch, "image/ktx2"),
    /identical input and output content types/,
  );
});

test("a post step uses the first source whose render accepts the frame", () => {
  const primaryModule = instantiate("components/interactive/macintosh-1bit.wasm");
  const effectModule = instantiate("image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm");
  const primarySource = node("source", { src: "/interactive/macintosh-1bit.wasm" });
  const rejectedSource = node("source", { src: "/image/reject.wasm" });
  const acceptedSource = node("source", { src: "/image/duotone.wasm" });
  const rejectedMemory = new WebAssembly.Memory({ initial: 64 });
  let rejectedRenderN = 0;
  const rejected = {
    sourceElement: rejectedSource,
    sourceLabel: "reject",
    exports: {
      memory: rejectedMemory,
      failure_modes_per_input_offset() { return 0; },
      render() { rejectedRenderN++; return 1n << 63n; },
    },
    memory: rejectedMemory,
    inputPtr: 0,
    inputCapacity: rejectedMemory.buffer.byteLength,
    outputCapacity: 0,
    renderN: 0,
    lastRenderMS: 0,
  };
  const accepted = {
    sourceElement: acceptedSource,
    sourceLabel: "duotone",
    exports: effectModule.exports,
    memory: effectModule.exports.memory,
    inputPtr: effectModule.exports.input_ptr(),
    inputCapacity: effectModule.exports.input_bytes_cap(),
    outputCapacity: effectModule.exports.output_bytes_cap(),
    renderN: 0,
    lastRenderMS: 0,
  };
  const primary = {
    label: "desktop",
    sourceElement: primarySource,
    exports: primaryModule.exports,
    memory: primaryModule.exports.memory,
    outputCapacity: primaryModule.exports.output_bytes_cap(),
    renderN: 0,
    lastRenderMS: 0,
  };
  const stage = {
    label: "effect",
    candidates: [rejected, accepted],
    renderN: 0,
    lastRenderMS: 0,
    selectedSourceLabel: "",
  };
  const element = new QIPPlayElement();
  element._exports = primary.exports;
  element._memory = primary.memory;
  element._sourceElement = primarySource;
  element._uniforms = [];
  element._outputCapacity = primary.outputCapacity;
  element._steps = [primary, stage];
  element._postStages = [stage];

  const initial = element._runInitialContentRender();
  assert.equal(element._readKTX2Output(initial.rendered).profile.pixelFormat, "rgba-float32");
  assert.equal(rejectedRenderN, 1);
  assert.equal(accepted.renderN, 1);
  assert.equal(stage.selectedSourceLabel, "duotone");

  element._runInitialContentRender();
  assert.equal(rejectedRenderN, 1, "the rejected alternative is not retried after selection");
  assert.equal(accepted.renderN, 2);

  stage.selectedCandidate = null;
  stage.candidates = [rejected, accepted];
  rejected.exports.render = () => { throw new WebAssembly.RuntimeError("broken"); };
  assert.throws(() => element._runInitialContentRender(), WebAssembly.RuntimeError);
  assert.equal(accepted.renderN, 2, "a trap must not fall through to another source");
});

test("finite post-processing runs after the Interactive render and reports each step", () => {
  const primaryModule = instantiate("components/interactive/macintosh-1bit.wasm");
  const effectModule = instantiate("image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm");
  const primarySource = node("source");
  const effectSource = node("source");
  const primary = {
    label: "desktop",
    sourceElement: primarySource,
    exports: primaryModule.exports,
    memory: primaryModule.exports.memory,
    moduleBytes: primaryModule.bytes,
    outputCapacity: primaryModule.exports.output_bytes_cap(),
    renderN: 0,
    lastRenderMS: 0,
  };
  const effect = {
    label: "duotone",
    sourceElement: effectSource,
    exports: effectModule.exports,
    memory: effectModule.exports.memory,
    moduleBytes: effectModule.bytes,
    outputCapacity: effectModule.exports.output_bytes_cap(),
    inputCapacity: effectModule.exports.input_bytes_cap(),
    inputPtr: effectModule.exports.input_ptr(),
    renderN: 0,
    lastRenderMS: 0,
  };

  const element = new QIPPlayElement();
  element._exports = primary.exports;
  element._memory = primary.memory;
  element._sourceElement = primarySource;
  element._uniforms = [];
  element._outputCapacity = primary.outputCapacity;
  element._steps = [primary, effect];
  element._postStages = [effect];
  element._wasmByteLength = primary.moduleBytes + effect.moduleBytes;
  element._debugStats = true;
  element._stats = { textContent: "" };

  const initial = element._runInitialContentRender();
  const parsed = element._readKTX2Output(initial.rendered);
  assert.equal(parsed.width, 512);
  assert.equal(parsed.height, 342);
  assert.equal(parsed.profile.pixelFormat, "rgba-float32");
  assert.equal(primary.renderN, 1);
  assert.equal(effect.renderN, 1);

  const floats = parsed.pixels;
  let foundShadow = false;
  let foundHighlight = false;
  for (let offset = 0; offset < floats.length; offset += 4) {
    foundShadow ||= Math.abs(floats[offset] - 0.004) < 0.0001;
    foundHighlight ||= Math.abs(floats[offset] - 2.40) < 0.0001;
    if (foundShadow && foundHighlight) break;
  }
  assert.equal(foundShadow, true);
  assert.equal(foundHighlight, true);

  element._updateStats();
  assert.match(element._stats.textContent, /\ndesktop \| wasm .* \| memory .* \| render\s+1 /);
  assert.match(element._stats.textContent, /\nduotone \| wasm .* \| memory .* \| render\s+1 /);
});
