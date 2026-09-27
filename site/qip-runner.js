const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });
// A lowercase media type, optionally followed by ";name=value" parameters with no
// whitespace anywhere. Parameter
// names are case-insensitive; values are case-sensitive and kept verbatim, as in
// "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR".
const mimeTypePattern =
  /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*(?:;[A-Za-z0-9!#$&^_.+-]+=[^\s;"=]+)*$/;
const multipartFormDataPattern =
  /^multipart\/form-data;boundary=uuid-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function toI32(value, label) {
  const n = typeof value === "bigint" ? Number(value) : value;
  if (typeof n !== "number" || !Number.isFinite(n)) {
    throw Error(label + " returned non-finite numeric value");
  }
  return n | 0;
}

function optionalContractContentType(value) {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw Error("contentType must be a string");
  }
  if (multipartFormDataPattern.test(value)) {
    return value;
  }
  // multipart/form-data is only valid in its canonical UUID boundary form above.
  if (value.startsWith("multipart/form-data") || !mimeTypePattern.test(value)) {
    throw Error(
      "contentType must be a lowercase MIME type, optionally with \"; name=value\" parameters, except for the canonical multipart/form-data UUID boundary",
    );
  }
  return value;
}

function parseContentType(value) {
  const segments = String(value).split(";");
  const mediaType = segments[0].trim().toLowerCase();
  const params = new Map();
  const names = new Map();
  for (const segment of segments.slice(1)) {
    const eq = segment.indexOf("=");
    if (eq === -1) continue;
    const declaredName = segment.slice(0, eq).trim();
    const name = declaredName.toLowerCase();
    if (name === "") continue;
    params.set(name, segment.slice(eq + 1).trim());
    names.set(name, declaredName);
  }
  return { mediaType, params, names };
}

// Why content of type `incoming` does not satisfy a declared `expected` type, or "" when it
// does: the media types differ, or a parameter both declare has different values. The
// wording matches the qip and qipx command-line tools.
// Only the incoming parameters when the media types agree, else the whole incoming type.
function incomingForMessage(expected, incoming) {
  if (parseContentType(expected).mediaType !== parseContentType(incoming).mediaType) return incoming;
  const cut = String(incoming).indexOf(";");
  return cut === -1 ? incoming : String(incoming).slice(cut + 1).trim();
}

function contentTypeMismatch(expected, incoming) {
  const want = parseContentType(expected);
  const got = parseContentType(incoming);
  if (want.mediaType !== got.mediaType) {
    return "media type expected " + want.mediaType + " got " + got.mediaType;
  }
  const details = [];
  for (const [name, value] of want.params) {
    if (got.params.has(name) && got.params.get(name) !== value) {
      const shown = want.names.get(name);
      details.push(shown + " expected " + value + " got " + got.params.get(name));
    }
  }
  return details.join("; ");
}

class ContentTypeUTF8 {
  constructor(optionalMIMEType) {
    this.contentType = optionalContractContentType(optionalMIMEType);
    Object.freeze(this);
  }
}

class ContentTypeBytes {
  constructor(optionalMIMEType) {
    this.contentType = optionalContractContentType(optionalMIMEType);
    Object.freeze(this);
  }
}

function contractAccepted(actual, expected) {
  return (
    encodingAccepted(actual, expected) &&
    (expected.contentType === undefined ||
      actual.contentType === expected.contentType)
  );
}

function encodingAccepted(actual, expected) {
  return (
    actual.constructor === expected.constructor ||
    (actual instanceof ContentTypeUTF8 && expected instanceof ContentTypeBytes)
  );
}

function describeContract(contract) {
  return (
    (contract instanceof ContentTypeUTF8 ? "utf-8" : "bytes") +
    (contract.contentType ? " " + contract.contentType : "")
  );
}

function isContentContract(value) {
  return value instanceof ContentTypeUTF8 || value instanceof ContentTypeBytes;
}

function assertContractsMatch(actual, expected, label) {
  if (!contractAccepted(actual, expected)) {
    throw Error(
      label +
        " contract mismatch: expected " +
        describeContract(expected) +
        ", got " +
        describeContract(actual),
    );
  }
}

function resolveComponentOutput(input, component) {
  assertContractsMatch(input, component.input, "component input");
  if (component.output.contentType !== undefined) {
    return component.output;
  }

  // Raw bytes converted to UTF-8 are newly interpreted text, so the binary
  // MIME type cannot follow. Other generic transforms preserve a known type.
  const contentType =
    component.input instanceof ContentTypeBytes &&
    component.output instanceof ContentTypeUTF8
      ? undefined
      : input.contentType;
  return component.output instanceof ContentTypeUTF8
    ? new ContentTypeUTF8(contentType)
    : new ContentTypeBytes(contentType);
}

function valueForInput(value, actual, expected) {
  if (actual instanceof ContentTypeUTF8 && expected instanceof ContentTypeBytes) {
    return textEncoder.encode(value);
  }
  return value;
}

function readI32Export(exportsObj, name) {
  return toI32(exportsObj[name](), name);
}

function readSlice(memory, ptr, len, label) {
  if (ptr < 0 || len < 0) {
    throw Error(label + " returned negative pointer/size");
  }
  const start = ptr >>> 0;
  const end = start + (len >>> 0);
  const mem = new Uint8Array(memory.buffer);
  if (end > mem.length) {
    throw Error(label + " exceeds wasm memory bounds");
  }
  return mem.slice(start, end);
}

function writeSlice(memory, ptr, bytes, label) {
  if (ptr < 0) {
    throw Error(label + " returned negative pointer");
  }
  const start = ptr >>> 0;
  const end = start + bytes.length;
  const mem = new Uint8Array(memory.buffer);
  if (end > mem.length) {
    throw Error(label + " exceeds wasm memory bounds");
  }
  mem.set(bytes, start);
}

function optionalContentType(exportsObj, memory, ptrName, sizeName) {
  if (exportsObj[ptrName] === undefined && exportsObj[sizeName] === undefined) {
    return undefined;
  }
  if (
    typeof exportsObj[ptrName] !== "function" ||
    typeof exportsObj[sizeName] !== "function"
  ) {
    throw Error(
      "content type exports " + ptrName + "/" + sizeName + " must be functions",
    );
  }
  const size = readI32Export(exportsObj, sizeName);
  if (size <= 0) {
    throw Error("content type export " + sizeName + " must be positive");
  }
  const ptr = readI32Export(exportsObj, ptrName);
  return optionalContractContentType(
    textDecoder.decode(readSlice(memory, ptr, size, ptrName + "/" + sizeName)),
  );
}

function requireExportedFunction(moduleExports, name) {
  if (
    !moduleExports.find((exp) => exp.name === name && exp.kind === "function")
  ) {
    throw Error("component must export " + name + " as function");
  }
}

function capName(contract, direction) {
  return (
    direction +
    (contract instanceof ContentTypeUTF8 ? "_utf8_cap" : "_bytes_cap")
  );
}

function bytesForInput(input, contract) {
  if (contract instanceof ContentTypeUTF8) {
    if (typeof input !== "string") {
      throw Error(
        "component input must be a string for " + describeContract(contract),
      );
    }
    return textEncoder.encode(input);
  }
  if (!(input instanceof Uint8Array)) {
    throw Error(
      "component input must be Uint8Array for " + describeContract(contract),
    );
  }
  return input;
}

function outputForBytes(bytes, contract) {
  return contract instanceof ContentTypeUTF8 ? textDecoder.decode(bytes) : bytes;
}

function assertJsOutput(value, contract) {
  if (contract instanceof ContentTypeUTF8) {
    if (typeof value !== "string") {
      throw Error(
        "JavaScript component returned non-string output for " +
          describeContract(contract),
      );
    }
  } else if (!(value instanceof Uint8Array)) {
    throw Error(
      "JavaScript component returned non-Uint8Array output for " +
        describeContract(contract),
    );
  }
}

function freezeComponent(fn, input, output) {
  Object.defineProperties(fn, {
    input: { value: input },
    output: { value: output },
  });
  return Object.freeze(fn);
}

function validateWasmComponent(input, module, output) {
  const moduleExports = WebAssembly.Module.exports(module);

  if (!moduleExports.find((exp) => exp.name === "memory" && exp.kind === "memory")) {
    throw Error("component must export memory");
  }
  requireExportedFunction(moduleExports, "render");
  requireExportedFunction(moduleExports, "input_ptr");
  requireExportedFunction(moduleExports, capName(input, "input"));
  requireExportedFunction(moduleExports, capName(output, "output"));

  const exportsObj = new WebAssembly.Instance(module, {}).exports;
  const declaredInput = optionalContentType(
    exportsObj,
    exportsObj.memory,
    "input_content_type_ptr",
    "input_content_type_size",
  );
  const declaredOutput = optionalContentType(
    exportsObj,
    exportsObj.memory,
    "output_content_type_ptr",
    "output_content_type_size",
  );

  const inputMismatch =
    declaredInput === undefined ? "" : contentTypeMismatch(declaredInput, input.contentType);
  if (inputMismatch !== "") {
    throw Error(
      "component expected " + declaredInput + ", got " + incomingForMessage(declaredInput, input.contentType) + ": " + inputMismatch,
    );
  }
  const outputMismatch =
    declaredOutput === undefined ? "" : contentTypeMismatch(output.contentType, declaredOutput);
  if (outputMismatch !== "") {
    throw Error(
      "component output " + declaredOutput + " does not satisfy " + output.contentType + ": " + outputMismatch,
    );
  }
}

function wasmComponent(input, module, output) {
  validateWasmComponent(input, module, output);

  return freezeComponent(
    (value) => {
      const exportsObj = new WebAssembly.Instance(module, {}).exports;
      const render = exportsObj.render;

      const inputBytes = bytesForInput(value, input);
      const inputPtr = readI32Export(exportsObj, "input_ptr");
      const inputCap = readI32Export(exportsObj, capName(input, "input"));
      if (inputBytes.length > inputCap) {
        throw Error(
          "input exceeds component capacity: " +
            inputBytes.length +
            " > " +
            inputCap,
        );
      }

      writeSlice(exportsObj.memory, inputPtr, inputBytes, "input_ptr");

      const renderResult = render(inputBytes.length);
      if (typeof renderResult !== "bigint") {
        throw TypeError("render export must have signature render(i32) -> i64");
      }
      const bits = BigInt.asUintN(64, renderResult);
      const outputLen = Number(bits & 0xffff_ffffn);
      if ((bits & (1n << 63n)) !== 0n) {
        if (typeof exportsObj.failure_modes_per_input_offset !== "function") {
          throw Error("render returned failure without failure_modes_per_input_offset");
        }
        const modes = readI32Export(exportsObj, "failure_modes_per_input_offset") >>> 0;
        if (modes === 0) throw Error("rejected input");
        const position = Math.floor(outputLen / modes);
        const mode = outputLen % modes;
        throw Error(
          modes === 1
            ? "rejected input at input offset " + String(position)
            : "rejected input at input offset " + String(position) + " with mode " + String(mode),
        );
      }

      const outputCap = readI32Export(exportsObj, capName(output, "output"));
      if (outputLen > outputCap) {
        throw Error(
          "render output exceeds component capacity: " +
            outputLen +
            " > " +
            outputCap,
        );
      }

      const outputPtr = Number((bits >> 32n) & 0x7fff_ffffn);
      return outputForBytes(
        readSlice(exportsObj.memory, outputPtr, outputLen, "output_ptr"),
        output,
      );
    },
    input,
    output,
  );
}

function jsComponent(input, fn, output) {
  return freezeComponent(
    (value) => {
      bytesForInput(value, input);
      const result = fn(value);
      assertJsOutput(result, output);
      return result;
    },
    input,
    output,
  );
}

function isContentComponent(value) {
  return (
    typeof value === "function" &&
    isContentContract(value.input) &&
    isContentContract(value.output)
  );
}

export function contentTypeUTF8(optionalMIMEType) {
  return new ContentTypeUTF8(optionalMIMEType);
}

export function contentTypeBytes(optionalMIMEType) {
  return new ContentTypeBytes(optionalMIMEType);
}

export function contentComponent(input, implementation, output) {
  if (!isContentContract(input)) {
    throw Error("contentComponent input must be a content contract");
  }
  if (!isContentContract(output)) {
    throw Error("contentComponent output must be a content contract");
  }
  if (implementation instanceof WebAssembly.Module) {
    return wasmComponent(input, implementation, output);
  }
  if (typeof implementation === "function") {
    return jsComponent(input, implementation, output);
  }
  throw Error(
    "content component implementation must be a WebAssembly.Module or function",
  );
}

export function contentRecipe(input, components, output) {
  if (!isContentContract(input)) {
    throw Error("contentRecipe input must be a content contract");
  }
  if (!isContentContract(output)) {
    throw Error("contentRecipe output must be a content contract");
  }
  if (!Array.isArray(components)) {
    throw Error("contentRecipe components must be an array");
  }

  const steps = components.slice();
  for (let i = 0; i < steps.length; i += 1) {
    if (!isContentComponent(steps[i])) {
      throw Error(
        "contentRecipe step " + String(i + 1) + " must be a content component",
      );
    }
  }

  const plannedInputs = [];
  let plannedOutput = input;
  if (steps.length === 0) {
    assertContractsMatch(input, output, "empty recipe");
  } else {
    let current = input;
    for (let i = 0; i < steps.length; i += 1) {
      try {
        plannedInputs.push(current);
        current = resolveComponentOutput(current, steps[i]);
      } catch (error) {
        throw Error(
          "recipe step " + String(i + 1) + " " + error.message,
        );
      }
    }
    assertContractsMatch(current, output, "recipe output");
    plannedOutput = current;
  }

  return freezeComponent(
    (value) => {
      bytesForInput(value, input);
      let current = value;
      for (let i = 0; i < steps.length; i += 1) {
        current = steps[i](
          valueForInput(current, plannedInputs[i], steps[i].input),
        );
      }
      current = valueForInput(current, plannedOutput, output);
      assertJsOutput(current, output);
      return current;
    },
    input,
    output,
  );
}
