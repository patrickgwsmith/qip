#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

function exportedI32(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(`Wasm module must export ${name}() -> i32`);
  return value() >>> 0;
}

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: bench-content-node-once.mjs component.wasm");
  process.exit(2);
}

const input = readFileSync(0);
const wasm = readFileSync(wasmPath);
const module = new WebAssembly.Module(wasm);
const instance = new WebAssembly.Instance(module, {});
const exports = instance.exports;
const inputPtr = exportedI32(exports, "input_ptr");
const inputCap = exportedI32(
  exports,
  exports.input_utf8_cap ? "input_utf8_cap" : "input_bytes_cap",
);
if (input.length > inputCap) throw new Error("input exceeds component capacity");
new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);
const result = BigInt.asUintN(64, exports.render(input.length));
if ((result >> 63n) !== 0n) throw new Error("rejected input");
const outputSize = Number(result & 0xffff_ffffn);
const outputCap = exportedI32(
  exports,
  exports.output_utf8_cap ? "output_utf8_cap" : "output_bytes_cap",
);
if (outputSize > outputCap) throw new Error("output exceeds component capacity");
const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
writeFileSync(
  1,
  new Uint8Array(exports.memory.buffer, outputPtr, outputSize),
);
