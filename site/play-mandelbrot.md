# Mandelbrot Explorer

An explorer for the Mandelbrot set, built as an interactive QIP component. It
renders at twice its display size and colours each pixel by its smooth escape
count, so there are no iteration bands. The iteration limit grows as you zoom
in, so deep views keep their detail up to nearly a trillion times
magnification, where 64-bit floating point runs out.

Escape counts are component state, worked out during updates instead of in
`render`. Each update spends a fixed number of iterations refining the view
from the centre outwards, first in 4×4 blocks, then 2×2 blocks, then every
pixel. While work remains, `finish_update` asks for another update. A deep view
sharpens over a second or so, and no single frame blocks for long. The budget
counts iterations, not milliseconds, so the same updates always produce the
same frame.

Zooms animate around the point you clicked. Each animation frame stretches the
previous picture, then refines it. Panning moves by whole pixels, so the work
already done moves with the view and only the newly exposed strip needs
computing.

Controls:

- Click to zoom in at that point; right-click to zoom out
- Drag to pan
- Arrow keys pan; hold Shift for bigger steps
- `+` or `=` zooms in, `-` zooms out
- `P` cycles the palette
- `H` hides the coordinates
- `R`, `0`, `Home` or `Escape` returns to the whole set

<qip-play canvas-width="480px" canvas-height="auto">
  <source src="/gui/mandelbrot.wasm" type="application/wasm" />
</qip-play>
