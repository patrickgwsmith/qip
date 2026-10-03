#!/usr/bin/env node

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const wasmPath = resolve(
  root,
  process.env.QIP_TLDRAW_METRICS_WASM ?? "text/tldraw-draw-font-metrics-csv.wasm",
);
const fontPath = resolve(
  root,
  process.env.QIP_TLDRAW_METRICS_FONT ?? "fixtures/tldraw-assets-5.5.1/fonts/Shantell_Sans-Informal_Regular.woff2",
);
const fontFamily = process.env.QIP_TLDRAW_METRICS_FONT_FAMILY ?? "QipTldrawVerify";

const wasmBytes = await readFile(wasmPath);
const fontBytes = await readFile(fontPath);

const page = String.raw`<!doctype html>
<meta charset="utf-8">
<title>TLDraw font metrics verification</title>
<pre id="out">running...</pre>
<script type="module">
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const fontFace = new FontFace(${JSON.stringify(fontFamily)}, "url(/font.woff2)");
await fontFace.load();
document.fonts.add(fontFace);
await document.fonts.ready;

const wasmBytes = await (await fetch("/component.wasm")).arrayBuffer();

const cases = [
  { name: "hello", text: "Hello", uniforms: { font_size: 24, measure: 0 } },
  { name: "punctuation", text: "AVATAR, yay!?", uniforms: { font_size: 24, measure: 0 } },
  { name: "spaces", text: "space  test", uniforms: { font_size: 24, measure: 0 } },
  { name: "explicit-lines", text: "Hello\nWorld", uniforms: { font_size: 24, measure: 0 } },
  {
    name: "wrapped",
    text: "The quick brown fox jumps over the lazy dog.",
    uniforms: { font_size: 24, measure: 160 },
  },
  { name: "latin-1", text: "Café déjà vu — €", uniforms: { font_size: 24, measure: 0 } },
];

function writeInput(exportsObj, text) {
  const bytes = encoder.encode(text);
  const inputPtr = exportsObj.input_ptr();
  const inputCap = exportsObj.input_utf8_cap();
  if (bytes.length > inputCap) throw new Error("input too large");
  new Uint8Array(exportsObj.memory.buffer, inputPtr, bytes.length).set(bytes);
  return bytes.length;
}

function runWasm(text, uniforms) {
  const instance = new WebAssembly.Instance(window.qipModule, {});
  const e = instance.exports;
  for (const [key, value] of Object.entries(uniforms)) {
    const setter = e["uniform_set_" + key];
    if (typeof setter === "function") setter(value);
  }
  const inputSize = writeInput(e, text);
  const packed = BigInt.asUintN(64, e.render(inputSize));
  if ((packed & (1n << 63n)) !== 0n) throw new Error("component rejected input");
  const outputSize = Number(packed & 0xffff_ffffn);
  const outputPtr = Number((packed >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(e.memory.buffer, outputPtr, outputSize));
}

function parseCsv(csv) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < csv.length; i += 1) {
    const ch = csv[i];
    if (quoted) {
      if (ch === '"' && csv[i + 1] === '"') {
        field += '"';
        i += 1;
      } else if (ch === '"') {
        quoted = false;
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === ",") {
      row.push(field);
      field = "";
    } else if (ch === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (ch !== "\r") {
      field += ch;
    }
  }
  if (field.length || row.length) {
    row.push(field);
    rows.push(row);
  }
  const header = rows.shift();
  return rows.filter((r) => r.length === header.length).map((r) =>
    Object.fromEntries(header.map((name, index) => [name, r[index]]))
  );
}

function round(value) {
  return Math.round(value * 1000) / 1000;
}

function diff(actual, expected) {
  return round(Number(actual) - Number(expected));
}

function measureBrowser(text, fontSize, kerning) {
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d");
  ctx.font = String(fontSize) + "px " + ${JSON.stringify(fontFamily)};
  ctx.fontKerning = kerning;
  ctx.textBaseline = "alphabetic";
  const metrics = ctx.measureText(text);
  return {
    width: round(metrics.width),
    actual_left: round(metrics.actualBoundingBoxLeft),
    actual_right: round(metrics.actualBoundingBoxRight),
    actual_ascent: round(metrics.actualBoundingBoxAscent),
    actual_descent: round(metrics.actualBoundingBoxDescent),
    font_ascent: round(metrics.fontBoundingBoxAscent),
    font_descent: round(metrics.fontBoundingBoxDescent),
  };
}

function measureDom(text, fontSize, features) {
  const root = document.createElement("div");
  root.style.position = "absolute";
  root.style.left = "-9999px";
  root.style.top = "-9999px";
  root.style.whiteSpace = "pre";
  root.style.fontFamily = ${JSON.stringify(fontFamily)};
  root.style.fontSize = String(fontSize) + "px";
  root.style.lineHeight = "normal";
  const span = document.createElement("span");
  span.textContent = text;
  if (features === "off") {
    span.style.fontKerning = "none";
    span.style.fontVariantLigatures = "none";
    span.style.fontFeatureSettings = '"kern" 0, "liga" 0, "clig" 0, "calt" 0';
  }
  root.append(span);
  document.body.append(root);
  const width = round(span.getBoundingClientRect().width);
  root.remove();
  return { width };
}

window.qipModule = await WebAssembly.compile(wasmBytes);
const results = [];
for (const testCase of cases) {
  const csv = runWasm(testCase.text, testCase.uniforms);
  const rows = parseCsv(csv);
  const rowResults = rows.map((row) => {
    const browser = measureBrowser(row.text, Number(row.font_size), "normal");
    const browserNoKerning = measureBrowser(row.text, Number(row.font_size), "none");
    const dom = measureDom(row.text, Number(row.font_size), "normal");
    const domFeaturesOff = measureDom(row.text, Number(row.font_size), "off");
    const wasmActualLeft = -Number(row.x_min);
    const wasmActualRight = Number(row.x_max);
    const wasmActualAscent = Number(row.baseline_y) - Number(row.y_min);
    const wasmActualDescent = Number(row.y_max) - Number(row.baseline_y);
    return {
      line_index: Number(row.line_index),
      text: row.text,
      wasm: {
        width: round(row.width),
        actual_left: round(wasmActualLeft),
        actual_right: round(wasmActualRight),
        actual_ascent: round(wasmActualAscent),
        actual_descent: round(wasmActualDescent),
        ascender: round(row.ascender),
        descender: round(row.descender),
      },
      browser,
      browser_no_kerning: browserNoKerning,
      dom,
      dom_features_off: domFeaturesOff,
      delta: {
        width: diff(browser.width, row.width),
        actual_left: diff(browser.actual_left, wasmActualLeft),
        actual_right: diff(browser.actual_right, wasmActualRight),
        actual_ascent: diff(browser.actual_ascent, wasmActualAscent),
        actual_descent: diff(browser.actual_descent, wasmActualDescent),
        font_ascent_vs_wasm_ascender: diff(browser.font_ascent, row.ascender),
        font_descent_vs_wasm_descender: diff(browser.font_descent, row.descender),
      },
      delta_no_kerning: {
        width: diff(browserNoKerning.width, row.width),
        actual_left: diff(browserNoKerning.actual_left, wasmActualLeft),
        actual_right: diff(browserNoKerning.actual_right, wasmActualRight),
        actual_ascent: diff(browserNoKerning.actual_ascent, wasmActualAscent),
        actual_descent: diff(browserNoKerning.actual_descent, wasmActualDescent),
        font_ascent_vs_wasm_ascender: diff(browserNoKerning.font_ascent, row.ascender),
        font_descent_vs_wasm_descender: diff(browserNoKerning.font_descent, row.descender),
      },
      delta_dom: {
        width: diff(dom.width, row.width),
      },
      delta_dom_features_off: {
        width: diff(domFeaturesOff.width, row.width),
      },
    };
  });
  results.push({ name: testCase.name, rows: rowResults });
}

const summary = results.flatMap((result) =>
  result.rows.map((row) => ({
    case: result.name,
    line: row.line_index,
    text: row.text,
    width_delta: row.delta.width,
    width_delta_no_kerning: row.delta_no_kerning.width,
    dom_width_delta: row.delta_dom.width,
    dom_width_delta_features_off: row.delta_dom_features_off.width,
    actual_right_delta: row.delta.actual_right,
    actual_right_delta_no_kerning: row.delta_no_kerning.actual_right,
    actual_ascent_delta: row.delta.actual_ascent,
    actual_descent_delta: row.delta.actual_descent,
  }))
);

const output = { userAgent: navigator.userAgent, summary, results };
window.qipVerification = output;
document.getElementById("out").textContent = JSON.stringify(output, null, 2);
</script>`;

const server = createServer((request, response) => {
  if (request.url === "/font.woff2") {
    response.writeHead(200, {
      "content-type": "font/woff2",
      "cache-control": "no-store",
    });
    response.end(fontBytes);
  } else if (request.url === "/component.wasm") {
    response.writeHead(200, {
      "content-type": "application/wasm",
      "cache-control": "no-store",
    });
    response.end(wasmBytes);
  } else {
    response.writeHead(200, {
      "content-type": "text/html;charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(page);
  }
});

server.listen(0, "127.0.0.1", () => {
  const { port } = server.address();
  console.log(`http://127.0.0.1:${port}/`);
});
