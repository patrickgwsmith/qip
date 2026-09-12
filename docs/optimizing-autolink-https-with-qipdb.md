# Optimizing `autolink-https` With qipdb

`autolink-https.wasm` turns visible HTTPS URLs into HTML links. The revised
component fixes six oracle cases, uses 640 KiB less linear memory, and renders
the canonical input 22% faster in wazero and 23% faster in Node.js.

The first source rewrite did not improve both runtimes. It used fewer executed
instructions and was faster in Node.js, but it was slower in wazero. qipdb
showed that the compiler had emitted byte-copy loops. A second change replaced
those loops with WebAssembly `memory.copy` instructions. That change made the
wazero run faster.

## Correctness First

The new Compliance oracle defines 21 exact input and output pairs. The old
component fails six of them:

- It changes `&` to `&amp;` in a generated `href`.
- It changes an existing `&amp;` to `&amp;amp;`.
- It links URLs after an alphanumeric prefix, such as
  `prefixhttps://example.com`.
- It links URLs in an HTML comment when the comment contains `>`.
- It loses its script context when a script contains `<`.
- It links URLs in a `title` element.

The revised component passes all 21 cases. A Node.js test also sends the full
1 MiB input capacity with the densest possible sequence of links. It verifies
the complete 3,565,151-byte output. This test checks the smaller output buffer
against its worst-case expansion.

## Canonical Input

`fixtures/autolink-https-canonical.html` is a 920-byte HTML document. It
contains visible URLs, punctuation, attributes, comments, anchors, code,
scripts, styles, and a title. Both builds produce the same 1,272-byte output:

```text
sha256 084fe8c8c9cc9632fbe8739217c4e83908bf5b731684dd50a8106eb3e9846625
```

The benchmark ran on a MacBook Air with an Apple M5 and 24 GB of memory. It
used macOS 26.6.2, qip with wazero 1.11.0, and Node.js 26.3.0 with V8
14.6.202.34. Each module ran for five seconds.

| Execution boundary | Before | After | Change |
| --- | ---: | ---: | ---: |
| wazero render mean | 54.118 µs | 42.032 µs | -22% |
| wazero fresh-instance total mean | 198.645 µs | 170.799 µs | -14% |
| Node.js render mean | 1.969 µs | 1.517 µs | -23% |
| Node.js reused-instance total mean | 2.375 µs | 1.925 µs | -19% |

The fresh-instance total includes contract checks, input and output copies,
and instantiation. The Node.js total reuses one instance. Do not compare the
two total columns as if they measured the same lifecycle.

## What qipdb Showed

The qipdb counts use the same canonical input and output hash:

| qipdb counter | Before | After | Change |
| --- | ---: | ---: | ---: |
| Executed instructions | 100,707 | 56,143 | -44% |
| Taken branches | 5,506 | 3,875 | -30% |
| Function calls | 150 | 164 | +9% |
| Memory operations that read | 2,115 | 1,704 | -19% |
| Memory operations that write | 1,272 | 103 | -92% |
| Fixed linear memory | 5,248 KiB | 4,608 KiB | -12% |

qipdb counts a `memory.copy` as one read operation and one write operation. It
does not count each copied byte as a separate operation. The lower write count
shows that the component now uses block copies. It does not mean that the
component wrote only 103 bytes.

The first rewrite still used scalar copy loops. On the same input, it executed
73,372 instructions, 2,823 read operations, and 1,272 write operations. Its
wazero render mean was about 64 to 67 µs, which was slower than the original.
This trace changed the optimization hypothesis: copying spans was not enough;
the compiled module also needed a block-copy instruction.

The final build uses `-mbulk-memory`. Zig then lowers `__builtin_memcpy` to
`memory.copy`. This reduced dynamic work and the measured render time in both
runtimes.

## Static Size And Structure

The source-built artifact is larger even though its executed path is shorter:

| Measurement | Before | After |
| --- | ---: | ---: |
| Raw Wasm | 3,033 B | 3,287 B |
| gzip, as reported by `qip bench` | 1,535 B | 1,699 B |
| Brotli level 11 | 1,385 B | 1,565 B |
| Static function instructions | 1,360 | 1,527 |
| Static branch sites | 133 | 172 |
| Static loops | 16 | 17 |

The extra code handles comments, quoted attributes, raw-text elements, URL
boundaries, and balanced trailing brackets. The canonical path executes less
work because the scanner copies contiguous spans and counts brackets once.
The old component copied most output one byte at a time. It also scanned the
URL again for each trailing unmatched bracket.

A trial with the repository's pinned `wasm-opt -Oz` produced a 2,982-byte
module. It passed the oracle and kept the speed improvement. Its gzip and
Brotli sizes were still 88 B and 93 B larger than the old component. The
tracked build does not use this extra post-link step. It keeps this small C
component on the direct Zig build path.

## Reproduce The Checks

```sh
make -j \
  qip \
  text/html/autolink-https.wasm \
  compliance/autolink-https.comply.wasm \
  application/wasm/wasm-counts.wasm \
  components/interactive/qipdb.wasm

./qip comply \
  text/html/autolink-https.wasm \
  --with compliance/autolink-https.comply.wasm \
  --straight-line-oracles

node --test test/html-adjacent.mjs

./qip bench \
  -i fixtures/autolink-https-canonical.html \
  --benchtime=5s \
  --node \
  /tmp/autolink-https-before.wasm \
  text/html/autolink-https.wasm

./qip run \
  -i text/html/autolink-https.wasm \
  -- application/wasm/wasm-counts.wasm
```

The benchmark command needs a saved baseline at the shown temporary path.
Its SHA-256 is
`ec613f67c001beb515e6565393f9cba7f2dc5934210b9ae0f020bed732e5aa7c`.

Open the component and fixture in qipdb:

```sh
npx @qip.dev/qipx tui \
  -F component=@text/html/autolink-https.wasm \
  -F input=@fixtures/autolink-https-canonical.html \
  components/interactive/qipdb.wasm
```

Press Space to finish execution. Press `i` to expand the counters.

## Limits Of This Comparison

The timings describe one short HTML document. A page with no links, many
links, or long unmatched brackets takes a different path. The oracle checks
selected HTML contexts; this component is not a complete HTML parser.

Both builds pass `wasm-strict-profile.wasm` and
`wasm-nontrapping-divides.wasm`. Neither build passes the optional static
proofs in `wasm-bounded-loops.wasm` or `wasm-bounded-output.wasm`. The source
bounds each scan by the input size and checks each output copy. The full-input
test checks the calculated output capacity, but these facts do not match the
conservative instruction patterns that the two proof components accept. Use a
host time limit when this component processes untrusted input.

Use it for controlled HTML fragments where a small streaming scanner is
sufficient. Use a conforming HTML parser when browser error recovery, foreign
content, templates, or malformed markup can change which text is visible.
