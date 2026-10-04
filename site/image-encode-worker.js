self.onmessage = async (event) => {
  try {
    const input = new Uint8Array(event.data.input);
    const { component, label } = event.data;
    const module = await WebAssembly.compileStreaming(fetch(component));
    const exports = new WebAssembly.Instance(module, {}).exports;
    const inputCap = exports.input_bytes_cap() >>> 0;
    if (input.length > inputCap) {
      throw Error(`Decoded image exceeds ${label} component capacity: ${input.length} > ${inputCap} bytes.`);
    }
    new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length)
      .set(input);
    const started = performance.now();
    const renderResult = exports.render(input.length);
    if (typeof renderResult !== "bigint") throw TypeError("render must return i64");
    const renderBits = BigInt.asUintN(64, renderResult);
    if ((renderBits & (1n << 63n)) !== 0n) throw Error(`The ${label} component rejected the decoded image.`);
    const outputSize = Number(renderBits & 0xffff_ffffn);
    const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
    const elapsedMs = performance.now() - started;
    if (outputSize === 0) {
      throw Error(`The ${label} component rejected the decoded image.`);
    }
    if (outputSize > (exports.output_bytes_cap() >>> 0)) {
      throw Error(`The ${label} component returned output beyond its declared capacity.`);
    }
    const output = new Uint8Array(
      exports.memory.buffer,
      outputPointer,
      outputSize,
    ).slice();
    self.postMessage({
      type: "done",
      output: output.buffer,
      elapsedMs,
    }, [output.buffer]);
  } catch (error) {
    self.postMessage({
      type: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  } finally {
    self.close();
  }
};
