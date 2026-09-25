# Optimizing HTML Escaping With qipdb

`html-escape.wasm` turns text into HTML-safe text. It replaces `&`, `<`, `>`,
double quotes, and apostrophes with entities. The site uses it when it renders
syntax-highlighted code. An unchanged input still needs an output copy, but it
does not need one WebAssembly store for every byte.

The original component scanned the input to calculate output size, then
scanned it again and wrote unchanged bytes one at a time. qipdb showed this
compiled path. A whole-input `memory.copy` for inputs with no escapes reduced
the executed instruction count by 57% on a 1,152-byte fixture. It also made a
9,216-byte fixture 1.52 times faster in wazero and 2.33 times faster in the
local Node.js `qipx` benchmark.

## Define The Output

The new Compliance oracle has 12 exact input and output cases. It covers each
entity, unchanged UTF-8, escapes at adjacent and separated positions, an
already escaped entity, and unchanged NUL and whitespace bytes. It passed
against the saved original Wasm before the source changed. The existing Zig
tests and site smoke test remain in place.

The original and final artifacts also produced identical output bytes in every
sample of both benchmarks below. This comparison checks the measured inputs;
the oracle checks small cases with independently written expected bytes.

## What qipdb Found

The trace input was `"ordinary text and UTF-8 café 😀. "` repeated 32 times:
1,152 UTF-8 bytes with no characters to escape. Both artifacts produced those
same 1,152 bytes. The input and output SHA-256 is
`670190980d05aab33912e3c43a7ecd374e5ced8a88ae3442e9040d29f9ba4584`.

| qipdb runtime counter | Original | Final |
| --- | ---: | ---: |
| Executed instructions | 99,119 | 42,672 |
| Taken branches | 8,067 | 3,458 |
| Memory reads | 2,304 | 1,153 |
| Memory writes | 1,152 | 1 |

The original reads each byte during both passes and uses a scalar store for
each unchanged byte. The final build reads each byte during the sizing pass,
then executes one `memory.copy`. qipdb counts that copy as one read operation
and one write operation; it does not claim that only one byte moved. Both builds
declare 5,696 KiB of linear memory.

This is a useful example of inspecting the compiled Wasm. Both source versions
use `@memcpy` to write escape entities, and even the original Wasm contains one
static `memory.copy` site. That static count did not mean normal text used a
bulk copy. qipdb showed the path actually executed for the input. It also
reported zero function calls: Zig had inlined the source helpers. Counting
source function calls would have misidentified the cost.

## The Span-Copy Trial

The first candidate accumulated unchanged bytes until it found an escapable
byte, then copied that span and wrote the entity. qipdb confirmed that Zig
compiled those variable-length `@memcpy` calls to `memory.copy`. On a
1,060-byte mixed fixture, executed instructions fell from 91,347 to 77,495
and memory write operations fell from 1,060 to 260.

That reduction did not improve every runtime. On an 8,480-byte mixed fixture,
1,000 alternating `qip bench` samples measured wazero fresh-instance mean
time at 374.4 µs for the original and 411.8 µs for the span-copy candidate.
Node.js improved from 21.1 µs to 18.5 µs on its reused-instance boundary.
The shorter instruction path was insufficient evidence for a wazero speedup.

A later three-way comparison used 30,000 runs per artifact. On the same mixed
fixture, Node.js measured 20.5 µs for the original, 18.6 µs for the final
fast-path build, and 17.7 µs for span copying. The installed Rust `qipx`, which
uses Wasmtime, measured 17.68 µs, 17.28 µs, and 20.91 µs respectively. Span
copying helped Node.js but was 21% slower than the fast-path build in Wasmtime.
On plain text, Wasmtime measured 11.11 µs, 5.38 µs, and 8.65 µs. The fast-path
build was the best of these three in Rust for both fixtures.

The final source takes a narrower path. The sizing pass already calculates
`needed`. Every escaped character expands to more than one byte, so
`needed == input.len` proves that no escaping is needed. In that case the
component copies the whole input once. For mixed input it keeps the original
scalar writer. This adds one branch to the mixed path without adding the many
small `memory.copy` operations from the first trial. This choice follows the
Node.js and Rust results as well as the wazero result.

## Measured Result

The benchmark used two deterministic fixtures:

| Input | Bytes | SHA-256 | Output bytes |
| --- | ---: | --- | ---: |
| Plain UTF-8, 256 repeats | 9,216 | `8d605cf2e85e73ac4b4580105cad3520324a23fdf81e3025c2f03e24ecbc5a57` | 9,216 |
| Mixed HTML, 160 repeats | 8,480 | `0e0f484075067435e812764124da0dae97221c4990533c17cf7ac3badeedc81a` | 12,640 |

Five thousand alternating `qip bench --node` samples per artifact gave these
mean times. The wazero total includes a new instance, contract checks, copies,
and render. The Node.js total copies input and output and renders on a reused
instance.

| Input and boundary | Original | Final | Change |
| --- | ---: | ---: | ---: |
| Plain, wazero total | 365.4 µs | 240.7 µs | 1.52× faster |
| Plain, wazero render | 266.2 µs | 140.2 µs | 1.90× faster |
| Plain, Node.js total | 13.57 µs | 5.33 µs | 2.55× faster |
| Mixed, wazero total | 377.4 µs | 372.7 µs | About the same |
| Mixed, Node.js total | 21.05 µs | 19.29 µs | 1.09× faster |

The local `qipx bench` command measured the plain fixture directly in Node.js:
13.7 µs before and 5.86 µs after, or 2.33 times faster. Its mixed-input means
were 21.9 µs and 18.9 µs. These runs had long outliers, so the exact means
vary. The plain-input gain appears in qipdb, wazero, and both Node.js runners;
the mixed-input difference is smaller and should not be used as a capacity
estimate without measuring the application's input distribution.

Rust `qipx` uses Wasmtime and reuses one instance. Thirty thousand runs with
the installed `~/.cargo/bin/qipx` measured 11.67 µs before and 4.60 µs after
on the plain fixture (2.53× faster). The mixed fixture took 17.88 µs before
and 17.72 µs after, a difference of less than 1%. A shorter 5,000-run mixed
trial showed a larger gap, which did not hold in the longer run. The checkout's
debug binary also reproduced the plain-input gain: 14.62 µs before and
9.22 µs after in a 5,000-run trial. Its mixed-input means were 41.26 µs and
41.37 µs. The installed and checkout binaries use different build profiles,
so compare each binary's before and after pair rather than their absolute times.

The final module is 672 raw bytes and 447 gzip bytes, up from 631 and 428
bytes. Its fixed linear memory remains 5,696 KiB. The extra 41 raw bytes buy a
fast path for unchanged text; inputs with escapes still use the old writer.

## Reproduce The Study

The saved original artifact is the tracked Wasm from commit
`63e9af619ec7014e209c046704f3d8e1bfb6603a` (SHA-256
`6f2663f4c55a5a444f65fa9ac6405f6ab6c055308ac8219071b993c98476a597`).
Recover it and build the final component and oracle:

```sh
git show 63e9af619ec7014e209c046704f3d8e1bfb6603a:text/html/html-escape.wasm > /tmp/html-escape-before.wasm
make -j text/html/html-escape.wasm compliance/html-escape.comply.wasm
./qip comply text/html/html-escape.wasm --with compliance/html-escape.comply.wasm --straight-line-oracles
```

Generate the benchmark inputs with Node.js:

```sh
node -e 'const fs=require("fs"); fs.writeFileSync("/tmp/html-plain.txt", "ordinary text and UTF-8 café 😀. ".repeat(256)); fs.writeFileSync("/tmp/html-mixed.txt", "<span title=\"Tom & QIP\">Hello</span> and plain text. ".repeat(160));'
```

Run the comparison without a build or other CPU-heavy work in parallel:

```sh
./qip bench -i /tmp/html-plain.txt -r 5000 --node /tmp/html-escape-before.wasm text/html/html-escape.wasm
./qip bench -i /tmp/html-mixed.txt -r 5000 --node /tmp/html-escape-before.wasm text/html/html-escape.wasm
node npm/qipx/cli.mjs bench -i /tmp/html-plain.txt -r 5000 /tmp/html-escape-before.wasm text/html/html-escape.wasm
~/.cargo/bin/qipx bench -i /tmp/html-plain.txt -r 30000 /tmp/html-escape-before.wasm text/html/html-escape.wasm
rust/qipx/target/debug/qipx bench -i /tmp/html-plain.txt -r 5000 /tmp/html-escape-before.wasm text/html/html-escape.wasm
```

To inspect the executed path, use 32 repeats for the shorter plain fixture and
open each artifact in qipdb. Press Space to finish execution and `i` to expand
the runtime counters:

```sh
node -e 'require("fs").writeFileSync("/tmp/html-trace.txt", "ordinary text and UTF-8 café 😀. ".repeat(32))'
node npm/qipx/cli.mjs tui -F component=@text/html/html-escape.wasm -F input=@/tmp/html-trace.txt tui/qipdb.wasm
```

qipdb is an interpreter. Its instruction and memory-operation counts describe
the path through this compiled Wasm. They are not production timings. Use the
benchmark results to decide whether a source change helps a target host.
