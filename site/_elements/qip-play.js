function qipPlayPerfNow() {
  return performance.now();
}

const QIP_PLAY_KEY_REPEAT_DELAY_MS = 250;
const QIP_PLAY_KEY_REPEAT_INTERVAL_MS = 33;

import {
  readModulePolicy as qipPlayReadModulePolicy,
  validateWasmModulePolicy as qipPlayValidateWasmModulePolicy,
  toI32 as qipPlayToI32,
  readI32Export as qipPlayReadI32Export,
  readSlice as qipPlayReadSlice,
} from "./qip-wasm-policy.js";
import {
  parseKTX2 as qipPlayParseKTX2,
  profileName as qipPlayProfileName,
  profileKey as qipPlayProfileKey,
  createPresentation as qipPlayCreatePresentation,
} from "./_qip-ktx2.js";
import {
  extractUniforms as qipPlayExtractUniforms,
  applyUniform as qipPlayApplyUniform,
  elementName as qipPlayElementName,
  directChildren as qipPlayDirectChildren,
  sourceSteps as qipPlaySourceSteps,
  readDeclaredContentType as qipPlayReadDeclaredContentType,
  stepLabel as qipPlayStepLabel,
  sourceLabel as qipPlaySourceLabel,
  validatePostStage as qipPlayValidatePostStage,
} from "./_qip-pipeline.js";

function qipPlayToI64(value, label) {
  if (typeof value === "bigint") {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error(label + " returned non-finite numeric value");
    }
    return BigInt(Math.trunc(value));
  }
  throw new Error(label + " returned unsupported numeric value");
}

function qipPlayI64MSAsNumber(value, label) {
  const ms = qipPlayToI64(value, label);
  if (ms <= 0n) {
    return 0;
  }
  const maxSafe = BigInt(Number.MAX_SAFE_INTEGER);
  if (ms > maxSafe) {
    return Number.MAX_SAFE_INTEGER;
  }
  return Number(ms);
}

function qipPlayNowMSArg(nowMS) {
  if (nowMS <= 0) {
    return 0n;
  }
  return BigInt(Math.floor(nowMS));
}

function qipPlayFormatByteSize(byteLength) {
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

function qipPlayFormatMS(ms) {
  return ms.toFixed(1);
}

function qipPlayFormatCount(count) {
  return String(count).padStart(3, " ");
}

function qipPlayByteSlicesEqual(a, b) {
  if (!a || !b || a.byteLength !== b.byteLength) {
    return false;
  }

  const len = a.byteLength;
  let i = 0;
  const aAlign = a.byteOffset & 3;
  const bAlign = b.byteOffset & 3;
  if (aAlign === bAlign) {
    const prefixLen = Math.min((4 - aAlign) & 3, len);
    while (i < prefixLen) {
      if (a[i] !== b[i]) {
        return false;
      }
      i++;
    }

    const wordBytes = (len - i) & ~3;
    const a32 = new Uint32Array(a.buffer, a.byteOffset + i, wordBytes >>> 2);
    const b32 = new Uint32Array(b.buffer, b.byteOffset + i, wordBytes >>> 2);
    for (let wordIndex = 0; wordIndex < a32.length; wordIndex++) {
      if (a32[wordIndex] !== b32[wordIndex]) {
        return false;
      }
    }
    i += wordBytes;
  }

  while (i < len) {
    if (a[i] !== b[i]) {
      return false;
    }
    i++;
  }
  return true;
}

function qipPlayCompareQueuedEvents(a, b) {
  return a.timeMS - b.timeMS || a.sequence - b.sequence;
}

function qipPlayMapKeyboardEventToKeysym(event) {
  const key = event.key || "";

  if (key === "ArrowLeft") return 0xff51;
  if (key === "ArrowUp") return 0xff52;
  if (key === "ArrowRight") return 0xff53;
  if (key === "ArrowDown") return 0xff54;
  if (key === "Shift") return event.location === 2 ? 0xffe2 : 0xffe1;
  if (key === "Escape") return 0xff1b;
  if (key === "Enter") return 0xff0d;
  if (key === "Tab") return 0xff09;
  if (key === "Backspace") return 0xff08;
  if (key === "Delete") return 0xffff;
  if (key === "Alt") return event.location === 2 ? 0xffea : 0xffe9;
  if (key === " ") return 0x20;

  if (key.length === 1) {
    return key.codePointAt(0) | 0;
  }

  return null;
}

function qipPlayShouldCaptureMetaKey(event, keysym) {
  // Preserve browser/app-level shortcuts by default, but allow the common
  // text-editing/navigation shortcuts modules expect.
  if (event.ctrlKey) return false;
  switch (keysym | 0) {
    case 0xff51: // Left
    case 0xff52: // Up
    case 0xff53: // Right
    case 0xff54: // Down
    case 0xff08: // Backspace
    case 0xffff: // Delete
    case 0xff50: // Home
    case 0xff57: // End
      return true;
    case 0x41: // A
    case 0x43: // C
    case 0x56: // V
    case 0x58: // X
    case 0x5a: // Z
    case 0x54: // T
    case 0x61: // a
    case 0x63: // c
    case 0x76: // v
    case 0x78: // x
    case 0x7a: // z
    case 0x74: // t
      return true;
    default:
      return false;
  }
}

function qipPlayBuildKeyFlags(event, isDown) {
  let flags = 0;
  if (isDown) flags |= 1 << 0;
  if (event.repeat) flags |= 1 << 1;
  if (event.shiftKey) flags |= 1 << 2;
  if (event.ctrlKey) flags |= 1 << 3;
  if (event.altKey) flags |= 1 << 4;
  if (event.metaKey) flags |= 1 << 5;
  return flags;
}

function qipPlayMapDOMButtonsToMask(buttons) {
  let mask = 0;
  if (buttons & 1) mask |= 1; // primary -> button 1
  if (buttons & 4) mask |= 2; // auxiliary -> button 2 (middle)
  if (buttons & 2) mask |= 4; // secondary -> button 3 (right)
  return mask;
}

function qipPlayKeyIdentity(event) {
  const code = event.code || "";
  if (code !== "") {
    return code;
  }
  return "key:" + (event.key || "");
}

function qipPlayCanvasXY(canvas, event, renderWidth, renderHeight) {
  const rect = canvas.getBoundingClientRect();
  const relX = rect.width > 0 ? (event.clientX - rect.left) / rect.width : 0;
  const relY = rect.height > 0 ? (event.clientY - rect.top) / rect.height : 0;

  let x = Math.floor(relX * renderWidth);
  let y = Math.floor(relY * renderHeight);

  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x >= renderWidth) x = renderWidth - 1;
  if (y >= renderHeight) y = renderHeight - 1;

  return { x, y };
}

async function qipPlayLoadModuleBytes(sourceURL) {
  const response = await fetch(sourceURL);
  if (!response.ok) {
    throw new Error(
      "failed to fetch module " +
        sourceURL +
        " (" +
        String(response.status) +
        ")",
    );
  }
  return await response.arrayBuffer();
}

function qipPlayGetInputElement(playElement) {
  return playElement.querySelector('input[name="input"], textarea[name="input"]');
}

function qipPlayGetInputSource(playElement) {
  return qipPlayDirectChildren(playElement, "source").find((source) =>
    (source.getAttribute("name") || "").trim() === "input" &&
    (source.getAttribute("type") || "").trim().toLowerCase() !== "application/wasm"
  ) || null;
}

function qipPlayOutputCapacity(exportsObj, contentType = "") {
  const utf8 = typeof exportsObj.output_utf8_cap === "function";
  const bytes = typeof exportsObj.output_bytes_cap === "function";
  if (utf8 === bytes) throw new Error("qip-play module must export exactly one output capacity getter");
  if (contentType === "image/svg+xml" && !utf8) {
    throw new Error("qip-play SVG output must declare output_utf8_cap");
  }
  return qipPlayReadI32Export(exportsObj, utf8 ? "output_utf8_cap" : "output_bytes_cap");
}

function qipPlayCustomProperty(computedStyle, propertyName, fallback) {
  if (!computedStyle) {
    return fallback;
  }
  const value = computedStyle.getPropertyValue(propertyName).trim();
  return value !== "" ? value : fallback;
}

function qipPlayPresentation(element, renderWidth) {
  const attrCanvasWidth = (element.getAttribute("canvas-width") || "").trim();
  const attrCanvasHeight = (element.getAttribute("canvas-height") || "").trim();
  const needsComputed = attrCanvasWidth === "" || attrCanvasHeight === "";
  const computedStyle = needsComputed ? getComputedStyle(element) : null;

  return {
    canvasWidth:
      attrCanvasWidth ||
      qipPlayCustomProperty(
        computedStyle,
        "--qip-play-canvas-width",
        String(renderWidth) + "px",
      ),
    canvasHeight:
      attrCanvasHeight ||
      qipPlayCustomProperty(
        computedStyle,
        "--qip-play-canvas-height",
        "auto",
      ),
  };
}

/**
 * <qip-play> is a light-DOM browser host for QIP Eventful components with
 * canonical KTX2 RGBA8 sRGB or RGBA32F linear Display P3 output.
 *
 * Static module policy:
 *
 * - Modules containing memory.grow are rejected by default.
 * - max-memory="<bytes>" rejects modules whose declared memory minimum or
 *   maximum exceeds the byte cap. A module with memory but no declared maximum
 *   is rejected when this attribute is set.
 * - allow-memory-grow permits memory.grow and requires max-memory.
 */
class QIPPlayElement extends HTMLElement {
  constructor() {
    super();
    this._started = false;
    this._rafID = 0;
    this._timeoutID = 0;
    this._timeoutTargetMS = 0;

    this._exports = null;
    this._memory = null;
    this._uniforms = [];
    this._inputSize = 0;
    this._finishedAtMS = 0;
    this._needsRender = false;
    this._initialFrame = null;

    this._canvas = null;
    this._presentationElement = null;
    this._contentType = "";
    this._svgBlobURL = "";
    this._svgLoadGeneration = 0;
    this._ctx = null;
    this._imageData = null;
    this._presentationConvert = null;
    this._presentationSourceProfileKey = "";
    this._presentationN = 0;
    this._outputProfile = null;
    this._canvasProfile = null;
    this._debugPreviousPixels = null;
    this._stats = null;

    this._outputBytes = 0;
    this._outputCapacity = 0;
    this._renderWidth = 0;
    this._renderHeight = 0;
    this._expectedOutputBytes = 0;
    this._wasmByteLength = 0;
    this._debugStats = false;
    this._logTimings = false;
    this._lastUpdateMS = 0;
    this._lastRenderMS = 0;
    this._lastDrawMS = 0;
    this._lastCompareMS = 0;
    this._lastRenderUnchanged = false;

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundPointerLeave = null;
    this._boundContextMenu = null;
    this._boundClickFocus = null;
    this._boundFrame = null;
    this._boundBlur = null;
    this._boundInputChange = null;
    this._boundVisibilityChange = null;
    this._intersectionObserver = null;
    this._isIntersecting = true;
    this._inputElement = null;
    this._sourceElement = null;
    this._steps = [];
    this._postStages = [];
    this._eventN = 0;
    this._updateN = 0;
    this._renderN = 0;
    this._unchangedRenderN = 0;
    this._drawN = 0;
    this._hasRenderedFrame = false;
    this._activeKeyRepeats = new Map();
    this._pendingEvents = [];
    this._eventSequence = 0;
    this._shiftKeyDown = false;
    this._altKeyDown = false;
    this._nextWakeAtMS = 0;
    this._timeOriginMS = 0;
  }

  async connectedCallback() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      await this._init();
      this._timeOriginMS = qipPlayPerfNow();
      this._runBootstrapUpdate();
      this._resumeLoop();
    } catch (err) {
      this._renderError(err);
    }
  }

  disconnectedCallback() {
    this._cancelScheduledLoop();
    if (this._intersectionObserver) {
      this._intersectionObserver.disconnect();
      this._intersectionObserver = null;
    }
    this._nextWakeAtMS = 0;
    this._timeOriginMS = 0;
    this._detachInputBinding();
    this._discardPendingInput();
    this._detachInputHandlers();
    if (this._boundVisibilityChange && typeof document.removeEventListener === "function") {
      document.removeEventListener("visibilitychange", this._boundVisibilityChange);
    }
    this._boundVisibilityChange = null;
    this._revokeSVGBlobURL();
  }

  async _init() {
    const stepRecords = qipPlaySourceSteps(this);
    const sourceElement = stepRecords[0].sourceElement;
    const inputElement = qipPlayGetInputElement(this);
    const inputSource = qipPlayGetInputSource(this);
    const policy = qipPlayReadModulePolicy(this);
    const loaded = [];
    for (let index = 0; index < stepRecords.length; index++) {
      const stepRecord = stepRecords[index];
      const candidateSources = index === 0 ? [stepRecord.sourceElement] : stepRecord.sourceElements;
      const candidates = [];
      for (const candidateSource of candidateSources) {
        const srcRaw = (candidateSource.getAttribute("src") || "").trim();
        if (srcRaw === "") {
          throw new Error("<qip-play> <source> requires a non-empty src");
        }
        const sourceURL = new URL(srcRaw, document.baseURI).toString();
        const moduleBytes = await qipPlayLoadModuleBytes(sourceURL);
        qipPlayValidateWasmModulePolicy(moduleBytes, policy, sourceURL);
        const instantiated = await WebAssembly.instantiate(moduleBytes, {});
        const exportsObj =
          (instantiated && instantiated.instance && instantiated.instance.exports) ||
          (instantiated && instantiated.exports) ||
          null;
        if (!exportsObj) throw new Error("failed to access wasm exports for qip-play module");
        if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
          throw new Error("qip-play module must export memory");
        }
        candidates.push({
          sourceElement: candidateSource,
          sourceURL,
          sourceLabel: qipPlaySourceLabel(candidateSource),
          moduleBytes: moduleBytes.byteLength,
          exports: exportsObj,
          memory: exportsObj.memory,
          outputCapacity: 0,
          renderN: 0,
          lastRenderMS: 0,
        });
      }
      const label = qipPlayStepLabel(stepRecord, index);
      if (index === 0) {
        loaded.push({ ...stepRecord, ...candidates[0], label, candidates });
      } else {
        loaded.push({
          ...stepRecord,
          label,
          candidates,
          moduleBytes: candidates.reduce((total, candidate) => total + candidate.moduleBytes, 0),
          renderN: 0,
          lastRenderMS: 0,
          selectedSourceLabel: "",
          selectedCandidate: null,
        });
      }
    }

    const primary = loaded[0];
    const exportsObj = primary.exports;

    const requiredExports = [
      "output_content_type_ptr",
      "output_content_type_size",
      "begin_update_at",
      "finish_update",
      "render",
    ];
    for (const name of requiredExports) {
      if (!(name in exportsObj)) {
        throw new Error("qip-play module missing export " + name);
      }
    }

    let precedingOutputType = qipPlayReadDeclaredContentType(
      primary.exports, primary.memory, "output_content_type_ptr", "output_content_type_size",
    );
    primary.outputCapacity = qipPlayOutputCapacity(primary.exports, precedingOutputType);
    for (const stage of loaded.slice(1)) {
      precedingOutputType = qipPlayValidatePostStage(stage, precedingOutputType);
    }

    this._exports = exportsObj;
    this._memory = exportsObj.memory;
    this._steps = loaded;
    this._postStages = loaded.slice(1);
    this._sourceElement = sourceElement;
    this._uniforms = qipPlayExtractUniforms(sourceElement);
    this._wasmByteLength = loaded.reduce((total, step) => total + step.moduleBytes, 0);
    this._debugStats = this.hasAttribute("debug");
    this._logTimings = this.hasAttribute("log");

    await this._setupInitialInput(inputSource, inputElement);

    this._outputCapacity = primary.outputCapacity;
    const contentType = precedingOutputType;
    if (contentType !== "image/ktx2" && contentType !== "image/svg+xml") {
      throw new Error("qip-play presentation output must declare image/ktx2 or image/svg+xml");
    }
    this._contentType = contentType;
    const initial = this._runInitialContentRender();
    const parsed = contentType === "image/ktx2" ? this._readKTX2Output(initial.rendered) : null;
    this._renderWidth = parsed?.width || 800;
    this._renderHeight = parsed?.height || 600;
    this._expectedOutputBytes = parsed?.sourceBytes.byteLength || 0;
    this._outputBytes = initial.rendered.outputLen;
    this._initialFrame = { ...initial, parsed };

    const presentation = qipPlayPresentation(this, this._renderWidth);
    if (parsed) this._installPresentation(parsed);
    else this._installSVGPresentation();

    this._stats = document.createElement("aside");
    this._stats.setAttribute("aria-label", "qip-play stats");
    this._stats.style.boxSizing = "border-box";
    this._stats.style.marginTop = "6px";
    this._stats.style.maxWidth = presentation.canvasWidth;
    this._stats.style.font = "11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
    this._stats.style.color = "#666";
    this._stats.style.whiteSpace = "pre-wrap";
    this._stats.style.lineHeight = "1.35";
    this._updateStats();

    if (this._initialFrame && parsed) {
      this._presentPixels(
        this._initialFrame.parsed.pixels,
        this._initialFrame.renderMS,
        "initial",
      );
      this._initialFrame = null;
    } else if (this._initialFrame) {
      this._presentSVGOutput(this._initialFrame.rendered, this._initialFrame.renderMS, "initial");
      this._initialFrame = null;
    }

    this.replaceChildren(this._presentationElement || this._canvas);
    if (inputElement) {
      this.appendChild(inputElement);
    }
    this.appendChild(this._stats);
    this._attachInputHandlers();
    this._setupIntersectionObserver();
    if (typeof document.addEventListener === "function") {
      this._boundVisibilityChange = () => {
        if (!document.hidden) {
          this._needsRender = true;
          this._resumeLoop();
        }
      };
      document.addEventListener("visibilitychange", this._boundVisibilityChange);
    }
  }

  _setupIntersectionObserver() {
    if (typeof globalThis.IntersectionObserver !== "function") {
      return;
    }
    this._intersectionObserver = new globalThis.IntersectionObserver((entries) => {
      let latest = null;
      for (const entry of entries) {
        if (entry.target === this) latest = entry;
      }
      if (!latest) return;
      const isIntersecting = Boolean(latest.isIntersecting);
      if (isIntersecting === this._isIntersecting) return;

      this._isIntersecting = isIntersecting;
      this._cancelScheduledLoop();
      if (isIntersecting) this._needsRender = true;
      // Offscreen Timed wakes are suspended, but queued user input remains
      // eligible so a focused component cannot accumulate stale events.
      this._resumeLoop();
    });
    this._intersectionObserver.observe(this);
  }

  _cancelScheduledLoop() {
    if (this._rafID !== 0 && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this._rafID);
      this._rafID = 0;
    }
    if (this._timeoutID !== 0) {
      clearTimeout(this._timeoutID);
      this._timeoutID = 0;
    }
    this._timeoutTargetMS = 0;
  }

  _canPresent() {
    return this._isIntersecting && !document.hidden;
  }

  async _setupInitialInput(inputSource, inputElement) {
    if (!inputSource && !inputElement) return;
    if (
      !("input_ptr" in this._exports) ||
      !("input_utf8_cap" in this._exports)
    ) {
      throw new Error(
        '<qip-play> SVG input requires module exports input_ptr and input_utf8_cap',
      );
    }
    this._inputElement = inputElement;
    if (inputSource) {
      const declaredInputType = qipPlayReadDeclaredContentType(
        this._exports, this._memory, "input_content_type_ptr", "input_content_type_size",
      );
      const sourceType = (inputSource.getAttribute("type") || "").trim().toLowerCase();
      if (declaredInputType === "" || sourceType !== declaredInputType) {
        throw new Error('<qip-play> <source name="input"> type must exactly match the module input content type');
      }
      const src = (inputSource.getAttribute("src") || "").trim();
      if (src === "") throw new Error('<qip-play> <source name="input"> requires a non-empty src');
      const response = await fetch(new URL(src, document.baseURI).toString());
      if (!response.ok) throw new Error("failed to fetch qip-play input source (" + String(response.status) + ")");
      this._writeInputText(await response.text());
    } else {
      this._writeInputText(String(inputElement.value ?? inputElement.textContent ?? ""));
    }
  }

  _installSVGPresentation() {
    const image = document.createElement("img");
    const cssPresentation = qipPlayPresentation(this, 800);
    image.alt = this.getAttribute("aria-label") || "Interactive SVG editor";
    image.draggable = false;
    image.style.display = "block";
    image.style.width = cssPresentation.canvasWidth;
    image.style.height = cssPresentation.canvasHeight;
    image.style.touchAction = this.getAttribute("touch-action")?.trim() || "none";
    image.tabIndex = this.hasAttribute("tabindex") ? this.tabIndex : 0;
    this.removeAttribute("tabindex");
    this._canvas = image;
    this._presentationElement = image;
    this._renderWidth = 800;
    this._renderHeight = 600;
  }

  _revokeSVGBlobURL() {
    if (this._svgBlobURL) URL.revokeObjectURL(this._svgBlobURL);
    this._svgBlobURL = "";
  }

  _presentSVGOutput(rendered, renderMS, reason) {
    if (rendered.outputLen < 0 || rendered.outputLen > rendered.outputCapacity) {
      throw new Error("qip-play Timed render returned output outside output_utf8_cap");
    }
    const source = qipPlayReadSlice(rendered.memory, rendered.outputPtr, rendered.outputLen, "output_ptr/output_utf8_cap");
    // Copy before the next component render can reuse its output buffer.
    const blob = new Blob([source.slice()], { type: "image/svg+xml" });
    const nextURL = URL.createObjectURL(blob);
    const previousURL = this._svgBlobURL;
    const generation = ++this._svgLoadGeneration;
    this._svgBlobURL = nextURL;
    this._canvas.onload = () => {
      if (generation !== this._svgLoadGeneration) return;
      if (previousURL) URL.revokeObjectURL(previousURL);
    };
    this._canvas.onerror = () => {
      if (generation === this._svgLoadGeneration) URL.revokeObjectURL(nextURL);
    };
    this._canvas.src = nextURL;
    this._renderN++;
    this._drawN++;
    this._hasRenderedFrame = true;
    this._lastRenderMS = renderMS;
    this._updateStats();
    if (this._logTimings && reason === "initial") console.log("[qip-play] initial_render_ms=%s", qipPlayFormatMS(renderMS));
  }

  _installPresentation(parsed) {
    const initial = this._presentationN === 0;
    const replacement = qipPlayCreatePresentation(parsed);
    const oldCanvas = this._canvas;
    const hadFocus = oldCanvas && typeof document !== "undefined" && document.activeElement === oldCanvas;
    if (oldCanvas) this._detachInputHandlers();

    const canvas = replacement.canvas;
    const cssPresentation = qipPlayPresentation(this, parsed.width);
    canvas.style.display = "block";
    canvas.style.width = cssPresentation.canvasWidth;
    canvas.style.height = cssPresentation.canvasHeight;
    canvas.style.touchAction = this.getAttribute("touch-action")?.trim() || "none";
    canvas.tabIndex = initial
      ? (this.hasAttribute("tabindex") ? this.tabIndex : 0)
      : (oldCanvas?.tabIndex ?? 0);
    if (initial) this.removeAttribute("tabindex");

    this._canvas = canvas;
    this._presentationElement = canvas;
    this._ctx = replacement.ctx;
    this._imageData = replacement.imageData;
    this._presentationConvert = replacement.convert;
    this._presentationSourceProfileKey = qipPlayProfileKey(parsed.profile);
    this._outputProfile = parsed.profile;
    this._canvasProfile = replacement.canvasProfile;
    this._renderWidth = parsed.width;
    this._renderHeight = parsed.height;
    this._expectedOutputBytes = parsed.sourceBytes.byteLength;
    this._hasRenderedFrame = false;
    this._debugPreviousPixels = null;
    this._presentationN++;

    if (oldCanvas && typeof oldCanvas.replaceWith === "function") {
      oldCanvas.replaceWith(canvas);
      this._attachInputHandlers();
      if (hadFocus && typeof canvas.focus === "function") canvas.focus();
    }
  }

  _detachInputBinding() {
    const inputElement = this._inputElement;
    if (inputElement && this._boundInputChange) {
      inputElement.removeEventListener("input", this._boundInputChange);
      inputElement.removeEventListener("change", this._boundInputChange);
    }
    this._inputElement = null;
    this._boundInputChange = null;
  }

  _writeInputText(inputText) {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(inputText);

    const inputPtr = qipPlayReadI32Export(this._exports, "input_ptr");
    const inputCap = qipPlayReadI32Export(this._exports, "input_utf8_cap");
    if (inputCap < 0 || inputPtr < 0) {
      throw new Error(
        "qip-play input exports returned invalid pointer/capacity",
      );
    }
    if (bytes.length > inputCap) {
      throw new Error(
        "qip-play input text exceeds module input_utf8_cap: " +
          String(bytes.length) +
          " > " +
          String(inputCap),
      );
    }

    const capSlice = qipPlayReadSlice(
      this._memory,
      inputPtr,
      inputCap,
      "input_ptr/input_utf8_cap",
    );
    capSlice.fill(0);
    capSlice.set(bytes, 0);
    this._inputSize = bytes.length;

    // Keep qip-play contract-simple: write input bytes only. Modules read the
    // initial source during their first Content render.
    this._nextWakeAtMS = 0;
    this._resumeLoop();
  }

  _applyUniforms() {
    const uniforms = this._sourceElement
      ? qipPlayExtractUniforms(this._sourceElement)
      : this._uniforms;
    for (const uniform of uniforms) {
      qipPlayApplyUniform(this._exports, uniform);
    }
  }

  _decodeRenderResult(renderResult, step = null, allowFailure = false) {
    const exportsObj = step?.exports || this._exports;
    if (typeof renderResult !== "bigint") {
      throw new TypeError("qip-play render export must have signature render(i32) -> i64");
    }
    const bits = BigInt.asUintN(64, renderResult);
    const outputLen = Number(bits & 0xffff_ffffn);
    if ((bits & (1n << 63n)) !== 0n) {
      if (typeof exportsObj.failure_modes_per_input_offset !== "function") {
        throw new Error("qip-play render returned failure without failure_modes_per_input_offset");
      }
      const modes = qipPlayReadI32Export(exportsObj, "failure_modes_per_input_offset") >>> 0;
      if (modes === 0 && outputLen !== 0) {
        throw new Error("qip-play render returned failure detail despite declaring no failure modes");
      }
      const position = modes === 0 ? 0 : Math.floor(outputLen / modes);
      const mode = modes === 0 ? 0 : outputLen % modes;
      const message = modes === 0
        ? "qip-play input was rejected"
        : modes === 1
          ? "qip-play input was rejected at input offset " + position
          : "qip-play input was rejected at input offset " + position + " with mode " + mode;
      if (allowFailure) return { failed: true, failureDetail: outputLen, message };
      throw new Error(message);
    }
    return {
      outputLen,
      outputPtr: Number((bits >> 32n) & 0x7fff_ffffn),
      memory: step?.memory || this._memory,
      outputCapacity: step?.outputCapacity ?? this._outputCapacity,
    };
  }

  _readKTX2Output(rendered) {
    const { outputLen, outputPtr } = rendered;
    const memory = rendered.memory || this._memory;
    const outputCapacity = rendered.outputCapacity ?? this._outputCapacity;
    if (outputLen < 0 || outputLen > outputCapacity) {
      throw new Error("qip-play Timed render returned output outside output_bytes_cap");
    }
    const bytes = qipPlayReadSlice(
      memory,
      outputPtr,
      outputLen,
      "output_ptr/output_bytes_cap",
    );
    return qipPlayParseKTX2(bytes);
  }

  _runInitialContentRender() {
    const { rendered, renderMS } = this._runPresentationPipeline(this._inputSize);
    this._renderN++;
    this._lastRenderMS = renderMS;
    this._finishedAtMS = 0;
    this._nextWakeAtMS = 0;
    return { rendered, renderMS };
  }

  _runPresentationPipeline(inputSize) {
    const pipelineStart = qipPlayPerfNow();
    this._applyUniforms();
    const primaryStart = qipPlayPerfNow();
    let rendered = this._decodeRenderResult(this._exports.render(inputSize), this._steps[0] || null);
    const primaryMS = qipPlayPerfNow() - primaryStart;
    if (this._steps[0]) {
      this._steps[0].renderN++;
      this._steps[0].lastRenderMS = primaryMS;
    }

    for (const stage of this._postStages) {
      if (rendered.outputLen < 0 || rendered.outputLen > rendered.outputCapacity) {
        throw new Error("qip-play pipeline output exceeds the preceding step capacity");
      }
      const inputBytes = qipPlayReadSlice(
        rendered.memory,
        rendered.outputPtr,
        rendered.outputLen,
        "qip-play pipeline input",
      );
      const candidates = stage.selectedCandidate
        ? [stage.selectedCandidate]
        : stage.candidates || [stage];
      const stageIsCandidate = !stage.candidates;
      let accepted = null;
      let stageRenderMS = 0;
      for (const candidate of candidates) {
        if (inputBytes.byteLength > candidate.inputCapacity) continue;
        const destination = qipPlayReadSlice(
          candidate.memory,
          candidate.inputPtr,
          candidate.inputCapacity,
          "qip-play post-processing input_ptr/input capacity",
        );
        destination.set(inputBytes, 0);
        for (const uniform of qipPlayExtractUniforms(candidate.sourceElement)) {
          qipPlayApplyUniform(candidate.exports, uniform);
        }
        const candidateStart = qipPlayPerfNow();
        const outcome = this._decodeRenderResult(
          candidate.exports.render(inputBytes.byteLength), candidate, true,
        );
        const candidateMS = qipPlayPerfNow() - candidateStart;
        candidate.lastRenderMS = candidateMS;
        candidate.renderN++;
        stageRenderMS += candidateMS;
        if (!outcome.failed) {
          accepted = outcome;
          stage.selectedCandidate = candidate;
          stage.candidates = [candidate];
          stage.selectedSourceLabel = candidate.sourceLabel || qipPlaySourceLabel(candidate.sourceElement);
          break;
        }
      }
      stage.lastRenderMS = stageRenderMS;
      if (!stageIsCandidate) stage.renderN++;
      if (!accepted) {
        throw new Error("qip-play post-processing step " + stage.label + " was rejected by every source");
      }
      rendered = accepted;
    }
    return { rendered, renderMS: qipPlayPerfNow() - pipelineStart };
  }

  _readFinishedUpdate(begunAtMS) {
    let result;
    try {
      result = this._exports.finish_update();
    } catch (cause) {
      throw new Error("qip-play finish_update trapped; the host or component broke the update lifecycle: " + (cause?.message ?? cause), { cause });
    }
    if (typeof result !== "bigint") {
      throw new TypeError("qip-play finish_update export must have signature finish_update() -> i64");
    }
    const value = qipPlayI64MSAsNumber(result, "finish_update");
    if (value < begunAtMS) {
      throw new Error("qip-play finish_update returned a time before the update time");
    }
    return value === begunAtMS ? 0 : value;
  }

  _runBootstrapUpdate() {
    const begunAtMS = 1;
    const updateStart = qipPlayPerfNow();
    this._exports.begin_update_at(qipPlayNowMSArg(begunAtMS));
    this._applyUniforms();
    this._nextWakeAtMS = this._readFinishedUpdate(begunAtMS);
    this._finishedAtMS = begunAtMS;
    this._updateN++;
    this._lastUpdateMS = qipPlayPerfNow() - updateStart;
  }

  _runUpdate(nowMS, renderRequested) {
    const begunAtMS = Math.max(Math.floor(nowMS), this._finishedAtMS + 1);
    const updateStart = qipPlayPerfNow();
    this._exports.begin_update_at(qipPlayNowMSArg(begunAtMS));
    this._applyUniforms();
    const eventResult = this._drainEvents(nowMS);
    const shouldRender = this._canPresent() && (renderRequested || eventResult.accepted);
    let rendered = null;
    let renderMS = 0;
    const nextWakeAtMS = this._readFinishedUpdate(begunAtMS);
    if (shouldRender) {
      const presentation = this._runPresentationPipeline(0);
      rendered = presentation.rendered;
      renderMS = presentation.renderMS;
    }
    const updateMS = qipPlayPerfNow() - updateStart - renderMS;
    this._updateN++;
    this._lastUpdateMS = updateMS;
    this._finishedAtMS = begunAtMS;
    this._nextWakeAtMS = nextWakeAtMS;
    if (shouldRender) {
      if (this._contentType === "image/svg+xml") this._presentSVGOutput(rendered, renderMS);
      else this._presentKTX2Output(this._readKTX2Output(rendered), renderMS);
    } else {
      this._updateStats();
    }
    return {
      nextWakeAtMS,
      updateMS,
      renderMS,
      eventCount: eventResult.eventCount,
      acceptedEvent: eventResult.accepted,
      rendered: shouldRender,
    };
  }

  _presentKTX2Output(parsed, renderMS) {
    const descriptorChanged =
      parsed.width !== this._renderWidth ||
      parsed.height !== this._renderHeight ||
      (this._presentationSourceProfileKey !== "" &&
        qipPlayProfileKey(parsed.profile) !== this._presentationSourceProfileKey);
    if (this._presentationSourceProfileKey !== "" && descriptorChanged) {
      this._installPresentation(parsed);
    } else if (parsed.width !== this._renderWidth || parsed.height !== this._renderHeight) {
      // Direct host tests can supply their own canvas without running _init().
      this._renderWidth = parsed.width;
      this._renderHeight = parsed.height;
      this._expectedOutputBytes = parsed.sourceBytes.byteLength;
      this._canvas.width = parsed.width;
      this._canvas.height = parsed.height;
      this._imageData = this._ctx.createImageData(parsed.width, parsed.height);
      this._hasRenderedFrame = false;
    }
    if (this._presentationSourceProfileKey === "") {
      this._presentationSourceProfileKey = qipPlayProfileKey(parsed.profile);
      this._outputProfile = parsed.profile;
      this._canvasProfile = parsed.profile;
    }
    this._renderN++;
    this._presentPixels(parsed.pixels, renderMS);
  }

  _attachInputHandlers() {
    if (!this._exports || !this._canvas) {
      return;
    }
    if (
      typeof this._exports.key_event !== "function" &&
      typeof this._exports.pointer_event !== "function"
    ) {
      return;
    }

    this._boundKeyDown = (event) => {
      this._dispatchKey(event, true);
    };
    this._boundKeyUp = (event) => {
      this._dispatchKey(event, false);
    };

    this._boundPointer = (event) => {
      this._dispatchPointer(event);
    };
    this._boundPointerUp = (event) => {
      this._dispatchPointer(event);
    };
    this._boundPointerLeave = () => {
      if (!this._exports || typeof this._exports.pointer_event !== "function") {
        return;
      }
      this._queuePointerEvent(0, -1, -1, this._eventNowMS());
      this._resumeLoop();
    };
    this._boundContextMenu = (event) => {
      event.preventDefault();
      event.stopPropagation();
    };

    this._boundClickFocus = () => {
      this._canvas.focus();
    };
    this._boundBlur = () => {
      this._releaseHeldInput();
    };

    this._canvas.addEventListener("keydown", this._boundKeyDown);
    this._canvas.addEventListener("keyup", this._boundKeyUp);
    this._canvas.addEventListener("pointerdown", this._boundPointer);
    this._canvas.addEventListener("pointermove", this._boundPointer);
    this._canvas.addEventListener("pointerup", this._boundPointerUp);
    this._canvas.addEventListener("pointercancel", this._boundPointerUp);
    this._canvas.addEventListener("pointerleave", this._boundPointerLeave);
    this._canvas.addEventListener("contextmenu", this._boundContextMenu, true);
    this._canvas.addEventListener("click", this._boundClickFocus);
    this._canvas.addEventListener("blur", this._boundBlur);
  }

  _detachInputHandlers() {
    if (this._canvas) {
      if (this._boundKeyDown) {
        this._canvas.removeEventListener("keydown", this._boundKeyDown);
      }
      if (this._boundKeyUp) {
        this._canvas.removeEventListener("keyup", this._boundKeyUp);
      }
      if (this._boundPointer) {
        this._canvas.removeEventListener("pointerdown", this._boundPointer);
        this._canvas.removeEventListener("pointermove", this._boundPointer);
      }
      if (this._boundPointerUp) {
        this._canvas.removeEventListener("pointerup", this._boundPointerUp);
        this._canvas.removeEventListener("pointercancel", this._boundPointerUp);
      }
      if (this._boundPointerLeave) {
        this._canvas.removeEventListener("pointerleave", this._boundPointerLeave);
      }
      if (this._boundContextMenu) {
        this._canvas.removeEventListener(
          "contextmenu",
          this._boundContextMenu,
          true,
        );
      }
      if (this._boundClickFocus) {
        this._canvas.removeEventListener("click", this._boundClickFocus);
      }
      if (this._boundBlur) {
        this._canvas.removeEventListener("blur", this._boundBlur);
      }
    }

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundPointerLeave = null;
    this._boundContextMenu = null;
    this._boundClickFocus = null;
    this._boundBlur = null;
  }

  _dispatchKey(event, isDown) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return;
    }

    const keysym = qipPlayMapKeyboardEventToKeysym(event);
    if (keysym === null) {
      return;
    }

    if (event.metaKey && !qipPlayShouldCaptureMetaKey(event, keysym)) {
      return;
    }

    event.preventDefault();
    const keyID = qipPlayKeyIdentity(event);

    // Ignore browser-generated repeat bursts; we drive repeat ourselves.
    if (isDown && event.repeat) {
      return;
    }
    if (isDown && this._activeKeyRepeats.has(keyID)) {
      return;
    }

    const flags = qipPlayBuildKeyFlags(event, isDown);
    const eventNowMS = this._eventNowMS();
    this._queueKeyEvent(keysym | 0, flags | 0, eventNowMS);
    if (keysym === 0xffe1 || keysym === 0xffe2) this._shiftKeyDown = isDown;
    if (keysym === 0xffe9 || keysym === 0xffea) this._altKeyDown = isDown;
    if (isDown) {
      this._startKeyRepeat(keyID, keysym, event);
    } else {
      this._stopKeyRepeat(keyID, true);
    }
    this._resumeLoop();
  }

  _dispatchPointer(event) {
    if (
      !this._exports ||
      !this._canvas ||
      typeof this._exports.pointer_event !== "function"
    ) {
      return;
    }

    if (this._canvas.style.touchAction === "none") event.preventDefault();
    if (event.type === "pointerdown" && typeof this._canvas.setPointerCapture === "function") {
      this._canvas.setPointerCapture(event.pointerId);
      this._canvas.focus();
    }

    const coords = qipPlayCanvasXY(
      this._canvas,
      event,
      this._renderWidth,
      this._renderHeight,
    );
    const buttonMask = qipPlayMapDOMButtonsToMask(event.buttons | 0);
    const eventNowMS = this._eventNowMS();
    if (typeof this._exports.key_event === "function") {
      const shiftDown = Boolean(event.shiftKey);
      const altDown = Boolean(event.altKey);
      if (shiftDown !== this._shiftKeyDown) {
        this._queueKeyEvent(0xffe1, qipPlayBuildKeyFlags(event, shiftDown), eventNowMS);
        this._shiftKeyDown = shiftDown;
      }
      if (altDown !== this._altKeyDown) {
        this._queueKeyEvent(0xffe9, qipPlayBuildKeyFlags(event, altDown), eventNowMS);
        this._altKeyDown = altDown;
      }
    }
    this._queuePointerEvent(
      buttonMask | 0,
      coords.x | 0,
      coords.y | 0,
      eventNowMS,
    );
    if ((event.type === "pointerup" || event.type === "pointercancel") && typeof this._canvas.releasePointerCapture === "function" && this._canvas.hasPointerCapture?.(event.pointerId)) {
      this._canvas.releasePointerCapture(event.pointerId);
    }
    this._resumeLoop();
  }

  _startKeyRepeat(keyID, keysym, baseEvent) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return;
    }
    if (this._activeKeyRepeats.has(keyID)) {
      return;
    }

    const repeatFlags = qipPlayBuildKeyFlags(baseEvent, true) | (1 << 1);
    const repeatState = {
      timeoutID: 0,
      keysym: keysym | 0,
      flags: repeatFlags | 0,
      pending: false,
      pendingTimeMS: 0,
      pendingSequence: 0,
    };

    const runRepeat = () => {
      if (!this._activeKeyRepeats.has(keyID)) {
        return;
      }
      repeatState.pending = true;
      repeatState.pendingTimeMS = this._eventNowMS();
      repeatState.pendingSequence = ++this._eventSequence;
      this._resumeLoop();
      repeatState.timeoutID = setTimeout(
        runRepeat,
        QIP_PLAY_KEY_REPEAT_INTERVAL_MS,
      );
    };

    repeatState.timeoutID = setTimeout(runRepeat, QIP_PLAY_KEY_REPEAT_DELAY_MS);
    this._activeKeyRepeats.set(keyID, repeatState);
  }

  _stopKeyRepeat(keyID, keepPending = false) {
    const repeatState = this._activeKeyRepeats.get(keyID);
    if (!repeatState) {
      return;
    }
    if (repeatState.timeoutID !== 0) {
      clearTimeout(repeatState.timeoutID);
    }
    if (keepPending && repeatState.pending) {
      this._pendingEvents.push({
        type: "key",
        keysym: repeatState.keysym,
        flags: repeatState.flags,
        timeMS: repeatState.pendingTimeMS,
        sequence: repeatState.pendingSequence,
      });
      this._pendingEvents.sort(qipPlayCompareQueuedEvents);
    }
    this._activeKeyRepeats.delete(keyID);
  }

  _discardPendingInput() {
    for (const keyID of this._activeKeyRepeats.keys()) {
      this._stopKeyRepeat(keyID);
    }
    this._pendingEvents.length = 0;
  }

  _releaseHeldInput() {
    const timeMS = this._eventNowMS();
    for (const [keyID, repeatState] of this._activeKeyRepeats) {
      this._stopKeyRepeat(keyID, true);
      this._queueKeyEvent(repeatState.keysym, repeatState.flags & ~3, timeMS);
    }
    this._shiftKeyDown = false;
    this._altKeyDown = false;
    if (typeof this._exports?.pointer_event === "function") {
      this._queuePointerEvent(0, -1, -1, timeMS);
    }
    this._resumeLoop();
  }

  _queueKeyEvent(keysym, flags, timeMS) {
    this._eventN++;
    this._pendingEvents.push({
      type: "key",
      keysym: keysym | 0,
      flags: flags | 0,
      timeMS,
      sequence: ++this._eventSequence,
    });
    this._pendingEvents.sort(qipPlayCompareQueuedEvents);
  }

  _queuePointerEvent(buttonMask, x, y, timeMS) {
    this._eventN++;
    this._pendingEvents.push({
      type: "pointer",
      buttonMask: buttonMask | 0,
      x: x | 0,
      y: y | 0,
      timeMS,
      sequence: ++this._eventSequence,
    });
    this._pendingEvents.sort(qipPlayCompareQueuedEvents);
  }

  _eventNowMS() {
    if (this._timeOriginMS <= 0) {
      return 0;
    }
    const elapsed = qipPlayPerfNow() - this._timeOriginMS;
    if (elapsed <= 0) {
      return 0;
    }
    return Math.floor(elapsed);
  }

  _flushPendingEvents(updateNowMS) {
    const due = [];
    while (this._pendingEvents.length > 0 && this._pendingEvents[0].timeMS <= updateNowMS) {
      due.push(this._pendingEvents.shift());
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending && repeatState.pendingTimeMS <= updateNowMS) {
        due.push({
          type: "key-repeat",
          keysym: repeatState.keysym,
          flags: repeatState.flags,
          timeMS: repeatState.pendingTimeMS,
          sequence: repeatState.pendingSequence,
          repeatState,
        });
      }
    }
    due.sort(qipPlayCompareQueuedEvents);

    let flushed = 0;
    let accepted = false;
    for (const evt of due) {
      let result = 0;
      if (evt.type === "pointer") {
        if (typeof this._exports?.pointer_event === "function") {
          result = this._exports.pointer_event(evt.buttonMask, evt.x, evt.y);
        }
      } else {
        if (evt.repeatState) evt.repeatState.pending = false;
        if (typeof this._exports?.key_event === "function") {
          result = this._exports.key_event(evt.keysym, evt.flags);
        }
      }
      if (Number(result) !== 0) accepted = true;
      flushed += 1;
    }
    return { count: flushed, accepted };
  }

  _resumeLoop() {
    const nowMS = this._eventNowMS();
    const immediate = this._hasReadyWork(nowMS);
    if (!immediate && this._nextWakeAtMS === 0 && !this._hasPendingFutureWork()) {
      return;
    }
    if (!this._boundFrame) {
      this._boundFrame = (nowMS) => {
        this._rafID = 0;
        this._timeoutID = 0;
        this._timeoutTargetMS = 0;
        this._frame(nowMS);
        this._resumeLoop();
      };
    }

    if (immediate) {
      if (this._timeoutID !== 0) {
        clearTimeout(this._timeoutID);
        this._timeoutID = 0;
        this._timeoutTargetMS = 0;
      }
      if (this._rafID !== 0) {
        return;
      }
      if (typeof requestAnimationFrame === "function") {
        this._rafID = requestAnimationFrame(this._boundFrame);
        return;
      }
      this._scheduleTimeout(1, nowMS + 1);
      return;
    }

    if (this._rafID !== 0) {
      return;
    }
    const delayMS = this._nextDelayMS(nowMS);
    const targetMS = nowMS + delayMS;
    if (this._timeoutID !== 0 && this._timeoutTargetMS <= targetMS) {
      return;
    }
    if (this._timeoutID !== 0) {
      clearTimeout(this._timeoutID);
      this._timeoutID = 0;
      this._timeoutTargetMS = 0;
    }
    this._scheduleTimeout(delayMS, targetMS);
  }

  _scheduleTimeout(delayMS, targetMS) {
    this._timeoutTargetMS = targetMS;
    this._timeoutID = setTimeout(() => this._boundFrame(qipPlayPerfNow()), delayMS);
  }

  _frame(nowMS) {
    this._frameUpdate(nowMS);
  }

  _frameUpdate(nowMS) {
    if (!this._exports) return;
    const updateNowMS = this._elapsedFromPerfNow(nowMS);
    const wakeDue = this._isIntersecting && this._nextWakeAtMS > 0 && updateNowMS >= this._nextWakeAtMS;
    const eventsDue = this._hasDueEvents(updateNowMS);
    const presentationDue = this._needsRender && this._canPresent();
    if (!wakeDue && !eventsDue && !presentationDue) return;
    if (!wakeDue && !eventsDue) {
      this._needsRender = false;
      const presentation = this._runPresentationPipeline(0);
      if (this._contentType === "image/svg+xml") this._presentSVGOutput(presentation.rendered, presentation.renderMS);
      else this._presentKTX2Output(this._readKTX2Output(presentation.rendered), presentation.renderMS);
      return;
    }
    const renderRequested = this._canPresent() && (this._needsRender || wakeDue);
    if (renderRequested) this._needsRender = false;
    const result = this._runUpdate(updateNowMS, renderRequested);
    if (this._logTimings) {
      console.log(
        "[qip-play] now_ms=%d events=%d next_wake_at_ms=%d update_ms=%s render_ms=%s frame_ms=%s",
        this._finishedAtMS,
        result.eventCount,
        result.nextWakeAtMS,
        qipPlayFormatMS(result.updateMS),
        qipPlayFormatMS(result.renderMS),
        qipPlayFormatMS(result.updateMS + result.renderMS),
      );
    }
  }

  _drainEvents(updateNowMS) {
    const result = this._flushPendingEvents(updateNowMS);
    return { eventCount: result.count, accepted: result.accepted };
  }

  _elapsedFromPerfNow(perfNowMS) {
    if (this._timeOriginMS <= 0) {
      return 0;
    }
    const elapsed = perfNowMS - this._timeOriginMS;
    if (elapsed <= 0) {
      return 0;
    }
    return Math.floor(elapsed);
  }

  _hasReadyWork(nowMS) {
    if (this._needsRender && this._canPresent()) {
      return true;
    }
    if (this._isIntersecting && this._nextWakeAtMS > 0 && nowMS >= this._nextWakeAtMS) {
      return true;
    }
    if (
      this._pendingEvents.length > 0 &&
      this._pendingEvents[0].timeMS <= nowMS
    ) {
      return true;
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending && repeatState.pendingTimeMS <= nowMS) {
        return true;
      }
    }
    return false;
  }

  _hasDueEvents(nowMS) {
    if (
      this._pendingEvents.length > 0 &&
      this._pendingEvents[0].timeMS <= nowMS
    ) {
      return true;
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending && repeatState.pendingTimeMS <= nowMS) {
        return true;
      }
    }
    return false;
  }

  _hasPendingFutureWork() {
    if (this._isIntersecting && this._nextWakeAtMS > 0) {
      return true;
    }
    if (this._pendingEvents.length > 0) {
      return true;
    }
    return this._hasPendingRepeatKeyEvents();
  }

  _nextDelayMS(nowMS) {
    let nextAt = Number.MAX_SAFE_INTEGER;
    if (this._isIntersecting && this._nextWakeAtMS > 0) {
      nextAt = Math.min(nextAt, this._nextWakeAtMS);
    }
    if (this._pendingEvents.length > 0) {
      nextAt = Math.min(nextAt, this._pendingEvents[0].timeMS);
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending) {
        nextAt = Math.min(nextAt, repeatState.pendingTimeMS);
      }
    }
    if (nextAt === Number.MAX_SAFE_INTEGER) {
      return 16;
    }
    const delay = Math.floor(nextAt - nowMS);
    if (delay <= 0) {
      return 1;
    }
    return Math.min(delay, 1000);
  }

  _hasPendingRepeatKeyEvents() {
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending) {
        return true;
      }
    }
    return false;
  }

  _presentPixels(bytes, renderMS, reason) {
    let compareMS = 0;
    let unchanged = false;
    if (this._debugStats && this._hasRenderedFrame) {
      const compareStart = qipPlayPerfNow();
      if (this._debugPreviousPixels && this._debugPreviousPixels.length === bytes.length) {
        unchanged = true;
        for (let i = 0; i < bytes.length; i++) {
          if (this._debugPreviousPixels[i] !== bytes[i]) {
            unchanged = false;
            break;
          }
        }
      }
      compareMS = qipPlayPerfNow() - compareStart;
      if (unchanged) {
        this._unchangedRenderN++;
      }
    }
    const drawStart = qipPlayPerfNow();
    const convert = this._presentationConvert || ((destination, source) => destination.set(source));
    convert(this._imageData.data, bytes);
    this._ctx.putImageData(this._imageData, 0, 0);
    const drawMS = qipPlayPerfNow() - drawStart;
    this._drawN++;
    this._hasRenderedFrame = true;
    this._lastRenderMS = renderMS;
    this._lastCompareMS = compareMS;
    this._lastDrawMS = drawMS;
    this._lastRenderUnchanged = unchanged;
    if (this._debugStats) this._debugPreviousPixels = bytes.slice();
    this._updateStats();
    if (this._logTimings && reason === "initial") {
      console.log(
        "[qip-play] initial_render_ms=%s initial_draw_ms=%s",
        qipPlayFormatMS(renderMS),
        qipPlayFormatMS(drawMS),
      );
    }
    return { renderMS, compareMS, drawMS, unchanged };
  }

  _updateStats() {
    if (!this._stats) {
      return;
    }
    const memoryBytes = this._steps.length > 0
      ? this._steps.reduce((total, step) => total + (step.candidates || [step])
        .reduce((candidateTotal, candidate) => candidateTotal + candidate.memory.buffer.byteLength, 0), 0)
      : this._memory.buffer.byteLength;
    let text =
      "wasm " +
      qipPlayFormatByteSize(this._wasmByteLength) +
      " | memory " +
      qipPlayFormatByteSize(memoryBytes) +
      (this._outputProfile && this._canvasProfile
        ? " | output " + qipPlayProfileName(this._outputProfile) +
          " | canvas " + qipPlayProfileName(this._canvasProfile)
        : "") +
      " | update " +
      qipPlayFormatCount(this._updateN) +
      " " +
      qipPlayFormatMS(this._lastUpdateMS) +
      " ms | render " +
      qipPlayFormatCount(this._renderN) +
      " " +
      qipPlayFormatMS(this._lastRenderMS) +
      " ms" +
      (this._debugStats
        ? " | unchanged renders " +
          String(this._unchangedRenderN) +
          " | compare " +
          qipPlayFormatMS(this._lastCompareMS) +
          " ms"
        : "");
    if (this._debugStats && this._steps.length > 1) {
      for (const step of this._steps) {
        text += "\n" + step.label +
          " | wasm " + qipPlayFormatByteSize(step.moduleBytes) +
          " | memory " + qipPlayFormatByteSize((step.candidates || [step])
            .reduce((total, candidate) => total + candidate.memory.buffer.byteLength, 0)) +
          " | render " + qipPlayFormatCount(step.renderN) +
          " " + qipPlayFormatMS(step.lastRenderMS) + " ms" +
          (step.selectedSourceLabel ? " | source " + step.selectedSourceLabel : "");
      }
    }
    this._stats.textContent = text;
  }

  _renderError(err) {
    const pre = document.createElement("pre");
    pre.setAttribute("role", "alert");
    const message = err instanceof Error ? err.message : String(err);
    pre.textContent = "Play error: " + message;
    this.replaceChildren(pre);
  }
}

if (!customElements.get("qip-play")) {
  customElements.define("qip-play", QIPPlayElement);
}
