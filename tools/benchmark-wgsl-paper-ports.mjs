#!/usr/bin/env node

// Compile each generated effect on the /wgsl demo page with both compiler
// modes, then time warmed V8 renders, as the page's Wasm runner does. With
// --baseline-page, the same effects from an older copy of site/wgsl.md are
// measured alternately and their outputs compared with the current page's.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { cpus } from "node:os";
import { dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const options = { runs: 15, warmup: 3, width: 512, height: 384, page: join(root, "site/wgsl.md"), baseline: null, only: null };
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === "--runs") options.runs = Number(process.argv[++i]);
  else if (arg === "--warmup") options.warmup = Number(process.argv[++i]);
  else if (arg === "--size") [options.width, options.height] = process.argv[++i].split("x").map(Number);
  else if (arg === "--page") options.page = resolve(process.argv[++i]);
  else if (arg === "--baseline-page") options.baseline = resolve(process.argv[++i]);
  else if (arg === "--only") options.only = process.argv[++i].split(",");
  else throw Error(`unknown option ${arg}`);
}
for (const value of [options.runs, options.width, options.height]) {
  assert.ok(Number.isSafeInteger(value) && value > 0, "sizes and run counts must be positive integers");
}

// Every top-level `function` on the page, evaluated together so generators
// can call shared helpers. Only generators run; none touch the DOM.
async function generatedEffects(path) {
  const page = await readFile(path, "utf8");
  const functions = page.match(/^function \w+\([^)]*\) \{[\s\S]*?\n\}$/gm) ?? [];
  const effects = [...page.matchAll(/dataset\.generated === "([\w-]+)"\) script\.textContent = (\w+)\(\);/g)];
  assert.ok(effects.length > 0, `${path} has generated effects`);
  const sources = runInNewContext(functions.join("\n") +
    `\n({ ${effects.map(([, key, fn]) => `${JSON.stringify(key)}: ${fn}()`).join(", ")} })`);
  return new Map(Object.entries(sources));
}

const compilerBytes = await readFile(join(root, "text/wgsl/wgsl-to-wasm.wasm"));
const compiler = new WebAssembly.Instance(new WebAssembly.Module(compilerBytes)).exports;
function compile(source, vectorize) {
  const bytes = new TextEncoder().encode(source);
  new Uint8Array(compiler.memory.buffer, compiler.input_ptr(), bytes.length).set(bytes);
  compiler.uniform_set_vectorize_invocations(vectorize ? 1 : 0);
  const start = performance.now();
  const result = BigInt.asUintN(64, compiler.render(bytes.length));
  const ms = performance.now() - start;
  assert.equal(result >> 63n, 0n, "compiler accepted the source");
  const wasm = new Uint8Array(compiler.memory.buffer.slice(Number(result >> 32n),
    Number(result >> 32n) + Number(result & 0xffffffffn)));
  const module = new WebAssembly.Module(wasm);
  return { wasm, ms, vectorized: WebAssembly.Module.customSections(module, "qip.vectorize_invocations").length > 0,
    exports: new WebAssembly.Instance(module).exports };
}

// The demo's test card is drawn on a canvas; a smooth deterministic image
// with edges stands in for it here.
const input = new Float32Array(options.width * options.height * 4);
for (let y = 0; y < options.height; y++) {
  for (let x = 0; x < options.width; x++) {
    const i = (y * options.width + x) * 4;
    input[i] = x / options.width;
    input[i + 1] = y / options.height;
    input[i + 2] = ((x >> 5) + (y >> 5)) % 2 ? 0.9 : 0.1;
    input[i + 3] = 1;
  }
}
const inputBytes = new Uint8Array(input.buffer);

function render(exports) {
  exports.uniform_set_width(options.width);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), inputBytes.length).set(inputBytes);
  const result = BigInt.asUintN(64, exports.render(inputBytes.length));
  assert.equal(result >> 63n, 0n, "render succeeded");
  return new Float32Array(exports.memory.buffer.slice(Number(result >> 32n),
    Number(result >> 32n) + Number(result & 0xffffffffn)));
}

const median = (values) => values.toSorted((a, b) => a - b)[values.length >> 1];
const current = await generatedEffects(options.page);
const baseline = options.baseline ? await generatedEffects(options.baseline) : null;
console.log(`CPU: ${cpus()[0]?.model}; Node ${process.version}; ${process.platform}/${process.arch}`);
console.log(`Image: ${options.width}x${options.height} RGBA32F; ${options.warmup} warmup, median of ${options.runs} renders`);
console.log(baseline ? `Baseline: ${options.baseline}\nCurrent:  ${options.page}` : `Page: ${options.page}`);

const rows = [];
for (const [key, source] of current) {
  if (options.only && !options.only.includes(key)) continue;
  const pages = baseline?.has(key) ? [["before", baseline.get(key)], ["after", source]] : [["after", source]];
  const measured = pages.map(([label, text]) => ({ label, text,
    modes: [false, true].map((vectorize) => ({ vectorize, ...compile(text, vectorize), times: [] })) }));
  for (const m of measured) for (const mode of m.modes) for (let i = 0; i < options.warmup; i++) render(mode.exports);
  // Alternate pages and modes so drift affects each equally.
  for (let run = 0; run < options.runs; run++) {
    for (const m of measured) {
      for (const mode of m.modes) {
        const start = performance.now();
        render(mode.exports);
        mode.times.push(performance.now() - start);
      }
    }
  }
  let diff = "";
  if (measured.length === 2) {
    const [a, b] = measured.map((m) => render(m.modes[0].exports));
    let max = 0;
    let pixels = 0;
    for (let i = 0; i < a.length; i += 4) {
      let pixel = 0;
      for (let c = 0; c < 4; c++) pixel = Math.max(pixel, Math.abs(a[i + c] - b[i + c]));
      if (pixel > 0) pixels++;
      max = Math.max(max, pixel);
    }
    diff = max === 0 ? "identical" : `${pixels} px, max ${max.toExponential(2)}`;
  }
  for (const m of measured) {
    const [scalar, vector] = m.modes;
    rows.push({ effect: key, page: m.label, wgsl: m.text.length, scalar: scalar.wasm.length,
      vectorized: vector.vectorized ? vector.wasm.length : "no", compile: scalar.ms,
      scalarMs: median(scalar.times), vectorMs: vector.vectorized ? median(vector.times) : null,
      diff: m.label === "after" ? diff : "" });
  }
}

const header = ["effect", "page", "WGSL B", "wasm B", "vector wasm B", "compile ms", "scalar ms", "vector ms", "after vs before"];
const table = rows.map((r) => [r.effect, r.page, String(r.wgsl), String(r.scalar), String(r.vectorized),
  r.compile.toFixed(1), r.scalarMs.toFixed(2), r.vectorMs === null ? "-" : r.vectorMs.toFixed(2), r.diff]);
const widths = header.map((h, i) => Math.max(h.length, ...table.map((row) => row[i].length)));
for (const row of [header, widths.map((w) => "-".repeat(w)), ...table]) {
  console.log(row.map((cell, i) => i < 2 || i === 8 ? cell.padEnd(widths[i]) : cell.padStart(widths[i])).join("  "));
}
