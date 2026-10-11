import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";

const encoderUrl = new URL("../image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossless.wasm", import.meta.url);
const lossyEncoderUrl = new URL("../image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jxl-lossy.wasm", import.meta.url);
const decoderUrl = new URL("../image/jxl/jxl-to-ktx2-r8g8b8a8-srgb.wasm", import.meta.url);

async function load(t) {
  try {
    await access(encoderUrl, constants.R_OK);
    await access(lossyEncoderUrl, constants.R_OK);
    await access(decoderUrl, constants.R_OK);
  } catch {
    t.skip("build the JPEG XL components first");
    return null;
  }
  const [encoder, lossyEncoder, decoder] = await Promise.all([readFile(encoderUrl), readFile(lossyEncoderUrl), readFile(decoderUrl)]);
  return {
    encoder: (await WebAssembly.instantiate(encoder)).instance.exports,
    lossyEncoder: (await WebAssembly.instantiate(lossyEncoder)).instance.exports,
    decoder: (await WebAssembly.instantiate(decoder)).instance.exports,
  };
}

function render(exports, input) {
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const result = BigInt.asUintN(64, exports.render(input.length));
  const size = Number(result & 0xffff_ffffn);
  const pointer = Number(result >> 32n);
  return Buffer.from(new Uint8Array(exports.memory.buffer, pointer, size));
}

function contentType(exports, prefix) {
  const bytes = new Uint8Array(exports.memory.buffer, exports[`${prefix}_content_type_ptr`](),
    exports[`${prefix}_content_type_size`]());
  return new TextDecoder().decode(bytes);
}

const identifier = [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a];
const orientation = [0x12, 0, 0, 0, ...Buffer.from("KTXorientation"), 0, 0x72, 0x64, 0, 0, 0];

function dfd(order) {
  const [first, third] = order === "bgra" ? [2, 0] : [0, 2];
  return [
    0x5c, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x58, 0, 1, 1, 2, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 7, first, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
    8, 0, 7, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
    0x10, 0, 7, third, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
    0x18, 0, 7, 0x1f, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
  ];
}

// Builds a strict QIP KTX2 image. Every seventh diagonal is fully transparent
// but keeps nonzero RGB, which a lossless encoder must preserve.
function buildKtx2(width, height, { order = "rgba", opaque = false } = {}) {
  const pixelBytes = width * height * 4;
  const ktx = Buffer.alloc(224 + pixelBytes);
  Buffer.from(identifier).copy(ktx, 0);
  ktx.writeUInt32LE(order === "bgra" ? 50 : 43, 12);
  ktx.writeUInt32LE(1, 16);
  ktx.writeUInt32LE(width, 20);
  ktx.writeUInt32LE(height, 24);
  ktx.writeUInt32LE(1, 36);
  ktx.writeUInt32LE(1, 40);
  ktx.writeUInt32LE(104, 48);
  ktx.writeUInt32LE(92, 52);
  ktx.writeUInt32LE(196, 56);
  ktx.writeUInt32LE(24, 60);
  ktx.writeBigUInt64LE(224n, 80);
  ktx.writeBigUInt64LE(BigInt(pixelBytes), 88);
  ktx.writeBigUInt64LE(BigInt(pixelBytes), 96);
  Buffer.from(dfd(order)).copy(ktx, 104);
  Buffer.from(orientation).copy(ktx, 196);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = 224 + (y * width + x) * 4;
      const red = (x * 13 + y * 3) & 255;
      const blue = (x * 19 + y * 7) & 255;
      ktx[offset] = order === "bgra" ? blue : red;
      ktx[offset + 1] = (x * 5 + y * 17) & 255;
      ktx[offset + 2] = order === "bgra" ? red : blue;
      ktx[offset + 3] = opaque ? 255 : (x + y) % 7 === 0 ? 0 : (x * 23 + y * 29) & 255;
    }
  }
  return ktx;
}

test("JPEG XL components declare their content types", async (t) => {
  const components = await load(t);
  if (!components) return;
  const { encoder, decoder } = components;
  assert.equal(contentType(encoder, "input"), "image/ktx2");
  assert.equal(contentType(encoder, "output"), "image/jxl");
  assert.equal(contentType(decoder, "input"), "image/jxl");
  assert.equal(contentType(decoder, "output"), "image/ktx2");
});

test("fjxl and jxl-rs round-trip RGBA and BGRA KTX2 exactly", async (t) => {
  const components = await load(t);
  if (!components) return;
  const { encoder, decoder } = components;
  // 300 x 270 spans two 256-pixel groups on each axis.
  const rgba = buildKtx2(300, 270);
  const jxl = render(encoder, Buffer.from(rgba));
  assert.equal(encoder.encoded_channel_count(), 4);
  assert.deepEqual([...jxl.subarray(0, 2)], [0xff, 0x0a], "bare JPEG XL codestream signature");
  assert.equal(encoder.arena_live_bytes(), 0);

  const bgraJxl = render(encoder, buildKtx2(300, 270, { order: "bgra" }));
  assert.deepEqual(bgraJxl, jxl, "BGRA input encodes the same pixels");

  const decoded = render(decoder, jxl);
  assert.deepEqual(decoded, rgba);
  assert.equal(decoder.arena_failed_allocation(), 0);
});

test("opaque KTX2 encodes without an alpha channel and decodes with alpha 255", async (t) => {
  const components = await load(t);
  if (!components) return;
  const { encoder, decoder } = components;
  const opaque = buildKtx2(64, 48, { opaque: true });
  const jxl = render(encoder, Buffer.from(opaque));
  assert.equal(encoder.encoded_channel_count(), 3);
  assert.deepEqual(render(decoder, jxl), opaque);
  const withAlpha = render(encoder, buildKtx2(64, 48));
  assert.ok(jxl.length < withAlpha.length);
});

test("fjxl effort is clamped and every effort stays lossless", async (t) => {
  const components = await load(t);
  if (!components) return;
  const { encoder, decoder } = components;
  const source = buildKtx2(97, 61);
  assert.equal(encoder.uniform_set_effort(500), 127);
  for (const effort of [0, 1, 2, 127]) {
    assert.equal(encoder.uniform_set_effort(effort), effort);
    const jxl = render(encoder, Buffer.from(source));
    assert.deepEqual(render(decoder, jxl), source, `effort ${effort}`);
  }
  encoder.uniform_set_effort(2);
});

test("JPEG XL components reject malformed input", async (t) => {
  const components = await load(t);
  if (!components) return;
  const { encoder, decoder } = components;
  const ktx = buildKtx2(16, 16);
  assert.equal(render(encoder, ktx.subarray(0, ktx.length - 1)).length, 0, "short KTX2 payload");
  const float = Buffer.from(ktx);
  float.writeUInt32LE(109, 12);
  assert.equal(render(encoder, float).length, 0, "unsupported vkFormat");

  const jxl = render(encoder, buildKtx2(300, 270));
  assert.equal(render(decoder, jxl.subarray(0, jxl.length >> 1)).length, 0, "truncated codestream");
  assert.equal(render(decoder, Buffer.from("not a JPEG XL file")).length, 0, "bad signature");
  // A rejected input must not prevent the next decode.
  assert.deepEqual(render(decoder, jxl), buildKtx2(300, 270));
});

test("libjxl lossy encoder writes sRGB JPEG XL that jxl-rs can decode", async (t) => {
  const components = await load(t);
  if (!components) return;
  const { lossyEncoder, decoder } = components;
  assert.equal(contentType(lossyEncoder, "input"), "image/ktx2");
  assert.equal(contentType(lossyEncoder, "output"), "image/jxl");
  assert.equal(lossyEncoder.uniform_set_effort(100), 9);
  assert.equal(lossyEncoder.uniform_set_effort(5), 5);
  assert.equal(lossyEncoder.uniform_set_distance(1), 1);
  for (const order of ["rgba", "bgra"]) {
    const input = buildKtx2(97, 61, { order });
    const output = render(lossyEncoder, Buffer.from(input));
    assert.ok(output.length > 0, `${order} encoded: stage ${lossyEncoder.last_failure_stage()}, error ${lossyEncoder.last_encoder_error()}, arena failed ${lossyEncoder.arena_failed_allocation()}, live ${lossyEncoder.arena_live_bytes()}`);
    assert.deepEqual([...output.subarray(0, 2)], [0xff, 0x0a]);
    assert.equal(lossyEncoder.arena_failed_allocation(), 0);
    assert.equal(lossyEncoder.arena_free_unmatched_count(), 0);
    assert.ok(lossyEncoder.arena_live_bytes() < 8 * 1024 * 1024);
    const decoded = render(decoder, output);
    assert.equal(decoded.length, input.length);
    let squaredError = 0;
    for (let i = 224; i < input.length; i += 4) {
      const red = order === "bgra" ? input[i + 2] : input[i];
      const blue = order === "bgra" ? input[i] : input[i + 2];
      squaredError += (decoded[i] - red) ** 2;
      squaredError += (decoded[i + 1] - input[i + 1]) ** 2;
      squaredError += (decoded[i + 2] - blue) ** 2;
      assert.equal(decoded[i + 3], input[i + 3], "alpha stays exact");
    }
    assert.ok(squaredError / (97 * 61 * 3) < 400);
  }
  const opaque = buildKtx2(64, 48, { opaque: true });
  const first = render(lossyEncoder, Buffer.from(opaque));
  assert.equal(lossyEncoder.encoded_channel_count(), 3);
  assert.ok(first.length > 0);
  for (let i = 0; i < 12; i += 1) {
    assert.deepEqual(render(lossyEncoder, Buffer.from(opaque)), first);
  }
  assert.ok(lossyEncoder.arena_live_bytes() < 8 * 1024 * 1024);
  assert.equal(render(lossyEncoder, opaque.subarray(0, 100)).length, 0);
  assert.deepEqual(render(lossyEncoder, Buffer.from(opaque)), first);
});
