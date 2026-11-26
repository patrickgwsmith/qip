# qipgui (prototype)

`qipgui` runs one QIP [GUI component](https://qip.dev/docs/gui-components) in a
terminal that supports the
[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
and SGR pixel mouse reports (kitty, Ghostty and WezTerm). It is a prototype for
testing whether this approach is viable. It requires Node.js 22 or newer.

```sh
npx qipgui ./gui/calculator.wasm
npx qipgui qip.dev/gui/calculator.wasm
npx qipgui qip.dev gui/calculator.wasm
node npm/qipgui/qipgui.mjs gui/calculator.wasm
node npm/qipgui/qipgui.mjs --stats --transport zlib gui/snake.wasm
node npm/qipgui/qipgui.mjs --size fill gui/paint.wasm
node npm/qipgui/qipgui.mjs gui/klondike.wasm \
  image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm -u background_color_rgba=0xffffffff
```

## Transform chains

Components after the first transform each frame in order, as with `qipdo`, and
only the last one has to output KTX2 `R8G8B8A8_SRGB`. This lets SVG components
run through a rasterizer. `-u` sets a uniform on the component before it. Before
any component, it applies to the first one.

- Only the first component receives keys, pointer events, and update calls.
  Later components must be content transforms: they take input and export no
  `begin_update_at`, `finish_update`, `key_event`, or `pointer_event`.
- Each transform's declared input type must match the output type of the stage
  before it, when both declare one.
- Transforms are assumed only to scale the frame. A click is taken as a fraction
  of the final image and multiplied by the first component's own size, which
  comes from its KTX2 header or its SVG root's numeric `width` and `height`, or
  its `viewBox`. For other formats, qipgui uses the final image size.

With `svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm`, the repository's 9 SVG GUI
components rasterize in 0.4 ms (`qip-logo-creature`) to 48 ms (`klondike`) per
frame. qipgui allows each component up to 1 GiB of memory (qiptui allows
256 MiB), so the `-simd` and ThorVG rasterizers also run, but on klondike they
are slower: about 220 ms and 3 s per frame.

It shares qiptui's loader, which supports hosted `host/path.wasm` downloads
and leading hosts (`qipgui qip.dev gui/calculator.wasm`) that supply
relative components missing locally. Like `qipx` and `qipok`, each component
tries the hosts in order, so one pipeline may mix components from different
hosts,
along with its Strict Wasm Profile checks, `-u` uniform parsing, and key
decoder. That code lives once in `npm/shared/qip-host.mjs` and is copied into
each package as `qip-host.mjs` by `make npm-shared`; edit only the source.
Only presentation and pointer input are new:

- The final `render()` output must be KTX2 `R8G8B8A8_SRGB`. Each frame's level 0 pixels go
  to the terminal as an `f=32` image in 4096-byte base64 chunks. Frames
  alternate between image ids 1 and 2: each new image is placed before the old
  one is deleted, inside synchronized output (`?2026`), to avoid flicker.
- Mouse reporting uses `?1003` (all motion), `?1006`, and `?1016` (pixel
  coordinates). The left, middle, and right buttons map to QIP masks 1, 2, and
  4. Moving off the image, or losing focus (`?1004`), sends `pointer_event(0,
  -1, -1)`. During a drag, a pointer outside the image reports the nearest
  edge pixel. The wheel is ignored.
- A component exporting `uniform_set_is_focused` draws its own focus state,
  such as an inactive window. qipgui leaves it at 1 at launch, then sets it to
  0 or 1 from the terminal's focus reports (`?1004`). The uniform is
  render-only: qipgui sets it before each render and redraws on a change, but
  runs no update, so focus never changes component state. Terminals without
  focus reporting keep it at 1.
- Keys are delivered like qiptui's: a key-down and a key-up together, because
  terminals do not report key releases. `Ctrl-C` exits and `Ctrl-Z` suspends.
- At startup, qipgui queries for graphics support, the window size in pixels
  (`CSI 14 t`), and the cell size (`CSI 16 t`). It fails if the graphics query
  gets no answer within one second. Each resize sends the size queries again.

## Shared channels (`connect`)

`qipgui connect <channel-url>` joins a shared channel, as specified in the
[shared channel protocol](https://github.com/royalicing/qip/blob/main/docs/qipgui-sync-protocol.md).
Everyone on the channel runs the same component and sees the same state.

```sh
node npm/qipgui/qipgui.mjs connect https://sync.example.org/v1/channels/Rk3v...
node npm/qipgui/qipgui.mjs connect --view https://sync.example.org/v1/channels/Rk3v...
```

This is the one form of qipgui that is not local. Every other form downloads
a component and then runs with no network access. With `connect`:

- The channel's server chooses the component, its input and every update
  time, and can replace the component while you watch. The component still
  runs in the same sandbox and is checked against the SHA-256 digest that
  the channel gives.
- If the URL permits editing, your keys and pointer events in the qipgui
  window are sent to the server, and from there to everyone on the channel.
  Nothing you type changes the component until the server sends it back, so
  input takes one round trip to show.
- qipgui asks before it starts, unless you pass `--yes`. `--view` never
  sends input and does not ask.
- The last row of the terminal shows the server's host, whether your input
  is being sent, and the last log entry applied. A channel URL does not say
  whether it permits editing: qipgui shows `editor` after the server accepts
  a first batch, and `viewer` after it refuses one.

Components after the URL are local transforms, as in the local form. `-i`
is not accepted, and `-u` only applies to transforms. The URL must use
HTTPS, except for a loopback address.

Animated components, such as `gui/snake.wasm`, work in a channel. Each client
runs the component's wakes on an estimate of the server's clock, so
animation plays between inputs. If an input arrives that belongs before wakes
that already ran, qipgui replays the log since the last module change
without drawing, then shows the corrected frame. Terminal focus still
reaches a channel's component, because it only affects rendering and so
cannot make clients differ.

For a local test, `tools/qipgui-channel-server.mjs` implements the server
side in memory and prints a view command (with `--view`) and an edit command:

```sh
node tools/qipgui-channel-server.mjs gui/calculator.wasm
```

Type `module gui/paint.wasm`, `prefetch gui/paint.wasm`, `drop` (cut every
stream, so clients reconnect) or `close` into it while clients are connected.
The client is in `qip-channel.mjs`, which has no terminal or GUI code.

## Options

| Option | Effect |
| --- | --- |
| `--size auto` | 1:1 pixels. An image larger than the window shrinks to fit. This is the default. |
| `--size native` | Always 1:1 pixels. |
| `--size fill` | Scale up or down to fit the window, sized in whole cell columns. |
| `--transport direct` | Base64 RGBA. This is the default. |
| `--transport zlib` | Deflated RGBA (`o=z`). |
| `--transport file` | Writes a temporary file for the terminal to read (`t=t`). Only works when the terminal runs on the same machine. |
| `--stats` | On exit, prints to stderr the frame rate, render and encode times, bytes per frame, and how long each input took to reach a flushed frame. |

## Backpressure

When `stdout.write` returns false, qipgui renders no more frames until
`drain` and then renders the latest state once. A slow terminal therefore
drops frames instead of queueing seconds of stale ones. `--stats` reports how
many renders were deferred.

## Measured encode cost

These are `render(0)` frame sizes for the repository's `gui/` components on an
Apple Silicon Mac:

| Component | Size | direct | zlib |
| --- | --- | --- | --- |
| calculator | 220×220 | 252 KiB, 0.2 ms | 6 KiB, 0.4 ms |
| snake | 400×280 | 584 KiB, 0.2 ms | 22 KiB, 0.7 ms |
| sudoku | 762×522 | 2.0 MiB, 0.3 ms | 40 KiB, 1.6 ms |
| god-rays | 640×360 | 1.2 MiB, 0.4 ms | 756 KiB, 22 ms |
| openai-anthropic-arr | 1640×1080 | 9.0 MiB, 4.5 ms | 155 KiB, 7.6 ms |
| photo-light-table | 1600×1040 | 8.5 MiB, 2.0 ms | 2.2 MiB, 54 ms |

Flat interface frames compress 20 to 60 times for a few milliseconds of
work. Photographic and shaded frames compress poorly and cost tens of
milliseconds, so `direct` or `file` suits them better.

qipgui presents 47 of the 57 `gui/*.wasm` components on their own. The other
9 SVG components need a rasterizer after them (see above), and `gif-player`
needs GIF input (`-i file.gif`).

## Still to verify in a real terminal

- Whether SGR pixel coordinates are 0-based or 1-based in each terminal.
  qipgui treats them as 0-based. Click a corner pixel to check.
- Whether pixel reports and the `CSI 14 t` window size use the same units on
  HiDPI displays.
- Pointer accuracy after resizing with `--size fill`.
- Frame rate and input latency over SSH, where `--transport file` is not
  available.
