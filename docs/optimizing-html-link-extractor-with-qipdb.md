# Optimizing HTML Link Extraction With qipdb

`html-link-extractor.wasm` reads HTML and writes one link per line. Each line
contains the decoded `href` and a simplified accessible name.

The old component did not recognize `aria-labelledby`. It also included
comments, scripts, and styles in names. The corrected component fixes those
cases and resolves repeated label references up to 9.9 times faster in V8.

## Define Correct Output First

The Compliance oracle has 20 exact input and output cases. It covers relative
and absolute links, entities, nested text, image `alt` text, `aria-label`,
`aria-labelledby`, duplicate IDs, forward references, comments, raw text, and
malformed anchors.

The shipped artifact passed 11 cases. It failed all seven
`aria-labelledby` cases because the attribute matcher used a length of 14.
The name has 15 characters, so that branch could not run. It also stopped at
the first same-name nested end tag and treated hidden source text as visible
text.

The new JavaScript tests check the same behavior through the Content ABI. They
also check maximum-size input, 1,100 IDs, and the label-heavy benchmark used
below. The 1,100-ID case verifies the bounded index fallback.

This is still a small HTML scanner, not a browser parser. The oracle defines
the supported subset. It does not claim full HTML parsing or complete
Accessible Name Computation conformance.

## Inspect The Corrected Baseline

Correctness changes can change execution paths. The performance comparison
therefore starts from a correctness-only build, not the shipped artifact.

On the 27,605-byte generated `site-static/docs.html` page, qipdb reported
904,750 executed instructions and 74,872 taken branches. The component
searched from the start of the document for each label reference.

The same trace wrote ordinary URL and text bytes with scalar stores. Static
analysis reported no `memory.copy` instruction.

The hypothesis had two parts:

- Build a bounded ID index on the first `aria-labelledby` use. Resolve later
  references against that index.
- Copy runs with no entity or whitespace boundary with `memory.copy`.

The index stores at most 1,024 IDs. If a document has more, the component uses
the old scan for that render. This keeps memory bounded and preserves output.
The index fits in the existing linear memory, so the module still declares
256 KiB.

## Results

The typical fixture is `site-static/docs.html`. Its SHA-256 is
`5c8b68425aaa61b13806c7fa84ce36b27aaa0242d1aa040ab155a602923fb2d4`.
Both measured builds produce 3,121 bytes with SHA-256
`30cc4a93d0192b412098f758a5894aefaa8b3a19d1bb1573861734e7936f17b4`.

Five thousand alternating runs gave these measurements:

| Measurement | Correctness-only | Indexed and bulk-copy | Change |
| --- | ---: | ---: | ---: |
| wazero total | 790.2 µs | 796.2 µs | 1% slower |
| V8 render | 25.02 µs | 22.40 µs | 1.12× faster |
| qipdb instructions | 904,750 | 827,633 | -9% |
| qipdb branches taken | 74,872 | 69,808 | -7% |

The second fixture has 128 IDs and 128 links. Each link names four labels. The
11,134-byte input has SHA-256
`05630c5cdfda8dff17732aeea58d6053e08d9699a250b50d084095a6600b47d9`.
It produces 5,338 bytes with SHA-256
`981ea3b40a980e3fae86bd5fe4a6fe21686b2d578292f6a8ba6a0b8b45ea779b`.

Three hundred alternating runs gave these measurements:

| Measurement | Correctness-only | Indexed and bulk-copy | Change |
| --- | ---: | ---: | ---: |
| wazero total | 25.99 ms | 3.047 ms | 8.53× faster |
| V8 render | 868.3 µs | 88.05 µs | 9.86× faster |
| qipdb instructions | 39,654,915 | 3,735,494 | -91% |
| qipdb branches taken | 2,609,090 | 203,642 | -92% |
| qipdb calls | 67,968 | 4,480 | -93% |

The indexed build adds code and two static `memory.copy` sites:

| Artifact | Oracle cases | Raw Wasm | gzip Wasm | Brotli Wasm | Linear memory |
| --- | ---: | ---: | ---: | ---: | ---: |
| Shipped | 11/20 | 8,640 B | 3,257 B | 2,848 B | 256 KiB |
| Correctness-only | 20/20 | 9,674 B | 3,633 B | 3,174 B | 256 KiB |
| Indexed and bulk-copy | 20/20 | 11,143 B | 4,073 B | 3,556 B | 256 KiB |

The production build uses the indexed version. It adds 440 gzip bytes over the
correctness-only build. The typical wazero difference is within 1%, the typical
V8 result is faster, and repeated label resolution is much faster in both
runtimes.

The benchmarks ran on a MacBook Air with an Apple M5 10-core CPU and 24 GB of
memory, on macOS 26.6.2. The runtimes were wazero 1.11.0 and Node.js 26.3.0
with V8 14.6.202.34-node.20. Zig 0.15.2 built the modules.

## Reproduce The Checks

Build and test the component:

```sh
make -j \
  qip \
  text/html/html-link-extractor.wasm \
  compliance/html-link-extractor.comply.wasm \
  application/wasm/wasm-counts.wasm \
  components/interactive/qipdb.wasm

./qip comply \
  text/html/html-link-extractor.wasm \
  --with compliance/html-link-extractor.comply.wasm \
  --straight-line-oracles

node --test test/html-link-extractor.mjs
```

Generate the label-heavy input without storing it in the repository:

```sh
node tools/generate-html-link-extractor-benchmark.mjs \
  > /tmp/html-link-extractor-label-heavy.html
```

Keep a baseline artifact before rebuilding. Then compare both modules:

```sh
./qip bench \
  -i /tmp/html-link-extractor-label-heavy.html \
  -r 300 \
  --node \
  /tmp/html-link-extractor-correct-before-fast.wasm \
  text/html/html-link-extractor.wasm
```

Open the same input in qipdb. Press Space to finish execution, then press `i`
to expand the counters:

```sh
npx @qip.dev/qipx tui \
  -F component=@text/html/html-link-extractor.wasm \
  -F input=@/tmp/html-link-extractor-label-heavy.html \
  components/interactive/qipdb.wasm
```

The shipped artifact has SHA-256
`97cd6ae88b7e72bb13db8f42f162188878fc288b8d63fd4c84a9281ed22f723f`.
The correctness-only artifact has SHA-256
`2fb3420c00cd497b2502ba8f0577cf8a82a1cf464a2834de85c6f905e569f71e`.
The final artifact has SHA-256
`99e8ecffd248cb6eb10cb7ff5215c2a2067c71f2d01b800707c2c4a6fae95e80`.

Both the shipped and final artifacts pass `wasm-strict-profile.wasm`. Neither
passes the optional static loop or output proofs. Use a host time limit for
untrusted input. The JavaScript capacity test verifies that the returned byte
count stays within the advertised output buffer.

## When Not To Use This Component

Use a conforming HTML parser when browser error recovery, templates, foreign
content, CSS visibility, or the complete accessible-name algorithm affects
your result. Use this component for controlled HTML where its tested subset is
sufficient.
