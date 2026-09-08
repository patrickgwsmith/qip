# Optimizing `rgb-to-hex` With qipdb

qipdb made unnecessary work in `rgb-to-hex.wasm` visible. For the 17-byte
input `rgb(101, 79, 240)`, the original component executed 31 memory reads and
10 memory writes to produce seven bytes. The optimized component reads each
input byte once and writes each output byte once.

The original code was correct for the documented examples. The extra accesses
were inside the component's declared memory, not out-of-bounds accesses. They
still cost instructions, obscured the parser's data flow, and required an
otherwise unused fourth WebAssembly memory page.

## Before And After

Continue execution in qipdb and expand its counters with `i`. The same module,
input, host, and qipdb build produced these measurements:

| qipdb counter | Before | After | Change |
| --- | ---: | ---: | ---: |
| Executed instructions | 1,219 | 967 | -21% |
| Function calls | 39 | 7 | -82% |
| Loop iterations | 12 | 9 | -25% |
| Memory reads | 31 | 17 | -45% |
| Memory writes | 10 | 7 | -30% |
| Fixed linear memory | 256 KiB | 192 KiB | -25% |
| Compiled Wasm size | 1,123 B | 972 B | -13% |

qipdb counts executed load and store instructions. It does not label each count
as a byte count. In the old component, 28 loads read single input bytes and
three loads read 32-bit parser positions from scratch memory. Seven stores
wrote the output and three 32-bit stores wrote those parser positions. Thus,
the old run touched more bytes than the `31 reads, 10 writes` labels alone
suggest.

The optimized run uses only `load8_u` for its 17 input reads and `store8` for
its seven output writes. For this input, the operation counts and byte counts
are therefore equal.

## What Changed

The parser previously returned a channel value and wrote its next input
position through a pointer at `0x30000`. Each of the three channels caused one
32-bit scratch store and one 32-bit scratch load. The new parser returns both
values in one `i64`: the channel occupies the high 32 bits and the next input
position occupies the low 32 bits. This removes six memory operations and the
scratch page.

The old parsing stages also loaded the same byte again when ownership passed
from whitespace scanning to digit scanning, and from digit scanning to
separator validation. The new parser keeps the current byte in a local and
hands it to the next stage. The representative input is now scanned once from
left to right.

Small helpers for whitespace checks, ASCII lowercasing, digit checks, and each
hex nibble previously caused most of the 39 calls. The revised implementation
keeps the three channel-parser calls and three two-digit output calls. Simple
checks are inline, and ASCII case folding and hex digit selection use integer
operations.

The output capacity now states the actual bound: seven bytes for `#rrggbb`,
instead of 64 KiB. The input capacity remains 64 KiB because whitespace and
leading zeroes can make a valid input longer than the common form.

The parser also rejects a channel as soon as its accumulated value exceeds
255. This avoids integer wrap on a very long decimal channel. Separators are
now exactly one comma, with optional whitespace on either side; repeated
commas are rejected.

## Reproduce The Check

Build the component and its Compliance oracle:

```sh
make -j \
  components/text/rgb-to-hex.wasm \
  compliance/rgb-to-hex.comply.wasm

./qip comply \
  components/text/rgb-to-hex.wasm \
  --with compliance/rgb-to-hex.comply.wasm
```

Open the representative input in qipdb:

```sh
npx @qip.dev/qipx tui \
  -F component=@components/text/rgb-to-hex.wasm \
  -F 'input=rgb(101, 79, 240)' \
  components/interactive/qipdb.wasm
```

Press Space to finish execution, then `i` to expand the static and runtime
counters. Use `x`, followed by `i` or `o`, to inspect the input or output
buffer.

## Limits Of This Comparison

These runtime counts describe one accepted input. Other inputs take different
paths: whitespace adds loop iterations, raw `r,g,b` input skips wrapper checks,
and invalid input returns early. Compliance cases protect the accepted syntax,
channel limits, malformed separators, and long decimal values, but qipdb is
still a debugger rather than a benchmark. Use `qip bench` or `qipx bench` to
compare elapsed time after qipdb identifies the work to remove.
