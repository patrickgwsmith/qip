import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const runnerPath = "components/application/wasm/qip-content-interpreter.wasm";
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function multipart(parts, selectedBoundary = boundary) {
  const chunks = [];
  for (const [name, body] of parts) {
    chunks.push(
      Buffer.from(
        `--${selectedBoundary}\r\n` +
        `Content-Disposition: form-data; name="${name}"; filename="${name}"\r\n` +
        "Content-Type: application/octet-stream\r\n\r\n",
      ),
      Buffer.from(body),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${selectedBoundary}--\r\n`));
  return Buffer.concat(chunks);
}

function bmp32(width, height, pixels) {
  const bytes = Buffer.alloc(54 + pixels.length);
  bytes.write("BM", 0, "ascii");
  bytes.writeUInt32LE(bytes.length, 2);
  bytes.writeUInt32LE(54, 10);
  bytes.writeUInt32LE(40, 14);
  bytes.writeInt32LE(width, 18);
  bytes.writeInt32LE(height, 22);
  bytes.writeUInt16LE(1, 26);
  bytes.writeUInt16LE(32, 28);
  bytes.writeUInt32LE(pixels.length, 34);
  Buffer.from(pixels).copy(bytes, 54);
  return bytes;
}

async function expectedOutput(component, input) {
  const host = new ContentComponentHost(component, { label: "native target" });
  const result = host.run(input);
  assert.equal(result.status, "accepted");
  return result.output;
}

test("interprets scalar, indirect-call, and SIMD Content components exactly", async () => {
  const [runner, rgb, commonmark, bmpDoubleSIMD] = await Promise.all([
    readFile(runnerPath),
    readFile("components/text/rgb-to-hex.wasm"),
    readFile("components/text/markdown/commonmark.0.31.2.wasm"),
    readFile("components/image/bmp/bmp-double-simd.wasm"),
  ]);
  const targets = [
    { component: rgb, input: encoder.encode("rgb(101, 79, 240)") },
    { component: commonmark, input: encoder.encode("# Hello from the interpreter\n") },
    {
      component: bmpDoubleSIMD,
      input: bmp32(2, 1, [0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff]),
    },
  ];
  const interpreter = new ContentComponentHost(runner, { label: "QIP Content interpreter" });

  for (const target of targets) {
    const expected = await expectedOutput(target.component, target.input);
    const actual = interpreter.run(multipart([
      ["component", target.component],
      ["input", target.input],
    ]));
    assert.equal(actual.status, "accepted");
    assert.deepEqual(actual.output, expected);
  }
});

test("uses a host-rewritten multipart boundary", async () => {
  const [runner, target] = await Promise.all([
    readFile(runnerPath),
    readFile("components/text/rgb-to-hex.wasm"),
  ]);
  const host = new ContentComponentHost(runner, { label: "QIP Content interpreter" });
  const instance = host.instantiate();
  const uuid = "12345678-90ab-cdef-1234-567890abcdef";
  const typePointer = instance.exports.input_content_type_ptr();
  const prefixLength = "multipart/form-data;boundary=uuid-".length;
  new Uint8Array(instance.exports.memory.buffer, typePointer + prefixLength, uuid.length).set(encoder.encode(uuid));

  const input = encoder.encode("rgb(101, 79, 240)");
  const result = host.run(multipart([
    ["component", target],
    ["input", input],
  ], `uuid-${uuid}`));
  assert.equal(result.status, "accepted");
  assert.equal(decoder.decode(result.output), "#654ff0");
});

test("applies prefixed multipart uniforms using the target setter types", async () => {
  const [runner, target] = await Promise.all([
    readFile(runnerPath),
    readFile("test/fixtures/qip-content-interpreter-uniforms.wasm"),
  ]);
  const native = new ContentComponentHost(target, { label: "native uniform target" }).run(new Uint8Array(), {
    uniforms: { unsigned: 0xffffffff, signed: -42n, ratio: 1.5, scale: -2.25 },
  });
  assert.equal(native.status, "accepted");

  const interpreted = new ContentComponentHost(runner, { label: "QIP Content interpreter" }).run(multipart([
    ["component", target],
    ["uniforms[scale]", Buffer.from("-2.25")],
    ["uniforms[unsigned]", Buffer.from("0xffffffff")],
    ["uniforms[ratio]", Buffer.from("1.5")],
    ["uniforms[signed]", Buffer.from("-42")],
  ]));
  assert.equal(interpreted.status, "accepted");
  assert.deepEqual(interpreted.output, native.output);
});

test("rejects unknown, malformed, duplicate, and invalid uniforms", async () => {
  const [runner, target] = await Promise.all([
    readFile(runnerPath),
    readFile("test/fixtures/qip-content-interpreter-uniforms.wasm"),
  ]);
  const host = new ContentComponentHost(runner, { label: "QIP Content interpreter" });
  for (const parts of [
    [["component", target], ["unsigned", Buffer.from("1")]],
    [["component", target], ["uniforms[bad-key]", Buffer.from("1")]],
    [["component", target], ["uniforms[missing]", Buffer.from("1")]],
    [["component", target], ["uniforms[unsigned]", Buffer.from("-1")]],
    [["component", target], ["uniforms[unsigned]", Buffer.from("1")], ["uniforms[unsigned]", Buffer.from("2")]],
  ]) {
    assert.equal(host.run(multipart(parts)).status, "rejected");
  }
});

test("rejects exhausted instruction budgets and resets the uniform", async () => {
  const [runner, infiniteLoop, rgb] = await Promise.all([
    readFile(runnerPath),
    readFile("components/text/infinite-loop.wasm"),
    readFile("components/text/rgb-to-hex.wasm"),
  ]);
  const host = new ContentComponentHost(runner, { label: "QIP Content interpreter" });
  const exhausted = host.run(multipart([["component", infiniteLoop]]), {
    uniforms: { instruction_budget: 100 },
  });
  assert.equal(exhausted.status, "rejected");

  const recovered = host.run(multipart([
    ["component", rgb],
    ["input", encoder.encode("rgb(101, 79, 240)")],
  ]));
  assert.equal(recovered.status, "accepted");
  assert.equal(decoder.decode(recovered.output), "#654ff0");
});

test("declares its dynamic target output as generic bytes", async () => {
  const runner = await readFile(runnerPath);
  const { instance } = await WebAssembly.instantiate(runner);
  const pointer = instance.exports.output_content_type_ptr();
  const size = instance.exports.output_content_type_size();
  assert.equal(
    decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer, size)),
    "application/octet-stream",
  );
});
