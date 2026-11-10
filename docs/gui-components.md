# GUI Components

A GUI component renders graphical state as KTX2 Content. KTX2 is an image
container commonly used to send texture data to GPUs. QIP uses a small,
uncompressed set of [KTX2 profiles](/docs/formats#qip-ktx2-profiles), so pixels
are directly addressable in WebAssembly memory while the file still records
its dimensions, pixel layout, orientation, and colour information. The
profiles support ordinary 8-bit sRGB and 32-bit floating-point (`f32`) RGBA for
linear-light and wide-colour Display P3 rendering.

A persistent GUI combines three small contracts: Content owns initialization
and presentation, [Time and Events](/docs/time-and-events) owns state updates
and input, and the KTX2 profile gives the browser host a predictable pixel
buffer to display.

Most applications and games in `gui/` use this composition. It is also
suitable for animation without user input. The GIF player accepts `image/gif`
as fallible Content, adds time to select later frames, and omits event exports
because playback needs no input.

Use the [Content Component Contract](/docs/content-component) alone when each
render is a finite input-to-output operation and no state must survive. A
Time and Events component can also return SVG. `<qip-play>` presents that SVG,
but it does not make the component a KTX2 GUI component.

## Contract Composition

Every GUI component implements Content and declares `image/ktx2` output.
Repository components normally use canonical `ktx2-r8g8b8a8-srgb` data.
`<qip-play>` also accepts the repository's narrow linear and transfer-encoded
Display P3 RGBA32F profiles.

A GUI that retains state or changes over time also exports:

```text
begin_update_at(now_ms: i64)
finish_update() -> i64
```

Add only the input functions the GUI needs. The common functions are:

```text
key_event(x11_key: i32, flags: i32) -> i32
pointer_event(button_mask: i32, x_px: i32, y_px: i32) -> i32
```

Time does not imply input: a component can export the two update functions and
no event function. A component with keyboard or pointer input uses the complete
Time and Events lifecycle.

## Update And Presentation

Initialize and present the component as Content at time zero:

```text
set any presentation-uniform overrides
render(input_size)
```

Open each later update with a positive, strictly increasing time:

```text
begin_update_at(now_ms)
set any update-uniform overrides
send zero or more events
next_wake_at_ms = finish_update()
```

Scheduled work due at `now_ms` runs before events in that update. Event
functions called outside an update trap. Rendering while an update is open
also traps. These failures identify a host or component defect; they are not
correctable user input.

`finish_update()` returns an absolute time:

- A value equal to `now_ms` requests no wake.
- A value greater than `now_ms` requests an update at or after that time.

The wake is advisory. A host can update earlier to deliver an event or later
after a background-tab pause. The component decides whether to replay fixed
steps, cap catch-up work, or fast-forward its own state.

Updates do not publish output. Only `render` may change the output buffer. A
host can therefore process events while hidden, keep reading the last rendered
bytes, and render the latest state when presentation is needed.

An omitted uniform uses its authored default. `finish_update` resets update
uniforms. `render` resets presentation uniforms, so an override never leaks
into a later execution.

See [Time and Events](/docs/time-and-events) for the complete state machines,
fixed-timestep choices, initialization failure, and uniform ordering. Those
rules are independent of KTX2 and browser presentation.

## GUI Input

[Time and Events](/docs/time-and-events#event-semantics) defines keysyms,
modifier flags, pointer button masks, and event return values. The GUI host
maps browser input to those values.

Coordinates are integer pixels in the current rendered presentation. When the
pointer leaves the surface, send a zero button mask and coordinates `-1, -1`
inside an update.

A host which loses keyboard or pointer focus must release input that it
previously reported as held. Queue key-up events for held keys and a zero-mask
pointer event before the next update. Otherwise a game can continue moving or
dragging after its view loses focus.

For pointer-heavy interfaces, compare semantic targets instead of raw movement.
For example, two coordinates inside the same unchanged button can produce one
accepted entry event followed by ignored moves.

## Browser Host Loop

A browser host owns event queues and presentation policy. A typical visible
loop for a stateful GUI is:

1. Call `render(input_size)` once to initialize and present time zero.
2. Perform a bootstrap update at the first positive time to discover a wake.
3. Queue native events until the host can open an update.
4. Open an update at the chosen event or wake time, set all update uniforms,
   deliver the queued events, and call `finish_update()`.
5. If a new presentation is needed, set all presentation uniforms and call
   `render(0)`.
6. Schedule the next host callback from the returned wake and pending events.

Give an event its own update when its exact native timestamp affects behavior,
such as double-click recognition. Several events can share one update when
coalescing them to one time is correct for that interface.

## Browser Presentation

`<qip-play>` is the browser host for this contract. Its
[reference](/docs/qip-elements#qip-play) lists the attributes, output types,
input mapping and scheduling rules. The points below matter when you write a
component for it.

- **Output.** A KTX2 frame is drawn to a canvas. A Time and Events component
  can return `image/svg+xml` instead; it is shown as an image unless the page
  opts into trusted inline SVG with `svg-inline`. Either can be the root of a
  `multipart/related` output.
- **Coordinates.** Pointer coordinates are integer pixels in the rendered
  frame, scaled from the displayed size. A component can render at high
  resolution while the page shows it smaller. SVG output has no pixel size, so
  the page sets its coordinate space with `svg-width` and `svg-height`
  (default 800 by 600).
- **Initial input.** A component that exports `input_ptr` and either
  `input_utf8_cap` or `input_bytes_cap` receives a page's initial input on its
  first render. Input is not resent later; to load another document, replace
  the component instance.
- **Offscreen and hidden pages.** The host suspends wakes and rendering while
  the element is offscreen and delivers one late update when it returns. Rely
  on the wake being advisory, as described in
  [Update And Presentation](#update-and-presentation).
- **Size and colour changes.** A frame may change its dimensions or KTX2
  profile; the host replaces its canvas to match.
- **SVG overlays.** An editor owns any SVG elements that it adds for
  presentation. The SVG path editor uses one
  `g[data-qip-editor-overlay="true"]`, removes an existing marked overlay
  during initialization, and writes one current overlay on render.

See [Testing GUI Components](/docs/testing-gui-components) for direct Wasm,
host-loop, output, and browser tests.

## When Not To Use This Contract

Use ordinary Content for a finite image render, HTML document, or non-interactive SVG. Use the
[TUI component contract](/docs/tui-components) when the presentation is a text
grid and the host is a terminal. Use application-native UI when the interface
needs platform controls, accessibility semantics, text input services, or
layout behavior that a pixel surface would have to reproduce.
