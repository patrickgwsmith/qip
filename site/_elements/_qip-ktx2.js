// KTX2 container parsing, color profiles (sRGB8, Display P3 RGBA32F
// linear/transfer), conversions, and canvas presentation creation.
// Useful for Content components as well as Interactive hosts.
// Extracted from qip-play.js so other hosts (qip-edit, external
// integrations) can share it. Served at /elements/ alongside the elements.

const QIP_PLAY_KTX2_IDENTIFIER = [
  0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a,
];
const QIP_PLAY_KTX2_RGBA8_SRGB_DFD = [
  0x5c, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x58, 0, 1, 1, 2, 0,
  0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
  8, 0, 7, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
  0x10, 0, 7, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
  0x18, 0, 7, 0x1f, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0, 0, 0,
];
const QIP_PLAY_KTX2_RGBA32F_DISPLAY_P3_LINEAR_DFD = [
  0x5c, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x58, 0, 1, 12, 1, 0,
  0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0x1f, 0xc0, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
  0x20, 0, 0x1f, 0xc1, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
  0x40, 0, 0x1f, 0xc2, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
  0x60, 0, 0x1f, 0xcf, 0, 0, 0, 0, 0, 0, 0x80, 0xbf, 0, 0, 0x80, 0x3f,
];
const QIP_PLAY_KTX2_RGBA32F_DISPLAY_P3_DFD = [
  ...QIP_PLAY_KTX2_RGBA32F_DISPLAY_P3_LINEAR_DFD,
];
QIP_PLAY_KTX2_RGBA32F_DISPLAY_P3_DFD[14] = 2;
const QIP_PLAY_KTX2_KVD = [
  0x12, 0, 0, 0, 0x4b, 0x54, 0x58, 0x6f, 0x72, 0x69, 0x65, 0x6e,
  0x74, 0x61, 0x74, 0x69, 0x6f, 0x6e, 0, 0x72, 0x64, 0, 0, 0,
];

function qipPlayMatchesBytes(bytes, offset, expected) {
  if (offset < 0 || offset + expected.length > bytes.length) return false;
  for (let i = 0; i < expected.length; i++) {
    if (bytes[offset + i] !== expected[i]) return false;
  }
  return true;
}

function qipPlayParseKTX2(bytes) {
  if (bytes.length < 224 || !qipPlayMatchesBytes(bytes, 0, QIP_PLAY_KTX2_IDENTIFIER)) {
    throw new Error("qip-play Timed output is not canonical KTX2");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const u32 = (offset) => view.getUint32(offset, true);
  const u64 = (offset) => {
    const value = view.getBigUint64(offset, true);
    if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error("qip-play KTX2 field exceeds JavaScript's safe integer range");
    }
    return Number(value);
  };
  const width = u32(20);
  const height = u32(24);
  const vkFormat = u32(12);
  const typeSize = u32(16);
  let bytesPerPixel;
  let dfd;
  let profile;
  if (vkFormat === 43 && typeSize === 1) {
    bytesPerPixel = 4;
    dfd = QIP_PLAY_KTX2_RGBA8_SRGB_DFD;
    profile = {
      pixelFormat: "rgba-unorm8",
      colorSpace: "srgb",
    };
  } else if (vkFormat === 109 && typeSize === 4 && bytes[118] === 1) {
    bytesPerPixel = 16;
    dfd = QIP_PLAY_KTX2_RGBA32F_DISPLAY_P3_LINEAR_DFD;
    profile = {
      pixelFormat: "rgba-float32",
      colorSpace: "display-p3-linear",
    };
  } else if (vkFormat === 109 && typeSize === 4 && bytes[118] === 2) {
    bytesPerPixel = 16;
    dfd = QIP_PLAY_KTX2_RGBA32F_DISPLAY_P3_DFD;
    profile = {
      pixelFormat: "rgba-float32",
      colorSpace: "display-p3",
    };
  } else {
    throw new Error("qip-play Timed output uses an unsupported KTX2 pixel format");
  }
  const pixelBytes = width * height * bytesPerPixel;
  if (
    width === 0 || height === 0 ||
    u32(28) !== 0 || u32(32) !== 0 || u32(36) !== 1 || u32(40) !== 1 ||
    u32(44) !== 0 || u32(48) !== 104 || u32(52) !== dfd.length ||
    u32(56) !== 196 || u32(60) !== QIP_PLAY_KTX2_KVD.length ||
    u64(64) !== 0 || u64(72) !== 0 || u64(80) !== 224 ||
    u64(88) !== pixelBytes || u64(96) !== pixelBytes ||
    bytes.length !== 224 + pixelBytes ||
    !qipPlayMatchesBytes(bytes, 104, dfd) ||
    !qipPlayMatchesBytes(bytes, 196, QIP_PLAY_KTX2_KVD)
  ) {
    throw new Error("qip-play Timed output is outside a supported canonical KTX2 profile");
  }
  const payload = bytes.subarray(224);
  if (profile.pixelFormat === "rgba-float32") {
    // A multipart/related root can start at any offset; only then is the payload copied.
    const aligned = (payload.byteOffset & 3) === 0 ? payload : payload.slice();
    return {
      width,
      height,
      profile,
      sourceBytes: payload,
      pixels: new Float32Array(aligned.buffer, aligned.byteOffset, aligned.byteLength / 4),
    };
  }
  return { width, height, profile, sourceBytes: payload, pixels: payload };
}

function qipPlayProfileName(profile) {
  return profile.pixelFormat + " " + profile.colorSpace;
}

function qipPlayProfileKey(profile) {
  return profile.pixelFormat + ":" + profile.colorSpace;
}

function qipPlayLinearToTransfer(value) {
  const magnitude = Math.abs(value);
  if (magnitude <= 0.0031308) return value * 12.92;
  const encoded = 1.055 * Math.pow(magnitude, 1 / 2.4) - 0.055;
  return value < 0 ? -encoded : encoded;
}

function qipPlayTransferToLinear(value) {
  const magnitude = Math.abs(value);
  if (magnitude <= 0.04045) return value / 12.92;
  const linear = Math.pow((magnitude + 0.055) / 1.055, 2.4);
  return value < 0 ? -linear : linear;
}

function qipPlayLinearP3ToLinearSRGB(r, g, b) {
  return [
    1.224745 * r - 0.224904 * g,
    -0.042058 * r + 1.042081 * g,
    -0.019642 * r - 0.078655 * g + 1.098537 * b,
  ];
}

function qipPlayFloatToUNorm8(value) {
  const finite = Number.isFinite(value) ? value : 0;
  return Math.round(Math.min(1, Math.max(0, finite)) * 255);
}

function qipPlayToneMapLinear(value) {
  if (!Number.isFinite(value) || value <= 0) return 0;
  if (value <= 0.9) return value;
  return 0.9 + 0.1 * (1 - Math.exp(-(value - 0.9) / 0.5));
}

function qipPlayCopyLinearFloat16(destination, source) {
  destination.set(source);
}

function qipPlayCopyTransferFloat16(destination, source) {
  for (let i = 0; i < source.length; i += 4) {
    destination[i] = qipPlayLinearToTransfer(source[i]);
    destination[i + 1] = qipPlayLinearToTransfer(source[i + 1]);
    destination[i + 2] = qipPlayLinearToTransfer(source[i + 2]);
    destination[i + 3] = source[i + 3];
  }
}

function qipPlayCopyEncodedToLinearFloat16(destination, source) {
  for (let i = 0; i < source.length; i += 4) {
    destination[i] = qipPlayTransferToLinear(source[i]);
    destination[i + 1] = qipPlayTransferToLinear(source[i + 1]);
    destination[i + 2] = qipPlayTransferToLinear(source[i + 2]);
    destination[i + 3] = source[i + 3];
  }
}

function qipPlayCopyToneMappedP3(destination, source) {
  for (let i = 0; i < source.length; i += 4) {
    destination[i] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(qipPlayToneMapLinear(source[i])));
    destination[i + 1] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(qipPlayToneMapLinear(source[i + 1])));
    destination[i + 2] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(qipPlayToneMapLinear(source[i + 2])));
    destination[i + 3] = qipPlayFloatToUNorm8(source[i + 3]);
  }
}

function qipPlayCopyEncodedToneMappedP3(destination, source) {
  for (let i = 0; i < source.length; i += 4) {
    destination[i] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(qipPlayToneMapLinear(qipPlayTransferToLinear(source[i]))));
    destination[i + 1] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(qipPlayToneMapLinear(qipPlayTransferToLinear(source[i + 1]))));
    destination[i + 2] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(qipPlayToneMapLinear(qipPlayTransferToLinear(source[i + 2]))));
    destination[i + 3] = qipPlayFloatToUNorm8(source[i + 3]);
  }
}

function qipPlayCopyToneMappedSRGB(destination, source) {
  for (let i = 0; i < source.length; i += 4) {
    const rgb = qipPlayLinearP3ToLinearSRGB(
      qipPlayToneMapLinear(source[i]),
      qipPlayToneMapLinear(source[i + 1]),
      qipPlayToneMapLinear(source[i + 2]),
    );
    destination[i] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(rgb[0]));
    destination[i + 1] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(rgb[1]));
    destination[i + 2] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(rgb[2]));
    destination[i + 3] = qipPlayFloatToUNorm8(source[i + 3]);
  }
}

function qipPlayCopyEncodedToneMappedSRGB(destination, source) {
  for (let i = 0; i < source.length; i += 4) {
    const rgb = qipPlayLinearP3ToLinearSRGB(
      qipPlayToneMapLinear(qipPlayTransferToLinear(source[i])),
      qipPlayToneMapLinear(qipPlayTransferToLinear(source[i + 1])),
      qipPlayToneMapLinear(qipPlayTransferToLinear(source[i + 2])),
    );
    destination[i] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(rgb[0]));
    destination[i + 1] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(rgb[1]));
    destination[i + 2] = qipPlayFloatToUNorm8(qipPlayLinearToTransfer(rgb[2]));
    destination[i + 3] = qipPlayFloatToUNorm8(source[i + 3]);
  }
}

function qipPlayTryHDRPresentation(parsed, colorSpace, convert) {
  if (typeof globalThis.Float16Array !== "function") return null;
  const canvas = document.createElement("canvas");
  canvas.width = parsed.width;
  canvas.height = parsed.height;
  let ctx;
  try {
    ctx = canvas.getContext("2d", {
      alpha: true,
      desynchronized: true,
      colorSpace,
      colorType: "float16",
    });
  } catch {
    return null;
  }
  if (!ctx) return null;
  const attributes = typeof ctx.getContextAttributes === "function"
    ? ctx.getContextAttributes()
    : null;
  if (!attributes || attributes.colorSpace !== colorSpace || attributes.colorType !== "float16") {
    return null;
  }
  let imageData;
  try {
    imageData = ctx.createImageData(parsed.width, parsed.height, {
      colorSpace,
      pixelFormat: "rgba-float16",
    });
  } catch {
    return null;
  }
  if (!(imageData.data instanceof globalThis.Float16Array)) return null;
  return {
    canvas,
    ctx,
    imageData,
    convert,
    canvasProfile: { pixelFormat: "rgba-float16", colorSpace },
  };
}

function qipPlayTryUNormPresentation(parsed, colorSpace, convert) {
  const canvas = document.createElement("canvas");
  canvas.width = parsed.width;
  canvas.height = parsed.height;
  let ctx;
  try {
    ctx = canvas.getContext("2d", {
      alpha: true,
      desynchronized: true,
      colorSpace,
    });
  } catch {
    return null;
  }
  if (!ctx) return null;
  if (colorSpace !== "srgb" && typeof ctx.getContextAttributes === "function") {
    if (ctx.getContextAttributes().colorSpace !== colorSpace) return null;
  }
  let imageData;
  try {
    imageData = ctx.createImageData(parsed.width, parsed.height, { colorSpace });
  } catch {
    if (colorSpace !== "srgb") return null;
    try {
      imageData = ctx.createImageData(parsed.width, parsed.height);
    } catch {
      return null;
    }
  }
  if (!(imageData.data instanceof Uint8ClampedArray)) return null;
  return {
    canvas,
    ctx,
    imageData,
    convert,
    canvasProfile: { pixelFormat: "rgba-unorm8", colorSpace },
  };
}

function qipPlayCreatePresentation(parsed) {
  if (parsed.profile.pixelFormat === "rgba-unorm8" && parsed.profile.colorSpace === "srgb") {
    const presentation = qipPlayTryUNormPresentation(
      parsed,
      "srgb",
      (destination, source) => destination.set(source),
    );
    if (!presentation) throw new Error("2D canvas context is unavailable");
    return presentation;
  }

  if (parsed.profile.pixelFormat === "rgba-float32" && parsed.profile.colorSpace === "display-p3") {
    return qipPlayTryHDRPresentation(
      parsed,
      "display-p3",
      qipPlayCopyLinearFloat16,
    ) || qipPlayTryHDRPresentation(
      parsed,
      "display-p3-linear",
      qipPlayCopyEncodedToLinearFloat16,
    ) || qipPlayTryUNormPresentation(
      parsed,
      "display-p3",
      qipPlayCopyEncodedToneMappedP3,
    ) || qipPlayTryUNormPresentation(
      parsed,
      "srgb",
      qipPlayCopyEncodedToneMappedSRGB,
    ) || (() => {
      throw new Error("2D canvas context is unavailable");
    })();
  }

  return qipPlayTryHDRPresentation(
    parsed,
    "display-p3-linear",
    qipPlayCopyLinearFloat16,
  ) || qipPlayTryHDRPresentation(
    parsed,
    "display-p3",
    qipPlayCopyTransferFloat16,
  ) || qipPlayTryUNormPresentation(
    parsed,
    "display-p3",
    qipPlayCopyToneMappedP3,
  ) || qipPlayTryUNormPresentation(
    parsed,
    "srgb",
    qipPlayCopyToneMappedSRGB,
  ) || (() => {
    throw new Error("2D canvas context is unavailable");
  })();
}


export {
  qipPlayParseKTX2 as parseKTX2,
  qipPlayProfileName as profileName,
  qipPlayProfileKey as profileKey,
  qipPlayCreatePresentation as createPresentation,
};
