# Cover Flow

The Cover Flow renderer, styled after the 2006 iTunes and iPod original: projective covers in tight ~70° side stacks on a black stage, mirrored floor reflections, bilinear album sampling, antialiased edges, side-cover shading, and spring easing. Album titles and labels are rasterized at runtime from Inter Display's outlines, with kerning.

The component applies input events and animation time before it publishes a new
KTX2 frame. Its feature flags are retained interaction state; it does not
export configuration uniforms.

Compare against the browser-native [WebGL2 renderer](/play-cover-flow-webgl2) at the same displayed size.

Controls:

- Drag left/right: move through albums with inertia
- Tap an album: select it
- Scroll bar: drag the thumb to scrub through albums, or press the track to jump there
- Keyboard: `Left/Right` or `A/D`
- Feature toggles: `L` lighting, `S` spring easing

<qip-play canvas-width="720px" canvas-height="auto">
  <source src="/gui/cover-flow.wasm" type="application/wasm" />
</qip-play>
