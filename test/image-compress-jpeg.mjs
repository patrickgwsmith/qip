import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function makeKtx2() {
  const module = await WebAssembly.compile(
    await readFile("image/png/png-to-ktx2-r8g8b8a8-srgb.wasm"),
  );
  const { exports } = new WebAssembly.Instance(module, {});
  const png = await readFile("fixtures/image-compress/red-zeppelin-320x240.png");
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), png.length).set(png);
  const bits = BigInt.asUintN(64, exports.render(png.length));
  const size = Number(bits & 0xffff_ffffn);
  const pointer = Number((bits >> 32n) & 0x7fff_ffffn);
  return Buffer.from(new Uint8Array(exports.memory.buffer, pointer, size).slice());
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

  const ktx2 = await makeKtx2();
  await self.onmessage({
    data: { type: "init", codec: "jpeg", input: ktx2.buffer, hasAlpha: false },
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
