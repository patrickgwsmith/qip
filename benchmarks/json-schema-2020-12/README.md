# JSON Schema 2020-12: QIP components vs @cfworker/json-schema vs ata-validator

Compares two QIP paths with two JavaScript validators on correctness and
speed:

- `application/json/json-schema-2020-12-must-be-valid.wasm` (Zig,
  ReleaseSmall, 58 KB) validates an envelope of schema and instance in one
  render.
- `application/json/json-schema-to-wasm.wasm` compiles a schema once into its
  own validator component (about 22 KB plus the schema), which then takes bare
  instances. See [Compiled schemas](#compiled-schemas-json-schema-to-wasm).

The component takes one JSON envelope and outputs the instance's bytes when it
conforms:

```json
{"schemas": {"https://example.com/a.json": {…}}, "schema": {…}, "instance": …}
```

`"schemas"` is optional and preloads remote `$ref` documents by URI, as ata's
`schemas` option and cfworker's `addSchema` do. Keys may come in any order.

```bash
cd benchmarks/json-schema-2020-12
npm install
node suite.mjs          # JSON-Schema-Test-Suite, draft 2020-12 core
node bench.mjs          # timings (about 20 s)
```

## Correctness

All four run the same 1,298 cases from the vendored JSON-Schema-Test-Suite
(`compliance/json-schema-test-suite/`, draft 2020-12, core tests only, no
`optional/`). `suite.mjs` drives them through the Compliance oracle,
`compliance/json-schema-2020-12.comply.wasm`, the same Wasm file that
`make test-comply` runs with `qip comply`. Each library gets a small adapter
that takes the oracle's envelope input and says accept, reject or error. The
compiled adapter splits the envelope, compiles its schema (once per distinct
schema) and runs the instance through the generated module.

| Validator | Passed | |
| --- | ---: | ---: |
| QIP (Zig → Wasm) | 1,298 / 1,298 | 100.00% |
| QIP compiled (json-schema-to-wasm) | 1,298 / 1,298 | 100.00% |
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
process: 5 warm-up runs, then the median and fastest of 31. Load average was
about 1.8. Earlier runs under heavier load were up to 3× slower across the
board, so read the ratios rather than the exact values.

| Workload | Validator | Median | Fastest |
| --- | --- | ---: | ---: |
| suite cold (1,298 cases) | QIP (Zig → Wasm) | 1.85 ms | 1.77 ms |
| suite cold (1,298 cases) | @cfworker/json-schema | 39.61 ms | 39.16 ms |
| suite cold (1,298 cases) | ata-validator | 21.05 ms | 19.77 ms |
| suite warm (validate only) | @cfworker/json-schema | 2.23 ms | 2.02 ms |
| suite warm (validate only) | ata-validator | 157 µs | 133 µs |
| suite warm (validate only) | QIP compiled, bytes in | 709 µs | 647 µs |
| large cold (4000 orders, 0.75 MB) | QIP (Zig → Wasm) | 6.27 ms | 6.18 ms |
| large cold (4000 orders, 0.75 MB) | @cfworker/json-schema | 25.25 ms | 24.54 ms |
| large cold (4000 orders, 0.75 MB) | ata-validator | 2.16 ms | 2.03 ms |
| large cold (4000 orders, 0.75 MB) | ata-validator isValid(Buffer) | 2.35 ms | 2.08 ms |
| large warm (validate only) | @cfworker/json-schema | 23.36 ms | 22.58 ms |
| large warm (validate only) | ata-validator | 558 µs | 520 µs |
| large warm (validate only) | ata-validator isValid(Buffer) | 2.23 ms | 2.03 ms |
| large warm (validate only) | QIP compiled, bytes in | 2.00 ms | 1.96 ms |
| compile the order schema | QIP json-schema-to-wasm + instantiate | 109 µs | 81 µs |
| large: JSON.parse alone (reference) | V8 | 1.55 ms | 1.50 ms |

What the rows mean:

- **cold** starts from bytes or JSON text and compiles the schema every time.
  This is the only mode the QIP component has: each render parses the
  envelope, indexes the schema and validates. The JS validators
  pay `JSON.parse`, `new Validator(...)` and one validation.
- **warm** reuses a compiled validator. The JS validators get an
  already-parsed object, except ata's `isValid(Buffer)`, which parses bytes.
  The QIP compiled module always gets bytes, so it parses the instance in
  every render; compiling the schema happened once, outside the timing.
- **large** is one order book document from `orders.mjs`, using `$ref`,
  four patterns, `enum`, `const`, `if`/`then`, `multipleOf: 0.01`,
  `uniqueItems` and `unevaluatedProperties`. All three agree it's valid, and
  that a copy with one bad SKU is invalid.

Takeaways:

- **Many small schemas, each used once:** QIP is about 11× faster than ata
  and 22× faster than cfworker. ata generates JavaScript for each schema, and
  compiling that is the cost in the cold suite.
- **One big document, one schema, compiled each time:** ata is about 3×
  faster than the one-render QIP component. Parsing
  the JSON is only about 1.4 ms of QIP's 6.2 ms (see the schema `true` row
  below); validation is the rest, and regular expressions are about a third
  of it.
- **Reusing a schema:** compiled with `json-schema-to-wasm`, QIP validates
  the large document from bytes in 1.96 ms. That's level with ata's bytes API
  (2.03 ms) and with `JSON.parse` followed by ata's validation (about 2.0 ms). ata on an
  already-parsed object is still about 3.8× faster (0.52 ms), and on the
  suite's tiny instances (133 µs against 647 µs), where QIP's cost is mostly
  copying each instance into Wasm memory and calling render.
- cfworker is the slowest in every mode here.

## Compiled schemas: json-schema-to-wasm

```bash
printf '{"schema": {"type": "array", "items": {"type": "integer"}}}' \
  | qip run -o ints.wasm application/json/json-schema-to-wasm.wasm
printf '[1, 2, 3]' | qip run ints.wasm      # accepted: prints [1, 2, 3]
```

The compiler takes the validator's envelope without `"instance"`. Ahead of
time it parses and indexes every document, resolves each `$ref` and anchor
to a node, decides which `$dynamicRef`s are dynamic, keeps only the keywords
of active vocabularies, turns `type` into a bit mask, `minLength`-style
numbers into integer bounds, `const` and `enum` into value tapes, and checks
every keyword value and regular expression. A schema it can't compile is
rejected at that point, so a broken keyword is found before any instance
reaches it.

The output is `application/json/lib/json-schema-runtime.wasm`, a fixed
evaluator, with the compiled program added as one more data segment and the
input kept in a `qip.json-schema` custom section. The generated module for
the order schema is 31.3 KB. Code isn't specialized per schema yet: each
module carries the same evaluator, and the schema is data. Patterns are
compiled by json-schema-to-wasm too, with `\p{Letter}` expanded into class
ranges, so the runtime carries no regex parser or Unicode table. That took the
runtime from 37 KB to 21 KB with no change in speed.

Each render parses the instance into a flat token tape instead of a tree,
with no allocation per value, and each container records where it ends.
Then the evaluator walks the program over the tape. Patterns run on a lazy
DFA built over the Pike VM's thread sets, with patterns using `\b`/`\B`
left on the Pike VM.

Where the 1.96 ms goes on the large document, measured by removing one
keyword at a time from the order schema (fastest of 31, one process):

| Schema | Time | Difference |
| --- | ---: | ---: |
| `true` (copy in + parse only) | 0.61 ms | |
| order schema | 1.95 ms | |
| … without `pattern` | 1.66 ms | patterns 0.29 ms |
| … and without `unevaluatedProperties` | 1.57 ms | 0.09 ms |
| … and without the `allOf`/`if`/`then` | 1.47 ms | 0.10 ms |
| … and without `multipleOf` | 1.40 ms | 0.07 ms |

The steps from the first working compiled version (4.9 ms) to 1.96 ms:

| Change | Large document |
| --- | ---: |
| first version: tape parser, compiled program, Pike VM | 4.87 ms |
| lazy DFA for patterns | 3.35 ms |
| schema numbers pre-parsed as scaled integers; `required` answered from the `properties` pass; no dynamic scope without dynamic anchors | 2.77 ms |
| strings scanned 8 bytes at a time (SWAR); `$ref`-only nodes followed without a full visit | 2.15 ms |
| `$` acceptance cached per DFA state; equal-scale numbers compared directly | 1.96 ms |

`properties` keys are sorted by length then bytes at compile time. Lists
of more than 16 keys are binary searched; shorter ones are scanned as
before, because binary search measured 5–9% slower on them. On arrays of
2,000 objects that each carry every property (old scan vs new, fastest
of 41, alternating rounds, two runs):

| Properties | Before | After |
| ---: | ---: | ---: |
| 4, 8, 16 | 0.23, 0.44, 0.93 ms | no change (within ±4%) |
| 32 | 2.23 ms | 2.07 ms (−7 to −9%) |
| 64 | 6.07 ms | 4.33 ms (−28 to −29%) |

The order document, whose objects have 2–5 properties, is unchanged.

Each entry then also stores its key's first four bytes as a big-endian
word, so length and prefix settle most comparisons without reading the key,
and keys of four bytes or fewer never read it at all. Lists of more than 16
keys also get a hash table built at compile time from each key's length and
first and last four bytes: the compiler tries seeds until no two keys share
a slot, and keeps binary search only when no seed separates them. Against
the binary-search build above (fastest of 41, two runs), with instance keys
in one fixed order or shuffled per object:

| Properties | Before | After |
| ---: | ---: | ---: |
| 4, 8, 16 | 0.23, 0.45, 0.92 ms | no change (within ±4%) |
| 8, shuffled | 0.61 ms | 0.58 ms (−4 to −7%) |
| 32 | 2.08 ms | 1.83 ms (−11 to −14%) |
| 64 | 4.37 ms | 3.87 ms (−11 to −12%) |
| 64, shuffled | 5.87 ms | 4.57 ms (−20 to −24%) |

Using the table for every list size made the order document about 5%
slower, since hashing a key costs more than scanning 2–5 entries, so short
lists are still scanned. Remembering which entry matched at each position
of the previous object was 25% faster at 64 properties when every object
lists its keys in the same order, but about 10% slower on small objects
with shuffled keys, so it was left out.

The four-byte prefix then became a single tag word: the key's length
(capped at 255) in the top byte and its first three bytes below it. One
compare settles nearly every pair, keys of up to three bytes are decided by
the tag alone, and only keys of 255 bytes or more need the stored length as
a tiebreak. The table hash became one multiply and shift over the tag mixed
with the last four bytes, with the compiler trying multipliers instead of
seeds. Against the previous build (fastest of 41, alternating rounds):

| Properties | Before | After |
| ---: | ---: | ---: |
| 4 | 0.23 ms | 0.22 ms (−4 to −5%) |
| 16 | 0.90 ms | 0.85 ms (−5 to −7%) |
| 8, 32, 64, shuffled | | no change (within ±3%) |
| Order document, suite | 1.94, 0.66 ms | no change |

Using the cheaper hash for every list of 2, 5 or 9 keys and up measured the
same as scanning, within noise, so the table still starts at 17 keys. Key
lookup is no longer a measurable share of the time, so it was left there.
Mixing the tag into the old seeded hash with no other change made 64 keys
10–20% slower, from a worse table for that key set, which is part of why the
hash changed too.

The hash tables were then removed. Lists of more than 16 keys now
binary-search the tag words alone, then scan the entries that share the
tag, so they need no data beyond the sorted entries. A first version that
compared the whole key at each step of the search was 6–8% slower than the
table at 64 keys and 15–17% slower with shuffled keys; comparing only the tag
closed most of that. Against the table build (fastest of 41, two runs):

| Workload | Table | Binary search |
| ---: | ---: | ---: |
| 4, 8, 16, 32 properties | 0.22–1.87 ms | no change (within ±4%) |
| 64 | 3.88 ms | no change (−1 to +1%) |
| 64, shuffled | 4.53 ms | 4.72 ms (+4%) |
| Order document, suite | 1.89, 0.67 ms | no change |

| Size (bytes) | Table | Binary search |
| ---: | ---: | ---: |
| Runtime | 22,084 | 21,719 |
| Order schema module | 31,892 | 31,295 |
| 16 / 32 / 64 property module | 26,633 / 31,071 / 40,238 | 26,132 / 30,182 / 38,324 |

The saving comes from the table code, the table slots (4 bytes per slot,
two slots or more per key) and one fewer List on every node.

The runtime is ReleaseSmall (22 KB). When it was 37 KB, ReleaseFast was only
about 8% faster at about 68 KB, and `simd128` made no difference, so it stays small.

What's left: parsing is about 0.6 ms, already faster than `JSON.parse` on
the same bytes. Evaluation is about 1.3 ms, roughly 10 ns per keyword visit.
Getting closer to ata's 0.52 ms would need code generated per schema, so
that each node's checks are straight-line Wasm instead of a walk over node
records.

## Input format: why a JSON envelope, not TAR

The component first took a TAR (`schema.json`, `instance.json` and
`schemas/<scheme>/<rest>` per remote, at commit `2302b32d`). Before
switching, a benchmark built an envelope variant from the same validation
code and ran both on the suite, converted case by case, and on the large
document. The envelope variant passed all 1,298 cases, and the switch made the
component 58 KB instead of 60 KB.

Both formats run in one process with alternating rounds; fastest of 41, two
runs agreed within 3%:

| Workload | TAR | Envelope | Envelope / TAR | Input bytes |
| --- | ---: | ---: | ---: | ---: |
| suite (1,298 cases), render only | 2.47 ms | 1.77 ms | 0.71× | 4,048,384 → 234,162 |
| suite, host builds input + render | 10.36 ms | 2.12 ms | 0.21× | |
| suite, host builds input only | 7.87 ms | 286 µs | 0.04× | |
| large (0.75 MB), order schema | 6.31 ms | 6.26 ms | 0.99× | 750,592 → 748,466 |
| large (0.75 MB), schema `true` (framing + parsing) | 1.43 ms | 1.43 ms | 1.00× | |
| large (0.75 MB), host builds input only | 61 µs | 29 µs | 0.47× | |

- **Small inputs:** the envelope is about 30% faster inside the component.
  Copying the extra bytes costs only 0.05 ms; most of the 0.7 ms is the TAR
  reader itself (header checksums, the zero end blocks, remote paths turned
  back into URIs). Each case's TAR is 17× bigger, mostly 512-byte padding.
- **Building the input:** the envelope is string concatenation of JSON text
  the host already has. Writing a TAR in JS took 25× longer, though that
  writer was simple and a faster one would have narrowed the gap.
- **Large documents:** no difference. Parsing and validation dominate.
- **Parsing is smaller than estimated:** with schema `true`, reading and
  parsing the 0.75 MB document takes 1.43 ms. Validation is the other ~4.9 ms
  of the 6.3 ms, so a schema-specialized compiler has more room than parsing
  alone suggested.

## Why a Compliance oracle helps

Packaging the suite as `compliance/json-schema-2020-12.comply.wasm` paid off
in three ways:

1. **One source of cases for every implementation.** The oracle is a Wasm
   module that declares cases through `must_render_exactly` and
   `must_reject`. `qip comply` binds those to a QIP component, and
   `lib.mjs` binds the same imports to the two JS libraries in about 30
   lines. No library needed its own copy of the suite.
2. **Reject versus trap is checked.** `must_reject` only passes on a clean
   rejection. The component traps on a malformed envelope, an unresolvable
   `$ref`, an unsupported regex or an unknown required vocabulary. So a
   broken schema can't pass the suite's invalid cases by failing for the wrong
   reason. The JS adapters report thrown errors the same way.
3. **It runs in `make test-comply`.** `node
   tools/gen-json-schema-2020-12-fixtures.mjs --check` also fails if the
   fixture drifts from the vendored suite.

The oracle embeds the 149 KB flattened fixture and joins each case's envelope
into its own buffer at run time, with `"instance"` last. That makes it a
generated oracle rather than a `--straight-line-oracles` one. It still asserts
that it declared exactly the number of cases the fixture's `cases` line
promises.
