# Interactive ANSI Terminal Output

Status: shelved design draft. Do not treat this page as a contract or an
implementation plan.

The Timed and Eventful Interactive contract can publish terminal output instead
of pixels. A first terminal component could retain application state, accept
the existing keyboard events, and return a complete `text/x-ansi` screen from
each `render` call. The browser host would select a terminal presenter from the
declared output content type.

This would exercise the same separation already used by pixel components:

```text
begin_update_at -> key events -> finish_update -> render
                                               -> text/x-ansi snapshot
```

KTX2 would remain the primary pixel presentation format. ANSI output would
demonstrate that time and events extend the Content lifecycle without requiring
a framebuffer.

## Initial Output Profile

`text/x-ansi` is an informal MIME type rather than a complete terminal format
specification. QIP would need to document and validate a narrow profile. The
first profile should favor complete, deterministic snapshots over xterm
compatibility.

- UTF-8 output.
- One complete fixed-size screen per `render` call.
- A rectangular grid, initially 80 columns by 24 rows.
- SGR foreground color, background color, bold, and inverse video.
- Newline, carriage return, cursor positioning, erase, and visibility controls
  from a documented ECMA-48 subset.
- A reset, clear, and home sequence at the start of every snapshot.
- No OSC commands, clipboard access, hyperlinks, device queries, terminal
  resizing, alternate screen, or mouse reporting.
- Fixed limits for output bytes, escape-sequence length, rows, columns, and
  parsed cells.

A snapshot could begin with:

```text
ESC [ 0 m  ESC [ 2 J  ESC [ H
```

The presenter must parse the bytes. It must never send them to the browser DOM
as HTML or forward them to a real terminal. Output outside the supported
profile is a component or host integration defect.

The initial implementation can limit printable cells to ASCII. Supporting
general Unicode requires a defined cell-width algorithm for combining and
wide characters. UTF-8 alone does not specify terminal cell width.

Complete snapshots preserve the current presentation rules. A presenter can
recreate the screen after suspension or resource loss without retaining an
earlier stream. Incremental terminal output would make rendering depend on
missing history and should not be part of the first version.

## Browser Presenter

Canvas is the preferred first presenter. It provides predictable latency and
does not require SVG or HTML markup diffing.

The presenter would:

1. Parse the ANSI snapshot into a fixed cell grid.
2. Validate its dimensions and supported control sequences.
3. Draw background runs.
4. Draw glyph runs with one fixed-width font and measured cell dimensions.
5. Draw an optional steady cursor.
6. Map browser focus and keyboard events through the existing Interactive host
   loop.

An 80 by 24 screen contains 1,920 cells, so a complete Canvas redraw should be
cheap. The presenter can retain the preceding parsed grid and skip unchanged
runs later, but that is an internal optimization. The component continues to
publish a complete screen.

SVG is a possible second presenter. Replacing a small SVG after a keyboard
event would probably be adequate, but SVG parsing, DOM allocation, style work,
and text positioning add overhead without improving the initial experiment.
SVG becomes useful when selectable vector text or inspection is a higher
priority than the lowest presentation latency.

A styled `pre` element could provide native selection and accessibility. It
would require DOM construction and careful handling of style runs. A later
host could pair Canvas presentation with a synchronized semantic text view
instead.

## Cursor

A blinking cursor is not required. Blinking would create presentation work
without changing component state and could run inside the presenter if it is
added later.

A steady cursor is useful because it shows keyboard focus and the insertion
position. The snapshot can position and show the cursor at its final cell. The
Canvas presenter can draw a block or underline there. The host can distinguish
focused and unfocused states without asking the component to render another
snapshot.

The first demonstration may omit the cursor if it only accepts complete
commands. An interface that displays character-by-character editing should use
a steady cursor.

## Existing Key Event Compatibility

The current `key_event(x11_key, flags)` ABI is sufficient for an initial ASCII
terminal. It carries printable code points, navigation keysyms, key-down and
key-up state, repeat, and modifier flags.

A fake terminal application can consume these events directly. It only needs
to encode terminal input bytes if it emulates a terminal connected to a
program that expects stdin. Such an encoder would normally map key-down and
repeat events as follows:

| QIP event | Terminal input bytes |
| --- | --- |
| Printable code point | UTF-8 |
| Enter | carriage return |
| Tab | horizontal tab |
| Escape | `ESC` |
| Backspace | `DEL` |
| Up, Down, Right, Left | `CSI A`, `CSI B`, `CSI C`, `CSI D` |
| Control plus A through Z | C0 bytes `0x01` through `0x1a` |
| Alt plus a printable key | `ESC` followed by the encoded key |

Key-up events normally produce no terminal input. They remain part of the
shared Interactive ABI because games and held-key interfaces need them.

The current browser host has gaps which do not block the first experiment:

- Home, End, Page Up, Page Down, Insert, and function keys need DOM-to-X11
  mappings.
- Paste and IME composition need a separate UTF-8 text event. A pasted string
  should not be represented as one key event.
- The DOM mapping misses Unicode code points represented by UTF-16 surrogate
  pairs because it currently accepts only `event.key.length === 1`.
- A complete emulator would retain terminal modes that select CSI or SS3
  navigation sequences.

These are host or emulator extensions. They do not require replacing the
existing key event ABI for the ASCII demonstration.

## Possible First Demonstration

A small fake shell would be enough to validate the format boundary:

- An 80 by 24 screen.
- A prompt with character-by-character input.
- Backspace, Enter, arrow-key history, and a few built-in commands.
- ANSI colors and inverse-video selection.
- A steady cursor.
- No process execution, filesystem, network, paste, IME, scrollback, or full
  xterm emulation.

The component would remain deterministic and self-contained. It would not be a
security boundary around a real shell.

## Deferred Decisions

- Whether the fixed dimensions belong only to the output profile, content-type
  parameters, component metadata, or presenter configuration.
- Whether `text/x-ansi` should remain the public format or later give way to a
  registered or QIP-specific terminal snapshot type.
- The exact ECMA-48 sequence allowlist and color palette.
- Unicode cell-width behavior.
- Selection, copying, accessibility, and paste semantics.
- Whether cursor appearance is component output or host presentation state.
- Whether a later presenter may compare complete snapshots and update only
  dirty cells.

Do not use ANSI output for arbitrary graphical interfaces or when exact font
shaping, proportional layout, images, or pointer geometry defines the
interface. KTX2, SVG, HTML, or a future semantic scene format is a better
presentation boundary for those cases.

See [TUI Components](/docs/tui-components), [Time and
Events](/docs/time-and-events), and [Formats And Encodings](/docs/formats) for
the current implemented contracts.
