# Interactive Rendering Performance

Renderer shape matters more than renderer cleverness.

The Cover Flow WebGL2 comparison is useful because it exposes a structure that fast renderers have used for decades: describe the scene as a small set of objects, do object-level setup once, then run specialized kernels over coherent screen regions. The GPU makes that structure obvious, but the same idea improves a QIP Interactive module that writes RGBA pixels in WebAssembly.

## What WebGL2 Teaches

WebGL2 does not render Cover Flow by asking JavaScript to touch every framebuffer pixel for every album. JavaScript builds a compact draw command for each cover: projected quad corners, edge equations, inverse homography, source texture, lighting, alpha, and blend mode. The fragment shader then runs only over the cover's bounding rectangle.

That points to a strong CPU/Wasm default: prepare per-object constants outside the pixel loop, then dispatch to narrow raster kernels. A cover face, a reflection, a shadow, text, and chrome should not all share one flag-heavy function if their hot paths are materially different.

For Cover Flow, this means:

- Album art should already be a texture buffer.
- Each cover should compute geometry and matrix data once.
- Rendering should be clipped to the projected bounds.
- Interior pixels should skip antialiasing coverage work.
- Edge pixels should take the exact AA path.
- Opaque interiors should write packed pixels directly.
- Reflections should use a separate alpha-blend kernel.

The big win from this round came from splitting full-coverage interior batches away from edge batches. The old path computed 4-sample AA coverage for every 4-pixel batch. The new path computes a conservative full-coverage span per row and sends those batches to a full-coverage bilinear kernel.

## What WebGPU Adds

WebGPU makes the pass structure even more explicit: prepare command data, bind the data a pass needs, then run a narrow shader over a coherent region. We can borrow that grain without needing a GPU backend.

For a QIP Interactive renderer, this points to three practical habits:

- Treat rows and spans as dispatch units, not just pixels. The row-binned Cover Flow path now splits edge batches, full interior batches, and edge batches again, so the interior loop does not ask the same coverage question every four pixels.
- Hoist pass constants to the pass or row that owns them. Reflection fade depends on `y`, not on each sampled pixel, so the renderer computes it once per row and skips rows whose reflection alpha is already zero.
- Strength-reduce fragment math only when the value range is pinned. The packed batch path replaces exact `/255`, `/100`, and `/11` channel divides with multiply-and-shift identities over known non-negative ranges.

The caution is just as useful. A vector-looking source change is not automatically faster in Wasm. A batch sampler experiment moved more coordinate setup into vectors, but the generated Wasm added lane extract/replace shuffles and got slower. An affine-specialized path also preserved pixels, but the code size and extra dispatch outweighed the small denominator savings.

## When To Build A GPU Twin

We should not build a WebGL2 or WebGPU version for every QIP GUI component. We should build one when it can teach us the grain of the work faster than staring at the software renderer.

A GPU twin is useful when the component has at least two of these traits:

- Repeated textured or transformed primitives.
- Several blend modes or visual passes.
- A hot path that is hard to reason about from code alone.
- A likely future accelerated backend.
- A performance target tight enough that single-millisecond choices matter.
- A need to compare visual quality against browser-native rendering.

Cover Flow qualified because it had all of them: transformed album quads, reflections, text, chrome, bilinear sampling, AA, lighting, and a frame budget that made the difference between `10 ms` and `6 ms` matter. The WebGL2 port forced the renderer into draw commands, textures, passes, and fragment kernels, then the QIP renderer could borrow that structure without borrowing the GPU.

The GPU version does not need to be a product-quality backend to be useful. A good calibration port should use the same assets, canvas size, transforms, and visual ordering, but it can be temporary. Its job is to answer questions:

- What are the natural draw commands?
- Which constants belong per scene, per object, per row, or per pixel?
- Which pixels are interior pixels and which are edge pixels?
- Which passes blend and which passes overwrite?
- Which work disappears when the GPU clips to primitive bounds?

Once those answers are written down, the software renderer can usually continue without the GPU twin.

## Ranking The Six Patterns

This is the order I would use for QIP Interactive renderers, ranked by likely speed gain and by dependency order.

1. **Treat source art as textures.** This is the foundation. Procedural cover generation inside the draw loop is unrealistic for album art and hides the real bottleneck. Decode or generate once into a known RGBA buffer, then sample that buffer.
2. **Move invariant work out of pixel loops.** Per-object geometry, edge equations, matrices, lighting factors, alpha ranges, and bounds should be computed before the row loop starts. This unlocks every later optimization.
3. **Use bounded work regions.** Draw only the screen-space rectangle that can contain the primitive. This is the CPU version of rasterizing a primitive instead of scanning the whole framebuffer.
4. **Think in spans, tiles, and batches.** Once bounds are tight, find coherent regions inside them. Full-coverage spans let the renderer skip AA work. Four-pixel batches let the compiler use wider operations and reduce loop overhead.
5. **Specialize passes and kernels.** Split opaque cover faces, reflections, shadows, text, and chrome. A single generic function with runtime flags is easy to write, but it blocks the compiler from producing the simplest hot loop.
6. **Exploit opacity and packed stores.** Opaque interiors should use packed writes. Alpha blending should be limited to edges, reflections, shadows, and UI overlays. This is the same practical advice as making Core Animation layers opaque when possible.

The order is not absolute, but the dependencies matter. Packed stores help much more after the renderer can prove a pixel batch is opaque and fully covered. Specialized kernels help more after source art and object constants are already separated.

## Node/V8 Benchmark Process

We prefer the Node benchmark when optimizing `<qip-play>` examples because most users will run the same WebAssembly through V8 in Chrome or Node. `qip bench` is still useful for CLI regressions, but it uses wazero and can give a different performance shape.

Use this process when making a rendering optimization:

1. Build the module with the same Makefile path the page uses:

```sh
make -j components/interactive/dock-magnification.wasm
```

2. Measure the steady initial-frame render with V8:

```sh
node tools/bench-qip-play.mjs components/interactive/dock-magnification.wasm
```

`tools/bench-qip-play.mjs` instantiates the module and performs its initial
Content render. It then warms up the renderer and times only `render(0)`.
Presentation renders do not open updates or advance time. The tool also prints
render size, Wasm byte size, and a SHA-256 of the KTX2 output so two variants
can be checked for byte-identical output.

3. For longer runs, set the warmup and sample count explicitly:

```sh
QIP_PLAY_BENCH_WARMUP=50 QIP_PLAY_BENCH_RUNS=300 \
  node tools/bench-qip-play.mjs components/interactive/dock-magnification.wasm
```

4. For interactive states, write a tiny Node snippet that sends the same exported events the browser sends, warms up the chosen state, and times only `render(0)`. For example, the Dock open/bounce path:

```sh
node -e 'const fs=require("fs");const {performance}=require("perf_hooks");(async()=>{const bytes=fs.readFileSync("components/interactive/dock-magnification.wasm");const {instance}=await WebAssembly.instantiate(bytes,{});const e=instance.exports;e.render(0);e.begin_update_at(1n);e.pointer_event(1,960,655);e.pointer_event(0,960,655);e.finish_update();for(let i=1;i<=20;i++){e.begin_update_at(BigInt(i*16+1));e.finish_update();e.render(0);}const samples=[];for(let i=21;i<=140;i++){e.begin_update_at(BigInt(i*16+1));e.finish_update();const t=performance.now();e.render(0);samples.push(performance.now()-t);}samples.sort((a,b)=>a-b);const mean=samples.reduce((a,b)=>a+b,0)/samples.length;console.log(`open-bounce render mean ${mean.toFixed(3)} ms [min ${samples[0].toFixed(3)}, p50 ${samples[60].toFixed(3)}, p95 ${samples[Math.ceil(samples.length*.95)-1].toFixed(3)}, max ${samples[samples.length-1].toFixed(3)}]`);})();'
```

Run benchmark commands by themselves. Do not run preview generation, tests, or another benchmark in parallel with timing runs; the Node/V8 numbers are sensitive enough that unrelated work can create misleading max and p95 values.

Record before and after numbers in the work log or final response. At minimum, keep mean, p50, p95, wasm byte size, render size, and whether the output hash changed. If the optimization is intended to preserve pixels, compare the SHA-256 before and after.

## A Shared Object Tree

Yes, a common description could render to both QIP Interactive modules and WebGL2, but it should be smaller and more deterministic than Three.js.

The useful abstraction is not a full scene graph with arbitrary user callbacks. It is a compact render IR: a declarative object tree or draw list that can compile to different backends.

A practical first version could include:

- `Texture`: named RGBA8 source data with fixed width, height, and color space.
- `ImageQuad`: four screen points, texture coordinates, sampling mode, coverage mode, opacity, lighting, and blend mode.
- `Rect`, `Line`, `Circle`: simple screen-space primitives for chrome.
- `TextRun`: font asset, text bytes, position, color, and scale.
- `Group`: ordered children with an optional transform or opacity.
- `Pass`: ordered draw commands with explicit blend behavior.

The compiler would lower this IR in two directions:

- **QIP Interactive backend:** generate or interpret specialized Wasm raster kernels that write RGBA8 sRGB bytes.
- **WebGL2 backend:** generate JavaScript setup plus GLSL shaders and texture uploads.

The tradeoff is determinism. A QIP/Wasm raster backend can be byte-exact across hosts if it avoids unspecified behavior and pins its math. WebGL2 can be visually matched very closely, especially with `texelFetch`, manual bilinear sampling, and fixed shader precision, but pixel-exact output across GPUs and drivers is not a contract I would rely on. That suggests treating the QIP backend as the deterministic reference and WebGL2 as an accelerated presentation backend.

## What Changed In Cover Flow

The current high-fidelity Cover Flow renderer now follows this shape more closely:

- Baked album textures are sampled instead of procedural art in the hot path.
- Cover rendering is clipped to each projected quad's bounding rectangle.
- A row-level full-coverage span skips AA coverage for interior batches.
- The row loop is split into edge, full-coverage, and edge spans.
- Full-coverage cover faces use a dedicated bilinear opaque batch kernel.
- Full-coverage reflections use a packed batch blend with shared alpha.
- Reflection fade is computed once per row, and fully transparent reflection rows are skipped.
- Packed color math uses exact multiply-and-shift replacements for hot channel divides.
- Edge batches still use the AA coverage path, keeping output byte-identical.

Measured with the V8-style qip-play benchmark:

- Before: about `10.4-10.6 ms` mean render time for the initial 720x480 frame.
- After the first span/batch pass: about `7.1-7.4 ms` mean render time, with the same frame SHA-256.
- After row-binning, exact divide strength reduction, and reflection row-fade hoisting: about `5.8-6.1 ms` mean render time, still with the same frame SHA-256.
- The Deno helper shows the same direction, though short runs can have more scheduler noise, so p50 is often the better quick-read value.

The important lesson is that the WebGL2 port did not merely show that GPUs are faster. It showed where the CPU renderer was doing edge work for interior pixels, where reflection blending could be batched, and where the code needed to describe separate rendering jobs instead of one broad loop.

## When Not To Use This

Do not start with a scene IR for a tiny component that renders one static bitmap or a simple text transform. The overhead is only worth it when a renderer has repeated primitives, transforms, blend modes, or multiple backends.

Do not build a WebGL2 comparison just because the software renderer is slow. First check whether the slow path is obvious with `qip bench` or the V8 helper. If a module spends most of its time in one loop over a known buffer, a small benchmark clone is usually more useful than a browser GPU port.

For one-off demos, write the direct renderer first. When the same ideas appear twice, promote them into a small IR and compile or interpret that IR deliberately.
