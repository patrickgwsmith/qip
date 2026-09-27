#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";

function exportedI32(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(`Wasm module must export ${name}() -> i32`);
  return value() >>> 0;
}

function renderOnce(exports, input) {
  const inputPtr = exportedI32(exports, "input_ptr");
  const inputCapName = exports.input_utf8_cap ? "input_utf8_cap" : "input_bytes_cap";
  const outputCapName = exports.output_utf8_cap ? "output_utf8_cap" : "output_bytes_cap";
  if (input.length > exportedI32(exports, inputCapName)) {
    throw new Error("input exceeds component capacity");
  }
  new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  if (outputSize > exportedI32(exports, outputCapName)) {
    throw new Error("component output exceeds capacity");
  }
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  return new Uint8Array(exports.memory.buffer, outputPtr, outputSize);
}

function renderRecipe(instances, input) {
  let bytes = input;
  for (const instance of instances) bytes = renderOnce(instance.exports, bytes);
  return bytes;
}

function percentile(sorted, fraction) {
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    samples: samples.length,
    mean_ms: samples.reduce((sum, value) => sum + value, 0) / samples.length,
    p50_ms: percentile(sorted, 0.50),
    p95_ms: percentile(sorted, 0.95),
    max_ms: sorted.at(-1),
  };
}

const [inputPath, durationArg = "2000", ...recipeArgs] = process.argv.slice(2);
let warmup = 20;
let wasmPaths = recipeArgs;
if (recipeArgs[0] === "--warmup") {
  if (!/^[1-9][0-9]*$/.test(recipeArgs[1] ?? "")) {
    throw new Error("--warmup requires a positive integer");
  }
  warmup = Number(recipeArgs[1]);
  wasmPaths = recipeArgs.slice(2);
}
if (!inputPath || wasmPaths.length === 0) {
  console.error(
    "usage: bench-content-node-recipe.mjs input duration-ms " +
      "[--warmup N] module.wasm ...",
  );
  process.exit(2);
}

const input = await readFile(inputPath);
const wasmBytes = await Promise.all(wasmPaths.map((path) => readFile(path)));
let start = performance.now();
const compiled = await Promise.all(wasmBytes.map((bytes) => WebAssembly.compile(bytes)));
const compileMs = performance.now() - start;
start = performance.now();
const instances = await Promise.all(compiled.map((module) => WebAssembly.instantiate(module, {})));
const instantiateMs = performance.now() - start;
const initialRssBytes = process.memoryUsage().rss;

let output = renderRecipe(instances, input);
const firstRssBytes = process.memoryUsage().rss;
for (let i = 1; i < warmup; i += 1) output = renderRecipe(instances, input);

const samples = [];
const deadline = performance.now() + Number(durationArg);
do {
  start = performance.now();
  output = renderRecipe(instances, input);
  samples.push(performance.now() - start);
} while (performance.now() < deadline);

const memorySizes = instances.map((instance) => instance.exports.memory.buffer.byteLength);
console.log(JSON.stringify({
  runtime: `node-${process.versions.node}-v8-${process.versions.v8}`,
  steps: instances.length,
  input_bytes: input.length,
  output_bytes: output.length,
  output_sha256: createHash("sha256").update(output).digest("hex"),
  wasm_bytes: wasmBytes.reduce((sum, bytes) => sum + bytes.length, 0),
  linear_memory_bytes: memorySizes.reduce((sum, size) => sum + size, 0),
  largest_linear_memory_bytes: Math.max(...memorySizes),
  initial_rss_bytes: initialRssBytes,
  first_rss_bytes: firstRssBytes,
  final_rss_bytes: process.memoryUsage().rss,
  compile_ms: compileMs,
  instantiate_ms: instantiateMs,
  warm_recipe: summarize(samples),
}));
