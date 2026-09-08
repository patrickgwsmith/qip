# Time And Events

Use this contract when an application needs to call the same Content component
again after its first render. It can tell the component that time has passed,
send keyboard or pointer input, and render the new state. Games, animations,
editors, and other persistent interfaces use this pattern.

This page calls the application code that runs the component the host. The host
controls the clock, collects events, and decides when to display a new render.
The component owns its state and decides what each update does.

The lifecycle has three parts:

```text
initialize as Content -> update state over time -> render committed state
```

Updates and rendering are separate. A hidden component can continue to process
time and events without producing a new frame. A host can also render the same
state again without advancing time.

## Initialize The Component

The first `render(input_size)` call initializes the component and produces its
initial output. Initialization succeeds in one of two ways.

Most components are infallible:

```text
initializing
  `-- uniforms -> render(input_size) --> ready
```

If `render` returns, initialization is complete. A trap means the host broke a
precondition or the component has a defect. The host must discard that
instance.

A component that can reject validly supplied source data exports
`failure_modes_per_input_offset` and uses the normal fallible Content result:

```text
initializing
  |-- uniforms -> render accepts --> ready
  `-- uniforms -> render rejects --> initializing
```

Rejection leaves the component available for another input. Use it for source
errors such as a malformed GIF, not for user events or incorrect call order.
The GIF player validates and indexes its complete source during this first
render, so later timed updates cannot discover an invalid frame.

Initialization occurs once per instance. To reset the component or replace its
source, create a fresh instance and initialize it again. Do not use
`begin_update_at(0)` as a reset; updates require a positive time.

## Update State

A component that uses time exports:

```text
begin_update_at(now_ms: i64)
finish_update() -> i64
```

A component can also export event functions:

```text
key_event(x11_key: i32, flags: i32) -> i32
pointer_event(button_mask: i32, x_px: i32, y_px: i32) -> i32
```

One update has this call order:

```text
begin_update_at(now_ms)
set any update-uniform overrides
send zero or more events
finish_update()
```

Uniform setters must run before the first event. A missing uniform uses its
authored default. `finish_update` restores all update uniforms to those
defaults, so an override does not leak into the next update.

`now_ms` must be positive and greater than the time of the preceding completed
update. These calls are contract violations and trap:

- opening an update while another update is open;
- sending an event when no update is open;
- setting an update uniform after the first event;
- rendering while an update is open; or
- finishing when no update is open.

`finish_update` commits the state directly. It does not reject a correctly
formed update, so the component does not need a rollback copy of its state.

## Schedule The Next Update

`finish_update()` returns an absolute time on the same clock as `now_ms`:

```text
result == now_ms  no scheduled update
result > now_ms   update at or after this time
```

A result before `now_ms` breaks the component contract. The requested time is
advisory: the host may update earlier to deliver an event or later because the
component was hidden or the application was busy.

After initialization, the host performs one update at its first positive time.
This bootstrap update lets the component request its first wake:

```js
component.begin_update_at(1n);
setUpdateUniformOverrides(component);
const nextUpdateAtMS = component.finish_update();
```

An animation returns a future time. A component with nothing scheduled returns
the time it received. A later event can start animation by making
`finish_update` return a future time.

## Process Time Before Events

Work scheduled for time `T` runs before events delivered in an update at `T`.
The event affects work after that boundary. This gives the same ordering on
every host without adding a timestamp parameter to each event function.

Update uniforms can affect time advancement, so a component may wait until its
first event or `finish_update` before advancing:

```text
ensure_advanced():
  use authored defaults plus this update's overrides
  if this update has not advanced:
    advance_to(update_time)
    mark this update advanced
```

Call this operation before applying the first event and again from
`finish_update`. The second call does nothing when the update already advanced.

Give an event its own update when its exact native time changes behavior:

```js
component.begin_update_at(eventTimeMS);
setUpdateUniformOverrides(component);
component.key_event(keysym, flags);
const nextUpdateAtMS = component.finish_update();
```

The host queues events until it can open an update. Event functions do not
queue input themselves.

## Event Semantics

Keyboard input uses X11 keysyms. `flags` is a bit field:

- Bit 0: key down (`1`) or key up (`0`).
- Bit 1: repeat.
- Bit 2: shift.
- Bit 3: control.
- Bit 4: alt.
- Bit 5: meta.

Common keysyms include Left `0xFF51`, Up `0xFF52`, Right `0xFF53`, Down
`0xFF54`, Escape `0xFF1B`, Enter `0xFF0D`, Tab `0xFF09`, and Backspace
`0xFF08`. Pass printable Unicode or ASCII code points directly.

Pointer input follows the Remote Framebuffer button-state model:

- Bit 0 (`1`): primary button.
- Bit 1 (`2`): middle button.
- Bit 2 (`4`): secondary button.

An event returns `1` when it changes the component and `0` when it is ignored.
The host can use this result to avoid an unnecessary render. The result does
not finish or reject the update.

## Render The Current State

Render only after an update has finished:

```text
set any presentation-uniform overrides
output_size = render(0)
```

`render(0)` writes the current state to the output buffer. It does not advance
time or process events. Calling it again with the same state and uniforms
produces the same bytes.

Only `render` changes the output buffer. Update calls leave the previous output
intact. This lets a host update a hidden component without rendering it, or
recreate a discarded copy of the output without changing component state.

Presentation uniforms also use authored defaults. `render` restores those
defaults after each call.

The output can be KTX2, terminal text, HTML, SVG, or any other declared Content
format. [GUI Components](/docs/gui-components) defines the KTX2 and graphical
host contract. [TUI Components](/docs/tui-components) defines the UTF-8, ANSI,
and terminal-host contract.

## Handle Late Updates

A component that uses a fixed timestep keeps its next step boundary, processes
the steps due by `now_ms`, and returns the following boundary. Regular and
irregular host updates then produce the same simulation when they process the
same events at the same times.

A long delay requires an explicit product choice:

- Exact catch-up preserves every simulated step but can monopolize one update.
- Bounded catch-up limits work but skips part of the simulated history.
- Pause and resume suits a game that should not progress while abandoned.
- Fast-forward suits animation when skipped frames do not change the final state.

The component makes this choice because it changes application behavior. Keep
a long-suspension threshold separate from the ordinary catch-up budget, so a
routine frame hitch does not look like a user leaving for several minutes. The
host supplies monotonic time and must not invent steps or rewrite component
state.

This contract works with the fixed-step accumulator described in [Fix Your Timestep](https://www.gafferongames.com/post/fix_your_timestep/),
but it does not require that integration method.

## Examples

- `calculator.zig` updates only when it receives keyboard or pointer events.
- `snake.zig` combines events with scheduled fixed steps.
- `gif-player.zig` schedules frames but exports no event functions.
- `qipdb.zig` renders text instead of pixels.

These components are in `components/interactive/`; the directory name is
historical. GUI and terminal hosts use the same update contract even though
they present different output formats.

## Limits

This contract has no in-place reset, source replacement call, event timestamp
arguments, or universal policy for long suspension. Fresh instantiation resets
or replaces source. A separate update supplies an exact event time. Each
component chooses how to handle late updates.

Do not use Time and Events for a one-shot transform or a view that can be
recomputed from each input. A Content component has a shorter lifecycle and
works in every Content host.
