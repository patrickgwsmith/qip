# JavaScript syntax highlight oracle

This differential oracle compares the QIP semantic JavaScript highlighter with
Shiki 4.4.3. It downloads exact library files and verifies their byte lengths
and SHA-256 digests before it runs either highlighter.

Install the pinned dependencies, build the component, and run all fixtures:

```sh
make install
make compare
```

Pass one or more fixture names after `--` to run a smaller set:

```sh
npm run compare -- react-development three-minified
```

Add `--json` to return confusion matrices and per-class precision and recall.
The score compares the class of each non-whitespace source character. The
runner also decodes the QIP HTML and requires it to reproduce the source.

Run the warmed Node.js benchmark without other CPU-heavy work:

```sh
make benchmark
```

It concatenates ten verified copies of `three.min.js`, creates one Wasm
instance, performs one warmup render, and measures ten renders. Each sample
includes the input and output copies. The script checks every output against
the warmup output after timing it.

Large library files find repeated classification errors. Reduce each useful
error to a small case in
`../../compliance/syntax-highlight-javascript-semantic.fixtures.txt`. The
Compliance oracle defines the stable component contract without embedding the
third-party libraries.

## WebAssembly SIMD experiment

gpu-lexer 0.0.2 is not one matrix multiplication. It first tokenizes the source
in JavaScript. Seven WebGPU compute passes then create embeddings, propagate
forward and backward context, reduce context trees, and classify each token.
The model has 41,321 `f32` weights. Some intermediate values use `f16`.

The experiment implements the matrix shape of the final neural classifier.
This is the most matrix-heavy part of the model. It performs 7,432
multiply-add operations for each token. The Zig and Odin versions process four
tokens with each SIMD instruction. The WAT version also uses relaxed SIMD
multiply-add instructions in the two largest matrix loops.

Build and compare all three versions with:

```sh
make benchmark-wasm-variants
```

The default workload uses the 2,483,870 lexical tokens that gpu-lexer creates
for the ten-copy `three.min.js` input. The benchmark uses synthetic features
and weights because it measures matrix throughput, not highlight correctness.
It also uses a fast approximation for `tanh`. These choices make the timing a
favorable lower bound for a full port. Each version must agree with its scalar
path and with the other versions.

The following results are from one alternating run on a MacBook Air with an
Apple M5. Each value is the mean of three runs.

| Implementation | SIMD time | Change from Zig | Wasm size |
| --- | ---: | ---: | ---: |
| Zig | 3,380 ms | — | 4.38 kB |
| Odin | 2,862 ms | 15% faster | 2.69 kB |
| WAT with relaxed SIMD | 3,152 ms | 7% faster | 2.62 kB |

Odin produced the fastest code. Raw WAT made the file 78 bytes smaller than
Odin, but it ran 10% slower. This test does not isolate the cause. The result
does not justify maintaining generated WAT for this kernel. The WAT version
also requires relaxed SIMD. The Zig and Odin versions require baseline SIMD.

Even the Odin classifier alone took more than five times gpu-lexer's complete
533 ms WebGPU run on the same machine. A full CPU WebAssembly port would add
tokenization and all recurrent context passes. This prototype uses one CPU
core. WebGPU distributes its work across many workgroups. A CPU WebAssembly
port is unlikely to improve speed on hardware with WebGPU.

The Wasm files do not contain the model weights. The 41,321 weights would add
165,284 bytes if stored as `f32`. The experiment does not establish label
agreement with gpu-lexer. A complete port must use the exact model weights,
match its `f16` rounding and activation functions, and compare every output
label. A WebAssembly port can still be useful as a CPU fallback when WebGPU is
not available.
