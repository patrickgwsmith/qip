# Formula 1 Venue Map

Drag the map to pan. Use the `+` and `-` buttons, or the keyboard, to zoom.

The markers show the Formula 1 race venues from the 2026 calendar.

The component retains map input from each update before it renders the next
KTX2 frame. A host can retain pan and zoom changes while the component is
offscreen.

<qip-play canvas-width="960px" canvas-height="auto">
  <source src="/gui/formula-1-map.wasm" type="application/wasm" />
</qip-play>
