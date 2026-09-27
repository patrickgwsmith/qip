const qipEditTextEncoder = new TextEncoder();
const qipEditTextDecoder = new TextDecoder("utf-8", { fatal: true });

function qipEditNowMS() {
  if (typeof performance !== "undefined" && typeof performance.now === "function") {
    return performance.now();
  }
  return Date.now();
}

function qipEditFormatByteSize(byteLength) {
  if (byteLength < 1000) {
    return String(byteLength) + " B";
  }
  const kilobytes = byteLength / 1000;
  if (kilobytes < 100) {
    return kilobytes.toFixed(1) + " kB";
  }
  if (kilobytes < 1000) {
    return kilobytes.toFixed(0) + " kB";
  }
  const megabytes = kilobytes / 1000;
  if (megabytes < 100) {
    return megabytes.toFixed(1) + " MB";
  }
  return megabytes.toFixed(0) + " MB";
}

function qipEditFormatMS(ms) {
  return ms.toFixed(1) + " ms";
}

const QIP_EDIT_WASM_PAGE_SIZE_BYTES = 65536;
const QIP_EDIT_OPCODE_MEMORY_GROW = 0x40;

class QIPEditWasmReader {
  constructor(bytes) {
    this.bytes = bytes;
    this.off = 0;
  }

  remaining() {
    return this.bytes.length - this.off;
  }

  readByte() {
    if (this.off >= this.bytes.length) {
      throw new Error("unexpected end of wasm");
    }
    return this.bytes[this.off++];
  }

  peekByte() {
    if (this.off >= this.bytes.length) {
      throw new Error("unexpected end of wasm");
    }
    return this.bytes[this.off];
  }

  readBytes(count) {
    if (count < 0 || this.remaining() < count) {
      throw new Error("unexpected end of wasm");
    }
    const start = this.off;
    this.off += count;
    return this.bytes.subarray(start, this.off);
  }

  readVarU32() {
    let result = 0;
    let shift = 0;
    for (let i = 0; i < 5; i++) {
      const b = this.readByte();
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) {
        return result >>> 0;
      }
      shift += 7;
    }
    throw new Error("invalid u32 leb128");
  }

  readVarU64Number() {
    let result = 0;
    let factor = 1;
    let finite = true;
    for (let i = 0; i < 10; i++) {
      const b = this.readByte();
      if (finite) {
        result += (b & 0x7f) * factor;
      }
      if ((b & 0x80) === 0) {
        return finite ? result : Number.POSITIVE_INFINITY;
      }
      if (factor > Number.MAX_SAFE_INTEGER / 128) {
        finite = false;
      } else {
        factor *= 128;
      }
    }
    throw new Error("invalid u64 leb128");
  }

  readVarS32() {
    let result = 0;
    let shift = 0;
    let b = 0;
    for (let i = 0; i < 5; i++) {
      b = this.readByte();
      result |= (b & 0x7f) << shift;
      shift += 7;
      if ((b & 0x80) === 0) {
        break;
      }
      if (i === 4) {
        throw new Error("invalid s32 leb128");
      }
    }
    if (shift < 32 && (b & 0x40) !== 0) {
      result |= (~0 << shift);
    }
    return result | 0;
  }

  readVarS64(maxBytes) {
    for (let i = 0; i < maxBytes; i++) {
      const b = this.readByte();
      if ((b & 0x80) === 0) {
        return;
      }
    }
    throw new Error("invalid s64 leb128");
  }

  readName() {
    const len = this.readVarU32();
    const bytes = this.readBytes(len);
    return qipEditTextDecoder.decode(bytes);
  }
}

function qipEditReadModulePolicy(rootElement) {
  const maxMemoryRaw = rootElement.getAttribute("max-memory");
  const maxMemoryBytes = maxMemoryRaw === null ? 0 : qipEditParsePolicyBytes(maxMemoryRaw, "max-memory");
  const allowMemoryGrow = rootElement.hasAttribute("allow-memory-grow");
  if (allowMemoryGrow && maxMemoryBytes === 0) {
    throw new Error("allow-memory-grow requires max-memory=\"<bytes>\"");
  }
  const rejectOpcodes = allowMemoryGrow ? [] : [QIP_EDIT_OPCODE_MEMORY_GROW];
  return { maxMemoryBytes, rejectOpcodes };
}

function qipEditParsePolicyBytes(rawValue, attrName) {
  const value = String(rawValue).trim();
  if (!/^\d+$/.test(value)) {
    throw new Error(attrName + " must be an integer byte count");
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(attrName + " is outside the supported integer range");
  }
  return parsed;
}

function qipEditValidateWasmModulePolicy(moduleBytes, policy, label) {
  if (!policy || (policy.maxMemoryBytes === 0 && policy.rejectOpcodes.length === 0)) {
    return;
  }
  const failures = [];
  const rejectMemoryGrow = policy.rejectOpcodes.includes(QIP_EDIT_OPCODE_MEMORY_GROW);
  const bytes = new Uint8Array(moduleBytes);
  if (
    bytes.length < 8 ||
    bytes[0] !== 0x00 ||
    bytes[1] !== 0x61 ||
    bytes[2] !== 0x73 ||
    bytes[3] !== 0x6d ||
    bytes[4] !== 0x01 ||
    bytes[5] !== 0x00 ||
    bytes[6] !== 0x00 ||
    bytes[7] !== 0x00
  ) {
    throw new Error("invalid wasm module header");
  }

  const r = new QIPEditWasmReader(bytes.subarray(8));
  let memoryIndex = 0;
  while (r.remaining() > 0) {
    const sectionID = r.readByte();
    const sectionSize = r.readVarU32();
    const payload = r.readBytes(sectionSize);
    const section = new QIPEditWasmReader(payload);
    if (sectionID === 2) {
      memoryIndex = qipEditScanImportSectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 5) {
      memoryIndex = qipEditScanMemorySectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 10 && rejectMemoryGrow) {
      qipEditScanCodeSectionForPolicy(section, failures);
    }
  }

  if (failures.length > 0) {
    throw new Error("module " + label + " rejected by policy: " + failures.join("; "));
  }
}

function qipEditScanImportSectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    r.readName();
    r.readName();
    const kind = r.readByte();
    if (kind === 0x00) {
      r.readVarU32();
    } else if (kind === 0x01) {
      qipEditSkipTableType(r);
    } else if (kind === 0x02) {
      const limit = qipEditReadLimits(r);
      qipEditCheckMemoryLimit(limit, memoryIndex, policy, failures);
      memoryIndex++;
    } else if (kind === 0x03) {
      qipEditSkipGlobalType(r);
    } else if (kind === 0x04) {
      r.readByte();
      r.readVarU32();
    } else {
      throw new Error("unsupported wasm import kind 0x" + kind.toString(16));
    }
  }
  return memoryIndex;
}

function qipEditScanMemorySectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const limit = qipEditReadLimits(r);
    qipEditCheckMemoryLimit(limit, memoryIndex, policy, failures);
    memoryIndex++;
  }
  return memoryIndex;
}

function qipEditReadLimits(r) {
  const flags = r.readByte();
  const memory64 = (flags & 0x04) !== 0;
  const minPages = memory64 ? r.readVarU64Number() : r.readVarU32();
  let hasMax = false;
  let maxPages = 0;
  if ((flags & 0x01) !== 0) {
    hasMax = true;
    maxPages = memory64 ? r.readVarU64Number() : r.readVarU32();
  }
  return { minPages, hasMax, maxPages };
}

function qipEditCheckMemoryLimit(limit, memoryIndex, policy, failures) {
  if (policy.maxMemoryBytes === 0) {
    return;
  }
  if (qipEditPagesToBytes(limit.minPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] initial size " + String(limit.minPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
  if (!limit.hasMax) {
    failures.push("memory[" + memoryIndex + "] has no declared maximum");
    return;
  }
  if (qipEditPagesToBytes(limit.maxPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] maximum " + String(limit.maxPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
}

function qipEditPagesToBytes(pages) {
  if (!Number.isFinite(pages) || pages > Number.MAX_SAFE_INTEGER / QIP_EDIT_WASM_PAGE_SIZE_BYTES) {
    return Number.POSITIVE_INFINITY;
  }
  return pages * QIP_EDIT_WASM_PAGE_SIZE_BYTES;
}

function qipEditScanCodeSectionForPolicy(r, failures) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const bodySize = r.readVarU32();
    qipEditScanFunctionBodyForPolicy(new QIPEditWasmReader(r.readBytes(bodySize)), failures);
  }
}

function qipEditScanFunctionBodyForPolicy(r, failures) {
  const localDecls = r.readVarU32();
  for (let i = 0; i < localDecls; i++) {
    r.readVarU32();
    r.readByte();
  }
  while (r.remaining() > 0) {
    const op = r.readByte();
    switch (op) {
      case 0x00:
      case 0x01:
      case 0x05:
      case 0x0b:
      case 0x0f:
      case 0x1a:
      case 0x1b:
        break;
      case 0x02:
      case 0x03:
      case 0x04:
        qipEditReadBlockType(r);
        break;
      case 0x0c:
      case 0x0d:
      case 0x10:
      case 0x12:
      case 0x14:
      case 0xd2:
        r.readVarU32();
        break;
      case 0x0e: {
        const targetCount = r.readVarU32();
        for (let i = 0; i < targetCount; i++) r.readVarU32();
        r.readVarU32();
        break;
      }
      case 0x11:
      case 0x13:
        r.readVarU32();
        r.readVarU32();
        break;
      case 0x1c: {
        const count = r.readVarU32();
        r.readBytes(count);
        break;
      }
      case 0x20:
      case 0x21:
      case 0x22:
      case 0x23:
      case 0x24:
      case 0x25:
      case 0x26:
        r.readVarU32();
        break;
      case 0x28:
      case 0x29:
      case 0x2a:
      case 0x2b:
      case 0x2c:
      case 0x2d:
      case 0x2e:
      case 0x2f:
      case 0x30:
      case 0x31:
      case 0x32:
      case 0x33:
      case 0x34:
      case 0x35:
      case 0x36:
      case 0x37:
      case 0x38:
      case 0x39:
      case 0x3a:
      case 0x3b:
      case 0x3c:
      case 0x3d:
      case 0x3e:
        qipEditReadMemArg(r);
        break;
      case 0x3f:
        r.readVarU32();
        break;
      case 0x40:
        r.readVarU32();
        failures.push("violates fixed-memory policy: contains memory.grow");
        break;
      case 0x41:
        r.readVarS32();
        break;
      case 0x42:
        r.readVarS64(10);
        break;
      case 0x43:
        r.readBytes(4);
        break;
      case 0x44:
        r.readBytes(8);
        break;
      case 0xd0:
        r.readByte();
        break;
      case 0xfc:
        qipEditReadFCImmediate(r);
        break;
      case 0xfd:
        qipEditReadFDImmediate(r);
        break;
      case 0xfe:
        qipEditReadFEImmediate(r);
        break;
      default:
        break;
    }
  }
}

function qipEditReadBlockType(r) {
  const b = r.peekByte();
  if (b === 0x40 || b === 0x7f || b === 0x7e || b === 0x7d || b === 0x7c || b === 0x7b || b === 0x70 || b === 0x6f) {
    r.readByte();
    return;
  }
  r.readVarS64(5);
}

function qipEditReadMemArg(r) {
  r.readVarU32();
  r.readVarU32();
}

function qipEditReadFCImmediate(r) {
  const sub = r.readVarU32();
  if (sub === 8) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 9) {
    r.readVarU32();
  } else if (sub === 10) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 11) {
    r.readVarU32();
  } else if (sub === 12) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 13) {
    r.readVarU32();
  } else if (sub === 14) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 15 || sub === 16 || sub === 17) {
    r.readVarU32();
  }
}

function qipEditReadFDImmediate(r) {
  const sub = r.readVarU32();
  if (sub <= 11 || sub === 92 || sub === 93) {
    qipEditReadMemArg(r);
  } else if (sub === 12 || sub === 13) {
    r.readBytes(16);
  } else if (sub >= 21 && sub <= 34) {
    r.readByte();
  } else if (sub >= 84 && sub <= 91) {
    qipEditReadMemArg(r);
    r.readByte();
  }
}

function qipEditReadFEImmediate(r) {
  const sub = r.readVarU32();
  if (sub === 3) {
    r.readByte();
    return;
  }
  qipEditReadMemArg(r);
}

function qipEditSkipTableType(r) {
  r.readByte();
  qipEditReadLimits(r);
}

function qipEditSkipGlobalType(r) {
  r.readByte();
  r.readByte();
}

function qipEditToI32(value, label) {
  if (typeof value === "number") {
    return value | 0;
  }
  if (typeof value === "bigint") {
    const converted = Number(value);
    if (!Number.isFinite(converted)) {
      throw new Error(label + " returned non-finite numeric value");
    }
    return converted | 0;
  }
  throw new Error(label + " returned unsupported numeric value");
}

function qipEditReadI32Export(exportsObj, exportName) {
  const value = exportsObj[exportName];
  if (typeof value === "function") {
    return qipEditToI32(value(), exportName);
  }
  throw new Error("edit module must export " + exportName + "() -> i32");
}

function qipEditReadSlice(memory, ptr, len, label) {
  if (ptr < 0 || len < 0) {
    throw new Error(label + " returned negative pointer/size");
  }
  const start = ptr >>> 0;
  const size = len >>> 0;
  const end = start + size;
  if (end < start) {
    throw new Error(label + " exceeds wasm memory bounds");
  }
  const mem = new Uint8Array(memory.buffer);
  if (end > mem.length) {
    throw new Error(label + " exceeds wasm memory bounds");
  }
  return mem.slice(start, end);
}

function qipEditNormalizeContentType(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim().toLowerCase();
  if (trimmed === "") {
    return "";
  }
  const semi = trimmed.indexOf(";");
  if (semi === -1) {
    return trimmed;
  }
  return trimmed.slice(0, semi).trim();
}

function qipEditReadDeclaredContentType(exportsObj, ptrExport, sizeExport) {
  if (!(ptrExport in exportsObj) || !(sizeExport in exportsObj)) {
    return "";
  }
  const size = qipEditReadI32Export(exportsObj, sizeExport);
  if (size <= 0) {
    return "";
  }
  const ptr = qipEditReadI32Export(exportsObj, ptrExport);
  const bytes = qipEditReadSlice(exportsObj.memory, ptr, size, ptrExport + "/" + sizeExport);
  const text = qipEditTextDecoder.decode(bytes);
  return qipEditNormalizeContentType(text);
}

function qipEditParseUniformAttempts(rawValue) {
  const value = String(rawValue).trim();
  if (value === "") {
    throw new Error("uniform value must not be empty");
  }

  const parsedColor = qipEditParseColorInputValue(value);
  if (parsedColor !== null) {
    return [parsedColor, BigInt(parsedColor)];
  }

  if (/^[+-]?0x[0-9a-f]+$/i.test(value) || /^[+-]?\d+$/.test(value)) {
    const bigValue = BigInt(value);
    const numberValue = Number(bigValue);
    if (Number.isSafeInteger(numberValue)) {
      return [numberValue, bigValue];
    }
    return [bigValue];
  }

  const floatValue = Number(value);
  if (!Number.isFinite(floatValue)) {
    throw new Error("uniform value is not a finite number");
  }
  return [floatValue];
}

function qipEditApplyUniform(exportsObj, key, rawValue) {
  const setterName = "uniform_set_" + key;
  const setter = exportsObj[setterName];
  if (typeof setter !== "function") {
    throw new Error("edit module missing export " + setterName);
  }
  let attempts;
  try {
    attempts = qipEditParseUniformAttempts(rawValue);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error("qip-edit uniform parse error", {
      key,
      value: rawValue,
      valueType: typeof rawValue,
      error: detail,
    });
    throw err;
  }

  let lastErr = null;
  for (const value of attempts) {
    try {
      setter(value);
      return;
    } catch (err) {
      lastErr = err;
    }
  }

  const detail = lastErr instanceof Error ? lastErr.message : String(lastErr);
  console.error("qip-edit uniform set error", {
    key,
    value: rawValue,
    valueType: typeof rawValue,
    attempts: attempts.map((v) => typeof v === "bigint" ? (v.toString() + "n") : String(v)),
    error: detail,
  });
  throw new Error("failed to set uniform " + key + ": " + detail);
}

function qipEditIsTextContentType(contentType) {
  return contentType.startsWith("text/") ||
    contentType === "application/json" ||
    contentType === "application/javascript" ||
    contentType === "application/xml" ||
    contentType.endsWith("+json") ||
    contentType.endsWith("+xml");
}

function qipEditIsHTMLContentType(contentType) {
  return contentType === "text/html";
}

function qipEditGuessImageContentType(bytes) {
  if (bytes.length >= 8 &&
      bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
      bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) {
    return "image/png";
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (bytes.length >= 6 &&
      bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
      bytes[3] === 0x38 && (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61) {
    return "image/gif";
  }
  if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) {
    return "image/bmp";
  }
  if (bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x00 && bytes[2] === 0x01 && bytes[3] === 0x00) {
    return "image/x-icon";
  }
  if (bytes.length >= 12 &&
      bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
      bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    return "image/webp";
  }
  return "";
}

function qipEditGuessDisplayContentType(bytes, declared) {
  const normalized = qipEditNormalizeContentType(declared);
  if (normalized !== "") {
    return normalized;
  }
  const guessedImage = qipEditGuessImageContentType(bytes);
  if (guessedImage !== "") {
    return guessedImage;
  }
  try {
    qipEditTextDecoder.decode(bytes);
    return "text/plain";
  } catch (_) {
    return "";
  }
}

function qipEditFormatBinary(bytes) {
  const max = Math.min(bytes.length, 256);
  let hex = "";
  for (let i = 0; i < max; i += 1) {
    if (i > 0 && i % 16 === 0) {
      hex += "\n";
    } else if (i > 0) {
      hex += " ";
    }
    const value = bytes[i].toString(16).padStart(2, "0");
    hex += value;
  }
  if (bytes.length > max) {
    hex += "\n...";
  }
  return "Binary output (" + String(bytes.length) + " bytes)\n" + hex;
}

function qipEditExtractUniforms(sourceElement) {
  const pairs = [];
  const names = sourceElement.getAttributeNames();
  for (const attrName of names) {
    if (!attrName.startsWith("data-uniform-")) {
      continue;
    }
    const key = attrName.slice("data-uniform-".length).trim();
    if (key === "") {
      continue;
    }
    const rawValue = sourceElement.getAttribute(attrName);
    if (rawValue === null) {
      continue;
    }
    const trimmed = rawValue.trim();
    if (trimmed !== "") {
      pairs.push({
        key,
        staticValue: rawValue,
        inputElement: null,
      });
      continue;
    }
    const inputElement = qipEditFindUniformInputElement(sourceElement, key);
    if (!inputElement) {
      throw new Error(
        "<source> uniform " + key + " requires an input with name=\"uniform-" + key + "\" in the same <qip-edit> when " + attrName + " is empty",
      );
    }
    pairs.push({
      key,
      staticValue: null,
      inputElement,
    });
  }
  pairs.sort((a, b) => a.key.localeCompare(b.key));
  return pairs;
}

function qipEditFindUniformInputElement(sourceElement, key) {
  const name = "uniform-" + key;
  const root = sourceElement.closest("qip-edit");
  if (root) {
    const named = root.querySelectorAll("[name]");
    for (const candidate of named) {
      if (typeof candidate.getAttribute === "function" && candidate.getAttribute("name") === name) {
        return candidate;
      }
    }
  }
  return null;
}

function qipEditReadUniformValue(uniform) {
  if (uniform.inputElement) {
    const element = uniform.inputElement;
    if (element instanceof HTMLInputElement) {
      const inputType = (element.type || "").toLowerCase();
      const declaredType = (element.getAttribute("type") || "").toLowerCase();
      if (inputType === "color" || declaredType === "color") {
        const parsedColor = qipEditParseColorInputValue(element.value || "");
        if (parsedColor === null) {
          throw new Error("color uniform input must be a hex color (#rgb, #rrggbb, #rgba, #rrggbbaa)");
        }
        return parsedColor;
      }
      return element.value || "";
    }
    if (element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
      return element.value || "";
    }
    return (element.textContent || "").trim();
  }
  return uniform.staticValue || "";
}

function qipEditParseColorInputValue(rawValue) {
  const value = String(rawValue).trim();
  let hex = "";
  if (/^#[0-9a-f]{3}$/i.test(value)) {
    const r = value[1];
    const g = value[2];
    const b = value[3];
    hex = r + r + g + g + b + b + "ff";
  } else if (/^#[0-9a-f]{4}$/i.test(value)) {
    const r = value[1];
    const g = value[2];
    const b = value[3];
    const a = value[4];
    hex = r + r + g + g + b + b + a + a;
  } else if (/^#[0-9a-f]{6}$/i.test(value)) {
    hex = value.slice(1) + "ff";
  } else if (/^#[0-9a-f]{8}$/i.test(value)) {
    hex = value.slice(1);
  } else {
    return null;
  }
  const parsed = Number.parseInt(hex, 16);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return parsed >>> 0;
}

function qipEditSourceType(sourceElement) {
  return (sourceElement.getAttribute("type") || "application/wasm").trim().toLowerCase();
}

// A <source name="input"> is the input; every other <source> is a pipeline
// stage. Because the name carries the meaning, the input may itself be wasm.
function qipEditIsDataSource(sourceElement) {
  return sourceElement.getAttribute("name") === "input";
}

async function qipEditFetchSourceBytes(sourceElement, label) {
  const srcRaw = (sourceElement.getAttribute("src") || "").trim();
  if (srcRaw === "") {
    throw new Error("<source> inside <qip-edit> requires a non-empty src");
  }
  const sourceURL = new URL(srcRaw, document.baseURI).toString();
  const response = await fetch(sourceURL);
  if (!response.ok) {
    throw new Error("failed to fetch " + label + " " + sourceURL + " (" + String(response.status) + ")");
  }
  const bytes = await response.arrayBuffer();
  return { sourceURL, bytes };
}

async function qipEditLoadStage(sourceElement, policy) {
  const { sourceURL, bytes } = await qipEditFetchSourceBytes(sourceElement, "module");
  qipEditValidateWasmModulePolicy(bytes, policy, sourceURL);
  const module = await WebAssembly.compile(bytes);
  return {
    src: sourceURL,
    module,
    moduleBytes: bytes.byteLength,
    uniforms: qipEditExtractUniforms(sourceElement),
    exports: null,
  };
}

// Fetches the <source name="input"> payload. Its type attribute becomes the
// pipeline's initial content type.
async function qipEditLoadDataSource(sourceElement) {
  const { sourceURL, bytes } = await qipEditFetchSourceBytes(sourceElement, "input payload");
  return {
    src: sourceURL,
    bytes: new Uint8Array(bytes),
    contentType: qipEditNormalizeContentType(qipEditSourceType(sourceElement)),
  };
}

function qipEditWriteInput(exportsObj, inputBytes) {
  const inputPtr = qipEditReadI32Export(exportsObj, "input_ptr");
  const inputCapName = ("input_utf8_cap" in exportsObj) ? "input_utf8_cap" : "input_bytes_cap";
  const inputCap = qipEditReadI32Export(exportsObj, inputCapName);
  if (inputPtr < 0 || inputCap < 0) {
    throw new Error("module returned invalid input pointer/capacity");
  }
  if (inputBytes.length > inputCap) {
    throw new Error("input size exceeds " + inputCapName);
  }
  const start = inputPtr >>> 0;
  const end = start + inputBytes.length;
  const mem = new Uint8Array(exportsObj.memory.buffer);
  if (end < start || end > mem.length) {
    throw new Error("input write exceeds wasm memory bounds");
  }
  mem.set(inputBytes, start);
}

function qipEditReadOutputBytes(exportsObj, outputPtr, outputLen) {
  let capName = "";
  if ("output_utf8_cap" in exportsObj) {
    capName = "output_utf8_cap";
  } else if ("output_bytes_cap" in exportsObj) {
    capName = "output_bytes_cap";
  } else {
    throw new Error("edit module missing output_utf8_cap/output_bytes_cap");
  }

  const cap = qipEditReadI32Export(exportsObj, capName);
  if (cap < 0) {
    throw new Error("module returned invalid " + capName);
  }
  if (outputLen > cap) {
    throw new Error("render output size exceeds " + capName);
  }
  return qipEditReadSlice(exportsObj.memory, outputPtr, outputLen, "output_ptr/" + capName);
}

async function qipEditStageExports(stage) {
  if (stage.exports) {
    return stage.exports;
  }
  const instantiated = await WebAssembly.instantiate(stage.module, {});
  const exportsObj = (instantiated && instantiated.instance && instantiated.instance.exports) ||
    (instantiated && instantiated.exports) ||
    null;
  if (!exportsObj) {
    throw new Error("failed to access wasm exports for edit module");
  }
  if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
    throw new Error("edit module must export memory");
  }
  if (typeof exportsObj.render !== "function") {
    throw new Error("edit module missing export render");
  }
  stage.exports = exportsObj;
  return exportsObj;
}

async function qipEditRunStage(stage, input) {
  // One instance is kept per stage and re-rendered, as the component contract
  // intends; re-instantiating per render churns linear memory allocations. A
  // failed render drops the instance so the next run starts fresh.
  const exportsObj = await qipEditStageExports(stage);
  try {
    const expectedInputType = qipEditReadDeclaredContentType(exportsObj, "input_content_type_ptr", "input_content_type_size");
    if (expectedInputType !== "" && input.contentType !== "" && expectedInputType !== input.contentType) {
      throw new Error("input content type mismatch: expected " + expectedInputType + ", got " + input.contentType);
    }

    qipEditWriteInput(exportsObj, input.bytes);
    for (const uniform of stage.uniforms) {
      qipEditApplyUniform(exportsObj, uniform.key, qipEditReadUniformValue(uniform));
    }

    const renderResult = exportsObj.render(input.bytes.length);
    if (typeof renderResult !== "bigint") {
      throw new TypeError("render export must have signature render(i32) -> i64");
    }
    const bits = BigInt.asUintN(64, renderResult);
    const outputLen = Number(bits & 0xffff_ffffn);
    if ((bits & (1n << 63n)) !== 0n) {
      if (typeof exportsObj.failure_modes_per_input_offset !== "function") {
        throw new Error("render returned failure without failure_modes_per_input_offset");
      }
      const modes = qipEditReadI32Export(exportsObj, "failure_modes_per_input_offset") >>> 0;
      if (modes === 0) throw new Error("rejected input");
      const position = Math.floor(outputLen / modes);
      const mode = outputLen % modes;
      throw new Error(modes === 1
        ? "rejected input at input offset " + position
        : "rejected input at input offset " + position + " with mode " + mode);
    }
    const outputPtr = Number((bits >> 32n) & 0x7fff_ffffn);
    const outputBytes = qipEditReadOutputBytes(exportsObj, outputPtr, outputLen);
    let outputContentType = qipEditReadDeclaredContentType(exportsObj, "output_content_type_ptr", "output_content_type_size");
    if (outputContentType === "") {
      // A bytes-in, UTF-8-out component produces new text; the incoming
      // (binary) pipeline content type does not describe its output.
      const readsUTF8 = "input_utf8_cap" in exportsObj;
      const emitsUTF8 = "output_utf8_cap" in exportsObj;
      if (readsUTF8 || !emitsUTF8) {
        outputContentType = input.contentType;
      }
    }
    return {
      bytes: outputBytes,
      contentType: outputContentType,
    };
  } catch (err) {
    stage.exports = null;
    throw err;
  }
}

function qipEditIsFileInput(inputElement) {
  return inputElement instanceof HTMLInputElement &&
    (inputElement.type || "").toLowerCase() === "file";
}

// Resolves the pipeline's initial bytes and content type. A chosen file wins,
// then the input <source>, then the input element's text.
async function qipEditReadInput(inputElement, payload) {
  if (inputElement && qipEditIsFileInput(inputElement)) {
    const file = inputElement.files && inputElement.files[0];
    if (file) {
      const bytes = new Uint8Array(await file.arrayBuffer());
      return {
        bytes,
        contentType: qipEditNormalizeContentType(file.type || ""),
      };
    }
    if (payload) {
      return { bytes: payload.bytes, contentType: payload.contentType };
    }
    return { bytes: new Uint8Array(0), contentType: "" };
  }
  if (payload) {
    return { bytes: payload.bytes, contentType: payload.contentType };
  }
  if (!inputElement) {
    return { bytes: new Uint8Array(0), contentType: "" };
  }
  if (inputElement instanceof HTMLTextAreaElement || inputElement instanceof HTMLInputElement) {
    return {
      bytes: qipEditTextEncoder.encode(inputElement.value || ""),
      contentType: "",
    };
  }
  return {
    bytes: qipEditTextEncoder.encode((inputElement.textContent || "").trim()),
    contentType: "",
  };
}

function qipEditEscapeHTML(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function qipEditFindTextOutputTarget(outputElement) {
  return outputElement.querySelector("pre > code, iframe");
}

function qipEditIsElementNamed(element, localName) {
  return element && typeof element.localName === "string" && element.localName.toLowerCase() === localName;
}

function qipEditSetGeneratedAlertRole(outputElement) {
  if (!outputElement.hasAttribute("role")) {
    outputElement.setAttribute("role", "alert");
    outputElement.setAttribute("data-qip-generated-alert-role", "true");
  }
}

function qipEditClearGeneratedAlertRole(outputElement) {
  if (outputElement.getAttribute("data-qip-generated-alert-role") === "true") {
    outputElement.removeAttribute("role");
    outputElement.removeAttribute("data-qip-generated-alert-role");
  }
}

const QIP_EDIT_IFRAME_STYLE = "\n<style>:where(body){font-family:sans-serif}</style>";

function qipEditSetIframeSrcdoc(iframeElement, html, includePreviewStyle) {
  const srcdoc = includePreviewStyle ? html + QIP_EDIT_IFRAME_STYLE : html;
  iframeElement.srcdoc = srcdoc;
  iframeElement.setAttribute("srcdoc", srcdoc);
}

function qipEditRenderTextOutput(outputElement, text, contentType, isError) {
  const target = qipEditFindTextOutputTarget(outputElement);
  if (qipEditIsElementNamed(target, "iframe")) {
    if (!target.hasAttribute("sandbox")) {
      target.setAttribute("sandbox", "");
    }
    if (isError) {
      qipEditSetIframeSrcdoc(target, "<pre role=\"alert\">" + qipEditEscapeHTML(text) + "</pre>", false);
      return;
    }
    qipEditSetIframeSrcdoc(target, text, qipEditIsHTMLContentType(contentType));
    return;
  }
  if (target) {
    target.textContent = text;
    return;
  }
  outputElement.textContent = text;
}

/**
 * <qip-edit> is a light-DOM browser host for Content components.
 *
 * The element reads input from the first child with name="input", runs each
 * <source type="application/wasm"> as a QIP pipeline stage, then writes the same
 * output bytes into every <output name="output"> child. Multiple outputs are
 * views of one component result, not multiple component return values.
 *
 * Binary input has two HTML-native forms:
 *
 * - A <source name="input" src="..." type="..."> is fetched as the input; its
 *   type attribute becomes the pipeline's initial content type.
 * - An <input type="file" name="input"> supplies the chosen file's bytes. With
 *   no file selected it falls back to the input <source>, so a page can ship
 *   default data that visitors override with their own file.
 *
 * Each <output> may declare its preferred view with normal HTML:
 *
 * - <pre><code></code></pre> receives decoded UTF-8 output as textContent.
 * - <iframe sandbox></iframe> receives decoded UTF-8 output as srcdoc. For
 *   text/html output, a minimal preview style is appended.
 * - <img> receives image output through an object URL.
 * - Without a recognized child, decoded text or a small binary hex preview is
 *   written directly to the <output> element.
 *
 * Text views are used only after the bytes decode as UTF-8 or the content type
 * is a known text type. Image views are used only for image/* content types.
 *
 * Static module policy:
 *
 * - Modules containing memory.grow are rejected by default.
 * - max-memory="<bytes>" rejects modules whose declared memory minimum or
 *   maximum exceeds the byte cap. A module with memory but no declared maximum
 *   is rejected when this attribute is set.
 * - allow-memory-grow permits memory.grow and requires max-memory.
 */
class QIPEditElement extends HTMLElement {
  constructor() {
    super();
    this._started = false;
    this._stages = [];
    this._payload = null;
    this._inputElement = null;
    this._outputElements = [];
    this._runToken = 0;
    this._boundControlListener = null;
    this._objectURLs = [];
    this._moduleBytesTotal = 0;
    this._runRequestID = 0;
    this._queuedRunToken = 0;
  }

  async connectedCallback() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      await this._init();
      this._scheduleRun();
    } catch (err) {
      this._renderError(err);
    }
  }

  disconnectedCallback() {
    if (this._boundControlListener) {
      this.removeEventListener("input", this._boundControlListener);
      this.removeEventListener("change", this._boundControlListener);
    }
    if (this._runRequestID !== 0 && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this._runRequestID);
      this._runRequestID = 0;
    }
    this._boundControlListener = null;
    this._revokeObjectURLs();
  }

  async _init() {
    const sourceElements = Array.from(this.querySelectorAll("source"));
    const moduleSourceElements = [];
    const dataSourceElements = [];
    for (const sourceElement of sourceElements) {
      if (qipEditIsDataSource(sourceElement)) {
        dataSourceElements.push(sourceElement);
        continue;
      }
      const sourceType = qipEditSourceType(sourceElement);
      if (sourceType !== "application/wasm") {
        throw new Error(
          "pipeline <source> must be application/wasm, got " + sourceType + "; use name=\"input\" for the input",
        );
      }
      moduleSourceElements.push(sourceElement);
    }
    if (moduleSourceElements.length === 0) {
      throw new Error("<qip-edit> requires at least one <source> module");
    }
    if (dataSourceElements.length > 1) {
      throw new Error("<qip-edit> allows at most one non-wasm data <source>");
    }

    const policy = qipEditReadModulePolicy(this);
    this._stages = [];
    this._moduleBytesTotal = 0;
    for (const sourceElement of moduleSourceElements) {
      const stage = await qipEditLoadStage(sourceElement, policy);
      this._stages.push(stage);
      this._moduleBytesTotal += stage.moduleBytes;
    }
    this.dataset.moduleBytesTotal = String(this._moduleBytesTotal);
    this.dataset.wasmSize = qipEditFormatByteSize(this._moduleBytesTotal);

    this._payload = null;
    if (dataSourceElements.length === 1) {
      this._payload = await qipEditLoadDataSource(dataSourceElements[0]);
    }

    this._inputElement = null;
    for (const candidate of this.querySelectorAll("[name='input']")) {
      if (!qipEditIsElementNamed(candidate, "source")) {
        this._inputElement = candidate;
        break;
      }
    }
    if (!this._inputElement && !this._payload) {
      throw new Error("<qip-edit> requires a child input with name=\"input\" or a data <source>");
    }
    this._outputElements = Array.from(this.querySelectorAll("output[name='output']"));
    if (this._outputElements.length === 0) {
      throw new Error("<qip-edit> requires a child output with name=\"output\"");
    }

    this._boundControlListener = () => {
      this._scheduleRun();
    };
    this.addEventListener("input", this._boundControlListener);
    this.addEventListener("change", this._boundControlListener);
  }

  _scheduleRun() {
    const token = ++this._runToken;
    this._queuedRunToken = token;
    if (this._runRequestID !== 0) {
      return;
    }
    const flushRun = () => {
      this._runRequestID = 0;
      const nextToken = this._queuedRunToken;
      this._runPipeline(nextToken).catch((err) => {
        if (nextToken === this._runToken) {
          this._renderError(err);
        }
      });
    };
    if (typeof requestAnimationFrame === "function") {
      this._runRequestID = requestAnimationFrame(flushRun);
      return;
    }
    flushRun();
  }

  async _runPipeline(token) {
    if ((!this._inputElement && !this._payload) || this._outputElements.length === 0) {
      throw new Error("qip-edit is not initialized");
    }
    const startedMS = qipEditNowMS();
    try {
      let current = await qipEditReadInput(this._inputElement, this._payload);
      if (token !== this._runToken) {
        return;
      }
      for (const stage of this._stages) {
        current = await qipEditRunStage(stage, current);
        if (token !== this._runToken) {
          return;
        }
      }
      if (token !== this._runToken) {
        return;
      }
      this._renderResult(current);
    } finally {
      if (token === this._runToken) {
        const elapsedMS = Math.max(0, qipEditNowMS() - startedMS);
        this.dataset.runMs = String(Math.round(elapsedMS));
        this._updateStats(elapsedMS);
      }
    }
  }

  _updateStats(elapsedMS) {
    let memoryBytesTotal = 0;
    for (const stage of this._stages) {
      if (stage.exports && stage.exports.memory instanceof WebAssembly.Memory) {
        memoryBytesTotal += stage.exports.memory.buffer.byteLength;
      }
    }
    this.dataset.wasmSize = qipEditFormatByteSize(this._moduleBytesTotal);
    this.dataset.memoryBytesTotal = String(memoryBytesTotal);
    this.dataset.memorySize = qipEditFormatByteSize(memoryBytesTotal);
    this.dataset.renderTime = qipEditFormatMS(elapsedMS);
  }

  _renderResult(result) {
    if (this._outputElements.length === 0) {
      return;
    }
    this._revokeObjectURLs();
    const contentType = qipEditGuessDisplayContentType(result.bytes, result.contentType);
    const isImage = contentType.startsWith("image/");
    let decodedText = null;
    let fallbackText = null;
    if (contentType === "" || qipEditIsTextContentType(contentType)) {
      try {
        decodedText = qipEditTextDecoder.decode(result.bytes);
      } catch (_) {
        fallbackText = qipEditFormatBinary(result.bytes);
      }
    } else if (!isImage) {
      fallbackText = qipEditFormatBinary(result.bytes);
    }

    let imageURL = "";
    for (const outputElement of this._outputElements) {
      qipEditClearGeneratedAlertRole(outputElement);
      if (isImage) {
        let imageElement = outputElement.querySelector("img");
        if (!imageElement) {
          imageElement = document.createElement("img");
          outputElement.replaceChildren(imageElement);
        }
        if (imageURL === "") {
          const blob = new Blob([result.bytes], { type: contentType });
          imageURL = URL.createObjectURL(blob);
        }
        if (!imageElement.hasAttribute("alt")) {
          imageElement.alt = "qip-edit output";
        }
        imageElement.hidden = false;
        outputElement.querySelector("[data-qip-error]")?.remove();
        imageElement.src = imageURL;
        continue;
      }
      if (decodedText !== null) {
        qipEditRenderTextOutput(outputElement, decodedText, contentType, false);
      } else {
        outputElement.textContent = fallbackText || qipEditFormatBinary(result.bytes);
      }
    }
    if (imageURL !== "") {
      this._objectURLs.push(imageURL);
    }
  }

  _renderError(err) {
    if (this._outputElements.length === 0) {
      const fallback = document.createElement("pre");
      fallback.setAttribute("role", "alert");
      const message = err instanceof Error ? err.message : String(err);
      fallback.textContent = "Preview error: " + message;
      this.replaceChildren(fallback);
      return;
    }
    this._revokeObjectURLs();
    const message = err instanceof Error ? err.message : String(err);
    for (const outputElement of this._outputElements) {
      const imageElement = outputElement.querySelector("img");
      if (imageElement) {
        imageElement.hidden = true;
        let errorElement = outputElement.querySelector("[data-qip-error]");
        if (!errorElement) {
          errorElement = document.createElement("pre");
          errorElement.setAttribute("data-qip-error", "");
          errorElement.setAttribute("role", "alert");
          outputElement.append(errorElement);
        }
        errorElement.textContent = "Preview error: " + message;
        continue;
      }
      qipEditSetGeneratedAlertRole(outputElement);
      qipEditRenderTextOutput(outputElement, "Preview error: " + message, "text/plain", true);
    }
  }

  _revokeObjectURLs() {
    for (const objectURL of this._objectURLs) {
      URL.revokeObjectURL(objectURL);
    }
    this._objectURLs = [];
  }
}

// <qip-view> shares the implementation: same wiring, same rendering. The
// user relationship differs (consume rather than author), and views commonly
// carry the rendered attribute with page-owned hidden inputs.
class QIPViewElement extends QIPEditElement {}

if (!customElements.get("qip-view")) {
  customElements.define("qip-view", QIPViewElement);
}
