import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const moduleNames = [
  "gpu-lexer-classifier-simd.wasm",
  "gpu-lexer-classifier-simd-odin.wasm",
  "gpu-lexer-classifier-simd-relaxed.wasm",
];
const tokenCount = Number.parseInt(process.argv[2] ?? "2483870", 10);
const runCount = Number.parseInt(process.argv[3] ?? "3", 10);
if (!Number.isSafeInteger(tokenCount) || tokenCount <= 0) throw new RangeError("token count must be positive");
if (!Number.isSafeInteger(runCount) || runCount <= 0) throw new RangeError("run count must be positive");

const modules = [];
for (const name of moduleNames) {
  const path = fileURLToPath(new URL(name, import.meta.url));
  const bytes = await readFile(path);
  const { instance } = await WebAssembly.instantiate(bytes);
  modules.push({ name, bytes: bytes.length, wasm: instance.exports, samples: [] });
}

const featureCount = modules[0].wasm.features_f32_cap();
const weightCount = modules[0].wasm.weights_f32_cap();
let randomState = 0x51f15e5d;
function randomWeight(scale) {
  randomState = (Math.imul(randomState, 1664525) + 1013904223) >>> 0;
  return ((randomState >>> 8) / 0x1000000 - 0.5) * scale;
}
const featureValues = Float32Array.from({ length: featureCount }, () => randomWeight(0.2));
const weightValues = Float32Array.from({ length: weightCount }, () => randomWeight(0.1));

for (const module of modules) {
  const { wasm } = module;
  if (wasm.features_f32_cap() !== featureCount || wasm.weights_f32_cap() !== weightCount) {
    throw new Error(`${module.name} has different buffer capacities`);
  }
  new Float32Array(wasm.memory.buffer, wasm.features_ptr(), featureCount).set(featureValues);
  new Float32Array(wasm.memory.buffer, wasm.weights_ptr(), weightCount).set(weightValues);

  const validationCount = Math.min(wasm.labels_cap(), tokenCount);
  wasm.classify_scalar(validationCount);
  const labels = new Uint8Array(wasm.memory.buffer, wasm.labels_ptr(), wasm.labels_cap());
  const scalarLabels = labels.slice(0, validationCount);
  wasm.classify_simd(validationCount);
  for (let index = 0; index < validationCount; index += 1) {
    if (labels[index] !== scalarLabels[index]) {
      throw new Error(`${module.name} SIMD label differs at token ${index}`);
    }
  }
  module.validationLabels = labels.slice(0, validationCount);
}

const referenceLabels = modules[0].validationLabels;
for (const module of modules.slice(1)) {
  for (let index = 0; index < referenceLabels.length; index += 1) {
    if (module.validationLabels[index] !== referenceLabels[index]) {
      throw new Error(`${module.name} label differs from ${modules[0].name} at token ${index}`);
    }
  }
}

function classifyAll(wasm) {
  let remaining = tokenCount;
  let checksum = 0;
  const batchSize = wasm.labels_cap();
  while (remaining > 0) {
    const count = Math.min(remaining, batchSize);
    checksum = (checksum + wasm.classify_simd(count)) >>> 0;
    remaining -= count;
  }
  return checksum;
}

for (const module of modules) classifyAll(module.wasm);
const checksums = new Map();
for (let run = 0; run < runCount; run += 1) {
  const order = run % 2 === 0 ? modules : [...modules].reverse();
  for (const module of order) {
    const start = performance.now();
    const checksum = classifyAll(module.wasm);
    module.samples.push(performance.now() - start);
    const expected = checksums.get(module.name);
    if (expected !== undefined && expected !== checksum) throw new Error(`${module.name} checksum changed`);
    checksums.set(module.name, checksum);
  }
}

function summarize(module) {
  const sorted = [...module.samples].sort((left, right) => left - right);
  const mean = module.samples.reduce((sum, value) => sum + value, 0) / module.samples.length;
  return {
    mean_ms: mean.toFixed(2),
    min_ms: sorted[0].toFixed(2),
    max_ms: sorted.at(-1).toFixed(2),
    million_tokens_per_second: (tokenCount / mean / 1000).toFixed(3),
    wasm_bytes: module.bytes,
  };
}

console.table(Object.fromEntries(modules.map((module) => [module.name, summarize(module)])));
console.log({
  token_count: tokenCount,
  run_count: runCount,
  multiply_adds_per_token: 7432,
  node: process.versions.node,
  v8: process.versions.v8,
});
