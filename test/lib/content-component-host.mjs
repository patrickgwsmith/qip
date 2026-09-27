const utf8Decoder = new TextDecoder("utf-8", { fatal: true });
const utf8Encoder = new TextEncoder();
const lastOutputPointers = new WeakMap();

export function decodeRenderResult(value) {
  if (typeof value !== "bigint") throw new TypeError("render must return i64");
  const bits = BigInt.asUintN(64, value);
  return Object.freeze({
    failed: (bits & (1n << 63n)) !== 0n,
    value: Number(bits & 0xffff_ffffn),
    outputPointer: Number((bits >> 32n) & 0x7fff_ffffn),
  });
}

export function renderSize(exports, inputSize) {
  const result = decodeRenderResult(exports.render(inputSize));
  if (result.failed) {
    const error = new Error("rejected input");
    error.failureDetail = result.value;
    throw error;
  }
  lastOutputPointers.set(exports, result.outputPointer);
  return result.value;
}

export function renderedOutputPointer(exports) {
  const pointer = lastOutputPointers.get(exports);
  if (pointer === undefined) throw new Error("render has not returned output");
  return pointer;
}

export class ContentRenderTrap extends Error {
  constructor(label, cause) {
    super(`${label} render trapped: ${cause?.message ?? cause}`);
    this.name = "ContentRenderTrap";
    this.cause = cause;
  }
}

export class ContentUniformTrap extends Error {
  constructor(label, key, cause) {
    super(`${label} uniform_set_${key} trapped: ${cause?.message ?? cause}`);
    this.name = "ContentUniformTrap";
    this.cause = cause;
  }
}

export class ContentComponentHost {
  constructor(wasmBytes, { label = "component" } = {}) {
    this.label = label;
    this.module = new WebAssembly.Module(wasmBytes);
    this.instance = null;
    this.instanceCount = 0;
  }

  instantiate() {
    this.instance = new WebAssembly.Instance(this.module);
    this.instanceCount += 1;
    return this.instance;
  }

  discard() {
    this.instance = null;
  }

  run(input, { uniforms = {} } = {}) {
    const instance = this.instance ?? this.instantiate();
    const exports = instance.exports;
    const inputBytes = typeof input === "string" ? utf8Encoder.encode(input) : new Uint8Array(input);
    const hasInputUTF8 = typeof exports.input_utf8_cap === "function";
    const hasInputBytes = typeof exports.input_bytes_cap === "function";
    if (hasInputUTF8 === hasInputBytes) {
      throw new TypeError(`${this.label} must export exactly one input capacity`);
    }
    if (hasInputUTF8 && typeof input !== "string") utf8Decoder.decode(inputBytes);

    const inputCapacity = Number((hasInputUTF8 ? exports.input_utf8_cap : exports.input_bytes_cap)()) >>> 0;
    const inputPointer = Number(exports.input_ptr()) >>> 0;
    if (inputBytes.byteLength > inputCapacity || inputPointer + inputBytes.byteLength > exports.memory.buffer.byteLength) {
      throw new RangeError(`${this.label} input exceeds its capacity`);
    }
    new Uint8Array(exports.memory.buffer, inputPointer, inputBytes.byteLength).set(inputBytes);

    for (const key of Object.keys(uniforms).sort()) {
      const setter = exports[`uniform_set_${key}`];
      if (typeof setter !== "function") throw new TypeError(`${this.label} does not export uniform_set_${key}`);
      try {
        setter(uniforms[key]);
      } catch (error) {
        this.discard();
        throw new ContentUniformTrap(this.label, key, error);
      }
    }

    let renderResult;
    try {
      renderResult = exports.render(inputBytes.byteLength);
    } catch (error) {
      this.discard();
      throw new ContentRenderTrap(this.label, error);
    }

    if (typeof renderResult !== "bigint") {
      this.discard();
      throw new TypeError(`${this.label} render export must have signature render(i32) -> i64`);
    }
    const bits = BigInt.asUintN(64, renderResult);
    const detail = Number(bits & 0xffff_ffffn);
    if ((bits & (1n << 63n)) !== 0n) {
      if (typeof exports.failure_modes_per_input_offset !== "function") {
        this.discard();
        throw new TypeError(`${this.label} returned failure without exporting failure_modes_per_input_offset`);
      }
      const modes = Number(exports.failure_modes_per_input_offset()) >>> 0;
      return Object.freeze({
        status: "rejected",
        detail,
        inputOffset: modes === 0 ? undefined : Math.floor(detail / modes),
        failureMode: modes === 0 ? undefined : detail % modes,
      });
    }

    const outputSize = detail;

    const hasOutputUTF8 = typeof exports.output_utf8_cap === "function";
    const hasOutputBytes = typeof exports.output_bytes_cap === "function";
    if (hasOutputUTF8 === hasOutputBytes) throw new TypeError(`${this.label} must export exactly one output capacity`);
    const outputCapacity = Number((hasOutputUTF8 ? exports.output_utf8_cap : exports.output_bytes_cap)()) >>> 0;
    const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
    if (outputSize > outputCapacity || outputPointer + outputSize > exports.memory.buffer.byteLength) {
      this.discard();
      throw new RangeError(`${this.label} returned output outside its declared capacity`);
    }
    const output = new Uint8Array(exports.memory.buffer, outputPointer, outputSize).slice();
    if (hasOutputUTF8) {
      try {
        utf8Decoder.decode(output);
      } catch (error) {
        this.discard();
        throw new TypeError(`${this.label} returned malformed output despite output_utf8_cap: ${error.message}`);
      }
    }
    return Object.freeze({ status: "accepted", output, outputIsUTF8: hasOutputUTF8 });
  }
}
