# Drawing A Memory Heat Map In The QIP Interpreter

`qip-interpret-memory-thermal-ktx2.wasm` runs a QIP Content component in the
bounded Zig interpreter, then returns a KTX2 image with one pixel for each
byte of memory that `render` read or wrote. Each pixel shows how much work
went into the bytes written there, so you can see which output bytes or
scratch buffers took the most time to produce.

```sh
make -j application/wasm/qip-interpret-memory-thermal-ktx2.wasm

qip run \
  -F component=@text/uri-list/url-to-qr-svg.wasm \
  -F 'input=https://example.com' \
  application/wasm/qip-interpret-memory-thermal-ktx2.wasm \
  -u instruction_budget=10000000 -u normalize=0 \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm > qr-memory.png
```

This command converts the KTX2 output to PNG for viewing. The request uses the
same `component`, `input`, and `uniforms[<key>]` fields and the same
`instruction_budget` uniform as
[the QIP Content interpreter](/docs/qip-content-interpreter).

## Layout

Each 64 KiB page that `render` read or wrote becomes one 256×256 tile. Byte
`offset` of the page is at `x = offset % 256`, `y = offset / 256`, so a buffer
written front to back fills rows from left to right. Tiles stack from top to
bottom in ascending page order, with no gap between tiles.

The image holds up to 32 tiles (the KTX2 height limit of 8192). Pages are
taken from the `first_page` uniform upward, so set `first_page` to see pages
past the first 32. To get the page number of each tile, run
[`qip-interpret-memory-page-writes-csv`](/docs/qip-interpret-memory-page-writes-csv)
with the same request: tiles are its rows with nonzero `reads` or `writes`, in
the same order.

## Channels

Each instruction of `render` is attributed to the next write outside the
shadow stack, and added to the first byte that the write touched. Writes to
the same byte add up. A bright byte took a lot of work to produce. The total of
the image is the work done before the last write outside the stack, the same
way the widths in a flame graph add up to the total time.

- Red: instructions executed.
- Green: loop iterations, counted as branches back to a `loop`.
- Blue: direct and indirect calls.
- Alpha: 0 for a byte that `render` did not touch. Otherwise, the number of
  load, store, `memory.copy`, and `memory.fill` operations that touched the
  byte, starting at 64 so that bytes touched once stay visible.

Bytes that were loaded before `render` ran but that `render` never touched
keep red, green, and blue at 0 and get a low alpha: 40 for the target's input
and 24 for a data segment. Data segment bytes at alpha 24 are dead weight in
the module for this input, and a large static table that is read sparsely
shows up as a block of alpha 24 with a few brighter bytes. Only pages that
`render` read or wrote become tiles, so a page holding only unused data does
not appear.

Stack writes are not attributed. Compiled code writes to the stack every few
instructions, so the stack would otherwise take most of the work. Stack bytes
still show their access counts in alpha. The stack is the range from the lowest
value of global 0 up to its initial value. LLVM toolchains use global 0 as
`__stack_pointer`.

Only the first byte of each write gets work. A 4-byte store or a
`memory.copy` of a string shows one bright pixel followed by pixels with alpha
only.

## Scale

Levels are log2 scaled, so you can see costs from 1 to millions of
instructions in the same image.

- `normalize=1`, the default: the largest value of each channel maps to 255.
  This option shows the most contrast in one image.
- `normalize=0`: each doubling adds 8 levels, so a red level `r` means about
  `2^(r/8) - 1` instructions, and an alpha level `a` means about
  `2^((a-64)/8)` accesses. Use this option to compare images from different
  runs or components. Each level is a step of about 9%.

## How to read it

- A long run of dim, even pixels in the output region is a steady writer. Its
  level shows the cost of each byte.
- One bright pixel with dark pixels around it is a byte that waited for a large
  computation, such as a table build or a search. For `url-to-qr-svg`, one byte
  outside the output receives about 1M of the 2.7M instructions, with 32K loop
  iterations and 5.8K calls.
- High alpha with no color is memory that the component reads or rewrites
  often, such as lookup tables, the stack, and scratch buffers.

## Limits

The target runs twice: once to find touched pages and the stack range, and
once to record. Both runs use the same instruction budget. Uniform setters run
but are not recorded, so a page that only a setter touched shows an empty
tile. Work done after the last write outside the stack is not shown.

The output uses the repository's `R8G8B8A8_SRGB` KTX2 format so that other KTX2
components can read it. The channel values are measurements, not colors, so
read the stored byte values rather than colors converted to linear light.

A malformed request, unsupported Wasm feature, trap, exhausted budget, invalid
target Content contract, target rejection, or a `render` that touches no memory
at or above `first_page` becomes an outer Content rejection.

## When not to use it

The image shows where work ended up in memory, not which functions did it. Use
qipdb to step through the instructions that write a bright byte. The interpreter
runs much slower than `qip run`, so measure speed with
[benchmarks](/docs/benchmarking-components), not with this tool.
