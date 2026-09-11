import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  __cliInternals,
  buildMultipartFormInput,
  canonicalFormContentType,
} from "../npm/qipx/qipx.mjs";

const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const identity = "bytes/identity.wasm";

function run(command, args, input) {
  return spawnSync(command, args, { input, maxBuffer: 4 * 1024 * 1024 });
}

test("Go qip and Node qipx construct byte-identical multipart input", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "qip-form-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const filePath = join(directory, "component.wasm");
  const fileBody = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0xff]);
  await writeFile(filePath, fileBody);

  const fields = ["mode=step", `component=@${filePath}`];
  const expected = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="mode"\r\n\r\n` +
      `step\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="component"; filename="component.wasm"\r\n` +
      `Content-Type: application/octet-stream\r\n\r\n`,
    ),
    fileBody,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);

  const built = await buildMultipartFormInput(fields);
  assert.equal(built.contentType, canonicalFormContentType);
  assert.deepEqual(Buffer.from(built.bytes), expected);

  const formArgs = ["-F", fields[0], "--form", fields[1]];
  const go = run("./qip", ["run", identity, ...formArgs]);
  assert.equal(go.status, 0, go.stderr.toString());
  const node = run(process.execPath, ["npm/qipx/cli.mjs", "run", identity, ...formArgs]);
  assert.equal(node.status, 0, node.stderr.toString());
  assert.deepEqual(go.stdout, expected);
  assert.deepEqual(node.stdout, expected);
});

test("@- has the same stdin and filename behavior in both CLIs", () => {
  const stdin = Buffer.from([0x00, 0xff, 0x0a]);
  const args = ["run", "-F", "component=@-", identity];
  const go = run("./qip", args, stdin);
  assert.equal(go.status, 0, go.stderr.toString());
  const node = run(process.execPath, ["npm/qipx/cli.mjs", ...args], stdin);
  assert.equal(node.status, 0, node.stderr.toString());
  assert.deepEqual(node.stdout, go.stdout);
  assert.match(go.stdout.toString("latin1"), /name="component"; filename="-"/);
});

test("multipart execution consumes its precomputed source plan", async () => {
  let observedPlan;
  await buildMultipartFormInput(["component=@text/example.wasm"], {
    hosts: [{ origin: "https://components.example" }],
    loadFile: (_path, plan) => {
      observedPlan = plan;
      return Buffer.from([0x00, 0x61, 0x73, 0x6d]);
    },
  });
  assert.deepEqual(observedPlan, __cliInternals.planMultipartFormInput(
    ["component=@text/example.wasm"],
    [{ origin: "https://components.example" }],
  ).fields[0].sourcePlan);
});

test("both CLIs reject raw input with -F and still require a component", () => {
  for (const [command, prefix] of [
    ["./qip", ["run"]],
    [process.execPath, ["npm/qipx/cli.mjs", "run"]],
  ]) {
    const mixed = run(command, [...prefix, "-i", "README.md", "-F", "component=@README.md", identity]);
    assert.notEqual(mixed.status, 0);
    assert.match(mixed.stderr.toString(), /-F and -i are mutually exclusive/);

    const missingComponent = run(command, [...prefix, "-F", "mode=step"]);
    assert.notEqual(missingComponent.status, 0);
    assert.equal(missingComponent.stdout.length, 0);
  }
});

test("qipx bench accepts the same multipart input as Go qip bench", () => {
  const fields = ["mode=step", "component=@text/hello.wasm"];
  const multipartComponent = "multipart/form-data/form-data-to-tar.wasm";
  const go = run("./qip", [
    "bench",
    "-F", fields[0],
    "--form", fields[1],
    "-r", "1",
    multipartComponent,
  ]);
  assert.equal(go.status, 0, go.stderr.toString());

  const node = run(process.execPath, [
    "npm/qipx/cli.mjs",
    "bench",
    "-F", fields[0],
    "--form", fields[1],
    "--runs", "1",
    "--warmup", "0",
    multipartComponent,
  ]);
  assert.equal(node.status, 0, node.stderr.toString());
  assert.match(node.stdout.toString(), /Input: multipart form \(2 fields\)/);

  const goHash = /sha256:\s+([0-9a-f]{64})/.exec(go.stdout.toString())?.[1];
  assert.ok(goHash, "Go benchmark did not report an output SHA-256");
  assert.match(node.stdout.toString(), new RegExp(`Output SHA-256: ${goHash}`));
});

test("qipx bench rejects raw and multipart input together", () => {
  const result = run(process.execPath, [
    "npm/qipx/cli.mjs",
    "bench",
    "-i", "README.md",
    "-F", "component=@text/hello.wasm",
    "--runs", "1",
    "multipart/form-data/form-data-to-tar.wasm",
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr.toString(), /-F and -i are mutually exclusive/);
});
