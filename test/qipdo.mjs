import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { parseArgs } from "../npm/qipdo/qipdo.mjs";

const markdown = "text/markdown/markdown-basic.wasm";
const escape = "text/html/html-escape.wasm";

function qipdo(args, input) {
  const result = spawnSync(process.execPath, ["npm/qipdo/qipdo.mjs", ...args], { input, maxBuffer: 16 * 1024 * 1024 });
  return { status: result.status, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
}

test("qipdo prints help with no arguments and with -h", () => {
  for (const args of [[], ["-h"], ["--help"], [escape, "--help"]]) {
    const result = qipdo(args);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^Usage: qipdo \[host \.\.\.\] \[options\]/);
    assert.match(result.stdout, /--dry-run/);
    assert.match(result.stdout, /--strict-capacities/);
    assert.doesNotMatch(result.stdout, /qipx/);
  }
});

test("qipdo --version prints the package version", async () => {
  const { version } = JSON.parse(await readFile("npm/qipdo/package.json", "utf8"));
  const result = qipdo(["--version"]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), version);
});

test("qipdo runs a chain on stdin without a subcommand", () => {
  const result = qipdo([markdown, escape], "# Hi");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "&lt;h1&gt;Hi&lt;/h1&gt;\n\n");
});

test("qipdo reads -i and writes -o", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qipdo-"));
  try {
    await writeFile(join(directory, "page.md"), "*hi*");
    const output = join(directory, "page.html");
    const result = qipdo(["-i", join(directory, "page.md"), markdown, "-o", output]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "");
    assert.equal(await readFile(output, "utf8"), "<p><em>hi</em></p>\n");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("qipdo allows a larger output capacity by default and notes it on --dry-run", () => {
  const run = qipdo([markdown, escape], "# Hi");
  assert.equal(run.status, 0, run.stderr);
  const dry = qipdo(["--dry-run", markdown, escape]);
  assert.equal(dry.status, 0, dry.stderr);
  assert.match(dry.stdout, /Pipeline compatible: 2 step\(s\)/);
  assert.match(dry.stdout, /Note: step 2 text\/html\/html-escape\.wasm: previous output capacity/);
});

test("qipdo --strict-capacities rejects the mismatch on run and --dry-run", () => {
  for (const args of [["--strict-capacities", markdown, escape], ["--dry-run", "--strict-capacities", markdown, escape]]) {
    const result = qipdo(args, "# Hi");
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^qipdo: step 2 text\/html\/html-escape\.wasm input capacity .* cannot fit step 1/m);
  }
});

test("qipdo --dry-run reads neither stdin nor input files", () => {
  const result = qipdo(["--dry-run", "-i", "missing-input.md", markdown]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Pipeline compatible: 1 step\(s\)/);
});

test("qipdo rejects qipx's old capacity flag name and unknown options", () => {
  const old = qipdo(["--capacities-must-fit", escape]);
  assert.equal(old.status, 1);
  assert.equal(old.stderr, "qipdo: unknown option --capacities-must-fit; use --strict-capacities\n");
  const unknown = qipdo(["--dry", escape]);
  assert.equal(unknown.status, 1);
  assert.equal(unknown.stderr, "qipdo: unknown option --dry\n");
});

test("qipdo takes hosts before the first component, with options before or after them", () => {
  const hosts = (argv) => parseArgs(argv).hosts.map((host) => host.origin);
  const components = (argv) => parseArgs(argv).components.map((stage) => stage.filePath);
  for (const argv of [
    ["qip.dev", "--dry-run", "a.wasm"],
    ["--dry-run", "qip.dev", "a.wasm"],
    ["-i", "page.md", "qip.dev", "a.wasm"],
  ]) {
    assert.deepEqual(hosts(argv), ["https://qip.dev"], argv.join(" "));
    assert.deepEqual(components(argv), ["a.wasm"], argv.join(" "));
  }
  assert.deepEqual(hosts(["qip.dev", "Example.com:8443", "a.wasm"]), ["https://qip.dev", "https://example.com:8443"]);

  // Option values are never hosts or flags.
  const parsed = parseArgs(["-i", "--dry-run", "a.wasm", "-u", "x=1", "--", "--strict-capacities"]);
  assert.equal(parsed.options.input, "--dry-run");
  assert.equal(parsed.options.dryRun, false);
  assert.equal(parsed.options.strictCapacities, false);
  assert.deepEqual(parsed.components.map((stage) => [stage.filePath, stage.uniforms]), [["a.wasm", [["x", "1"]]], ["--strict-capacities", []]]);

  // A .wasm name or a path is a component, not a host, and the last positional argument is
  // always a component, so a lone file name reaches the module loader.
  assert.deepEqual(hosts(["hello.wasm"]), []);
  assert.deepEqual(components(["text/hello.wasm"]), ["text/hello.wasm"]);
  assert.deepEqual(components(["README.md"]), ["README.md"]);
  assert.deepEqual(components(["qip.dev", "README.md", "-u", "x=1"]), ["README.md"]);
  assert.deepEqual(hosts(["qip.dev", "a.wasm", "example.com"]), ["https://qip.dev"]);
  assert.throws(() => parseArgs(["localhost", "a.wasm"]), /invalid host "localhost"/);
});

test("qipdo --dry-run accepts a host after the flag", async () => {
  const directory = await mkdtemp(join(tmpdir(), "qipdo-"));
  try {
    for (const args of [["--dry-run", "qip.dev", "missing.wasm"], ["qip.dev", "--dry-run", "missing.wasm"]]) {
      const result = spawnSync(process.execPath, [join(process.cwd(), "npm/qipdo/qipdo.mjs"), ...args], { cwd: directory });
      assert.equal(result.status, 0, result.stderr.toString());
      assert.match(result.stdout.toString(), /1  https  https:\/\/qip\.dev\/missing\.wasm/, args.join(" "));
      assert.match(result.stdout.toString(), /missing\.wasm: deferred \(local file missing\)/, args.join(" "));
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
