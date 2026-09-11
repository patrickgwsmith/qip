import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { decodeRenderResult } from "./lib/content-component-host.mjs";

const execFileP = promisify(execFile);

const qip = fileURLToPath(new URL("../qip", import.meta.url));
const strictProfile = fileURLToPath(
  new URL("../application/wasm/wasm-strict-profile.wasm", import.meta.url),
);
const readInputContentType = fileURLToPath(
  new URL("../application/wasm/wasm-read-input-content-type.wasm", import.meta.url),
);
const componentDirs = ["components", "application", "bytes", "font", "image", "multipart", "text"]
  .map((directory) => fileURLToPath(new URL(`../${directory}`, import.meta.url)));
const boundedLoops = fileURLToPath(
  new URL("../application/wasm/wasm-bounded-loops.wasm", import.meta.url),
);
const boundedOutput = fileURLToPath(
  new URL("../application/wasm/wasm-bounded-output.wasm", import.meta.url),
);
const wasmCounts = fileURLToPath(
  new URL("../application/wasm/wasm-counts.wasm", import.meta.url),
);
const wasmRenderCyclomaticComplexity = fileURLToPath(
  new URL("../application/wasm/render-cyclomatic-complexity.wasm", import.meta.url),
);
const nontrappingDivides = fileURLToPath(
  new URL("../application/wasm/wasm-nontrapping-divides.wasm", import.meta.url),
);
const core10Validator = fileURLToPath(
  new URL("../application/wasm/wasm-validate-core-1.0.wasm", import.meta.url),
);
const luhn = fileURLToPath(new URL("../text/luhn.wasm", import.meta.url));
const e164 = fileURLToPath(new URL("../text/e164.wasm", import.meta.url));
const infiniteLoop = fileURLToPath(new URL("../text/infinite-loop.wasm", import.meta.url));
const helloNaive = fileURLToPath(new URL("../text/hello-naive.wasm", import.meta.url));
const bmpColorPalette = fileURLToPath(
  new URL("../image/bmp/bmp-color-palette.wasm", import.meta.url),
);
const indirectFixture = fileURLToPath(
  new URL("fixtures/qip-component-to-zig-indirect.wasm", import.meta.url),
);

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(strictProfile, constants.R_OK);
    await access(readInputContentType, constants.R_OK);
    await access(boundedLoops, constants.R_OK);
    await access(boundedOutput, constants.R_OK);
    await access(wasmCounts, constants.R_OK);
    await access(wasmRenderCyclomaticComplexity, constants.R_OK);
    await access(nontrappingDivides, constants.R_OK);
    await access(core10Validator, constants.R_OK);
    await access(luhn, constants.R_OK);
    await access(e164, constants.R_OK);
    await access(infiniteLoop, constants.R_OK);
    await access(helloNaive, constants.R_OK);
    await access(bmpColorPalette, constants.R_OK);
    await access(indirectFixture, constants.R_OK);
  } catch {
    t.skip("build ./qip and components first");
  }
}

test("Core 1.0 validator agrees with WebAssembly.validate and recovers after rejection", async (t) => {
  await ensurePrerequisites(t);

  const valid = await readFile(helloNaive);
  const invalid = Buffer.from(
    "0061736d0100000001070160027f7e017f030201000a09010700200020016a0b",
    "hex",
  );
  assert.equal(WebAssembly.validate(valid), true);
  assert.equal(WebAssembly.validate(invalid), false);

  const validatorBytes = await readFile(core10Validator);
  const instance = await WebAssembly.instantiate(validatorBytes);
  const wasm = instance.instance.exports;
  const validate = (bytes) => {
    new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), bytes.length).set(bytes);
    const result = decodeRenderResult(wasm.render(bytes.length));
    return !result.failed && result.value === bytes.length;
  };

  assert.equal(validate(invalid), WebAssembly.validate(invalid));
  assert.equal(validate(valid), WebAssembly.validate(valid));

  const result = await runQip(["run", "-i", helloNaive, "--", core10Validator]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.deepEqual(result.stdout, valid);
});

async function runQip(args) {
  try {
    const { stdout, stderr } = await execFileP(qip, args, {
      encoding: "buffer",
      maxBuffer: 1024 * 1024,
    });
    return { code: 0, stdout, stderr };
  } catch (err) {
    if (err && Object.hasOwn(err, "stdout") && Object.hasOwn(err, "stderr")) {
      return {
        code: typeof err.code === "number" ? err.code : 1,
        stdout: err.stdout ?? Buffer.alloc(0),
        stderr: err.stderr ?? Buffer.alloc(0),
      };
    }
    throw err;
  }
}

function parseCountRows(output) {
  const lines = output.toString("utf8").trimEnd().split("\n");
  assert.equal(lines[0], "metric,value");
  const rows = new Map(
    lines.slice(1).map((line) => {
      const [metric, value, ...extra] = line.split(",");
      assert.equal(extra.length, 0);
      assert.match(metric, /^[a-z][a-z0-9_]*$/);
      assert.match(value, /^\d+$/);
      return [metric, Number(value)];
    }),
  );
  assert.equal(rows.size, lines.length - 1, "metric names must be unique");
  return rows;
}

test("wasm-counts emits stable long-form integer CSV", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", e164, "--", wasmCounts]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));

  const rows = parseCountRows(result.stdout);
  assert.equal(rows.get("exports"), 5);
  assert.equal(rows.get("functions_exported"), 4);
  assert.equal(rows.get("memories_exported"), 1);
  assert.equal(rows.get("functions_defined"), 4);
  assert.equal(rows.get("function_instructions"), 73);
  assert.equal(rows.get("loops"), 1);
  assert.equal(rows.get("simd_instructions"), 0);
  assert.equal(rows.get("memory_loads"), 1);
  assert.equal(rows.get("memory_stores"), 2);
  assert.equal(rows.get("memory_copies"), 0);
  assert.equal(rows.get("memory_fills"), 0);
  assert.ok(rows.get("potentially_trapping_instructions") > 0);
});

test("wasm-counts reports table shape and exact indirect-call opcodes", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", indirectFixture, "--", wasmCounts]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  const rows = parseCountRows(result.stdout);
  assert.equal(rows.get("tables_defined"), 1);
  assert.equal(rows.get("tables_funcref"), 1);
  assert.equal(rows.get("tables_fixed_size"), 1);
  assert.equal(rows.get("active_element_segments_table_zero"), 2);
  assert.equal(rows.get("element_function_index_initializers"), 2);
  assert.equal(rows.get("calls_indirect"), 6);
  assert.equal(rows.get("call_indirect"), 6);
  assert.equal(rows.get("return_call_indirect"), 0);
  assert.equal(rows.get("call_ref"), 0);
  assert.equal(rows.get("indirect_calls_table_zero"), 6);
  assert.equal(rows.get("indirect_calls_nonzero_table"), 0);
  assert.equal(rows.get("table_set"), 0);
});

test("wasm-counts has no indirect calls", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", wasmCounts, "--", wasmCounts]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.match(result.stdout.toString("utf8"), /^calls_indirect,0$/m);
});

test("render-cyclomatic-complexity follows render calls once", async (t) => {
  await ensurePrerequisites(t);

  const dir = await mkdtemp(join(tmpdir(), "qip-render-cyclomatic-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const modulePath = join(dir, "reachable-branches.wasm");
  const outputPath = join(dir, "complexity.txt");
  const module = renderCyclomaticComplexityModule();
  assert.equal(WebAssembly.validate(module), true);
  await writeFile(modulePath, module);

  const result = await runQip([
    "run", "-i", modulePath, "-o", outputPath, "--", wasmRenderCyclomaticComplexity,
  ]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.deepEqual(await readFile(outputPath), Buffer.from("4"));
});

function encodeU32(value) {
  const bytes = [];
  let remaining = value >>> 0;
  do {
    let byte = remaining & 0x7f;
    remaining >>>= 7;
    if (remaining !== 0) byte |= 0x80;
    bytes.push(byte);
  } while (remaining !== 0);
  return bytes;
}

function wasmSection(id, payload) {
  return [id, ...encodeU32(payload.length), ...payload];
}

function wasmName(value) {
  const bytes = [...Buffer.from(value)];
  return [...encodeU32(bytes.length), ...bytes];
}

function renderCyclomaticComplexityModule() {
  const bodies = [
    [0x00, 0x10, 0x01, 0x10, 0x02, 0x0b],
    [0x00, 0x41, 0x00, 0x04, 0x40, 0x0b, 0x10, 0x00, 0x10, 0x03, 0x0b],
    [0x00, 0x41, 0x00, 0x0d, 0x00, 0x0b],
    [
      0x00,
      0x02, 0x40,
      0x02, 0x40,
      0x41, 0x00,
      0x0e, 0x02, 0x00, 0x01, 0x00,
      0x0b, 0x0b, 0x0b,
    ],
    [0x00, 0x41, 0x00, 0x04, 0x40, 0x0b, 0x0b],
  ];
  const code = [bodies.length];
  for (const body of bodies) code.push(...encodeU32(body.length), ...body);

  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...wasmSection(1, [0x01, 0x60, 0x00, 0x00]),
    ...wasmSection(3, [bodies.length, ...new Array(bodies.length).fill(0)]),
    ...wasmSection(7, [0x01, ...wasmName("render"), 0x00, 0x00]),
    ...wasmSection(10, code),
  ]);
}

function singleVoidFunctionModule(ops) {
  const body = [0x00, ...ops, 0x0b];
  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...wasmSection(1, [0x01, 0x60, 0x00, 0x00]),
    ...wasmSection(3, [0x01, 0x00]),
    ...wasmSection(10, [0x01, ...encodeU32(body.length), ...body]),
  ]);
}

function singleI32FunctionModule(ops) {
  const body = [0x00, ...ops, 0x0b];
  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...wasmSection(1, [0x01, 0x60, 0x01, 0x7f, 0x00]),
    ...wasmSection(3, [0x01, 0x00]),
    ...wasmSection(10, [0x01, ...encodeU32(body.length), ...body]),
  ]);
}

test("nontrapping divides accepts a proved divisor and rejects zero", async (t) => {
  await ensurePrerequisites(t);
  const checkerBytes = await readFile(nontrappingDivides);
  const { instance } = await WebAssembly.instantiate(checkerBytes);
  const wasm = instance.exports;
  const check = (moduleBytes) => {
    assert.equal(WebAssembly.validate(moduleBytes), true);
    new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), moduleBytes.length).set(moduleBytes);
    const result = decodeRenderResult(wasm.render(moduleBytes.length));
    return result.failed ? -1 : result.value;
  };

  const safe = singleVoidFunctionModule([0x41, 42, 0x41, 3, 0x6e, 0x1a]);
  assert.equal(check(safe), safe.length);

  const zero = singleVoidFunctionModule([0x41, 42, 0x41, 0, 0x6e, 0x1a]);
  assert.equal(check(zero), -1);

  const guarded = singleI32FunctionModule([
    0x02, 0x40,
    0x20, 0x00, 0x45, 0x0d, 0x00,
    0x41, 42, 0x20, 0x00, 0x6e, 0x1a,
    0x0b,
  ]);
  assert.equal(check(guarded), guarded.length);

  const guardedAcrossReturn = singleI32FunctionModule([
    0x02, 0x40,
    0x02, 0x40,
    0x20, 0x00, 0x45, 0x0d, 0x00,
    0x0c, 0x01,
    0x0b,
    0x0f,
    0x0b,
    0x41, 42, 0x20, 0x00, 0x6e, 0x1a,
  ]);
  assert.equal(check(guardedAcrossReturn), guardedAcrossReturn.length);

  const unsafeJoin = singleI32FunctionModule([
    0x02, 0x40,
    0x02, 0x40,
    0x20, 0x00, 0x45, 0x0d, 0x00,
    0x0c, 0x01,
    0x0b,
    0x01,
    0x0b,
    0x41, 42, 0x20, 0x00, 0x6e, 0x1a,
  ]);
  assert.equal(check(unsafeJoin), -1);

  const unrelatedLaterLoopWrite = singleI32FunctionModule([
    0x41, 1, 0x21, 0x00,
    0x02, 0x40, 0x03, 0x40, 0x0c, 0x01, 0x0b, 0x0b,
    0x41, 42, 0x20, 0x00, 0x6e, 0x1a,
    0x02, 0x40, 0x03, 0x40,
    0x41, 0, 0x21, 0x00, 0x0c, 0x01, 0x0b, 0x0b,
  ]);
  assert.equal(check(unrelatedLaterLoopWrite), unrelatedLaterLoopWrite.length);

  const palette = await readFile(bmpColorPalette);
  assert.equal(check(palette), palette.length);
  assert.deepEqual(
    Buffer.from(
      wasm.memory.buffer,
      decodeRenderResult(wasm.render(palette.length)).outputPointer,
      palette.length,
    ),
    palette,
  );
});

function staticContentTypeModule({
  inputPtrBody = [0x00, 0x41, 0x10, 0x0b],
  inputSizeBody = [0x00, 0x41, 0x0a, 0x0b],
  outputPtrBody = [0x00, 0x41, 0x20, 0x0b],
  outputSizeBody = [0x00, 0x41, 0x09, 0x0b],
  exports = [
    ["input_content_type_ptr", 0],
    ["input_content_type_size", 1],
    ["output_content_type_ptr", 2],
    ["output_content_type_size", 3],
  ],
  data = [
    [16, "text/plain"],
    [32, "text/html"],
  ],
  globals = [],
} = {}) {
  const bodies = [inputPtrBody, inputSizeBody, outputPtrBody, outputSizeBody];
  const typeSection = wasmSection(1, [0x01, 0x60, 0x00, 0x01, 0x7f]);
  const functionSection = wasmSection(3, [bodies.length, ...bodies.map(() => 0)]);
  const memorySection = wasmSection(5, [0x01, 0x01, 0x01, 0x01]);
  const globalSection = globals.length === 0
    ? []
    : wasmSection(6, [
        ...encodeU32(globals.length),
        ...globals.flatMap(({ mutable, value }) => [
          0x7f,
          mutable ? 0x01 : 0x00,
          0x41,
          ...encodeU32(value),
          0x0b,
        ]),
      ]);
  const exportSection = wasmSection(7, [
    ...encodeU32(exports.length + 1),
    ...wasmName("memory"), 0x02, 0x00,
    ...exports.flatMap(([name, index, kind = 0x00]) => [
      ...wasmName(name), kind, ...encodeU32(index),
    ]),
  ]);
  const codeSection = wasmSection(10, [
    ...encodeU32(bodies.length),
    ...bodies.flatMap((body) => [...encodeU32(body.length), ...body]),
  ]);
  const dataSection = data.length === 0
    ? []
    : wasmSection(11, [
        ...encodeU32(data.length),
        ...data.flatMap(([offset, value]) => {
          const bytes = [...Buffer.from(value)];
          return [0x00, 0x41, ...encodeU32(offset), 0x0b, ...encodeU32(bytes.length), ...bytes];
        }),
      ]);
  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    ...typeSection,
    ...functionSection,
    ...memorySection,
    ...globalSection,
    ...exportSection,
    ...codeSection,
    ...dataSection,
  ]);
}

function globalContractValueModule(globalName) {
  const typeSection = wasmSection(1, [
    0x02,
    0x60, 0x00, 0x01, 0x7f,
    0x60, 0x01, 0x7f, 0x01, 0x7e,
  ]);
  const functionSection = wasmSection(3, [0x04, 0x00, 0x00, 0x00, 0x01]);
  const memorySection = wasmSection(5, [0x01, 0x01, 0x01, 0x01]);
  const globalSection = wasmSection(6, [0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b]);
  const valueExports = [
    ["input_ptr", 0],
    ["input_bytes_cap", 1],
    ["output_bytes_cap", 2],
  ];
  const exports = [
    [...wasmName("memory"), 0x02, 0x00],
    ...valueExports.map(([name, index]) => [
      ...wasmName(name),
      name === globalName ? 0x03 : 0x00,
      ...encodeU32(name === globalName ? 0 : index),
    ]),
    [...wasmName("render"), 0x00, 0x03],
  ];
  const exportSection = wasmSection(7, [
    ...encodeU32(exports.length),
    ...exports.flat(),
  ]);
  const bodies = [
    [0x00, 0x41, 0x00, 0x0b],
    [0x00, 0x41, 0xff, 0x01, 0x0b],
    [0x00, 0x41, 0xff, 0x01, 0x0b],
    [0x00, 0x42, 0x00, 0x0b],
  ];
  const codeSection = wasmSection(10, [
    ...encodeU32(bodies.length),
    ...bodies.flatMap((body) => [...encodeU32(body.length), ...body]),
  ]);
  return new Uint8Array([
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    ...typeSection,
    ...functionSection,
    ...memorySection,
    ...globalSection,
    ...exportSection,
    ...codeSection,
  ]);
}

async function strictProfileAccepts(moduleBytes) {
  const validatorBytes = await readFile(strictProfile);
  const { instance } = await WebAssembly.instantiate(validatorBytes);
  const wasm = instance.exports;
  new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), moduleBytes.length).set(moduleBytes);
  const result = decodeRenderResult(wasm.render(moduleBytes.length));
  return !result.failed && result.value === moduleBytes.length;
}

async function createContentTypeReader() {
  const readerBytes = await readFile(readInputContentType);
  const { instance } = await WebAssembly.instantiate(readerBytes);
  const wasm = instance.exports;
  return (moduleBytes) => {
    assert.ok(moduleBytes.length <= wasm.input_bytes_cap(), "module exceeds reader capacity");
    new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), moduleBytes.length).set(moduleBytes);
    const result = decodeRenderResult(wasm.render(moduleBytes.length));
    assert.equal(result.failed, false);
    return Buffer.from(
      new Uint8Array(wasm.memory.buffer, result.outputPointer, result.value),
    ).toString("utf8");
  };
}

async function componentWasmFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await componentWasmFiles(path));
    else if (entry.isFile() && path.endsWith(".wasm")) files.push(path);
  }
  return files;
}

async function allComponentWasmFiles() {
  return (await Promise.all(componentDirs.map(componentWasmFiles))).flat();
}

test("strict profile accepts content types from the initial memory image", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule();
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), true);
  const readContentType = await createContentTypeReader();
  assert.equal(readContentType(moduleBytes), "text/plain");
});

test("strict profile accepts content type getters backed by immutable constants", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule({
    inputPtrBody: [0x00, 0x23, 0x00, 0x0b],
    inputSizeBody: [0x00, 0x23, 0x01, 0x0b],
    globals: [
      { mutable: false, value: 16 },
      { mutable: false, value: 10 },
    ],
  });
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), true);
  const readContentType = await createContentTypeReader();
  assert.equal(readContentType(moduleBytes), "text/plain");
});

test("strict profile rejects branching content type getters", async (t) => {
  await ensurePrerequisites(t);
  const branchingGetter = [
    0x00,
    0x41, 0x01,
    0x04, 0x7f,
    0x41, 0x10,
    0x05,
    0x41, 0x20,
    0x0b,
    0x0b,
  ];
  const moduleBytes = staticContentTypeModule({ inputPtrBody: branchingGetter });
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), false);
  const readContentType = await createContentTypeReader();
  assert.throws(() => readContentType(moduleBytes), WebAssembly.RuntimeError);
});

test("strict profile rejects mutable content type globals", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule({
    inputPtrBody: [0x00, 0x23, 0x00, 0x0b],
    globals: [{ mutable: true, value: 16 }],
  });
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), false);
  const readContentType = await createContentTypeReader();
  assert.throws(() => readContentType(moduleBytes), WebAssembly.RuntimeError);
});

test("strict profile rejects content type metadata exported as globals", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule({
    exports: [
      ["input_content_type_ptr", 0, 0x03],
      ["input_content_type_size", 1, 0x03],
      ["output_content_type_ptr", 2, 0x03],
      ["output_content_type_size", 3, 0x03],
    ],
    globals: [
      { mutable: false, value: 16 },
      { mutable: false, value: 10 },
      { mutable: false, value: 32 },
      { mutable: false, value: 9 },
    ],
  });
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), false);
  const readContentType = await createContentTypeReader();
  assert.throws(() => readContentType(moduleBytes), WebAssembly.RuntimeError);
});

test("strict profile rejects content types absent from initial memory", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule({ data: [] });
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), false);
  const readContentType = await createContentTypeReader();
  assert.throws(() => readContentType(moduleBytes), WebAssembly.RuntimeError);
});

test("strict profile requires content type pointer and size pairs", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule({
    exports: [
      ["input_content_type_ptr", 0],
      ["output_content_type_ptr", 2],
      ["output_content_type_size", 3],
    ],
  });
  assert.equal(WebAssembly.validate(moduleBytes), true);
  assert.equal(await strictProfileAccepts(moduleBytes), false);
  const readContentType = await createContentTypeReader();
  assert.throws(() => readContentType(moduleBytes), WebAssembly.RuntimeError);
});

test("content type reader returns empty when input metadata is omitted", async (t) => {
  await ensurePrerequisites(t);
  const moduleBytes = staticContentTypeModule({
    exports: [
      ["output_content_type_ptr", 2],
      ["output_content_type_size", 3],
    ],
  });
  const readContentType = await createContentTypeReader();
  assert.equal(readContentType(moduleBytes), "");
});

test("all component content types are statically readable", async (t) => {
  await ensurePrerequisites(t);
  const readContentType = await createContentTypeReader();
  const failures = [];
  let checked = 0;

  for (const path of await allComponentWasmFiles()) {
    const moduleBytes = await readFile(path);
    const exports = WebAssembly.Module.exports(new WebAssembly.Module(moduleBytes));
    if (!exports.some(({ name }) => name.includes("content_type"))) continue;
    checked += 1;
    try {
      readContentType(moduleBytes);
    } catch (error) {
      failures.push(`${path}: ${error.message}`);
    }
  }

  assert.ok(checked > 0, "no component content types found");
  assert.deepEqual(failures, []);
});

test("all component QIP value exports are functions", async (t) => {
  await ensurePrerequisites(t);
  const qipValueNames = new Set([
    "input_ptr", "input_utf8_cap", "input_bytes_cap",
    "output_utf8_cap", "output_bytes_cap", "failure_modes_per_input_offset",
    "input_content_type_ptr", "input_content_type_size",
    "output_content_type_ptr", "output_content_type_size",
    "output_rgba8_srgb_bytes", "render_width_px", "render_height_px",
  ]);
  const failures = [];
  let checked = 0;
  for (const path of await allComponentWasmFiles()) {
    const exports = WebAssembly.Module.exports(new WebAssembly.Module(await readFile(path)));
    for (const valueExport of exports.filter(({ name }) => qipValueNames.has(name))) {
      checked += 1;
      if (valueExport.kind !== "function") failures.push(`${path}: ${valueExport.name}`);
    }
  }
  assert.ok(checked > 0, "no QIP value exports found");
  assert.deepEqual(failures, []);
});

test("qip run and comply reject QIP values exported as globals", async (t) => {
  await ensurePrerequisites(t);
  const directory = await mkdtemp(join(tmpdir(), "qip-input-ptr-"));
  try {
    for (const name of ["input_ptr", "input_bytes_cap", "output_bytes_cap"]) {
      const moduleBytes = globalContractValueModule(name);
      assert.equal(WebAssembly.validate(moduleBytes), true);
      const path = join(directory, `${name}.wasm`);
      await writeFile(path, moduleBytes);
      for (const args of [["run", "-i", path, "--", path], ["comply", path]]) {
        const result = await runQip(args);
        assert.notEqual(result.code, 0);
        assert.match(
          result.stderr.toString("utf8"),
          new RegExp(`${name}.*(?:\\(\\) -> i32|must be function)`),
          `${args[0]} should report the invalid ${name} export on stderr`,
        );
      }
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("content type reader runs as a QIP component", async (t) => {
  await ensurePrerequisites(t);
  const result = await runQip(["run", "-i", strictProfile, "--", readInputContentType]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.equal(result.stdout.toString("utf8"), "application/wasm\n");
});

test("strict tier pipeline accepts bounded luhn loops and output", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip([
    "run",
    "-i",
    luhn,
    "--",
    strictProfile,
    boundedLoops,
    boundedOutput,
  ]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.equal(result.stdout.length > 0, true);
});

test("bounded output rejects a dynamic result without a proof epilogue", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", helloNaive, "--", boundedOutput]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr.toString("utf8"), /component rejected input/);
});

test("strict profile alone accepts an unbounded loop", async (t) => {
  await ensurePrerequisites(t);

  // Loop bounds are wasm-bounded-loops' job: the profile stage checks the
  // factual rules only.
  const result = await runQip(["run", "-i", infiniteLoop, "--", strictProfile]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.equal(result.stdout.length > 0, true);
});

test("bounded loops stage rejects an unbounded loop", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", infiniteLoop, "--", boundedLoops]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr.toString("utf8"), /component rejected input/);
});

test("qip score warns that Wasm checker components replace it", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["score", infiniteLoop]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.match(result.stderr.toString("utf8"), /qip score is deprecated/);
  assert.match(result.stderr.toString("utf8"), /wasm-bounded-loops\.wasm/);
});
