# Cover Flow WebGL2

The same Cover Flow scene as the [Wasm renderer](/play-cover-flow), drawn through WebGL2: covers in tight ~70° side stacks on a black stage, mirrored floor reflections, bilinear album sampling, antialiased edges, side-cover shading, and spring easing. It renders at the same 1440x960 and is displayed at 720x480. Text is set in Inter Display by the browser, with kerning.

Controls:

- Drag left/right: move through albums with inertia
- Tap an album: select it
- Scroll bar: drag the thumb to scrub through albums, or press the track to jump there
- Keyboard: `Left/Right` or `A/D`, `Home`/`End`
- Feature toggles: `L` lighting, `S` spring easing

<script type="module" src="/cover-flow-webgl2.js"></script>

<cover-flow-webgl2></cover-flow-webgl2>
