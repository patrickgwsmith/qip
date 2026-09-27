// Every QIP host must validate a recipe the same way and print the same message. This runs
// the same pipelines through the Go `qip`, the Node.js `qipx`, and, when built, the Rust
// `qipx`, and asserts their exit codes and first error lines agree. Run with:
//   node --test test/pipeline-consensus.mjs
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import test from "node:test";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const goCLI = resolve(root, "qip");
const nodeCLI = resolve(root, "npm/qipx/cli.mjs");
const rustCLI = resolve(root, "rust/qipx/target/debug/qipx");
const input = readFileSync(resolve(root, "qip-logo.png"));

function firstError(stderr) {
  return stderr.replace(/^qipx: /, "").split("\n")[0];
}

function runTool(tool, subcommand, args, options = {}) {
  const { form = null, inputFile = "qip-logo.png", inputBytes = input } = options;
  let argv;
  let stdin;
  if (tool === "go") {
    argv = subcommand === "dry" ? ["dry", "run", ...args] : ["run", ...args, ...(form ? ["-F", form] : ["-i", inputFile]), "-o", "/dev/null"];
  } else {
    argv = subcommand === "dry" ? ["dry", "run", ...args] : ["run", ...(form ? ["-F", form] : []), ...args];
    stdin = form || subcommand === "dry" ? undefined : inputBytes;
  }
  const command = tool === "node" ? process.execPath : tool === "go" ? goCLI : rustCLI;
  const result = spawnSync(command, tool === "node" ? [nodeCLI, ...argv] : argv, { cwd: root, input: stdin });
  return { code: result.status, error: firstError(result.stderr.toString("utf8")) };
}

const tools = ["go", "node", ...(existsSync(rustCLI) ? ["rust"] : [])];

const refusals = [
  ["bytes output into an untyped UTF-8 input", "run", ["bytes/zlib-compress.wasm", "text/base64-decode-c-simd.wasm"]],
  ["typed bytes output into a typed UTF-8 input", "run", ["bytes/zlib-compress.wasm", "text/markdown/commonmark.0.31.2.wasm"]],
  ["RGBA8 KTX2 into a float KTX2 component", "run", [
    "image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm",
    "image/ktx2/ktx2-rgba32float-look-warm-fade.wasm",
  ]],
  ["inputless generator after the first step", "run", [
    "image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm",
  ]],
  ["form input into a step that declares image/png", "run", ["image/png/png-to-ktx2-r8g8b8a8-srgb.wasm"], { form: "input=hello" }],
  ["capacities must fit", "dry", ["--capacities-must-fit", "text/ansi-sgr-to-svg.wasm", "text/rgb-to-hex.wasm"]],
];

for (const [name, subcommand, args, options] of refusals) {
  test(`hosts agree: ${name}`, () => {
    const results = tools.map((tool) => [tool, runTool(tool, subcommand, args, options)]);
    for (const [tool, result] of results) {
      assert.equal(result.code, 1, `${tool} should refuse: ${result.error}`);
      assert.match(result.error, /^step \d+ /, `${tool} message should name the step: ${result.error}`);
    }
    const [, first] = results[0];
    for (const [tool, result] of results.slice(1)) {
      assert.equal(result.error, first.error, `${tool} disagrees with ${results[0][0]}`);
    }
  });
}

const accepted = [
  ["untyped input into a step that declares image/png", ["image/png/png-to-ktx2-r8g8b8a8-srgb.wasm"]],
  ["bare image/ktx2 output into a step that declares a profile", [
    "image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm",
  ]],
  ["profile converters between RGBA8 and float", [
    "image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm",
    "image/ktx2/ktx2-rgba32float-look-warm-fade.wasm",
    "image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm",
  ]],
];

for (const [name, args] of accepted) {
  test(`hosts agree: ${name} runs`, () => {
    for (const tool of tools) {
      const result = runTool(tool, "run", args);
      assert.equal(result.code, 0, `${tool} refused: ${result.error}`);
    }
  });
}

const scratch = mkdtempSync(join(tmpdir(), "qip-consensus-"));
const invalidUTF8 = join(scratch, "invalid-utf8.bin");
writeFileSync(invalidUTF8, Buffer.from([0x6f, 0x6b, 0xff, 0xfe, 0x0a]));
const overflowInput = join(scratch, "blob.bin");
writeFileSync(overflowInput, randomBytes(50000));

test("hosts agree: invalid UTF-8 into a UTF-8 first step is refused by the host", () => {
  const options = { inputFile: invalidUTF8, inputBytes: readFileSync(invalidUTF8) };
  const results = tools.map((tool) => [tool, runTool(tool, "run", ["text/trim.wasm"], options)]);
  for (const [tool, result] of results) {
    assert.equal(result.code, 1, `${tool} should refuse`);
    assert.equal(result.error, "step 1 text/trim.wasm expected UTF-8 input, got invalid UTF-8 at input offset 2", tool);
  }
});

test("hosts agree: an intermediate output larger than the next input capacity stops the run", () => {
  const options = { inputFile: overflowInput, inputBytes: readFileSync(overflowInput) };
  const results = tools.map((tool) => [tool, runTool(tool, "run", ["bytes/base64-encode.wasm", "text/base64-decode-c-simd.wasm"], options)]);
  for (const [tool, result] of results) {
    assert.equal(result.code, 1, `${tool} should fail`);
    assert.equal(result.error, "step 2 text/base64-decode-c-simd.wasm input is too large (66668 bytes > 65536 bytes input capacity)", tool);
  }
});

test("hosts agree: a component rejection names the step", () => {
  const results = tools.map((tool) => [tool, runTool(tool, "run", ["bytes/zlib-decompress.wasm"])]);
  for (const [tool, result] of results) {
    assert.equal(result.code, 1, `${tool} should fail`);
    assert.equal(result.error, "step 1 bytes/zlib-decompress.wasm rejected input", tool);
  }
});

test("hosts agree: a trap names the step; the reason is engine-specific", () => {
  for (const tool of tools) {
    const result = runTool(tool, "run", ["image/ktx2/ktx2-rgba32float-look-warm-fade.wasm"]);
    assert.equal(result.code, 1, `${tool} should fail`);
    assert.match(result.error, /^step 1 image\/ktx2\/ktx2-rgba32float-look-warm-fade\.wasm trapped: /, tool);
  }
});

test("hosts agree: dry run notes a capacity overflow the same way", () => {
  const notes = tools.map((tool) => {
    const command = tool === "node" ? process.execPath : tool === "go" ? goCLI : rustCLI;
    const argv = ["dry", "run", "text/ansi-sgr-to-svg.wasm", "text/rgb-to-hex.wasm"];
    const result = spawnSync(command, tool === "node" ? [nodeCLI, ...argv] : argv, { cwd: root });
    const text = result.stdout.toString("utf8") + result.stderr.toString("utf8");
    const note = text.split("\n").find((line) => line.includes("Note: step"));
    return [tool, result.status, note?.trim()];
  });
  for (const [tool, code, note] of notes) {
    assert.equal(code, 0, `${tool} dry run failed`);
    assert.ok(note, `${tool} printed no capacity note`);
    assert.equal(note, notes[0][2], `${tool} disagrees with ${notes[0][0]}`);
  }
});
