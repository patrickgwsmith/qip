import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const runnerPath = "application/wasm/qip-interpret-memory-thermal-ktx2.wasm";
const pageWritesPath = "application/wasm/qip-interpret-memory-page-writes-csv.wasm";
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const markdown = encoder.encode("# Hello\n\nSome *text* with [a link](https://example.com).\n");
const ktx2HeaderSize = 224;
const tileBytes = 65536;

function multipart(parts) {
  const chunks = [];
  for (const [name, body] of parts) {
    chunks.push(
      Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="${name}"\r\n\r\n`,
      ),
      Buffer.from(body),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

function parseImage(output) {
  const bytes = Buffer.from(output);
  assert.equal(bytes.readUInt32LE(12), 43, "VK_FORMAT_R8G8B8A8_SRGB");
  const width = bytes.readUInt32LE(20);
  const height = bytes.readUInt32LE(24);
  assert.equal(width, 256);
  assert.equal(height % 256, 0);
  const pixels = bytes.subarray(ktx2HeaderSize);
  assert.equal(pixels.length, width * height * 4);
  return { tiles: height / 256, pixels };
}

async function runTarget(uniforms = {}) {
  const [runner, target] = await Promise.all([
    readFile(runnerPath),
    readFile("text/markdown/commonmark.0.31.2.wasm"),
  ]);
  const host = new ContentComponentHost(runner, { label: "memory thermal" });
  return host.run(multipart([["component", target], ["input", markdown]]), { uniforms });
}

test("draws one tile per page that render read or wrote", async () => {
  const [result, pageWrites, target] = await Promise.all([
    runTarget({ normalize: 0 }),
    readFile(pageWritesPath),
    readFile("text/markdown/commonmark.0.31.2.wasm"),
  ]);
  assert.equal(result.status, "accepted");
  const { tiles, pixels } = parseImage(result.output);

  const csvHost = new ContentComponentHost(pageWrites, { label: "memory page writes" });
  const csv = csvHost.run(multipart([["component", target], ["input", markdown]]));
  const touchedPages = decoder.decode(csv.output).trimEnd().split("\n").slice(1)
    .map((line) => line.split(","))
    .filter((row) => Number(row[3]) > 0 || Number(row[5]) > 0);
  assert.equal(tiles, touchedPages.length);

  let stackTileWork = 0;
  let bytesWithWork = 0;
  let unusedDataBytes = 0;
  const stackTile = touchedPages.findIndex((row) => row[1].split("+").includes("stack"));
  assert.ok(stackTile >= 0);
  for (let tile = 0; tile < tiles; tile++) {
    let touched = 0;
    for (let offset = 0; offset < tileBytes; offset++) {
      const pixel = (tile * tileBytes + offset) * 4;
      const [red, green, blue, alpha] = pixels.subarray(pixel, pixel + 4);
      if (alpha < 64) {
        assert.equal(red + green + blue, 0, "untouched bytes carry no work");
        assert.ok([0, 24, 40].includes(alpha), "untouched bytes are empty, data, or input");
        if (alpha === 24) unusedDataBytes++;
        continue;
      }
      touched++;
      assert.ok(alpha >= 64, "touched bytes stay visible");
      if (red > 0) bytesWithWork++;
      if (tile === stackTile) stackTileWork += red + green + blue;
    }
    assert.ok(touched > 0, `tile ${tile} has touched bytes`);
  }
  assert.equal(stackTileWork, 0, "stack writes take no work");
  assert.ok(bytesWithWork > 0);
  assert.ok(unusedDataBytes > 0, "data segment bytes that render never touched are marked");
});

test("normalizes each channel to its maximum by default", async () => {
  const result = await runTarget();
  assert.equal(result.status, "accepted");
  const { pixels } = parseImage(result.output);
  const maximum = [0, 0, 0, 0];
  for (let index = 0; index < pixels.length; index += 4) {
    for (let channel = 0; channel < 4; channel++) maximum[channel] = Math.max(maximum[channel], pixels[index + channel]);
  }
  assert.deepEqual(maximum, [255, 255, 255, 255]);
});

test("first_page skips lower pages", async () => {
  const all = parseImage((await runTarget()).output);
  const skipped = parseImage((await runTarget({ first_page: 16 })).output);
  assert.ok(skipped.tiles < all.tiles);
  assert.equal((await runTarget({ first_page: 3000 })).status, "rejected");
});

test("rejects a missing or invalid target", async () => {
  const runner = await readFile(runnerPath);
  const host = new ContentComponentHost(runner, { label: "memory thermal" });
  assert.equal(host.run(multipart([["input", encoder.encode("rgb(1, 2, 3)")]])).status, "rejected");
  assert.equal(host.run(multipart([["component", encoder.encode("not wasm")]])).status, "rejected");
});

test("declares KTX2 output", async () => {
  const runner = await readFile(runnerPath);
  const { instance } = await WebAssembly.instantiate(runner);
  const pointer = instance.exports.output_content_type_ptr();
  const size = instance.exports.output_content_type_size();
  assert.equal(
    decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer, size)),
    "image/ktx2;vkFormat=R8G8B8A8_SRGB;colorPrimaries=BT709;transferFunction=SRGB",
  );
});
