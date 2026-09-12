# Benchmarking Components

Start with `qip bench`. It measures a component through the same wazero execution
path as `qip run`, checks the output on every measured run, and makes
before-and-after comparisons difficult to accidentally invalidate. Use `qipx
bench` for warmed Node.js/V8 measurements. Add a small Node.js harness when a
browser lifecycle or component-specific telemetry is part of the measurement.

Benchmarking is not a substitute for a correctness test. Keep a deterministic
test fixture and expected output first; then time the exact artifact that passed
that test.

See [Empirical Component Optimization](/docs/empirical-optimization) for the
full correctness, inspection, hypothesis, measurement, and iteration loop.

## The Default: `qip bench`

Build once, then run the benchmark without another build or test process in
parallel:

```sh
make -j text/markdown/commonmark.0.31.2.wasm

./qip bench \
  -i README.md \
  --benchtime=3s \
  text/markdown/commonmark.0.31.2.wasm
```

`qip bench` compiles the module once and creates a fresh instance for each
sample. Its report includes:

- mean, standard deviation, minimum, p95, and maximum total time;
- mean execution and instantiation time, plus one compile measurement;
- mean and peak allocated WebAssembly linear memory;
- input and output capacities;
- raw and gzip-compressed module size; and
- output length and SHA-256.

The total time is the best first number for a normal Content component because
QIP hosts do not promise that instances will be reused. The execution breakdown
helps distinguish a slow algorithm from a large module that is expensive to
instantiate.

For a component that accepts `multipart/form-data`, repeat `-F` or `--form` as
you would with `qip run`. QIP constructs the same canonical multipart bytes for
every sample:

```sh
./qip bench \
  -F component=@text/hello.wasm \
  -r 100 \
  components/interactive/qipdb.wasm
```

Use `-F name=value` for a text field, `-F name=@path` for file bytes, or
`-F name=@-` for one file field read from standard input. `-F` and `-i` are
mutually exclusive.

## Compare A Reused Instance In Node.js

Pass `--node` to add an opt-in V8 measurement for Content components:

```sh
./qip bench \
  -i README.md \
  --benchtime=3s \
  --node \
  text/markdown/commonmark.0.31.2.wasm
```

Node.js is required only when the flag is present. QIP finds `node` on `PATH`,
starts one child process without a shell, and sends the already-validated Wasm
bytes and input through a pipe. It does not create a temporary script, copy the
component to another file, or maintain a compiled-artifact cache.

The Node process compiles and instantiates each module once, performs one
unmeasured correctness render, then reuses that instance for every measured
request. With `-r`, Node runs the requested number of samples. With
`--benchtime`, wazero first determines how many samples meet the duration
target and Node runs that same count. Multiple candidate modules are alternated
inside the process. Every repeated Node output must match its first output, and
the final output must match the wazero baseline byte for byte.

Read the two reports as different lifecycle boundaries:

- The normal wazero total creates and closes a fresh instance for each sample.
- The Node total copies input, calls `render`, and copies output on one reused
  instance. Compilation and the one instantiation are reported separately.

The displayed ratio retains those labels because it is not an engine-only
speedup. It answers how a warmed V8 host compares with QIP's default
fresh-instance boundary. Node's memory line is allocated WebAssembly linear
memory, not process RSS.

If Node.js is already your target runtime, use `qipx bench` directly:

```sh
NODE_OPTIONS=--expose-gc npx @qip.dev/qipx bench \
  -i README.md \
  --benchtime=3s \
  /tmp/commonmark-before.wasm \
  text/markdown/commonmark.0.31.2.wasm
```

`qipx bench` validates and compiles each Content component once, creates one
instance, then warms and measures each component in input order. It uses 10
warmup renders by default and measures the same reused instance boundary as the
`render()` JavaScript API. Every warmup and measured render must match the first
candidate's output type and bytes. Its report adds p50, renders per second,
input throughput, runtime and CPU identification, and relative time. Use
`--warmup <n>` to change warmup work. Use `-r <n>` when you need an exact render
count instead of the default three-second measured target.

`qipx bench` also accepts repeatable `-F` or `--form` fields instead of `-i`.
It constructs the same canonical multipart bytes as `qipx run` and Go
`qip bench`, including support for one `-F name=@-` field read from standard
input. Multipart form input and `-i` are mutually exclusive.

Input throughput is external input bytes divided by mean end-to-end render time.
It includes uniform setters and input and output copies; it is not Wasm memory
bandwidth. Empty input is reported as `Input empty` because no meaningful byte
rate exists.

The example opts into manual GC with `--expose-gc` and uses `NODE_OPTIONS` so
the normal `npx` command still works. When the flag is present, `qipx` collects
after each component's warmup and before measuring that component. Without the
flag, the runtime manages collection normally. `qipx` does not collect before
each measured render, so measured-phase GC pauses remain part of sustained
throughput.

Run the same benchmark under Bun to compare JavaScriptCore's WebAssembly
implementation. Use `bunx --bun` to override the package's Node shebang.
`BUN_OPTIONS` passes the GC opt-in to the spawned Bun process:

```sh
BUN_OPTIONS=--expose-gc bunx --bun @qip.dev/qipx bench \
  -i README.md \
  --benchtime=3s \
  /tmp/commonmark-before.wasm \
  /tmp/commonmark-after.wasm
```

The report identifies Bun and JavaScriptCore instead of Bun's Node-compatible
`process.versions.node` and `process.versions.v8` values. Compare runtimes only
when the input, components, output, host, and command options are the same.

Synchronous WebAssembly blocks the Node thread, so a JavaScript timer cannot
interrupt a render. `qipx bench` does not offer a per-render timeout. Use only
admitted components and stop the process if an unexpected render does not
return.

`--node` currently supports the Content contract, not Tile or Interactive
components. Synchronous V8 execution cannot receive a JavaScript timer while a
render is running, so QIP supervises the Node process with an aggregate
deadline rather than claiming an exact per-render Node timeout. The normal
wazero samples still enforce `--timeout-ms` individually.

Prefer `--benchtime` for quick components. It gathers as many samples as fit in
the requested measured time:

```sh
./qip bench -i input.bin --benchtime=5s component.wasm
```

Use a fixed run count for slow inputs, and raise the per-run timeout explicitly:

```sh
./qip bench \
  -i fixtures/25mp-lossless.jp2 \
  -r 3 \
  --timeout-ms 30000 \
  image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm
```

The timeout protects each sample; it is not the benchmark duration.

## Compare Variants In One Command

Before changing the implementation, copy the built artifact to a separate path.
Then pass that baseline first and one or more candidates after it:

```sh
cp text/markdown/commonmark.0.31.2.wasm \
  /tmp/commonmark-before.wasm

# Make the source change and rebuild the production target.
make -j text/markdown/commonmark.0.31.2.wasm

./qip bench \
  -i README.md \
  --benchtime=3s \
  /tmp/commonmark-before.wasm \
  text/markdown/commonmark.0.31.2.wasm
```

QIP alternates the order in which it runs the modules. It also requires every
output byte from every sample to match the first module. The final comparison
reports relative speed and the variant with the lowest peak linear memory.

Keep the old artifact at a separate path. Rebuilding the same target and relying
on remembered numbers loses both the executable baseline and the strongest
correctness check.

Byte equality is deliberately strict. It works well for parsers, transforms,
lossless codecs, and optimizations that should not change pixels. It is not the
right equivalence rule when multiple encodings are valid, such as two DEFLATE
streams that decompress to the same bytes. Benchmark those variants separately,
then test semantic equivalence by decoding their outputs.

## Choose Inputs Before Optimizing

One friendly fixture rarely represents a component. Choose a small input matrix
that exercises the work the algorithm actually performs:

- tiny, typical, and near-limit sizes;
- compressible and incompressible bytes for codecs;
- opaque and alpha-bearing images;
- shallow and deeply nested structured data; and
- any format feature that selects a separate hot path.

Keep malformed-input and limit tests in the test suite. Do not mix them into
throughput numbers unless you intend to measure rejection latency.

Record fixture names and hashes when the bytes are not obvious from the
repository. A benchmark without its input is not reproducible.

## When To Write A Node.js Harness

Start with `qip bench --node` or `qipx bench` for an ordinary Content transform.
Write a separate Node harness when the browser/V8 host needs a different
execution boundary or component-specific behavior. Common cases are:

- measuring a reused instance after V8 has warmed and optimized it;
- driving interactive events or a particular renderer state;
- timing one exported kernel rather than a complete Content invocation;
- reading component-specific counters such as allocator peak usage; and
- comparing scalar and SIMD behavior in the engine users will run.

Keep the harness small and checked in under `tools/` when other developers will
repeat the measurement. A benchmark script should:

1. Load the same `.wasm` artifact shipped by the project.
2. Validate required exports and copy the fixture into Wasm memory.
3. Run unmeasured warmup iterations when measuring a reused instance.
4. State whether the number covers compilation, instantiation, one export, or
   the full pipeline, then time exactly that boundary.
5. Collect many samples and report at least mean, p50, p95, and maximum.
6. Hash or otherwise validate the output outside the timed region.

`tools/bench-qip-play.mjs` is the repository example for warmed interactive
rendering:

```sh
node tools/bench-qip-play.mjs \
  components/interactive/dock-magnification.wasm
```

Do not turn a Node test into a timing assertion. Use `node --test` to instantiate
a module, exercise its ABI, check output hashes, and read
telemetry. Wall-clock thresholds in a correctness suite are noisy across CI
machines and tend to fail without identifying a regression. Put repeatable
timing in a benchmark script and keep pass/fail assertions about correctness.

## Compare With A Native Reference

For a common algorithm, also measure a mature native implementation when one is
available: a standard library, an installed CLI, or the upstream library's own
tool. Each comparison supplies different evidence:

- QIP variant comparisons tell you whether your change helped.
- A native reference estimates the remaining performance gap.
- Cross-engine Node and wazero results show whether a speedup or slowdown
  changes with the runtime.

Match boundaries before comparing numbers. If `qip bench` includes
instantiation and output copying, a native command that times only its inner
codec loop is not an equivalent end-to-end measurement. Either align the
boundaries or label the difference plainly.

For a component whose source exposes the direct-native benchmark adapter, run
the complete source, generated-C, wasm2c, V8, and wazero matrix with:

```sh
tools/bench-qip-component-to-c-source.sh \
  --input README.md \
  text/markdown/commonmark.0.31.2.zig
```

See [QIP Component-to-C Runtime Benchmarks](/docs/qip-component-to-c-benchmarks#reproducing) for
the adapter contract and the table's lifecycle boundaries.

To measure source emitted by the Zig backend, compile the generated module with
the reusable native harness. The timed region copies input, calls `render`, and
copies output, matching the warmed generated-C boundary:

```sh
./qip run \
  -i text/markdown/commonmark.0.31.2.wasm \
  -o /tmp/commonmark-qip.zig \
  application/wasm/qip-component-to-zig.wasm
zig build-exe -O ReleaseFast \
  --dep component \
  -Mroot=tools/bench-content-generated-zig.zig \
  -Mcomponent=/tmp/commonmark-qip.zig \
  -femit-bin=/tmp/commonmark-qip
/tmp/commonmark-qip README.md 2000
```

For a pipeline of Content components, use the recipe variant:

```sh
tools/bench-qip-component-to-c-recipe.sh \
  --input qip-logo.svg \
  image/svg+xml/svg-recolor-current-color.wasm \
  image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm \
  image/bmp/bmp-to-png.wasm
```

It first delegates content-type and encoding validation to `qip dry run`, then
uses `qip run` to produce the canonical output. QIP-generated C with shared and
dedicated workspaces, wasm2c, Node/V8, and warmed wazero must reproduce those
bytes. The table reports whole-recipe time, RSS checkpoints, linear-memory
commitments, and executable or Wasm payload sizes.

This generic comparison does not produce an expertly integrated native row.
Such a row needs a recipe-specific adapter that configures every native library
and gives it equivalent ownership and reuse rules. Keep that adapter beside
the fixture when studying a particular codec pipeline; otherwise the generic
script would hide exactly the per-library integration work the comparison is
intended to measure.

The initial recipe driver accepts ordinary Content module paths without uniform
arguments. A future recipe description can add typed uniforms without relying
on shell-specific query-string parsing.

For image and codec work, compare decoded bytes as well as timing. In the JPEG
2000 component work, the QIP output was checked pixel-for-pixel against FFmpeg
before its runtime was compared with FFmpeg. Compare speed only if the decoded
images match pixel for pixel. Otherwise, you are making incorrect output
faster. Flawless first, then fast.

## Memory Needs Two Measurements

`qip bench` reports allocated WebAssembly linear memory. For a fixed-memory
component, that may be the full declared memory even if the algorithm touches
much less of it.

If a vendored library uses an arena, export counters such as peak live bytes,
largest allocation, failed allocations, and unmatched frees. Read them in a
correctness test or a dedicated Node harness after decoding. Report both values:
the host-visible linear-memory commitment and the allocator's observed peak
describe different costs.

Do not add telemetry imports solely for benchmarking. Exported integer counters
keep the component deterministic and work in both direct WebAssembly harnesses
and QIP hosts.

## Keep Timing Runs Quiet

Builds and tests should use the repository's parallel Makefile targets:

```sh
make -j test
```

Timing runs should be serial. Do not run `make -j`, another benchmark, a browser
preview, or a large download in parallel with them. For performance-sensitive
changes:

1. Build and test both artifacts.
2. Stop unrelated CPU-heavy work.
3. Run the comparison more than once.
4. Treat isolated minimums and maximums as clues, not conclusions.
5. Record the command, input, hardware, runtime, artifact sizes, output hash,
   and representative distribution.

If a claimed improvement is smaller than the run-to-run standard deviation,
collect more samples and repeat the trial. If the component ships in both CLI
and browser hosts, confirm the change with wazero and V8.

## Recommended Workflow

Use this sequence for most component work:

1. Add a deterministic fixture and correctness test.
2. Save the current `.wasm` artifact as the baseline.
3. Run `qip bench` against baseline and candidate on several inputs.
4. Inspect execution, instantiation, memory, and binary size—not only the mean.
5. Add `--node` for a normal warmed V8 comparison; write a Node harness only
   for stateful, browser-specific, or telemetry measurements.
6. Compare with a mature native implementation that accepts the same input and
   produces equivalent output.
7. Run `make -j test`, then repeat the timing commands without parallel work.
8. Report regressions and tradeoffs along with improvements.

Benchmark the exported function or pipeline that users exercise. A
microbenchmark of an inner helper can locate a bottleneck, but it cannot
establish an end-to-end improvement.
