const KTX2_HEADER_SIZE = 224;
const TILE_SIDE = 256;
const modulePromise = WebAssembly.compileStreaming(
  fetch("/application/wasm/qip-interpret-memory-thermal-ktx2.wasm"),
);

// A uniform's setter is uniform_set_<key>, optionally followed by "__" and a
// suffix that declares the uniform's maxima.
function uniformSetter(exports, key) {
  const names = Object.keys(exports).filter((name) => name === `uniform_set_${key}` || name.startsWith(`uniform_set_${key}__`));
  if (names.length > 1) throw Error(`Component exports both ${names[0]} and ${names[1]} for uniform ${key}.`);
  return exports[names[0]];
}

self.onmessage = async (event) => {
  const { id, form, instructionBudget, normalize } = event.data;
  try {
    const input = new Uint8Array(form);
    // A fresh instance per run releases the previous run's memory.
    const exports = new WebAssembly.Instance(await modulePromise, {}).exports;
    const inputCap = exports.input_bytes_cap() >>> 0;
    if (input.length > inputCap) {
      throw Error(`Request exceeds the thermal tool's capacity: ${input.length} > ${inputCap} bytes.`);
    }
    new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length).set(input);
    uniformSetter(exports, "instruction_budget")(instructionBudget);
    uniformSetter(exports, "normalize")(normalize ? 1 : 0);
    const started = performance.now();
    const renderBits = BigInt.asUintN(64, exports.render(input.length));
    const elapsedMs = performance.now() - started;
    const outputSize = Number(renderBits & 0xffff_ffffn);
    if ((renderBits & (1n << 63n)) !== 0n || outputSize === 0) {
      throw Error("The thermal tool rejected this run. The target may have trapped, run out of budget, or touched no memory.");
    }
    const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
    const pixelBytes = outputSize - KTX2_HEADER_SIZE;
    if (pixelBytes <= 0 || pixelBytes % (TILE_SIDE * TILE_SIDE * 4) !== 0) {
      throw Error("The thermal tool returned an unexpected image size.");
    }
    const pixels = new Uint8Array(
      exports.memory.buffer,
      outputPointer + KTX2_HEADER_SIZE,
      pixelBytes,
    ).slice();
    self.postMessage({
      id,
      type: "done",
      pixels: pixels.buffer,
      width: TILE_SIDE,
      height: pixelBytes / (TILE_SIDE * 4),
      normalize,
      elapsedMs,
    }, [pixels.buffer]);
  } catch (error) {
    self.postMessage({
      id,
      type: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  }
};
