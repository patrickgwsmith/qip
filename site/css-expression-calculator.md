<title>CSS expression calculator</title>

# CSS expression calculator

Resolve viewport units, root-relative units, safe-area insets, and virtual-keyboard insets for an editable mobile browser scenario. Everything runs locally in a QIP WebAssembly component.

The presets are illustrative starting points, not device specifications. Browser version, orientation, display mode, page viewport metadata, browser chrome, zoom, and keyboard state can all change the measurements.

<style>
.mobile-value-tool { display: grid; gap: 1rem; }
.mobile-value-tool fieldset { display: grid; gap: 0.75rem; margin: 0; }
.mobile-value-tool label { display: grid; gap: 0.25rem; }
.mobile-value-tool input, .mobile-value-tool select { box-sizing: border-box; max-width: 100%; font: inherit; }
.mobile-value-tool input[type="number"] { width: 8rem; }
.mobile-value-expression { width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.mobile-value-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr)); gap: 0.75rem; }
.mobile-value-result { padding: 1rem; border: 1px solid currentColor; }
.mobile-value-result output { display: block; font: 700 2rem/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.mobile-value-result p { margin-bottom: 0; }
.mobile-value-error { color: #b42318; }
.mobile-value-tool details { border: 1px solid color-mix(in srgb, currentColor 25%, transparent); padding: 0.75rem; }
.mobile-value-tool summary { cursor: pointer; font-weight: 700; }
</style>

<div class="mobile-value-tool">
  <label>
    <strong>Example scenario</strong>
    <select id="mobile-preset">
      <option value="iphone-visible">iPhone portrait example — browser UI visible</option>
      <option value="iphone-keyboard">iPhone portrait example — keyboard open</option>
      <option value="android-visible">Android Chrome example — browser UI visible</option>
      <option value="android-keyboard">Android Chrome example — keyboard resizes visual viewport</option>
      <option value="android-resizes-content">Android Chrome example — keyboard resizes content</option>
      <option value="custom">Custom</option>
    </select>
  </label>

  <label>
    <strong>CSS expression</strong>
    <input id="mobile-expression" class="mobile-value-expression" value="calc(100dvh - max(1rlh, env(safe-area-inset-bottom)))" spellcheck="false" />
  </label>

  <div id="mobile-result-panel" class="mobile-value-result" aria-live="polite">
    <span>Computed value</span>
    <output id="mobile-result">Loading…</output>
    <p id="mobile-comparison"></p>
  </div>

  <fieldset>
    <legend>Root metrics</legend>
    <div class="mobile-value-grid">
      <label>Root font size (px)<input data-uniform="root_font_size" type="number" min="0" step="0.1" value="16" /></label>
      <label>Root line height (px)<input data-uniform="root_line_height" type="number" min="0" step="0.1" value="24" /></label>
    </div>
  </fieldset>

  <fieldset>
    <legend>Viewport sizes in CSS pixels</legend>
    <div class="mobile-value-grid">
      <label>Large/default width<input data-uniform="viewport_width" type="number" min="0" step="0.1" /></label>
      <label>Large/default height<input data-uniform="viewport_height" type="number" min="0" step="0.1" /></label>
      <label>Small width<input data-uniform="small_viewport_width" type="number" min="0" step="0.1" /></label>
      <label>Small height<input data-uniform="small_viewport_height" type="number" min="0" step="0.1" /></label>
      <label>Dynamic width<input data-uniform="dynamic_viewport_width" type="number" min="0" step="0.1" /></label>
      <label>Dynamic height<input data-uniform="dynamic_viewport_height" type="number" min="0" step="0.1" /></label>
      <label>Visual width<input data-context="visual_viewport_width" type="number" min="0" step="0.1" /></label>
      <label>Visual height<input data-context="visual_viewport_height" type="number" min="0" step="0.1" /></label>
      <label>Visual offset X<input data-context="visual_viewport_offset_x" type="number" min="0" step="0.1" /></label>
      <label>Visual offset Y<input data-context="visual_viewport_offset_y" type="number" min="0" step="0.1" /></label>
    </div>
  </fieldset>

  <details open>
    <summary>Safe-area environment values</summary>
    <div class="mobile-value-grid">
      <label>Safe-area top<input data-uniform="safe_area_inset_top" type="number" min="0" step="0.1" /></label>
      <label>Safe-area right<input data-uniform="safe_area_inset_right" type="number" min="0" step="0.1" /></label>
      <label>Safe-area bottom<input data-uniform="safe_area_inset_bottom" type="number" min="0" step="0.1" /></label>
      <label>Safe-area left<input data-uniform="safe_area_inset_left" type="number" min="0" step="0.1" /></label>
      <label>Maximum top<input data-uniform="safe_area_max_inset_top" type="number" min="0" step="0.1" /></label>
      <label>Maximum right<input data-uniform="safe_area_max_inset_right" type="number" min="0" step="0.1" /></label>
      <label>Maximum bottom<input data-uniform="safe_area_max_inset_bottom" type="number" min="0" step="0.1" /></label>
      <label>Maximum left<input data-uniform="safe_area_max_inset_left" type="number" min="0" step="0.1" /></label>
    </div>
  </details>

  <details>
    <summary>Virtual-keyboard environment values</summary>
    <div class="mobile-value-grid">
      <label>Keyboard top<input data-uniform="keyboard_inset_top" type="number" min="0" step="0.1" /></label>
      <label>Keyboard right<input data-uniform="keyboard_inset_right" type="number" min="0" step="0.1" /></label>
      <label>Keyboard bottom<input data-uniform="keyboard_inset_bottom" type="number" min="0" step="0.1" /></label>
      <label>Keyboard left<input data-uniform="keyboard_inset_left" type="number" min="0" step="0.1" /></label>
      <label>Width<input data-uniform="keyboard_inset_width" type="number" min="0" step="0.1" /></label>
      <label>Height<input data-uniform="keyboard_inset_height" type="number" min="0" step="0.1" /></label>
    </div>
  </details>
</div>

<script type="module">
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const expression = document.getElementById("mobile-expression");
const presetSelect = document.getElementById("mobile-preset");
const result = document.getElementById("mobile-result");
const resultPanel = document.getElementById("mobile-result-panel");
const comparison = document.getElementById("mobile-comparison");
const uniformInputs = [...document.querySelectorAll("[data-uniform]")];
const contextInputs = [...document.querySelectorAll("[data-context]")];

const base = {
  root_font_size: 16, root_line_height: 24,
  safe_area_inset_top: 0, safe_area_inset_right: 0, safe_area_inset_bottom: 0, safe_area_inset_left: 0,
  safe_area_max_inset_top: 0, safe_area_max_inset_right: 0, safe_area_max_inset_bottom: 0, safe_area_max_inset_left: 0,
  keyboard_inset_top: 0, keyboard_inset_right: 0, keyboard_inset_bottom: 0, keyboard_inset_left: 0,
  keyboard_inset_width: 0, keyboard_inset_height: 0,
  visual_viewport_offset_x: 0, visual_viewport_offset_y: 0,
};

const presets = {
  "iphone-visible": { ...base, viewport_width: 393, viewport_height: 852, small_viewport_width: 393, small_viewport_height: 745, dynamic_viewport_width: 393, dynamic_viewport_height: 745, visual_viewport_width: 393, visual_viewport_height: 745, safe_area_inset_top: 59, safe_area_inset_bottom: 34, safe_area_max_inset_top: 59, safe_area_max_inset_bottom: 34 },
  "iphone-keyboard": { ...base, viewport_width: 393, viewport_height: 852, small_viewport_width: 393, small_viewport_height: 745, dynamic_viewport_width: 393, dynamic_viewport_height: 745, visual_viewport_width: 393, visual_viewport_height: 430, safe_area_inset_top: 59, safe_area_inset_bottom: 34, safe_area_max_inset_top: 59, safe_area_max_inset_bottom: 34, keyboard_inset_top: 430, keyboard_inset_width: 393, keyboard_inset_height: 315 },
  "android-visible": { ...base, viewport_width: 412, viewport_height: 915, small_viewport_width: 412, small_viewport_height: 800, dynamic_viewport_width: 412, dynamic_viewport_height: 800, visual_viewport_width: 412, visual_viewport_height: 800, safe_area_inset_top: 24, safe_area_max_inset_top: 24 },
  "android-keyboard": { ...base, viewport_width: 412, viewport_height: 915, small_viewport_width: 412, small_viewport_height: 800, dynamic_viewport_width: 412, dynamic_viewport_height: 800, visual_viewport_width: 412, visual_viewport_height: 480, safe_area_inset_top: 24, safe_area_max_inset_top: 24, keyboard_inset_top: 480, keyboard_inset_width: 412, keyboard_inset_height: 320 },
  "android-resizes-content": { ...base, viewport_width: 412, viewport_height: 915, small_viewport_width: 412, small_viewport_height: 800, dynamic_viewport_width: 412, dynamic_viewport_height: 480, visual_viewport_width: 412, visual_viewport_height: 480, safe_area_inset_top: 24, safe_area_max_inset_top: 24, keyboard_inset_top: 480, keyboard_inset_width: 412, keyboard_inset_height: 320 },
};

const wasm = await WebAssembly.instantiateStreaming(fetch("/text/css/css-expression-to-value.wasm"));
const exports = wasm.instance.exports;

function applyPreset(name) {
  const values = presets[name];
  if (!values) return;
  for (const input of [...uniformInputs, ...contextInputs]) {
    const key = input.dataset.uniform || input.dataset.context;
    input.value = values[key] ?? 0;
  }
  calculate();
}

function calculate() {
  try {
    for (const input of uniformInputs) {
      const value = Number(input.value);
      if (!Number.isFinite(value)) throw new Error("Every scenario value must be a finite number.");
      exports[`uniform_set_${input.dataset.uniform}`](value);
    }
    const bytes = encoder.encode(expression.value);
    const inputPointer = exports.input_ptr();
    if (bytes.length > exports.input_utf8_cap()) throw new Error("Expression is too long.");
    new Uint8Array(exports.memory.buffer, inputPointer, bytes.length).set(bytes);
    const packed = BigInt.asUintN(64, exports.render(bytes.length));
    if ((packed >> 63n) !== 0n) throw new Error("Expression is invalid.");
    const outputLength = Number(packed & 0xffff_ffffn);
    const outputPointer = Number((packed >> 32n) & 0x7fff_ffffn);
    const computed = decoder.decode(new Uint8Array(exports.memory.buffer, outputPointer, outputLength));
    result.textContent = computed;
    resultPanel.classList.remove("mobile-value-error");

    const visualHeight = Number(document.querySelector('[data-context="visual_viewport_height"]').value);
    const numeric = computed.endsWith("px") ? Number(computed.slice(0, -2)) : NaN;
    comparison.textContent = Number.isFinite(numeric)
      ? `Current visual viewport height: ${visualHeight}px. If this value is used as a height from the visual viewport top, the numerical difference is ${(numeric - visualHeight).toFixed(2).replace(/\.00$/, "")}px.`
      : `Current visual viewport height: ${visualHeight}px. The result is unitless.`;
  } catch (error) {
    result.textContent = "Invalid expression";
    comparison.textContent = "Check the supported units, functions, and scenario values.";
    resultPanel.classList.add("mobile-value-error");
  }
}

presetSelect.addEventListener("change", () => applyPreset(presetSelect.value));
expression.addEventListener("input", calculate);
for (const input of [...uniformInputs, ...contextInputs]) {
  input.addEventListener("input", () => {
    presetSelect.value = "custom";
    calculate();
  });
}
applyPreset(presetSelect.value);
</script>

## Supported expressions

The evaluator supports `px`, `rem`, `rlh`, physical `v*`/`sv*`/`lv*`/`dv*` units, arithmetic, `calc()`, `min()`, `max()`, `clamp()`, safe-area environment values, and keyboard environment values.

It resolves one numeric expression. It does not calculate layout, determine whether an element scrolls, or emulate a particular browser version. The visual viewport comparison is contextual information rather than a CSS unit.

## CLI

```bash
echo -n 'calc(100dvh - max(1rlh, env(safe-area-inset-bottom)))' | \
  npx qipdo qip.dev text/css/css-expression-to-value.wasm \
  -u root_line_height=24 -u dynamic_viewport_height=745 \
  -u safe_area_inset_bottom=34
```

The viewport model follows [CSS Values and Units](https://drafts.csswg.org/css-values-4/#viewport-relative-lengths). Safe-area names come from [CSS Environment Variables](https://drafts.csswg.org/css-env-1/#safe-area-insets), and keyboard geometry follows the [Virtual Keyboard API](https://w3c.github.io/virtual-keyboard/#keyboard-inset-variables).
