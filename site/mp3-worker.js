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
    const { input, bitrateKbps } = event.data;
    const encoderModule = await WebAssembly.compileStreaming(
      fetch("/audio/wav/wav-to-mp3-lossy.wasm"),
    );
    const encoder = new WebAssembly.Instance(encoderModule, {}).exports;
    encoder._initialize?.();
    encoder.uniform_set_bitrate_kbps(bitrateKbps);
    const started = performance.now();
    const mp3 = run(encoder, new Uint8Array(input));
    if (mp3 === null) {
      throw Error(
        "The encoder rejected this WAV. It must be 16-bit PCM, mono or stereo, at 8–48 kHz.",
      );
    }
    self.postMessage({
      type: "done",
      output: mp3.buffer,
      elapsedMs: performance.now() - started,
      peakBytes: encoder.arena_peak_bytes() >>> 0,
    }, [mp3.buffer]);
  } catch (error) {
    self.postMessage({
      type: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  } finally {
    self.close();
  }
};
