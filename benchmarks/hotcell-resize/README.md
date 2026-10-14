# Image resize: QIP and HotCell

This benchmark times three Ruby call paths for one JPEG reduced to a 1024 × 768 PNG or WebP file:

| Path | Work inside the timed request |
| --- | --- |
| `direct_vips` | Ruby calls `ImageProcessing::Vips` in its own process. |
| `hotcell_vips` | Ruby sends file descriptors to HotCell's shipped Active Storage Vips operation. The cell runs the same `resize_to_limit` request. |
| `qip_wasmtime` | Ruby copies input through QIP's JPEG decoder, SIMD Lanczos3 reducer, and the selected PNG or WebP encoder in Wasmtime. |

The HotCell and direct Vips paths use `image_processing/vips` with the same saver options. The QIP path resizes in linear light with premultiplied alpha. All outputs must have the requested dimensions and format. Different resampling and color handling mean QIP and Vips bytes are not expected to match. Inspect outputs and compare decoded pixels before interpreting speed as a quality-equivalent result. The benchmark reports output size and SHA-256 so the artifacts can be checked separately.

Each measurement starts inside Ruby with the same input file path. Direct Vips and HotCell open the input file and read the result from a temporary file. QIP reads the JPEG into a Ruby string and returns a Ruby string. This reflects the HotCell file-descriptor API and the QIP byte API; it is an end-to-end resize and encode comparison, not an encoder-only measurement. Wasm compilation, cell boot, and warmup are outside the timed samples. The QIP modules and their instances are reused. HotCell uses its default one request per worker policy, configured explicitly in `config.rb`. Both Vips processes default to two libvips worker threads per request.

## Requirements

- Ruby 3.3 or newer, Bundler, and libvips 8.13 or newer.
- Linux for a hardened HotCell container measurement. `make cell` starts HotCell's uncontainerized development server and is useful for checking the harness on Linux or macOS; it does not measure the hardened deployment.
- The repository's tracked `.wasm` modules and the checked-in JPEG fixture.

This directory is one benchmark project with two Gemfiles and checked-in lockfiles. `Gemfile` is the Ruby caller; `Gemfile.cell` contains only the cell-side gems. The pinned HotCell source and installed gems stay in ignored `vendor/`, not copied into QIP.

## Run a development measurement

From this directory:

```sh
make -j install
make cell
```

In another terminal, with the cell running:

```sh
make benchmark
```

Select the output encoding with `BENCH_ARGS`:

```sh
make benchmark BENCH_ARGS='--format webp-lossless'
make benchmark BENCH_ARGS='--format webp-lossy'
```

Set `VIPS_CONCURRENCY` in **both** terminals to compare libvips worker counts. Restart the cell after changing the value; its workers inherit the setting from the server process. QIP does not use this setting.

```sh
# Cell terminal
VIPS_CONCURRENCY=1 make cell

# Benchmark terminal
VIPS_CONCURRENCY=1 make benchmark BENCH_ARGS='--format webp-lossy'
```

`png` is the default. The WebP modes use these settings:

| Mode | QIP WebP component | Vips saver options |
| --- | --- | --- |
| `webp-lossless` | Lossless preset level 6 | `lossless: true`, `effort: 6` |
| `webp-lossy` | Quality 95, method 4, sharp YUV on, low-memory mode on | `Q: 95`, `effort: 4`, `smart_subsample: true`, `alpha_q: 100` |

These settings express similar encoding intent. The two encoder implementations can still differ in compressed bytes, color handling, and speed. The JSON reports their sizes and decoded RGB difference; it does not establish equal visual quality. The Vips output from HotCell must match direct Vips byte for byte.

`make install` checks out HotCell commit `805dde16fdace04a864410ee4a1485e0881d2642` and installs both bundles. It does not alter the QIP root Gemfile or the HotCell source. For a deployed cell, point `HOTCELL_DIR` at its socket directory and run `make benchmark` without `make cell`. Use the same host and no competing CPU-heavy work for published numbers.

To check only the Ruby Wasmtime path without libvips or a running cell, run `make benchmark-qip` after installing the caller bundle. This is a harness check, not a HotCell comparison.

The default sample count is ten measured requests after two warmups. The runner alternates the three paths on each round and reports mean, p50, p95, minimum, and maximum latency in milliseconds. It reports the fixture hash, component hashes, Ruby version, and gem versions. After timing, it requires direct Vips and HotCell to produce identical bytes. It reports the mean and maximum absolute RGB channel difference between QIP and Vips on an 8-bit scale. This pixel statistic does not measure perceived quality. Record the CPU model, libvips version, HotCell container configuration, and peak RSS alongside any published results. On macOS, HotCell does not enforce its memory clamp; use Linux for a containment comparison.

Use `BENCH_ARGS` to change the output dimensions or sample count. The fixture is 4032 × 3024, so these examples keep its 4:3 aspect ratio:

```sh
make benchmark BENCH_ARGS='--width 256 --height 192 --warmups 2 --runs 30'
make benchmark BENCH_ARGS='--width 2048 --height 1536 --warmups 2 --runs 30'
```

The JSON includes `qip_setup_ms`: the one-time cost of creating the Wasmtime engine and compiling and instantiating the three modules. It excludes Ruby process startup and loading gems. Every measured QIP request uses those same instances and their existing linear memory; the resize component's input, output, and intermediate buffers are statically reserved. Longer runs improve the steady-state estimate but do not reduce the measured per-request cost. For a workload that starts a fresh process, add `qip_setup_ms / number_of_requests` to the QIP mean as an estimate of its per-request share of setup. HotCell server boot is outside its timed requests, so this setup number is not a complete cold-start comparison.

The runner writes one final file per path to `tmp/results/<format>/` after timing. Inspect those files and compare decoded pixels before publishing a performance claim. The QIP WebP encoders need more than the PNG-era 1 GiB Wasm linear-memory cap, so the harness allows 2 GiB for the encoder stage in WebP modes. Each other stage retains a 1 GiB cap. These are per-stage Wasm memory limits, not process RSS limits.

## Run on another Mac over SSH

First connect with ordinary SSH and verify the host key through a trusted channel. The destination needs Remote Login enabled, Ruby 3.3 or newer, Bundler, libvips, and internet access for `make install`. The known public SSH address is `m1@51.159.120.44`. The Tailscale hostname `scaleway-mac-mini.macaque-tritone.ts.net` reaches the same SSH server, but it requires the same SSH authentication.

Copy only the benchmark, its three tracked components, and the fixture. From the QIP repository root:

```sh
ssh m1@51.159.120.44 'mkdir -p ~/qip-benchmark'
rsync -azR --exclude='vendor/' --exclude='tmp/' --exclude='run/' \
  benchmarks/hotcell-resize/ \
  fixtures/j-g-d-uP-haUp0YQw-unsplash.jpg \
  image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm \
  image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm \
  image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm \
  image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm \
  m1@51.159.120.44:~/qip-benchmark/
```

On the remote Mac, run `make -j install` in `~/qip-benchmark/benchmarks/hotcell-resize`. Start `make cell` in one SSH session and run `make benchmark` in another. Run the timing command with no other CPU-heavy work. The JSON prints to the terminal and the output files are saved under `tmp/results/<format>/` on the remote Mac. Keep the remote command, hardware model, Ruby and libvips versions, and container or development-cell configuration with any published numbers.

This Mac run is a second development-cell measurement. It does not exercise HotCell's hardened Linux container or its Linux memory clamp.

## Interpretation

The direct Vips row estimates the cost of the same Vips transform without HotCell. The HotCell row includes socket dispatch, worker startup, file handling, and Vips processing. The QIP row includes three Wasm component calls, memory copies, and all decode/resize/encode work. None of the three rows alone proves that the outputs have the same visual quality or that the containment guarantees are equivalent.

The QIP path instantiates with no imports, uses the per-stage Wasm linear-memory limits described above, and uses a 30 second epoch deadline for each render. These are benchmark host settings, not a claim that the complete Ruby process is limited to their sum. The HotCell settings in `config.rb` apply to the cell process; its hardened container needs its own deployment limits. See [QIP hard limits](../../docs/hard-limits.md) and [HotCell's design](https://github.com/basecamp/hotcell/blob/master/docs/DESIGN.md) before comparing security properties.
