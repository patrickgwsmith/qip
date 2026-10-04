import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const FIXTURES = "fixtures/image-compress";
const handlers = new Map();

// Node caches the worker modules, so each is imported once. Its handler reads
// the current self on every call.
async function runWorker(path, message) {
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
  await handlers.get(path)({ data: message });
  assert.equal(posted.length, 1);
  return posted[0];
}

function toArrayBuffer(bytes) {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

async function decode(format, bytes) {
  const message = await runWorker("image-compress-decode-worker.js", {
    type: "decode",
    format,
    input: toArrayBuffer(bytes),
  });
  assert.equal(message.type, "done", message.message);
  return message;
}

const LOSSY_OPTIONS = {
  quality: 80,
  method: 4,
  sharpYuv: true,
  lowMemory: true,
  backgroundColor: 0xffffff,
};

async function encode(inputFormat, mode, input) {
  const message = await runWorker("webp-worker.js", {
    input,
    inputFormat,
    mode,
    options: mode === "lossless" ? { level: 6 } : LOSSY_OPTIONS,
  });
  assert.equal(message.type, "done", message.message);
  const bytes = Buffer.from(message.output);
  assert.equal(bytes.toString("latin1", 0, 4), "RIFF");
  assert.equal(bytes.toString("latin1", 8, 12), "WEBP");
  return bytes;
}

function pixels(decoded) {
  return Buffer.from(decoded.output).subarray(224);
}

// 32-bit top-down BGRX or V5 BGRA BMP built from RGBA8 KTX2 pixels.
function bmpFromRGBA(decoded, v5Alpha) {
  const rgba = pixels(decoded);
  const dibSize = v5Alpha ? 124 : 40;
  const offset = 14 + dibSize;
  const bmp = Buffer.alloc(offset + rgba.length);
  bmp.write("BM", 0, "latin1");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(offset, 10);
  bmp.writeUInt32LE(dibSize, 14);
  bmp.writeInt32LE(decoded.width, 18);
  bmp.writeInt32LE(-decoded.height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  bmp.writeUInt32LE(v5Alpha ? 3 : 0, 30);
  bmp.writeUInt32LE(rgba.length, 34);
  if (v5Alpha) {
    bmp.writeUInt32LE(0x00ff0000, 54);
    bmp.writeUInt32LE(0x0000ff00, 58);
    bmp.writeUInt32LE(0x000000ff, 62);
    bmp.writeUInt32LE(0xff000000, 66);
    bmp.write("BGRs", 70, "latin1");
  }
  for (let i = 0; i < rgba.length; i += 4) {
    bmp[offset + i] = rgba[i + 2];
    bmp[offset + i + 1] = rgba[i + 1];
    bmp[offset + i + 2] = rgba[i];
    bmp[offset + i + 3] = v5Alpha ? rgba[i + 3] : 0;
  }
  return bmp;
}

const INPUTS = [
  ["jpeg", "red-zeppelin-320x240-progressive.jpg", 320, 240, false],
  ["png", "red-zeppelin-320x240.png", 320, 240, false],
  ["avif", "red-zeppelin-320x240.avif", 320, 240, false],
  ["webp", "red-zeppelin-320x240.webp", 320, 240, false],
  ["png", "transparent-radial-160x120.png", 160, 120, true],
  ["webp", "transparent-radial-160x120.webp", 160, 120, true],
];

for (const [format, file, width, height, transparent] of INPUTS) {
  test(`WebP converter encodes ${file} in every mode via KTX2`, async () => {
    const decoded = await decode(format, await readFile(`${FIXTURES}/${file}`));
    assert.equal(decoded.width, width);
    assert.equal(decoded.height, height);
    assert.equal(decoded.hasAlpha, transparent);

    for (const mode of ["opaque", "lossy", "lossless"]) {
      const webp = await encode("ktx2", mode, decoded.output.slice(0));
      const roundTrip = await decode("webp", webp);
      assert.equal(roundTrip.width, width, mode);
      assert.equal(roundTrip.height, height, mode);
      assert.equal(roundTrip.hasAlpha, transparent && mode !== "opaque", mode);
      if (mode === "lossless") {
        assert.ok(pixels(roundTrip).equals(pixels(decoded)), "lossless pixels differ");
      }
    }
  });
}

test("WebP converter keeps BMP input on the BMP encoders", async () => {
  const photo = await decode("png", await readFile(`${FIXTURES}/red-zeppelin-320x240.png`));
  const bgrx = bmpFromRGBA(photo, false);
  const opaque = await decode("webp", await encode("bmp", "opaque", toArrayBuffer(bgrx)));
  assert.equal(opaque.width, 320);
  assert.equal(opaque.hasAlpha, false);

  const radial = await decode("png", await readFile(`${FIXTURES}/transparent-radial-160x120.png`));
  const bgra = bmpFromRGBA(radial, true);
  const lossless = await decode("webp", await encode("bmp", "lossless", toArrayBuffer(bgra)));
  assert.equal(lossless.hasAlpha, true);
  assert.ok(pixels(lossless).equals(pixels(radial)), "lossless BMP pixels differ");
});

test("WebP converter rejects an unknown input format", async () => {
  const message = await runWorker("webp-worker.js", {
    input: new ArrayBuffer(16),
    inputFormat: "gif",
    mode: "opaque",
    options: LOSSY_OPTIONS,
  });
  assert.equal(message.type, "error");
});
