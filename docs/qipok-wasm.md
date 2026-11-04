# Checking Compliance In The QIP Interpreter

`qipok.wasm` runs [`qip comply`](/docs/comply) checks inside a QIP Content
component. It accepts an implementation and one or more Compliance oracles as
multipart form data. It runs each oracle and the implementation in the bounded
Zig interpreter that qipdb uses, and returns a plain-text report in the
`qipok` format.

```sh
make -j application/wasm/qipok.wasm

npx qipx run \
  -F component=@text/luhn.wasm \
  -F suite=@compliance/luhn.comply.wasm \
  application/wasm/qipok.wasm
```

```text
PASS luhn.wasm
PASS luhn.wasm --suite luhn.comply.wasm (1603 cases)

pass=2 fail=0 total=2
```

The request supports these multipart fields:

- `component` is required and contains the implementation.
- `suite` is required for behavior checks and can be repeated, up to 32 times.
  Each suite runs against a fresh implementation state.

The report labels each module with its form file name. A failing suite lists up
to five cases, with UTF-8 and hex previews of the input, expected output, and
actual output, as `qip comply` does.

## Uniforms

| Uniform | Default | Meaning |
| --- | --- | --- |
| `seed` | not set | Passed to each oracle's `uniform_set_seed`. A suite without that export fails, as with `qipok --seed`. |
| `instruction_budget` | 100,000,000 | Most instructions for one implementation render, one uniform setter, or the oracle's work between two bridge calls. |

```sh
npx qipx run \
  -F component=@text/currency-format-en-us.wasm \
  -F suite=@compliance/currency-format-en-us.comply.wasm \
  application/wasm/qipok.wasm -u seed=42
```

A Content component must give the same output for the same input, so
`qipok.wasm` does not pick a random seed. Without `seed`, each oracle uses its
own default seed.

## How It Works

The component holds two interpreter machines. The oracle machine holds up to
16 MiB of memory and the implementation machine holds up to 176 MiB.

1. The oracle runs `comply()` until it calls a `qip.*` bridge import. The
   interpreter pauses the oracle there.
2. The component copies the case input into the implementation's input buffer
   and runs `render` on the implementation machine.
3. It compares the result with the case, records any failure, and resumes the
   oracle with the bridge result.

A trap or exhausted budget in the implementation counts as a trap. The
implementation then restarts with fresh memory and globals, as the native
bridge creates a new instance.

## Differences From `qip comply`

- The implementation check covers the Content exports, memory export, and input
  buffer. It does not check the Strict Wasm Profile or the static shape of the
  exported functions.
- An implementation must load in the interpreter. A Wasm feature outside the
  [interpreter's profile](/docs/qip-content-interpreter), or a declared memory
  above 176 MiB, gives a `FAIL` line for the implementation. In this repo,
  `mermaid-to-unicode-html.wasm` and the two BMP and JPEG suite
  implementations fail for these reasons.
- A malformed request is a Content rejection. A failing check is a normal
  report, so test the summary line, not the exit status.

## Performance

These times compare `qipok.wasm` with the native checkers on an Apple M5. Each
value is the median wall time of 10 runs after one warm-up run, in
milliseconds. Each run starts a new process, so the times include startup and
compilation.

| Suite | Cases | `qipok` (Node) | `qipx comply` (Node) | `qipx comply` (Rust) | `qip comply` (Go) | `qipok.wasm` in Rust `qipx run` | `qipok.wasm` in Node `qipx run` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| preserve-empty | 1 | 26 | 29 | 3 | 5 | 35 | 31 |
| cve | 756 | 28 | 30 | 5 | 5 | 42 | 43 |
| luhn | 1,603 | 30 | 32 | 5 | 6 | 62 | 57 |
| commonmark-spec-0.31.2 | 655 | 34 | 36 | 51 | 42 | 145 | 121 |
| html5-entities | 2,143 | 35 | 36 | 49 | 43 | 193 | 160 |
| json-schema-2020-12 | 1,298 | 37 | 38 | 49 | 40 | 415 | 332 |
| currency-format-en-us (seed 42) | 8,736 | 43 | 43 | 25 | 548 | 229 | 183 |

Node `qipx comply` and `qipok` run the same checks in Node, and
`test/qipx-parity.mjs` keeps them in step. Their times are within 1 to 3 ms of
each other, probably because `qipx` is a larger module to load.

`qipok.wasm` has a fixed cost of about 30 ms, mostly for its 239 MiB of memory.
In total, it takes 3.6 to 11 times as long as the fastest native checker for
each suite. Use `qipok`, either `qipx comply`, or `qip comply` for normal checks.
Use `qipok.wasm` when the check must run inside a QIP host or pipeline, or when
you want to test the interpreter against real suites.
