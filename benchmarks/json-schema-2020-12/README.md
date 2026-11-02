# JSON Schema 2020-12: QIP component vs @cfworker/json-schema vs ata-validator

Compares `application/x-tar/json-schema-2020-12-must-be-valid.wasm` (Zig,
ReleaseSmall, 96 KB) with two JavaScript validators on correctness and speed.

```bash
cd benchmarks/json-schema-2020-12
npm install
node suite.mjs          # JSON-Schema-Test-Suite, draft 2020-12 core
node bench.mjs          # timings (about 20 s)
```

## Correctness

All three run the same 1,298 cases from the vendored JSON-Schema-Test-Suite
(`compliance/json-schema-test-suite/`, draft 2020-12, core tests only, no
`optional/`). `suite.mjs` drives them through the Compliance oracle,
`compliance/json-schema-2020-12.comply.wasm`, the same Wasm file that
`make test-comply` runs with `qip comply`. Each library gets a small adapter
that takes the oracle's TAR input and says accept, reject or error.

| Validator | Passed | |
| --- | ---: | ---: |
| QIP (Zig → Wasm) | 1,298 / 1,298 | 100.00% |
| ata-validator 1.62.1 | 1,298 / 1,298 | 100.00% |
| @cfworker/json-schema 4.1.4 | 1,257 / 1,298 | 96.84% |

The 41 cfworker misses are library behavior, not harness setup:

- **format (15):** cfworker always asserts `format`. In 2020-12 it is an
  annotation unless the format-assertion vocabulary is in use, so invalid
  emails, dates and so on must still pass.
- **$dynamicRef (20) and unevaluated* through $dynamicRef (2):** cfworker
  resolves `$dynamicRef` like `$ref` in most of these cases.
- **The rest (4):** a custom meta-schema without the validation vocabulary
  (`vocabulary.json`), `unevaluatedItems` seeing annotations from a bare
  `if`, a `$id`/`$anchor`/`$ref` ordering case and one meta-schema case in
  `defs.json`.

Setup for fairness: cfworker doesn't bundle the 2020-12 meta-schemas, so the
adapter registers them (that alone fixed 3 cases), and runs with
`shortCircuit: true`. ata runs with `useDefaults: false` (otherwise it writes
defaults into the instance) and `assertFormat: false`. npm installed ata's
native accelerator (`@ata-validator/native-darwin-arm64`).

## Speed

Node v26.3.0 on darwin-arm64 (Apple Silicon). Each row runs in a fresh
process: 5 warm-up runs, then the median and fastest of 31. The machine was
under load (load average about 3), and the medians of the same row moved by up
to 2× between runs, so read the fastest column and the rough ratios rather
than the exact values.

| Workload | Validator | Median | Fastest |
| --- | --- | ---: | ---: |
| suite cold (1,298 cases) | QIP (Zig → Wasm) | 6.08 ms | 5.83 ms |
| suite cold (1,298 cases) | @cfworker/json-schema | 132.60 ms | 93.85 ms |
| suite cold (1,298 cases) | ata-validator | 59.48 ms | 54.74 ms |
| suite warm (validate only) | @cfworker/json-schema | 6.30 ms | 5.63 ms |
| suite warm (validate only) | ata-validator | 430 µs | 359 µs |
| large cold (4000 orders, 0.75 MB) | QIP (Zig → Wasm) | 16.12 ms | 13.25 ms |
| large cold (4000 orders, 0.75 MB) | @cfworker/json-schema | 70.83 ms | 59.12 ms |
| large cold (4000 orders, 0.75 MB) | ata-validator | 6.00 ms | 4.58 ms |
| large cold (4000 orders, 0.75 MB) | ata-validator isValid(Buffer) | 5.97 ms | 5.12 ms |
| large warm (validate only) | @cfworker/json-schema | 77.54 ms | 63.00 ms |
| large warm (validate only) | ata-validator | 1.49 ms | 1.41 ms |
| large warm (validate only) | ata-validator isValid(Buffer) | 5.04 ms | 4.56 ms |
| large: JSON.parse alone (reference) | V8 | 3.45 ms | 3.37 ms |

What the rows mean:

- **cold** starts from bytes or JSON text and compiles the schema every time.
  This is the only mode the QIP component has: each render reads the TAR,
  parses both documents, indexes the schema and validates. The JS validators
  pay `JSON.parse`, `new Validator(...)` and one validation.
- **warm** reuses a compiled validator on an already-parsed object. QIP has
  no equivalent because a Content component keeps nothing between renders.
- **large** is one order book document from `orders.mjs`, using `$ref`,
  four patterns, `enum`, `const`, `if`/`then`, `multipleOf: 0.01`,
  `uniqueItems` and `unevaluatedProperties`. All three agree it's valid, and
  that a copy with one bad SKU is invalid.

Takeaways:

- **Many small schemas, each used once:** QIP is about 8–10× faster than
  ata and 13–20× faster than cfworker. ata generates JavaScript for each schema, and compiling
  that is the cost in the cold suite.
- **One big document, one schema:** ata is about 3× faster than QIP in
  this harness. In an
  interleaved in-process run (fastest of 40) QIP took 7.3 ms on this
  document, close to ata's cold time. About 3.5 ms of that is parsing the JSON,
  and regular expressions are about a third of the rest.
- **Reusing a schema:** ata's compiled validator is far ahead (1.5 ms).
  Matching that in QIP would need a different design, such as a component
  that compiles a schema into a smaller program for a second stage.
- cfworker is the slowest in every mode here.

## Why a Compliance oracle helps

Packaging the suite as `compliance/json-schema-2020-12.comply.wasm` paid off
in three ways:

1. **One source of cases for every implementation.** The oracle is a Wasm
   module that declares cases through `must_render_exactly` and
   `must_reject`. `qip comply` binds those to a QIP component, and
   `lib.mjs` binds the same imports to the two JS libraries in about 30
   lines. No library needed its own copy of the suite.
2. **Reject versus trap is checked.** `must_reject` only passes on a clean
   rejection. The component traps on a malformed archive, an unresolvable
   `$ref`, an unsupported regex or an unknown required vocabulary. So a
   broken schema can't pass the suite's invalid cases by failing for the wrong
   reason. The JS adapters report thrown errors the same way.
3. **It runs in `make test-comply`.** `node
   tools/gen-json-schema-2020-12-fixtures.mjs --check` also fails if the
   fixture drifts from the vendored suite.

A per-case TAR built at compile time would have embedded about 4 MB of
512-byte blocks. Instead the oracle embeds the 149 KB flattened fixture and
writes each case's archive into its own buffer at run time. That makes it a
generated oracle rather than a `--straight-line-oracles` one. It still asserts
that it declared exactly the number of cases the fixture's `cases` line
promises.
