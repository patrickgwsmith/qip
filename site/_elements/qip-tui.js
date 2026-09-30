import { contentComponent, contentTypeUTF8 } from "../qip-runner.js";
import {
  readModulePolicy, validateWasmModulePolicy, readI32Export, readSlice,
} from "./qip-wasm-policy.js";
import {
  readDeclaredContentType, extractUniforms, applyUniform, sourceSteps,
  stepLabel, sourceLabel, validatePostStage,
} from "./_qip-pipeline.js";
import {
  QIPInteractiveSession, decodeRenderResult, mapKeyboardEventToKeysym, keyFlags,
} from "./_qip-interactive-session.js";
import { linkifyHttpURLs } from "./_qip-tui-links.js";

const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();
const htmlPrefix = '<!doctype html><meta charset="utf-8"><pre>';
const htmlSuffix = "</pre>";
let ansiRendererPromise;

function ansiRenderer() {
  ansiRendererPromise ??= WebAssembly.compileStreaming(fetch("/text/ansi-sgr-to-html.wasm"))
    .then((module) => contentComponent(
      contentTypeUTF8("text/plain"), module, contentTypeUTF8("text/html"),
    ));
  return ansiRendererPromise;
}

function gridDimensions(width, height, characterWidth, lineHeight) {
  return {
    columns: Math.max(1, Math.floor(width / characterWidth)),
    lines: Math.max(1, Math.floor(height / lineHeight)),
  };
}

class QIPTUIElement extends HTMLElement {
  constructor() {
    super();
    this._session = null;
    this._screen = null;
    this._shell = null;
    this._renderer = null;
    this._resizeObserver = null;
    this._wakeTimer = 0;
    this._timeOrigin = 0;
    this._grid = { columns: 80, lines: 24 };
    this._generation = 0;
    this._sourceUniforms = [];
    this._postStages = [];
    this._textMode = false;
    this._input = null;
    this._inputError = null;
    this._inputBytes = new Uint8Array(0);
    this._activeIndex = 0;
    this._activeCount = 0;
    this._detailOffset = 0;
    this._detailCount = 0;
    this._detailPageSize = 0;
    this._onInput = (event) => {
      if (!event.isComposing) {
        try { this._editTextInput(); }
        catch (error) { this._showError(error); }
      }
    };
    this._onKeyDown = (event) => this._handleKey(event, true);
    this._onKeyUp = (event) => this._handleKey(event, false);
  }

  connectedCallback() {
    if (this._shell) return;
    const shell = document.createElement("div");
    shell.style.boxSizing = "border-box";
    shell.style.width = "100%";
    shell.style.maxWidth = "100%";
    shell.style.minWidth = "min(24ch, 100%)";
    shell.style.height = this.getAttribute("height") || "min(70vh, 36rem)";
    shell.style.minHeight = "8rem";
    shell.style.resize = "both";
    shell.style.overflow = "hidden";
    shell.style.display = "flex";
    shell.style.flexDirection = "column";
    shell.style.border = "1px solid color-mix(in srgb, currentColor 30%, transparent)";
    shell.style.borderRadius = "0.5rem";
    shell.style.background = "#111";
    shell.style.color = "#e8e8e8";
    this.style.display = "block";
    const screen = document.createElement("pre");
    screen.setAttribute("role", "region");
    screen.setAttribute("aria-label", this.getAttribute("aria-label") || "Terminal screen");
    screen.setAttribute("aria-keyshortcuts", "Control+Enter");
    screen.tabIndex = this.hasAttribute("tabindex") ? this.tabIndex : 0;
    screen.style.boxSizing = "border-box";
    screen.style.width = "100%";
    screen.style.flex = "1";
    screen.style.minHeight = "0";
    screen.style.margin = "0";
    screen.style.padding = "1rem";
    screen.style.overflow = "auto";
    screen.style.whiteSpace = "pre";
    screen.style.font = "13px/1.25 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
    shell.append(screen);
    this.append(shell);
    this._shell = shell;
    this._screen = screen;
    screen.addEventListener("keydown", this._onKeyDown);
    screen.addEventListener("keyup", this._onKeyUp);
    if (typeof ResizeObserver === "function") {
      this._resizeObserver = new ResizeObserver(() => this._measureAndRender());
      this._resizeObserver.observe(shell);
    }
    if (Array.from(this.children).some((child) =>
      child.localName === "source" || child.localName === "qip-step"
    )) {
      this._loadSource().catch((error) => this._showError(error));
    }
  }

  disconnectedCallback() {
    this._generation++;
    this._clearWake();
    this._resizeObserver?.disconnect();
    this._resizeObserver = null;
    this._screen?.removeEventListener("keydown", this._onKeyDown);
    this._screen?.removeEventListener("keyup", this._onKeyUp);
    this._removeTextInput();
    this._session = null;
    this._screen = null;
    this._shell = null;
  }

  get exports() { return this._session?.exports ?? null; }
  get screen() { return this._screen; }
  get input() { return this._input; }

  async _loadSource() {
    const steps = sourceSteps(this);
    const source = steps[0].sourceElement;
    this._sourceUniforms = extractUniforms(source);
    const url = new URL(source.getAttribute("src"), document.baseURI);
    const response = await fetch(url);
    if (!response.ok) throw new Error("failed to fetch TUI component (" + response.status + ")");
    const inputSource = Array.from(this.children).find((child) =>
      child.localName === "source" && child.getAttribute("name") === "input"
    );
    let inputBytes = new Uint8Array(0);
    let inputType = "";
    if (inputSource) {
      inputType = (inputSource.getAttribute("type") || "").trim().toLowerCase();
      if (!inputType) throw new Error("TUI input source requires a content type");
      const inputResponse = await fetch(new URL(inputSource.getAttribute("src"), document.baseURI));
      if (!inputResponse.ok) throw new Error("failed to fetch TUI input (" + inputResponse.status + ")");
      inputBytes = new Uint8Array(await inputResponse.arrayBuffer());
    }
    const postStages = [];
    for (let index = 1; index < steps.length; index++) {
      const record = steps[index];
      const candidates = [];
      for (const candidateSource of record.sourceElements) {
        const candidateURL = new URL(candidateSource.getAttribute("src"), document.baseURI);
        const candidateResponse = await fetch(candidateURL);
        if (!candidateResponse.ok) throw new Error("failed to fetch TUI step (" + candidateResponse.status + ")");
        const candidateBytes = new Uint8Array(await candidateResponse.arrayBuffer());
        validateWasmModulePolicy(candidateBytes, readModulePolicy(this), candidateURL.toString());
        const instantiated = await WebAssembly.instantiate(candidateBytes, {});
        const exportsObj = instantiated.instance?.exports ?? instantiated.exports;
        if (!(exportsObj.memory instanceof WebAssembly.Memory)) throw new Error("TUI step must export memory");
        candidates.push({
          sourceElement: candidateSource, sourceLabel: sourceLabel(candidateSource),
          exports: exportsObj, memory: exportsObj.memory, renderN: 0, lastRenderMS: 0,
        });
      }
      postStages.push({ label: stepLabel(record, index), candidates });
    }
    await this.load({
      moduleBytes: new Uint8Array(await response.arrayBuffer()),
      inputBytes, inputType, postStages,
    });
  }

  async load({ moduleBytes, inputBytes = new Uint8Array(0), inputType = "", postStages = [] }) {
    if (!this._screen) throw new Error("connect <qip-tui> before loading a component");
    const generation = ++this._generation;
    this._clearWake();
    this._session = null;
    this._removeTextInput();
    this._textMode = false;
    this._screen.textContent = "Loading…";
    const bytes = moduleBytes instanceof Uint8Array ? moduleBytes : new Uint8Array(moduleBytes);
    const input = inputBytes instanceof Uint8Array ? inputBytes : new Uint8Array(inputBytes);
    validateWasmModulePolicy(bytes, readModulePolicy(this), "qip-tui module");
    const [instantiated, renderer] = await Promise.all([
      WebAssembly.instantiate(bytes, {}), ansiRenderer(),
    ]);
    if (generation !== this._generation) return;
    const exportsObj = instantiated.instance?.exports ?? instantiated.exports;
    if (!(exportsObj.memory instanceof WebAssembly.Memory)) throw new Error("TUI module must export memory");
    const eventful = ["begin_update_at", "finish_update", "key_event", "pointer_event"].some((name) => exportsObj[name] !== undefined);
    if (eventful && typeof exportsObj.key_event !== "function") throw new Error("TUI module must export key_event");
    if (!eventful) {
      const declaredInputType = readDeclaredContentType(exportsObj, exportsObj.memory, "input_content_type_ptr", "input_content_type_size");
      if (declaredInputType !== "text/plain" || typeof exportsObj.input_ptr !== "function" ||
          typeof exportsObj.input_utf8_cap !== "function" || exportsObj.input_bytes_cap !== undefined) {
        throw new Error("TUI text input requires UTF-8 text/plain input");
      }
      if (exportsObj.uniform_set_active_index !== undefined || exportsObj.active_count !== undefined) {
        if (typeof exportsObj.uniform_set_active_index !== "function" || exportsObj.uniform_set_active_index.length !== 1 ||
            typeof exportsObj.active_count !== "function" || exportsObj.active_count.length !== 0) {
          throw new Error("TUI navigation requires uniform_set_active_index and active_count");
        }
      }
    }
    if (!eventful && ["uniform_set_detail_offset", "detail_count", "detail_page_size"].some((name) => exportsObj[name] !== undefined)) {
      for (const [name, arity] of [["uniform_set_detail_offset", 1], ["detail_count", 0], ["detail_page_size", 0]]) {
        if (typeof exportsObj[name] !== "function" || exportsObj[name].length !== arity) throw new Error("TUI detail scrolling requires offset, count, and page size exports");
      }
    }
    const contentType = readDeclaredContentType(
      exportsObj, exportsObj.memory, "output_content_type_ptr", "output_content_type_size",
    );
    if ((contentType !== "" && contentType !== "text/plain") ||
        typeof exportsObj.output_utf8_cap !== "function") {
      throw new Error("TUI output must be UTF-8 text/plain");
    }
    let finalType = contentType;
    for (const stage of postStages) finalType = validatePostStage(stage, finalType);
    if (postStages.length > 0 && finalType !== "text/plain") {
      throw new Error("TUI pipeline must finish with text/plain");
    }
    if (postStages.length > 0 && postStages.at(-1).candidates.some(
      (candidate) => typeof candidate.exports.output_utf8_cap !== "function"
    )) {
      throw new Error("TUI pipeline must finish with UTF-8 output");
    }
    if (inputType) {
      const declaredInputType = readDeclaredContentType(
        exportsObj, exportsObj.memory, "input_content_type_ptr", "input_content_type_size",
      );
      if (declaredInputType !== inputType) throw new Error("TUI input source type does not match the component input type");
    }
    const session = eventful ? new QIPInteractiveSession(exportsObj, exportsObj.memory) :
      { exports: exportsObj, memory: exportsObj.memory };
    if (input.length > 0) {
      const pointer = readI32Export(exportsObj, "input_ptr");
      const capacity = readI32Export(exportsObj, typeof exportsObj.input_utf8_cap === "function" ? "input_utf8_cap" : "input_bytes_cap");
      if (input.length > capacity || pointer + capacity > session.memory.buffer.byteLength) {
        throw new Error("TUI input exceeds the declared input buffer");
      }
      new Uint8Array(session.memory.buffer, pointer, input.length).set(input);
    }
    this._session = session;
    this._textMode = !eventful;
    this._postStages = postStages;
    this._renderer = renderer;
    this._timeOrigin = performance.now();
    if (this._textMode) this._createTextInput(input);
    this._measureGrid();
    this.render(input.length);
    if (eventful) {
      session.update(1, [], () => this._applyUniforms());
      this._scheduleWake();
    }
    this.dispatchEvent(new Event("qip-ready"));
  }

  _createTextInput(bytes) {
    const value = decoder.decode(bytes);
    const capacity = readI32Export(this.exports, "input_utf8_cap");
    if (bytes.length > capacity) throw new Error("TUI input exceeds the declared input buffer");
    if (/[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw new Error("TUI text input must be one printable line");
    const field = document.createElement("input");
    field.type = "text";
    field.value = value;
    field.placeholder = "Type to search";
    field.setAttribute("aria-label", (this.getAttribute("aria-label") || "Component") + " input");
    field.style.margin = "0.75rem 1rem 0";
    field.style.padding = "0.5rem";
    field.style.font = this._screen.style.font;
    field.style.color = "inherit";
    field.style.background = "#222";
    field.style.border = "1px solid #888";
    field.style.borderRadius = "0.25rem";
    const error = document.createElement("span");
    error.hidden = true;
    error.setAttribute("role", "status");
    error.style.margin = "0.25rem 1rem 0";
    this._shell.prepend(field, error);
    this._input = field;
    this._inputError = error;
    this._inputBytes = bytes.slice();
    const configured = this._sourceUniforms.find((uniform) => uniform.key === "active_index");
    this._activeIndex = configured ? Number(configured.value) : 0;
    if (!Number.isInteger(this._activeIndex) || this._activeIndex < 0 || this._activeIndex > 0xffff_ffff) {
      throw new Error("active_index must be a u32");
    }
    this._activeCount = 0;
    const configuredOffset = this._sourceUniforms.find((uniform) => uniform.key === "detail_offset");
    this._detailOffset = configuredOffset ? Number(configuredOffset.value) : 0;
    if (!Number.isInteger(this._detailOffset) || this._detailOffset < 0 || this._detailOffset > 0xffff_ffff) {
      throw new Error("detail_offset must be a u32");
    }
    this._detailCount = 0;
    this._detailPageSize = 0;
    field.addEventListener("input", this._onInput);
    field.addEventListener("compositionend", this._onInput);
    field.addEventListener("keydown", this._onKeyDown);
    field.addEventListener("keyup", this._onKeyUp);
  }

  _removeTextInput() {
    this._input?.removeEventListener("input", this._onInput);
    this._input?.removeEventListener("compositionend", this._onInput);
    this._input?.removeEventListener("keydown", this._onKeyDown);
    this._input?.removeEventListener("keyup", this._onKeyUp);
    this._input?.remove();
    this._inputError?.remove();
    this._input = null;
    this._inputError = null;
  }

  _editTextInput() {
    if (!this._textMode || !this._session) return;
    const bytes = encoder.encode(this._input.value);
    const capacity = readI32Export(this.exports, "input_utf8_cap");
    if (bytes.length > capacity || /[\u0000-\u001f\u007f-\u009f]/u.test(this._input.value)) {
      this._input.setAttribute("aria-invalid", "true");
      this._inputError.textContent = bytes.length > capacity ? `Input limit: ${capacity} UTF-8 bytes` : "Use one printable line";
      this._inputError.hidden = false;
      return;
    }
    this._input.removeAttribute("aria-invalid");
    this._inputError.hidden = true;
    this._activeIndex = 0;
    this._detailOffset = 0;
    this._inputBytes = bytes;
    this.render();
  }

  _measureGrid() {
    if (!this._screen) return false;
    const probe = document.createElement("span");
    probe.textContent = "0000000000";
    probe.style.font = this._screen.style.font;
    probe.style.position = "absolute";
    probe.style.visibility = "hidden";
    this._screen.append(probe);
    const rect = probe.getBoundingClientRect();
    probe.remove();
    const style = getComputedStyle(this._screen);
    const paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
    const paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    const characterWidth = rect.width / 10 || 8;
    const lineHeight = parseFloat(style.lineHeight) || rect.height || 16;
    const next = gridDimensions(
      Math.max(1, this._screen.clientWidth - paddingX),
      Math.max(1, this._screen.clientHeight - paddingY), characterWidth, lineHeight,
    );
    const changed = next.columns !== this._grid.columns || next.lines !== this._grid.lines;
    this._grid = next;
    return changed;
  }

  _measureAndRender() {
    if (this._measureGrid() && this._session) {
      this._detailOffset = 0;
      this.render(0);
    }
  }

  _applyGrid() {
    if (!this._session) return;
    const exportsObj = this._session.exports;
    if (typeof exportsObj.uniform_set_columns === "function") exportsObj.uniform_set_columns(this._grid.columns);
    if (typeof exportsObj.uniform_set_lines === "function") exportsObj.uniform_set_lines(this._grid.lines);
  }

  _applyUniforms() {
    if (!this._session) return;
    for (const uniform of this._sourceUniforms) applyUniform(this._session.exports, uniform);
    this._applyGrid();
  }

  render(inputSize = 0) {
    if (!this._session) return;
    if (this._textMode) {
      const pointer = readI32Export(this.exports, "input_ptr");
      const capacity = readI32Export(this.exports, "input_utf8_cap");
      if (this._inputBytes.length > capacity) throw new Error("TUI input exceeds the declared input buffer");
      readSlice(this._session.memory, pointer, capacity, "TUI input").set(this._inputBytes);
      inputSize = this._inputBytes.length;
    }
    this._applyUniforms();
    const { exports: exportsObj, memory } = this._session;
    if (this._textMode && typeof exportsObj.uniform_set_active_index === "function") exportsObj.uniform_set_active_index(this._activeIndex);
    if (this._textMode && typeof exportsObj.uniform_set_detail_offset === "function") exportsObj.uniform_set_detail_offset(this._detailOffset);
    const capacity = readI32Export(exportsObj, "output_utf8_cap");
    const result = decodeRenderResult(exportsObj.render(inputSize), capacity, memory, "TUI");
    if (result.failed) throw new Error("rejected input at " + result.detail);
    if (this._textMode && typeof exportsObj.active_count === "function") {
      this._activeCount = readI32Export(exportsObj, "active_count");
      this._activeIndex = Math.min(this._activeIndex, Math.max(0, this._activeCount - 1));
    }
    if (this._textMode && typeof exportsObj.detail_count === "function") {
      this._detailCount = readI32Export(exportsObj, "detail_count");
      this._detailPageSize = readI32Export(exportsObj, "detail_page_size");
      this._detailOffset = Math.min(this._detailOffset, Math.max(0, this._detailCount - this._detailPageSize));
    }
    let output = readSlice(memory, result.pointer, result.size, "TUI output");
    for (const stage of this._postStages) {
      const candidates = stage.selectedCandidate ? [stage.selectedCandidate] : stage.candidates;
      let accepted = null;
      for (const candidate of candidates) {
        if (output.length > candidate.inputCapacity) continue;
        const target = readSlice(candidate.memory, candidate.inputPtr, candidate.inputCapacity, "TUI step input");
        target.set(output);
        for (const uniform of extractUniforms(candidate.sourceElement)) applyUniform(candidate.exports, uniform);
        const outcome = decodeRenderResult(
          candidate.exports.render(output.length), candidate.outputCapacity, candidate.memory, "TUI step",
        );
        if (outcome.failed) continue;
        accepted = { candidate, output: readSlice(candidate.memory, outcome.pointer, outcome.size, "TUI step output") };
        break;
      }
      if (!accepted) throw new Error("TUI step " + stage.label + " rejected the frame");
      stage.selectedCandidate = accepted.candidate;
      stage.candidates = [accepted.candidate];
      output = accepted.output;
    }
    if (output.length > 256 * 1024) throw new Error("TUI frame exceeds the ANSI renderer's 256 KiB input limit");
    const ansi = decoder.decode(output);
    const html = this._renderer(ansi);
    if (!html.startsWith(htmlPrefix) || !html.endsWith(htmlSuffix)) {
      throw new Error("ANSI renderer returned an unexpected document");
    }
    this._screen.innerHTML = html.slice(htmlPrefix.length, -htmlSuffix.length);
    linkifyHttpURLs(this._screen);
  }

  sendKey(keysym, flags = 1, updateUniforms = null) {
    if (!this._session) return false;
    if (this._textMode) {
      if ((flags & 1) === 0 || (flags & (8 | 16 | 32)) !== 0) return false;
      if (keysym === 0xff55 || keysym === 0xff56) {
        if (!this._detailPageSize) return false;
        const offset = Math.max(0, Math.min(this._detailOffset + (keysym === 0xff55 ? -1 : 1) * this._detailPageSize,
          this._detailCount - this._detailPageSize));
        if (offset === this._detailOffset) return false;
        this._detailOffset = offset;
        this.render();
        return true;
      }
      if (keysym !== 0xff52 && keysym !== 0xff54) return false;
      const index = Math.max(0, Math.min(this._activeIndex + (keysym === 0xff52 ? -1 : 1), this._activeCount - 1));
      if (index === this._activeIndex) return false;
      this._activeIndex = index;
      this._detailOffset = 0;
      this.render();
      return true;
    }
    const time = Math.max(1, Math.floor(performance.now() - this._timeOrigin));
    const result = this._session.update(time, [{ type: "key", keysym, flags }], () => {
      this._applyUniforms();
      updateUniforms?.(this._session.exports);
    });
    if (result.accepted) this.render(0);
    this._scheduleWake();
    return result.accepted;
  }

  _handleKey(event, down) {
    if (this.hasAttribute("manual-keys")) return;
    if (this._textMode && (event.isComposing || event.keyCode === 229)) return;
    if (this._textMode && event.target === this._input && !["ArrowUp", "ArrowDown", "PageUp", "PageDown"].includes(event.key)) return;
    if (event.target?.closest?.("a[href]")) {
      if (down && event.key === "Escape") {
        event.preventDefault();
        this._screen?.focus();
      }
      return;
    }
    if (down && event.ctrlKey && event.key === "Enter") {
      const firstLink = this._screen?.querySelector("a[href]");
      if (firstLink) {
        event.preventDefault();
        firstLink.focus();
      }
      return;
    }
    if (event.metaKey || event.ctrlKey) return;
    const keysym = mapKeyboardEventToKeysym(event);
    if (keysym === null) return;
    if (this._textMode && ![0xff52, 0xff54, 0xff55, 0xff56].includes(keysym)) return;
    if (this._textMode && (keysym === 0xff55 || keysym === 0xff56) &&
        typeof this.exports?.uniform_set_detail_offset !== "function") return;
    event.preventDefault();
    try { this.sendKey(keysym, keyFlags(event, down)); }
    catch (error) { this._showError(error); }
  }

  _clearWake() {
    if (this._wakeTimer) clearTimeout(this._wakeTimer);
    this._wakeTimer = 0;
  }

  _scheduleWake() {
    this._clearWake();
    const wake = this._session?.nextWakeAt;
    if (!wake) return;
    const now = Math.floor(performance.now() - this._timeOrigin);
    this._wakeTimer = setTimeout(() => {
      this._wakeTimer = 0;
      if (!this._session) return;
      if (Math.floor(performance.now() - this._timeOrigin) < wake) {
        this._scheduleWake();
        return;
      }
      try {
        const result = this._session.update(
          Math.max(wake, Math.floor(performance.now() - this._timeOrigin)), [],
          () => this._applyUniforms(),
        );
        if (result.at >= wake) this.render(0);
        this._scheduleWake();
      } catch (error) { this._showError(error); }
    }, Math.max(1, Math.min(1000, wake - now)));
  }

  _showError(error) {
    this._clearWake();
    if (this._screen) this._screen.textContent = "TUI error: " + (error?.message ?? error);
    this.dispatchEvent(new CustomEvent("qip-error", { detail: error }));
  }
}

if (!customElements.get("qip-tui")) customElements.define("qip-tui", QIPTUIElement);

export { gridDimensions };
