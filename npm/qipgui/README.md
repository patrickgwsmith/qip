# qipgui (prototype)

`qipgui` runs one QIP [GUI component](https://qip.dev/docs/gui-components) in a
terminal that supports the
[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
and SGR pixel mouse reports (kitty, Ghostty and WezTerm). It is a prototype for
testing whether this approach is viable, so the package is marked private and
imports `../qiptui/qiptui.mjs` directly. Before anyone publishes it, it needs
to depend on `qiptui` or bundle the code it shares with it.

```sh
node npm/qipgui/qipgui.mjs gui/calculator.wasm
node npm/qipgui/qipgui.mjs --stats --transport zlib gui/snake.wasm
node npm/qipgui/qipgui.mjs --size fill gui/paint.wasm
```

It reuses qiptui's loader, which supports hosted `host/path.wasm` downloads,
along with qiptui's Strict Wasm Profile checks, `-u` uniform parsing, and key
decoder. Only presentation and pointer input are new:

- `render()` must return KTX2 `R8G8B8A8_SRGB`. Each frame's level 0 pixels go
  to the terminal as an `f=32` image in 4096-byte base64 chunks. Frames
  alternate between image ids 1 and 2: each new image is placed before the old
  one is deleted, inside synchronized output (`?2026`), to avoid flicker.
- Mouse reporting uses `?1003` (all motion), `?1006`, and `?1016` (pixel
  coordinates). The left, middle, and right buttons map to QIP masks 1, 2, and
  4. Moving off the image, or losing focus (`?1004`), sends `pointer_event(0,
  -1, -1)`. During a drag, a pointer outside the image reports the nearest
  edge pixel. The wheel is ignored.
- Keys are delivered like qiptui's: a key-down and a key-up together, because
  terminals do not report key releases. `Ctrl-C` exits and `Ctrl-Z` suspends.
- At startup, qipgui queries for graphics support, the window size in pixels
  (`CSI 14 t`), and the cell size (`CSI 16 t`). It fails if the graphics query
  gets no answer within one second. Each resize sends the size queries again.

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

qipgui presents 47 of the 57 `gui/*.wasm` components. The other 10 output SVG,
or, in the case of `gif-player`, need GIF input (`-i file.gif`).

## Still to verify in a real terminal

- Whether SGR pixel coordinates are 0-based or 1-based in each terminal.
  qipgui treats them as 0-based. Click a corner pixel to check.
- Whether pixel reports and the `CSI 14 t` window size use the same units on
  HiDPI displays.
- Pointer accuracy after resizing with `--size fill`.
- Frame rate and input latency over SSH, where `--transport file` is not
  available.
