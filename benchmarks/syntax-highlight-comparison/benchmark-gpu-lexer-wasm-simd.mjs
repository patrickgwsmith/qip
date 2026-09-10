import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const moduleName = process.env.WASM ?? "gpu-lexer-classifier-simd.wasm";
const modulePath = fileURLToPath(new URL(moduleName, import.meta.url));
// gpu-lexer emits 2,483,870 lexical tokens for ten copies of three.min.js.
const tokenCount = Number.parseInt(process.argv[2] ?? "2483870", 10);
const runCount = Number.parseInt(process.argv[3] ?? "3", 10);
if (!Number.isSafeInteger(tokenCount) || tokenCount <= 0) throw new RangeError("token count must be positive");
if (!Number.isSafeInteger(runCount) || runCount <= 0) throw new RangeError("run count must be positive");

const { instance } = await WebAssembly.instantiate(await readFile(modulePath));
const wasm = instance.exports;
const batchSize = wasm.labels_cap();
const features = new Float32Array(wasm.memory.buffer, wasm.features_ptr(), wasm.features_f32_cap());
const weights = new Float32Array(wasm.memory.buffer, wasm.weights_ptr(), wasm.weights_f32_cap());
const labels = new Uint8Array(wasm.memory.buffer, wasm.labels_ptr(), batchSize);

let randomState = 0x51f15e5d;
function randomWeight(scale) {
  randomState = (Math.imul(randomState, 1664525) + 1013904223) >>> 0;
  return ((randomState >>> 8) / 0x1000000 - 0.5) * scale;
}
for (let index = 0; index < features.length; index += 1) features[index] = randomWeight(0.2);
for (let index = 0; index < weights.length; index += 1) weights[index] = randomWeight(0.1);

const validationCount = Math.min(batchSize, tokenCount);
const scalarChecksum = wasm.classify_scalar(validationCount);
const scalarLabels = labels.slice(0, validationCount);
const simdChecksum = wasm.classify_simd(validationCount);
if (scalarChecksum !== simdChecksum) throw new Error("SIMD checksum differs from scalar checksum");
for (let index = 0; index < scalarLabels.length; index += 1) {
  if (scalarLabels[index] !== labels[index]) throw new Error(`SIMD label differs at token ${index}`);
}

function classifyAll(classify) {
  let remaining = tokenCount;
  let checksum = 0;
  while (remaining > 0) {
    const count = Math.min(remaining, batchSize);
    checksum = (checksum + classify(count)) >>> 0;
    remaining -= count;
  }
  return checksum;
}

classifyAll(wasm.classify_scalar);
classifyAll(wasm.classify_simd);

const samples = { scalar: [], simd: [] };
const checksums = {};
for (let run = 0; run < runCount; run += 1) {
  const order = run % 2 === 0
    ? [["scalar", wasm.classify_scalar], ["simd", wasm.classify_simd]]
    : [["simd", wasm.classify_simd], ["scalar", wasm.classify_scalar]];
  for (const [name, classify] of order) {
    const start = performance.now();
    const checksum = classifyAll(classify);
    samples[name].push(performance.now() - start);
    checksums[name] ??= checksum;
    if (checksums[name] !== checksum) throw new Error(`${name} checksum changed`);
  }
}

function summarize(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return {
    mean_ms: mean.toFixed(2),
    min_ms: sorted[0].toFixed(2),
    max_ms: sorted.at(-1).toFixed(2),
    million_tokens_per_second: (tokenCount / mean / 1000).toFixed(3),
  };
}

const scalar = summarize(samples.scalar);
const simd = summarize(samples.simd);
console.table({ scalar, simd });
console.log({
  token_count: tokenCount,
  batch_size: batchSize,
  multiply_adds_per_token: 7432,
  simd_speedup: `${(Number(scalar.mean_ms) / Number(simd.mean_ms)).toFixed(2)}x`,
  wasm: moduleName,
  wasm_bytes: (await readFile(modulePath)).length,
  node: process.versions.node,
  v8: process.versions.v8,
});
