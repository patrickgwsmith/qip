# Browser Elements

QIP provides three custom elements organized around the user's relationship to a component. Use `<qip-view>` to consume a result, `<qip-edit>` to author inputs, and `<qip-play>` to interact with a running component.

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

## Choosing An Element

1. Use `<qip-view>` when the user consumes a result whose source is owned by the page or application.
2. Use `<qip-edit>` when the user changes source inputs and QIP reactively updates the outputs.
3. Use `<qip-play>` when the component owns an ongoing stateful session and responds to interaction over time.

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
- `allow-memory-grow` permits `memory.grow` and requires `max-memory` on the same element.

These checks run after the module bytes are fetched and before `WebAssembly.compile`. `<qip-view>` and `<qip-play>` accept the same attributes.

## `<qip-play>`

`<qip-play>` is the persistent, interaction-oriented element. The component remains instantiated over time, owns or participates in an evolving stateful session, and user events can affect subsequent output.

```html
<qip-play>
  <source src="/interactive/snake.wasm" type="application/wasm" />
</qip-play>
```

A direct `<source>` is shorthand for one interactive step. Use ordered
`<qip-step>` wrappers to pass each rendered frame through finite Content
post-processing components:

```html
<qip-play debug>
  <qip-step name="desktop">
    <source src="/interactive/macintosh-1bit.wasm" type="application/wasm" />
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
`highlight` uniforms to author another linear Display P3 color without changing
the GUI component.

The first step must implement Interactive. Later steps must implement finite
Content, accept and emit `image/ktx2`, and must not export Timed or Eventful
capabilities. `<qip-play>` sends pointer and keyboard events only to the first
step. It copies each KTX2 result into the next component's bounded input memory
and presents only the last result. Timed post-processing is not supported yet.

The first step selects its first matching `<source>` child through normal media
selection. A later step treats matching sources as ordered executable
alternatives. On the first frame, `<qip-play>` calls each candidate until one
accepts the input with a successful Content result. It retains that component
instance for later frames. A recoverable rejection tries the next source; a
trap stops the pipeline because the component instance is no longer safe to
reuse.

Every alternative in one step must declare identical, non-empty input and
output content types. The input type must also match the preceding step's
declared output type. The host loads and validates every candidate before it
starts. All downloaded Wasm counts toward the step's byte total. After a source
accepts the first frame, the host releases its references to the unselected
instances so their fixed memories can be collected. For example, a resize step
can choose its direction without putting image-size policy in JavaScript:

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
recoverable rejection and the Mitchell component gets the same input. Do not
mix direct `<source>` children and `<qip-step>` children. With `debug`, the
statistics include all alternatives' Wasm size, retained memory, the selected
source, latest render time, and render count for each named step.

The distinction from `<qip-edit>` is not merely that both accept interaction. Editing changes declared source inputs and produces finite results; playing interacts with a running component whose state persists between events. A fallback, poster, or initial snapshot may be rendered ahead of time, but the experience requires client activation to become interactive.

The element supports [Time and Events](/docs/time-and-events):
`begin_update_at`, complete
update uniforms, timestamp-free events, `finish_update`, separate
presentation, and canonical KTX2 output. `calculator` uses the
application-style path. `snake` combines events with fixed-step scheduled
wakes. See also [GUI Components](/docs/gui-components) and
[Interactive Rendering Performance](/docs/interactive-rendering-performance).

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
