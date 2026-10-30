# Cover Flow

The Cover Flow renderer, styled after the 2006 iTunes and iPod original: projective covers in tight ~70° side stacks on a black stage, mirrored floor reflections, bilinear album sampling, antialiased edges, side-cover shading, and spring easing. Album titles and labels are rasterized at runtime from Inter Display's outlines, with kerning.

The component applies input events and animation time before it publishes a new
KTX2 frame. Its feature flags are retained interaction state; it does not
export configuration uniforms.

Controls:

- Drag left/right: move through albums with inertia
- Tap an album: select it
- Scroll bar: drag the thumb to scrub through albums, or press the track to jump there
- Keyboard: `Left/Right` or `A/D`
- Feature toggles: `L` lighting, `S` spring easing

<qip-play canvas-width="720px" canvas-height="auto">
  <source src="/gui/cover-flow.wasm" type="application/wasm" />
</qip-play>

## WebGL2

The same scene drawn through WebGL2 in the browser, for comparison at the same displayed size. It renders at 1440x960 and is displayed at 720x480. Text is set in Inter Display by the browser, with kerning. It also supports `Home`/`End`.

<script type="module" src="/cover-flow-webgl2.js"></script>

<cover-flow-webgl2></cover-flow-webgl2>
