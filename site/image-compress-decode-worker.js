const DECODER_PATHS = {
  avif: [
    "/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm",
  ],
  jpeg: [
    "/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm",
  ],
  png: [
    "/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
  ],
  webp: [
    "/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm",
  ],
};
const KTX2_HEADER_SIZE = 224;
const KTX2_IDENTIFIER = [0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a];
const VK_FORMAT_R8G8B8A8_SRGB = 43;

function decoderError(error) {
  return error instanceof Error ? error.message : String(error);
}

async function compileDecoder(format) {
  let lastError = null;
  for (const path of DECODER_PATHS[format]) {
    try {
      const module = await WebAssembly.compileStreaming(fetch(path));
      return { module, path };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || Error(`No decoder is available for ${format}.`);
}

function readKTX2Metadata(bytes) {
  if (
    bytes.length < KTX2_HEADER_SIZE ||
    KTX2_IDENTIFIER.some((byte, index) => bytes[index] !== byte)
  ) {
    throw Error("The decoder did not return a KTX2 image.");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const width = view.getUint32(20, true);
  const height = view.getUint32(24, true);
  if (view.getUint32(12, true) !== VK_FORMAT_R8G8B8A8_SRGB || width === 0 || height === 0) {
    throw Error("The decoder returned an unsupported KTX2 layout.");
  }
  const pixelBytes = width * height * 4;
  if (KTX2_HEADER_SIZE + pixelBytes !== bytes.length) {
    throw Error("The decoder returned a truncated KTX2 image.");
  }
  let hasAlpha = false;
  for (let offset = KTX2_HEADER_SIZE + 3; offset < bytes.length; offset += 4) {
    if (bytes[offset] !== 255) {
      hasAlpha = true;
      break;
    }
  }
  return { width, height, pixels: width * height, hasAlpha };
}

function run(exports, input) {
  const inputCap = exports.input_bytes_cap() >>> 0;
  if (input.length > inputCap) {
    throw Error(`Input exceeds decoder capacity: ${input.length} > ${inputCap} bytes.`);
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length)
    .set(input);
  const renderResult = exports.render(input.length);
  if (typeof renderResult !== "bigint") throw TypeError("render must return i64");
  const renderBits = BigInt.asUintN(64, renderResult);
  if ((renderBits & (1n << 63n)) !== 0n) throw Error("The decoder rejected the image.");
  const outputSize = Number(renderBits & 0xffff_ffffn);
  const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
  if (outputSize === 0) {
    throw Error("The decoder rejected the image or exceeded its fixed output capacity.");
  }
  if (outputSize > (exports.output_bytes_cap() >>> 0)) {
    throw Error("The decoder returned output beyond its declared capacity.");
  }
  return new Uint8Array(
    exports.memory.buffer,
    outputPointer,
    outputSize,
  ).slice();
}

self.onmessage = async (event) => {
  try {
    const { format, input } = event.data;
    if (!DECODER_PATHS[format]) throw Error("Choose a JPEG, PNG, WebP or AVIF image.");
    const inputBytes = new Uint8Array(input);
    const { module, path } = await compileDecoder(format);
    const { exports } = new WebAssembly.Instance(module, {});
    exports._initialize?.();
    const started = performance.now();
    const ktx2 = run(exports, inputBytes);
    const metadata = readKTX2Metadata(ktx2);
    self.postMessage({
      type: "done",
      output: ktx2.buffer,
      ...metadata,
      decoderPath: path,
      elapsedMs: performance.now() - started,
    }, [ktx2.buffer]);
  } catch (error) {
    self.postMessage({ type: "error", message: decoderError(error) });
  } finally {
    self.close();
  }
};
