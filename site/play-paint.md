# Paint

A small black-and-white bitmap editor for sketching directly inside a QIP interactive module.

Controls:

- Drag on the canvas to draw
- Left toolbar: pencil, eraser, brush, line, rectangle, oval, fill, spray
- Right click draws with white for tools that support it
- `[` / `]`: smaller or larger brush
- `Z`: undo
- `C`: clear
- `I`: invert

<qip-play>
  <source src="/gui/paint.wasm" type="application/wasm" />
</qip-play>

Each update changes the bitmap, undo buffer, tool, and drag state together.
Only `render` replaces the published KTX2 image.
