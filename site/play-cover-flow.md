# Cover Flow Hifi

The high-fidelity Cover Flow renderer: projective covers, bilinear album sampling, antialiased edges, directional lighting, and spring easing.

The component applies input events and animation time before it publishes a new
KTX2 frame. Its feature flags are retained interaction state; it does not
export configuration uniforms.

Compare against the browser-native [WebGL2 renderer](/play-cover-flow-webgl2) at the same displayed size.

Controls:

- Drag left/right: move through albums with inertia
- Tap an album: select it
- Keyboard: `Left/Right` or `A/D`
- Feature toggles: `L` lighting, `S` spring easing

<qip-play canvas-width="720px" canvas-height="auto">
  <source src="/gui/cover-flow.wasm" type="application/wasm" />
</qip-play>
