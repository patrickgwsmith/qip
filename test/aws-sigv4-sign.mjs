import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await WebAssembly.compile(
  await readFile("multipart/form-data/aws-sigv4-sign.wasm"),
);
const TYPE_PREFIX = "multipart/form-data;boundary=uuid-";
const UUID = "12345678-90ab-cdef-1234-567890abcdef";
const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

// From the AWS S3 SigV4 documentation's GET bucket lifecycle example.
const s3Example = {
  method: "GET",
  url: "https://examplebucket.s3.amazonaws.com/?lifecycle",
  region: "us-east-1",
  service: "s3",
  access_key_id: "AKIAIOSFODNN7EXAMPLE",
  secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
};

async function sign(fields, timestamp = 1369353600n) {
  const { exports } = await WebAssembly.instantiate(wasm, {});
  new Uint8Array(
    exports.memory.buffer,
    exports.input_content_type_ptr() + TYPE_PREFIX.length,
    36,
  ).set(Buffer.from(UUID));
  if (timestamp !== null) exports.uniform_set_timestamp(timestamp);

  const boundary = "uuid-" + UUID;
  let body = "";
  for (const [name, value] of Object.entries(fields)) {
    body += `--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`;
  }
  body += `--${boundary}--\r\n`;
  const bytes = Buffer.from(body);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), bytes.length).set(bytes);
  const outputSize = qipRenderSize(exports, bytes.length);
  return Buffer.from(
    new Uint8Array(exports.memory.buffer, qipRenderedOutputPointer(exports), outputSize),
  ).toString();
}

test("aws-sigv4-sign matches the AWS S3 lifecycle example", async () => {
  assert.equal(
    await sign(s3Example),
    "X-Amz-Date: 20130524T000000Z\n" +
      `X-Amz-Content-Sha256: ${EMPTY_SHA256}\n` +
      "Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
      "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " +
      "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543\n",
  );
});

test("aws-sigv4-sign signs a lowercase host without its default port", async () => {
  assert.equal(
    await sign({ ...s3Example, url: "https://ExampleBucket.s3.amazonaws.com:443/?lifecycle" }),
    await sign(s3Example),
  );
  assert.notEqual(
    await sign({ ...s3Example, url: "https://examplebucket.s3.amazonaws.com:8443/?lifecycle" }),
    await sign(s3Example),
  );
});

// From the AWS SigV4 test suite: get-slashes and
// get-vanilla-query-order-key-case.
test("aws-sigv4-sign matches the AWS test suite for other services", async () => {
  const suiteExample = {
    method: "GET",
    region: "us-east-1",
    service: "service",
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  };
  const header = (signature) =>
    "X-Amz-Date: 20150830T123600Z\n" +
    "Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
    `SignedHeaders=host;x-amz-date, Signature=${signature}\n`;
  assert.equal(
    await sign({ ...suiteExample, url: "https://example.amazonaws.com//example//" }, 1440938160n),
    header("9a624bd73a37c9a373b5312afbebe7a714a789de108f0bdfe846570885f57e84"),
  );
  assert.equal(
    await sign({ ...suiteExample, url: "https://example.amazonaws.com/?Param2=value2&Param1=value1" }, 1440938160n),
    header("b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"),
  );
});

test("aws-sigv4-sign rejects a malformed escape or port", async () => {
  await assert.rejects(sign({ ...s3Example, url: "https://examplebucket.s3.amazonaws.com/a%2" }), /rejected input/);
  await assert.rejects(sign({ ...s3Example, url: "https://examplebucket.s3.amazonaws.com:x/" }), /rejected input/);
});

test("aws-sigv4-sign hashes the body and signs the session token", async () => {
  const output = await sign({
    ...s3Example,
    method: "PUT",
    url: "https://examplebucket.s3.amazonaws.com/test.txt",
    session_token: "TOKEN",
    body: "Welcome to Amazon S3.",
  });
  const bodyHash = createHash("sha256").update("Welcome to Amazon S3.").digest("hex");
  assert.match(output, new RegExp(`^X-Amz-Content-Sha256: ${bodyHash}$`, "m"));
  assert.match(output, /^X-Amz-Security-Token: TOKEN$/m);
  assert.match(output, /SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,/);
  assert.doesNotMatch(output, /wJalrXUtnFEMI/);
});

test("aws-sigv4-sign accepts UNSIGNED-PAYLOAD", async () => {
  const output = await sign({ ...s3Example, payload_sha256: "UNSIGNED-PAYLOAD" });
  assert.match(output, /^X-Amz-Content-Sha256: UNSIGNED-PAYLOAD$/m);
});

test("aws-sigv4-sign rejects a missing timestamp", async () => {
  await assert.rejects(sign(s3Example, null), /rejected input/);
});

test("aws-sigv4-sign rejects unknown fields", async () => {
  await assert.rejects(sign({ ...s3Example, secret: "x" }), /rejected input/);
});

test("aws-sigv4-sign rejects empty required fields", async () => {
  await assert.rejects(sign({ ...s3Example, access_key_id: "" }), /rejected input/);
});
