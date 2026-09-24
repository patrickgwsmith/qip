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
import { multipart as buildTUIForm } from "../npm/qiptui/qiptui.mjs";

const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const identity = "bytes/identity.wasm";

function run(command, args, input) {
  return spawnSync(command, args, { input, maxBuffer: 4 * 1024 * 1024 });
}

test("CLI help explains every multipart form variant with quoted examples", () => {
  const commands = [
    ["Go run", "./qip", ["help", "run"], true],
    ["Go dry run", "./qip", ["help", "dry"], false],
    ["Go bench", "./qip", ["help", "bench"], true],
    ["Go tui", "./qip", ["help", "tui"], false],
    ["Node qipx", process.execPath, ["npm/qipx/cli.mjs", "--help"], true],
    ["Node qipx bench", process.execPath, ["npm/qipx/cli.mjs", "bench", "--help"], true],
    ["Node qipx tui", process.execPath, ["npm/qipx/cli.mjs", "tui", "--help"], false],
    ["qiptui", process.execPath, ["npm/qiptui/qiptui.mjs", "--help"], false],
  ];
  for (const [label, command, args, stdinAllowed] of commands) {
    const result = run(command, args);
    assert.equal(result.status, 0, `${label}: ${result.stderr}`);
    const help = result.stdout.toString();
    for (const variant of ["name=value", "name=@path", "name=<path", "name=@-", "name=<-", "Examples:"]) {
      assert.ok(help.includes(variant), `${label} help omits ${variant}`);
    }
    assert.match(help, /Content-Type: application\/octet-stream/);
    assert.match(help, /omits that part header/);
    assert.match(help, /quote/i, `${label} help should explain shell quoting`);
    if (label === "Go dry run") assert.match(help, /does not read stdin/i);
    else if (!stdinAllowed) assert.match(help, /stdin carries|stdin.*unavailable/i, `${label} help should reserve stdin for keys`);
  }
});

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

test("<file sends a text field with identical bytes in Go, qipx, and qiptui", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "qip-form-text-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "input.txt");
  await writeFile(path, "hello\n");
  const fields = [`data=<${path}`];
  const expected = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="data"\r\n\r\n` +
    `hello\n\r\n--${boundary}--\r\n`,
  );
  const built = await buildMultipartFormInput(fields);
  assert.deepEqual(Buffer.from(built.bytes), expected);
  assert.deepEqual(await buildTUIForm(fields), expected);

  const go = run("./qip", ["run", "-F", fields[0], identity]);
  assert.equal(go.status, 0, go.stderr.toString());
  const node = run(process.execPath, ["npm/qipx/cli.mjs", "run", "-F", fields[0], identity]);
  assert.equal(node.status, 0, node.stderr.toString());
  assert.deepEqual(go.stdout, expected);
  assert.deepEqual(node.stdout, expected);
});

test("<- reads stdin as a text field in Go and qipx", () => {
  const input = Buffer.from("hello\n");
  const args = ["run", "-F", "data=<-", identity];
  const go = run("./qip", args, input);
  assert.equal(go.status, 0, go.stderr.toString());
  const node = run(process.execPath, ["npm/qipx/cli.mjs", ...args], input);
  assert.equal(node.status, 0, node.stderr.toString());
  assert.deepEqual(go.stdout, node.stdout);
  assert.doesNotMatch(go.stdout.toString(), /filename=/);
});

test("TUI commands reserve stdin and reject <-", () => {
  for (const [command, prefix] of [
    ["./qip", ["tui"]],
    [process.execPath, ["npm/qipx/cli.mjs", "tui"]],
  ]) {
    const result = run(command, [...prefix, "-F", "input=<-", "tui/qipdb.wasm"], "hello");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr.toString(), /cannot use -F name=@- or name=<- because stdin carries terminal events/);
  }
});

test("multipart execution consumes its precomputed source plan", async () => {
  for (const field of ["component=@text/example.wasm", "component=<text/example.wasm"]) {
    let observedPlan;
    await buildMultipartFormInput([field], {
      hosts: [{ origin: "https://components.example" }],
      loadFile: (_path, plan) => {
        observedPlan = plan;
        return Buffer.from([0x00, 0x61, 0x73, 0x6d]);
      },
    });
    assert.deepEqual(observedPlan, __cliInternals.planMultipartFormInput(
      [field],
      [{ origin: "https://components.example" }],
    ).fields[0].sourcePlan);
  }
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
