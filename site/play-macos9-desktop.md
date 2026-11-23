# Mac OS 9 Desktop

A QIP interactive desktop sketch of the Mac OS 9 Platinum Finder, drawn pixel for pixel at its real size.

Controls:

- Drag icons to rearrange them, or drag on the desktop to select several
- Drag the title bar or the size box. The window follows a dotted outline and moves when you let go
- Use the close, zoom and collapse boxes, the scroll bars, and click a row in the list
- Press on a menu title and release on an item. Release on the title to keep the menu open
- Right-click the desktop for its contextual menu
- `R`: reset the desktop

<style>
#macos9-desktop canvas {
  image-rendering: pixelated;
}
</style>

<qip-play id="macos9-desktop" canvas-width="640px" canvas-height="480px">
  <source src="/gui/macos9-desktop.wasm" type="application/wasm" />
</qip-play>
