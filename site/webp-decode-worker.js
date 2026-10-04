function run(exports, input) {
  const inputCap = exports.input_bytes_cap() >>> 0;
  if (input.length > inputCap) {
    throw Error(`Input exceeds component capacity: ${input.length} > ${inputCap} bytes.`);
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length)
    .set(input);
  const renderResult = exports.render(input.length);
  if (typeof renderResult !== "bigint") throw TypeError("render must return i64");
  const renderBits = BigInt.asUintN(64, renderResult);
  if ((renderBits & (1n << 63n)) !== 0n) return null;
  const outputSize = Number(renderBits & 0xffff_ffffn);
  const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
  if (outputSize === 0) {
    return null;
  }
  if (outputSize > (exports.output_bytes_cap() >>> 0)) {
    throw Error("A component returned output beyond its declared capacity.");
  }
  return new Uint8Array(
    exports.memory.buffer,
    outputPointer,
    outputSize,
  ).slice();
}

self.onmessage = async (event) => {
  try {
    const { input } = event.data;
    const inputBytes = new Uint8Array(input);
    const decoderModule = await WebAssembly.compileStreaming(
      fetch("/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm"),
    );
    const decoder = new WebAssembly.Instance(decoderModule, {}).exports;
    decoder._initialize?.();
    const started = performance.now();
    const ktx2 = run(decoder, inputBytes);
    if (ktx2 === null) {
      throw Error(
        "The decoder rejected this WebP. It may be malformed, animated, or larger than 25 MP.",
      );
    }
    const view = new DataView(ktx2.buffer, ktx2.byteOffset, ktx2.byteLength);
    const width = view.getUint32(20, true);
    const height = view.getUint32(24, true);
    const elapsedMs = performance.now() - started;
    self.postMessage({
      type: "done",
      output: ktx2.buffer,
      width,
      height,
      elapsedMs,
      peakBytes: decoder.arena_peak_bytes() >>> 0,
    }, [ktx2.buffer]);
  } catch (error) {
    self.postMessage({
      type: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  } finally {
    self.close();
  }
};
