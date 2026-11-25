# PlayStation 2 Menu

A console menu in the style of the PlayStation 2 Browser and System
Configuration screens. It renders at twice its display size, with Inter
Display text over a slowly turning field of light pillars.

- **Browser** shows two memory cards and a disc tray. Open a card to see its
  saves as spinning icons. Each save can be copied to the other card, with a
  progress bar, or deleted after a confirmation. Free space updates as you go.
- **System Configuration** changes the language (English, French, German,
  Spanish or Italian, and every label is translated), the accent colour,
  background motion and the button guide. It also shows console information.

Controls:

- Arrow keys or `WASD` move the selection
- `Left` / `Right` change a setting
- `Enter`, `Space` or `X` selects
- `Escape`, `Backspace` or `O` goes back
- Hover to select and click to open. Right-click, or click the title, to go back

<qip-play canvas-width="480px" canvas-height="auto">
  <source src="/gui/ps2-menu.wasm" type="application/wasm" />
</qip-play>

All motion comes from update time. Each update eases the selection and moves
transitions on by the time since the previous update, so the same updates
always produce the same frame. While anything is moving, `finish_update` asks
for the next frame. With background motion off, the menu stops asking once it
settles. Only `render` replaces the published KTX2 image.
