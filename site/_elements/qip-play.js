import {
  readModulePolicy, validateWasmModulePolicy, readI32Export, readSlice,
} from "./qip-wasm-policy.js";
import { parseKTX2, profileName, profileKey, createPresentation } from "./_qip-ktx2.js";
import {
  extractUniforms, uniformSetter, applyUniform, directChildren, sourceSteps,
  readDeclaredContentType, mediaTypeOf, parseContentType, stepLabel, sourceLabel, validatePostStage,
} from "./_qip-pipeline.js";
import { QIPInteractiveSession, mapKeyboardEventToKeysym, keyFlags } from "./_qip-interactive-session.js";

const KEY_REPEAT_DELAY_MS = 250;
const KEY_REPEAT_INTERVAL_MS = 33;
const CRLF_CRLF = new Uint8Array([13, 10, 13, 10]);
// Listened for on the render surface; contextmenu is added separately in the capture phase.
const SURFACE_EVENTS = ["keydown", "keyup", "pointerdown", "pointermove", "pointerup", "pointercancel", "pointerleave", "click", "blur"];
// With Meta held, only text-editing and navigation shortcuts reach the
// component; other Meta shortcuts stay with the browser.
const META_KEYSYMS = new Set([
  0xff51, 0xff52, 0xff53, 0xff54, 0xff08, 0xffff, 0xff50, 0xff57, // arrows, Backspace, Delete, Home, End
  ...[..."ACVXZTacvxzt"].map((c) => c.charCodeAt(0)),
]);

const formatMS = (ms) => ms.toFixed(1);
const formatCount = (count) => String(count).padStart(3, " ");

function formatByteSize(n) {
  if (n < 1000) return n + " B";
  const [value, unit] = n < 1e6 ? [n / 1000, " kB"] : [n / 1e6, " MB"];
  return value.toFixed(value < 100 ? 1 : 0) + unit;
}

const compareQueuedEvents = (a, b) => a.timeMS - b.timeMS || a.sequence - b.sequence;

// DOM buttons (1 primary, 2 secondary, 4 auxiliary) to QIP buttons 1, 3 and 2.
const buttonsToMask = (buttons) => (buttons & 1) | (buttons & 4 ? 2 : 0) | (buttons & 2 ? 4 : 0);

function canvasXY(canvas, event, width, height) {
  const rect = canvas.getBoundingClientRect();
  const relX = rect.width > 0 ? (event.clientX - rect.left) / rect.width : 0;
  const relY = rect.height > 0 ? (event.clientY - rect.top) / rect.height : 0;
  return {
    x: Math.min(Math.max(Math.floor(relX * width), 0), width - 1),
    y: Math.min(Math.max(Math.floor(relY * height), 0), height - 1),
  };
}

function outputCapacity(exportsObj, contentType) {
  const utf8 = typeof exportsObj.output_utf8_cap === "function";
  if (utf8 === (typeof exportsObj.output_bytes_cap === "function")) {
    throw new Error("qip-play module must export exactly one output capacity getter");
  }
  if (contentType === "image/svg+xml" && !utf8) throw new Error("qip-play SVG output must declare output_utf8_cap");
  return readI32Export(exportsObj, utf8 ? "output_utf8_cap" : "output_bytes_cap");
}

function indexOfBytes(bytes, needle, from) {
  const last = bytes.length - needle.length;
  for (let i = bytes.indexOf(needle[0], from); i !== -1 && i <= last; i = bytes.indexOf(needle[0], i + 1)) {
    let j = 1;
    while (j < needle.length && bytes[i + j] === needle[j]) j++;
    if (j === needle.length) return i;
  }
  return -1;
}

// Returns the root part body of a QIP multipart/related output as a subarray of `bytes`,
// so the root is never copied. Later parts are skipped unread. `delimiter` holds the
// bytes "\r\n--<boundary>"; the CRLF before each later delimiter is not part of a body.
function multipartRelatedRoot(bytes, delimiter, rootType) {
  const fail = (reason) => {
    throw new Error("qip-play multipart/related output " + reason);
  };
  const opening = delimiter.subarray(2);
  if (indexOfBytes(bytes.subarray(0, opening.length), opening, 0) !== 0 ||
      bytes[opening.length] !== 13 || bytes[opening.length + 1] !== 10) {
    fail("must start with its boundary delimiter");
  }
  const headersStart = opening.length + 2;
  const headersEnd = indexOfBytes(bytes, CRLF_CRLF, headersStart);
  if (headersEnd === -1) fail("root part headers are unterminated");
  let partType = "";
  const headers = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(headersStart, headersEnd));
  for (const line of headers.split("\r\n")) {
    const colon = line.indexOf(":");
    if (colon !== -1 && line.slice(0, colon).trim().toLowerCase() === "content-type") {
      partType = mediaTypeOf(line.slice(colon + 1));
    }
  }
  if (partType !== rootType) fail("root part must be " + rootType + ", got " + (partType || "no Content-Type"));
  const bodyStart = headersEnd + 4;
  const bodyEnd = indexOfBytes(bytes, delimiter, bodyStart);
  if (bodyEnd === -1) fail("root part is not followed by a boundary delimiter");
  return bytes.subarray(bodyStart, bodyEnd);
}

// CSS size of the surface: attribute, then custom property, then fallback.
function cssSize(element, renderWidth) {
  const read = (attribute, property, fallback) =>
    (element.getAttribute(attribute) || "").trim() ||
    getComputedStyle(element).getPropertyValue(property).trim() || fallback;
  return {
    width: read("canvas-width", "--qip-play-canvas-width", renderWidth + "px"),
    height: read("canvas-height", "--qip-play-canvas-height", "auto"),
  };
}

/**
 * <qip-play> is a light-DOM browser host for QIP Eventful components with
 * canonical KTX2 RGBA8 sRGB or RGBA32F linear Display P3 output.
 *
 * Static module policy:
 *
 * - Modules containing memory.grow are always rejected.
 * - max-memory="<bytes>" rejects modules whose declared memory minimum or
 *   maximum exceeds the byte cap. A module with memory but no declared maximum
 *   is rejected when this attribute is set.
 *
 * Pointer lock:
 *
 * - data-pointer-lock asks for pointer lock on a mouse press. While locked,
 *   movementX/movementY are summed and passed to the optional exports
 *   uniform_set_pointer_total_movement_x/_y as running totals.
 */
class QIPPlayElement extends HTMLElement {
  // Scheduling
  _started = false; _rafID = 0; _timeoutID = 0; _timeoutTargetMS = 0; _boundFrame = null;
  _nextWakeAtMS = 0; _timeOriginMS = 0; _finishedAtMS = 0; _needsRender = false;
  _isIntersecting = true; _intersectionObserver = null; _documentAbort = null;
  // Component
  _exports = null; _session = null; _memory = null; _uniforms = []; _sourceElement = null;
  _steps = []; _postStages = []; _inputSize = 0; _outputCapacity = 0; _wasmByteLength = 0;
  // Presentation
  _canvas = null; _presentationElement = null; _contentType = ""; _relatedDelimiter = null;
  _inlineSVG = false; _noTextSelection = false; _svgBlobURL = ""; _svgLoadGeneration = 0;
  _ctx = null; _imageData = null; _presentationConvert = null; _presentationSourceProfileKey = "";
  _presentationN = 0; _outputProfile = null; _canvasProfile = null; _hasRenderedFrame = false;
  _renderWidth = 0; _renderHeight = 0; _expectedOutputBytes = 0;
  // Stats
  _stats = null; _debugStats = false; _logTimings = false; _debugPreviousPixels = null;
  _lastUpdateMS = 0; _lastRenderMS = 0; _lastDrawMS = 0; _lastCompareMS = 0; _lastRenderUnchanged = false;
  _eventN = 0; _updateN = 0; _renderN = 0; _unchangedRenderN = 0; _drawN = 0;
  // Input
  _surfaceAbort = null; _activeKeyRepeats = new Map(); _pendingEvents = []; _eventSequence = 0;
  _shiftKeyDown = false; _altKeyDown = false; _pointerButtonMask = 0; _pointerPressAccepted = false;
  _pointerLock = false; _pointerTotalMovementX = 0; _pointerTotalMovementY = 0; _pointerMovementPending = false;

  async connectedCallback() {
    if (this._started) return;
    this._started = true;
    try {
      await this._init();
      this._timeOriginMS = performance.now();
      this._runBootstrapUpdate();
      this._resumeLoop();
    } catch (err) {
      this._renderError(err);
    }
  }

  disconnectedCallback() {
    this._cancelScheduledLoop();
    this._intersectionObserver?.disconnect();
    this._intersectionObserver = null;
    this._nextWakeAtMS = 0;
    this._timeOriginMS = 0;
    this._discardPendingInput();
    this._detachInputHandlers();
    this._documentAbort?.abort();
    this._documentAbort = null;
    this._revokeSVGBlobURL();
  }

  async _loadSource(sourceElement, policy) {
    const src = (sourceElement.getAttribute("src") || "").trim();
    if (src === "") throw new Error("<qip-play> <source> requires a non-empty src");
    const sourceURL = new URL(src, document.baseURI).toString();
    const response = await fetch(sourceURL);
    if (!response.ok) throw new Error("failed to fetch module " + sourceURL + " (" + response.status + ")");
    const moduleBytes = await response.arrayBuffer();
    validateWasmModulePolicy(moduleBytes, policy, sourceURL);
    const instantiated = await WebAssembly.instantiate(moduleBytes, {});
    const exportsObj = instantiated?.instance?.exports || instantiated?.exports;
    if (!exportsObj) throw new Error("failed to access wasm exports for qip-play module");
    if (!(exportsObj.memory instanceof WebAssembly.Memory)) throw new Error("qip-play module must export memory");
    return {
      sourceElement, sourceURL, sourceLabel: sourceLabel(sourceElement), moduleBytes: moduleBytes.byteLength,
      exports: exportsObj, memory: exportsObj.memory, outputCapacity: 0, renderN: 0, lastRenderMS: 0,
    };
  }

  async _init() {
    const stepRecords = sourceSteps(this);
    const inputElement = this.querySelector('input[name="input"], textarea[name="input"]');
    const inputSource = directChildren(this, "source").find((source) =>
      (source.getAttribute("name") || "").trim() === "input" &&
      (source.getAttribute("type") || "").trim().toLowerCase() !== "application/wasm") || null;
    const policy = readModulePolicy(this);
    const loaded = [];
    for (const [index, stepRecord] of stepRecords.entries()) {
      const candidates = [];
      for (const sourceElement of index === 0 ? [stepRecord.sourceElement] : stepRecord.sourceElements) {
        candidates.push(await this._loadSource(sourceElement, policy));
      }
      const label = stepLabel(stepRecord, index);
      loaded.push(index === 0 ? { ...stepRecord, ...candidates[0], label, candidates } : {
        ...stepRecord, label, candidates,
        moduleBytes: candidates.reduce((total, candidate) => total + candidate.moduleBytes, 0),
        renderN: 0, lastRenderMS: 0, selectedSourceLabel: "", selectedCandidate: null,
      });
    }

    const primary = loaded[0];
    const exportsObj = primary.exports;
    for (const name of ["output_content_type_ptr", "output_content_type_size", "begin_update_at", "finish_update", "render"]) {
      if (!(name in exportsObj)) throw new Error("qip-play module missing export " + name);
    }
    let outputType = readDeclaredContentType(exportsObj, primary.memory, "output_content_type_ptr", "output_content_type_size");
    primary.outputCapacity = outputCapacity(exportsObj, outputType);
    let outputUTF8 = typeof exportsObj.output_utf8_cap === "function";
    for (const stage of loaded.slice(1)) {
      outputType = validatePostStage(stage, outputType, outputUTF8);
      outputUTF8 = stage.outputUTF8;
    }

    this._exports = exportsObj;
    this._memory = exportsObj.memory;
    this._session = new QIPInteractiveSession(exportsObj, exportsObj.memory);
    this._steps = loaded;
    this._postStages = loaded.slice(1);
    this._sourceElement = primary.sourceElement;
    this._uniforms = extractUniforms(primary.sourceElement);
    this._wasmByteLength = loaded.reduce((total, step) => total + step.moduleBytes, 0);
    this._debugStats = this.hasAttribute("debug");
    this._logTimings = this.hasAttribute("log");
    this._pointerLock = this.hasAttribute("data-pointer-lock");

    await this._setupInitialInput(inputSource, inputElement);

    this._outputCapacity = primary.outputCapacity;
    let contentType = mediaTypeOf(outputType);
    this._relatedDelimiter = null;
    if (contentType === "multipart/related") {
      // Only the KTX2 or SVG root is presented; later parts are skipped.
      const { params } = parseContentType(outputType);
      const rootType = params.get("type");
      if ((rootType !== "image/ktx2" && rootType !== "image/svg+xml") || !params.get("boundary")) {
        throw new Error("qip-play multipart/related output must declare type=\"image/ktx2\" or type=\"image/svg+xml\" and a boundary");
      }
      this._relatedDelimiter = new TextEncoder().encode("\r\n--" + params.get("boundary"));
      contentType = rootType;
    }
    if (contentType !== "image/ktx2" && contentType !== "image/svg+xml") {
      throw new Error("qip-play presentation output must declare image/ktx2, image/svg+xml, or multipart/related with one of them as its type");
    }
    this._contentType = contentType;
    const { rendered, renderMS } = this._runInitialContentRender();
    const parsed = contentType === "image/ktx2" ? this._readKTX2Output(rendered) : null;
    this._renderWidth = parsed?.width || 800;
    this._renderHeight = parsed?.height || 600;
    this._expectedOutputBytes = parsed?.sourceBytes.byteLength || 0;

    const statsWidth = cssSize(this, this._renderWidth).width;
    if (parsed) this._installPresentation(parsed);
    else this._installSVGPresentation();

    this._stats = document.createElement("aside");
    this._stats.setAttribute("aria-label", "qip-play stats");
    Object.assign(this._stats.style, {
      boxSizing: "border-box", marginTop: "6px", maxWidth: statsWidth,
      font: "11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
      color: "#666", whiteSpace: "pre-wrap", lineHeight: "1.35",
    });
    this._updateStats();

    if (parsed) this._presentPixels(parsed.pixels, renderMS, "initial");
    else this._presentSVGOutput(rendered, renderMS, "initial");

    this.replaceChildren(this._presentationElement || this._canvas);
    if (inputElement) this.appendChild(inputElement);
    this.appendChild(this._stats);
    this._attachInputHandlers();
    this._setupIntersectionObserver();
    if (typeof document.addEventListener === "function") {
      this._documentAbort = new AbortController();
      document.addEventListener("visibilitychange", this, { signal: this._documentAbort.signal });
    }
  }

  _setupIntersectionObserver() {
    if (typeof globalThis.IntersectionObserver !== "function") return;
    this._intersectionObserver = new globalThis.IntersectionObserver((entries) => {
      const latest = entries.findLast((entry) => entry.target === this);
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

  _clearTimer() {
    if (this._timeoutID !== 0) clearTimeout(this._timeoutID);
    this._timeoutID = 0;
    this._timeoutTargetMS = 0;
  }

  _cancelScheduledLoop() {
    if (this._rafID !== 0 && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this._rafID);
      this._rafID = 0;
    }
    this._clearTimer();
  }

  _canPresent() {
    return this._isIntersecting && !document.hidden;
  }

  async _setupInitialInput(inputSource, inputElement) {
    if (!inputSource && !inputElement) return;
    const capName = "input_utf8_cap" in this._exports ? "input_utf8_cap" : "input_bytes_cap";
    if (!("input_ptr" in this._exports) || !(capName in this._exports)) {
      throw new Error("<qip-play> input requires module exports input_ptr and input_utf8_cap or input_bytes_cap");
    }
    if (!inputSource) {
      this._writeInput(capName, new TextEncoder().encode(String(inputElement.value ?? inputElement.textContent ?? "")));
      return;
    }
    const declaredInputType = readDeclaredContentType(this._exports, this._memory, "input_content_type_ptr", "input_content_type_size");
    const sourceType = (inputSource.getAttribute("type") || "").trim().toLowerCase();
    if (declaredInputType === "" || sourceType !== declaredInputType) {
      throw new Error('<qip-play> <source name="input"> type must exactly match the module input content type');
    }
    const src = (inputSource.getAttribute("src") || "").trim();
    if (src === "") throw new Error('<qip-play> <source name="input"> requires a non-empty src');
    const response = await fetch(new URL(src, document.baseURI).toString());
    if (!response.ok) throw new Error("failed to fetch qip-play input source (" + response.status + ")");
    this._writeInput(capName, new Uint8Array(await response.arrayBuffer()));
  }

  // Styles a new presentation surface and gives it the element's tab stop.
  _styleSurface(surface, width, tabIndex) {
    const size = cssSize(this, width);
    Object.assign(surface.style, {
      display: "block", width: size.width, height: size.height,
      touchAction: this.getAttribute("touch-action")?.trim() || "none",
    });
    surface.tabIndex = tabIndex ?? (this.hasAttribute("tabindex") ? this.tabIndex : 0);
    if (tabIndex === undefined) this.removeAttribute("tabindex");
  }

  _installSVGPresentation() {
    this._inlineSVG = this.hasAttribute("svg-inline");
    this._noTextSelection = this.hasAttribute("no-text-selection");
    // SVG coordinates drive both pointer mapping and the inline surface ratio.
    const svgWidth = Number(this.getAttribute("svg-width") || 800);
    const svgHeight = Number(this.getAttribute("svg-height") || 600);
    if (!Number.isSafeInteger(svgWidth) || svgWidth <= 0 || !Number.isSafeInteger(svgHeight) || svgHeight <= 0) {
      throw new Error("qip-play SVG dimensions must be positive integers");
    }
    const surface = document.createElement(this._inlineSVG ? "div" : "img");
    const label = this.getAttribute("aria-label") || "Interactive SVG editor";
    if (this._inlineSVG) {
      surface.setAttribute("role", "img");
      surface.setAttribute("aria-label", label);
      surface.style.aspectRatio = `${svgWidth} / ${svgHeight}`;
      surface.style.userSelect = this._noTextSelection ? "none" : "text";
    } else {
      surface.alt = label;
      surface.draggable = false;
    }
    this._styleSurface(surface, svgWidth);
    this._canvas = surface;
    this._presentationElement = surface;
    this._renderWidth = svgWidth;
    this._renderHeight = svgHeight;
  }

  _revokeSVGBlobURL() {
    if (this._svgBlobURL) URL.revokeObjectURL(this._svgBlobURL);
    this._svgBlobURL = "";
  }

  _presentSVGOutput(rendered, renderMS, reason) {
    if (rendered.outputLen < 0 || rendered.outputLen > rendered.outputCapacity) {
      throw new Error("qip-play Timed render returned output outside its output capacity");
    }
    let source = readSlice(rendered.memory, rendered.outputPtr, rendered.outputLen, "output_ptr/output capacity");
    if (this._relatedDelimiter) source = multipartRelatedRoot(source, this._relatedDelimiter, "image/svg+xml");
    if (this._inlineSVG) {
      const markup = new TextDecoder("utf-8", { fatal: true }).decode(source);
      const root = new DOMParser().parseFromString(markup, "image/svg+xml").documentElement;
      if (root.localName !== "svg" || root.namespaceURI !== "http://www.w3.org/2000/svg") {
        throw new Error("qip-play SVG output must have an SVG root element");
      }
      Object.assign(root.style, { display: "block", width: "100%", height: "100%" });
      if (this._noTextSelection) root.style.userSelect = "none";
      this._canvas.replaceChildren(root);
    } else {
      // Copy before the next component render can reuse its output buffer.
      const nextURL = URL.createObjectURL(new Blob([source.slice()], { type: "image/svg+xml" }));
      const previousURL = this._svgBlobURL;
      const generation = ++this._svgLoadGeneration;
      this._svgBlobURL = nextURL;
      this._canvas.onload = () => {
        if (generation === this._svgLoadGeneration && previousURL) URL.revokeObjectURL(previousURL);
      };
      this._canvas.onerror = () => {
        if (generation === this._svgLoadGeneration) URL.revokeObjectURL(nextURL);
      };
      this._canvas.src = nextURL;
    }
    this._drawN++;
    this._hasRenderedFrame = true;
    this._lastRenderMS = renderMS;
    this._updateStats();
    if (this._logTimings && reason === "initial") console.log("[qip-play] initial_render_ms=%s", formatMS(renderMS));
  }

  _installPresentation(parsed) {
    const initial = this._presentationN === 0;
    const replacement = createPresentation(parsed);
    const oldCanvas = this._canvas;
    const hadFocus = oldCanvas && typeof document !== "undefined" && document.activeElement === oldCanvas;
    if (oldCanvas) this._detachInputHandlers();

    const canvas = replacement.canvas;
    this._styleSurface(canvas, parsed.width, initial ? undefined : (oldCanvas?.tabIndex ?? 0));
    this._canvas = canvas;
    this._presentationElement = canvas;
    this._ctx = replacement.ctx;
    this._imageData = replacement.imageData;
    this._presentationConvert = replacement.convert;
    this._presentationSourceProfileKey = profileKey(parsed.profile);
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

  _writeInput(capName, bytes) {
    const inputPtr = readI32Export(this._exports, "input_ptr");
    const inputCap = readI32Export(this._exports, capName);
    if (inputCap < 0 || inputPtr < 0) throw new Error("qip-play input exports returned invalid pointer/capacity");
    if (bytes.length > inputCap) {
      throw new Error(`qip-play input exceeds module ${capName}: ${bytes.length} > ${inputCap}`);
    }
    const capSlice = readSlice(this._memory, inputPtr, inputCap, `input_ptr/${capName}`);
    capSlice.fill(0);
    capSlice.set(bytes, 0);
    this._inputSize = bytes.length;
    // Keep qip-play contract-simple: write input bytes only. Modules read the
    // initial source during their first Content render.
    this._nextWakeAtMS = 0;
    this._resumeLoop();
  }

  _applyUniforms() {
    const uniforms = this._sourceElement ? extractUniforms(this._sourceElement) : this._uniforms;
    for (const uniform of uniforms) applyUniform(this._exports, uniform);
    // Host-driven and optional. Totals rather than deltas, so reapplying them
    // before another update or render cannot count the same motion twice.
    for (const [key, total] of [
      ["pointer_total_movement_x", this._pointerTotalMovementX],
      ["pointer_total_movement_y", this._pointerTotalMovementY],
    ]) {
      if (uniformSetter(this._exports, key)) applyUniform(this._exports, { key, value: String(Math.round(total)) });
    }
  }

  _hasPointerMovementUniforms() {
    return Boolean(this._exports && (uniformSetter(this._exports, "pointer_total_movement_x") ||
      uniformSetter(this._exports, "pointer_total_movement_y")));
  }

  _isPointerLocked() {
    return this._pointerLock && this._canvas !== null &&
      typeof document !== "undefined" && document.pointerLockElement === this._canvas;
  }

  _requestPointerLock() {
    try {
      // Newer browsers return a promise that rejects if the user or page
      // denies the lock; older ones fire pointerlockerror instead.
      this._canvas.requestPointerLock?.()?.catch?.(() => {});
    } catch {
      // Pointer lock is an enhancement; absolute pointer events still work.
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
      const modes = readI32Export(exportsObj, "failure_modes_per_input_offset") >>> 0;
      if (modes === 0 && outputLen !== 0) {
        throw new Error("qip-play render returned failure detail despite declaring no failure modes");
      }
      let message = "qip-play input was rejected";
      if (modes > 0) message += " at input offset " + Math.floor(outputLen / modes);
      if (modes > 1) message += " with mode " + (outputLen % modes);
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

  _readKTX2Output({ outputLen, outputPtr, memory = this._memory, outputCapacity = this._outputCapacity }) {
    if (outputLen < 0 || outputLen > outputCapacity) {
      throw new Error("qip-play Timed render returned output outside output_bytes_cap");
    }
    const bytes = readSlice(memory, outputPtr, outputLen, "output_ptr/output_bytes_cap");
    return parseKTX2(this._relatedDelimiter ? multipartRelatedRoot(bytes, this._relatedDelimiter, "image/ktx2") : bytes);
  }

  _runInitialContentRender() {
    const result = this._runPresentationPipeline(this._inputSize);
    this._renderN++;
    this._lastRenderMS = result.renderMS;
    this._finishedAtMS = 0;
    this._nextWakeAtMS = 0;
    return result;
  }

  _runPresentationPipeline(inputSize) {
    const pipelineStart = performance.now();
    this._applyUniforms();
    const primaryStart = performance.now();
    let rendered = this._decodeRenderResult(this._exports.render(inputSize), this._steps[0] || null);
    if (this._steps[0]) {
      this._steps[0].renderN++;
      this._steps[0].lastRenderMS = performance.now() - primaryStart;
    }

    for (const stage of this._postStages) {
      if (rendered.outputLen < 0 || rendered.outputLen > rendered.outputCapacity) {
        throw new Error("qip-play pipeline output exceeds the preceding step capacity");
      }
      const inputBytes = readSlice(rendered.memory, rendered.outputPtr, rendered.outputLen, "qip-play pipeline input");
      const candidates = stage.selectedCandidate ? [stage.selectedCandidate] : stage.candidates || [stage];
      const stageIsCandidate = !stage.candidates;
      let accepted = null;
      let stageRenderMS = 0;
      for (const candidate of candidates) {
        if (inputBytes.byteLength > candidate.inputCapacity) continue;
        readSlice(candidate.memory, candidate.inputPtr, candidate.inputCapacity,
          "qip-play post-processing input_ptr/input capacity").set(inputBytes, 0);
        for (const uniform of extractUniforms(candidate.sourceElement)) applyUniform(candidate.exports, uniform);
        const candidateStart = performance.now();
        const outcome = this._decodeRenderResult(candidate.exports.render(inputBytes.byteLength), candidate, true);
        candidate.lastRenderMS = performance.now() - candidateStart;
        candidate.renderN++;
        stageRenderMS += candidate.lastRenderMS;
        if (!outcome.failed) {
          accepted = outcome;
          stage.selectedCandidate = candidate;
          stage.candidates = [candidate];
          stage.selectedSourceLabel = candidate.sourceLabel || sourceLabel(candidate.sourceElement);
          break;
        }
      }
      stage.lastRenderMS = stageRenderMS;
      if (!stageIsCandidate) stage.renderN++;
      if (!accepted) throw new Error("qip-play post-processing step " + stage.label + " was rejected by every source");
      rendered = accepted;
    }
    return { rendered, renderMS: performance.now() - pipelineStart };
  }

  // Elements driven directly by tests skip _init(), so the session is lazy.
  _beginUpdate(requestedAtMS) {
    this._session ??= new QIPInteractiveSession(this._exports, this._memory);
    return this._session.begin(requestedAtMS);
  }

  _runBootstrapUpdate() {
    const updateStart = performance.now();
    const begunAtMS = this._beginUpdate(1);
    this._applyUniforms();
    this._nextWakeAtMS = this._session.finish(begunAtMS);
    this._finishedAtMS = begunAtMS;
    this._updateN++;
    this._lastUpdateMS = performance.now() - updateStart;
  }

  _runUpdate(nowMS, renderRequested) {
    const updateStart = performance.now();
    const begunAtMS = this._beginUpdate(Math.max(Math.floor(nowMS), this._finishedAtMS + 1));
    const pointerMoved = this._pointerMovementPending;
    this._pointerMovementPending = false;
    this._applyUniforms();
    const events = this._flushPendingEvents(nowMS);
    const shouldRender = this._canPresent() && (renderRequested || events.accepted || pointerMoved);
    const nextWakeAtMS = this._session.finish(begunAtMS);
    const presentation = shouldRender ? this._runPresentationPipeline(0) : { renderMS: 0 };
    const updateMS = performance.now() - updateStart - presentation.renderMS;
    this._updateN++;
    this._lastUpdateMS = updateMS;
    this._finishedAtMS = begunAtMS;
    this._nextWakeAtMS = nextWakeAtMS;
    if (shouldRender) this._present(presentation);
    else this._updateStats();
    return {
      nextWakeAtMS, updateMS, renderMS: presentation.renderMS,
      eventCount: events.count, acceptedEvent: events.accepted, rendered: shouldRender,
    };
  }

  _present({ rendered, renderMS }) {
    if (this._contentType === "image/svg+xml") {
      this._renderN++;
      this._presentSVGOutput(rendered, renderMS);
    } else this._presentKTX2Output(this._readKTX2Output(rendered), renderMS);
  }

  _presentKTX2Output(parsed, renderMS) {
    const sizeChanged = parsed.width !== this._renderWidth || parsed.height !== this._renderHeight;
    if (this._presentationSourceProfileKey !== "" &&
        (sizeChanged || profileKey(parsed.profile) !== this._presentationSourceProfileKey)) {
      this._installPresentation(parsed);
    } else if (sizeChanged) {
      // Direct host tests can supply their own canvas without running _init().
      this._renderWidth = this._canvas.width = parsed.width;
      this._renderHeight = this._canvas.height = parsed.height;
      this._expectedOutputBytes = parsed.sourceBytes.byteLength;
      this._imageData = this._ctx.createImageData(parsed.width, parsed.height);
      this._hasRenderedFrame = false;
    }
    if (this._presentationSourceProfileKey === "") {
      this._presentationSourceProfileKey = profileKey(parsed.profile);
      this._outputProfile = this._canvasProfile = parsed.profile;
    }
    this._renderN++;
    this._presentPixels(parsed.pixels, renderMS);
  }

  _attachInputHandlers() {
    if (!this._exports || !this._canvas) return;
    if (typeof this._exports.key_event !== "function" && typeof this._exports.pointer_event !== "function" &&
        !(this._pointerLock && this._hasPointerMovementUniforms())) {
      return;
    }
    this._surfaceAbort = new AbortController();
    const signal = this._surfaceAbort.signal;
    for (const type of SURFACE_EVENTS) this._canvas.addEventListener(type, this, { signal });
    this._canvas.addEventListener("contextmenu", this, { capture: true, signal });
  }

  _detachInputHandlers() {
    if (this._isPointerLocked() && typeof document.exitPointerLock === "function") document.exitPointerLock();
    this._surfaceAbort?.abort();
    this._surfaceAbort = null;
  }

  handleEvent(event) {
    switch (event.type) {
      case "keydown": case "keyup":
        this._dispatchKey(event, event.type === "keydown");
        break;
      case "pointerdown": case "pointermove": case "pointerup": case "pointercancel":
        this._dispatchPointer(event);
        break;
      case "pointerleave":
        if (typeof this._exports?.pointer_event !== "function") return;
        this._queuePointerEvent(0, -1, -1, this._eventNowMS());
        this._resumeLoop();
        break;
      case "contextmenu":
        // Deliver the queued press now so the module decides whether it wanted
        // it; if pointer_event returned 0, leave the browser's context menu.
        if (this._hasDueEvents(this._eventNowMS())) {
          this._frameUpdate(performance.now());
          this._resumeLoop();
        }
        if (!this._pointerPressAccepted) return;
        event.preventDefault();
        event.stopPropagation();
        break;
      case "click":
        this._canvas.focus();
        break;
      case "blur":
        this._releaseHeldInput();
        break;
      case "visibilitychange":
        if (document.hidden) return;
        this._needsRender = true;
        this._resumeLoop();
        break;
    }
  }

  _dispatchKey(event, isDown) {
    if (typeof this._exports?.key_event !== "function") return;
    const keysym = mapKeyboardEventToKeysym(event);
    if (keysym === null) return;
    if (event.metaKey && (event.ctrlKey || !META_KEYSYMS.has(keysym | 0))) return;
    event.preventDefault();
    const keyID = event.code || "key:" + (event.key || "");
    // Ignore browser-generated repeat bursts; we drive repeat ourselves.
    if (isDown && (event.repeat || this._activeKeyRepeats.has(keyID))) return;

    this._queueKeyEvent(keysym | 0, keyFlags(event, isDown) | 0, this._eventNowMS());
    if (keysym === 0xffe1 || keysym === 0xffe2) this._shiftKeyDown = isDown;
    if (keysym === 0xffe9 || keysym === 0xffea) this._altKeyDown = isDown;
    if (isDown) this._startKeyRepeat(keyID, keysym, event);
    else this._stopKeyRepeat(keyID, true);
    this._resumeLoop();
  }

  _dispatchPointer(event) {
    if (!this._exports || !this._canvas) return;

    // With data-pointer-lock, a mouse press locks the pointer to the surface
    // (Esc releases it). Locked motion is unbounded, so it is tallied into the
    // pointer_total_movement uniforms rather than sent as canvas coordinates.
    const locked = this._isPointerLocked();
    if (locked && event.type === "pointermove" && (event.movementX || event.movementY)) {
      this._pointerTotalMovementX += event.movementX || 0;
      this._pointerTotalMovementY += event.movementY || 0;
      if (this._hasPointerMovementUniforms()) {
        this._pointerMovementPending = true;
        this._resumeLoop();
      }
    }
    if (this._pointerLock && !locked && event.type === "pointerdown" && event.pointerType === "mouse") {
      this._requestPointerLock();
    }
    if (typeof this._exports.pointer_event !== "function") return;

    if (this._canvas.style.touchAction === "none" && (!this._inlineSVG || this._noTextSelection || event.pointerType === "touch")) {
      event.preventDefault();
    }
    if (event.type === "pointerdown") {
      const selectingSVGText = this._inlineSVG && !this._noTextSelection && event.pointerType === "mouse" && event.target?.closest?.("text");
      // setPointerCapture throws while the document holds a pointer lock.
      if (!selectingSVGText && !locked) this._canvas.setPointerCapture?.(event.pointerId);
      this._canvas.focus();
    }

    const { x, y } = canvasXY(this._canvas, event, this._renderWidth, this._renderHeight);
    const eventNowMS = this._eventNowMS();
    if (typeof this._exports.key_event === "function") {
      // Modifier state can change while the surface is unfocused.
      const shiftDown = Boolean(event.shiftKey);
      const altDown = Boolean(event.altKey);
      if (shiftDown !== this._shiftKeyDown) {
        this._queueKeyEvent(0xffe1, keyFlags(event, shiftDown), eventNowMS);
        this._shiftKeyDown = shiftDown;
      }
      if (altDown !== this._altKeyDown) {
        this._queueKeyEvent(0xffe9, keyFlags(event, altDown), eventNowMS);
        this._altKeyDown = altDown;
      }
    }
    this._queuePointerEvent(buttonsToMask(event.buttons | 0), x | 0, y | 0, eventNowMS);
    if ((event.type === "pointerup" || event.type === "pointercancel") &&
        typeof this._canvas.releasePointerCapture === "function" && this._canvas.hasPointerCapture?.(event.pointerId)) {
      this._canvas.releasePointerCapture(event.pointerId);
    }
    this._resumeLoop();
  }

  _startKeyRepeat(keyID, keysym, baseEvent) {
    if (typeof this._exports?.key_event !== "function" || this._activeKeyRepeats.has(keyID)) return;
    const repeatState = {
      timeoutID: 0,
      keysym: keysym | 0,
      flags: (keyFlags(baseEvent, true) | (1 << 1)) | 0,
      pending: false,
      pendingTimeMS: 0,
      pendingSequence: 0,
    };
    const runRepeat = () => {
      if (!this._activeKeyRepeats.has(keyID)) return;
      repeatState.pending = true;
      repeatState.pendingTimeMS = this._eventNowMS();
      repeatState.pendingSequence = ++this._eventSequence;
      this._resumeLoop();
      repeatState.timeoutID = setTimeout(runRepeat, KEY_REPEAT_INTERVAL_MS);
    };
    repeatState.timeoutID = setTimeout(runRepeat, KEY_REPEAT_DELAY_MS);
    this._activeKeyRepeats.set(keyID, repeatState);
  }

  _stopKeyRepeat(keyID, keepPending = false) {
    const repeatState = this._activeKeyRepeats.get(keyID);
    if (!repeatState) return;
    if (repeatState.timeoutID !== 0) clearTimeout(repeatState.timeoutID);
    if (keepPending && repeatState.pending) {
      const { keysym, flags, pendingTimeMS: timeMS, pendingSequence: sequence } = repeatState;
      this._enqueue({ type: "key", keysym, flags, timeMS, sequence });
    }
    this._activeKeyRepeats.delete(keyID);
  }

  _discardPendingInput() {
    for (const keyID of this._activeKeyRepeats.keys()) this._stopKeyRepeat(keyID);
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
    if (typeof this._exports?.pointer_event === "function") this._queuePointerEvent(0, -1, -1, timeMS);
    this._resumeLoop();
  }

  _enqueue(event) {
    this._pendingEvents.push(event);
    this._pendingEvents.sort(compareQueuedEvents);
  }

  _queueKeyEvent(keysym, flags, timeMS) {
    this._eventN++;
    this._enqueue({ type: "key", keysym: keysym | 0, flags: flags | 0, timeMS, sequence: ++this._eventSequence });
  }

  _queuePointerEvent(buttonMask, x, y, timeMS) {
    this._eventN++;
    this._enqueue({ type: "pointer", buttonMask: buttonMask | 0, x: x | 0, y: y | 0, timeMS, sequence: ++this._eventSequence });
  }

  // Whole milliseconds since the bootstrap update, or 0 before it.
  _elapsedMS(perfNowMS) {
    return this._timeOriginMS <= 0 ? 0 : Math.max(0, Math.floor(perfNowMS - this._timeOriginMS));
  }

  _eventNowMS() {
    return this._elapsedMS(performance.now());
  }

  _flushPendingEvents(updateNowMS) {
    const due = [];
    while (this._pendingEvents.length > 0 && this._pendingEvents[0].timeMS <= updateNowMS) {
      due.push(this._pendingEvents.shift());
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending && repeatState.pendingTimeMS <= updateNowMS) {
        const { keysym, flags, pendingTimeMS: timeMS, pendingSequence: sequence } = repeatState;
        due.push({ type: "key-repeat", keysym, flags, timeMS, sequence, repeatState });
      }
    }
    due.sort(compareQueuedEvents);

    let accepted = false;
    for (const evt of due) {
      let result = 0;
      if (evt.type === "pointer") {
        if (typeof this._exports?.pointer_event === "function") {
          result = this._exports.pointer_event(evt.buttonMask, evt.x, evt.y);
        }
        if (evt.buttonMask & ~this._pointerButtonMask) this._pointerPressAccepted = Number(result) !== 0;
        this._pointerButtonMask = evt.buttonMask;
      } else {
        if (evt.repeatState) evt.repeatState.pending = false;
        if (typeof this._exports?.key_event === "function") result = this._exports.key_event(evt.keysym, evt.flags);
      }
      if (Number(result) !== 0) accepted = true;
    }
    return { count: due.length, accepted };
  }

  _resumeLoop() {
    const nowMS = this._eventNowMS();
    const immediate = this._hasReadyWork(nowMS);
    if (!immediate && this._nextWakeAtMS === 0 && !this._hasPendingFutureWork()) return;
    this._boundFrame ??= (frameNowMS) => {
      this._rafID = 0;
      this._timeoutID = 0;
      this._timeoutTargetMS = 0;
      this._frameUpdate(frameNowMS);
      this._resumeLoop();
    };

    if (immediate) {
      this._clearTimer();
      if (this._rafID !== 0) return;
      if (typeof requestAnimationFrame === "function") {
        this._rafID = requestAnimationFrame(this._boundFrame);
      } else {
        this._scheduleTimeout(1, nowMS + 1);
      }
      return;
    }

    if (this._rafID !== 0) return;
    const delayMS = this._nextDelayMS(nowMS);
    const targetMS = nowMS + delayMS;
    if (this._timeoutID !== 0 && this._timeoutTargetMS <= targetMS) return;
    this._clearTimer();
    this._scheduleTimeout(delayMS, targetMS);
  }

  _scheduleTimeout(delayMS, targetMS) {
    this._timeoutTargetMS = targetMS;
    this._timeoutID = setTimeout(() => this._boundFrame(performance.now()), delayMS);
  }

  _frameUpdate(nowMS) {
    if (!this._exports) return;
    const updateNowMS = this._elapsedMS(nowMS);
    const wakeDue = this._wakeDue(updateNowMS);
    const eventsDue = this._hasDueEvents(updateNowMS);
    const presentationDue = this._needsRender && this._canPresent();
    if (!wakeDue && !eventsDue) {
      if (presentationDue) {
        this._needsRender = false;
        this._present(this._runPresentationPipeline(0));
      }
      return;
    }
    const renderRequested = this._canPresent() && (this._needsRender || wakeDue);
    if (renderRequested) this._needsRender = false;
    const result = this._runUpdate(updateNowMS, renderRequested);
    if (this._logTimings) {
      console.log(
        "[qip-play] now_ms=%d events=%d next_wake_at_ms=%d update_ms=%s render_ms=%s frame_ms=%s",
        this._finishedAtMS, result.eventCount, result.nextWakeAtMS,
        formatMS(result.updateMS), formatMS(result.renderMS), formatMS(result.updateMS + result.renderMS),
      );
    }
  }

  _wakeDue(nowMS) {
    return this._isIntersecting && this._nextWakeAtMS > 0 && nowMS >= this._nextWakeAtMS;
  }

  _hasPendingRepeat(nowMS = Infinity) {
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending && repeatState.pendingTimeMS <= nowMS) return true;
    }
    return false;
  }

  _hasDueEvents(nowMS) {
    return this._pointerMovementPending || this._pendingEvents[0]?.timeMS <= nowMS || this._hasPendingRepeat(nowMS);
  }

  _hasReadyWork(nowMS) {
    return (this._needsRender && this._canPresent()) || this._wakeDue(nowMS) || this._hasDueEvents(nowMS);
  }

  _hasPendingFutureWork() {
    return (this._isIntersecting && this._nextWakeAtMS > 0) || this._pendingEvents.length > 0 || this._hasPendingRepeat();
  }

  _nextDelayMS(nowMS) {
    let nextAt = Number.MAX_SAFE_INTEGER;
    if (this._isIntersecting && this._nextWakeAtMS > 0) nextAt = Math.min(nextAt, this._nextWakeAtMS);
    if (this._pendingEvents.length > 0) nextAt = Math.min(nextAt, this._pendingEvents[0].timeMS);
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending) nextAt = Math.min(nextAt, repeatState.pendingTimeMS);
    }
    if (nextAt === Number.MAX_SAFE_INTEGER) return 16;
    return Math.min(Math.max(Math.floor(nextAt - nowMS), 1), 1000);
  }

  _presentPixels(bytes, renderMS, reason) {
    let compareMS = 0;
    let unchanged = false;
    if (this._debugStats && this._hasRenderedFrame) {
      const compareStart = performance.now();
      const previous = this._debugPreviousPixels;
      if (previous && previous.length === bytes.length) {
        unchanged = true;
        for (let i = 0; i < bytes.length && unchanged; i++) unchanged = previous[i] === bytes[i];
      }
      compareMS = performance.now() - compareStart;
      if (unchanged) this._unchangedRenderN++;
    }
    const drawStart = performance.now();
    const convert = this._presentationConvert || ((destination, source) => destination.set(source));
    convert(this._imageData.data, bytes);
    this._ctx.putImageData(this._imageData, 0, 0);
    const drawMS = performance.now() - drawStart;
    this._drawN++;
    this._hasRenderedFrame = true;
    this._lastRenderMS = renderMS;
    this._lastCompareMS = compareMS;
    this._lastDrawMS = drawMS;
    this._lastRenderUnchanged = unchanged;
    if (this._debugStats) this._debugPreviousPixels = bytes.slice();
    this._updateStats();
    if (this._logTimings && reason === "initial") {
      console.log("[qip-play] initial_render_ms=%s initial_draw_ms=%s", formatMS(renderMS), formatMS(drawMS));
    }
    return { renderMS, compareMS, drawMS, unchanged };
  }

  _updateStats() {
    if (!this._stats) return;
    const memoryOf = (step) => (step.candidates || [step])
      .reduce((total, candidate) => total + candidate.memory.buffer.byteLength, 0);
    const memoryBytes = this._steps.length > 0
      ? this._steps.reduce((total, step) => total + memoryOf(step), 0)
      : this._memory.buffer.byteLength;
    let text = `wasm ${formatByteSize(this._wasmByteLength)} | memory ${formatByteSize(memoryBytes)}` +
      (this._outputProfile && this._canvasProfile
        ? ` | output ${profileName(this._outputProfile)} | canvas ${profileName(this._canvasProfile)}`
        : "") +
      ` | update ${formatCount(this._updateN)} ${formatMS(this._lastUpdateMS)} ms` +
      ` | render ${formatCount(this._renderN)} ${formatMS(this._lastRenderMS)} ms` +
      (this._debugStats ? ` | unchanged renders ${this._unchangedRenderN} | compare ${formatMS(this._lastCompareMS)} ms` : "");
    if (this._debugStats && this._steps.length > 1) {
      for (const step of this._steps) {
        text += `\n${step.label} | wasm ${formatByteSize(step.moduleBytes)} | memory ${formatByteSize(memoryOf(step))}` +
          ` | render ${formatCount(step.renderN)} ${formatMS(step.lastRenderMS)} ms` +
          (step.selectedSourceLabel ? ` | source ${step.selectedSourceLabel}` : "");
      }
    }
    this._stats.textContent = text;
  }

  _renderError(err) {
    const pre = document.createElement("pre");
    pre.setAttribute("role", "alert");
    pre.textContent = "Play error: " + (err instanceof Error ? err.message : String(err));
    this.replaceChildren(pre);
  }
}

if (!customElements.get("qip-play")) {
  customElements.define("qip-play", QIPPlayElement);
}
