# Colosseum renderers: sectors versus a true 3D BSP

[`gui/colosseum.wasm`](../../gui/colosseum.zig) draws one scene two ways and
can switch between them while you play (press `B`):

- **Sectors (Build-style).** The level is 1,114 convex rooms with their own
  floor and ceiling planes. Each of a room's sides is cut into spans stacked
  from floor to ceiling: solid wall, an opening into another room, or open
  sky. A side can open onto several rooms stacked above one another, so the
  hypogeum runs under the arena and the upper ambulatory sits on the lower
  one. Each screen column follows its ray from room to room, and every
  opening narrows the rows the column can still draw.
- **True 3D BSP.** The same rooms become 7,027 convex polygons: every floor,
  ceiling, and solid span. A BSP built from the polygons' own planes orders
  them front to back. The walk culls subtrees whose bounding boxes are off
  screen or cover only pixels already drawn, then scan-converts each
  polygon facing the eye and shades only uncovered pixels. It has no
  precomputed visibility set, as Quake had.

Both renderers call the same per-pixel shading with the same ray and depth,
so their frames can be compared byte for byte. In all six views, 100% of
pixels match within 8/255 per channel. The Zig and Node tests require at
least 99%.

## Method

```sh
make -j gui/colosseum.wasm
node tools/bench-colosseum-renderers.mjs --runs 100 --warmup 10 \
  --csv benchmarks/colosseum-renderers/node-v8-ms-per-frame.csv
```

The tool reuses one instance, as `<qip-play>` does, and times `render` for one
640 by 480 frame. It sets a fixed view with the `bench_set_view` export, which
also hides the HUD. Renderers alternate sample by sample, so background load
affects both alike. The `-flat` rows replace textures and lighting with one
colour per surface. They still write all 307,200 pixels and their depths and
draw the gulls, so they measure visibility plus a fixed per-pixel cost that
both renderers share.

The first run used Node v26.3.0 (V8) on an Apple M5 with the repository's
ReleaseSmall build, 100 samples after 10 warmup renders. The level then had
507 rooms and a zero-thickness outer wall. The machine was busy (load average
8 to 11), so the p95 values are noisy; compare medians.

## Results

Median milliseconds per frame, first run (507 rooms):

| View | Sectors | 3D BSP | Sectors, flat | 3D BSP, flat |
| --- | ---: | ---: | ---: | ---: |
| Street, facing the arches | 9.59 | 12.14 | 3.11 | 4.66 |
| Deck, over the hypogeum | 10.99 | 11.76 | 3.06 | 4.26 |
| Hypogeum corridor | 9.32 | 11.52 | 2.74 | 3.86 |
| Lower ambulatory | 8.75 | 11.87 | 2.90 | 4.28 |
| Top terrace, whole bowl | 10.58 | 11.48 | 3.09 | 3.87 |
| Seats | 9.30 | 10.20 | 2.65 | 3.36 |

- The sector renderer is faster in every view: by 0.8 to 3.1 ms per frame, or
  7% to 36%. Both fit a 16 ms frame on this machine.
- With flat shading, the BSP takes 0.7 to 1.6 ms more (25% to 50%). Its extra
  work is per pixel: a coverage-buffer test and a ray-plane intersection for
  each polygon pixel, plus clipping and scan-converting each polygon. The
  sector renderer tests a room's sides once per column and fills rows in runs.
- Shading is 60% to 70% of a full frame for either renderer, so the choice of
  visibility method moves the frame by a few milliseconds, not by a factor.
- Work per frame differs in kind. The sector renderer made 1,522 to 14,181
  room visits across 640 columns; the most were on the terrace, where columns
  cross dozens of seating cells. The BSP entered 99 to 690 nodes and
  rasterized 59 to 1,436 polygons.

Start-up costs: linking the level (cutting sides and stacking spans) and the
first frame take 17 ms. Building the BSP takes 5.5 ms more, so the component
builds it only the first time `B` is pressed or a benchmark asks for it.

## Rerun with the thicker outer wall

The outer wall is now 2.5 m thick. Each arch is six small rooms under a
sloped vault, and a walkable parapet runs along its top, which brings the
level to 1,114 rooms. The hypogeum also gained a corridor under the deck and
a passage under the wall tops. [node-v8-run.txt](node-v8-run.txt) and
[node-v8-ms-per-frame.csv](node-v8-ms-per-frame.csv) hold that run, with the
same settings. They replace the first run's files.

The machine was about twice as slow during the rerun, so its absolute times
are not comparable with the table above: 20.7 to 25.1 ms for sectors and
23.5 to 30.0 ms for the BSP. Back to back under the same load, 40 samples
each, the 507-room and 1,114-room builds took the same time per view to
within 2.7 ms, with neither consistently faster. The extra rooms are drawn
only where a column passes through an arch. Start-up is the real cost: the
level build took 71 ms against 44 ms for the old level under the same load,
because linking compares every room's sides with every other room. The BSP
build took 27 ms against 16 ms.

## What the sectors give up

The sector renderer is faster here because the Colosseum suits it: every wall
is vertical, and every floor and ceiling is one plane per room. It cannot draw
a sloped wall, a vault as geometry, or an overhang that is not a stacked room.
Those would need either many small rooms or the polygon renderer. The polygon
BSP draws any convex polygon, but on this scene it pays for that generality on
every pixel.

## Limits of this result

- One scene, one machine, and V8 only. A browser adds the `<qip-play>` upload
  of each frame, which is the same for both renderers.
- The BSP has no potentially visible set. A Quake-style PVS would skip whole
  subtrees behind walls before the coverage test; the hypogeum and ambulatory
  views would gain most.
- Both renderers are single-threaded scalar Wasm without SIMD.

Two compiler findings made a larger difference than the choice of renderer.
Before them, both renderers took roughly 25 to 50 ms per frame in these views:

- In ReleaseSmall, Zig's `@min`, `@max`, and `std.math.clamp` on `f32` compile
  to calls to `fminf` and `fmaxf`, about 15% of frame time. A branch-based
  clamp avoids the calls.
- ReleaseSmall does not inline small helpers such as `toByte`, `putPixel`,
  `frac`, and `hashf`. Marking about 20 of them `inline` cut frame time
  roughly in half, and the module grew from 65 KB to 76 KB.

Rotunda's renderer uses the same patterns and would likely gain from the same
changes.
