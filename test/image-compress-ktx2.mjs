import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const FIXTURES = "fixtures/image-compress";
const handlers = new Map();

// Node caches the worker modules, so each is imported once. Its handler reads
// the current self on every call, and the encode worker resets on "init".
async function runWorker(path, messages) {
  const posted = [];
  globalThis.self = {
    postMessage(message) {
      posted.push(message);
    },
    close() {},
  };
  globalThis.fetch = async (url) => new Response(
    await readFile(`.${url}`),
    { headers: { "content-type": "application/wasm" } },
  );
  if (!handlers.has(path)) {
    await import(`../site/${path}`);
    handlers.set(path, self.onmessage);
  }
  const handler = handlers.get(path);
  for (const message of messages) await handler({ data: message });
  return posted;
}

async function decode(format, file) {
  const input = await readFile(`${FIXTURES}/${file}`);
  const inputBuffer = input.buffer.slice(
    input.byteOffset,
    input.byteOffset + input.byteLength,
  );
  const [message] = await runWorker("image-compress-decode-worker.js", [
    { type: "decode", format, input: inputBuffer },
  ]);
  assert.equal(message.type, "done", message.message);
  return message;
}

async function encode(codec, decoded, quality = 40) {
  const posted = await runWorker("image-compress-worker.js", [
    {
      type: "init",
      codec,
      input: decoded.output.slice(0),
      hasAlpha: decoded.hasAlpha,
    },
    { type: "encode", id: `${codec}:${quality}`, quality },
  ]);
  assert.deepEqual(posted[0], { type: "ready", codec });
  assert.equal(posted[1].type, "result", posted[1].message);
  assert.equal(posted[1].quality, quality);
  return Buffer.from(posted[1].output);
}

function assertWebP(bytes) {
  assert.equal(bytes.toString("latin1", 0, 4), "RIFF");
  assert.equal(bytes.toString("latin1", 8, 12), "WEBP");
}

function webpHasAlpha(bytes) {
  return bytes.includes(Buffer.from("ALPH", "latin1"));
}

const OPAQUE_INPUTS = [
  ["png", "red-zeppelin-320x240.png"],
  ["jpeg", "red-zeppelin-320x240-progressive.jpg"],
  ["webp", "red-zeppelin-320x240.webp"],
  ["avif", "red-zeppelin-320x240.avif"],
];

for (const [format, file] of OPAQUE_INPUTS) {
  test(`image compressor decodes ${format} to KTX2 and encodes every codec`, async () => {
    const decoded = await decode(format, file);
    assert.equal(decoded.width, 320);
    assert.equal(decoded.height, 240);
    assert.equal(decoded.pixels, 320 * 240);
    assert.equal(decoded.hasAlpha, false);
    assert.match(decoded.decoderPath, new RegExp(`/${format}-to-ktx2-r8g8b8a8-srgb\\.wasm$`));
    const ktx2 = Buffer.from(decoded.output);
    assert.equal(ktx2.length, 224 + 320 * 240 * 4);
    assert.equal(ktx2.readUInt32LE(12), 43);

    const webp = await encode("webp", decoded);
    assertWebP(webp);
    assert.equal(webpHasAlpha(webp), false);

    const avif = await encode("avif", decoded);
    assert.equal(avif.toString("latin1", 4, 12), "ftypavif");

    const jpeg = await encode("jpeg", decoded);
    assert.equal(jpeg.readUInt16BE(0), 0xffd8);
    assert.equal(jpeg.readUInt16BE(jpeg.length - 2), 0xffd9);
  });
}

for (const [format, file] of [
  ["png", "transparent-radial-160x120.png"],
  ["webp", "transparent-radial-160x120.webp"],
]) {
  test(`image compressor keeps ${format} transparency in WebP`, async () => {
    const decoded = await decode(format, file);
    assert.equal(decoded.width, 160);
    assert.equal(decoded.height, 120);
    assert.equal(decoded.hasAlpha, true);
    const webp = await encode("webp", decoded);
    assertWebP(webp);
    assert.equal(webpHasAlpha(webp), true);
  });
}

test("image compressor decode worker rejects mismatched input", async () => {
  const input = await readFile(`${FIXTURES}/red-zeppelin-320x240.png`);
  const [message] = await runWorker("image-compress-decode-worker.js", [
    { type: "decode", format: "webp", input: input.buffer.slice(0) },
  ]);
  assert.equal(message.type, "error");
});

test("image compressor page accepts WebP and AVIF", async () => {
  const page = await readFile("site/image-compress.md", "utf8");
  assert.match(page, /accept="[^"]*image\/webp[^"]*image\/avif/);
  assert.doesNotMatch(page, /-to-bmp-|\/image\/bmp\//);
});
