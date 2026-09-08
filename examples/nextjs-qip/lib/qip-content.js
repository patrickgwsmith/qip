const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function decodeRenderResult(value) {
  const bits = BigInt.asUintN(64, value);
  if ((bits >> 63n) !== 0n) {
    throw new Error("component rejected input");
  }

  return {
    outputPtr: Number((bits >> 32n) & 0x7fff_ffffn),
    outputSize: Number(bits & 0xffff_ffffn),
  };
}

export function createTextRenderer(exports) {
  const { memory, input_ptr, input_utf8_cap, render } = exports;

  if (
    !(memory instanceof WebAssembly.Memory) ||
    typeof input_ptr !== "function" ||
    typeof input_utf8_cap !== "function" ||
    typeof render !== "function"
  ) {
    throw new TypeError("module does not provide the QIP UTF-8 Content contract");
  }

  return function renderText(source) {
    const input = new Uint8Array(
      memory.buffer,
      input_ptr(),
      input_utf8_cap(),
    );
    const { read, written } = encoder.encodeInto(source, input);

    if (read !== source.length) {
      throw new RangeError("input exceeds component capacity");
    }

    const { outputPtr, outputSize } = decodeRenderResult(render(written));
    return decoder.decode(
      new Uint8Array(memory.buffer, outputPtr, outputSize),
    );
  };
}
