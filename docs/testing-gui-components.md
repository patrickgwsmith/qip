# Testing GUI Components

GUI components are easiest to test at three boundaries: the Wasm module, the
host loop, and a real browser. Keep each test at the lowest boundary that can
prove the behavior. A module test should not need a browser, and every
component should not repeat the host's event-queue tests.

## Test The Wasm Contract Directly

Build the component, instantiate it without imports, then call the same exports a host calls:

```sh
make -j components/interactive/calculator.wasm
node --test test/calculator-snake-interactive.mjs
```

```js
const bytes = await readFile("components/interactive/calculator.wasm");
const { instance } = await WebAssembly.instantiate(bytes, {});
const game = instance.exports;

const outputSize = game.render(0); // Initializes and presents at time zero.

game.begin_update_at(1n);       // Bootstrap the Timed capability.
game.finish_update();

game.begin_update_at(2n);
game.key_event("2".codePointAt(0), 1);
game.finish_update();           // State changes; output bytes stay unchanged.

game.render(0);                 // Presents the updated state as KTX2.
```

At this level, check contract behavior rather than browser mechanics:

- The KTX2 dimensions and output capacity agree.
- Accepted events return `1`; ignored events return `0`.
- Readonly or out-of-range targets leave state unchanged.
- A meaningful state transition changes the framebuffer.
- Repeating an event over the same semantic target is ignored when it would produce identical pixels.

Copy output bytes before another `render(0)` call. Updates, events, and
`finish_update()` must not change the published bytes, but the next render writes into the same
linear-memory region.

### Test Timed Updates

The first Timed component has a direct contract test:

```sh
make -j components/interactive/god-rays-optimized.wasm
node --test test/god-rays-optimized-timed.mjs
```

For a Timed component, check that its initial Content render completes without
an update, later update times increase strictly, and omitted uniforms use their
authored defaults independently in updates and presentation. `finish_update`
may advance state and schedule a wake, but only a later `render` may replace
the KTX2 bytes. Invalid call order traps as a host protocol violation.

The first event-driven update test uses Tic-Tac-Toe:

```sh
make -j components/interactive/tic-tac-toe-sun-moon.wasm
node --test test/tic-tac-toe-interactive.mjs
```

It checks that events have no timestamp argument, ordered events update retained
state, `finish_update` preserves output bytes, rendering inside an update traps,
and reset is an ordinary event rather than a rejected update. The shared
`<qip-play>` test checks that an accepted event causes one later presentation
while an ignored event does not.

Calculator and Snake cover the next combinations:

```sh
make -j components/interactive/calculator.wasm components/interactive/snake.wasm
node --test test/calculator-snake-interactive.mjs
```

Calculator tests several ordered key events in one application-style update.
Snake tests fixed-step advancement before events at the same time, future wake
scheduling, bounded catch-up, pausing, and separate presentation. Both test
that lifecycle misuse traps instead of becoming a correctable user rejection.

Spreadsheet and Side Scroller cover the current update lifecycle directly:

```sh
make -j components/interactive/spreadsheet.wasm components/interactive/side-scroller-platformer.wasm
node --test test/spreadsheet-platformer-update.mjs
```

Spreadsheet tests application deadlines through its blinking edit caret and
uses the enclosing update time for double-click handling. Side Scroller tests a
16 ms fixed game step, held keys, and an eight-step catch-up limit. Both tests
also check KTX2 output, output isolation, and trapping lifecycle violations.

Cover Flow and Shadow Rendering test event-owned retained state:

```sh
make -j components/interactive/cover-flow.wasm components/interactive/shadow-rendering.wasm
node --test test/cover-flow-shadow-interactive.mjs
```

The tests check that the old uniform and framebuffer exports are absent, that
renderless updates preserve the published output, and that reset restores the
initial frame. The Cover Flow case also checks its 16 ms animation wake.

Render Counts, Mandelbrot, and Perlin Noise cover update diagnostics,
event-only retained state, and held-key animation:

```sh
make -j components/interactive/render-counts.wasm components/interactive/mandelbrot.wasm components/interactive/perlin-noise.wasm
node --test test/render-counts-mandelbrot-perlin.mjs
```

These tests check event times inherited from `begin_update_at`, renderless
output retention, deterministic reset, scheduled wakes, and a jump to the
largest valid update time without an unbounded catch-up loop.

Moon Phases, Cover Flow Lofi, and Dock Magnification cover source input and two
more animation shapes:

```sh
make -j components/interactive/moon-phases.wasm components/interactive/cover-flow-lofi.wasm components/interactive/dock-magnification.wasm
node --test test/moon-cover-lofi-dock-interactive.mjs
```

The Moon Phases test passes an exact date slice to `render` and then changes
the date through a renderless event update. The Cover Flow and Dock tests
check that inertia and hover animation can advance without replacing the last
published KTX2 output.

Layout Systems, Browser Security, and Graph Calculator cover event-driven
components which do not schedule future work:

```sh
make -j components/interactive/layout-systems.wasm components/interactive/browser-security.wasm components/interactive/graph-calculator.wasm
node --test test/layout-security-graph-interactive.mjs
```

The tests finish controls without rendering, verify that the old KTX2 output
remains available, and materialize the changed state in a later render.
The graph test also distinguishes an intentionally empty expression from its
uninitialized default.

Aces Up and the original God Rays port cover a scheduled game transition and a
large, event-free uniform set:

```sh
make -j components/interactive/aces-up.wasm components/interactive/god-rays.wasm
node --test test/aces-god-rays-interactive.mjs
```

The tests prove that an Aces Up deal can finish without replacing the published
frame, that reset reproduces the initial deal, and that God Rays accepts a
partial uniform set while using defaults for the omitted settings.

Sudoku and WebOS Card View cover a deterministic generated document and a
continuously scheduled interface animation:

```sh
make -j components/interactive/sudoku.wasm components/interactive/webos-card-view.wasm
node --test test/sudoku-ui.mjs test/sudoku-webos-interactive.mjs
```

The Sudoku workflow opens a new update for every pointer sequence and
checks hard-coded pixel colors inside the KTX2 payload. The WebOS test checks
that a renderless selection and animation step leaves the last frame intact.

Tile World, Tetris, and Web Mechanics cover bounded game-loop catch-up and a
further event-only component:

```sh
make -j components/interactive/tile-world-12x12.wasm components/interactive/tetris.wasm components/interactive/web-mechanics.wasm
node --test test/tile-tetris-web-interactive.mjs
```

The game tests jump directly to the largest valid update time. Tile World
replays at most 24 movement steps and Tetris replays at most 24 drops. Both then
discard older backlog and schedule from the finished update time. This keeps work
bounded when a host resumes after a long pause.

IEEE 754 Floats and the two financial charts cover retained selections on
larger, event-driven renderers:

```sh
make -j components/interactive/ieee-754-floats.wasm components/interactive/shutterstock-earnings.wasm components/interactive/openai-anthropic-arr.wasm
node --test test/floats-financial-charts-interactive.mjs
```

Each test finishes a selection update without rendering, checks that the published
KTX2 bytes remain unchanged, renders the selection later, and verifies that a
reset restores the initial frame.

Formula 1 Map and Page Load Waterfall cover pointer-heavy retained state and a
short scheduled animation:

```sh
make -j components/interactive/formula-1-map.wasm components/interactive/page-load-waterfall.wasm
node --test test/map-waterfall-interactive.mjs
```

The map test finishes a zoom without rendering. The waterfall test starts its
playback without rendering, uses the wake time returned by `finish_update`, and then
renders the advanced timeline. Both tests verify that reset reproduces the
initial KTX2 frame.

Photo Light Table and Xbox Dashboard cover selection animation and continuous
animation:

```sh
make -j components/interactive/photo-light-table.wasm components/interactive/xbox-dashboard.wasm
node --test test/photo-xbox-interactive.mjs
```

The light table keeps its large background cache private and publishes only
from `render`. The Xbox test checks that its pulse follows update time,
not the number of host calls. Both retain renderless input and reset to the
same initial KTX2 bytes.

Paint and PS2 Menu cover an editable document and another time-driven menu:

```sh
make -j components/interactive/paint.wasm components/interactive/ps2-menu.wasm
node --test test/paint-ps2-interactive.mjs
```

The Paint test finishes a multi-event stroke without rendering and verifies
that the previous image remains published. The PS2 test verifies renderless
selection and its next-frame schedule. Reset restores the initial frame in
both components.

The final GUI component test covers nine different application and game
shapes:

```sh
make -j components/interactive/gameboy-camera.wasm \
  components/interactive/liars-dice.wasm \
  components/interactive/macos9-desktop.wasm \
  components/interactive/macosx-leopard-desktop.wasm \
  components/interactive/org_planner.wasm \
  components/interactive/peon-gold.wasm \
  components/interactive/textedit.wasm \
  components/interactive/vertical-shooter.wasm \
  components/interactive/windows95-desktop.wasm
node --test test/final-interactive-components.mjs
```

It checks the KTX2 Content ABI, absence of legacy exports, output isolation,
component-specific wake results, and traps for lifecycle misuse. Zig inline
tests retain detailed editor, desktop, and game-state regression cases.

The SVG path editor uses generic Time and Events output instead of the KTX2
GUI contract. Test its UTF-8 SVG ABI and retained-state lifecycle separately:

```sh
make components/interactive/svg-path-editor.wasm
node --test test/svg-path-editor.mjs test/qip-play-svg.mjs
```

## Test Semantic Pointer Targets

Convert raw coordinates into one semantic hit result and use it for hover and click handling. A grid with nested controls might return `{ cell_index, subcell_index }`. Tests can then use a small table of representative coordinates instead of reproducing UI logic through many screenshots.

For a 3x3 target, cover the whole row-major mapping when that mapping is the risky part:

```text
1 2 3
4 5 6
7 8 9
```

Also move twice within one target. The first move should be accepted, while the second should return `0` and leave the framebuffer hash unchanged. This checks the optimization at the module boundary without depending on timing.

## Check Frames Without Large Snapshot Suites

Full framebuffer snapshots are useful for a few stable reference states, but they become expensive when every hover and pressed state gets its own fixture. Prefer focused assertions:

- Sample a stable interior pixel for a background or highlight.
- Count a known color within one cell or control.
- Hash the full frame to prove that ignored input changes nothing.
- Check a small region for a bitmap glyph rather than snapshotting the whole page.

Use exact pixel checks for component-rendered bitmap graphics. Browser text, CSS layout, timing labels, and antialiasing are better checked structurally or in a browser screenshot.

## Test The Host Once

Host tests should cover behavior shared by every component. In this repo, `test/qip-play-debug-stats.mjs` loads the browser runtime in a small DOM shim and checks concerns such as:

- DOM button and key translation.
- Pointer leave behavior.
- Focus loss releasing held keys and pointer buttons.
- Canvas focus and context-menu scoping.
- Event queue ordering.
- Accepted events opening and finishing an update.
- Ignored events avoiding an unnecessary presentation render.
- Complete Timed uniform updates and `finish_update` wake results.
- Hidden-page updates which leave the previous KTX2 output in place.
- A later visible render which presents the new state.

Do not repeat those assertions in each component test unless the component adds its own state transition at that boundary.

### Compare Host Decisions As Text

The JavaScript and Go host tests also run Calculator and Snake against one
plain-text decision trace:

```sh
node --test test/interactive-host-decisions.mjs
go test -run TestGoHostDecisionsMatchSharedInteractiveTrace .
```

Both tests compare their complete output with
`testdata/interactive-host-decisions.txt`. The JavaScript test drives the real
`<qip-play>` methods. The Go test makes the same ABI calls with wazero and
applies the same host decisions. A normal string comparison detects a changed
call order, return value, wake decision, or render decision.

The trace includes an application-style component and a timed game. Calculator
checks an ignored event, an accepted event, and pointer-before-key ordering at
one update time. Snake checks bootstrap scheduling, a fixed step which runs
before an event at the same time, and pausing with no next wake. Add a trace
case when host control flow is the risk. Keep component-only state and pixel
assertions in the direct Wasm or Zig tests.

## Verify The Browser Path

Use a real browser for the remaining integration risks:

1. Start the site with `make dev`.
2. Wait for the canvas's intrinsic width and height, not an arbitrary delay.
3. Convert logical render coordinates through `getBoundingClientRect()` before moving or clicking the pointer.
4. Sample `canvas.getContext("2d").getImageData(...)` for one or two important states.
5. Check desktop and narrow viewports when CSS scales the fixed framebuffer.

Repository tests may inspect private counters such as `<qip-play>._renderN` to prove that moving within one semantic hover target does not render again. That counter is host instrumentation, not part of the public component contract.

Take a screenshot when layout or visual hierarchy is under review. Pixel samples establish precise output; the screenshot catches clipping, awkward spacing, and controls that are technically present but visually misplaced.

## Keep The Suite Small

A typical GUI component needs only a few durable tests:

- One initialization and primary-workflow smoke test.
- One test for its highest-risk coordinate or state mapping.
- One ignored-input or readonly boundary.
- A browser check only for behavior that direct Wasm and host tests cannot prove.

Avoid duplicating the same state across full snapshots, Node, browser automation, and host-runtime tests. Keep the assertion at the boundary that owns the behavior.
