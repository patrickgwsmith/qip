# Browser Elements

QIP provides three general custom elements organized around the user's relationship to a component. Use `<qip-view>` to consume a result, `<qip-edit>` to author inputs, and `<qip-play>` to interact with a running graphical component. `<qip-tui>` hosts a running text-grid component in the browser.

```text
view    consume
edit    author
play    interact
```

These names describe the user experience, not implementation concepts such as rendering, pipelines, transforms, or static generation.

| Element | User relationship | Input or state owner | Lifecycle | Pre-rendering |
|---|---|---|---|---|
| `<qip-view>` | Consume | The page or application | Finite rendering | The complete output can be rendered at build time or on the server; client activation can be optional |
| `<qip-edit>` | Author | User-editable form controls | Reactive finite rendering | The initial output can be pre-rendered, but client activation is required for editing |
| `<qip-play>` | Interact | The running QIP component | Persistent, stateful session | A fallback, poster, or initial snapshot can be pre-rendered, but interaction requires activation |
| `<qip-tui>` | Interact in a text grid | The running QIP component | Persistent, stateful session | An initial text frame can be pre-rendered, but interaction requires activation |

## Choosing An Element

1. Use `<qip-view>` when the user consumes a result whose source is owned by the page or application.
2. Use `<qip-edit>` when the user changes source inputs and QIP reactively updates the outputs.
3. Use `<qip-play>` when the component owns an ongoing stateful session and responds to interaction over time.
4. Use `<qip-tui>` for the same persistent interaction when the component emits TUI text frames and takes keyboard input.

The distinction is the overall user experience, not the presence of a particular form-control attribute:

- A published Markdown document with its source in a hidden input is a view.
- A Markdown authoring interface is an edit.
- An editor temporarily locked by permissions remains an edit: it is still fundamentally an authoring interface.
- A game, simulation, or other persistent GUI component is a play experience.

## `<qip-view>`

`<qip-view>` is the finite, consumption-oriented element. Its standalone module currently duplicates `<qip-edit>`'s wiring, rendering, and module policy. Keeping one entrypoint per element makes loading and replacement predictable; shared implementation can be introduced later without changing the public routes.

The page or application owns the canonical input, and the user consumes the resulting representation rather than editing it. Inputs may be supplied with hidden or read-only controls:

```html
<qip-view>
  <source src="/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
  <input type="hidden" name="input" value="# Rendered ahead of time" />
  <output name="output"><h1>Rendered ahead of time</h1></output>
</qip-view>
```

A view performs a finite rendering operation. Its output may be generated at build time or on the server, and a pre-rendered view stays useful without client-side execution merely to display existing output. The browser may render or rerender the view when the application explicitly asks for it.

## Rendering Times

Finite rendering can observe values from three different eras:

```text
build time → request time → interaction time
```

Here, time is logical: it says which value came after another, not how many
seconds passed. This remains useful when values are synchronized without
requiring clocks to agree.

- **Build time** supplies authored inputs and fallbacks while producing a static page or server template.
- **Request time** applies values available only when a server handles a URL, such as explicitly permitted search parameters.
- **Interaction time** is the current browser state after a person or client-side application changes a control.

Each later era may override a value without destroying the earlier value it
came from. This lets the same markup provide a static fallback, a complete
server-rendered response, and optional client-side enhancement.

| Environment | Initial values | Where QIP runs | What remains possible |
|---|---|---|---|
| Static page without JavaScript | Build-time fallbacks | During the build | The complete fallback result is readable and form submission can navigate normally |
| Server with no JavaScript | Build-time fallbacks plus request-time values | While serving the request | The response contains the complete result; a form can submit another request |
| Static page with JavaScript | Build-time fallbacks, then values connected from the current URL | During the build and locally in the browser | Wasm can rerender after URL or form-control changes without a server renderer |
| Server with JavaScript | Request-time values in the initial response, followed by live control values | On the server initially and locally thereafter | The page works before activation and can rerender without another request after activation |

### Preserving Value Eras

One proposed finite-rendering element is
`<qip-connect-search-params>`. It explicitly connects permitted URL search
parameters to ordinary hidden form controls:

```html
<qip-connect-search-params>
  <input type="hidden" name="language" value="en">
  <input type="hidden" name="currency" value="AUD">
</qip-connect-search-params>
```

A build transform can preserve each authored `value` as
`data-qip-fallback`. A request-time renderer then writes the resolved value to
the normal `value` attribute:

```html
<qip-connect-search-params>
  <input
    type="hidden"
    name="language"
    value="fr"
    data-qip-fallback="en"
  >
</qip-connect-search-params>
```

The three representations have distinct ownership:

| Era | Representation | Meaning |
|---|---|---|
| Build time | `data-qip-fallback` | Authored fallback snapshot retained by the build |
| Request time | The serialized `value` attribute | Value selected for the server-rendered response, or the fallback when no request value exists |
| Interaction time | The live input `value` DOM property | Current browser value, which may differ from the serialized request snapshot |

The browser custom element can restore `data-qip-fallback` when a search
parameter disappears, update the live value when the URL changes, and notify
the enclosing finite renderer. Without JavaScript, the hidden inputs remain
successful form controls and carry the server-selected or fallback values into
the next submission.

This is a proposed API rather than part of the current browser-element
contract. Its server and browser implementations should share fixtures that
verify they select the same parameters and produce byte-identical
`application/x-www-form-urlencoded` input.

## `<qip-edit>`

`<qip-edit>` is the finite, authoring-oriented element. The user authors one or more declared inputs; QIP performs finite renders in response to relevant input changes and writes the result to the declared outputs. Use "edit element" when a noun is needed in prose.

The element is intentionally small: the page provides input controls, Wasm sources, and output views; the runtime wires them together.

```html
<form aria-label="Markdown to HTML">
  <qip-edit>
    <source src="/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
    <source src="/text/html/html-code-syntax-highlight-tsx.wasm" type="application/wasm" />

    <textarea name="input" rows="5" placeholder="Write some Markdown"># A Markdown renderer that works identically cross-platform! Try typing…</textarea>

    <output name="output"><pre><code></code></pre></output>
    <output name="output"><iframe title="Rendered HTML preview" sandbox></iframe></output>
  </qip-edit>
</form>
```

Initial output may be rendered ahead of time, but client activation is still required for the element to respond to later edits. A temporarily read-only authoring experience is still an edit rather than a view.

### Contract

Each edit element needs at least one QIP component, one input, and one output:

```html
<qip-edit>
  <source src="/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
  <textarea name="input"># Hello</textarea>
  <output name="output"><pre><code></code></pre></output>
</qip-edit>
```

The runtime reads from the first child with `name="input"`. It runs each `<source type="application/wasm">` as a pipeline stage in document order. It then writes the same output bytes into every `<output name="output">`.

Multiple outputs are multiple views of one result. They are not multiple return values from the component.

### Output Views

`<output name="output">` is the semantic binding. Its child element declares how the page wants to show the bytes.

```html
<output name="output"><pre><code></code></pre></output>
<output name="output"><iframe title="Rendered HTML preview" sandbox></iframe></output>
<output name="output"><img alt="Generated image preview" /></output>
```

For UTF-8 output, the runtime looks inside each output for `pre > code` or `iframe`.

- `pre > code` receives the decoded output as `textContent`.
- `iframe` receives the decoded output as `srcdoc`. For `text/html` output, the runtime appends a low-specificity default sans-serif body style. Use `sandbox` for rendered HTML.
- Without either child, decoded text is written directly to the `<output>`.

For `image/*` output, an `img` child receives an object URL for the rendered image. This is the right view for SVG, PNG, JPEG, GIF, BMP, ICO, or WebP output. If there is no `img`, SVG and other UTF-8 image formats can still be shown as text with `pre > code`.

Binary output without a matching view falls back to a short hex listing in the `<output>`.

### Binary Input

Text inputs cover UTF-8 transforms; binary payloads have two HTML-native forms.

A `<source name="input">` declares the input. The runtime fetches it, and its `type` attribute becomes the pipeline's initial content type:

```html
<qip-edit>
  <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
  <source src="/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
  <output name="output"><pre><code></code></pre></output>
</qip-edit>
```

Every other `<source>` is a pipeline stage. The naming follows the element's existing `name="output"` and `name="uniform-*"` wiring, and the input can itself be a wasm module — for example, feeding one into `wasm-strict-profile.wasm`:

```html
<qip-edit>
  <source name="input" src="/text/luhn.wasm" type="application/wasm" />
  <source src="/application/wasm/wasm-strict-profile.wasm" type="application/wasm" />
  <output name="output"><pre><code></code></pre></output>
</qip-edit>
```

With an input `<source>` present, a separate input control is optional. `data:` URLs work for inlining small payloads.

An `<input type="file" name="input">` supplies the chosen file's bytes and content type instead. With no file selected it falls back to the input `<source>`, so a page can ship default data that visitors override with their own file:

```html
<qip-edit>
  <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
  <source src="/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
  <input type="file" name="input" accept=".sqlite,application/vnd.sqlite3" />
  <output name="output"><pre><code></code></pre></output>
</qip-edit>
```

Precedence: a chosen file wins, then the input `<source>`, then the input element's text.

### Module Policy

Components use fixed memory by default. Add a byte cap when the page needs a tighter resource boundary:

```html
<qip-edit max-memory="67108864">
  <source src="/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
  <textarea name="input"># Hello</textarea>
  <output name="output"><pre><code></code></pre></output>
</qip-edit>
```

- `max-memory="<bytes>"` rejects a module whose declared memory minimum or maximum exceeds the cap. If a module has memory but no declared maximum, it is rejected.
- A module containing `memory.grow` is always rejected. The `allow-memory-grow` attribute has been removed, and an element that still sets it reports an error.

These checks run after the module bytes are fetched and before `WebAssembly.compile`. `<qip-view>` and `<qip-play>` accept the same attributes.

## `<qip-play>`

`<qip-play>` is the persistent, interaction-oriented element. The component
stays instantiated, keeps its state between events, and user input can change
later output.

```html
<qip-play>
  <source src="/gui/snake.wasm" type="application/wasm" />
</qip-play>
```

The difference from `<qip-edit>` is more than whether a page takes input. An
edit changes declared source inputs and produces finite results. A play session
talks to a running component whose state persists between events. A fallback,
poster, or initial snapshot can be rendered ahead of time, but the session only
becomes interactive once the element runs in the browser.

The element implements the host side of [Time and Events](/docs/time-and-events):
a time-zero `render`, a bootstrap update, then `begin_update_at`, events,
`finish_update`, and a separate `render` when a new frame is needed.
`calculator` follows the application-style path, which renders only after
accepted input. `snake` combines events with fixed-step scheduled wakes. See
[GUI Components](/docs/gui-components) for the component contract and
[Interactive Rendering Performance](/docs/interactive-rendering-performance)
for timing.

### Attributes

| Attribute | Effect |
| --- | --- |
| `canvas-width`, `canvas-height` | CSS size of the presentation surface. Default: the rendered width in CSS pixels, and `auto` height. The `--qip-play-canvas-width` and `--qip-play-canvas-height` custom properties set the same values; attributes take precedence. |
| `svg-width`, `svg-height` | Coordinate space of SVG output, in whole positive numbers. Default 800 by 600. Pointer coordinates are mapped into this space, and inline SVG uses it as the surface's aspect ratio. Ignored for KTX2 output, whose size comes from each frame. |
| `svg-inline` | Present SVG frames in the page DOM instead of through an image. Use only for trusted output; see Output below. |
| `no-text-selection` | With `svg-inline`, turn off text selection so a press on SVG text starts a drag. |
| `touch-action` | CSS `touch-action` for the surface. Default `none`, so touch and pen drags reach the component instead of scrolling the page. |
| `aria-label` | Accessible name of an SVG surface. Default "Interactive SVG editor". |
| `tabindex` | Moved to the surface, which is focusable by default (`0`). |
| `data-pointer-lock` | Request pointer lock on a mouse press; see Pointer Lock below. |
| `max-memory` | Reject modules whose declared memory exceeds the byte cap, as for `<qip-edit>`; see Module Policy above. |
| `debug` | Add frame comparisons and per-step lines to the stats; see Stats And Errors below. |
| `log` | Log initial render time and each update's timings to the console. |

### Children

| Child | Role |
| --- | --- |
| `<source type="application/wasm">` | The component. Normal media selection picks the first matching source. |
| `<qip-step>` | One stage of a post-processing pipeline. Do not mix direct Wasm `<source>` children with `<qip-step>` children. |
| `<source name="input" type="…">` | Initial input fetched from `src`. |
| `<input name="input">` or `<textarea name="input">` | Initial input from the control's text. It stays on the page below the surface. |

Set uniforms with `data-uniform-<name>` attributes on any Wasm `<source>`, for
example `data-uniform-width="1200"`. Names use lowercase letters, digits and
single underscores. The host reads these attributes again before every update
and render, so a script can change one and the next frame uses the new value.

### Output

The first component, or the last step of a pipeline, must declare one of these
output content types:

| Output | Presentation |
| --- | --- |
| `image/ktx2` | A canvas. Accepts canonical RGBA8 sRGB and the repository's RGBA32F linear or transfer-encoded Display P3 [profiles](/docs/formats#qip-ktx2-profiles). |
| `image/svg+xml` | A focusable, non-draggable `<img>` backed by a Blob URL, or inline SVG with `svg-inline`. The module must use `output_utf8_cap`. |
| `multipart/related;type="image/ktx2"` or `type="image/svg+xml"` | The root part only, presented as above. Later parts are skipped unread. The declaration must include a `boundary`. |

Anything else, including `text/plain`, is an error. Use
[`<qip-tui>`](#qip-tui) for text frames.

**KTX2.** When a frame changes size or colour profile, the host replaces the
canvas and its context, because those context settings cannot change. Focus
moves to the new canvas. For linear Display P3 RGBA32F output, the host tries a
float16 linear Display P3 canvas first, then transfer-encoded float16 Display
P3. If the browser offers neither, it tone maps into an 8-bit canvas in Display
P3 or sRGB. The stats line shows the output profile and the canvas profile.

**SVG as an image.** The `<img>` boundary keeps scripts in component output
inert. Each frame gets a new Blob URL, the host revokes the URL it replaced, and
it ignores late load events from replaced frames.

**Inline SVG.** With `svg-inline`, the host parses each frame and swaps the SVG
inside a stable, focusable element with `role="img"`. The output must have an
SVG root element. Focus and pointer capture stay on the wrapper while frames
change, and SVG text can be selected with the mouse unless `no-text-selection`
is set. Inline SVG joins the page DOM, so use it only for trusted output.

### Initial Input

The first component can read input on its first render. Input is set once:
replace the element to load another document.

- A `<source name="input">` is fetched as bytes. Its `type` must exactly match
  the module's declared input content type.
- Otherwise an `<input name="input">` or `<textarea name="input">` supplies its
  text, encoded as UTF-8.
- With neither, the first render gets empty input.

The module must export `input_ptr` and either `input_utf8_cap` or
`input_bytes_cap`. The host prefers `input_utf8_cap` when both exist. Input
longer than the capacity is an error. For example, Moon Phases takes an
optional date string:

```html
<qip-play>
  <source src="/gui/moon-phases.wasm" type="application/wasm" />
  <input type="hidden" name="input" value="2026-05-31" />
</qip-play>
```

### Post-Processing Steps

Wrap sources in ordered `<qip-step>` elements to pass each frame through
finite Content components:

```html
<qip-play debug>
  <qip-step name="desktop">
    <source src="/gui/macintosh-1bit.wasm" type="application/wasm" />
  </qip-step>
  <qip-step name="duotone">
    <source src="/image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm"
            type="application/wasm"
            data-uniform-highlight_r="2.4"
            data-uniform-highlight_g="0.42"
            data-uniform-highlight_b="0.015" />
  </qip-step>
</qip-play>
```

This example maps the light end of the image to HDR orange. Change the three
`highlight` uniforms to pick another linear Display P3 colour without changing
the GUI component.

- The first step must implement Interactive. It alone receives pointer and
  keyboard events and updates.
- Later steps must implement finite Content and must not export Timed or
  Eventful functions. Each step's input type must match the previous step's
  output type, and the last step's output must be one of the
  output types listed under Output above.
- The host copies each result into the next component's input memory and
  presents only the last result. Timed post-processing is not supported yet.

The first step selects its first matching `<source>` through normal media
selection. A later step treats its matching sources as ordered alternatives. On
the first frame, `<qip-play>` calls each one until one accepts the input, then
keeps that instance for later frames and releases the others so their memory
can be collected. A recoverable rejection tries the next source. A trap stops
the pipeline, because that instance is no longer safe to reuse.

Every alternative in one step must declare the same non-empty input and output
content types. The host loads and validates every alternative before it
starts, and all of their Wasm counts toward the step's size in the stats. For
example, a resize step can choose its direction without putting image-size
policy in JavaScript:

```html
<qip-step name="resize">
  <source src="/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm"
          type="application/wasm"
          data-uniform-width="1200" />
  <source src="/image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell.wasm"
          type="application/wasm"
          data-uniform-width="1200" />
</qip-step>
```

Both components declare `image/ktx2 -> image/ktx2`. The reduction component
accepts when 1200 pixels does not enlarge an axis. Otherwise it returns a
recoverable rejection and the Mitchell component gets the same input.

Pointer coordinates are measured in the presented image, which is the last
step's output. A step that changes the image size therefore also changes the
coordinates the first component receives. The host does not map them back yet,
so put size-changing steps only after components that ignore pointer input.

### Input Events

The host listens on the presentation surface only when the component exports
`key_event` or `pointer_event`, or uses pointer lock. Events are queued with
their time and delivered in order inside the next update. A frame is rendered
only when an event returns nonzero, a wake is due, or the view needs
refreshing.

**Pointer.** Coordinates are integer pixels in the rendered image, scaled from
the surface's displayed box and clamped to its edges. A high-resolution frame
can therefore be shown at a smaller CSS size. The DOM's primary, auxiliary and
secondary buttons become QIP button mask bits 1, 2 and 4. A press focuses the
surface and captures the pointer for the drag. Leaving the surface sends mask
0 at `(-1, -1)`. When the component also takes keys, Shift and Alt changes seen
on pointer events are sent as key events first, so a modifier pressed while
the surface was unfocused still applies to the click.

**Keyboard.** Keys become X11 keysyms. While Meta is held, only arrows,
Backspace, Delete, Home, End and A, C, V, X, Z and T reach the component, and
Meta with Ctrl never does, so other browser shortcuts keep working. The host
ignores browser key repeats and generates its own: the first repeat after
250 ms, then every 33 ms, flagged as a repeat.

**Context menu.** A right-click delivers the press immediately. The browser's
menu is suppressed only if `pointer_event` accepted that press.

**Focus loss.** On blur, the host sends key-up events for held keys and a
zero-mask pointer event, so a game stops moving and a drag ends.

### Pointer Lock And Total Movement

Add `data-pointer-lock` to let a first-person or other mouse-look component
turn without the cursor stopping at the canvas edge:

```html
<qip-play data-pointer-lock>
  <source src="/gui/rotunda.wasm" type="application/wasm" />
</qip-play>
```

A mouse press on the surface then asks the browser for
[pointer lock](https://developer.mozilla.org/en-US/docs/Web/API/Pointer_Lock_API);
Esc releases it, and the next press asks again. The press is still delivered to
`pointer_event`. While the lock is held, `<qip-play>` adds each
`pointermove`'s `movementX` and `movementY` to two running totals and passes
them, rounded to whole CSS pixels, through optional uniforms:

| Export | Value |
| --- | --- |
| `uniform_set_pointer_total_movement_x` | Total rightward movement since the element started |
| `uniform_set_pointer_total_movement_y` | Total downward movement since the element started |

Totals, not per-event deltas, are passed because the host reapplies uniforms
before each update and each render. The component remembers the last totals it
saw and moves by the difference, so a repeated value moves nothing. Locked
motion schedules an update and a render, like an accepted event. Pointer
coordinates in `pointer_event` stay where the cursor was locked, and
`setPointerCapture` is skipped while locked. Pages without the attribute, touch
and pen input, and components without these exports are unaffected; the
totals stay at 0.

### Scheduling And Visibility

The host schedules work with `requestAnimationFrame` when something is ready
and a timer for the next wake or queued event. While the element is outside
the viewport, it suspends scheduled wakes and rendering but keeps the
component's next wake deadline. When the element comes back, the host runs one
late update at the current time, renders the current state, and schedules the
next returned wake, so component time keeps passing while execution is paused.
Queued user input can still open an offscreen update, but it does not render.
A hidden tab skips rendering in the same way and renders again when the tab
becomes visible. Browsers without `IntersectionObserver` keep the component
running.

Removing the element from the page stops scheduling, drops queued input,
removes its listeners and releases pointer lock.

### Stats And Errors

A stats line below the surface always shows the total Wasm size, the memory of
every loaded instance, and the latest update and render counts and times. KTX2
output also shows the output and canvas profiles. The first render counts as
render 1 for both KTX2 and SVG output.

With `debug`, the line also counts renders whose pixels match the previous
frame and the time spent comparing them. The comparison scans the whole
frame, so leave `debug` off in normal use. A pipeline with more than one step
also gets one line per step with its Wasm size, memory, render count and time,
and the selected source.

If loading, validation or a render fails, the element replaces its contents
with a `<pre role="alert">` that starts with "Play error:".

## `<qip-tui>`

`<qip-tui>` hosts a keyboard-driven TUI component in a resizable browser text
grid. It starts at its parent width, and users can
drag its bottom-right corner to reduce its width or change its height. The host
measures the monospace cell size and supplies `columns` and `lines` uniforms
when the component exports them. A resize renders the retained state again; it
does not instantiate the component again.

```html
<qip-tui aria-label="Calendar" height="28rem">
  <source src="/tui/calendar-gregorian.wasm" type="application/wasm" />
</qip-tui>
```

Use `<qip-step>` wrappers when a finite Content component must transform each
frame. The first step owns the TUI state and keyboard events; later steps
accept and emit exact content types. The final step must emit `text/plain`.
The browser retains the first post-processing alternative that accepts the
initial frame, as `<qip-play>` does.

An eventful component exports `key_event`, the Time and Events functions, and
UTF-8 output. A plain-text Content component can instead declare UTF-8
`text/plain` input and omit all event and update exports. The host then shows
an HTML text input above its output. Each edit supplies the complete input to
`render`, including a zero-byte render when the field is empty. A component
with `uniform_set_active_index` and `active_count` also gets Up/Down result
navigation. Text edits reset the active index; resize preserves it. See
[TUI components](/docs/tui-components#host-managed-text-input) for the complete
text input and navigation rules.

Both models can declare `text/plain` as their output content type. The host
validates the terminal's narrow ANSI SGR
profile through `ansi-sgr-to-html.wasm` before presenting the frame. It accepts
at most 256 KiB of frame text. Its `load({moduleBytes, inputBytes})` method also
lets an application provide bytes it has already fetched. The
[component debugger](/component-debugger) uses this path for local files.

The browser host makes absolute `http://` and `https://` URLs in rendered text
clickable. It opens a link in a new tab only after the user activates it, without
sending the page referrer. Press `Ctrl-Enter` while the grid is focused to focus
its first link; Tab then moves between links, and Escape returns to the grid.
The host does not fetch URLs found in frames. It does not accept terminal OSC 8
hyperlink sequences.

Use `<qip-play>` for KTX2 or SVG frames, pointer coordinates, or image-specific
canvas behavior. Use ordinary HTML when the interface needs controls beyond the supported text
field or semantic document navigation.

## Pre-Rendering

Prefer the terms pre-rendered, build-time rendered, or server-rendered over calling the consumption element "static".

A view is not necessarily unchanging: application code may explicitly rerender it when externally owned data changes. Likewise, an edit may begin with pre-rendered output even though it later becomes reactive. The distinction stays:

```text
view    consume a finite result
edit    author inputs and produce finite results
play    interact with a persistent session
```

— not static versus dynamic.

## Externally Managed Data

`<qip-view>` is not intended to own application data loading. Authentication, network requests, caching, retries, and invalidation belong in application code or a developer-defined custom element, which can invoke QIP's rendering functions and control when a component is loaded or rerendered:

```html
<account-usage-report account="123"></account-usage-report>
```

A custom element such as `<account-usage-report>` can own authenticated fetching and caching while using QIP internally for deterministic rendering.

## Related Documentation

- [Component Contracts](/docs/component-contract) — the component types and their execution models.
- [Content Component Contract](/docs/content-component) — the exports, inputs, outputs, and content-type composition used by finite renderers.
- [Hard Limits](/docs/hard-limits) — the memory, time, and host-access budget components run within.
- [Architecture And Boundaries](/docs/architecture-boundaries) — where trust boundaries sit between host, component, and page.
- [GUI Components](/docs/gui-components) — the composed contract behind `<qip-play>`.
- [Form ABI](/docs/form_abi) — prompt-driven form components, a separate element family.
