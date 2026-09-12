# Empirical Component Optimization

Empirical optimization combines reasoning with observation. First, use the
source and the algorithm to propose a faster design. Then use correctness
checks, elapsed time, execution traces, and artifact sizes to test that design.

This method is useful for coding agents. An agent can quickly identify repeated
work, unnecessary allocation, or a better data structure. It can also optimize
code that the compiler already removed, or reduce an instruction count without
improving execution time. Measurements distinguish a useful change from a
plausible change.

Use this page with [Benchmarking Components](/docs/benchmarking-components),
which defines the benchmark commands and execution boundaries.

## Evidence From Different Tools

No single measurement describes component performance.

| Question | Tool | Evidence | Limit |
| --- | --- | --- | --- |
| Does the component satisfy its contract? | `qip comply`, unit tests, property tests, and fuzzing | Accepted inputs, exact outputs, rejection, and invariants | A test can only check behavior that its oracle or generator defines. |
| Is the component faster? | `qip bench` and `qipx bench` | Elapsed time in wazero and a warmed JavaScript runtime | The result applies to the selected inputs, runtime, and lifecycle. |
| What work ran for this input? | qipdb | Executed instructions, calls, branches, loop iterations, memory reads, and memory writes | qipdb is an interpreter. Its execution time is not production execution time. |
| What does the compiled module contain? | [`wasm-counts.wasm`](/docs/wasm-counts) | Static code, control-flow, memory, data, and instruction counts | Static counts do not identify hot code or predict elapsed time. |
| How much space does it use? | `qip bench` and file compression tools | Raw and compressed Wasm size, declared linear memory, and observed allocation | Declared memory and touched memory are different quantities. |

Use counts to form and test a hypothesis. Use wall-clock measurements to decide
whether the change is faster. A lower branch, loop, or instruction count does
not by itself prove a speed improvement.

## The Empirical Loop

### 1. Define And Check The Behavior

Create an independent Compliance oracle before optimization. Add unit tests for
implementation invariants. Add property tests or fuzzing when the input space
is too large for fixtures.

Do not copy the implementation into its oracle. Derive expected behavior from
a format specification, published examples, a mature implementation, or small
fixtures that are easy to audit.

If legacy behavior is incorrect, define the intended behavior first. The old
component does not need to pass a case that represents an intentional fix.

### 2. Preserve And Measure The Baseline

Build the component once and save its Wasm under another path. Record the
source revision, artifact hash, build command, toolchain, machine, operating
system, and runtime versions.

Choose one canonical input when it represents normal use. Add more inputs only
for materially different paths, such as plain text and replacement-heavy text,
or compressible and incompressible data.

Measure a distribution, not one run. Record output length and hash with raw,
gzip, and Brotli Wasm sizes. Separate instantiation from execution when the
runtime exposes both values.

### 3. Inspect The Baseline And State A Hypothesis

Run the canonical input through qipdb. Inspect the instructions on the hot path,
calls, branches, loop iterations, memory accesses, and output hash. Run
`wasm-counts.wasm` to record the module's static structure.

Use the source and these observations to state one change and its expected
effect. For example:

> Shortcode lookup scans many entries for each match. Binary search should
> reduce comparisons on replacement-heavy input without changing output.

Estimate a reasonable lower bound when one is visible. A transform that must
inspect all input needs at least one full pass over those bytes, although wider
loads can use fewer instructions. A renderer must write its output bytes
somewhere. These bounds guide inspection; they do not predict runtime cost.

### 4. Change The Source

Change one major mechanism at a time when practical. Rebuild the tracked Wasm
from the same build target and compiler settings as the baseline.

Keep experimental artifacts at separate paths. Do not overwrite the only copy
of a useful candidate.

### 5. Check Correctness Before Timing

Run the Compliance oracle and focused tests first. Check the strict Wasm
profile and other component policy that applies. For an optimization that must
preserve output, compare every output byte with the baseline.

Use a semantic comparison when several byte encodings are valid. For example,
decode two valid compressed files and compare the decoded bytes.

### 6. Measure, Inspect, And Repeat

Benchmark the baseline and candidate in one command so the runner can alternate
them. Run benchmarks without builds, tests, or other CPU-heavy work in
parallel. Repeat the trial when the improvement is close to measurement noise.

Run the candidate through qipdb with the same input. Compare its executed path
and output hash. Run `wasm-counts.wasm` again. The observations must support the
hypothesis, but elapsed time decides whether the change improved speed.

Repeat the loop while a new hypothesis has evidence behind it. Stop when gains
fall inside normal run-to-run variation, move cost to another critical input,
or require disproportionate code and Wasm size.

### 7. Keep The Useful Trade-offs

Present only candidates on the useful trade-off boundary. Typical options are:

- the fastest component, with a larger lookup table or more code;
- a compact component that remains faster than the baseline; and
- the baseline, if it is still the smallest or simplest useful option.

Do not create two options by convention. If one candidate is faster, smaller,
and equally correct, it replaces the others.

For each retained option, report:

- exact benchmark inputs and output hashes;
- mean, median, variation, and the measured execution boundary;
- raw, gzip, and Brotli Wasm sizes;
- qipdb dynamic counts;
- `wasm-counts.wasm` static counts;
- linear-memory commitment and observed working memory, when available; and
- correctness coverage and remaining uncertainty.

## A Small Reproducible Run

This example preserves `rgb-to-hex.wasm`, checks its behavior, measures the
same input in wazero and Node.js, and collects static counts:

```sh
make -j \
  qip \
  text/rgb-to-hex.wasm \
  compliance/rgb-to-hex.comply.wasm \
  application/wasm/wasm-counts.wasm \
  components/interactive/qipdb.wasm

cp text/rgb-to-hex.wasm /tmp/rgb-to-hex-before.wasm
printf 'rgb(101, 79, 240)' > /tmp/rgb-input.txt

# Change the source, then rebuild the production artifact.
make -j text/rgb-to-hex.wasm

./qip comply \
  text/rgb-to-hex.wasm \
  --with compliance/rgb-to-hex.comply.wasm

./qip bench \
  -i /tmp/rgb-input.txt \
  --benchtime=3s \
  --node \
  /tmp/rgb-to-hex-before.wasm \
  text/rgb-to-hex.wasm

./qip run \
  -i text/rgb-to-hex.wasm \
  -- application/wasm/wasm-counts.wasm
```

Open the same input in qipdb:

```sh
npx @qip.dev/qipx tui \
  -F component=@text/rgb-to-hex.wasm \
  -F 'input=rgb(101, 79, 240)' \
  components/interactive/qipdb.wasm
```

Press Space to finish execution. Press `i` to expand the counters. The detailed
[`rgb-to-hex` study](/docs/optimizing-rgb-to-hex-with-qipdb) shows how those
observations led to fewer memory accesses and a smaller Wasm module.

The [`autolink-https` study](/docs/optimizing-autolink-https-with-qipdb) shows a
different outcome. The first source rewrite reduced executed instructions but
made wazero slower. qipdb exposed scalar copy loops, and a second build changed
them to `memory.copy` instructions. That build improved correctness, memory,
and elapsed time, but increased compressed Wasm size.

## When Not To Use This Method

Do not optimize a component only because a static count looks high. First show
that its performance affects a real workload.

Do not use qipdb execution time as a production benchmark. Use qipdb to inspect
the executed path, then measure the shipped Wasm in its target runtimes.

Do not compare speed when outputs differ without an agreed semantic comparison.
A faster component that produces incorrect output is a correctness regression,
not an optimization.
