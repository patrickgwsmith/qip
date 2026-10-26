// Wasm module reading, policy scanning (max-memory / memory-grow
// rejection), and safe export/memory access helpers.
// Extracted from qip-play.js so other hosts (qip-edit, external
// integrations) can share it. Served at /elements/ alongside the elements.

const QIP_PLAY_WASM_PAGE_SIZE_BYTES = 65536;
const QIP_PLAY_OPCODE_MEMORY_GROW = 0x40;

class QIPPlayWasmReader {
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
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }
}

function qipPlayReadModulePolicy(rootElement) {
  const maxMemoryRaw = rootElement.getAttribute("max-memory");
  const maxMemoryBytes = maxMemoryRaw === null ? 0 : qipPlayParsePolicyBytes(maxMemoryRaw, "max-memory");
  if (rootElement.hasAttribute("allow-memory-grow")) {
    throw new Error("allow-memory-grow has been removed: modules containing memory.grow are always rejected");
  }
  return { maxMemoryBytes, rejectOpcodes: [QIP_PLAY_OPCODE_MEMORY_GROW] };
}

function qipPlayParsePolicyBytes(rawValue, attrName) {
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

function qipPlayValidateWasmModulePolicy(moduleBytes, policy, label) {
  if (!policy || (policy.maxMemoryBytes === 0 && policy.rejectOpcodes.length === 0)) {
    return;
  }
  const failures = [];
  const rejectMemoryGrow = policy.rejectOpcodes.includes(QIP_PLAY_OPCODE_MEMORY_GROW);
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

  const r = new QIPPlayWasmReader(bytes.subarray(8));
  let memoryIndex = 0;
  while (r.remaining() > 0) {
    const sectionID = r.readByte();
    const sectionSize = r.readVarU32();
    const payload = r.readBytes(sectionSize);
    const section = new QIPPlayWasmReader(payload);
    if (sectionID === 2) {
      memoryIndex = qipPlayScanImportSectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 5) {
      memoryIndex = qipPlayScanMemorySectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 10 && rejectMemoryGrow) {
      qipPlayScanCodeSectionForPolicy(section, failures);
    }
  }

  if (failures.length > 0) {
    throw new Error("module " + label + " rejected by policy: " + failures.join("; "));
  }
}

function qipPlayScanImportSectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    r.readName();
    r.readName();
    const kind = r.readByte();
    if (kind === 0x00) {
      r.readVarU32();
    } else if (kind === 0x01) {
      qipPlaySkipTableType(r);
    } else if (kind === 0x02) {
      const limit = qipPlayReadLimits(r);
      qipPlayCheckMemoryLimit(limit, memoryIndex, policy, failures);
      memoryIndex++;
    } else if (kind === 0x03) {
      qipPlaySkipGlobalType(r);
    } else if (kind === 0x04) {
      r.readByte();
      r.readVarU32();
    } else {
      throw new Error("unsupported wasm import kind 0x" + kind.toString(16));
    }
  }
  return memoryIndex;
}

function qipPlayScanMemorySectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const limit = qipPlayReadLimits(r);
    qipPlayCheckMemoryLimit(limit, memoryIndex, policy, failures);
    memoryIndex++;
  }
  return memoryIndex;
}

function qipPlayReadLimits(r) {
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

function qipPlayCheckMemoryLimit(limit, memoryIndex, policy, failures) {
  if (policy.maxMemoryBytes === 0) {
    return;
  }
  if (qipPlayPagesToBytes(limit.minPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] initial size " + String(limit.minPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
  if (!limit.hasMax) {
    failures.push("memory[" + memoryIndex + "] has no declared maximum");
    return;
  }
  if (qipPlayPagesToBytes(limit.maxPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] maximum " + String(limit.maxPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
}

function qipPlayPagesToBytes(pages) {
  if (!Number.isFinite(pages) || pages > Number.MAX_SAFE_INTEGER / QIP_PLAY_WASM_PAGE_SIZE_BYTES) {
    return Number.POSITIVE_INFINITY;
  }
  return pages * QIP_PLAY_WASM_PAGE_SIZE_BYTES;
}

function qipPlayScanCodeSectionForPolicy(r, failures) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const bodySize = r.readVarU32();
    qipPlayScanFunctionBodyForPolicy(new QIPPlayWasmReader(r.readBytes(bodySize)), failures);
  }
}

function qipPlayScanFunctionBodyForPolicy(r, failures) {
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
        qipPlayReadBlockType(r);
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
        qipPlayReadMemArg(r);
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
        qipPlayReadFCImmediate(r);
        break;
      case 0xfd:
        qipPlayReadFDImmediate(r);
        break;
      case 0xfe:
        qipPlayReadFEImmediate(r);
        break;
      default:
        break;
    }
  }
}

function qipPlayReadBlockType(r) {
  const b = r.peekByte();
  if (b === 0x40 || b === 0x7f || b === 0x7e || b === 0x7d || b === 0x7c || b === 0x7b || b === 0x70 || b === 0x6f) {
    r.readByte();
    return;
  }
  r.readVarS64(5);
}

function qipPlayReadMemArg(r) {
  r.readVarU32();
  r.readVarU32();
}

function qipPlayReadFCImmediate(r) {
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

function qipPlayReadFDImmediate(r) {
  const sub = r.readVarU32();
  if (sub <= 11 || sub === 92 || sub === 93) {
    qipPlayReadMemArg(r);
  } else if (sub === 12 || sub === 13) {
    r.readBytes(16);
  } else if (sub >= 21 && sub <= 34) {
    r.readByte();
  } else if (sub >= 84 && sub <= 91) {
    qipPlayReadMemArg(r);
    r.readByte();
  }
}

function qipPlayReadFEImmediate(r) {
  const sub = r.readVarU32();
  if (sub === 3) {
    r.readByte();
    return;
  }
  qipPlayReadMemArg(r);
}

function qipPlaySkipTableType(r) {
  r.readByte();
  qipPlayReadLimits(r);
}

function qipPlaySkipGlobalType(r) {
  r.readByte();
  r.readByte();
}


function qipPlayToI32(value, label) {
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


function qipPlayReadI32Export(exportsObj, exportName) {
  const value = exportsObj[exportName];
  if (typeof value === "function") {
    return qipPlayToI32(value(), exportName);
  }
  throw new Error("qip-play module must export " + exportName + "() -> i32");
}

function qipPlayReadSlice(memory, ptr, len, label) {
  if (!(memory instanceof WebAssembly.Memory)) {
    throw new Error("qip-play module memory export is missing or invalid");
  }
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
  return mem.subarray(start, end);
}


export {
  QIPPlayWasmReader as WasmModuleReader,
  qipPlayReadModulePolicy as readModulePolicy,
  qipPlayParsePolicyBytes as parsePolicyBytes,
  qipPlayValidateWasmModulePolicy as validateWasmModulePolicy,
  qipPlayToI32 as toI32,
  qipPlayReadI32Export as readI32Export,
  qipPlayReadSlice as readSlice,
};

if (
  typeof globalThis.customElements !== "undefined" &&
  typeof globalThis.HTMLElement === "function" &&
  !customElements.get("qip-wasm-policy")
) {
  customElements.define("qip-wasm-policy", class QIPWasmPolicyElement extends HTMLElement {});
}
