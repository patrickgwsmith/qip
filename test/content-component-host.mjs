import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  ContentComponentHost,
  ContentRenderTrap,
} from "./lib/content-component-host.mjs";

const decoder = new TextDecoder("utf-8", { fatal: true });

test("input rejection keeps the instance reusable", async () => {
  const host = new ContentComponentHost(
    await readFile("components/text/utf8-must-be-valid.wasm"),
    { label: "UTF-8 validator" },
  );

  const empty = host.run(new Uint8Array());
  assert.equal(empty.status, "accepted");
  assert.equal(empty.output.byteLength, 0);
  const firstInstance = host.instance;

  const rejected = host.run(new Uint8Array([0x41, 0xc3, 0x28]));
  assert.equal(rejected.status, "rejected");
  assert.equal(rejected.detail, 2);
  assert.equal(rejected.inputOffset, 2);
  assert.equal(rejected.failureMode, 0);
  assert.equal(host.instance, firstInstance);

  const accepted = host.run("again");
  assert.equal(accepted.status, "accepted");
  assert.equal(decoder.decode(accepted.output), "again");
  assert.equal(host.instance, firstInstance);
  assert.equal(host.instanceCount, 1);
});

test("a render trap discards the instance instead of attempting recovery", async () => {
  const host = new ContentComponentHost(
    await readFile("components/text/css/css-expression-to-value.wasm"),
    { label: "CSS expression evaluator" },
  );

  assert.throws(() => host.run("1 / 0"), ContentRenderTrap);
  assert.equal(host.instance, null);
  assert.equal(host.instanceCount, 1);

  const accepted = host.run("2px + 3px");
  assert.equal(accepted.status, "accepted");
  assert.equal(decoder.decode(accepted.output), "5px");
  assert.equal(host.instanceCount, 2);
});

test("Base64 rejects malformed and non-canonical input and recovers", async () => {
  const host = new ContentComponentHost(
    await readFile("components/text/base64-decode.wasm"),
    { label: "Base64 decoder" },
  );
  const instance = host.instantiate();

  for (const [encoded, expected] of [
    ["", ""],
    ["TQ==", "M"],
    ["TWE=", "Ma"],
    ["TWFu", "Man"],
  ]) {
    const accepted = host.run(encoded);
    assert.equal(accepted.status, "accepted");
    assert.equal(decoder.decode(accepted.output), expected);
  }

  for (const [encoded, offset] of [
    ["A", 1],
    ["!!!!", 0],
    ["A===", 1],
    ["TQ=A", 2],
    ["TQ==AAAA", 2],
    ["TR==", 1],
    ["TWF=", 2],
    ["TWFu====", 4],
  ]) {
    const rejected = host.run(encoded);
    assert.equal(rejected.status, "rejected", encoded);
    assert.equal(rejected.detail, offset, encoded);
    assert.equal(rejected.inputOffset, offset, encoded);
    assert.equal(rejected.failureMode, 0, encoded);
    assert.equal(host.instance, instance);
  }

  assert.equal(decoder.decode(host.run("YWdhaW4=").output), "again");
  assert.equal(host.instance, instance);
});

test("zlib distinguishes accepted empty output from rejection", async () => {
  const host = new ContentComponentHost(
    await readFile("components/bytes/zlib-decompress.wasm"),
    { label: "zlib decompressor" },
  );
  const instance = host.instantiate();

  const empty = host.run(new Uint8Array([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]));
  assert.equal(empty.status, "accepted");
  assert.equal(empty.output.byteLength, 0);

  const rejected = host.run(new Uint8Array([0x78, 0x00]));
  assert.equal(rejected.status, "rejected");
  assert.equal(rejected.inputOffset, undefined);
  assert.equal(host.instance, instance);

  const recovered = host.run(new Uint8Array([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]));
  assert.equal(recovered.status, "accepted");
  assert.equal(host.instance, instance);
});

test("Core Wasm validation rejects and recovers without copying accepted input", async () => {
  const wasmBytes = await readFile("components/application/wasm/wasm-validate-core-1.0.wasm");
  const host = new ContentComponentHost(wasmBytes, { label: "Core Wasm validator" });

  const rejected = host.run(new Uint8Array([0x00, 0x61, 0x73, 0x6d]));
  assert.equal(rejected.status, "rejected");
  assert.equal(rejected.inputOffset, undefined);

  const accepted = host.run(wasmBytes);
  assert.equal(accepted.status, "accepted");
  assert.deepEqual(Buffer.from(accepted.output), wasmBytes);
});

test("Core 2.0 validation accepts Core 2.0 and rejects later proposals", async () => {
  const validatorBytes = await readFile(
    "components/application/wasm/wasm-validate-core-2.0.wasm",
  );
  const host = new ContentComponentHost(validatorBytes, {
    label: "Core 2.0 Wasm validator",
  });

  // () -> (i32, i64) uses Core 2.0 multi-value results.
  const multiValue = Buffer.from(
    "0061736d010000000106016000027f7e030201000a08010600410042000b",
    "hex",
  );
  const accepted = host.run(multiValue);
  assert.equal(accepted.status, "accepted");
  assert.deepEqual(Buffer.from(accepted.output), multiValue);

  // return_call is a tail-call proposal instruction, not Core 2.0.
  const tailCall = Buffer.from(
    "0061736d0100000001040160000003030200000a0902040012010b02000b",
    "hex",
  );
  const rejected = host.run(tailCall);
  assert.equal(rejected.status, "rejected");
  assert.equal(rejected.inputOffset, 24);

  assert.equal(host.run(multiValue).status, "accepted");
});
