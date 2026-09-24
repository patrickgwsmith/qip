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

const decoder = new TextDecoder("utf-8", { fatal: true });
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
    shell.style.border = "1px solid color-mix(in srgb, currentColor 30%, transparent)";
    shell.style.borderRadius = "0.5rem";
    shell.style.background = "#111";
    shell.style.color = "#e8e8e8";
    this.style.display = "block";
    const screen = document.createElement("pre");
    screen.setAttribute("role", "region");
    screen.setAttribute("aria-label", this.getAttribute("aria-label") || "Terminal screen");
    screen.tabIndex = this.hasAttribute("tabindex") ? this.tabIndex : 0;
    screen.style.boxSizing = "border-box";
    screen.style.width = "100%";
    screen.style.height = "100%";
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
    this._session = null;
    this._screen = null;
    this._shell = null;
  }

  get exports() { return this._session?.exports ?? null; }
  get screen() { return this._screen; }

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
    if (typeof exportsObj.key_event !== "function") throw new Error("TUI module must export key_event");
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
    const session = new QIPInteractiveSession(exportsObj, exportsObj.memory);
    if (input.length > 0) {
      const pointer = readI32Export(exportsObj, "input_ptr");
      const capacity = readI32Export(exportsObj, "input_bytes_cap");
      if (input.length > capacity || pointer + capacity > session.memory.buffer.byteLength) {
        throw new Error("TUI input exceeds the declared input buffer");
      }
      new Uint8Array(session.memory.buffer, pointer, input.length).set(input);
    }
    this._session = session;
    this._postStages = postStages;
    this._renderer = renderer;
    this._timeOrigin = performance.now();
    this._measureGrid();
    this.render(input.length);
    session.update(1, [], () => this._applyUniforms());
    this._scheduleWake();
    this.dispatchEvent(new Event("qip-ready"));
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
    if (this._measureGrid() && this._session) this.render(0);
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
    this._applyUniforms();
    const { exports: exportsObj, memory } = this._session;
    const capacity = readI32Export(exportsObj, "output_utf8_cap");
    const result = decodeRenderResult(exportsObj.render(inputSize), capacity, memory, "TUI");
    if (result.failed) throw new Error("TUI component rejected input at " + result.detail);
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
  }

  sendKey(keysym, flags = 1, updateUniforms = null) {
    if (!this._session) return false;
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
    if (event.metaKey || event.ctrlKey) return;
    const keysym = mapKeyboardEventToKeysym(event);
    if (keysym === null) return;
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
