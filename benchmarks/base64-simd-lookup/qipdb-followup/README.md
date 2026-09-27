# Base64 SIMD follow-up with qipdb

qipdb made the WAT decoder's hot path visible. On 64 KiB of valid Base64, the
lookup decoder from commit `a783e21` called its 16-byte SIMD helper 4,096
times. It read one vector and wrote one vector per call. Moving the helper body
into the loop removed the calls without changing output or memory traffic.

The shipped qipdb initially trapped at `i16x8.shr_u` after 47 instructions.
Its interpreter supported only a small SIMD subset. This change adds the SIMD
operations used by the WAT decoder and the C decoder's `i8x16.gt_u`. The expanded
`test/qipdb.mjs` cases check the complete alphabet, output hash, and vector-loop
counts for both modules. qipdb finishes the compiled C SIMD decoder: its 64 KiB
trace reports 417,859 executed instructions, 4,097 memory reads, 4,096 writes,
and the same output SHA-256 as the WAT decoder. See the [C trace](qipdb-c.txt).

## Observations

qipdb counters are executed Wasm operations, not elapsed time:

| 64 KiB input | Before | Inline helper | Change |
| --- | ---: | ---: | ---: |
| Executed instructions | 520,255 | 491,583 | −5.5% |
| Function calls | 4,096 | 0 | −4,096 |
| Taken branches | 4,098 | 4,098 | none |
| Memory reads | 4,097 | 4,097 | none |
| Memory writes | 4,096 | 4,096 | none |
| Wasm size | 1,167 B | 1,146 B | −21 B |

Both runs returned 49,152 bytes with SHA-256
`2f9ed51cabdc4c74cb6139abc0b8da5e1b6565b4bb0832507c133a9a9dd341df`.
The [before trace](qipdb-before.txt) and [after trace](qipdb-after.txt) retain
the full qipdb screens.

The production runtimes measured the same before artifact and inline build:

| Boundary | Before | Inline helper | Interpretation |
| --- | ---: | ---: | --- |
| QIP/wazero, fresh instance | 103.872 µs | 103.181 µs | Within run variation |
| Node.js/V8, reused instance | 13.839 µs | 13.830 µs | No useful change |
| Rust qipx/Wasmtime, reused instance | 16.868 µs | 14.632 µs | 13.3% less time |

The Rust figures average two two-second passes with reversed candidate order.
The other two columns come from one two-second comparison and should not be
read as precise gains. The raw [QIP and Node](qip-node.txt),
[Rust forward](rust-forward.txt), and [Rust reverse](rust-reverse.txt) outputs
include output hashes and runtime details. Rust qipx was the Makefile's debug
build.

## Reproduce

```sh
git show a783e21:text/base64-decode-simd.wasm > /tmp/qip-base64-lookup-before.wasm
python3 - <<'PY'
import base64, random
from pathlib import Path
Path('/tmp/qip-base64-64k.txt').write_bytes(
    base64.b64encode(random.Random(0xB64).randbytes(49152)))
PY
make -j tui/qipdb.wasm text/base64-decode-simd.wasm text/base64-decode-c-simd.wasm
node benchmarks/base64-simd-lookup/qipdb-followup/profile.mjs \
  /tmp/qip-base64-lookup-before.wasm /tmp/qip-base64-64k.txt
node benchmarks/base64-simd-lookup/qipdb-followup/profile.mjs \
  text/base64-decode-simd.wasm /tmp/qip-base64-64k.txt
node benchmarks/base64-simd-lookup/qipdb-followup/profile.mjs \
  text/base64-decode-c-simd.wasm /tmp/qip-base64-64k.txt
```

Run benchmarks without another CPU-heavy job. qipdb is an interpreter, so use
its counts to identify work and use `qip bench` or `qipx bench` to decide speed.
