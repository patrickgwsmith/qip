import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const paths = [
  "text/base64-decode.wasm",
  "text/base64-decode-simd.wasm",
  "text/base64-decode-c.wasm",
  "text/base64-decode-c-simd.wasm",
  "text/base64-decode-zig.wasm",
  "text/base64-decode-zig-simd.wasm",
  "text/base64-decode-odin.wasm",
  "text/base64-decode-odin-simd.wasm",
];
const components = await Promise.all(paths.map(async (path) => {
  const { instance } = await WebAssembly.instantiate(readFileSync(path));
  return instance.exports;
}));

function run(component, input) {
  const start = component.input_ptr();
  new Uint8Array(component.memory.buffer, start, input.length).set(input);
  const result = component.render(input.length);
  if (result >> 63n) return { error: Number(result & 0xffffffffn) };
  const size = Number(result & 0xffffffffn);
  const ptr = Number(result >> 32n);
  return { output: Buffer.from(new Uint8Array(component.memory.buffer, ptr, size)) };
}

function check(input) {
  const expected = run(components[0], input);
  for (let i = 1; i < components.length; i++) {
    assert.deepEqual(run(components[i], input), expected, paths[i]);
  }
}

for (const input of ["", "TQ==", "TWE=", "TWFu", "A", "!!!!", "A===", "TQ=A", "TQ==AAAA", "TR==", "TWF="]) {
  check(Buffer.from(input));
}

let state = 0x12345678;
function nextByte() {
  state ^= state << 13;
  state ^= state >>> 17;
  state ^= state << 5;
  return state & 255;
}

for (let n = 0; n < 256; n++) {
  const bytes = Buffer.alloc(n);
  for (let i = 0; i < n; i++) bytes[i] = nextByte();
  const encoded = Buffer.from(bytes.toString("base64"));
  check(encoded);
  for (let i = 0; i < encoded.length; i++) {
    const invalid = Buffer.from(encoded);
    invalid[i] = i % 2 ? "=".charCodeAt(0) : "!".charCodeAt(0);
    check(invalid);
  }
}

// Every byte value in every vector lane must preserve the scalar decoder's
// output or exact rejection offset, including the final unpadded vector.
const vectorInput = Buffer.from("QUJD".repeat(12));
for (let offset = 0; offset < vectorInput.length; offset++) {
  for (let byte = 0; byte < 256; byte++) {
    const candidate = Buffer.from(vectorInput);
    candidate[offset] = byte;
    try {
      check(candidate);
    } catch (error) {
      throw new Error(`vector byte ${byte} at offset ${offset}`, { cause: error });
    }
  }
}

const maxBytes = Buffer.alloc(49152);
for (let i = 0; i < maxBytes.length; i++) maxBytes[i] = nextByte();
for (const length of [49150, 49151, 49152]) {
  const encoded = Buffer.from(maxBytes.subarray(0, length).toString("base64"));
  assert.equal(encoded.length, 65536);
  check(encoded);
  for (const offset of [0, 15, 16, 32767, 65520, 65535]) {
    const invalid = Buffer.from(encoded);
    invalid[offset] = "!".charCodeAt(0);
    check(invalid);
  }
}

console.log("Base64 decoder variants match the WAT component");
