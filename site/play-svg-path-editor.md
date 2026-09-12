# SVG Path Editor

Edit cubic SVG paths without converting the rest of the document to an editor-specific format. The component preserves elements and attributes that it does not edit. It adds a marked overlay to each rendered SVG for controls and selection feedback.

- Press `P` for the Pen tool. Click to add a corner or drag to pull mirrored cubic handles. Click the first anchor to close the path, press `Enter` to keep it open, or press `Escape` to cancel it.
- Press `V` for the Selection tool. Click a path or anchor, drag it, or drag an empty area to select anchors with a marquee.
- Drag a control handle to keep its opposite handle mirrored. Hold `Alt` while dragging to break the pair.
- Use the arrow keys to move the selection by one document unit, or hold `Shift` to move it by ten. `Delete` and `Backspace` remove the selected anchors or paths.

This increment does not edit quadratic (`Q`, `T`) or arc (`A`) commands. It preserves those paths as uneditable source content. It also does not expand `<use>`, interpret CSS transforms, or provide undo and redo.

<qip-play aria-label="SVG path editor" canvas-width="min(100%, 800px)">
  <source name="input" src="/example.svg" type="image/svg+xml">
  <source src="/interactive/svg-path-editor.wasm" type="application/wasm">
</qip-play>
