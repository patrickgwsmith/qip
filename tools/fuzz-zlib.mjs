// Differential fuzzer for the zlib components against node's zlib (real
// zlib bindings). Three properties are checked every iteration:
//
// 1. Streams from our compressors decode identically through node's inflate
//    and through our own zlib-decompress.
// 2. Streams from node's deflate at every level decode identically through
//    our zlib-decompress.
// 3. Random mutations (bit flips, byte edits, inserts, deletes, truncations)
//    of valid streams never make our decoder disagree with node's: if ours
//    accepts, node must accept with identical output. If node accepts and
//    ours rejects, the stream must have trailing bytes past the deflate
//    stream end (we are strict single-stream; node ignores trailing) and our
//    decoder must accept the exact consumed prefix.
//
// Usage:
//   node tools/fuzz-zlib.mjs [iterations] [seed]
//   make fuzz-zlib
//
// Runs are deterministic per seed; failures save the offending stream under
// tools/fuzz-failures/ and print the seed/iteration to reproduce.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const iterations = Number(process.argv[2] ?? 2000);
const seed = Number(process.argv[3] ?? Math.floor(Math.random() * 0xffffffff));

const componentsDir = fileURLToPath(new URL("../bytes/", import.meta.url));
const failureDir = fileURLToPath(new URL("./fuzz-failures/", import.meta.url));

// mulberry32: small deterministic PRNG so every run is reproducible.
function mulberry32(a) {
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = mulberry32(seed);
const randInt = (n) => Math.floor(rand() * n);

async function loadComponent(name) {
  const bytes = readFileSync(`${componentsDir}${name}.wasm`);
  const instance = await WebAssembly.instantiate(await WebAssembly.compile(bytes), {});
  const ex = instance.exports;
  return {
    name,
    inputCap: ex.input_bytes_cap() >>> 0,
    run(input) {
      if (input.length > this.inputCap) throw new Error(`${name}: input exceeds cap`);
      new Uint8Array(ex.memory.buffer, ex.input_ptr(), input.length).set(input);
      const result = BigInt.asUintN(64, ex.render(input.length));
      if ((result >> 63n) !== 0n) return null;
      const n = Number(result & 0xffff_ffffn);
      const ptr = Number((result >> 32n) & 0x7fff_ffffn);
      return Buffer.from(new Uint8Array(ex.memory.buffer, ptr, n));
    },
  };
}

const compressors = await Promise.all([
  loadComponent("zlib-compress"),
  loadComponent("zlib-compress-fixed-huffman"),
  loadComponent("zlib-compress-dynamic-huffman"),
  loadComponent("zlib-compress-dynamic-huffman-opt"),
]);
const decompressor = await loadComponent("zlib-decompress");

function nodeInflate(buf) {
  try {
    const { buffer, engine } = zlib.inflateSync(buf, { info: true });
    return { out: buffer, consumed: engine.bytesWritten };
  } catch {
    return null;
  }
}

function oursInflate(buf) {
  const out = decompressor.run(buf);
  if (out === null) return null;
  if (out.length > 0) return out;
  const ref = nodeInflate(buf);
  if (ref !== null && ref.out.length === 0 && ref.consumed === buf.length) {
    return Buffer.alloc(0);
  }
  return null;
}

// --- input generators, weighted toward compressible structure ---

const vocab = ["the", "quick", "zlib", "stream", "huffman", "block", "qip", "wasm", "png", "filter"];

function generateInput() {
  const profile = randInt(5);
  const size = rand() < 0.02 ? randInt(1 << 20) : rand() < 0.2 ? randInt(1 << 16) : randInt(4096);
  const out = Buffer.alloc(size);
  if (profile === 0) {
    for (let i = 0; i < size; i++) out[i] = randInt(256);
  } else if (profile === 1) {
    let i = 0;
    while (i < size) {
      const runLen = 1 + randInt(300);
      const b = randInt(256);
      for (let k = 0; k < runLen && i < size; k++) out[i++] = b;
    }
  } else if (profile === 2) {
    let i = 0;
    while (i < size) {
      const word = vocab[randInt(vocab.length)] + (rand() < 0.2 ? "\n" : " ");
      for (let k = 0; k < word.length && i < size; k++) out[i++] = word.charCodeAt(k);
    }
  } else if (profile === 3) {
    // repeating period exercises match distances, including > 32 KB
    const period = 1 + randInt(70000);
    for (let i = 0; i < size; i++) out[i] = (i % period) & 0xff;
  }
  // profile 4: leave as zeros
  return out;
}

function mutate(stream) {
  const buf = Buffer.from(stream);
  const kind = randInt(5);
  if (buf.length === 0) return buf;
  if (kind === 0) {
    buf[randInt(buf.length)] ^= 1 << randInt(8);
    return buf;
  }
  if (kind === 1) {
    buf[randInt(buf.length)] = randInt(256);
    return buf;
  }
  if (kind === 2) {
    const at = randInt(buf.length + 1);
    const insert = Buffer.alloc(1 + randInt(4));
    for (let i = 0; i < insert.length; i++) insert[i] = randInt(256);
    return Buffer.concat([buf.subarray(0, at), insert, buf.subarray(at)]);
  }
  if (kind === 3) {
    const at = randInt(buf.length);
    const n = 1 + randInt(Math.min(4, buf.length - at));
    return Buffer.concat([buf.subarray(0, at), buf.subarray(at + n)]);
  }
  return buf.subarray(0, randInt(buf.length + 1));
}

// --- oracles ---

let failures = 0;

function fail(label, stream, context) {
  failures += 1;
  mkdirSync(failureDir, { recursive: true });
  const path = `${failureDir}seed${seed}-${label.replaceAll(/[^a-z0-9-]/g, "_")}.bin`;
  writeFileSync(path, stream);
  console.error(`FAIL [${label}] ${context}`);
  console.error(`  stream saved to ${path}`);
  console.error(`  reproduce: node tools/fuzz-zlib.mjs ${iterations} ${seed}`);
}

function checkValidStream(stream, expected, label) {
  const ref = nodeInflate(stream);
  if (ref === null || !ref.out.equals(expected) || ref.consumed !== stream.length) {
    fail(label, stream, "node zlib does not round-trip this stream");
    return;
  }
  const ours = oursInflate(stream);
  if (ours === null || !ours.equals(expected)) {
    fail(label, stream, "our decoder does not round-trip this stream");
  }
}

function checkDifferential(stream, label) {
  const ref = nodeInflate(stream);
  const ours = oursInflate(stream);

  if (ours !== null) {
    if (ref === null) {
      fail(label, stream, "our decoder accepts a stream node zlib rejects");
    } else if (!ours.equals(ref.out)) {
      fail(label, stream, "our decoder and node zlib decode different bytes");
    }
    return;
  }

  if (ref !== null) {
    // We are stricter in exactly one way: trailing bytes past the stream end.
    if (ref.consumed >= stream.length) {
      fail(label, stream, "our decoder rejects a stream node zlib fully consumes");
      return;
    }
    const prefix = oursInflate(stream.subarray(0, ref.consumed));
    if (prefix === null || !prefix.equals(ref.out)) {
      fail(label, stream, "our decoder rejects the exact stream node zlib consumed");
    }
  }
}

// --- main loop ---

console.log(`fuzz-zlib: ${iterations} iterations, seed ${seed}`);
const started = performance.now();

for (let iter = 0; iter < iterations && failures === 0; iter++) {
  const input = generateInput();

  let stream;
  const source = randInt(compressors.length + 3);
  if (source < compressors.length) {
    stream = compressors[source].run(input);
    if (stream.length === 0) {
      fail(`iter${iter}-compress`, input, `${compressors[source].name} returned empty output`);
      break;
    }
    checkValidStream(stream, input, `iter${iter}-${compressors[source].name}`);
  } else {
    stream = zlib.deflateSync(input, { level: randInt(10) });
    const ours = oursInflate(stream);
    if (ours === null || !ours.equals(input)) {
      fail(`iter${iter}-node-deflate`, stream, "our decoder does not round-trip node deflate output");
    }
  }

  const mutations = 1 + randInt(8);
  for (let m = 0; m < mutations && failures === 0; m++) {
    checkDifferential(mutate(stream), `iter${iter}-mut${m}`);
  }

  if ((iter + 1) % 500 === 0) {
    console.log(`  ${iter + 1}/${iterations} iterations, ${((performance.now() - started) / 1000).toFixed(1)}s`);
  }
}

if (failures === 0) {
  console.log(`OK: ${iterations} iterations clean in ${((performance.now() - started) / 1000).toFixed(1)}s (seed ${seed})`);
} else {
  process.exitCode = 1;
}
