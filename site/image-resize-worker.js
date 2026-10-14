const DECODER_PATHS = {
  avif: "/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm",
  jpeg: "/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm",
  png: "/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
  webp: "/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm",
};

const RESIZE_PATHS = {
  down: {
    paths: [
      "/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm",
      "/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm",
    ],
    algorithm: "Lanczos3 reduction",
  },
  up: {
    paths: [
      "/image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.wasm",
      "/image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm",
    ],
    algorithm: "Mitchell-Netravali enlargement",
  },
};

const ENCODERS = {
  jpeg: {
    path: "/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm",
    contentType: "image/jpeg",
    extension: "jpg",
    label: "JPEG",
    lossy: true,
  },
  png: {
    path: "/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm",
    contentType: "image/png",
    extension: "png",
    label: "PNG",
    lossy: false,
  },
  "webp-lossless": {
    path: "/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm",
    contentType: "image/webp",
    extension: "webp",
    label: "WebP lossless",
    lossy: false,
  },
  "webp-lossy": {
    path: "/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm",
    contentType: "image/webp",
    extension: "webp",
    label: "WebP lossy",
    lossy: true,
  },
};

const compiledModules = new Map();
const compiledChoices = new Map();

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

async function compile(path) {
  let pending = compiledModules.get(path);
  if (pending === undefined) {
    pending = WebAssembly.compileStreaming(fetch(path));
    compiledModules.set(path, pending);
  }
  try {
    return await pending;
  } catch (error) {
    compiledModules.delete(path);
    throw error;
  }
}

async function compileFirst(paths) {
  let pending = compiledChoices.get(paths);
  if (pending === undefined) {
    pending = (async () => {
      let lastError;
      for (const path of paths) {
        try {
          return { module: await compile(path), path };
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError;
    })();
    compiledChoices.set(paths, pending);
  }
  try {
    return await pending;
  } catch (error) {
    compiledChoices.delete(paths);
    throw error;
  }
}

// A uniform's setter is uniform_set_<key>, optionally followed by "__" and a
// suffix that declares the uniform's maxima.
function uniformSetter(exports, key) {
  const names = Object.keys(exports).filter((name) => name === `uniform_set_${key}` || name.startsWith(`uniform_set_${key}__`));
  if (names.length > 1) throw Error(`Component exports both ${names[0]} and ${names[1]} for uniform ${key}.`);
  return exports[names[0]];
}

function run(module, input, uniforms = {}) {
  const exports = new WebAssembly.Instance(module, {}).exports;
  exports._initialize?.();
  const inputCapacity = exports.input_bytes_cap() >>> 0;
  if (input.byteLength > inputCapacity) {
    throw Error(`Input exceeds component capacity: ${input.byteLength} > ${inputCapacity} bytes.`);
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.byteLength).set(input);
  for (const [key, value] of Object.entries(uniforms).sort(([a], [b]) => a.localeCompare(b))) {
    const setter = uniformSetter(exports, key);
    if (typeof setter !== "function") throw Error(`Component does not accept the ${key} uniform.`);
    setter(value);
  }

  const packed = exports.render(input.byteLength);
  if (typeof packed !== "bigint") throw TypeError("render must return i64");
  const bits = BigInt.asUintN(64, packed);
  const value = Number(bits & 0xffff_ffffn);
  if ((bits & (1n << 63n)) !== 0n) {
    if (typeof exports.failure_modes_per_input_offset !== "function") {
      throw Error("Component rejected input without declaring failure behavior.");
    }
    return { status: "rejected" };
  }
  const outputCapacity = exports.output_bytes_cap() >>> 0;
  if (value > outputCapacity) throw Error("Component output exceeds its declared capacity.");
  const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
  const outputEnd = outputPointer + value;
  if (outputEnd > exports.memory.buffer.byteLength) throw Error("Component output exceeds Wasm memory.");
  return {
    status: "accepted",
    output: new Uint8Array(exports.memory.buffer, outputPointer, value).slice(),
  };
}

function readKTX2Size(bytes) {
  if (bytes.byteLength < 224) throw Error("The decoder returned a truncated KTX2 image.");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: view.getUint32(20, true), height: view.getUint32(24, true) };
}

function calculateDimensions(width, height, maxWidth, maxHeight, enlarge) {
  if (![width, height, maxWidth, maxHeight].every(Number.isInteger) ||
      width < 1 || height < 1 || maxWidth < 1 || maxHeight < 1) {
    throw Error("Image and maximum dimensions must be positive integers.");
  }
  const scale = Math.min(maxWidth / width, maxHeight / height, enlarge ? Infinity : 1);
  return {
    width: Math.max(1, Math.floor(width * scale)),
    height: Math.max(1, Math.floor(height * scale)),
  };
}

async function resize(input, source, target) {
  if (source.width === target.width && source.height === target.height) {
    return { output: input, algorithm: "No resize" };
  }
  const direction = target.width <= source.width && target.height <= source.height
    ? "down"
    : "up";
  const candidate = RESIZE_PATHS[direction];
  const compiled = await compileFirst(candidate.paths);
  const result = run(compiled.module, input, target);
  if (result.status !== "accepted") {
    throw Error(`${candidate.algorithm} rejected the calculated dimensions.`);
  }
  const simd = compiled.path.endsWith("-simd.wasm") ? " (SIMD)" : "";
  return { output: result.output, algorithm: `${candidate.algorithm}${simd}` };
}

self.onmessage = async (event) => {
  const { id, format, input, maxWidth, maxHeight, enlarge, outputFormat, quality } = event.data;
  try {
    const decoderPath = DECODER_PATHS[format];
    if (!decoderPath) throw Error("Choose a supported JPEG, PNG, WebP, or AVIF image.");
    const encoder = ENCODERS[outputFormat];
    if (!encoder) throw Error("Choose PNG, JPEG, WebP lossy, or WebP lossless output.");
    if (!Number.isInteger(maxWidth) || !Number.isInteger(maxHeight) ||
        maxWidth < 1 || maxHeight < 1 || maxWidth > 8192 || maxHeight > 8192) {
      throw Error("Maximum width and height must be integers from 1 through 8192.");
    }
    if (encoder.lossy && (!Number.isInteger(quality) || quality < 1 || quality > 100)) {
      throw Error("Quality must be an integer from 1 through 100.");
    }

    const started = performance.now();
    const decoded = run(await compile(decoderPath), new Uint8Array(input));
    if (decoded.status !== "accepted") throw Error("The decoder rejected the image.");
    const source = readKTX2Size(decoded.output);
    const target = calculateDimensions(source.width, source.height, maxWidth, maxHeight, enlarge);
    if (target.width > 8192 || target.height > 8192 || target.width * target.height > 25_000_000) {
      throw Error("Output exceeds the 8192-pixel edge or 25-megapixel limit.");
    }
    const resized = await resize(decoded.output, source, target);
    const uniforms = encoder.lossy ? { quality } : {};
    const encoded = run(await compile(encoder.path), resized.output, uniforms);
    if (encoded.status !== "accepted") throw Error(`The ${encoder.label} encoder rejected the image.`);
    self.postMessage({
      type: "done",
      id,
      output: encoded.output.buffer,
      sourceWidth: source.width,
      sourceHeight: source.height,
      width: target.width,
      height: target.height,
      algorithm: resized.algorithm,
      contentType: encoder.contentType,
      extension: encoder.extension,
      elapsedMs: performance.now() - started,
    }, [encoded.output.buffer]);
  } catch (error) {
    self.postMessage({ type: "error", id, message: errorMessage(error) });
  }
};
