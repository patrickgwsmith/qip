# Go `qip comply` vs JS `qipx comply` Differences For `./components`

Checked with:

```sh
./qip comply ./components > /tmp/go-comply-components.out 2>/tmp/go-comply-components.err
node npm/qipx/qipx.mjs comply ./components > /tmp/js-comply-components.out 2>/tmp/js-comply-components.err
```

Both commands currently agree on the high-level result:

```text
exit code: 1
stdout lines: 224
stderr lines: 0
pass=155 fail=67 total=222
```

The stdout is not byte-identical. There are 44 differing component lines.

## 1. Go Fails, JS Passes

### `components/image/jpeg/jpeg-strip-gps-exif.wasm`

Go:

```text
FAIL components/image/jpeg/jpeg-strip-gps-exif.wasm: comply: static qip contract checks failed
```

JS:

```text
PASS components/image/jpeg/jpeg-strip-gps-exif.wasm
```

Likely cause: Go runs static qip contract checks that `qipx` does not fully implement yet.

## 2. Go Passes, JS Fails

### `components/multipart/form-data/form-data-to-tar.wasm`

Go:

```text
PASS components/multipart/form-data/form-data-to-tar.wasm
```

JS:

```text
FAIL components/multipart/form-data/form-data-to-tar.wasm: invalid components/multipart/form-data/form-data-to-tar.wasm input content type: multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000
```

Likely cause: JS content-type validation rejects MIME parameters. Go currently accepts this content type.

Decision needed: decide whether QIP content types can include MIME parameters such as `multipart/form-data;boundary=...`, then align Go and JS.

## 3. Both Fail, But Diagnostics Differ

The Interactive components fail in both implementations. Go reports missing `input_ptr`; JS reports missing or ambiguous input capacity first.

Go pattern:

```text
FAIL <path>: <path> must export input_ptr
```

JS pattern:

```text
FAIL <path>: <path> must export exactly one input capacity: input_utf8_cap or input_bytes_cap
```

Affected components:

```text
gui/aces-up.wasm
gui/browser-security.wasm
gui/calculator.wasm
gui/cover-flow-lofi.wasm
gui/cover-flow.wasm
gui/dock-magnification.wasm
gui/formula-1-map.wasm
gui/gameboy-camera.wasm
gui/god-rays-optimized.wasm
gui/god-rays.wasm
gui/graph-calculator.wasm
gui/ieee-754-floats.wasm
gui/layout-systems.wasm
gui/liars-dice.wasm
gui/macos9-desktop.wasm
gui/macosx-leopard-desktop.wasm
gui/mandelbrot.wasm
gui/openai-anthropic-arr.wasm
gui/org_planner.wasm
gui/page-load-waterfall.wasm
gui/paint.wasm
gui/peon-gold.wasm
gui/perlin-noise.wasm
gui/photo-light-table.wasm
gui/ps2-menu.wasm
gui/render-counts.wasm
gui/shadow-rendering.wasm
gui/shutterstock-earnings.wasm
gui/side-scroller-platformer.wasm
gui/snake.wasm
gui/spreadsheet.wasm
gui/sudoku.wasm
gui/tetris.wasm
gui/textedit.wasm
gui/tic-tac-toe-sun-moon.wasm
gui/tile-world-12x12.wasm
gui/vector-editor.wasm
gui/vertical-shooter.wasm
gui/web-mechanics.wasm
gui/webos-card-view.wasm
gui/windows95-desktop.wasm
gui/xbox-dashboard.wasm
```

Likely cause: Content ABI validation order differs. Go checks `input_ptr` before input capacity. JS checks input capacity before `input_ptr`.

## Likely Parity Fixes

1. Add Go-equivalent static qip contract checks to `qipx`, or make Go omit that check from the default directory-summary contract if JS should stay intentionally smaller.
2. Decide the QIP rule for content-type parameters, then align Go and JS validation.
3. Align JS Content ABI validation order with Go:
   - `memory`
   - `render`
   - `input_ptr`
   - exactly one input capacity
   - `output_ptr`
   - exactly one output capacity
