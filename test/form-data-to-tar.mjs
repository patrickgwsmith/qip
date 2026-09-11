import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await WebAssembly.compile(
  await readFile("multipart/form-data/form-data-to-tar.wasm"),
);
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const TYPE_PREFIX = "multipart/form-data;boundary=uuid-";

function exportedString(exports, pointerName, sizeName) {
  const pointer = exports[pointerName]();
  const size = exports[sizeName]();
  return decoder.decode(new Uint8Array(exports.memory.buffer, pointer, size));
}

async function convert(parts, uuid = "12345678-90ab-cdef-1234-567890abcdef") {
  const { exports } = await WebAssembly.instantiate(wasm, {});
  const typePointer = exports.input_content_type_ptr();
  const typeSize = exports.input_content_type_size();
  assert.equal(typeSize, TYPE_PREFIX.length + 36);
  new Uint8Array(exports.memory.buffer, typePointer + TYPE_PREFIX.length, 36).set(
    encoder.encode(uuid),
  );
  assert.equal(
    exportedString(exports, "input_content_type_ptr", "input_content_type_size"),
    TYPE_PREFIX + uuid,
  );

  const boundary = "uuid-" + uuid;
  const chunks = [];
  for (const part of parts) {
    chunks.push(
      `--${boundary}\r\nContent-Disposition: form-data; name="${part.name}"` +
        (part.filename === undefined ? "" : `; filename="${part.filename}"`) +
        "\r\n" +
        (part.type === undefined ? "" : `Content-Type: ${part.type}\r\n`) +
        "\r\n",
      part.body,
      "\r\n",
    );
  }
  chunks.push(`--${boundary}--\r\n`);
  const bytes = Buffer.concat(
    chunks.map((chunk) =>
      typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk),
    ),
  );
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  const outputSize = qipRenderSize(exports, bytes.length);
  return Buffer.from(
    new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), outputSize),
  );
}

function octal(field) {
  return Number.parseInt(decoder.decode(field).replaceAll("\0", "").trim() || "0", 8);
}

function parseTar(tar) {
  const entries = [];
  let offset = 0;
  while (!tar.subarray(offset, offset + 512).every((byte) => byte === 0)) {
    const header = tar.subarray(offset, offset + 512);
    const expected = octal(header.subarray(148, 156));
    const actual = header.reduce(
      (sum, byte, index) => sum + (index >= 148 && index < 156 ? 0x20 : byte),
      0,
    );
    assert.equal(actual, expected);
    assert.deepEqual([...header.subarray(257, 265)], [117, 115, 116, 97, 114, 0, 48, 48]);
    const nameEnd = header.indexOf(0);
    const name = decoder.decode(header.subarray(0, nameEnd));
    const size = octal(header.subarray(124, 136));
    const start = offset + 512;
    entries.push({ name, body: Buffer.from(tar.subarray(start, start + size)) });
    offset = start + Math.ceil(size / 512) * 512;
  }
  assert.ok(tar.subarray(offset).length >= 1024);
  assert.ok(tar.subarray(offset).every((byte) => byte === 0));
  return entries;
}

test("uses the live UUID boundary and emits deterministic ustar", async () => {
  const tar = await convert([
    { name: "reference.bmp", filename: "ignored.bmp", type: "image/bmp", body: [0x42, 0x4d, 0] },
    { name: "candidate.bmp", body: [0x42, 0x4d, 1, 2] },
  ]);
  assert.deepEqual(parseTar(tar), [
    { name: "reference.bmp", body: Buffer.from([0x42, 0x4d, 0]) },
    { name: "candidate.bmp", body: Buffer.from([0x42, 0x4d, 1, 2]) },
  ]);
  assert.deepEqual(tar, await convert([
    { name: "reference.bmp", filename: "ignored.bmp", type: "image/bmp", body: [0x42, 0x4d, 0] },
    { name: "candidate.bmp", body: [0x42, 0x4d, 1, 2] },
  ]));
});

test("preserves safe nested names and boundary-like body bytes", async () => {
  const body = encoder.encode("before\r\n--uuid-12345678-90ab-cdef-1234-567890abcdef-not-a-delimiter\nafter");
  const entries = parseTar(await convert([{ name: "reports/result.txt", body }]));
  assert.deepEqual(entries, [{ name: "reports/result.txt", body: Buffer.from(body) }]);
});

test("turns an empty form into an empty archive", async () => {
  assert.deepEqual(parseTar(await convert([])), []);
});

test("rejects unsafe and duplicate names", async () => {
  await assert.rejects(() => convert([{ name: "../secret", body: [] }]));
  await assert.rejects(() => convert([
    { name: "same.txt", body: [1] },
    { name: "same.txt", body: [2] },
  ]));
});

test("rejects a non-canonical UUID in the writable slot", async () => {
  await assert.rejects(() =>
    convert([{ name: "file.txt", body: [] }], "12345678-90AB-cdef-1234-567890abcdef"),
  );
});
