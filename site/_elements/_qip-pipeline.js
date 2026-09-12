// Browser-host pipeline parsing, uniform application, and declared
// content-type validation for <qip-step> source pipelines.
// Extracted from qip-play.js so other hosts (qip-edit, external
// integrations) can share it. Served at /elements/ alongside the elements.

import {
  readI32Export as qipPlayReadI32Export,
  readSlice as qipPlayReadSlice,
} from "./qip-wasm-policy.js";

function qipPlayExtractUniforms(sourceElement) {
  const uniforms = [];
  for (const attributeName of sourceElement.getAttributeNames()) {
    if (!attributeName.startsWith("data-uniform-")) continue;
    const key = attributeName.slice("data-uniform-".length);
    if (!/^[a-z][a-z0-9_]{0,62}$/.test(key) || key.endsWith("_") || key.includes("__")) {
      throw new Error("invalid qip-play uniform key " + key);
    }
    const value = (sourceElement.getAttribute(attributeName) || "").trim();
    if (value === "") throw new Error("qip-play uniform " + key + " requires a value");
    uniforms.push({ key, value });
  }
  uniforms.sort((a, b) => a.key.localeCompare(b.key));
  return uniforms;
}

function qipPlayUniformAttempts(rawValue) {
  if (/^[+-]?0x[0-9a-f]+$/i.test(rawValue) || /^[+-]?\d+$/.test(rawValue)) {
    const bigint = BigInt(rawValue);
    const number = Number(bigint);
    return Number.isSafeInteger(number) ? [number, bigint] : [bigint];
  }
  const number = Number(rawValue);
  if (!Number.isFinite(number)) throw new Error("uniform value is not a finite number");
  return [number];
}

function qipPlayApplyUniform(exportsObj, uniform) {
  const name = "uniform_set_" + uniform.key;
  const setter = exportsObj[name];
  if (typeof setter !== "function") throw new Error("qip-play module missing export " + name);
  let lastError = null;
  for (const value of qipPlayUniformAttempts(uniform.value)) {
    try {
      setter(value);
      return;
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error("failed to set qip-play uniform " + uniform.key + ": " + (lastError?.message ?? lastError));
}

function qipPlayElementName(element) {
  return String(element?.localName || element?.tagName || "").toLowerCase();
}

function qipPlayDirectChildren(element, name) {
  return Array.from(element?.children || []).filter((child) => qipPlayElementName(child) === name);
}

function qipPlaySelectStepSources(stepElement) {
  const sources = qipPlayDirectChildren(stepElement, "source");
  const selected = [];
  for (const source of sources) {
    const type = (source.getAttribute("type") || "application/wasm").trim().toLowerCase();
    if (type !== "application/wasm") continue;
    const media = (source.getAttribute("media") || "").trim();
    if (media !== "" && typeof globalThis.matchMedia === "function" && !globalThis.matchMedia(media).matches) {
      continue;
    }
    selected.push(source);
  }
  if (selected.length === 0) {
    throw new Error("<qip-step> requires a matching <source type=\"application/wasm\">");
  }
  return selected;
}

function qipPlaySourceSteps(element) {
  const wrappedSteps = qipPlayDirectChildren(element, "qip-step");
  // A named non-Wasm source is initialization data, not a pipeline stage.
  const directSources = qipPlayDirectChildren(element, "source").filter(
    (source) => (source.getAttribute("type") || "application/wasm").trim().toLowerCase() === "application/wasm",
  );
  if (wrappedSteps.length > 0) {
    if (directSources.length > 0) {
      throw new Error("<qip-play> cannot mix direct <source> children with <qip-step>");
    }
    return wrappedSteps.map((stepElement) => {
      const sourceElements = qipPlaySelectStepSources(stepElement);
      return { stepElement, sourceElements, sourceElement: sourceElements[0] };
    });
  }
  if (directSources.length !== 1) {
    throw new Error("<qip-play> requires one direct <source> or one or more <qip-step> children");
  }
  return [{ stepElement: null, sourceElements: directSources, sourceElement: directSources[0] }];
}

function qipPlayReadDeclaredContentType(exportsObj, memory, ptrName, sizeName) {
  if (!(ptrName in exportsObj) && !(sizeName in exportsObj)) return "";
  if (!(ptrName in exportsObj) || !(sizeName in exportsObj)) {
    throw new Error("qip-play component must export both " + ptrName + " and " + sizeName);
  }
  const ptr = qipPlayReadI32Export(exportsObj, ptrName);
  const size = qipPlayReadI32Export(exportsObj, sizeName);
  return new TextDecoder("utf-8", { fatal: true }).decode(
    qipPlayReadSlice(memory, ptr, size, ptrName + "/" + sizeName),
  ).trim().toLowerCase();
}

function qipPlayStepLabel(stepRecord, index) {
  const authored = (stepRecord.stepElement?.getAttribute("name") || "").trim();
  if (authored !== "") return authored;
  const src = (stepRecord.sourceElement.getAttribute("src") || "").trim();
  const filename = src.split("/").filter(Boolean).at(-1) || "step";
  return String(index + 1) + ":" + filename.replace(/\.wasm$/i, "");
}

function qipPlaySourceLabel(sourceElement) {
  const src = (sourceElement.getAttribute("src") || "").trim();
  return src.split("/").filter(Boolean).at(-1)?.replace(/\.wasm$/i, "") || "source";
}

function qipPlayValidatePostStage(stage, precedingOutputType) {
  let expectedInputType = null;
  let expectedOutputType = null;
  for (const candidate of stage.candidates) {
    for (const name of ["input_ptr", "render"]) {
      if (!(name in candidate.exports)) {
        throw new Error("qip-play post-processing step " + stage.label + " missing export " + name);
      }
    }
    if ("begin_update_at" in candidate.exports || "finish_update" in candidate.exports) {
      throw new Error("qip-play post-processing step " + stage.label + " must be finite Content; Timed steps are not supported yet");
    }
    if ("key_event" in candidate.exports || "pointer_event" in candidate.exports) {
      throw new Error("qip-play post-processing step " + stage.label + " must not be Eventful");
    }
    const inputType = qipPlayReadDeclaredContentType(
      candidate.exports, candidate.memory, "input_content_type_ptr", "input_content_type_size",
    );
    const outputType = qipPlayReadDeclaredContentType(
      candidate.exports, candidate.memory, "output_content_type_ptr", "output_content_type_size",
    );
    if (inputType === "" || outputType === "") {
      throw new Error("qip-play post-processing alternatives must declare exact input and output content types");
    }
    const inputUTF8 = typeof candidate.exports.input_utf8_cap === "function";
    const inputBytes = typeof candidate.exports.input_bytes_cap === "function";
    const outputUTF8 = typeof candidate.exports.output_utf8_cap === "function";
    const outputBytes = typeof candidate.exports.output_bytes_cap === "function";
    if (inputUTF8 === inputBytes || outputUTF8 === outputBytes) {
      throw new Error("qip-play post-processing alternatives must declare exactly one input and output capacity getter");
    }
    if (expectedInputType === null) {
      expectedInputType = inputType;
      expectedOutputType = outputType;
    } else if (inputType !== expectedInputType || outputType !== expectedOutputType) {
      throw new Error("qip-play alternatives in step " + stage.label + " must declare identical input and output content types");
    }
    candidate.inputType = inputType;
    candidate.outputType = outputType;
    candidate.inputCapacity = qipPlayReadI32Export(candidate.exports, inputUTF8 ? "input_utf8_cap" : "input_bytes_cap");
    candidate.inputPtr = qipPlayReadI32Export(candidate.exports, "input_ptr");
    candidate.outputCapacity = qipPlayReadI32Export(candidate.exports, outputUTF8 ? "output_utf8_cap" : "output_bytes_cap");
  }
  if (expectedInputType !== precedingOutputType) {
    throw new Error(
      "qip-play step " + stage.label + " input type " + expectedInputType +
      " does not match preceding output type " + precedingOutputType,
    );
  }
  stage.inputType = expectedInputType;
  stage.outputType = expectedOutputType;
  return expectedOutputType;
}


export {
  qipPlayExtractUniforms as extractUniforms,
  qipPlayUniformAttempts as uniformAttempts,
  qipPlayApplyUniform as applyUniform,
  qipPlayElementName as elementName,
  qipPlayDirectChildren as directChildren,
  qipPlaySelectStepSources as selectStepSources,
  qipPlaySourceSteps as sourceSteps,
  qipPlayReadDeclaredContentType as readDeclaredContentType,
  qipPlayStepLabel as stepLabel,
  qipPlaySourceLabel as sourceLabel,
  qipPlayValidatePostStage as validatePostStage,
};
