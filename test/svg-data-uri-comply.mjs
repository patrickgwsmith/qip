import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  registerGenericComplianceTests,
  runComplianceComponent,
} from "./lib/compliance-harness.mjs";
import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";

const svgComplianceBytes = await readFile(
  new URL("../compliance/svg-to-data-uri.comply.wasm", import.meta.url),
);
const cssComplianceBytes = await readFile(
  new URL("../compliance/data-uri-to-css-url.comply.wasm", import.meta.url),
);

registerGenericComplianceTests(test, svgComplianceBytes, {
  curatedCount: 8,
  expectSeedVariation: false,
});
registerGenericComplianceTests(test, cssComplianceBytes, {
  curatedCount: 12,
  expectSeedVariation: false,
});

function encodeSvgDataUri(input) {
  const safe = (byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a) ||
    "-._~!$()*+,;=:@/?".includes(String.fromCharCode(byte));
  return "data:image/svg+xml," + [...input]
    .map((byte) => safe(byte) ? String.fromCharCode(byte) : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`)
    .join("");
}

function wrapCssDataUri(input) {
  if (!input.subarray(0, 5).equals(Buffer.from("data:")) || !input.subarray(5).includes(0x2c)) {
    return null;
  }
  const body = [...input].map((byte) =>
    byte === 0x22 || byte === 0x27 || byte === 0x5c || byte <= 0x1f || byte === 0x7f
      ? `%${byte.toString(16).toUpperCase().padStart(2, "0")}`
      : String.fromCharCode(byte)
  ).join("");
  return Buffer.from(`url("${body}")`);
}

test("SVG data URI cases match the independent JavaScript oracle", async () => {
  const { cases } = await runComplianceComponent(svgComplianceBytes);
  for (const entry of cases) {
    assert.equal(entry.expected?.toString(), encodeSvgDataUri(entry.input));
  }
});

test("CSS url cases match the independent JavaScript oracle", async () => {
  const { cases } = await runComplianceComponent(cssComplianceBytes);
  for (const entry of cases) {
    const actual = wrapCssDataUri(entry.input);
    assert.equal(actual?.toString() ?? null, entry.expected?.toString() ?? null);
  }
});

async function duel(complianceBytes, implementationUrl) {
  const implementationBytes = await readFile(implementationUrl);
  const { instance } = await WebAssembly.instantiate(implementationBytes);
  const implementation = instance.exports;
  const readI32 = (name) => typeof implementation[name] === "function"
    ? implementation[name]()
    : implementation[name].value;
  const render = (input) => {
    new Uint8Array(implementation.memory.buffer, readI32("input_ptr"), input.length).set(input);
    try {
      const outputLength = renderSize(implementation, input.length);
      return Buffer.from(new Uint8Array(
        implementation.memory.buffer,
        renderedOutputPointer(implementation),
        outputLength,
      ));
    } catch {
      return null;
    }
  };
  const { cases } = await runComplianceComponent(complianceBytes);
  const failures = cases
    .filter((entry) => entry.expected === null
      ? render(entry.input) !== null
      : !render(entry.input)?.equals(entry.expected))
    .map((entry) => entry.ordinal);
  assert.deepEqual(failures, []);
}

test("duel: svg-to-data-uri.wasm satisfies the contract", async () => {
  await duel(
    svgComplianceBytes,
    new URL("../image/svg+xml/svg-to-data-uri.wasm", import.meta.url),
  );
});

test("duel: data-uri-to-css-url.wasm satisfies the contract", async () => {
  await duel(
    cssComplianceBytes,
    new URL("../text/uri-list/data-uri-to-css-url.wasm", import.meta.url),
  );
});

async function instantiateModule(url) {
  const bytes = await readFile(url);
  const { instance } = await WebAssembly.instantiate(bytes);
  const exports = instance.exports;
  const readI32 = (name) => typeof exports[name] === "function"
    ? exports[name]()
    : exports[name].value;
  return { bytes, exports, readI32 };
}

test("svg-to-data-uri expands its maximum input in one memory page", async () => {
  const { bytes, exports, readI32 } = await instantiateModule(
    new URL("../image/svg+xml/svg-to-data-uri.wasm", import.meta.url),
  );
  const inputLength = readI32("input_utf8_cap");
  const input = Buffer.alloc(inputLength, 0x22);
  new Uint8Array(exports.memory.buffer, readI32("input_ptr"), input.length).set(input);
  const outputLength = renderSize(exports, input.length);
  const output = Buffer.from(new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), outputLength));
  assert.equal(output.toString("ascii", 0, 19), "data:image/svg+xml,");
  assert.equal(outputLength, 19 + inputLength * 3);
  assert.equal(output.subarray(-6).toString(), "%22%22");
  assert.equal(exports.memory.buffer.byteLength, 65_536);
  assert.ok(bytes.length <= 1024, `module grew to ${bytes.length} bytes`);
});

test("data-uri-to-css-url expands its maximum input in one memory page", async () => {
  const { bytes, exports, readI32 } = await instantiateModule(
    new URL("../text/uri-list/data-uri-to-css-url.wasm", import.meta.url),
  );
  const inputLength = readI32("input_utf8_cap");
  const input = Buffer.concat([Buffer.from("data:,"), Buffer.alloc(inputLength - 6, 0x22)]);
  new Uint8Array(exports.memory.buffer, readI32("input_ptr"), input.length).set(input);
  const outputLength = renderSize(exports, input.length);
  const output = Buffer.from(new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), outputLength));
  assert.equal(output.subarray(0, 10).toString(), 'url("data:');
  assert.equal(output.subarray(-8).toString(), "%22%22\")");
  assert.equal(exports.memory.buffer.byteLength, 65_536);
  assert.ok(bytes.length <= 1024, `module grew to ${bytes.length} bytes`);
});

test("the two modules compose into a CSS url value", async () => {
  const svg = Buffer.from('<svg fill="none"><path d="m6 8 4 4 4-4"/></svg>');
  const expectedUri = Buffer.from(encodeSvgDataUri(svg));
  const expectedCss = wrapCssDataUri(expectedUri);

  const first = await instantiateModule(
    new URL("../image/svg+xml/svg-to-data-uri.wasm", import.meta.url),
  );
  new Uint8Array(first.exports.memory.buffer, first.readI32("input_ptr"), svg.length).set(svg);
  const uriLength = renderSize(first.exports, svg.length);
  const uri = Buffer.from(new Uint8Array(
    first.exports.memory.buffer,
    renderedOutputPointer(first.exports),
    uriLength,
  ));

  const second = await instantiateModule(
    new URL("../text/uri-list/data-uri-to-css-url.wasm", import.meta.url),
  );
  new Uint8Array(second.exports.memory.buffer, second.readI32("input_ptr"), uri.length).set(uri);
  const cssLength = renderSize(second.exports, uri.length);
  const css = Buffer.from(new Uint8Array(
    second.exports.memory.buffer,
    renderedOutputPointer(second.exports),
    cssLength,
  ));
  assert.deepEqual(css, expectedCss);
});
