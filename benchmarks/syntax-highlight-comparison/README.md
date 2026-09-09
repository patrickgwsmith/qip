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
