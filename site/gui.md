<title>GUI components</title>

# GUI components

These components keep graphical state and render frames in a browser host.
Most return KTX2 images; the SVG path editor returns SVG. Open the
[browser demos](/play) to try them, or download a `.wasm` file to host one in your own
application. The [GUI contract](/docs/gui-components) describes KTX2 output,
events, and timing.

## Editors and tools

- [`calculator.wasm`](/gui/calculator.wasm) implements a graphical calculator.
- [`graph-calculator.wasm`](/gui/graph-calculator.wasm) plots entered expressions.
- [`paint.wasm`](/gui/paint.wasm) draws with pointer input.
- [`spreadsheet.wasm`](/gui/spreadsheet.wasm) edits a grid of cells.
- [`svg-path-editor.wasm`](/gui/svg-path-editor.wasm) edits vector paths and returns SVG frames.
- [`textedit.wasm`](/gui/textedit.wasm) provides a plain-text editor.
- [`photo-light-table.wasm`](/gui/photo-light-table.wasm) arranges and browses photos.
- [`gameboy-camera.wasm`](/gui/gameboy-camera.wasm) recreates a camera interface.
- [`gif-player.wasm`](/gui/gif-player.wasm) advances GIF frames over time without input events.

## Games

- [`aces-up.wasm`](/gui/aces-up.wasm) plays Aces Up solitaire.
- [`liars-dice.wasm`](/gui/liars-dice.wasm) plays Liar's Dice.
- [`peon-gold.wasm`](/gui/peon-gold.wasm) runs the Peon Gold game loop.
- [`side-scroller-platformer.wasm`](/gui/side-scroller-platformer.wasm) runs a side-scrolling platform game.
- [`snake.wasm`](/gui/snake.wasm) combines key input with scheduled movement.
- [`sudoku.wasm`](/gui/sudoku.wasm) edits a Sudoku grid.
- [`tetris.wasm`](/gui/tetris.wasm) runs a falling-block game.
- [`tic-tac-toe-sun-moon.wasm`](/gui/tic-tac-toe-sun-moon.wasm) plays a Sun and Moon tic-tac-toe variant.
- [`tile-world-12x12.wasm`](/gui/tile-world-12x12.wasm) moves through a small tile map.
- [`vertical-shooter.wasm`](/gui/vertical-shooter.wasm) runs a scrolling shooter.

## Interface studies

- [`browser-security.wasm`](/gui/browser-security.wasm) presents a browser-security interface.
- [`cover-flow.wasm`](/gui/cover-flow.wasm) and [`cover-flow-lofi.wasm`](/gui/cover-flow-lofi.wasm) browse a Cover Flow layout.
- [`dock-magnification.wasm`](/gui/dock-magnification.wasm) magnifies icons around the pointer.
- [`layout-systems.wasm`](/gui/layout-systems.wasm) compares layout behavior.
- [`macintosh-1bit.wasm`](/gui/macintosh-1bit.wasm) renders a monochrome Macintosh interface.
- [`macos9-desktop.wasm`](/gui/macos9-desktop.wasm) and [`macosx-leopard-desktop.wasm`](/gui/macosx-leopard-desktop.wasm) render desktop interfaces.
- [`org_planner.wasm`](/gui/org_planner.wasm) presents an organization planner.
- [`ps2-menu.wasm`](/gui/ps2-menu.wasm) renders a PlayStation 2 style menu.
- [`webos-card-view.wasm`](/gui/webos-card-view.wasm) presents a card interface.
- [`windows95-desktop.wasm`](/gui/windows95-desktop.wasm) renders a Windows 95 style desktop.
- [`xbox-dashboard.wasm`](/gui/xbox-dashboard.wasm) renders an Xbox style dashboard.

## Visualizations and rendering

- [`chronograph.wasm`](/gui/chronograph.wasm) renders a timed chronograph.
- [`formula-1-map.wasm`](/gui/formula-1-map.wasm) shows a Formula 1 venue map.
- [`god-rays.wasm`](/gui/god-rays.wasm) and [`god-rays-optimized.wasm`](/gui/god-rays-optimized.wasm) render animated light shafts.
- [`ieee-754-floats.wasm`](/gui/ieee-754-floats.wasm) explains floating-point values visually.
- [`mandelbrot.wasm`](/gui/mandelbrot.wasm) explores the Mandelbrot set.
- [`moon-phases.wasm`](/gui/moon-phases.wasm) shows the lunar phase cycle.
- [`openai-anthropic-arr.wasm`](/gui/openai-anthropic-arr.wasm) charts annual recurring revenue data.
- [`page-load-waterfall.wasm`](/gui/page-load-waterfall.wasm) draws a page-load timeline.
- [`perlin-noise.wasm`](/gui/perlin-noise.wasm) visualizes procedural noise.
- [`render-counts.wasm`](/gui/render-counts.wasm) displays render and update counts.
- [`shadow-rendering.wasm`](/gui/shadow-rendering.wasm) demonstrates shadow rendering.
- [`shutterstock-earnings.wasm`](/gui/shutterstock-earnings.wasm) overlays earnings data.
- [`web-mechanics.wasm`](/gui/web-mechanics.wasm) illustrates browser mechanics.

For one-shot image transforms, use the [image content components](/image). For
terminal interfaces, browse the [TUI components](/tui).
