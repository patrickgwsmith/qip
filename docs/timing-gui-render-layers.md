# Timing GUI Render Layers

A whole-frame benchmark tells you that a GUI component is slow, but not where
the time goes. To decide what to simplify, time each drawing pass on its own:
the dial, the bezel, the hand, the glass and so on.

A shipped component cannot do this. It has no clock and no imports: time
reaches it only through `begin_update_at` and uniforms, and
[`wasm-strict-profile`](/docs/hard-limits) rejects any import. So build a
separate timed copy for measurement only, and keep the shipped artifact
unchanged.

## Swap In A Timer Module

Give the component a small `layer_timer` module and choose its implementation
at build time. The normal build gets empty functions. The timed build imports a
clock from the benchmark host. Neither file exists in the repository yet; the
paths below are examples.

`gui/lib/layer-timer-off.zig`, used by the shipped build:

```zig
pub const Layer = enum { dial, bezel, hand, glass };
pub inline fn begin() f64 {
    return 0;
}
pub inline fn end(comptime layer: Layer, start: f64) void {
    _ = layer;
    _ = start;
}
```

`gui/lib/layer-timer-on.zig`, used only for measurement:

```zig
extern "qip_bench" fn now_ms() f64;
pub const Layer = enum { dial, bezel, hand, glass };
pub var totals_ms = [_]f64{0} ** @typeInfo(Layer).@"enum".fields.len;
pub inline fn begin() f64 {
    return now_ms();
}
pub inline fn end(comptime layer: Layer, start: f64) void {
    totals_ms[@intFromEnum(layer)] += now_ms() - start;
}
export fn layer_times_ptr() u32 {
    return @intCast(@intFromPtr(&totals_ms));
}
export fn layer_times_len() u32 {
    return totals_ms.len;
}
```

Wrap each pass in the component:

```zig
const layer_timer = @import("layer_timer");

const t = layer_timer.begin();
drawDialSurface();
layer_timer.end(.dial, t);
```

Build the timed copy with the same command as the `Makefile` rule, adding the
`layer_timer` module. Only the `-Mlayer_timer=` path differs from the shipped
build:

```sh
zig build-exe -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry \
  -rdynamic -mcpu=generic+simd128 --max-memory=67108864 \
  --dep ktx2_rgba8_srgb --dep ktx2_rgba32float_display_p3_linear \
  --dep layer_timer \
  -Mroot=gui/chronograph.zig \
  -Mktx2_rgba8_srgb=image/lib/ktx2-rgba8-srgb.zig \
  -Mktx2_rgba32float_display_p3_linear=image/lib/ktx2-rgba32float-display-p3-linear.zig \
  -Mlayer_timer=gui/lib/layer-timer-on.zig \
  -femit-bin=/tmp/chronograph-timed.wasm
```

With the off module, the calls inline away. The shipped `.wasm` still has no
imports and no extra exports. Check both builds:

```sh
node -e 'for (const f of process.argv.slice(1)) console.log(f, WebAssembly.Module.imports(new WebAssembly.Module(require("fs").readFileSync(f))))' \
  gui/chronograph.wasm /tmp/chronograph-timed.wasm
```

The shipped build should list `[]`. The timed build should list only
`qip_bench.now_ms`.

Use the same optimization flags as the shipped build. Timing a `ReleaseSmall`
copy of a component that ships as `ReleaseFast` with SIMD measures the wrong
code.

## Drive It From Node

The benchmark host supplies the clock, puts the component into the state you
care about, then reads the totals straight from linear memory:

```js
import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync("/tmp/chronograph-timed.wasm"));
const { exports: e } = new WebAssembly.Instance(module, {
  qip_bench: { now_ms: () => performance.now() },
});

e.render(0);
// Tilt the watch with the same events the browser sends.
e.begin_update_at(1n);
e.pointer_event(1, 360, 360);
e.pointer_event(1, 460, 360);
e.pointer_event(0, 460, 360);
e.finish_update();

for (let i = 0; i < 10; i++) e.render(0); // warm up
const totals = () => new Float64Array(e.memory.buffer, e.layer_times_ptr(), e.layer_times_len());
totals().fill(0);

const frames = 60;
let frameMs = 0;
for (let i = 0; i < frames; i++) {
  const t = performance.now();
  e.render(0);
  frameMs += performance.now() - t;
}
console.log("frame", (frameMs / frames).toFixed(2), "ms");
totals().forEach((ms, i) => console.log(i, (ms / frames).toFixed(2), "ms"));
```

Create the `Float64Array` view again after rendering. A view made earlier stays
valid only while the memory doesn't grow, and making a new one is cheap.

Measure each state the user actually sees. For the chronograph that means a
face-on first frame, the cached face-on tick, several tilts in both directions,
and HDR output. Caches and tilt-dependent passes change which layers run at all.

## Count Work, Not Just Time

Time shows which layer is expensive. A per-layer count of pixel blends shows
why. Increment a counter in the innermost blend function and attribute it to
the current layer in the same way. A layer with many blends but almost no
visible pixels is drawing something that a later layer covers up.

That is how the chronograph's case top turned out to be wasted work: it was
shaded across its full radius, then the bezel covered almost all of it.

## Example: The Chronograph

Per-layer timing of `gui/chronograph.wasm` at 720×720, 0.35 rad tilt, SDR,
averaged over 60 frames in Node:

| Layer | Before | After |
|---|---|---|
| Blue dial (hobnail, snailing, sheen) | 8.4 ms | 8.2 ms |
| Bezel top ring | 3.7 ms | 3.7 ms |
| Case top ring | 4.6 ms | 1.5 ms |
| Hand | 3.6 ms | 0.9 ms |
| Glass reflection | 3.0 ms | 3.0 ms |
| Case bands | 4.0 ms | 2.3 ms |
| Chapter rings | 1.3 ms | 0.3 ms |

The dial was kept as it was. The other savings came from three changes:

- drawing only the visible rim of the case top;
- limiting the hand and baton rows to their rotated rectangle, not the bounding
  box;
- skipping the hollow centre of tilted rings.

All three changes kept every frame pixel-identical, which was checked by
comparing hashes over a sweep of tilts and hand positions.

## Keep It Honest

- Timer calls cost something. Wrap whole passes, not individual pixels. The
  per-layer totals should add up to roughly the full frame time; if they come to
  much more, the probes are too fine-grained.
- Run timing on its own, with nothing else running, as described in
  [Benchmarking Components](/docs/benchmarking-components#keep-timing-runs-quiet).
- Whenever a change is meant to keep pixels unchanged, compare output hashes
  between the shipped builds before and after. Do this outside the timed copy.
- Don't add timing assertions to `node --test`. Keep per-layer timing as a
  benchmark you run when you need it.
