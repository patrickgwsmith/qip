# Counting Memory Page Reads And Writes In The QIP Interpreter

`qip-interpret-memory-page-writes-csv.wasm` runs a QIP Content component in the
bounded Zig interpreter, then returns one CSV row for each 64 KiB memory page
that was initialized, read, or written. Use it to find where a component spends
its reads and writes: data tables, output buffers, the shadow stack, or scratch
memory.

```sh
make -j qip application/wasm/qip-interpret-memory-page-writes-csv.wasm

qip run \
  -F component=@text/markdown/commonmark.0.31.2.wasm \
  -F 'input=# Hello

Some *text* with [a link](https://example.com).' \
  application/wasm/qip-interpret-memory-page-writes-csv.wasm
```

The output for this request starts like this:

```csv
page,region,initialized_bytes,reads,bytes_read,writes,bytes_written,distinct_bytes_written,rewrite_ratio
15,stack,0,935,3348,700,2888,415,6.96
16,data+input,43776,641,1825,7,28,4,7.00
48,input+output,0,400,1336,144,176,88,2.00
80,other,0,23,92,4,16,16,1.00
```

The request uses the same `component`, `input`, and `uniforms[<key>]` fields
and the same `instruction_budget` uniform as
[the QIP Content interpreter](/docs/qip-content-interpreter).

## Columns

- `page` is the zero-based page index. Multiply by 65536 for the first byte.
- `region` lists the known ranges that overlap the page, joined with `+`:
  - `data`: an active data segment.
  - `input`: the target's `input_ptr` buffer, up to its declared capacity.
  - `stack`: from the lowest value of global 0 up to its initial value. LLVM
    toolchains use global 0 as `__stack_pointer`.
  - `output`: the bytes that the target returned.
  - `other`: none of the above, usually heap or static scratch buffers.
- `initialized_bytes` counts data segment and request input bytes copied into
  the page before the run.
- `reads` counts load operations and `memory.copy` sources that touched the
  page. One operation that crosses a page boundary counts once on each page.
- `bytes_read` counts every byte read, including rereads of the same byte.
- `writes` counts store, `memory.copy`, and `memory.fill` operations that
  touched the page. One operation that crosses a page boundary counts once on
  each page.
- `bytes_written` counts every byte written, including rewrites of the same
  byte.
- `distinct_bytes_written` counts bytes written at least once.
- `rewrite_ratio` is `bytes_written / distinct_bytes_written`, rounded to two
  decimals, and empty for a page that was not written.
  A ratio near 1.00 means each byte was written once. A high ratio means the
  component rewrites the same memory, which is normal for the stack and can
  show churn in scratch buffers.

A page is labelled by overlap only. A page labelled `data` can also hold heap
bytes after the end of the segment.

## What counts as a read or write

The read and write counters cover the target's uniform setters and its `render`
call. Copying data segments and the request input into memory before the run
counts only toward `initialized_bytes`. Pages that were not initialized, read,
or written get no row.

A malformed request, unsupported Wasm feature, trap, exhausted budget, invalid
target Content contract, or target rejection becomes an outer Content
rejection. The tool does not report pages for a run that did not finish.

## When not to use it

Page totals do not show when the component wrote each byte or which
instructions produced it. Use qipdb to step through instructions and inspect
memory as the component runs. The interpreter runs much slower than `qip run`,
so measure speed with [benchmarks](/docs/benchmarking-components), not with
this tool.
