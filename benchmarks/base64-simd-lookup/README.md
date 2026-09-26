# Base64 SIMD lookup experiment

The [SIMD Base64 article](https://mcyoung.xyz/2023/11/27/simd-base64/) suggests
using the ASCII high nibble as a small SIMD lookup index. The WAT and C decoders
now use that index to select the sextet offset and low-nibble validity bounds.
They still fall back to scalar decoding on an invalid vector so the QIP error
includes the first bad byte offset. They also decode a complete final SIMD
block when the input has no padding.

The charts show **input throughput in MiB/s; higher is faster**. The input is
64 KiB of valid Base64. `qip bench --node` checked byte-for-byte output across
both runtimes and all candidates, then measured 21,249 runs per module with a
two-second target per module. Node.js/V8 reuses one instance. QIP/wazero creates
a fresh instance for each sample. Rust qipx uses Wasmtime and reuses one
instance. Its chart uses the mean of two two-second passes with candidate order
reversed. These boundaries should be compared within each chart, not across
charts.

![Node.js/V8 input throughput](node-v8-mib-per-second.svg)

![QIP/wazero input throughput](qip-wazero-mib-per-second.svg)

![Rust qipx/Wasmtime input throughput](rust-qipx-mib-per-second.svg)

| Decoder | Node.js/V8 before → after | QIP/wazero before → after | Rust qipx before → after |
| --- | ---: | ---: | ---: |
| WAT | 15.773 → 13.708 µs | 97.954 → 97.204 µs | 21.149 → 16.591 µs |
| C | 18.114 → 14.615 µs | 96.727 → 94.124 µs | 17.737 → 15.145 µs |

The WAT wazero change is small relative to run-to-run variance. Zig and Odin
were also tested with the final-block change alone. It did not give a useful
gain at 64 KiB, so their source and Wasm artifacts remain as before. Their
measurements are in [raw-benchmark.txt](raw-benchmark.txt). The Rust qipx
measurements are in the [forward](rust-qipx-forward.txt) and
[reverse](rust-qipx-reverse.txt) logs.

To reproduce the input and before artifacts from commit `77920c9`:

```sh
python3 - <<'PY'
import base64, random
from pathlib import Path
Path('/tmp/qip-base64-64k.txt').write_bytes(
    base64.b64encode(random.Random(0xB64).randbytes(49152)))
PY
git show 77920c9:text/base64-decode-simd.wasm > /tmp/qip-base64-wat-before.wasm
git show 77920c9:text/base64-decode-c-simd.wasm > /tmp/qip-base64-c-before.wasm
make -j text/base64-decode-simd.wasm text/base64-decode-c-simd.wasm
./qip bench -i /tmp/qip-base64-64k.txt --benchtime=2s --node \
  /tmp/qip-base64-wat-before.wasm text/base64-decode-simd.wasm \
  /tmp/qip-base64-c-before.wasm text/base64-decode-c-simd.wasm
make -j qipx-rust
rust/qipx/target/debug/qipx bench -i /tmp/qip-base64-64k.txt --benchtime=2s \
  /tmp/qip-base64-wat-before.wasm text/base64-decode-simd.wasm \
  /tmp/qip-base64-c-before.wasm text/base64-decode-c-simd.wasm
rust/qipx/target/debug/qipx bench -i /tmp/qip-base64-64k.txt --benchtime=2s \
  text/base64-decode-c-simd.wasm /tmp/qip-base64-c-before.wasm \
  text/base64-decode-simd.wasm /tmp/qip-base64-wat-before.wasm
```

Run the benchmark without another build or test process on the same CPU.
