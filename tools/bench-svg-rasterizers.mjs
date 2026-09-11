#!/usr/bin/env node

import { performance } from "node:perf_hooks";
import { readFile } from "node:fs/promises";

const encoder = new TextEncoder();
const width = Number.parseInt(process.argv[2] ?? "256", 10);
const runs = Number.parseInt(process.argv[3] ?? "10", 10);
if (!Number.isInteger(width) || width < 1 || width > 4096) throw new Error("width must be 1..4096");
if (!Number.isInteger(runs) || runs < 1 || runs > 1000) throw new Error("runs must be 1..1000");

const tigerUrl = new URL("../test/fixtures/svg/ghostscript-tiger.svg", import.meta.url);
const rgba8Url = new URL(
  "../image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm",
  import.meta.url,
);
const floatUrl = new URL(
  "../image/svg+xml/svg-rasterize-to-ktx2-rgba32float-bt709-linear-simd.wasm",
  import.meta.url,
);
const rgba8SimdUrl = new URL(
  "../image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd.wasm",
  import.meta.url,
);
const thorvgUrl = new URL(
  "../image/svg+xml/svg-rasterize-thorvg-to-ktx2-r8g8b8a8-srgb.wasm",
  import.meta.url,
);

function decodeResult(result) {
  const bits = BigInt.asUintN(64, result);
  return {
    size: Number(bits & 0xffffffffn),
    pointer: Number((bits >> 32n) & 0x7fffffffn),
    failed: Number(bits >> 63n),
  };
}

async function load(url) {
  const wasm = await readFile(url);
  const { instance } = await WebAssembly.instantiate(wasm);
  return { exports: instance.exports, wasmBytes: wasm.length };
}

function percentile(sorted, fraction) {
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

function summarize(samples, pixelCount) {
  const sorted = [...samples].sort((a, b) => a - b);
  const mean = samples.reduce((sum, value) => sum + value, 0) / samples.length;
  return {
    meanMs: mean,
    medianMs: percentile(sorted, 0.5),
    p95Ms: percentile(sorted, 0.95),
    megapixelsPerSecond: pixelCount / mean / 1000,
  };
}

function renderOnce(exports, inputSize) {
  const result = decodeResult(exports.render(inputSize));
  if (result.failed) throw new Error(`render failed with code ${result.size}`);
  return result;
}

function linearToSrgb8(value) {
  const encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * value ** (1 / 2.4) - 0.055;
  return Math.max(0, Math.min(255, Math.round(encoded * 255)));
}

const source = await readFile(tigerUrl, "utf8");
const sizedSource = source.replace(/<svg\b/, `<svg width="${width}" height="${width}"`);
const input = encoder.encode(sizedSource);
const implementations = [
  { name: "RGBA8 center sample", url: rgba8Url, bytesPerPixel: 4 },
  { name: "RGBA8 SIMD scanline 4x4", url: rgba8SimdUrl, bytesPerPixel: 4 },
  { name: "RGBA32F SIMD scanline 4x4", url: floatUrl, bytesPerPixel: 16 },
  { name: "RGBA8 ThorVG CPU", url: thorvgUrl, bytesPerPixel: 4 },
];
const results = [];

for (const implementation of implementations) {
  const loaded = await load(implementation.url);
  const { exports } = loaded;
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  renderOnce(exports, input.length);
  const samples = [];
  let result;
  for (let run = 0; run < runs; run += 1) {
    const start = performance.now();
    result = renderOnce(exports, input.length);
    samples.push(performance.now() - start);
  }
  results.push({
    ...implementation,
    ...loaded,
    ...summarize(samples, width * width),
    result,
  });
}

const rgba8 = results[0];
const rgba8Simd = results[1];
const float = results[2];
const thorvg = results[3];
const rgba8Pixels = new Uint8Array(
  rgba8.exports.memory.buffer,
  rgba8.result.pointer + 224,
  width * width * 4,
);
const floatPixels = new DataView(
  float.exports.memory.buffer,
  float.result.pointer + 224,
  width * width * 16,
);
let fractionalAlphaPixels = 0;
let absoluteChannelDifference = 0;
for (let index = 0; index < width * width; index += 1) {
  const floatOffset = index * 16;
  const alpha = floatPixels.getFloat32(floatOffset + 12, true);
  if (alpha > 0 && alpha < 1) fractionalAlphaPixels += 1;
  absoluteChannelDifference += Math.abs(rgba8Pixels[index * 4] - linearToSrgb8(floatPixels.getFloat32(floatOffset, true)));
  absoluteChannelDifference += Math.abs(rgba8Pixels[index * 4 + 1] - linearToSrgb8(floatPixels.getFloat32(floatOffset + 4, true)));
  absoluteChannelDifference += Math.abs(rgba8Pixels[index * 4 + 2] - linearToSrgb8(floatPixels.getFloat32(floatOffset + 8, true)));
  absoluteChannelDifference += Math.abs(rgba8Pixels[index * 4 + 3] - Math.round(alpha * 255));
}

console.log(`Ghostscript Tiger, ${width}x${width}, ${runs} measured renders per component`);
for (const result of results) {
  console.log(
    `${result.name}: mean ${result.meanMs.toFixed(2)} ms, median ${result.medianMs.toFixed(2)} ms, ` +
      `p95 ${result.p95Ms.toFixed(2)} ms, ${result.megapixelsPerSecond.toFixed(2)} MP/s, ` +
      `${result.result.size} output bytes, ${result.wasmBytes} Wasm bytes`,
  );
}
console.log(`Scanline speedup over center sample: ${(rgba8.meanMs / float.meanMs).toFixed(2)}x`);
console.log(`Matched-quality RGBA8 relative time: ${(rgba8Simd.meanMs / float.meanMs).toFixed(2)}x`);
console.log(`RGBA32F output-size ratio: ${(float.result.size / rgba8.result.size).toFixed(2)}x`);
console.log(`ThorVG relative time to matched-quality RGBA8: ${(thorvg.meanMs / rgba8Simd.meanMs).toFixed(2)}x`);
console.log(`RGBA32F fractional-alpha pixels: ${fractionalAlphaPixels}`);
console.log(
  `Mean absolute channel difference after linear-to-sRGB conversion: ${(
    absoluteChannelDifference /
    (width * width * 4)
  ).toFixed(2)} / 255`,
);
