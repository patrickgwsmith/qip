// Interoperability tests for the gzip and BGZF components against Node's
// zlib bindings and the system gzip command.
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

const gzipCompress = await load("bytes/gzip-compress.wasm");
const gzipDecompress = await load("bytes/gzip-decompress.wasm");
const bgzfCompress = await load("bytes/bgzf-compress.wasm");
const bgzfDecompress = await load("bytes/bgzf-decompress.wasm");

const BGZF_EOF = Buffer.from("1f8b08040000000000ff0600424302001b0003000000000000000000", "hex");
const BGZF_BLOCK_DATA_MAX = 0xff00;

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
    random: randomBytes(3 * BGZF_BLOCK_DATA_MAX + 17, 7),
    exactBlock: Buffer.alloc(BGZF_BLOCK_DATA_MAX, 0x41),
    mixed: Buffer.concat([text, randomBytes(100_000, 9), text]),
  };
}

/** Splits BGZF output into members by BSIZE alone, as an indexed reader does. */
function bgzfMembers(bytes) {
  const members = [];
  let pos = 0;
  while (pos < bytes.length) {
    assert.deepEqual([...bytes.subarray(pos, pos + 4)], [0x1f, 0x8b, 0x08, 0x04]);
    assert.equal(bytes.readUInt16LE(pos + 10), 6, "XLEN");
    assert.equal(bytes.toString("latin1", pos + 12, pos + 14), "BC");
    assert.equal(bytes.readUInt16LE(pos + 14), 2, "SLEN");
    const size = bytes.readUInt16LE(pos + 16) + 1;
    assert.ok(size <= 0x10000);
    members.push(bytes.subarray(pos, pos + size));
    pos += size;
  }
  assert.equal(pos, bytes.length);
  return members;
}

test("gzip-compress output gunzips with Node and the gzip command", () => {
  for (const [name, input] of Object.entries(sampleInputs())) {
    const gz = gzipCompress.run(input);
    assert.ok(gz, name);
    assert.deepEqual([...gz.subarray(0, 10)], [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff], name);
    assert.ok(zlib.gunzipSync(gz).equals(input), name);
    assert.ok(execFileSync("gzip", ["-dc"], { input: gz, maxBuffer: 1 << 26 }).equals(input), name);
    assert.ok(gzipDecompress.run(gz).equals(input), name);
  }
});

test("gzip-compress output is deterministic and close to zlib level 6 for text", () => {
  const { text } = sampleInputs();
  const first = gzipCompress.run(text);
  assert.ok(first.equals(gzipCompress.run(text)));
  assert.ok(first.length < zlib.gzipSync(text).length * 1.1);
});

test("gzip-decompress reads Node gzip at every level and concatenated members", () => {
  const inputs = Object.values(sampleInputs());
  for (const input of inputs) {
    for (let level = 0; level <= 9; level++) {
      assert.ok(gzipDecompress.run(zlib.gzipSync(input, { level })).equals(input), `level ${level}`);
    }
  }
  const joined = Buffer.concat(inputs.map((input) => zlib.gzipSync(input)));
  assert.ok(gzipDecompress.run(joined).equals(Buffer.concat(inputs)));
});

test("gzip-decompress reads FNAME headers from the gzip command", () => {
  const input = Buffer.from("named member\n");
  const gz = execFileSync("gzip", ["-c", "-N"], { input });
  const named = Buffer.from(gz);
  named[3] |= 0x08;
  const withName = Buffer.concat([named.subarray(0, 10), Buffer.from("a.txt\0"), named.subarray(10)]);
  assert.ok(zlib.gunzipSync(withName).equals(input));
  assert.ok(gzipDecompress.run(withName).equals(input));
});

test("gzip-decompress rejects zlib, trailing bytes, truncation, and corrupt trailers", () => {
  const input = Buffer.from("strict gzip\n".repeat(50));
  const gz = zlib.gzipSync(input);
  assert.equal(gzipDecompress.run(Buffer.alloc(0)), null);
  assert.equal(gzipDecompress.run(zlib.deflateSync(input)), null);
  assert.equal(gzipDecompress.run(Buffer.concat([gz, Buffer.from([0])])), null);
  assert.equal(gzipDecompress.run(gz.subarray(0, gz.length - 1)), null);
  for (const offset of [gz.length - 8, gz.length - 4]) {
    const bad = Buffer.from(gz);
    bad[offset] ^= 1;
    assert.equal(gzipDecompress.run(bad), null);
  }
});

test("gzip-decompress never accepts a mutated stream that Node rejects", () => {
  const rand = prng(42);
  const base = [zlib.gzipSync(sampleInputs().text.subarray(0, 4000)), gzipCompress.run(Buffer.from("qip gzip ".repeat(300)))];
  for (let i = 0; i < 3000; i++) {
    const bad = Buffer.from(base[i % base.length]);
    const flips = 1 + Math.floor(rand() * 3);
    for (let k = 0; k < flips; k++) bad[Math.floor(rand() * bad.length)] ^= 1 << Math.floor(rand() * 8);
    const ours = gzipDecompress.run(bad);
    if (ours === null) continue;
    let theirs;
    try {
      theirs = zlib.gunzipSync(bad);
    } catch {
      assert.fail(`iteration ${i}: accepted a stream that Node rejects`);
    }
    assert.ok(ours.equals(theirs), `iteration ${i}: output differs from Node`);
  }
});

test("bgzf-compress writes valid BGZF that gunzip reads", () => {
  for (const [name, input] of Object.entries(sampleInputs())) {
    const bgzf = bgzfCompress.run(input);
    assert.ok(bgzf, name);
    assert.ok(bgzf.subarray(bgzf.length - BGZF_EOF.length).equals(BGZF_EOF), `${name}: EOF block`);
    const members = bgzfMembers(bgzf);
    assert.equal(members.length, Math.ceil(input.length / BGZF_BLOCK_DATA_MAX) + 1, name);

    // Every member stands alone, so each one gunzips to its own slice.
    let offset = 0;
    for (const member of members) {
      const plain = zlib.gunzipSync(member);
      assert.ok(plain.length <= BGZF_BLOCK_DATA_MAX);
      assert.ok(plain.equals(input.subarray(offset, offset + plain.length)), name);
      offset += plain.length;
    }
    assert.equal(offset, input.length, name);

    assert.ok(zlib.gunzipSync(bgzf).equals(input), name);
    assert.ok(execFileSync("gzip", ["-dc"], { input: bgzf, maxBuffer: 1 << 26 }).equals(input), name);
    assert.ok(gzipDecompress.run(bgzf).equals(input), name);
    assert.ok(bgzfDecompress.run(bgzf).equals(input), name);
  }
});

test("bgzf-compress keeps incompressible members within 64 KiB", () => {
  const input = randomBytes(2 * BGZF_BLOCK_DATA_MAX, 3);
  const members = bgzfMembers(bgzfCompress.run(input));
  assert.equal(members[0].length, 18 + 5 + BGZF_BLOCK_DATA_MAX + 8);
});

test("bgzf-decompress rejects plain gzip, truncation, and a wrong BSIZE", () => {
  const input = sampleInputs().text;
  const bgzf = bgzfCompress.run(input);
  assert.equal(bgzfDecompress.run(zlib.gzipSync(input)), null);
  assert.equal(bgzfDecompress.run(Buffer.concat([zlib.gzipSync(input), BGZF_EOF])), null);
  assert.equal(bgzfDecompress.run(bgzf.subarray(0, bgzf.length - BGZF_EOF.length)), null);
  assert.equal(bgzfDecompress.run(bgzf.subarray(0, bgzf.length - 1)), null);
  const bad = Buffer.from(bgzf);
  bad.writeUInt16LE(bad.readUInt16LE(16) - 1, 16);
  assert.equal(bgzfDecompress.run(bad), null);
});

test("gzip components declare application/gzip", () => {
  const contentType = (component, prefix) => {
    const ex = component.exports;
    return Buffer.from(
      new Uint8Array(ex.memory.buffer, ex[`${prefix}_content_type_ptr`](), ex[`${prefix}_content_type_size`]()),
    ).toString();
  };
  assert.equal(contentType(gzipCompress, "output"), "application/gzip");
  assert.equal(contentType(bgzfCompress, "output"), "application/gzip");
  assert.equal(contentType(gzipDecompress, "input"), "application/gzip");
  assert.equal(contentType(bgzfDecompress, "input"), "application/gzip");
});
