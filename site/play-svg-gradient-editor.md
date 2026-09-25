# SVG Gradient Editor

Build a linear or radial SVG gradient on the canvas. Drag the two end handles to set its position and reach. Drag a color stop along the line, or click the line to add one. Select a stop to adjust its hue, saturation, lightness, and opacity. Press `Delete` to remove a selected inner stop.

The color sliders use HSL. The SVG and CSS snippets export each stop as an sRGB hex color with separate opacity.

<qip-play id="gradient-editor" aria-label="SVG gradient editor" canvas-width="min(100%, 800px)" svg-inline>
  <source src="/gui/svg-gradient-editor.wasm" type="application/wasm">
</qip-play>

## CSS gradient

This code follows the stops and handles as you edit. Its positions match the 732 × 342 px swatch above.

<style>
#gradient-css-copy { position: relative; display: block; }
#gradient-css-copy > pre { margin-block-end: 0; }
#gradient-css-copy > pre > code { padding-inline-end: 7.5rem; }
#gradient-css-copy > button {
  position: absolute;
  top: 0.75rem;
  right: 0.75rem;
  display: block;
  padding: 0.4rem 0.65rem;
  border: 1px solid #547087;
  border-radius: 0.35rem;
  background: #1d394d;
  color: #f5f9fc;
  font: inherit;
  font-size: 0.8rem;
  line-height: 1.2;
  cursor: pointer;
}
#gradient-css-copy > button:hover { background: #2b526c; }
#gradient-css-copy > button:focus-visible { outline: 2px solid #3ec9f5; outline-offset: 2px; }
@media (max-width: 520px) {
  #gradient-css-copy > pre > code { padding-block-start: 3.25rem; padding-inline-end: 0.85rem; }
}
</style>

<copy-code id="gradient-css-copy">
  <pre><code id="gradient-css-code" class="language-css">Loading gradient…</code></pre>
</copy-code>

<script type="module">
import { svgGradientCSS } from "/svg-gradient-css.js";

const editor = document.getElementById("gradient-editor");
const code = document.getElementById("gradient-css-code");
const updateCode = () => {
  const svg = editor.querySelector("svg");
  if (svg) code.textContent = svgGradientCSS(svg);
};
new MutationObserver(updateCode).observe(editor, { childList: true, subtree: true });
updateCode();
</script>

Use the Linear and Radial buttons, or press `L` and `R`, to change the gradient type. Press `P` or click Preview to hide the editing controls. Press `P` again to return to editing. The component also exposes an `editing` uniform: set it to `0` to render an SVG with no editor overlay.

The SVG marks its editor group with `data-qip-gradient-overlay="true"`. Each interactive control has a `data-qip-gradient-control` role. Stop handles also carry `data-qip-gradient-stop-index`, and channel sliders carry `data-qip-gradient-channel`. These attributes let a host inspect the controls without relying on SVG element order.
