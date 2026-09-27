#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";

function exportedI32(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(`Wasm module must export ${name}() -> i32`);
  return value() >>> 0;
}

function percentile(sorted, fraction) {
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  const mean = samples.reduce((sum, value) => sum + value, 0) / samples.length;
  return {
    samples: samples.length,
    mean_ms: mean,
    p50_ms: percentile(sorted, 0.50),
    p95_ms: percentile(sorted, 0.95),
    max_ms: sorted.at(-1),
  };
}

function renderOnce(exports, input) {
  const inputPtr = exportedI32(exports, "input_ptr");
  const inputCapName = exports.input_utf8_cap ? "input_utf8_cap" : "input_bytes_cap";
  const outputCapName = exports.output_utf8_cap ? "output_utf8_cap" : "output_bytes_cap";
  if (input.length > exportedI32(exports, inputCapName)) throw new Error("input exceeds capacity");
  new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  if (outputSize > exportedI32(exports, outputCapName)) throw new Error("output exceeds capacity");
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return Buffer.from(new Uint8Array(exports.memory.buffer, outputPtr, outputSize));
}

const [wasmPath, inputPath, durationArg = "2000", outputPath] = process.argv.slice(2);
if (!wasmPath || !inputPath) {
  console.error("usage: bench-content-node.mjs module.wasm input [duration-ms] [output]");
  process.exit(2);
}

const wasm = await readFile(wasmPath);
const input = await readFile(inputPath);

let start = performance.now();
const compiled = await WebAssembly.compile(wasm);
const compileMs = performance.now() - start;

start = performance.now();
const instance = await WebAssembly.instantiate(compiled, {});
const instantiateMs = performance.now() - start;

let output = renderOnce(instance.exports, input);
for (let i = 0; i < 20; i += 1) output = renderOnce(instance.exports, input);

const durationMs = Number(durationArg);
const samples = [];
const deadline = performance.now() + durationMs;
do {
  start = performance.now();
  output = renderOnce(instance.exports, input);
  samples.push(performance.now() - start);
} while (performance.now() < deadline);

if (outputPath) await import("node:fs/promises").then(({ writeFile }) => writeFile(outputPath, output));

console.log(JSON.stringify({
  runtime: `node-${process.versions.node}-v8-${process.versions.v8}`,
  module: wasmPath,
  input_bytes: input.length,
  output_bytes: output.length,
  output_sha256: createHash("sha256").update(output).digest("hex"),
  wasm_bytes: wasm.length,
  linear_memory_bytes: instance.exports.memory.buffer.byteLength,
  process_rss_bytes: process.memoryUsage().rss,
  compile_ms: compileMs,
  instantiate_ms: instantiateMs,
  warm_full: summarize(samples),
}));
