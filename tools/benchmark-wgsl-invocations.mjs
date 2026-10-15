#!/usr/bin/env node

// Compile the demo's unchanged Perlin shader with both compiler modes, then
// compare complete Content calls in wazero and warmed V8. Benchmarks run serially.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir, cpus } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { runInNewContext } from "node:vm";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const execFileAsync = promisify(execFile);
const options = { runs: 40, width: 256, height: 192, octaves: [1, 4, 8], baselineCompiler: null };
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === "--runs") options.runs = Number(process.argv[++i]);
  else if (arg === "--size") [options.width, options.height] = process.argv[++i].split("x").map(Number);
  else if (arg === "--octaves") options.octaves = process.argv[++i].split(",").map(Number);
  else if (arg === "--baseline-compiler") options.baselineCompiler = resolve(process.argv[++i]);
  else throw Error(`unknown option ${arg}`);
}
for (const value of [options.runs, options.width, options.height, ...options.octaves]) {
  assert.ok(Number.isSafeInteger(value) && value > 0, "dimensions, run count and octaves must be positive integers");
}
assert.ok(options.width * options.height <= 65536, "input exceeds generated component capacity");
assert.ok(options.octaves.every((n) => n <= 8), "octaves must be in 1..8");

const page = await readFile(join(root, "site/wgsl.md"), "utf8");
const generator = page.match(/function perlinNoiseShader\(\) \{[\s\S]*?\n\}/)?.[0];
assert.ok(generator, "Perlin generator is present in the demo");
const originalSource = runInNewContext(generator + "\nperlinNoiseShader()");
const compilerPath = join(root, "text/wgsl/wgsl-compute-to-wasm.wasm");
const compilerBytes = await readFile(compilerPath);
const compiler = new WebAssembly.Instance(new WebAssembly.Module(compilerBytes)).exports;
const baselineBytes = options.baselineCompiler ? await readFile(options.baselineCompiler) : null;
const baseline = baselineBytes ? new WebAssembly.Instance(new WebAssembly.Module(baselineBytes)).exports : null;
const directory = await mkdtemp(join(tmpdir(), "qip-invocations-bench-"));
const input = Buffer.alloc(options.width * options.height * 16);
const inputPath = join(directory, "image.rgba32f");
await writeFile(inputPath, input);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
console.log(`CPU: ${cpus()[0]?.model}; Node ${process.version}; ${process.platform}/${process.arch}`);
console.log(`Compiler SHA-256: ${hash(compilerBytes)}`);
if (baselineBytes) console.log(`Baseline compiler SHA-256: ${hash(baselineBytes)}`);
console.log(`Input: ${options.width}x${options.height} RGBA32F zeros, ${input.length} bytes, SHA-256 ${hash(input)}`);
console.log(`Artifacts retained in ${directory}`);

for (const octaves of options.octaves) {
  // Change authored defaults so the same artifacts and bytes are benchmarked
  // in both hosts, without relying on host-specific uniform forwarding.
  const source = originalSource
    .replace("override width: u32 = 256;", `override width: u32 = ${options.width};`)
    .replace("override octave_count: u32 = 1;", `override octave_count: u32 = ${octaves};`)
    .replace("override seed: u32 = 0;", "override seed: u32 = 7;")
    .replace("override time: f32 = 0.0;", "override time: f32 = 2.3;");
  await writeFile(join(directory, `perlin-${octaves}.wgsl`), source);
  const paths = [];
  const variants = [{ compiler, mode: 0, name: "scalar" },
    ...(baseline ? [{ compiler: baseline, mode: 1, name: "vector-before" }] : []),
    { compiler, mode: 1, name: "vector" }];
  for (const { compiler, mode, name } of variants) {
    const bytes = new TextEncoder().encode(source);
    new Uint8Array(compiler.memory.buffer, compiler.input_ptr(), bytes.length).set(bytes);
    compiler.uniform_set_vectorize_invocations(mode);
    const result = BigInt.asUintN(64, compiler.render(bytes.length));
    assert.equal(result >> 63n, 0n, "compiler accepted the source");
    const output = Buffer.from(compiler.memory.buffer.slice(Number(result >> 32n),
      Number(result >> 32n) + Number(result & 0xffffffffn)));
    const module = new WebAssembly.Module(output);
    assert.equal(WebAssembly.Module.customSections(module, "qip.vectorize_invocations").length, mode,
      "optimized artifact actually contains the four-invocation path");
    const path = join(directory, `perlin-${octaves}-${name}.wasm`);
    await writeFile(path, output);
    paths.push(path);
    console.log(`${octaves} octaves, ${name}: ${output.length} bytes, SHA-256 ${hash(output)}`);
  }
  for (const [command, args] of [
    [join(root, "qip"), ["bench", "-i", inputPath, "-r", String(options.runs), ...paths]],
    [process.execPath, [join(root, "npm/qipx/cli.mjs"), "bench", "-i", inputPath,
      "--warmup", "30", "-r", String(options.runs), ...paths]],
  ]) {
    console.log(`\n${command} ${args.join(" ")}`);
    const { stdout, stderr } = await execFileAsync(command, args, { cwd: root, maxBuffer: 4 * 1024 * 1024 });
    process.stdout.write(stdout);
    process.stderr.write(stderr);
  }
}
