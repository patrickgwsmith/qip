# Photo Light Table

Drag the table, click a photo to center it, or use arrow keys/WASD after focusing the frame.

<qip-play id="photo-light-table-play" canvas-width="800px" canvas-height="auto">
  <source src="/gui/photo-light-table.wasm" type="application/wasm" />
</qip-play>

This example uses downloaded Unsplash photos baked into fixed-size TGA BGRA8 textures so the renderer can spend its frame time on affine quads, bilinear sampling, edge antialiasing, reflections, shadows, and packed framebuffer writes.

Selection and movement update retained state before the next KTX2 frame is
rendered. The component keeps its background cache private, so events cannot
overwrite the last published frame.
