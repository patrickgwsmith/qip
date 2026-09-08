# TUI Components

A TUI component renders retained state as UTF-8 text for a terminal host. The
contract combines Content presentation, the
[Time and Events](/docs/time-and-events) capability, a required keyboard event
function, and an optional narrow ANSI SGR profile. `qipx tui` implements this
composition.

The host owns terminal mode, screen redraws, timing, and key decoding. The
component produces complete text frames and cannot issue general terminal
commands. A frame may be plain text or use the supported SGR styles.

Run the calendar with no input or options:

```sh
qipx tui components/interactive/calendar-gregorian.wasm
```

Press Up for the previous month and Down for the next month. Press `Ctrl-C` to
exit. `qipx` retains one instance of the component, calls its initial Content
render, delivers key events through Time and Events updates, renders accepted
changes, and honors later wake times returned by `finish_update`.

## Contract Composition

The first component implements Content with UTF-8 output and exports:

```text
begin_update_at(now_ms: i64)
key_event(x11_key: i32, flags: i32) -> i32
finish_update() -> i64
```

It can also export uniforms such as `uniform_set_columns`,
`uniform_set_lines`, or an authored option that enables ANSI SGR. The host
validates every completed frame before writing it to the terminal.

## Input And Components

Use `-i path` for one initial byte input. Use repeatable `-F` or `--form`
arguments to construct `multipart/form-data`. Terminal stdin carries key events,
so `-i -` and `-F name=@-` are not available in TUI mode.

For example, the component debugger needs a Wasm component and its input:

```sh
qipx tui \
  -F component=@components/text/wc.wasm \
  -F 'input=The quick brown fox jumps over the lazy dog' \
  components/interactive/qipdb.wasm
```

Component hosts can precede the command and provide missing components:

```sh
qipx qip.dev tui \
  -F component=@components/text/wc.wasm \
  interactive/qipdb.wasm
```

The first stage must implement the TUI contract. Later stages must be ordinary
Content components. They transform every rendered frame from left to right:

```sh
qipx tui \
  -F component=@components/text/wc.wasm \
  components/interactive/qipdb.wasm \
  components/text/strip-ansi-sgr.wasm
```

The final stage must produce UTF-8. Tile and Timed stages are not valid after
the first stage because the TUI host needs one finite text result for each
presentation.

Place `-u name=value` after the stage that receives it. If a stage exports
`uniform_set_columns` or `uniform_set_lines`, the host supplies the current
terminal width and height. An explicit `-u columns=...` or `-u lines=...`
value takes precedence. A resize updates the automatic values and redraws.

## Keyboard Mapping

The host decodes traditional terminal input into the X11 keysyms and modifier
flags defined by [Time and Events](/docs/time-and-events#event-semantics). It
supports printable UTF-8, Tab, Backspace, Enter, Escape, arrows, Home, End,
Insert, Delete, Page Up, Page Down, F1 through F12, and common Shift, Control,
and Alt variants.

Each terminal key press becomes a key-down event followed immediately by its
key-up event in the same QIP update. Terminals do not normally report separate
press and release events, so a component must not depend on a key remaining
held between terminal updates.

The host reserves these terminal controls:

- `Ctrl-C` exits and restores the terminal.
- `Ctrl-Z` restores and suspends the process on Unix, then redraws after resume.
- `Ctrl-S` and `Ctrl-Q` are ignored so software flow-control bytes cannot reach
  the component.

Escape-prefixed input is ambiguous: for example, `Alt-[` begins with the same
bytes as an arrow key. The host waits 30 ms for the rest of a known sequence,
then treats an incomplete `Escape` prefix as an Alt key chord.

## Terminal Safety Boundary

The component does not control the cursor. On each presentation, the host moves
to the top-left, clears the previous frame, writes the validated new frame,
resets text styling, and clears the remaining screen. It uses the alternate
screen and restores the previous screen and input mode on exit.

A rendered frame can contain:

- valid UTF-8 printable text;
- line feed (`LF`);
- SGR reset, bold, dim, underline, standard 8-color foreground/background, and
  their bright variants.

The host rejects carriage return, Tab, Backspace, DEL, C1 controls, indexed or
true-color SGR, and every non-SGR escape sequence. This includes cursor
movement, OSC window-title and clipboard commands, DCS device commands, and
terminal queries. Post-processing components run before this check, so the
bytes written to the terminal always pass the same validation.

This boundary is narrower than a general terminal emulator. Use a native TUI
library or a browser host when an interface needs cursor placement, mouse input,
independent key-up events, terminal queries, or arbitrary color control.
