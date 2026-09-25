# TUI Components

A TUI component renders retained state as UTF-8 text for a terminal host. The
contract combines Content presentation, the
[Time and Events](/docs/time-and-events) capability, a required keyboard event
function, and an optional narrow ANSI SGR profile. `npx qiptui` runs this
contract in a terminal.

The host owns terminal mode, screen redraws, timing, and key decoding. The
component produces complete text frames and cannot issue general terminal
commands. A frame may be plain text or use the supported SGR styles.

In a browser, `<qip-tui>` presents the same frames in a focusable, resizable
grid. It measures available width and height and supplies `uniform_set_columns`
and `uniform_set_lines` when present. Resizing redraws retained state. The
[browser element guide](/docs/qip-elements#qip-tui) shows markup and limits.
The browser host turns absolute HTTP and HTTPS URLs in displayed text into links;
opening one takes an explicit user action. This does not change the component's
plain-text frame contract or allow OSC 8 escape sequences.

Run the hosted calendar without input:

```sh
npx qiptui qip.dev tui/calendar-gregorian.wasm
```

Press Up for the previous month and Down for the next month. Press `Ctrl-C` to
exit. `qiptui` retains one instance of the component, calls its initial Content
render, delivers key events through Time and Events updates, renders accepted
changes, and honors later wake times returned by `finish_update`.

## Contract Composition

The TUI component implements Content with UTF-8 output and exports:

```text
begin_update_at(now_ms: i64)
key_event(x11_key: i32, flags: i32) -> i32
finish_update() -> i64
```

It can also export uniforms such as `uniform_set_columns`,
`uniform_set_lines`, or an authored option that enables ANSI SGR. The host
validates every completed frame before writing it to the terminal.

## Input And Component Files

Use `-i path` for one initial byte input. Use repeatable `-F` or `--form`
arguments to construct `multipart/form-data`; `-i` and `-F` cannot be combined.
Use `-F name=@path` to include a file with its filename, or quote
`-F 'name=<path'` to include the same bytes without a filename. Use `-i -`,
`-F name=@-`, or `-F 'name=<-'` to read piped stdin once. In this case, qiptui
reads keys from the terminal on stderr. Keep stderr attached to a terminal.

For example, the component debugger needs a Wasm component and its input:

```sh
npx qiptui \
  -F component=@text/wc.wasm \
  -F 'input=The quick brown fox jumps over the lazy dog' \
  ./tui/qipdb.wasm
```

A leading host applies to both the TUI and `.wasm` form fields:

```sh
npx qiptui qip.dev \
  -F component=@text/wc.wasm \
  tui/qipdb.wasm
```

To read a piped EPUB with the text reader:

```sh
cat book.epub | npx qiptui qip.dev -i - tui/epub-reader.wasm
```

To inspect an Apple property list, pass the file bytes to the plist viewer:

```sh
npx qiptui -i Settings.plist ./tui/plist-viewer.wasm
```

For an app's `Info.plist`, use the schema-aware viewer:

```sh
npx qiptui -i Info.plist ./tui/info-plist-viewer.wasm
```

It shows readable names in the tree and the selected raw key and expected type
below it. It recognizes nested dictionaries and array entries, and marks values
whose type differs from the known key type.
The bundled key metadata comes from Xcode 27.0. Unknown keys remain visible
under their raw names. These type hints do not validate a whole app bundle or
account for values Xcode adds during a build.

The viewer accepts UTF-8 XML plists and `bplist00` binary plists. It shows
dictionaries and arrays as a tree. Use Up and Down to select a value, Left and
Right to fold or open a container, Enter to toggle it, `a` to open all containers,
and Page Up and Page Down
to move through long trees. It shows data as a byte count. The input limit is
8 MiB, with at most 32,768 displayed values and 128 nesting levels.

Use another tool to edit or convert a plist, or to read an older OpenStep
property list. This viewer only presents XML and binary plist values.

`qiptui` accepts one TUI component. A `.wasm` file supplied through `-F` is
input data for that component, not a second stage that transforms its frames.

Use `-u name=value` to set a component uniform. If the component exports
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
terminal queries. Every frame written to the terminal passes this validation.

This boundary is narrower than a general terminal emulator. Use a native TUI
library or a browser host when an interface needs cursor placement, mouse input,
independent key-up events, terminal queries, or arbitrary color control.
