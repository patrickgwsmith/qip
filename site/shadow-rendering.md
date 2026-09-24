# Shadow Rendering Comparison

The sliders are retained as component state. Pointer and keyboard events update
them during an update, and `render` publishes the current view as KTX2.
The component does not expose the slider values as uniforms.

<qip-play canvas-width="1120px" canvas-height="auto">
  <source src="/gui/shadow-rendering.wasm" type="application/wasm" />
</qip-play>
