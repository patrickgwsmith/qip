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

## Size reduction (2026-11-17)

Starting from the speed work above (`533e824d`). Output is again byte-identical:
same SHA-256 on `input.md`, no differences from the `533e824d` build on 2,098
spec, GFM and differential-corpus examples, `README.md`, `site/*.md`, every
HTML5 entity name with near misses, and 300,000 random Markdown-like inputs per
component ([`differential.mjs`](differential.mjs)). The CommonMark, GFM,
entity, casefold and differential-corpus suites, the pathological budgets and
the 63 related Node tests pass.

| Item | Bytes | SHA-256 |
| --- | ---: | --- |
| `text/markdown/commonmark.0.31.2.wasm` | 77,469 | `4dc69e5ecc7d46315a3bd20536eaf42238a98b0bad18d30d3c4115116a74f640` |
| `text/markdown/gfm-commonmark.0.31.2.wasm` | 82,779 | `e09a1663aa3f40411f3052f17ab19cb4b732eccc8550a0f0257222118b8cd0ea` |

Wasm bytes after each step (CommonMark / GFM):

| Step | CommonMark | GFM |
| --- | ---: | ---: |
| Start (`533e824d`) | 93,566 | 98,937 |
| Front-coded entity table | 81,826 (−11,740) | 87,199 (−11,738) |
| Heading digit + `writeDecimal` instead of `std.fmt.bufPrint` | 79,328 (−2,498) | 84,709 (−2,490) |
| Type 6 tag names as one sorted string, scanned from the first letter | 78,931 (−397) | 84,345 (−364) |
| One block-start classifier for all block dispatch | 77,507 (−1,424) | 82,817 (−1,528) |
| Entity bucket walk without rebuilding names | 77,469 (−38) | 82,779 (−38) |
| **Total** | **−16,097 (−17.2%)** | **−16,158 (−16.3%)** |
| `qip bench` gzip | 49,710 → 38,744 (−22.1%) | 51,506 → 40,782 (−20.8%) |

| `input.md` | CommonMark before → after | GFM before → after |
| --- | ---: | ---: |
| Executed instructions | 8,232,746 → 7,410,347 (−10.0%) | 10,491,525 → 9,669,288 (−7.8%) |
| Loop iterations (all loops) | 236,182 → 235,998 | 284,310 → 284,126 |
| Calls | 49,406 → 37,926 (−23%) | 55,571 → 44,091 (−21%) |
| Memory reads / writes | 470K / 116K → 432K / 97K | 593K / 124K → 555K / 106K |
| wazero total, mean (min) | 4.638 (4.384) → 4.436 (4.196) ms | 5.733 (5.365) → 5.730 (5.008) ms |
| Node.js/V8 request, mean (min) | 0.173 (0.161) → 0.156 (0.139) ms | 0.218 (0.199) → 0.223 (0.191) ms |

The instruction, call and memory counts are deterministic. The timings are
not: another app was using about two cores during these runs, and the new GFM
build had outliers up to 34 ms (stddev 1.8 ms), so its means are not
comparable; the minimums are the steadier figure there. Both builds were
benchmarked back to back in the same session.

Raw output: [CommonMark trace](qipdb-commonmark-size.txt),
[GFM trace](qipdb-gfm-commonmark-size.txt),
[CommonMark bench](bench-commonmark-size.txt),
[GFM bench](bench-gfm-commonmark-size.txt).

### What changed

- **Entity table.** `tools/generate-markdown-tables.py` now writes the
  component's copy of the 2,125 names front-coded in buckets of 16. Each entry
  is a header byte (shared-prefix length << 3 | value length), the rest of the
  name with bit 7 set on its last byte, then the replacement text: 16,466 bytes
  plus 133 `u16` bucket offsets, instead of 28,720 bytes of blobs and offsets.
  Lookup binary-searches the bucket heads, then walks the bucket by
  shared-prefix length without rebuilding names. The compliance copy stays
  flat. The generator now runs `zig fmt`, so regenerating reproduces the
  checked-in files.
- **Integer formatting.** Heading levels are one digit; ordered-list starts use
  a small `writeDecimal`. Removing `std.fmt` also removed the build's only
  function table and `call_indirect` sites, so `test/qipdb.mjs` now checks the
  table counters on the QR SVG component instead.
- **HTML tag names.** The 62 type 6 names are one space-separated sorted
  string; the scan only compares names with the same first letter and stops
  after them. A `switch` on the first letter with a slice list per letter was
  **285–317 bytes larger** (each slice costs an 8-byte pointer/length pair),
  and a first-letter switch for the four type 1 names was 40 bytes larger, so
  `matchesType1Start` keeps its loop.
- **Block dispatch.** `classifyBlockStart` decides what block a line opens by
  switching on the first byte after the indent, so each line runs at most two
  parsers. `interruptsParagraph`, `canLazyContinue` and
  `leavesLazyParagraphOpen` are built on it, and `renderBlocks`,
  `renderListItemContent`, `collectReferenceDefs`, `renderParagraph`, both
  blockquote renderers, `firstListItemBlockIsCode`, `contentOpensParagraph` and
  `tableBodyCanContinue` all use them in place of their own copies of the
  check chains. The fenced-code opening tag, heading output and trailing-blank
  trimming are shared too. This is also where the drop in calls comes from.

### Costs

- **Entity-heavy input is slower.** On a 163 KB document that is nothing but
  17,000 entity references, V8 takes 1.17 ms against 0.73 ms before (about
  26 ns more per entity). Rebuilding each name, the first version, took
  1.57 ms. Buckets of 8 brought it to 1.09 ms but cost 698 bytes, so the bucket
  size stays 16. `input.md` has too few entities to show this.

### Remaining size opportunities (not done)

- `renderList` and `renderTmpList` (and `listHasSiblingSeparatorBlank`) are
  still near-copies that walk input lines and container text respectively, and
  differ in a few conditions. Merging them needs a shared line-source
  abstraction, and the differing conditions should be checked against cmark
  first, since unifying them changes output.
- Entity values: 1,511 distinct values across 2,125 entries, so deduplicating
  them would save little. The 133 bucket heads could also be front-coded
  against the previous head.
- A `wasm-opt -Oz` post-pass, not yet measured.
- Not recommended: ReleaseFast is 1.6× faster in V8 but only about 1.15× in
  qip's wazero, and costs +62–66% wasm (+24–26% gzip). Forcing
  `leadingIndent` inline gains about 10% for +5.5 KB.

## Newline scan and empty list items (2026-11-17)

Starting from the size work above (`883d22e1`). Two changes in
`text/markdown/lib/commonmark.zig`:

- `indexOfNewline` tests eight bytes per step and replaces the byte-at-a-time
  loops in `splitLines` and `nextTmpLine`.
- `writeListItem` takes back the newline of an `<li>\n` whose content renders
  to nothing, so the `compactEmptyListItems` pass over the whole output is
  gone.

| Item | Bytes | SHA-256 |
| --- | ---: | --- |
| `text/markdown/commonmark.0.31.2.wasm` | 77,116 (−353) | `45b1fef3217cb1104aa1b0e3ba9eb5a0a6adaed96ef8883e1c6f29e89938167e` |
| `text/markdown/gfm-commonmark.0.31.2.wasm` | 82,441 (−338) | `9977cc3ad5014852e52fe0493a2d67647fca365e3f966c2ee502576eb4b71a5e` |

| `input.md` | CommonMark before → after | GFM before → after |
| --- | ---: | ---: |
| Executed instructions | 7,410,347 → 4,991,781 (−32.6%) | 9,669,288 → 7,147,312 (−26.1%) |
| Loop iterations (all loops) | 235,998 → 101,645 | 284,126 → 144,028 |
| Calls | 37,926 → 38,116 | 44,091 → 44,281 |
| wazero total, mean (min) | 4.294 (4.078) → 2.421 (2.316) ms | 5.116 (4.802) → 3.245 (3.143) ms |
| Node.js/V8 request, mean (min) | 0.146 (0.133) → 0.115 (0.105) ms | 0.186 (0.168) → 0.152 (0.138) ms |
| `qip bench` gzip | 38,744 → 38,649 | 40,782 → 40,668 |

Both builds were benchmarked back to back (`--benchtime=3s --node`), with a
load average of about 2. The `input.md` output hashes are unchanged.

Output is no longer byte-identical to the previous build in one situation,
where the removed pass disagreed with cmark 0.31.2. It rewrote every
`<li>\n</li>\n` in the output, wherever it came from:

- Raw HTML containing `<li>\n</li>` was rewritten to `<li></li>`; it is now
  passed through.
- `- &NewLine;` rendered `<li></li>`; it now renders `<li>\n</li>`.

Against the previous build, 129 of 152,318 inputs per component differed
(`differential.mjs` with `<li>`, `</li>` and bare list markers added to its
atoms). Every difference was this pattern, and none moved away from `cmark
--unsafe`: for CommonMark 106 now match cmark exactly and 23 still differ
elsewhere in the document for unrelated, existing reasons. Three such cases are
pinned in `compliance/commonmark-differential-corpus.txt` (now 97 cases). The
CommonMark, GFM, entity, casefold and differential-corpus suites, the
pathological budgets and the Node tests pass.

Raw output: [CommonMark trace](qipdb-commonmark-newline.txt),
[GFM trace](qipdb-gfm-commonmark-newline.txt),
[CommonMark bench](bench-commonmark-newline.txt),
[GFM bench](bench-gfm-commonmark-newline.txt).

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

To compare a change against an earlier build for byte-identical output, copy
the earlier `.wasm` aside first, then:

```sh
node benchmarks/commonmark-gfm-baseline/differential.mjs old.wasm text/markdown/gfm-commonmark.0.31.2.wasm 60000 1 README.md
```

The arguments after the two builds are the number of random inputs, the seed,
and any extra input files.

`profile.mjs` raises the qipdb instruction budget from its 1,000,000 default to
the 100,000,000 maximum. Without that change, qipdb pauses before `render`
finishes.
