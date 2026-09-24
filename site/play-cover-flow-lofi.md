# Cover Flow Lofi

The lighter Cover Flow renderer: projective covers, reflections, and fast nearest-neighbor album sampling.

Selection and inertia are retained update state. The component asks for a
16 ms wake while motion continues and publishes a new KTX2 frame only from
`render`.

Controls:

- Drag left/right: move through albums with inertia
- Tap an album: select it
- Keyboard: `Left/Right` or `A/D`

<qip-play>
  <source src="/gui/cover-flow-lofi.wasm" type="application/wasm" />
</qip-play>
