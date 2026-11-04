import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import { parseArgs } from "../npm/qipok/qipok.mjs";

// Shared comply behavior is covered against qipx in test/qipx-parity.mjs. These tests cover
// what is specific to qipok: help, --version, and where hosts may appear.

function qipok(args, { cwd } = {}) {
  const result = spawnSync(process.execPath, [resolve("npm/qipok/qipok.mjs"), ...args], { cwd, maxBuffer: 16 * 1024 * 1024 });
  return { status: result.status, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
}

test("qipok prints help with no arguments and with -h", () => {
  for (const args of [[], ["-h"], ["--help"], ["text/hello.wasm", "--help"]]) {
    const result = qipok(args);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^Usage: qipok \[host \.\.\.\] \[options\] <file-or-dir>/);
    assert.match(result.stdout, /--suite <suite\.wasm>/);
    assert.match(result.stdout, /--seed <n>/);
    assert.match(result.stdout, /--max-memory <bytes>/);
    assert.doesNotMatch(result.stdout, /qipx|--with/);
  }
});

test("qipok --version prints the package version", async () => {
  const { version } = JSON.parse(await readFile("npm/qipok/package.json", "utf8"));
  const result = qipok(["--version"]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), version);
});

test("qipok checks components without a subcommand", () => {
  const result = qipok(["text/hello.wasm", "--suite", "compliance/preserve-empty.wasm"]);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /^PASS text\/hello\.wasm\nFAIL text\/hello\.wasm --suite compliance\/preserve-empty\.wasm: /);
  const identity = qipok(["bytes/identity.wasm", "--suite", "compliance/preserve-empty.wasm"]);
  assert.equal(identity.status, 0, identity.stderr);
  assert.equal(identity.stdout, "PASS bytes/identity.wasm\nPASS bytes/identity.wasm --suite compliance/preserve-empty.wasm (1 cases)\n\npass=2 fail=0 total=2\n");
});

test("qipok spells the suite option only --suite", () => {
  const result = qipok(["bytes/identity.wasm", "--with", "compliance/preserve-empty.wasm"]);
  assert.equal(result.status, 1);
  assert.equal(result.stderr, "qipok: unknown option --with; use --suite\n");
});

// Hosts by authority, and paths, as parsed from argv.
function split(argv) {
  const { hosts, paths } = parseArgs(argv);
  return { hosts: hosts.map((host) => host.authority), paths };
}

test("qipok takes hosts anywhere before the first file or directory", () => {
  const expected = { hosts: ["qip.dev", "example.com:8443"], paths: ["text/hello.wasm", "bytes"] };
  for (const argv of [
    ["qip.dev", "example.com:8443", "text/hello.wasm", "bytes"],
    ["--seed", "7", "qip.dev", "example.com:8443", "text/hello.wasm", "bytes"],
    ["qip.dev", "--seed", "7", "example.com:8443", "--suite", "s.wasm", "text/hello.wasm", "bytes"],
  ]) {
    assert.deepEqual(split(argv), expected, argv.join(" "));
  }
  // After the first path, a host-like argument is a path.
  assert.deepEqual(split(["text/hello.wasm", "qip.dev"]), { hosts: [], paths: ["text/hello.wasm", "qip.dev"] });
  // The last positional argument is always a path, and so is a host-like name that exists.
  assert.deepEqual(split(["README.md"]), { hosts: [], paths: ["README.md"] });
  assert.deepEqual(split(["qip.dev", "README.md"]), { hosts: ["qip.dev"], paths: ["README.md"] });
  assert.deepEqual(split(["README.md", "text/hello.wasm"]), { hosts: [], paths: ["README.md", "text/hello.wasm"] });
  // Names without a dot, such as directories, are never hosts.
  assert.deepEqual(split(["bytes", "text"]), { hosts: [], paths: ["bytes", "text"] });
});

test("qipok reads a local directory named like a host instead of contacting it", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qipok-"));
  try {
    await mkdir(join(directory, "qip.dev"));
    const result = qipok(["qip.dev", resolve("text/hello.wasm")], { cwd: directory });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, `PASS ${resolve("text/hello.wasm")}\n\npass=1 fail=0 total=1\n`);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
