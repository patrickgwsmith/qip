// Interoperability tests for the zstd components against Node's zlib
// bindings and the system zstd command.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import zlib from "node:zlib";

async function load(path) {
  const { instance } = await WebAssembly.instantiate(readFileSync(path), {});
  const ex = instance.exports;
  return {
    exports: ex,
    run(input) {
      assert.ok(input.length <= ex.input_bytes_cap(), `${path}: input exceeds cap`);
      new Uint8Array(ex.memory.buffer, ex.input_ptr(), input.length).set(input);
      const result = BigInt.asUintN(64, ex.render(input.length));
      if (result >> 63n) return null;
      const size = Number(result & 0xffff_ffffn);
      const ptr = Number((result >> 32n) & 0x7fff_ffffn);
      return Buffer.from(new Uint8Array(ex.memory.buffer, ptr, size));
    },
  };
}

const zstdCompress = await load("bytes/zstd-compress.wasm");
const zstdDecompress = await load("bytes/zstd-decompress.wasm");

const BLOCK_MAX = 128 * 1024;

// mulberry32, so inputs are the same on every run.
function prng(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomBytes(length, seed) {
  const rand = prng(seed);
  return Buffer.from(Array.from({ length }, () => Math.floor(rand() * 256)));
}

function sampleInputs() {
  const text = Buffer.from(
    Array.from({ length: 4000 }, (_, i) => `chr${(i % 22) + 1}\t${i * 137}\t${i * 137 + 50}\tfeature_${i % 97}\n`).join(""),
  );
  return {
    empty: Buffer.alloc(0),
    byte: Buffer.from("x"),
    text,
    random: randomBytes(3 * BLOCK_MAX + 17, 7),
    exactBlock: Buffer.alloc(BLOCK_MAX, 0x41),
    mixed: Buffer.concat([text, randomBytes(100_000, 9), text]),
    html: readFileSync("site/index.md"),
  };
}

test("zstd-compress output decompresses with Node and the zstd command", () => {
  for (const [name, input] of Object.entries(sampleInputs())) {
    const zst = zstdCompress.run(input);
    assert.ok(zst, name);
    assert.ok(zlib.zstdDecompressSync(zst).equals(input), name);
    assert.ok(execFileSync("zstd", ["-dc"], { input: zst, maxBuffer: 1 << 26 }).equals(input), name);
    assert.ok(zstdDecompress.run(zst).equals(input), name);
  }
});

// Literals are stored raw, so text compresses to about 1.5x zstd level 3.
test("zstd-compress output is deterministic and within 2x of zstd level 3 for text", () => {
  const { text } = sampleInputs();
  const first = zstdCompress.run(text);
  assert.ok(first.equals(zstdCompress.run(text)));
  assert.ok(first.length < text.length / 2);
  assert.ok(first.length < zlib.zstdCompressSync(text).length * 2);
});

test("zstd-compress keeps incompressible input within one raw block header per block", () => {
  const input = randomBytes(2 * BLOCK_MAX, 3);
  // Magic, descriptor, 4-byte content size, two block headers, checksum.
  assert.equal(zstdCompress.run(input).length, 4 + 1 + 4 + 2 * 3 + input.length + 4);
});

test("zstd-decompress reads Node zstd at several levels and concatenated frames", () => {
  const inputs = Object.values(sampleInputs());
  for (const input of inputs) {
    for (const level of [1, 3, 9, 19]) {
      const zst = zlib.zstdCompressSync(input, {
        params: { [zlib.constants.ZSTD_c_compressionLevel]: level, [zlib.constants.ZSTD_c_checksumFlag]: 1 },
      });
      assert.ok(zstdDecompress.run(zst).equals(input), `level ${level}`);
    }
  }
  const joined = Buffer.concat(inputs.map((input) => zlib.zstdCompressSync(input)));
  assert.ok(zstdDecompress.run(joined).equals(Buffer.concat(inputs)));
});

// zlib.zstdDecompressSync stops after the first frame, so this checks the
// zstd command instead.
test("concatenated zstd-compress frames decode as one stream", () => {
  const parts = ["<!doctype html><title>qip</title>", "<main>", "dynamic part", "</main>"].map((s) => Buffer.from(s));
  const joined = Buffer.concat(parts.map((part) => zstdCompress.run(part)));
  assert.equal(execFileSync("zstd", ["-dc"], { input: joined }).toString(), Buffer.concat(parts).toString());
  assert.equal(zstdDecompress.run(joined).toString(), Buffer.concat(parts).toString());
});

test("zstd-decompress rejects trailing bytes, truncation, and corrupt checksums", () => {
  const input = Buffer.from("strict zstd\n".repeat(50));
  const zst = zstdCompress.run(input);
  assert.equal(zstdDecompress.run(Buffer.alloc(0)), null);
  assert.equal(zstdDecompress.run(zlib.gzipSync(input)), null);
  assert.equal(zstdDecompress.run(Buffer.concat([zst, Buffer.from([0])])), null);
  assert.equal(zstdDecompress.run(zst.subarray(0, zst.length - 1)), null);
  const bad = Buffer.from(zst);
  bad[bad.length - 1] ^= 1;
  assert.equal(zstdDecompress.run(bad), null);
});

test("zstd-decompress never accepts a mutated stream that Node rejects", () => {
  const rand = prng(42);
  const base = [
    zlib.zstdCompressSync(sampleInputs().text.subarray(0, 4000), { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } }),
    zstdCompress.run(Buffer.from("qip zstd ".repeat(300))),
  ];
  for (let i = 0; i < 3000; i++) {
    const bad = Buffer.from(base[i % base.length]);
    const flips = 1 + Math.floor(rand() * 3);
    for (let k = 0; k < flips; k++) bad[Math.floor(rand() * bad.length)] ^= 1 << Math.floor(rand() * 8);
    const ours = zstdDecompress.run(bad);
    if (ours === null) continue;
    let theirs;
    try {
      theirs = zlib.zstdDecompressSync(bad);
    } catch {
      assert.fail(`iteration ${i}: accepted a stream that Node rejects`);
    }
    assert.ok(ours.equals(theirs), `iteration ${i}: output differs from Node`);
  }
});

test("zstd components declare application/zstd", () => {
  const contentType = (component, prefix) => {
    const ex = component.exports;
    return Buffer.from(
      new Uint8Array(ex.memory.buffer, ex[`${prefix}_content_type_ptr`](), ex[`${prefix}_content_type_size`]()),
    ).toString();
  };
  assert.equal(contentType(zstdCompress, "output"), "application/zstd");
  assert.equal(contentType(zstdDecompress, "input"), "application/zstd");
});
