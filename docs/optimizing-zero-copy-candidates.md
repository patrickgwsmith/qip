# Optimizing Two Zero-Copy Candidates

`wasm-counts` found two components with `memory_copies=0` and large scalar
copy loops. qipdb then confirmed that those loops ran for representative
inputs. Replacing the loops with a guarded `memory.copy` path made both
components faster.

`memory_copies=0` is only a search filter. A validator or encoder can have no
bytes that are safe to copy as one block. Inspect the source and an executed
path before you change it.

## Unicode NFC Normalization

The old `unicode-17-normalize-nfc.wasm` decoded, decomposed, reordered,
composed, and encoded every ASCII byte. An 8,439-byte Markdown file did not
finish within qipdb's 10-million-instruction budget.

The new path scans for a byte with its high bit set. If there is none, the
input is valid UTF-8 and is already in NFC. One `memory.copy` writes the
output. qipdb now completes the same input in 143,505 instructions. It records
8,440 memory reads and one memory write instruction. The one write is a block
copy, not a one-byte write.

The optimization also exposed correctness defects. The old component omitted
1,035 canonical singleton decompositions. It also failed to compose some
Unicode 17 pairs when the second code point had canonical combining class
zero. The old artifact failed 2,477 of the 100,170 NFC relationships in the
Unicode 17.0.0 normalization test suite.

The corrected component passes all 100,170 relationships. Its Compliance
oracle adds 24 small, portable cases. A Node.js test adds 810 deterministic
sequences, maximum-size ASCII input, and malformed UTF-8 cases. The generated
singleton table comes from the pinned `UnicodeData.txt` file in this
repository.

NFC composition cannot increase the decomposed code-point count. The component
now composes in place and removes its second scratch array. This reduces fixed
linear memory from 22.1 MiB to 14.1 MiB.

For the 8,439-byte ASCII fixture, 100 alternating runs gave these measurements:

| Measurement | Old artifact | New artifact | Change |
| --- | ---: | ---: | ---: |
| wazero total | 7.154 ms | 0.285 ms | 25.1× faster |
| wazero render | 6.779 ms | 0.149 ms | 45.5× faster |
| V8 render | 207.2 µs | 4.16 µs | 49.9× faster |
| Fixed linear memory | 22.1 MiB | 14.1 MiB | -8 MiB |
| Raw Wasm | 35,191 B | 39,504 B | +4,313 B |
| gzip Wasm | 15,164 B | 18,344 B | +3,180 B |

The larger module contains the missing Unicode mappings. That size increase is
the cost of correct Unicode 17 NFC behavior, not the ASCII fast path alone.
The fast path added 67 raw bytes to the corrected build.

A 5,684-byte page with non-ASCII text selects the general Unicode path. Its V8
render time stayed near 216 µs in one 200-run comparison. The new wazero total
was 4% slower in that run. The exact ratio varies, but the conformance fix and
8 MiB memory reduction apply to every runtime.

## CSS Data URI Wrapping

`data-uri-to-css-url.wasm` scans its input once to calculate escaped output
size. The old component then copied every byte backwards, even when no byte
needed escaping.

The new component uses `memory.copy` when the first scan finds no escaped
bytes. It keeps the scalar backwards loop for quotes, backslashes, control
bytes, and other escaped input. Marking the small escape predicate as `inline`
also removes one call for each scanned byte.

For a 20,477-byte clean data URI, qipdb reports:

| qipdb counter | Before | After | Change |
| --- | ---: | ---: | ---: |
| Executed instructions | 2,396,027 | 962,648 | -60% |
| Function calls | 40,954 | 0 | -100% |
| Branches taken | 61,439 | 40,962 | -33% |
| Copy-loop iterations | 20,477 | 0 | -100% |
| `memory.copy` sites used | 0 | 1 | +1 |

Ten thousand alternating runs measured the same input and output:

| Measurement | Before | After | Change |
| --- | ---: | ---: | ---: |
| wazero total | 809.5 µs | 389.5 µs | 2.08× faster |
| wazero render | 778.8 µs | 359.5 µs | 2.17× faster |
| V8 render | 38.34 µs | 15.48 µs | 2.48× faster |
| Raw Wasm | 918 B | 1,017 B | +99 B |
| gzip Wasm | 594 B | 624 B | +30 B |
| Fixed linear memory | 64 KiB | 64 KiB | No change |

The existing 12-case Compliance oracle and JavaScript oracle still pass. The
tests cover escaped input, invalid data URIs, maximum expansion, and a
maximum-size clean input.

## Reproduce The Checks

Build the components and oracles:

```sh
make -j \
  text/unicode-17-normalize-nfc.wasm \
  compliance/unicode-17-normalize-nfc.comply.wasm \
  text/uri-list/data-uri-to-css-url.wasm \
  compliance/data-uri-to-css-url.comply.wasm

./qip comply \
  text/unicode-17-normalize-nfc.wasm \
  --with compliance/unicode-17-normalize-nfc.comply.wasm

./qip comply \
  text/uri-list/data-uri-to-css-url.wasm \
  --with compliance/data-uri-to-css-url.comply.wasm
```

Download the published Unicode suite and run every NFC relationship:

```sh
curl -L \
  https://www.unicode.org/Public/17.0.0/ucd/NormalizationTest.txt \
  -o /tmp/NormalizationTest-17.0.0.txt

node tools/check-unicode-nfc.mjs \
  /tmp/NormalizationTest-17.0.0.txt \
  text/unicode-17-normalize-nfc.wasm
```

The downloaded file used for this study has SHA-256
`5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db`.

Use the exact fixtures and run counts shown above only to reproduce these
numbers. Choose inputs from your own workload before you use either speedup as
a capacity estimate.
