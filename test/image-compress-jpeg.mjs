import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

function makeBmp(width, height) {
  const offset = 54;
  const bytes = Buffer.alloc(offset + width * height * 4);
  bytes.write("BM");
  bytes.writeUInt32LE(bytes.length, 2);
  bytes.writeUInt32LE(offset, 10);
  bytes.writeUInt32LE(40, 14);
  bytes.writeInt32LE(width, 18);
  bytes.writeInt32LE(height, 22);
  bytes.writeUInt16LE(1, 26);
  bytes.writeUInt16LE(32, 28);
  bytes.writeUInt32LE(width * height * 4, 34);
  for (let index = offset; index < bytes.length; index += 4) {
    bytes[index] = index & 255;
    bytes[index + 1] = (index * 3) & 255;
    bytes[index + 2] = (index * 7) & 255;
    bytes[index + 3] = 255;
  }
  return bytes;
}

test("image compressor keeps JPEG opt-in", async () => {
  const page = await readFile("site/image-compress.md", "utf8");
  assert.match(page, /value="webp" checked/);
  assert.match(page, /value="avif" checked/);
  assert.match(page, /value="jpeg"> JPEG/);
  assert.doesNotMatch(page, /value="jpeg" checked/);
});

test("image compressor worker runs the MozJPEG component", async () => {
  const messages = [];
  globalThis.self = {
    postMessage(message) {
      messages.push(message);
    },
    close() {},
  };
  globalThis.fetch = async (path) => new Response(
    await readFile(`.${path}`),
    { headers: { "content-type": "application/wasm" } },
  );
  await import(`../site/image-compress-worker.js?jpeg-test=${Date.now()}`);

  const bmp = makeBmp(16, 12);
  await self.onmessage({
    data: { type: "init", codec: "jpeg", input: bmp.buffer, hasAlpha: false },
  });
  assert.deepEqual(messages.shift(), { type: "ready", codec: "jpeg" });

  await self.onmessage({
    data: { type: "encode", id: "jpeg:40", quality: 40 },
  });
  const result = messages.shift();
  assert.equal(result.type, "result");
  assert.equal(result.codec, "jpeg");
  assert.equal(result.quality, 40);
  const jpeg = Buffer.from(result.output);
  assert.equal(jpeg.readUInt16BE(0), 0xffd8);
  assert.equal(jpeg.readUInt16BE(jpeg.length - 2), 0xffd9);
});
