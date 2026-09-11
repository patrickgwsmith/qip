import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const qip = fileURLToPath(new URL("../qip", import.meta.url));
const instrumenter = fileURLToPath(
  new URL("../application/wasm/wasm-trace-instrument.wasm", import.meta.url),
);

function isDenoPermissionError(err) {
  return err && (err.name === "NotCapable" || String(err.message ?? "").includes("Requires "));
}

async function ensureTracePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
  } catch (err) {
    if (isDenoPermissionError(err)) throw err;
    t.skip("build ./qip first");
  }

  try {
    await access(instrumenter, constants.R_OK);
  } catch (err) {
    if (isDenoPermissionError(err)) throw err;
    t.skip("build application/wasm/wasm-trace-instrument.wasm first");
  }

  try {
    await execFileP("wat2wasm", ["--version"]);
  } catch (err) {
    if (err && err.code === "ENOENT") {
      t.skip("wat2wasm is required to compile the test fixtures");
    }
    throw err;
  }
}

async function watToWasm(t, name, wat) {
  const dir = await mkdtemp(join(tmpdir(), "qip-trace-with-"));
  t.after(() => rm(dir, { recursive: true, force: true }));

  const watPath = join(dir, `${name}.wat`);
  const wasmPath = join(dir, `${name}.wasm`);
  const inputPath = join(dir, "empty-input.bin");
  await writeFile(watPath, wat);
  await writeFile(inputPath, "");
  await execFileP("wat2wasm", [watPath, "-o", wasmPath]);
  return { inputPath, wasmPath };
}

async function runQip(args) {
  try {
    const { stdout, stderr } = await execFileP(qip, args, { maxBuffer: 1024 * 1024 });
    return { code: 0, stdout, stderr };
  } catch (err) {
    if (err && Object.hasOwn(err, "stdout") && Object.hasOwn(err, "stderr")) {
      return {
        code: typeof err.code === "number" ? err.code : 1,
        stdout: err.stdout ?? "",
        stderr: err.stderr ?? "",
      };
    }
    throw err;
  }
}

test("qip run --trace-with reports the load that traps out of bounds", async (t) => {
  await ensureTracePrerequisites(t);

  const fixture = await watToWasm(
    t,
    "oob-load",
    `(module
      (memory (export "memory") 1)
      (func (export "render") (param i32) (result i64)
        (i32.load (i32.const 65536))
        drop
        (i64.const 137438953472))
      (func (export "input_ptr") (result i32) (i32.const 0))
      (func (export "input_bytes_cap") (result i32) (i32.const 16))
      (func (export "output_bytes_cap") (result i32) (i32.const 16)))`,
  );

  const result = await runQip(["run", "-i", fixture.inputPath, "--trace-with", instrumenter, fixture.wasmPath]);
  assert.notEqual(result.code, 0, result.stdout);
  assert.match(result.stderr, /trace retry with .*wasm-trace-instrument\.wasm:/);
  assert.match(result.stderr, /instrumented retry trapped:/);
  assert.match(result.stderr, /before_load func=0 op=0 mem=0 addr=0x00010000 width=4 bytes=<out-of-bounds>/);
});

test("qip run --trace-with reports store bytes before and after mutation", async (t) => {
  await ensureTracePrerequisites(t);

  const fixture = await watToWasm(
    t,
    "store-then-trap",
    `(module
      (memory (export "memory") 1)
      (data (i32.const 8) "ABCD")
      (func (export "render") (param i32) (result i64)
        (i32.store (i32.const 8) (i32.const 0x11223344))
        (i32.load (i32.const 65536))
        drop
        (i64.const 137438953472))
      (func (export "input_ptr") (result i32) (i32.const 0))
      (func (export "input_bytes_cap") (result i32) (i32.const 16))
      (func (export "output_bytes_cap") (result i32) (i32.const 16)))`,
  );

  const result = await runQip(["run", "-i", fixture.inputPath, "--trace-with", instrumenter, fixture.wasmPath]);
  assert.notEqual(result.code, 0, result.stdout);
  assert.match(result.stderr, /before_store func=0 op=0 mem=0 addr=0x00000008 width=4 bytes=41424344/);
  assert.match(result.stderr, /after_store func=0 op=0 mem=0 addr=0x00000008 width=4 bytes=44332211/);
  assert.match(result.stderr, /before_load func=0 op=1 mem=0 addr=0x00010000 width=4 bytes=<out-of-bounds>/);
});
