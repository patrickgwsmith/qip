# CommonMark and GFM baseline

Baseline measurements before optimizing `text/markdown/lib/commonmark.zig`,
which both components share.

## Artifacts and input

| Item | Bytes | SHA-256 |
| --- | ---: | --- |
| `input.md` (snapshot of `README.md`) | 40,099 | `caea40fecc220e139217f585bcddee3fb4b6567df6d5dd152873a31c3ddc59cb` |
| `text/markdown/commonmark.0.31.2.wasm` | 92,647 | `c1e148e8854b77d657e31c8a34574c008aa122a7edb0f10bbfadfe77ba17b11f` |
| `text/markdown/gfm-commonmark.0.31.2.wasm` | 97,828 | `df2634e69085abbb01c9804ec44f65918d335e2db510f61604685154d9933a83` |
| `tui/qipdb.wasm` | 130,773 | `4ccc157eb4ac8779d9f77fc5829be53acb7417c818f0ac1bfdc82acb415683cf` |

Source revision `bde4919f`; the Markdown sources and Wasm were unmodified and
up to date (`make -q`). Zig 0.15.2, Node.js 26.3.0, wazero v1.11.0, Apple M5,
macOS 27.2.1.

## qipdb counters

qipdb counts executed Wasm operations in its interpreter. These counts are not
elapsed time. Loop iterations are the sum over every loop that qipdb listed.

| `input.md` | CommonMark | GFM |
| --- | ---: | ---: |
| Executed instructions | 21,854,246 | 29,286,826 |
| Loop iterations (all loops) | 446,647 | 564,017 |
| Hottest loop iterations | 191,316 (f32 `0x00509b`) | 269,940 (f35 `0x005743`) |
| Taken branches | 1,158,695 | 1,492,854 |
| Calls | 204,424 | 309,935 |
| Memory reads | 1,301,356 | 1,622,754 |
| Memory writes | 471,700 | 591,608 |
| Output bytes | 46,638 | 52,383 |
| Output SHA-256 | `296d3efd…4b908f04` | `3c46ed32…d0a3d3c0` |

The [CommonMark trace](qipdb-commonmark.txt) and
[GFM trace](qipdb-gfm-commonmark.txt) contain the full screens, including the
iteration count for each loop. The CommonMark output hash matches `qip run`
after removing the trailing newline that the CLI adds.

## Time

`qip bench --benchtime=3s --node`, 334 runs for each module. The wazero time
includes a fresh instance for each run. The Node.js time uses one reused
instance.

| Boundary | CommonMark | GFM |
| --- | ---: | ---: |
| wazero total, mean ± stddev | 8.986 ms ± 0.834 | 11.547 ms ± 0.727 |
| wazero `render` mean | 8.624 ms | 11.204 ms |
| wazero instantiation mean | 0.281 ms | 0.263 ms |
| Node.js/V8 request, mean ± stddev | 0.436 ms ± 0.052 | 0.603 ms ± 0.052 |
| Node.js/V8 `render` mean | 0.429 ms | 0.597 ms |

Raw reports: [CommonMark](bench-commonmark.txt) and
[GFM](bench-gfm-commonmark.txt).

## After optimization (2026-11-17)

Same input, machine, toolchain, and commands. Output is byte-identical to
the baseline (same SHA-256 for both components), and the CommonMark, GFM,
entity, casefold, and differential-corpus suites pass, as do the
pathological budgets. Both builds also matched the baseline Wasm on 140,000
random Markdown-like inputs.

| Item | Bytes | SHA-256 |
| --- | ---: | --- |
| `text/markdown/commonmark.0.31.2.wasm` | 93,566 | `f9f8aa27728dbab3e414bc00dd6ad221c2a745c11379fa402537d4267c5c4804` |
| `text/markdown/gfm-commonmark.0.31.2.wasm` | 98,937 | `45cc0f354ccd689f6c8cb2fc6d7a475612ffee45f42c00f4796a7ab4612b9585` |

| `input.md` | CommonMark before → after | GFM before → after |
| --- | ---: | ---: |
| Executed instructions | 21,854,246 → 8,232,746 (2.65×) | 29,286,826 → 10,491,525 (2.79×) |
| Loop iterations (all loops) | 446,647 → 236,182 | 564,017 → 284,310 |
| Hottest loop | 191,316 → 60,131 (`nextTmpLine`) | 269,940 → 82,747 (`indexOfScalarPos`) |
| Calls | 204,424 → 49,406 | 309,935 → 55,571 |
| Memory reads / writes | 1.30M / 472K → 470K / 116K | 1.62M / 592K → 593K / 124K |
| wazero total, mean | 8.986 → 4.735 ms (1.90×) | 11.547 → 5.539 ms (2.08×) |
| Node.js/V8 request, mean | 0.436 → 0.172 ms (2.54×) | 0.603 → 0.212 ms (2.84×) |
| Wasm bytes (gzip) | 92,647 → 93,566 (49,262 → 49,710) | 97,828 → 98,937 (51,109 → 51,506) |

In both baseline builds the hottest loop was `mem.eql` (f32 in CommonMark,
f35 in GFM). Most of those calls came from `compactEmptyListItems` calling
it once per output byte.

Raw output: [CommonMark trace](qipdb-commonmark-optimized.txt),
[GFM trace](qipdb-gfm-commonmark-optimized.txt),
[CommonMark bench](bench-commonmark-optimized.txt),
[GFM bench](bench-gfm-commonmark-optimized.txt).

### wazero timing and context-done checks

qip's runtime uses `WithCloseOnContextDone(true)`
(`internal/wasmruntime/runtime.go`). This adds a check on every loop back-edge
and function call. A Go harness that reused one instance and ran the optimized
GFM `render` 300 times took 1.01 ms per run without the setting and 6.39 ms with
it. Most of the 25× gap between wazero and V8 in the tables comes from this,
not from the guest code. It's also why reducing loop iterations and calls
helps wazero more than the instruction count alone suggests.

### Wasm size opportunities (not done)

- HTML5 entity table: about 35 KB of the 44 KB data section. Front-code the
  sorted names (the existing TODO in `lib/commonmark.zig`).
- Block-level dispatch is duplicated across `renderBlocks`,
  `renderListItemContent`, `firstListItemBlockIsCode`,
  `contentOpensParagraph` and the paragraph lookaheads. A per-line classifier
  (the line-classification TODO) would merge these, and would also remove most
  of the remaining `leadingIndent`/`parseListMarker` calls.
- `std.fmt.bufPrint` for heading tags and ordered-list start numbers links in
  the integer formatter. A one-digit level write plus a small itoa is enough.
- `matchesType1Start` / `isType6TagName` compare against string lists one by
  one. A switch on the first byte would be smaller and faster.
- A `wasm-opt -Oz` post-pass, not yet measured.
- Not recommended: ReleaseFast is 1.6× faster in V8 but only about 1.15× in
  qip's wazero, and costs +62–66% wasm (+24–26% gzip). Forcing
  `leadingIndent` inline gains about 10% for +5.5 KB.

## Reproduce

```sh
make -j qip tui/qipdb.wasm text/markdown/commonmark.0.31.2.wasm text/markdown/gfm-commonmark.0.31.2.wasm
cd benchmarks/commonmark-gfm-baseline
node profile.mjs ../../text/markdown/commonmark.0.31.2.wasm input.md > qipdb-commonmark.txt
node profile.mjs ../../text/markdown/gfm-commonmark.0.31.2.wasm input.md > qipdb-gfm-commonmark.txt
cd ../..
./qip bench -i benchmarks/commonmark-gfm-baseline/input.md --benchtime=3s --node text/markdown/commonmark.0.31.2.wasm
./qip bench -i benchmarks/commonmark-gfm-baseline/input.md --benchtime=3s --node text/markdown/gfm-commonmark.0.31.2.wasm
```

`profile.mjs` raises the qipdb instruction budget from its 1,000,000 default to
the 100,000,000 maximum. Without that change, qipdb pauses before `render`
finishes.
