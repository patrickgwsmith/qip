# Mandelbrot Explorer

Viewport changes become retained component state. Rendering publishes a KTX2
frame; updates without a render leave the previous frame intact.

Controls:

- Arrow keys pan
- `=` and `+` zoom in
- `-` zoom out
- Click/tap to recenter

<qip-play>
  <source src="/gui/mandelbrot.wasm" type="application/wasm" />
</qip-play>
