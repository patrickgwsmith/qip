import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import test from "node:test";

import { ContentComponentHost } from "./lib/content-component-host.mjs";

const checkerPath = "application/wasm/qipok.wasm";
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const decoder = new TextDecoder();
const checker = new ContentComponentHost(await readFile(checkerPath), { label: "qipok.wasm" });

async function form(component, suites) {
  const parts = [["component", component], ...suites.map((suite) => ["suite", suite])];
  const chunks = [];
  for (const [name, path] of parts) {
    chunks.push(
      Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="${name}"; filename="${basename(path)}"\r\n` +
        "Content-Type: application/octet-stream\r\n\r\n",
      ),
      await readFile(path),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

async function check(component, suites, uniforms = {}) {
  const result = checker.run(await form(component, suites), { uniforms });
  assert.equal(result.status, "accepted");
  return decoder.decode(result.output);
}

test("passes an implementation that satisfies its suite", async () => {
  const report = await check("text/luhn.wasm", ["compliance/luhn.comply.wasm"]);
  assert.equal(report, "PASS luhn.wasm\nPASS luhn.wasm --suite luhn.comply.wasm (1603 cases)\n\npass=2 fail=0 total=2\n");
});

test("runs repeated suites against fresh implementation state", async () => {
  const report = await check("text/utf8-must-be-valid.wasm", [
    "compliance/reject-invalid-utf8.wasm",
    "compliance/preserve-ascii.wasm",
    "compliance/preserve-empty.wasm",
    "compliance/preserve-whitespace.wasm",
  ]);
  assert.match(report, /^PASS utf8-must-be-valid\.wasm --suite reject-invalid-utf8\.wasm \(\d+ cases\)$/m);
  assert.match(report, /^PASS utf8-must-be-valid\.wasm --suite preserve-whitespace\.wasm \(\d+ cases\)$/m);
  assert.match(report, /\npass=5 fail=0 total=5\n$/);
});

test("answers must_render_into cases with the implementation output", async () => {
  const report = await check("text/markdown/commonmark.0.31.2.wasm", ["compliance/html5-entities.comply.wasm"]);
  assert.match(report, /^PASS commonmark\.0\.31\.2\.wasm --suite html5-entities\.comply\.wasm \(2143 cases\)$/m);
});

test("reports failing cases with input, expected, and actual previews", async () => {
  const report = await check("text/trim.wasm", ["compliance/luhn.comply.wasm"]);
  assert.match(report, /^FAIL trim\.wasm --suite luhn\.comply\.wasm: 1283\/1603 cases failed$/m);
  assert.match(report, /^ {2}case 1: output mismatch\n {4}input_utf8_preview=1-8\n {4}input_hex_preview=31 2d 38\n {4}expected_output_utf8_preview=18\n/m);
  assert.match(report, /^ {2}… and 1278 more failing case\(s\)/m);
  assert.match(report, /\npass=1 fail=1 total=2\n$/);
});

test("reports a missing rejection contract per case", async () => {
  const report = await check("text/trim.wasm", ["compliance/reject-invalid-utf8.wasm"]);
  assert.match(report, /^ {2}case 0: expected rejection, but implementation does not export failure_modes_per_input_offset$/m);
});

test("passes the seed uniform to seeded suites and reports it", async () => {
  const report = await check("text/currency-format-en-us.wasm", ["compliance/currency-format-en-us.comply.wasm"], { seed: 42 });
  assert.match(report, /^PASS currency-format-en-us\.wasm --suite currency-format-en-us\.comply\.wasm \(8736 cases\)$/m);
  assert.match(report, /\npass=2 fail=0 total=2 seed=42\n$/);
});

test("fails a suite without uniform_set_seed when a seed is set", async () => {
  const report = await check("text/luhn.wasm", ["compliance/luhn.comply.wasm"], { seed: 1 });
  assert.match(report, /^FAIL luhn\.wasm --suite luhn\.comply\.wasm: seed given but Compliance oracle does not export uniform_set_seed$/m);
});

test("fails an implementation whose memory is larger than the interpreter holds", async () => {
  const report = await check("image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm", ["compliance/bmp-b8g8r8a8-icc-to-srgb.comply.wasm"]);
  assert.equal(report, "FAIL bmp-b8g8r8a8-icc-to-srgb.wasm: declared memory is larger than the interpreter holds\n\npass=0 fail=1 total=1\n");
});

test("rejects a request without a component", () => {
  const body = Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="suite"\r\n\r\nx\r\n--${boundary}--\r\n`);
  assert.equal(checker.run(body).status, "rejected");
});
