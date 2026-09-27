const isDeno = typeof Deno !== "undefined" && typeof Deno.version !== "undefined";

async function readAllStdin() {
  if (isDeno) {
    const chunks = [];
    let total = 0;
    for await (const chunk of Deno.stdin.readable) {
      chunks.push(chunk);
      total += chunk.length;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    return out;
  }

  const fs = await import("node:fs");
  const buf = fs.readFileSync(0);
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}

async function readWasmFile(path) {
  if (isDeno) {
    return await Deno.readFile(path);
  }
  const fs = await import("node:fs");
  const buf = fs.readFileSync(path);
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}

async function writeStdout(bytes) {
  if (isDeno) {
    await Deno.stdout.write(bytes);
    return;
  }
  const { Buffer } = await import("node:buffer");
  process.stdout.write(Buffer.from(bytes));
}

function getExportI32(exportsObj, name) {
  const value = exportsObj[name];
  if (typeof value === "function") {
    const result = value();
    if (typeof result !== "number" || !Number.isFinite(result)) {
      throw new Error(`export ${name}() did not return a number`);
    }
    return result | 0;
  }
  if (typeof value === "number") {
    return value | 0;
  }
  if (value instanceof WebAssembly.Global) {
    return Number(value.value) | 0;
  }
  throw new Error(`missing export: ${name}`);
}

function getInputCap(exportsObj) {
  try {
    return getExportI32(exportsObj, "input_bytes_cap");
  } catch {
    return getExportI32(exportsObj, "input_utf8_cap");
  }
}

function getOutputCap(exportsObj) {
  try {
    return getExportI32(exportsObj, "output_bytes_cap");
  } catch {
    return getExportI32(exportsObj, "output_utf8_cap");
  }
}

function ensureRange(name, ptr, size, memorySize) {
  if (ptr < 0 || size < 0 || ptr + size > memorySize) {
    throw new Error(`${name} out of bounds ptr=${ptr} size=${size} memory=${memorySize}`);
  }
}

async function main() {
  const wasmPath = (isDeno ? Deno.args[0] : process.argv[2]) ?? "./wordcount_zig_wasm.wasm";

  const [input, wasmBytes] = await Promise.all([readAllStdin(), readWasmFile(wasmPath)]);
  const mod = await WebAssembly.instantiate(wasmBytes, {});
  const exportsObj = mod.instance.exports;

  if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing export: memory");
  }
  const memory = exportsObj.memory;

  const inputPtr = getExportI32(exportsObj, "input_ptr");
  const inputCap = getInputCap(exportsObj);
  if (input.length > inputCap) {
    throw new Error(`input too large: ${input.length} > ${inputCap}`);
  }

  let memBytes = new Uint8Array(memory.buffer);
  ensureRange("input", inputPtr, input.length, memBytes.length);
  memBytes.set(input, inputPtr);

  const render = exportsObj.render;
  if (typeof render !== "function") {
    throw new Error("missing export: render");
  }
  const result = BigInt.asUintN(64, render(input.length));
  if ((result >> 63n) !== 0n) throw new Error("rejected input");
  const outputSize = Number(result & 0xffff_ffffn);
  const outputPtr = Number((result >> 32n) & 0x7fff_ffffn);
  const outputCap = getOutputCap(exportsObj);
  if (outputSize > outputCap) {
    throw new Error(`output too large: ${outputSize} > ${outputCap}`);
  }

  memBytes = new Uint8Array(memory.buffer);
  ensureRange("output", outputPtr, outputSize, memBytes.length);
  const out = memBytes.slice(outputPtr, outputPtr + outputSize);
  await writeStdout(out);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  if (isDeno) {
    Deno.exit(1);
  } else {
    process.exit(1);
  }
});
