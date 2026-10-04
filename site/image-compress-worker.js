const CODEC_CONFIG = {
  webp: {
    modulePath(hasAlpha) {
      return hasAlpha
        ? "/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm"
        : "/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm";
    },
  },
  avif: {
    modulePath() {
      return "/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm";
    },
  },
  jpeg: {
    modulePath() {
      return "/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm";
    },
  },
};

let codec = null;
let inputBytes = null;
let exports = null;
let queue = [];
let running = false;

function message(error) {
  return error instanceof Error ? error.message : String(error);
}

function setUniforms(quality) {
  if (codec === "webp") {
    exports.uniform_set_quality(quality);
    exports.uniform_set_method(4);
    exports.uniform_set_sharp_yuv(1);
    exports.uniform_set_low_memory(1);
  } else if (codec === "avif") {
    exports.uniform_set_quality(quality);
    exports.uniform_set_quality_alpha(100);
    exports.uniform_set_speed(8);
    exports.uniform_set_subsample(0);
  } else {
    exports.uniform_set_quality(quality);
    exports.uniform_set_subsample(2);
    exports.uniform_set_background_color_rgb(0xffffff);
  }
}

async function initialize(data) {
  codec = data.codec;
  const config = CODEC_CONFIG[codec];
  if (!config) throw Error("Unknown image codec.");
  inputBytes = new Uint8Array(data.input);
  const module = await WebAssembly.compileStreaming(
    fetch(config.modulePath(data.hasAlpha)),
  );
  ({ exports } = new WebAssembly.Instance(module, {}));
  exports._initialize?.();
  const inputCap = exports.input_bytes_cap() >>> 0;
  if (inputBytes.length > inputCap) {
    throw Error(`KTX2 image exceeds ${codec} input capacity: ${inputBytes.length} > ${inputCap} bytes.`);
  }
}

async function drain() {
  if (running) return;
  running = true;
  while (queue.length > 0) {
    const job = queue.shift();
    try {
      setUniforms(job.quality);
      const input = new Uint8Array(
        exports.memory.buffer,
        exports.input_ptr() >>> 0,
        inputBytes.length,
      );
      input.set(inputBytes);
      const renderResult = exports.render(inputBytes.length);
      if (typeof renderResult !== "bigint") throw TypeError("render must return i64");
      const renderBits = BigInt.asUintN(64, renderResult);
      if ((renderBits & (1n << 63n)) !== 0n) throw Error("The encoder rejected the image.");
      const outputSize = Number(renderBits & 0xffff_ffffn);
      const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
      if (outputSize === 0) {
        throw Error("The encoder rejected the image or exceeded its fixed output capacity.");
      }
      if (outputSize > (exports.output_bytes_cap() >>> 0)) {
        throw Error("The encoder returned output beyond its declared capacity.");
      }
      const output = new Uint8Array(
        exports.memory.buffer,
        outputPointer,
        outputSize,
      ).slice();
      self.postMessage({
        type: "result",
        id: job.id,
        codec,
        quality: job.quality,
        output: output.buffer,
      }, [output.buffer]);
    } catch (error) {
      self.postMessage({
        type: "job-error",
        id: job.id,
        codec,
        quality: job.quality,
        message: message(error),
      });
      queue = [];
      break;
    }
  }
  running = false;
}

self.onmessage = async (event) => {
  const data = event.data;
  if (data.type === "init") {
    try {
      await initialize(data);
      self.postMessage({ type: "ready", codec });
    } catch (error) {
      self.postMessage({ type: "error", codec: data.codec, message: message(error) });
      self.close();
    }
    return;
  }
  if (data.type === "encode") {
    queue.push({ id: data.id, quality: data.quality });
    await drain();
    return;
  }
  if (data.type === "close") {
    self.close();
  }
};
